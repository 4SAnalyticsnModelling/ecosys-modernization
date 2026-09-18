//! `hourly_science` declarations: state_updates.
//!
//! Split out of `hourly_science.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const ecosys = @import("ecosys_ng");
const biogeochemistry_batches = @import("biogeochemistry_batches.zig");
const diagnostics = @import("diagnostics.zig");
const plant_daily = @import("plant_daily.zig");
const root_processes = @import("root_processes.zig");
const soil_chemistry_convergence = @import("soil_chemistry_convergence.zig");
const surface_litter_convergence = @import("surface_litter_convergence.zig");
const tile_kernels = @import("tile_kernels.zig");

pub fn state_updateHourlySoilSoluteContributionGenerations(
    context: anytype,
) !void {
    const generation = std.math.cast(
        u64,
        context.executed_weather_hours.*,
    ) orelse return error.LateralContributionGenerationExceedsU64;
    const workspace = context.lateral_contribution_workspace.*;
    const buffer_byte_count: usize = 64 * 1024;
    const aqueous_species_count =
        context.micropore_solute_state.species_count;
    const micropore_store = try workspace.store(
        context.allocator,
        workspace.micropore_solute,
        buffer_byte_count,
        generation,
    );
    try ecosys.hourly_lateral_contribution_io.publishTransportGeneration(
        context.allocator,
        micropore_store,
        context.tile_plan.*,
        context.grid.soil_layer_capacity,
        context.soil_transport_faces.micropore_faces,
        aqueous_species_count,
        context.micropore_solute_face_flux_mol,
    );
    try ecosys.hourly_lateral_contribution_io.verifyGenerationConservation(
        context.allocator,
        micropore_store,
        context.tile_plan.*,
        context.grid.soil_layer_capacity,
        aqueous_species_count,
    );
    try ecosys.hourly_lateral_contribution_io.state_updateTransportGeneration(
        context.allocator,
        micropore_store,
        context.tile_plan.*,
        context.grid.soil_layer_capacity,
        aqueous_species_count,
        context.micropore_solute_state.amount_mol,
    );

    const macropore_store = try workspace.store(
        context.allocator,
        workspace.macropore_solute,
        buffer_byte_count,
        generation,
    );
    try ecosys.hourly_lateral_contribution_io.publishTransportGeneration(
        context.allocator,
        macropore_store,
        context.tile_plan.*,
        context.grid.soil_layer_capacity,
        context.soil_transport_faces.macropore_faces,
        aqueous_species_count,
        context.macropore_solute_face_flux_mol,
    );
    try ecosys.hourly_lateral_contribution_io.verifyGenerationConservation(
        context.allocator,
        macropore_store,
        context.tile_plan.*,
        context.grid.soil_layer_capacity,
        aqueous_species_count,
    );
    try ecosys.hourly_lateral_contribution_io.state_updateTransportGeneration(
        context.allocator,
        macropore_store,
        context.tile_plan.*,
        context.grid.soil_layer_capacity,
        aqueous_species_count,
        context.macropore_solute_state.amount_mol,
    );
}

/// Publishes and verifies the already-applied, hourly accumulated face
/// ledgers. Used by dt-coupled substeps, which update authoritative solute
/// inventories after every accepted water-flux snapshot and therefore must not
/// apply the same lateral contribution again at the end of the hour.
pub fn publishHourlySoilSoluteContributionGenerations(context: anytype) !void {
    const generation = std.math.cast(u64, context.executed_weather_hours.*) orelse
        return error.LateralContributionGenerationExceedsU64;
    const workspace = context.lateral_contribution_workspace.*;
    const buffer_byte_count: usize = 64 * 1024;
    const aqueous_species_count = context.micropore_solute_state.species_count;
    if (context.tile_plan.*.tiles.len == 1) {
        try ecosys.hourly_lateral_contribution_io
            .verifySingleTileTransportGenerationInMemory(
            context.allocator,
            context.tile_plan.*,
            context.grid.soil_layer_capacity,
            context.soil_transport_faces.micropore_faces,
            aqueous_species_count,
            context.micropore_solute_face_flux_mol,
        );
        try ecosys.hourly_lateral_contribution_io
            .verifySingleTileTransportGenerationInMemory(
            context.allocator,
            context.tile_plan.*,
            context.grid.soil_layer_capacity,
            context.soil_transport_faces.macropore_faces,
            aqueous_species_count,
            context.macropore_solute_face_flux_mol,
        );
        return;
    }
    const micropore_store = try workspace.store(
        context.allocator,
        workspace.micropore_solute,
        buffer_byte_count,
        generation,
    );
    try ecosys.hourly_lateral_contribution_io.publishTransportGeneration(
        context.allocator,
        micropore_store,
        context.tile_plan.*,
        context.grid.soil_layer_capacity,
        context.soil_transport_faces.micropore_faces,
        aqueous_species_count,
        context.micropore_solute_face_flux_mol,
    );
    try ecosys.hourly_lateral_contribution_io.verifyGenerationConservation(
        context.allocator,
        micropore_store,
        context.tile_plan.*,
        context.grid.soil_layer_capacity,
        aqueous_species_count,
    );
    const macropore_store = try workspace.store(
        context.allocator,
        workspace.macropore_solute,
        buffer_byte_count,
        generation,
    );
    try ecosys.hourly_lateral_contribution_io.publishTransportGeneration(
        context.allocator,
        macropore_store,
        context.tile_plan.*,
        context.grid.soil_layer_capacity,
        context.soil_transport_faces.macropore_faces,
        aqueous_species_count,
        context.macropore_solute_face_flux_mol,
    );
    try ecosys.hourly_lateral_contribution_io.verifyGenerationConservation(
        context.allocator,
        macropore_store,
        context.tile_plan.*,
        context.grid.soil_layer_capacity,
        aqueous_species_count,
    );
}

pub fn state_updateHourlyWaterHeatStateGeneration(
    context: anytype,
    accepted: *const ecosys.soil_water_heat_step.DeferredMappedResult,
) !void {
    const generation = std.math.cast(
        u64,
        context.executed_weather_hours.*,
    ) orelse return error.LateralContributionGenerationExceedsU64;
    const carrier_count =
        ecosys.soil_water_heat_step.deferred_grid_carrier_count;
    const component_count = try std.math.mul(
        usize,
        context.grid.layer_count,
        carrier_count,
    );
    if (accepted.grid_delta_by_layer_carrier.len != component_count)
        return error.DeferredSoilStateDeltaDimensionMismatch;
    const packed_state = try context.allocator.alloc(f64, component_count);
    defer context.allocator.free(packed_state);
    const state_fields: [carrier_count][]f64 = .{
        context.grid.matrix_liquid_water_m3,
        context.grid.macropore_liquid_water_m3,
        context.grid.liquid_water_m3,
        context.grid.matrix_air_volume_m3,
        context.grid.macropore_air_volume_m3,
        context.grid.air_volume_m3,
        context.grid.water_vapor_volume_m3,
        context.grid.matrix_ice_water_m3,
        context.grid.macropore_ice_water_m3,
        context.grid.ice_water_m3,
        context.grid.soil_temperature_k,
        context.grid.matric_potential_megapascal,
    };
    for (0..context.grid.layer_count) |layer| {
        for (0..carrier_count) |carrier|
            packed_state[layer * carrier_count + carrier] =
                state_fields[carrier][layer];
    }
    if (context.tile_plan.*.tiles.len == 1) {
        try ecosys.hourly_lateral_contribution_io
            .state_updateSingleTileFiniteStateDelta(
            context.tile_plan.*,
            context.grid.soil_layer_capacity,
            carrier_count,
            accepted.grid_delta_by_layer_carrier,
            packed_state,
        );
    } else {
        const workspace = context.lateral_contribution_workspace.*;
        const store = try workspace.store(
            context.allocator,
            workspace.water_heat_vapor,
            64 * 1024,
            generation,
        );
        try ecosys.hourly_lateral_contribution_io
            .publishLayerCellDeltaGeneration(
            context.allocator,
            store,
            context.tile_plan.*,
            context.grid.soil_layer_capacity,
            carrier_count,
            accepted.grid_delta_by_layer_carrier,
        );
        try ecosys.hourly_lateral_contribution_io.state_updateFiniteStateGeneration(
            context.allocator,
            store,
            context.tile_plan.*,
            context.grid.soil_layer_capacity,
            carrier_count,
            packed_state,
        );
    }
    for (0..context.grid.layer_count) |layer| {
        for (0..carrier_count) |carrier| {
            const value = packed_state[layer * carrier_count + carrier];
            if (!std.math.isFinite(value) or
                (carrier < 10 and value < 0) or
                (carrier == 10 and value <= 0))
                return error.InvalidStateUpdatetedSoilWaterHeatState;
        }
    }
    for (0..context.grid.layer_count) |layer| {
        for (0..carrier_count) |carrier| {
            const value = packed_state[layer * carrier_count + carrier];
            state_fields[carrier][layer] = value;
        }
    }
    @memcpy(
        context.transport_hydrology.micropore_water_volume_m3,
        context.grid.matrix_liquid_water_m3,
    );
    @memcpy(
        context.transport_hydrology.macropore_water_volume_m3,
        context.grid.macropore_liquid_water_m3,
    );
    @memcpy(
        context.transport_hydrology.matrix_air_volume_m3,
        context.grid.matrix_air_volume_m3,
    );
    @memcpy(
        context.transport_hydrology.macropore_air_volume_m3,
        context.grid.macropore_air_volume_m3,
    );
    @memcpy(
        context.transport_hydrology.air_volume_m3,
        context.grid.air_volume_m3,
    );
    @memcpy(
        context.transport_hydrology.water_vapor_volume_m3,
        context.grid.water_vapor_volume_m3,
    );
}

pub fn state_updateHourlyGasContributionGeneration(
    context: anytype,
    accepted: *const ecosys.gas_transport.State,
) !void {
    const generation = std.math.cast(
        u64,
        context.executed_weather_hours.*,
    ) orelse return error.LateralContributionGenerationExceedsU64;
    const species_count = ecosys.gas_transport.species_count;
    const phase_count: usize = 4;
    const carrier_count = phase_count * species_count;
    const component_count = try std.math.mul(
        usize,
        context.grid.layer_count,
        carrier_count,
    );
    const packed_amount = try context.allocator.alloc(f64, component_count);
    defer context.allocator.free(packed_amount);
    const delta = try context.allocator.alloc(f64, component_count);
    defer context.allocator.free(delta);
    const current = context.gas_transport;
    const current_phases: [phase_count][]f64 = .{
        current.gaseous_mass_g,
        current.dissolved_mass_g,
        current.macropore_dissolved_mass_g,
        current.band_dissolved_mass_g,
    };
    const accepted_phases: [phase_count][]const f64 = .{
        accepted.gaseous_mass_g,
        accepted.dissolved_mass_g,
        accepted.macropore_dissolved_mass_g,
        accepted.band_dissolved_mass_g,
    };
    for (0..context.grid.layer_count) |layer| {
        for (0..phase_count) |phase| {
            for (0..species_count) |species| {
                const phase_component = layer * species_count + species;
                const packed_component =
                    layer * carrier_count + phase * species_count + species;
                packed_amount[packed_component] =
                    current_phases[phase][phase_component];
                delta[packed_component] =
                    accepted_phases[phase][phase_component] -
                    current_phases[phase][phase_component];
                if (!std.math.isFinite(delta[packed_component]))
                    return error.NonFiniteAcceptedGasDelta;
            }
        }
    }
    if (context.tile_plan.*.tiles.len == 1) {
        try ecosys.hourly_lateral_contribution_io
            .state_updateSingleTileTransportDelta(
            context.tile_plan.*,
            context.grid.soil_layer_capacity,
            carrier_count,
            delta,
            packed_amount,
        );
    } else {
        const workspace = context.lateral_contribution_workspace.*;
        const store = try workspace.store(
            context.allocator,
            workspace.gas,
            64 * 1024,
            generation,
        );
        try ecosys.hourly_lateral_contribution_io
            .publishLayerCellDeltaGeneration(
            context.allocator,
            store,
            context.tile_plan.*,
            context.grid.soil_layer_capacity,
            carrier_count,
            delta,
        );
        try ecosys.hourly_lateral_contribution_io.state_updateTransportGeneration(
            context.allocator,
            store,
            context.tile_plan.*,
            context.grid.soil_layer_capacity,
            carrier_count,
            packed_amount,
        );
    }
    for (0..context.grid.layer_count) |layer| {
        for (0..phase_count) |phase| {
            for (0..species_count) |species| {
                const phase_component = layer * species_count + species;
                const packed_component =
                    layer * carrier_count + phase * species_count + species;
                if (!std.math.isFinite(packed_amount[packed_component]) or
                    packed_amount[packed_component] < 0)
                    return error.InvalidStateUpdatetedGasInventory;
                current_phases[phase][phase_component] =
                    packed_amount[packed_component];
            }
        }
    }
}

/// Publishes the complete accepted gas delta after substeps have already
/// updated authoritative gas inventories. It intentionally does not apply the
/// generation again.
pub fn publishHourlyGasContributionGenerationAlreadyApplied(
    context: anytype,
    initial: *const ecosys.gas_transport.State,
) !void {
    const generation = std.math.cast(u64, context.executed_weather_hours.*) orelse
        return error.LateralContributionGenerationExceedsU64;
    const species_count = ecosys.gas_transport.species_count;
    const phase_count: usize = 4;
    const carrier_count = phase_count * species_count;
    const component_count = try std.math.mul(
        usize,
        context.grid.layer_count,
        carrier_count,
    );
    const delta = try context.allocator.alloc(f64, component_count);
    defer context.allocator.free(delta);
    const current_phases: [phase_count][]const f64 = .{
        context.gas_transport.gaseous_mass_g,
        context.gas_transport.dissolved_mass_g,
        context.gas_transport.macropore_dissolved_mass_g,
        context.gas_transport.band_dissolved_mass_g,
    };
    const initial_phases: [phase_count][]const f64 = .{
        initial.gaseous_mass_g,
        initial.dissolved_mass_g,
        initial.macropore_dissolved_mass_g,
        initial.band_dissolved_mass_g,
    };
    for (0..context.grid.layer_count) |layer| {
        for (0..phase_count) |phase| {
            for (0..species_count) |species| {
                const phase_component = layer * species_count + species;
                const packed_component = layer * carrier_count + phase * species_count + species;
                const value = current_phases[phase][phase_component] -
                    initial_phases[phase][phase_component];
                if (!std.math.isFinite(value)) return error.NonFiniteAcceptedGasDelta;
                delta[packed_component] = value;
            }
        }
    }
    if (context.tile_plan.*.tiles.len == 1) return;
    const workspace = context.lateral_contribution_workspace.*;
    const store = try workspace.store(
        context.allocator,
        workspace.gas,
        64 * 1024,
        generation,
    );
    try ecosys.hourly_lateral_contribution_io.publishLayerCellDeltaGeneration(
        context.allocator,
        store,
        context.tile_plan.*,
        context.grid.soil_layer_capacity,
        carrier_count,
        delta,
    );
}
