// CANOPY-TKC-001 Sub-task A: the canopy-surface-temperature (TKCY) Newton
// residual, transcribing `uptake.f:862--1057`. This is deliberately a SCALAR
// solve, not a 4-variable {TKCY,TKQY,VPCY,VPQY} dense system as an earlier
// register amendment ("amendment 2") proposed. Reading the oracle past line
// 1057 shows why: `uptake.f:926` (`DTKQC=TKAM-TKQY`) and `:935`
// (`DTKC=TKQY-TKCY`) both treat TKQY as a *constant* throughout the entire
// `DO 4000 NN` loop that solves TKCY, and TKQY/VPQY are updated exactly once,
// explicitly (not iteratively), after that loop exits
// (`uptake.f:1263--1289`). That explicit update is already the bound,
// production `canopy/energy/air_exchange.zig` (`solveInto` owns TKQC; see
// its own module comment). So the true coupling is a per-M-substep
// Gauss-Seidel split -- solve TKCY holding TKQY fixed, then update TKQY/VPQY
// once from the converged TKCY's fluxes -- not a simultaneous vector Newton
// step. Building the latter would be a faithful-looking but scientifically
// wrong translation; MIGRATION.md's oracle rule means the source, not a
// prior plan, wins. VPCY (`uptake.f:999--1001`) is a closed-form function of
// TKCY and PSILT (fixed), not an independent unknown, so it is evaluated
// inline by `surface_exchange.calculate` and never appears as a solver
// variable here either.
//
// `stomatal_call_boundary.zig` (also named by amendment 2 for this sub-task)
// is deliberately NOT consumed here: its `prepare` snapshots per-species
// TKQY/vapor state into a caller-owned array (`SnapshotState`) once per hour,
// ahead of the separate STOMATE call -- a production-wiring concern
// (sub-task C), not something a stateless scalar residual has a slot for.
//
// `airflow.zig` is also not called per Newton iteration, despite the
// directive suggesting it. Its resistances (`RABX`-derived, biome/species
// level) depend only on TKQY/TKAM/ground (`uptake.f:929--932`), none of
// which vary while solving TKCY, so recomputing them every iterate would be
// pure waste with an identical result each time. Only `surface_exchange.zig`
// -- whose resistances depend on the trial TKCY via `DTKC` -- must be
// re-evaluated fresh each iterate, and it is.
//
// `fixed_terms.Result.latent_boundary_conductance_m2_per_step` /
// `sensible_boundary_conductance_megajoules_per_m_k_step` (PAREZ/PARSZ,
// `uptake.f:830--831`) are intentionally NOT fed into
// `surface_exchange.Inputs`' numerator fields either: `surface_exchange.zig`
// already multiplies its numerator inputs by `species_canopy_radiation_fraction`
// (FRADP) internally, so it expects the *unscaled* airflow-level numerator
// (PAREX/PARSX); feeding it the already-FRADP-scaled `fixed_terms` output
// would double-apply FRADP. `FixedInputs` below therefore takes the raw
// airflow-level numerators directly.
const std = @import("std");
const numerics = @import("../../core/numerics.zig");
const water_heat_initialization = @import("water_heat_initialization.zig");
const substep_initialization = @import("substep_initialization.zig");
const fixed_terms = @import("fixed_terms.zig");
const water_osmotic_potential = @import("water_osmotic_potential.zig");
const radiation_iteration = @import("radiation_iteration.zig");
const surface_exchange = @import("surface_exchange.zig");
const minimum_stomatal = @import("minimum_stomatal_resistance.zig");
const convergence_pass_control = @import("../state/convergence_pass_control.zig");
const water_balance = @import("../../plant/root/water_balance.zig");

pub const Settings = struct {
    heat_flux_timestep_h: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    minimum_temperature_k: f64,
    maximum_temperature_k: f64,
    surface_exchange_parameters: surface_exchange.Parameters,
    solver_options: numerics.SolverOptions,
};

/// Everything the TKCY residual needs that is fixed for the whole `DO 4000
/// NN` loop: either genuinely constant per M-substep in the oracle, or
/// (`heat_initialization`/`substep`/`fixed_terms`) the already-evaluated
/// `Result` of an upstream module this sub-task consumes rather than
/// reimplements.
pub const FixedInputs = struct {
    heat_initialization: water_heat_initialization.Result,
    substep: substep_initialization.Result,
    fixed_terms: fixed_terms.Result,

    ground_surface_temperature_k: f64,
    absorbed_radiation_fraction: f64,

    atmospheric_temperature_k: f64,
    bulk_richardson_coefficient_k: f64,
    biome_isothermal_boundary_resistance_h_per_m: f64,
    aerodynamic_resistance_below_biome_h_per_m: f64,
    aerodynamic_resistance_below_species_h_per_m: f64,
    latent_boundary_numerator_m2_per_h: f64,
    sensible_boundary_numerator_megajoules_per_m_h_k: f64,
    sensible_surface_resistance_h_per_m: f64,
    latent_surface_resistance_h_per_m: f64,
    canopy_air_vapor_fraction: f64,

    canopy_total_water_potential_megapascal: f64,
    minimum_dry_matter_fraction_g_c_per_g: f64,
    canopy_water_mass_g: f64,
    osmotic_potential_at_zero_total_megapascal: f64,
    canopy_salt_concentration_mol_per_g_c: f64,

    minimum_stomatal_resistance_h_per_m: f64,
    cuticular_resistance_h_per_m: f64,
    stomatal_turgor_shape_per_megapascal: f64,
};

pub const Result = struct {
    canopy_surface_temperature_k: f64,
    net_canopy_radiation_megajoules_per_step: f64,
    sensible_heat_flux_megajoules_per_step: f64,
    latent_heat_flux_megajoules_per_step: f64,
    vapor_sensible_heat_flux_megajoules_per_step: f64,
    canopy_storage_heat_flux_megajoules_per_step: f64,
    /// EPCCMX (`uptake.f:1006`): the actual canopy-atmosphere vapor flux.
    /// Canopy-air and external-boundary ledgers must use this value.
    surface_transpiration_m3_per_step: f64,
    /// EPCCM (`uptake.f:1014`): EPCCMX plus VOLWPDM, the canopy-capacity
    /// adjustment used by the hydraulic/storage residual and legacy TUPVC
    /// aggregate. It is not, by itself, an atmospheric boundary flux.
    transpiration_m3_per_step: f64,
    intercepted_water_change_m3_per_step: f64,
    turgor_water_potential_megapascal: f64,
    osmotic_water_potential_megapascal: f64,
    stomatal_resistance_h_per_m: f64,
    wet_canopy_heat_capacity_megajoules_per_k: f64,
    boundary_layer_resistance_h_per_m: f64,
    total_aerodynamic_resistance_h_per_m: f64,
    adjusted_surface_resistance_h_per_m: f64,
    canopy_surface_vapor_fraction: f64,
    emitted_canopy_longwave_megajoules_per_step: f64,
    canopy_to_ground_longwave_megajoules_per_step: f64,
    net_canopy_longwave_megajoules_per_step: f64,
    /// True when `uptake.f:1042`'s `VHCPCC.GT.VHCPYZ` gate failed at the
    /// converged temperature, meaning TKCY was (correctly) held frozen
    /// rather than solved this step.
    heat_capacity_gated_frozen: bool,
    iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
    anderson_steps: u16,
};

const Evaluation = struct {
    osmotic: water_osmotic_potential.Result,
    surface: surface_exchange.Result,
    radiation: radiation_iteration.Result,
    stomatal_resistance_h_per_m: f64,
    storage_flux_megajoules_per_step: f64,
    wet_heat_capacity_megajoules_per_k: f64,
    picard_target_k: f64,
};

/// `numerics.newtonPicard`'s residual/picard callbacks cannot return errors,
/// but the modules this residual composes validate their own inputs and can
/// fail. A pointer context lets a failure be captured here and re-surfaced
/// by `solve` after the driver aborts (a non-finite residual makes it abort
/// on the very same evaluation that produced it, so the captured error is
/// always the true proximate cause, never stale).
const EvaluationContext = struct {
    fixed: *const FixedInputs,
    settings: *const Settings,
    captured_error: ?anyerror = null,
};

/// UPTAKE.F 862--1057. Solves for canopy surface temperature (TKCY) via
/// Newton/Anderson-Picard, holding canopy air temperature and vapor
/// concentration (TKQY/VPQY) fixed as this module's contract requires.
pub fn solve(fixed: FixedInputs, settings: Settings) !Result {
    try validateSettings(settings);
    try validateFixedInputs(fixed);

    var context: EvaluationContext = .{ .fixed = &fixed, .settings = &settings };
    const initial_guess = fixed.heat_initialization.previous_canopy_temperature_k;
    var options = settings.solver_options;
    options.residual_scale = @max(1.0, @abs(initial_guess));

    const Callbacks = struct {
        fn residual(ctx: *EvaluationContext, temperature_k: f64) f64 {
            const eval = evaluate(ctx.fixed.*, ctx.settings.*, temperature_k) catch |err| {
                ctx.captured_error = err;
                return std.math.nan(f64);
            };
            return eval.picard_target_k - temperature_k;
        }
        fn picard(ctx: *EvaluationContext, temperature_k: f64) f64 {
            const eval = evaluate(ctx.fixed.*, ctx.settings.*, temperature_k) catch |err| {
                ctx.captured_error = err;
                return std.math.nan(f64);
            };
            return eval.picard_target_k;
        }
    };

    const solved = numerics.newtonPicardFiniteDifference(
        &context,
        Callbacks.residual,
        Callbacks.picard,
        settings.minimum_temperature_k,
        settings.maximum_temperature_k,
        std.math.clamp(initial_guess, settings.minimum_temperature_k, settings.maximum_temperature_k),
        options,
    ) catch |err| {
        if (context.captured_error) |captured| return captured;
        return err;
    };

    const final = try evaluate(fixed, settings, solved.root);
    return .{
        .canopy_surface_temperature_k = solved.root,
        .net_canopy_radiation_megajoules_per_step = final.radiation.net_canopy_radiation_megajoules_per_step,
        .sensible_heat_flux_megajoules_per_step = final.surface.sensible_heat_flux_megajoules_per_h * settings.heat_flux_timestep_h,
        .latent_heat_flux_megajoules_per_step = final.surface.latent_heat_flux_megajoules_per_h * settings.heat_flux_timestep_h,
        .vapor_sensible_heat_flux_megajoules_per_step = final.surface.vapor_sensible_heat_flux_megajoules_per_h * settings.heat_flux_timestep_h,
        .canopy_storage_heat_flux_megajoules_per_step = final.storage_flux_megajoules_per_step,
        .surface_transpiration_m3_per_step = final.surface.transpiration_m3_per_h * settings.heat_flux_timestep_h,
        .transpiration_m3_per_step = final.surface.transpiration_m3_per_h * settings.heat_flux_timestep_h + final.radiation.canopy_water_capacity_difference_change_m3_per_step,
        .intercepted_water_change_m3_per_step = final.surface.intercepted_water_change_m3_per_h * settings.heat_flux_timestep_h,
        .turgor_water_potential_megapascal = final.osmotic.turgor_water_potential_megapascal,
        .osmotic_water_potential_megapascal = final.osmotic.osmotic_water_potential_megapascal,
        .stomatal_resistance_h_per_m = final.stomatal_resistance_h_per_m,
        .wet_canopy_heat_capacity_megajoules_per_k = final.wet_heat_capacity_megajoules_per_k,
        .boundary_layer_resistance_h_per_m = final.surface.boundary_layer_resistance_h_per_m,
        .total_aerodynamic_resistance_h_per_m = final.surface.total_aerodynamic_resistance_h_per_m,
        .adjusted_surface_resistance_h_per_m = final.surface.adjusted_surface_resistance_h_per_m,
        .canopy_surface_vapor_fraction = final.surface.canopy_surface_vapor_fraction,
        .emitted_canopy_longwave_megajoules_per_step = final.radiation.emitted_canopy_longwave_megajoules_per_step,
        .canopy_to_ground_longwave_megajoules_per_step = final.radiation.canopy_to_ground_longwave_megajoules_per_step,
        .net_canopy_longwave_megajoules_per_step = final.radiation.net_canopy_longwave_megajoules_per_step,
        .heat_capacity_gated_frozen = final.wet_heat_capacity_megajoules_per_k <= fixed.heat_initialization.low_heat_capacity_threshold_megajoules_per_k,
        .iterations = solved.iterations,
        .newton_raphson_steps = solved.newton_raphson_steps,
        .picard_steps = solved.picard_steps,
        .anderson_steps = solved.anderson_steps,
    };
}

/// One full evaluation of the TKCY residual chain at a trial temperature:
/// turgor (`water_osmotic_potential`) -> stomatal resistance
/// (`uptake.f:972--973`) -> canopy resistance/water/heat fluxes
/// (`surface_exchange`) -> net radiation (`radiation_iteration`) ->
/// HFLXCCM/VHCPCC/TKCZ (`uptake.f:1026,1041,1044`).
fn evaluate(fixed: FixedInputs, settings: Settings, trial_temperature_k: f64) !Evaluation {
    const osmotic = try water_osmotic_potential.calculate(.{
        .canopy_total_water_potential_megapascal = fixed.canopy_total_water_potential_megapascal,
        .minimum_dry_matter_fraction_g_c_per_g = fixed.minimum_dry_matter_fraction_g_c_per_g,
        .canopy_water_mass_g = fixed.canopy_water_mass_g,
        .osmotic_potential_at_zero_total_megapascal = fixed.osmotic_potential_at_zero_total_megapascal,
        .canopy_surface_temperature_k = trial_temperature_k,
        .nonstructural_solute_concentration_g_per_g_c = fixed.fixed_terms.total_nonstructural_solute_concentration_g_per_g_c,
        .solute_molar_mass_g_per_mol = fixed.fixed_terms.osmotic_molar_mass_g_per_mol,
        .canopy_salt_concentration_mol_per_g_c = fixed.canopy_salt_concentration_mol_per_g_c,
    });

    // UPTAKE.F 972--973: RC = RSMN + (RSMH-RSMN)*EXP(RCS*PSILG). Mirrors the
    // identical water-stress formula in
    // `surface_exchange.SurfaceInputWorkspace.refresh`; duplicated as a
    // scalar expression here because that API is batch/slice-shaped and
    // does not fit a per-iterate scalar residual.
    const stomatal_resistance = fixed.minimum_stomatal_resistance_h_per_m +
        (fixed.cuticular_resistance_h_per_m - fixed.minimum_stomatal_resistance_h_per_m) *
            @exp(fixed.stomatal_turgor_shape_per_megapascal * osmotic.turgor_water_potential_megapascal);

    const surface = try surface_exchange.calculate(.{
        .atmospheric_temperature_k = fixed.atmospheric_temperature_k,
        .canopy_air_temperature_k = fixed.substep.canopy_air_temperature_k,
        .canopy_surface_temperature_k = trial_temperature_k,
        .canopy_air_vapor_fraction = fixed.canopy_air_vapor_fraction,
        .bulk_richardson_coefficient_k = fixed.bulk_richardson_coefficient_k,
        .biome_isothermal_boundary_resistance_h_per_m = fixed.biome_isothermal_boundary_resistance_h_per_m,
        .aerodynamic_resistance_below_biome_h_per_m = fixed.aerodynamic_resistance_below_biome_h_per_m,
        .aerodynamic_resistance_below_species_h_per_m = fixed.aerodynamic_resistance_below_species_h_per_m,
        .species_canopy_radiation_fraction = fixed.absorbed_radiation_fraction,
        .latent_boundary_numerator_m2_per_h = fixed.latent_boundary_numerator_m2_per_h,
        .sensible_boundary_numerator_megajoules_per_m_h_k = fixed.sensible_boundary_numerator_megajoules_per_m_h_k,
        .sensible_surface_resistance_h_per_m = fixed.sensible_surface_resistance_h_per_m,
        .latent_surface_resistance_h_per_m = fixed.latent_surface_resistance_h_per_m,
        .stomatal_resistance_h_per_m = stomatal_resistance,
        .canopy_total_water_potential_megapascal = fixed.canopy_total_water_potential_megapascal,
        .intercepted_water_volume_m3 = fixed.substep.canopy_surface_water_m3,
    }, settings.surface_exchange_parameters);

    const radiation = try radiation_iteration.calculate(.{
        .canopy_water_capacity_m3 = osmotic.canopy_water_volume_m3,
        .current_canopy_water_m3 = fixed.heat_initialization.previous_canopy_water_m3,
        .legacy_substep_multiplier = 1.0,
        .emitted_longwave_coefficient_megajoules_per_step_k4 = fixed.fixed_terms.emitted_longwave_coefficient_megajoules_per_step_k4,
        .canopy_surface_temperature_k = trial_temperature_k,
        .ground_surface_temperature_k = fixed.ground_surface_temperature_k,
        .absorbed_radiation_fraction = fixed.absorbed_radiation_fraction,
        .absorbed_sky_longwave_megajoules_per_step = fixed.fixed_terms.absorbed_sky_longwave_megajoules_per_step,
        .absorbed_lateral_longwave_megajoules_per_step = fixed.fixed_terms.absorbed_lateral_longwave_megajoules_per_step,
        .absorbed_shortwave_radiation_megajoules_per_step = fixed.fixed_terms.absorbed_shortwave_radiation_megajoules_per_step,
    });

    // UPTAKE.F 1026: HFLXCCM = RFLXCCM+EFLXCCM+SFLXCCM+VFLXCCM+HFLWCCM.
    const storage_flux = radiation.net_canopy_radiation_megajoules_per_step +
        surface.latent_heat_flux_megajoules_per_h * settings.heat_flux_timestep_h +
        surface.sensible_heat_flux_megajoules_per_h * settings.heat_flux_timestep_h +
        surface.vapor_sensible_heat_flux_megajoules_per_h * settings.heat_flux_timestep_h +
        fixed.substep.retained_foliar_water_heat_megajoules_per_step;

    // UPTAKE.F 1041: VHCPCC = VHCPCX + 4.19*(EVAPCCM+FLWCCM).
    const evaporation_m3_per_step = surface.intercepted_water_change_m3_per_h * settings.heat_flux_timestep_h;
    const wet_heat_capacity = fixed.heat_initialization.wet_canopy_heat_capacity_megajoules_per_k +
        settings.liquid_water_heat_capacity_megajoules_per_m3_k *
            (evaporation_m3_per_step + fixed.heat_initialization.retained_foliar_water_m3_per_step);

    // UPTAKE.F 1042--1048: gated fixed point. Below the threshold, TKCZ=TKCX
    // (the loop's own current iterate), i.e. a trivial fixed point.
    const picard_target = if (wet_heat_capacity > fixed.heat_initialization.low_heat_capacity_threshold_megajoules_per_k)
        (trial_temperature_k * fixed.heat_initialization.wet_canopy_heat_capacity_megajoules_per_k + storage_flux) / wet_heat_capacity
    else
        trial_temperature_k;

    const result: Evaluation = .{
        .osmotic = osmotic,
        .surface = surface,
        .radiation = radiation,
        .stomatal_resistance_h_per_m = stomatal_resistance,
        .storage_flux_megajoules_per_step = storage_flux,
        .wet_heat_capacity_megajoules_per_k = wet_heat_capacity,
        .picard_target_k = picard_target,
    };
    if (!std.math.isFinite(result.picard_target_k) or !std.math.isFinite(result.wet_heat_capacity_megajoules_per_k))
        return error.NonFiniteCanopyCoupledConvergenceEvaluation;
    return result;
}

fn validateSettings(settings: Settings) !void {
    if (!std.math.isFinite(settings.heat_flux_timestep_h) or settings.heat_flux_timestep_h <= 0 or
        !std.math.isFinite(settings.liquid_water_heat_capacity_megajoules_per_m3_k) or settings.liquid_water_heat_capacity_megajoules_per_m3_k < 0 or
        !std.math.isFinite(settings.minimum_temperature_k) or !std.math.isFinite(settings.maximum_temperature_k) or
        settings.minimum_temperature_k <= 0 or settings.minimum_temperature_k >= settings.maximum_temperature_k)
        return error.InvalidCanopyCoupledConvergenceSettings;
}

fn validateFixedInputs(fixed: FixedInputs) !void {
    inline for (.{
        fixed.ground_surface_temperature_k,
        fixed.absorbed_radiation_fraction,
        fixed.atmospheric_temperature_k,
        fixed.bulk_richardson_coefficient_k,
        fixed.biome_isothermal_boundary_resistance_h_per_m,
        fixed.aerodynamic_resistance_below_biome_h_per_m,
        fixed.aerodynamic_resistance_below_species_h_per_m,
        fixed.latent_boundary_numerator_m2_per_h,
        fixed.sensible_boundary_numerator_megajoules_per_m_h_k,
        fixed.sensible_surface_resistance_h_per_m,
        fixed.latent_surface_resistance_h_per_m,
        fixed.canopy_air_vapor_fraction,
        fixed.canopy_total_water_potential_megapascal,
        fixed.minimum_dry_matter_fraction_g_c_per_g,
        fixed.canopy_water_mass_g,
        fixed.osmotic_potential_at_zero_total_megapascal,
        fixed.canopy_salt_concentration_mol_per_g_c,
        fixed.minimum_stomatal_resistance_h_per_m,
        fixed.cuticular_resistance_h_per_m,
        fixed.stomatal_turgor_shape_per_megapascal,
    }) |value| if (!std.math.isFinite(value)) return error.InvalidCanopyCoupledConvergenceInput;
    if (fixed.ground_surface_temperature_k <= 0 or
        fixed.absorbed_radiation_fraction < 0 or
        fixed.atmospheric_temperature_k <= 0 or
        fixed.biome_isothermal_boundary_resistance_h_per_m < 0 or
        fixed.aerodynamic_resistance_below_biome_h_per_m < 0 or
        fixed.aerodynamic_resistance_below_species_h_per_m < 0 or
        fixed.latent_boundary_numerator_m2_per_h < 0 or
        fixed.sensible_boundary_numerator_megajoules_per_m_h_k < 0 or
        fixed.sensible_surface_resistance_h_per_m < 0 or
        fixed.latent_surface_resistance_h_per_m < 0 or
        fixed.canopy_air_vapor_fraction < 0 or
        fixed.cuticular_resistance_h_per_m < fixed.minimum_stomatal_resistance_h_per_m)
        return error.InvalidCanopyCoupledConvergenceInput;
}

// CANOPY-TKC-001 Sub-task B (register: amendment 2/3's "outer coupling with
// root uptake"): wires this module's converged transpiration into
// `water_balance.solveSinglePlant`'s existing root-uptake solve as its
// `transpiration_loss_m` input, and feeds that solve's converged canopy
// total water potential back into this module's `canopy_total_water_potential_megapascal`
// fixed input for the next outer iterate -- `uptake.f:1140--1216`'s `DPSI`
// outer relaxation, expressed as an explicit Newton/Anderson-Picard root
// find on canopy total water potential rather than porting legacy's
// bisection bookkeeping (MIGRATION.md bans reproducing legacy's hand-rolled
// bisection; sub-task A already established this precedent for TKCY).

pub const OuterRootInputs = struct {
    soil_water_potential_megapascal: []const f64,
    root_conductance_m_per_h_megapascal: []const f64,
    maximum_uptake_m: []const f64,
    maximum_release_m: []const f64,
    active_layer_count: usize,
    layer_capacity: usize,
    root_domain_count: usize,
    canopy_gravitational_offset_megapascal: f64 = 0,
};

pub const OuterCoupledFixedInputs = struct {
    /// `canopy_total_water_potential_megapascal` is overwritten every outer
    /// iterate; any finite value here satisfies `validateFixedInputs`.
    canopy: FixedInputs,
    root: OuterRootInputs,
    canopy_water_capacitance_m_per_m2_megapascal: f64,
    cell_area_m2: f64,
    previous_canopy_water_potential_megapascal: f64,
};

pub const OuterCoupledSettings = struct {
    canopy_settings: Settings,
    water_balance_settings: water_balance.Settings,
    outer_solver_options: numerics.SolverOptions,
    /// `uptake.f:474,1225--1228`: STOMATE runs before the coupled solve and
    /// once more after its first accepted convergence, immediately before the
    /// final pass. Null is retained for isolated kernel callers; production
    /// supplies this boundary for every living canopy.
    stomate_final_pass: ?StomateFinalPass = null,
};

pub const StomateFinalPass = struct {
    inputs: minimum_stomatal.Inputs,
    /// `CO2Q-CO2I` in umol mol-1. STOMATE converts it with
    /// `FMOL=1.2194E+04/TKC` on both calls, so the final call observes the
    /// temperature converged by the first canopy pass.
    canopy_to_intercellular_co2_difference_umol_per_mol: f64,
    /// Optional source-order producer for STOMATE's CH2O. Production binds
    /// this to the side-effect-free canopy capacity/radiation calculation so
    /// both calls recompute gas kinetics and capacity at their own TKC. The
    /// opaque callback keeps this convergence owner independent of canopy
    /// topology while retaining a scalar, allocation-free boundary.
    maximum_turgor_carboxylation: ?MaximumTurgorCarboxylationProducer = null,
};

pub const MaximumTurgorCarboxylationProducer = struct {
    context: *const anyopaque,
    evaluate_fn: *const fn (*const anyopaque, f64) anyerror!f64,

    pub fn evaluate(self: MaximumTurgorCarboxylationProducer, canopy_surface_temperature_k: f64) !f64 {
        return self.evaluate_fn(self.context, canopy_surface_temperature_k);
    }
};

pub const StomateEvaluation = struct {
    minimum_stomatal_resistance_h_per_m: f64,
    maximum_turgor_carboxylation_umol_per_s: f64,
};

pub const OuterCoupledResult = struct {
    canopy: Result,
    water: water_balance.SinglePlantWaterBalanceResult,
    canopy_total_water_potential_megapascal: f64,
    outer_iterations: u16,
    outer_newton_raphson_steps: u16,
    outer_picard_steps: u16,
    outer_anderson_steps: u16,
    initial_minimum_stomatal_resistance_h_per_m: f64,
    final_minimum_stomatal_resistance_h_per_m: f64,
    initial_maximum_turgor_carboxylation_umol_per_s: f64,
    final_maximum_turgor_carboxylation_umol_per_s: f64,
    stomate_final_pass_applied: bool,
    /// Total nonlinear method iterations attempted across the outer potential
    /// solve and every nested canopy-temperature/root-water solve used to
    /// evaluate it. Line-search and finite-difference probes are not included.
    attempted_nonlinear_iterations: u16,
};

/// Builds the exact STOMATE RSMN boundary for a particular canopy surface
/// temperature without publishing it. Keeping this pure is what lets the
/// hourly caller stage both the first call and the final-pass reset and leave
/// no changed plant state when either nonlinear pass fails.
pub fn minimumStomatalResistanceAtTemperature(
    boundary: StomateFinalPass,
    canopy_surface_temperature_k: f64,
) !f64 {
    return (try evaluateStomateAtTemperature(boundary, canopy_surface_temperature_k)).minimum_stomatal_resistance_h_per_m;
}

/// Replays STOMATE's current-temperature CH2O -> RSMN causal chain without
/// publishing any canopy state. `stomate.f:55--73,87--629,656--665` computes
/// both quantities inside each call; carrying the prior GROSUB CH2O across
/// this boundary is therefore not source-equivalent.
pub fn evaluateStomateAtTemperature(
    boundary: StomateFinalPass,
    canopy_surface_temperature_k: f64,
) !StomateEvaluation {
    if (!std.math.isFinite(canopy_surface_temperature_k) or canopy_surface_temperature_k <= 0 or
        !std.math.isFinite(boundary.canopy_to_intercellular_co2_difference_umol_per_mol) or
        boundary.canopy_to_intercellular_co2_difference_umol_per_mol < 0)
        return error.InvalidCanopyStomateFinalPassInput;
    var inputs = boundary.inputs;
    if (boundary.maximum_turgor_carboxylation) |producer|
        inputs.canopy_co2_fixation_umol_per_s = try producer.evaluate(canopy_surface_temperature_k);
    // stomate.f:55--56/73.
    inputs.co2_concentration_difference_umol_per_m3 =
        12_194.0 / canopy_surface_temperature_k *
        boundary.canopy_to_intercellular_co2_difference_umol_per_mol;
    return .{
        .minimum_stomatal_resistance_h_per_m = try minimum_stomatal.compute(inputs),
        .maximum_turgor_carboxylation_umol_per_s = inputs.canopy_co2_fixation_umol_per_s,
    };
}

const OuterEvaluation = struct {
    canopy: Result,
    water: water_balance.SinglePlantWaterBalanceResult,
};

const OuterContext = struct {
    fixed: *const OuterCoupledFixedInputs,
    settings: *const OuterCoupledSettings,
    captured_error: ?anyerror = null,
    last_psi: f64 = std.math.nan(f64),
    last_evaluation: ?OuterEvaluation = null,
};

/// One full outer iterate: solve TKCY at the trial canopy total water
/// potential (holding it fixed for this inner solve, per sub-task A's own
/// contract), convert the converged transpiration to a depth rate, then
/// solve root uptake against it.
/// Converts UPTAKE's source-signed EPCCM to the signed atmospheric-boundary
/// depth used by the whole-hour hydraulic residual. Negative EPCCM is an
/// outflow (positive returned depth); positive EPCCM is a canopy gain
/// (negative returned depth). Keeping the gain branch is required by
/// `uptake.f:1190--1192`, where DIFFU=EPCCM-UPRTM retains both signs.
pub fn netCanopyWaterOutflowDepthM(net_canopy_water_flux_m3_per_step: f64, cell_area_m2: f64) !f64 {
    if (!std.math.isFinite(net_canopy_water_flux_m3_per_step) or
        !std.math.isFinite(cell_area_m2) or cell_area_m2 <= 0)
        return error.InvalidCanopyOuterCoupledInput;
    return -net_canopy_water_flux_m3_per_step / cell_area_m2;
}

fn outerEvaluate(ctx: *const OuterContext, canopy_total_water_potential_megapascal: f64) !OuterEvaluation {
    var canopy_fixed = ctx.fixed.canopy;
    canopy_fixed.canopy_total_water_potential_megapascal = canopy_total_water_potential_megapascal;
    const canopy_result = try solve(canopy_fixed, ctx.settings.canopy_settings);
    // EPCCM follows UPTAKE's sign convention: net water leaving the canopy is
    // negative and becomes positive hydraulic outflow depth. A positive EPCCM
    // remains a signed gain; unlike the atmospheric ledger this residual must
    // include VOLWPDM's canopy-capacity adjustment.
    const transpiration_loss_m = try netCanopyWaterOutflowDepthM(canopy_result.transpiration_m3_per_step, ctx.fixed.cell_area_m2);
    const water_result = try water_balance.solveSinglePlant(.{
        .soil_water_potential_megapascal = ctx.fixed.root.soil_water_potential_megapascal,
        .root_conductance_m_per_h_megapascal = ctx.fixed.root.root_conductance_m_per_h_megapascal,
        .maximum_uptake_m = ctx.fixed.root.maximum_uptake_m,
        .maximum_release_m = ctx.fixed.root.maximum_release_m,
        .previous_canopy_water_potential_megapascal = ctx.fixed.previous_canopy_water_potential_megapascal,
        .canopy_water_capacitance_m_per_m2_megapascal = ctx.fixed.canopy_water_capacitance_m_per_m2_megapascal,
        .transpiration_loss_m = transpiration_loss_m,
        .active_layer_count = ctx.fixed.root.active_layer_count,
        .layer_capacity = ctx.fixed.root.layer_capacity,
        .root_domain_count = ctx.fixed.root.root_domain_count,
        .canopy_gravitational_offset_megapascal = ctx.fixed.root.canopy_gravitational_offset_megapascal,
        .settings = ctx.settings.water_balance_settings,
    });
    return .{ .canopy = canopy_result, .water = water_result };
}

fn outerEvaluateAndCache(ctx: *OuterContext, canopy_total_water_potential_megapascal: f64) !OuterEvaluation {
    const evaluated = try outerEvaluate(ctx, canopy_total_water_potential_megapascal);
    ctx.last_psi = canopy_total_water_potential_megapascal;
    ctx.last_evaluation = evaluated;
    return evaluated;
}

/// Outer Newton/Anderson-Picard root find on canopy total water potential:
/// `F(psi) = water_balance(coupled_convergence(psi)).canopy_water_potential - psi`.
pub fn solveOuterCoupled(fixed: OuterCoupledFixedInputs, settings: OuterCoupledSettings) !OuterCoupledResult {
    try validateOuterInputs(fixed);

    // This routine owns the coupled transaction budget. Accepting caller-
    // supplied child pointers would permit split counters or a silent opt-out,
    // so all three option sets must arrive unbound and are rebound together.
    if (settings.outer_solver_options.shared_budget != null or
        settings.canopy_settings.solver_options.shared_budget != null or
        settings.water_balance_settings.solver_options.shared_budget != null)
        return error.InvalidCanopySharedBudgetConfiguration;
    var budget = try numerics.NonlinearBudget.init(settings.outer_solver_options.max_iterations);
    var budgeted_settings = settings;
    budgeted_settings.outer_solver_options.shared_budget = &budget;
    budgeted_settings.canopy_settings.solver_options.max_iterations = @min(
        budgeted_settings.canopy_settings.solver_options.max_iterations,
        budget.limit,
    );
    budgeted_settings.canopy_settings.solver_options.shared_budget = &budget;
    budgeted_settings.water_balance_settings.solver_options.max_iterations = @min(
        budgeted_settings.water_balance_settings.solver_options.max_iterations,
        budget.limit,
    );
    budgeted_settings.water_balance_settings.solver_options.shared_budget = &budget;

    var first_fixed = fixed;
    var initial_minimum = fixed.canopy.minimum_stomatal_resistance_h_per_m;
    var initial_carboxylation: f64 = 0;
    if (settings.stomate_final_pass) |stomate| {
        const initial_stomate = try evaluateStomateAtTemperature(
            stomate,
            fixed.canopy.heat_initialization.previous_canopy_temperature_k,
        );
        initial_minimum = initial_stomate.minimum_stomatal_resistance_h_per_m;
        initial_carboxylation = initial_stomate.maximum_turgor_carboxylation_umol_per_s;
        first_fixed.canopy.minimum_stomatal_resistance_h_per_m = initial_minimum;
    }
    var result = try solveOuterCoupledPass(
        first_fixed,
        &budgeted_settings,
        fixed.previous_canopy_water_potential_megapascal,
    );
    result.initial_minimum_stomatal_resistance_h_per_m = initial_minimum;
    result.final_minimum_stomatal_resistance_h_per_m = initial_minimum;
    result.initial_maximum_turgor_carboxylation_umol_per_s = initial_carboxylation;
    result.final_maximum_turgor_carboxylation_umol_per_s = initial_carboxylation;
    result.attempted_nonlinear_iterations = budget.attempted_iterations;

    const stomate = settings.stomate_final_pass orelse return result;
    const first_control = try convergence_pass_control.evaluate(.{
        .final_check_pending = false,
        .outer_iteration = 1,
        .maximum_outer_iterations = 1,
        .inner_iteration = @max(1, result.outer_iterations),
        .maximum_observed_inner_iterations = 0,
    });
    if (first_control.action != .continue_iteration or
        !first_control.reset_stomatal_minimum_before_final_pass)
        return error.InvalidCanopyFinalPassControl;
    const first = result;

    // The first converged TKCY is the source's temperature seen by the
    // second STOMATE call. Only after RSMN has been reset do we execute the
    // final coupled pass, so its transpiration and heat fluxes cannot retain
    // the stale boundary.
    const final_stomate = try evaluateStomateAtTemperature(
        stomate,
        result.canopy.canopy_surface_temperature_k,
    );
    const final_minimum = final_stomate.minimum_stomatal_resistance_h_per_m;
    var final_fixed = fixed;
    final_fixed.canopy.minimum_stomatal_resistance_h_per_m = final_minimum;
    const final = try solveOuterCoupledPass(
        final_fixed,
        &budgeted_settings,
        first.canopy_total_water_potential_megapascal,
    );
    const second_control = try convergence_pass_control.evaluate(.{
        .final_check_pending = first_control.final_check_pending,
        .outer_iteration = 1,
        .maximum_outer_iterations = 1,
        .inner_iteration = @max(1, final.outer_iterations),
        .maximum_observed_inner_iterations = first_control.maximum_observed_inner_iterations,
    });
    if (second_control.action != .finish_subproblem or
        second_control.reset_stomatal_minimum_before_final_pass)
        return error.InvalidCanopyFinalPassControl;

    result = final;
    result.outer_iterations = try std.math.add(u16, first.outer_iterations, final.outer_iterations);
    result.outer_newton_raphson_steps = try std.math.add(u16, first.outer_newton_raphson_steps, final.outer_newton_raphson_steps);
    result.outer_picard_steps = try std.math.add(u16, first.outer_picard_steps, final.outer_picard_steps);
    result.outer_anderson_steps = try std.math.add(u16, first.outer_anderson_steps, final.outer_anderson_steps);
    result.initial_minimum_stomatal_resistance_h_per_m = initial_minimum;
    result.final_minimum_stomatal_resistance_h_per_m = final_minimum;
    result.initial_maximum_turgor_carboxylation_umol_per_s = initial_carboxylation;
    result.final_maximum_turgor_carboxylation_umol_per_s = final_stomate.maximum_turgor_carboxylation_umol_per_s;
    result.stomate_final_pass_applied = true;
    result.attempted_nonlinear_iterations = budget.attempted_iterations;
    return result;
}

fn solveOuterCoupledPass(
    fixed: OuterCoupledFixedInputs,
    budgeted_settings: *const OuterCoupledSettings,
    initial_canopy_water_potential_megapascal: f64,
) !OuterCoupledResult {
    var context: OuterContext = .{ .fixed = &fixed, .settings = budgeted_settings };
    var options = budgeted_settings.outer_solver_options;
    options.residual_scale = @max(0.1, @abs(fixed.previous_canopy_water_potential_megapascal));

    const Callbacks = struct {
        fn residualFn(ctx: *OuterContext, psi: f64) f64 {
            const eval = outerEvaluateAndCache(ctx, psi) catch |err| {
                ctx.captured_error = err;
                return std.math.nan(f64);
            };
            return eval.water.canopy_water_potential_megapascal - psi;
        }
        fn picardFn(ctx: *OuterContext, psi: f64) f64 {
            const eval = outerEvaluateAndCache(ctx, psi) catch |err| {
                ctx.captured_error = err;
                return std.math.nan(f64);
            };
            return eval.water.canopy_water_potential_megapascal;
        }
    };

    const solved = numerics.newtonPicardFiniteDifference(
        &context,
        Callbacks.residualFn,
        Callbacks.picardFn,
        budgeted_settings.water_balance_settings.minimum_canopy_water_potential_megapascal,
        budgeted_settings.water_balance_settings.maximum_canopy_water_potential_megapascal,
        std.math.clamp(
            initial_canopy_water_potential_megapascal,
            budgeted_settings.water_balance_settings.minimum_canopy_water_potential_megapascal,
            budgeted_settings.water_balance_settings.maximum_canopy_water_potential_megapascal,
        ),
        options,
    ) catch |err| {
        if (context.captured_error) |captured| return captured;
        return err;
    };

    // The generic solver's convergence/final-ceiling residual audit evaluated
    // this exact root and cached both nested results. Re-running the nested
    // solvers here would attempt work after the nonlinear-iteration ceiling.
    if (context.last_evaluation == null or context.last_psi != solved.root)
        return error.MissingCanopyCoupledFinalEvaluation;
    const final = context.last_evaluation.?;
    return .{
        .canopy = final.canopy,
        .water = final.water,
        .canopy_total_water_potential_megapascal = solved.root,
        .outer_iterations = solved.iterations,
        .outer_newton_raphson_steps = solved.newton_raphson_steps,
        .outer_picard_steps = solved.picard_steps,
        .outer_anderson_steps = solved.anderson_steps,
        .initial_minimum_stomatal_resistance_h_per_m = fixed.canopy.minimum_stomatal_resistance_h_per_m,
        .final_minimum_stomatal_resistance_h_per_m = fixed.canopy.minimum_stomatal_resistance_h_per_m,
        .initial_maximum_turgor_carboxylation_umol_per_s = 0,
        .final_maximum_turgor_carboxylation_umol_per_s = 0,
        .stomate_final_pass_applied = false,
        .attempted_nonlinear_iterations = 0,
    };
}

fn validateOuterInputs(fixed: OuterCoupledFixedInputs) !void {
    if (!std.math.isFinite(fixed.cell_area_m2) or fixed.cell_area_m2 <= 0) return error.InvalidCanopyOuterCoupledInput;
    if (!std.math.isFinite(fixed.canopy_water_capacitance_m_per_m2_megapascal) or fixed.canopy_water_capacitance_m_per_m2_megapascal <= 0) return error.InvalidCanopyOuterCoupledInput;
    if (!std.math.isFinite(fixed.previous_canopy_water_potential_megapascal) or fixed.previous_canopy_water_potential_megapascal > 0) return error.InvalidCanopyOuterCoupledInput;
    if (fixed.root.layer_capacity == 0 or fixed.root.root_domain_count == 0 or fixed.root.active_layer_count > fixed.root.layer_capacity) return error.InvalidCanopyOuterCoupledInput;
    if (!std.math.isFinite(fixed.root.canopy_gravitational_offset_megapascal) or fixed.root.canopy_gravitational_offset_megapascal < 0) return error.InvalidCanopyOuterCoupledInput;
    const roots_per_plant = fixed.root.root_domain_count * fixed.root.layer_capacity;
    if (fixed.root.soil_water_potential_megapascal.len != fixed.root.layer_capacity or
        fixed.root.root_conductance_m_per_h_megapascal.len != roots_per_plant or
        fixed.root.maximum_uptake_m.len != roots_per_plant or
        fixed.root.maximum_release_m.len != roots_per_plant) return error.InvalidCanopyOuterCoupledInput;
}

fn sourceHeatInitialization() water_heat_initialization.Result {
    return water_heat_initialization.calculate(.{
        .foliar_water_retention_m3_per_h = 0.02,
        .water_flux_timestep_h = 0.25,
        .current_canopy_water_m3 = 0.3,
        .previous_hydrologically_active_carbon_g_c = 7,
        .leaf_and_petiole_carbon_g_c = 10,
        .stalk_carbon_g_c = 8,
        .sapwood_thickness_m = 0.02,
        .stalk_surface_area_m2 = 20,
        .stalk_volume_per_carbon_m3_per_g_c = 0.1,
        .canopy_total_water_potential_megapascal = -1,
        .minimum_dry_matter_fraction = 0.16,
        .canopy_surface_water_m3 = 0.1,
        .dry_carbon_heat_capacity_megajoules_per_m3_k = 2.496,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .high_heat_capacity_threshold_megajoules_per_m2_k = 0.838e-3,
        .low_heat_capacity_threshold_megajoules_per_m2_k = 0.838e-4,
        .cell_area_m2 = 100,
        .current_canopy_temperature_k = 295,
        .high_capacity_temperature_step_k = 0.125,
        .low_capacity_temperature_step_k = 0.025,
        .water_volume_per_carbon_scale_m3_per_g_c = 1e-6,
        .dry_matter_potential_numerator = 0.10,
        .dry_matter_potential_denominator_coefficient = 0.05,
        .dry_matter_potential_denominator_intercept = 2,
    }) catch unreachable;
}

fn sourceSubstep(canopy_surface_temperature_k: f64) substep_initialization.Result {
    return substep_initialization.calculate(.{
        .canopy_air_temperature_k = 293,
        .canopy_air_heat_capacity_megajoules_per_k = 2,
        .negligible_canopy_air_heat_capacity_megajoules_per_k = 1e-12,
        .canopy_radiation_share = 0.5,
        .negligible_canopy_radiation_share = 1e-12,
        .previous_combustion_heat_megajoules_per_step = 0,
        .legacy_substep_multiplier = 0.25,
        .canopy_surface_water_m3 = 0.1,
        .retained_foliar_water_m3_per_step = 0.005,
        .canopy_surface_temperature_k = canopy_surface_temperature_k,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
    }) catch unreachable;
}

fn sourceFixedTerms() fixed_terms.Result {
    return fixed_terms.calculate(.{
        .canopy_total_water_potential_megapascal = -1,
        .absorbed_shortwave_radiation_megajoules_per_h = 4,
        .heat_flux_timestep_h = 0.25,
        .canopy_emissivity = 0.97,
        .stefan_boltzmann_megajoules_per_h_m2_k4 = 2.04e-10,
        .absorbed_radiation_fraction = 0.4,
        .cell_area_m2 = 100,
        .sky_longwave_radiation_megajoules_per_h = 2,
        .lateral_longwave_radiation_megajoules_per_step = -0.2,
        .canopy_radiation_share = 0.3,
        .nonstructural_carbon_concentration_g_c_per_g_c = 0.1,
        .nonstructural_nitrogen_concentration_g_n_per_g_c = 0.02,
        .nonstructural_phosphorus_concentration_g_p_per_g_c = 0.01,
        .osmotic_molar_mass_intercept_g_per_mol = 144,
        .osmotic_molar_mass_slope_g_per_mol = 840,
        .latent_boundary_conductance_m2_per_step = 5,
        .sensible_boundary_conductance_megajoules_per_m_k_step = 6,
    }) catch unreachable;
}

fn sourceFixedInputs() FixedInputs {
    const heat_initialization = sourceHeatInitialization();
    return .{
        .heat_initialization = heat_initialization,
        .substep = sourceSubstep(heat_initialization.previous_canopy_temperature_k),
        .fixed_terms = sourceFixedTerms(),
        .ground_surface_temperature_k = 292,
        .absorbed_radiation_fraction = 0.4,
        .atmospheric_temperature_k = 293,
        .bulk_richardson_coefficient_k = 1,
        .biome_isothermal_boundary_resistance_h_per_m = 0.005,
        .aerodynamic_resistance_below_biome_h_per_m = 0.01,
        .aerodynamic_resistance_below_species_h_per_m = 0.004,
        .latent_boundary_numerator_m2_per_h = 10,
        .sensible_boundary_numerator_megajoules_per_m_h_k = 0.125,
        .sensible_surface_resistance_h_per_m = 0.004,
        .latent_surface_resistance_h_per_m = 0.002,
        // VPQ is vapor volume fraction (m3 m-3), not vapor pressure (kPa).
        // 1.9 kPa at 293 K is approximately 1.4e-5 by the source conversion.
        .canopy_air_vapor_fraction = 1.4e-5,
        .canopy_total_water_potential_megapascal = -1,
        .minimum_dry_matter_fraction_g_c_per_g = 0.16,
        .canopy_water_mass_g = 100,
        .osmotic_potential_at_zero_total_megapascal = -1.5,
        .canopy_salt_concentration_mol_per_g_c = 0.001,
        .minimum_stomatal_resistance_h_per_m = 0.003,
        .cuticular_resistance_h_per_m = 0.03,
        .stomatal_turgor_shape_per_megapascal = -0.2,
    };
}

fn sourceSettings() Settings {
    return .{
        .heat_flux_timestep_h = 0.25,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .minimum_temperature_k = 250,
        .maximum_temperature_k = 330,
        .surface_exchange_parameters = .{
            .minimum_richardson_number = -0.1,
            .maximum_richardson_number = 0.05,
            .richardson_resistance_multiplier = 10,
            .minimum_boundary_resistance_h_per_m = 0.00139,
            .maximum_boundary_resistance_h_per_m = 0.0139,
            .saturation_vapor_prefactor_k = 2.173e-3,
            .saturation_relative_humidity = 0.61,
            .saturation_temperature_k = 5360,
            .saturation_reference_inverse_temperature_per_k = 3.661e-3,
            .water_potential_vapor_coefficient_mol_per_m3 = 18,
            .universal_gas_constant_j_per_mol_k = 8.3143,
            .latent_heat_of_vaporization_megajoules_per_m3 = 2465,
            .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        },
        .solver_options = .{ .residual_scale = 1, .max_iterations = 100 },
    };
}

test "coupled convergence solves TKCY to a genuine fixed point of the source residual" {
    const fixed = sourceFixedInputs();
    const settings = sourceSettings();
    const result = try solve(fixed, settings);
    try std.testing.expect(result.iterations < settings.solver_options.max_iterations);
    try std.testing.expect(!result.heat_capacity_gated_frozen);

    // Independent check: recompute the picard target at the published root
    // and confirm it reproduces the root, i.e. the published temperature is
    // genuinely a fixed point of `uptake.f:1044`'s TKCZ map, not just
    // whatever the driver last held. This substitutes for an
    // analytic-derivative cross-check (the residual composes four modules
    // through branches that make hand-differentiation impractical, so this
    // module uses `numerics.newtonPicardFiniteDifference`, matching
    // `plant/root/water_balance.zig`'s established precedent for
    // multi-module residuals of this shape).
    const eval = try evaluate(fixed, settings, result.canopy_surface_temperature_k);
    try std.testing.expectApproxEqAbs(result.canopy_surface_temperature_k, eval.picard_target_k, 1e-6);
    try std.testing.expect(@abs(result.canopy_surface_temperature_k - fixed.heat_initialization.previous_canopy_temperature_k) > 1e-6);

    // `hourly_vegetation` passes this published temperature directly to
    // canopy biochemistry. Show that the solve changes a concrete downstream
    // TFN3 state, rather than merely updating an otherwise-unused carrier.
    const growth_temperature = @import("../../plant/response/growth_temperature.zig");
    const previous_response = try growth_temperature.response(fixed.heat_initialization.previous_canopy_temperature_k, growth_temperature.compatibilityParameters());
    const coupled_response = try growth_temperature.response(result.canopy_surface_temperature_k, growth_temperature.compatibilityParameters());
    try std.testing.expect(@abs(coupled_response - previous_response) > 1e-10);
}

test "heat capacity gate freezes TKCY exactly like uptake.f:1042's VHCPCC.LE.VHCPYZ branch" {
    var fixed = sourceFixedInputs();
    // Push the gate threshold above any reachable VHCPCC so the ELSE branch
    // (TKCZ=TKCX=TKCY, i.e. no movement) is exercised every iteration.
    fixed.heat_initialization.low_heat_capacity_threshold_megajoules_per_k = 1.0e6;
    const settings = sourceSettings();
    const result = try solve(fixed, settings);
    try std.testing.expect(result.heat_capacity_gated_frozen);
    try std.testing.expectApproxEqAbs(
        fixed.heat_initialization.previous_canopy_temperature_k,
        result.canopy_surface_temperature_k,
        1e-9,
    );
}

test "stronger sensible coupling pulls converged TKCY toward the fixed canopy air temperature" {
    // Qualitative/limiting-case check (substitutes for the register's
    // "night, zero-radiation collapse" test, which belongs to
    // `air_exchange.zig`'s TKQY/VPQY update, not this module's TKCY-only
    // scope): raising the sensible surface conductance (lowering its
    // resistance) should monotonically pull the solved TKCY closer to the
    // fixed TKQY it is exchanging heat with, all else equal.
    var loose = sourceFixedInputs();
    loose.sensible_surface_resistance_h_per_m = 0.02;
    var tight = sourceFixedInputs();
    tight.sensible_surface_resistance_h_per_m = 0.0005;
    const settings = sourceSettings();
    const loose_result = try solve(loose, settings);
    const tight_result = try solve(tight, settings);
    const canopy_air_temperature_k = loose.substep.canopy_air_temperature_k;
    try std.testing.expect(
        @abs(tight_result.canopy_surface_temperature_k - canopy_air_temperature_k) <
            @abs(loose_result.canopy_surface_temperature_k - canopy_air_temperature_k),
    );
}

test "coupled convergence rejects non-finite fixed input" {
    var fixed = sourceFixedInputs();
    fixed.atmospheric_temperature_k = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidCanopyCoupledConvergenceInput,
        solve(fixed, sourceSettings()),
    );
}

test "coupled convergence rejects an invalid solver bound" {
    var settings = sourceSettings();
    settings.minimum_temperature_k = settings.maximum_temperature_k;
    try std.testing.expectError(
        error.InvalidCanopyCoupledConvergenceSettings,
        solve(sourceFixedInputs(), settings),
    );
}

fn sourceOuterFixedInputs() OuterCoupledFixedInputs {
    return .{
        .canopy = sourceFixedInputs(),
        .root = .{
            .soil_water_potential_megapascal = &.{ -0.2, -0.4 },
            .root_conductance_m_per_h_megapascal = &.{ 0.004, 0.002 },
            .maximum_uptake_m = &.{ 0.01, 0.01 },
            .maximum_release_m = &.{ 0.01, 0.01 },
            .active_layer_count = 2,
            .layer_capacity = 2,
            .root_domain_count = 1,
        },
        .canopy_water_capacitance_m_per_m2_megapascal = 0.002,
        .cell_area_m2 = 100,
        .previous_canopy_water_potential_megapascal = -1.0,
    };
}

fn sourceOuterSettings() OuterCoupledSettings {
    return .{
        .canopy_settings = sourceSettings(),
        .water_balance_settings = .{
            .minimum_canopy_water_potential_megapascal = -10,
            .maximum_canopy_water_potential_megapascal = -0.001,
            .solver_options = .{ .residual_scale = 0.01, .max_iterations = 200 },
        },
        .outer_solver_options = .{ .residual_scale = 1, .max_iterations = 100 },
    };
}

fn sourceStomateFinalPass() StomateFinalPass {
    return .{
        .inputs = .{
            .photosynthesis_active = true,
            .canopy_co2_fixation_umol_per_s = 5_000,
            .negligible_fixation_umol_per_s = 1.0e-12,
            .canopy_radiation_fraction = 0.4,
            .co2_concentration_difference_umol_per_m3 = 0,
            .horizontal_cell_area_m2 = 100,
            .seconds_per_hour = 3_600,
            .cuticular_water_vapor_resistance_h_per_m = 0.03,
            .co2_to_water_cuticular_resistance_ratio = 1.56,
            .minimum_co2_stomatal_resistance_h_per_m = 2.78e-3,
            .co2_to_water_stomatal_resistance_ratio = 0.641,
        },
        .canopy_to_intercellular_co2_difference_umol_per_mol = 120,
    };
}

test "outer coupling converges to a self-consistent transpiration/water-potential fixed point" {
    const fixed = sourceOuterFixedInputs();
    const settings = sourceOuterSettings();
    const result = try solveOuterCoupled(fixed, settings);
    try std.testing.expect(result.outer_iterations < settings.outer_solver_options.max_iterations);
    try std.testing.expect(result.attempted_nonlinear_iterations <= settings.outer_solver_options.max_iterations);
    try std.testing.expect(result.attempted_nonlinear_iterations >= result.outer_iterations);

    // Independent check: re-evaluate at the published root and confirm the
    // water-balance solve reproduces the same psi, i.e. the outer loop
    // genuinely stopped at a fixed point of the composed
    // TKCY-solve -> transpiration -> root-uptake-solve chain, not just
    // wherever the driver last held.
    const context: OuterContext = .{ .fixed = &fixed, .settings = &settings };
    const eval = try outerEvaluate(&context, result.canopy_total_water_potential_megapascal);
    try std.testing.expectApproxEqAbs(result.canopy_total_water_potential_megapascal, eval.water.canopy_water_potential_megapascal, 1e-6);
}

test "accepted whole-step fluxes close water and heat and do not scale with iteration ceiling" {
    const fixed = sourceOuterFixedInputs();
    var settings = sourceOuterSettings();
    const reference = try solveOuterCoupled(fixed, settings);

    // A larger ceiling permits more failed work; it is not elapsed time. Both
    // solves stop at the same accepted root and therefore publish the same
    // extensive flux tuple once (`MIGRATION.md`, solver migration).
    settings.outer_solver_options.max_iterations = 200;
    settings.canopy_settings.solver_options.max_iterations = 200;
    settings.water_balance_settings.solver_options.max_iterations = 200;
    const enlarged_ceiling = try solveOuterCoupled(fixed, settings);
    try std.testing.expectEqual(reference.canopy_total_water_potential_megapascal, enlarged_ceiling.canopy_total_water_potential_megapascal);
    try std.testing.expectEqual(reference.canopy.surface_transpiration_m3_per_step, enlarged_ceiling.canopy.surface_transpiration_m3_per_step);
    try std.testing.expectEqual(reference.canopy.transpiration_m3_per_step, enlarged_ceiling.canopy.transpiration_m3_per_step);
    try std.testing.expectEqual(reference.canopy.canopy_storage_heat_flux_megajoules_per_step, enlarged_ceiling.canopy.canopy_storage_heat_flux_megajoules_per_step);
    try std.testing.expectEqual(reference.attempted_nonlinear_iterations, enlarged_ceiling.attempted_nonlinear_iterations);

    // uptake.f:1190--1192 in positive-Zig-uptake notation:
    // delta storage = root uptake - signed canopy-boundary outflow.
    const boundary_outflow_m = try netCanopyWaterOutflowDepthM(
        reference.canopy.transpiration_m3_per_step,
        fixed.cell_area_m2,
    );
    const storage_change_m = fixed.canopy_water_capacitance_m_per_m2_megapascal *
        (reference.canopy_total_water_potential_megapascal - fixed.previous_canopy_water_potential_megapascal);
    const independently_reconstructed_water_residual =
        reference.water.total_root_water_uptake_m - boundary_outflow_m - storage_change_m;
    try std.testing.expectApproxEqAbs(reference.water.residual_m, independently_reconstructed_water_residual, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0), independently_reconstructed_water_residual, 1e-8);

    // EPCCMX is the atmospheric vapor term at uptake.f:1285; EPCCM adds the
    // internal VOLWPDM capacity correction at :1014. They must remain distinct
    // unless that correction happens to be exactly zero.
    const capacity_adjustment_m3 = reference.canopy.transpiration_m3_per_step -
        reference.canopy.surface_transpiration_m3_per_step;
    try std.testing.expectApproxEqAbs(
        capacity_adjustment_m3,
        (try evaluate(
            blk: {
                var canopy_fixed = fixed.canopy;
                canopy_fixed.canopy_total_water_potential_megapascal = reference.canopy_total_water_potential_megapascal;
                break :blk canopy_fixed;
            },
            sourceOuterSettings().canopy_settings,
            reference.canopy.canopy_surface_temperature_k,
        )).radiation.canopy_water_capacity_difference_change_m3_per_step,
        1e-15,
    );

    // uptake.f:1026, reconstructed without using the published storage term.
    const independently_reconstructed_storage_heat =
        reference.canopy.net_canopy_radiation_megajoules_per_step +
        reference.canopy.latent_heat_flux_megajoules_per_step +
        reference.canopy.sensible_heat_flux_megajoules_per_step +
        reference.canopy.vapor_sensible_heat_flux_megajoules_per_step +
        fixed.canopy.substep.retained_foliar_water_heat_megajoules_per_step;
    try std.testing.expectApproxEqAbs(
        reference.canopy.canopy_storage_heat_flux_megajoules_per_step,
        independently_reconstructed_storage_heat,
        1e-12,
    );
}

test "outer coupling converges cleanly under low soil water potential without silent divergence" {
    var fixed = sourceOuterFixedInputs();
    fixed.root.soil_water_potential_megapascal = &.{ -8.0, -9.0 };
    fixed.previous_canopy_water_potential_megapascal = -8.5;
    const settings = sourceOuterSettings();
    const result = try solveOuterCoupled(fixed, settings);
    try std.testing.expect(result.outer_iterations < settings.outer_solver_options.max_iterations);
    try std.testing.expect(result.attempted_nonlinear_iterations <= settings.outer_solver_options.max_iterations);
    try std.testing.expect(std.math.isFinite(result.canopy_total_water_potential_megapascal));
    try std.testing.expect(result.canopy_total_water_potential_megapascal <= 0);
}

test "source final STOMATE reset is applied before the fluxes returned by the final canopy pass" {
    var fixed = sourceOuterFixedInputs();
    // A dry canopy sends the vapor gradient through stomata instead of first
    // exhausting intercepted water, making the RSMN causal edge observable.
    fixed.canopy.substep.canopy_surface_water_m3 = 0;
    fixed.canopy.canopy_air_vapor_fraction = 5.0e-6;
    const TemperatureCapacity = struct {
        scale: f64,
        fn evaluate(raw: *const anyopaque, temperature_k: f64) anyerror!f64 {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            return self.scale * (temperature_k - 250.0);
        }
    };
    const capacity: TemperatureCapacity = .{ .scale = 100 };
    var boundary = sourceStomateFinalPass();
    boundary.maximum_turgor_carboxylation = .{
        .context = &capacity,
        .evaluate_fn = TemperatureCapacity.evaluate,
    };

    // Independent first pass: this is the state at uptake.f:1218 before the
    // ICHK handshake calls STOMATE again.
    const initial_minimum = try minimumStomatalResistanceAtTemperature(
        boundary,
        fixed.canopy.heat_initialization.previous_canopy_temperature_k,
    );
    var first_fixed = fixed;
    first_fixed.canopy.minimum_stomatal_resistance_h_per_m = initial_minimum;
    const first = try solveOuterCoupled(first_fixed, sourceOuterSettings());

    var settings = sourceOuterSettings();
    settings.stomate_final_pass = boundary;
    const final = try solveOuterCoupled(fixed, settings);
    const expected_final_minimum = try minimumStomatalResistanceAtTemperature(
        boundary,
        first.canopy.canopy_surface_temperature_k,
    );
    const expected_initial_stomate = try evaluateStomateAtTemperature(
        boundary,
        fixed.canopy.heat_initialization.previous_canopy_temperature_k,
    );
    const expected_final_stomate = try evaluateStomateAtTemperature(
        boundary,
        first.canopy.canopy_surface_temperature_k,
    );

    try std.testing.expect(final.stomate_final_pass_applied);
    try std.testing.expectApproxEqAbs(initial_minimum, final.initial_minimum_stomatal_resistance_h_per_m, 1e-15);
    try std.testing.expectApproxEqAbs(expected_final_minimum, final.final_minimum_stomatal_resistance_h_per_m, 1e-15);
    try std.testing.expectApproxEqAbs(expected_initial_stomate.maximum_turgor_carboxylation_umol_per_s, final.initial_maximum_turgor_carboxylation_umol_per_s, 1e-15);
    try std.testing.expectApproxEqAbs(expected_final_stomate.maximum_turgor_carboxylation_umol_per_s, final.final_maximum_turgor_carboxylation_umol_per_s, 1e-15);
    try std.testing.expect(@abs(final.final_maximum_turgor_carboxylation_umol_per_s - final.initial_maximum_turgor_carboxylation_umol_per_s) > 1e-6);
    try std.testing.expect(@abs(final.final_minimum_stomatal_resistance_h_per_m - initial_minimum) > 1e-10);
    try std.testing.expect(@abs(final.canopy.stomatal_resistance_h_per_m - first.canopy.stomatal_resistance_h_per_m) > 1e-10);

    // Hold both converged state coordinates fixed and independently evaluate
    // the exact downstream resistance -> transpiration -> energy equations
    // with the reset boundary. Both fluxes move; the final nonlinear pass
    // then re-equilibrates TKCY/root uptake from this changed residual.
    var initial_evaluation_fixed = fixed.canopy;
    initial_evaluation_fixed.minimum_stomatal_resistance_h_per_m = initial_minimum;
    initial_evaluation_fixed.canopy_total_water_potential_megapascal = first.canopy_total_water_potential_megapascal;
    const before_reset = try evaluate(
        initial_evaluation_fixed,
        settings.canopy_settings,
        first.canopy.canopy_surface_temperature_k,
    );
    var reset_evaluation_fixed = initial_evaluation_fixed;
    reset_evaluation_fixed.minimum_stomatal_resistance_h_per_m = expected_final_minimum;
    const after_reset = try evaluate(
        reset_evaluation_fixed,
        settings.canopy_settings,
        first.canopy.canopy_surface_temperature_k,
    );
    try std.testing.expect(@abs(after_reset.surface.transpiration_m3_per_h - before_reset.surface.transpiration_m3_per_h) > 1e-12);
    try std.testing.expect(@abs(after_reset.surface.latent_heat_flux_megajoules_per_h - before_reset.surface.latent_heat_flux_megajoules_per_h) > 1e-10);
    try std.testing.expect(final.attempted_nonlinear_iterations <= settings.outer_solver_options.max_iterations);
}

test "failed source final pass has no publication side effect" {
    var published_minimum: f64 = 0.019;
    var invalid = sourceStomateFinalPass();
    invalid.canopy_to_intercellular_co2_difference_umol_per_mol = std.math.nan(f64);
    if (minimumStomatalResistanceAtTemperature(invalid, 295)) |candidate| {
        published_minimum = candidate;
        return error.ExpectedCanopyFinalPassValidationFailure;
    } else |err| try std.testing.expectEqual(error.InvalidCanopyStomateFinalPassInput, err);
    try std.testing.expectEqual(@as(f64, 0.019), published_minimum);
}

test "outer coupling rejects an invalid cell area" {
    var fixed = sourceOuterFixedInputs();
    fixed.cell_area_m2 = 0;
    try std.testing.expectError(
        error.InvalidCanopyOuterCoupledInput,
        solveOuterCoupled(fixed, sourceOuterSettings()),
    );
}

test "outer coupling rejects every caller-supplied shared-budget binding" {
    var budget = try numerics.NonlinearBudget.init(100);

    var settings = sourceOuterSettings();
    settings.outer_solver_options.shared_budget = &budget;
    try std.testing.expectError(
        error.InvalidCanopySharedBudgetConfiguration,
        solveOuterCoupled(sourceOuterFixedInputs(), settings),
    );

    settings = sourceOuterSettings();
    settings.canopy_settings.solver_options.shared_budget = &budget;
    try std.testing.expectError(
        error.InvalidCanopySharedBudgetConfiguration,
        solveOuterCoupled(sourceOuterFixedInputs(), settings),
    );

    settings = sourceOuterSettings();
    settings.water_balance_settings.solver_options.shared_budget = &budget;
    try std.testing.expectError(
        error.InvalidCanopySharedBudgetConfiguration,
        solveOuterCoupled(sourceOuterFixedInputs(), settings),
    );
    try std.testing.expectEqual(@as(u16, 0), budget.attempted_iterations);
}

test "outer coupling rejects mismatched root array lengths" {
    var fixed = sourceOuterFixedInputs();
    fixed.root.maximum_uptake_m = &.{0.01};
    try std.testing.expectError(
        error.InvalidCanopyOuterCoupledInput,
        solveOuterCoupled(fixed, sourceOuterSettings()),
    );
}

test "outer coupling preserves both signs of source EPCCM at the hydraulic boundary" {
    try std.testing.expectApproxEqAbs(@as(f64, 2.5e-4), try netCanopyWaterOutflowDepthM(-0.025, 100), 1e-16);
    try std.testing.expectApproxEqAbs(@as(f64, -2.5e-4), try netCanopyWaterOutflowDepthM(0.025, 100), 1e-16);
    try std.testing.expectError(error.InvalidCanopyOuterCoupledInput, netCanopyWaterOutflowDepthM(-0.025, 0));
    try std.testing.expectError(error.InvalidCanopyOuterCoupledInput, netCanopyWaterOutflowDepthM(std.math.nan(f64), 100));
}
