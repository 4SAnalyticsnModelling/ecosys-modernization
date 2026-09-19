const inventory = @import("landscape_mass_inventory.zig");
const group_gas = @import("landscape_mass_inventory_gas.zig");
const group_misc = @import("landscape_mass_inventory_misc.zig");
const group_nitrogen = @import("landscape_mass_inventory_nitrogen.zig");
const group_organic = @import("landscape_mass_inventory_organic.zig");
const group_phosphorus = @import("landscape_mass_inventory_phosphorus_ions.zig");
const group_plant = @import("landscape_mass_inventory_plant.zig");
const runtime = @import("landscape_mass_balance_runtime.zig");
const relayering_activity = @import("../soil/profile/relayering_activity.zig");
const relayering = @import("../soil/profile/relayering.zig");
const ice_units = @import("../core/ice_units.zig");

/// Adapter from the complete production mass-inventory binding to REDIST's
/// boundary-local sampler. The same authoritative formulas therefore feed the
/// hourly storage census and the relayering activity; this module introduces
/// no second chemistry/species mapping.
pub const Context = struct {
    inputs: runtime.Inputs,

    pub fn source(self: *Context) relayering_activity.SnapshotSource {
        return .{ .context = self, .capture_fn = captureOpaque };
    }

    /// Rejects a census accidentally wired to a different owner graph. The
    /// activity would otherwise be internally self-consistent while observing
    /// states that REDIST did not mutate.
    pub fn binding(
        self: *Context,
        sidecar: *relayering_activity.Sidecar,
        science: relayering.Context,
    ) !relayering_activity.Binding {
        try validateBinding(self.inputs, science);
        return .{ .sidecar = sidecar, .snapshot_source = self.source() };
    }

    fn captureOpaque(
        raw: *anyopaque,
        cell: usize,
        local_layer: usize,
        live_soil_mass_megagrams: []const f64,
    ) !inventory.Storage {
        const self: *Context = @ptrCast(@alignCast(raw));
        return capture(
            self.inputs,
            cell,
            local_layer,
            live_soil_mass_megagrams,
        );
    }
};

pub fn validateBinding(inputs: runtime.Inputs, science: relayering.Context) !void {
    const properties = science.soil_properties orelse
        return error.RelayeringActivityRequiresSoilProperties;
    const transport = science.transport_owners orelse
        return error.RelayeringActivityRequiresTransportOwners;
    if (inputs.grid != science.grid or
        inputs.soil_thermal != science.soil_thermal or
        inputs.soil_properties != properties or
        inputs.soil_gas != science.gas_transport or
        inputs.soil_organic != science.soil_organic or
        inputs.soil_organic_transport != transport.organic or
        inputs.mineral_nitrogen != transport.mineral_nitrogen or
        inputs.fertilizer_band != (science.fertilizer_band orelse
            return error.RelayeringActivityRequiresFertilizerBand) or
        inputs.soil_chemistry != science.soil_chemistry or
        inputs.nitrogen_fertilizer != science.soil_fertilizer_inventory or
        inputs.mineral_fertilizer != science.mineral_fertilizer_inventory or
        inputs.micropore_solutes != transport.micropore_solute or
        inputs.macropore_solutes != transport.macropore_solute)
        return error.RelayeringActivityOwnerMismatch;
    if (science.plant_roots) |roots| {
        if ((inputs.root_gas orelse return error.RelayeringActivityRootOwnerMismatch) != roots)
            return error.RelayeringActivityRootOwnerMismatch;
    } else if (inputs.root_gas != null) {
        return error.RelayeringActivityRootOwnerMismatch;
    }
    const inventory_ice_heat_capacity = ice_units.heatCapacityPerWaterEquivalentM3K(
        inputs.parameters.surface_physical.ice_heat_capacity_megajoules_per_m3_k,
        inputs.parameters.surface_physical.ice_density_megagrams_per_m3,
    ) catch return error.RelayeringActivityHeatParameterMismatch;
    if (inputs.parameters.surface_physical.liquid_water_heat_capacity_megajoules_per_m3_k !=
        science.water_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k or
        inventory_ice_heat_capacity != science.water_heat_parameters.ice_heat_capacity_megajoules_per_m3_k)
        return error.RelayeringActivityHeatParameterMismatch;
}

/// Reconstruct exactly one soil-layer control volume. `live_soil_mass` is the
/// REDIST source-order carrier: properties do not publish their final geometry
/// carrier until all internal boundaries have completed, so using the ordinary
/// hourly scratch here would mis-scale adsorbed/solid chemistry mid-loop.
pub fn capture(
    inputs: runtime.Inputs,
    cell: usize,
    local_layer: usize,
    live_soil_mass_megagrams: []const f64,
) !inventory.Storage {
    if (cell >= inputs.grid.cell_count or local_layer >= inputs.grid.soil_layer_capacity)
        return error.RelayeringSnapshotLayerOutOfBounds;
    if (live_soil_mass_megagrams.len != inputs.grid.layer_count)
        return error.RelayeringSnapshotSoilMassDimensionMismatch;

    var soil: inventory.Storage = .{};
    try soil.add(try group_gas.aggregateSoilPhysicalAndGasLayer(
        inputs.grid,
        inputs.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k,
        inputs.soil_thermal.layer_volume_m3,
        inputs.parameters.surface_physical.liquid_water_heat_capacity_megajoules_per_m3_k,
        inputs.parameters.surface_physical.ice_heat_capacity_megajoules_per_m3_k,
        inputs.parameters.surface_physical.ice_density_megagrams_per_m3,
        inputs.parameters.soil_latent_heat_of_fusion_megajoules_per_m3,
        inputs.parameters.surface_physical.pure_water_melting_temperature_k,
        inputs.soil_gas,
        cell,
        local_layer,
    ));
    try soil.add(try group_misc.aggregateSoilMineralTextureLayer(
        inputs.grid,
        inputs.soil_properties,
        cell,
        local_layer,
    ));
    try soil.add(try group_organic.aggregateSoilOrganicLayer(
        inputs.soil_organic,
        inputs.grid,
        cell,
        local_layer,
    ));
    try soil.add(try group_organic.aggregateSoilOrganicTransportMacroporeLayer(
        inputs.soil_organic_transport,
        inputs.grid,
        cell,
        local_layer,
    ));
    try soil.add(try group_nitrogen.aggregateProfileMineralNitrogenLayer(
        inputs.grid,
        inputs.mineral_nitrogen,
        inputs.soil_chemistry,
        inputs.nitrogen_fertilizer,
        live_soil_mass_megagrams,
        inputs.fertilizer_band,
        inputs.parameters.nitrogen_g_per_mol,
        cell,
        local_layer,
    ));
    try soil.add(try group_phosphorus.aggregateProfilePhosphorusAndIonsLayer(
        inputs.grid,
        inputs.micropore_solutes,
        inputs.macropore_solutes,
        inputs.soil_chemistry,
        inputs.mineral_fertilizer,
        inputs.grid.matrix_liquid_water_m3,
        live_soil_mass_megagrams,
        inputs.fertilizer_band,
        inputs.parameters.carbon_g_per_mol,
        inputs.parameters.phosphorus_g_per_mol,
        inputs.cell_area_m2,
        cell,
        local_layer,
    ));
    if (inputs.root_gas) |roots|
        try soil.add(try group_gas.aggregateRootGasLayer(
            roots,
            inputs.plants.species_count,
            cell,
            local_layer,
        ));
    if (inputs.plant_canopy) |canopy| {
        const roots = inputs.root_gas orelse return error.PlantInventoryRequiresRootState;
        try soil.add(try group_plant.aggregatePlantRootsLayer(
            canopy,
            roots,
            cell,
            local_layer,
        ));
    }
    try soil.validate();
    return soil;
}

test "relayering snapshot delegates every canonical soil-layer inventory group" {
    const source = @embedFile("relayering_layer_snapshot.zig");
    inline for (.{
        "aggregateSoilPhysicalAndGasLayer(",
        "aggregateSoilMineralTextureLayer(",
        "aggregateSoilOrganicLayer(",
        "aggregateSoilOrganicTransportMacroporeLayer(",
        "aggregateProfileMineralNitrogenLayer(",
        "aggregateProfilePhosphorusAndIonsLayer(",
        "aggregateRootGasLayer(",
        "aggregatePlantRootsLayer(",
        "validateBinding(self.inputs, science)",
    }) |needle|
        try @import("std").testing.expect(@import("std").mem.indexOf(u8, source, needle) != null);
}
