//! `solver` declarations: residual.
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
const kirchhoff = @import("kirchhoff.zig");
const transport_hydrology = @import("../../transport/hydrology.zig");
const water_boundary = @import("boundary.zig");
const boundary_topology = @import("../profile/boundary_topology.zig");
const group_flux = @import("solver_flux.zig");
const group_hydraulics = @import("solver_hydraulics.zig");
const group_solve = @import("solver_solve.zig");
const group_types = @import("solver_types.zig");

pub fn rememberIteration(current: []const f64, residual: []const f64, previous_state: []f64, previous_residual: []f64, previous_previous_state: []f64, previous_previous_residual: []f64, history_count: *u8) void {
    if (history_count.* > 0) {
        @memcpy(previous_previous_state, previous_state);
        @memcpy(previous_previous_residual, previous_residual);
    }
    @memcpy(previous_state, current);
    @memcpy(previous_residual, residual);
    history_count.* = @min(@as(u8, 2), history_count.* + 1);
}

/// Routes the oracle's vertical freezing displacement before Darcy fluxes are
/// assembled. Faces are stored top-to-bottom, so space opened by a shallower
/// layer's upward transfer is immediately available to receive displacement
/// from the next deeper layer. Every transfer is one donor debit and one
/// recipient credit; the same accepted amount is published for downstream
/// heat and solute transport.
fn applyMechanicalFreezingDisplacement(
    grid: *const grid_module.GridState,
    faces: []const group_types.Face,
    properties: group_types.Properties,
    target: []f64,
    micro_fluxes: []f64,
    macro_fluxes: []f64,
) !void {
    const cells = grid.layer_count;
    for (faces, 0..) |face, face_index| {
        if (!face.active) continue;
        if (face.direction != .vertical) continue;
        const source = face.source_cell;
        const destination = face.destination_cell;

        const matrix_excess = try group_flux.physicalPoreSpaceM3(
            grid.matrix_pore_capacity_m3[destination],
            target[destination],
            grid.matrix_ice_water_m3[destination],
            properties.ice_density_megagrams_per_m3,
        );
        const requested_matrix = try water_flux.mechanicalFreezingDisplacementM3(
            target[destination],
            matrix_excess,
            properties.nonlinear_time_fraction,
        );
        const matrix_flux = group_flux.limitFluxForAssembledTarget(
            requested_matrix,
            target[0..cells],
            source,
            destination,
            try group_flux.physicalLiquidCapacityM3(
                grid.matrix_pore_capacity_m3[source],
                grid.matrix_ice_water_m3[source],
                properties.ice_density_megagrams_per_m3,
            ),
            try group_flux.physicalLiquidCapacityM3(
                grid.matrix_pore_capacity_m3[destination],
                grid.matrix_ice_water_m3[destination],
                properties.ice_density_megagrams_per_m3,
            ),
        );
        group_flux.applyConservativeFlux(target[0..cells], source, destination, matrix_flux);
        micro_fluxes[face_index] += matrix_flux;

        if (grid.macropore_pore_capacity_m3[source] <= 0 or
            grid.macropore_pore_capacity_m3[destination] <= 0)
            continue;
        const macropore_excess = try group_flux.physicalPoreSpaceM3(
            grid.macropore_pore_capacity_m3[destination],
            target[cells + destination],
            grid.macropore_ice_water_m3[destination],
            properties.ice_density_megagrams_per_m3,
        );
        const requested_macropore = try water_flux.mechanicalFreezingDisplacementM3(
            target[cells + destination],
            macropore_excess,
            properties.nonlinear_time_fraction,
        );
        const macropore_flux = group_flux.limitFluxForAssembledTarget(
            requested_macropore,
            target[cells..],
            source,
            destination,
            try group_flux.physicalLiquidCapacityM3(
                grid.macropore_pore_capacity_m3[source],
                grid.macropore_ice_water_m3[source],
                properties.ice_density_megagrams_per_m3,
            ),
            try group_flux.physicalLiquidCapacityM3(
                grid.macropore_pore_capacity_m3[destination],
                grid.macropore_ice_water_m3[destination],
                properties.ice_density_megagrams_per_m3,
            ),
        );
        group_flux.applyConservativeFlux(target[cells..], source, destination, macropore_flux);
        macro_fluxes[face_index] += macropore_flux;
    }
}

pub fn residualAt(grid: *const grid_module.GridState, faces: []const group_types.Face, properties: group_types.Properties, base: []const f64, trial: []const f64, target: []f64, residual: []f64, scratch: []f64, micro_fluxes: []f64, macro_fluxes: []f64) !void {
    if (properties.richards_face_flux_cache) |cache| cache.beginResidual();
    if (properties.artificial_drainage_outflow_m3_per_step) |outflow| {
        if (outflow.len != grid.cell_count) return error.ArtificialDrainageDimensionMismatch;
        @memset(outflow, 0);
    }
    if (properties.boundary_water_exchange_m3_per_step) |exchange| {
        if (exchange.len != grid.cell_count) return error.BoundaryWaterExchangeDimensionMismatch;
        @memset(exchange, 0);
    }
    if (properties.boundary_water_exchange_m3_per_layer_per_step) |exchange| {
        if (exchange.len != grid.layer_count) return error.BoundaryWaterExchangeLayerDimensionMismatch;
        @memset(exchange, 0);
    }
    const cells = grid.layer_count;
    @memcpy(scratch, trial);
    @memcpy(target, base);
    if (properties.matrix_external_source_m3_per_step.len != 0)
        for (
            target[0..cells],
            properties.matrix_external_source_m3_per_step,
            0..,
        ) |*water_m3, source_m3, layer| {
            if (!std.math.isFinite(source_m3) or source_m3 < 0)
                return error.InvalidSoilWaterExternalSource;
            if (properties.active_by_layer.len != 0 and
                !properties.active_by_layer[layer]) continue;
            water_m3.* += source_m3;
            if (!std.math.isFinite(water_m3.*))
                return error.NonFiniteSoilWaterExternalSource;
        };
    @memset(micro_fluxes, 0);
    @memset(macro_fluxes, 0);
    for (0..cells) |cell| {
        // The nonlinear coordinate is conserved water equivalent. HOUR1 may
        // lower a deep layer's rigid pore capacity beneath its accepted water
        // inventory; physical ice expansion creates the same signed demand.
        // The mechanical prepass below is the source-shaped owner of both
        // transfers. Permit a trial no farther outside the water-equivalent
        // bound than the accepted entry state, while still rejecting optimizer
        // excursions that manufacture additional overfill.
        const matrix_entry_ceiling = try group_flux.acceptedEntryLiquidCeilingM3(grid.matrix_pore_capacity_m3[cell], base[cell], grid.matrix_ice_water_m3[cell]);
        const macropore_entry_ceiling = try group_flux.acceptedEntryLiquidCeilingM3(grid.macropore_pore_capacity_m3[cell], base[cells + cell], grid.macropore_ice_water_m3[cell]);
        if (trial[cell] > matrix_entry_ceiling + group_hydraulics.poreCapacityRoundoffToleranceM3(matrix_entry_ceiling) or
            trial[cells + cell] > macropore_entry_ceiling + group_hydraulics.poreCapacityRoundoffToleranceM3(macropore_entry_ceiling)) return error.SoilWaterCandidateExceedsPoreCapacity;
    }
    try applyMechanicalFreezingDisplacement(grid, faces, properties, target, micro_fluxes, macro_fluxes);
    for (faces, 0..) |face, face_index| {
        if (!face.active) continue;
        const source = face.source_cell;
        const destination = face.destination_cell;
        const source_water = scratch[source];
        const destination_water = scratch[destination];
        const calculated_matrix_flux_m3 = cached_matrix: {
            if (properties.richards_face_flux_cache) |cache| {
                if (cache.get(
                    face_index,
                    .matrix,
                    source_water,
                    destination_water,
                )) |cached| break :cached_matrix cached;
            }
            const direction_index: usize = @intFromEnum(face.axis);
            const source_air = try group_flux.derivedPhysicalAirVolumeM3(grid.matrix_pore_capacity_m3[source], source_water, grid.matrix_ice_water_m3[source], properties.ice_density_megagrams_per_m3);
            const destination_air = try group_flux.derivedPhysicalAirVolumeM3(grid.matrix_pore_capacity_m3[destination], destination_water, grid.matrix_ice_water_m3[destination], properties.ice_density_megagrams_per_m3);
            const source_fraction = source_water / properties.matrix_bulk_volume_m3[source];
            const destination_fraction = destination_water / properties.matrix_bulk_volume_m3[destination];
            const source_head_for_face_m = try group_hydraulics.pressureHeadMAtAssumeValid(properties, source, source_fraction);
            const destination_head_for_face_m = try group_hydraulics.pressureHeadMAtAssumeValid(properties, destination, destination_fraction);
            const source_matric = source_head_for_face_m * properties.gravitational_water_potential_mpa_per_m;
            const destination_matric = destination_head_for_face_m * properties.gravitational_water_potential_mpa_per_m;
            const source_total = source_matric + properties.gravitational_potential_megapascal[source] + properties.osmotic_potential_multiplier * properties.osmotic_potential_megapascal[source];
            const destination_total = destination_matric + properties.gravitational_potential_megapascal[destination] + properties.osmotic_potential_multiplier * properties.osmotic_potential_megapascal[destination];
            // PR-KIRCHHOFF-DESIGN: the face conductance is built from each
            // cell's curve averaged over the full matric interval.
            const source_conductivity = try group_hydraulics.intervalAveragedConductivityAtKnownHeadAssumeValid(properties, source, direction_index, source_fraction, source_head_for_face_m, destination_head_for_face_m, grid.matrix_ice_water_m3[source]);
            const destination_conductivity = try group_hydraulics.intervalAveragedConductivityAtKnownHeadAssumeValid(properties, destination, direction_index, destination_fraction, destination_head_for_face_m, source_head_for_face_m, grid.matrix_ice_water_m3[destination]);
            const matrix = try water_flux.calculateMatrixFaceFlux(.{ .direction = face.direction, .source_water_m3 = source_water, .destination_water_m3 = destination_water, .source_air_m3 = source_air, .destination_air_m3 = destination_air, .source_micropore_volume_m3 = properties.matrix_bulk_volume_m3[source], .destination_micropore_volume_m3 = properties.matrix_bulk_volume_m3[destination], .source_water_fraction = source_fraction, .destination_water_fraction = destination_fraction, .source_total_water_potential_megapascal = source_total, .destination_total_water_potential_megapascal = destination_total, .source_hydraulic_conductivity_m2_per_h_megapascal = source_conductivity, .destination_hydraulic_conductivity_m2_per_h_megapascal = destination_conductivity, .source_path_length_m = face.source_path_length_m, .destination_path_length_m = face.destination_path_length_m, .face_area_m2 = face.face_area_m2, .time_fraction = properties.nonlinear_time_fraction });
            if (properties.richards_face_flux_cache) |cache| cache.put(
                face_index,
                .matrix,
                source_water,
                destination_water,
                matrix.limited_water_m3,
            );
            break :cached_matrix matrix.limited_water_m3;
        };
        const matrix_flux_m3 = group_flux.limitFluxForAssembledTarget(
            calculated_matrix_flux_m3,
            target[0..cells],
            source,
            destination,
            try group_flux.physicalLiquidCapacityM3(grid.matrix_pore_capacity_m3[source], grid.matrix_ice_water_m3[source], properties.ice_density_megagrams_per_m3),
            try group_flux.physicalLiquidCapacityM3(grid.matrix_pore_capacity_m3[destination], grid.matrix_ice_water_m3[destination], properties.ice_density_megagrams_per_m3),
        );
        if (properties.richards_face_flux_cache) |cache|
            cache.observeAssembledTargetLimit(calculated_matrix_flux_m3, matrix_flux_m3);
        group_flux.applyConservativeFlux(
            target[0..cells],
            source,
            destination,
            matrix_flux_m3,
        );
        // FLWM is assigned from FLWL=FLQL in WATSUB; FLQ2 is retained by the
        // face kernel for the separate FLWLX unsaturated-water diagnostic.
        micro_fluxes[face_index] += matrix_flux_m3;

        const source_macro = scratch[cells + source];
        const destination_macro = scratch[cells + destination];
        if (grid.macropore_pore_capacity_m3[source] > 0 and grid.macropore_pore_capacity_m3[destination] > 0) {
            const calculated_macro_flux_m3 = cached_macro: {
                if (properties.richards_face_flux_cache) |cache| {
                    if (cache.get(
                        face_index,
                        .macropore,
                        source_macro,
                        destination_macro,
                    )) |cached| break :cached_macro cached;
                }
                const source_macro_air = try group_flux.derivedPhysicalAirVolumeM3(grid.macropore_pore_capacity_m3[source], source_macro, grid.macropore_ice_water_m3[source], properties.ice_density_megagrams_per_m3);
                const destination_macro_air = try group_flux.derivedPhysicalAirVolumeM3(grid.macropore_pore_capacity_m3[destination], destination_macro, grid.macropore_ice_water_m3[destination], properties.ice_density_megagrams_per_m3);
                const source_saturation = source_macro / grid.macropore_pore_capacity_m3[source];
                const destination_saturation = destination_macro / grid.macropore_pore_capacity_m3[destination];
                const source_parameters = properties.macropore_mualem_van_genuchten_parameters[source];
                const destination_parameters = properties.macropore_mualem_van_genuchten_parameters[destination];
                const source_head_m = try source_parameters.pressureHeadAtWaterContent(std.math.clamp(source_saturation, source_parameters.residual_water_content_m3_per_m3, 1));
                const destination_head_m = try destination_parameters.pressureHeadAtWaterContent(std.math.clamp(destination_saturation, destination_parameters.residual_water_content_m3_per_m3, 1));
                // PR-KIRCHHOFF-DESIGN, heterogeneous-interface policy: each
                // side averages its own curve over the interval between its own
                // matric potential and the neighbour's. Passing the neighbour's
                // `psi` (not its `Se`) into this cell's curve is what enforces
                // continuity of potential at the interface, which is the
                // physically correct condition when the two sides have
                // different Mualem-van Genuchten parameters.
                const source_interval_conductivity = if (properties.kirchhoff_cache) |cache|
                    try cache.getOrComputeAssumeValid(source_parameters, source_head_m, destination_head_m)
                else
                    try kirchhoff.intervalAveragedConductivityMPerH(source_parameters, source_head_m, destination_head_m);
                const source_macropore_conductivity = source_interval_conductivity / properties.gravitational_water_potential_mpa_per_m *
                    group_hydraulics.frozenHydraulicImpedance(
                        properties.frozen_hydraulic_impedance_exponent,
                        grid.macropore_ice_water_m3[source] / properties.ice_density_megagrams_per_m3 / grid.macropore_pore_capacity_m3[source],
                        source_parameters,
                    );
                const destination_interval_conductivity = if (properties.kirchhoff_cache) |cache|
                    try cache.getOrComputeAssumeValid(destination_parameters, destination_head_m, source_head_m)
                else
                    try kirchhoff.intervalAveragedConductivityMPerH(destination_parameters, destination_head_m, source_head_m);
                const destination_macropore_conductivity = destination_interval_conductivity / properties.gravitational_water_potential_mpa_per_m *
                    group_hydraulics.frozenHydraulicImpedance(
                        properties.frozen_hydraulic_impedance_exponent,
                        grid.macropore_ice_water_m3[destination] / properties.ice_density_megagrams_per_m3 / grid.macropore_pore_capacity_m3[destination],
                        destination_parameters,
                    );
                const flux = try water_flux.calculateMatrixFaceFlux(.{
                    .direction = face.direction,
                    .source_water_m3 = source_macro,
                    .destination_water_m3 = destination_macro,
                    .source_air_m3 = source_macro_air,
                    .destination_air_m3 = destination_macro_air,
                    .source_micropore_volume_m3 = grid.macropore_pore_capacity_m3[source],
                    .destination_micropore_volume_m3 = grid.macropore_pore_capacity_m3[destination],
                    .source_water_fraction = source_saturation,
                    .destination_water_fraction = destination_saturation,
                    .source_total_water_potential_megapascal = source_head_m * properties.gravitational_water_potential_mpa_per_m + properties.gravitational_potential_megapascal[source],
                    .destination_total_water_potential_megapascal = destination_head_m * properties.gravitational_water_potential_mpa_per_m + properties.gravitational_potential_megapascal[destination],
                    .source_hydraulic_conductivity_m2_per_h_megapascal = source_macropore_conductivity,
                    .destination_hydraulic_conductivity_m2_per_h_megapascal = destination_macropore_conductivity,
                    .source_path_length_m = face.source_path_length_m,
                    .destination_path_length_m = face.destination_path_length_m,
                    .face_area_m2 = face.face_area_m2,
                    .time_fraction = properties.nonlinear_time_fraction,
                });
                if (properties.richards_face_flux_cache) |cache| cache.put(
                    face_index,
                    .macropore,
                    source_macro,
                    destination_macro,
                    flux.limited_water_m3,
                );
                break :cached_macro flux.limited_water_m3;
            };
            const macro_flux_m3 = group_flux.limitFluxForAssembledTarget(
                calculated_macro_flux_m3,
                target[cells..],
                source,
                destination,
                try group_flux.physicalLiquidCapacityM3(grid.macropore_pore_capacity_m3[source], grid.macropore_ice_water_m3[source], properties.ice_density_megagrams_per_m3),
                try group_flux.physicalLiquidCapacityM3(grid.macropore_pore_capacity_m3[destination], grid.macropore_ice_water_m3[destination], properties.ice_density_megagrams_per_m3),
            );
            if (properties.richards_face_flux_cache) |cache|
                cache.observeAssembledTargetLimit(calculated_macro_flux_m3, macro_flux_m3);
            group_flux.applyConservativeFlux(
                target[cells..],
                source,
                destination,
                macro_flux_m3,
            );
            macro_fluxes[face_index] += macro_flux_m3;
        }
    }
    if (properties.dual_domain_exchange_enabled.len != 0) for (0..cells) |cell| {
        if (properties.active_by_layer.len != 0 and
            !properties.active_by_layer[cell]) continue;
        if (!properties.dual_domain_exchange_enabled[cell] or
            grid.macropore_pore_capacity_m3[cell] <= 0)
            continue;
        const matrix_water = scratch[cell];
        const macropore_water = scratch[cells + cell];
        const matrix_air = try group_flux.derivedPhysicalAirVolumeM3(
            grid.matrix_pore_capacity_m3[cell],
            matrix_water,
            grid.matrix_ice_water_m3[cell],
            properties.ice_density_megagrams_per_m3,
        );
        const macropore_air = try group_flux.derivedPhysicalAirVolumeM3(
            grid.macropore_pore_capacity_m3[cell],
            macropore_water,
            grid.macropore_ice_water_m3[cell],
            properties.ice_density_megagrams_per_m3,
        );
        // Potentials are evaluated at the nonlinear trial, while the flux is
        // state_updateted to the hour-start target. Bound transfer by both views so
        // neither the trial path nor the authoritative conservative target
        // can overdraw a donor or overfill a receiver away from the root.
        const assembled_matrix_water = @max(0.0, target[cell]);
        const assembled_macropore_water =
            @max(0.0, target[cells + cell]);
        const assembled_matrix_air = try group_flux.derivedPhysicalAirVolumeM3(
            grid.matrix_pore_capacity_m3[cell],
            assembled_matrix_water,
            grid.matrix_ice_water_m3[cell],
            properties.ice_density_megagrams_per_m3,
        );
        const assembled_macropore_air = try group_flux.derivedPhysicalAirVolumeM3(
            grid.macropore_pore_capacity_m3[cell],
            assembled_macropore_water,
            grid.macropore_ice_water_m3[cell],
            properties.ice_density_megagrams_per_m3,
        );
        const matrix_parameters = properties.mualem_van_genuchten_parameters[cell];
        var exchange_matrix_parameters = matrix_parameters;
        exchange_matrix_parameters.saturated_hydraulic_conductivity_m_per_h *=
            group_hydraulics.frozenHydraulicImpedance(
                properties.frozen_hydraulic_impedance_exponent,
                grid.matrix_ice_water_m3[cell] / properties.ice_density_megagrams_per_m3 /
                    properties.matrix_bulk_volume_m3[cell],
                matrix_parameters,
            );
        const macropore_parameters =
            properties.macropore_mualem_van_genuchten_parameters[cell];
        const matrix_fraction = matrix_water / properties.matrix_bulk_volume_m3[cell];
        const macropore_saturation =
            macropore_water / grid.macropore_pore_capacity_m3[cell];
        const matrix_pressure_head_m = try matrix_parameters.pressureHeadAtWaterContentAssumeValid(
            std.math.clamp(
                matrix_fraction,
                matrix_parameters.residual_water_content_m3_per_m3,
                matrix_parameters.saturated_water_content_m3_per_m3,
            ),
        );
        const macropore_pressure_head_m =
            try macropore_parameters.pressureHeadAtWaterContentAssumeValid(
                std.math.clamp(
                    macropore_saturation,
                    macropore_parameters.residual_water_content_m3_per_m3,
                    macropore_parameters.saturated_water_content_m3_per_m3,
                ),
            );
        const exchange_m3 = try water_flux.calculateDualDomainExchange(.{
            .matrix_parameters = exchange_matrix_parameters,
            .matrix_pressure_head_m = matrix_pressure_head_m,
            .macropore_pressure_head_m = macropore_pressure_head_m,
            .matrix_bulk_volume_m3 = properties.matrix_bulk_volume_m3[cell],
            .characteristic_matrix_length_m = properties.macropore_spacing_m[cell] -
                properties.macropore_radius_m[cell],
            .geometry_factor = properties.dual_domain_geometry_factor,
            .scaling_coefficient = properties.dual_domain_scaling_coefficient,
            .time_fraction = properties.nonlinear_time_fraction,
            .matrix_water_m3 = @min(matrix_water, assembled_matrix_water),
            .matrix_air_m3 = @min(matrix_air, assembled_matrix_air),
            .macropore_water_m3 = @min(macropore_water, assembled_macropore_water),
            .macropore_air_m3 = @min(macropore_air, assembled_macropore_air),
        });
        target[cell] += exchange_m3;
        target[cells + cell] -= exchange_m3;
    };
    // Lower boundaries participate in the same nonlinear residual as internal
    // faces. WATSUB stores an oriented face flux; multiplying by XN converts
    // it to the source-layer storage change (drainage is negative).
    if (properties.boundary_topology) |topology| for (topology.faces) |boundary_face| {
        const layer = boundary_face.layer_index;
        if (properties.active_by_layer.len != 0 and
            !properties.active_by_layer[layer]) continue;
        const matrix_water = scratch[layer];
        const macropore_water = scratch[cells + layer];
        const matrix_fraction = matrix_water / properties.matrix_bulk_volume_m3[layer];
        var matrix_change: f64 = 0;
        var macropore_change: f64 = 0;
        if (boundary_face.is_lower_boundary) {
            if (boundary_face.natural_exchange_fraction == 0) continue;
            const oriented = try water_boundary.freeDrainage(.{ .direction_sign = boundary_face.direction_sign, .slope_sine = 1, .matrix_hydraulic_conductivity_m2_per_h_megapascal = try group_hydraulics.conductivityAt(properties, layer, 2, matrix_fraction, grid.matrix_ice_water_m3[layer]), .macropore_hydraulic_conductivity_m2_per_h_megapascal = properties.boundary_macropore_hydraulic_conductivity_m2_per_h_megapascal[layer] * group_hydraulics.macroporeFrozenHydraulicImpedance(properties, grid, layer), .face_area_m2 = properties.boundary_face_area_m2[layer], .matrix_water_available_m3 = matrix_water, .macropore_water_available_m3 = macropore_water, .recharge_frequency_divisor = 1, .recharge_time_multiplier = boundary_face.natural_exchange_fraction, .time_fraction = properties.nonlinear_time_fraction, .source_temperature_k = grid.soil_temperature_k[layer] });
            matrix_change = boundary_face.direction_sign * oriented.matrix_water_m3;
            macropore_change = boundary_face.direction_sign * oriented.macropore_water_m3;
        } else if (topology.water_table_mode[boundary_face.cell_index] != 0) {
            const axis: usize = if (boundary_face.direction == .east or boundary_face.direction == .west) 0 else 1;
            const thickness_m = properties.vertical_thickness_m[layer];
            const midpoint_m = properties.boundary_layer_midpoint_depth_m[layer];
            const bottom_m = properties.boundary_layer_bottom_depth_m[layer];
            const profile_bottom_m = properties.boundary_layer_bottom_depth_m[boundary_face.cell_index * grid.soil_layer_capacity + grid.active_soil_layer_count[boundary_face.cell_index] - 1];
            const face_area_m2 = properties.boundary_layer_volume_m3[layer] / boundary_face.directional_layer_width_m;
            const matric_megapascal = try group_hydraulics.matricPotentialMpaAtAssumeValid(properties, layer, matrix_fraction);
            const base_fraction = base[layer] / properties.matrix_bulk_volume_m3[layer];
            const base_matric_megapascal = try group_hydraulics.matricPotentialMpaAtAssumeValid(properties, layer, base_fraction);
            const current_layer_discharge_candidate = base_matric_megapascal > grid.matric_potential_megapascal[layer];
            const macro_capacity = grid.macropore_pore_capacity_m3[layer];
            const macropore_physical_ice_m3 = grid.macropore_ice_water_m3[layer] / properties.ice_density_megagrams_per_m3;
            const macro_water_depth_m = if (macro_capacity > 0) bottom_m - (macropore_water + macropore_physical_ice_m3) / macro_capacity * thickness_m else bottom_m;
            const base_macro_water_depth_m = if (macro_capacity > 0) bottom_m - (base[cells + layer] + macropore_physical_ice_m3) / macro_capacity * thickness_m else bottom_m;
            for ([_]bool{ false, true }) |artificial| {
                var matrix_discharge_enabled = current_layer_discharge_candidate;
                if (artificial and topology.water_table_mode[boundary_face.cell_index] < 3) continue;
                const external_depth_m = if (artificial) topology.artificial_water_table_depth_m[boundary_face.cell_index] else topology.natural_water_table_depth_m[boundary_face.cell_index];
                const table_slope = if (artificial)
                    topology.artificial_water_table_surface_slope[boundary_face.cell_index]
                else
                    topology.natural_water_table_surface_slope[boundary_face.cell_index];
                const distance_m = if (artificial) boundary_face.artificial_water_table_distance_m else boundary_face.natural_water_table_distance_m;
                const exchange_fraction = if (artificial) boundary_face.artificial_exchange_fraction else boundary_face.natural_exchange_fraction;
                if (exchange_fraction == 0) continue;
                // `GRID-INV-001`. A face with no stated distance to the
                // external water table has no gradient to compute, so it is
                // not an exchanging face. Previously this value reached the
                // kernel as a frequency divisor and a zero silently meant
                // "divide by one", turning the head difference into the flux.
                if (distance_m <= 0) continue;
                // WATSUB IFLGU/IFLGD require every deeper layer above the
                // corresponding external table to remain wetter than its
                // previous HOUR1 matric state. Freeze this active set from the
                // hour-start state so the implicit residual remains smooth.
                if (matrix_discharge_enabled and midpoint_m < external_depth_m) {
                    const local_layer = layer % grid.soil_layer_capacity;
                    var lower_local = local_layer + 1;
                    while (lower_local < grid.active_soil_layer_count[boundary_face.cell_index]) : (lower_local += 1) {
                        const lower = boundary_face.cell_index * grid.soil_layer_capacity + lower_local;
                        if (properties.boundary_layer_midpoint_depth_m[lower] >= external_depth_m) break;
                        const lower_fraction = base[lower] / properties.matrix_bulk_volume_m3[lower];
                        const lower_matric_megapascal = try group_hydraulics.matricPotentialMpaAtAssumeValid(properties, lower, lower_fraction);
                        if (lower_matric_megapascal <= grid.matric_potential_megapascal[lower] or properties.boundary_layer_midpoint_depth_m[lower] > topology.active_layer_depth_m[boundary_face.cell_index]) {
                            matrix_discharge_enabled = false;
                            break;
                        }
                    }
                }
                const fraction_below = std.math.clamp((bottom_m - external_depth_m) / thickness_m, 0, 1);
                if (midpoint_m < external_depth_m and matrix_discharge_enabled) {
                    const oriented = try water_boundary.matrixDischarge(.{ .direction_sign = boundary_face.direction_sign, .slope_sine = boundary_face.slope_sine, .directional_layer_width_m = boundary_face.directional_layer_width_m, .water_table_slope = table_slope, .matric_potential_megapascal = matric_megapascal, .saturation_water_potential_megapascal = group_hydraulics.saturationMatricPotentialMpa(properties, layer), .layer_midpoint_depth_m = midpoint_m, .external_water_table_depth_m = external_depth_m, .internal_water_table_depth_m = topology.internal_water_table_depth_m[boundary_face.cell_index], .hydraulic_conductivity_m2_per_h_megapascal = try group_hydraulics.conductivityAt(properties, layer, axis, matrix_fraction, grid.matrix_ice_water_m3[layer]), .face_area_m2 = face_area_m2, .external_separation_distance_m = distance_m, .fraction_face_below_water_table = fraction_below, .recharge_frequency_divisor = 0, .recharge_time_multiplier = exchange_fraction, .time_fraction = properties.nonlinear_time_fraction, .source_temperature_k = grid.soil_temperature_k[layer] }, artificial);
                    const accepted_change = group_flux.limitExternalStorageChange(
                        boundary_face.direction_sign * oriented.matrix_water_m3,
                        matrix_water + matrix_change,
                        target[layer] + matrix_change,
                        try group_flux.physicalLiquidCapacityM3(grid.matrix_pore_capacity_m3[layer], grid.matrix_ice_water_m3[layer], properties.ice_density_megagrams_per_m3),
                    );
                    matrix_change += accepted_change;
                    if (artificial) {
                        if (properties.artificial_drainage_outflow_m3_per_step) |outflow|
                            outflow[boundary_face.cell_index] +=
                                @max(0, -accepted_change);
                    }
                } else if (!artificial and !matrix_discharge_enabled and midpoint_m >= external_depth_m and midpoint_m < profile_bottom_m) {
                    // The artificial (tile-drain) table has no reservoir
                    // below it to recharge from: watsub.f's only two blocks
                    // referencing the artificial-table controls (RCHGFA/
                    // RCHGFB, "DISCHARGE ABOVE TILE DRAIN") are strictly
                    // discharge-only (PSISWT/PSISWTH clamped to <= 0). The
                    // "RECHARGE BELOW WATER TABLE" blocks exclusively use the
                    // natural-table controls (RCHGFU/RCHGFT). So when the
                    // artificial table's discharge condition isn't met this
                    // step, the correct behavior is no flux at this face,
                    // not a fabricated inflow.
                    const oriented = try water_boundary.recharge(.{ .direction_sign = boundary_face.direction_sign, .slope_sine = boundary_face.slope_sine, .directional_layer_width_m = boundary_face.directional_layer_width_m, .water_table_slope = table_slope, .matric_potential_megapascal = matric_megapascal, .layer_or_macropore_water_depth_m = midpoint_m, .external_water_table_depth_m = external_depth_m, .hydraulic_conductivity_m2_per_h_megapascal = try group_hydraulics.conductivityAt(properties, layer, axis, properties.retention_curve[layer].porosity_fraction, grid.matrix_ice_water_m3[layer]), .face_area_m2 = face_area_m2, .external_separation_distance_m = distance_m, .fraction_face_below_water_table = fraction_below, .recharge_frequency_divisor = 1, .recharge_time_multiplier = exchange_fraction, .time_fraction = properties.nonlinear_time_fraction, .available_air_volume_m3 = try group_flux.derivedPhysicalAirVolumeM3(grid.matrix_pore_capacity_m3[layer], matrix_water, grid.matrix_ice_water_m3[layer], properties.ice_density_megagrams_per_m3), .source_temperature_k = grid.soil_temperature_k[layer] }, false);
                    matrix_change += group_flux.limitExternalStorageChange(
                        boundary_face.direction_sign * oriented.matrix_water_m3,
                        matrix_water + matrix_change,
                        target[layer] + matrix_change,
                        try group_flux.physicalLiquidCapacityM3(grid.matrix_pore_capacity_m3[layer], grid.matrix_ice_water_m3[layer], properties.ice_density_megagrams_per_m3),
                    );
                }
                if (macro_capacity > 0 and base_macro_water_depth_m < external_depth_m and macropore_water > 0) {
                    // The source bound is VOLWH1*XNPXX plus the signed vertical
                    // FLWHL terms. In the whole-hour implicit group_solve.solve scratch
                    // already contains those vertical terms. It additionally
                    // contains horizontal transfers and earlier boundary-face
                    // withdrawals, which is the conservative generalization
                    // required when the source sub-hour sweep is removed.
                    const oriented = try water_boundary.macroporeDischarge(.{ .direction_sign = boundary_face.direction_sign, .slope_sine = boundary_face.slope_sine, .directional_layer_width_m = boundary_face.directional_layer_width_m, .water_table_slope = table_slope, .macropore_water_depth_m = macro_water_depth_m, .external_water_table_depth_m = external_depth_m, .internal_water_table_depth_m = topology.internal_water_table_depth_m[boundary_face.cell_index], .hydraulic_conductivity_m2_per_h_megapascal = properties.boundary_macropore_hydraulic_conductivity_m2_per_h_megapascal[layer] * group_hydraulics.macroporeFrozenHydraulicImpedance(properties, grid, layer), .face_area_m2 = face_area_m2, .external_separation_distance_m = distance_m, .fraction_face_below_water_table = fraction_below, .recharge_frequency_divisor = 1, .recharge_time_multiplier = exchange_fraction, .time_fraction = properties.nonlinear_time_fraction, .available_macropore_water_m3 = macropore_water, .incoming_vertical_macropore_water_m3 = 0, .outgoing_vertical_macropore_water_m3 = 0, .source_temperature_k = grid.soil_temperature_k[layer] });
                    const accepted_change = group_flux.limitExternalStorageChange(
                        boundary_face.direction_sign * oriented.macropore_water_m3,
                        macropore_water + macropore_change,
                        target[cells + layer] + macropore_change,
                        try group_flux.physicalLiquidCapacityM3(macro_capacity, grid.macropore_ice_water_m3[layer], properties.ice_density_megagrams_per_m3),
                    );
                    macropore_change += accepted_change;
                    if (artificial) {
                        if (properties.artificial_drainage_outflow_m3_per_step) |outflow|
                            outflow[boundary_face.cell_index] +=
                                @max(0, -accepted_change);
                    }
                } else if (!artificial and macro_capacity > 0 and base_macro_water_depth_m >= external_depth_m and midpoint_m < profile_bottom_m) {
                    // Same rationale as the micropore branch above: no
                    // recharge pathway exists below an artificial tile
                    // drain in the Fortran reference.
                    const oriented = try water_boundary.recharge(.{ .direction_sign = boundary_face.direction_sign, .slope_sine = boundary_face.slope_sine, .directional_layer_width_m = boundary_face.directional_layer_width_m, .water_table_slope = table_slope, .matric_potential_megapascal = 0, .layer_or_macropore_water_depth_m = macro_water_depth_m, .external_water_table_depth_m = external_depth_m, .hydraulic_conductivity_m2_per_h_megapascal = properties.boundary_macropore_hydraulic_conductivity_m2_per_h_megapascal[layer] * group_hydraulics.macroporeFrozenHydraulicImpedance(properties, grid, layer), .face_area_m2 = face_area_m2, .external_separation_distance_m = distance_m, .fraction_face_below_water_table = fraction_below, .recharge_frequency_divisor = 1, .recharge_time_multiplier = exchange_fraction, .time_fraction = properties.nonlinear_time_fraction, .available_air_volume_m3 = try group_flux.derivedPhysicalAirVolumeM3(macro_capacity, macropore_water, grid.macropore_ice_water_m3[layer], properties.ice_density_megagrams_per_m3), .source_temperature_k = grid.soil_temperature_k[layer] }, true);
                    macropore_change += group_flux.limitExternalStorageChange(
                        boundary_face.direction_sign * oriented.macropore_water_m3,
                        macropore_water + macropore_change,
                        target[cells + layer] + macropore_change,
                        try group_flux.physicalLiquidCapacityM3(macro_capacity, grid.macropore_ice_water_m3[layer], properties.ice_density_megagrams_per_m3),
                    );
                }
            }
        }
        target[layer] += matrix_change;
        target[cells + layer] += macropore_change;
        scratch[layer] += matrix_change;
        scratch[cells + layer] += macropore_change;
        if (properties.boundary_water_exchange_m3_per_step) |exchange|
            exchange[boundary_face.cell_index] += matrix_change + macropore_change;
        if (properties.boundary_water_exchange_m3_per_layer_per_step) |exchange|
            exchange[layer] += matrix_change + macropore_change;
    };
    for (target, trial, residual) |value, trial_value, *difference| {
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSoilWaterCandidate;
        difference.* = value - trial_value;
    }
}

pub fn addDirection(current: []const f64, direction: []const f64, fraction: f64, output: []f64) !void {
    for (current, direction, output) |value, delta, *candidate| {
        candidate.* = value + fraction * delta;
        if (!std.math.isFinite(candidate.*) or candidate.* < 0) return error.InvalidSoilWaterCandidate;
    }
}

pub fn projectStorageStep(grid: *const grid_module.GridState, current: []const f64, direction: []const f64, fraction: f64, ice_density_megagrams_per_m3: f64, output: []f64) bool {
    const cells = grid.layer_count;
    if (current.len != 2 * cells or direction.len != current.len or output.len != current.len or !std.math.isFinite(fraction)) return false;
    for (current, direction, output, 0..) |value, delta, *candidate, component| {
        const cell = if (component < cells) component else component - cells;
        const capacity = if (component < cells)
            group_flux.physicalLiquidCapacityM3(grid.matrix_pore_capacity_m3[cell], grid.matrix_ice_water_m3[cell], ice_density_megagrams_per_m3) catch return false
        else
            group_flux.physicalLiquidCapacityM3(grid.macropore_pore_capacity_m3[cell], grid.macropore_ice_water_m3[cell], ice_density_megagrams_per_m3) catch return false;
        const unconstrained = value + fraction * delta;
        if (!std.math.isFinite(unconstrained) or !std.math.isFinite(capacity) or capacity < 0 or unconstrained < 0 or unconstrained > capacity) return false;
        candidate.* = unconstrained;
    }
    return true;
}

pub fn scaledNorm(state: []const f64, residual: []const f64, options: group_types.Options) !f64 {
    var maximum: f64 = 0;
    for (state, residual) |value, difference| {
        if (!std.math.isFinite(value) or value < 0 or !std.math.isFinite(difference)) return error.NonFiniteSoilWaterSolverState;
        maximum = @max(maximum, scaledComponentResidual(value, difference, options));
    }
    return maximum;
}

pub fn scaledComponentResidual(state: f64, residual: f64, options: group_types.Options) f64 {
    return @abs(residual) /
        (options.absolute_tolerance_m3 +
            options.relative_tolerance * @abs(state));
}
