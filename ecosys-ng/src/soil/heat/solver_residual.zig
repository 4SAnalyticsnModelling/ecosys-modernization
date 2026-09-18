//! `solver` declarations: residual.
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
const water_state = @import("../water/solver_flux.zig");
const enthalpy = @import("../water/enthalpy_balance.zig");
const retention = @import("../water/retention.zig");
const group_enthalpy = @import("solver_enthalpy.zig");
const group_misc = @import("solver_misc.zig");
const group_types = @import("solver_types.zig");
const group_validation = @import("solver_validation.zig");

fn evaluationEntry(
    properties: group_types.Properties,
    coupling: group_misc.EnthalpyCoupling,
    phase_buffers: group_misc.PhaseBuffers,
    cell: usize,
) !?*group_misc.EnthalpyEvaluationCache.Entry {
    const cache = phase_buffers.evaluation_cache orelse return null;
    const entry = &cache.entries[cell];
    if (!entry.parameters_valid) {
        entry.parameters = try group_enthalpy.enthalpyParameters(properties, coupling, cell);
        entry.parameters_valid = true;
        if (builtin.is_test) cache.parameter_misses += 1;
    }
    return entry;
}

fn trialState(
    entry: ?*group_misc.EnthalpyEvaluationCache.Entry,
    parameters: enthalpy.Parameters,
    temperature_k: f64,
    cache: ?*group_misc.EnthalpyEvaluationCache,
) !enthalpy.State {
    if (entry) |value| {
        if (builtin.is_test and value.trial_valid and value.temperature_k == temperature_k)
            cache.?.state_hits += 1;
        return value.trialState(temperature_k);
    }
    return enthalpy.stateAtTemperature(parameters, temperature_k);
}

pub fn residualAt(
    faces: []const group_types.Face,
    properties: group_types.Properties,
    water_fluxes: group_types.WaterHeatFluxes,
    base: []const f64,
    trial: []const f64,
    target: []f64,
    residual: []f64,
    scratch: []f64,
    output_flux: []f64,
    phase_buffers: group_misc.PhaseBuffers,
    solver_options: group_types.Options,
) !void {
    return residualAtImpl(
        faces,
        properties,
        water_fluxes,
        base,
        trial,
        target,
        residual,
        scratch,
        output_flux,
        phase_buffers,
        solver_options,
        null,
    );
}

fn residualAtImpl(
    faces: []const group_types.Face,
    properties: group_types.Properties,
    water_fluxes: group_types.WaterHeatFluxes,
    base: []const f64,
    trial: []const f64,
    target: []f64,
    residual: []f64,
    scratch: []f64,
    output_flux: []f64,
    phase_buffers: group_misc.PhaseBuffers,
    solver_options: group_types.Options,
    target_enthalpy_output: ?[]f64,
) !void {
    _ = solver_options;
    try group_validation.validateSoilTemperaturePhysicalDomain(base);
    try group_validation.validateSoilTemperaturePhysicalDomain(trial);
    if (target_enthalpy_output) |values|
        if (values.len != trial.len)
            return error.SoilHeatExactPicardImageDimensionMismatch;
    @memcpy(scratch, trial);
    @memcpy(target, base);
    if (properties.enthalpy_coupling) |coupling| {
        for (0..trial.len) |cell| {
            if (trial[cell] == base[cell]) {
                phase_buffers.matrix_liquid_m3[cell] =
                    coupling.matrix_liquid_water_m3[cell];
                phase_buffers.matrix_ice_m3[cell] =
                    coupling.matrix_ice_water_equivalent_m3[cell];
                if (phase_buffers.macropore_enabled) {
                    phase_buffers.macropore_liquid_m3[cell] =
                        coupling.macropore_liquid_water_m3[cell];
                    phase_buffers.macropore_ice_m3[cell] =
                        coupling.macropore_ice_water_equivalent_m3[cell];
                } else {
                    phase_buffers.macropore_liquid_m3[cell] = 0;
                    phase_buffers.macropore_ice_m3[cell] = 0;
                }
                continue;
            }
            const entry = try evaluationEntry(properties, coupling, phase_buffers, cell);
            const parameters = if (entry) |value| value.parameters else try group_enthalpy.enthalpyParameters(properties, coupling, cell);
            const trial_phase = try trialState(
                entry,
                parameters,
                trial[cell],
                phase_buffers.evaluation_cache,
            );
            phase_buffers.matrix_liquid_m3[cell] =
                trial_phase.liquid_water_m3;
            phase_buffers.matrix_ice_m3[cell] =
                trial_phase.ice_water_equivalent_m3;
            phase_buffers.macropore_liquid_m3[cell] =
                trial_phase.secondary_liquid_water_m3;
            phase_buffers.macropore_ice_m3[cell] =
                trial_phase.secondary_ice_water_equivalent_m3;
        }
    }
    for (target, properties.cell_heat_source_megajoules, properties.heat_capacity_megajoules_per_k, 0..) |*temperature, source_megajoules, capacity, cell| {
        if (properties.active_by_layer.len != 0 and
            !properties.active_by_layer[cell]) continue;
        temperature.* += source_megajoules / capacity;
    }
    @memset(output_flux, 0);
    for (faces, 0..) |face, face_index| {
        if (!face.active) continue;
        const source = face.source_cell;
        const destination = face.destination_cell;
        const difference = scratch[source] - scratch[destination];
        if (difference == 0 and
            water_fluxes.liquid_water_m3[face_index] == 0 and
            water_fluxes.vapor_m3[face_index] == 0 and
            water_fluxes.macropore_water_m3[face_index] == 0)
        {
            output_flux[face_index] = 0;
            continue;
        }
        const source_conductivity = try heat.calculateCellConductivity(
            try group_enthalpy.cellConductivityInputs(
                properties,
                source,
                difference,
                phase_buffers,
            ),
            properties.turbulence,
        );
        const destination_conductivity = try heat.calculateCellConductivity(
            try group_enthalpy.cellConductivityInputs(
                properties,
                destination,
                difference,
                phase_buffers,
            ),
            properties.turbulence,
        );
        const flux = try heat.calculateFaceFlux(.{ .source_temperature_k = scratch[source], .destination_temperature_k = scratch[destination], .source_heat_capacity_megajoules_per_k = properties.heat_capacity_megajoules_per_k[source], .destination_heat_capacity_megajoules_per_k = properties.heat_capacity_megajoules_per_k[destination], .source_minimum_heat_capacity_megajoules_per_k = properties.minimum_heat_capacity_megajoules_per_k[source], .destination_minimum_heat_capacity_megajoules_per_k = properties.minimum_heat_capacity_megajoules_per_k[destination], .source_is_top_soil_layer = properties.is_top_soil_layer[source], .top_snow_heat_capacity_megajoules_per_k = properties.top_snow_heat_capacity_megajoules_per_k[source], .maximum_negligible_snow_heat_capacity_megajoules_per_k = properties.maximum_negligible_snow_heat_capacity_megajoules_per_k[source], .snow_storage_heat_flux_megajoules = properties.snow_storage_heat_flux_megajoules[source], .liquid_water_flux_m3 = water_fluxes.liquid_water_m3[face_index], .vapor_flux_m3 = water_fluxes.vapor_m3[face_index], .macropore_water_flux_m3 = water_fluxes.macropore_water_m3[face_index], .liquid_water_heat_capacity_megajoules_per_m3_k = properties.liquid_water_heat_capacity_megajoules_per_m3_k, .source_thermal_conductivity_m_megajoules_per_h_k = source_conductivity, .destination_thermal_conductivity_m_megajoules_per_h_k = destination_conductivity, .source_path_length_m = face.source_path_length_m, .destination_path_length_m = face.destination_path_length_m, .face_area_m2 = face.face_area_m2, .time_fraction = properties.time_step_hours });
        output_flux[face_index] = flux.total_megajoules;
        const source_delta = flux.total_megajoules / properties.heat_capacity_megajoules_per_k[source];
        const destination_delta = flux.total_megajoules / properties.heat_capacity_megajoules_per_k[destination];
        // WATSUB evaluates every HFLWL face from the unchanged nonlinear
        // iterate (TK1), nets equal/opposite heat into THFLWL, and promotes
        // temperature only after the complete face sweep. Mutating `scratch`
        // here made downstream faces depend on traversal order even though
        // `target` already owns the conservative accumulation.
        target[source] -= source_delta;
        target[destination] += destination_delta;
    }
    if (properties.geothermal_boundary) |geothermal| {
        for (geothermal.topology.faces) |boundary_face| {
            if (!boundary_face.is_lower_boundary) continue;
            const horizontal_cell = boundary_face.cell_index;
            if (!geothermal.enabled_by_cell[horizontal_cell]) continue;
            const layer = boundary_face.layer_index;
            if (properties.active_by_layer.len != 0 and
                !properties.active_by_layer[layer]) continue;
            const lower_depth_m = geothermal.layer_bottom_depth_m[layer];
            const source_depth_m = @max(geothermal.minimum_source_depth_m, lower_depth_m + geothermal.source_depth_below_profile_m);
            const deep_temperature_k = geothermal.mean_annual_temperature_k_by_cell[horizontal_cell] + geothermal.geothermal_flux_megajoules_per_m2_h * source_depth_m / geothermal.conductivity_m_megajoules_per_h_k;
            const outward_heat_megajoules = try water_boundary.geothermalHeatFluxMj(scratch[layer], deep_temperature_k, geothermal.conductivity_m_megajoules_per_h_k, source_depth_m, lower_depth_m, geothermal.lower_face_area_m2[layer], properties.time_step_hours);
            target[layer] -= outward_heat_megajoules / properties.heat_capacity_megajoules_per_k[layer];
        }
    }
    if (properties.dirichlet_thermal_boundaries) |boundaries| {
        for (boundaries.cell_index, boundaries.temperature_k, boundaries.distance_from_cell_center_m, boundaries.face_area_m2) |cell, boundary_temperature_k, distance_m, face_area_m2| {
            if (properties.active_by_layer.len != 0 and
                !properties.active_by_layer[cell]) continue;
            const temperature_difference_k =
                boundary_temperature_k - scratch[cell];
            const conductivity_m_megajoules_per_h_k =
                try heat.calculateCellConductivity(
                    try group_enthalpy.cellConductivityInputs(
                        properties,
                        cell,
                        temperature_difference_k,
                        phase_buffers,
                    ),
                    properties.turbulence,
                );
            const inward_heat_megajoules =
                conductivity_m_megajoules_per_h_k * face_area_m2 *
                temperature_difference_k / distance_m *
                properties.time_step_hours;
            if (!std.math.isFinite(inward_heat_megajoules))
                return error.NonFiniteDirichletSoilHeatFlux;
            target[cell] += inward_heat_megajoules /
                properties.heat_capacity_megajoules_per_k[cell];
        }
    }
    if (properties.enthalpy_coupling) |coupling| {
        for (0..target.len) |cell| {
            const non_phase_heat_megajoules =
                (target[cell] - base[cell]) *
                properties.heat_capacity_megajoules_per_k[cell];
            // WATSUB 6907--6913 is the oracle's soil-layer temperature update:
            //
            //   IF(VHCP1(L,NY,NX).GT.VHCPRX(NY,NX)
            //  2.AND.VOLX(L,NY,NX).GT.ZEROS2(NY,NX))THEN
            //   TK1(L,NY,NX)=(ENGY1+THFLWL+THFLFL+THFLVL+HWFLU1+HFLXF)
            //  2/VHCP1(L,NY,NX)
            //   ELSE
            //   TK1(L,NY,NX)=TKS(L,NY,NX)
            //   ENDIF
            //
            // A layer at or below the minimum heat capacity is NOT solved from
            // its energy balance; it holds its prior accepted temperature. The
            // same guard and the same fallback appear at `redist.f:9655-9659`,
            // and `VHCPRX` is tested at 51 sites across STARTS, WATSUB and
            // REDIST. `target[cell] = base[cell]` below is exactly `TK1 = TKS`.
            //
            // `DRY-LAYER-UNPHYSICAL-HEAT-SINK-HOUR-2726-001`: without this, the
            // hour-2726 top layer -- dry, and holding `4.993374886774233e-5`
            // MJ/K against a `VHCPRX` of `8.380e-5` -- was solved against a
            // `-15.816727759048629` MJ surface conduction demand it cannot
            // absorb, reaching 312--320 K and driving a 4394 W m-2 upward flux
            // that no Newton or Picard step could reconcile.
            //
            // The oracle's second condition, `VOLX > ZEROS2`, is not repeated
            // here because a non-positive layer volume cannot reach this solver:
            // `hourly_workspace.refresh` rejects it with `InvalidSoilHourlyState`
            // before the heat properties are bound.
            const negligible_heat_capacity =
                properties.heat_capacity_megajoules_per_k[cell] <=
                properties.minimum_heat_capacity_megajoules_per_k[cell];
            if (non_phase_heat_megajoules == 0 or negligible_heat_capacity) {
                if (target_enthalpy_output) |values|
                    values[cell] = std.math.nan(f64);
                target[cell] = base[cell];
                residual[cell] = base[cell] - trial[cell];
                scratch[cell] = 0;
                phase_buffers.matrix_liquid_m3[cell] =
                    coupling.matrix_liquid_water_m3[cell];
                phase_buffers.matrix_ice_m3[cell] =
                    coupling.matrix_ice_water_equivalent_m3[cell];
                if (phase_buffers.macropore_enabled) {
                    phase_buffers.macropore_liquid_m3[cell] =
                        coupling.macropore_liquid_water_m3[cell];
                    phase_buffers.macropore_ice_m3[cell] =
                        coupling.macropore_ice_water_equivalent_m3[cell];
                } else {
                    phase_buffers.macropore_liquid_m3[cell] = 0;
                    phase_buffers.macropore_ice_m3[cell] = 0;
                }
                continue;
            }
            const entry = try evaluationEntry(properties, coupling, phase_buffers, cell);
            const parameters = if (entry) |value| value.parameters else try group_enthalpy.enthalpyParameters(properties, coupling, cell);
            if (entry == null or !entry.?.base_validated) {
                const base_state = enthalpy.stateAtTemperature(
                    parameters,
                    base[cell],
                ) catch |err| {
                    std.log.err(
                        "soil enthalpy coupling rejected state: cell={d} domain=matrix temperature_k={e} total_water_equivalent_m3={e} porous_medium_volume_m3={e} residual_water_content_m3_per_m3={e} saturated_water_content_m3_per_m3={e} error={s}",
                        .{
                            cell,
                            base[cell],
                            parameters.total_water_equivalent_m3,
                            parameters.porous_medium_volume_m3,
                            parameters.mualem_van_genuchten
                                .residual_water_content_m3_per_m3,
                            parameters.mualem_van_genuchten
                                .saturated_water_content_m3_per_m3,
                            @errorName(err),
                        },
                    );
                    if (parameters.secondary_domain) |secondary| {
                        std.log.err(
                            "soil enthalpy coupling paired domain: cell={d} domain=macropore total_water_equivalent_m3={e} porous_medium_volume_m3={e} residual_water_content_m3_per_m3={e} saturated_water_content_m3_per_m3={e}",
                            .{
                                cell,
                                secondary.total_water_equivalent_m3,
                                secondary.porous_medium_volume_m3,
                                secondary.mualem_van_genuchten
                                    .residual_water_content_m3_per_m3,
                                secondary.mualem_van_genuchten
                                    .saturated_water_content_m3_per_m3,
                            },
                        );
                    }
                    return err;
                };
                // Retained as a validity gate on `parameters` at `base[cell]`.
                _ = base_state;
                if (entry) |value| value.base_validated = true;
            }
            // The base enthalpy must be valued from the liquid/ice split the
            // grid actually holds, not from the Dall'Amico equilibrium split
            // re-derived at `base[cell]`. When the incoming grid state is off
            // its equilibrium partition, the equilibrium-valued base silently
            // creates or destroys `L * (liquid_eq - liquid_actual)` of latent
            // energy every hour, which the landscape census (which values the
            // real split) then reports as unexplained heat. Measured at
            // -129237 m3 of spurious liquid over 216 h = -0.4952 MJ/m2,
            // 99.1% of the observed `spatial_heat` residual.
            const actual_liquid_water_m3 =
                coupling.matrix_liquid_water_m3[cell] +
                if (phase_buffers.macropore_enabled)
                    coupling.macropore_liquid_water_m3[cell]
                else
                    0;
            const actual_ice_water_equivalent_m3 =
                coupling.matrix_ice_water_equivalent_m3[cell] +
                if (phase_buffers.macropore_enabled)
                    coupling.macropore_ice_water_equivalent_m3[cell]
                else
                    0;
            const actual_base_enthalpy_megajoules =
                (parameters.dry_solid_heat_capacity_megajoules_per_k +
                    parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
                        actual_liquid_water_m3 +
                    parameters.ice_water_equivalent_heat_capacity_megajoules_per_m3_k *
                        actual_ice_water_equivalent_m3) *
                (base[cell] - parameters.pure_water_melting_temperature_k) +
                parameters.latent_heat_of_fusion_megajoules_per_m3 *
                    actual_liquid_water_m3;
            if (!std.math.isFinite(actual_base_enthalpy_megajoules))
                return error.NonFiniteSoilEnthalpyState;
            const target_enthalpy_megajoules =
                actual_base_enthalpy_megajoules + non_phase_heat_megajoules;
            if (target_enthalpy_output) |values|
                values[cell] = target_enthalpy_megajoules;
            const trial_state = trialState(
                entry,
                parameters,
                trial[cell],
                phase_buffers.evaluation_cache,
            ) catch |err| {
                std.log.err(
                    "soil enthalpy residual rejected trial state: cell={d} base_temperature_k={e} trial_temperature_k={e} target_enthalpy_megajoules={e} actual_base_enthalpy_megajoules={e} non_phase_heat_megajoules={e} error={s}",
                    .{ cell, base[cell], trial[cell], target_enthalpy_megajoules, actual_base_enthalpy_megajoules, non_phase_heat_megajoules, @errorName(err) },
                );
                return err;
            };
            // Solve Appendix C's energy closure directly. The previous
            // residual inverted target enthalpy to a temperature inside every
            // outer probe and then subtracted the trial temperature. Near a
            // saturated phase front that nested map is almost singular: tiny
            // conductivity perturbations are amplified by the sharp latent-
            // heat slope, obscuring the topology-local Newton Jacobian. The
            // energy defect has the identical zero and is converted to kelvin
            // with the positive constitutive tangent dH/dT, so the public
            // temperature tolerance retains its physical meaning through the
            // latent transition.
            const enthalpy_defect_megajoules =
                target_enthalpy_megajoules -
                trial_state.enthalpy_megajoules;
            const enthalpy_tolerance_megajoules =
                coupling.solver_options.absolute_enthalpy_tolerance_megajoules +
                coupling.solver_options.relative_enthalpy_tolerance *
                    @max(1.0, @abs(target_enthalpy_megajoules));
            const constitutive_tangent_megajoules_per_k =
                if (entry) |value| try value.derivative() else try enthalpy.enthalpyDerivativeMjPerK(
                    parameters,
                    trial[cell],
                    trial_state,
                );
            // STARTS 655 `VHCPRX`. The oracle never divides by a layer heat
            // capacity without first testing it against this floor -- 51 sites,
            // canonically `redist.f:9655-9659`, which adopts a neighbouring
            // temperature instead of dividing when `VHCP <= VHCPRX`. REDIST
            // transfers `VHCM` by the volume fraction `FWO=FX` (`redist.f:9646`,
            // the same fraction as `VOLW`/`VOLV`/`VOLI`/`VOLY`/`VOLWX`, and NOT
            // the solid-mass owners) and HOUR1 deliberately does not rebuild it
            // (`hour1.f:3697` is commented out), so a layer's capacity falling
            // arbitrarily low is expected oracle behaviour, not a defect to
            // repair upstream.
            //
            // Without the floor this division amplified a `15.4242252197233` MJ
            // defect by a `5.051462339142763e-5` MJ/K tangent into
            // `residual_k = 3.0534e5`, which no Newton or Picard step can
            // reduce, and the deck died with `SoilHeatSolverStagnated` at hour
            // 2,726. The measured tangent is `1.66x` below the floor.
            //
            // This bounds the K-equivalent conversion only. The MJ defect,
            // its tolerance, and `scaled_enthalpy_defect` are untouched, so
            // physical acceptance is still judged in energy and nothing is
            // loosened: a layer above the floor divides exactly as before.
            const temperature_residual_capacity_megajoules_per_k = @max(
                constitutive_tangent_megajoules_per_k,
                properties.minimum_heat_capacity_megajoules_per_k[cell],
            );
            const temperature_defect_k =
                enthalpy_defect_megajoules /
                temperature_residual_capacity_megajoules_per_k;
            const scaled_enthalpy_defect =
                enthalpy_defect_megajoules / enthalpy_tolerance_megajoules;
            // The raw constitutive tangent is still validated as before, so a
            // non-finite or non-positive `dH/dT` remains a fatal domain error and
            // the floor cannot mask one. Only the divisor is floored.
            if (!std.math.isFinite(constitutive_tangent_megajoules_per_k) or
                constitutive_tangent_megajoules_per_k <= 0 or
                !std.math.isFinite(temperature_residual_capacity_megajoules_per_k) or
                temperature_residual_capacity_megajoules_per_k <= 0 or
                !std.math.isFinite(temperature_defect_k) or
                !std.math.isFinite(scaled_enthalpy_defect))
                return error.NonFiniteSoilEnthalpyResidual;
            target[cell] = trial[cell] + temperature_defect_k;
            // Preserve the analytic K-equivalent defect directly. Re-forming
            // it below as `(trial + defect) - trial` cancels every defect below
            // half a temperature ULP even though the independent MJ defect is
            // representable and may still exceed its configured tolerance.
            // The direct value is also the exact diagonal Newton correction
            // for the smooth constitutive energy equation.
            residual[cell] = temperature_defect_k;
            // Face evaluation has finished, so `scratch` can carry the second,
            // independent merit coordinate without another O(n) allocation.
            // Its sign is retained for diagnostics; `scaledNorm` takes the
            // magnitude alongside (not instead of) the K-equivalent gate.
            scratch[cell] = scaled_enthalpy_defect;
            phase_buffers.matrix_liquid_m3[cell] =
                trial_state.liquid_water_m3;
            phase_buffers.matrix_ice_m3[cell] =
                trial_state.ice_water_equivalent_m3;
            phase_buffers.macropore_liquid_m3[cell] =
                trial_state.secondary_liquid_water_m3;
            phase_buffers.macropore_ice_m3[cell] =
                trial_state.secondary_ice_water_equivalent_m3;
        }
    }
    for (target, trial, residual) |value, trial_value, *difference| {
        if (!std.math.isFinite(value) or
            (properties.enthalpy_coupling == null and value <= 0))
            return error.InvalidSoilHeatCandidate;
        if (properties.enthalpy_coupling == null)
            difference.* = value - trial_value;
    }
}

/// Evaluates the exact enthalpy-inversion fixed-point map for the complete
/// simultaneous-face target assembled at `trial`. This is recovery-only: the
/// returned image is a seed/history value and is never an accepted heat state.
/// Each cell owns an independent constitutive budget bounded by the smaller of
/// its configured local limit and the user inversion ceiling.
pub fn exactEnthalpyPicardImage(
    faces: []const group_types.Face,
    properties: group_types.Properties,
    water_fluxes: group_types.WaterHeatFluxes,
    base: []const f64,
    trial: []const f64,
    image: []f64,
    target: []f64,
    residual: []f64,
    scratch: []f64,
    output_flux: []f64,
    phase_buffers: group_misc.PhaseBuffers,
    solver_options: group_types.Options,
) !void {
    const coupling = properties.enthalpy_coupling orelse
        return error.SoilHeatExactPicardRequiresEnthalpyCoupling;
    if (image.len != trial.len)
        return error.SoilHeatExactPicardImageDimensionMismatch;
    try residualAtImpl(
        faces,
        properties,
        water_fluxes,
        base,
        trial,
        target,
        residual,
        scratch,
        output_flux,
        phase_buffers,
        solver_options,
        image,
    );
    const per_cell_iteration_cap = @min(
        coupling.solver_options.max_iterations,
        coupling.solver_options.local_iteration_limit,
    );
    if (per_cell_iteration_cap == 0)
        return error.InvalidSoilEnthalpySolverOption;
    for (image, trial, base, 0..) |*target_enthalpy_or_image, initial_temperature_k, base_temperature_k, cell| {
        if (std.math.isNan(target_enthalpy_or_image.*)) {
            // A zero non-phase target deliberately preserves the accepted
            // temperature and phase split rather than re-equilibrating latent
            // heat in an otherwise quiescent cell.
            target_enthalpy_or_image.* = base_temperature_k;
            continue;
        }
        var inversion_options = coupling.solver_options;
        inversion_options.max_iterations = per_cell_iteration_cap;
        inversion_options.local_iteration_limit = per_cell_iteration_cap;
        inversion_options.initial_temperature_k =
            if (initial_temperature_k >= inversion_options.minimum_temperature_k and
            initial_temperature_k <= inversion_options.maximum_temperature_k)
                initial_temperature_k
            else
                null;
        const solved = try enthalpy.temperatureFromEnthalpy(
            try group_enthalpy.enthalpyParameters(properties, coupling, cell),
            target_enthalpy_or_image.*,
            inversion_options,
        );
        target_enthalpy_or_image.* = solved.state.temperature_k;
    }
}

pub fn state_updateMatrixPhase(
    grid: *grid_module.GridState,
    phase_buffers: group_misc.PhaseBuffers,
) !void {
    try validateMatrixPhaseUpdate(grid, phase_buffers);
    publishValidatedMatrixPhaseUpdate(grid, phase_buffers);
}

/// Completes every fallible check needed by `publishValidatedMatrixPhaseUpdate`
/// without mutating the grid. A caller that has other fallible commit checks
/// can run this first, then make the final phase publication non-fallible.
pub fn validateMatrixPhaseUpdate(
    grid: *const grid_module.GridState,
    phase_buffers: group_misc.PhaseBuffers,
) !void {
    if (phase_buffers.matrix_liquid_m3.len != grid.layer_count or
        phase_buffers.matrix_ice_m3.len != grid.layer_count or
        phase_buffers.macropore_liquid_m3.len != grid.layer_count or
        phase_buffers.macropore_ice_m3.len != grid.layer_count)
        return error.SoilHeatPhaseStateUpdateDimensionMismatch;
    if (!std.math.isFinite(phase_buffers.ice_density_megagrams_per_m3) or
        phase_buffers.ice_density_megagrams_per_m3 <= 0 or
        phase_buffers.ice_density_megagrams_per_m3 >= 1)
        return error.InvalidSoilHeatEnthalpyCoupling;
    // Validate the complete candidate before publishing any part of it. In
    // particular, a zero-capacity macropore error must not occur after matrix
    // liquid/ice have already been overwritten: direct solver callers rely on
    // failure leaving every phase and derived pore-state owner unchanged.
    try grid.validateFinite();
    for (0..grid.layer_count) |cell| {
        const matrix_liquid = phase_buffers.matrix_liquid_m3[cell];
        const matrix_ice = phase_buffers.matrix_ice_m3[cell];
        if (!std.math.isFinite(matrix_liquid) or matrix_liquid < 0 or
            !std.math.isFinite(matrix_ice) or matrix_ice < 0)
            return error.InvalidSoilHeatPhaseCandidate;

        var macropore_liquid = grid.macropore_liquid_water_m3[cell];
        var macropore_ice = grid.macropore_ice_water_m3[cell];
        if (phase_buffers.macropore_enabled) {
            macropore_liquid = phase_buffers.macropore_liquid_m3[cell];
            macropore_ice = phase_buffers.macropore_ice_m3[cell];
            if (!std.math.isFinite(macropore_liquid) or macropore_liquid < 0 or
                !std.math.isFinite(macropore_ice) or macropore_ice < 0)
                return error.InvalidSoilHeatPhaseCandidate;
            const capacity = grid.macropore_pore_capacity_m3[cell];
            if (capacity <= 0 and
                (macropore_liquid != 0 or macropore_ice != 0 or
                    grid.macropore_liquid_water_m3[cell] != 0 or
                    grid.macropore_ice_water_m3[cell] != 0))
            {
                std.log.warn(
                    "macropore phase publish into a cell with no macropore capacity: " ++
                        "cell={d} macropore_pore_capacity_m3={e} incoming_liquid_m3={e} " ++
                        "incoming_ice_m3={e} resident_liquid_m3={e} resident_ice_m3={e}",
                    .{ cell, capacity, macropore_liquid, macropore_ice, grid.macropore_liquid_water_m3[cell], grid.macropore_ice_water_m3[cell] },
                );
                return error.UnbackedMacroporePhaseInventory;
            }
        }
        _ = try water_state.derivedPhysicalAirVolumeM3(
            grid.matrix_pore_capacity_m3[cell],
            matrix_liquid,
            matrix_ice,
            phase_buffers.ice_density_megagrams_per_m3,
        );
        _ = try water_state.derivedPhysicalAirVolumeM3(
            grid.macropore_pore_capacity_m3[cell],
            macropore_liquid,
            macropore_ice,
            phase_buffers.ice_density_megagrams_per_m3,
        );
        if (!std.math.isFinite(matrix_liquid + macropore_liquid) or
            !std.math.isFinite(matrix_ice + macropore_ice))
            return error.InvalidSoilHeatPhaseCandidate;
    }
}

/// Publishes a candidate previously accepted by `validateMatrixPhaseUpdate`.
/// This routine is intentionally non-fallible so a transaction can perform all
/// validation before its first externally visible state write.
pub fn publishValidatedMatrixPhaseUpdate(
    grid: *grid_module.GridState,
    phase_buffers: group_misc.PhaseBuffers,
) void {
    @memcpy(
        grid.matrix_liquid_water_m3,
        phase_buffers.matrix_liquid_m3,
    );
    @memcpy(grid.matrix_ice_water_m3, phase_buffers.matrix_ice_m3);
    if (phase_buffers.macropore_enabled) {
        // HEAT-MACROPORE-PUBLISH-SINK-001. This used to be an unconditional
        // pair of @memcpy calls over the whole grid. That is unsafe because
        // the macropore phase state handed to us is computed from an OPTIONAL
        // secondary equilibrium: soil/water/enthalpy_balance.zig:113-119
        // substitutes a literal 0 for both liquid and ice whenever the
        // secondary (macropore) equilibrium is absent, which is exactly the
        // case for a cell with no macropore capacity. Publishing that
        // substituted zero over a cell that is actually holding macropore
        // water destroys the water silently, and the recomputation loop below
        // immediately rebuilds grid.liquid_water_m3 from the components it
        // just overwrote, so no downstream total can ever observe the loss.
        //
        // On the Ottawa deck five of twelve cells (7..11) have
        // macropore_fraction 0, three declared and two copy-forward
        // extrapolated, so this path is live, not hypothetical.
        //
        // The fix is deliberately NOT "skip zero-capacity cells". Skipping
        // would leave an unbacked inventory sitting in a cell that has no pore
        // volume to hold it, which is a second, quieter corruption. Instead we
        // publish every cell that has capacity, and for a cell with no
        // capacity we require that both the incoming value and the resident
        // value are already zero. If either is non-zero, some upstream stage
        // put water in a pore volume that does not exist, and that is a real
        // conservation defect we must surface rather than paper over.
        for (0..grid.layer_count) |cell| {
            const capacity = grid.macropore_pore_capacity_m3[cell];
            if (capacity > 0) {
                grid.macropore_liquid_water_m3[cell] = phase_buffers.macropore_liquid_m3[cell];
                grid.macropore_ice_water_m3[cell] = phase_buffers.macropore_ice_m3[cell];
                continue;
            }
            // Both sides are zero, so the publish is a genuine no-op and the
            // cell stays consistent. Write nothing.
        }
    }
    for (0..grid.layer_count) |cell| {
        grid.liquid_water_m3[cell] =
            grid.matrix_liquid_water_m3[cell] +
            grid.macropore_liquid_water_m3[cell];
        grid.ice_water_m3[cell] =
            grid.matrix_ice_water_m3[cell] +
            grid.macropore_ice_water_m3[cell];
        // GAS-SOLVER/HEAT-ICE-EXPANSION-001. `grid.matrix_ice_water_m3` and
        // `grid.macropore_ice_water_m3` are the Dall'Amico closure's
        // water-equivalent ice volume (`phase_change.zig`'s
        // `dallAmicoEquilibrium` doc comment: ice is returned water-equivalent
        // "because the paper assumes a rigid porous medium with equal water
        // and ice densities"). That convention is correct for the mass/energy
        // closure itself and must not be disturbed there, but it is wrong for
        // how much PHYSICAL pore space the ice occupies: real ice is ~8.7%
        // less dense than water (`starts.f:99` DENSI, `watsub.f:6817,6820`
        // scale the freezing flux by `1/DENSI`), so the same mass of ice
        // occupies more volume than the water it froze from. Dividing by
        // `ice_density_megagrams_per_m3` converts only geometric occupancy;
        // the conserved mass/enthalpy carriers above remain water-equivalent.
        // A signed physical deficit is reconstructed by the Richards and
        // litter-soil vertical-face paths on the next coupled sweep and routed
        // as a donor-bounded liquid transfer. The air carrier itself stays
        // nonnegative because negative air is not a physical storage pool.
        const matrix_air = grid.matrix_pore_capacity_m3[cell] -
            grid.matrix_liquid_water_m3[cell] -
            grid.matrix_ice_water_m3[cell] /
                phase_buffers.ice_density_megagrams_per_m3;
        const macropore_air = grid.macropore_pore_capacity_m3[cell] -
            grid.macropore_liquid_water_m3[cell] -
            grid.macropore_ice_water_m3[cell] /
                phase_buffers.ice_density_megagrams_per_m3;
        grid.matrix_air_volume_m3[cell] = if (matrix_air > 0) matrix_air else 0;
        grid.macropore_air_volume_m3[cell] = if (macropore_air > 0) macropore_air else 0;
        grid.air_volume_m3[cell] =
            grid.matrix_air_volume_m3[cell] +
            grid.macropore_air_volume_m3[cell];
    }
}

pub fn addDirection(current: []const f64, direction: []const f64, fraction: f64, output: []f64) !void {
    for (current, direction, output) |value, delta, *candidate| {
        candidate.* = value + fraction * delta;
        if (!group_validation.isPhysicalTemperatureK(candidate.*))
            return error.InvalidSoilHeatCandidate;
    }
}

pub fn scaledNorm(
    state: []const f64,
    residual: []const f64,
    scaled_enthalpy_defect: []const f64,
    enthalpy_coupled: bool,
    options: group_types.Options,
) !f64 {
    if (scaled_enthalpy_defect.len != state.len)
        return error.SoilHeatSolverDimensionMismatch;
    var maximum: f64 = 0;
    for (state, residual, scaled_enthalpy_defect) |value, difference, scaled_enthalpy| {
        if (!std.math.isFinite(value) or value <= 0 or !std.math.isFinite(difference)) return error.NonFiniteSoilHeatSolverState;
        maximum = @max(maximum, @abs(difference) / (options.absolute_tolerance_k + options.relative_tolerance * @abs(value)));
        if (enthalpy_coupled) {
            if (!std.math.isFinite(scaled_enthalpy))
                return error.NonFiniteSoilHeatSolverState;
            maximum = @max(maximum, @abs(scaled_enthalpy));
        }
    }
    return maximum;
}

pub fn conservationArithmeticBound(operation_count: usize, magnitude: f64) !f64 {
    if (!std.math.isFinite(magnitude) or magnitude < 0)
        return error.InvalidSoilHeatConservationTolerance;
    if (operation_count == 0 or magnitude == 0) return 0;
    const scaled_epsilon = @as(f64, @floatFromInt(operation_count)) *
        std.math.floatEps(f64);
    if (scaled_epsilon >= 1)
        return error.InvalidSoilHeatConservationTolerance;
    const allowance = scaled_epsilon / (1 - scaled_epsilon) * magnitude;
    if (!std.math.isFinite(allowance))
        return error.InvalidSoilHeatConservationTolerance;
    return std.math.nextAfter(f64, allowance, std.math.inf(f64));
}

fn addConservationBounds(left: f64, right: f64) !f64 {
    if (!std.math.isFinite(left) or left < 0 or
        !std.math.isFinite(right) or right < 0)
        return error.InvalidSoilHeatConservationTolerance;
    if (left == 0) return right;
    if (right == 0) return left;
    const sum = left + right;
    if (!std.math.isFinite(sum))
        return error.InvalidSoilHeatConservationTolerance;
    return std.math.nextAfter(f64, sum, std.math.inf(f64));
}

/// Absolute-term magnitude of `enthalpy_balance.stateAtTemperature` after its
/// constitutive liquid/ice partition is known. The enthalpy expression and its
/// capacity assembly have at most fifteen rounded arithmetic operations; 32
/// is an explicit conservative ceiling including the dual-domain branch.
pub fn enthalpyExpressionRoundoffBound(
    parameters: enthalpy.Parameters,
    temperature_k: f64,
    liquid_water_m3: f64,
    ice_water_equivalent_m3: f64,
) !f64 {
    const temperature_offset_k =
        temperature_k - parameters.pure_water_melting_temperature_k;
    const magnitude =
        @abs(parameters.dry_solid_heat_capacity_megajoules_per_k * temperature_offset_k) +
        @abs(parameters.liquid_water_heat_capacity_megajoules_per_m3_k * liquid_water_m3 * temperature_offset_k) +
        @abs(parameters.ice_water_equivalent_heat_capacity_megajoules_per_m3_k * ice_water_equivalent_m3 * temperature_offset_k) +
        @abs(parameters.latent_heat_of_fusion_megajoules_per_m3 * liquid_water_m3);
    return conservationArithmeticBound(32, magnitude);
}

/// Independent layer-local energy-conservation merit. The ordinary entry point
/// never masks or relaxes this balance. A separate proven-endpoint entry point
/// may add only the constitutive energy width of one adjacent-f64 temperature
/// interval after the full coupled residual has bracketed its root there.
/// `residual_k` is the direct constitutive K-equivalent defect emitted by
/// `residualAt`; multiplying it by the same local dH/dT reconstructs the signed
/// MJ defect without re-evaluating transport faces.
pub const ConservationComponent = struct {
    cell: usize,
    scaled_norm: f64,
    base_temperature_k: f64,
    trial_temperature_k: f64,
    residual_k: f64,
    derivative_megajoules_per_k: f64,
    enthalpy_defect_megajoules: f64,
    actual_base_enthalpy_megajoules: f64,
    trial_enthalpy_megajoules: f64,
    target_enthalpy_megajoules: f64,
    non_phase_heat_megajoules: f64,
    /// `DRY-LAYER-UNPHYSICAL-HEAT-SINK-HOUR-2726-001`. The transport sweep
    /// converts heat to kelvin with `properties.heat_capacity_megajoules_per_k`
    /// (WATSUB `VHCP`, which includes `4.19 * water`), while the enthalpy closure
    /// converts kelvin back to heat with the local `dH/dT`. Those are two
    /// representations of one layer's heat capacity and must agree to within the
    /// phase-change slope; at the hour-2726 failure they differ by 531x
    /// (`2.6815026902369143e-2` against `5.051462339142763e-5`, the latter being
    /// the dry term alone for a layer holding `6.343346971125337e-3` m3 of
    /// liquid). Carry both, and the water the coupling actually saw, so the
    /// stagnation report says which representation is wrong instead of leaving it
    /// to be inferred.
    transport_heat_capacity_megajoules_per_k: f64,
    dry_solid_heat_capacity_megajoules_per_k: f64,
    coupling_liquid_water_m3: f64,
    coupling_ice_water_equivalent_m3: f64,
    /// The water the enthalpy `parameters` carry, as distinct from the water the
    /// coupling arrays carry above. `actual_base_enthalpy_megajoules` values the
    /// base state from the COUPLING's liquid/ice split -- deliberately, so the
    /// Dall'Amico equilibrium re-derivation cannot invent latent energy -- while
    /// `stateAtTemperature` values the trial state from `parameters`. That
    /// asymmetry is only sound if the two agree on the layer's TOTAL water. If
    /// `parameters.total_water_equivalent_m3` is ~0 while the coupling holds
    /// `6.343346971125337e-3` m3, the trial state cannot represent the base
    /// state's water enthalpy at any temperature and the defect can never close.
    parameters_total_water_equivalent_m3: f64,
    parameters_porous_medium_volume_m3: f64,
    /// The extensive cell heat source for this layer, so `non_phase_heat` can be
    /// split between it and the conduction faces. `non_phase_heat` is the whole
    /// accumulated sweep -- `bindSurfaceHeatFlux` writes the surface conduction
    /// into `cell_heat_source_megajoules[top]` and the faces add the rest -- and
    /// at the hour-2726 failure it is `-9.442581151294318` MJ into a layer the
    /// solver sees as completely dry (`coupling_liquid_m3 = 0`,
    /// `parameters_total_water_equivalent_m3 = 0`) holding only
    /// `4.993374886774233e-5` MJ/K of dry capacity. Printing the source says in
    /// one run whether that demand arrives from the surface energy balance or
    /// from layer-to-layer conduction, instead of leaving it to be inferred.
    cell_heat_source_megajoules: f64,
    delta_storage_megajoules: f64,
    interval_activity_megajoules: f64,
    arithmetic_roundoff_megajoules: f64,
    temperature_representability_megajoules: f64,
    tolerance_megajoules: f64,
};

fn temperatureRepresentabilityAllowanceMegajoules(
    parameters: enthalpy.Parameters,
    temperature_k: f64,
    difference_k: f64,
) !f64 {
    if (difference_k == 0) return 0;
    const trial_state = try enthalpy.stateAtTemperature(
        parameters,
        temperature_k,
    );
    const adjacent_temperature_k = std.math.nextAfter(
        f64,
        temperature_k,
        if (difference_k > 0)
            std.math.inf(f64)
        else
            -std.math.inf(f64),
    );
    const adjacent_state = try enthalpy.stateAtTemperature(
        parameters,
        adjacent_temperature_k,
    );
    const adjacent_expression_roundoff =
        try enthalpyExpressionRoundoffBound(
            parameters,
            adjacent_temperature_k,
            adjacent_state.liquid_water_m3 +
                adjacent_state.secondary_liquid_water_m3,
            adjacent_state.ice_water_equivalent_m3 +
                adjacent_state.secondary_ice_water_equivalent_m3,
        );
    return addConservationBounds(
        @abs(adjacent_state.enthalpy_megajoules -
            trial_state.enthalpy_megajoules),
        adjacent_expression_roundoff,
    );
}

/// Materializes the exact per-layer allowance attached to an accepted set of
/// adjacent-f64 full-residual endpoint proofs. Callers use this to give an
/// independent post-commit census the same binary64 certificate; zero marks
/// every ordinary, representable coordinate.
pub fn fillConservationRepresentabilityAllowances(
    properties: group_types.Properties,
    trial_temperature_k: []const f64,
    residual_k: []const f64,
    represented_endpoints: []const f64,
    output_megajoules: []f64,
) !void {
    if (trial_temperature_k.len != residual_k.len or
        trial_temperature_k.len != represented_endpoints.len or
        trial_temperature_k.len != output_megajoules.len)
        return error.SoilHeatSolverDimensionMismatch;
    @memset(output_megajoules, 0);
    const coupling = properties.enthalpy_coupling orelse return;
    for (represented_endpoints, 0..) |represented, cell| {
        if (represented == 0) continue;
        const parameters = try group_enthalpy.enthalpyParameters(
            properties,
            coupling,
            cell,
        );
        output_megajoules[cell] =
            try temperatureRepresentabilityAllowanceMegajoules(
                parameters,
                trial_temperature_k[cell],
                residual_k[cell],
            );
    }
}

/// Returns the same worst component used by `conservationScaledNorm`, with
/// enough physical detail for a failure-only diagnostic. Keeping this as the
/// single implementation prevents the diagnostic from silently disagreeing
/// with the acceptance gate.
pub fn worstConservationComponent(
    properties: group_types.Properties,
    base_temperature_k: []const f64,
    trial_temperature_k: []const f64,
    residual_k: []const f64,
) !?ConservationComponent {
    return worstConservationComponentWithRepresentedEndpoints(
        properties,
        base_temperature_k,
        trial_temperature_k,
        residual_k,
        null,
        null,
        false,
        false,
    );
}

fn worstConservationComponentWithRepresentedEndpoints(
    properties: group_types.Properties,
    base_temperature_k: []const f64,
    trial_temperature_k: []const f64,
    residual_k: []const f64,
    represented_endpoints: ?[]const f64,
    excluded_cells: ?[]const f64,
    skip_represented_endpoints: bool,
    descent_merit: bool,
) !?ConservationComponent {
    const coupling = properties.enthalpy_coupling orelse return null;
    if (coupling.conservation_cell_area_m2.len == 0) return null;
    if (base_temperature_k.len != trial_temperature_k.len or
        residual_k.len != trial_temperature_k.len or
        coupling.conservation_cell_area_m2.len != trial_temperature_k.len)
        return error.SoilHeatSolverDimensionMismatch;
    if (represented_endpoints) |endpoints|
        if (endpoints.len != trial_temperature_k.len)
            return error.SoilHeatSolverDimensionMismatch;
    if (excluded_cells) |excluded|
        if (excluded.len != trial_temperature_k.len)
            return error.SoilHeatSolverDimensionMismatch;

    var worst: ?ConservationComponent = null;
    for (trial_temperature_k, residual_k, 0..) |temperature_k, difference_k, cell| {
        if (excluded_cells) |excluded|
            if (excluded[cell] != 0) continue;
        if (skip_represented_endpoints) {
            if (represented_endpoints) |endpoints|
                if (endpoints[cell] != 0) continue;
        }
        if (properties.active_by_layer.len != 0 and
            !properties.active_by_layer[cell]) continue;
        const parameters = try group_enthalpy.enthalpyParameters(
            properties,
            coupling,
            cell,
        );
        const actual_liquid_water_m3 =
            coupling.matrix_liquid_water_m3[cell] +
            if (coupling.macropore_mualem_van_genuchten.len != 0)
                coupling.macropore_liquid_water_m3[cell]
            else
                0;
        const actual_ice_water_equivalent_m3 =
            coupling.matrix_ice_water_equivalent_m3[cell] +
            if (coupling.macropore_mualem_van_genuchten.len != 0)
                coupling.macropore_ice_water_equivalent_m3[cell]
            else
                0;
        const actual_base_enthalpy_megajoules =
            (parameters.dry_solid_heat_capacity_megajoules_per_k +
                parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
                    actual_liquid_water_m3 +
                parameters.ice_water_equivalent_heat_capacity_megajoules_per_m3_k *
                    actual_ice_water_equivalent_m3) *
            (base_temperature_k[cell] -
                parameters.pure_water_melting_temperature_k) +
            parameters.latent_heat_of_fusion_megajoules_per_m3 *
                actual_liquid_water_m3;
        const trial_state = try enthalpy.stateAtTemperature(
            parameters,
            temperature_k,
        );
        const derivative_megajoules_per_k =
            try enthalpy.enthalpyDerivativeMjPerK(
                parameters,
                temperature_k,
                trial_state,
            );
        const enthalpy_defect_megajoules =
            difference_k * derivative_megajoules_per_k;
        const target_enthalpy_megajoules =
            trial_state.enthalpy_megajoules +
            enthalpy_defect_megajoules;
        const non_phase_heat_megajoules =
            target_enthalpy_megajoules -
            actual_base_enthalpy_megajoules;
        const delta_storage_megajoules =
            trial_state.enthalpy_megajoules -
            actual_base_enthalpy_megajoules;
        const interval_activity_megajoules = @max(
            @abs(delta_storage_megajoules),
            @abs(non_phase_heat_megajoules),
        );
        const base_expression_roundoff = try enthalpyExpressionRoundoffBound(
            parameters,
            base_temperature_k[cell],
            actual_liquid_water_m3,
            actual_ice_water_equivalent_m3,
        );
        const trial_expression_roundoff = try enthalpyExpressionRoundoffBound(
            parameters,
            temperature_k,
            trial_state.liquid_water_m3 + trial_state.secondary_liquid_water_m3,
            trial_state.ice_water_equivalent_m3 + trial_state.secondary_ice_water_equivalent_m3,
        );
        const derived_roundoff = try conservationArithmeticBound(
            4,
            @abs(enthalpy_defect_megajoules) +
                @abs(target_enthalpy_megajoules) +
                @abs(non_phase_heat_megajoules) +
                @abs(delta_storage_megajoules),
        );
        var arithmetic_roundoff = try addConservationBounds(
            base_expression_roundoff,
            trial_expression_roundoff,
        );
        arithmetic_roundoff = try addConservationBounds(
            arithmetic_roundoff,
            derived_roundoff,
        );
        var temperature_representability_megajoules: f64 = 0;
        if (represented_endpoints) |endpoints| {
            if (endpoints[cell] != 0 and difference_k != 0) {
                temperature_representability_megajoules =
                    try temperatureRepresentabilityAllowanceMegajoules(
                        parameters,
                        temperature_k,
                        difference_k,
                    );
            }
        }
        const tolerance_megajoules =
            coupling.conservation_absolute_tolerance_megajoules_per_m2 *
            coupling.conservation_cell_area_m2[cell] +
            arithmetic_roundoff +
            temperature_representability_megajoules +
            coupling.conservation_relative_tolerance *
                interval_activity_megajoules;
        if (!std.math.isFinite(enthalpy_defect_megajoules) or
            !std.math.isFinite(tolerance_megajoules) or
            tolerance_megajoules <= 0)
            return error.InvalidSoilHeatConservationTolerance;
        const acceptance_norm =
            @abs(enthalpy_defect_megajoules) / tolerance_megajoules;
        // A trial-dependent storage denominator is valid for acceptance but
        // not for descent: with negative heat and positive storage, reducing
        // the energy error increases |storage-heat|/|storage|. Rank rejected
        // states by the energy defect on the existing arithmetic/absolute
        // scale instead. Do not chase that stricter scale once the ORIGINAL
        // conservation gate is satisfied. Thus merit <= 1 is equivalent to
        // physical acceptance, including only proven endpoint allowances.
        const scaled_norm = if (descent_merit)
            conservationDescentScore(
                enthalpy_defect_megajoules,
                tolerance_megajoules,
                coupling.conservation_absolute_tolerance_megajoules_per_m2 *
                    coupling.conservation_cell_area_m2[cell] +
                    arithmetic_roundoff + temperature_representability_megajoules,
            )
        else
            acceptance_norm;
        if (worst == null or scaled_norm > worst.?.scaled_norm) {
            worst = .{
                .cell = cell,
                .scaled_norm = scaled_norm,
                .base_temperature_k = base_temperature_k[cell],
                .trial_temperature_k = temperature_k,
                .residual_k = difference_k,
                .derivative_megajoules_per_k = derivative_megajoules_per_k,
                .enthalpy_defect_megajoules = enthalpy_defect_megajoules,
                .actual_base_enthalpy_megajoules = actual_base_enthalpy_megajoules,
                .trial_enthalpy_megajoules = trial_state.enthalpy_megajoules,
                .target_enthalpy_megajoules = target_enthalpy_megajoules,
                .non_phase_heat_megajoules = non_phase_heat_megajoules,
                .transport_heat_capacity_megajoules_per_k = properties.heat_capacity_megajoules_per_k[cell],
                .dry_solid_heat_capacity_megajoules_per_k = parameters.dry_solid_heat_capacity_megajoules_per_k,
                .coupling_liquid_water_m3 = actual_liquid_water_m3,
                .coupling_ice_water_equivalent_m3 = actual_ice_water_equivalent_m3,
                .parameters_total_water_equivalent_m3 = parameters.total_water_equivalent_m3,
                .parameters_porous_medium_volume_m3 = parameters.porous_medium_volume_m3,
                .cell_heat_source_megajoules = if (cell < properties.cell_heat_source_megajoules.len)
                    properties.cell_heat_source_megajoules[cell]
                else
                    std.math.nan(f64),
                .delta_storage_megajoules = delta_storage_megajoules,
                .interval_activity_megajoules = interval_activity_megajoules,
                .arithmetic_roundoff_megajoules = arithmetic_roundoff,
                .temperature_representability_megajoules = temperature_representability_megajoules,
                .tolerance_megajoules = tolerance_megajoules,
            };
        }
    }
    return worst;
}

pub fn conservationScaledNorm(
    properties: group_types.Properties,
    base_temperature_k: []const f64,
    trial_temperature_k: []const f64,
    residual_k: []const f64,
) !f64 {
    const worst = try worstConservationComponent(
        properties,
        base_temperature_k,
        trial_temperature_k,
        residual_k,
    );
    return if (worst) |component| component.scaled_norm else 0;
}

/// Conservation merit for coordinates whose full coupled enthalpy residual has
/// already been proven to change sign across the adjacent f64 temperature in
/// the residual direction. Only those proven coordinates receive the exact
/// constitutive enthalpy width of that one-temperature-ULP interval; ordinary
/// conservation checks remain unchanged.
pub fn conservationScaledNormWithRepresentedEndpoints(
    properties: group_types.Properties,
    base_temperature_k: []const f64,
    trial_temperature_k: []const f64,
    residual_k: []const f64,
    represented_endpoints: []const f64,
) !f64 {
    const worst = try worstConservationComponentWithRepresentedEndpoints(
        properties,
        base_temperature_k,
        trial_temperature_k,
        residual_k,
        represented_endpoints,
        null,
        false,
        false,
    );
    return if (worst) |component| component.scaled_norm else 0;
}

/// Step selection and best-state ranking, separate from the acceptance ratio.
/// This never admits a state rejected by conservationScaledNorm: only the
/// ordering of states outside the original physical acceptance set changes.
pub fn conservationDescentNorm(
    properties: group_types.Properties,
    base_temperature_k: []const f64,
    trial_temperature_k: []const f64,
    residual_k: []const f64,
    represented_endpoints: ?[]const f64,
) !f64 {
    const worst = try worstConservationComponentWithRepresentedEndpoints(
        properties,
        base_temperature_k,
        trial_temperature_k,
        residual_k,
        represented_endpoints,
        null,
        false,
        true,
    );
    return if (worst) |component| component.scaled_norm else 0;
}

fn conservationDescentScore(defect_megajoules: f64, tolerance_megajoules: f64, arithmetic_scale_megajoules: f64) f64 {
    const acceptance_norm = @abs(defect_megajoules) / tolerance_megajoules;
    if (acceptance_norm <= 1) return acceptance_norm;
    return 1 + @abs(defect_megajoules) / arithmetic_scale_megajoules;
}

test "heat conservation descent follows falling energy error across wrong-sign storage" {
    const heat_megajoules: f64 = -0.001;
    const old_storage_megajoules: f64 = 0.1;
    const new_storage_megajoules: f64 = 0.05;
    const old_defect = old_storage_megajoules - heat_megajoules;
    const new_defect = new_storage_megajoules - heat_megajoules;
    const arithmetic_scale: f64 = 1e-14;
    const old_tolerance = arithmetic_scale + 1e-9 * old_storage_megajoules;
    const new_tolerance = arithmetic_scale + 1e-9 * new_storage_megajoules;
    try std.testing.expect(new_defect < old_defect);
    // The acceptance ratios rank this real physical improvement backwards.
    try std.testing.expect(new_defect / new_tolerance > old_defect / old_tolerance);
    try std.testing.expect(conservationDescentScore(new_defect, new_tolerance, arithmetic_scale) <
        conservationDescentScore(old_defect, old_tolerance, arithmetic_scale));
}

test "heat conservation descent preserves the exact physical acceptance set" {
    for ([_]f64{ 1e-14, 1e-9, 0.1 }) |tolerance| {
        for ([_]f64{ -2, -1, -0.5, 0, 0.5, 1, 2 }) |multiple| {
            const defect = multiple * tolerance;
            const score = conservationDescentScore(defect, tolerance, 0.01 * tolerance);
            try std.testing.expectEqual(@abs(defect) <= tolerance, score <= 1);
            if (@abs(defect) <= tolerance)
                try std.testing.expectEqual(@abs(defect) / tolerance, score);
        }
    }
}

/// Highest still-unproven conservation coordinate for adjacent-f64 endpoint
/// discovery. Proven endpoints already carry their explicit one-ULP allowance;
/// `checked_cells` prevents a non-bracketing coordinate from starving the rest
/// of the bounded scan.
pub fn worstUnresolvedConservationComponent(
    properties: group_types.Properties,
    base_temperature_k: []const f64,
    trial_temperature_k: []const f64,
    residual_k: []const f64,
    represented_endpoints: []const f64,
    checked_cells: []const f64,
) !?ConservationComponent {
    if (represented_endpoints.len != checked_cells.len)
        return error.SoilHeatSolverDimensionMismatch;
    return worstConservationComponentWithRepresentedEndpoints(
        properties,
        base_temperature_k,
        trial_temperature_k,
        residual_k,
        represented_endpoints,
        checked_cells,
        true,
        false,
    );
}
