//! `solver` declarations: boundary.
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
const group_enthalpy = @import("solver_enthalpy.zig");
const group_misc = @import("solver_misc.zig");
const group_types = @import("solver_types.zig");

pub const BoundaryHeat = struct { input_megajoules: f64, output_megajoules: f64 };

const CellBoundaryHeat = struct {
    input_megajoules: []f64,
    output_megajoules: []f64,
    soil_layer_capacity: usize,
};

/// Re-evaluates only explicit external thermal faces at the accepted
/// temperature. `cell_heat_source_megajoules` is deliberately excluded because its
/// mapped production owner combines true sources with surface-to-soil
/// conduction; that conduction is internal to EXEC's landscape storage.
/// Internal faces and water-carried heat likewise cancel within the domain.
pub fn acceptedBoundaryHeat(
    properties: group_types.Properties,
    accepted_temperature_k: []const f64,
    phase_buffers: group_misc.PhaseBuffers,
) !BoundaryHeat {
    return acceptedBoundaryHeatInto(properties, accepted_temperature_k, phase_buffers, null, null);
}

/// Producer-owned accepted signed boundary heat partition by soil layer.
/// Positive entries enter the layer; negative entries leave it. Validation
/// completes before the caller-owned output is changed.
pub fn acceptedBoundaryHeatByLayer(
    properties: group_types.Properties,
    accepted_temperature_k: []const f64,
    phase_buffers: group_misc.PhaseBuffers,
    signed_megajoules_by_layer: []f64,
) !BoundaryHeat {
    if (signed_megajoules_by_layer.len == 0 or signed_megajoules_by_layer.len != accepted_temperature_k.len)
        return error.BoundaryHeatLayerDimensionMismatch;
    const total = try acceptedBoundaryHeatInto(properties, accepted_temperature_k, phase_buffers, null, null);
    @memset(signed_megajoules_by_layer, 0);
    const repeated = try acceptedBoundaryHeatInto(properties, accepted_temperature_k, phase_buffers, null, signed_megajoules_by_layer);
    if (repeated.input_megajoules != total.input_megajoules or repeated.output_megajoules != total.output_megajoules)
        return error.BoundaryHeatPartitionMismatch;
    return total;
}

/// Producer-owned horizontal partition of accepted external thermal faces.
/// The scalar return is the exact landscape sum. A validation pass completes
/// before either destination slice is changed.
pub fn acceptedBoundaryHeatByHorizontalCell(
    properties: group_types.Properties,
    accepted_temperature_k: []const f64,
    phase_buffers: group_misc.PhaseBuffers,
    soil_layer_capacity: usize,
    input_megajoules_by_cell: []f64,
    output_megajoules_by_cell: []f64,
) !BoundaryHeat {
    if (soil_layer_capacity == 0 or input_megajoules_by_cell.len == 0 or
        output_megajoules_by_cell.len != input_megajoules_by_cell.len or
        accepted_temperature_k.len != try std.math.mul(usize, input_megajoules_by_cell.len, soil_layer_capacity))
        return error.BoundaryHeatCellDimensionMismatch;
    const total = try acceptedBoundaryHeatInto(properties, accepted_temperature_k, phase_buffers, null, null);
    @memset(input_megajoules_by_cell, 0);
    @memset(output_megajoules_by_cell, 0);
    const repeated = try acceptedBoundaryHeatInto(properties, accepted_temperature_k, phase_buffers, .{
        .input_megajoules = input_megajoules_by_cell,
        .output_megajoules = output_megajoules_by_cell,
        .soil_layer_capacity = soil_layer_capacity,
    }, null);
    if (repeated.input_megajoules != total.input_megajoules or repeated.output_megajoules != total.output_megajoules)
        return error.BoundaryHeatPartitionMismatch;
    return total;
}

fn acceptedBoundaryHeatInto(
    properties: group_types.Properties,
    accepted_temperature_k: []const f64,
    phase_buffers: group_misc.PhaseBuffers,
    cell_output: ?CellBoundaryHeat,
    layer_output: ?[]f64,
) !BoundaryHeat {
    var result: BoundaryHeat = .{ .input_megajoules = 0, .output_megajoules = 0 };
    if (properties.geothermal_boundary) |geothermal| {
        for (geothermal.topology.faces) |boundary_face| {
            if (!boundary_face.is_lower_boundary) continue;
            const horizontal_cell = boundary_face.cell_index;
            if (!geothermal.enabled_by_cell[horizontal_cell]) continue;
            const layer = boundary_face.layer_index;
            if (properties.active_by_layer.len != 0 and
                !properties.active_by_layer[layer]) continue;
            const lower_depth_m = geothermal.layer_bottom_depth_m[layer];
            const source_depth_m = @max(
                geothermal.minimum_source_depth_m,
                lower_depth_m + geothermal.source_depth_below_profile_m,
            );
            const deep_temperature_k =
                geothermal.mean_annual_temperature_k_by_cell[horizontal_cell] +
                geothermal.geothermal_flux_megajoules_per_m2_h * source_depth_m /
                    geothermal.conductivity_m_megajoules_per_h_k;
            const outward_heat_megajoules = try water_boundary.geothermalHeatFluxMj(
                accepted_temperature_k[layer],
                deep_temperature_k,
                geothermal.conductivity_m_megajoules_per_h_k,
                source_depth_m,
                lower_depth_m,
                geothermal.lower_face_area_m2[layer],
                properties.time_step_hours,
            );
            try accumulateSignedBoundaryHeat(&result, -outward_heat_megajoules);
            if (cell_output) |output|
                try accumulateSignedCellBoundaryHeat(output, horizontal_cell, -outward_heat_megajoules);
            if (layer_output) |output|
                try accumulateSignedLayerBoundaryHeat(output, layer, -outward_heat_megajoules);
        }
    }
    if (properties.dirichlet_thermal_boundaries) |boundaries| {
        for (
            boundaries.cell_index,
            boundaries.temperature_k,
            boundaries.distance_from_cell_center_m,
            boundaries.face_area_m2,
        ) |cell, boundary_temperature_k, distance_m, face_area_m2| {
            if (properties.active_by_layer.len != 0 and
                !properties.active_by_layer[cell]) continue;
            const temperature_difference_k =
                boundary_temperature_k - accepted_temperature_k[cell];
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
            try accumulateSignedBoundaryHeat(&result, inward_heat_megajoules);
            if (cell_output) |output|
                try accumulateSignedCellBoundaryHeat(output, cell / output.soil_layer_capacity, inward_heat_megajoules);
            if (layer_output) |output|
                try accumulateSignedLayerBoundaryHeat(output, cell, inward_heat_megajoules);
        }
    }
    return result;
}

fn accumulateSignedLayerBoundaryHeat(output: []f64, layer: usize, signed_input_megajoules: f64) !void {
    if (layer >= output.len or !std.math.isFinite(signed_input_megajoules))
        return error.InvalidBoundaryHeatLayer;
    output[layer] += signed_input_megajoules;
    if (!std.math.isFinite(output[layer])) return error.NonFiniteAcceptedBoundaryHeat;
}

fn accumulateSignedCellBoundaryHeat(output: CellBoundaryHeat, cell: usize, signed_input_megajoules: f64) !void {
    if (cell >= output.input_megajoules.len or !std.math.isFinite(signed_input_megajoules))
        return error.InvalidBoundaryHeatCell;
    if (signed_input_megajoules >= 0)
        output.input_megajoules[cell] += signed_input_megajoules
    else
        output.output_megajoules[cell] -= signed_input_megajoules;
    if (!std.math.isFinite(output.input_megajoules[cell]) or !std.math.isFinite(output.output_megajoules[cell]))
        return error.NonFiniteAcceptedBoundaryHeat;
}

fn accumulateSignedBoundaryHeat(
    result: *BoundaryHeat,
    signed_input_megajoules: f64,
) !void {
    if (!std.math.isFinite(signed_input_megajoules))
        return error.NonFiniteAcceptedBoundaryHeat;
    if (signed_input_megajoules >= 0)
        result.input_megajoules += signed_input_megajoules
    else
        result.output_megajoules -= signed_input_megajoules;
    if (!std.math.isFinite(result.input_megajoules) or
        !std.math.isFinite(result.output_megajoules))
        return error.NonFiniteAcceptedBoundaryHeat;
}
