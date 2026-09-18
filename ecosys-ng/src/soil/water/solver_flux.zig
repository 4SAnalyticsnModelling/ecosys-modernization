//! `solver` declarations: flux.
//!
//! Split out of `solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const numerics = @import("../../core/numerics.zig");
const grid_module = @import("../../state/grid.zig");
const retention = @import("retention.zig");
const water_flux = @import("flux.zig");
const transport_hydrology = @import("../../transport/hydrology.zig");
const water_boundary = @import("boundary.zig");
const boundary_topology = @import("../profile/boundary_topology.zig");
const group_hydraulics = @import("solver_hydraulics.zig");
const group_types = @import("solver_types.zig");

pub fn recordArtificialDrainage(outflow_m3: []f64, cell: usize, direction_sign: f64, oriented_flux_m3: f64) void {
    outflow_m3[cell] += @max(0, -direction_sign * oriented_flux_m3);
}

pub fn limitExternalStorageChange(
    proposed_change_m3: f64,
    trial_water_m3: f64,
    target_water_m3: f64,
    capacity_m3: f64,
) f64 {
    const minimum_change_m3 =
        -@min(@max(0.0, trial_water_m3), @max(0.0, target_water_m3));
    const maximum_change_m3 = @min(
        @max(0.0, capacity_m3 - trial_water_m3),
        @max(0.0, capacity_m3 - target_water_m3),
    );
    return std.math.clamp(
        proposed_change_m3,
        minimum_change_m3,
        maximum_change_m3,
    );
}

pub fn applyConservativeFlux(
    target: []f64,
    source: usize,
    destination: usize,
    flux_m3: f64,
) void {
    target[source] -= flux_m3;
    target[destination] += flux_m3;
}

pub fn limitFluxForAssembledTarget(
    flux_m3: f64,
    target: []const f64,
    source: usize,
    destination: usize,
    source_capacity_m3: f64,
    destination_capacity_m3: f64,
) f64 {
    if (flux_m3 >= 0)
        return @min(
            flux_m3,
            @min(
                @max(0.0, target[source]),
                @max(0.0, destination_capacity_m3 - target[destination]),
            ),
        );
    return @max(
        flux_m3,
        -@min(
            @max(0.0, target[destination]),
            @max(0.0, source_capacity_m3 - target[source]),
        ),
    );
}

pub fn state_update(grid: *grid_module.GridState, properties: group_types.Properties, state: []const f64) !void {
    const cells = grid.layer_count;
    for (0..cells) |cell| {
        const matrix = state[cell];
        const macro = state[cells + cell];
        if (!std.math.isFinite(matrix) or !std.math.isFinite(macro) or matrix < 0 or macro < 0) return error.InvalidSoilWaterCandidate;
        _ = try derivedPhysicalAirVolumeM3(grid.matrix_pore_capacity_m3[cell], matrix, grid.matrix_ice_water_m3[cell], properties.ice_density_megagrams_per_m3);
        _ = try derivedPhysicalAirVolumeM3(grid.macropore_pore_capacity_m3[cell], macro, grid.macropore_ice_water_m3[cell], properties.ice_density_megagrams_per_m3);
        grid.matrix_liquid_water_m3[cell] = matrix;
        grid.macropore_liquid_water_m3[cell] = macro;
        grid.liquid_water_m3[cell] = matrix + macro;
        grid.matrix_air_volume_m3[cell] = try derivedPhysicalAirVolumeM3(grid.matrix_pore_capacity_m3[cell], matrix, grid.matrix_ice_water_m3[cell], properties.ice_density_megagrams_per_m3);
        grid.macropore_air_volume_m3[cell] = try derivedPhysicalAirVolumeM3(grid.macropore_pore_capacity_m3[cell], macro, grid.macropore_ice_water_m3[cell], properties.ice_density_megagrams_per_m3);
        grid.air_volume_m3[cell] = grid.matrix_air_volume_m3[cell] + grid.macropore_air_volume_m3[cell];
        grid.matric_potential_megapascal[cell] = try group_hydraulics.matricPotentialMpaAt(
            properties,
            cell,
            matrix / properties.matrix_bulk_volume_m3[cell],
        );
    }
    try grid.validateFinite();
}

/// Signed physical pore space. A negative result is retained as an explicit
/// mechanical-freezing displacement demand; callers must route that liquid to
/// the vertically adjacent receiver rather than erase any conserved carrier.
pub fn physicalPoreSpaceM3(capacity_m3: f64, liquid_m3: f64, ice_water_equivalent_m3: f64, ice_density_megagrams_per_m3: f64) !f64 {
    inline for (.{ capacity_m3, liquid_m3, ice_water_equivalent_m3, ice_density_megagrams_per_m3 }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSoilWaterCandidate;
    if (capacity_m3 < 0 or liquid_m3 < 0 or ice_water_equivalent_m3 < 0 or ice_density_megagrams_per_m3 <= 0 or ice_density_megagrams_per_m3 > 1)
        return error.InvalidSoilWaterCandidate;
    const raw = capacity_m3 - liquid_m3 - ice_water_equivalent_m3 / ice_density_megagrams_per_m3;
    if (!std.math.isFinite(raw)) return error.NonFiniteSoilWaterCandidate;
    return raw;
}

pub fn physicalLiquidCapacityM3(capacity_m3: f64, ice_water_equivalent_m3: f64, ice_density_megagrams_per_m3: f64) !f64 {
    return @max(0, try physicalPoreSpaceM3(capacity_m3, 0, ice_water_equivalent_m3, ice_density_megagrams_per_m3));
}

/// Maximum liquid coordinate admitted while a source-ordered mechanical
/// prepass routes an HOUR1 capacity contraction. It is exactly the predicate
/// used by the residual: accepted entry overfill may persist transiently, but
/// a nonlinear proposal may not manufacture any additional overfill.
pub fn acceptedEntryLiquidCeilingM3(capacity_m3: f64, entry_liquid_m3: f64, ice_water_equivalent_m3: f64) !f64 {
    if (!std.math.isFinite(capacity_m3) or capacity_m3 < 0 or
        !std.math.isFinite(entry_liquid_m3) or entry_liquid_m3 < 0 or
        !std.math.isFinite(ice_water_equivalent_m3) or ice_water_equivalent_m3 < 0)
        return error.InvalidSoilWaterPoreState;
    return @max(0.0, @max(capacity_m3, entry_liquid_m3 + ice_water_equivalent_m3) - ice_water_equivalent_m3);
}

/// Air is derived, not conserved. The signed deficit remains exactly
/// reconstructible through `physicalPoreSpaceM3` and drives the next vertical
/// mechanical transfer; the nonnegative air carrier exposes only gas-filled
/// volume. No water or ice carrier is changed here.
pub fn derivedPhysicalAirVolumeM3(capacity_m3: f64, liquid_m3: f64, ice_water_equivalent_m3: f64, ice_density_megagrams_per_m3: f64) !f64 {
    const raw = try physicalPoreSpaceM3(capacity_m3, liquid_m3, ice_water_equivalent_m3, ice_density_megagrams_per_m3);
    return if (raw > 0) raw else 0;
}
