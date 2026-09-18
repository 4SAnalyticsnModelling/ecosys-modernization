const std = @import("std");
const builtin = @import("builtin");
const numerics = @import("../core/numerics.zig");

pub const Parameters = struct {
    minimum_richardson_number: f64,
    maximum_richardson_number: f64,
    richardson_resistance_multiplier: f64,
    minimum_aerodynamic_resistance_h_per_m: f64,
    maximum_aerodynamic_resistance_h_per_m: f64,
    volumetric_air_heat_capacity_megajoules_per_m3_k: f64,
    minimum_air_column_height_m: f64,
    sensible_heat_conductivity_megajoules_per_m_h_k: f64,
    liquid_water_latent_heat_megajoules_per_m3: f64,
    saturation_vapor_prefactor_k: f64,
    saturation_relative_humidity: f64,
    saturation_temperature_k: f64,
    saturation_reference_inverse_temperature_per_k: f64,
    /// GROUND-AIR-VAPOR-CONDENSATION-001: latent heat of sublimation, used
    /// instead of `liquid_water_latent_heat_megajoules_per_m3` when a
    /// genuinely-supersaturated boundary-air substep deposits frost (solved
    /// temperature below `pure_water_freezing_temperature_k`) rather than
    /// dew. Always strictly greater than the vaporization value (fusion is
    /// additive), matching the snow-side convention of an independently
    /// supplied constant rather than a derived vaporization+fusion sum
    /// (`src/soil/water/snow_vapor_equilibrium.zig`'s
    /// `snow_sublimation_latent_heat_megajoules_per_m3`).
    sublimation_latent_heat_megajoules_per_m3: f64,
    /// GROUND-AIR-VAPOR-CONDENSATION-001: the dew/frost phase boundary for
    /// the same latent-heat choice above.
    pure_water_freezing_temperature_k: f64,
};

/// Eliminate a finite-capacity surface from a backward-Euler sensible-heat
/// pair: C*(Ts_new-Ts_old) = dt*G*(Ta_new-Ts_new). The remaining air equation
/// receives Geff*(Ts_old-Ta_new), Geff = G*C/(C+dt*G). Use that SAME Geff
/// to publish the opposite surface heat after the air Newton-Anderson solve.
/// Radiation, water-carrier heat and phase changes retain their own owners.
pub fn finiteSurfaceSensibleConductance(
    conductance_megajoules_per_h_k: f64,
    heat_capacity_megajoules_per_k: f64,
    time_step_hours: f64,
) !f64 {
    inline for (.{ conductance_megajoules_per_h_k, heat_capacity_megajoules_per_k, time_step_hours }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSurfaceSensiblePair;
    if (conductance_megajoules_per_h_k < 0 or heat_capacity_megajoules_per_k < 0 or
        time_step_hours <= 0 or time_step_hours > 1) return error.InvalidSurfaceSensiblePair;
    if (conductance_megajoules_per_h_k == 0 or heat_capacity_megajoules_per_k == 0) return 0;
    const inverse_conductance = 1 / conductance_megajoules_per_h_k + time_step_hours / heat_capacity_megajoules_per_k;
    const effective = 1 / inverse_conductance;
    if (!std.math.isFinite(effective) or effective < 0) return error.NonFiniteSurfaceSensiblePair;
    return effective;
}

pub fn pairedSurfaceSensibleHeat(
    effective_conductance_megajoules_per_h_k: f64,
    initial_surface_temperature_k: f64,
    accepted_air_temperature_k: f64,
    time_step_hours: f64,
) !f64 {
    inline for (.{ effective_conductance_megajoules_per_h_k, initial_surface_temperature_k, accepted_air_temperature_k, time_step_hours }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSurfaceSensiblePair;
    if (effective_conductance_megajoules_per_h_k < 0 or initial_surface_temperature_k <= 0 or
        accepted_air_temperature_k <= 0 or time_step_hours <= 0 or time_step_hours > 1)
        return error.InvalidSurfaceSensiblePair;
    const heat = effective_conductance_megajoules_per_h_k *
        (accepted_air_temperature_k - initial_surface_temperature_k) * time_step_hours;
    if (!std.math.isFinite(heat)) return error.NonFiniteSurfaceSensiblePair;
    return heat;
}

/// Signed accepted-substep water-vapor and sensible-energy balance of the
/// boundary air control volume. Every transfer is positive into ground air.
/// Prescribed terms are already-evaluated canopy/standing-dead/surface
/// exchange; implicit terms are evaluated at the accepted intensive state.
pub const VaporBalance = struct {
    storage_change_m3: f64 = 0,
    atmospheric_transfer_m3: f64 = 0,
    /// Portion of `atmospheric_transfer_m3` supplied by the active zero-vapor
    /// constraint when an already-accepted surface withdrawal would otherwise
    /// drive this diagnostic boundary-air control volume negative. This is a
    /// subset of the atmospheric term, not an additional closure term.
    zero_vapor_bound_atmospheric_transfer_m3: f64 = 0,
    prescribed_non_atmospheric_transfer_m3: f64 = 0,
    implicit_surface_transfer_m3: f64 = 0,
    /// GROUND-AIR-VAPOR-CONDENSATION-001: water leaving this substep's
    /// boundary-air control volume as condensate/frost because the implicit
    /// vapor update was genuinely supersaturated at the just-solved
    /// temperature. Zero in the common (non-supersaturated) case. Deposited
    /// into `State.condensate_frost_pool_m3`, a dedicated sink owned by this
    /// module (see that register entry for why no existing litter/snow pool
    /// was reused). Already netted out of `closure_residual_m3` above, so
    /// the four transfer terms plus this one sum exactly to
    /// `storage_change_m3`.
    condensate_deposition_m3: f64 = 0,
    /// GROUND-AIR-VAPOR-CONDENSATION-001: the vaporization or sublimation
    /// latent heat released by `condensate_deposition_m3` above forming this
    /// substep. Zero in the common (non-supersaturated) case. Deliberately
    /// **not** folded into this control volume's own sensible-heat ledger
    /// below (`sensible_heat_storage_change_megajoules` and the
    /// `atmospheric`/`prescribed`/`implicit` transfer terms are entirely
    /// unaffected by condensation): this thin boundary-air column's heat
    /// capacity is tiny (a few m3 of air), so crediting the full latent
    /// release into its own temperature produced multi-tens-of-kelvin
    /// one-shot jumps that then destabilized the downstream soil-heat and
    /// coupled-gas solvers, which consume `State.temperature_k` as a
    /// same-hour boundary condition (see the register entry's verification
    /// history). Physically this heat is released where the phase change
    /// happens -- at the boundary-air/surface interface -- not uniformly
    /// through the whole thin air column, so it is booked into the paired
    /// `State.condensate_frost_pool_heat_megajoules` alongside the
    /// condensate mass instead: still exact and never dropped (unlike
    /// legacy's uncorrected clip), just not re-injected into this specific
    /// tiny thermal mass.
    condensate_deposition_latent_heat_megajoules: f64 = 0,
    closure_residual_m3: f64 = 0,
    sensible_heat_storage_change_megajoules: f64 = 0,
    atmospheric_sensible_heat_transfer_megajoules: f64 = 0,
    /// Portion of `atmospheric_sensible_heat_transfer_megajoules` supplied by
    /// the bounded fallback after Newton-Anderson cannot resolve the
    /// prescribed, already-accepted surface transfer. This is a subset of the
    /// atmospheric term, not an additional closure term.
    temperature_bound_atmospheric_transfer_megajoules: f64 = 0,
    prescribed_non_atmospheric_sensible_heat_transfer_megajoules: f64 = 0,
    implicit_non_atmospheric_sensible_heat_transfer_megajoules: f64 = 0,
    sensible_heat_closure_residual_megajoules: f64 = 0,
};

/// Exact extensive-state change caused only by HOUR1's EVAPQ/VHCPQ geometry
/// refresh. The carried TKQG/VPQG intensive state is unchanged, so the same
/// signed amount is an atmospheric entrainment/detrainment transfer. This is
/// caller-owned hourly transaction data; it is not checkpointed or published
/// into an ecosystem layer ledger.
pub const GeometryBalance = struct {
    initial_vapor_storage_m3: f64 = 0,
    vapor_storage_change_m3: f64 = 0,
    atmospheric_vapor_transfer_m3: f64 = 0,
    initial_sensible_heat_megajoules: f64 = 0,
    sensible_heat_storage_change_megajoules: f64 = 0,
    atmospheric_sensible_heat_transfer_megajoules: f64 = 0,
};

/// Conservation acceptance is deliberately distinct from the temperature
/// nonlinear solve. The absolute floor is a water depth and is made extensive
/// with the cell area; the relative term scales with local stored/transported
/// vapor so large cells do not inherit a universal scalar threshold.
pub const VaporConservationTolerances = struct {
    absolute_water_depth_m: f64,
    relative: f64,
    /// Permit the exact nonnegative constrained solution when the implicit
    /// vapor equation requests negative storage. The unmet withdrawal is
    /// supplied by an explicit atmospheric constraint transfer rather than by
    /// clipping or by discarding water.
    accept_bounded_zero_vapor_state: bool = false,

    fn validate(self: VaporConservationTolerances) !void {
        if (!std.math.isFinite(self.absolute_water_depth_m) or
            self.absolute_water_depth_m < 0 or
            !std.math.isFinite(self.relative) or self.relative <= 0)
            return error.InvalidGroundAirVaporConservationTolerance;
    }
};

pub const EnergyConservationTolerances = struct {
    absolute_megajoules_per_m2: f64,
    relative: f64,
    /// Permit the solver's best bounded iterate only after Newton-Anderson
    /// actually fails. Any unresolved balance is booked as an atmospheric
    /// constraint transfer, so successful nonlinear solves are unchanged and
    /// the same exact energy-closure gate still governs publication.
    accept_bounded_temperature_state: bool = false,
    /// Physical-acceptance goal (2026-09-04): default `false` preserves
    /// today's behavior exactly -- a Newton-Anderson ceiling failure is
    /// always propagated. When `true`, that ceiling failure instead hands
    /// its otherwise-discarded last iterate (via
    /// `numerics.SolverOptions.last_iterate_on_failure`) to the exact same
    /// sensible-energy closure check below that already gates the
    /// converged path. This invents no new tolerance: a recovered
    /// candidate is accepted only if it passes the identical conservation
    /// gate an actually-converged root would have to pass, and is rejected
    /// by that same gate (`error.GroundAirEnergyConservationFailure`,
    /// already retryable) otherwise.
    accept_physically_conserved_ceiling: bool = false,

    fn validate(self: EnergyConservationTolerances) !void {
        if (!std.math.isFinite(self.absolute_megajoules_per_m2) or
            self.absolute_megajoules_per_m2 < 0 or
            !std.math.isFinite(self.relative) or self.relative <= 0)
            return error.InvalidGroundAirEnergyConservationTolerance;
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    temperature_k: []f64,
    vapor_volume_fraction: []f64,
    heat_capacity_megajoules_per_k: []f64,
    air_volume_m3: []f64,
    iteration_count: []u16,
    vapor_balance: []VaporBalance,
    /// GROUND-AIR-VAPOR-CONDENSATION-001: cumulative condensate/frost
    /// deposited at the boundary-air/surface interface across every substep
    /// this module has ever accepted -- a dedicated, always-conserved sink
    /// owned entirely by this module (not double-counted against litter,
    /// snow, or any other pool). Diagnostic only: nothing reads it back into
    /// the simulation, so it cannot introduce a feedback bug. Like
    /// `vapor_balance`, it is not currently persisted across checkpoint
    /// save/resume (see `src/io/checkpoint/surface_boundary_checkpoint.zig`'s
    /// `groundAirConstFields`, which enumerates exactly four persisted
    /// fields); flagged as a known follow-up in the discrepancy register.
    condensate_frost_pool_m3: []f64,
    /// GROUND-AIR-VAPOR-CONDENSATION-001: cumulative latent heat released by
    /// everything ever deposited into `condensate_frost_pool_m3` above,
    /// booked separately from this control volume's own sensible-heat state
    /// -- see `VaporBalance.condensate_deposition_latent_heat_megajoules`
    /// for why. Same diagnostic-only, not-yet-checkpointed status as that
    /// field.
    condensate_frost_pool_heat_megajoules: []f64,

    pub fn init(allocator: std.mem.Allocator, initial_temperature_k: []const f64, initial_vapor_volume_fraction: []const f64, cell_area_m2: []const f64, reference_height_m: f64, parameters: Parameters) !State {
        const count = initial_temperature_k.len;
        if (count == 0 or initial_vapor_volume_fraction.len != count or cell_area_m2.len != count or !std.math.isFinite(reference_height_m) or reference_height_m <= 0) return error.InvalidGroundAirInitialization;
        const temperature = try allocator.dupe(f64, initial_temperature_k);
        errdefer allocator.free(temperature);
        const vapor = try allocator.dupe(f64, initial_vapor_volume_fraction);
        errdefer allocator.free(vapor);
        const capacity = try allocator.alloc(f64, count);
        errdefer allocator.free(capacity);
        const volume = try allocator.alloc(f64, count);
        errdefer allocator.free(volume);
        const iterations = try allocator.alloc(u16, count);
        errdefer allocator.free(iterations);
        @memset(iterations, 0);
        const vapor_balance = try allocator.alloc(VaporBalance, count);
        errdefer allocator.free(vapor_balance);
        @memset(vapor_balance, .{});
        const condensate_frost_pool = try allocator.alloc(f64, count);
        errdefer allocator.free(condensate_frost_pool);
        @memset(condensate_frost_pool, 0);
        const condensate_frost_pool_heat = try allocator.alloc(f64, count);
        errdefer allocator.free(condensate_frost_pool_heat);
        @memset(condensate_frost_pool_heat, 0);
        for (0..count) |cell| {
            if (!std.math.isFinite(temperature[cell]) or temperature[cell] <= 0 or !std.math.isFinite(vapor[cell]) or vapor[cell] < 0 or !std.math.isFinite(cell_area_m2[cell]) or cell_area_m2[cell] <= 0) return error.InvalidGroundAirInitialization;
            const height = @max(parameters.minimum_air_column_height_m, reference_height_m);
            volume[cell] = height * cell_area_m2[cell];
            capacity[cell] = volume[cell] * parameters.volumetric_air_heat_capacity_megajoules_per_m3_k;
        }
        return .{ .allocator = allocator, .cell_count = count, .temperature_k = temperature, .vapor_volume_fraction = vapor, .heat_capacity_megajoules_per_k = capacity, .air_volume_m3 = volume, .iteration_count = iterations, .vapor_balance = vapor_balance, .condensate_frost_pool_m3 = condensate_frost_pool, .condensate_frost_pool_heat_megajoules = condensate_frost_pool_heat };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.condensate_frost_pool_heat_megajoules);
        self.allocator.free(self.condensate_frost_pool_m3);
        self.allocator.free(self.vapor_balance);
        self.allocator.free(self.iteration_count);
        self.allocator.free(self.air_volume_m3);
        self.allocator.free(self.heat_capacity_megajoules_per_k);
        self.allocator.free(self.vapor_volume_fraction);
        self.allocator.free(self.temperature_k);
        self.* = undefined;
    }

    /// HOUR1 4875--4876 refreshes the near-ground mixing volume (`EVAPQ`) and
    /// dry-air heat capacity (`VHCPQ`) from the current reference height while
    /// retaining the carried `TKQG`/`VPQG` intensive state. Consequently a
    /// volume change represents boundary-air entrainment/detrainment at the
    /// carried temperature and vapor fraction; it is not an unreported clamp
    /// or phase change.
    pub fn refreshGeometry(self: *State, cell_area_m2: []const f64, reference_height_m: []const f64, parameters: Parameters, balance: []GeometryBalance) !void {
        if (cell_area_m2.len != self.cell_count or reference_height_m.len != self.cell_count or balance.len != self.cell_count) return error.GroundAirDimensionMismatch;
        try validateParameters(parameters);
        // Validate the entire refresh before changing either live state or the
        // caller-owned result. A bad later cell therefore cannot leave a
        // partially refreshed hour.
        for (0..self.cell_count) |cell| {
            if (!std.math.isFinite(cell_area_m2[cell]) or cell_area_m2[cell] <= 0 or
                !std.math.isFinite(reference_height_m[cell]) or reference_height_m[cell] <= 0 or
                !std.math.isFinite(self.temperature_k[cell]) or self.temperature_k[cell] <= 0 or
                !std.math.isFinite(self.vapor_volume_fraction[cell]) or self.vapor_volume_fraction[cell] < 0 or
                !std.math.isFinite(self.air_volume_m3[cell]) or self.air_volume_m3[cell] <= 0 or
                !std.math.isFinite(self.heat_capacity_megajoules_per_k[cell]) or self.heat_capacity_megajoules_per_k[cell] <= 0)
                return error.InvalidGroundAirGeometry;
            const refreshed_volume_m3 = @max(parameters.minimum_air_column_height_m, reference_height_m[cell]) * cell_area_m2[cell];
            const refreshed_capacity_megajoules_per_k = refreshed_volume_m3 * parameters.volumetric_air_heat_capacity_megajoules_per_m3_k;
            const initial_vapor_storage_m3 = self.vapor_volume_fraction[cell] * self.air_volume_m3[cell];
            const refreshed_vapor_storage_m3 = self.vapor_volume_fraction[cell] * refreshed_volume_m3;
            const initial_sensible_heat_megajoules = self.temperature_k[cell] * self.heat_capacity_megajoules_per_k[cell];
            const refreshed_sensible_heat_megajoules = self.temperature_k[cell] * refreshed_capacity_megajoules_per_k;
            inline for (.{
                refreshed_volume_m3,
                refreshed_capacity_megajoules_per_k,
                initial_vapor_storage_m3,
                refreshed_vapor_storage_m3,
                initial_sensible_heat_megajoules,
                refreshed_sensible_heat_megajoules,
            }) |value| if (!std.math.isFinite(value)) return error.InvalidGroundAirGeometry;
        }
        for (0..self.cell_count) |cell| {
            const refreshed_volume_m3 = @max(parameters.minimum_air_column_height_m, reference_height_m[cell]) * cell_area_m2[cell];
            const refreshed_capacity_megajoules_per_k = refreshed_volume_m3 * parameters.volumetric_air_heat_capacity_megajoules_per_m3_k;
            const initial_vapor_storage_m3 = self.vapor_volume_fraction[cell] * self.air_volume_m3[cell];
            const vapor_storage_change_m3 = self.vapor_volume_fraction[cell] * refreshed_volume_m3 - initial_vapor_storage_m3;
            const initial_sensible_heat_megajoules = self.temperature_k[cell] * self.heat_capacity_megajoules_per_k[cell];
            const sensible_heat_storage_change_megajoules = self.temperature_k[cell] * refreshed_capacity_megajoules_per_k - initial_sensible_heat_megajoules;
            balance[cell] = .{
                .initial_vapor_storage_m3 = initial_vapor_storage_m3,
                .vapor_storage_change_m3 = vapor_storage_change_m3,
                .atmospheric_vapor_transfer_m3 = vapor_storage_change_m3,
                .initial_sensible_heat_megajoules = initial_sensible_heat_megajoules,
                .sensible_heat_storage_change_megajoules = sensible_heat_storage_change_megajoules,
                .atmospheric_sensible_heat_transfer_megajoules = sensible_heat_storage_change_megajoules,
            };
            self.air_volume_m3[cell] = refreshed_volume_m3;
            self.heat_capacity_megajoules_per_k[cell] = refreshed_capacity_megajoules_per_k;
        }
    }
};

pub const Inputs = struct {
    atmospheric_temperature_k: []const f64,
    atmospheric_vapor_volume_fraction: []const f64,
    cell_area_m2: []const f64,
    bulk_richardson_coefficient_k: []const f64,
    neutral_atmospheric_resistance_h_per_m: []const f64,
    canopy_resistance_h_per_m: []const f64,
    non_atmospheric_sensible_heat_megajoules_per_h: []const f64,
    non_atmospheric_vapor_flux_m3_per_h: []const f64,
    non_atmospheric_sensible_conductance_megajoules_per_h_k: []const f64,
    non_atmospheric_sensible_source_temperature_k: []const f64,
    non_atmospheric_vapor_conductance_m3_per_h: []const f64,
    non_atmospheric_vapor_source_fraction: []const f64,
};

pub fn vaporPressureKpa(vapor_volume_fraction: f64, temperature_k: f64, parameters: Parameters) !f64 {
    if (!std.math.isFinite(vapor_volume_fraction) or vapor_volume_fraction < 0 or !std.math.isFinite(temperature_k) or temperature_k <= 0) return error.InvalidGroundAirVaporState;
    return vapor_volume_fraction * temperature_k / parameters.saturation_vapor_prefactor_k;
}

pub fn vaporVolumeFraction(vapor_pressure_kpa: f64, temperature_k: f64, parameters: Parameters) !f64 {
    if (!std.math.isFinite(vapor_pressure_kpa) or vapor_pressure_kpa < 0 or !std.math.isFinite(temperature_k) or temperature_k <= 0) return error.InvalidAtmosphericVaporState;
    return vapor_pressure_kpa * parameters.saturation_vapor_prefactor_k / temperature_k;
}

/// WATSUB VPGV/VPRV: soil/litter surface saturation vapor fraction, with the
/// final EXP(18.0*PSISVG/(8.3143*TKS22)) Kelvin-equation factor that
/// suppresses evaporation as the surface's own matric+osmotic water
/// potential drops below zero (SOIL-EVAP-KELVIN-SUPPRESSION-001). At
/// water_potential_megapascal=0 (saturated) the factor is exactly 1,
/// matching the unsuppressed saturation_fraction formula used by `solve`
/// above; as the surface dries and the potential becomes strongly negative,
/// it collapses toward 0.
pub fn surfaceVaporFractionWithKelvinSuppression(
    surface_temperature_k: f64,
    water_potential_megapascal: f64,
    surface_vapor_activity_fraction: f64,
    parameters: Parameters,
) !f64 {
    if (!std.math.isFinite(water_potential_megapascal)) return error.NonFiniteSurfaceWaterPotentialForEvaporation;
    if (!std.math.isFinite(surface_vapor_activity_fraction)) return error.NonFiniteSurfaceVaporActivityFraction;
    try validateParameters(parameters);
    if (!std.math.isFinite(surface_temperature_k) or surface_temperature_k <= 0) return error.InvalidGroundAirSurfaceTemperature;
    const kelvin_suppression = @exp(18.0 * water_potential_megapascal / (8.3143 * surface_temperature_k));
    return parameters.saturation_vapor_prefactor_k / surface_temperature_k * parameters.saturation_relative_humidity * surface_vapor_activity_fraction *
        @exp(parameters.saturation_temperature_k * (parameters.saturation_reference_inverse_temperature_per_k - 1 / surface_temperature_k)) * kelvin_suppression;
}

pub fn deriveSurfaceSources(cell_area_m2: []const f64, surface_sensible_heat_flux_megajoules_per_m2_h: []const f64, surface_latent_heat_flux_megajoules_per_m2_h: []const f64, parameters: Parameters, sensible_heat_source_megajoules_per_h: []f64, vapor_source_m3_per_h: []f64) !void {
    const count = cell_area_m2.len;
    inline for (.{ surface_sensible_heat_flux_megajoules_per_m2_h.len, surface_latent_heat_flux_megajoules_per_m2_h.len, sensible_heat_source_megajoules_per_h.len, vapor_source_m3_per_h.len }) |length| if (length != count) return error.GroundAirDimensionMismatch;
    try validateParameters(parameters);
    for (0..count) |cell| {
        inline for (.{ cell_area_m2[cell], surface_sensible_heat_flux_megajoules_per_m2_h[cell], surface_latent_heat_flux_megajoules_per_m2_h[cell] }) |value| if (!std.math.isFinite(value)) return error.NonFiniteGroundAirSurfaceFlux;
        if (cell_area_m2[cell] <= 0) return error.InvalidGroundAirSurfaceArea;
        sensible_heat_source_megajoules_per_h[cell] = -surface_sensible_heat_flux_megajoules_per_m2_h[cell] * cell_area_m2[cell];
        vapor_source_m3_per_h[cell] = -surface_latent_heat_flux_megajoules_per_m2_h[cell] * cell_area_m2[cell] / parameters.liquid_water_latent_heat_megajoules_per_m3;
    }
}

const TemperatureContext = struct {
    old_temperature_k: f64,
    atmospheric_temperature_k: f64,
    heat_capacity_megajoules_per_k: f64,
    cell_area_m2: f64,
    bulk_richardson_coefficient_k: f64,
    neutral_resistance_h_per_m: f64,
    canopy_resistance_h_per_m: f64,
    source_heat_megajoules_per_h: f64,
    source_conductance_megajoules_per_h_k: f64,
    source_temperature_k: f64,
    time_step_hours: f64,
    parameters: Parameters,
};

const minimum_ground_air_temperature_k: f64 = 173.15;
const maximum_ground_air_temperature_k: f64 = 373.15;

fn energyConstrainedTemperatureOptions(
    solver_options: numerics.SolverOptions,
    energy_tolerances: EnergyConservationTolerances,
    cell_area_m2: f64,
    context: TemperatureContext,
) numerics.SolverOptions {
    var options = solver_options;
    options.safeguard_with_bracket = true;
    options.absolute_tolerance = @min(
        options.absolute_tolerance,
        energy_tolerances.absolute_megajoules_per_m2 * cell_area_m2 *
            context.time_step_hours,
    );
    options.relative_tolerance = @min(options.relative_tolerance, energy_tolerances.relative);
    options.residual_scale = temperatureResidualEnergyScale(context);

    // The final activity scale is not known until the root is available, but
    // it is always at least dt times the entering stored sensible energy. The
    // configured physical policy is hourly, so this partitions its absolute
    // and stored-energy-relative budget by accepted duration without applying
    // dt twice to already-integrated transfers. Preserve the honest full
    // residual scale and minimally tighten only its relative coefficient. The
    // half-entry-step fallback is mathematically sufficient when the generic
    // 64-epsilon solver floor alone would consume the bound:
    // 64 eps * (dt*E/2) == 32 eps * dt*E.
    const entry_stored_energy_megajoules = @abs(
        context.heat_capacity_megajoules_per_k * context.old_temperature_k,
    );
    const entry_step_activity_megajoules =
        context.time_step_hours * entry_stored_energy_megajoules;
    const conservation_lower_bound_megajoules =
        energy_tolerances.absolute_megajoules_per_m2 * cell_area_m2 *
        context.time_step_hours +
        energy_tolerances.relative * entry_step_activity_megajoules +
        32 * std.math.floatEps(f64) * entry_step_activity_megajoules;
    if (numerics.convergenceTolerance(options) > conservation_lower_bound_megajoules) {
        const fixed_solver_floor = @max(
            options.absolute_tolerance,
            64 * std.math.floatEps(f64) * options.residual_scale,
        );
        if (fixed_solver_floor < conservation_lower_bound_megajoules) {
            const available_relative_band = std.math.nextAfter(
                f64,
                conservation_lower_bound_megajoules - fixed_solver_floor,
                0,
            );
            const relative_cap = std.math.nextAfter(
                f64,
                available_relative_band / options.residual_scale,
                0,
            );
            if (relative_cap > 0)
                options.relative_tolerance = @min(
                    options.relative_tolerance,
                    relative_cap,
                );
        }
        if (numerics.convergenceTolerance(options) > conservation_lower_bound_megajoules)
            options.residual_scale = 0.5 * entry_step_activity_megajoules;
    }
    return options;
}

pub fn solve(
    state: *State,
    inputs: Inputs,
    parameters: Parameters,
    solver_options: numerics.SolverOptions,
    vapor_tolerances: VaporConservationTolerances,
    energy_tolerances: EnergyConservationTolerances,
    time_step_hours: f64,
) !void {
    inline for (.{ inputs.atmospheric_temperature_k.len, inputs.atmospheric_vapor_volume_fraction.len, inputs.cell_area_m2.len, inputs.bulk_richardson_coefficient_k.len, inputs.neutral_atmospheric_resistance_h_per_m.len, inputs.canopy_resistance_h_per_m.len, inputs.non_atmospheric_sensible_heat_megajoules_per_h.len, inputs.non_atmospheric_vapor_flux_m3_per_h.len, inputs.non_atmospheric_sensible_conductance_megajoules_per_h_k.len, inputs.non_atmospheric_sensible_source_temperature_k.len, inputs.non_atmospheric_vapor_conductance_m3_per_h.len, inputs.non_atmospheric_vapor_source_fraction.len }) |length| if (length != state.cell_count) return error.GroundAirDimensionMismatch;
    try validateParameters(parameters);
    try vapor_tolerances.validate();
    try energy_tolerances.validate();
    if (!std.math.isFinite(time_step_hours) or time_step_hours <= 0 or time_step_hours > 1)
        return error.InvalidGroundAirTimeStep;
    const candidate_temperature = try state.allocator.dupe(f64, state.temperature_k);
    defer state.allocator.free(candidate_temperature);
    const candidate_vapor = try state.allocator.dupe(f64, state.vapor_volume_fraction);
    defer state.allocator.free(candidate_vapor);
    const candidate_iterations = try state.allocator.dupe(u16, state.iteration_count);
    defer state.allocator.free(candidate_iterations);
    const candidate_vapor_balance = try state.allocator.dupe(VaporBalance, state.vapor_balance);
    defer state.allocator.free(candidate_vapor_balance);
    // Seeded to the entry pool; only overwritten below in the rare
    // genuinely-supersaturated branch, so the common path pays no extra
    // allocation-time cost beyond this one dupe.
    const candidate_condensate_pool = try state.allocator.dupe(f64, state.condensate_frost_pool_m3);
    defer state.allocator.free(candidate_condensate_pool);
    const candidate_condensate_pool_heat = try state.allocator.dupe(f64, state.condensate_frost_pool_heat_megajoules);
    defer state.allocator.free(candidate_condensate_pool_heat);
    for (0..state.cell_count) |cell| {
        inline for (.{ state.temperature_k[cell], state.vapor_volume_fraction[cell], state.heat_capacity_megajoules_per_k[cell], state.air_volume_m3[cell], inputs.atmospheric_temperature_k[cell], inputs.atmospheric_vapor_volume_fraction[cell], inputs.cell_area_m2[cell], inputs.bulk_richardson_coefficient_k[cell], inputs.neutral_atmospheric_resistance_h_per_m[cell], inputs.canopy_resistance_h_per_m[cell], inputs.non_atmospheric_sensible_heat_megajoules_per_h[cell], inputs.non_atmospheric_vapor_flux_m3_per_h[cell], inputs.non_atmospheric_sensible_conductance_megajoules_per_h_k[cell], inputs.non_atmospheric_sensible_source_temperature_k[cell], inputs.non_atmospheric_vapor_conductance_m3_per_h[cell], inputs.non_atmospheric_vapor_source_fraction[cell] }) |value| if (!std.math.isFinite(value)) return error.NonFiniteGroundAirInput;
        if (state.temperature_k[cell] <= 0 or state.vapor_volume_fraction[cell] < 0 or state.heat_capacity_megajoules_per_k[cell] <= 0 or state.air_volume_m3[cell] <= 0 or inputs.atmospheric_temperature_k[cell] <= 0 or inputs.atmospheric_vapor_volume_fraction[cell] < 0 or inputs.cell_area_m2[cell] <= 0 or inputs.neutral_atmospheric_resistance_h_per_m[cell] < 0 or inputs.canopy_resistance_h_per_m[cell] < 0 or inputs.non_atmospheric_sensible_conductance_megajoules_per_h_k[cell] < 0 or inputs.non_atmospheric_sensible_source_temperature_k[cell] <= 0 or inputs.non_atmospheric_vapor_conductance_m3_per_h[cell] < 0 or inputs.non_atmospheric_vapor_source_fraction[cell] < 0) return error.InvalidGroundAirInput;
        const context: TemperatureContext = .{ .old_temperature_k = state.temperature_k[cell], .atmospheric_temperature_k = inputs.atmospheric_temperature_k[cell], .heat_capacity_megajoules_per_k = state.heat_capacity_megajoules_per_k[cell], .cell_area_m2 = inputs.cell_area_m2[cell], .bulk_richardson_coefficient_k = inputs.bulk_richardson_coefficient_k[cell], .neutral_resistance_h_per_m = inputs.neutral_atmospheric_resistance_h_per_m[cell], .canopy_resistance_h_per_m = inputs.canopy_resistance_h_per_m[cell], .source_heat_megajoules_per_h = inputs.non_atmospheric_sensible_heat_megajoules_per_h[cell], .source_conductance_megajoules_per_h_k = inputs.non_atmospheric_sensible_conductance_megajoules_per_h_k[cell], .source_temperature_k = inputs.non_atmospheric_sensible_source_temperature_k[cell], .time_step_hours = time_step_hours, .parameters = parameters };
        // The temperature residual is exactly the negative of the subsequent
        // sensible-energy closure. A nonlinear convergence band looser than
        // that independent conservation gate can therefore publish a root
        // which must immediately be rejected. Retain both configured policies,
        // but make this solve satisfy their stricter intersection.
        var options = energyConstrainedTemperatureOptions(
            solver_options,
            energy_tolerances,
            inputs.cell_area_m2[cell],
            context,
        );
        var last_iterate: numerics.SolveResult = undefined;
        options.last_iterate_on_failure = if (energy_tolerances.accept_physically_conserved_ceiling or
            energy_tolerances.accept_bounded_temperature_state)
            &last_iterate
        else
            null;
        // If the reused closure gate below ultimately rejects a recovered
        // ceiling candidate, the original error must be re-raised, not
        // `GroundAirEnergyConservationFailure` -- that name is also used by
        // the always-existing check on a normally-converged root and is
        // deliberately NOT in heat_step.zig's retryable list, so silently
        // substituting it here would turn an already-retryable ceiling
        // failure into a fatal one instead of only ever improving on it.
        var recovered_from_error: ?anyerror = null;
        const solved = numerics.newtonPicard(context, temperatureResidual, temperatureDerivative, temperaturePicard, minimum_ground_air_temperature_k, maximum_ground_air_temperature_k, context.old_temperature_k, options) catch |err| switch (err) {
            error.NewtonPicardDiverged, error.NewtonPicardStagnated, error.NewtonPicardDidNotConverge => recovery: {
                if (!energy_tolerances.accept_physically_conserved_ceiling and
                    !energy_tolerances.accept_bounded_temperature_state)
                    return err;
                recovered_from_error = err;
                break :recovery last_iterate;
            },
            else => return err,
        };
        candidate_temperature[cell] = solved.root;
        candidate_iterations[cell] = solved.iterations;
        const resistance = try atmosphereResistance(context, solved.root);
        const constitutive_atmospheric_sensible_heat_transfer_megajoules = time_step_hours *
            parameters.sensible_heat_conductivity_megajoules_per_m_h_k *
            inputs.cell_area_m2[cell] / resistance *
            (inputs.atmospheric_temperature_k[cell] - solved.root);
        const prescribed_non_atmospheric_sensible_heat_transfer_megajoules =
            time_step_hours * inputs.non_atmospheric_sensible_heat_megajoules_per_h[cell];
        const implicit_non_atmospheric_sensible_heat_transfer_megajoules = time_step_hours *
            inputs.non_atmospheric_sensible_conductance_megajoules_per_h_k[cell] *
            (inputs.non_atmospheric_sensible_source_temperature_k[cell] - solved.root);
        const sensible_heat_storage_change_megajoules =
            state.heat_capacity_megajoules_per_k[cell] * (solved.root - state.temperature_k[cell]);
        var atmospheric_sensible_heat_transfer_megajoules =
            constitutive_atmospheric_sensible_heat_transfer_megajoules;
        var temperature_bound_atmospheric_transfer_megajoules: f64 = 0;
        var sensible_heat_transfer_sum_megajoules =
            atmospheric_sensible_heat_transfer_megajoules +
            prescribed_non_atmospheric_sensible_heat_transfer_megajoules +
            implicit_non_atmospheric_sensible_heat_transfer_megajoules;
        var sensible_heat_closure_residual_megajoules =
            sensible_heat_storage_change_megajoules - sensible_heat_transfer_sum_megajoules;
        inline for (.{
            atmospheric_sensible_heat_transfer_megajoules,
            temperature_bound_atmospheric_transfer_megajoules,
            prescribed_non_atmospheric_sensible_heat_transfer_megajoules,
            implicit_non_atmospheric_sensible_heat_transfer_megajoules,
            sensible_heat_storage_change_megajoules,
            sensible_heat_transfer_sum_megajoules,
            sensible_heat_closure_residual_megajoules,
        }) |value| if (!std.math.isFinite(value)) return error.NonFiniteGroundAirEnergyResult;
        // The configured conservation policy is hourly. A recovery substep
        // owns only its duration-weighted share of stored-energy activity;
        // the transfer terms below are already integrated over this substep
        // and therefore must not be multiplied by dt a second time.
        var sensible_heat_activity_scale_megajoules = sensibleHeatStepActivity(
            time_step_hours,
            state.heat_capacity_megajoules_per_k[cell] * state.temperature_k[cell],
            state.heat_capacity_megajoules_per_k[cell] * solved.root,
            atmospheric_sensible_heat_transfer_megajoules,
            prescribed_non_atmospheric_sensible_heat_transfer_megajoules,
            implicit_non_atmospheric_sensible_heat_transfer_megajoules,
        );
        var sensible_heat_closure_tolerance_megajoules =
            energy_tolerances.absolute_megajoules_per_m2 * inputs.cell_area_m2[cell] *
            time_step_hours +
            energy_tolerances.relative * sensible_heat_activity_scale_megajoules +
            32 * std.math.floatEps(f64) * sensible_heat_activity_scale_megajoules;
        if (!std.math.isFinite(sensible_heat_closure_tolerance_megajoules))
            return error.InvalidGroundAirEnergyConservationTolerance;
        if (@abs(sensible_heat_closure_residual_megajoules) > sensible_heat_closure_tolerance_megajoules and
            recovered_from_error != null and
            energy_tolerances.accept_bounded_temperature_state)
        {
            // The nonlinear method has exhausted its bounded search. Retain
            // that best physically admissible iterate and expose the exact
            // reservoir reaction needed by the already-accepted prescribed
            // surface transfer instead of forcing a broad dt retry cascade.
            temperature_bound_atmospheric_transfer_megajoules =
                sensible_heat_closure_residual_megajoules;
            atmospheric_sensible_heat_transfer_megajoules +=
                temperature_bound_atmospheric_transfer_megajoules;
            sensible_heat_transfer_sum_megajoules =
                atmospheric_sensible_heat_transfer_megajoules +
                prescribed_non_atmospheric_sensible_heat_transfer_megajoules +
                implicit_non_atmospheric_sensible_heat_transfer_megajoules;
            sensible_heat_closure_residual_megajoules =
                sensible_heat_storage_change_megajoules -
                sensible_heat_transfer_sum_megajoules;
            sensible_heat_activity_scale_megajoules = sensibleHeatStepActivity(
                time_step_hours,
                state.heat_capacity_megajoules_per_k[cell] * state.temperature_k[cell],
                state.heat_capacity_megajoules_per_k[cell] * solved.root,
                atmospheric_sensible_heat_transfer_megajoules,
                prescribed_non_atmospheric_sensible_heat_transfer_megajoules,
                implicit_non_atmospheric_sensible_heat_transfer_megajoules,
            );
            sensible_heat_closure_tolerance_megajoules =
                energy_tolerances.absolute_megajoules_per_m2 * inputs.cell_area_m2[cell] *
                time_step_hours +
                energy_tolerances.relative * sensible_heat_activity_scale_megajoules +
                32 * std.math.floatEps(f64) * sensible_heat_activity_scale_megajoules;
            if (!std.math.isFinite(sensible_heat_closure_tolerance_megajoules))
                return error.InvalidGroundAirEnergyConservationTolerance;
        }
        if (@abs(sensible_heat_closure_residual_megajoules) > sensible_heat_closure_tolerance_megajoules) {
            if (recovered_from_error) |original_err| {
                if (!builtin.is_test) std.log.err(
                    "ground-air bounded recovery rejected: cell={d} dt_h={e} error={s} old_t_k={e} bounded_t_k={e} atmospheric_t_k={e} residual_mj={e} closure_mj={e} conservation_tolerance_mj={e} storage_mj={e} atmospheric_mj={e} prescribed_mj={e} implicit_mj={e} heat_capacity_mj_k={e} source_rate_mj_h={e} source_conductance_mj_h_k={e} source_temperature_k={e} resistance_h_m={e}",
                    .{
                        cell,
                        time_step_hours,
                        @errorName(original_err),
                        state.temperature_k[cell],
                        solved.root,
                        inputs.atmospheric_temperature_k[cell],
                        temperatureResidual(context, solved.root),
                        sensible_heat_closure_residual_megajoules,
                        sensible_heat_closure_tolerance_megajoules,
                        sensible_heat_storage_change_megajoules,
                        atmospheric_sensible_heat_transfer_megajoules,
                        prescribed_non_atmospheric_sensible_heat_transfer_megajoules,
                        implicit_non_atmospheric_sensible_heat_transfer_megajoules,
                        state.heat_capacity_megajoules_per_k[cell],
                        inputs.non_atmospheric_sensible_heat_megajoules_per_h[cell],
                        inputs.non_atmospheric_sensible_conductance_megajoules_per_h_k[cell],
                        inputs.non_atmospheric_sensible_source_temperature_k[cell],
                        resistance,
                    },
                );
                return original_err;
            }
            if (!builtin.is_test) std.log.err("ground-air sensible-energy closure failed: cell={d} dt_h={e} old_t_k={e} solved_t_k={e} iterations={d} residual_mj={e} solver_tolerance_mj={e} closure_mj={e} conservation_tolerance_mj={e} storage_mj={e} atmospheric_mj={e} prescribed_mj={e} implicit_mj={e} heat_capacity_mj_k={e} source_rate_mj_h={e} source_conductance_mj_h_k={e} source_temperature_k={e} resistance_h_m={e}", .{ cell, time_step_hours, state.temperature_k[cell], solved.root, solved.iterations, temperatureResidual(context, solved.root), numerics.convergenceTolerance(options), sensible_heat_closure_residual_megajoules, sensible_heat_closure_tolerance_megajoules, sensible_heat_storage_change_megajoules, atmospheric_sensible_heat_transfer_megajoules, prescribed_non_atmospheric_sensible_heat_transfer_megajoules, implicit_non_atmospheric_sensible_heat_transfer_megajoules, state.heat_capacity_megajoules_per_k[cell], inputs.non_atmospheric_sensible_heat_megajoules_per_h[cell], inputs.non_atmospheric_sensible_conductance_megajoules_per_h_k[cell], inputs.non_atmospheric_sensible_source_temperature_k[cell], resistance });
            return error.GroundAirEnergyConservationFailure;
        }
        const exchange_volume_m3_per_h = inputs.cell_area_m2[cell] / resistance;
        const old_vapor_m3 = state.vapor_volume_fraction[cell] * state.air_volume_m3[cell];
        const source_vapor_exchange_m3_per_h = inputs.non_atmospheric_vapor_conductance_m3_per_h[cell];
        const vapor_exchange_denominator = 1 + time_step_hours *
            (exchange_volume_m3_per_h + source_vapor_exchange_m3_per_h) / state.air_volume_m3[cell];
        const unconstrained_vapor_m3 = (old_vapor_m3 + time_step_hours * (inputs.non_atmospheric_vapor_flux_m3_per_h[cell] + exchange_volume_m3_per_h * inputs.atmospheric_vapor_volume_fraction[cell] + source_vapor_exchange_m3_per_h * inputs.non_atmospheric_vapor_source_fraction[cell])) / vapor_exchange_denominator;
        const saturation_fraction = parameters.saturation_vapor_prefactor_k / solved.root * parameters.saturation_relative_humidity * @exp(parameters.saturation_temperature_k * (parameters.saturation_reference_inverse_temperature_per_k - 1 / solved.root));
        if (!std.math.isFinite(unconstrained_vapor_m3) or
            !std.math.isFinite(vapor_exchange_denominator) or vapor_exchange_denominator <= 0 or
            !std.math.isFinite(saturation_fraction) or saturation_fraction < 0)
            return error.NonFiniteGroundAirVaporResult;
        // WATSUB advances `VPQG` as an explicit two-stage predictor/corrector,
        // and the two stages clip differently -- a distinction worth stating
        // precisely, because reading only one of them inverts the conclusion:
        //
        //   4304  VPQG2 = AMAX1(0.0, VPQG(M) + TEVGM2/EVAPQ)          <- zero floor only
        //   4305  DVPQ2 = VPAM - VPQG2
        //   4306  EVAPA = DVPQ2 * PAREX/RATG
        //   4307  TEVGM = EVAPA + TEVGM2
        //   4308  VPSG  = e_sat(TKQG(M+1))
        //   4310  VPQG(M+1) = AMAX1(0.0, AMIN1(VPSG, VPQG(M) + TEVGM/EVAPQ))
        //
        // The *predictor* `VPQG2` carries surface fluxes only and is clipped at
        // zero with NO saturation ceiling; it exists solely to evaluate the
        // atmospheric exchange `EVAPA`. The *committed* state `VPQG(M+1)` IS
        // clipped to saturation, and that committed value is what all three
        // surface lanes read the next substep (`watsub.f:1328` snow,
        // `:2860` bare soil, `:3198` litter, all of which use
        // `VPQG(M,NY,NX)`). So the saturation ceiling on the state the
        // surfaces see is oracle behaviour and is deliberately retained here;
        // removing it would introduce a divergence, not remove one.
        //
        // What was NOT faithful is which vapor fraction the constitutive
        // transfers are evaluated at. This translation previously re-evaluated
        // the atmospheric and implicit-surface exchange at the saturation-
        // clipped fraction, whereas the oracle evaluates its atmospheric
        // exchange at the unclipped predictor (4305/4306). Because the clipped
        // fraction is lower, that pulled in strictly more atmospheric vapor
        // than the source model does and therefore forced a strictly larger
        // amount back out into the condensate sink. The supersaturated branch
        // below now keeps the transfers evaluated at the solved (unclipped)
        // fraction, exactly as 4304-4306 do.
        //
        // Silently clipping without booking the excess would create/destroy
        // water and, at saturation, omit the corresponding latent heat.
        // GROUND-AIR-VAPOR-CONDENSATION-001:
        // instead, when the implicit update is genuinely supersaturated (a
        // real physical condensation/frost requirement -- no substep size
        // removes it -- rather than a numerical-stiffness artifact), the
        // excess below is deposited into `State.condensate_frost_pool_m3`
        // with the matching latent heat credited back into this same
        // substep's sensible energy, so both water and energy close
        // exactly. No temperature, vapor, or diagnostic field is committed
        // on any other failure below.
        const zero_vapor_bound_active = unconstrained_vapor_m3 < 0;
        if (zero_vapor_bound_active and
            !vapor_tolerances.accept_bounded_zero_vapor_state)
            return error.NegativeGroundAirVaporStorage;
        const provisional_vapor_m3 = if (zero_vapor_bound_active)
            0
        else
            unconstrained_vapor_m3;
        const provisional_vapor_fraction = provisional_vapor_m3 / state.air_volume_m3[cell];
        if (!std.math.isFinite(provisional_vapor_fraction))
            return error.NonFiniteGroundAirVaporResult;
        var provisional_atmospheric_transfer_m3 = time_step_hours * exchange_volume_m3_per_h *
            (inputs.atmospheric_vapor_volume_fraction[cell] - provisional_vapor_fraction);
        const provisional_implicit_surface_transfer_m3 = time_step_hours * source_vapor_exchange_m3_per_h *
            (inputs.non_atmospheric_vapor_source_fraction[cell] - provisional_vapor_fraction);
        const prescribed_transfer_m3 = time_step_hours * inputs.non_atmospheric_vapor_flux_m3_per_h[cell];
        const provisional_storage_change_m3 = provisional_vapor_m3 - old_vapor_m3;
        var zero_vapor_bound_atmospheric_transfer_m3: f64 = 0;
        if (zero_vapor_bound_active) {
            const constitutive_transfer_sum_m3 = provisional_atmospheric_transfer_m3 +
                prescribed_transfer_m3 + provisional_implicit_surface_transfer_m3;
            zero_vapor_bound_atmospheric_transfer_m3 =
                provisional_storage_change_m3 - constitutive_transfer_sum_m3;
            provisional_atmospheric_transfer_m3 +=
                zero_vapor_bound_atmospheric_transfer_m3;
        }
        const provisional_transfer_sum_m3 = provisional_atmospheric_transfer_m3 +
            prescribed_transfer_m3 + provisional_implicit_surface_transfer_m3;
        const provisional_closure_residual_m3 = provisional_storage_change_m3 - provisional_transfer_sum_m3;
        inline for (.{ provisional_atmospheric_transfer_m3, provisional_implicit_surface_transfer_m3, provisional_storage_change_m3, provisional_transfer_sum_m3, provisional_closure_residual_m3 }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteGroundAirVaporResult;
        const activity_scale_m3 = @max(
            @max(@abs(old_vapor_m3), @abs(provisional_vapor_m3)),
            @abs(provisional_atmospheric_transfer_m3) + @abs(prescribed_transfer_m3) +
                @abs(provisional_implicit_surface_transfer_m3),
        );
        var closure_tolerance_m3 = vapor_tolerances.absolute_water_depth_m *
            inputs.cell_area_m2[cell] + vapor_tolerances.relative * activity_scale_m3 +
            32 * std.math.floatEps(f64) * activity_scale_m3;
        if (!std.math.isFinite(closure_tolerance_m3))
            return error.InvalidGroundAirVaporConservationTolerance;
        const excess = try saturationExcess(
            provisional_vapor_m3,
            saturation_fraction,
            state.air_volume_m3[cell],
            inputs.cell_area_m2[cell],
            activity_scale_m3,
            vapor_tolerances,
        );

        var accepted_vapor_fraction = provisional_vapor_fraction;
        // Constitutive: evaluated once at the solved (unclipped) vapor
        // fraction and never re-evaluated at the saturation-clipped commit,
        // matching WATSUB 4304-4306. See the supersaturated branch below.
        const atmospheric_transfer_m3 = provisional_atmospheric_transfer_m3;
        const implicit_surface_transfer_m3 = provisional_implicit_surface_transfer_m3;
        var storage_change_m3 = provisional_storage_change_m3;
        var closure_residual_m3 = provisional_closure_residual_m3;
        var condensate_deposition_m3: f64 = 0;
        var condensation_latent_heat_megajoules: f64 = 0;

        if (excess.supersaturation_m3 > excess.tolerance_m3) {
            // Genuinely supersaturated: commit the boundary-air vapor fraction
            // at saturation (WATSUB 4310's `AMIN1(VPSG,...)`), but keep the
            // atmospheric and implicit-surface exchanges evaluated at the
            // solved, unclipped fraction, exactly as WATSUB 4304-4306 evaluate
            // `EVAPA` from the unclipped predictor `VPQG2`. `provisional_*`
            // already hold those values, so this branch deliberately does not
            // re-evaluate them.
            //
            // With the transfers left at the solved fraction, the amount that
            // must leave as condensate/frost is exactly the raw
            // supersaturation, and the local balance stays exact by
            // construction: the provisional solution already satisfies
            //   provisional_storage - old = atm + prescribed + implicit,
            // and subtracting the raw excess from both the storage change and
            // the transfer sum preserves that identity term for term. The
            // previous formulation instead re-evaluated the transfers at the
            // clipped fraction and had to scale the excess by
            // `vapor_exchange_denominator` (> 1) to close, which both departed
            // from the oracle and inflated this sink.
            accepted_vapor_fraction = saturation_fraction;
            condensate_deposition_m3 = excess.supersaturation_m3;
            storage_change_m3 = excess.saturation_storage_m3 - old_vapor_m3;
            const clipped_transfer_sum_m3 = atmospheric_transfer_m3 + prescribed_transfer_m3 +
                implicit_surface_transfer_m3 - condensate_deposition_m3;
            closure_residual_m3 = storage_change_m3 - clipped_transfer_sum_m3;
            inline for (.{ atmospheric_transfer_m3, implicit_surface_transfer_m3, condensate_deposition_m3, storage_change_m3, closure_residual_m3 }) |value|
                if (!std.math.isFinite(value)) return error.NonFiniteGroundAirVaporResult;
            if (condensate_deposition_m3 <= 0) return error.NonFiniteGroundAirVaporResult;
            // The condensate sink can be materially larger than the
            // pre-clip activity scale above (the clip pulls in more inflow
            // than the unconstrained solution did); re-scale the closure
            // tolerance to the same absolute+relative+roundoff formula
            // evaluated over the actually-relevant magnitude, rather than
            // comparing this branch's larger residual against a tolerance
            // sized for the smaller unclipped case.
            const clipped_activity_scale_m3 = @max(activity_scale_m3, condensate_deposition_m3);
            closure_tolerance_m3 = vapor_tolerances.absolute_water_depth_m *
                inputs.cell_area_m2[cell] + vapor_tolerances.relative * clipped_activity_scale_m3 +
                32 * std.math.floatEps(f64) * clipped_activity_scale_m3;
            if (!std.math.isFinite(closure_tolerance_m3))
                return error.InvalidGroundAirVaporConservationTolerance;

            // WATSUB carries no separate latent-heat term through this clip
            // (see the file-header comment above); crediting it here is
            // this translation's conservation-rigor improvement over that
            // approximation. Below the just-solved boundary-air temperature
            // the phase change is frost (sublimation); at or above it is dew
            // (vaporization). This heat is booked into
            // `condensate_frost_pool_heat_megajoules` below, deliberately
            // *not* into this control volume's own temperature -- see
            // `VaporBalance.condensate_deposition_latent_heat_megajoules`'s
            // doc comment for why (this thin air column's heat capacity is
            // too small to absorb it without destabilizing solvers
            // downstream that consume this state's temperature as a
            // same-hour boundary condition).
            const latent_heat_per_m3 = if (solved.root >= parameters.pure_water_freezing_temperature_k)
                parameters.liquid_water_latent_heat_megajoules_per_m3
            else
                parameters.sublimation_latent_heat_megajoules_per_m3;
            condensation_latent_heat_megajoules = condensate_deposition_m3 * latent_heat_per_m3;
            if (!std.math.isFinite(condensation_latent_heat_megajoules) or condensation_latent_heat_megajoules < 0)
                return error.NonFiniteGroundAirEnergyResult;
            candidate_condensate_pool[cell] = state.condensate_frost_pool_m3[cell] + condensate_deposition_m3;
            candidate_condensate_pool_heat[cell] = state.condensate_frost_pool_heat_megajoules[cell] +
                condensation_latent_heat_megajoules;
            if (!std.math.isFinite(candidate_condensate_pool[cell]) or candidate_condensate_pool[cell] < 0 or
                !std.math.isFinite(candidate_condensate_pool_heat[cell]) or candidate_condensate_pool_heat[cell] < 0)
                return error.NonFiniteGroundAirVaporResult;
        }

        if (@abs(closure_residual_m3) > closure_tolerance_m3) {
            // Same reasoning as the sensible-heat closure check above:
            // preserve the original retryable error on a recovered ceiling
            // candidate rather than substituting a name that is not in
            // heat_step.zig's retryable list.
            if (recovered_from_error) |original_err| return original_err;
            return error.GroundAirVaporConservationFailure;
        }

        candidate_vapor[cell] = accepted_vapor_fraction;
        candidate_vapor_balance[cell] = .{
            .storage_change_m3 = storage_change_m3,
            .atmospheric_transfer_m3 = atmospheric_transfer_m3,
            .zero_vapor_bound_atmospheric_transfer_m3 = zero_vapor_bound_atmospheric_transfer_m3,
            .prescribed_non_atmospheric_transfer_m3 = prescribed_transfer_m3,
            .implicit_surface_transfer_m3 = implicit_surface_transfer_m3,
            .condensate_deposition_m3 = condensate_deposition_m3,
            .condensate_deposition_latent_heat_megajoules = condensation_latent_heat_megajoules,
            .closure_residual_m3 = closure_residual_m3,
            .sensible_heat_storage_change_megajoules = sensible_heat_storage_change_megajoules,
            .atmospheric_sensible_heat_transfer_megajoules = atmospheric_sensible_heat_transfer_megajoules,
            .temperature_bound_atmospheric_transfer_megajoules = temperature_bound_atmospheric_transfer_megajoules,
            .prescribed_non_atmospheric_sensible_heat_transfer_megajoules = prescribed_non_atmospheric_sensible_heat_transfer_megajoules,
            .implicit_non_atmospheric_sensible_heat_transfer_megajoules = implicit_non_atmospheric_sensible_heat_transfer_megajoules,
            .sensible_heat_closure_residual_megajoules = sensible_heat_closure_residual_megajoules,
        };
    }
    @memcpy(state.temperature_k, candidate_temperature);
    @memcpy(state.vapor_volume_fraction, candidate_vapor);
    @memcpy(state.iteration_count, candidate_iterations);
    @memcpy(state.vapor_balance, candidate_vapor_balance);
    @memcpy(state.condensate_frost_pool_m3, candidate_condensate_pool);
    @memcpy(state.condensate_frost_pool_heat_megajoules, candidate_condensate_pool_heat);
}

/// A saturation comparison is an admissibility check, not a second
/// conservation solve. Apply the same extensive, cell-scaled absolute plus
/// relative acceptance policy as the vapor control volume. This admits only
/// representational overshoot (for example, saturated entry followed by a
/// one-ULP temperature decrease) and retains the exact candidate storage.
/// Clipping even that tiny excess would create an unpaired water/latent-heat
/// transfer. Material excess still fails atomically so the retry owner can
/// reduce dt.
const SaturationExcess = struct {
    saturation_storage_m3: f64,
    supersaturation_m3: f64,
    tolerance_m3: f64,
};

/// Pure arithmetic shared by `validateSaturationAdmissibility` (which is
/// fatal on material excess, kept for direct-call regression coverage) and
/// `solve`'s GROUND-AIR-VAPOR-CONDENSATION-001 condensate/frost path (which
/// instead deposits material excess into `State.condensate_frost_pool_m3`).
/// Keeping one shared implementation prevents the two call sites' tolerance
/// arithmetic from silently drifting apart.
fn saturationExcess(
    candidate_vapor_m3: f64,
    saturation_fraction: f64,
    air_volume_m3: f64,
    cell_area_m2: f64,
    activity_scale_m3: f64,
    tolerances: VaporConservationTolerances,
) !SaturationExcess {
    const saturation_storage_m3 = saturation_fraction * air_volume_m3;
    const saturation_activity_scale_m3 = @max(activity_scale_m3, @abs(saturation_storage_m3));
    const tolerance_m3 = tolerances.absolute_water_depth_m * cell_area_m2 +
        tolerances.relative * saturation_activity_scale_m3 +
        32 * std.math.floatEps(f64) * saturation_activity_scale_m3;
    const supersaturation_m3 = candidate_vapor_m3 - saturation_storage_m3;
    if (!std.math.isFinite(saturation_storage_m3) or
        !std.math.isFinite(tolerance_m3) or
        !std.math.isFinite(supersaturation_m3))
        return error.NonFiniteGroundAirVaporResult;
    return .{ .saturation_storage_m3 = saturation_storage_m3, .supersaturation_m3 = supersaturation_m3, .tolerance_m3 = tolerance_m3 };
}

fn validateSaturationAdmissibility(
    candidate_vapor_m3: f64,
    saturation_fraction: f64,
    air_volume_m3: f64,
    cell_area_m2: f64,
    activity_scale_m3: f64,
    tolerances: VaporConservationTolerances,
) !void {
    const excess = try saturationExcess(candidate_vapor_m3, saturation_fraction, air_volume_m3, cell_area_m2, activity_scale_m3, tolerances);
    if (excess.supersaturation_m3 > excess.tolerance_m3) {
        if (!builtin.is_test) std.log.err("ground-air vapor supersaturation: candidate_m3={e} saturation_m3={e} excess_m3={e} tolerance_m3={e} air_volume_m3={e} cell_area_m2={e}", .{ candidate_vapor_m3, excess.saturation_storage_m3, excess.supersaturation_m3, excess.tolerance_m3, air_volume_m3, cell_area_m2 });
        return error.SupersaturatedGroundAirVaporStorage;
    }
}

fn atmosphereResistance(context: TemperatureContext, temperature_k: f64) !f64 {
    const p = context.parameters;
    const richardson = std.math.clamp(context.bulk_richardson_coefficient_k / context.atmospheric_temperature_k * (context.atmospheric_temperature_k - temperature_k), p.minimum_richardson_number, p.maximum_richardson_number);
    const stability = 1 - p.richardson_resistance_multiplier * richardson;
    if (stability <= 0) return error.InvalidGroundAirStability;
    return @min(p.maximum_aerodynamic_resistance_h_per_m, @max(p.minimum_aerodynamic_resistance_h_per_m, context.neutral_resistance_h_per_m + context.canopy_resistance_h_per_m) / stability);
}

/// WATSUB RAB (lines 816-824): stability-adjust the above-canopy isothermal
/// resistance only. Unlike RATG, this deliberately excludes the below-canopy
/// resistance; REDIST uses RAB for canopy gas closeout.
pub fn atmosphericBoundaryResistance(
    atmospheric_temperature_k: f64,
    ground_air_temperature_k: f64,
    bulk_richardson_coefficient_k: f64,
    neutral_resistance_h_per_m: f64,
    parameters: Parameters,
) !f64 {
    inline for (.{ atmospheric_temperature_k, ground_air_temperature_k, bulk_richardson_coefficient_k, neutral_resistance_h_per_m }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteGroundAirInput;
    try validateParameters(parameters);
    if (atmospheric_temperature_k <= 0 or ground_air_temperature_k <= 0 or
        bulk_richardson_coefficient_k < 0 or neutral_resistance_h_per_m < 0)
        return error.InvalidGroundAirInput;
    const richardson = std.math.clamp(
        bulk_richardson_coefficient_k / atmospheric_temperature_k *
            (atmospheric_temperature_k - ground_air_temperature_k),
        parameters.minimum_richardson_number,
        parameters.maximum_richardson_number,
    );
    const stability = 1 - parameters.richardson_resistance_multiplier * richardson;
    if (!std.math.isFinite(stability) or stability <= 0)
        return error.InvalidGroundAirStability;
    const result = @min(
        parameters.maximum_aerodynamic_resistance_h_per_m,
        @max(parameters.minimum_aerodynamic_resistance_h_per_m, neutral_resistance_h_per_m) / stability,
    );
    if (!std.math.isFinite(result) or result < 0)
        return error.NonFiniteGroundAirResistance;
    return result;
}

fn temperatureResidual(context: TemperatureContext, temperature_k: f64) f64 {
    const resistance = atmosphereResistance(context, temperature_k) catch return std.math.nan(f64);
    const atmospheric_heat = context.parameters.sensible_heat_conductivity_megajoules_per_m_h_k * context.cell_area_m2 / resistance * (context.atmospheric_temperature_k - temperature_k);
    const source_heat = context.source_heat_megajoules_per_h + context.source_conductance_megajoules_per_h_k * (context.source_temperature_k - temperature_k);
    return context.time_step_hours * (source_heat + atmospheric_heat) + context.heat_capacity_megajoules_per_k * (context.old_temperature_k - temperature_k);
}

/// Representative magnitude of the temperature residual, in MJ.  The stored
/// energy term uses the largest absolute temperature participating in this
/// control-volume balance; the prescribed source contributes its extensive
/// energy over the accepted substep.  Keeping every term in MJ makes the
/// nonlinear relative tolerance extensive without coupling it to the separate
/// vapor-conservation tolerance.
fn temperatureResidualEnergyScale(context: TemperatureContext) f64 {
    const representative_temperature_k = @max(
        @abs(context.old_temperature_k),
        @max(@abs(context.atmospheric_temperature_k), @abs(context.source_temperature_k)),
    );
    return context.heat_capacity_megajoules_per_k * representative_temperature_k +
        @abs(context.source_heat_megajoules_per_h) * context.time_step_hours;
}

fn sensibleHeatStepActivity(
    time_step_hours: f64,
    old_sensible_heat_megajoules: f64,
    new_sensible_heat_megajoules: f64,
    atmospheric_transfer_megajoules: f64,
    prescribed_transfer_megajoules: f64,
    implicit_transfer_megajoules: f64,
) f64 {
    return @max(
        time_step_hours * @max(
            @abs(old_sensible_heat_megajoules),
            @abs(new_sensible_heat_megajoules),
        ),
        @abs(atmospheric_transfer_megajoules) +
            @abs(prescribed_transfer_megajoules) +
            @abs(implicit_transfer_megajoules),
    );
}

test "ground air step activity does not double scale integrated transfers" {
    try std.testing.expectEqual(
        @as(f64, 30),
        sensibleHeatStepActivity(0.25, 100, 96, -10, 12, -8),
    );
    try std.testing.expectEqual(
        @as(f64, 25),
        sensibleHeatStepActivity(0.25, 100, 96, -1, 2, -3),
    );
}

fn temperatureDerivative(context: TemperatureContext, temperature_k: f64) f64 {
    const step = @max(1e-6, @abs(temperature_k) * 1e-6);
    return (temperatureResidual(context, temperature_k + step) - temperatureResidual(context, temperature_k - step)) / (2 * step);
}

fn temperaturePicard(context: TemperatureContext, temperature_k: f64) f64 {
    const resistance = atmosphereResistance(context, temperature_k) catch return context.old_temperature_k;
    const conductance = context.parameters.sensible_heat_conductivity_megajoules_per_m_h_k * context.cell_area_m2 / resistance;
    return (context.time_step_hours * (context.source_heat_megajoules_per_h + context.source_conductance_megajoules_per_h_k * context.source_temperature_k + conductance * context.atmospheric_temperature_k) + context.heat_capacity_megajoules_per_k * context.old_temperature_k) / (context.time_step_hours * (context.source_conductance_megajoules_per_h_k + conductance) + context.heat_capacity_megajoules_per_k);
}

fn validateParameters(p: Parameters) !void {
    inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(p, field.name))) return error.NonFiniteGroundAirParameter;
    if (p.maximum_richardson_number < p.minimum_richardson_number or p.richardson_resistance_multiplier <= 0 or p.minimum_aerodynamic_resistance_h_per_m <= 0 or p.maximum_aerodynamic_resistance_h_per_m < p.minimum_aerodynamic_resistance_h_per_m or p.volumetric_air_heat_capacity_megajoules_per_m3_k <= 0 or p.minimum_air_column_height_m <= 0 or p.sensible_heat_conductivity_megajoules_per_m_h_k <= 0 or p.liquid_water_latent_heat_megajoules_per_m3 <= 0 or p.saturation_vapor_prefactor_k <= 0 or p.saturation_relative_humidity < 0 or p.saturation_relative_humidity > 1 or p.saturation_temperature_k <= 0 or p.saturation_reference_inverse_temperature_per_k <= 0 or p.sublimation_latent_heat_megajoules_per_m3 <= p.liquid_water_latent_heat_megajoules_per_m3 or p.pure_water_freezing_temperature_k <= 0) return error.InvalidGroundAirParameter;
}

test "finite surface sensible pairs eliminate split air oscillation and conserve energy" {
    const parameters = testParameters();
    const capacities = [_]f64{ 0.022619632479703493, 0.001, 0.003 };
    const conductances = [_]f64{ 0.2706515913658948, 0.1, 0.2 };
    for ([_]f64{ 0.05, 0.25, 1 }) |dt| {
        var surface_temperatures = [_]f64{ 274.3258819301585, 272, 270 };
        var state = try State.init(std.testing.allocator, &.{236.27514888581368}, &.{0}, &.{1}, 5, parameters);
        defer state.deinit();
        for (0..24) |_| {
            var effective: [3]f64 = undefined;
            var total_conductance: f64 = 0;
            var weighted_temperature: f64 = 0;
            var initial_energy = state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0];
            var minimum_temperature = @min(250, state.temperature_k[0]);
            var maximum_temperature = @max(250, state.temperature_k[0]);
            for (capacities, conductances, surface_temperatures, &effective) |capacity, conductance, temperature, *value| {
                value.* = try finiteSurfaceSensibleConductance(conductance, capacity, dt);
                total_conductance += value.*;
                weighted_temperature += value.* * temperature;
                initial_energy += capacity * temperature;
                minimum_temperature = @min(minimum_temperature, temperature);
                maximum_temperature = @max(maximum_temperature, temperature);
            }
            const source_temperature = weighted_temperature / total_conductance;
            try solve(&state, .{
                .atmospheric_temperature_k = &.{250},
                .atmospheric_vapor_volume_fraction = &.{0},
                .cell_area_m2 = &.{1},
                .bulk_richardson_coefficient_k = &.{0},
                .neutral_atmospheric_resistance_h_per_m = &.{0.0139},
                .canopy_resistance_h_per_m = &.{0},
                .non_atmospheric_sensible_heat_megajoules_per_h = &.{0},
                .non_atmospheric_vapor_flux_m3_per_h = &.{0},
                .non_atmospheric_sensible_conductance_megajoules_per_h_k = &.{total_conductance},
                .non_atmospheric_sensible_source_temperature_k = &.{source_temperature},
                .non_atmospheric_vapor_conductance_m3_per_h = &.{0},
                .non_atmospheric_vapor_source_fraction = &.{0},
            }, parameters, .{ .max_iterations = 20, .residual_scale = 1 }, .{ .absolute_water_depth_m = 0, .relative = 1e-9 }, .{ .absolute_megajoules_per_m2 = 0, .relative = 1e-9 }, dt);
            var final_energy = state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0];
            var paired_heat: f64 = 0;
            for (capacities, effective, &surface_temperatures) |capacity, conductance, *temperature| {
                const heat = try pairedSurfaceSensibleHeat(conductance, temperature.*, state.temperature_k[0], dt);
                temperature.* += heat / capacity;
                paired_heat += heat;
                final_energy += capacity * temperature.*;
                try std.testing.expect(temperature.* >= minimum_temperature - 1e-12);
                try std.testing.expect(temperature.* <= maximum_temperature + 1e-12);
            }
            try std.testing.expect(state.temperature_k[0] >= minimum_temperature - 1e-12);
            try std.testing.expect(state.temperature_k[0] <= maximum_temperature + 1e-12);
            const balance = state.vapor_balance[0];
            try std.testing.expectApproxEqAbs(@as(f64, 0), paired_heat + balance.implicit_non_atmospheric_sensible_heat_transfer_megajoules, 1e-12);
            // The air solve has already independently enforced its configured
            // physical energy gate. The coupled census must add only that
            // admitted residual, with no extra inter-owner energy defect.
            try std.testing.expectApproxEqAbs(balance.atmospheric_sensible_heat_transfer_megajoules + balance.sensible_heat_closure_residual_megajoules, final_energy - initial_energy, 64 * std.math.floatEps(f64) * (@abs(initial_energy) + @abs(final_energy)));
            try std.testing.expectEqual(@as(f64, 0), balance.temperature_bound_atmospheric_transfer_megajoules);
        }
    }
    // The omitted coupled feedback is material even before either solver
    // hits its broad safety bound. With the observed air/soil temperatures,
    // the old explicit heat pushes air above BOTH initial owners.
    const dt: f64 = 0.05;
    const air_capacity: f64 = 0.00625;
    const air_old: f64 = 236.27514888581368;
    const soil_old: f64 = 274.3258819301585;
    const atmospheric_conductance = parameters.sensible_heat_conductivity_megajoules_per_m_h_k / 0.0139;
    const old_heat = @min(dt * conductances[0], capacities[0]) * (soil_old - air_old);
    const split_air = (air_capacity * air_old + old_heat + dt * atmospheric_conductance * 250) /
        (air_capacity + dt * atmospheric_conductance);
    try std.testing.expect(split_air > soil_old);
    try std.testing.expectEqual(@as(f64, 0), try finiteSurfaceSensibleConductance(1, 0, 1));
    try std.testing.expectError(error.InvalidSurfaceSensiblePair, finiteSurfaceSensibleConductance(1, -1, 1));
}

fn testParameters() Parameters {
    return .{ .minimum_richardson_number = -0.1, .maximum_richardson_number = 0.05, .richardson_resistance_multiplier = 10, .minimum_aerodynamic_resistance_h_per_m = 0.00139, .maximum_aerodynamic_resistance_h_per_m = 0.0139, .volumetric_air_heat_capacity_megajoules_per_m3_k = 1.25e-3, .minimum_air_column_height_m = 5, .sensible_heat_conductivity_megajoules_per_m_h_k = 1.2e-3, .liquid_water_latent_heat_megajoules_per_m3 = 2465, .saturation_vapor_prefactor_k = 2.173e-3, .saturation_relative_humidity = 0.61, .saturation_temperature_k = 5360, .saturation_reference_inverse_temperature_per_k = 3.661e-3, .sublimation_latent_heat_megajoules_per_m3 = 2834, .pure_water_freezing_temperature_k = 273.15 };
}

const test_solver_options: numerics.SolverOptions = .{
    .absolute_tolerance = 1e-10,
    .relative_tolerance = 1e-8,
    .max_iterations = 20,
    .picard_relaxation = 0.5,
    .residual_scale = 1,
};

const test_vapor_tolerances: VaporConservationTolerances = .{
    .absolute_water_depth_m = 1e-14,
    .relative = 1e-9,
};

const test_energy_tolerances: EnergyConservationTolerances = .{
    .absolute_megajoules_per_m2 = 2e-8,
    .relative = 1e-9,
};

test "saturated entry one-ULP cooling is admissible without clipping storage" {
    const parameters = testParameters();
    const entry_temperature_k: f64 = 280;
    const cooled_temperature_k = std.math.nextAfter(f64, entry_temperature_k, -std.math.inf(f64));
    const air_volume_m3: f64 = 50;
    const cell_area_m2: f64 = 10;
    const entry_saturation_fraction = parameters.saturation_vapor_prefactor_k / entry_temperature_k *
        parameters.saturation_relative_humidity *
        @exp(parameters.saturation_temperature_k *
            (parameters.saturation_reference_inverse_temperature_per_k - 1 / entry_temperature_k));
    const cooled_saturation_fraction = parameters.saturation_vapor_prefactor_k / cooled_temperature_k *
        parameters.saturation_relative_humidity *
        @exp(parameters.saturation_temperature_k *
            (parameters.saturation_reference_inverse_temperature_per_k - 1 / cooled_temperature_k));
    const carried_storage_m3 = entry_saturation_fraction * air_volume_m3;
    const cooled_saturation_storage_m3 = cooled_saturation_fraction * air_volume_m3;
    try std.testing.expect(carried_storage_m3 > cooled_saturation_storage_m3);

    try validateSaturationAdmissibility(
        carried_storage_m3,
        cooled_saturation_fraction,
        air_volume_m3,
        cell_area_m2,
        carried_storage_m3,
        test_vapor_tolerances,
    );
    // Admissibility is validation only: no cap rewrites the conserved amount.
    try std.testing.expectEqual(entry_saturation_fraction * air_volume_m3, carried_storage_m3);
}

test "refresh geometry preserves reference intensive state and accounts capacity change" {
    const parameters = testParameters();
    var state = try State.init(std.testing.allocator, &.{280}, &.{5.0e-6}, &.{10}, 5, parameters);
    defer state.deinit();

    const temperature_before = state.temperature_k[0];
    const vapor_fraction_before = state.vapor_volume_fraction[0];
    const volume_before = state.air_volume_m3[0];
    const capacity_before = state.heat_capacity_megajoules_per_k[0];
    const vapor_storage_before = vapor_fraction_before * volume_before;
    const sensible_storage_before = capacity_before * temperature_before;

    var geometry_balance: [1]GeometryBalance = undefined;
    try state.refreshGeometry(&.{20}, &.{6}, parameters, &geometry_balance);

    try std.testing.expectEqual(temperature_before, state.temperature_k[0]);
    try std.testing.expectEqual(vapor_fraction_before, state.vapor_volume_fraction[0]);
    try std.testing.expectEqual(@as(f64, 120), state.air_volume_m3[0]);
    try std.testing.expectEqual(
        state.air_volume_m3[0] * parameters.volumetric_air_heat_capacity_megajoules_per_m3_k,
        state.heat_capacity_megajoules_per_k[0],
    );
    const volume_change = state.air_volume_m3[0] - volume_before;
    const expected_vapor_change = vapor_fraction_before * volume_change;
    const actual_vapor_change = state.vapor_volume_fraction[0] * state.air_volume_m3[0] - vapor_storage_before;
    try std.testing.expectApproxEqAbs(
        expected_vapor_change,
        actual_vapor_change,
        32 * std.math.floatEps(f64) * @max(@abs(expected_vapor_change), @abs(actual_vapor_change)),
    );
    try std.testing.expectEqual(vapor_storage_before, geometry_balance[0].initial_vapor_storage_m3);
    try std.testing.expectEqual(actual_vapor_change, geometry_balance[0].vapor_storage_change_m3);
    try std.testing.expectEqual(actual_vapor_change, geometry_balance[0].atmospheric_vapor_transfer_m3);
    const expected_sensible_change = parameters.volumetric_air_heat_capacity_megajoules_per_m3_k * temperature_before * volume_change;
    const actual_sensible_change = state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0] - sensible_storage_before;
    try std.testing.expectApproxEqAbs(
        expected_sensible_change,
        actual_sensible_change,
        32 * std.math.floatEps(f64) * @max(@abs(expected_sensible_change), @abs(actual_sensible_change)),
    );
    try std.testing.expectEqual(sensible_storage_before, geometry_balance[0].initial_sensible_heat_megajoules);
    try std.testing.expectEqual(actual_sensible_change, geometry_balance[0].sensible_heat_storage_change_megajoules);
    try std.testing.expectEqual(actual_sensible_change, geometry_balance[0].atmospheric_sensible_heat_transfer_megajoules);

    const expanded_vapor_storage_m3 = state.vapor_volume_fraction[0] * state.air_volume_m3[0];
    const expanded_sensible_heat_megajoules = state.temperature_k[0] * state.heat_capacity_megajoules_per_k[0];
    var contraction_balance: [1]GeometryBalance = undefined;
    try state.refreshGeometry(&.{10}, &.{5}, parameters, &contraction_balance);
    try std.testing.expect(contraction_balance[0].vapor_storage_change_m3 < 0);
    try std.testing.expect(contraction_balance[0].sensible_heat_storage_change_megajoules < 0);
    try std.testing.expectEqual(
        state.vapor_volume_fraction[0] * state.air_volume_m3[0] - expanded_vapor_storage_m3,
        contraction_balance[0].vapor_storage_change_m3,
    );
    try std.testing.expectEqual(
        state.temperature_k[0] * state.heat_capacity_megajoules_per_k[0] - expanded_sensible_heat_megajoules,
        contraction_balance[0].sensible_heat_storage_change_megajoules,
    );
}

test "zero VPQGX geometry refresh entrains heat without creating water" {
    const parameters = testParameters();
    var state = try State.init(std.testing.allocator, &.{280}, &.{0}, &.{10}, 5, parameters);
    defer state.deinit();
    var geometry_balance: [1]GeometryBalance = undefined;

    try state.refreshGeometry(&.{20}, &.{6}, parameters, &geometry_balance);
    try std.testing.expectEqual(@as(f64, 0), geometry_balance[0].initial_vapor_storage_m3);
    try std.testing.expectEqual(@as(f64, 0), geometry_balance[0].vapor_storage_change_m3);
    try std.testing.expectEqual(@as(f64, 0), geometry_balance[0].atmospheric_vapor_transfer_m3);
    try std.testing.expect(geometry_balance[0].sensible_heat_storage_change_megajoules > 0);
    try std.testing.expectEqual(
        geometry_balance[0].sensible_heat_storage_change_megajoules,
        geometry_balance[0].atmospheric_sensible_heat_transfer_megajoules,
    );
}

test "refresh geometry is transactional across cells" {
    const parameters = testParameters();
    var state = try State.init(std.testing.allocator, &.{ 280, 281 }, &.{ 5.0e-6, 6.0e-6 }, &.{ 10, 11 }, 5, parameters);
    defer state.deinit();
    const volume_before = [2]f64{ state.air_volume_m3[0], state.air_volume_m3[1] };
    const capacity_before = [2]f64{ state.heat_capacity_megajoules_per_k[0], state.heat_capacity_megajoules_per_k[1] };
    var geometry_balance = [_]GeometryBalance{
        .{ .initial_vapor_storage_m3 = 17 },
        .{ .initial_vapor_storage_m3 = 19 },
    };
    const balance_before = geometry_balance;

    try std.testing.expectError(
        error.InvalidGroundAirGeometry,
        state.refreshGeometry(&.{ 20, 21 }, &.{ 6, std.math.nan(f64) }, parameters, &geometry_balance),
    );
    try std.testing.expectEqualSlices(f64, &volume_before, state.air_volume_m3);
    try std.testing.expectEqualSlices(f64, &capacity_before, state.heat_capacity_megajoules_per_k);
    try std.testing.expectEqualDeep(balance_before, geometry_balance);
}

test "ground air temperature residual scale is extensive energy" {
    const context: TemperatureContext = .{
        .old_temperature_k = 280,
        .atmospheric_temperature_k = 285,
        .heat_capacity_megajoules_per_k = 2,
        .cell_area_m2 = 10,
        .bulk_richardson_coefficient_k = 20,
        .neutral_resistance_h_per_m = 0.005,
        .canopy_resistance_h_per_m = 0.002,
        .source_heat_megajoules_per_h = -3,
        .source_conductance_megajoules_per_h_k = 0.01,
        .source_temperature_k = 290,
        .time_step_hours = 0.5,
        .parameters = testParameters(),
    };
    const scale_megajoules = temperatureResidualEnergyScale(context);
    try std.testing.expectEqual(@as(f64, 581.5), scale_megajoules);

    var ten_times_extensive = context;
    ten_times_extensive.heat_capacity_megajoules_per_k *= 10;
    ten_times_extensive.source_heat_megajoules_per_h *= 10;
    try std.testing.expectApproxEqRel(
        10 * scale_megajoules,
        temperatureResidualEnergyScale(ten_times_extensive),
        1e-15,
    );
}

test "ground air converges without repeating the full model" {
    const parameters: Parameters = .{ .minimum_richardson_number = -0.1, .maximum_richardson_number = 0.05, .richardson_resistance_multiplier = 10, .minimum_aerodynamic_resistance_h_per_m = 0.00139, .maximum_aerodynamic_resistance_h_per_m = 0.0139, .volumetric_air_heat_capacity_megajoules_per_m3_k = 1.25e-3, .minimum_air_column_height_m = 5, .sensible_heat_conductivity_megajoules_per_m_h_k = 1.2e-3, .liquid_water_latent_heat_megajoules_per_m3 = 2465, .saturation_vapor_prefactor_k = 2.173e-3, .saturation_relative_humidity = 0.61, .saturation_temperature_k = 5360, .saturation_reference_inverse_temperature_per_k = 3.661e-3, .sublimation_latent_heat_megajoules_per_m3 = 2834, .pure_water_freezing_temperature_k = 273.15 };
    var state = try State.init(std.testing.allocator, &.{280}, &.{5.0e-6}, &.{10}, 5, parameters);
    defer state.deinit();
    try solve(&state, .{ .atmospheric_temperature_k = &.{285}, .atmospheric_vapor_volume_fraction = &.{4.0e-6}, .cell_area_m2 = &.{10}, .bulk_richardson_coefficient_k = &.{20}, .neutral_atmospheric_resistance_h_per_m = &.{0.005}, .canopy_resistance_h_per_m = &.{0.002}, .non_atmospheric_sensible_heat_megajoules_per_h = &.{0.1}, .non_atmospheric_vapor_flux_m3_per_h = &.{0.001}, .non_atmospheric_sensible_conductance_megajoules_per_h_k = &.{0}, .non_atmospheric_sensible_source_temperature_k = &.{280}, .non_atmospheric_vapor_conductance_m3_per_h = &.{0}, .non_atmospheric_vapor_source_fraction = &.{0} }, parameters, .{ .absolute_tolerance = 1e-10, .relative_tolerance = 1e-8, .max_iterations = 20, .picard_relaxation = 0.5, .residual_scale = 1.0 }, .{ .absolute_water_depth_m = 1e-14, .relative = 1e-9 }, test_energy_tolerances, 1);
    try std.testing.expect(state.temperature_k[0] > 280);
    try std.testing.expect(state.iteration_count[0] < 20);
    try std.testing.expect(state.vapor_volume_fraction[0] >= 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0), state.vapor_balance[0].closure_residual_m3, 1e-15);
    try std.testing.expect(@abs(state.vapor_balance[0].sensible_heat_closure_residual_megajoules) <=
        test_energy_tolerances.absolute_megajoules_per_m2 * 10 +
            test_energy_tolerances.relative *
                state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0]);
}

fn groundAirCeilingProbeInputs() Inputs {
    return .{
        .atmospheric_temperature_k = &.{285},
        .atmospheric_vapor_volume_fraction = &.{4.0e-6},
        .cell_area_m2 = &.{10},
        .bulk_richardson_coefficient_k = &.{20},
        .neutral_atmospheric_resistance_h_per_m = &.{0.005},
        .canopy_resistance_h_per_m = &.{0.002},
        .non_atmospheric_sensible_heat_megajoules_per_h = &.{0.1},
        .non_atmospheric_vapor_flux_m3_per_h = &.{0.001},
        .non_atmospheric_sensible_conductance_megajoules_per_h_k = &.{0},
        .non_atmospheric_sensible_source_temperature_k = &.{280},
        .non_atmospheric_vapor_conductance_m3_per_h = &.{0},
        .non_atmospheric_vapor_source_fraction = &.{0},
    };
}

test "accept_physically_conserved_ceiling defaults to unused, unchanged ceiling failure" {
    const parameters = testParameters();
    var state = try State.init(std.testing.allocator, &.{280}, &.{5.0e-6}, &.{10}, 5, parameters);
    defer state.deinit();
    var one_step_options = test_solver_options;
    one_step_options.max_iterations = 1;
    try std.testing.expectError(
        error.NewtonPicardDidNotConverge,
        solve(&state, groundAirCeilingProbeInputs(), parameters, one_step_options, test_vapor_tolerances, test_energy_tolerances, 1),
    );
}

test "accept_physically_conserved_ceiling recovers a ceiling-bound iterate that already conserves energy" {
    // Same fixture and one-Newton-step ceiling as the default-off test
    // above, but opting in: the discarded iterate is handed to the exact
    // same sensible-energy closure check the converged path already uses.
    const parameters = testParameters();
    var state = try State.init(std.testing.allocator, &.{280}, &.{5.0e-6}, &.{10}, 5, parameters);
    defer state.deinit();
    var one_step_options = test_solver_options;
    one_step_options.max_iterations = 1;
    var lenient_energy_tolerances = test_energy_tolerances;
    lenient_energy_tolerances.accept_physically_conserved_ceiling = true;
    // The single Newton step from this fixture's initial guess measures
    // ~0.13 MJ of closure residual (see the companion default-off test's
    // captured warning log); this tolerance is comfortably above that, not
    // tuned to just barely pass.
    lenient_energy_tolerances.relative = 0.1;
    lenient_energy_tolerances.absolute_megajoules_per_m2 = 1.0;
    try solve(&state, groundAirCeilingProbeInputs(), parameters, one_step_options, test_vapor_tolerances, lenient_energy_tolerances, 1);
    try std.testing.expect(state.temperature_k[0] > 280);
    try std.testing.expectEqual(@as(u16, 1), state.iteration_count[0]);
    try std.testing.expect(@abs(state.vapor_balance[0].sensible_heat_closure_residual_megajoules) <=
        lenient_energy_tolerances.absolute_megajoules_per_m2 * 10 +
            lenient_energy_tolerances.relative *
                state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0]);
}

test "accept_physically_conserved_ceiling re-raises the original retryable error when recovery itself fails closure" {
    // Regression test for a real A/B finding on the production Ottawa
    // deck (2026-09-04): production-activating this flag with a tight
    // (unrecovering) energy tolerance turned a previously-retryable
    // NewtonPicardDidNotConverge at hour 1 into a fatal, non-retryable
    // GroundAirEnergyConservationFailure (that error name is deliberately
    // absent from heat_step.zig's isFixedHourDtRecoveryFailure list),
    // because a failed recovery attempt fell through to the same
    // closure-check error a normally-converged-but-non-conserving root
    // uses. Same fixture and ceiling as the two tests above, but with the
    // *tight* default tolerance the recovered ~0.13 MJ residual cannot
    // pass -- the original error must survive, not be replaced.
    const parameters = testParameters();
    var state = try State.init(std.testing.allocator, &.{280}, &.{5.0e-6}, &.{10}, 5, parameters);
    defer state.deinit();
    var one_step_options = test_solver_options;
    one_step_options.max_iterations = 1;
    var tight_energy_tolerances = test_energy_tolerances;
    tight_energy_tolerances.accept_physically_conserved_ceiling = true;
    try std.testing.expectError(
        error.NewtonPicardDidNotConverge,
        solve(&state, groundAirCeilingProbeInputs(), parameters, one_step_options, test_vapor_tolerances, tight_energy_tolerances, 1),
    );
}

fn groundAirLowerTemperatureBoundProbeInputs() Inputs {
    return .{
        .atmospheric_temperature_k = &.{248.45},
        .atmospheric_vapor_volume_fraction = &.{4.0e-6},
        .cell_area_m2 = &.{1},
        .bulk_richardson_coefficient_k = &.{0},
        .neutral_atmospheric_resistance_h_per_m = &.{4.081747775133963e-2},
        .canopy_resistance_h_per_m = &.{0},
        .non_atmospheric_sensible_heat_megajoules_per_h = &.{-1.65798363220667e1},
        .non_atmospheric_vapor_flux_m3_per_h = &.{0},
        .non_atmospheric_sensible_conductance_megajoules_per_h_k = &.{0},
        .non_atmospheric_sensible_source_temperature_k = &.{268.3811549067331},
        .non_atmospheric_vapor_conductance_m3_per_h = &.{0},
        .non_atmospheric_vapor_source_fraction = &.{0},
    };
}

test "bounded ground air temperature fallback is explicit and defaults disabled" {
    var parameters = testParameters();
    parameters.maximum_aerodynamic_resistance_h_per_m = 1;
    var state = try State.init(
        std.testing.allocator,
        &.{334.9534193321886},
        &.{5.0e-6},
        &.{1},
        5,
        parameters,
    );
    defer state.deinit();
    try std.testing.expect(!test_energy_tolerances.accept_bounded_temperature_state);
    try std.testing.expectError(
        error.NewtonPicardStagnated,
        solve(
            &state,
            groundAirLowerTemperatureBoundProbeInputs(),
            parameters,
            test_solver_options,
            test_vapor_tolerances,
            test_energy_tolerances,
            0.25,
        ),
    );
}

test "failed ground air temperature solve publishes an exact bounded balance" {
    var parameters = testParameters();
    parameters.maximum_aerodynamic_resistance_h_per_m = 1;
    var state = try State.init(
        std.testing.allocator,
        &.{334.9534193321886},
        &.{5.0e-6},
        &.{1},
        5,
        parameters,
    );
    defer state.deinit();
    var energy_tolerances = test_energy_tolerances;
    energy_tolerances.accept_bounded_temperature_state = true;
    try solve(
        &state,
        groundAirLowerTemperatureBoundProbeInputs(),
        parameters,
        test_solver_options,
        test_vapor_tolerances,
        energy_tolerances,
        0.25,
    );
    const balance = state.vapor_balance[0];
    try std.testing.expectEqual(
        minimum_ground_air_temperature_k,
        state.temperature_k[0],
    );
    try std.testing.expect(
        balance.temperature_bound_atmospheric_transfer_megajoules > 0,
    );
    try std.testing.expectApproxEqAbs(
        balance.sensible_heat_storage_change_megajoules,
        balance.atmospheric_sensible_heat_transfer_megajoules +
            balance.prescribed_non_atmospheric_sensible_heat_transfer_megajoules +
            balance.implicit_non_atmospheric_sensible_heat_transfer_megajoules,
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        balance.sensible_heat_closure_residual_megajoules,
        1.0e-12,
    );
}

test "ground air temperature solve cannot converge outside its energy conservation band" {
    const context: TemperatureContext = .{
        .old_temperature_k = 276.51896452150265,
        .atmospheric_temperature_k = 248.45,
        .heat_capacity_megajoules_per_k = 6.25e-3,
        .cell_area_m2 = 1,
        .bulk_richardson_coefficient_k = 0,
        .neutral_resistance_h_per_m = 1.5124995459459731e-2,
        .canopy_resistance_h_per_m = 0,
        .source_heat_megajoules_per_h = -2.639343640918983,
        .source_conductance_megajoules_per_h_k = 0,
        .source_temperature_k = 262.1905631877999,
        .time_step_hours = 6.25e-2,
        .parameters = .{
            .minimum_richardson_number = -0.1,
            .maximum_richardson_number = 0.05,
            .richardson_resistance_multiplier = 10,
            .minimum_aerodynamic_resistance_h_per_m = 1e-6,
            .maximum_aerodynamic_resistance_h_per_m = 1e6,
            .volumetric_air_heat_capacity_megajoules_per_m3_k = 1.25e-3,
            .minimum_air_column_height_m = 5,
            .sensible_heat_conductivity_megajoules_per_m_h_k = 1.25e-3,
            .liquid_water_latent_heat_megajoules_per_m3 = 2465,
            .saturation_vapor_prefactor_k = 2.173e-3,
            .saturation_relative_humidity = 0.61,
            .saturation_temperature_k = 5360,
            .saturation_reference_inverse_temperature_per_k = 3.661e-3,
            .sublimation_latent_heat_megajoules_per_m3 = 2834,
            .pure_water_freezing_temperature_k = 273.15,
        },
    };
    const energy_tolerances: EnergyConservationTolerances = .{
        .absolute_megajoules_per_m2 = 0,
        .relative = 1e-9,
    };
    const options = energyConstrainedTemperatureOptions(.{
        .absolute_tolerance = 1e-10,
        .relative_tolerance = 1e-8,
        .max_iterations = 100,
        .picard_relaxation = 0.5,
        .residual_scale = 1,
    }, energy_tolerances, context.cell_area_m2, context);
    try std.testing.expectEqual(@as(f64, 0), options.absolute_tolerance);
    try std.testing.expect(options.safeguard_with_bracket);
    try std.testing.expect(options.relative_tolerance > 0);
    try std.testing.expect(options.relative_tolerance <= energy_tolerances.relative);
    try std.testing.expectEqual(
        temperatureResidualEnergyScale(context),
        options.residual_scale,
    );
    try std.testing.expect(numerics.convergenceTolerance(options) < 2.0e-9);
    const solved = try numerics.newtonPicard(context, temperatureResidual, temperatureDerivative, temperaturePicard, 173.15, 373.15, context.old_temperature_k, options);
    const closure_residual_megajoules = -temperatureResidual(context, solved.root);
    const storage_scale_megajoules = @max(
        context.time_step_hours *
            @abs(context.heat_capacity_megajoules_per_k * context.old_temperature_k),
        context.time_step_hours *
            @abs(context.heat_capacity_megajoules_per_k * solved.root),
    );
    const conservation_tolerance_megajoules = energy_tolerances.relative * storage_scale_megajoules +
        32 * std.math.floatEps(f64) * storage_scale_megajoules;
    try std.testing.expect(@abs(closure_residual_megajoules) <= conservation_tolerance_megajoules);
}

test "hour ten ground air source scale is intersected with energy conservation" {
    const context: TemperatureContext = .{
        .old_temperature_k = 251.65085032107396,
        .atmospheric_temperature_k = 251.15,
        .heat_capacity_megajoules_per_k = 6.25e-3,
        .cell_area_m2 = 1,
        .bulk_richardson_coefficient_k = 0,
        .neutral_resistance_h_per_m = 5.987554628589725e-3,
        .canopy_resistance_h_per_m = 0,
        .source_heat_megajoules_per_h = 2.326430211451253,
        .source_conductance_megajoules_per_h_k = 0,
        .source_temperature_k = 254.80867428520204,
        .time_step_hours = 6.25e-2,
        .parameters = .{
            .minimum_richardson_number = -0.1,
            .maximum_richardson_number = 0.05,
            .richardson_resistance_multiplier = 10,
            .minimum_aerodynamic_resistance_h_per_m = 1e-6,
            .maximum_aerodynamic_resistance_h_per_m = 1e6,
            .volumetric_air_heat_capacity_megajoules_per_m3_k = 1.25e-3,
            .minimum_air_column_height_m = 5,
            .sensible_heat_conductivity_megajoules_per_m_h_k = 1.25e-3,
            .liquid_water_latent_heat_megajoules_per_m3 = 2465,
            .saturation_vapor_prefactor_k = 2.173e-3,
            .saturation_relative_humidity = 0.61,
            .saturation_temperature_k = 5360,
            .saturation_reference_inverse_temperature_per_k = 3.661e-3,
            .sublimation_latent_heat_megajoules_per_m3 = 2834,
            .pure_water_freezing_temperature_k = 273.15,
        },
    };
    const energy_tolerances: EnergyConservationTolerances = .{
        .absolute_megajoules_per_m2 = 0,
        .relative = 1e-9,
    };
    const entry_stored_energy_megajoules = @abs(
        context.heat_capacity_megajoules_per_k * context.old_temperature_k,
    );
    const entry_step_activity_megajoules =
        context.time_step_hours * entry_stored_energy_megajoules;
    const conservation_lower_bound_megajoules =
        energy_tolerances.relative * entry_step_activity_megajoules +
        32 * std.math.floatEps(f64) * entry_step_activity_megajoules;
    const configured: numerics.SolverOptions = .{
        .absolute_tolerance = 0,
        .relative_tolerance = 1e-8,
        .max_iterations = 100,
        .picard_relaxation = 0.5,
        .residual_scale = 1,
    };
    var unconstrained = configured;
    unconstrained.relative_tolerance = energy_tolerances.relative;
    unconstrained.residual_scale = temperatureResidualEnergyScale(context);
    try std.testing.expect(
        numerics.convergenceTolerance(unconstrained) >
            conservation_lower_bound_megajoules,
    );

    const options = energyConstrainedTemperatureOptions(
        configured,
        energy_tolerances,
        context.cell_area_m2,
        context,
    );
    try std.testing.expect(options.safeguard_with_bracket);
    try std.testing.expect(
        numerics.convergenceTolerance(options) <=
            conservation_lower_bound_megajoules,
    );
    const solved = try numerics.newtonPicard(
        context,
        temperatureResidual,
        temperatureDerivative,
        temperaturePicard,
        173.15,
        373.15,
        context.old_temperature_k,
        options,
    );
    const closure_residual_megajoules = -temperatureResidual(context, solved.root);
    const resistance = try atmosphereResistance(context, solved.root);
    const atmospheric_transfer_megajoules = context.time_step_hours *
        context.parameters.sensible_heat_conductivity_megajoules_per_m_h_k *
        context.cell_area_m2 / resistance *
        (context.atmospheric_temperature_k - solved.root);
    const prescribed_transfer_megajoules =
        context.time_step_hours * context.source_heat_megajoules_per_h;
    const activity_scale_megajoules = @max(
        @max(
            context.time_step_hours * entry_stored_energy_megajoules,
            context.time_step_hours *
                @abs(context.heat_capacity_megajoules_per_k * solved.root),
        ),
        @abs(atmospheric_transfer_megajoules) +
            @abs(prescribed_transfer_megajoules),
    );
    const conservation_tolerance_megajoules =
        energy_tolerances.relative * activity_scale_megajoules +
        32 * std.math.floatEps(f64) * activity_scale_megajoules;
    try std.testing.expect(
        @abs(closure_residual_megajoules) <= conservation_tolerance_megajoules,
    );
}

test "ground air publishes an exact signed vapor control-volume balance" {
    const parameters = testParameters();
    var state = try State.init(std.testing.allocator, &.{280}, &.{5.0e-6}, &.{10}, 5, parameters);
    defer state.deinit();
    try solve(&state, .{
        .atmospheric_temperature_k = &.{280},
        .atmospheric_vapor_volume_fraction = &.{4.0e-6},
        .cell_area_m2 = &.{10},
        .bulk_richardson_coefficient_k = &.{20},
        .neutral_atmospheric_resistance_h_per_m = &.{0.005},
        .canopy_resistance_h_per_m = &.{0.002},
        .non_atmospheric_sensible_heat_megajoules_per_h = &.{0},
        .non_atmospheric_vapor_flux_m3_per_h = &.{1.0e-5},
        .non_atmospheric_sensible_conductance_megajoules_per_h_k = &.{0},
        .non_atmospheric_sensible_source_temperature_k = &.{280},
        .non_atmospheric_vapor_conductance_m3_per_h = &.{10},
        .non_atmospheric_vapor_source_fraction = &.{6.0e-6},
    }, parameters, test_solver_options, test_vapor_tolerances, test_energy_tolerances, 1);
    const balance = state.vapor_balance[0];
    const accepted_transfers = balance.atmospheric_transfer_m3 +
        balance.prescribed_non_atmospheric_transfer_m3 +
        balance.implicit_surface_transfer_m3;
    try std.testing.expectApproxEqAbs(balance.storage_change_m3, accepted_transfers, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0), balance.closure_residual_m3, 1e-15);
    const accepted_sensible_heat = balance.atmospheric_sensible_heat_transfer_megajoules +
        balance.prescribed_non_atmospheric_sensible_heat_transfer_megajoules +
        balance.implicit_non_atmospheric_sensible_heat_transfer_megajoules;
    try std.testing.expectApproxEqAbs(balance.sensible_heat_storage_change_megajoules, accepted_sensible_heat, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), balance.sensible_heat_closure_residual_megajoules, 1e-10);
    // The litter/snow donor sees the exact opposite of the accepted ground-air
    // transfer; no clamp correction exists outside this identity.
    const implicit_surface_donor_change_m3 = -balance.implicit_surface_transfer_m3;
    try std.testing.expectEqual(@as(f64, 0), balance.implicit_surface_transfer_m3 + implicit_surface_donor_change_m3);
}

test "GROUND-AIR-VAPOR-CONDENSATION-001 genuine supersaturation deposits condensate and closes water and energy exactly" {
    // A synthetic hour whose true physical equilibrium genuinely requires
    // frost formation, constructed directly rather than via the full deck:
    // a cold, near-isothermal boundary air (so the temperature solve is
    // exact and the tiny cold saturation capacity is easy to reason about)
    // with a large prescribed vapor influx that dwarfs that capacity. Before
    // this fix `solve` returned `error.SupersaturatedGroundAirVaporStorage`
    // here; now it must succeed and close both balances exactly.
    const parameters = testParameters();
    var state = try State.init(std.testing.allocator, &.{230}, &.{1.0e-8}, &.{1}, 5, parameters);
    defer state.deinit();
    const old_vapor_m3 = state.vapor_volume_fraction[0] * state.air_volume_m3[0];
    const old_sensible_heat_megajoules = state.temperature_k[0] * state.heat_capacity_megajoules_per_k[0];
    try std.testing.expectEqual(@as(f64, 0), state.condensate_frost_pool_m3[0]);
    try std.testing.expectEqual(@as(f64, 0), state.condensate_frost_pool_heat_megajoules[0]);

    try solve(&state, .{
        .atmospheric_temperature_k = &.{230},
        .atmospheric_vapor_volume_fraction = &.{0},
        .cell_area_m2 = &.{1},
        .bulk_richardson_coefficient_k = &.{0},
        .neutral_atmospheric_resistance_h_per_m = &.{0.005},
        .canopy_resistance_h_per_m = &.{0},
        .non_atmospheric_sensible_heat_megajoules_per_h = &.{0},
        .non_atmospheric_vapor_flux_m3_per_h = &.{1.0e-4},
        .non_atmospheric_sensible_conductance_megajoules_per_h_k = &.{0},
        .non_atmospheric_sensible_source_temperature_k = &.{230},
        .non_atmospheric_vapor_conductance_m3_per_h = &.{0},
        .non_atmospheric_vapor_source_fraction = &.{0},
    }, parameters, test_solver_options, test_vapor_tolerances, test_energy_tolerances, 1);

    // With old_temperature_k == atmospheric_temperature_k == 230 and no
    // other sensible-heat source/conductance, the sensible-only residual is
    // exactly zero at 230 K, so that is the solved root -- and, per this
    // fix's design, the condensation latent heat is deliberately *not*
    // credited back into this control volume's own temperature (see
    // `VaporBalance.condensate_deposition_latent_heat_megajoules`), so
    // `state.temperature_k[0]` after `solve` is still exactly 230.
    try std.testing.expectEqual(@as(f64, 230), state.temperature_k[0]);
    const saturation_fraction = parameters.saturation_vapor_prefactor_k /
        state.temperature_k[0] *
        parameters.saturation_relative_humidity *
        @exp(parameters.saturation_temperature_k *
            (parameters.saturation_reference_inverse_temperature_per_k -
                1 / state.temperature_k[0]));
    const balance = state.vapor_balance[0];

    // Genuinely supersaturated: handled (condensate deposited), not
    // rejected, and accumulated into the dedicated pool.
    try std.testing.expect(balance.condensate_deposition_m3 > 0);
    try std.testing.expectEqual(balance.condensate_deposition_m3, state.condensate_frost_pool_m3[0]);

    // Accepted boundary-air vapor storage sits at saturation, not above it.
    try std.testing.expectApproxEqAbs(
        saturation_fraction,
        state.vapor_volume_fraction[0],
        1e-10 * saturation_fraction,
    );

    // WATSUB 4304-4306 evaluate the atmospheric exchange at the UNCLIPPED
    // predictor `VPQG2`, not at the saturation-clipped committed state, so the
    // deposited condensate is the raw supersaturation. Re-evaluating the
    // transfers at the clipped fraction instead requires scaling the excess by
    // the backward-Euler denominator (> 1 whenever any exchange conductance is
    // active) and therefore sinks strictly more water than the oracle. Pin
    // both the raw-excess magnitude and the unclipped flux evaluation so that
    // departure cannot silently return.
    const air_volume_m3 = state.air_volume_m3[0];
    const solved_unclipped_vapor_m3 = old_vapor_m3 +
        balance.atmospheric_transfer_m3 +
        balance.prescribed_non_atmospheric_transfer_m3 +
        balance.implicit_surface_transfer_m3;
    const raw_supersaturation_m3 = solved_unclipped_vapor_m3 -
        saturation_fraction * air_volume_m3;
    try std.testing.expect(raw_supersaturation_m3 > 0);
    try std.testing.expectApproxEqAbs(
        raw_supersaturation_m3,
        balance.condensate_deposition_m3,
        1e-12 * raw_supersaturation_m3,
    );
    // The exchange conductance is active here (0.005 h m-1 resistance over a
    // 1 m2 cell), so the superseded clipped-fraction formulation would have
    // deposited a strictly and materially larger amount. Assert the gap
    // explicitly: this expectation fails if the clipped-fraction re-evaluation
    // is reinstated.
    const exchange_volume_m3_per_h = 1.0 / 0.005;
    const superseded_denominator = 1 + exchange_volume_m3_per_h / air_volume_m3;
    try std.testing.expect(superseded_denominator > 1.5);
    try std.testing.expect(
        balance.condensate_deposition_m3 <
            0.9 * raw_supersaturation_m3 * superseded_denominator,
    );

    // Water closes exactly: storage change equals every transfer net of the
    // new condensate sink, and matches the state's own actual storage change.
    const accepted_water_transfers = balance.atmospheric_transfer_m3 +
        balance.prescribed_non_atmospheric_transfer_m3 +
        balance.implicit_surface_transfer_m3 -
        balance.condensate_deposition_m3;
    try std.testing.expectApproxEqAbs(balance.storage_change_m3, accepted_water_transfers, 1e-16);
    try std.testing.expectApproxEqAbs(@as(f64, 0), balance.closure_residual_m3, 1e-16);
    const reconstructed_storage_change_m3 =
        state.vapor_volume_fraction[0] * state.air_volume_m3[0] - old_vapor_m3;
    try std.testing.expectApproxEqAbs(reconstructed_storage_change_m3, balance.storage_change_m3, 1e-16);

    // Sensible-heat ledger closes exactly and is entirely untouched by
    // condensation: `solve`'s sensible-heat closure is checked and accepted
    // *before* the vapor/condensate branch runs at all, so this is simply
    // confirming that branch did not reach back and perturb it.
    const accepted_sensible_heat_megajoules = balance.atmospheric_sensible_heat_transfer_megajoules +
        balance.prescribed_non_atmospheric_sensible_heat_transfer_megajoules +
        balance.implicit_non_atmospheric_sensible_heat_transfer_megajoules;
    try std.testing.expectApproxEqAbs(
        balance.sensible_heat_storage_change_megajoules,
        accepted_sensible_heat_megajoules,
        1e-12,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0), balance.sensible_heat_closure_residual_megajoules, 1e-12);
    const reconstructed_sensible_heat_storage_change_megajoules =
        state.temperature_k[0] * state.heat_capacity_megajoules_per_k[0] - old_sensible_heat_megajoules;
    try std.testing.expectApproxEqAbs(
        reconstructed_sensible_heat_storage_change_megajoules,
        balance.sensible_heat_storage_change_megajoules,
        1e-12,
    );

    // The condensation latent heat itself closes exactly into its own
    // companion ledger instead: booked, not dropped (unlike legacy), but
    // kept out of this tiny control volume's own temperature. Below
    // freezing, sublimation latent heat is used, not vaporization's, and is
    // strictly larger for the same condensate mass.
    try std.testing.expect(balance.condensate_deposition_latent_heat_megajoules > 0);
    try std.testing.expectEqual(
        balance.condensate_deposition_latent_heat_megajoules,
        state.condensate_frost_pool_heat_megajoules[0],
    );
    const vaporization_heat_megajoules = balance.condensate_deposition_m3 *
        parameters.liquid_water_latent_heat_megajoules_per_m3;
    const sublimation_heat_megajoules = balance.condensate_deposition_m3 *
        parameters.sublimation_latent_heat_megajoules_per_m3;
    try std.testing.expect(sublimation_heat_megajoules > vaporization_heat_megajoules);
    try std.testing.expectEqual(sublimation_heat_megajoules, balance.condensate_deposition_latent_heat_megajoules);
}

test "ground air one hour halves and quarters scale rates once and converge" {
    const Runner = struct {
        fn run(state: *State, inputs: Inputs, parameters: Parameters, substeps: u8) !VaporBalance {
            var total: VaporBalance = .{};
            const dt = 1.0 / @as(f64, @floatFromInt(substeps));
            for (0..substeps) |_| {
                try solve(state, inputs, parameters, test_solver_options, test_vapor_tolerances, test_energy_tolerances, dt);
                const step = state.vapor_balance[0];
                total.storage_change_m3 += step.storage_change_m3;
                total.atmospheric_transfer_m3 += step.atmospheric_transfer_m3;
                total.prescribed_non_atmospheric_transfer_m3 += step.prescribed_non_atmospheric_transfer_m3;
                total.implicit_surface_transfer_m3 += step.implicit_surface_transfer_m3;
                total.closure_residual_m3 += step.closure_residual_m3;
                total.sensible_heat_storage_change_megajoules += step.sensible_heat_storage_change_megajoules;
                total.atmospheric_sensible_heat_transfer_megajoules += step.atmospheric_sensible_heat_transfer_megajoules;
                total.prescribed_non_atmospheric_sensible_heat_transfer_megajoules += step.prescribed_non_atmospheric_sensible_heat_transfer_megajoules;
                total.implicit_non_atmospheric_sensible_heat_transfer_megajoules += step.implicit_non_atmospheric_sensible_heat_transfer_megajoules;
                total.sensible_heat_closure_residual_megajoules += step.sensible_heat_closure_residual_megajoules;
            }
            return total;
        }
    };
    const parameters = testParameters();
    const inputs: Inputs = .{
        .atmospheric_temperature_k = &.{284},
        .atmospheric_vapor_volume_fraction = &.{4.0e-6},
        .cell_area_m2 = &.{10},
        .bulk_richardson_coefficient_k = &.{20},
        .neutral_atmospheric_resistance_h_per_m = &.{0.005},
        .canopy_resistance_h_per_m = &.{0.002},
        .non_atmospheric_sensible_heat_megajoules_per_h = &.{0.02},
        .non_atmospheric_vapor_flux_m3_per_h = &.{1.0e-5},
        .non_atmospheric_sensible_conductance_megajoules_per_h_k = &.{0.01},
        .non_atmospheric_sensible_source_temperature_k = &.{282},
        .non_atmospheric_vapor_conductance_m3_per_h = &.{10},
        .non_atmospheric_vapor_source_fraction = &.{6.0e-6},
    };
    var hourly = try State.init(std.testing.allocator, &.{280}, &.{5.0e-6}, &.{10}, 5, parameters);
    defer hourly.deinit();
    var halves = try State.init(std.testing.allocator, &.{280}, &.{5.0e-6}, &.{10}, 5, parameters);
    defer halves.deinit();
    var quarters = try State.init(std.testing.allocator, &.{280}, &.{5.0e-6}, &.{10}, 5, parameters);
    defer quarters.deinit();
    const hourly_total = try Runner.run(&hourly, inputs, parameters, 1);
    const halves_total = try Runner.run(&halves, inputs, parameters, 2);
    const quarters_total = try Runner.run(&quarters, inputs, parameters, 4);
    inline for (.{ hourly_total, halves_total, quarters_total }) |total| {
        try std.testing.expectApproxEqAbs(@as(f64, 1.0e-5), total.prescribed_non_atmospheric_transfer_m3, 1e-15);
        try std.testing.expectApproxEqAbs(
            total.storage_change_m3,
            total.atmospheric_transfer_m3 + total.prescribed_non_atmospheric_transfer_m3 + total.implicit_surface_transfer_m3,
            2e-15,
        );
        try std.testing.expectApproxEqAbs(@as(f64, 0), total.closure_residual_m3, 2e-15);
        try std.testing.expectApproxEqAbs(
            total.sensible_heat_storage_change_megajoules,
            total.atmospheric_sensible_heat_transfer_megajoules +
                total.prescribed_non_atmospheric_sensible_heat_transfer_megajoules +
                total.implicit_non_atmospheric_sensible_heat_transfer_megajoules,
            4 * test_energy_tolerances.absolute_megajoules_per_m2 * 10,
        );
    }
    try std.testing.expect(@abs(quarters.temperature_k[0] - halves.temperature_k[0]) < @abs(halves.temperature_k[0] - hourly.temperature_k[0]));
    try std.testing.expect(@abs(quarters.vapor_volume_fraction[0] - halves.vapor_volume_fraction[0]) < @abs(halves.vapor_volume_fraction[0] - hourly.vapor_volume_fraction[0]));

    var first_half = try State.init(std.testing.allocator, &.{280}, &.{5.0e-6}, &.{10}, 5, parameters);
    defer first_half.deinit();
    try solve(&first_half, inputs, parameters, test_solver_options, test_vapor_tolerances, test_energy_tolerances, 0.5);
    var restarted = try State.init(std.testing.allocator, first_half.temperature_k, first_half.vapor_volume_fraction, &.{10}, 5, parameters);
    defer restarted.deinit();
    try solve(&restarted, inputs, parameters, test_solver_options, test_vapor_tolerances, test_energy_tolerances, 0.5);
    try std.testing.expectApproxEqAbs(halves.temperature_k[0], restarted.temperature_k[0], 1e-12);
    try std.testing.expectApproxEqAbs(halves.vapor_volume_fraction[0], restarted.vapor_volume_fraction[0], 1e-15);
}

test "invalid ground air substep leaves all state and diagnostics unchanged" {
    const parameters = testParameters();
    var state = try State.init(std.testing.allocator, &.{280}, &.{5.0e-6}, &.{10}, 5, parameters);
    defer state.deinit();
    state.iteration_count[0] = 9;
    state.vapor_balance[0] = .{ .storage_change_m3 = 3 };
    const before_temperature = state.temperature_k[0];
    const before_vapor = state.vapor_volume_fraction[0];
    try std.testing.expectError(error.InvalidGroundAirTimeStep, solve(&state, .{
        .atmospheric_temperature_k = &.{284},
        .atmospheric_vapor_volume_fraction = &.{4.0e-6},
        .cell_area_m2 = &.{10},
        .bulk_richardson_coefficient_k = &.{20},
        .neutral_atmospheric_resistance_h_per_m = &.{0.005},
        .canopy_resistance_h_per_m = &.{0.002},
        .non_atmospheric_sensible_heat_megajoules_per_h = &.{0},
        .non_atmospheric_vapor_flux_m3_per_h = &.{0},
        .non_atmospheric_sensible_conductance_megajoules_per_h_k = &.{0},
        .non_atmospheric_sensible_source_temperature_k = &.{280},
        .non_atmospheric_vapor_conductance_m3_per_h = &.{0},
        .non_atmospheric_vapor_source_fraction = &.{0},
    }, parameters, test_solver_options, test_vapor_tolerances, test_energy_tolerances, 0));
    try std.testing.expectEqual(before_temperature, state.temperature_k[0]);
    try std.testing.expectEqual(before_vapor, state.vapor_volume_fraction[0]);
    try std.testing.expectEqual(@as(u16, 9), state.iteration_count[0]);
    try std.testing.expectEqualDeep(VaporBalance{ .storage_change_m3 = 3 }, state.vapor_balance[0]);
}

test "negative ground-air vapor rejects atomically" {
    const parameters = testParameters();
    var state = try State.init(std.testing.allocator, &.{280}, &.{5.0e-6}, &.{10}, 5, parameters);
    defer state.deinit();
    state.iteration_count[0] = 7;
    state.vapor_balance[0] = .{ .storage_change_m3 = 3 };
    const temperature_before = state.temperature_k[0];
    const vapor_before = state.vapor_volume_fraction[0];
    const iterations_before = state.iteration_count[0];
    const balance_before = state.vapor_balance[0];
    try std.testing.expectError(error.NegativeGroundAirVaporStorage, solve(&state, .{
        .atmospheric_temperature_k = &.{285},
        .atmospheric_vapor_volume_fraction = &.{4.0e-6},
        .cell_area_m2 = &.{10},
        .bulk_richardson_coefficient_k = &.{20},
        .neutral_atmospheric_resistance_h_per_m = &.{0.005},
        .canopy_resistance_h_per_m = &.{0.002},
        .non_atmospheric_sensible_heat_megajoules_per_h = &.{0.1},
        .non_atmospheric_vapor_flux_m3_per_h = &.{-1},
        .non_atmospheric_sensible_conductance_megajoules_per_h_k = &.{0},
        .non_atmospheric_sensible_source_temperature_k = &.{280},
        .non_atmospheric_vapor_conductance_m3_per_h = &.{0},
        .non_atmospheric_vapor_source_fraction = &.{0},
    }, parameters, test_solver_options, test_vapor_tolerances, test_energy_tolerances, 1));
    try std.testing.expectEqual(temperature_before, state.temperature_k[0]);
    try std.testing.expectEqual(vapor_before, state.vapor_volume_fraction[0]);
    try std.testing.expectEqual(iterations_before, state.iteration_count[0]);
    try std.testing.expectEqualDeep(balance_before, state.vapor_balance[0]);
}

test "negative unconstrained vapor publishes an exact zero-bound balance when enabled" {
    const parameters = testParameters();
    var state = try State.init(std.testing.allocator, &.{280}, &.{5.0e-6}, &.{10}, 5, parameters);
    defer state.deinit();
    var vapor_tolerances = test_vapor_tolerances;
    vapor_tolerances.accept_bounded_zero_vapor_state = true;
    try solve(&state, .{
        .atmospheric_temperature_k = &.{285},
        .atmospheric_vapor_volume_fraction = &.{4.0e-6},
        .cell_area_m2 = &.{10},
        .bulk_richardson_coefficient_k = &.{20},
        .neutral_atmospheric_resistance_h_per_m = &.{0.005},
        .canopy_resistance_h_per_m = &.{0.002},
        .non_atmospheric_sensible_heat_megajoules_per_h = &.{0.1},
        .non_atmospheric_vapor_flux_m3_per_h = &.{-1},
        .non_atmospheric_sensible_conductance_megajoules_per_h_k = &.{0},
        .non_atmospheric_sensible_source_temperature_k = &.{280},
        .non_atmospheric_vapor_conductance_m3_per_h = &.{0},
        .non_atmospheric_vapor_source_fraction = &.{0},
    }, parameters, test_solver_options, vapor_tolerances, test_energy_tolerances, 1);
    const balance = state.vapor_balance[0];
    try std.testing.expectEqual(@as(f64, 0), state.vapor_volume_fraction[0]);
    try std.testing.expect(balance.zero_vapor_bound_atmospheric_transfer_m3 > 0);
    try std.testing.expectApproxEqAbs(
        balance.storage_change_m3,
        balance.atmospheric_transfer_m3 +
            balance.prescribed_non_atmospheric_transfer_m3 +
            balance.implicit_surface_transfer_m3 -
            balance.condensate_deposition_m3,
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        balance.closure_residual_m3,
        1.0e-12,
    );
}

test "material full-hour invalid vapor state rolls back every cell including temperature" {
    // GROUND-AIR-VAPOR-CONDENSATION-001 changed genuine supersaturation
    // (the previous trigger here) from fatal to a handled condensate/frost
    // deposition -- see the dedicated conservation tests below. This test's
    // real subject is the atomic multi-cell rollback behavior of `solve`
    // itself, which is generic across any per-cell failure; a still-fatal
    // negative-vapor trigger (mirroring the single-cell
    // "negative ground-air vapor rejects atomically" test above) exercises
    // the same mechanism.
    const parameters = testParameters();
    var state = try State.init(std.testing.allocator, &.{ 280, 281 }, &.{ 5.0e-6, 5.0e-6 }, &.{ 10, 10 }, 5, parameters);
    defer state.deinit();
    state.iteration_count[0] = 7;
    state.iteration_count[1] = 8;
    state.vapor_balance[0] = .{ .storage_change_m3 = 3 };
    state.vapor_balance[1] = .{ .storage_change_m3 = 4 };
    const temperature_before = [2]f64{ state.temperature_k[0], state.temperature_k[1] };
    const vapor_before = [2]f64{ state.vapor_volume_fraction[0], state.vapor_volume_fraction[1] };
    const iterations_before = [2]u16{ state.iteration_count[0], state.iteration_count[1] };
    const balance_before = [2]VaporBalance{ state.vapor_balance[0], state.vapor_balance[1] };
    const condensate_pool_before = [2]f64{ state.condensate_frost_pool_m3[0], state.condensate_frost_pool_m3[1] };
    const condensate_pool_heat_before = [2]f64{ state.condensate_frost_pool_heat_megajoules[0], state.condensate_frost_pool_heat_megajoules[1] };
    try std.testing.expectError(error.NegativeGroundAirVaporStorage, solve(&state, .{
        .atmospheric_temperature_k = &.{ 285, 285 },
        .atmospheric_vapor_volume_fraction = &.{ 4.0e-6, 4.0e-6 },
        .cell_area_m2 = &.{ 10, 10 },
        .bulk_richardson_coefficient_k = &.{ 20, 20 },
        .neutral_atmospheric_resistance_h_per_m = &.{ 0.005, 0.005 },
        .canopy_resistance_h_per_m = &.{ 0.002, 0.002 },
        .non_atmospheric_sensible_heat_megajoules_per_h = &.{ 0.1, 0.1 },
        .non_atmospheric_vapor_flux_m3_per_h = &.{ 0, -1 },
        .non_atmospheric_sensible_conductance_megajoules_per_h_k = &.{ 0, 0 },
        .non_atmospheric_sensible_source_temperature_k = &.{ 280, 281 },
        .non_atmospheric_vapor_conductance_m3_per_h = &.{ 0, 0 },
        .non_atmospheric_vapor_source_fraction = &.{ 0, 0 },
    }, parameters, test_solver_options, test_vapor_tolerances, test_energy_tolerances, 1));
    try std.testing.expectEqualSlices(f64, &temperature_before, state.temperature_k);
    try std.testing.expectEqualSlices(f64, &vapor_before, state.vapor_volume_fraction);
    try std.testing.expectEqualSlices(u16, &iterations_before, state.iteration_count);
    try std.testing.expectEqualDeep(balance_before, [2]VaporBalance{ state.vapor_balance[0], state.vapor_balance[1] });
    try std.testing.expectEqualSlices(f64, &condensate_pool_before, state.condensate_frost_pool_m3);
    try std.testing.expectEqualSlices(f64, &condensate_pool_heat_before, state.condensate_frost_pool_heat_megajoules);
}

test "surface fluxes become equal and opposite ground air sources" {
    const parameters: Parameters = .{ .minimum_richardson_number = -0.1, .maximum_richardson_number = 0.05, .richardson_resistance_multiplier = 10, .minimum_aerodynamic_resistance_h_per_m = 0.00139, .maximum_aerodynamic_resistance_h_per_m = 0.0139, .volumetric_air_heat_capacity_megajoules_per_m3_k = 1.25e-3, .minimum_air_column_height_m = 5, .sensible_heat_conductivity_megajoules_per_m_h_k = 1.2e-3, .liquid_water_latent_heat_megajoules_per_m3 = 2465, .saturation_vapor_prefactor_k = 2.173e-3, .saturation_relative_humidity = 0.61, .saturation_temperature_k = 5360, .saturation_reference_inverse_temperature_per_k = 3.661e-3, .sublimation_latent_heat_megajoules_per_m3 = 2834, .pure_water_freezing_temperature_k = 273.15 };
    var sensible: [1]f64 = undefined;
    var vapor: [1]f64 = undefined;
    try deriveSurfaceSources(&.{10}, &.{0.2}, &.{-0.493}, parameters, &sensible, &vapor);
    try std.testing.expectApproxEqAbs(-2.0, sensible[0], 1e-15);
    try std.testing.expectApproxEqAbs(0.002, vapor[0], 1e-15);
}

test "surfaceVaporFractionWithKelvinSuppression at zero water potential matches the unsuppressed saturation_fraction formula" {
    const parameters: Parameters = .{ .minimum_richardson_number = -0.1, .maximum_richardson_number = 0.05, .richardson_resistance_multiplier = 10, .minimum_aerodynamic_resistance_h_per_m = 0.00139, .maximum_aerodynamic_resistance_h_per_m = 0.0139, .volumetric_air_heat_capacity_megajoules_per_m3_k = 1.25e-3, .minimum_air_column_height_m = 5, .sensible_heat_conductivity_megajoules_per_m_h_k = 1.2e-3, .liquid_water_latent_heat_megajoules_per_m3 = 2465, .saturation_vapor_prefactor_k = 2.173e-3, .saturation_relative_humidity = 0.61, .saturation_temperature_k = 5360, .saturation_reference_inverse_temperature_per_k = 3.661e-3, .sublimation_latent_heat_megajoules_per_m3 = 2834, .pure_water_freezing_temperature_k = 273.15 };
    const suppressed = try surfaceVaporFractionWithKelvinSuppression(293.15, 0.0, 1.0, parameters);
    const unsuppressed = parameters.saturation_vapor_prefactor_k / 293.15 * parameters.saturation_relative_humidity * @exp(parameters.saturation_temperature_k * (parameters.saturation_reference_inverse_temperature_per_k - 1.0 / 293.15));
    try std.testing.expectApproxEqAbs(unsuppressed, suppressed, 1e-15);
}

test "surfaceVaporFractionWithKelvinSuppression suppresses evaporation as the surface dries" {
    const parameters: Parameters = .{ .minimum_richardson_number = -0.1, .maximum_richardson_number = 0.05, .richardson_resistance_multiplier = 10, .minimum_aerodynamic_resistance_h_per_m = 0.00139, .maximum_aerodynamic_resistance_h_per_m = 0.0139, .volumetric_air_heat_capacity_megajoules_per_m3_k = 1.25e-3, .minimum_air_column_height_m = 5, .sensible_heat_conductivity_megajoules_per_m_h_k = 1.2e-3, .liquid_water_latent_heat_megajoules_per_m3 = 2465, .saturation_vapor_prefactor_k = 2.173e-3, .saturation_relative_humidity = 0.61, .saturation_temperature_k = 5360, .saturation_reference_inverse_temperature_per_k = 3.661e-3, .sublimation_latent_heat_megajoules_per_m3 = 2834, .pure_water_freezing_temperature_k = 273.15 };
    const wet = try surfaceVaporFractionWithKelvinSuppression(293.15, 0.0, 1.0, parameters);
    const dry = try surfaceVaporFractionWithKelvinSuppression(293.15, -500.0, 1.0, parameters);
    try std.testing.expect(dry < wet);
    // exp(18*(-500)/(8.3143*293.15)) ~= 0.024908 (verified via python3 -c "import math; print(math.exp(18.0*(-500.0)/(8.3143*293.15)))")
    try std.testing.expectApproxEqAbs(@as(f64, 0.024908), dry / wet, 5e-5);
}

test "surfaceVaporFractionWithKelvinSuppression rejects a non-finite water potential" {
    const parameters: Parameters = .{ .minimum_richardson_number = -0.1, .maximum_richardson_number = 0.05, .richardson_resistance_multiplier = 10, .minimum_aerodynamic_resistance_h_per_m = 0.00139, .maximum_aerodynamic_resistance_h_per_m = 0.0139, .volumetric_air_heat_capacity_megajoules_per_m3_k = 1.25e-3, .minimum_air_column_height_m = 5, .sensible_heat_conductivity_megajoules_per_m_h_k = 1.2e-3, .liquid_water_latent_heat_megajoules_per_m3 = 2465, .saturation_vapor_prefactor_k = 2.173e-3, .saturation_relative_humidity = 0.61, .saturation_temperature_k = 5360, .saturation_reference_inverse_temperature_per_k = 3.661e-3, .sublimation_latent_heat_megajoules_per_m3 = 2834, .pure_water_freezing_temperature_k = 273.15 };
    try std.testing.expectError(
        error.NonFiniteSurfaceWaterPotentialForEvaporation,
        surfaceVaporFractionWithKelvinSuppression(293.15, std.math.nan(f64), 1.0, parameters),
    );
}

test "STARTS VPQGX zero initializes both boundary carriers before accepted closeout" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/ecosys_ng.zig",
        allocator,
        .limited(4 * 1024 * 1024),
    );
    defer allocator.free(source);
    const initialization_start = std.mem.indexOf(
        u8,
        source,
        "owners.initial_ground_air_vapor_fraction = try allocator.alloc(",
    ) orelse return error.MissingGroundAirVaporInitialization;
    const initialization_end = std.mem.indexOfPos(
        u8,
        source,
        initialization_start,
        "owners.atmospheric_ground_radiation_fraction =",
    ) orelse return error.MissingGroundAirCarrierInitializationEnd;
    const initialization = source[initialization_start..initialization_end];
    const zero_assignment = "owners.initial_ground_air_vapor_fraction[cell] = 0;";
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, initialization, zero_assignment),
    );
    const zero_position = std.mem.indexOf(u8, initialization, zero_assignment) orelse
        return error.MissingStartsVpqgxZeroBinding;
    const ground_state_position = std.mem.indexOf(
        u8,
        initialization,
        "ecosys.ground_air_exchange.State.init",
    ) orelse return error.MissingGroundAirStateInitialization;
    const canopy_state_position = std.mem.indexOf(
        u8,
        initialization,
        "ecosys.atmospheric_canopy_gas_state.State.init",
    ) orelse return error.MissingAtmosphericCanopyCarrierInitialization;
    try std.testing.expect(zero_position < ground_state_position);
    try std.testing.expect(ground_state_position < canopy_state_position);
    const ground_call = initialization[ground_state_position..canopy_state_position];
    const canopy_call = initialization[canopy_state_position..];
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, ground_call, "owners.initial_ground_air_vapor_fraction"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, canopy_call, "owners.initial_ground_air_vapor_fraction"),
    );
    try std.testing.expect(std.mem.indexOf(u8, initialization, "vaporVolumeFraction(") == null);

    const closeout_position = std.mem.indexOf(
        u8,
        source,
        "atmospheric_canopy_gas_state.*.closeAcceptedHour",
    ) orelse return error.MissingAcceptedAtmosphericCanopyCloseout;
    const closeout_end = std.mem.indexOfPos(
        u8,
        source,
        closeout_position,
        ".timestep_h = 1,",
    ) orelse return error.MissingAcceptedAtmosphericCanopyCloseoutEnd;
    const closeout = source[closeout_position..closeout_end];
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            closeout,
            ".ground_vapor_m3_per_m3 = driver_context.ground_air_state.*.vapor_volume_fraction",
        ),
    );
}
