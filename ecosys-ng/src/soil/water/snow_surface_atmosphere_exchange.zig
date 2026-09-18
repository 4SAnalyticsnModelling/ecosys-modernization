//! WATSUB snow-surface vapor and sensible-heat exchange.
//!
//! The surface snow layer is layer zero (`watsub.f` layer 1).  A positive
//! signed water transfer enters the snowpack; a negative transfer leaves it.
//! On evaporation, the oracle exhausts snow vapor first, then liquid water,
//! then solid snow. Liquid and solid withdrawals use the source's independent
//! donor-availability fraction. Every candidate cell is validated before any
//! prognostic state or caller-owned diagnostic is published.

const std = @import("std");
const builtin = @import("builtin");
const snow = @import("../solute/snow_solute_transport.zig");
const ice_units = @import("../../core/ice_units.zig");

pub const Parameters = struct {
    vapor_volume_prefactor_k: f64,
    equilibrium_relative_humidity: f64,
    clausius_clapeyron_temperature_k: f64,
    reference_inverse_temperature_per_k: f64,
    liquid_evaporation_latent_heat_megajoules_per_m3: f64,
    snow_sublimation_latent_heat_megajoules_per_m3: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    ice_density_megagrams_per_m3: f64,
    pure_water_melting_temperature_k: f64,
};

pub const SourceContext = struct {
    fallback_temperature_k: []const f64,
    vapor_fraction: []f64,
    temperature_k: []f64,
};

pub const EquilibriumContext = struct {
    /// WATSUB `XNPSX` inventory fraction. Equilibrium is explicit rather than
    /// a rate integral, so this must not be conflated with physical dt.
    donor_availability_fraction: f64,
    /// WFLVW2*VAP + WFLVS2*VAPS. This is the surface-layer part of
    /// WATSUB EFLXW2 and is kept separate from the atmosphere boundary term.
    latent_heat_megajoules: []f64,
    /// Independently derived hybrid-reference internal process heat:
    /// `Lv*dL + Ls*dS + Ks*dS`. The stage publishes this as internal heat.
    reference_state_heat_megajoules: []f64,
    cell_area_m2: []const f64,
    energy_conservation_absolute_tolerance_megajoules_per_m2: f64,
    energy_conservation_relative_tolerance: f64,
};

pub const ApplyContext = struct {
    /// Physical integration interval for accepted atmosphere exchange,
    /// sensible heat, and radiation (`XNPYX` role).
    physical_time_step_hours: f64,
    /// Fraction of the current liquid/solid donor inventory available to the
    /// surface exchange (`XNPSX` role). This is independent of physical dt.
    donor_availability_fraction: f64,
    cell_area_m2: []const f64,
    energy_conservation_absolute_tolerance_megajoules_per_m2: f64,
    energy_conservation_relative_tolerance: f64,
    /// Shared surface-energy physical domain. A finite but extreme snow
    /// temperature is a rejected timestep candidate, not an admissible state.
    minimum_temperature_k: f64,
    maximum_temperature_k: f64,
    /// PAREWM after the caller has applied the current snow-cover fraction.
    vapor_conductance_m3_per_h: []const f64,
    /// PARSWM after the caller has applied the current snow-cover fraction.
    sensible_conductance_megajoules_per_h_k: []const f64,
    accepted_ground_air_vapor_fraction: []const f64,
    accepted_ground_air_temperature_k: []const f64,
    /// Net shortwave plus longwave at the snow surface, positive inward.
    radiative_heat_megajoules_per_h: []const f64,
    /// Positive outward from snow to ground air.
    evaporation_m3: []f64,
    /// Positive inward from ground air to snow.
    condensation_m3: []f64,
    /// Change in the landscape snow enthalpy census; positive into snow.
    boundary_heat_megajoules: []f64,
    /// Signed latent part of the snow energy change; negative on evaporation.
    latent_heat_megajoules: []f64,
    /// Signed carrier sensible heat; negative when water leaves snow.
    carrier_sensible_heat_megajoules: []f64,
    /// Direct air/snow sensible exchange; positive into snow.
    air_sensible_heat_megajoules: []f64,
    /// Accepted snow-surface radiative heat; positive into snow.
    radiative_heat_megajoules: []f64,
};

pub const RadiationInputs = struct {
    snow_cover_fraction: f64,
    cell_area_m2: f64,
    incident_shortwave_megajoules_per_m2_h: f64,
    atmospheric_longwave_megajoules_per_m2_h: f64,
    ground_exposure_fraction: f64,
    snow_longwave_emissivity: f64,
    stefan_boltzmann_megajoules_per_m2_h_k4: f64,
    snow_temperature_k: f64,
    solid_snow_water_equivalent_m3: f64,
    liquid_water_m3: f64,
    ice_volume_m3: f64,
    /// Accepted `TKC`/`TKD` surface temperatures and the current-hour
    /// `FRADP`/`FRADQ` view factors from HOUR1. Empty slices are the
    /// canopy-free case; otherwise all four slices have equal length.
    living_canopy_temperature_k: []const f64 = &.{},
    standing_dead_temperature_k: []const f64 = &.{},
    living_canopy_radiation_fraction: []const f64 = &.{},
    standing_dead_radiation_fraction: []const f64 = &.{},
};

pub const Radiation = struct {
    absorbed_shortwave_megajoules_per_h: f64,
    sky_net_longwave_megajoules_per_h: f64,
    canopy_longwave_megajoules_per_h: f64,
    net_longwave_megajoules_per_h: f64,
    net_radiation_megajoules_per_h: f64,
};

const solid_snow_heat_capacity_megajoules_per_m3_k: f64 = 2.095;

fn solidFrozenCorrectionMegajoulesPerM3(parameters: Parameters) !f64 {
    return ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        solid_snow_heat_capacity_megajoules_per_m3_k,
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
        parameters.latent_heat_of_fusion_megajoules_per_m3,
        parameters.pure_water_melting_temperature_k,
    );
}

fn censusEnthalpyMegajoules(
    heat_capacity_megajoules_per_k: f64,
    temperature_k: f64,
    solid_snow_water_equivalent_m3: f64,
    physical_ice_volume_m3: f64,
    parameters: Parameters,
) !f64 {
    const ice_capacity_we = try ice_units.heatCapacityPerWaterEquivalentM3K(
        parameters.ice_heat_capacity_megajoules_per_m3_k,
        parameters.ice_density_megagrams_per_m3,
    );
    const ice_correction = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        ice_capacity_we,
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
        parameters.latent_heat_of_fusion_megajoules_per_m3,
        parameters.pure_water_melting_temperature_k,
    );
    const ice_we = try ice_units.waterEquivalentM3FromPhysicalVolume(
        physical_ice_volume_m3,
        parameters.ice_density_megagrams_per_m3,
    );
    const result = heat_capacity_megajoules_per_k * temperature_k +
        (try solidFrozenCorrectionMegajoulesPerM3(parameters)) * solid_snow_water_equivalent_m3 +
        ice_correction * ice_we;
    if (!std.math.isFinite(result)) return error.NonFiniteSnowSurfaceReferenceHeat;
    return result;
}

/// Applies WATSUB 1275--1301 to L=1 before the atmosphere boundary solve.
/// This is a local phase transfer: liquid is the first donor to a vapor
/// deficit and solid snow supplies only the remainder. The accepted donor
/// fraction limits both pools, and every cell plus both diagnostics commit
/// atomically.
pub fn equilibrateSurface(
    allocator: std.mem.Allocator,
    state: *snow.State,
    parameters: Parameters,
    context: EquilibriumContext,
) !void {
    try validateParameters(parameters);
    try validateStateDimensions(state);
    const cells = state.cell_count;
    if (context.latent_heat_megajoules.len != cells or
        context.reference_state_heat_megajoules.len != cells or
        context.cell_area_m2.len != cells)
        return error.SnowSurfaceEquilibriumDimensionMismatch;
    if (!std.math.isFinite(context.donor_availability_fraction) or
        context.donor_availability_fraction <= 0 or context.donor_availability_fraction > 1 or
        !std.math.isFinite(context.energy_conservation_absolute_tolerance_megajoules_per_m2) or
        context.energy_conservation_absolute_tolerance_megajoules_per_m2 < 0 or
        !std.math.isFinite(context.energy_conservation_relative_tolerance) or
        context.energy_conservation_relative_tolerance < 0)
        return error.InvalidSnowSurfaceEquilibriumTimestep;

    const solid = try allocator.dupe(f64, state.solid_snow_water_equivalent_m3);
    defer allocator.free(solid);
    const liquid = try allocator.dupe(f64, state.liquid_water_volume_m3);
    defer allocator.free(liquid);
    const vapor = try allocator.dupe(f64, state.vapor_water_equivalent_m3);
    defer allocator.free(vapor);
    const temperature = try allocator.dupe(f64, state.temperature_k);
    defer allocator.free(temperature);
    const heat_capacity = try allocator.dupe(f64, state.heat_capacity_megajoules_per_k);
    defer allocator.free(heat_capacity);
    const latent_heat = try allocator.alloc(f64, cells);
    defer allocator.free(latent_heat);
    const reference_heat = try allocator.alloc(f64, cells);
    defer allocator.free(reference_heat);

    for (0..cells) |cell| {
        const top = cell * state.layer_capacity;
        try validateTopLayer(state, top);
        if (!std.math.isFinite(context.cell_area_m2[cell]) or context.cell_area_m2[cell] <= 0)
            return error.InvalidSnowSurfaceEquilibriumCellArea;
        if (!state.active[top] or
            !try topLayerAboveActivationThreshold(state, top) or
            state.air_filled_volume_m3[top] == 0)
        {
            latent_heat[cell] = 0;
            reference_heat[cell] = 0;
            continue;
        }

        const equilibrium_fraction = try equilibriumVaporFraction(temperature[top], parameters);
        const transfer_from_vapor_m3 = vapor[top] -
            equilibrium_fraction * state.air_filled_volume_m3[top];
        // watsub.f:1278-1282. Positive change condenses vapor into liquid;
        // negative change evaporates liquid, then sublimates solid snow.
        const liquid_change_m3 = @max(
            transfer_from_vapor_m3,
            -liquid[top] * context.donor_availability_fraction,
        );
        const residual_deficit_m3 = @min(0, transfer_from_vapor_m3 - liquid_change_m3);
        const solid_change_m3 = @max(
            residual_deficit_m3,
            -solid[top] * context.donor_availability_fraction,
        );
        const vapor_change_m3 = -liquid_change_m3 - solid_change_m3;
        const next_solid = solid[top] + solid_change_m3;
        const next_liquid = liquid[top] + liquid_change_m3;
        const next_vapor = vapor[top] + vapor_change_m3;
        const latent = parameters.liquid_evaporation_latent_heat_megajoules_per_m3 * liquid_change_m3 +
            parameters.snow_sublimation_latent_heat_megajoules_per_m3 * solid_change_m3;
        const next_capacity = solid_snow_heat_capacity_megajoules_per_m3_k * next_solid +
            parameters.liquid_water_heat_capacity_megajoules_per_m3_k * (next_liquid + next_vapor) +
            parameters.ice_heat_capacity_megajoules_per_m3_k * state.ice_volume_m3[top];
        const next_sensible_energy = heat_capacity[top] * temperature[top] + latent;
        const next_temperature = if (next_capacity > 0)
            next_sensible_energy / next_capacity
        else
            temperature[top];
        // F77 publishes `Cs*SWE*T`; only the change in solid SWE needs the
        // carrier-specific offset to the liquid-referenced enthalpy census.
        const reference_adjustment =
            latent + (try solidFrozenCorrectionMegajoulesPerM3(parameters)) * solid_change_m3;
        const census_before = try censusEnthalpyMegajoules(
            heat_capacity[top],
            temperature[top],
            solid[top],
            state.ice_volume_m3[top],
            parameters,
        );
        const census_after = try censusEnthalpyMegajoules(
            next_capacity,
            next_temperature,
            next_solid,
            state.ice_volume_m3[top],
            parameters,
        );
        const census_change = census_after - census_before;
        const energy_scale = @max(@max(@abs(census_before), @abs(census_after)), @abs(reference_adjustment));
        const energy_tolerance = context.energy_conservation_absolute_tolerance_megajoules_per_m2 * context.cell_area_m2[cell] +
            context.energy_conservation_relative_tolerance * energy_scale +
            256 * std.math.floatEps(f64) * energy_scale;
        inline for (.{
            transfer_from_vapor_m3,
            liquid_change_m3,
            solid_change_m3,
            vapor_change_m3,
            next_solid,
            next_liquid,
            next_vapor,
            latent,
            next_capacity,
            next_temperature,
            census_before,
            census_after,
            census_change,
            reference_adjustment,
            energy_scale,
            energy_tolerance,
        }) |value| if (!std.math.isFinite(value))
            return error.NonFiniteSnowSurfaceEquilibriumCandidate;
        if (next_solid < 0 or next_liquid < 0 or next_vapor < 0 or
            next_capacity < 0 or next_temperature <= 0)
            return error.InvalidSnowSurfaceEquilibriumCandidate;
        if (@abs(census_change - reference_adjustment) > energy_tolerance)
            return error.SnowSurfaceEquilibriumEnergyConservationFailure;

        solid[top] = next_solid;
        liquid[top] = next_liquid;
        vapor[top] = next_vapor;
        heat_capacity[top] = next_capacity;
        temperature[top] = next_temperature;
        latent_heat[cell] = latent;
        reference_heat[cell] = reference_adjustment;
        if (!std.math.isFinite(reference_heat[cell]))
            return error.NonFiniteSnowSurfaceReferenceHeat;
    }

    @memcpy(state.solid_snow_water_equivalent_m3, solid);
    @memcpy(state.liquid_water_volume_m3, liquid);
    @memcpy(state.vapor_water_equivalent_m3, vapor);
    @memcpy(state.temperature_k, temperature);
    @memcpy(state.heat_capacity_megajoules_per_k, heat_capacity);
    state.refreshAllGeometry();
    @memcpy(context.latent_heat_megajoules, latent_heat);
    @memcpy(context.reference_state_heat_megajoules, reference_heat);
}

pub fn prepareSurfaceSources(state: *const snow.State, parameters: Parameters, context: SourceContext) !void {
    try validateParameters(parameters);
    const cells = state.cell_count;
    if (context.fallback_temperature_k.len != cells or context.vapor_fraction.len != cells or context.temperature_k.len != cells)
        return error.SnowSurfaceSourceDimensionMismatch;
    try validateStateDimensions(state);

    // Stage the read-only products too: an invalid later cell must not leave a
    // partially refreshed source vector that a retry could consume.
    const vapor_candidate = try state.allocator.alloc(f64, cells);
    defer state.allocator.free(vapor_candidate);
    const temperature_candidate = try state.allocator.alloc(f64, cells);
    defer state.allocator.free(temperature_candidate);
    for (0..cells) |cell| {
        const top = cell * state.layer_capacity;
        const fallback_temperature = context.fallback_temperature_k[cell];
        if (!std.math.isFinite(fallback_temperature) or fallback_temperature <= 0)
            return error.InvalidSnowSurfaceFallbackTemperature;
        try validateTopLayer(state, top);
        const water_m3 = layerWaterEquivalentM3(state, top, parameters);
        if (!state.active[top] or
            !try topLayerAboveActivationThreshold(state, top) or
            water_m3 == 0)
        {
            vapor_candidate[cell] = 0;
            temperature_candidate[cell] = fallback_temperature;
            continue;
        }
        const temperature = state.temperature_k[top];
        const vapor_fraction = try surfaceVaporFraction(state, top, parameters);
        if (!std.math.isFinite(vapor_fraction) or vapor_fraction < 0)
            return error.InvalidSnowSurfaceVaporFraction;
        vapor_candidate[cell] = vapor_fraction;
        temperature_candidate[cell] = temperature;
    }
    @memcpy(context.vapor_fraction, vapor_candidate);
    @memcpy(context.temperature_k, temperature_candidate);
}

/// Applies the accepted ground-air state to the top snow layer.  This is the
/// prognostic counterpart to the snow source supplied to the implicit
/// ground-air solve.  It is deliberately allocation-backed and atomic because
/// it runs inside the heat/water/solute retry transaction.
pub fn applyAccepted(allocator: std.mem.Allocator, state: *snow.State, parameters: Parameters, context: ApplyContext) !void {
    try validateParameters(parameters);
    try validateStateDimensions(state);
    const cells = state.cell_count;
    inline for (.{
        context.cell_area_m2.len,
        context.vapor_conductance_m3_per_h.len,
        context.sensible_conductance_megajoules_per_h_k.len,
        context.accepted_ground_air_vapor_fraction.len,
        context.accepted_ground_air_temperature_k.len,
        context.radiative_heat_megajoules_per_h.len,
        context.evaporation_m3.len,
        context.condensation_m3.len,
        context.boundary_heat_megajoules.len,
        context.latent_heat_megajoules.len,
        context.carrier_sensible_heat_megajoules.len,
        context.air_sensible_heat_megajoules.len,
        context.radiative_heat_megajoules.len,
    }) |length| if (length != cells) return error.SnowSurfaceExchangeDimensionMismatch;
    if (!std.math.isFinite(context.physical_time_step_hours) or
        context.physical_time_step_hours <= 0 or context.physical_time_step_hours > 1 or
        !std.math.isFinite(context.donor_availability_fraction) or
        context.donor_availability_fraction <= 0 or context.donor_availability_fraction > 1)
        return error.InvalidSnowSurfaceExchangeTimestep;
    if (!std.math.isFinite(context.energy_conservation_absolute_tolerance_megajoules_per_m2) or
        context.energy_conservation_absolute_tolerance_megajoules_per_m2 < 0 or
        !std.math.isFinite(context.energy_conservation_relative_tolerance) or
        context.energy_conservation_relative_tolerance < 0 or
        !std.math.isFinite(context.minimum_temperature_k) or
        !std.math.isFinite(context.maximum_temperature_k) or
        context.minimum_temperature_k <= 0 or
        context.maximum_temperature_k < context.minimum_temperature_k)
        return error.InvalidSnowSurfaceExchangeEnergyTolerance;

    const solid = try allocator.dupe(f64, state.solid_snow_water_equivalent_m3);
    defer allocator.free(solid);
    const liquid = try allocator.dupe(f64, state.liquid_water_volume_m3);
    defer allocator.free(liquid);
    const vapor = try allocator.dupe(f64, state.vapor_water_equivalent_m3);
    defer allocator.free(vapor);
    const temperature = try allocator.dupe(f64, state.temperature_k);
    defer allocator.free(temperature);
    const heat_capacity = try allocator.dupe(f64, state.heat_capacity_megajoules_per_k);
    defer allocator.free(heat_capacity);
    const active = try allocator.dupe(bool, state.active);
    defer allocator.free(active);
    const evaporation = try allocator.alloc(f64, cells);
    defer allocator.free(evaporation);
    const condensation = try allocator.alloc(f64, cells);
    defer allocator.free(condensation);
    const boundary_heat = try allocator.alloc(f64, cells);
    defer allocator.free(boundary_heat);
    const latent_heat = try allocator.alloc(f64, cells);
    defer allocator.free(latent_heat);
    const carrier_heat = try allocator.alloc(f64, cells);
    defer allocator.free(carrier_heat);
    const air_sensible_heat = try allocator.alloc(f64, cells);
    defer allocator.free(air_sensible_heat);
    const radiative_heat = try allocator.alloc(f64, cells);
    defer allocator.free(radiative_heat);

    for (0..cells) |cell| {
        const top = cell * state.layer_capacity;
        try validateTopLayer(state, top);
        if (temperature[top] < context.minimum_temperature_k or
            temperature[top] > context.maximum_temperature_k)
        {
            if (!builtin.is_test) std.log.err(
                "snow surface exchange rejected input temperature: cell={d} top={d} temperature_k={e} minimum_temperature_k={e} maximum_temperature_k={e} active={} heat_capacity_mj_per_k={e} solid_snow_we_m3={e} liquid_water_m3={e} vapor_water_we_m3={e} ice_volume_m3={e}",
                .{ cell, top, temperature[top], context.minimum_temperature_k, context.maximum_temperature_k, state.active[top], heat_capacity[top], solid[top], liquid[top], vapor[top], state.ice_volume_m3[top] },
            );
            return error.InvalidSnowSurfaceExchangeTemperature;
        }
        if (!std.math.isFinite(context.cell_area_m2[cell]) or context.cell_area_m2[cell] <= 0)
            return error.InvalidSnowSurfaceExchangeCellArea;
        const vapor_conductance = context.vapor_conductance_m3_per_h[cell];
        const sensible_conductance = context.sensible_conductance_megajoules_per_h_k[cell];
        const air_vapor_fraction = context.accepted_ground_air_vapor_fraction[cell];
        const air_temperature = context.accepted_ground_air_temperature_k[cell];
        const radiative_heat_per_h = context.radiative_heat_megajoules_per_h[cell];
        inline for (.{ vapor_conductance, sensible_conductance, air_vapor_fraction, air_temperature, radiative_heat_per_h }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteSnowSurfaceExchangeInput;
        if (vapor_conductance < 0 or sensible_conductance < 0 or air_vapor_fraction < 0 or air_temperature <= 0)
            return error.InvalidSnowSurfaceExchangeInput;

        const initial_water = layerWaterEquivalentM3(state, top, parameters);
        // WATSUB 1227 gates the complete surface radiation, vapor, and
        // sensible-heat block on strict VHCPWM2 > VHCPWX. Canonical cold snow
        // may remain below that area-scaled activation threshold; it is later
        // assigned the source-compatible reference temperature by
        // snow_inactive_temperature and must not integrate a boundary flux as
        // though its vanishing heat capacity were an active prognostic layer.
        if (!state.active[top] or
            !try topLayerAboveActivationThreshold(state, top) or
            initial_water == 0)
        {
            evaporation[cell] = 0;
            condensation[cell] = 0;
            boundary_heat[cell] = 0;
            latent_heat[cell] = 0;
            carrier_heat[cell] = 0;
            air_sensible_heat[cell] = 0;
            radiative_heat[cell] = 0;
            continue;
        }

        // watsub.f:1323-1327 reads the accepted pore-vapor concentration
        // produced by the immediately preceding L=1 equilibrium. It does not
        // replace a donor-limited result with an assumed saturated value.
        const surface_fraction = if (state.air_filled_volume_m3[top] > 0)
            vapor[top] / state.air_filled_volume_m3[top]
        else
            try equilibriumVaporFraction(temperature[top], parameters);
        if (!std.math.isFinite(surface_fraction) or surface_fraction < 0)
            return error.InvalidSnowSurfaceVaporFraction;
        const unlimited_into_snow_m3 = vapor_conductance *
            (air_vapor_fraction - surface_fraction) * context.physical_time_step_hours;
        if (!std.math.isFinite(unlimited_into_snow_m3))
            return error.NonFiniteSnowSurfaceWaterExchange;

        // watsub.f:1329-1334. Vapor is immediately available; liquid and
        // solid availability scale with the independent donor fraction.
        // An ice-only or liquid-only surface has no pore-air carrier in which
        // incoming vapor can reside. Condense that influx directly into the
        // liquid lane below, including its latent heat. The existing phase
        // owner handles any subsequent freezing. Porous-snow exchange and
        // the outward vapor/liquid/solid donor order remain unchanged.
        const vapor_change_m3 = if (state.air_filled_volume_m3[top] == 0 and unlimited_into_snow_m3 > 0)
            0
        else
            @max(unlimited_into_snow_m3, -vapor[top]);
        const liquid_change_m3 = @max(
            unlimited_into_snow_m3 - vapor_change_m3,
            -liquid[top] * context.donor_availability_fraction,
        );
        const solid_change_m3 = @max(
            unlimited_into_snow_m3 - vapor_change_m3 - liquid_change_m3,
            -solid[top] * context.donor_availability_fraction,
        );
        const signed_into_snow_m3 = vapor_change_m3 + liquid_change_m3 + solid_change_m3;
        const donor_temperature = if (signed_into_snow_m3 < 0) temperature[top] else air_temperature;
        const carrier_sensible =
            ((vapor_change_m3 + liquid_change_m3) * parameters.liquid_water_heat_capacity_megajoules_per_m3_k +
                solid_change_m3 * solid_snow_heat_capacity_megajoules_per_m3_k) * donor_temperature;
        const latent = liquid_change_m3 * parameters.liquid_evaporation_latent_heat_megajoules_per_m3 +
            solid_change_m3 * parameters.snow_sublimation_latent_heat_megajoules_per_m3;
        const accepted_radiation = radiative_heat_per_h * context.physical_time_step_hours;

        const next_solid = solid[top] + solid_change_m3;
        const next_liquid = liquid[top] + liquid_change_m3;
        const next_vapor = vapor[top] + vapor_change_m3;
        const next_capacity = solid_snow_heat_capacity_megajoules_per_m3_k * next_solid +
            parameters.liquid_water_heat_capacity_megajoules_per_m3_k * (next_liquid + next_vapor) +
            parameters.ice_heat_capacity_megajoules_per_m3_k * state.ice_volume_m3[top];
        const old_sensible_energy = heat_capacity[top] * temperature[top];
        const non_sensible_energy = old_sensible_energy + carrier_sensible +
            latent + accepted_radiation;
        const interval_sensible_conductance = sensible_conductance *
            context.physical_time_step_hours;
        const sensible_denominator = next_capacity +
            interval_sensible_conductance;
        // The accepted ground-air temperature is fixed over this boundary
        // transaction. Solve C*T1 = E* + G*dt*(Tair - T1) at the endpoint
        // instead of advancing that stiff linear exchange with forward Euler.
        // This is first-order consistent as dt -> 0, cannot overshoot the air
        // endpoint solely because a snow layer is thin, and publishes the
        // exact equal-and-opposite accepted heat to the ground-air owner.
        const next_temperature = if (sensible_denominator > 0)
            (non_sensible_energy +
                interval_sensible_conductance * air_temperature) /
                sensible_denominator
        else
            temperature[top];
        const direct_sensible = if (interval_sensible_conductance > 0)
            next_capacity * next_temperature - non_sensible_energy
        else
            0;
        const next_sensible_energy = non_sensible_energy + direct_sensible;
        inline for (.{
            next_solid,
            next_liquid,
            next_vapor,
            next_capacity,
            carrier_sensible,
            latent,
            interval_sensible_conductance,
            sensible_denominator,
            direct_sensible,
            accepted_radiation,
            non_sensible_energy,
            next_sensible_energy,
            next_temperature,
        }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteSnowSurfaceExchangeCandidate;
        if (next_solid < 0 or next_liquid < 0 or next_vapor < 0 or next_capacity < 0)
            return error.InvalidSnowSurfaceExchangeCandidate;
        if (!std.math.isFinite(next_temperature) or
            next_temperature < context.minimum_temperature_k or
            next_temperature > context.maximum_temperature_k)
        {
            if (!builtin.is_test) std.log.err(
                "snow surface exchange rejected candidate temperature: cell={d} top={d} current_temperature_k={e} next_temperature_k={e} minimum_temperature_k={e} maximum_temperature_k={e} old_heat_capacity_mj_per_k={e} next_heat_capacity_mj_per_k={e} old_sensible_energy_mj={e} next_sensible_energy_mj={e} carrier_sensible_mj={e} latent_mj={e} direct_sensible_mj={e} radiation_mj={e} next_solid_snow_we_m3={e} next_liquid_water_m3={e} next_vapor_water_we_m3={e}",
                .{ cell, top, temperature[top], next_temperature, context.minimum_temperature_k, context.maximum_temperature_k, heat_capacity[top], next_capacity, old_sensible_energy, next_sensible_energy, carrier_sensible, latent, direct_sensible, accepted_radiation, next_solid, next_liquid, next_vapor },
            );
            return error.InvalidSnowSurfaceExchangeTemperature;
        }
        const census_before = try censusEnthalpyMegajoules(
            heat_capacity[top],
            temperature[top],
            solid[top],
            state.ice_volume_m3[top],
            parameters,
        );
        const census_after = try censusEnthalpyMegajoules(
            next_capacity,
            next_temperature,
            next_solid,
            state.ice_volume_m3[top],
            parameters,
        );
        solid[top] = next_solid;
        liquid[top] = next_liquid;
        vapor[top] = next_vapor;
        heat_capacity[top] = next_capacity;
        temperature[top] = next_temperature;
        active[top] = next_solid + next_liquid + next_vapor + state.ice_volume_m3[top] > 0;
        evaporation[cell] = @max(0, -signed_into_snow_m3);
        condensation[cell] = @max(0, signed_into_snow_m3);
        latent_heat[cell] = latent;
        carrier_heat[cell] = carrier_sensible;
        air_sensible_heat[cell] = direct_sensible;
        radiative_heat[cell] = accepted_radiation;
        boundary_heat[cell] = carrier_sensible + latent + direct_sensible + accepted_radiation +
            (try solidFrozenCorrectionMegajoulesPerM3(parameters)) * solid_change_m3;
        if (!std.math.isFinite(boundary_heat[cell]))
            return error.NonFiniteSnowSurfaceBoundaryHeat;
        const energy_scale = @max(@max(@abs(census_before), @abs(census_after)), @abs(boundary_heat[cell]));
        const energy_tolerance = context.energy_conservation_absolute_tolerance_megajoules_per_m2 * context.cell_area_m2[cell] +
            context.energy_conservation_relative_tolerance * energy_scale +
            256 * std.math.floatEps(f64) * energy_scale;
        const energy_residual = (census_after - census_before) - boundary_heat[cell];
        if (!std.math.isFinite(energy_tolerance) or @abs(energy_residual) > energy_tolerance) {
            if (!builtin.is_test) std.log.err(
                "snow surface exchange energy failure: cell={d} dt_h={e} donor_fraction={e} residual_mj={e} tolerance_mj={e} census_before_mj={e} census_after_mj={e} boundary_heat_mj={e} old_sensible_mj={e} next_sensible_target_mj={e} temperature_before_k={e} temperature_after_k={e} capacity_before_mj_k={e} capacity_after_mj_k={e} carrier_sensible_mj={e} latent_mj={e} air_sensible_mj={e} radiation_mj={e}",
                .{
                    cell,
                    context.physical_time_step_hours,
                    context.donor_availability_fraction,
                    energy_residual,
                    energy_tolerance,
                    census_before,
                    census_after,
                    boundary_heat[cell],
                    old_sensible_energy,
                    next_sensible_energy,
                    state.temperature_k[top],
                    next_temperature,
                    state.heat_capacity_megajoules_per_k[top],
                    next_capacity,
                    carrier_sensible,
                    latent,
                    direct_sensible,
                    accepted_radiation,
                },
            );
            if (!builtin.is_test) std.log.err(
                "snow surface exchange energy failure carriers: solid_before_m3={e} solid_change_m3={e} solid_after_m3={e} liquid_before_m3={e} liquid_change_m3={e} liquid_after_m3={e} vapor_before_m3={e} vapor_change_m3={e} vapor_after_m3={e} ice_physical_m3={e} air_volume_m3={e} surface_vapor_fraction={e} air_vapor_fraction={e} requested_water_m3={e} accepted_water_m3={e}",
                .{
                    state.solid_snow_water_equivalent_m3[top],
                    solid_change_m3,
                    next_solid,
                    state.liquid_water_volume_m3[top],
                    liquid_change_m3,
                    next_liquid,
                    state.vapor_water_equivalent_m3[top],
                    vapor_change_m3,
                    next_vapor,
                    state.ice_volume_m3[top],
                    state.air_filled_volume_m3[top],
                    surface_fraction,
                    air_vapor_fraction,
                    unlimited_into_snow_m3,
                    signed_into_snow_m3,
                },
            );
            return error.SnowSurfaceExchangeEnergyConservationFailure;
        }
    }

    @memcpy(state.solid_snow_water_equivalent_m3, solid);
    @memcpy(state.liquid_water_volume_m3, liquid);
    @memcpy(state.vapor_water_equivalent_m3, vapor);
    @memcpy(state.temperature_k, temperature);
    @memcpy(state.heat_capacity_megajoules_per_k, heat_capacity);
    @memcpy(state.active, active);
    state.refreshAllGeometry();
    @memcpy(context.evaporation_m3, evaporation);
    @memcpy(context.condensation_m3, condensation);
    @memcpy(context.boundary_heat_megajoules, boundary_heat);
    @memcpy(context.latent_heat_megajoules, latent_heat);
    @memcpy(context.carrier_sensible_heat_megajoules, carrier_heat);
    @memcpy(context.air_sensible_heat_megajoules, air_sensible_heat);
    @memcpy(context.radiative_heat_megajoules, radiative_heat);
}

/// Exact `watsub.f:1238-1249` snow-surface radiation. The shortwave albedo
/// weights are 0.90 dry snow, 0.30 refrozen ice, and 0.06 liquid water.
/// Living and standing-dead longwave use the source's snow emissivity `EMMW`
/// and current `FRADP`/`FRADQ` once each; their temperatures are accepted
/// hourly canopy state and are read-only forcing during snow recovery steps.
pub fn calculateNetRadiation(inputs: RadiationInputs) !Radiation {
    inline for (.{
        inputs.snow_cover_fraction,
        inputs.cell_area_m2,
        inputs.incident_shortwave_megajoules_per_m2_h,
        inputs.atmospheric_longwave_megajoules_per_m2_h,
        inputs.ground_exposure_fraction,
        inputs.snow_longwave_emissivity,
        inputs.stefan_boltzmann_megajoules_per_m2_h_k4,
        inputs.snow_temperature_k,
        inputs.solid_snow_water_equivalent_m3,
        inputs.liquid_water_m3,
        inputs.ice_volume_m3,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteSnowSurfaceRadiationInput;
    const canopy_count = inputs.living_canopy_temperature_k.len;
    if (inputs.standing_dead_temperature_k.len != canopy_count or
        inputs.living_canopy_radiation_fraction.len != canopy_count or
        inputs.standing_dead_radiation_fraction.len != canopy_count)
        return error.SnowSurfaceCanopyRadiationDimensionMismatch;
    for (0..canopy_count) |plant| {
        const living_temperature = inputs.living_canopy_temperature_k[plant];
        const dead_temperature = inputs.standing_dead_temperature_k[plant];
        const living_fraction = inputs.living_canopy_radiation_fraction[plant];
        const dead_fraction = inputs.standing_dead_radiation_fraction[plant];
        inline for (.{ living_temperature, dead_temperature, living_fraction, dead_fraction }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteSnowSurfaceRadiationInput;
        // WATSUB 1244--1249 multiplies TKC/TKD radiation by FRADP/FRADQ.
        // An absent population therefore carries a zero view factor and may
        // retain its zero-temperature sentinel; it contributes no radiation.
        // A negative temperature is never a valid sentinel, and a positive
        // view factor always requires a physical Kelvin temperature.
        if (living_temperature < 0 or dead_temperature < 0 or
            (living_fraction > 0 and living_temperature == 0) or
            (dead_fraction > 0 and dead_temperature == 0) or
            living_fraction < 0 or living_fraction > 1 or
            dead_fraction < 0 or dead_fraction > 1)
            return error.InvalidSnowSurfaceRadiationInput;
    }
    if (inputs.snow_cover_fraction < 0 or inputs.snow_cover_fraction > 1 or
        inputs.cell_area_m2 <= 0 or inputs.incident_shortwave_megajoules_per_m2_h < 0 or
        inputs.atmospheric_longwave_megajoules_per_m2_h < 0 or
        inputs.ground_exposure_fraction < 0 or inputs.ground_exposure_fraction > 1 or
        inputs.snow_longwave_emissivity < 0 or inputs.snow_longwave_emissivity > 1 or
        inputs.stefan_boltzmann_megajoules_per_m2_h_k4 <= 0 or
        inputs.snow_temperature_k <= 0 or inputs.solid_snow_water_equivalent_m3 < 0 or
        inputs.liquid_water_m3 < 0 or inputs.ice_volume_m3 < 0)
        return error.InvalidSnowSurfaceRadiationInput;
    const phase_total = inputs.solid_snow_water_equivalent_m3 + inputs.liquid_water_m3 + inputs.ice_volume_m3;
    if (inputs.snow_cover_fraction > 0 and phase_total <= 0)
        return error.MissingSnowSurfaceRadiationCarrier;
    const snow_albedo = if (phase_total > 0)
        (0.90 * inputs.solid_snow_water_equivalent_m3 +
            0.06 * inputs.liquid_water_m3 + 0.30 * inputs.ice_volume_m3) / phase_total
    else
        0.90;
    // `RADXW=RADG*FSNW` (watsub.f:572): RADG is already the shortwave that
    // passed through the canopy, so FRADG must not attenuate it a second
    // time. Sky/emitted longwave do carry FRADG (lines 628, 631-632).
    const snow_area = inputs.cell_area_m2 * inputs.snow_cover_fraction;
    const longwave_exposed_area = snow_area * inputs.ground_exposure_fraction;
    const absorbed_shortwave = inputs.incident_shortwave_megajoules_per_m2_h *
        (1 - snow_albedo) * snow_area;
    const sky_net_longwave = (inputs.atmospheric_longwave_megajoules_per_m2_h -
        inputs.snow_longwave_emissivity * inputs.stefan_boltzmann_megajoules_per_m2_h_k4 *
            std.math.pow(f64, inputs.snow_temperature_k, 4)) * longwave_exposed_area;
    const snow_emission_coefficient = inputs.snow_longwave_emissivity *
        inputs.stefan_boltzmann_megajoules_per_m2_h_k4 * snow_area;
    const snow_temperature_fourth = std.math.pow(f64, inputs.snow_temperature_k, 4);
    var canopy_longwave: f64 = 0;
    for (0..canopy_count) |plant| {
        const living_fraction = inputs.living_canopy_radiation_fraction[plant];
        if (living_fraction > 0) {
            canopy_longwave += snow_emission_coefficient *
                (std.math.pow(f64, inputs.living_canopy_temperature_k[plant], 4) -
                    snow_temperature_fourth) *
                living_fraction;
        }
        const dead_fraction = inputs.standing_dead_radiation_fraction[plant];
        if (dead_fraction > 0) {
            canopy_longwave += snow_emission_coefficient *
                (std.math.pow(f64, inputs.standing_dead_temperature_k[plant], 4) -
                    snow_temperature_fourth) *
                dead_fraction;
        }
    }
    const net_longwave = sky_net_longwave + canopy_longwave;
    const net = absorbed_shortwave + net_longwave;
    inline for (.{ absorbed_shortwave, sky_net_longwave, canopy_longwave, net_longwave, net }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSnowSurfaceRadiation;
    return .{
        .absorbed_shortwave_megajoules_per_h = absorbed_shortwave,
        .sky_net_longwave_megajoules_per_h = sky_net_longwave,
        .canopy_longwave_megajoules_per_h = canopy_longwave,
        .net_longwave_megajoules_per_h = net_longwave,
        .net_radiation_megajoules_per_h = net,
    };
}

fn validateParameters(parameters: Parameters) !void {
    inline for (@typeInfo(Parameters).@"struct".fields) |field|
        if (!std.math.isFinite(@field(parameters, field.name)))
            return error.NonFiniteSnowSurfaceExchangeParameter;
    if (parameters.vapor_volume_prefactor_k <= 0 or
        parameters.equilibrium_relative_humidity < 0 or parameters.equilibrium_relative_humidity > 1 or
        parameters.clausius_clapeyron_temperature_k <= 0 or
        parameters.reference_inverse_temperature_per_k <= 0 or
        parameters.liquid_evaporation_latent_heat_megajoules_per_m3 <= 0 or
        parameters.snow_sublimation_latent_heat_megajoules_per_m3 <= 0 or
        parameters.latent_heat_of_fusion_megajoules_per_m3 <= 0 or
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or
        parameters.ice_heat_capacity_megajoules_per_m3_k <= 0 or
        parameters.ice_density_megagrams_per_m3 <= 0 or
        parameters.ice_density_megagrams_per_m3 > 1 or
        parameters.pure_water_melting_temperature_k <= 0)
        return error.InvalidSnowSurfaceExchangeParameter;
}

fn validateStateDimensions(state: *const snow.State) !void {
    if (state.cell_count == 0 or state.layer_capacity == 0) return error.SnowSurfaceExchangeDimensionMismatch;
    const layers = try std.math.mul(usize, state.cell_count, state.layer_capacity);
    inline for (.{
        state.active.len,
        state.solid_snow_water_equivalent_m3.len,
        state.liquid_water_volume_m3.len,
        state.vapor_water_equivalent_m3.len,
        state.ice_volume_m3.len,
        state.air_filled_volume_m3.len,
        state.temperature_k.len,
        state.heat_capacity_megajoules_per_k.len,
        state.horizontal_area_m2.len,
    }) |length| if (length != layers) return error.SnowSurfaceExchangeDimensionMismatch;
}

fn topLayerAboveActivationThreshold(
    state: *const snow.State,
    top: usize,
) !bool {
    const area_m2 = state.horizontal_area_m2[top];
    if (!std.math.isFinite(area_m2) or area_m2 <= 0)
        return error.InvalidSnowSurfaceState;
    const threshold =
        snow.activation_heat_capacity_megajoules_per_m2_k * area_m2;
    if (!std.math.isFinite(threshold))
        return error.InvalidSnowSurfaceState;
    return state.heat_capacity_megajoules_per_k[top] > threshold;
}

fn validateTopLayer(state: *const snow.State, top: usize) !void {
    inline for (.{
        state.solid_snow_water_equivalent_m3[top],
        state.liquid_water_volume_m3[top],
        state.vapor_water_equivalent_m3[top],
        state.ice_volume_m3[top],
        state.air_filled_volume_m3[top],
        state.temperature_k[top],
        state.heat_capacity_megajoules_per_k[top],
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSnowSurfaceState;
    if (state.solid_snow_water_equivalent_m3[top] < 0 or
        state.liquid_water_volume_m3[top] < 0 or
        state.vapor_water_equivalent_m3[top] < 0 or
        state.ice_volume_m3[top] < 0 or
        state.air_filled_volume_m3[top] < 0 or
        state.temperature_k[top] <= 0 or
        state.heat_capacity_megajoules_per_k[top] < 0)
        return error.InvalidSnowSurfaceState;
}

fn layerWaterEquivalentM3(state: *const snow.State, top: usize, parameters: Parameters) f64 {
    return state.solid_snow_water_equivalent_m3[top] +
        state.liquid_water_volume_m3[top] + state.vapor_water_equivalent_m3[top] +
        state.ice_volume_m3[top] * parameters.ice_density_megagrams_per_m3;
}

fn surfaceVaporFraction(state: *const snow.State, top: usize, parameters: Parameters) !f64 {
    if (state.air_filled_volume_m3[top] > 0)
        return state.vapor_water_equivalent_m3[top] / state.air_filled_volume_m3[top];
    return equilibriumVaporFraction(state.temperature_k[top], parameters);
}

fn equilibriumVaporFraction(temperature_k: f64, parameters: Parameters) !f64 {
    const result = parameters.vapor_volume_prefactor_k / temperature_k *
        parameters.equilibrium_relative_humidity *
        @exp(parameters.clausius_clapeyron_temperature_k *
            (parameters.reference_inverse_temperature_per_k - 1 / temperature_k));
    if (!std.math.isFinite(result) or result < 0) return error.InvalidSnowSurfaceVaporFraction;
    return result;
}

fn testParameters() Parameters {
    return .{
        .vapor_volume_prefactor_k = 2.173e-3,
        .equilibrium_relative_humidity = 0.61,
        .clausius_clapeyron_temperature_k = 5360,
        .reference_inverse_temperature_per_k = 3.661e-3,
        .liquid_evaporation_latent_heat_megajoules_per_m3 = 2465,
        .snow_sublimation_latent_heat_megajoules_per_m3 = 2834,
        .latent_heat_of_fusion_megajoules_per_m3 = 333,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
        .ice_density_megagrams_per_m3 = 0.92,
        .pure_water_melting_temperature_k = 273.15,
    };
}

const TestOutputs = struct {
    cell_area_m2: []f64,
    evaporation: []f64,
    condensation: []f64,
    boundary_heat: []f64,
    latent: []f64,
    carrier: []f64,
    sensible: []f64,
    radiation: []f64,

    fn init(allocator: std.mem.Allocator, cells: usize, initial: f64) !TestOutputs {
        var values: [8][]f64 = undefined;
        var count: usize = 0;
        errdefer for (values[0..count]) |slice| allocator.free(slice);
        for (&values) |*slice| {
            slice.* = try allocator.alloc(f64, cells);
            @memset(slice.*, initial);
            count += 1;
        }
        @memset(values[0], 1);
        return .{ .cell_area_m2 = values[0], .evaporation = values[1], .condensation = values[2], .boundary_heat = values[3], .latent = values[4], .carrier = values[5], .sensible = values[6], .radiation = values[7] };
    }

    fn deinit(self: *TestOutputs, allocator: std.mem.Allocator) void {
        inline for (.{ self.cell_area_m2, self.evaporation, self.condensation, self.boundary_heat, self.latent, self.carrier, self.sensible, self.radiation }) |slice| allocator.free(slice);
        self.* = undefined;
    }

    fn context(self: *TestOutputs, timestep: f64, vapor_conductance: []const f64, sensible_conductance: []const f64, air_vapor: []const f64, air_temperature: []const f64, radiation_per_h: []const f64) ApplyContext {
        return .{
            .physical_time_step_hours = timestep,
            .donor_availability_fraction = 1,
            .cell_area_m2 = self.cell_area_m2,
            .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12,
            .energy_conservation_relative_tolerance = 1e-10,
            // Individual tests narrow this when exercising production-domain
            // rejection; the generic exchange oracle also covers colder
            // synthetic states used by donor-order tests.
            .minimum_temperature_k = std.math.floatTrueMin(f64),
            .maximum_temperature_k = std.math.floatMax(f64),
            .vapor_conductance_m3_per_h = vapor_conductance,
            .sensible_conductance_megajoules_per_h_k = sensible_conductance,
            .accepted_ground_air_vapor_fraction = air_vapor,
            .accepted_ground_air_temperature_k = air_temperature,
            .radiative_heat_megajoules_per_h = radiation_per_h,
            .evaporation_m3 = self.evaporation,
            .condensation_m3 = self.condensation,
            .boundary_heat_megajoules = self.boundary_heat,
            .latent_heat_megajoules = self.latent,
            .carrier_sensible_heat_megajoules = self.carrier,
            .air_sensible_heat_megajoules = self.sensible,
            .radiative_heat_megajoules = self.radiation,
        };
    }
};

test "surface equilibrium applies WATSUB liquid then solid donor order and closes enthalpy" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    const parameters = testParameters();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{268}, &.{0.2}, 0.1, snow.test_thermodynamics);
    state.liquid_water_volume_m3[0] = 1.0e-7;
    state.vapor_water_equivalent_m3[0] = 0;
    state.heat_capacity_megajoules_per_k[0] =
        solid_snow_heat_capacity_megajoules_per_m3_k * state.solid_snow_water_equivalent_m3[0] +
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k * state.liquid_water_volume_m3[0];
    state.refreshAllGeometry();

    const before_solid = state.solid_snow_water_equivalent_m3[0];
    const before_liquid = state.liquid_water_volume_m3[0];
    const before_vapor = state.vapor_water_equivalent_m3[0];
    const before_capacity = state.heat_capacity_megajoules_per_k[0];
    const before_temperature = state.temperature_k[0];
    const before_water = before_solid + before_liquid + before_vapor;
    const timestep: f64 = 0.5;
    const target_vapor = try equilibriumVaporFraction(before_temperature, parameters) *
        state.air_filled_volume_m3[0];
    const transfer_from_vapor = before_vapor - target_vapor;
    const expected_liquid_change = @max(transfer_from_vapor, -before_liquid * timestep);
    const expected_solid_change = @max(
        @min(0, transfer_from_vapor - expected_liquid_change),
        -before_solid * timestep,
    );
    const expected_vapor_change = -expected_liquid_change - expected_solid_change;
    const expected_latent = parameters.liquid_evaporation_latent_heat_megajoules_per_m3 * expected_liquid_change +
        parameters.snow_sublimation_latent_heat_megajoules_per_m3 * expected_solid_change;
    const frozen_rebasing =
        (parameters.liquid_water_heat_capacity_megajoules_per_m3_k -
            solid_snow_heat_capacity_megajoules_per_m3_k) *
        parameters.pure_water_melting_temperature_k -
        parameters.latent_heat_of_fusion_megajoules_per_m3;
    var latent = [_]f64{17};
    var reference = [_]f64{19};
    try equilibrateSurface(std.testing.allocator, &state, parameters, .{
        .donor_availability_fraction = timestep,
        .latent_heat_megajoules = &latent,
        .reference_state_heat_megajoules = &reference,
        .cell_area_m2 = &.{1},
        .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12,
        .energy_conservation_relative_tolerance = 1e-10,
    });

    try std.testing.expect(expected_liquid_change < 0);
    try std.testing.expect(expected_solid_change < 0);
    try std.testing.expectApproxEqAbs(before_liquid + expected_liquid_change, state.liquid_water_volume_m3[0], 1e-18);
    try std.testing.expectApproxEqAbs(before_solid + expected_solid_change, state.solid_snow_water_equivalent_m3[0], 1e-18);
    try std.testing.expectApproxEqAbs(before_vapor + expected_vapor_change, state.vapor_water_equivalent_m3[0], 1e-18);
    try std.testing.expectApproxEqAbs(before_water, state.solid_snow_water_equivalent_m3[0] + state.liquid_water_volume_m3[0] + state.vapor_water_equivalent_m3[0], 1e-16);
    try std.testing.expectApproxEqAbs(expected_latent, latent[0], 1e-15);
    try std.testing.expectApproxEqAbs(expected_latent + frozen_rebasing * expected_solid_change, reference[0], 1e-15);
    try std.testing.expectApproxEqAbs(
        before_capacity * before_temperature + latent[0],
        state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0],
        1e-13,
    );
}

test "invalid later surface equilibrium cell rolls state and diagnostics back atomically" {
    var state = try snow.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{ 0.1, 0.1 }, &.{ 1, 1 }, &.{ 268, 268 }, &.{0.2}, 0.1, snow.test_thermodynamics);
    state.temperature_k[1] = std.math.nan(f64);
    const solid_before = state.solid_snow_water_equivalent_m3[0];
    const temperature_before = state.temperature_k[0];
    var latent = [_]f64{ 17, 17 };
    var reference = [_]f64{ 19, 19 };
    try std.testing.expectError(error.NonFiniteSnowSurfaceState, equilibrateSurface(
        std.testing.allocator,
        &state,
        testParameters(),
        .{
            .donor_availability_fraction = 1,
            .latent_heat_megajoules = &latent,
            .reference_state_heat_megajoules = &reference,
            .cell_area_m2 = &.{ 1, 1 },
            .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12,
            .energy_conservation_relative_tolerance = 1e-10,
        },
    ));
    try std.testing.expectEqual(solid_before, state.solid_snow_water_equivalent_m3[0]);
    try std.testing.expectEqual(temperature_before, state.temperature_k[0]);
    try std.testing.expectEqualSlices(f64, &.{ 17, 17 }, &latent);
    try std.testing.expectEqualSlices(f64, &.{ 19, 19 }, &reference);
}

test "snow surface exchange uses top layer and vapor liquid solid donor order" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{268}, &.{ 0.05, 0.10 }, 0.1, snow.test_thermodynamics);
    state.solid_snow_water_equivalent_m3[0] = 0.05;
    state.vapor_water_equivalent_m3[0] = 0.001;
    state.liquid_water_volume_m3[0] = 0.002;
    state.heat_capacity_megajoules_per_k[0] = 2.095 * state.solid_snow_water_equivalent_m3[0] + 4.19 * 0.003;
    state.vapor_water_equivalent_m3[1] = 0.004;
    state.refreshAllGeometry();
    const lower_before = state.vapor_water_equivalent_m3[1];
    const surface_fraction = try surfaceVaporFraction(&state, 0, testParameters());
    const requested = 0.006;
    const conductance = requested / surface_fraction;
    var outputs = try TestOutputs.init(std.testing.allocator, 1, 0);
    defer outputs.deinit(std.testing.allocator);
    try applyAccepted(std.testing.allocator, &state, testParameters(), outputs.context(1, &.{conductance}, &.{0}, &.{0}, &.{280}, &.{0}));
    try std.testing.expectApproxEqAbs(@as(f64, 0), state.vapor_water_equivalent_m3[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0), state.liquid_water_volume_m3[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.047), state.solid_snow_water_equivalent_m3[0], 1e-14);
    try std.testing.expectApproxEqAbs(requested, outputs.evaporation[0], 1e-14);
    try std.testing.expectApproxEqAbs(lower_before, state.vapor_water_equivalent_m3[1], 0);
    try std.testing.expect(outputs.latent[0] < 0);
    try std.testing.expect(state.temperature_k[0] < 268);
}

test "snow surface atmosphere donor availability is independent of physical integration time" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.05}, &.{1}, &.{268}, &.{0.10}, 0.1, snow.test_thermodynamics);
    state.vapor_water_equivalent_m3[0] = 0.001;
    state.liquid_water_volume_m3[0] = 0.002;
    state.heat_capacity_megajoules_per_k[0] =
        2.095 * state.solid_snow_water_equivalent_m3[0] +
        4.19 * (state.liquid_water_volume_m3[0] + state.vapor_water_equivalent_m3[0]);
    state.refreshAllGeometry();

    const physical_time_step_hours: f64 = 0.5;
    const donor_availability_fraction: f64 = 0.1;
    const requested_m3: f64 = 0.02;
    const vapor_before = state.vapor_water_equivalent_m3[0];
    const liquid_before = state.liquid_water_volume_m3[0];
    const solid_before = state.solid_snow_water_equivalent_m3[0];
    const surface_fraction = try surfaceVaporFraction(&state, 0, testParameters());
    const conductance = requested_m3 /
        (surface_fraction * physical_time_step_hours);
    var outputs = try TestOutputs.init(std.testing.allocator, 1, 0);
    defer outputs.deinit(std.testing.allocator);
    var context = outputs.context(
        physical_time_step_hours,
        &.{conductance},
        &.{0},
        &.{0},
        &.{268},
        &.{0},
    );
    context.donor_availability_fraction = donor_availability_fraction;
    try applyAccepted(std.testing.allocator, &state, testParameters(), context);

    const expected_evaporation = vapor_before +
        donor_availability_fraction * (liquid_before + solid_before);
    try std.testing.expectApproxEqAbs(
        expected_evaporation,
        outputs.evaporation[0],
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        liquid_before * (1 - donor_availability_fraction),
        state.liquid_water_volume_m3[0],
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        solid_before * (1 - donor_availability_fraction),
        state.solid_snow_water_equivalent_m3[0],
        1e-14,
    );
}

test "snow condensation enters vapor and warm air supplies carrier plus sensible heat" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.05}, &.{1}, &.{268}, &.{0.10}, 0.1, snow.test_thermodynamics);
    const vapor_before = state.vapor_water_equivalent_m3[0];
    var outputs = try TestOutputs.init(std.testing.allocator, 1, 0);
    defer outputs.deinit(std.testing.allocator);
    try applyAccepted(std.testing.allocator, &state, testParameters(), outputs.context(1, &.{1}, &.{0.01}, &.{0.002}, &.{278}, &.{0}));
    try std.testing.expect(state.vapor_water_equivalent_m3[0] > vapor_before);
    try std.testing.expectEqual(@as(f64, 0), outputs.evaporation[0]);
    try std.testing.expect(outputs.condensation[0] > 0);
    try std.testing.expectEqual(@as(f64, 0), outputs.latent[0]);
    try std.testing.expect(outputs.carrier[0] > 0);
    try std.testing.expect(outputs.sensible[0] > 0);
    try std.testing.expect(outputs.boundary_heat[0] > 0);
}

test "snow surface zero-air condensation retains a physical carrier and exact exchange heat" {
    const parameters = testParameters();
    for ([_]f64{ 1, 2.75, 0.125 }) |area| {
        for ([_]f64{ 1, 0.25 }) |duration| {
            for ([_]bool{ true, false }) |ice_only| {
                var state = try snow.State.init(std.testing.allocator, 1, 2);
                defer state.deinit();
                const initial_temperature: f64 = if (ice_only) 266.30167274307297 else 278;
                const air_temperature: f64 = 270;
                try state.initializePhysicalState(&.{0}, &.{area}, &.{initial_temperature}, &.{ 0.01, 0.02 }, 0.05, snow.test_thermodynamics);
                state.active[0] = true;
                // Snow initialization caps temperature at melting; this
                // fixture also deliberately exercises a warm liquid surface.
                state.temperature_k[0] = initial_temperature;
                if (ice_only) {
                    state.ice_volume_m3[0] = 5.164933739154166e-4 * area;
                } else {
                    state.liquid_water_volume_m3[0] = 5.164933739154166e-4 * area;
                }
                state.heat_capacity_megajoules_per_k[0] = parameters.ice_heat_capacity_megajoules_per_m3_k * state.ice_volume_m3[0] +
                    parameters.liquid_water_heat_capacity_megajoules_per_m3_k * state.liquid_water_volume_m3[0];
                state.refreshAllGeometry();
                try std.testing.expectEqual(@as(f64, 0), state.air_filled_volume_m3[0]);
                const before_water = layerWaterEquivalentM3(&state, 0, parameters);
                const before_capacity = state.heat_capacity_megajoules_per_k[0];
                const before_liquid = state.liquid_water_volume_m3[0];
                const before_heat = try censusEnthalpyMegajoules(before_capacity, initial_temperature, 0, state.ice_volume_m3[0], parameters);
                const surface_fraction = try equilibriumVaporFraction(initial_temperature, parameters);
                const air_fraction = surface_fraction + 5.2748954152499024e-9;
                const influx = area * (air_fraction - surface_fraction) * duration;
                const expected_carrier_heat = parameters.liquid_water_heat_capacity_megajoules_per_m3_k * influx * air_temperature;
                const expected_latent_heat = parameters.liquid_evaporation_latent_heat_megajoules_per_m3 * influx;
                var outputs = try TestOutputs.init(std.testing.allocator, 1, 0);
                defer outputs.deinit(std.testing.allocator);
                outputs.cell_area_m2[0] = area;
                try applyAccepted(std.testing.allocator, &state, parameters, outputs.context(duration, &.{area}, &.{0}, &.{air_fraction}, &.{air_temperature}, &.{0}));
                try std.testing.expectEqual(@as(f64, 0), state.vapor_water_equivalent_m3[0]);
                try std.testing.expectApproxEqAbs(before_liquid + influx, state.liquid_water_volume_m3[0], 1e-18 * area);
                try std.testing.expectApproxEqAbs(before_water + influx, layerWaterEquivalentM3(&state, 0, parameters), 1e-18 * area);
                try std.testing.expectApproxEqAbs(influx, outputs.condensation[0], 1e-20 * area);
                try std.testing.expectEqual(@as(f64, 0), outputs.evaporation[0]);
                try std.testing.expectApproxEqAbs(expected_latent_heat, outputs.latent[0], 1e-18 * area);
                try std.testing.expectApproxEqAbs(expected_carrier_heat, outputs.carrier[0], 1e-18 * area);
                try std.testing.expectApproxEqAbs(expected_carrier_heat + expected_latent_heat, outputs.boundary_heat[0], 1e-18 * area);
                const expected_temperature = (before_capacity * initial_temperature + expected_carrier_heat + expected_latent_heat) /
                    (before_capacity + parameters.liquid_water_heat_capacity_megajoules_per_m3_k * influx);
                try std.testing.expectApproxEqAbs(expected_temperature, state.temperature_k[0], 1e-12);
                const after_heat = try censusEnthalpyMegajoules(state.heat_capacity_megajoules_per_k[0], state.temperature_k[0], 0, state.ice_volume_m3[0], parameters);
                try std.testing.expectApproxEqAbs(before_heat + expected_carrier_heat + expected_latent_heat, after_heat, 1e-15 * area);
                const diffusion = @import("snow_vapor_diffusion.zig");
                const report = try diffusion.solve(std.testing.allocator, &state, .{
                    .reference_vapor_diffusivity_m2_per_h = 0.0896,
                    .reference_temperature_k = 298.15,
                    .temperature_exponent = 1.75,
                    .minimum_air_fraction = 0,
                    .vapor_sensible_heat_capacity_megajoules_per_m3_k = 4.19,
                }, .{ .physical_time_step_hours = duration, .donor_availability_fraction = 1, .full_snow_cover_depth_m = 0.07, .thermodynamics = snow.test_thermodynamics });
                try std.testing.expect(report.converged);
                try std.testing.expectEqual(@as(f64, 0), report.maximum_interface_flux_m3);
                const phase = @import("snow_phase_change.zig");
                var phase_report = try phase.solve(std.testing.allocator, &state, .{
                    .physical_rate_time_step_hours = duration,
                    .ice_density_megagrams_per_m3 = parameters.ice_density_megagrams_per_m3,
                    .latent_heat_of_fusion_megajoules_per_m3 = parameters.latent_heat_of_fusion_megajoules_per_m3,
                    .solid_snow_heat_capacity_megajoules_per_m3_k = solid_snow_heat_capacity_megajoules_per_m3_k,
                    .liquid_water_heat_capacity_megajoules_per_m3_k = parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                    .ice_heat_capacity_megajoules_per_m3_k = parameters.ice_heat_capacity_megajoules_per_m3_k,
                    .pure_water_melting_temperature_k = parameters.pure_water_melting_temperature_k,
                    .damping_divisor = 2.7185,
                    .absolute_temperature_tolerance_k = 1e-10,
                    .relative_tolerance = 1e-10,
                    .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12,
                    .energy_conservation_relative_tolerance = 1e-10,
                    .picard_relaxation = 1,
                    .max_iterations = 20,
                    .local_layer_index = 0,
                });
                defer phase_report.deinit(std.testing.allocator);
                try std.testing.expect(phase_report.converged);
                if (ice_only) try std.testing.expectEqual(@as(f64, 0), state.liquid_water_volume_m3[0]);
                try std.testing.expectEqual(@as(f64, 0), state.vapor_water_equivalent_m3[0]);
                try std.testing.expectApproxEqAbs(before_water + influx, layerWaterEquivalentM3(&state, 0, parameters), 1e-18 * area);
                const phase_heat = try censusEnthalpyMegajoules(state.heat_capacity_megajoules_per_k[0], state.temperature_k[0], 0, state.ice_volume_m3[0], parameters);
                try std.testing.expectApproxEqAbs(after_heat, phase_heat, 1e-15 * area);
            }
        }
    }
}

test "snow surface zero-air condensation rejects invalid later cell atomically" {
    var state = try snow.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{ 0, 0 }, &.{ 2, 3 }, &.{ 266, 267 }, &.{0.01}, 0.05, snow.test_thermodynamics);
    for (0..2) |index| {
        state.active[index] = true;
        state.ice_volume_m3[index] = 5e-4 * state.horizontal_area_m2[index];
        state.heat_capacity_megajoules_per_k[index] = testParameters().ice_heat_capacity_megajoules_per_m3_k * state.ice_volume_m3[index];
    }
    state.refreshAllGeometry();
    var before = try @import("snow_source_order_energy.zig").cloneState(std.testing.allocator, &state);
    defer before.deinit();
    var outputs = try TestOutputs.init(std.testing.allocator, 2, 17);
    defer outputs.deinit(std.testing.allocator);
    @memcpy(outputs.cell_area_m2, state.horizontal_area_m2);
    try std.testing.expectError(error.NonFiniteSnowSurfaceExchangeInput, applyAccepted(
        std.testing.allocator,
        &state,
        testParameters(),
        outputs.context(1, &.{ 1, 1 }, &.{ 0, 0 }, &.{ 1e-3, std.math.nan(f64) }, &.{ 270, 270 }, &.{ 0, 0 }),
    ));
    inline for (.{ "solid_snow_water_equivalent_m3", "liquid_water_volume_m3", "vapor_water_equivalent_m3", "ice_volume_m3", "air_filled_volume_m3", "total_layer_volume_m3", "layer_thickness_m", "cumulative_depth_m", "temperature_k", "heat_capacity_megajoules_per_k", "amount_g", "salt_amount_mol" }) |field|
        try std.testing.expectEqualSlices(f64, @field(before, field), @field(state, field));
    try std.testing.expectEqualSlices(bool, before.active, state.active);
    inline for (.{ "evaporation", "condensation", "boundary_heat", "latent", "carrier", "sensible", "radiation" }) |field|
        try std.testing.expectEqualSlices(f64, &.{ 17, 17 }, @field(outputs, field));
}

test "snow surface sensible exchange uses a conservative bounded implicit endpoint" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    const capacity: f64 = 1.0e-3;
    const initial_temperature: f64 = 270;
    const air_temperature: f64 = 240;
    try state.initializePhysicalState(
        &.{capacity / solid_snow_heat_capacity_megajoules_per_m3_k},
        &.{1},
        &.{initial_temperature},
        &.{0.001},
        0.1,
        snow.test_thermodynamics,
    );
    state.solid_snow_water_equivalent_m3[0] =
        capacity / solid_snow_heat_capacity_megajoules_per_m3_k;
    state.liquid_water_volume_m3[0] = 0;
    state.vapor_water_equivalent_m3[0] = 0;
    state.ice_volume_m3[0] = 0;
    state.heat_capacity_megajoules_per_k[0] = capacity;
    state.active[0] = true;
    state.refreshAllGeometry();
    try std.testing.expect(
        capacity > snow.activation_heat_capacity_megajoules_per_m2_k,
    );

    const interval_conductance: f64 = 1.0e-2;
    const explicit_temperature = initial_temperature +
        interval_conductance * (air_temperature - initial_temperature) /
            capacity;
    try std.testing.expect(explicit_temperature < 173.15);
    var outputs = try TestOutputs.init(std.testing.allocator, 1, 0);
    defer outputs.deinit(std.testing.allocator);
    var context = outputs.context(
        1,
        &.{0},
        &.{interval_conductance},
        &.{0},
        &.{air_temperature},
        &.{0},
    );
    context.minimum_temperature_k = 173.15;
    context.maximum_temperature_k = 373.15;
    try applyAccepted(
        std.testing.allocator,
        &state,
        testParameters(),
        context,
    );

    const expected_temperature =
        (capacity * initial_temperature +
            interval_conductance * air_temperature) /
        (capacity + interval_conductance);
    try std.testing.expectApproxEqRel(
        expected_temperature,
        state.temperature_k[0],
        16 * std.math.floatEps(f64),
    );
    try std.testing.expect(state.temperature_k[0] > air_temperature);
    try std.testing.expect(state.temperature_k[0] < initial_temperature);
    try std.testing.expect(outputs.sensible[0] < 0);
    try std.testing.expectApproxEqAbs(
        capacity * (state.temperature_k[0] - initial_temperature),
        outputs.sensible[0],
        16 * std.math.floatEps(f64),
    );
    try std.testing.expectApproxEqAbs(
        outputs.sensible[0],
        outputs.boundary_heat[0],
        16 * std.math.floatEps(f64),
    );
}

test "snow surface exchange rejects a finite endpoint outside the physical temperature domain" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.05}, &.{1}, &.{268}, &.{0.10}, 0.1, snow.test_thermodynamics);
    const temperature_before = state.temperature_k[0];
    const solid_before = state.solid_snow_water_equivalent_m3[0];
    var outputs = try TestOutputs.init(std.testing.allocator, 1, 17);
    defer outputs.deinit(std.testing.allocator);
    var context = outputs.context(1, &.{0}, &.{0}, &.{0}, &.{268}, &.{100});
    context.maximum_temperature_k = 300;

    try std.testing.expectError(
        error.InvalidSnowSurfaceExchangeTemperature,
        applyAccepted(std.testing.allocator, &state, testParameters(), context),
    );
    try std.testing.expectEqual(temperature_before, state.temperature_k[0]);
    try std.testing.expectEqual(solid_before, state.solid_snow_water_equivalent_m3[0]);
    try std.testing.expectEqualSlices(f64, &.{17}, outputs.boundary_heat);
}

test "snow surface source falls back only when snow is absent" {
    var state = try snow.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{ 0.05, 0 }, &.{ 1, 1 }, &.{ 268, 270 }, &.{0.10}, 0.1, snow.test_thermodynamics);
    state.vapor_water_equivalent_m3[0] = 0.001;
    state.refreshAllGeometry();
    var vapor = [_]f64{ 9, 9 };
    var temperature = [_]f64{ 9, 9 };
    try prepareSurfaceSources(&state, testParameters(), .{
        .fallback_temperature_k = &.{ 280, 281 },
        .vapor_fraction = &vapor,
        .temperature_k = &temperature,
    });
    try std.testing.expect(vapor[0] > 0);
    try std.testing.expectEqual(@as(f64, 268), temperature[0]);
    try std.testing.expectEqual(@as(f64, 0), vapor[1]);
    try std.testing.expectEqual(@as(f64, 281), temperature[1]);
}

test "snow surface atmosphere skips canonical snow below strict VHCPWX activation" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(
        &.{0.0001},
        &.{1},
        &.{260},
        &.{0.001},
        0.1,
        snow.test_thermodynamics,
    );
    state.active[0] = true;
    state.solid_snow_water_equivalent_m3[0] = 0.0001;
    state.liquid_water_volume_m3[0] = 0;
    state.vapor_water_equivalent_m3[0] = 0;
    state.ice_volume_m3[0] = 0;
    state.heat_capacity_megajoules_per_k[0] =
        solid_snow_heat_capacity_megajoules_per_m3_k *
        state.solid_snow_water_equivalent_m3[0];
    state.refreshAllGeometry();
    try std.testing.expect(
        state.heat_capacity_megajoules_per_k[0] <
            snow.activation_heat_capacity_megajoules_per_m2_k *
                state.horizontal_area_m2[0],
    );

    const solid_before = state.solid_snow_water_equivalent_m3[0];
    const temperature_before = state.temperature_k[0];
    var equilibrium_latent = [_]f64{17};
    var equilibrium_reference = [_]f64{19};
    try equilibrateSurface(
        std.testing.allocator,
        &state,
        testParameters(),
        .{
            .donor_availability_fraction = 1,
            .latent_heat_megajoules = &equilibrium_latent,
            .reference_state_heat_megajoules = &equilibrium_reference,
            .cell_area_m2 = &.{1},
            .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12,
            .energy_conservation_relative_tolerance = 1e-10,
        },
    );
    try std.testing.expectEqualSlices(f64, &.{0}, &equilibrium_latent);
    try std.testing.expectEqualSlices(f64, &.{0}, &equilibrium_reference);

    var source_vapor = [_]f64{17};
    var source_temperature = [_]f64{19};
    try prepareSurfaceSources(&state, testParameters(), .{
        .fallback_temperature_k = &.{280},
        .vapor_fraction = &source_vapor,
        .temperature_k = &source_temperature,
    });
    try std.testing.expectEqualSlices(f64, &.{0}, &source_vapor);
    try std.testing.expectEqualSlices(f64, &.{280}, &source_temperature);

    var outputs = try TestOutputs.init(std.testing.allocator, 1, 23);
    defer outputs.deinit(std.testing.allocator);
    try applyAccepted(
        std.testing.allocator,
        &state,
        testParameters(),
        outputs.context(1, &.{1}, &.{1}, &.{1}, &.{373}, &.{100}),
    );
    inline for (.{
        outputs.evaporation,
        outputs.condensation,
        outputs.boundary_heat,
        outputs.latent,
        outputs.carrier,
        outputs.sensible,
        outputs.radiation,
    }) |values| try std.testing.expectEqualSlices(f64, &.{0}, values);
    try std.testing.expectEqual(solid_before, state.solid_snow_water_equivalent_m3[0]);
    try std.testing.expectEqual(temperature_before, state.temperature_k[0]);
}

test "snow surface radiation uses live phase albedo and covered area" {
    const dry_inputs: RadiationInputs = .{
        .snow_cover_fraction = 0.5,
        .cell_area_m2 = 10,
        .incident_shortwave_megajoules_per_m2_h = 2,
        .atmospheric_longwave_megajoules_per_m2_h = 1,
        .ground_exposure_fraction = 0.8,
        .snow_longwave_emissivity = 0.97,
        .stefan_boltzmann_megajoules_per_m2_h_k4 = 2.04e-10,
        .snow_temperature_k = 268,
        .solid_snow_water_equivalent_m3 = 1,
        .liquid_water_m3 = 0,
        .ice_volume_m3 = 0,
    };
    const cold_dry = try calculateNetRadiation(dry_inputs);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), cold_dry.absorbed_shortwave_megajoules_per_h, 1e-14);
    var half_sky_exposure_inputs = dry_inputs;
    half_sky_exposure_inputs.ground_exposure_fraction = 0.4;
    const half_sky_exposure = try calculateNetRadiation(half_sky_exposure_inputs);
    try std.testing.expectEqual(cold_dry.absorbed_shortwave_megajoules_per_h, half_sky_exposure.absorbed_shortwave_megajoules_per_h);
    try std.testing.expectApproxEqRel(cold_dry.net_longwave_megajoules_per_h * 0.5, half_sky_exposure.net_longwave_megajoules_per_h, 64 * std.math.floatEps(f64));
    const wet = try calculateNetRadiation(.{
        .snow_cover_fraction = 0.5,
        .cell_area_m2 = 10,
        .incident_shortwave_megajoules_per_m2_h = 2,
        .atmospheric_longwave_megajoules_per_m2_h = 1,
        .ground_exposure_fraction = 0.8,
        .snow_longwave_emissivity = 0.97,
        .stefan_boltzmann_megajoules_per_m2_h_k4 = 2.04e-10,
        .snow_temperature_k = 268,
        .solid_snow_water_equivalent_m3 = 0,
        .liquid_water_m3 = 1,
        .ice_volume_m3 = 0,
    });
    try std.testing.expect(wet.absorbed_shortwave_megajoules_per_h > cold_dry.absorbed_shortwave_megajoules_per_h);
    try std.testing.expectApproxEqAbs(cold_dry.absorbed_shortwave_megajoules_per_h + cold_dry.net_longwave_megajoules_per_h, cold_dry.net_radiation_megajoules_per_h, 1e-14);
}

test "WATSUB snow radiation sums living and dead canopy longwave once with source signs and units" {
    const sigma: f64 = 2.04e-10;
    const emissivity: f64 = 0.97;
    const area_m2: f64 = 12;
    const cover: f64 = 0.6;
    const snow_temperature_k: f64 = 270;
    const living_temperature_k = [_]f64{ 285, 280 };
    const dead_temperature_k = [_]f64{ 278, 275 };
    const living_fraction = [_]f64{ 0.20, 0.10 };
    const dead_fraction = [_]f64{ 0.08, 0.07 };
    const inputs: RadiationInputs = .{
        .snow_cover_fraction = cover,
        .cell_area_m2 = area_m2,
        .incident_shortwave_megajoules_per_m2_h = 1.5,
        .atmospheric_longwave_megajoules_per_m2_h = 0.9,
        .ground_exposure_fraction = 0.55,
        .snow_longwave_emissivity = emissivity,
        .stefan_boltzmann_megajoules_per_m2_h_k4 = sigma,
        .snow_temperature_k = snow_temperature_k,
        .solid_snow_water_equivalent_m3 = 1,
        .liquid_water_m3 = 0,
        .ice_volume_m3 = 0,
        .living_canopy_temperature_k = &living_temperature_k,
        .standing_dead_temperature_k = &dead_temperature_k,
        .living_canopy_radiation_fraction = &living_fraction,
        .standing_dead_radiation_fraction = &dead_fraction,
    };
    const radiation = try calculateNetRadiation(inputs);
    const snow_area_m2 = area_m2 * cover;
    const snow_fourth = std.math.pow(f64, snow_temperature_k, 4);
    const coefficient = emissivity * sigma * snow_area_m2;
    var expected_canopy: f64 = 0;
    for (0..living_temperature_k.len) |plant| {
        expected_canopy += coefficient *
            (std.math.pow(f64, living_temperature_k[plant], 4) - snow_fourth) *
            living_fraction[plant];
        expected_canopy += coefficient *
            (std.math.pow(f64, dead_temperature_k[plant], 4) - snow_fourth) *
            dead_fraction[plant];
    }
    const expected_sky = (inputs.atmospheric_longwave_megajoules_per_m2_h -
        emissivity * sigma * snow_fourth) * snow_area_m2 * inputs.ground_exposure_fraction;
    try std.testing.expect(expected_canopy > 0);
    try std.testing.expectApproxEqRel(expected_canopy, radiation.canopy_longwave_megajoules_per_h, 64 * std.math.floatEps(f64));
    try std.testing.expectApproxEqRel(expected_sky, radiation.sky_net_longwave_megajoules_per_h, 64 * std.math.floatEps(f64));
    try std.testing.expectApproxEqRel(
        expected_sky + expected_canopy,
        radiation.net_longwave_megajoules_per_h,
        64 * std.math.floatEps(f64),
    );
    try std.testing.expectApproxEqRel(
        radiation.absorbed_shortwave_megajoules_per_h + expected_sky + expected_canopy,
        radiation.net_radiation_megajoules_per_h,
        64 * std.math.floatEps(f64),
    );

    var cold_inputs = inputs;
    cold_inputs.living_canopy_temperature_k = &.{ 255, 260 };
    cold_inputs.standing_dead_temperature_k = &.{ 262, 265 };
    try std.testing.expect((try calculateNetRadiation(cold_inputs)).canopy_longwave_megajoules_per_h < 0);
}

test "WATSUB snow radiation accepts zero-temperature absent populations but rejects active zero temperatures" {
    const absent: RadiationInputs = .{
        .snow_cover_fraction = 1,
        .cell_area_m2 = 1,
        .incident_shortwave_megajoules_per_m2_h = 0,
        .atmospheric_longwave_megajoules_per_m2_h = 0,
        .ground_exposure_fraction = 0,
        .snow_longwave_emissivity = 0.97,
        .stefan_boltzmann_megajoules_per_m2_h_k4 = 2.04e-10,
        .snow_temperature_k = 270,
        .solid_snow_water_equivalent_m3 = 1,
        .liquid_water_m3 = 0,
        .ice_volume_m3 = 0,
        .living_canopy_temperature_k = &.{0},
        .standing_dead_temperature_k = &.{0},
        .living_canopy_radiation_fraction = &.{0},
        .standing_dead_radiation_fraction = &.{0},
    };
    const radiation = try calculateNetRadiation(absent);
    try std.testing.expectEqual(@as(f64, 0), radiation.canopy_longwave_megajoules_per_h);

    var active_living_zero = absent;
    active_living_zero.living_canopy_radiation_fraction = &.{0.1};
    try std.testing.expectError(
        error.InvalidSnowSurfaceRadiationInput,
        calculateNetRadiation(active_living_zero),
    );

    var active_dead_zero = absent;
    active_dead_zero.standing_dead_radiation_fraction = &.{0.1};
    try std.testing.expectError(
        error.InvalidSnowSurfaceRadiationInput,
        calculateNetRadiation(active_dead_zero),
    );

    var negative_inactive = absent;
    negative_inactive.living_canopy_temperature_k = &.{-1};
    try std.testing.expectError(
        error.InvalidSnowSurfaceRadiationInput,
        calculateNetRadiation(negative_inactive),
    );
}

test "accepted canopy longwave is published once to snow boundary heat and closes sensible storage" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{270}, &.{0.2}, 0.1, snow.test_thermodynamics);
    const initial_sensible_heat = state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0];
    const radiation = try calculateNetRadiation(.{
        .snow_cover_fraction = 1,
        .cell_area_m2 = 1,
        .incident_shortwave_megajoules_per_m2_h = 0,
        .atmospheric_longwave_megajoules_per_m2_h = 0,
        .ground_exposure_fraction = 0,
        .snow_longwave_emissivity = 0.97,
        .stefan_boltzmann_megajoules_per_m2_h_k4 = 2.04e-10,
        .snow_temperature_k = 270,
        .solid_snow_water_equivalent_m3 = state.solid_snow_water_equivalent_m3[0],
        .liquid_water_m3 = 0,
        .ice_volume_m3 = 0,
        .living_canopy_temperature_k = &.{280},
        .standing_dead_temperature_k = &.{275},
        .living_canopy_radiation_fraction = &.{0.3},
        .standing_dead_radiation_fraction = &.{0.2},
    });
    const timestep_h: f64 = 0.25;
    var outputs = try TestOutputs.init(std.testing.allocator, 1, 0);
    defer outputs.deinit(std.testing.allocator);
    try applyAccepted(
        std.testing.allocator,
        &state,
        testParameters(),
        outputs.context(
            timestep_h,
            &.{0},
            &.{0},
            &.{0},
            &.{270},
            &.{radiation.net_radiation_megajoules_per_h},
        ),
    );
    const accepted_radiation = radiation.net_radiation_megajoules_per_h * timestep_h;
    const final_sensible_heat = state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0];
    try std.testing.expect(accepted_radiation > 0);
    try std.testing.expectApproxEqRel(accepted_radiation, outputs.radiation[0], 64 * std.math.floatEps(f64));
    try std.testing.expectApproxEqRel(accepted_radiation, outputs.boundary_heat[0], 64 * std.math.floatEps(f64));
    try std.testing.expectApproxEqRel(accepted_radiation, final_sensible_heat - initial_sensible_heat, 128 * std.math.floatEps(f64));
}

test "invalid later cell leaves all snow and diagnostics unchanged" {
    var state = try snow.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{ 0.05, 0.05 }, &.{ 1, 1 }, &.{ 268, 268 }, &.{0.10}, 0.1, snow.test_thermodynamics);
    const solid_before = state.solid_snow_water_equivalent_m3[0];
    const temperature_before = state.temperature_k[0];
    var outputs = try TestOutputs.init(std.testing.allocator, 2, 17);
    defer outputs.deinit(std.testing.allocator);
    try std.testing.expectError(error.NonFiniteSnowSurfaceExchangeInput, applyAccepted(
        std.testing.allocator,
        &state,
        testParameters(),
        outputs.context(1, &.{ 0.1, 0.1 }, &.{ 0, 0 }, &.{ 0, std.math.nan(f64) }, &.{ 280, 280 }, &.{ 0, 0 }),
    ));
    try std.testing.expectEqual(solid_before, state.solid_snow_water_equivalent_m3[0]);
    try std.testing.expectEqual(temperature_before, state.temperature_k[0]);
    try std.testing.expectEqualSlices(f64, &.{ 17, 17 }, outputs.evaporation);
    try std.testing.expectEqualSlices(f64, &.{ 17, 17 }, outputs.boundary_heat);
}

test "complete sublimation deactivates a snow surface without touching lower storage" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.05}, &.{1}, &.{268}, &.{ 0.05, 0.10 }, 0.1, snow.test_thermodynamics);
    state.solid_snow_water_equivalent_m3[1] = 0;
    state.heat_capacity_megajoules_per_k[1] = 0;
    state.active[1] = false;
    state.vapor_water_equivalent_m3[0] = 0.001;
    state.heat_capacity_megajoules_per_k[0] +=
        testParameters().liquid_water_heat_capacity_megajoules_per_m3_k * 0.001;
    state.refreshAllGeometry();
    const surface_fraction = try surfaceVaporFraction(&state, 0, testParameters());
    const solid_before = state.solid_snow_water_equivalent_m3[0];
    const lower_before = state.solid_snow_water_equivalent_m3[1];
    const conductance = solid_before / surface_fraction * 2;
    var outputs = try TestOutputs.init(std.testing.allocator, 1, 0);
    defer outputs.deinit(std.testing.allocator);
    // Removing the final carrier without supplying its sublimation energy is
    // an impossible state, not a license to discard negative sensible energy.
    try std.testing.expectError(
        error.SnowSurfaceExchangeEnergyConservationFailure,
        applyAccepted(std.testing.allocator, &state, testParameters(), outputs.context(1, &.{conductance}, &.{0}, &.{0}, &.{280}, &.{0})),
    );
    try std.testing.expectEqual(solid_before, state.solid_snow_water_equivalent_m3[0]);
    const sublimation_energy = testParameters().snow_sublimation_latent_heat_megajoules_per_m3 * solid_before;
    try applyAccepted(std.testing.allocator, &state, testParameters(), outputs.context(1, &.{conductance}, &.{0}, &.{0}, &.{280}, &.{sublimation_energy}));
    try std.testing.expectApproxEqAbs(@as(f64, 0), state.solid_snow_water_equivalent_m3[0], 1e-15);
    try std.testing.expect(!state.active[0]);
    try std.testing.expectEqual(@as(f64, 0), state.heat_capacity_megajoules_per_k[0]);
    try std.testing.expectApproxEqAbs(outputs.evaporation[0], 0.006, 1e-14);
    try std.testing.expectEqual(lower_before, state.solid_snow_water_equivalent_m3[1]);
    try std.testing.expectApproxEqAbs(sublimation_energy, outputs.radiation[0], 1e-14);
}

test "freeze then sublimation closes snow water and landscape enthalpy" {
    const snow_phase = @import("snow_phase_change.zig");
    const inventory = @import("../../validation/landscape_mass_inventory.zig");
    const ice_density = 0.92;
    const parameters = testParameters();
    const molar_mass_g_per_mol: inventory.SnowMolarMassesGPerMol = .{
        .nitrogen = 14,
        .phosphorus = 31,
        .ions = .{ .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 },
    };

    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{270}, &.{0.2}, 0.05, snow.test_thermodynamics);
    state.liquid_water_volume_m3[0] = 0.002;
    state.heat_capacity_megajoules_per_k[0] +=
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k * 0.002;
    const water_before_phase = state.solid_snow_water_equivalent_m3[0] +
        state.liquid_water_volume_m3[0] + state.vapor_water_equivalent_m3[0] +
        state.ice_volume_m3[0] * ice_density;
    var phase_report = try snow_phase.solve(std.testing.allocator, &state, .{
        .ice_density_megagrams_per_m3 = ice_density,
        .latent_heat_of_fusion_megajoules_per_m3 = parameters.latent_heat_of_fusion_megajoules_per_m3,
        .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095,
        .liquid_water_heat_capacity_megajoules_per_m3_k = parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
        .ice_heat_capacity_megajoules_per_m3_k = parameters.ice_heat_capacity_megajoules_per_m3_k,
        .pure_water_melting_temperature_k = parameters.pure_water_melting_temperature_k,
        .damping_divisor = 2.7185,
        .absolute_temperature_tolerance_k = 1e-8,
        .relative_tolerance = 1e-8,
        .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12,
        .energy_conservation_relative_tolerance = 1e-10,
        .picard_relaxation = 1,
        .max_iterations = 20,
    });
    defer phase_report.deinit(std.testing.allocator);
    try std.testing.expect(phase_report.converged);
    try std.testing.expect(state.ice_volume_m3[0] > 0);
    const water_after_phase = state.solid_snow_water_equivalent_m3[0] +
        state.liquid_water_volume_m3[0] + state.vapor_water_equivalent_m3[0] +
        state.ice_volume_m3[0] * ice_density;
    try std.testing.expectApproxEqRel(water_before_phase, water_after_phase, 64 * std.math.floatEps(f64));

    const before = try inventory.aggregateSnowEnthalpy(
        &state,
        ice_density,
        parameters.latent_heat_of_fusion_megajoules_per_m3,
        solid_snow_heat_capacity_megajoules_per_m3_k,
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
        parameters.ice_heat_capacity_megajoules_per_m3_k,
        parameters.pure_water_melting_temperature_k,
        molar_mass_g_per_mol,
    );
    var equilibrium_latent = [_]f64{0};
    var equilibrium_reference = [_]f64{0};
    try equilibrateSurface(std.testing.allocator, &state, parameters, .{
        .donor_availability_fraction = 1,
        .latent_heat_megajoules = &equilibrium_latent,
        .reference_state_heat_megajoules = &equilibrium_reference,
        .cell_area_m2 = &.{1},
        .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12,
        .energy_conservation_relative_tolerance = 1e-10,
    });
    const surface_fraction = try surfaceVaporFraction(&state, 0, parameters);
    const requested_evaporation_m3 = 0.001;
    var outputs = try TestOutputs.init(std.testing.allocator, 1, 0);
    defer outputs.deinit(std.testing.allocator);
    try applyAccepted(
        std.testing.allocator,
        &state,
        parameters,
        outputs.context(
            1,
            &.{requested_evaporation_m3 / surface_fraction},
            &.{0},
            &.{0},
            &.{280},
            &.{0},
        ),
    );
    const after = try inventory.aggregateSnowEnthalpy(
        &state,
        ice_density,
        parameters.latent_heat_of_fusion_megajoules_per_m3,
        solid_snow_heat_capacity_megajoules_per_m3_k,
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
        parameters.ice_heat_capacity_megajoules_per_m3_k,
        parameters.pure_water_melting_temperature_k,
        molar_mass_g_per_mol,
    );
    try std.testing.expectApproxEqRel(
        before.water_m3 - outputs.evaporation[0] + outputs.condensation[0],
        after.water_m3,
        128 * std.math.floatEps(f64),
    );
    try std.testing.expectApproxEqRel(
        equilibrium_reference[0] + outputs.boundary_heat[0],
        after.heat_megajoules - before.heat_megajoules,
        128 * std.math.floatEps(f64),
    );
}
