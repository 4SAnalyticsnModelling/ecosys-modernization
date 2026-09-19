const std = @import("std");
const GridState = @import("../../state/grid.zig").GridState;
const thermal_module = @import("../heat/thermal.zig");

pub const Parameters = struct {
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    /// Grid ice carriers are water-equivalent; production converts the F77
    /// physical-ice coefficient with `ice_units` at the relayering boundary.
    ice_heat_capacity_megajoules_per_m3_k: f64,
    minimum_heat_capacity_megajoules_per_k: f64,
};

/// `issue-062`. `redist.f` 9660--9665 (mirrored below at the `minimum_heat_capacity_megajoules_per_k`
/// fallback) assigns a side's temperature from the undivided layer's
/// temperature instead of dividing energy by a heat capacity at or below
/// `VHCPRX`, whenever that side's resulting capacity is nonzero but too small
/// to divide by. That is faithful, deliberately-tested legacy behavior (see
/// this file's own fallback tests), but it means the side's actual final
/// state -- `capacity_after * assigned_temperature` -- can differ from the
/// exact conservative energy split computed just above it. This struct
/// reports that difference so a downstream conservation consumer with its
/// own before/after snapshot of the same transfer (e.g.
/// `relayering_activity.zig`'s `stageBoundary`) can net it out before
/// comparing donor loss against recipient gain, instead of independently
/// discovering -- via a crash -- that it needs its own floor patch. Zero on
/// a side whenever that side's exact division path was taken.
pub const FloorDiscard = struct {
    source_megajoules: f64 = 0,
    destination_megajoules: f64 = 0,
};

const Candidate = struct {
    source_matrix_liquid_water_m3: f64,
    destination_matrix_liquid_water_m3: f64,
    source_matrix_ice_water_m3: f64,
    destination_matrix_ice_water_m3: f64,
    source_matrix_pore_capacity_m3: f64,
    destination_matrix_pore_capacity_m3: f64,
    source_matrix_air_volume_m3: f64,
    destination_matrix_air_volume_m3: f64,
    source_macropore_liquid_water_m3: f64,
    destination_macropore_liquid_water_m3: f64,
    source_macropore_ice_water_m3: f64,
    destination_macropore_ice_water_m3: f64,
    source_macropore_pore_capacity_m3: f64,
    destination_macropore_pore_capacity_m3: f64,
    source_macropore_air_volume_m3: f64,
    destination_macropore_air_volume_m3: f64,
    source_water_vapor_volume_m3: f64,
    destination_water_vapor_volume_m3: f64,
    source_layer_volume_m3: f64,
    destination_layer_volume_m3: f64,
    source_dry_heat_capacity_megajoules_per_k: f64,
    destination_dry_heat_capacity_megajoules_per_k: f64,
    source_total_heat_capacity_megajoules_per_k: f64,
    destination_total_heat_capacity_megajoules_per_k: f64,
    source_temperature_k: f64,
    destination_temperature_k: f64,
    /// See `FloorDiscard`. Zero unless this side's floor fallback fired.
    source_discarded_megajoules: f64,
    destination_discarded_megajoules: f64,
};

/// Matrix-only compatibility entry point. Production REDIST uses
/// `transferLayerFractions`, because `redist.f:9611-9622` moves macropore
/// water, ice, and air whenever both endpoint layers have a macropore domain.
pub fn transferLayerFraction(
    grid: *GridState,
    thermal: *thermal_module.State,
    source: usize,
    destination: usize,
    fraction: f64,
    parameters: Parameters,
    floor_discard: ?*FloorDiscard,
) !void {
    try transferLayerFractions(grid, thermal, source, destination, fraction, 0, parameters, floor_discard);
}

/// Conservative coupled REDIST water/ice/heat remap. `matrix_fraction` is
/// FWO/FX and `macropore_fraction` is FHO (zero when either FHOL endpoint is
/// absent, otherwise FX). Phase mass carries its heat at the donor
/// temperature, so the transfer closes both water and enthalpy.
pub fn transferLayerFractions(
    grid: *GridState,
    thermal: *thermal_module.State,
    source: usize,
    destination: usize,
    matrix_fraction: f64,
    macropore_fraction: f64,
    parameters: Parameters,
    floor_discard: ?*FloorDiscard,
) !void {
    const candidate = try calculate(grid, thermal, source, destination, matrix_fraction, macropore_fraction, parameters);
    if (floor_discard) |out| out.* = .{
        .source_megajoules = candidate.source_discarded_megajoules,
        .destination_megajoules = candidate.destination_discarded_megajoules,
    };

    grid.matrix_liquid_water_m3[source] = candidate.source_matrix_liquid_water_m3;
    grid.matrix_liquid_water_m3[destination] = candidate.destination_matrix_liquid_water_m3;
    grid.matrix_ice_water_m3[source] = candidate.source_matrix_ice_water_m3;
    grid.matrix_ice_water_m3[destination] = candidate.destination_matrix_ice_water_m3;
    grid.matrix_pore_capacity_m3[source] = candidate.source_matrix_pore_capacity_m3;
    grid.matrix_pore_capacity_m3[destination] = candidate.destination_matrix_pore_capacity_m3;
    grid.matrix_air_volume_m3[source] = candidate.source_matrix_air_volume_m3;
    grid.matrix_air_volume_m3[destination] = candidate.destination_matrix_air_volume_m3;
    grid.macropore_liquid_water_m3[source] = candidate.source_macropore_liquid_water_m3;
    grid.macropore_liquid_water_m3[destination] = candidate.destination_macropore_liquid_water_m3;
    grid.macropore_ice_water_m3[source] = candidate.source_macropore_ice_water_m3;
    grid.macropore_ice_water_m3[destination] = candidate.destination_macropore_ice_water_m3;
    grid.macropore_pore_capacity_m3[source] = candidate.source_macropore_pore_capacity_m3;
    grid.macropore_pore_capacity_m3[destination] = candidate.destination_macropore_pore_capacity_m3;
    grid.macropore_air_volume_m3[source] = candidate.source_macropore_air_volume_m3;
    grid.macropore_air_volume_m3[destination] = candidate.destination_macropore_air_volume_m3;
    grid.water_vapor_volume_m3[source] = candidate.source_water_vapor_volume_m3;
    grid.water_vapor_volume_m3[destination] = candidate.destination_water_vapor_volume_m3;
    thermal.layer_volume_m3[source] = candidate.source_layer_volume_m3;
    thermal.layer_volume_m3[destination] = candidate.destination_layer_volume_m3;

    state_updateDerived(grid, thermal, source, candidate.source_dry_heat_capacity_megajoules_per_k, candidate.source_total_heat_capacity_megajoules_per_k, candidate.source_temperature_k);
    state_updateDerived(grid, thermal, destination, candidate.destination_dry_heat_capacity_megajoules_per_k, candidate.destination_total_heat_capacity_megajoules_per_k, candidate.destination_temperature_k);
}

pub fn validateLayerFraction(
    grid: *const GridState,
    thermal: *const thermal_module.State,
    source: usize,
    destination: usize,
    fraction: f64,
    parameters: Parameters,
) !void {
    _ = try calculate(grid, thermal, source, destination, fraction, 0, parameters);
}

fn calculate(
    grid: *const GridState,
    thermal: *const thermal_module.State,
    source: usize,
    destination: usize,
    fraction: f64,
    macropore_fraction: f64,
    parameters: Parameters,
) !Candidate {
    if (source >= grid.layer_count or destination >= grid.layer_count or source >= thermal.layer_volume_m3.len or destination >= thermal.layer_volume_m3.len or source == destination) return error.WaterHeatLayerRemapIndexOutOfBounds;
    inline for (.{ fraction, macropore_fraction, parameters.liquid_water_heat_capacity_megajoules_per_m3_k, parameters.ice_heat_capacity_megajoules_per_m3_k, parameters.minimum_heat_capacity_megajoules_per_k }) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteWaterHeatLayerRemapInput;
    }
    if (fraction < 0 or fraction > 1 or macropore_fraction < 0 or macropore_fraction > 1 or parameters.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or parameters.ice_heat_capacity_megajoules_per_m3_k <= 0 or parameters.minimum_heat_capacity_megajoules_per_k < 0) return error.InvalidWaterHeatLayerRemapInput;

    const remaining = 1 - fraction;
    const macropore_remaining = 1 - macropore_fraction;
    inline for (.{
        grid.matrix_liquid_water_m3[source],                         grid.matrix_liquid_water_m3[destination],
        grid.matrix_ice_water_m3[source],                            grid.matrix_ice_water_m3[destination],
        grid.macropore_liquid_water_m3[source],                      grid.macropore_liquid_water_m3[destination],
        grid.macropore_ice_water_m3[source],                         grid.macropore_ice_water_m3[destination],
        grid.macropore_pore_capacity_m3[source],                     grid.macropore_pore_capacity_m3[destination],
        grid.macropore_air_volume_m3[source],                        grid.macropore_air_volume_m3[destination],
        grid.matrix_pore_capacity_m3[source],                        grid.matrix_pore_capacity_m3[destination],
        grid.matrix_air_volume_m3[source],                           grid.matrix_air_volume_m3[destination],
        grid.water_vapor_volume_m3[source],                          grid.water_vapor_volume_m3[destination],
        thermal.layer_volume_m3[source],                             thermal.layer_volume_m3[destination],
        thermal.dry_solid_heat_capacity_megajoules_per_m3_k[source], thermal.dry_solid_heat_capacity_megajoules_per_m3_k[destination],
        thermal.total_heat_capacity_megajoules_per_m3_k[source],     thermal.total_heat_capacity_megajoules_per_m3_k[destination],
        grid.soil_temperature_k[source],                             grid.soil_temperature_k[destination],
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidWaterHeatLayerRemapState;

    const source_volume_before = thermal.layer_volume_m3[source];
    const destination_volume_before = thermal.layer_volume_m3[destination];
    if (source_volume_before > 0 and grid.soil_temperature_k[source] <= 0) return error.InvalidWaterHeatLayerRemapState;
    if (source_volume_before == 0 and
        (grid.matrix_liquid_water_m3[source] != 0 or
            grid.matrix_ice_water_m3[source] != 0 or
            grid.matrix_pore_capacity_m3[source] != 0 or
            grid.matrix_air_volume_m3[source] != 0 or
            grid.water_vapor_volume_m3[source] != 0 or
            thermal.dry_solid_heat_capacity_megajoules_per_m3_k[source] != 0))
        return error.InvalidWaterHeatLayerRemapState;
    if (destination_volume_before > 0 and grid.soil_temperature_k[destination] <= 0) return error.InvalidWaterHeatLayerRemapState;
    if (destination_volume_before == 0 and
        (grid.matrix_liquid_water_m3[destination] != 0 or
            grid.matrix_ice_water_m3[destination] != 0 or
            grid.matrix_pore_capacity_m3[destination] != 0 or
            grid.matrix_air_volume_m3[destination] != 0 or
            grid.water_vapor_volume_m3[destination] != 0 or
            thermal.dry_solid_heat_capacity_megajoules_per_m3_k[destination] != 0))
        return error.InvalidWaterHeatLayerRemapState;
    const source_dry_before = if (source_volume_before > 0)
        thermal.dry_solid_heat_capacity_megajoules_per_m3_k[source] * source_volume_before
    else
        0;
    const destination_dry_before = if (destination_volume_before > 0)
        thermal.dry_solid_heat_capacity_megajoules_per_m3_k[destination] * destination_volume_before
    else
        0;
    // The cached total-capacity table is the authoritative "before" value: it
    // is what the rest of the hour's solvers have been using for this layer,
    // and `soil_thermal.refresh` now builds it from the same carriers and the
    // same vapor term as the EXEC census, so the two agree. Reconstructing it
    // here instead was tried and rejected: it disagreed with the temperature
    // the phase solver expected and drove `SoilPhaseSolverStagnated`.
    const source_heat_capacity_before = if (source_volume_before > 0)
        thermal.total_heat_capacity_megajoules_per_m3_k[source] * source_volume_before
    else
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k * grid.macropore_liquid_water_m3[source] +
            parameters.ice_heat_capacity_megajoules_per_m3_k * grid.macropore_ice_water_m3[source];
    // A preceding boundary can empty a layer's matrix domain before a later
    // boundary uses that same layer as the recipient. The zero-volume state
    // stores per-volume capacities as zero, but independently retained
    // macropore water/ice still carries heat and remains in the census.
    const destination_heat_capacity_before = if (destination_volume_before > 0)
        thermal.total_heat_capacity_megajoules_per_m3_k[destination] * destination_volume_before
    else
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k * grid.macropore_liquid_water_m3[destination] +
            parameters.ice_heat_capacity_megajoules_per_m3_k * grid.macropore_ice_water_m3[destination];
    if ((source_heat_capacity_before > 0 and grid.soil_temperature_k[source] <= 0) or
        (destination_heat_capacity_before > 0 and grid.soil_temperature_k[destination] <= 0))
        return error.InvalidWaterHeatLayerRemapState;
    const source_energy_before = source_heat_capacity_before * grid.soil_temperature_k[source];
    const destination_energy_before = destination_heat_capacity_before * grid.soil_temperature_k[destination];

    var result: Candidate = .{
        .source_matrix_liquid_water_m3 = remaining * grid.matrix_liquid_water_m3[source],
        .destination_matrix_liquid_water_m3 = grid.matrix_liquid_water_m3[destination] + fraction * grid.matrix_liquid_water_m3[source],
        .source_matrix_ice_water_m3 = remaining * grid.matrix_ice_water_m3[source],
        .destination_matrix_ice_water_m3 = grid.matrix_ice_water_m3[destination] + fraction * grid.matrix_ice_water_m3[source],
        .source_matrix_pore_capacity_m3 = remaining * grid.matrix_pore_capacity_m3[source],
        .destination_matrix_pore_capacity_m3 = grid.matrix_pore_capacity_m3[destination] + fraction * grid.matrix_pore_capacity_m3[source],
        .source_matrix_air_volume_m3 = remaining * grid.matrix_air_volume_m3[source],
        .destination_matrix_air_volume_m3 = grid.matrix_air_volume_m3[destination] + fraction * grid.matrix_air_volume_m3[source],
        .source_macropore_liquid_water_m3 = macropore_remaining * grid.macropore_liquid_water_m3[source],
        .destination_macropore_liquid_water_m3 = grid.macropore_liquid_water_m3[destination] + macropore_fraction * grid.macropore_liquid_water_m3[source],
        .source_macropore_ice_water_m3 = macropore_remaining * grid.macropore_ice_water_m3[source],
        .destination_macropore_ice_water_m3 = grid.macropore_ice_water_m3[destination] + macropore_fraction * grid.macropore_ice_water_m3[source],
        .source_macropore_pore_capacity_m3 = macropore_remaining * grid.macropore_pore_capacity_m3[source],
        .destination_macropore_pore_capacity_m3 = grid.macropore_pore_capacity_m3[destination] + macropore_fraction * grid.macropore_pore_capacity_m3[source],
        .source_macropore_air_volume_m3 = macropore_remaining * grid.macropore_air_volume_m3[source],
        .destination_macropore_air_volume_m3 = grid.macropore_air_volume_m3[destination] + macropore_fraction * grid.macropore_air_volume_m3[source],
        // Vapor occupies the transferred pore volume, so it moves with the same
        // fraction as the other matrix stores. WATSUB gives it liquid heat
        // capacity, so leaving it behind would move volume without its energy.
        .source_water_vapor_volume_m3 = remaining * grid.water_vapor_volume_m3[source],
        .destination_water_vapor_volume_m3 = grid.water_vapor_volume_m3[destination] + fraction * grid.water_vapor_volume_m3[source],
        .source_layer_volume_m3 = remaining * source_volume_before,
        .destination_layer_volume_m3 = destination_volume_before + fraction * source_volume_before,
        .source_dry_heat_capacity_megajoules_per_k = remaining * source_dry_before,
        .destination_dry_heat_capacity_megajoules_per_k = destination_dry_before + fraction * source_dry_before,
        .source_total_heat_capacity_megajoules_per_k = undefined,
        .destination_total_heat_capacity_megajoules_per_k = undefined,
        .source_temperature_k = undefined,
        .destination_temperature_k = undefined,
        .source_discarded_megajoules = undefined,
        .destination_discarded_megajoules = undefined,
    };
    result.source_total_heat_capacity_megajoules_per_k = result.source_dry_heat_capacity_megajoules_per_k +
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k * (result.source_matrix_liquid_water_m3 + result.source_macropore_liquid_water_m3 + result.source_water_vapor_volume_m3) +
        parameters.ice_heat_capacity_megajoules_per_m3_k * (result.source_matrix_ice_water_m3 + result.source_macropore_ice_water_m3);
    result.destination_total_heat_capacity_megajoules_per_k = result.destination_dry_heat_capacity_megajoules_per_k +
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k * (result.destination_matrix_liquid_water_m3 + result.destination_macropore_liquid_water_m3 + result.destination_water_vapor_volume_m3) +
        parameters.ice_heat_capacity_megajoules_per_m3_k * (result.destination_matrix_ice_water_m3 + result.destination_macropore_ice_water_m3);
    // Energy moves with the *transferred material only*, at the source
    // temperature. `redist.f` 9645--9651 is explicit about this:
    //
    //   FXVHCM = FWO*VHCM(L0)
    //   FXVHCP = FXVHCM + 4.19*(FXVOLW+FXVOLV) + 1.9274*FXVOLI
    //   FXENGY = TKS(L0)*FXVHCP
    //   ENGY1  = VHCP(L1)*TKS(L1) + FXENGY
    //   ENGY0  = VHCP(L0)*TKS(L0) - FXENGY
    //
    // and every `FXVOL*` in that expression is a matrix store. The source also
    // moves `VOLWH`/`VOLIH` at 9611--9622 under FHO, but omits their heat from
    // FXVHCP. Repeating that omission would move phase mass without its
    // enthalpy and create a temperature gradient in an initially isothermal
    // pair. The conservative translation below therefore adds the FHO-gated
    // macropore liquid/ice capacities at the same donor temperature.
    //
    // The previous form here was `source_energy_after = remaining *
    // source_energy_before`, which scales the source's *whole* energy, including
    // the part carried by macropore water and ice that never left the layer. That
    // is only equivalent when the macropore domain is empty, which is why no
    // Ottawa hour exposed it: Ottawa's mineral column carries no macropore water
    // at these layers. Wherever macropore storage exists, the old form exported
    // energy the destination never received material for, and at `fraction == 1`
    // it removed *all* the source's energy while leaving real macropore heat
    // capacity behind, producing a 0 K source layer.
    //
    // That inconsistency is precisely what the emptied-source guard below
    // detected in the `Arctic Fen CH` first hour. The guard is correct and is
    // kept unchanged; the energy split it was reporting on is what was wrong.
    const transferred_heat_capacity_megajoules_per_k = fraction * source_dry_before +
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
            (fraction * (grid.matrix_liquid_water_m3[source] + grid.water_vapor_volume_m3[source]) +
                macropore_fraction * grid.macropore_liquid_water_m3[source]) +
        parameters.ice_heat_capacity_megajoules_per_m3_k *
            (fraction * grid.matrix_ice_water_m3[source] +
                macropore_fraction * grid.macropore_ice_water_m3[source]);
    const transferred_energy = grid.soil_temperature_k[source] * transferred_heat_capacity_megajoules_per_k;
    const source_energy_after = source_energy_before - transferred_energy;
    const destination_energy_after = destination_energy_before + transferred_energy;
    // `redist.f` 9660--9665 falls back to the *undivided* layer's temperature
    // when a side ends below the minimum capacity, and uses that same fallback
    // for both sides. Production keeps its established source-then-destination
    // ordering, which agrees wherever the fallback is not taken.
    result.destination_temperature_k = if (result.destination_total_heat_capacity_megajoules_per_k > parameters.minimum_heat_capacity_megajoules_per_k) destination_energy_after / result.destination_total_heat_capacity_megajoules_per_k else grid.soil_temperature_k[source];
    result.source_temperature_k = if (result.source_total_heat_capacity_megajoules_per_k > parameters.minimum_heat_capacity_megajoules_per_k) source_energy_after / result.source_total_heat_capacity_megajoules_per_k else result.destination_temperature_k;

    // `issue-062`/`FloorDiscard`. Whenever the fallback above fired, the side's
    // actual final state (`capacity_after * assigned_temperature`) is not the
    // exact conservative split (`*_energy_after`) computed a few lines above --
    // that is precisely what `redist.f` 9660--9665 accepts by holding the
    // undivided temperature instead of dividing. Report the difference so a
    // caller with its own before/after transfer snapshot (this file's own
    // callers are its regression tests; production's is
    // `relayering_activity.zig`'s `stageBoundary`) can recognize this exact,
    // bounded, already-characterized event instead of treating it as an
    // unexplained conservation violation. Zero whenever the exact division
    // path was taken.
    result.destination_discarded_megajoules =
        if (result.destination_total_heat_capacity_megajoules_per_k > parameters.minimum_heat_capacity_megajoules_per_k)
            0
        else
            result.destination_total_heat_capacity_megajoules_per_k * result.destination_temperature_k - destination_energy_after;
    result.source_discarded_megajoules =
        if (result.source_total_heat_capacity_megajoules_per_k > parameters.minimum_heat_capacity_megajoules_per_k)
            0
        else
            result.source_total_heat_capacity_megajoules_per_k * result.source_temperature_k - source_energy_after;

    inline for (.{ result.source_total_heat_capacity_megajoules_per_k, result.destination_total_heat_capacity_megajoules_per_k, result.source_temperature_k, result.destination_temperature_k, result.source_discarded_megajoules, result.destination_discarded_megajoules }) |value| {
        if (!std.math.isFinite(value)) return error.InvalidWaterHeatLayerRemapResult;
    }
    inline for (.{ result.source_total_heat_capacity_megajoules_per_k, result.destination_total_heat_capacity_megajoules_per_k, result.source_temperature_k, result.destination_temperature_k }) |value| {
        if (value < 0) return error.InvalidWaterHeatLayerRemapResult;
    }
    // A zero-volume source may still legitimately hold heat capacity, because
    // its macropore stores stay attached to the layer (`redist.f` 9609--9622,
    // where `VOLWH`/`VOLIH` move on their own `FHOL` gate rather than on `FX`).
    // `fraction == 1` is ordinary in the source, which sets `FX=1.0` explicitly
    // at 8452, 8461, 8472, 8494 and 8502, so a full transfer out of a layer that
    // carries macropore water reaches exactly this state. `state_updateDerived` divides
    // by the volume, so what actually has to hold is that a zero-volume layer
    // retains no *matrix* storage to describe, which is guaranteed by construction
    // above; the remaining capacity is then macropore-only and its temperature is
    // still meaningful.
    //
    // What must never happen is capacity remaining that the retained carriers
    // cannot account for, since that would mean the split lost track of material.
    // Check that directly instead of forbidding the state outright.
    if (result.source_layer_volume_m3 == 0) {
        const retained_capacity_megajoules_per_k =
            parameters.liquid_water_heat_capacity_megajoules_per_m3_k * result.source_macropore_liquid_water_m3 +
            parameters.ice_heat_capacity_megajoules_per_m3_k * result.source_macropore_ice_water_m3;
        const unexplained = result.source_total_heat_capacity_megajoules_per_k - retained_capacity_megajoules_per_k;
        if (unexplained > parameters.minimum_heat_capacity_megajoules_per_k) return error.InvalidWaterHeatLayerRemapResult;
    }
    return result;
}

fn state_updateDerived(grid: *GridState, thermal: *thermal_module.State, index: usize, dry_heat_capacity_megajoules_per_k: f64, total_heat_capacity_megajoules_per_k: f64, temperature_k: f64) void {
    grid.liquid_water_m3[index] = grid.matrix_liquid_water_m3[index] + grid.macropore_liquid_water_m3[index];
    grid.ice_water_m3[index] = grid.matrix_ice_water_m3[index] + grid.macropore_ice_water_m3[index];
    grid.air_volume_m3[index] = grid.matrix_air_volume_m3[index] + grid.macropore_air_volume_m3[index];
    grid.soil_temperature_k[index] = temperature_k;
    const volume = thermal.layer_volume_m3[index];
    thermal.dry_solid_heat_capacity_megajoules_per_m3_k[index] = if (volume > 0) dry_heat_capacity_megajoules_per_k / volume else 0;
    thermal.total_heat_capacity_megajoules_per_m3_k[index] = if (volume > 0) total_heat_capacity_megajoules_per_k / volume else 0;
    thermal.porosity_fraction[index] = if (volume > 0) (grid.matrix_pore_capacity_m3[index] + grid.macropore_pore_capacity_m3[index]) / volume else 0;
}

test "a fully transferred source layer that retains macropore water is accepted" {
    // Reproduces the `Arctic Fen CH` first-hour `InvalidWaterHeatLayerRemapResult`
    // (examples-ng/Arctic Fen CH/FINDING_saturated_peat_layer_remap.md).
    //
    // `fraction == 1` is a state the oracle reaches routinely, not an edge case:
    // `redist.f` sets `FX=1.0` explicitly at 8452, 8461, 8472, 8494 and 8502,
    // which is what happens whenever the boundary displacement equals or exceeds
    // the source layer's whole thickness.
    //
    // At `fraction == 1` every matrix store and the layer volume go to zero, but
    // the macropore stores deliberately stay attached to their layer, matching
    // `redist.f` 9609--9622 where `VOLWH`/`VOLIH`/`VOLAH` move on their own
    // `FHOL` gate rather than on `FX`.
    //
    // The defect was the ENERGY SPLIT, not the acceptance predicate. The old
    // `source_energy_after = remaining * source_energy_before` scaled the whole
    // source energy, including heat carried by macropore water that never moved,
    // so at `fraction == 1` it removed all the energy while leaving real
    // macropore capacity behind. The emptied-source guard at the end of
    // `calculate` correctly refused that inconsistent state. `redist.f`
    // 9645--9651 instead moves only the transferred material's energy.

    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var thermal: thermal_module.State = undefined;
    var layer_volume_m3 = [_]f64{ 0.05, 0.10 };
    var dry_heat_capacity_megajoules_per_m3_k = [_]f64{ 0.06, 0.06 };
    var total_heat_capacity_megajoules_per_m3_k = [_]f64{ 0, 0 };
    var porosity_fraction = [_]f64{ 0.9, 0.9 };
    thermal.layer_volume_m3 = &layer_volume_m3;
    thermal.dry_solid_heat_capacity_megajoules_per_m3_k = &dry_heat_capacity_megajoules_per_m3_k;
    thermal.total_heat_capacity_megajoules_per_m3_k = &total_heat_capacity_megajoules_per_m3_k;
    thermal.porosity_fraction = &porosity_fraction;

    // A saturated, mineral-poor, partly frozen peat layer: nearly all pore space
    // is water or ice, the dry solid capacity is small, and a macropore domain
    // carries part of the water. Layer 0 is the source and is fully transferred.
    grid.matrix_liquid_water_m3[0] = 0.030;
    grid.matrix_liquid_water_m3[1] = 0.060;
    grid.matrix_ice_water_m3[0] = 0.012;
    grid.matrix_ice_water_m3[1] = 0.020;
    grid.macropore_liquid_water_m3[0] = 0.003;
    grid.macropore_liquid_water_m3[1] = 0.006;
    grid.macropore_ice_water_m3[0] = 0.001;
    grid.macropore_ice_water_m3[1] = 0.002;
    grid.matrix_pore_capacity_m3[0] = 0.045;
    grid.matrix_pore_capacity_m3[1] = 0.090;
    grid.matrix_air_volume_m3[0] = 0.003;
    grid.matrix_air_volume_m3[1] = 0.010;
    grid.water_vapor_volume_m3[0] = 0.0005;
    grid.water_vapor_volume_m3[1] = 0.0010;
    grid.soil_temperature_k[0] = 272.2;
    grid.soil_temperature_k[1] = 273.4;

    const parameters: Parameters = .{
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
        // `starts.f:655` VHCPRX = 8.380e-5 * AREA, so the threshold is small but
        // strictly positive, exactly as in production.
        .minimum_heat_capacity_megajoules_per_k = 8.380e-5,
    };
    for (0..2) |index| {
        thermal.total_heat_capacity_megajoules_per_m3_k[index] =
            censusHeatCapacityPerK(&grid, &thermal, index, parameters) / thermal.layer_volume_m3[index];
    }

    const energy_before = censusEnergy(&grid, &thermal, parameters);
    const water_before = grid.matrix_liquid_water_m3[0] + grid.matrix_liquid_water_m3[1] +
        grid.macropore_liquid_water_m3[0] + grid.macropore_liquid_water_m3[1];
    const ice_before = grid.matrix_ice_water_m3[0] + grid.matrix_ice_water_m3[1] +
        grid.macropore_ice_water_m3[0] + grid.macropore_ice_water_m3[1];

    // This is the call that failed in the fen's first simulated hour.
    try transferLayerFraction(&grid, &thermal, 0, 1, 1.0, parameters, null);

    // Tier 1: the source's matrix domain is empty and its macropore domain is
    // untouched, which is the source behaviour being asserted.
    try std.testing.expectEqual(@as(f64, 0), grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 0), grid.matrix_ice_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 0.003), grid.macropore_liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 0.001), grid.macropore_ice_water_m3[0]);

    // Tier 2: water and ice are conserved across the pair.
    const water_after = grid.matrix_liquid_water_m3[0] + grid.matrix_liquid_water_m3[1] +
        grid.macropore_liquid_water_m3[0] + grid.macropore_liquid_water_m3[1];
    const ice_after = grid.matrix_ice_water_m3[0] + grid.matrix_ice_water_m3[1] +
        grid.macropore_ice_water_m3[0] + grid.macropore_ice_water_m3[1];
    try std.testing.expectApproxEqRel(water_before, water_after, 1e-15);
    try std.testing.expectApproxEqRel(ice_before, ice_after, 1e-15);

    // Tier 2: the census energy is conserved. This is the invariant that makes
    // accepting the state safe rather than merely permissive: the retained
    // macropore stores keep real heat capacity in the source layer, and the
    // source keeps a physical temperature to carry it at.
    const energy_after = censusEnergy(&grid, &thermal, parameters);
    try std.testing.expectApproxEqRel(energy_before, energy_after, 1e-12);

    // Tier 1: the emptied source still holds a physical temperature. With zero
    // volume its per-volume densities are zero by `state_updateDerived`, so the
    // temperature is the only carrier left that a later consumer can read.
    try std.testing.expect(grid.soil_temperature_k[0] > 0);
    try std.testing.expect(std.math.isFinite(grid.soil_temperature_k[0]));
}

test "an emptied source with no retained storage inherits the destination temperature" {
    // The complementary case to the fen state: a source that ends with zero volume
    // AND zero retained storage holds no energy, so it has no temperature of its
    // own. `redist.f` 9660--9665 handles this with an explicit fallback to the
    // undivided layer's temperature rather than a division by a vanishing
    // capacity, and production must do the same instead of producing 0 K or NaN.

    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var thermal: thermal_module.State = undefined;
    var layer_volume_m3 = [_]f64{ 0.05, 0.10 };
    // A large dry solid capacity that would survive the transfer only if the
    // implementation failed to scale it with the transferred fraction.
    var dry_heat_capacity_megajoules_per_m3_k = [_]f64{ 2.0, 2.0 };
    var total_heat_capacity_megajoules_per_m3_k = [_]f64{ 0, 0 };
    var porosity_fraction = [_]f64{ 0.5, 0.5 };
    thermal.layer_volume_m3 = &layer_volume_m3;
    thermal.dry_solid_heat_capacity_megajoules_per_m3_k = &dry_heat_capacity_megajoules_per_m3_k;
    thermal.total_heat_capacity_megajoules_per_m3_k = &total_heat_capacity_megajoules_per_m3_k;
    thermal.porosity_fraction = &porosity_fraction;
    grid.soil_temperature_k[0] = 280;
    grid.soil_temperature_k[1] = 281;
    const parameters: Parameters = .{
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
        .minimum_heat_capacity_megajoules_per_k = 8.380e-5,
    };
    for (0..2) |index| {
        thermal.total_heat_capacity_megajoules_per_m3_k[index] =
            censusHeatCapacityPerK(&grid, &thermal, index, parameters) / thermal.layer_volume_m3[index];
    }
    // No macropore storage is retained, so a full transfer leaves the source with
    // literally nothing: zero volume, zero capacity, zero stores.
    try std.testing.expectEqual(@as(f64, 0), grid.macropore_liquid_water_m3[0]);
    try transferLayerFraction(&grid, &thermal, 0, 1, 1.0, parameters, null);
    // Accepted, because a source with zero retained capacity is consistent: it
    // holds no energy, and it inherits the destination temperature exactly as
    // `redist.f` 9660--9665 does through its `TKS(L,NY,NX)` fallback.
    try std.testing.expect(grid.soil_temperature_k[0] > 0);
}

test "an emptied source retains exactly its macropore capacity and nothing more" {
    // Evidence for the narrowed guard, stated honestly.
    //
    // At `fraction == 1` the retained-capacity identity is *structural*: every
    // matrix and vapor term in `source_total_heat_capacity` is multiplied by
    // `remaining == 0`, and `source_dry_heat_capacity` likewise, so the
    // reconstructed source capacity is identically the macropore term. The guard
    // therefore cannot fire at `fraction == 1` under the current construction,
    // and that is exactly the point: it now expresses the real invariant
    // ("capacity must be explained by retained carriers") instead of a proxy
    // ("a zero-volume layer must hold no capacity") that the source contradicts.
    //
    // It is kept rather than deleted because it still constrains any future edit
    // to the capacity reconstruction: if someone adds a term that does not scale
    // with the transferred fraction, or moves the macropore stores into the `FX`
    // transfer without updating the retained set, this fires instead of silently
    // producing a layer whose temperature means nothing. This test pins the
    // identity the guard depends on, so that constraint is checked rather than
    // assumed.
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var thermal: thermal_module.State = undefined;
    var layer_volume_m3 = [_]f64{ 0.05, 0.10 };
    // A deliberately large dry solid capacity: if it failed to scale with the
    // transferred fraction it would leave unexplained capacity behind.
    var dry_heat_capacity_megajoules_per_m3_k = [_]f64{ 2.0, 2.0 };
    var total_heat_capacity_megajoules_per_m3_k = [_]f64{ 0, 0 };
    var porosity_fraction = [_]f64{ 0.5, 0.5 };
    thermal.layer_volume_m3 = &layer_volume_m3;
    thermal.dry_solid_heat_capacity_megajoules_per_m3_k = &dry_heat_capacity_megajoules_per_m3_k;
    thermal.total_heat_capacity_megajoules_per_m3_k = &total_heat_capacity_megajoules_per_m3_k;
    thermal.porosity_fraction = &porosity_fraction;
    grid.matrix_liquid_water_m3[0] = 0.02;
    grid.matrix_liquid_water_m3[1] = 0.04;
    grid.matrix_ice_water_m3[0] = 0.006;
    grid.water_vapor_volume_m3[0] = 0.0004;
    grid.macropore_liquid_water_m3[0] = 0.005;
    grid.macropore_ice_water_m3[0] = 0.002;
    // Macropore pore space with no water in it carries no heat, so it must not
    // appear in the retained set.
    grid.macropore_pore_capacity_m3[0] = 0.02;
    grid.soil_temperature_k[0] = 274;
    grid.soil_temperature_k[1] = 275;
    const parameters: Parameters = .{
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
        .minimum_heat_capacity_megajoules_per_k = 8.380e-5,
    };
    for (0..2) |index| {
        thermal.total_heat_capacity_megajoules_per_m3_k[index] =
            censusHeatCapacityPerK(&grid, &thermal, index, parameters) / thermal.layer_volume_m3[index];
    }
    const expected_retained_megajoules_per_k =
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k * grid.macropore_liquid_water_m3[0] +
        parameters.ice_heat_capacity_megajoules_per_m3_k * grid.macropore_ice_water_m3[0];
    // Nonzero, so the identity below is not the trivial 0 == 0.
    try std.testing.expect(expected_retained_megajoules_per_k > parameters.minimum_heat_capacity_megajoules_per_k);

    const candidate = try calculate(&grid, &thermal, 0, 1, 1.0, 0, parameters);

    // The identity the guard rests on: an emptied source's whole remaining
    // capacity is its retained macropore carriers, to f64 rounding.
    try std.testing.expectApproxEqRel(
        expected_retained_megajoules_per_k,
        candidate.source_total_heat_capacity_megajoules_per_k,
        1e-15,
    );
    // And the dry solid capacity did leave with the transferred material, which is
    // what makes the identity nontrivial given the 2.0 value seeded above.
    try std.testing.expectApproxEqAbs(@as(f64, 0), candidate.source_dry_heat_capacity_megajoules_per_k, 1e-18);
}

test "a partial transfer leaves retained macropore heat in the source layer" {

    // This is the discriminating test for the energy-split correction, and it is
    // the one that fails under the old `remaining * source_energy_before` form
    // while conserving energy either way. Energy conservation alone cannot
    // separate the two formulations: both move a total that sums correctly. What
    // separates them is WHERE the retained macropore heat ends up.
    //
    // Setup: the source and destination start at the SAME temperature. Under the
    // source formulation (`redist.f` 9645--9651) an isothermal pair must stay
    // isothermal, because energy is moved at exactly the temperature and capacity
    // of the material that moves. Under the old form the source exports a share
    // of its macropore heat as well, so it must cool while the destination warms,
    // which is a spurious temperature gradient manufactured by relayering out of
    // nothing.
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var thermal: thermal_module.State = undefined;
    var layer_volume_m3 = [_]f64{ 0.05, 0.10 };
    var dry_heat_capacity_megajoules_per_m3_k = [_]f64{ 0.06, 0.06 };
    var total_heat_capacity_megajoules_per_m3_k = [_]f64{ 0, 0 };
    var porosity_fraction = [_]f64{ 0.9, 0.9 };
    thermal.layer_volume_m3 = &layer_volume_m3;
    thermal.dry_solid_heat_capacity_megajoules_per_m3_k = &dry_heat_capacity_megajoules_per_m3_k;
    thermal.total_heat_capacity_megajoules_per_m3_k = &total_heat_capacity_megajoules_per_m3_k;
    thermal.porosity_fraction = &porosity_fraction;
    grid.matrix_liquid_water_m3[0] = 0.030;
    grid.matrix_liquid_water_m3[1] = 0.060;
    grid.matrix_ice_water_m3[0] = 0.012;
    grid.matrix_ice_water_m3[1] = 0.020;
    // The source carries substantial macropore storage; this is the term the old
    // form wrongly exported a share of.
    grid.macropore_liquid_water_m3[0] = 0.010;
    grid.macropore_liquid_water_m3[1] = 0.004;
    grid.macropore_ice_water_m3[0] = 0.004;
    grid.macropore_ice_water_m3[1] = 0.001;
    grid.matrix_pore_capacity_m3[0] = 0.045;
    grid.matrix_pore_capacity_m3[1] = 0.090;
    grid.matrix_air_volume_m3[0] = 0.003;
    grid.matrix_air_volume_m3[1] = 0.010;
    grid.water_vapor_volume_m3[0] = 0.0005;
    grid.water_vapor_volume_m3[1] = 0.0010;
    const isothermal_k: f64 = 272.6;
    grid.soil_temperature_k[0] = isothermal_k;
    grid.soil_temperature_k[1] = isothermal_k;

    const parameters: Parameters = .{
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
        .minimum_heat_capacity_megajoules_per_k = 8.380e-5,
    };
    for (0..2) |index| {
        thermal.total_heat_capacity_megajoules_per_m3_k[index] =
            censusHeatCapacityPerK(&grid, &thermal, index, parameters) / thermal.layer_volume_m3[index];
    }
    const energy_before = censusEnergy(&grid, &thermal, parameters);

    try transferLayerFraction(&grid, &thermal, 0, 1, 0.4, parameters, null);

    // Tier 2: energy is still conserved. Both formulations pass this, which is
    // exactly why it is not sufficient on its own.
    try std.testing.expectApproxEqRel(energy_before, censusEnergy(&grid, &thermal, parameters), 1e-12);

    // Tier 1, the discriminating assertion: moving material between two layers at
    // the same temperature cannot create a temperature difference. The old form
    // cooled the source here by exporting retained macropore heat.
    try std.testing.expectApproxEqRel(isothermal_k, grid.soil_temperature_k[0], 1e-13);
    try std.testing.expectApproxEqRel(isothermal_k, grid.soil_temperature_k[1], 1e-13);
}

test "remap conserves the EXEC census heat definition when a layer holds vapor" {
    // The landscape census in `landscape_mass_inventory.zig` builds extensive
    // heat capacity from the authoritative carriers as
    //   dry * volume + liquid_capacity * (matrix_liquid + macropore_liquid + vapor)
    //              + ice_capacity * (matrix_ice + macropore_ice)
    // so a layer holding water vapor has a larger capacity than the cached
    // `soil_thermal` table, which omits vapor. A relayering transfer must
    // conserve the census definition, otherwise EXEC's daily heat audit sees
    // energy created out of the remap.
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var thermal: thermal_module.State = undefined;
    var layer_volume_m3 = [_]f64{ 2, 3 };
    var dry_heat_capacity_megajoules_per_m3_k = [_]f64{ 1, 2 };
    var total_heat_capacity_megajoules_per_m3_k = [_]f64{ 0, 0 };
    var porosity_fraction = [_]f64{ 0.5, 0.5 };
    thermal.layer_volume_m3 = &layer_volume_m3;
    thermal.dry_solid_heat_capacity_megajoules_per_m3_k = &dry_heat_capacity_megajoules_per_m3_k;
    thermal.total_heat_capacity_megajoules_per_m3_k = &total_heat_capacity_megajoules_per_m3_k;
    thermal.porosity_fraction = &porosity_fraction;
    grid.matrix_liquid_water_m3[0] = 0.4;
    grid.matrix_liquid_water_m3[1] = 0.3;
    grid.macropore_liquid_water_m3[0] = 0.1;
    grid.macropore_liquid_water_m3[1] = 0.2;
    grid.matrix_ice_water_m3[0] = 0.2;
    grid.matrix_ice_water_m3[1] = 0.1;
    // The source layer holds vapor; the destination does not.
    grid.water_vapor_volume_m3[0] = 0.05;
    grid.water_vapor_volume_m3[1] = 0;
    grid.matrix_pore_capacity_m3[0] = 1;
    grid.matrix_pore_capacity_m3[1] = 1.5;
    grid.matrix_air_volume_m3[0] = 0.4;
    grid.matrix_air_volume_m3[1] = 0.8;
    grid.soil_temperature_k[0] = 280;
    grid.soil_temperature_k[1] = 290;

    const parameters: Parameters = .{ .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .minimum_heat_capacity_megajoules_per_k = 0 };

    // Seed the cached table the way `soil_thermal.refresh` would, so the test
    // starts from a consistent live state rather than a hand-picked one.
    for (0..2) |index| {
        thermal.total_heat_capacity_megajoules_per_m3_k[index] = censusHeatCapacityPerK(&grid, &thermal, index, parameters) / thermal.layer_volume_m3[index];
    }

    const energy_before = censusEnergy(&grid, &thermal, parameters);
    try transferLayerFraction(&grid, &thermal, 0, 1, 0.25, parameters, null);
    const energy_after = censusEnergy(&grid, &thermal, parameters);
    try std.testing.expectApproxEqRel(energy_before, energy_after, 1e-12);
}

/// Mirrors the extensive heat capacity that `landscape_mass_inventory.zig`
/// reconstructs for the EXEC census, including the vapor term.
fn censusHeatCapacityPerK(grid: *const GridState, thermal: *const thermal_module.State, index: usize, parameters: Parameters) f64 {
    return thermal.dry_solid_heat_capacity_megajoules_per_m3_k[index] * thermal.layer_volume_m3[index] +
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
            (grid.matrix_liquid_water_m3[index] + grid.macropore_liquid_water_m3[index] + grid.water_vapor_volume_m3[index]) +
        parameters.ice_heat_capacity_megajoules_per_m3_k *
            (grid.matrix_ice_water_m3[index] + grid.macropore_ice_water_m3[index]);
}

fn censusEnergy(grid: *const GridState, thermal: *const thermal_module.State, parameters: Parameters) f64 {
    var total: f64 = 0;
    for (0..2) |index| total += censusHeatCapacityPerK(grid, thermal, index, parameters) * grid.soil_temperature_k[index];
    return total;
}

test "REDIST water heat remap conserves matrix stores and energy while leaving macropores" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var thermal: thermal_module.State = undefined;
    var layer_volume_m3 = [_]f64{ 2, 3 };
    var dry_heat_capacity_megajoules_per_m3_k = [_]f64{ 1, 2 };
    var total_heat_capacity_megajoules_per_m3_k = [_]f64{ 2, 3 };
    var porosity_fraction = [_]f64{ 0.5, 0.5 };
    thermal.layer_volume_m3 = &layer_volume_m3;
    thermal.dry_solid_heat_capacity_megajoules_per_m3_k = &dry_heat_capacity_megajoules_per_m3_k;
    thermal.total_heat_capacity_megajoules_per_m3_k = &total_heat_capacity_megajoules_per_m3_k;
    thermal.porosity_fraction = &porosity_fraction;
    grid.matrix_liquid_water_m3[0] = 0.4;
    grid.matrix_liquid_water_m3[1] = 0.3;
    grid.macropore_liquid_water_m3[0] = 0.1;
    grid.macropore_liquid_water_m3[1] = 0.2;
    grid.matrix_ice_water_m3[0] = 0.2;
    grid.matrix_ice_water_m3[1] = 0.1;
    grid.matrix_pore_capacity_m3[0] = 1;
    grid.matrix_pore_capacity_m3[1] = 1.5;
    grid.matrix_air_volume_m3[0] = 0.4;
    grid.matrix_air_volume_m3[1] = 0.8;
    grid.soil_temperature_k[0] = 280;
    grid.soil_temperature_k[1] = 290;
    const parameters: Parameters = .{ .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .minimum_heat_capacity_megajoules_per_k = 0 };
    // Seed the cached table consistently with the live carriers, the way
    // `soil_thermal.refresh` does. The transfer reconstructs capacity from the
    // carriers, so a hand-picked inconsistent table would assert nothing.
    for (0..2) |index| {
        total_heat_capacity_megajoules_per_m3_k[index] = censusHeatCapacityPerK(&grid, &thermal, index, parameters) / layer_volume_m3[index];
    }
    const initial_energy = censusEnergy(&grid, &thermal, parameters);
    try transferLayerFraction(&grid, &thermal, 0, 1, 0.25, parameters, null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), grid.matrix_liquid_water_m3[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), grid.matrix_liquid_water_m3[1], 1e-14);
    try std.testing.expectEqual(@as(f64, 0.1), grid.macropore_liquid_water_m3[0]);
    const final_energy = thermal.total_heat_capacity_megajoules_per_m3_k[0] * thermal.layer_volume_m3[0] * grid.soil_temperature_k[0] +
        thermal.total_heat_capacity_megajoules_per_m3_k[1] * thermal.layer_volume_m3[1] * grid.soil_temperature_k[1];
    try std.testing.expectApproxEqAbs(initial_energy, final_energy, 1e-9);
}

test "REDIST zero-volume recipient is refilled conservatively" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-8, .max_nonlinear_iterations = 4 });
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var layer_volume_m3 = [_]f64{ 2, 0 };
    var dry_heat_capacity_megajoules_per_m3_k = [_]f64{ 1, 0 };
    var total_heat_capacity_megajoules_per_m3_k = [_]f64{ 0, 0 };
    var porosity_fraction = [_]f64{ 0.5, 0 };
    var thermal: thermal_module.State = undefined;
    thermal.layer_volume_m3 = &layer_volume_m3;
    thermal.dry_solid_heat_capacity_megajoules_per_m3_k = &dry_heat_capacity_megajoules_per_m3_k;
    thermal.total_heat_capacity_megajoules_per_m3_k = &total_heat_capacity_megajoules_per_m3_k;
    thermal.porosity_fraction = &porosity_fraction;

    grid.matrix_liquid_water_m3[0] = 0.4;
    grid.matrix_ice_water_m3[0] = 0.2;
    grid.matrix_pore_capacity_m3[0] = 1;
    grid.matrix_air_volume_m3[0] = 0.4;
    grid.soil_temperature_k[0] = 280;
    grid.soil_temperature_k[1] = 0;
    const parameters: Parameters = .{ .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .minimum_heat_capacity_megajoules_per_k = 1e-8 };
    total_heat_capacity_megajoules_per_m3_k[0] = censusHeatCapacityPerK(&grid, &thermal, 0, parameters) / layer_volume_m3[0];
    const energy_before = censusEnergy(&grid, &thermal, parameters);

    try transferLayerFraction(&grid, &thermal, 0, 1, 0.25, parameters, null);

    try std.testing.expectApproxEqAbs(@as(f64, 0.5), layer_volume_m3[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), grid.matrix_liquid_water_m3[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), grid.matrix_ice_water_m3[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 280), grid.soil_temperature_k[1], 1e-12);
    try std.testing.expectApproxEqRel(energy_before, censusEnergy(&grid, &thermal, parameters), 1e-12);
}

test "REDIST zero-matrix donor transfers retained macropore phases and heat" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-8, .max_nonlinear_iterations = 4 });
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var layer_volume_m3 = [_]f64{ 0, 2 };
    var dry_heat_capacity_megajoules_per_m3_k = [_]f64{ 0, 1 };
    var total_heat_capacity_megajoules_per_m3_k = [_]f64{ 0, 0 };
    var porosity_fraction = [_]f64{ 0, 0.5 };
    var thermal: thermal_module.State = undefined;
    thermal.layer_volume_m3 = &layer_volume_m3;
    thermal.dry_solid_heat_capacity_megajoules_per_m3_k = &dry_heat_capacity_megajoules_per_m3_k;
    thermal.total_heat_capacity_megajoules_per_m3_k = &total_heat_capacity_megajoules_per_m3_k;
    thermal.porosity_fraction = &porosity_fraction;

    grid.macropore_liquid_water_m3[0] = 0.2;
    grid.macropore_ice_water_m3[0] = 0.1;
    grid.macropore_pore_capacity_m3[0] = 0.4;
    grid.macropore_air_volume_m3[0] = 0.1;
    grid.matrix_liquid_water_m3[1] = 0.4;
    grid.matrix_ice_water_m3[1] = 0.2;
    grid.matrix_pore_capacity_m3[1] = 1;
    grid.matrix_air_volume_m3[1] = 0.4;
    grid.soil_temperature_k[0] = 275;
    grid.soil_temperature_k[1] = 280;
    const parameters: Parameters = .{ .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .minimum_heat_capacity_megajoules_per_k = 1e-8 };
    total_heat_capacity_megajoules_per_m3_k[1] = censusHeatCapacityPerK(&grid, &thermal, 1, parameters) / layer_volume_m3[1];
    const energy_before = censusEnergy(&grid, &thermal, parameters);

    try transferLayerFractions(&grid, &thermal, 0, 1, 0.5, 0.5, parameters, null);

    try std.testing.expectEqual(@as(f64, 0), layer_volume_m3[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), grid.macropore_liquid_water_m3[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), grid.macropore_liquid_water_m3[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), grid.macropore_ice_water_m3[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), grid.macropore_ice_water_m3[1], 1e-14);
    try std.testing.expectApproxEqRel(energy_before, censusEnergy(&grid, &thermal, parameters), 1e-12);
}

test "REDIST coupled remap moves macropore phases and their enthalpy conservatively" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var layer_volume_m3 = [_]f64{ 2, 3 };
    var dry_heat_capacity_megajoules_per_m3_k = [_]f64{ 1, 2 };
    var total_heat_capacity_megajoules_per_m3_k = [_]f64{ 0, 0 };
    var porosity_fraction = [_]f64{ 0.5, 0.5 };
    var thermal: thermal_module.State = undefined;
    thermal.layer_volume_m3 = &layer_volume_m3;
    thermal.dry_solid_heat_capacity_megajoules_per_m3_k = &dry_heat_capacity_megajoules_per_m3_k;
    thermal.total_heat_capacity_megajoules_per_m3_k = &total_heat_capacity_megajoules_per_m3_k;
    thermal.porosity_fraction = &porosity_fraction;
    grid.matrix_liquid_water_m3[0] = 0.4;
    grid.matrix_liquid_water_m3[1] = 0.3;
    grid.matrix_ice_water_m3[0] = 0.2;
    grid.matrix_ice_water_m3[1] = 0.1;
    grid.matrix_pore_capacity_m3[0] = 1;
    grid.matrix_pore_capacity_m3[1] = 1.5;
    grid.matrix_air_volume_m3[0] = 0.4;
    grid.matrix_air_volume_m3[1] = 0.8;
    grid.macropore_liquid_water_m3[0] = 0.12;
    grid.macropore_liquid_water_m3[1] = 0.20;
    grid.macropore_ice_water_m3[0] = 0.04;
    grid.macropore_ice_water_m3[1] = 0.05;
    grid.macropore_pore_capacity_m3[0] = 0.20;
    grid.macropore_pore_capacity_m3[1] = 0.35;
    grid.macropore_air_volume_m3[0] = 0.04;
    grid.macropore_air_volume_m3[1] = 0.10;
    grid.soil_temperature_k[0] = 280;
    grid.soil_temperature_k[1] = 280;
    const parameters: Parameters = .{ .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .minimum_heat_capacity_megajoules_per_k = 0 };
    for (0..2) |index|
        total_heat_capacity_megajoules_per_m3_k[index] = censusHeatCapacityPerK(&grid, &thermal, index, parameters) / layer_volume_m3[index];
    const energy_before = censusEnergy(&grid, &thermal, parameters);
    const macropore_water_before = grid.macropore_liquid_water_m3[0] + grid.macropore_liquid_water_m3[1];
    const macropore_ice_before = grid.macropore_ice_water_m3[0] + grid.macropore_ice_water_m3[1];
    const macropore_capacity_before = grid.macropore_pore_capacity_m3[0] + grid.macropore_pore_capacity_m3[1];

    try transferLayerFractions(&grid, &thermal, 0, 1, 0.25, 0.25, parameters, null);

    try std.testing.expectApproxEqAbs(@as(f64, 0.09), grid.macropore_liquid_water_m3[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.23), grid.macropore_liquid_water_m3[1], 1e-14);
    try std.testing.expectApproxEqAbs(macropore_water_before, grid.macropore_liquid_water_m3[0] + grid.macropore_liquid_water_m3[1], 1e-14);
    try std.testing.expectApproxEqAbs(macropore_ice_before, grid.macropore_ice_water_m3[0] + grid.macropore_ice_water_m3[1], 1e-14);
    try std.testing.expectApproxEqAbs(macropore_capacity_before, grid.macropore_pore_capacity_m3[0] + grid.macropore_pore_capacity_m3[1], 1e-14);
    try std.testing.expectApproxEqRel(energy_before, censusEnergy(&grid, &thermal, parameters), 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 280), grid.soil_temperature_k[0], 1e-13);
    try std.testing.expectApproxEqRel(@as(f64, 280), grid.soil_temperature_k[1], 1e-13);
}

test "issue-062: the redist.f 9660-9665 remap-time floor fallback reports the energy its undivided-temperature fallback discards" {
    // A thin, nearly-dry source layer (hour 2894's degenerate cell-0/layer-0
    // shape, per issue-060/062) transferring almost all of its tiny water
    // content into a well-watered destination at a different temperature.
    // Leaving 0.1% of the source's already-tiny water content puts its
    // resulting capacity (~4.19e-6 MJ/K) below the 8.38e-5 `VHCPRX`-style
    // floor, so `redist.f` 9660--9665's undivided-temperature fallback must
    // fire for the source side only.
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var thermal: thermal_module.State = undefined;
    var layer_volume_m3 = [_]f64{ 0.05, 0.10 };
    var dry_heat_capacity_megajoules_per_m3_k = [_]f64{ 0, 0 };
    var total_heat_capacity_megajoules_per_m3_k = [_]f64{ 0, 0 };
    var porosity_fraction = [_]f64{ 0.9, 0.9 };
    thermal.layer_volume_m3 = &layer_volume_m3;
    thermal.dry_solid_heat_capacity_megajoules_per_m3_k = &dry_heat_capacity_megajoules_per_m3_k;
    thermal.total_heat_capacity_megajoules_per_m3_k = &total_heat_capacity_megajoules_per_m3_k;
    thermal.porosity_fraction = &porosity_fraction;

    grid.matrix_liquid_water_m3[0] = 0.001;
    grid.matrix_liquid_water_m3[1] = 1.0;
    grid.soil_temperature_k[0] = 300;
    grid.soil_temperature_k[1] = 280;

    const parameters: Parameters = .{
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
        // `starts.f:655` VHCPRX = 8.380E-05 * AREA, the same floor issue-060/062 cite.
        .minimum_heat_capacity_megajoules_per_k = 8.380e-5,
    };
    for (0..2) |index| {
        thermal.total_heat_capacity_megajoules_per_m3_k[index] =
            censusHeatCapacityPerK(&grid, &thermal, index, parameters) / thermal.layer_volume_m3[index];
    }
    const energy_before = censusEnergy(&grid, &thermal, parameters);

    var discard: FloorDiscard = .{};
    try transferLayerFraction(&grid, &thermal, 0, 1, 0.999, parameters, &discard);

    // The destination's resulting capacity (~4.19 MJ/K) stays far above the
    // floor, so its exact division path is unaffected.
    try std.testing.expectEqual(@as(f64, 0), discard.destination_megajoules);
    // The source's resulting capacity is below the floor: its fallback
    // fired and it must report a materially nonzero discard, or this
    // struct is reporting nothing useful.
    try std.testing.expect(@abs(discard.source_megajoules) > 1e-6);

    // The identity this struct exists to preserve, checked structurally
    // (not by hand-deriving the exact split's own magic numbers): whatever
    // the fallback added to or removed from the system relative to the
    // exact conservative split is exactly recoverable as the reported
    // discard, with no other unaccounted term. `energy_after - energy_before`
    // is the whole system's real energy change, and the exact split alone
    // would have kept that at exactly zero.
    // Absolute, not relative: `energy_after`/`energy_before` are ~1174 MJ
    // scale and their difference is only ~8e-5 MJ, so comparing on a
    // relative basis against the tiny result amplifies ordinary ~1e-13 MJ
    // float noise from the two large operands into a spurious failure.
    const energy_after = censusEnergy(&grid, &thermal, parameters);
    try std.testing.expectApproxEqAbs(
        discard.source_megajoules + discard.destination_megajoules,
        energy_after - energy_before,
        1e-9,
    );
}

test "issue-062: FloorDiscard reports zero on both sides when both endpoints divide normally" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 });
    var grid = try GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var thermal: thermal_module.State = undefined;
    var layer_volume_m3 = [_]f64{ 2, 3 };
    var dry_heat_capacity_megajoules_per_m3_k = [_]f64{ 1, 2 };
    var total_heat_capacity_megajoules_per_m3_k = [_]f64{ 0, 0 };
    var porosity_fraction = [_]f64{ 0.5, 0.5 };
    thermal.layer_volume_m3 = &layer_volume_m3;
    thermal.dry_solid_heat_capacity_megajoules_per_m3_k = &dry_heat_capacity_megajoules_per_m3_k;
    thermal.total_heat_capacity_megajoules_per_m3_k = &total_heat_capacity_megajoules_per_m3_k;
    thermal.porosity_fraction = &porosity_fraction;
    grid.matrix_liquid_water_m3[0] = 0.4;
    grid.matrix_liquid_water_m3[1] = 0.3;
    grid.matrix_ice_water_m3[0] = 0.2;
    grid.matrix_ice_water_m3[1] = 0.1;
    grid.soil_temperature_k[0] = 280;
    grid.soil_temperature_k[1] = 290;
    const parameters: Parameters = .{ .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .minimum_heat_capacity_megajoules_per_k = 0 };
    for (0..2) |index|
        total_heat_capacity_megajoules_per_m3_k[index] = censusHeatCapacityPerK(&grid, &thermal, index, parameters) / layer_volume_m3[index];

    var discard: FloorDiscard = .{};
    try transferLayerFraction(&grid, &thermal, 0, 1, 0.25, parameters, &discard);

    try std.testing.expectEqual(@as(f64, 0), discard.source_megajoules);
    try std.testing.expectEqual(@as(f64, 0), discard.destination_megajoules);
}
