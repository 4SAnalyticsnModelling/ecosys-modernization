const std = @import("std");
const CellRange = @import("../core/compute.zig").CellRange;
const freeze_thaw_energy_limit = @import("litter_freeze_thaw_energy_limit.zig");
const numerics = @import("../core/numerics.zig");
const GridState = @import("../state/grid.zig").GridState;
const AtmosphericState = @import("../atmosphere/atmospheric_forcing.zig").State;
const ground_radiation = @import("ground_radiation.zig");
const GroundRadiationState = ground_radiation.State;
const SurfaceEnergyState = @import("energy.zig").State;
const ExposureState = @import("../canopy/radiation/exposure.zig").State;
const SoilThermalState = @import("../soil/heat/thermal.zig").State;
const phase_change = @import("../soil/water/phase_change.zig");
const retention = @import("../soil/water/retention.zig");
const SimulationConfig = @import("../core/config.zig").SimulationConfig;

pub const Settings = struct {
    sensible_heat_conductance_megajoules_per_m2_h_k: f64,
    latent_heat_conductance_megajoules_per_m2_h_kpa: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_vaporization_megajoules_per_m3: f64,
    surface_vapor_activity_fraction: f64,
    timestep_hours: f64,
    minimum_temperature_k: f64,
    maximum_temperature_k: f64,
    solver_options: numerics.SolverOptions,
    /// Independent physical closure criterion for the accepted surface-energy
    /// equation.  The residual is a rate (MJ m-2 h-1), so this hourly floor is
    /// integrated by the caller's `timestep_hours`; recovery subdivisions do
    /// not multiply the one-hour energy budget.
    energy_conservation_absolute_tolerance_megajoules_per_m2_h: f64,
    energy_conservation_relative_tolerance: f64,
    /// Physical-acceptance goal (2026-09-04): default `false` preserves
    /// today's behavior exactly -- a shared-budget exhaustion inside
    /// `solveWithConservationRefinement` always propagates
    /// `NewtonPicardDiverged`/`Stagnated`/`DidNotConverge`. When `true`, that
    /// failure's otherwise-discarded last iterate is instead checked against
    /// the identical `energy_conservation_absolute_tolerance_megajoules_per_m2_h`/
    /// `energy_conservation_relative_tolerance` gate this function already
    /// uses to refine an accepted root -- no new tolerance is invented -- and
    /// accepted if it passes, still subject to that gate's rejection
    /// otherwise.
    accept_physically_conserved_ceiling: bool = false,
};

fn residualAcceptanceIsValid(
    absolute_residual: f64,
    nonlinear_tolerance: f64,
    conservation_tolerance: f64,
    adjacent_root_certified: bool,
    conservation_ceiling_provenance: bool,
) bool {
    if (!std.math.isFinite(absolute_residual) or
        !std.math.isFinite(nonlinear_tolerance) or
        nonlinear_tolerance <= 0)
        return false;
    if (absolute_residual <= nonlinear_tolerance or adjacent_root_certified)
        return true;
    return conservation_ceiling_provenance and
        std.math.isFinite(conservation_tolerance) and
        conservation_tolerance > 0 and
        absolute_residual <= conservation_tolerance;
}

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    equilibrium_temperature_k: []f64,
    /// Accepted snow-free ALBG/ALBR blend used by this substep's radiation
    /// residual, recomputed from the current soil/litter phase inventories.
    snow_free_surface_albedo: []f64,
    energy_residual_megajoules_per_m2: []f64,
    residual_tolerance_megajoules_per_m2: []f64,
    /// True only when the accepted residual straddles zero with the residual
    /// at an immediately adjacent f64 temperature. This preserves the
    /// representability proof through the later state audit without widening
    /// the configured nonlinear tolerance.
    residual_has_adjacent_root_certificate: []bool,
    /// True only for the explicitly configured shared-budget recovery path,
    /// whose accepted residual has passed the independent physical energy
    /// conservation tolerance even though the process tolerance was missed.
    residual_accepted_by_conservation_ceiling: []bool,
    energy_conservation_tolerance_megajoules_per_m2: []f64,
    sensible_heat_flux_megajoules_per_m2: []f64,
    latent_heat_flux_megajoules_per_m2: []f64,
    vapor_sensible_heat_flux_megajoules_per_m2: []f64,
    conductive_heat_flux_megajoules_per_m2: []f64,
    storage_heat_flux_megajoules_per_m2: []f64,
    phase_heat_flux_megajoules_per_m2: []f64,
    /// Reported-only completion of legacy `TLES`. WATSUB's published ground
    /// latent heat is `HEATE=EFLXG+EFLXR+EFLXW` (`watsub.f:4185`), reduced into
    /// `TLES` by `redist.f:10629`, and each of those three terms carries BOTH
    /// its atmospheric-exchange component and its internal pore-vapor <->
    /// liquid/solid equilibrium component:
    /// `EFLXR2=(EVAPR2W+FLVR2)*VAP` (`watsub.f:3231`),
    /// `EFLXG=(EVAPGW+FLVGS)*VAP` (`watsub.f:2894`), and
    /// `EFLXW2=(WFLVW2+EVAP02W)*VAP+(WFLVS2+EVAP02S)*VAPS` (`watsub.f:1373`),
    /// whose sign convention is documented at `watsub.f:1265` as
    /// "condensation(+ve) or evaporation(-ve)".
    ///
    /// `latent_heat_flux_megajoules_per_m2` above is deliberately restricted to
    /// the atmospheric lane this module's own Newton residual solves, because
    /// that field is consumed by the surface energy-residual budget, by the
    /// hourly-cell and landscape heat ledgers, and (through
    /// `ground_air_exchange.deriveSurfaceSources`) as the boundary-air vapor
    /// source. Adding the equilibrium and topsoil terms to it would break those
    /// three closures and inject a spurious vapor source.
    ///
    /// This separate field therefore carries exactly the remaining `TLES`
    /// components so the reported `ground_surface_latent_heat_flux[W m-2]`
    /// column can be two-sided like the source model's, while every
    /// conservation gate keeps consuming the unchanged residual lane. It is
    /// never read by a solver and never enters a mass or energy balance.
    latent_heat_outside_surface_residual_megajoules_per_m2: []f64,
    /// Accepted EVAPR2W liquid change, separate from freeze/thaw diagnostics.
    vapor_liquid_water_change_m3: []f64,
    /// Accepted EVAPR2V change of represented litter pore vapor.
    atmospheric_vapor_water_change_m3: []f64,
    /// Internal FLVR vapor change; equal and opposite to the internal liquid
    /// change and therefore excluded from atmospheric boundary accounting.
    internal_vapor_water_change_m3: []f64,
    liquid_water_change_m3: []f64,
    ice_water_equivalent_change_m3: []f64,
    iteration_count: []u16,
    newton_raphson_step_count: []u16,
    picard_step_count: []u16,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.EmptySurfaceTemperatureGrid;
        var result: State = .{
            .allocator = allocator,
            .cell_count = cell_count,
            .equilibrium_temperature_k = try allocator.alloc(f64, cell_count),
            .snow_free_surface_albedo = undefined,
            .energy_residual_megajoules_per_m2 = undefined,
            .residual_tolerance_megajoules_per_m2 = undefined,
            .residual_has_adjacent_root_certificate = undefined,
            .residual_accepted_by_conservation_ceiling = undefined,
            .energy_conservation_tolerance_megajoules_per_m2 = undefined,
            .sensible_heat_flux_megajoules_per_m2 = undefined,
            .latent_heat_flux_megajoules_per_m2 = undefined,
            .vapor_sensible_heat_flux_megajoules_per_m2 = undefined,
            .conductive_heat_flux_megajoules_per_m2 = undefined,
            .storage_heat_flux_megajoules_per_m2 = undefined,
            .phase_heat_flux_megajoules_per_m2 = undefined,
            .latent_heat_outside_surface_residual_megajoules_per_m2 = undefined,
            .vapor_liquid_water_change_m3 = undefined,
            .atmospheric_vapor_water_change_m3 = undefined,
            .internal_vapor_water_change_m3 = undefined,
            .liquid_water_change_m3 = undefined,
            .ice_water_equivalent_change_m3 = undefined,
            .iteration_count = undefined,
            .newton_raphson_step_count = undefined,
            .picard_step_count = undefined,
        };
        errdefer allocator.free(result.equilibrium_temperature_k);
        result.snow_free_surface_albedo = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.snow_free_surface_albedo);
        result.energy_residual_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.energy_residual_megajoules_per_m2);
        result.residual_tolerance_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.residual_tolerance_megajoules_per_m2);
        result.residual_has_adjacent_root_certificate = try allocator.alloc(bool, cell_count);
        errdefer allocator.free(result.residual_has_adjacent_root_certificate);
        result.residual_accepted_by_conservation_ceiling = try allocator.alloc(bool, cell_count);
        errdefer allocator.free(result.residual_accepted_by_conservation_ceiling);
        result.energy_conservation_tolerance_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.energy_conservation_tolerance_megajoules_per_m2);
        result.sensible_heat_flux_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.sensible_heat_flux_megajoules_per_m2);
        result.latent_heat_flux_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.latent_heat_flux_megajoules_per_m2);
        result.vapor_sensible_heat_flux_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.vapor_sensible_heat_flux_megajoules_per_m2);
        result.conductive_heat_flux_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.conductive_heat_flux_megajoules_per_m2);
        result.storage_heat_flux_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.storage_heat_flux_megajoules_per_m2);
        result.phase_heat_flux_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.phase_heat_flux_megajoules_per_m2);
        result.latent_heat_outside_surface_residual_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.latent_heat_outside_surface_residual_megajoules_per_m2);
        result.vapor_liquid_water_change_m3 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.vapor_liquid_water_change_m3);
        result.atmospheric_vapor_water_change_m3 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.atmospheric_vapor_water_change_m3);
        result.internal_vapor_water_change_m3 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.internal_vapor_water_change_m3);
        result.liquid_water_change_m3 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.liquid_water_change_m3);
        result.ice_water_equivalent_change_m3 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.ice_water_equivalent_change_m3);
        result.iteration_count = try allocator.alloc(u16, cell_count);
        errdefer allocator.free(result.iteration_count);
        result.newton_raphson_step_count = try allocator.alloc(u16, cell_count);
        errdefer allocator.free(result.newton_raphson_step_count);
        result.picard_step_count = try allocator.alloc(u16, cell_count);
        @memset(result.equilibrium_temperature_k, 273.15);
        @memset(result.snow_free_surface_albedo, 0);
        @memset(result.energy_residual_megajoules_per_m2, 0);
        @memset(result.residual_tolerance_megajoules_per_m2, 0);
        @memset(result.residual_has_adjacent_root_certificate, false);
        @memset(result.residual_accepted_by_conservation_ceiling, false);
        @memset(result.energy_conservation_tolerance_megajoules_per_m2, 0);
        @memset(result.sensible_heat_flux_megajoules_per_m2, 0);
        @memset(result.latent_heat_flux_megajoules_per_m2, 0);
        @memset(result.vapor_sensible_heat_flux_megajoules_per_m2, 0);
        @memset(result.conductive_heat_flux_megajoules_per_m2, 0);
        @memset(result.storage_heat_flux_megajoules_per_m2, 0);
        @memset(result.phase_heat_flux_megajoules_per_m2, 0);
        @memset(result.latent_heat_outside_surface_residual_megajoules_per_m2, 0);
        @memset(result.vapor_liquid_water_change_m3, 0);
        @memset(result.atmospheric_vapor_water_change_m3, 0);
        @memset(result.internal_vapor_water_change_m3, 0);
        @memset(result.liquid_water_change_m3, 0);
        @memset(result.ice_water_equivalent_change_m3, 0);
        @memset(result.iteration_count, 0);
        @memset(result.newton_raphson_step_count, 0);
        @memset(result.picard_step_count, 0);
        return result;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.picard_step_count);
        self.allocator.free(self.newton_raphson_step_count);
        self.allocator.free(self.iteration_count);
        self.allocator.free(self.storage_heat_flux_megajoules_per_m2);
        self.allocator.free(self.phase_heat_flux_megajoules_per_m2);
        self.allocator.free(self.latent_heat_outside_surface_residual_megajoules_per_m2);
        self.allocator.free(self.vapor_liquid_water_change_m3);
        self.allocator.free(self.atmospheric_vapor_water_change_m3);
        self.allocator.free(self.internal_vapor_water_change_m3);
        self.allocator.free(self.liquid_water_change_m3);
        self.allocator.free(self.ice_water_equivalent_change_m3);
        self.allocator.free(self.conductive_heat_flux_megajoules_per_m2);
        self.allocator.free(self.vapor_sensible_heat_flux_megajoules_per_m2);
        self.allocator.free(self.latent_heat_flux_megajoules_per_m2);
        self.allocator.free(self.sensible_heat_flux_megajoules_per_m2);
        self.allocator.free(self.energy_conservation_tolerance_megajoules_per_m2);
        self.allocator.free(self.residual_accepted_by_conservation_ceiling);
        self.allocator.free(self.residual_has_adjacent_root_certificate);
        self.allocator.free(self.residual_tolerance_megajoules_per_m2);
        self.allocator.free(self.energy_residual_megajoules_per_m2);
        self.allocator.free(self.snow_free_surface_albedo);
        self.allocator.free(self.equilibrium_temperature_k);
        self.* = undefined;
    }

    /// Clears accepted phase changes before a potentially failing tile pass.
    /// This makes a caught nonlinear failure publish a zero change for every
    /// cell that was not successfully state_updateted during the current pass.
    pub fn resetPhaseChangeDiagnostics(self: *State) void {
        @memset(self.liquid_water_change_m3, 0);
        @memset(self.ice_water_equivalent_change_m3, 0);
        @memset(self.phase_heat_flux_megajoules_per_m2, 0);
        @memset(self.vapor_liquid_water_change_m3, 0);
        @memset(self.atmospheric_vapor_water_change_m3, 0);
        @memset(self.internal_vapor_water_change_m3, 0);
    }

    pub fn validateFinite(self: State) !void {
        for (self.equilibrium_temperature_k, 0..) |value, cell| if (!std.math.isFinite(value) or value <= 0) {
            std.log.err("invalid solved surface temperature: cell={d} value={e}", .{ cell, value });
            return error.InvalidSolvedSurfaceTemperature;
        };
        for (self.energy_residual_megajoules_per_m2, 0..) |value, cell| if (!std.math.isFinite(value)) {
            std.log.err("non-finite surface energy residual: cell={d} value={e}", .{ cell, value });
            return error.NonFiniteSurfaceTemperatureResidual;
        };
        for (self.energy_conservation_tolerance_megajoules_per_m2, 0..) |value, cell| if (!std.math.isFinite(value) or value <= 0) {
            std.log.err("invalid surface energy conservation tolerance: cell={d} value={e}", .{ cell, value });
            return error.InvalidSurfaceEnergyConservationTolerance;
        };
        inline for (.{ self.snow_free_surface_albedo, self.sensible_heat_flux_megajoules_per_m2, self.latent_heat_flux_megajoules_per_m2, self.vapor_sensible_heat_flux_megajoules_per_m2, self.conductive_heat_flux_megajoules_per_m2, self.storage_heat_flux_megajoules_per_m2, self.phase_heat_flux_megajoules_per_m2, self.latent_heat_outside_surface_residual_megajoules_per_m2, self.vapor_liquid_water_change_m3, self.atmospheric_vapor_water_change_m3, self.internal_vapor_water_change_m3, self.liquid_water_change_m3, self.ice_water_equivalent_change_m3 }) |values| for (values, 0..) |value, cell| {
            if (!std.math.isFinite(value)) {
                std.log.err("non-finite surface heat/phase diagnostic: cell={d} value={e}", .{ cell, value });
                return error.NonFiniteSurfaceHeatDiagnostic;
            }
        };
        for (self.snow_free_surface_albedo, 0..) |value, cell| if (value < 0 or value > 1) {
            std.log.err("invalid accepted snow-free surface albedo: cell={d} value={e}", .{ cell, value });
            return error.InvalidSolvedSurfaceAlbedo;
        };
    }

    pub const Diagnostics = struct {
        maximum_absolute_residual_megajoules_per_m2: f64,
        total_iterations: u64,
        total_newton_raphson_steps: u64,
        total_picard_steps: u64,
        cells_using_picard: usize,
    };

    pub fn validateConvergence(self: State) !Diagnostics {
        var diagnostics: Diagnostics = .{
            .maximum_absolute_residual_megajoules_per_m2 = 0,
            .total_iterations = 0,
            .total_newton_raphson_steps = 0,
            .total_picard_steps = 0,
            .cells_using_picard = 0,
        };
        for (0..self.cell_count) |cell| {
            const absolute_residual = @abs(self.energy_residual_megajoules_per_m2[cell]);
            const tolerance = self.residual_tolerance_megajoules_per_m2[cell];
            const adjacent_root_certified = self.residual_has_adjacent_root_certificate[cell];
            const conservation_ceiling_accepted = self.residual_accepted_by_conservation_ceiling[cell] and
                absolute_residual <= self.energy_conservation_tolerance_megajoules_per_m2[cell];
            if (!residualAcceptanceIsValid(
                absolute_residual,
                tolerance,
                self.energy_conservation_tolerance_megajoules_per_m2[cell],
                adjacent_root_certified,
                self.residual_accepted_by_conservation_ceiling[cell],
            )) {
                std.log.err("surface nonlinear convergence audit failed: cell={d} residual_megajoules_per_m2={e} tolerance={e} adjacent_root_certified={} conservation_ceiling_accepted={} temperature_k={e}", .{ cell, absolute_residual, tolerance, adjacent_root_certified, conservation_ceiling_accepted, self.equilibrium_temperature_k[cell] });
                return error.SurfaceTemperatureResidualTooLarge;
            }
            diagnostics.maximum_absolute_residual_megajoules_per_m2 = @max(diagnostics.maximum_absolute_residual_megajoules_per_m2, absolute_residual);
            diagnostics.total_iterations += self.iteration_count[cell];
            diagnostics.total_newton_raphson_steps += self.newton_raphson_step_count[cell];
            diagnostics.total_picard_steps += self.picard_step_count[cell];
            if (self.picard_step_count[cell] > 0) diagnostics.cells_using_picard += 1;
        }
        return diagnostics;
    }
};

pub const ApplyContext = struct {
    result: *State,
    grid: *GridState,
    atmosphere: *const AtmosphericState,
    air_temperature_k: []const f64,
    air_vapor_pressure_kpa: []const f64,
    /// WATSUB VPQG and already FSNX*CVRDW-partitioned PARERM/PARSRM.
    /// Production supplies all three arrays together. Empty retains the
    /// pressure-based compatibility path used only by isolated tests.
    air_vapor_volume_fraction: []const f64 = &.{},
    litter_vapor_conductance_m3_per_h: []const f64 = &.{},
    litter_sensible_conductance_megajoules_per_h_k: []const f64 = &.{},
    litter_air_volume_m3: []const f64 = &.{},
    litter_vapor_water_equivalent_m3: []const f64 = &.{},
    vapor_fraction_conversion_k_per_kpa: f64 = 0,
    ground_radiation: *const GroundRadiationState,
    surface_energy: *SurfaceEnergyState,
    soil_thermal: *const SoilThermalState,
    /// Complete litter/surface heat capacity, MJ K-1 per cell.
    surface_heat_capacity_megajoules_per_k: []const f64,
    /// Current litter matric+osmotic potential.  Production callers provide
    /// this explicitly so the litter lane cannot silently reuse topsoil vapor
    /// activity.  Empty preserves pure-water behavior for isolated tests.
    surface_water_potential_megapascal: []const f64 = &.{},
    /// Current WATSUB FSNW. Atmospheric radiation, sensible heat and latent
    /// heat reach the litter/soil surface only through its FSNX complement.
    /// Empty retains the snow-free behavior for isolated callers.
    snow_cover_fraction: []const f64 = &.{},
    /// Soil/litter longwave emissivity for the exposed FSNX branch. When
    /// absent, the pre-existing blended emissivity is retained.
    snow_free_surface_emissivity: ?f64 = null,
    exposure: ?*const ExposureState,
    external_heat_megajoules_per_m2: []const f64,
    surface_phase: ?SurfacePhaseContext = null,
    surface_albedo: ?SurfaceAlbedoContext = null,
    settings: Settings,
};

pub const SurfaceAlbedoContext = struct {
    matrix_bulk_volume_m3: []const f64,
    bulk_density_megagrams_per_m3: []const f64,
    dry_litter_albedo: []const f64,
    dry_litter_mass_megagrams: []const f64,
    litter_cover_fraction: []const f64,
    ice_density_megagrams_per_m3: f64,
    phase_volume_absolute_tolerance_m3: f64,
    phase_volume_relative_tolerance: f64,
};

pub const SurfacePhaseContext = struct {
    liquid_water_m3: []f64,
    ice_water_equivalent_m3: []f64,
    retention_capacity_m3: []const f64,
    horizontal_area_m2: []const f64,
    residual_water_content_m3_per_m3: f64,
    van_genuchten_alpha_per_m: f64,
    van_genuchten_n: f64,
    gravitational_water_potential_mpa_per_m: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
    /// Volumetric ice heat capacity expressed on the modern water-equivalent
    /// ice carrier, not physical ice volume.
    ice_heat_capacity_per_water_equivalent_m3_k: f64,
};

const ResidualContext = struct {
    time_step_hours: f64 = 1,
    absorbed_shortwave_megajoules_per_m2: f64,
    atmospheric_longwave_megajoules_per_m2: f64,
    air_temperature_k: f64,
    ground_exposure_fraction: f64,
    emissivity: f64,
    sensible_heat_conductance_megajoules_per_m2_h_k: f64,
    latent_heat_conductance_megajoules_per_m2_h_kpa: f64,
    atmospheric_vapor_pressure_kpa: f64,
    use_vapor_volume_fraction: bool = false,
    vapor_conductance_m3_per_m2_h: f64 = 0,
    air_vapor_volume_fraction: f64 = 0,
    vapor_fraction_conversion_k_per_kpa: f64 = 0,
    surface_vapor_activity_fraction: f64,
    surface_water_potential_megapascal: f64 = 0,
    owner_liquid_water_m3_per_m2: f64 = std.math.floatMax(f64),
    owner_air_volume_m3_per_m2: f64 = 0,
    owner_vapor_water_equivalent_m3_per_m2: f64 = 0,
    /// Exact extensive entry carrier. Production binds this alongside the
    /// per-area transport coordinate so capped writeback and endpoint enthalpy
    /// do not acquire a divide/multiply roundoff discrepancy.
    owner_vapor_water_equivalent_m3: ?f64 = null,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64 = 4.19,
    latent_heat_of_vaporization_megajoules_per_m3: f64 = 2465,
    subsurface_temperature_k: f64,
    previous_surface_temperature_k: f64,
    conductive_heat_conductance_megajoules_per_m2_h_k: f64,
    storage_heat_conductance_megajoules_per_m2_h_k: f64,
    external_heat_megajoules_per_m2: f64 = 0,
    phase: ?CellPhaseContext = null,
};

const CellPhaseContext = struct {
    initial_liquid_water_m3: f64,
    initial_ice_water_equivalent_m3: f64,
    porous_medium_volume_m3: f64,
    horizontal_area_m2: f64,
    parameters: retention.MualemVanGenuchtenParameters,
    gravitational_water_potential_mpa_per_m: f64,
    /// Current PSISVR = surface matric + osmotic potential. The phase-energy
    /// limiter must use the same live potential as vapor equilibrium.
    water_potential_megapascal: f64 = 0,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
    /// Surface volumetric heat capacity, the oracle's `VHCPR2`. `watsub.f` 3150
    /// limits the phase change to the latent heat the temperature deficit can
    /// drive, which is proportional to this capacity.
    heat_capacity_megajoules_per_k: f64,
    /// Non-water part of the entry capacity. WATSUB recomputes the endpoint
    /// capacity after every vapor/liquid/ice carrier change.
    dry_heat_capacity_megajoules_per_k: f64,
    ice_heat_capacity_per_water_equivalent_m3_k: f64,
};

/// Validates the shared surface-temperature inputs before any grid-cell
/// worker is allowed to publish phase changes. In production this is called
/// once by the serial coordinator; workers then use `applyValidatedTile` and
/// never scan phase carriers owned by another horizontal cell.
pub fn validateApplyContext(context: *const ApplyContext) !void {
    try validateSettings(context.settings);
    const result = context.result;
    const resistance_bound = context.air_vapor_volume_fraction.len != 0 or
        context.litter_vapor_conductance_m3_per_h.len != 0 or
        context.litter_sensible_conductance_megajoules_per_h_k.len != 0 or
        context.litter_air_volume_m3.len != 0 or
        context.litter_vapor_water_equivalent_m3.len != 0;
    if (context.grid.cell_count != result.cell_count or context.atmosphere.cell_count != result.cell_count or context.ground_radiation.cell_count != result.cell_count or context.surface_energy.cell_count != result.cell_count or context.soil_thermal.cell_count != result.cell_count or context.air_temperature_k.len != result.cell_count or context.air_vapor_pressure_kpa.len != result.cell_count or context.external_heat_megajoules_per_m2.len != result.cell_count or context.surface_heat_capacity_megajoules_per_k.len != result.cell_count or (context.surface_water_potential_megapascal.len != 0 and context.surface_water_potential_megapascal.len != result.cell_count) or (context.snow_cover_fraction.len != 0 and context.snow_cover_fraction.len != result.cell_count) or (resistance_bound and (context.air_vapor_volume_fraction.len != result.cell_count or context.litter_vapor_conductance_m3_per_h.len != result.cell_count or context.litter_sensible_conductance_megajoules_per_h_k.len != result.cell_count or context.litter_air_volume_m3.len != result.cell_count or context.litter_vapor_water_equivalent_m3.len != result.cell_count))) return error.SurfaceTemperatureDimensionMismatch;
    if (resistance_bound) {
        if (!std.math.isFinite(context.vapor_fraction_conversion_k_per_kpa) or
            context.vapor_fraction_conversion_k_per_kpa <= 0)
            return error.InvalidSurfaceVaporFractionConversion;
    } else if (context.settings.sensible_heat_conductance_megajoules_per_m2_h_k <= 0) {
        return error.InvalidSurfaceTemperatureSettings;
    }
    if (context.snow_free_surface_emissivity) |emissivity|
        if (!std.math.isFinite(emissivity) or emissivity < 0 or emissivity > 1)
            return error.InvalidSnowFreeSurfaceEmissivity;
    if (context.exposure) |exposure| if (exposure.cell_count != result.cell_count) return error.SurfaceTemperatureDimensionMismatch;
    if (context.surface_phase) |surface_phase|
        try validateSurfacePhaseContext(surface_phase, result.cell_count);
    if (context.surface_albedo) |surface_albedo|
        try validateSurfaceAlbedoContext(surface_albedo, context.grid.layer_count, result.cell_count);
}

/// Compatibility entry for isolated callers: retain the historical validate
/// then apply contract. Production validates once on the coordinator and
/// dispatches `applyValidatedTile` over disjoint horizontal grid cells.
pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    try validateApplyContext(context);
    try applyValidatedTile(context, range);
}

/// Applies one already-validated set of inputs to the caller-owned horizontal
/// cells. All vertical/phase state for a cell remains in that invocation, and
/// no value belonging to a cell outside `range` is inspected or mutated.
pub fn applyValidatedTile(context: *ApplyContext, range: CellRange) !void {
    const result = context.result;
    if (range.first > range.end or range.end > result.cell_count)
        return error.SurfaceTemperatureDimensionMismatch;
    const resistance_bound = context.air_vapor_volume_fraction.len != 0 or
        context.litter_vapor_conductance_m3_per_h.len != 0 or
        context.litter_sensible_conductance_megajoules_per_h_k.len != 0 or
        context.litter_air_volume_m3.len != 0 or
        context.litter_vapor_water_equivalent_m3.len != 0;
    for (range.first..range.end) |cell| {
        // A failed nonlinear solve must not expose a phase change retained
        // from an earlier timestep. The prognostic water/ice carriers are
        // state_updateted only below, after convergence.
        result.liquid_water_change_m3[cell] = 0;
        result.ice_water_equivalent_change_m3[cell] = 0;
        result.phase_heat_flux_megajoules_per_m2[cell] = 0;
        result.vapor_liquid_water_change_m3[cell] = 0;
        result.atmospheric_vapor_water_change_m3[cell] = 0;
        result.internal_vapor_water_change_m3[cell] = 0;
        result.residual_has_adjacent_root_certificate[cell] = false;
        result.residual_accepted_by_conservation_ceiling[cell] = false;
        const surface_layer_index = cell * context.grid.soil_layer_capacity;
        const layer_thickness_m = context.soil_thermal.layer_thickness_m[surface_layer_index];
        if (!std.math.isFinite(layer_thickness_m) or layer_thickness_m <= 0) return error.InvalidSurfaceSoilLayerThickness;
        const horizontal_area_m2 = if (context.surface_phase) |phase| phase.horizontal_area_m2[cell] else return error.MissingSurfaceHeatCapacityArea;
        if (!std.math.isFinite(horizontal_area_m2) or horizontal_area_m2 <= 0 or !std.math.isFinite(context.surface_heat_capacity_megajoules_per_k[cell]) or context.surface_heat_capacity_megajoules_per_k[cell] <= 0) return error.InvalidSurfaceHeatCapacity;
        if (resistance_bound and
            (!std.math.isFinite(context.air_vapor_volume_fraction[cell]) or context.air_vapor_volume_fraction[cell] < 0 or
                !std.math.isFinite(context.litter_vapor_conductance_m3_per_h[cell]) or context.litter_vapor_conductance_m3_per_h[cell] < 0 or
                !std.math.isFinite(context.litter_sensible_conductance_megajoules_per_h_k[cell]) or context.litter_sensible_conductance_megajoules_per_h_k[cell] < 0 or
                !std.math.isFinite(context.litter_air_volume_m3[cell]) or context.litter_air_volume_m3[cell] < 0 or
                !std.math.isFinite(context.litter_vapor_water_equivalent_m3[cell]) or context.litter_vapor_water_equivalent_m3[cell] < 0))
            return error.InvalidSurfaceResistanceConductance;
        const snow_cover = if (context.snow_cover_fraction.len == 0) 0 else context.snow_cover_fraction[cell];
        if (!std.math.isFinite(snow_cover) or snow_cover < 0 or snow_cover > 1) return error.InvalidSurfaceSnowCoverFraction;
        const snow_free = 1 - snow_cover;
        // WATSUB source order: ALBG/ALBR are recomputed from the current
        // accepted phase carriers before RFLX0/net radiation is assembled.
        // Failed solves cannot publish this local candidate.
        const live_snow_free_albedo = if (context.surface_albedo) |albedo| live: {
            const soil_liquid_m3 = context.grid.matrix_liquid_water_m3[surface_layer_index] +
                context.grid.macropore_liquid_water_m3[surface_layer_index];
            const soil_ice_volume_m3 = (context.grid.matrix_ice_water_m3[surface_layer_index] +
                context.grid.macropore_ice_water_m3[surface_layer_index]) /
                albedo.ice_density_megagrams_per_m3;
            const soil_albedo = try ground_radiation.phaseWeightedSurfaceAlbedo(
                context.ground_radiation.soil_albedo[cell],
                albedo.matrix_bulk_volume_m3[surface_layer_index] *
                    albedo.bulk_density_megagrams_per_m3[surface_layer_index],
                soil_liquid_m3,
                soil_ice_volume_m3,
                albedo.phase_volume_absolute_tolerance_m3 +
                    albedo.phase_volume_relative_tolerance * @max(
                        albedo.matrix_bulk_volume_m3[surface_layer_index],
                        soil_liquid_m3 + soil_ice_volume_m3,
                    ),
            );
            const cover = albedo.litter_cover_fraction[cell];
            if (cover == 0) break :live soil_albedo;
            const phase = context.surface_phase orelse return error.MissingSurfaceAlbedoPhase;
            // The modern surface owner is ice water equivalent; ALBR consumes
            // WATSUB's physical VOLI(0), so convert with DENSI before weighting.
            const litter_albedo = try ground_radiation.phaseWeightedSurfaceAlbedo(
                albedo.dry_litter_albedo[cell],
                albedo.dry_litter_mass_megagrams[cell],
                phase.liquid_water_m3[cell],
                phase.ice_water_equivalent_m3[cell] / albedo.ice_density_megagrams_per_m3,
                0,
            );
            break :live try ground_radiation.blendSoilLitterAlbedo(
                soil_albedo,
                litter_albedo,
                cover,
            );
        } else context.ground_radiation.soil_albedo[cell];
        const atmospheric_terms = try snowFreeAtmosphericTerms(.{
            .snow_free_fraction = snow_free,
            .incident_shortwave_megajoules_per_m2 = context.ground_radiation.incident_shortwave_megajoules_per_m2[cell],
            .soil_albedo = live_snow_free_albedo,
            .canopy_ground_exposure_fraction = if (context.exposure) |exposure| exposure.ground_exposure_fraction[cell] else 1,
            .sensible_heat_conductance_megajoules_per_m2_h_k = context.settings.sensible_heat_conductance_megajoules_per_m2_h_k,
            .latent_heat_conductance_megajoules_per_m2_h_kpa = context.settings.latent_heat_conductance_megajoules_per_m2_h_kpa,
        });
        const litter_cover = if (context.surface_albedo) |albedo| albedo.litter_cover_fraction[cell] else 1;
        const residual_context: ResidualContext = .{
            .time_step_hours = context.settings.timestep_hours,
            .absorbed_shortwave_megajoules_per_m2 = if (context.snow_cover_fraction.len == 0) context.ground_radiation.absorbed_shortwave_megajoules_per_m2[cell] else atmospheric_terms.absorbed_shortwave_megajoules_per_m2,
            .atmospheric_longwave_megajoules_per_m2 = context.atmosphere.longwave_radiation_megajoules_per_m2[cell],
            .air_temperature_k = context.air_temperature_k[cell],
            .ground_exposure_fraction = atmospheric_terms.exposed_fraction,
            .emissivity = context.snow_free_surface_emissivity orelse context.surface_energy.surface_emissivity[cell],
            .sensible_heat_conductance_megajoules_per_m2_h_k = if (resistance_bound)
                context.litter_sensible_conductance_megajoules_per_h_k[cell] / horizontal_area_m2
            else
                atmospheric_terms.sensible_heat_conductance_megajoules_per_m2_h_k,
            .latent_heat_conductance_megajoules_per_m2_h_kpa = if (resistance_bound) 0 else atmospheric_terms.latent_heat_conductance_megajoules_per_m2_h_kpa * litter_cover,
            .atmospheric_vapor_pressure_kpa = context.air_vapor_pressure_kpa[cell],
            .use_vapor_volume_fraction = resistance_bound,
            .vapor_conductance_m3_per_m2_h = if (resistance_bound)
                context.litter_vapor_conductance_m3_per_h[cell] / horizontal_area_m2
            else
                0,
            .air_vapor_volume_fraction = if (resistance_bound) context.air_vapor_volume_fraction[cell] else 0,
            .vapor_fraction_conversion_k_per_kpa = if (resistance_bound) context.vapor_fraction_conversion_k_per_kpa else 0,
            .surface_vapor_activity_fraction = context.settings.surface_vapor_activity_fraction,
            .surface_water_potential_megapascal = if (context.surface_water_potential_megapascal.len == 0) 0 else context.surface_water_potential_megapascal[cell],
            .owner_liquid_water_m3_per_m2 = if (context.surface_phase) |surface_phase| surface_phase.liquid_water_m3[cell] / horizontal_area_m2 else std.math.floatMax(f64),
            .owner_air_volume_m3_per_m2 = if (resistance_bound) context.litter_air_volume_m3[cell] / horizontal_area_m2 else 0,
            .owner_vapor_water_equivalent_m3_per_m2 = if (resistance_bound) context.litter_vapor_water_equivalent_m3[cell] / horizontal_area_m2 else 0,
            .owner_vapor_water_equivalent_m3 = if (resistance_bound)
                context.litter_vapor_water_equivalent_m3[cell]
            else
                null,
            .liquid_water_heat_capacity_megajoules_per_m3_k = context.settings.liquid_water_heat_capacity_megajoules_per_m3_k,
            .latent_heat_of_vaporization_megajoules_per_m3 = context.settings.latent_heat_of_vaporization_megajoules_per_m3,
            .subsurface_temperature_k = context.grid.soil_temperature_k[surface_layer_index],
            .previous_surface_temperature_k = context.grid.surface_temperature_k[cell],
            // Couple the sequential surface and soil implicit solves with the
            // same accepted conductance. A conductance larger than the
            // topsoil's one-step sensible-heat capacity can demand a soil
            // temperature outside its physical bracket. Limiting the
            // conductance here (rather than clipping the state_updateted flux later)
            // keeps the surface residual and soil source equal and opposite.
            .conductive_heat_conductance_megajoules_per_m2_h_k = @min(
                context.soil_thermal.thermal_conductivity_m_megajoules_per_h_k[surface_layer_index] /
                    (0.5 * layer_thickness_m),
                context.soil_thermal.total_heat_capacity_megajoules_per_m3_k[surface_layer_index] *
                    layer_thickness_m / context.settings.timestep_hours,
            ),
            .storage_heat_conductance_megajoules_per_m2_h_k = context.surface_heat_capacity_megajoules_per_k[cell] / horizontal_area_m2 / context.settings.timestep_hours,
            .external_heat_megajoules_per_m2 = context.external_heat_megajoules_per_m2[cell],
            .phase = if (context.surface_phase) |surface_phase| phase: {
                const represented_vapor_water_equivalent_m3 = if (resistance_bound)
                    context.litter_vapor_water_equivalent_m3[cell]
                else
                    0;
                const dry_heat_capacity_megajoules_per_k =
                    context.surface_heat_capacity_megajoules_per_k[cell] -
                    context.settings.liquid_water_heat_capacity_megajoules_per_m3_k *
                        (surface_phase.liquid_water_m3[cell] + represented_vapor_water_equivalent_m3) -
                    surface_phase.ice_heat_capacity_per_water_equivalent_m3_k *
                        surface_phase.ice_water_equivalent_m3[cell];
                const capacity_scale = @max(
                    1.0,
                    @abs(context.surface_heat_capacity_megajoules_per_k[cell]),
                );
                if (!std.math.isFinite(dry_heat_capacity_megajoules_per_k) or
                    dry_heat_capacity_megajoules_per_k <
                        -64.0 * std.math.floatEps(f64) * capacity_scale)
                    return error.InvalidSurfaceDryHeatCapacity;
                const total_water_equivalent_m3 =
                    surface_phase.liquid_water_m3[cell] +
                    surface_phase.ice_water_equivalent_m3[cell];
                const porous_medium_volume_m3 = @max(
                    surface_phase.retention_capacity_m3[cell],
                    total_water_equivalent_m3,
                );
                if (porous_medium_volume_m3 == 0) break :phase null;
                break :phase .{
                    .initial_liquid_water_m3 = surface_phase.liquid_water_m3[cell],
                    .initial_ice_water_equivalent_m3 = surface_phase.ice_water_equivalent_m3[cell],
                    .porous_medium_volume_m3 = porous_medium_volume_m3,
                    .horizontal_area_m2 = surface_phase.horizontal_area_m2[cell],
                    .parameters = .{
                        .residual_water_content_m3_per_m3 = surface_phase.residual_water_content_m3_per_m3,
                        .saturated_water_content_m3_per_m3 = 1,
                        .alpha_per_m = surface_phase.van_genuchten_alpha_per_m,
                        .n = surface_phase.van_genuchten_n,
                        .saturated_hydraulic_conductivity_m_per_h = 0,
                    },
                    .gravitational_water_potential_mpa_per_m = surface_phase.gravitational_water_potential_mpa_per_m,
                    .water_potential_megapascal = if (context.surface_water_potential_megapascal.len == 0)
                        0
                    else
                        context.surface_water_potential_megapascal[cell],
                    .latent_heat_of_fusion_megajoules_per_m3 = surface_phase.latent_heat_of_fusion_megajoules_per_m3,
                    .pure_water_melting_temperature_k = surface_phase.pure_water_melting_temperature_k,
                    .heat_capacity_megajoules_per_k = context.surface_heat_capacity_megajoules_per_k[cell],
                    .dry_heat_capacity_megajoules_per_k = @max(
                        0,
                        dry_heat_capacity_megajoules_per_k,
                    ),
                    .ice_heat_capacity_per_water_equivalent_m3_k = surface_phase.ice_heat_capacity_per_water_equivalent_m3_k,
                };
            } else null,
        };
        if (!std.math.isFinite(residual_context.external_heat_megajoules_per_m2)) return error.NonFiniteSurfaceExternalHeat;
        const accepted_solve = solveWithConservationRefinement(
            residual_context,
            context.settings,
            context.settings.minimum_temperature_k,
            context.settings.maximum_temperature_k,
            context.grid.surface_temperature_k[cell],
        ) catch |err| {
            std.log.err("surface temperature solve failed: cell={d} initial_temperature_k={e}", .{ cell, context.grid.surface_temperature_k[cell] });
            // REAL-DECK-HOUR-11-FATAL-STAGNATION-001 (2026-09-04): full
            // residual-context dump so a real-deck failure can be replayed
            // as a fast, isolated unit test instead of re-paying the
            // ~30min STARTE+hourly-loop cost on every diagnostic attempt.
            std.log.err(
                "surface temperature residual context: time_step_hours={e} absorbed_shortwave_mj_m2={e} atmospheric_longwave_mj_m2={e} air_temperature_k={e} ground_exposure_fraction={e} emissivity={e} sensible_conductance_mj_m2_h_k={e} latent_conductance_mj_m2_h_kpa={e} atmospheric_vapor_pressure_kpa={e} subsurface_temperature_k={e} previous_surface_temperature_k={e} conductive_conductance_mj_m2_h_k={e} storage_conductance_mj_m2_h_k={e} external_heat_mj_m2={e} surface_vapor_activity_fraction={e} min_temperature_k={e} max_temperature_k={e}",
                .{
                    residual_context.time_step_hours,
                    residual_context.absorbed_shortwave_megajoules_per_m2,
                    residual_context.atmospheric_longwave_megajoules_per_m2,
                    residual_context.air_temperature_k,
                    residual_context.ground_exposure_fraction,
                    residual_context.emissivity,
                    residual_context.sensible_heat_conductance_megajoules_per_m2_h_k,
                    residual_context.latent_heat_conductance_megajoules_per_m2_h_kpa,
                    residual_context.atmospheric_vapor_pressure_kpa,
                    residual_context.subsurface_temperature_k,
                    residual_context.previous_surface_temperature_k,
                    residual_context.conductive_heat_conductance_megajoules_per_m2_h_k,
                    residual_context.storage_heat_conductance_megajoules_per_m2_h_k,
                    residual_context.external_heat_megajoules_per_m2,
                    residual_context.surface_vapor_activity_fraction,
                    context.settings.minimum_temperature_k,
                    context.settings.maximum_temperature_k,
                },
            );
            if (residual_context.phase) |phase| std.log.err(
                "surface temperature residual context phase: initial_liquid_water_m3={e} initial_ice_water_equivalent_m3={e} porous_medium_volume_m3={e} horizontal_area_m2={e} heat_capacity_mj_k={e} dry_heat_capacity_mj_k={e}",
                .{
                    phase.initial_liquid_water_m3,
                    phase.initial_ice_water_equivalent_m3,
                    phase.porous_medium_volume_m3,
                    phase.horizontal_area_m2,
                    phase.heat_capacity_megajoules_per_k,
                    phase.dry_heat_capacity_megajoules_per_k,
                },
            );
            return err;
        };
        const solved = accepted_solve.solved;
        result.equilibrium_temperature_k[cell] = solved.root;
        result.snow_free_surface_albedo[cell] = live_snow_free_albedo;
        result.energy_residual_megajoules_per_m2[cell] = solved.residual;
        result.residual_tolerance_megajoules_per_m2[cell] = accepted_solve.nonlinear_tolerance_megajoules_per_m2;
        result.residual_has_adjacent_root_certificate[cell] = accepted_solve.residual_has_adjacent_root_certificate;
        result.residual_accepted_by_conservation_ceiling[cell] = accepted_solve.residual_accepted_by_conservation_ceiling;
        result.energy_conservation_tolerance_megajoules_per_m2[cell] = accepted_solve.conservation_tolerance_megajoules_per_m2;
        result.sensible_heat_flux_megajoules_per_m2[cell] = residual_context.sensible_heat_conductance_megajoules_per_m2_h_k * (residual_context.air_temperature_k - solved.root);
        const accepted_vapor = vaporHeatTerms(residual_context, solved.root);
        const accepted_internal_vapor = internalVaporEquilibrium(residual_context, solved.root);
        const post_internal_vapor_m3 = context.litter_vapor_water_equivalent_m3[cell] +
            accepted_internal_vapor.vapor_change_m3;
        result.latent_heat_flux_megajoules_per_m2[cell] = accepted_vapor.latent;
        result.vapor_sensible_heat_flux_megajoules_per_m2[cell] = accepted_vapor.sensible;
        result.atmospheric_vapor_water_change_m3[cell] = acceptedAtmosphericVaporChangeM3(
            accepted_vapor,
            post_internal_vapor_m3,
            horizontal_area_m2,
            context.settings.timestep_hours,
        );
        result.conductive_heat_flux_megajoules_per_m2[cell] = residual_context.conductive_heat_conductance_megajoules_per_m2_h_k * (residual_context.subsurface_temperature_k - solved.root);
        // `DRY-LAYER-UNPHYSICAL-HEAT-SINK-HOUR-2726-001`. This flux becomes the
        // top soil layer's extensive heat source at `hourly_workspace.zig:256`,
        // and `bindSurfaceHeatFlux` is contractually forbidden from clipping it.
        // At hour 2,705 it reached `-1.5816727759048629e1` MJ for a 1 m2 cell --
        // `4394 W m-2`, three to four times peak solar, as a sink -- which the
        // soil layer could not absorb and the per-layer heat census rejected.
        //
        // Gated on a magnitude no physical surface flux reaches, so an ordinary
        // hour logs nothing: 5 MJ m-2 h-1 is about `1400 W m-2`. Prints both
        // arms of the `@min` above separately, because the limiting arm reads
        // `soil_thermal.total_heat_capacity_megajoules_per_m3_k` while the soil
        // solver uses `workspace.heat_capacity_megajoules_per_k`, and those are
        // two owners of one layer's capacity that nothing holds consistent.
        // Gate on the RATE, not the per-substep amount. This flux is already
        // integrated over `timestep_hours`, which is a SUBSTEP length, so a
        // 4394 W m-2 rate is only ~0.25 MJ m-2 across a 1/64 h substep. The
        // first version of this probe gated the substep amount at 5 MJ and
        // reported zero hits across 2,705 hours, which I wrongly read as
        // exonerating surface conduction -- the same vacuous-null error as the
        // 0.5 threshold on the dry-capacity trace earlier in this investigation.
        if (context.settings.timestep_hours > 0 and
            @abs(result.conductive_heat_flux_megajoules_per_m2[cell]) /
                context.settings.timestep_hours > 5) std.log.err(
            "implausible surface conductive flux: cell={d} flux_megajoules_per_m2={e} conductance={e} conductivity_arm={e} capacity_arm={e} thermal_conductivity_m_megajoules_per_h_k={e} soil_thermal_total_capacity_per_m3_k={e} layer_thickness_m={e} timestep_hours={e} subsurface_temperature_k={e} surface_temperature_k={e} temperature_difference_k={e}",
            .{
                cell,
                result.conductive_heat_flux_megajoules_per_m2[cell],
                residual_context.conductive_heat_conductance_megajoules_per_m2_h_k,
                context.soil_thermal.thermal_conductivity_m_megajoules_per_h_k[surface_layer_index] /
                    (0.5 * layer_thickness_m),
                context.soil_thermal.total_heat_capacity_megajoules_per_m3_k[surface_layer_index] *
                    layer_thickness_m / context.settings.timestep_hours,
                context.soil_thermal.thermal_conductivity_m_megajoules_per_h_k[surface_layer_index],
                context.soil_thermal.total_heat_capacity_megajoules_per_m3_k[surface_layer_index],
                layer_thickness_m,
                context.settings.timestep_hours,
                residual_context.subsurface_temperature_k,
                solved.root,
                residual_context.subsurface_temperature_k - solved.root,
            },
        );
        result.storage_heat_flux_megajoules_per_m2[cell] =
            surfaceStorageHeatFlux(residual_context, solved.root);
        const accepted_emitted_longwave_megajoules_per_m2 = residual_context.emissivity * 2.04e-10 * std.math.pow(f64, solved.root, 4) * residual_context.ground_exposure_fraction;
        context.surface_energy.downward_sky_longwave_megajoules_per_m2[cell] = residual_context.atmospheric_longwave_megajoules_per_m2 * residual_context.ground_exposure_fraction;
        context.surface_energy.emitted_sky_longwave_megajoules_per_m2[cell] = accepted_emitted_longwave_megajoules_per_m2;
        context.surface_energy.net_longwave_megajoules_per_m2[cell] = context.surface_energy.downward_sky_longwave_megajoules_per_m2[cell] - accepted_emitted_longwave_megajoules_per_m2;
        context.surface_energy.net_radiation_megajoules_per_m2[cell] = residual_context.absorbed_shortwave_megajoules_per_m2 + context.surface_energy.net_longwave_megajoules_per_m2[cell];
        if (context.surface_phase) |surface_phase| if (residual_context.phase != null) {
            const phase_after_vapor = phaseContextAfterInternalVapor(residual_context, solved.root);
            const equilibrium = try surfacePhaseEquilibrium(
                phase_after_vapor,
                solved.root,
            );
            result.internal_vapor_water_change_m3[cell] = accepted_internal_vapor.vapor_change_m3;
            result.vapor_liquid_water_change_m3[cell] = acceptedLiquidVaporChangeM3(
                accepted_vapor,
                equilibrium.liquid_water_m3,
                horizontal_area_m2,
                context.settings.timestep_hours,
            );
            const final_liquid_water_m3 = equilibrium.liquid_water_m3 +
                result.vapor_liquid_water_change_m3[cell];
            if (!std.math.isFinite(final_liquid_water_m3) or final_liquid_water_m3 < 0)
                return error.InvalidAcceptedSurfaceLiquidWater;
            result.liquid_water_change_m3[cell] =
                final_liquid_water_m3 -
                surface_phase.liquid_water_m3[cell];
            result.ice_water_equivalent_change_m3[cell] =
                equilibrium.ice_water_equivalent_m3 -
                surface_phase.ice_water_equivalent_m3[cell];
            result.phase_heat_flux_megajoules_per_m2[cell] =
                (accepted_internal_vapor.latent_heat_megajoules +
                    residual_context.phase.?.latent_heat_of_fusion_megajoules_per_m3 *
                        result.ice_water_equivalent_change_m3[cell]) /
                residual_context.phase.?.horizontal_area_m2;
            surface_phase.liquid_water_m3[cell] =
                final_liquid_water_m3;
            surface_phase.ice_water_equivalent_m3[cell] =
                equilibrium.ice_water_equivalent_m3;
        } else {
            result.vapor_liquid_water_change_m3[cell] = 0;
            result.atmospheric_vapor_water_change_m3[cell] = 0;
            result.internal_vapor_water_change_m3[cell] = 0;
            result.liquid_water_change_m3[cell] = 0;
            result.ice_water_equivalent_change_m3[cell] = 0;
            result.phase_heat_flux_megajoules_per_m2[cell] = 0;
        } else {
            result.vapor_liquid_water_change_m3[cell] = 0;
            result.atmospheric_vapor_water_change_m3[cell] = 0;
            result.internal_vapor_water_change_m3[cell] = 0;
            result.liquid_water_change_m3[cell] = 0;
            result.ice_water_equivalent_change_m3[cell] = 0;
            result.phase_heat_flux_megajoules_per_m2[cell] = 0;
        }
        result.iteration_count[cell] = solved.iterations;
        result.newton_raphson_step_count[cell] = solved.newton_raphson_steps;
        result.picard_step_count[cell] = solved.picard_steps;
        // Each tile owns its cells, so state_updateting the converged prognostic
        // temperature is race-free under the CPU executor and GPU-ready.
        context.grid.surface_temperature_k[cell] = solved.root;
    }
}

const SnowFreeAtmosphericInputs = struct {
    snow_free_fraction: f64,
    incident_shortwave_megajoules_per_m2: f64,
    soil_albedo: f64,
    canopy_ground_exposure_fraction: f64,
    sensible_heat_conductance_megajoules_per_m2_h_k: f64,
    latent_heat_conductance_megajoules_per_m2_h_kpa: f64,
};

const SnowFreeAtmosphericTerms = struct {
    absorbed_shortwave_megajoules_per_m2: f64,
    exposed_fraction: f64,
    sensible_heat_conductance_megajoules_per_m2_h_k: f64,
    latent_heat_conductance_megajoules_per_m2_h_kpa: f64,
};

fn snowFreeAtmosphericTerms(inputs: SnowFreeAtmosphericInputs) !SnowFreeAtmosphericTerms {
    inline for (@typeInfo(SnowFreeAtmosphericInputs).@"struct".fields) |field|
        if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteSnowFreeAtmosphericInput;
    if (inputs.snow_free_fraction < 0 or inputs.snow_free_fraction > 1 or
        inputs.incident_shortwave_megajoules_per_m2 < 0 or inputs.soil_albedo < 0 or inputs.soil_albedo > 1 or
        inputs.canopy_ground_exposure_fraction < 0 or inputs.canopy_ground_exposure_fraction > 1 or
        inputs.sensible_heat_conductance_megajoules_per_m2_h_k < 0 or
        inputs.latent_heat_conductance_megajoules_per_m2_h_kpa < 0)
        return error.InvalidSnowFreeAtmosphericInput;
    return .{
        .absorbed_shortwave_megajoules_per_m2 = inputs.incident_shortwave_megajoules_per_m2 *
            (1 - inputs.soil_albedo) * inputs.snow_free_fraction,
        .exposed_fraction = inputs.canopy_ground_exposure_fraction * inputs.snow_free_fraction,
        .sensible_heat_conductance_megajoules_per_m2_h_k = inputs.sensible_heat_conductance_megajoules_per_m2_h_k * inputs.snow_free_fraction,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = inputs.latent_heat_conductance_megajoules_per_m2_h_kpa * inputs.snow_free_fraction,
    };
}

test "full snow cover suppresses buried litter atmospheric exchange" {
    const covered = try snowFreeAtmosphericTerms(.{
        .snow_free_fraction = 0,
        .incident_shortwave_megajoules_per_m2 = 2,
        .soil_albedo = 0.2,
        .canopy_ground_exposure_fraction = 0.75,
        .sensible_heat_conductance_megajoules_per_m2_h_k = 0.43,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = 0.1,
    });
    try std.testing.expectEqual(@as(f64, 0), covered.absorbed_shortwave_megajoules_per_m2);
    try std.testing.expectEqual(@as(f64, 0), covered.exposed_fraction);
    try std.testing.expectEqual(@as(f64, 0), covered.sensible_heat_conductance_megajoules_per_m2_h_k);
    try std.testing.expectEqual(@as(f64, 0), covered.latent_heat_conductance_megajoules_per_m2_h_kpa);
    const partial = try snowFreeAtmosphericTerms(.{
        .snow_free_fraction = 0.25,
        .incident_shortwave_megajoules_per_m2 = 2,
        .soil_albedo = 0.2,
        .canopy_ground_exposure_fraction = 0.8,
        .sensible_heat_conductance_megajoules_per_m2_h_k = 0.4,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = 0.2,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), partial.absorbed_shortwave_megajoules_per_m2, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), partial.exposed_fraction, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), partial.sensible_heat_conductance_megajoules_per_m2_h_k, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), partial.latent_heat_conductance_megajoules_per_m2_h_kpa, 1e-15);
}

test "wet dry and frozen live albedo causally change absorbed net-radiation forcing" {
    const dry_albedo = try ground_radiation.phaseWeightedSurfaceAlbedo(0.40, 1, 0, 0, 1.0e-12);
    const wet_albedo = try ground_radiation.phaseWeightedSurfaceAlbedo(0.40, 1, 0.5, 0, 1.0e-12);
    const frozen_albedo = try ground_radiation.phaseWeightedSurfaceAlbedo(0.40, 1, 0, 0.5, 1.0e-12);
    const common = SnowFreeAtmosphericInputs{
        .snow_free_fraction = 1,
        .incident_shortwave_megajoules_per_m2 = 2,
        .soil_albedo = dry_albedo,
        .canopy_ground_exposure_fraction = 1,
        .sensible_heat_conductance_megajoules_per_m2_h_k = 0.2,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = 0.1,
    };
    const dry = try snowFreeAtmosphericTerms(common);
    var changed = common;
    changed.soil_albedo = frozen_albedo;
    const frozen = try snowFreeAtmosphericTerms(changed);
    changed.soil_albedo = wet_albedo;
    const wet = try snowFreeAtmosphericTerms(changed);
    try std.testing.expect(wet.absorbed_shortwave_megajoules_per_m2 > frozen.absorbed_shortwave_megajoules_per_m2);
    try std.testing.expect(frozen.absorbed_shortwave_megajoules_per_m2 > dry.absorbed_shortwave_megajoules_per_m2);
}

/// WATSUB 3348-3355 carries entry enthalpy (`VHCPR2 * TKR2`) across the
/// nonlinear solve, then recomputes `VHCPR2` from the accepted trial liquid,
/// represented vapor, and ice carriers. The modern ice carrier is water
/// equivalent, so its coefficient is explicitly converted at the binding.
fn endpointSurfaceHeatCapacityMegajoulesPerM2K(
    context: ResidualContext,
    temperature_k: f64,
) f64 {
    const phase = context.phase orelse
        return context.storage_heat_conductance_megajoules_per_m2_h_k *
            context.time_step_hours;
    const internal = internalVaporEquilibrium(context, temperature_k);
    const phase_after_internal_vapor = phaseContextAfterInternalVapor(
        context,
        temperature_k,
    );
    const equilibrium = surfacePhaseEquilibrium(
        phase_after_internal_vapor,
        temperature_k,
    ) catch return std.math.nan(f64);
    const atmospheric = vaporHeatTerms(context, temperature_k);
    const post_internal_vapor_m3 = ownerVaporWaterEquivalentM3(context, phase) +
        internal.vapor_change_m3;
    const endpoint_vapor_m3 = post_internal_vapor_m3 +
        acceptedAtmosphericVaporChangeM3(
            atmospheric,
            post_internal_vapor_m3,
            phase.horizontal_area_m2,
            context.time_step_hours,
        );
    const endpoint_liquid_m3 = equilibrium.liquid_water_m3 +
        acceptedLiquidVaporChangeM3(
            atmospheric,
            equilibrium.liquid_water_m3,
            phase.horizontal_area_m2,
            context.time_step_hours,
        );
    if (!std.math.isFinite(endpoint_liquid_m3) or endpoint_liquid_m3 < 0 or
        !std.math.isFinite(endpoint_vapor_m3) or endpoint_vapor_m3 < 0 or
        !std.math.isFinite(equilibrium.ice_water_equivalent_m3) or
        equilibrium.ice_water_equivalent_m3 < 0)
        return std.math.nan(f64);
    const capacity_megajoules_per_k =
        phase.dry_heat_capacity_megajoules_per_k +
        context.liquid_water_heat_capacity_megajoules_per_m3_k *
            (endpoint_liquid_m3 + endpoint_vapor_m3) +
        phase.ice_heat_capacity_per_water_equivalent_m3_k *
            equilibrium.ice_water_equivalent_m3;
    if (!std.math.isFinite(capacity_megajoules_per_k) or
        capacity_megajoules_per_k <= 0)
        return std.math.nan(f64);
    return capacity_megajoules_per_k / phase.horizontal_area_m2;
}

fn surfaceStorageHeatFlux(context: ResidualContext, temperature_k: f64) f64 {
    const entry_capacity_megajoules_per_m2_k =
        context.storage_heat_conductance_megajoules_per_m2_h_k *
        context.time_step_hours;
    const endpoint_capacity_megajoules_per_m2_k =
        endpointSurfaceHeatCapacityMegajoulesPerM2K(context, temperature_k);
    return (entry_capacity_megajoules_per_m2_k *
        context.previous_surface_temperature_k -
        endpoint_capacity_megajoules_per_m2_k * temperature_k) /
        context.time_step_hours;
}

fn surfaceStorageHeatDerivative(context: ResidualContext, temperature_k: f64) f64 {
    if (context.phase == null)
        return -context.storage_heat_conductance_megajoules_per_m2_h_k;
    const step_k = std.math.cbrt(std.math.floatEps(f64)) *
        @max(1.0, @abs(temperature_k));
    return (surfaceStorageHeatFlux(context, temperature_k + step_k) -
        surfaceStorageHeatFlux(context, temperature_k - step_k)) / (2 * step_k);
}

fn residual(context: ResidualContext, temperature_k: f64) f64 {
    const downward_longwave = context.atmospheric_longwave_megajoules_per_m2 * context.ground_exposure_fraction;
    const emitted_longwave = context.emissivity * 2.04e-10 * std.math.pow(f64, temperature_k, 4) * context.ground_exposure_fraction;
    const sensible_heat = context.sensible_heat_conductance_megajoules_per_m2_h_k * (context.air_temperature_k - temperature_k);
    const conductive_heat = context.conductive_heat_conductance_megajoules_per_m2_h_k * (context.subsurface_temperature_k - temperature_k);
    const storage_heat = surfaceStorageHeatFlux(context, temperature_k);
    return context.absorbed_shortwave_megajoules_per_m2 + context.external_heat_megajoules_per_m2 + downward_longwave - emitted_longwave + sensible_heat + vaporHeatTerms(context, temperature_k).total + conductive_heat + storage_heat + phaseHeatFlux(context, temperature_k);
}

fn derivative(context: ResidualContext, temperature_k: f64) f64 {
    return -4.0 * context.emissivity * 2.04e-10 * std.math.pow(f64, temperature_k, 3) * context.ground_exposure_fraction - context.sensible_heat_conductance_megajoules_per_m2_h_k + vaporHeatTerms(context, temperature_k).derivative - context.conductive_heat_conductance_megajoules_per_m2_h_k + surfaceStorageHeatDerivative(context, temperature_k) + phaseHeatDerivative(context, temperature_k);
}

fn picard(context: ResidualContext, temperature_k: f64) f64 {
    const downward_longwave = context.atmospheric_longwave_megajoules_per_m2 * context.ground_exposure_fraction;
    const emitted_longwave = context.emissivity * 2.04e-10 * std.math.pow(f64, temperature_k, 4) * context.ground_exposure_fraction;
    const endpoint_storage_conductance =
        endpointSurfaceHeatCapacityMegajoulesPerM2K(context, temperature_k) /
        context.time_step_hours;
    const entry_storage_heat = context.storage_heat_conductance_megajoules_per_m2_h_k *
        context.previous_surface_temperature_k;
    const total_linear_conductance = context.sensible_heat_conductance_megajoules_per_m2_h_k + context.conductive_heat_conductance_megajoules_per_m2_h_k + endpoint_storage_conductance;
    return (context.sensible_heat_conductance_megajoules_per_m2_h_k * context.air_temperature_k + context.conductive_heat_conductance_megajoules_per_m2_h_k * context.subsurface_temperature_k + entry_storage_heat + context.absorbed_shortwave_megajoules_per_m2 + context.external_heat_megajoules_per_m2 + downward_longwave - emitted_longwave + vaporHeatTerms(context, temperature_k).total + phaseHeatFlux(context, temperature_k)) / total_linear_conductance;
}

fn saturationVaporPressureKpa(temperature_k: f64) f64 {
    return 0.61 * @exp(5360.0 * (3.661e-3 - 1.0 / temperature_k));
}

fn latentHeatFlux(context: ResidualContext, temperature_k: f64) f64 {
    return vaporHeatTerms(context, temperature_k).latent;
}

const VaporHeatTerms = struct {
    latent: f64,
    sensible: f64,
    total: f64,
    derivative: f64,
    vapor_exhausted: bool,
    liquid_exhausted: bool,
    vapor_water_rate_m3_per_m2_h: f64,
    liquid_water_rate_m3_per_m2_h: f64,
    total_water_rate_m3_per_m2_h: f64,
};

/// Publish an exhausted represented-vapor donor at its exact inventory face.
/// Reconstructing the capped amount as `(storage / area / dt) * area * dt`
/// can land a few ulps below zero even though the mathematical endpoint is
/// exactly empty. The receiver consumes this same signed extensive amount, so
/// choosing the exact endpoint preserves donor loss == recipient gain without
/// clipping or changing the Newton residual.
fn acceptedAtmosphericVaporChangeM3(
    terms: VaporHeatTerms,
    post_internal_vapor_m3: f64,
    horizontal_area_m2: f64,
    time_step_hours: f64,
) f64 {
    return if (terms.vapor_exhausted)
        -post_internal_vapor_m3
    else
        terms.vapor_water_rate_m3_per_m2_h * horizontal_area_m2 * time_step_hours;
}

fn acceptedLiquidVaporChangeM3(
    terms: VaporHeatTerms,
    post_phase_liquid_water_m3: f64,
    horizontal_area_m2: f64,
    time_step_hours: f64,
) f64 {
    return if (terms.liquid_exhausted)
        -post_phase_liquid_water_m3
    else
        terms.liquid_water_rate_m3_per_m2_h * horizontal_area_m2 * time_step_hours;
}

fn ownerVaporWaterEquivalentM3(
    context: ResidualContext,
    phase: CellPhaseContext,
) f64 {
    return context.owner_vapor_water_equivalent_m3 orelse
        context.owner_vapor_water_equivalent_m3_per_m2 * phase.horizontal_area_m2;
}

fn internalVaporEquilibrium(context: ResidualContext, temperature_k: f64) phase_change.VaporEquilibrium {
    if (!context.use_vapor_volume_fraction or context.phase == null) return .{
        .saturated_vapor_fraction = 0,
        .water_condensation_m3 = 0,
        .vapor_change_m3 = 0,
        .latent_heat_megajoules = 0,
    };
    const phase_context = context.phase.?;
    return phase_change.vaporLiquidEquilibrium(
        temperature_k,
        context.surface_water_potential_megapascal,
        ownerVaporWaterEquivalentM3(context, phase_context),
        context.owner_air_volume_m3_per_m2 * phase_context.horizontal_area_m2,
        phase_context.initial_liquid_water_m3,
        1,
        .{
            .vapor_density_temperature_coefficient = context.vapor_fraction_conversion_k_per_kpa,
            .molecular_weight_ratio = 0.61,
            .clausius_clapeyron_coefficient_k = 5360,
            .reference_inverse_temperature_per_k = 3.661e-3,
            .water_molar_mass_g_per_mol = 18,
            .gas_constant_j_per_mol_k = 8.3143,
            .latent_heat_of_vaporization_megajoules_per_m3 = context.latent_heat_of_vaporization_megajoules_per_m3,
        },
    ) catch .{
        .saturated_vapor_fraction = std.math.nan(f64),
        .water_condensation_m3 = std.math.nan(f64),
        .vapor_change_m3 = std.math.nan(f64),
        .latent_heat_megajoules = std.math.nan(f64),
    };
}

/// WATSUB EVAPR2V/EVAPR2W/EFLXR2/VFLXR2. Represented pore vapor is consumed
/// before liquid. Only EVAPR2W carries latent heat; total EVAPR2 carries the
/// donor-temperature sensible heat. Caps remain inside the residual.
fn vaporHeatTermsValue(context: ResidualContext, temperature_k: f64) VaporHeatTerms {
    const internal = internalVaporEquilibrium(context, temperature_k);
    const potential_factor = @exp(18.0 * context.surface_water_potential_megapascal /
        (8.3143 * temperature_k));
    const owner_pressure = context.surface_vapor_activity_fraction *
        saturationVaporPressureKpa(temperature_k) * potential_factor;
    const owner_pressure_derivative = owner_pressure *
        (5360.0 / (temperature_k * temperature_k) -
            18.0 * context.surface_water_potential_megapascal /
                (8.3143 * temperature_k * temperature_k));
    const equilibrium_owner_vapor_fraction = owner_pressure *
        context.vapor_fraction_conversion_k_per_kpa / temperature_k;
    const equilibrium_owner_vapor_fraction_derivative = context.vapor_fraction_conversion_k_per_kpa *
        (owner_pressure_derivative / temperature_k -
            owner_pressure / (temperature_k * temperature_k));
    const represented_owner_vapor = context.use_vapor_volume_fraction and
        context.owner_air_volume_m3_per_m2 > 0;
    const entry_vapor_m3_per_m2 = if (context.owner_vapor_water_equivalent_m3) |vapor_m3|
        if (context.phase) |phase_context|
            vapor_m3 / phase_context.horizontal_area_m2
        else
            context.owner_vapor_water_equivalent_m3_per_m2
    else
        context.owner_vapor_water_equivalent_m3_per_m2;
    const post_internal_vapor_m3_per_m2 = entry_vapor_m3_per_m2 +
        if (context.phase) |phase_context|
            internal.vapor_change_m3 / phase_context.horizontal_area_m2
        else
            0;
    const owner_vapor_fraction = if (represented_owner_vapor)
        post_internal_vapor_m3_per_m2 /
            context.owner_air_volume_m3_per_m2
    else
        equilibrium_owner_vapor_fraction;
    const owner_vapor_fraction_derivative = if (represented_owner_vapor)
        0
    else
        equilibrium_owner_vapor_fraction_derivative;
    const unlimited_water_rate = if (context.use_vapor_volume_fraction)
        context.vapor_conductance_m3_per_m2_h *
            (context.air_vapor_volume_fraction - owner_vapor_fraction)
    else
        context.latent_heat_conductance_megajoules_per_m2_h_kpa *
            (context.atmospheric_vapor_pressure_kpa - owner_pressure) /
            context.latent_heat_of_vaporization_megajoules_per_m3;
    const unlimited_water_rate_derivative = if (context.use_vapor_volume_fraction)
        -context.vapor_conductance_m3_per_m2_h * owner_vapor_fraction_derivative
    else
        -context.latent_heat_conductance_megajoules_per_m2_h_kpa * owner_pressure_derivative /
            context.latent_heat_of_vaporization_megajoules_per_m3;
    const maximum_vapor_evaporation_rate = post_internal_vapor_m3_per_m2 /
        context.time_step_hours;
    const vapor_limited = context.use_vapor_volume_fraction and
        unlimited_water_rate < -maximum_vapor_evaporation_rate;
    const vapor_water_rate = if (context.use_vapor_volume_fraction)
        @max(unlimited_water_rate, -maximum_vapor_evaporation_rate)
    else
        0;
    const vapor_water_rate_derivative = if (context.use_vapor_volume_fraction and !vapor_limited)
        unlimited_water_rate_derivative
    else
        0;
    const vapor_exhausted = context.use_vapor_volume_fraction and
        vapor_water_rate == -maximum_vapor_evaporation_rate;
    const liquid_remainder_rate = if (context.use_vapor_volume_fraction)
        unlimited_water_rate - vapor_water_rate
    else
        unlimited_water_rate;
    const liquid_remainder_rate_derivative = if (context.use_vapor_volume_fraction)
        unlimited_water_rate_derivative - vapor_water_rate_derivative
    else
        unlimited_water_rate_derivative;
    const post_phase_liquid_m3_per_m2 = if (context.phase != null) phase_liquid: {
        const phase_before_atmosphere = phaseContextAfterInternalVapor(context, temperature_k);
        const equilibrium = surfacePhaseEquilibrium(phase_before_atmosphere, temperature_k) catch
            break :phase_liquid std.math.nan(f64);
        break :phase_liquid equilibrium.liquid_water_m3 / phase_before_atmosphere.horizontal_area_m2;
    } else context.owner_liquid_water_m3_per_m2;
    const maximum_liquid_evaporation_rate = post_phase_liquid_m3_per_m2 /
        context.time_step_hours;
    const liquid_limited = liquid_remainder_rate < -maximum_liquid_evaporation_rate;
    const liquid_water_rate = if (liquid_limited)
        -maximum_liquid_evaporation_rate
    else
        liquid_remainder_rate;
    const liquid_water_rate_derivative = if (liquid_limited)
        0
    else
        liquid_remainder_rate_derivative;
    const liquid_exhausted = liquid_water_rate == -maximum_liquid_evaporation_rate;
    const total_water_rate = vapor_water_rate + liquid_water_rate;
    const total_water_rate_derivative = vapor_water_rate_derivative +
        liquid_water_rate_derivative;
    const latent = liquid_water_rate *
        context.latent_heat_of_vaporization_megajoules_per_m3;
    const latent_derivative = liquid_water_rate_derivative *
        context.latent_heat_of_vaporization_megajoules_per_m3;
    const condensation = total_water_rate >= 0;
    const donor_temperature = if (condensation) context.air_temperature_k else temperature_k;
    const sensible = total_water_rate * context.liquid_water_heat_capacity_megajoules_per_m3_k * donor_temperature;
    const sensible_derivative = context.liquid_water_heat_capacity_megajoules_per_m3_k *
        (total_water_rate_derivative * donor_temperature + if (condensation) 0 else total_water_rate);
    return .{
        .latent = latent,
        .sensible = sensible,
        .total = latent + sensible,
        .derivative = latent_derivative + sensible_derivative,
        .vapor_exhausted = vapor_exhausted,
        .liquid_exhausted = liquid_exhausted,
        .vapor_water_rate_m3_per_m2_h = vapor_water_rate,
        .liquid_water_rate_m3_per_m2_h = liquid_water_rate,
        .total_water_rate_m3_per_m2_h = total_water_rate,
    };
}

fn vaporHeatTerms(context: ResidualContext, temperature_k: f64) VaporHeatTerms {
    var terms = vaporHeatTermsValue(context, temperature_k);
    if (!context.use_vapor_volume_fraction) return terms;
    const step_k = std.math.cbrt(std.math.floatEps(f64)) *
        @max(1.0, @abs(temperature_k));
    terms.derivative = (vaporHeatTermsValue(context, temperature_k + step_k).total -
        vaporHeatTermsValue(context, temperature_k - step_k).total) / (2 * step_k);
    return terms;
}

fn vaporSensibleHeatFlux(
    latent_heat_flux_megajoules_per_m2: f64,
    air_temperature_k: f64,
    surface_temperature_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_vaporization_megajoules_per_m3: f64,
) !f64 {
    inline for (.{ latent_heat_flux_megajoules_per_m2, air_temperature_k, surface_temperature_k, liquid_water_heat_capacity_megajoules_per_m3_k, latent_heat_of_vaporization_megajoules_per_m3 }) |value|
        if (!std.math.isFinite(value))
            return error.NonFiniteSurfaceVaporSensibleHeatInput;
    if (air_temperature_k <= 0 or surface_temperature_k <= 0 or
        liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or
        latent_heat_of_vaporization_megajoules_per_m3 <= 0)
        return error.InvalidSurfaceVaporSensibleHeatInput;
    const water_flux_into_surface_m3_per_m2 =
        latent_heat_flux_megajoules_per_m2 / latent_heat_of_vaporization_megajoules_per_m3;
    const donor_temperature_k = if (water_flux_into_surface_m3_per_m2 >= 0)
        air_temperature_k
    else
        surface_temperature_k;
    const heat_flux_megajoules_per_m2 = water_flux_into_surface_m3_per_m2 *
        liquid_water_heat_capacity_megajoules_per_m3_k * donor_temperature_k;
    if (!std.math.isFinite(heat_flux_megajoules_per_m2))
        return error.NonFiniteSurfaceVaporSensibleHeatResult;
    return heat_flux_megajoules_per_m2;
}

test "litter vapor Newton term couples owner cap latent and donor heat" {
    const common: ResidualContext = .{
        .time_step_hours = 1,
        .absorbed_shortwave_megajoules_per_m2 = 0,
        .atmospheric_longwave_megajoules_per_m2 = 0,
        .air_temperature_k = 290,
        .ground_exposure_fraction = 1,
        .emissivity = 0,
        .sensible_heat_conductance_megajoules_per_m2_h_k = 0,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = 100,
        .atmospheric_vapor_pressure_kpa = 0,
        .surface_vapor_activity_fraction = 1,
        .surface_water_potential_megapascal = 0,
        .owner_liquid_water_m3_per_m2 = 0.002,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .latent_heat_of_vaporization_megajoules_per_m3 = 2465,
        .subsurface_temperature_k = 280,
        .previous_surface_temperature_k = 280,
        .conductive_heat_conductance_megajoules_per_m2_h_k = 0,
        .storage_heat_conductance_megajoules_per_m2_h_k = 1,
    };
    const limited = vaporHeatTerms(common, 300);
    try std.testing.expectEqual(@as(f64, -0.002 * 2465), limited.latent);
    try std.testing.expectApproxEqAbs(@as(f64, -0.002 * 4.19 * 300), limited.sensible, 1e-14);
    // The capped latent term is constant, but evaporated carrier water still
    // leaves at the candidate owner temperature inside Newton.
    try std.testing.expectApproxEqAbs(-0.002 * 4.19, limited.derivative, 1e-14);

    var dry = common;
    dry.owner_liquid_water_m3_per_m2 = 0;
    const dry_terms = vaporHeatTerms(dry, 300);
    try std.testing.expectEqual(@as(f64, 0), dry_terms.total);
    try std.testing.expectEqual(@as(f64, 0), dry_terms.derivative);
}

test "WATSUB litter atmospheric exchange debits vapor before latent liquid" {
    var context: ResidualContext = .{
        .time_step_hours = 1,
        .absorbed_shortwave_megajoules_per_m2 = 0,
        .atmospheric_longwave_megajoules_per_m2 = 0,
        .air_temperature_k = 290,
        .ground_exposure_fraction = 1,
        .emissivity = 0,
        .sensible_heat_conductance_megajoules_per_m2_h_k = 0,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = 0,
        .atmospheric_vapor_pressure_kpa = 0,
        .use_vapor_volume_fraction = true,
        .vapor_conductance_m3_per_m2_h = 1,
        .air_vapor_volume_fraction = 0,
        .vapor_fraction_conversion_k_per_kpa = 2.173e-3,
        .surface_vapor_activity_fraction = 1,
        .owner_air_volume_m3_per_m2 = 1,
        .owner_vapor_water_equivalent_m3_per_m2 = 0.01,
        .owner_liquid_water_m3_per_m2 = 0.02,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .latent_heat_of_vaporization_megajoules_per_m3 = 2465,
        .subsurface_temperature_k = 280,
        .previous_surface_temperature_k = 280,
        .conductive_heat_conductance_megajoules_per_m2_h_k = 0,
        .storage_heat_conductance_megajoules_per_m2_h_k = 1,
    };
    const vapor_only = vaporHeatTerms(context, 300);
    try std.testing.expectEqual(@as(f64, -0.01), vapor_only.vapor_water_rate_m3_per_m2_h);
    try std.testing.expect(vapor_only.vapor_exhausted);
    try std.testing.expect(!vapor_only.liquid_exhausted);
    try std.testing.expectEqual(@as(f64, 0), vapor_only.liquid_water_rate_m3_per_m2_h);
    try std.testing.expectEqual(@as(f64, 0), vapor_only.latent);
    try std.testing.expectApproxEqAbs(-0.01 * 4.19 * 300, vapor_only.sensible, 1e-14);

    context.vapor_conductance_m3_per_m2_h = 10;
    const exhausted = vaporHeatTerms(context, 300);
    try std.testing.expectEqual(@as(f64, -0.01), exhausted.vapor_water_rate_m3_per_m2_h);
    try std.testing.expectEqual(@as(f64, -0.02), exhausted.liquid_water_rate_m3_per_m2_h);
    try std.testing.expect(exhausted.vapor_exhausted);
    try std.testing.expect(exhausted.liquid_exhausted);
    try std.testing.expectApproxEqAbs(@as(f64, -0.02 * 2465), exhausted.latent, 1e-12);
    try std.testing.expectApproxEqAbs(-0.03 * 4.19 * 300, exhausted.sensible, 1e-12);

    context.air_vapor_volume_fraction = 0.02;
    context.vapor_conductance_m3_per_m2_h = 1;
    const condensation = vaporHeatTerms(context, 300);
    try std.testing.expectEqual(@as(f64, 0.01), condensation.vapor_water_rate_m3_per_m2_h);
    try std.testing.expectEqual(@as(f64, 0), condensation.liquid_water_rate_m3_per_m2_h);
    try std.testing.expectEqual(@as(f64, 0), condensation.latent);
}

test "exhausted litter vapor publishes an exact conservative inventory face" {
    const old_vapor_m3: f64 = 1.9511605890874306e-11;
    const internal_vapor_change_m3: f64 = 5.510168405073654e-12;
    const post_internal_vapor_m3 = old_vapor_m3 + internal_vapor_change_m3;
    const horizontal_area_m2: f64 = 9109.652910356466;
    const time_step_hours: f64 = 0.125;
    const capped_rate = -(old_vapor_m3 / horizontal_area_m2 +
        internal_vapor_change_m3 / horizontal_area_m2) / time_step_hours;
    const terms: VaporHeatTerms = .{
        .latent = 0,
        .sensible = 0,
        .total = 0,
        .derivative = 0,
        .vapor_exhausted = true,
        .liquid_exhausted = true,
        .vapor_water_rate_m3_per_m2_h = capped_rate,
        .liquid_water_rate_m3_per_m2_h = capped_rate,
        .total_water_rate_m3_per_m2_h = 2 * capped_rate,
    };
    const accepted_change_m3 = acceptedAtmosphericVaporChangeM3(
        terms,
        post_internal_vapor_m3,
        horizontal_area_m2,
        time_step_hours,
    );
    try std.testing.expectEqual(@as(f64, 0), post_internal_vapor_m3 + accepted_change_m3);
    try std.testing.expectEqual(post_internal_vapor_m3, -accepted_change_m3);
    const accepted_liquid_change_m3 = acceptedLiquidVaporChangeM3(
        terms,
        post_internal_vapor_m3,
        horizontal_area_m2,
        time_step_hours,
    );
    try std.testing.expectEqual(@as(f64, 0), post_internal_vapor_m3 + accepted_liquid_change_m3);
    try std.testing.expectEqual(post_internal_vapor_m3, -accepted_liquid_change_m3);
}

test "litter vapor non-exhaustion derivative matches centered difference" {
    const context: ResidualContext = .{
        .time_step_hours = 0.5,
        .absorbed_shortwave_megajoules_per_m2 = 0,
        .atmospheric_longwave_megajoules_per_m2 = 0,
        .air_temperature_k = 288,
        .ground_exposure_fraction = 1,
        .emissivity = 0,
        .sensible_heat_conductance_megajoules_per_m2_h_k = 0,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = 0.1,
        .atmospheric_vapor_pressure_kpa = 0.7,
        .surface_vapor_activity_fraction = 0.9,
        .surface_water_potential_megapascal = -0.5,
        .owner_liquid_water_m3_per_m2 = 1,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .latent_heat_of_vaporization_megajoules_per_m3 = 2465,
        .subsurface_temperature_k = 280,
        .previous_surface_temperature_k = 280,
        .conductive_heat_conductance_megajoules_per_m2_h_k = 0,
        .storage_heat_conductance_megajoules_per_m2_h_k = 1,
    };
    const temperature_k: f64 = 285;
    const step: f64 = 1e-4;
    const terms = vaporHeatTerms(context, temperature_k);
    const numerical = (vaporHeatTerms(context, temperature_k + step).total -
        vaporHeatTerms(context, temperature_k - step).total) / (2 * step);
    try std.testing.expectApproxEqRel(numerical, terms.derivative, 2e-8);
}

fn surfacePhaseEquilibrium(
    context: CellPhaseContext,
    temperature_k: f64,
) !phase_change.DallAmicoEquilibrium {
    const total_water_equivalent_m3 =
        context.initial_liquid_water_m3 +
        context.initial_ice_water_equivalent_m3;
    const total_water_content =
        total_water_equivalent_m3 / context.porous_medium_volume_m3;
    if (total_water_content <=
        context.parameters.residual_water_content_m3_per_m3)
    {
        return .{
            .depressed_melting_temperature_k = context.pure_water_melting_temperature_k,
            .liquid_pressure_head_m = 0,
            .liquid_water_m3 = total_water_equivalent_m3,
            .ice_water_equivalent_m3 = 0,
        };
    }
    const unfrozen_pressure_head_m =
        try context.parameters.pressureHeadAtWaterContent(
            std.math.clamp(
                total_water_content,
                context.parameters.residual_water_content_m3_per_m3,
                context.parameters.saturated_water_content_m3_per_m3,
            ),
        );
    const equilibrium = try phase_change.dallAmicoEquilibrium(.{
        .temperature_k = temperature_k,
        .total_water_equivalent_m3 = total_water_equivalent_m3,
        .porous_medium_volume_m3 = context.porous_medium_volume_m3,
        .unfrozen_pressure_head_m = unfrozen_pressure_head_m,
        .gravitational_water_potential_mpa_per_m = context.gravitational_water_potential_mpa_per_m,
        .latent_heat_of_fusion_megajoules_per_m3 = context.latent_heat_of_fusion_megajoules_per_m3,
        .pure_water_melting_temperature_k = context.pure_water_melting_temperature_k,
        .mualem_van_genuchten = context.parameters,
    });
    return limitPhaseChangeToAvailableEnergy(context, temperature_k, total_water_equivalent_m3, equilibrium);
}

/// WATSUB 3150--3156 rate limit. The Dall'Amico equilibrium answers "what split
/// would this temperature imply at equilibrium", but the oracle asks the different
/// question "how much phase change can the temperature deficit actually drive in
/// this step", with the available phase acting only as a cap. Applying the
/// equilibrium directly let the whole litter reservoir freeze in one hour at
/// `19.17x` the energy-permitted rate, which collapsed the litter water carrier by
/// `1.1e7` and made surface evaporation impossible. See EXEC-002 and EXEC-004.
///
/// This clamps the requested ice change to the energy limit. It is applied inside
/// `surfacePhaseEquilibrium` so the Newton residual, its derivative, and the final
/// writeback all see the same limited value and the solve stays consistent.
fn limitPhaseChangeToAvailableEnergy(
    context: CellPhaseContext,
    temperature_k: f64,
    total_water_equivalent_m3: f64,
    equilibrium: phase_change.DallAmicoEquilibrium,
) !phase_change.DallAmicoEquilibrium {
    const requested_ice_change_m3 =
        equilibrium.ice_water_equivalent_m3 - context.initial_ice_water_equivalent_m3;
    if (requested_ice_change_m3 == 0) return equilibrium;
    if (!std.math.isFinite(context.heat_capacity_megajoules_per_k) or
        context.heat_capacity_megajoules_per_k <= 0) return equilibrium;

    const limit = try freeze_thaw_energy_limit.apply(.{
        .temperature_k = temperature_k,
        .heat_capacity_megajoules_per_k = context.heat_capacity_megajoules_per_k,
        .liquid_water_m3 = context.initial_liquid_water_m3,
        .ice_water_equivalent_m3 = context.initial_ice_water_equivalent_m3,
        // The Dall'Amico solve already accounts for the depressed melting point
        // through the retention curve, so express the same depression as the
        // potential the energy limit expects.
        .water_potential_megapascal = context.water_potential_megapascal,
        .substep_energy_fraction = 1,
        .substep_mass_fraction = 1,
        .negligible_volume_m3 = 0,
    }, .{
        .latent_heat_of_fusion_megajoules_per_m3 = context.latent_heat_of_fusion_megajoules_per_m3,
        .freezing_point_depression_numerator = 9.0959e4,
        .freezing_temperature_coefficient = 6.2913e-3,
    });
    // `liquid_water_change_m3` is negative when freezing, so the permitted ice
    // change is its negation.
    const permitted_ice_change_m3 = -limit.liquid_water_change_m3;
    const limited_ice_change_m3 = if (requested_ice_change_m3 > 0)
        @min(requested_ice_change_m3, @max(0.0, permitted_ice_change_m3))
    else
        @max(requested_ice_change_m3, @min(0.0, permitted_ice_change_m3));
    const limited_ice_m3 = std.math.clamp(
        context.initial_ice_water_equivalent_m3 + limited_ice_change_m3,
        0,
        total_water_equivalent_m3,
    );
    if (!std.math.isFinite(limited_ice_m3)) return equilibrium;
    return .{
        .depressed_melting_temperature_k = equilibrium.depressed_melting_temperature_k,
        .liquid_pressure_head_m = equilibrium.liquid_pressure_head_m,
        .liquid_water_m3 = total_water_equivalent_m3 - limited_ice_m3,
        .ice_water_equivalent_m3 = limited_ice_m3,
    };
}

fn phaseHeatFlux(context: ResidualContext, temperature_k: f64) f64 {
    const phase = context.phase orelse return 0;
    const internal = internalVaporEquilibrium(context, temperature_k);
    const phase_after_vapor = phaseContextAfterInternalVapor(context, temperature_k);
    const equilibrium =
        surfacePhaseEquilibrium(phase_after_vapor, temperature_k) catch return std.math.nan(f64);
    const fusion_heat = phase.latent_heat_of_fusion_megajoules_per_m3 *
        (equilibrium.ice_water_equivalent_m3 -
            phase.initial_ice_water_equivalent_m3);
    return (internal.latent_heat_megajoules + fusion_heat) /
        phase.horizontal_area_m2 / context.time_step_hours;
}

fn phaseContextAfterInternalVapor(context: ResidualContext, temperature_k: f64) CellPhaseContext {
    var phase = context.phase.?;
    const internal = internalVaporEquilibrium(context, temperature_k);
    phase.initial_liquid_water_m3 = @max(
        0,
        phase.initial_liquid_water_m3 + internal.water_condensation_m3,
    );
    phase.porous_medium_volume_m3 = @max(
        phase.porous_medium_volume_m3,
        phase.initial_liquid_water_m3 + phase.initial_ice_water_equivalent_m3,
    );
    return phase;
}

fn phaseHeatDerivative(context: ResidualContext, temperature_k: f64) f64 {
    if (context.phase == null) return 0;
    // A centered first derivative has O(h^2 + eps/h) error, so cbrt(eps)
    // is the cancellation-safe scale. sqrt(eps) lost significant digits in
    // the nested Dall'Amico/retention solves and gave Newton a biased slope.
    const step_k = std.math.cbrt(std.math.floatEps(f64)) *
        @max(1.0, @abs(temperature_k));
    return (phaseHeatFlux(context, temperature_k + step_k) -
        phaseHeatFlux(context, temperature_k - step_k)) / (2 * step_k);
}

fn validateSurfacePhaseContext(
    context: SurfacePhaseContext,
    cell_count: usize,
) !void {
    if (context.liquid_water_m3.len != cell_count or
        context.ice_water_equivalent_m3.len != cell_count or
        context.retention_capacity_m3.len != cell_count or
        context.horizontal_area_m2.len != cell_count)
        return error.SurfaceTemperatureDimensionMismatch;
    inline for (.{
        context.residual_water_content_m3_per_m3,
        context.van_genuchten_alpha_per_m,
        context.van_genuchten_n,
        context.gravitational_water_potential_mpa_per_m,
        context.latent_heat_of_fusion_megajoules_per_m3,
        context.pure_water_melting_temperature_k,
        context.ice_heat_capacity_per_water_equivalent_m3_k,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteSurfacePhaseParameter;
    if (context.residual_water_content_m3_per_m3 < 0 or
        context.residual_water_content_m3_per_m3 >= 1 or
        context.van_genuchten_alpha_per_m <= 0 or
        context.van_genuchten_n <= 1 or
        context.gravitational_water_potential_mpa_per_m <= 0 or
        context.latent_heat_of_fusion_megajoules_per_m3 <= 0 or
        context.pure_water_melting_temperature_k <= 0 or
        context.ice_heat_capacity_per_water_equivalent_m3_k <= 0)
        return error.InvalidSurfacePhaseParameter;
    for (context.liquid_water_m3, context.ice_water_equivalent_m3, context.retention_capacity_m3, context.horizontal_area_m2) |liquid, ice, capacity, area| {
        if (!std.math.isFinite(liquid) or liquid < 0 or
            !std.math.isFinite(ice) or ice < 0 or
            !std.math.isFinite(capacity) or capacity < 0 or
            !std.math.isFinite(area) or area <= 0)
            return error.InvalidSurfacePhaseState;
    }
}

fn validateSurfaceAlbedoContext(
    context: SurfaceAlbedoContext,
    layer_count: usize,
    cell_count: usize,
) !void {
    if (context.matrix_bulk_volume_m3.len != layer_count or
        context.bulk_density_megagrams_per_m3.len != layer_count or
        context.dry_litter_albedo.len != cell_count or
        context.dry_litter_mass_megagrams.len != cell_count or
        context.litter_cover_fraction.len != cell_count)
        return error.SurfaceTemperatureDimensionMismatch;
    inline for (.{
        context.ice_density_megagrams_per_m3,
        context.phase_volume_absolute_tolerance_m3,
        context.phase_volume_relative_tolerance,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceAlbedoParameter;
    if (context.ice_density_megagrams_per_m3 <= 0 or
        context.phase_volume_absolute_tolerance_m3 < 0 or
        context.phase_volume_relative_tolerance < 0)
        return error.InvalidSurfaceAlbedoParameter;
    for (context.matrix_bulk_volume_m3, context.bulk_density_megagrams_per_m3) |volume, density|
        if (!std.math.isFinite(volume) or volume < 0 or
            !std.math.isFinite(density) or density < 0)
            return error.InvalidSurfaceAlbedoState;
    for (context.dry_litter_albedo, context.dry_litter_mass_megagrams, context.litter_cover_fraction) |albedo, mass, cover|
        if (!std.math.isFinite(albedo) or albedo < 0 or albedo > 1 or
            !std.math.isFinite(mass) or mass < 0 or
            !std.math.isFinite(cover) or cover < 0 or cover > 1)
            return error.InvalidSurfaceAlbedoState;
}

test "validated tile does not rescan or mutate a peer cell phase carrier" {
    const allocator = std.testing.allocator;
    const config = try SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 2, .tile_cells = 2 },
        .{
            .relative_tolerance = 1.0e-8,
            .absolute_tolerance = 1.0e-10,
            .max_nonlinear_iterations = 40,
        },
    );
    var grid = try GridState.init(allocator, config);
    defer grid.deinit();
    var atmosphere = try AtmosphericState.init(allocator, 2);
    defer atmosphere.deinit();
    var surface_energy = try SurfaceEnergyState.init(allocator, 2);
    defer surface_energy.deinit();
    var result = try State.init(allocator, 2);
    defer result.deinit();

    var ground_values = [_]f64{ 0, 0 };
    var ground_radiation_state: GroundRadiationState = .{
        .allocator = allocator,
        .cell_count = 2,
        .soil_albedo = ground_values[0..],
        .initial_snow_depth_m = ground_values[0..],
        .surface_albedo = ground_values[0..],
        .incident_shortwave_megajoules_per_m2 = ground_values[0..],
        .absorbed_shortwave_megajoules_per_m2 = ground_values[0..],
        .reflected_shortwave_megajoules_per_m2 = ground_values[0..],
        .incident_par_micromol_per_m2_per_s = ground_values[0..],
        .absorbed_par_micromol_per_m2_per_s = ground_values[0..],
        .reflected_par_micromol_per_m2_per_s = ground_values[0..],
    };
    var layer_thickness_m = [_]f64{ -1, 1 };
    var soil_values = [_]f64{ 1, 1 };
    var soil_thermal: SoilThermalState = .{
        .allocator = allocator,
        .cell_count = 2,
        .soil_layer_capacity = 1,
        .layer_volume_m3 = soil_values[0..],
        .layer_thickness_m = layer_thickness_m[0..],
        .porosity_fraction = soil_values[0..],
        .dry_solid_heat_capacity_megajoules_per_m3_k = soil_values[0..],
        .solid_thermal_conductivity_numerator_m_megajoules_per_h_k = soil_values[0..],
        .solid_thermal_conductivity_denominator = soil_values[0..],
        .total_heat_capacity_megajoules_per_m3_k = soil_values[0..],
        .thermal_conductivity_m_megajoules_per_h_k = soil_values[0..],
    };
    var air_temperature_k = [_]f64{ 280, 280 };
    var air_vapor_pressure_kpa = [_]f64{ 0, 0 };
    var external_heat_megajoules_per_m2 = [_]f64{ 0, 0 };
    var surface_heat_capacity_megajoules_per_k = [_]f64{ 1, 1 };
    var liquid_water_m3 = [_]f64{ 0.001, 0.001 };
    var ice_water_equivalent_m3 = [_]f64{ 0, 0 };
    var retention_capacity_m3 = [_]f64{ 0.01, 0.01 };
    var horizontal_area_m2 = [_]f64{ 1, 1 };
    var context: ApplyContext = .{
        .result = &result,
        .grid = &grid,
        .atmosphere = &atmosphere,
        .air_temperature_k = air_temperature_k[0..],
        .air_vapor_pressure_kpa = air_vapor_pressure_kpa[0..],
        .ground_radiation = &ground_radiation_state,
        .surface_energy = &surface_energy,
        .soil_thermal = &soil_thermal,
        .surface_heat_capacity_megajoules_per_k = surface_heat_capacity_megajoules_per_k[0..],
        .exposure = null,
        .external_heat_megajoules_per_m2 = external_heat_megajoules_per_m2[0..],
        .surface_phase = .{
            .liquid_water_m3 = liquid_water_m3[0..],
            .ice_water_equivalent_m3 = ice_water_equivalent_m3[0..],
            .retention_capacity_m3 = retention_capacity_m3[0..],
            .horizontal_area_m2 = horizontal_area_m2[0..],
            .residual_water_content_m3_per_m3 = 0,
            .van_genuchten_alpha_per_m = 400,
            .van_genuchten_n = 2.5,
            .gravitational_water_potential_mpa_per_m = 0.0098,
            .latent_heat_of_fusion_megajoules_per_m3 = 333,
            .pure_water_melting_temperature_k = 273.15,
            .ice_heat_capacity_per_water_equivalent_m3_k = 1.9274 / 0.917,
        },
        .settings = .{
            .sensible_heat_conductance_megajoules_per_m2_h_k = 1,
            .latent_heat_conductance_megajoules_per_m2_h_kpa = 0,
            .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
            .latent_heat_of_vaporization_megajoules_per_m3 = 2465,
            .surface_vapor_activity_fraction = 0,
            .timestep_hours = 1,
            .minimum_temperature_k = 200,
            .maximum_temperature_k = 350,
            .solver_options = .{ .residual_scale = 1 },
            .energy_conservation_absolute_tolerance_megajoules_per_m2_h = 0,
            .energy_conservation_relative_tolerance = 1.0e-9,
        },
    };

    // The coordinator validates the complete shared carrier while it is
    // quiescent. Poisoning a peer afterward models that peer publishing while
    // this worker owns cell 0; the worker must reach its local error instead
    // of racing through a second whole-grid validation pass.
    try validateApplyContext(&context);
    liquid_water_m3[1] = std.math.nan(f64);
    @memset(result.liquid_water_change_m3, 37);
    try std.testing.expectError(
        error.InvalidSurfaceSoilLayerThickness,
        applyValidatedTile(&context, .{ .first = 0, .end = 1 }),
    );
    try std.testing.expectEqual(@as(f64, 0), result.liquid_water_change_m3[0]);
    try std.testing.expectEqual(@as(f64, 37), result.liquid_water_change_m3[1]);
    try std.testing.expect(std.math.isNan(liquid_water_m3[1]));
}

fn residualScale(context: ResidualContext, temperature_k: f64) f64 {
    const downward_longwave = context.atmospheric_longwave_megajoules_per_m2 * context.ground_exposure_fraction;
    const emitted_longwave = context.emissivity * 2.04e-10 * std.math.pow(f64, temperature_k, 4) * context.ground_exposure_fraction;
    const sensible_heat = context.sensible_heat_conductance_megajoules_per_m2_h_k * (context.air_temperature_k - temperature_k);
    const vapor_heat = vaporHeatTerms(context, temperature_k);
    const conductive_heat = context.conductive_heat_conductance_megajoules_per_m2_h_k * (context.subsurface_temperature_k - temperature_k);
    const storage_heat = surfaceStorageHeatFlux(context, temperature_k);
    const phase_heat = phaseHeatFlux(context, temperature_k);
    return @max(1.0e-12, @abs(context.absorbed_shortwave_megajoules_per_m2) + @abs(context.external_heat_megajoules_per_m2) + @abs(downward_longwave) + @abs(emitted_longwave) + @abs(sensible_heat) + @abs(vapor_heat.latent) + @abs(vapor_heat.sensible) + @abs(conductive_heat) + @abs(storage_heat) + @abs(phase_heat));
}

/// Activity scale matching the directional owners used by the local surface
/// conservation ledger.  Radiation, sensible heat, and vapor heat form one
/// atmospheric boundary exchange; litter-soil conduction, delayed internal
/// heat, and phase heat are independent transfer/production lanes.  Storage is
/// the left-hand side of the identity and is deliberately not throughput.
fn conservationResidualScale(context: ResidualContext, temperature_k: f64) f64 {
    const downward_longwave = context.atmospheric_longwave_megajoules_per_m2 *
        context.ground_exposure_fraction;
    const emitted_longwave = context.emissivity * 2.04e-10 *
        std.math.pow(f64, temperature_k, 4) * context.ground_exposure_fraction;
    const sensible_heat = context.sensible_heat_conductance_megajoules_per_m2_h_k *
        (context.air_temperature_k - temperature_k);
    const atmospheric_heat = context.absorbed_shortwave_megajoules_per_m2 +
        downward_longwave - emitted_longwave + sensible_heat +
        vaporHeatTerms(context, temperature_k).total;
    const conductive_heat = context.conductive_heat_conductance_megajoules_per_m2_h_k *
        (context.subsurface_temperature_k - temperature_k);
    const phase_heat = phaseHeatFlux(context, temperature_k);
    return @max(
        1.0e-12,
        @abs(atmospheric_heat) + @abs(context.external_heat_megajoules_per_m2) +
            @abs(conductive_heat) + @abs(phase_heat),
    );
}

const AcceptedSolve = struct {
    solved: numerics.SolveResult,
    nonlinear_tolerance_megajoules_per_m2: f64,
    conservation_tolerance_megajoules_per_m2: f64,
    residual_has_adjacent_root_certificate: bool,
    residual_accepted_by_conservation_ceiling: bool,
};

const RepresentableRoot = struct {
    root: f64,
    residual: f64,
};

/// Certify that the continuous surface-energy residual changes sign between
/// two adjacent floating-point temperatures.  This is an arithmetic
/// representability proof, not a wider physical residual tolerance: no f64
/// coordinate exists inside the returned bracket.
fn nearestRepresentableRootCertificate(
    context: ResidualContext,
    lower_bound_k: f64,
    upper_bound_k: f64,
    candidate_root_k: f64,
    candidate_residual: f64,
) ?RepresentableRoot {
    if (!std.math.isFinite(candidate_root_k) or
        !std.math.isFinite(candidate_residual) or
        candidate_root_k < lower_bound_k or candidate_root_k > upper_bound_k)
        return null;

    for ([_]f64{ lower_bound_k, upper_bound_k }) |toward| {
        const neighbor = std.math.nextAfter(f64, candidate_root_k, toward);
        if (neighbor == candidate_root_k or
            neighbor < lower_bound_k or neighbor > upper_bound_k)
            continue;
        const neighbor_residual = residual(context, neighbor);
        if (!std.math.isFinite(neighbor_residual)) continue;
        if (neighbor_residual == 0 or
            std.math.signbit(neighbor_residual) != std.math.signbit(candidate_residual))
        {
            if (@abs(neighbor_residual) < @abs(candidate_residual))
                return .{ .root = neighbor, .residual = neighbor_residual };
            return .{ .root = candidate_root_k, .residual = candidate_residual };
        }
    }
    return null;
}

test "surface root certificate accepts only an adjacent floating-point sign bracket" {
    const candidate_k: f64 = 300;
    const upper_neighbor_k = std.math.nextAfter(
        f64,
        candidate_k,
        std.math.inf(f64),
    );
    const context: ResidualContext = .{
        .absorbed_shortwave_megajoules_per_m2 = 0,
        .atmospheric_longwave_megajoules_per_m2 = 0,
        .air_temperature_k = candidate_k,
        .ground_exposure_fraction = 0,
        .emissivity = 0,
        .sensible_heat_conductance_megajoules_per_m2_h_k = 0,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = 0,
        .atmospheric_vapor_pressure_kpa = 0,
        .surface_vapor_activity_fraction = 0,
        .subsurface_temperature_k = candidate_k,
        .previous_surface_temperature_k = candidate_k,
        .conductive_heat_conductance_megajoules_per_m2_h_k = 0,
        .storage_heat_conductance_megajoules_per_m2_h_k = 1,
        // The continuous root is exactly halfway between `candidate_k` and
        // its next representable neighbor.
        .external_heat_megajoules_per_m2 = 0x1p-45,
    };
    const candidate_residual = residual(context, candidate_k);
    const neighbor_residual = residual(context, upper_neighbor_k);
    try std.testing.expect(candidate_residual > 0);
    try std.testing.expect(neighbor_residual < 0);
    try std.testing.expectEqual(
        upper_neighbor_k,
        std.math.nextAfter(f64, candidate_k, upper_neighbor_k),
    );

    const certified = nearestRepresentableRootCertificate(
        context,
        299,
        301,
        candidate_k,
        candidate_residual,
    ) orelse return error.MissingAdjacentRepresentableRootCertificate;
    try std.testing.expect(
        certified.root == candidate_k or certified.root == upper_neighbor_k,
    );
    try std.testing.expectEqual(residual(context, certified.root), certified.residual);

    // Moving the bound onto the candidate removes the opposite-sign neighbor;
    // a tolerance-only acceptance must not be manufactured.
    try std.testing.expect(nearestRepresentableRootCertificate(
        context,
        299,
        candidate_k,
        candidate_k,
        candidate_residual,
    ) == null);
}

test "surface convergence audit preserves solver acceptance provenance" {
    const observed_residual = 6.330835993261952e-15;
    const nonlinear_tolerance = 4.31729138114292e-16;
    try std.testing.expect(!residualAcceptanceIsValid(
        observed_residual,
        nonlinear_tolerance,
        1.0e-12,
        false,
        false,
    ));
    try std.testing.expect(residualAcceptanceIsValid(
        observed_residual,
        nonlinear_tolerance,
        1.0e-12,
        true,
        false,
    ));
    try std.testing.expect(residualAcceptanceIsValid(
        observed_residual,
        nonlinear_tolerance,
        1.0e-12,
        false,
        true,
    ));
    // The ceiling provenance cannot bypass its own physical closure bound.
    try std.testing.expect(!residualAcceptanceIsValid(
        observed_residual,
        nonlinear_tolerance,
        1.0e-16,
        false,
        true,
    ));
}

test "surface refinement reports an adjacent-float acceptance certificate" {
    const candidate_k: f64 = 300;
    const context: ResidualContext = .{
        .absorbed_shortwave_megajoules_per_m2 = 0,
        .atmospheric_longwave_megajoules_per_m2 = 0,
        .air_temperature_k = candidate_k,
        .ground_exposure_fraction = 0,
        .emissivity = 0,
        .sensible_heat_conductance_megajoules_per_m2_h_k = 0,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = 0,
        .atmospheric_vapor_pressure_kpa = 0,
        .surface_vapor_activity_fraction = 0,
        .subsurface_temperature_k = candidate_k,
        .previous_surface_temperature_k = candidate_k,
        .conductive_heat_conductance_megajoules_per_m2_h_k = 0,
        .storage_heat_conductance_megajoules_per_m2_h_k = 1,
        .external_heat_megajoules_per_m2 = 0x1p-45,
    };
    const accepted = try solveWithConservationRefinement(
        context,
        .{
            .sensible_heat_conductance_megajoules_per_m2_h_k = 0,
            .latent_heat_conductance_megajoules_per_m2_h_kpa = 0,
            .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
            .latent_heat_of_vaporization_megajoules_per_m3 = 2465,
            .surface_vapor_activity_fraction = 0,
            .timestep_hours = 1,
            .minimum_temperature_k = 299,
            .maximum_temperature_k = 301,
            .solver_options = .{
                .relative_tolerance = 1.0e-16,
                .residual_scale = 1,
                .max_iterations = 10,
                .accept_nearest_representable_root = true,
            },
            .energy_conservation_absolute_tolerance_megajoules_per_m2_h = 0,
            .energy_conservation_relative_tolerance = 1.0e-16,
        },
        299,
        301,
        candidate_k,
    );
    try std.testing.expect(accepted.residual_has_adjacent_root_certificate);
    try std.testing.expect(@abs(accepted.solved.residual) >
        accepted.nonlinear_tolerance_megajoules_per_m2);
}

/// First solve under the process nonlinear criterion.  If that converged root
/// is not accurate enough for the independently scaled physical energy
/// closure, continue from the same root under the conservation criterion.
/// Both passes share one hard nonlinear-attempt budget, so refinement can
/// never multiply the user's `max_iterations` ceiling.
fn solveWithConservationRefinement(
    residual_context: ResidualContext,
    settings: Settings,
    lower_bound_k: f64,
    upper_bound_k: f64,
    initial_temperature_k: f64,
) !AcceptedSolve {
    var owned_budget = try numerics.NonlinearBudget.init(settings.solver_options.max_iterations);
    var nonlinear_options = settings.solver_options;
    nonlinear_options.residual_scale = residualScale(residual_context, initial_temperature_k);
    nonlinear_options.safeguard_with_bracket = true;
    if (nonlinear_options.shared_budget == null)
        nonlinear_options.shared_budget = &owned_budget;
    const nonlinear_tolerance = numerics.convergenceTolerance(nonlinear_options);

    var active_options = nonlinear_options;
    var current_temperature_k = initial_temperature_k;
    var total_iterations: u16 = 0;
    var total_newton_steps: u16 = 0;
    var total_anderson_steps: u16 = 0;
    var last_iterate: numerics.SolveResult = undefined;
    while (true) {
        active_options.last_iterate_on_failure = if (settings.accept_physically_conserved_ceiling) &last_iterate else null;
        const attempt = numerics.newtonPicard(
            residual_context,
            residual,
            derivative,
            picard,
            lower_bound_k,
            upper_bound_k,
            current_temperature_k,
            active_options,
        ) catch |err| {
            switch (err) {
                error.NewtonPicardDiverged, error.NewtonPicardStagnated, error.NewtonPicardDidNotConverge => {
                    if (!settings.accept_physically_conserved_ceiling) return err;
                    var recovery_options = settings.solver_options;
                    recovery_options.absolute_tolerance = settings.energy_conservation_absolute_tolerance_megajoules_per_m2_h;
                    recovery_options.relative_tolerance = settings.energy_conservation_relative_tolerance;
                    recovery_options.residual_scale = conservationResidualScale(residual_context, last_iterate.root);
                    const recovery_conservation_tolerance = numerics.convergenceTolerance(recovery_options);
                    var recovered = last_iterate;
                    // Failure retention can select an uncommitted line-search
                    // trial. Reprice it at the physical gate; the captured
                    // merit is not an independent conservation certificate.
                    recovered.residual = residual(residual_context, recovered.root);
                    if (!std.math.isFinite(recovered.residual)) return err;
                    var residual_has_adjacent_root_certificate = false;
                    if (@abs(recovered.residual) > recovery_conservation_tolerance) {
                        if (!settings.solver_options.accept_nearest_representable_root) return err;
                        const certified = nearestRepresentableRootCertificate(
                            residual_context,
                            lower_bound_k,
                            upper_bound_k,
                            recovered.root,
                            recovered.residual,
                        ) orelse return err;
                        recovered.root = certified.root;
                        recovered.residual = certified.residual;
                        residual_has_adjacent_root_certificate = true;
                    }
                    return .{
                        .solved = .{
                            .root = recovered.root,
                            .residual = recovered.residual,
                            .iterations = try std.math.add(u16, total_iterations, recovered.iterations),
                            .newton_raphson_steps = try std.math.add(u16, total_newton_steps, recovered.newton_raphson_steps),
                            .picard_steps = try std.math.add(u16, total_anderson_steps, recovered.anderson_steps),
                            .anderson_steps = try std.math.add(u16, total_anderson_steps, recovered.anderson_steps),
                        },
                        .nonlinear_tolerance_megajoules_per_m2 = nonlinear_tolerance,
                        .conservation_tolerance_megajoules_per_m2 = recovery_conservation_tolerance,
                        .residual_has_adjacent_root_certificate = residual_has_adjacent_root_certificate,
                        .residual_accepted_by_conservation_ceiling = !residual_has_adjacent_root_certificate,
                    };
                },
                else => return err,
            }
        };
        total_iterations = try std.math.add(u16, total_iterations, attempt.iterations);
        total_newton_steps = try std.math.add(u16, total_newton_steps, attempt.newton_raphson_steps);
        total_anderson_steps = try std.math.add(u16, total_anderson_steps, attempt.anderson_steps);

        var conservation_options = settings.solver_options;
        conservation_options.absolute_tolerance =
            settings.energy_conservation_absolute_tolerance_megajoules_per_m2_h;
        conservation_options.relative_tolerance =
            settings.energy_conservation_relative_tolerance;
        conservation_options.residual_scale = conservationResidualScale(
            residual_context,
            attempt.root,
        );
        conservation_options.safeguard_with_bracket = true;
        conservation_options.shared_budget = nonlinear_options.shared_budget;
        const conservation_tolerance = numerics.convergenceTolerance(conservation_options);
        const inside_both_tolerances = @abs(attempt.residual) <= nonlinear_tolerance and
            @abs(attempt.residual) <= conservation_tolerance;
        const certified = if (!inside_both_tolerances and
            settings.solver_options.accept_nearest_representable_root)
            nearestRepresentableRootCertificate(
                residual_context,
                lower_bound_k,
                upper_bound_k,
                attempt.root,
                attempt.residual,
            )
        else
            null;
        if (inside_both_tolerances or certified != null) {
            var solved = attempt;
            if (certified) |representable| {
                solved.root = representable.root;
                solved.residual = representable.residual;
            }
            solved.iterations = total_iterations;
            solved.newton_raphson_steps = total_newton_steps;
            solved.picard_steps = total_anderson_steps;
            solved.anderson_steps = total_anderson_steps;
            return .{
                .solved = solved,
                .nonlinear_tolerance_megajoules_per_m2 = nonlinear_tolerance,
                .conservation_tolerance_megajoules_per_m2 = conservation_tolerance,
                .residual_has_adjacent_root_certificate = certified != null,
                .residual_accepted_by_conservation_ceiling = false,
            };
        }

        // The broad nonlinear gate has already converged.  A subsequent pass
        // changes only root accuracy for this identical residual equation.
        current_temperature_k = attempt.root;
        active_options = conservation_options;
    }
}

fn validateSettings(settings: Settings) !void {
    if (!std.math.isFinite(settings.sensible_heat_conductance_megajoules_per_m2_h_k) or settings.sensible_heat_conductance_megajoules_per_m2_h_k < 0 or !std.math.isFinite(settings.latent_heat_conductance_megajoules_per_m2_h_kpa) or settings.latent_heat_conductance_megajoules_per_m2_h_kpa < 0 or !std.math.isFinite(settings.liquid_water_heat_capacity_megajoules_per_m3_k) or settings.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or !std.math.isFinite(settings.latent_heat_of_vaporization_megajoules_per_m3) or settings.latent_heat_of_vaporization_megajoules_per_m3 <= 0 or !std.math.isFinite(settings.surface_vapor_activity_fraction) or settings.surface_vapor_activity_fraction < 0 or settings.surface_vapor_activity_fraction > 1 or !std.math.isFinite(settings.timestep_hours) or settings.timestep_hours <= 0 or !std.math.isFinite(settings.minimum_temperature_k) or !std.math.isFinite(settings.maximum_temperature_k) or settings.minimum_temperature_k <= 0 or settings.minimum_temperature_k >= settings.maximum_temperature_k or !std.math.isFinite(settings.energy_conservation_absolute_tolerance_megajoules_per_m2_h) or settings.energy_conservation_absolute_tolerance_megajoules_per_m2_h < 0 or !std.math.isFinite(settings.energy_conservation_relative_tolerance) or settings.energy_conservation_relative_tolerance <= 0) return error.InvalidSurfaceTemperatureSettings;
}

test "hybrid Newton closes radiative sensible surface balance" {
    const context: ResidualContext = .{ .absorbed_shortwave_megajoules_per_m2 = 1.2, .atmospheric_longwave_megajoules_per_m2 = 0.9, .air_temperature_k = 285, .subsurface_temperature_k = 280, .previous_surface_temperature_k = 285, .ground_exposure_fraction = 1, .emissivity = 0.97, .sensible_heat_conductance_megajoules_per_m2_h_k = 0.43, .latent_heat_conductance_megajoules_per_m2_h_kpa = 0.1, .conductive_heat_conductance_megajoules_per_m2_h_k = 0.1, .storage_heat_conductance_megajoules_per_m2_h_k = 0.2, .atmospheric_vapor_pressure_kpa = 1.0, .surface_vapor_activity_fraction = 1.0 };
    // Same energy-balance scale the production path uses: the summed competing
    // flux magnitudes in MJ m-2 at the starting temperature.
    const solved = try numerics.newtonPicard(context, residual, derivative, picard, 173.15, 373.15, 285, .{ .residual_scale = residualScale(context, 285) });
    try std.testing.expect(@abs(solved.residual) < 1.0e-7);
    try std.testing.expect(solved.root > 285);
    try std.testing.expect(solved.newton_raphson_steps > 0);
}

test "surface conservation refinement shares the nonlinear hard ceiling" {
    const context: ResidualContext = .{
        .absorbed_shortwave_megajoules_per_m2 = 1.2,
        .atmospheric_longwave_megajoules_per_m2 = 0.9,
        .air_temperature_k = 285,
        .subsurface_temperature_k = 280,
        .previous_surface_temperature_k = 285,
        .ground_exposure_fraction = 1,
        .emissivity = 0.97,
        .sensible_heat_conductance_megajoules_per_m2_h_k = 0.43,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = 0.1,
        .conductive_heat_conductance_megajoules_per_m2_h_k = 0.1,
        .storage_heat_conductance_megajoules_per_m2_h_k = 0.2,
        .atmospheric_vapor_pressure_kpa = 1.0,
        .surface_vapor_activity_fraction = 1.0,
    };
    const max_iterations: u16 = 20;
    const accepted = try solveWithConservationRefinement(
        context,
        .{
            .sensible_heat_conductance_megajoules_per_m2_h_k = 0.43,
            .latent_heat_conductance_megajoules_per_m2_h_kpa = 0.1,
            .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
            .latent_heat_of_vaporization_megajoules_per_m3 = 2465,
            .surface_vapor_activity_fraction = 1,
            .timestep_hours = 1,
            .minimum_temperature_k = 173.15,
            .maximum_temperature_k = 373.15,
            // Deliberately broad nonlinear convergence; physical closure is
            // evaluated and refined independently below it.
            .solver_options = .{
                .relative_tolerance = 1.0e-3,
                .residual_scale = 1,
                .max_iterations = max_iterations,
            },
            .energy_conservation_absolute_tolerance_megajoules_per_m2_h = 0,
            .energy_conservation_relative_tolerance = 1.0e-10,
        },
        173.15,
        373.15,
        285,
    );
    try std.testing.expect(@abs(accepted.solved.residual) <=
        accepted.nonlinear_tolerance_megajoules_per_m2);
    try std.testing.expect(@abs(accepted.solved.residual) <=
        accepted.conservation_tolerance_megajoules_per_m2);
    try std.testing.expect(accepted.solved.iterations <= max_iterations);
    try std.testing.expect(accepted.solved.newton_raphson_steps +
        accepted.solved.anderson_steps <= accepted.solved.iterations);
}

const MonotonicCoolingResult = struct {
    same_sign_count: u32,
    opposite_sign_count: u32,
    extensive_absolute_total_mj: f64,
    first_conservation_tolerance_megajoules_per_m2: f64,
    last_conservation_tolerance_megajoules_per_m2: f64,
    tolerance_ever_decreased: bool,
};

fn runMonotonicCoolingSubsteps(accept_nearest_representable_root: bool) !MonotonicCoolingResult {
    return runMonotonicCoolingSubstepsScaled(accept_nearest_representable_root, 1.0);
}

/// `inner_tolerance_scale` divides the per-substep
/// `energy_conservation_relative_tolerance` (candidate fix #2: tighten the
/// INNER Newton acceptance proportionally to substep_count, rather than
/// loosening the OUTER ledger check -- the outer check's non-scaling design
/// is confirmed intentional by its own "rejects same-sign accumulation"
/// test and must not be touched).
fn runMonotonicCoolingSubstepsScaled(accept_nearest_representable_root: bool, inner_tolerance_scale: f64) !MonotonicCoolingResult {
    const substep_count: u16 = 16;
    const time_step_hours: f64 = 1.0 / @as(f64, @floatFromInt(substep_count));
    var surface_temperature_k: f64 = 260;
    var same_sign_count: u32 = 0;
    var opposite_sign_count: u32 = 0;
    var extensive_absolute_total_mj: f64 = 0;
    var first_sign: ?bool = null;
    var first_conservation_tolerance_megajoules_per_m2: f64 = undefined;
    var last_conservation_tolerance_megajoules_per_m2: f64 = undefined;
    var tolerance_ever_decreased = false;
    for (0..substep_count) |step| {
        // A sustained, deepening cold event: air temperature keeps dropping
        // every substep, exactly like a real multi-hour cold snap forcing
        // the recovery ladder into ever-finer substeps.
        const air_temperature_k: f64 = 260 - 3.0 * @as(f64, @floatFromInt(step + 1));
        const context: ResidualContext = .{
            .absorbed_shortwave_megajoules_per_m2 = 0,
            .atmospheric_longwave_megajoules_per_m2 = 0.3,
            .air_temperature_k = air_temperature_k,
            .subsurface_temperature_k = 265,
            .previous_surface_temperature_k = surface_temperature_k,
            .ground_exposure_fraction = 1,
            .emissivity = 0.97,
            .sensible_heat_conductance_megajoules_per_m2_h_k = 0.43,
            .latent_heat_conductance_megajoules_per_m2_h_kpa = 0,
            .conductive_heat_conductance_megajoules_per_m2_h_k = 0.1,
            .storage_heat_conductance_megajoules_per_m2_h_k = 0.2,
            .atmospheric_vapor_pressure_kpa = 0.05,
            .surface_vapor_activity_fraction = 0,
        };
        const accepted = try solveWithConservationRefinement(
            context,
            .{
                .sensible_heat_conductance_megajoules_per_m2_h_k = 0.43,
                .latent_heat_conductance_megajoules_per_m2_h_kpa = 0,
                .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
                .latent_heat_of_vaporization_megajoules_per_m3 = 2465,
                .surface_vapor_activity_fraction = 0,
                .timestep_hours = time_step_hours,
                .minimum_temperature_k = 173.15,
                .maximum_temperature_k = 373.15,
                .solver_options = .{
                    .relative_tolerance = 1.0e-8,
                    .residual_scale = 1,
                    .max_iterations = 40,
                    .accept_nearest_representable_root = accept_nearest_representable_root,
                },
                .energy_conservation_absolute_tolerance_megajoules_per_m2_h = 0,
                .energy_conservation_relative_tolerance = 1.0e-9 * inner_tolerance_scale,
            },
            173.15,
            373.15,
            surface_temperature_k,
        );
        // Each substep's own accepted residual is comfortably inside its
        // own reported tolerance -- this is not a case of the solver
        // ignoring its own acceptance band.
        try std.testing.expect(@abs(accepted.solved.residual) <=
            accepted.conservation_tolerance_megajoules_per_m2);
        const sign = accepted.solved.residual < 0;
        if (first_sign == null) first_sign = sign;
        if (sign == first_sign.?) same_sign_count += 1 else opposite_sign_count += 1;
        extensive_absolute_total_mj += @abs(accepted.solved.residual) * time_step_hours;
        if (step == 0) first_conservation_tolerance_megajoules_per_m2 = accepted.conservation_tolerance_megajoules_per_m2;
        if (step > 0 and accepted.conservation_tolerance_megajoules_per_m2 < last_conservation_tolerance_megajoules_per_m2)
            tolerance_ever_decreased = true;
        last_conservation_tolerance_megajoules_per_m2 = accepted.conservation_tolerance_megajoules_per_m2;
        surface_temperature_k = accepted.solved.root;
    }
    return .{
        .same_sign_count = same_sign_count,
        .opposite_sign_count = opposite_sign_count,
        .extensive_absolute_total_mj = extensive_absolute_total_mj,
        .first_conservation_tolerance_megajoules_per_m2 = first_conservation_tolerance_megajoules_per_m2,
        .last_conservation_tolerance_megajoules_per_m2 = last_conservation_tolerance_megajoules_per_m2,
        .tolerance_ever_decreased = tolerance_ever_decreased,
    };
}

test "monotonic cooling across many substeps produces same-signed, linearly-accumulating residuals within each substep's own tolerance" {
    // REAL-DECK-HOUR-11-FATAL-STAGNATION-001 / MASS-BALANCE-HEAT-FLOOR-DECK-EDIT-001
    // (2026-09-04): synthetic, fast (no real deck needed) reproduction of
    // the hypothesized mechanism behind the real captured hour-12 defect --
    // accept-on-first-crossing Newton, applied to a sustained one-directional
    // cooling trend across many substeps, should accept a same-signed
    // residual every time and their extensive sum should grow roughly
    // linearly with substep count, even though each individual substep is
    // comfortably inside its own reported tolerance.
    const result = try runMonotonicCoolingSubsteps(false);
    // The core claim: under a sustained one-directional trend, the
    // accept-on-first-crossing rule produces overwhelmingly same-signed
    // residuals, not a roughly-even random split.
    try std.testing.expect(result.same_sign_count >= 16 - 1);
    try std.testing.expect(result.opposite_sign_count <= 1);
    // Reconciles a real-deck observation from the same investigation:
    // `energy_conservation_tolerance_mj_m2` was captured GROWING (not
    // shrinking) across the real hour-12 substep sequence, which did not
    // fit the "per-substep tolerance should shrink with substep_count"
    // half of candidate fix #2 cleanly. Confirmed here for a physically
    // sensible, non-buggy reason: `subsurface_temperature_k` stays fixed
    // while the surface keeps cooling, so the conductive-heat
    // differential -- and therefore `conservationResidualScale`, the
    // activity this tolerance scales against -- legitimately grows as
    // the cold event deepens. The tolerance growing is real physics, not
    // evidence against dt-scaling or a hidden bug.
    try std.testing.expect(!result.tolerance_ever_decreased);
    try std.testing.expect(result.last_conservation_tolerance_megajoules_per_m2 >
        result.first_conservation_tolerance_megajoules_per_m2);
}

test "candidate fix #2 (tighten inner tolerance by substep_count) is ALSO ruled out -- it only works by chasing machine-precision residuals" {
    // Candidate fix #2, correctly framed to avoid touching the outer
    // ledger check's already-validated design: tighten the INNER
    // per-substep `energy_conservation_relative_tolerance` proportionally
    // to substep_count, mirroring how this same outer check's own
    // roundoff_allowance already scales with substep_count.
    //
    // Measured result: a modest, principled 16x tightening (matching
    // substep_count) has EXACTLY ZERO effect (bit-for-bit identical
    // accumulated total to the untouched baseline) -- because
    // `solveWithConservationRefinement`'s FIRST pass already accepts
    // under the separate, untouched `solver_options.relative_tolerance`
    // (the primary nonlinear criterion, ~1e-8 scale here) before the
    // conservation-refinement second pass, where
    // `energy_conservation_relative_tolerance` actually matters, is ever
    // reached. Only a wildly unreasonable 1e6x tightening produces any
    // measurable change at all, and when it does, the accepted residuals
    // collapse to representable-precision noise (~1e-14 to 1e-15 MJ,
    // signs no longer even consistently same-signed -- confirmed via a
    // temporary debug print before this assertion was written) --
    // exactly the "chasing residuals toward 1e-10/1e-11" pattern item #4
    // of the physical-acceptance goal explicitly names as wasteful, just
    // taken further. **Neither candidate fix is compatible with the
    // goal's own stated philosophy: #1 does not work at any scale, #2
    // only works by doing the exact thing the goal says not to do.**
    const baseline = try runMonotonicCoolingSubstepsScaled(false, 1.0);
    const modestly_scaled = try runMonotonicCoolingSubstepsScaled(false, 1.0 / 16.0);
    try std.testing.expectEqual(baseline.extensive_absolute_total_mj, modestly_scaled.extensive_absolute_total_mj);
}

test "accept_nearest_representable_root does NOT fix the same-sign accumulation -- candidate fix #1 ruled out empirically" {
    // Candidate fix #1 from the same investigation, tested safely against
    // the synthetic fixture before ever touching production. Hypothesis
    // was that symmetrizing Newton's acceptance (stop at the nearest
    // representable root within the safeguarded bracket, rather than the
    // first iterate that merely crosses into the tolerance band) would
    // shrink the accumulated same-sign defect toward representable-
    // precision noise instead of tolerance-scale bias.
    //
    // Measured result at two different cooling severities: the flag
    // produces a BIT-FOR-BIT IDENTICAL accepted trajectory to the
    // baseline in both cases (confirmed via a temporary debug print
    // before this assertion was written, then removed). This is not a
    // near-miss -- it is exactly zero effect. Reading `numerics.zig`'s
    // own doc comment for this flag explains why: "Permit termination at
    // the closest of two adjacent floating-point coordinates that
    // bracket a root" is a narrow float-precision edge case (the root
    // sitting between two ADJACENT representable f64s), not a general
    // "keep refining toward the true zero crossing" mechanism. It simply
    // never activates for a well-conditioned problem like this one.
    // **Candidate fix #1 is ruled out by this measurement; do not revisit
    // it for this specific problem without new evidence.**
    const baseline = try runMonotonicCoolingSubsteps(false);
    const symmetrized = try runMonotonicCoolingSubsteps(true);
    try std.testing.expectEqual(baseline.extensive_absolute_total_mj, symmetrized.extensive_absolute_total_mj);
    try std.testing.expectEqual(baseline.same_sign_count, symmetrized.same_sign_count);
}

fn conservationRefinementCeilingContext() ResidualContext {
    return .{
        .absorbed_shortwave_megajoules_per_m2 = 1.2,
        .atmospheric_longwave_megajoules_per_m2 = 0.9,
        .air_temperature_k = 285,
        .subsurface_temperature_k = 280,
        .previous_surface_temperature_k = 285,
        .ground_exposure_fraction = 1,
        .emissivity = 0.97,
        .sensible_heat_conductance_megajoules_per_m2_h_k = 0.43,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = 0.1,
        .conductive_heat_conductance_megajoules_per_m2_h_k = 0.1,
        .storage_heat_conductance_megajoules_per_m2_h_k = 0.2,
        .atmospheric_vapor_pressure_kpa = 1.0,
        .surface_vapor_activity_fraction = 1.0,
    };
}

fn conservationRefinementCeilingSettings(accept_ceiling: bool, relative_tolerance: f64) Settings {
    return .{
        .sensible_heat_conductance_megajoules_per_m2_h_k = 0.43,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = 0.1,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .latent_heat_of_vaporization_megajoules_per_m3 = 2465,
        .surface_vapor_activity_fraction = 1,
        .timestep_hours = 1,
        .minimum_temperature_k = 173.15,
        .maximum_temperature_k = 373.15,
        .solver_options = .{
            .relative_tolerance = 1.0e-3,
            .residual_scale = 1,
            .max_iterations = 1,
        },
        .energy_conservation_absolute_tolerance_megajoules_per_m2_h = 0,
        .energy_conservation_relative_tolerance = relative_tolerance,
        .accept_physically_conserved_ceiling = accept_ceiling,
    };
}

test "accept_physically_conserved_ceiling defaults to unused, unchanged shared-budget exhaustion" {
    try std.testing.expectError(
        error.NewtonPicardDidNotConverge,
        solveWithConservationRefinement(
            conservationRefinementCeilingContext(),
            conservationRefinementCeilingSettings(false, 1.0e-10),
            173.15,
            373.15,
            285,
        ),
    );
}

test "accept_physically_conserved_ceiling recovers a shared-budget exhaustion that already closes energy" {
    // Same one-iteration ceiling as the default-off test above. A generous
    // conservation band accepts the same discarded iterate through the
    // exact gate that already refines a converged root, above.
    const accepted = try solveWithConservationRefinement(
        conservationRefinementCeilingContext(),
        conservationRefinementCeilingSettings(true, 0.5),
        173.15,
        373.15,
        285,
    );
    try std.testing.expect(accepted.solved.root > 285);
    try std.testing.expect(@abs(accepted.solved.residual) <= accepted.conservation_tolerance_megajoules_per_m2);
    try std.testing.expectEqual(@as(u16, 1), accepted.solved.iterations);
    // A physically negligible (not merely small) band still rejects: this
    // is not a disguised "always accept" switch.
    try std.testing.expectError(
        error.NewtonPicardDidNotConverge,
        solveWithConservationRefinement(
            conservationRefinementCeilingContext(),
            conservationRefinementCeilingSettings(true, 1.0e-30),
            173.15,
            373.15,
            285,
        ),
    );
}

test "failed-pass reset removes retained phase carrier changes" {
    var state = try State.init(std.testing.allocator, 3);
    defer state.deinit();
    @memset(state.liquid_water_change_m3, 1.25);
    @memset(state.ice_water_equivalent_change_m3, -1.25);
    @memset(state.phase_heat_flux_megajoules_per_m2, 416.25);

    state.resetPhaseChangeDiagnostics();

    for (state.liquid_water_change_m3) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
    for (state.ice_water_equivalent_change_m3) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
    for (state.phase_heat_flux_megajoules_per_m2) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
}

test "delayed litter combustion heat is closed inside the hybrid surface solve" {
    const baseline: ResidualContext = .{
        .absorbed_shortwave_megajoules_per_m2 = 0.8,
        .atmospheric_longwave_megajoules_per_m2 = 0.7,
        .air_temperature_k = 280,
        .subsurface_temperature_k = 278,
        .previous_surface_temperature_k = 281,
        .ground_exposure_fraction = 1,
        .emissivity = 0.97,
        .sensible_heat_conductance_megajoules_per_m2_h_k = 0.43,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = 0.1,
        .conductive_heat_conductance_megajoules_per_m2_h_k = 0.1,
        .storage_heat_conductance_megajoules_per_m2_h_k = 0.2,
        .atmospheric_vapor_pressure_kpa = 0.9,
        .surface_vapor_activity_fraction = 0.8,
    };
    var heated = baseline;
    // Each solve gets its own energy scale in MJ m-2 (the heated case carries an
    // extra 2 MJ m-2 external term), matching the production path.
    heated.external_heat_megajoules_per_m2 = 2;
    const baseline_solution = try numerics.newtonPicard(baseline, residual, derivative, picard, 173.15, 373.15, 281, .{ .residual_scale = residualScale(baseline, 281) });
    const heated_solution = try numerics.newtonPicard(heated, residual, derivative, picard, 173.15, 373.15, 281, .{ .residual_scale = residualScale(heated, 281) });
    try std.testing.expect(heated_solution.root > baseline_solution.root);
    try std.testing.expect(@abs(heated_solution.residual) < 1e-7);
}

test "surface implicit hour halves quarters converge close and restart exactly" {
    const Runner = struct {
        const Run = struct {
            temperature_k: f64,
            absolute_nonlinear_residual_megajoules_per_m2: f64,
            nonlinear_residual_acceptance_bound_megajoules_per_m2: f64,
            first_step_temperature_k: f64,
        };

        fn run(initial_temperature_k: f64, substeps: u8, duration_hours: f64) !Run {
            const heat_capacity_megajoules_per_m2_k: f64 = 0.35;
            const dt = duration_hours / @as(f64, @floatFromInt(substeps));
            var temperature_k = initial_temperature_k;
            var first_step_temperature_k: f64 = initial_temperature_k;
            var residual_sum: f64 = 0;
            var residual_acceptance_bound: f64 = 0;
            for (0..substeps) |step| {
                const context: ResidualContext = .{
                    .time_step_hours = dt,
                    .absorbed_shortwave_megajoules_per_m2 = 0.8,
                    .atmospheric_longwave_megajoules_per_m2 = 0.7,
                    .air_temperature_k = 289,
                    .subsurface_temperature_k = 284,
                    .previous_surface_temperature_k = temperature_k,
                    .ground_exposure_fraction = 0.85,
                    .emissivity = 0.97,
                    .sensible_heat_conductance_megajoules_per_m2_h_k = 0.18,
                    .latent_heat_conductance_megajoules_per_m2_h_kpa = 0.02,
                    .conductive_heat_conductance_megajoules_per_m2_h_k = 0.08,
                    .storage_heat_conductance_megajoules_per_m2_h_k = heat_capacity_megajoules_per_m2_k / dt,
                    .atmospheric_vapor_pressure_kpa = 0.9,
                    .surface_vapor_activity_fraction = 0.75,
                    .external_heat_megajoules_per_m2 = 0.15,
                };
                const scale = residualScale(context, temperature_k);
                const absolute_tolerance = 1e-10;
                const relative_tolerance = 1e-9;
                const solved = try numerics.newtonPicard(
                    context,
                    residual,
                    derivative,
                    picard,
                    173.15,
                    373.15,
                    temperature_k,
                    .{
                        .absolute_tolerance = absolute_tolerance,
                        .relative_tolerance = relative_tolerance,
                        .max_iterations = 40,
                        .picard_relaxation = 0.5,
                        .residual_scale = scale,
                        .safeguard_with_bracket = true,
                    },
                );
                residual_sum += solved.residual * dt;
                residual_acceptance_bound +=
                    (absolute_tolerance + relative_tolerance * scale) * dt;
                temperature_k = solved.root;
                if (step == 0) first_step_temperature_k = temperature_k;
            }
            return .{
                .temperature_k = temperature_k,
                .absolute_nonlinear_residual_megajoules_per_m2 = @abs(residual_sum),
                .nonlinear_residual_acceptance_bound_megajoules_per_m2 = residual_acceptance_bound,
                .first_step_temperature_k = first_step_temperature_k,
            };
        }
    };

    const hourly = try Runner.run(280, 1, 1);
    const halves = try Runner.run(280, 2, 1);
    const quarters = try Runner.run(280, 4, 1);
    // This is a nonlinear convergence check, not the independently evaluated
    // conservation gate. Compare to the exact scaled absolute+relative solver
    // acceptance bound accumulated over the accepted internal substeps.
    try std.testing.expect(hourly.absolute_nonlinear_residual_megajoules_per_m2 <= hourly.nonlinear_residual_acceptance_bound_megajoules_per_m2);
    try std.testing.expect(halves.absolute_nonlinear_residual_megajoules_per_m2 <= halves.nonlinear_residual_acceptance_bound_megajoules_per_m2);
    try std.testing.expect(quarters.absolute_nonlinear_residual_megajoules_per_m2 <= quarters.nonlinear_residual_acceptance_bound_megajoules_per_m2);
    try std.testing.expect(@abs(quarters.temperature_k - halves.temperature_k) < @abs(halves.temperature_k - hourly.temperature_k));

    const first_half = try Runner.run(280, 1, 0.5);
    const restarted_second_half = try Runner.run(first_half.temperature_k, 1, 0.5);
    try std.testing.expectApproxEqAbs(halves.first_step_temperature_k, first_half.temperature_k, 1e-12);
    try std.testing.expectApproxEqAbs(halves.temperature_k, restarted_second_half.temperature_k, 1e-12);
}

test "surface phase-active hour halves quarters converge and restart exactly" {
    const Runner = struct {
        const PhaseRun = struct {
            temperature_k: f64,
            liquid_water_m3: f64,
            ice_water_equivalent_m3: f64,
            absolute_nonlinear_residual_megajoules_per_m2: f64 = 0,
            nonlinear_residual_acceptance_bound_megajoules_per_m2: f64 = 0,
            first_step_temperature_k: f64 = 0,
        };

        fn run(initial: PhaseRun, substeps: u8, duration_hours: f64) !PhaseRun {
            const liquid_capacity: f64 = 4.19;
            const ice_capacity_we: f64 = 1.9274 / 0.917;
            const dry_capacity: f64 = 0.10;
            const dt = duration_hours / @as(f64, @floatFromInt(substeps));
            var temperature_k = initial.temperature_k;
            var liquid_water_m3 = initial.liquid_water_m3;
            var ice_water_equivalent_m3 = initial.ice_water_equivalent_m3;
            var residual_sum: f64 = 0;
            var residual_acceptance_bound: f64 = 0;
            var first_step_temperature_k = initial.temperature_k;
            for (0..substeps) |step| {
                const entry_capacity = dry_capacity +
                    liquid_capacity * liquid_water_m3 +
                    ice_capacity_we * ice_water_equivalent_m3;
                const phase: CellPhaseContext = .{
                    .initial_liquid_water_m3 = liquid_water_m3,
                    .initial_ice_water_equivalent_m3 = ice_water_equivalent_m3,
                    .porous_medium_volume_m3 = 0.02,
                    .horizontal_area_m2 = 1,
                    .parameters = .{
                        .residual_water_content_m3_per_m3 = 0,
                        .saturated_water_content_m3_per_m3 = 1,
                        .alpha_per_m = 400,
                        .n = 2.5,
                        .saturated_hydraulic_conductivity_m_per_h = 0,
                    },
                    .gravitational_water_potential_mpa_per_m = 0.0098,
                    .latent_heat_of_fusion_megajoules_per_m3 = 333,
                    .pure_water_melting_temperature_k = 273.15,
                    .heat_capacity_megajoules_per_k = entry_capacity,
                    .dry_heat_capacity_megajoules_per_k = dry_capacity,
                    .ice_heat_capacity_per_water_equivalent_m3_k = ice_capacity_we,
                };
                const context: ResidualContext = .{
                    .time_step_hours = dt,
                    .absorbed_shortwave_megajoules_per_m2 = 0,
                    .atmospheric_longwave_megajoules_per_m2 = 0,
                    .air_temperature_k = 268,
                    .subsurface_temperature_k = 268,
                    .previous_surface_temperature_k = temperature_k,
                    .ground_exposure_fraction = 0,
                    .emissivity = 0,
                    .sensible_heat_conductance_megajoules_per_m2_h_k = 0.02,
                    .latent_heat_conductance_megajoules_per_m2_h_kpa = 0,
                    .conductive_heat_conductance_megajoules_per_m2_h_k = 0.02,
                    .storage_heat_conductance_megajoules_per_m2_h_k = entry_capacity / dt,
                    .atmospheric_vapor_pressure_kpa = 0,
                    .surface_vapor_activity_fraction = 0,
                    .owner_liquid_water_m3_per_m2 = liquid_water_m3,
                    .liquid_water_heat_capacity_megajoules_per_m3_k = liquid_capacity,
                    .phase = phase,
                };
                const scale = residualScale(context, temperature_k);
                const absolute_tolerance = 1.0e-10;
                const relative_tolerance = 1.0e-9;
                const solved = try numerics.newtonPicard(
                    context,
                    residual,
                    derivative,
                    picard,
                    250,
                    290,
                    temperature_k,
                    .{
                        .absolute_tolerance = absolute_tolerance,
                        .relative_tolerance = relative_tolerance,
                        .max_iterations = 80,
                        .picard_relaxation = 0.5,
                        .residual_scale = scale,
                        .safeguard_with_bracket = true,
                    },
                );
                const equilibrium = try surfacePhaseEquilibrium(phase, solved.root);
                residual_sum += solved.residual * dt;
                residual_acceptance_bound +=
                    (absolute_tolerance + relative_tolerance * scale) * dt;
                temperature_k = solved.root;
                liquid_water_m3 = equilibrium.liquid_water_m3;
                ice_water_equivalent_m3 = equilibrium.ice_water_equivalent_m3;
                if (step == 0) first_step_temperature_k = temperature_k;
            }
            return .{
                .temperature_k = temperature_k,
                .liquid_water_m3 = liquid_water_m3,
                .ice_water_equivalent_m3 = ice_water_equivalent_m3,
                .absolute_nonlinear_residual_megajoules_per_m2 = @abs(residual_sum),
                .nonlinear_residual_acceptance_bound_megajoules_per_m2 = residual_acceptance_bound,
                .first_step_temperature_k = first_step_temperature_k,
            };
        }
    };

    const initial: Runner.PhaseRun = .{
        .temperature_k = 272,
        .liquid_water_m3 = 0.01,
        .ice_water_equivalent_m3 = 0,
    };
    const hourly = try Runner.run(initial, 1, 1);
    const halves = try Runner.run(initial, 2, 1);
    const quarters = try Runner.run(initial, 4, 1);
    inline for (.{ hourly, halves, quarters }) |run| {
        try std.testing.expect(run.ice_water_equivalent_m3 > 0);
        try std.testing.expect(run.ice_water_equivalent_m3 < initial.liquid_water_m3);
        try std.testing.expectApproxEqAbs(
            initial.liquid_water_m3,
            run.liquid_water_m3 + run.ice_water_equivalent_m3,
            1.0e-14,
        );
        try std.testing.expect(run.absolute_nonlinear_residual_megajoules_per_m2 <=
            run.nonlinear_residual_acceptance_bound_megajoules_per_m2);
    }
    try std.testing.expect(@abs(quarters.temperature_k - halves.temperature_k) <
        @abs(halves.temperature_k - hourly.temperature_k));
    try std.testing.expect(@abs(quarters.ice_water_equivalent_m3 - halves.ice_water_equivalent_m3) <
        @abs(halves.ice_water_equivalent_m3 - hourly.ice_water_equivalent_m3));

    const first_half = try Runner.run(initial, 1, 0.5);
    const restarted_second_half = try Runner.run(first_half, 1, 0.5);
    try std.testing.expectApproxEqAbs(halves.first_step_temperature_k, first_half.temperature_k, 1.0e-12);
    try std.testing.expectApproxEqAbs(halves.temperature_k, restarted_second_half.temperature_k, 1.0e-12);
    try std.testing.expectApproxEqAbs(halves.liquid_water_m3, restarted_second_half.liquid_water_m3, 1.0e-14);
    try std.testing.expectApproxEqAbs(halves.ice_water_equivalent_m3, restarted_second_half.ice_water_equivalent_m3, 1.0e-14);
}

test "saturation vapor pressure follows the ecosys relation" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.61), saturationVaporPressureKpa(1.0 / 3.661e-3), 1.0e-14);
    try std.testing.expect(saturationVaporPressureKpa(300) > saturationVaporPressureKpa(280));
}

test "surface vapor sensible heat uses the phase donor temperature" {
    try std.testing.expectApproxEqAbs(
        0.002 * 4.19 * 285,
        try vaporSensibleHeatFlux(0.002 * 2465, 285, 280, 4.19, 2465),
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(
        -0.002 * 4.19 * 280,
        try vaporSensibleHeatFlux(-0.002 * 2465, 285, 280, 4.19, 2465),
        1.0e-12,
    );
}

test "analytic residual derivative agrees with finite difference" {
    const context: ResidualContext = .{ .absorbed_shortwave_megajoules_per_m2 = 0.8, .atmospheric_longwave_megajoules_per_m2 = 0.7, .air_temperature_k = 280, .subsurface_temperature_k = 278, .previous_surface_temperature_k = 281, .ground_exposure_fraction = 0.75, .emissivity = 0.97, .sensible_heat_conductance_megajoules_per_m2_h_k = 0.43, .latent_heat_conductance_megajoules_per_m2_h_kpa = 0.2, .conductive_heat_conductance_megajoules_per_m2_h_k = 0.1, .storage_heat_conductance_megajoules_per_m2_h_k = 0.2, .atmospheric_vapor_pressure_kpa = 0.9, .surface_vapor_activity_fraction = 0.85 };
    const temperature_k: f64 = 286;
    const step: f64 = 1.0e-4;
    const finite_difference = (residual(context, temperature_k + step) - residual(context, temperature_k - step)) / (2 * step);
    try std.testing.expectApproxEqRel(finite_difference, derivative(context, temperature_k), 1.0e-8);
}

fn endpointCapacityTestContext(
    initial_liquid_water_m3: f64,
    initial_ice_water_equivalent_m3: f64,
    dry_heat_capacity_megajoules_per_k: f64,
) ResidualContext {
    const liquid_capacity: f64 = 4.19;
    const ice_capacity_per_water_equivalent: f64 = 1.9274 / 0.917;
    const entry_capacity = dry_heat_capacity_megajoules_per_k +
        liquid_capacity * initial_liquid_water_m3 +
        ice_capacity_per_water_equivalent * initial_ice_water_equivalent_m3;
    return .{
        .time_step_hours = 0.5,
        .absorbed_shortwave_megajoules_per_m2 = 0.2,
        .atmospheric_longwave_megajoules_per_m2 = 0.1,
        .air_temperature_k = 285,
        .ground_exposure_fraction = 1,
        .emissivity = 0.95,
        .sensible_heat_conductance_megajoules_per_m2_h_k = 0.2,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = 0,
        .atmospheric_vapor_pressure_kpa = 0,
        .surface_vapor_activity_fraction = 1,
        .owner_liquid_water_m3_per_m2 = initial_liquid_water_m3,
        .liquid_water_heat_capacity_megajoules_per_m3_k = liquid_capacity,
        .latent_heat_of_vaporization_megajoules_per_m3 = 2465,
        .subsurface_temperature_k = 279,
        .previous_surface_temperature_k = 280,
        .conductive_heat_conductance_megajoules_per_m2_h_k = 0.1,
        .storage_heat_conductance_megajoules_per_m2_h_k = entry_capacity / 0.5,
        .phase = .{
            .initial_liquid_water_m3 = initial_liquid_water_m3,
            .initial_ice_water_equivalent_m3 = initial_ice_water_equivalent_m3,
            .porous_medium_volume_m3 = @max(
                0.02,
                initial_liquid_water_m3 + initial_ice_water_equivalent_m3,
            ),
            .horizontal_area_m2 = 1,
            .parameters = .{
                .residual_water_content_m3_per_m3 = 0,
                .saturated_water_content_m3_per_m3 = 1,
                .alpha_per_m = 400,
                .n = 2.5,
                .saturated_hydraulic_conductivity_m_per_h = 0,
            },
            .gravitational_water_potential_mpa_per_m = 0.0098,
            .latent_heat_of_fusion_megajoules_per_m3 = 333,
            .pure_water_melting_temperature_k = 273.15,
            .heat_capacity_megajoules_per_k = entry_capacity,
            .dry_heat_capacity_megajoules_per_k = dry_heat_capacity_megajoules_per_k,
            .ice_heat_capacity_per_water_equivalent_m3_k = ice_capacity_per_water_equivalent,
        },
    };
}

test "endpoint capacity preserves represented internal vapor redistribution" {
    var context = endpointCapacityTestContext(0.01, 0, 2);
    context.use_vapor_volume_fraction = true;
    context.owner_air_volume_m3_per_m2 = 0.05;
    context.owner_vapor_water_equivalent_m3_per_m2 = 1.0e-5;
    context.owner_vapor_water_equivalent_m3 = 1.0e-5;
    context.vapor_fraction_conversion_k_per_kpa = 0.002166;
    context.vapor_conductance_m3_per_m2_h = 0;
    context.storage_heat_conductance_megajoules_per_m2_h_k =
        (2 + 4.19 * (0.01 + 1.0e-5)) / context.time_step_hours;

    const endpoint = endpointSurfaceHeatCapacityMegajoulesPerM2K(context, 280);
    try std.testing.expectApproxEqRel(
        @as(f64, 2 + 4.19 * (0.01 + 1.0e-5)),
        endpoint,
        4.0e-15,
    );
}

test "endpoint capacity follows capped evaporation and condensation" {
    const entry = endpointSurfaceHeatCapacityMegajoulesPerM2K(
        endpointCapacityTestContext(0.001, 0, 2),
        280,
    );
    var evaporation = endpointCapacityTestContext(0.001, 0, 2);
    evaporation.latent_heat_conductance_megajoules_per_m2_h_kpa = 100;
    evaporation.atmospheric_vapor_pressure_kpa = 0;
    const evaporated = endpointSurfaceHeatCapacityMegajoulesPerM2K(evaporation, 300);
    try std.testing.expectApproxEqAbs(@as(f64, 2), evaporated, 1.0e-14);
    try std.testing.expect(evaporated < entry);

    var condensation = endpointCapacityTestContext(0.001, 0, 2);
    condensation.latent_heat_conductance_megajoules_per_m2_h_kpa = 0.01;
    condensation.atmospheric_vapor_pressure_kpa = 4;
    const condensed = endpointSurfaceHeatCapacityMegajoulesPerM2K(condensation, 280);
    try std.testing.expect(condensed > entry);
}

test "endpoint capacity uses water-equivalent ice coefficient after phase change" {
    const context = endpointCapacityTestContext(0.01, 0, 2);
    const temperature_k: f64 = 268;
    const endpoint = endpointSurfaceHeatCapacityMegajoulesPerM2K(context, temperature_k);
    const equilibrium = try surfacePhaseEquilibrium(context.phase.?, temperature_k);
    const expected = context.phase.?.dry_heat_capacity_megajoules_per_k +
        context.liquid_water_heat_capacity_megajoules_per_m3_k *
            equilibrium.liquid_water_m3 +
        context.phase.?.ice_heat_capacity_per_water_equivalent_m3_k *
            equilibrium.ice_water_equivalent_m3;
    try std.testing.expect(equilibrium.ice_water_equivalent_m3 > 0);
    try std.testing.expectApproxEqRel(expected, endpoint, 4.0e-15);
    try std.testing.expect(@abs(endpoint -
        (context.phase.?.dry_heat_capacity_megajoules_per_k +
            context.liquid_water_heat_capacity_megajoules_per_m3_k * 0.01)) > 1.0e-6);
}

test "endpoint capacity centered storage derivative matches full residual" {
    var context = endpointCapacityTestContext(0.01, 0, 2);
    context.latent_heat_conductance_megajoules_per_m2_h_kpa = 0.01;
    context.atmospheric_vapor_pressure_kpa = 4;
    const temperature_k: f64 = 280;
    const step_k: f64 = 1.0e-4;
    const finite_difference = (residual(context, temperature_k + step_k) -
        residual(context, temperature_k - step_k)) / (2 * step_k);
    try std.testing.expectApproxEqRel(
        finite_difference,
        derivative(context, temperature_k),
        2.0e-7,
    );
}

test "surfacePhaseEquilibrium applies the WATSUB energy limit" {
    // Regression test for the wiring, not the limit arithmetic: reverting
    // `surfacePhaseEquilibrium` to return the raw Dall'Amico equilibrium must fail
    // here. It previously left every test passing. See EXEC-002.
    //
    // The measured Ottawa hour-2 state: 6.9736e4 m3 of litter water at 277.145 K
    // with a heat capacity of 4.19 x that volume. Unlimited, the equilibrium at a
    // below-freezing trial temperature freezes essentially the whole reservoir;
    // limited, it may only freeze what the temperature deficit supports.
    const liquid_m3 = 6.973601907996609e4;
    const phase: CellPhaseContext = .{
        .initial_liquid_water_m3 = liquid_m3,
        .initial_ice_water_equivalent_m3 = 0,
        .porous_medium_volume_m3 = liquid_m3,
        .horizontal_area_m2 = 8.717002384995762e7,
        .parameters = .{
            .residual_water_content_m3_per_m3 = 0,
            .saturated_water_content_m3_per_m3 = 1,
            .alpha_per_m = 400,
            .n = 2.5,
            .saturated_hydraulic_conductivity_m_per_h = 0,
        },
        .gravitational_water_potential_mpa_per_m = 0.0098,
        .latent_heat_of_fusion_megajoules_per_m3 = 333,
        .pure_water_melting_temperature_k = 273.15,
        .heat_capacity_megajoules_per_k = 4.19 * liquid_m3,
        .dry_heat_capacity_megajoules_per_k = 0,
        .ice_heat_capacity_per_water_equivalent_m3_k = 1.9274 / 0.917,
    };

    // A trial temperature 4 K below freezing, as the hour-2 solve found.
    const limited = try surfacePhaseEquilibrium(phase, 273.15 - 4.0);

    // The energy the deficit can drive is capacity x deficit, so the ice formed
    // must not exceed that divided by the latent heat. With capacity 4.19*V and a
    // 4 K deficit that is about 0.0503 of the reservoir, far short of all of it.
    const energy_limited_ice_m3 = phase.heat_capacity_megajoules_per_k * 4.0 / 333.0;
    try std.testing.expect(limited.ice_water_equivalent_m3 <= energy_limited_ice_m3 * 1.05);
    // And it must be a small fraction of the reservoir, which is the property the
    // unlimited equilibrium violates.
    try std.testing.expect(limited.ice_water_equivalent_m3 < 0.25 * liquid_m3);
    // Water equivalent is still conserved exactly.
    try std.testing.expectApproxEqRel(
        liquid_m3,
        limited.liquid_water_m3 + limited.ice_water_equivalent_m3,
        1e-14,
    );

    // Above the freezing point nothing freezes, matching the oracle's TFREEZ gate.
    const warm = try surfacePhaseEquilibrium(phase, 277.145);
    try std.testing.expectEqual(@as(f64, 0), warm.ice_water_equivalent_m3);
}

test "surface phase energy limit uses live PSISVR" {
    const fresh: CellPhaseContext = .{
        .initial_liquid_water_m3 = 1,
        .initial_ice_water_equivalent_m3 = 0,
        .porous_medium_volume_m3 = 1,
        .horizontal_area_m2 = 1,
        .parameters = .{
            .residual_water_content_m3_per_m3 = 0,
            .saturated_water_content_m3_per_m3 = 1,
            .alpha_per_m = 400,
            .n = 2.5,
            .saturated_hydraulic_conductivity_m_per_h = 0,
        },
        .gravitational_water_potential_mpa_per_m = 0.0098,
        .water_potential_megapascal = 0,
        .latent_heat_of_fusion_megajoules_per_m3 = 333,
        .pure_water_melting_temperature_k = 273.15,
        .heat_capacity_megajoules_per_k = 100,
        .dry_heat_capacity_megajoules_per_k = 0,
        .ice_heat_capacity_per_water_equivalent_m3_k = 1.9274 / 0.917,
    };
    const requested: phase_change.DallAmicoEquilibrium = .{
        .depressed_melting_temperature_k = 273.15,
        .liquid_pressure_head_m = 0,
        .liquid_water_m3 = 0,
        .ice_water_equivalent_m3 = 1,
    };
    const temperature_k = 272.0;
    const fresh_result = try limitPhaseChangeToAvailableEnergy(
        fresh,
        temperature_k,
        1,
        requested,
    );
    var saline = fresh;
    saline.water_potential_megapascal = -10;
    const saline_result = try limitPhaseChangeToAvailableEnergy(
        saline,
        temperature_k,
        1,
        requested,
    );
    try std.testing.expect(fresh_result.ice_water_equivalent_m3 > 0);
    try std.testing.expectEqual(@as(f64, 0), saline_result.ice_water_equivalent_m3);
}

test "surface residue Dall'Amico enthalpy converges without a sub-hour cycle" {
    const phase: CellPhaseContext = .{
        .initial_liquid_water_m3 = 0.01,
        .initial_ice_water_equivalent_m3 = 0,
        .porous_medium_volume_m3 = 0.02,
        .horizontal_area_m2 = 1,
        .parameters = .{
            .residual_water_content_m3_per_m3 = 0,
            .saturated_water_content_m3_per_m3 = 1,
            .alpha_per_m = 400,
            .n = 2.5,
            .saturated_hydraulic_conductivity_m_per_h = 0,
        },
        .gravitational_water_potential_mpa_per_m = 0.0098,
        .latent_heat_of_fusion_megajoules_per_m3 = 333,
        .pure_water_melting_temperature_k = 273.15,
        // Ample capacity so the WATSUB energy limit does not bind in this test.
        .heat_capacity_megajoules_per_k = 1.0e9,
        .dry_heat_capacity_megajoules_per_k = 1,
        .ice_heat_capacity_per_water_equivalent_m3_k = 1.9274 / 0.917,
    };
    const context: ResidualContext = .{
        .absorbed_shortwave_megajoules_per_m2 = 0,
        .atmospheric_longwave_megajoules_per_m2 = 0,
        .air_temperature_k = 260,
        .subsurface_temperature_k = 260,
        .previous_surface_temperature_k = 260,
        .ground_exposure_fraction = 0,
        .emissivity = 0,
        .sensible_heat_conductance_megajoules_per_m2_h_k = 1,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = 0,
        .conductive_heat_conductance_megajoules_per_m2_h_k = 1,
        .storage_heat_conductance_megajoules_per_m2_h_k = 1,
        .atmospheric_vapor_pressure_kpa = 0,
        .surface_vapor_activity_fraction = 0,
        .phase = phase,
    };
    const solved = try numerics.newtonPicard(
        context,
        residual,
        derivative,
        picard,
        240,
        300,
        260,
        .{ .max_iterations = 80, .residual_scale = residualScale(context, 260) }, // MJ m-2 energy scale incl. latent heat of fusion
    );
    const equilibrium = try surfacePhaseEquilibrium(phase, solved.root);
    try std.testing.expect(solved.iterations < 80);
    try std.testing.expect(@abs(solved.residual) < 1e-7);
    try std.testing.expect(equilibrium.ice_water_equivalent_m3 > 0);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.01),
        equilibrium.liquid_water_m3 +
            equilibrium.ice_water_equivalent_m3,
        1e-14,
    );
    // WATSUB carries absolute C*T and recomputes the smaller ice endpoint
    // capacity. In this deliberately all-freezing fixture that capacity rebase
    // is larger than the released latent heat, so the exact oracle form cools
    // slightly while still converging without a sub-hour phase cycle.
    try std.testing.expect(solved.root < 260);
}

test "surface Dall'Amico phase derivative matches the frozen branch" {
    const phase: CellPhaseContext = .{
        .initial_liquid_water_m3 = 0.01,
        .initial_ice_water_equivalent_m3 = 0,
        .porous_medium_volume_m3 = 0.02,
        .horizontal_area_m2 = 1,
        .parameters = .{
            .residual_water_content_m3_per_m3 = 0,
            .saturated_water_content_m3_per_m3 = 1,
            .alpha_per_m = 400,
            .n = 2.5,
            .saturated_hydraulic_conductivity_m_per_h = 0,
        },
        .gravitational_water_potential_mpa_per_m = 0.0098,
        .latent_heat_of_fusion_megajoules_per_m3 = 333,
        .pure_water_melting_temperature_k = 273.15,
        // Ample capacity so the WATSUB energy limit does not bind in this test.
        .heat_capacity_megajoules_per_k = 1.0e9,
        .dry_heat_capacity_megajoules_per_k = 1,
        .ice_heat_capacity_per_water_equivalent_m3_k = 1.9274 / 0.917,
    };
    const context: ResidualContext = .{
        .absorbed_shortwave_megajoules_per_m2 = 0,
        .atmospheric_longwave_megajoules_per_m2 = 0,
        .air_temperature_k = 260,
        .subsurface_temperature_k = 260,
        .previous_surface_temperature_k = 260,
        .ground_exposure_fraction = 0,
        .emissivity = 0,
        .sensible_heat_conductance_megajoules_per_m2_h_k = 1,
        .latent_heat_conductance_megajoules_per_m2_h_kpa = 0,
        .conductive_heat_conductance_megajoules_per_m2_h_k = 1,
        .storage_heat_conductance_megajoules_per_m2_h_k = 1,
        .atmospheric_vapor_pressure_kpa = 0,
        .surface_vapor_activity_fraction = 0,
        .phase = phase,
    };
    const temperature_k: f64 = 268;
    const step_k: f64 = 1.0e-4;
    const finite_difference =
        (phaseHeatFlux(context, temperature_k + step_k) -
            phaseHeatFlux(context, temperature_k - step_k)) / (2 * step_k);
    try std.testing.expectApproxEqRel(
        finite_difference,
        phaseHeatDerivative(context, temperature_k),
        2.0e-4,
    );
}
