const std = @import("std");
const audit = @import("mass_balance_audit.zig");
const inventory = @import("landscape_mass_inventory.zig");
const boundary = @import("landscape_boundary_balance.zig");
const grid_module = @import("../state/grid.zig");
const snow_module = @import("../soil/solute/snow_solute_transport.zig");
const thermal_module = @import("../soil/heat/thermal.zig");
const soil_properties_module = @import("../soil/water/solver_properties.zig");
const gas_module = @import("../soil/gas/transport.zig");
const organic_module = @import("../soil/organic/initialization.zig");
const organic_transport_module = @import("../soil/organic/transport.zig");
const mineral_nitrogen_module = @import("../soil/biogeochemistry/mineral_nitrogen_transport.zig");
const chemistry_module = @import("../soil/solute/chemistry_state.zig");
const nitrogen_fertilizer_module = @import("../management/fertilizer_nitrogen_inventory.zig");
const mineral_fertilizer_module = @import("../management/mineral_fertilizer_inventory.zig");
const solute_module = @import("../soil/solute/transport.zig");
const litter_chemistry_module = @import("../surface/litter_chemistry.zig");
const litter_fertilizer_module = @import("../surface/litter_fertilizer.zig");
const surface_module = @import("../surface/precipitation.zig");
const surface_solute_module = @import("../soil/solute/surface_solute_routing.zig");
const canopy_retention_module = @import("../canopy/energy/precipitation_retention.zig");
const plant_root_module = @import("../plant/root/plant_root_system.zig");
const plant_canopy_module = @import("../canopy/photosynthesis/photosynthesis.zig");
const fire_exchange_module = @import("../soil/biogeochemistry/organic_matter_fire_exchange.zig");
const fertilizer_band_module = @import("../management/fertilizer_band_state.zig");
const suspended_module = @import("../erosion/suspended_constituents.zig");
const plant_litter_salt_ingress_module = @import("../plant/salt/litter_ingress.zig");

pub const Parameters = struct {
    snow_ice_density_megagrams_per_m3: f64,
    /// HEAT-001 resolution A. Latent heat of fusion used to convert the snow
    /// owner's frozen carriers from sensible heat to enthalpy. Authoritative
    /// source is `runscript.snow_latent_heat_of_fusion_megajoules_per_m3`.
    ///
    /// The default exists only because the composition root in
    /// `src/ecosys_ng.zig` is owned by the Integrator lane and cannot be
    /// edited here; see
    /// `docs/binding_requests/heat_001_landscape_enthalpy.md`. It equals the
    /// value every shipped runscript currently carries. Once the binding
    /// request lands the default must be deleted so a runscript that changes
    /// the constant cannot silently disagree with the census.
    snow_latent_heat_of_fusion_megajoules_per_m3: f64,
    snow_solid_heat_capacity_megajoules_per_m3_k: f64,
    /// As above, for the soil matrix and macropore ice carriers.
    /// Authoritative source is
    /// `runscript.soil_phase_heat_parameters.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3`.
    soil_latent_heat_of_fusion_megajoules_per_m3: f64,
    carbon_g_per_mol: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    snow_ion_molar_mass_g_per_mol: @import("../soil/water/snow_surface_discharge.zig").IonMolarMassesGPerMol,
    surface_physical: inventory.SurfacePhysicalParameters,
};

/// All authoritative owners needed by the all-storage conservation equations.
/// `soil_mass_megagrams_scratch` is caller-owned runtime memory so reconstruction
/// performs no allocation and remains suitable at every daily audit boundary.
pub const Inputs = struct {
    grid: *const grid_module.GridState,
    plants: *const grid_module.PlantState,
    plant_canopy: ?*const plant_canopy_module.State = null,
    snow: *const snow_module.State,
    soil_thermal: *const thermal_module.State,
    soil_properties: *const soil_properties_module.State,
    soil_gas: *const gas_module.State,
    root_gas: ?*const plant_root_module.State,
    soil_organic: *const organic_module.State,
    soil_organic_transport: *const organic_transport_module.State,
    surface_organic: *const organic_module.State,
    surface_fire_exchange: *const fire_exchange_module.State,
    mineral_nitrogen: *const mineral_nitrogen_module.State,
    fertilizer_band: *const fertilizer_band_module.State,
    soil_chemistry: *const chemistry_module.State,
    nitrogen_fertilizer: *const nitrogen_fertilizer_module.State,
    mineral_fertilizer: *const mineral_fertilizer_module.State,
    suspended_constituents: *const suspended_module.State,
    plant_litter_salt_ingress: *const plant_litter_salt_ingress_module.State,
    micropore_solutes: *const solute_module.State,
    macropore_solutes: *const solute_module.State,
    surface_chemistry: *const litter_chemistry_module.State,
    surface_solutes: *const surface_solute_module.State,
    surface_fertilizer: *const litter_fertilizer_module.State,
    surface_denitrification_nitrite_g_n: []const f64,
    surface: *const surface_module.RuntimeState,
    surface_ice_water_equivalent_m3: []const f64,
    surface_gas: *const gas_module.State,
    surface_litter_dry_mass_megagrams: []const f64,
    canopy_retention: ?*const canopy_retention_module.State,
    cell_area_m2: []const f64,
    soil_mass_megagrams_scratch: []f64,
    parameters: Parameters,
};

/// Reconstructs one complete, finite EXEC snapshot without mutating any
/// scientific owner. Boundary history is published only after all storage
/// contributors have validated, preventing a partially assembled audit.
pub fn reconstruct(
    inputs: Inputs,
    boundary_ledger: *const boundary.State,
) !audit.Totals {
    try validateDimensions(inputs);
    var storage: inventory.Storage = .{};
    try storage.add(try inventory.aggregateSnowEnthalpy(
        inputs.snow,
        inputs.parameters.snow_ice_density_megagrams_per_m3,
        inputs.parameters.snow_latent_heat_of_fusion_megajoules_per_m3,
        inputs.parameters.snow_solid_heat_capacity_megajoules_per_m3_k,
        // HEAT-001 second layer. The snow census re-bases its frozen carriers
        // onto the same ice-branch enthalpy definition the soil and surface
        // carriers use, so it needs both heat capacities. They come from the
        // same authoritative struct the soil aggregator reads below, which is
        // what keeps snow, surface, and soil on one definition.
        inputs.parameters.surface_physical.liquid_water_heat_capacity_megajoules_per_m3_k,
        inputs.parameters.surface_physical.ice_heat_capacity_megajoules_per_m3_k,
        inputs.parameters.surface_physical.pure_water_melting_temperature_k,
        .{
            .nitrogen = inputs.parameters.nitrogen_g_per_mol,
            .phosphorus = inputs.parameters.phosphorus_g_per_mol,
            .ions = inputs.parameters.snow_ion_molar_mass_g_per_mol,
        },
    ));
    try storage.add(try inventory.aggregateSoilPhysicalAndGas(
        inputs.grid,
        inputs.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k,
        inputs.soil_thermal.layer_volume_m3,
        inputs.parameters.surface_physical.liquid_water_heat_capacity_megajoules_per_m3_k,
        inputs.parameters.surface_physical.ice_heat_capacity_megajoules_per_m3_k,
        inputs.parameters.surface_physical.ice_density_megagrams_per_m3,
        inputs.parameters.soil_latent_heat_of_fusion_megajoules_per_m3,
        inputs.parameters.surface_physical.pure_water_melting_temperature_k,
        inputs.soil_gas,
    ));
    try storage.add(try inventory.aggregateSoilMineralTexture(inputs.grid, inputs.soil_properties));
    try storage.add(try inventory.aggregateSuspendedConstituents(
        inputs.suspended_constituents,
        inputs.soil_organic,
        inputs.parameters.carbon_g_per_mol,
        inputs.parameters.nitrogen_g_per_mol,
        inputs.parameters.phosphorus_g_per_mol,
    ));
    if (inputs.root_gas) |root_gas|
        try storage.add(try inventory.aggregateRootGas(root_gas));
    if (inputs.plant_canopy) |canopy| {
        const roots = inputs.root_gas orelse return error.PlantInventoryRequiresRootState;
        try storage.add(try inventory.aggregatePlantCarbonNitrogenPhosphorus(canopy, roots));
    }
    try storage.add(try inventory.aggregateSurfaceOrganic(
        inputs.surface_organic,
    ));
    try storage.add(try inventory.aggregatePendingSurfaceFire(
        inputs.surface_fire_exchange,
        inputs.parameters.nitrogen_g_per_mol,
        inputs.parameters.phosphorus_g_per_mol,
    ));
    try storage.add(try inventory.aggregateSoilOrganic(
        inputs.soil_organic,
        inputs.grid,
    ));
    try storage.add(try inventory.aggregateSoilOrganicTransportMacropore(
        inputs.soil_organic_transport,
        inputs.grid,
    ));
    try fillSoilMass(inputs);
    try storage.add(try inventory.aggregateProfileMineralNitrogen(
        inputs.grid,
        inputs.mineral_nitrogen,
        inputs.soil_chemistry,
        inputs.nitrogen_fertilizer,
        inputs.soil_mass_megagrams_scratch,
        inputs.fertilizer_band,
        inputs.parameters.nitrogen_g_per_mol,
    ));
    try storage.add(try inventory.aggregateProfilePhosphorusAndIons(
        inputs.grid,
        inputs.micropore_solutes,
        inputs.macropore_solutes,
        inputs.soil_chemistry,
        inputs.mineral_fertilizer,
        inputs.grid.matrix_liquid_water_m3,
        inputs.soil_mass_megagrams_scratch,
        inputs.fertilizer_band,
        inputs.parameters.carbon_g_per_mol,
        inputs.parameters.phosphorus_g_per_mol,
        inputs.cell_area_m2,
    ));
    try storage.add(try inventory.aggregatePendingSurfaceMinerals(
        inputs.mineral_fertilizer,
        inputs.parameters.carbon_g_per_mol,
        inputs.parameters.phosphorus_g_per_mol,
    ));
    try storage.add(try inventory.aggregatePendingPlantLitterSalts(
        inputs.plant_litter_salt_ingress,
    ));
    try storage.add(try inventory.aggregateSurfaceChemistry(
        inputs.surface_chemistry,
        inputs.surface_fertilizer,
        inputs.surface_denitrification_nitrite_g_n,
        inputs.surface.litter_water_m3,
        inputs.surface_litter_dry_mass_megagrams,
        inputs.parameters.carbon_g_per_mol,
        inputs.parameters.nitrogen_g_per_mol,
        inputs.parameters.phosphorus_g_per_mol,
    ));
    try storage.add(try inventory.aggregateSurfaceTransportComplexes(
        inputs.surface_solutes,
        inputs.parameters.carbon_g_per_mol,
        inputs.parameters.phosphorus_g_per_mol,
    ));
    try storage.add(try inventory.aggregateSurfacePhysicalAndGas(
        inputs.surface,
        inputs.surface_ice_water_equivalent_m3,
        inputs.grid,
        inputs.surface_gas,
        inputs.surface_organic,
        inputs.parameters.surface_physical,
    ));
    if (inputs.canopy_retention) |retention|
        try storage.add(try inventory.aggregateCanopyWaterAndHeat(
            inputs.plants,
            retention,
            inputs.cell_area_m2,
        ));

    var totals = std.mem.zeroes(audit.Totals);
    for (inputs.cell_area_m2) |area_m2| {
        if (!std.math.isFinite(area_m2) or area_m2 <= 0)
            return error.InvalidLandscapeCellArea;
        totals.landscape_area_m2 += area_m2;
        if (!std.math.isFinite(totals.landscape_area_m2))
            return error.LandscapeAreaOverflow;
    }
    try inventory.publishStorage(&totals, storage);
    try boundary_ledger.publish(&totals);
    std.log.debug("heat balance instrument: storage={e} cumulative_in={e} cumulative_out={e} cumulative_internal_production={e} cumulative_internal_consumption={e} balance={e}", .{
        totals.heat_storage_megajoules,
        totals.cumulative_heat_input_megajoules,
        totals.cumulative_heat_output_megajoules,
        totals.cumulative_internal_heat_production_megajoules,
        totals.cumulative_internal_heat_consumption_megajoules,
        totals.heat_storage_megajoules - totals.cumulative_heat_input_megajoules +
            totals.cumulative_heat_output_megajoules -
            totals.cumulative_internal_heat_production_megajoules +
            totals.cumulative_internal_heat_consumption_megajoules,
    });
    _ = try audit.balance(totals);
    return totals;
}

/// Reconstructs the same authoritative storage census before any horizontal
/// reduction. `storage_by_cell` is caller-owned so an hourly acceptance path
/// can retain its pre-hour snapshot without allocator or ledger side effects.
/// Every contributor delegates to the same range implementation as the
/// landscape aggregators above; formulas therefore cannot drift by scope.
pub fn reconstructCells(
    inputs: Inputs,
    storage_by_cell: []inventory.Storage,
) !void {
    if (storage_by_cell.len != inputs.grid.cell_count)
        return error.LandscapeCellStorageDimensionMismatch;
    try validateDimensions(inputs);
    if (inputs.root_gas) |root_gas| {
        const expected_plants = try std.math.mul(usize, inputs.grid.cell_count, inputs.plants.species_count);
        if (root_gas.plant_count != expected_plants)
            return error.RootGasInventoryPlantMappingMismatch;
    }
    try fillSoilMass(inputs);

    for (storage_by_cell, 0..) |*storage, cell| {
        var next: inventory.Storage = .{};
        try next.add(try inventory.aggregateSnowEnthalpyCell(
            inputs.snow,
            inputs.parameters.snow_ice_density_megagrams_per_m3,
            inputs.parameters.snow_latent_heat_of_fusion_megajoules_per_m3,
            inputs.parameters.snow_solid_heat_capacity_megajoules_per_m3_k,
            inputs.parameters.surface_physical.liquid_water_heat_capacity_megajoules_per_m3_k,
            inputs.parameters.surface_physical.ice_heat_capacity_megajoules_per_m3_k,
            inputs.parameters.surface_physical.pure_water_melting_temperature_k,
            .{
                .nitrogen = inputs.parameters.nitrogen_g_per_mol,
                .phosphorus = inputs.parameters.phosphorus_g_per_mol,
                .ions = inputs.parameters.snow_ion_molar_mass_g_per_mol,
            },
            cell,
        ));
        try next.add(try inventory.aggregateSoilPhysicalAndGasCell(
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
        ));
        try next.add(try inventory.aggregateSoilMineralTextureCell(inputs.grid, inputs.soil_properties, cell));
        try next.add(try inventory.aggregateSuspendedConstituentsCell(
            inputs.suspended_constituents,
            inputs.soil_organic,
            inputs.parameters.carbon_g_per_mol,
            inputs.parameters.nitrogen_g_per_mol,
            inputs.parameters.phosphorus_g_per_mol,
            cell,
        ));
        if (inputs.root_gas) |root_gas|
            try next.add(try inventory.aggregateRootGasCell(root_gas, inputs.plants.species_count, cell));
        if (inputs.plant_canopy) |canopy| {
            const roots = inputs.root_gas orelse return error.PlantInventoryRequiresRootState;
            try next.add(try inventory.aggregatePlantCarbonNitrogenPhosphorusCell(canopy, roots, cell));
        }
        try next.add(try inventory.aggregateSurfaceOrganicCell(inputs.surface_organic, cell));
        try next.add(try inventory.aggregatePendingSurfaceFireCell(
            inputs.surface_fire_exchange,
            inputs.parameters.nitrogen_g_per_mol,
            inputs.parameters.phosphorus_g_per_mol,
            cell,
        ));
        try next.add(try inventory.aggregateSoilOrganicCell(inputs.soil_organic, inputs.grid, cell));
        try next.add(try inventory.aggregateSoilOrganicTransportMacroporeCell(inputs.soil_organic_transport, inputs.grid, cell));
        try next.add(try inventory.aggregateProfileMineralNitrogenCell(
            inputs.grid,
            inputs.mineral_nitrogen,
            inputs.soil_chemistry,
            inputs.nitrogen_fertilizer,
            inputs.soil_mass_megagrams_scratch,
            inputs.fertilizer_band,
            inputs.parameters.nitrogen_g_per_mol,
            cell,
        ));
        try next.add(try inventory.aggregateProfilePhosphorusAndIonsCell(
            inputs.grid,
            inputs.micropore_solutes,
            inputs.macropore_solutes,
            inputs.soil_chemistry,
            inputs.mineral_fertilizer,
            inputs.grid.matrix_liquid_water_m3,
            inputs.soil_mass_megagrams_scratch,
            inputs.fertilizer_band,
            inputs.parameters.carbon_g_per_mol,
            inputs.parameters.phosphorus_g_per_mol,
            inputs.cell_area_m2,
            cell,
        ));
        try next.add(try inventory.aggregatePendingSurfaceMineralsCell(
            inputs.mineral_fertilizer,
            inputs.parameters.carbon_g_per_mol,
            inputs.parameters.phosphorus_g_per_mol,
            cell,
        ));
        try next.add(try inventory.aggregatePendingPlantLitterSaltsCell(
            inputs.plant_litter_salt_ingress,
            cell,
        ));
        try next.add(try inventory.aggregateSurfaceChemistryCell(
            inputs.surface_chemistry,
            inputs.surface_fertilizer,
            inputs.surface_denitrification_nitrite_g_n,
            inputs.surface.litter_water_m3,
            inputs.surface_litter_dry_mass_megagrams,
            inputs.parameters.carbon_g_per_mol,
            inputs.parameters.nitrogen_g_per_mol,
            inputs.parameters.phosphorus_g_per_mol,
            cell,
        ));
        try next.add(try inventory.aggregateSurfaceTransportComplexesCell(
            inputs.surface_solutes,
            inputs.parameters.carbon_g_per_mol,
            inputs.parameters.phosphorus_g_per_mol,
            cell,
        ));
        try next.add(try inventory.aggregateSurfacePhysicalAndGasCell(
            inputs.surface,
            inputs.surface_ice_water_equivalent_m3,
            inputs.grid,
            inputs.surface_gas,
            inputs.surface_organic,
            inputs.parameters.surface_physical,
            cell,
        ));
        if (inputs.canopy_retention) |retention|
            try next.add(try inventory.aggregateCanopyWaterAndHeatCell(inputs.plants, retention, inputs.cell_area_m2, cell));
        try next.validate();
        storage.* = next;
    }
}

fn fillSoilMass(inputs: Inputs) !void {
    try deriveSoilMass(
        inputs.soil_properties.matrix_bulk_volume_m3,
        inputs.soil_properties.bulk_density_megagrams_per_m3,
        inputs.soil_mass_megagrams_scratch,
    );
}

pub fn deriveSoilMass(
    matrix_bulk_volume_m3: []const f64,
    bulk_density_megagrams_per_m3: []const f64,
    soil_mass_megagrams: []f64,
) !void {
    if (matrix_bulk_volume_m3.len == 0 or
        bulk_density_megagrams_per_m3.len != matrix_bulk_volume_m3.len or
        soil_mass_megagrams.len != matrix_bulk_volume_m3.len)
        return error.RuntimeSoilMassDimensionMismatch;
    for (matrix_bulk_volume_m3, bulk_density_megagrams_per_m3) |volume_m3, density_megagrams_per_m3| {
        if (!std.math.isFinite(volume_m3) or volume_m3 < 0 or
            !std.math.isFinite(density_megagrams_per_m3) or density_megagrams_per_m3 < 0)
            return error.InvalidRuntimeSoilMassInput;
        const mass_megagrams = volume_m3 * density_megagrams_per_m3;
        if (!std.math.isFinite(mass_megagrams))
            return error.RuntimeSoilMassOverflow;
    }
    for (
        matrix_bulk_volume_m3,
        bulk_density_megagrams_per_m3,
        soil_mass_megagrams,
    ) |volume_m3, density_megagrams_per_m3, *mass_megagrams| {
        mass_megagrams.* = volume_m3 * density_megagrams_per_m3;
    }
}

fn validateDimensions(inputs: Inputs) !void {
    const layers = inputs.grid.layer_count;
    const cells = inputs.grid.cell_count;
    if (layers == 0 or cells == 0 or
        inputs.fertilizer_band.cell_count != cells or
        inputs.fertilizer_band.layer_capacity != inputs.grid.soil_layer_capacity or
        inputs.soil_thermal.total_heat_capacity_megajoules_per_m3_k.len != layers or
        inputs.soil_thermal.layer_volume_m3.len != layers or
        inputs.soil_properties.matrix_bulk_volume_m3.len != layers or
        inputs.soil_properties.bulk_density_megagrams_per_m3.len != layers or
        inputs.soil_properties.sand_mass_megagrams.len != layers or
        inputs.soil_properties.silt_mass_megagrams.len != layers or
        inputs.soil_properties.clay_mass_megagrams.len != layers or
        inputs.soil_properties.rock_fraction.len != layers or
        inputs.suspended_constituents.cell_count != cells or
        inputs.plant_litter_salt_ingress.cell_count != cells or
        inputs.plant_litter_salt_ingress.soil_layer_capacity != inputs.grid.soil_layer_capacity or
        inputs.soil_mass_megagrams_scratch.len != layers or
        inputs.surface_ice_water_equivalent_m3.len != cells or
        inputs.surface_litter_dry_mass_megagrams.len != cells or
        inputs.surface_fire_exchange.layer_count != cells or
        inputs.surface_solutes.carrier_volume_m3.len != cells or
        inputs.cell_area_m2.len != cells)
        return error.LandscapeMassBalanceRuntimeDimensionMismatch;
}

test "runtime soil mass derivation is explicit and rejects late invalid input" {
    var scratch = [_]f64{ 9, 9 };
    try std.testing.expectError(
        error.InvalidRuntimeSoilMassInput,
        deriveSoilMass(
            &.{ 2, 3 },
            &.{ 1.25, std.math.nan(f64) },
            &scratch,
        ),
    );
    try std.testing.expectEqualSlices(f64, &.{ 9, 9 }, &scratch);
    try deriveSoilMass(&.{ 2, 3 }, &.{ 1.25, 1.5 }, &scratch);
    try std.testing.expectEqualSlices(f64, &.{ 2.5, 4.5 }, &scratch);
}

test "per-cell reconstruction validates output extent before touching scientific owners" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 2 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var plants: grid_module.PlantState = undefined;
    var snow: snow_module.State = undefined;
    var thermal: thermal_module.State = undefined;
    var total_heat_capacity = [_]f64{0};
    var layer_volume = [_]f64{1};
    thermal.total_heat_capacity_megajoules_per_m3_k = &total_heat_capacity;
    thermal.layer_volume_m3 = &layer_volume;
    var properties: soil_properties_module.State = undefined;
    var matrix_bulk_volume = [_]f64{1};
    var bulk_density = [_]f64{1};
    properties.matrix_bulk_volume_m3 = &matrix_bulk_volume;
    properties.bulk_density_megagrams_per_m3 = &bulk_density;
    var soil_gas: gas_module.State = undefined;
    var soil_organic: organic_module.State = undefined;
    var organic_transport: organic_transport_module.State = undefined;
    var surface_organic: organic_module.State = undefined;
    var surface_fire_exchange: fire_exchange_module.State = undefined;
    var mineral_nitrogen: mineral_nitrogen_module.State = undefined;
    var fertilizer_band: fertilizer_band_module.State = undefined;
    var chemistry: chemistry_module.State = undefined;
    var nitrogen_fertilizer: nitrogen_fertilizer_module.State = undefined;
    var mineral_fertilizer: mineral_fertilizer_module.State = undefined;
    var suspended_constituents: suspended_module.State = undefined;
    var plant_litter_salt_ingress: plant_litter_salt_ingress_module.State = undefined;
    var micropore: solute_module.State = undefined;
    var macropore: solute_module.State = undefined;
    var surface_chemistry: litter_chemistry_module.State = undefined;
    var surface_solutes = try surface_solute_module.State.init(
        std.testing.allocator,
        1,
        1,
        @import("../soil/solute/transport_species.zig").AqueousSpecies.count,
    );
    defer surface_solutes.deinit();
    var surface_fertilizer: litter_fertilizer_module.State = undefined;
    var surface: surface_module.RuntimeState = undefined;
    var surface_gas: gas_module.State = undefined;
    var soil_mass = [_]f64{0};
    const inputs: Inputs = .{
        .grid = &grid,
        .plants = &plants,
        .snow = &snow,
        .soil_thermal = &thermal,
        .soil_properties = &properties,
        .soil_gas = &soil_gas,
        .root_gas = null,
        .soil_organic = &soil_organic,
        .soil_organic_transport = &organic_transport,
        .surface_organic = &surface_organic,
        .surface_fire_exchange = &surface_fire_exchange,
        .mineral_nitrogen = &mineral_nitrogen,
        .fertilizer_band = &fertilizer_band,
        .soil_chemistry = &chemistry,
        .nitrogen_fertilizer = &nitrogen_fertilizer,
        .mineral_fertilizer = &mineral_fertilizer,
        .suspended_constituents = &suspended_constituents,
        .plant_litter_salt_ingress = &plant_litter_salt_ingress,
        .micropore_solutes = &micropore,
        .macropore_solutes = &macropore,
        .surface_chemistry = &surface_chemistry,
        .surface_solutes = &surface_solutes,
        .surface_fertilizer = &surface_fertilizer,
        .surface_denitrification_nitrite_g_n = &.{0},
        .surface = &surface,
        .surface_ice_water_equivalent_m3 = &.{0},
        .surface_gas = &surface_gas,
        .surface_litter_dry_mass_megagrams = &.{0},
        .canopy_retention = null,
        .cell_area_m2 = &.{1},
        .soil_mass_megagrams_scratch = &soil_mass,
        .parameters = .{
            .snow_ice_density_megagrams_per_m3 = 0.92,
            .snow_latent_heat_of_fusion_megajoules_per_m3 = 333,
            .snow_solid_heat_capacity_megajoules_per_m3_k = 2.095,
            .soil_latent_heat_of_fusion_megajoules_per_m3 = 333,
            .carbon_g_per_mol = 12,
            .nitrogen_g_per_mol = 14,
            .phosphorus_g_per_mol = 31,
            .snow_ion_molar_mass_g_per_mol = .{
                .aluminum = 27,
                .iron = 56,
                .calcium = 40,
                .magnesium = 24.3,
                .sodium = 23,
                .potassium = 39.1,
                .sulfur = 32,
                .chloride = 35.5,
            },
            .surface_physical = .{
                .dry_organic_heat_capacity_megajoules_per_g_c_k = 1,
                .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
                .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
                .ice_density_megagrams_per_m3 = 0.92,
                .latent_heat_of_fusion_megajoules_per_m3 = 333,
                .pure_water_melting_temperature_k = 273.15,
                .water_molar_mass_g_per_mol = 18,
                .liquid_water_density_g_per_m3 = 1e6,
            },
        },
    };
    var no_output: [0]inventory.Storage = .{};
    try std.testing.expectError(
        error.LandscapeCellStorageDimensionMismatch,
        reconstructCells(inputs, &no_output),
    );
}
