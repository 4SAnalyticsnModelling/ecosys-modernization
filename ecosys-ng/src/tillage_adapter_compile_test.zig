const adapter = @import("redistribution/tillage/runtime_adapter.zig");
const TillageActivity = @import("redistribution/tillage/activity.zig");
const std = @import("std");
const SimulationConfig = @import("core/config.zig").SimulationConfig;
const Grid = @import("state/grid.zig").GridState;
const Geometry = @import("soil/profile/layer_geometry.zig").State;
const Properties = @import("soil/water/solver_properties.zig").State;
const Retention = @import("soil/water/retention.zig");
const Thermal = @import("soil/heat/thermal.zig").State;
const Organic = @import("soil/organic/initialization.zig").State;
const OrganicTransport = @import("soil/organic/transport.zig").State;
const GasModule = @import("soil/gas/transport.zig");
const Gas = GasModule.State;
const Chemistry = @import("soil/solute/chemistry_state.zig").State;
const ChemistryModule = @import("soil/solute/chemistry_state.zig");
const CationExchange = @import("soil/solute/cation_exchange.zig");
const SurfaceChemistry = @import("surface/litter_chemistry.zig").State;
const SurfaceGeometry = @import("surface/litter_geometry_step.zig").State;
const FertilizerBand = @import("management/fertilizer_band_state.zig");
const FertilizerNitrogen = @import("management/fertilizer_nitrogen_inventory.zig").State;
const SurfaceFertilizer = @import("surface/litter_fertilizer.zig").State;
const MineralFertilizer = @import("management/mineral_fertilizer_inventory.zig").State;
const ReactiveNitrogen = @import("soil/nutrients/reactive_nitrogen_state.zig").State;
const SoluteTransport = @import("soil/solute/transport.zig").State;
const SoluteSpecies = @import("soil/solute/transport_species.zig").AqueousSpecies;
const AqueousBridge = @import("soil/solute/aqueous_transport_bridge.zig");
const MineralNitrogen = @import("soil/biogeochemistry/mineral_nitrogen_transport.zig");
const SurfaceDenitrification = @import("surface/denitrification_step.zig").State;
const SurfaceSoluteRouting = @import("soil/solute/surface_solute_routing.zig").State;
const PlantLitterSaltIngress = @import("plant/salt/litter_ingress.zig");

comptime {
    _ = TillageActivity;
}

const exchange_ion_fields = .{ "hydrogen", "aluminum", "iron", "calcium", "magnesium", "sodium", "potassium" };

fn exchangeIonInventories(chemistry: *const Chemistry, surface: *const SurfaceChemistry, geometry: *const SurfaceGeometry, bulk: []const f64, volume: []const f64) [exchange_ion_fields.len]f64 {
    var result: [exchange_ion_fields.len]f64 = undefined;
    inline for (exchange_ion_fields, 0..) |field, ion| {
        result[ion] = @field(surface.cells[0].exchange, field ++ "_mol_per_megagram") * geometry.dry_mass_megagrams[0];
        for (bulk, volume, chemistry.cation_exchange_mol_per_megagram) |density, matrix_volume, exchange|
            result[ion] += density * matrix_volume * @field(exchange, field);
    }
    return result;
}

test "tillage surface dry-organic heat rejects a signed carbon increase" {
    const before: f64 = 1;
    const after = std.math.nextAfter(f64, before, std.math.inf(f64));
    try std.testing.expectError(
        error.TillageSurfaceOrganicConservationFailure,
        adapter.incorporatedSurfaceDryHeatCapacity(before, after, 2.5e-6),
    );
}

test "accepted tillage exchange capacity requires the exact BKVL carrier" {
    try std.testing.expectEqual(
        @as(f64, 2),
        try adapter.acceptedExchangeCapacityPerMegagram(6, 1.5, 2),
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        try adapter.acceptedExchangeCapacityPerMegagram(0, 0, 2),
    );
    try std.testing.expectError(
        error.UnboundTillageExchangeCapacity,
        adapter.acceptedExchangeCapacityPerMegagram(1, 0, 2),
    );
}

test "tillage runtime adapter compiles" {
    const config = try SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 8 });
    var grid = try Grid.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 0.1;
    // Layer 1 begins carrierless. A pending litter-salt inventory below must
    // still enter REDIST and bind to the water incorporated by tillage.
    grid.matrix_liquid_water_m3[1] = 0;
    grid.liquid_water_m3[0] = 0.1;
    grid.liquid_water_m3[1] = 0;
    grid.soil_temperature_k[0] = 280;
    grid.soil_temperature_k[1] = 300;

    var geometry = try Geometry.init(std.testing.allocator, 1, 2);
    defer geometry.deinit();
    var thickness = [_]f64{ 0.1, 0.1 };
    var bottoms = [_]f64{ 0.1, 0.2 };
    var volume = [_]f64{ 1, 1 };
    var bulk = [_]f64{ 1.2, 1.4 };
    var porosity = [_]f64{ 0.5, 0.4 };
    var sand_fraction = [_]f64{ 0.6, 0.4 };
    var clay_fraction = [_]f64{ 0.2, 0.3 };
    var sand_mass = [_]f64{ 0.6, 0.4 };
    var silt_mass = [_]f64{ 0.2, 0.3 };
    var clay_mass = [_]f64{ 0.2, 0.3 };
    var organic_concentration = [_]f64{ 10, 20 };
    var cec_per_mass = [_]f64{ 2, 4 };
    var aec_per_mass = [_]f64{ 1, 2 };
    var cec = [_]f64{ 2, 4 };
    var aec = [_]f64{ 1, 2 };
    var properties: Properties = undefined;
    properties.layer_count = 2;
    properties.layer_volume_m3 = &volume;
    properties.matrix_bulk_volume_m3 = &volume;
    properties.layer_thickness_m = &thickness;
    properties.layer_bottom_depth_m = &bottoms;
    var reference_bulk = [_]f64{ 1.15, 1.35 };
    var field_capacity = [_]f64{ 0.3, 0.25 };
    var wilting_point = [_]f64{ 0.1, 0.12 };
    var retention_curves: [2]Retention.ResolvedCurve = undefined;
    for (&retention_curves, 0..) |*curve, layer| curve.* = try Retention.resolve(Retention.compatibilityParameters(), .{
        .porosity_fraction = porosity[layer],
        .macropore_fraction = 0,
        .sand_fraction = sand_fraction[layer],
        .clay_fraction = clay_fraction[layer],
        .organic_carbon_g_per_megagram = organic_concentration[layer],
        .bulk_density_megagrams_per_m3 = bulk[layer],
        .supplied_field_capacity_fraction = field_capacity[layer],
        .supplied_wilting_point_fraction = wilting_point[layer],
    }, -0.01, -1.5);
    const retention_before = retention_curves;
    properties.retention_curve = &retention_curves;
    var lateral_saturated = [_]f64{ 0.02, 0.01 };
    var mualem = [_]Retention.MualemVanGenuchtenParameters{
        .{ .residual_water_content_m3_per_m3 = 0.05, .saturated_water_content_m3_per_m3 = 0.5, .alpha_per_m = 1, .n = 2, .saturated_hydraulic_conductivity_m_per_h = 0.04 },
        .{ .residual_water_content_m3_per_m3 = 0.05, .saturated_water_content_m3_per_m3 = 0.4, .alpha_per_m = 1, .n = 2, .saturated_hydraulic_conductivity_m_per_h = 0.02 },
    };
    properties.reference_bulk_density_megagrams_per_m3 = &reference_bulk;
    properties.field_capacity_fraction = &field_capacity;
    properties.wilting_point_fraction = &wilting_point;
    properties.lateral_saturated_hydraulic_conductivity_m_per_h = &lateral_saturated;
    properties.mualem_van_genuchten_parameters = &mualem;
    properties.bulk_density_megagrams_per_m3 = &bulk;
    properties.porosity_fraction = &porosity;
    properties.sand_mass_fraction = &sand_fraction;
    properties.clay_mass_fraction = &clay_fraction;
    properties.sand_mass_megagrams = &sand_mass;
    properties.silt_mass_megagrams = &silt_mass;
    properties.clay_mass_megagrams = &clay_mass;
    properties.total_organic_carbon_g_per_megagram = &organic_concentration;
    properties.cation_exchange_capacity_mol_per_megagram = &cec_per_mass;
    properties.anion_exchange_capacity_mol_per_megagram = &aec_per_mass;
    properties.cation_exchange_capacity_mol = &cec;
    properties.anion_exchange_capacity_mol = &aec;

    var dry_heat = [_]f64{ 1, 1 };
    var heat_capacity = [_]f64{ 2, 2 };
    var conductivity = [_]f64{ 1, 1 };
    var thermal: Thermal = undefined;
    thermal.layer_volume_m3 = &volume;
    thermal.dry_solid_heat_capacity_megajoules_per_m3_k = &dry_heat;
    thermal.total_heat_capacity_megajoules_per_m3_k = &heat_capacity;
    thermal.thermal_conductivity_m_megajoules_per_h_k = &conductivity;

    var soil_organic = try Organic.init(std.testing.allocator, 2);
    defer soil_organic.deinit();
    var surface_organic = try Organic.init(std.testing.allocator, 1);
    defer surface_organic.deinit();
    var soil_organic_transport = try OrganicTransport.init(std.testing.allocator, 2);
    defer soil_organic_transport.deinit();
    try soil_organic_transport.initializeFromProfile(&soil_organic);
    soil_organic.microbial[0] = .{ .carbon_g_c = 10, .nitrogen_g_n = 2, .phosphorus_g_p = 1 };
    surface_organic.microbial[0] = .{ .carbon_g_c = 4, .nitrogen_g_n = 0.8, .phosphorus_g_p = 0.4 };
    var soil_gas = try Gas.init(std.testing.allocator, 2);
    defer soil_gas.deinit();
    var surface_gas = try Gas.init(std.testing.allocator, 1);
    defer surface_gas.deinit();
    var chemistry = try Chemistry.init(std.testing.allocator, 2);
    defer chemistry.deinit();
    var surface_chemistry = try SurfaceChemistry.init(std.testing.allocator, 1);
    defer surface_chemistry.deinit();
    var surface_denitrification = try SurfaceDenitrification.init(std.testing.allocator, 1);
    defer surface_denitrification.deinit();
    var surface_solute_transport = try SurfaceSoluteRouting.init(std.testing.allocator, 1, 1, SoluteSpecies.count);
    defer surface_solute_transport.deinit();
    var plant_litter_salt_ingress = try PlantLitterSaltIngress.State.init(std.testing.allocator, 1, 2);
    defer plant_litter_salt_ingress.deinit();
    plant_litter_salt_ingress.pending_mol[2 * PlantLitterSaltIngress.salt_count] = 1.25;
    var surface_geometry = try SurfaceGeometry.init(std.testing.allocator, 1);
    defer surface_geometry.deinit();
    var fertilizer_band = try FertilizerBand.State.init(std.testing.allocator, .{ .cell_count = 1, .layer_capacity = 2, .active_layer_count_by_cell = &.{2}, .layer_upper_depth_m = &.{ 0, 0.1 }, .layer_lower_depth_m = &.{ 0.1, 0.2 }, .layer_thickness_m = &thickness, .initial_band_fraction_by_family = .{ 0.25, 0.25, 0.25 }, .row_spacing_m_by_cell_family = &.{ 0.3, 0.3, 0.3 } });
    defer fertilizer_band.deinit();
    var fertilizer_nitrogen = try FertilizerNitrogen.init(std.testing.allocator, 1, 2);
    defer fertilizer_nitrogen.deinit();
    var surface_fertilizer = try SurfaceFertilizer.init(std.testing.allocator, 1);
    defer surface_fertilizer.deinit();
    var mineral_fertilizer = try MineralFertilizer.init(std.testing.allocator, 1, 2);
    defer mineral_fertilizer.deinit();
    var reactive_nitrogen = try ReactiveNitrogen.init(std.testing.allocator, 2, 1);
    defer reactive_nitrogen.deinit();
    surface_geometry.dry_mass_megagrams[0] = 0.01;
    @memset(soil_gas.temperature_k, 290);
    surface_gas.temperature_k[0] = 290;
    soil_gas.gaseous_mass_g[0] = 2;
    soil_gas.gaseous_mass_g[GasModule.species_count] = 4;
    soil_gas.macropore_dissolved_mass_g[0] = 1;
    surface_gas.dissolved_mass_g[0] = 3;
    chemistry.aqueous[0].ammonium_non_band = 10;
    chemistry.aqueous[0].ammonium_band = 20;
    chemistry.aqueous[1].ammonium_non_band = 5;
    chemistry.aqueous[0].hydrogen = 2;
    chemistry.cation_exchange_mol_per_megagram[0].ammonium_non_band = 4;
    chemistry.cation_exchange_mol_per_megagram[0].ammonium_band = 6;
    inline for (exchange_ion_fields, 0..) |field, ion| {
        const scale: f64 = @floatFromInt(ion + 1);
        @field(chemistry.cation_exchange_mol_per_megagram[0], field) = 0.25 * scale;
        @field(chemistry.cation_exchange_mol_per_megagram[1], field) = 0.4 * scale;
        @field(surface_chemistry.cells[0].exchange, field ++ "_mol_per_megagram") = 0.5 * scale;
    }
    chemistry.non_band_phosphate[0].adsorbed_hpo4_mol_p_per_megagram = 1.25;
    chemistry.band_phosphate[0].adsorbed_h2po4_mol_p_per_megagram = 2.25;
    chemistry.non_band_phosphate[1].adsorbed_hpo4_mol_p_per_megagram = 3;
    chemistry.band_phosphate[1].adsorbed_h2po4_mol_p_per_megagram = 4;
    surface_chemistry.cells[0].phosphate_surface.adsorbed_hpo4_mol_p_per_megagram = 0.125;
    surface_chemistry.cells[0].phosphate_surface.adsorbed_h2po4_mol_p_per_megagram = 0.25;
    chemistry.non_band_phosphate[0].dissolved_hpo4_mol_p_per_m3 = 3;
    chemistry.band_phosphate[0].dissolved_hpo4_mol_p_per_m3 = 7;
    surface_chemistry.cells[0].ammonium_mol_per_m3 = 30;
    surface_chemistry.cells[0].hydrogen_mol_per_m3 = 8;
    surface_chemistry.cells[0].exchange.ammonium_mol_per_megagram = 9;
    surface_chemistry.cells[0].hpo4_mol_p_per_m3 = 11;
    surface_denitrification.nitrite_g_n[0] = 0.6;
    fertilizer_nitrogen.soil[0].broadcast_ammonium_mol_n = 2;
    fertilizer_nitrogen.soil[0].banded_ammonium_mol_n = 3;
    surface_fertilizer.cells[0].ammonium_mol_n = 4;
    surface_fertilizer.cells[0].initial_urease_inhibition_fraction = 0.8;
    surface_fertilizer.cells[0].current_urease_inhibition_fraction = 0.6;
    mineral_fertilizer.soil[0].calcite_mol = 2;
    mineral_fertilizer.surface[0].calcite_mol = 3;
    reactive_nitrogen.non_band_nitrite_g_n[0] = 1;
    reactive_nitrogen.band_nitrite_g_n[0] = 2;
    const nitrite_g_n_before = surface_denitrification.nitrite_g_n[0] +
        reactive_nitrogen.non_band_nitrite_g_n[0] + reactive_nitrogen.band_nitrite_g_n[0] +
        reactive_nitrogen.non_band_nitrite_g_n[1] + reactive_nitrogen.band_nitrite_g_n[1];
    reactive_nitrogen.initial_nitrification_inhibition_activity[0] = 0.5;
    reactive_nitrogen.current_nitrification_inhibition_activity[0] = 0.4;
    var micropore_solutes = try SoluteTransport.init(std.testing.allocator, 2, SoluteSpecies.count);
    defer micropore_solutes.deinit();
    var macropore_solutes = try SoluteTransport.init(std.testing.allocator, 2, SoluteSpecies.count);
    defer macropore_solutes.deinit();
    @memcpy(micropore_solutes.water_volume_m3, grid.matrix_liquid_water_m3);
    @memcpy(macropore_solutes.water_volume_m3, grid.macropore_liquid_water_m3);
    try AqueousBridge.exportChemistry(&chemistry, &micropore_solutes, &fertilizer_band, 0);
    macropore_solutes.amount_mol[@intFromEnum(SoluteSpecies.hydrogen)] = 0.75;
    macropore_solutes.amount_mol[@intFromEnum(SoluteSpecies.non_band_hpo4)] = 0.25;
    macropore_solutes.amount_mol[@intFromEnum(SoluteSpecies.band_hpo4)] = 0.7;
    var mineral_nitrogen_transport = try MineralNitrogen.State.init(std.testing.allocator, 2);
    defer mineral_nitrogen_transport.deinit();
    try mineral_nitrogen_transport.initializeMatrix(&chemistry, &reactive_nitrogen, grid.matrix_liquid_water_m3, &fertilizer_band, 14, 0);
    mineral_nitrogen_transport.macropore.amount_mol[@intFromEnum(MineralNitrogen.Species.ammonium_non_band)] = 0.5;
    var surface_water = [_]f64{0.05};
    var surface_ice = [_]f64{0.01};
    var surface_heat_capacity = [_]f64{1.0};
    // REDIST retains surface precipitates while incorporating the aqueous
    // 42-coordinate family. Keep live inventory here so the runtime test
    // rejects a future accidental aqueous alias or unrecorded removal.
    surface_chemistry.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3 = 2;
    surface_chemistry.cells[0].salt_minerals.calcite_mol_per_m3 = 3;
    surface_chemistry.mineral_reference_water_m3[0] = surface_water[0];
    const cell_area = [_]f64{1.0};
    var chemistry_parameters: [2]ChemistryModule.ReactionParameters = undefined;
    chemistry_parameters[0].cation_exchange_parameters.selectivity = .{ .calcium_ammonium = 1, .calcium_hydrogen = 7, .calcium_aluminum_and_iron = 2, .calcium_magnesium = 3, .calcium_sodium = 4, .calcium_potassium = 5 };
    chemistry_parameters[1].cation_exchange_parameters.selectivity = .{ .calcium_ammonium = 2, .calcium_hydrogen = 8, .calcium_aluminum_and_iron = 3, .calcium_magnesium = 4, .calcium_sodium = 5, .calcium_potassium = 6 };
    const salinity_enabled = [_]bool{true};
    const exchange_ions_before = exchangeIonInventories(&chemistry, &surface_chemistry, &surface_geometry, &bulk, &volume);
    var exchange_ammonium_before = surface_chemistry.cells[0].exchange.ammonium_mol_per_megagram * surface_geometry.dry_mass_megagrams[0];
    var adsorbed_phosphate_before = surface_geometry.dry_mass_megagrams[0] *
        (surface_chemistry.cells[0].phosphate_surface.adsorbed_hpo4_mol_p_per_megagram + surface_chemistry.cells[0].phosphate_surface.adsorbed_h2po4_mol_p_per_megagram);
    for (0..2) |layer| {
        const zones = try fertilizer_band.zoneFractions(0, layer);
        // SOLUTE and the authoritative landscape census use BKVL, not the
        // mineral texture sum. These deliberately differ in this fixture.
        const soil_mass = bulk[layer] * volume[layer];
        exchange_ammonium_before += soil_mass *
            (chemistry.cation_exchange_mol_per_megagram[layer].ammonium_non_band * zones.ammonium_non_band +
                chemistry.cation_exchange_mol_per_megagram[layer].ammonium_band * zones.ammonium_band);
        adsorbed_phosphate_before += soil_mass *
            ((chemistry.non_band_phosphate[layer].adsorbed_hpo4_mol_p_per_megagram + chemistry.non_band_phosphate[layer].adsorbed_h2po4_mol_p_per_megagram) * zones.phosphate_non_band +
                (chemistry.band_phosphate[layer].adsorbed_hpo4_mol_p_per_megagram + chemistry.band_phosphate[layer].adsorbed_h2po4_mol_p_per_megagram) * zones.phosphate_band);
    }
    // Nonzero OQCH verifies that tillage scales and conserves the actual
    // macropore-DOM owner instead of substituting a zero-filled placeholder.
    soil_organic_transport.macropore_amount_g[0] = 8;
    const held_carbon_before = soil_organic_transport.macropore_amount_g[0];
    var mineral_transport_before: f64 = surface_chemistry.cells[0].ammonium_mol_per_m3 * surface_water[0] +
        surface_chemistry.cells[0].ammonia_mol_per_m3 * surface_water[0] +
        surface_chemistry.cells[0].nitrate_mol_per_m3 * surface_water[0] +
        surface_denitrification.nitrite_g_n[0] / 14;
    for (mineral_nitrogen_transport.matrix.amount_mol, mineral_nitrogen_transport.macropore.amount_mol) |matrix, macropore|
        mineral_transport_before += matrix + macropore;
    const hydrogen_species = @intFromEnum(SoluteSpecies.hydrogen);
    var aqueous_hydrogen_before = surface_chemistry.cells[0].hydrogen_mol_per_m3 * surface_water[0];
    for (0..2) |layer| aqueous_hydrogen_before +=
        micropore_solutes.amount_mol[layer * SoluteSpecies.count + hydrogen_species] +
        macropore_solutes.amount_mol[layer * SoluteSpecies.count + hydrogen_species];
    const non_band_hpo4_species = @intFromEnum(SoluteSpecies.non_band_hpo4);
    const band_hpo4_species = @intFromEnum(SoluteSpecies.band_hpo4);
    var aqueous_hpo4_before = surface_chemistry.cells[0].hpo4_mol_p_per_m3 * surface_water[0];
    for (0..2) |layer| aqueous_hpo4_before +=
        micropore_solutes.amount_mol[layer * SoluteSpecies.count + non_band_hpo4_species] +
        macropore_solutes.amount_mol[layer * SoluteSpecies.count + non_band_hpo4_species] +
        micropore_solutes.amount_mol[layer * SoluteSpecies.count + band_hpo4_species] +
        macropore_solutes.amount_mol[layer * SoluteSpecies.count + band_hpo4_species];
    var local_activity = try TillageActivity.Sidecar.init(std.testing.allocator, 1, 2, .{ .relative = 1024 * std.math.floatEps(f64) });
    defer local_activity.deinit();
    var context: adapter.Context = .{ .allocator = std.testing.allocator, .grid = &grid, .geometry = &geometry, .properties = &properties, .thermal = &thermal, .soil_organic = &soil_organic, .soil_organic_transport = &soil_organic_transport, .surface_organic = &surface_organic, .soil_gas = &soil_gas, .surface_gas = &surface_gas, .soil_chemistry = &chemistry, .surface_chemistry = &surface_chemistry, .surface_geometry = &surface_geometry, .fertilizer_band = &fertilizer_band, .fertilizer_nitrogen = &fertilizer_nitrogen, .surface_fertilizer = &surface_fertilizer, .mineral_fertilizer = &mineral_fertilizer, .reactive_nitrogen = &reactive_nitrogen, .micropore_solutes = &micropore_solutes, .macropore_solutes = &macropore_solutes, .mineral_nitrogen_transport = &mineral_nitrogen_transport, .chemistry_layer_parameters = &chemistry_parameters, .surface_denitrification = &surface_denitrification, .surface_solute_transport = &surface_solute_transport, .plant_litter_salt_ingress = &plant_litter_salt_ingress, .local_activity = &local_activity, .surface_water_m3 = &surface_water, .surface_ice_m3 = &surface_ice, .surface_heat_capacity_megajoules_per_k = &surface_heat_capacity, .cell_area_m2 = &cell_area, .salinity_enabled_by_cell = &salinity_enabled, .minimum_layer_thickness_m = 0.001, .dry_organic_heat_capacity_megajoules_per_g_c_k = 2.496e-6, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .physical_ice_heat_capacity_megajoules_per_m3_k = 1.9274, .ice_density_megagrams_per_m3 = 0.917, .latent_heat_of_fusion_megajoules_per_m3 = 334, .pure_water_melting_temperature_k = 273.15, .carbon_g_per_mol = 12, .nitrogen_g_per_mol = 14, .phosphorus_g_per_mol = 31 };
    // Each initial curve is valid, but their mixed FC would exceed layer 1's
    // smaller pore fraction. Reject that candidate before any live scatter.
    porosity[1] = 0.26;
    retention_curves[1].porosity_fraction = 0.26;
    mualem[1].saturated_water_content_m3_per_m3 = 0.26;
    const curves_before_rejection = retention_curves;
    const water_before_rejection = [_]f64{ grid.matrix_liquid_water_m3[0], grid.matrix_liquid_water_m3[1] };
    const surface_water_before_rejection = surface_water[0];
    const carbon_before_rejection = try soil_organic.totalCarbon_g_c(0);
    try local_activity.beginAttempt();
    try std.testing.expectError(error.InvalidTillageRetentionCurve, adapter.apply(&context, 0, 0.2, 1));
    local_activity.abortAttempt();
    try std.testing.expectEqualDeep(curves_before_rejection, retention_curves);
    try std.testing.expectEqualSlices(f64, &water_before_rejection, grid.matrix_liquid_water_m3);
    try std.testing.expectEqual(surface_water_before_rejection, surface_water[0]);
    try std.testing.expectEqual(carbon_before_rejection, try soil_organic.totalCarbon_g_c(0));
    try std.testing.expectEqualSlices(f64, &.{ 0.3, 0.25 }, &field_capacity);
    try std.testing.expectEqualSlices(f64, &.{ 0.1, 0.12 }, &wilting_point);
    porosity[1] = 0.4;
    retention_curves[1].porosity_fraction = 0.4;
    mualem[1].saturated_water_content_m3_per_m3 = 0.4;
    try local_activity.beginAttempt();
    try adapter.apply(&context, 0, 0.2, 1);
    // REDIST changes FC/WP. Their constitutive mirrors must agree exactly at
    // this accepted boundary, before the next HOUR1 material refresh or any
    // rollback/checkpoint serialization. Differing layers expose more than
    // the one-ULP mismatch observed on Ottawa's first soil-tillage event.
    for (retention_curves, 0..) |curve, layer| {
        try std.testing.expectEqual(field_capacity[layer], curve.curve.field_capacity_fraction);
        try std.testing.expectEqual(wilting_point[layer], curve.curve.wilting_point_fraction);
        var expected = retention_before[layer];
        expected.curve.field_capacity_fraction = field_capacity[layer];
        expected.curve.wilting_point_fraction = wilting_point[layer];
        try std.testing.expectEqualDeep(expected, curve);
    }
    try local_activity.commitAttempt();
    for (0..2) |layer| {
        const soil_mass_megagrams = bulk[layer] * volume[layer];
        try std.testing.expectApproxEqAbs(
            cec[layer] / soil_mass_megagrams,
            cec_per_mass[layer],
            32 * std.math.floatEps(f64),
        );
        try std.testing.expectApproxEqAbs(
            aec[layer] / soil_mass_megagrams,
            aec_per_mass[layer],
            32 * std.math.floatEps(f64),
        );
        try std.testing.expectEqual(
            cec_per_mass[layer],
            chemistry_parameters[layer]
                .cation_exchange_capacity_mol_charge_per_megagram,
        );
    }
    // The downstream cation-exchange equilibrium consumes the rebound
    // reaction scalar, so its closed site charge must equal accepted XCEC/BKVL.
    const all_cations: CationExchange.Cations = .{
        .ammonium_non_band = 1,
        .ammonium_band = 1,
        .hydrogen = 1,
        .aluminum = 1,
        .iron = 1,
        .calcium = 1,
        .magnesium = 1,
        .sodium = 1,
        .potassium = 1,
    };
    const zero_cations: CationExchange.Cations = .{
        .ammonium_non_band = 0,
        .ammonium_band = 0,
        .hydrogen = 0,
        .aluminum = 0,
        .iron = 0,
        .calcium = 0,
        .magnesium = 0,
        .sodium = 0,
        .potassium = 0,
    };
    const equilibrium = try CationExchange.equilibriumIonConcentration(.{
        .cation_exchange_capacity_mol_charge_per_megagram = chemistry_parameters[0]
            .cation_exchange_capacity_mol_charge_per_megagram,
        .aqueous_concentration_mol_per_m3 = all_cations,
        .aqueous_activity_mol_per_m3 = all_cations,
        .exchange_concentration_mol_per_megagram = zero_cations,
        .ammonium_non_band_fraction = 0.5,
        .ammonium_band_fraction = 0.5,
        .soil_mass_per_water_volume_megagrams_per_m3 = 1,
    }, chemistry_parameters[0].cation_exchange_parameters.selectivity);
    const equilibrium_charge =
        0.5 * equilibrium.ammonium_non_band +
        0.5 * equilibrium.ammonium_band +
        equilibrium.hydrogen +
        3 * (equilibrium.aluminum + equilibrium.iron) +
        2 * (equilibrium.calcium + equilibrium.magnesium) +
        equilibrium.sodium + equilibrium.potassium;
    try std.testing.expectApproxEqAbs(
        chemistry_parameters[0]
            .cation_exchange_capacity_mol_charge_per_megagram,
        equilibrium_charge,
        64 * std.math.floatEps(f64),
    );
    try std.testing.expectEqual(@as(f64, 2), surface_chemistry.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 3), surface_chemistry.cells[0].salt_minerals.calcite_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0.05), surface_chemistry.mineral_reference_water_m3[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), surface_water[0] + grid.matrix_liquid_water_m3[0] + grid.matrix_liquid_water_m3[1], 1e-12);
    const aluminum_species = @intFromEnum(SoluteSpecies.aluminum);
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), micropore_solutes.amount_mol[aluminum_species] + micropore_solutes.amount_mol[SoluteSpecies.count + aluminum_species], 1e-12);
    for (plant_litter_salt_ingress.pending_mol) |amount| try std.testing.expectEqual(@as(f64, 0), amount);
    try std.testing.expectApproxEqAbs(@as(f64, 14) + held_carbon_before, try soil_organic.totalCarbon_g_c(0) + try soil_organic.totalCarbon_g_c(1) + try surface_organic.totalCarbon_g_c(0), 1e-12);
    var held_carbon_after: f64 = 0;
    for (soil_organic_transport.macropore_amount_g, 0..) |amount, index|
        if (index % 4 == 0 or index % 4 == 3) {
            held_carbon_after += amount;
        };
    var matrix_carbon_after: f64 = 0;
    for (soil_organic_transport.micropore_amount_g, 0..) |amount, index|
        if (index % 4 == 0 or index % 4 == 3) {
            matrix_carbon_after += amount;
        };
    try std.testing.expectApproxEqAbs(held_carbon_before, held_carbon_after + matrix_carbon_after, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 10), soil_gas.gaseous_mass_g[0] + soil_gas.gaseous_mass_g[GasModule.species_count] + soil_gas.dissolved_mass_g[0] + soil_gas.dissolved_mass_g[GasModule.species_count] + soil_gas.macropore_dissolved_mass_g[0] + surface_gas.dissolved_mass_g[0], 1e-12);
    var mineral_transport_after: f64 = surface_chemistry.cells[0].ammonium_mol_per_m3 * surface_water[0] +
        surface_chemistry.cells[0].ammonia_mol_per_m3 * surface_water[0] +
        surface_chemistry.cells[0].nitrate_mol_per_m3 * surface_water[0] +
        surface_denitrification.nitrite_g_n[0] / 14;
    for (mineral_nitrogen_transport.matrix.amount_mol, mineral_nitrogen_transport.macropore.amount_mol) |matrix, macropore|
        mineral_transport_after += matrix + macropore;
    try std.testing.expectApproxEqAbs(mineral_transport_before, mineral_transport_after, 1e-11);
    var aqueous_hydrogen_after = surface_chemistry.cells[0].hydrogen_mol_per_m3 * surface_water[0];
    for (0..2) |layer| aqueous_hydrogen_after +=
        micropore_solutes.amount_mol[layer * SoluteSpecies.count + hydrogen_species] +
        macropore_solutes.amount_mol[layer * SoluteSpecies.count + hydrogen_species];
    try std.testing.expectApproxEqAbs(aqueous_hydrogen_before, aqueous_hydrogen_after, 1e-11);
    var aqueous_hpo4_after = surface_chemistry.cells[0].hpo4_mol_p_per_m3 * surface_water[0];
    for (0..2) |layer| aqueous_hpo4_after +=
        micropore_solutes.amount_mol[layer * SoluteSpecies.count + non_band_hpo4_species] +
        macropore_solutes.amount_mol[layer * SoluteSpecies.count + non_band_hpo4_species] +
        micropore_solutes.amount_mol[layer * SoluteSpecies.count + band_hpo4_species] +
        macropore_solutes.amount_mol[layer * SoluteSpecies.count + band_hpo4_species];
    try std.testing.expectApproxEqAbs(aqueous_hpo4_before, aqueous_hpo4_after, 1e-11);
    try std.testing.expectEqual(@as(f64, 0), macropore_solutes.amount_mol[non_band_hpo4_species]);
    try std.testing.expectEqual(@as(f64, 0), macropore_solutes.amount_mol[band_hpo4_species]);
    var exchange_ammonium_after = surface_chemistry.cells[0].exchange.ammonium_mol_per_megagram * surface_geometry.dry_mass_megagrams[0];
    var adsorbed_phosphate_after = surface_geometry.dry_mass_megagrams[0] *
        (surface_chemistry.cells[0].phosphate_surface.adsorbed_hpo4_mol_p_per_megagram + surface_chemistry.cells[0].phosphate_surface.adsorbed_h2po4_mol_p_per_megagram);
    for (0..2) |layer| {
        const zones = try fertilizer_band.zoneFractions(0, layer);
        const soil_mass = bulk[layer] * volume[layer];
        exchange_ammonium_after += soil_mass *
            (chemistry.cation_exchange_mol_per_megagram[layer].ammonium_non_band * zones.ammonium_non_band +
                chemistry.cation_exchange_mol_per_megagram[layer].ammonium_band * zones.ammonium_band);
        adsorbed_phosphate_after += soil_mass *
            ((chemistry.non_band_phosphate[layer].adsorbed_hpo4_mol_p_per_megagram + chemistry.non_band_phosphate[layer].adsorbed_h2po4_mol_p_per_megagram) * zones.phosphate_non_band +
                (chemistry.band_phosphate[layer].adsorbed_hpo4_mol_p_per_megagram + chemistry.band_phosphate[layer].adsorbed_h2po4_mol_p_per_megagram) * zones.phosphate_band);
    }
    try std.testing.expectApproxEqAbs(exchange_ammonium_before, exchange_ammonium_after, 1e-11);
    try std.testing.expectApproxEqAbs(adsorbed_phosphate_before, adsorbed_phosphate_after, 1e-11);
    const exchange_ions_after = exchangeIonInventories(&chemistry, &surface_chemistry, &surface_geometry, &bulk, &volume);
    for (exchange_ions_before, exchange_ions_after) |before, after|
        try std.testing.expectApproxEqAbs(before, after, 1e-11);
    const fertilizer_ammonium = fertilizer_nitrogen.soil[0].broadcast_ammonium_mol_n + fertilizer_nitrogen.soil[0].banded_ammonium_mol_n + fertilizer_nitrogen.soil[1].broadcast_ammonium_mol_n + fertilizer_nitrogen.soil[1].banded_ammonium_mol_n + surface_fertilizer.cells[0].ammonium_mol_n;
    try std.testing.expectApproxEqAbs(@as(f64, 9), fertilizer_ammonium, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5), mineral_fertilizer.soil[0].calcite_mol + mineral_fertilizer.soil[1].calcite_mol + mineral_fertilizer.surface[0].calcite_mol, 1e-12);
    try std.testing.expectApproxEqAbs(nitrite_g_n_before, surface_denitrification.nitrite_g_n[0] + reactive_nitrogen.non_band_nitrite_g_n[0] + reactive_nitrogen.band_nitrite_g_n[0] + reactive_nitrogen.non_band_nitrite_g_n[1] + reactive_nitrogen.band_nitrite_g_n[1], 1e-12);
    inline for (std.enums.values(FertilizerBand.Family)) |family| {
        const view = try fertilizer_band.geometry(0, family);
        try std.testing.expectEqual(@as(f64, 0), view.band_volume_fraction[0]);
        try std.testing.expectEqual(@as(f64, 0), view.band_volume_fraction[1]);
        try std.testing.expectEqual(@as(f64, 1), view.non_band_volume_fraction[0]);
        try std.testing.expectEqual(@as(f64, 1), view.non_band_volume_fraction[1]);
    }

    // A genuinely carrierless profile cannot receive a concentration. The
    // exact extensive salt must still mix and remain in the pending owner.
    @memset(grid.matrix_liquid_water_m3, 0);
    @memset(grid.liquid_water_m3, 0);
    @memset(micropore_solutes.amount_mol, 0);
    @memset(macropore_solutes.amount_mol, 0);
    @memset(mineral_nitrogen_transport.matrix.amount_mol, 0);
    @memset(mineral_nitrogen_transport.macropore.amount_mol, 0);
    for (chemistry.aqueous) |*aqueous| aqueous.* = std.mem.zeroes(@TypeOf(aqueous.*));
    for (chemistry.non_band_phosphate) |*phosphate| phosphate.* = std.mem.zeroes(@TypeOf(phosphate.*));
    for (chemistry.band_phosphate) |*phosphate| phosphate.* = std.mem.zeroes(@TypeOf(phosphate.*));
    for (chemistry.geochemistry_solids) |*solid| solid.* = std.mem.zeroes(@TypeOf(solid.*));
    surface_chemistry.cells[0] = std.mem.zeroes(@TypeOf(surface_chemistry.cells[0]));
    surface_chemistry.dry_reference_water_m3[0] = 0;
    surface_water[0] = 0;
    plant_litter_salt_ingress.pending_mol[2 * PlantLitterSaltIngress.salt_count] = 2;
    try local_activity.beginAttempt();
    try adapter.apply(&context, 0, 0.2, 1);
    try local_activity.commitAttempt();
    var carrierless_pending_total: f64 = 0;
    for (plant_litter_salt_ingress.pending_mol) |amount| carrierless_pending_total += amount;
    try std.testing.expectApproxEqAbs(@as(f64, 2), carrierless_pending_total, 1e-12);
    try std.testing.expectEqual(@as(f64, 0), micropore_solutes.amount_mol[aluminum_species]);
    try std.testing.expectEqual(@as(f64, 0), micropore_solutes.amount_mol[SoluteSpecies.count + aluminum_species]);

    // Force a failure in the final mineral-fertilizer family after every
    // translated tillage kernel has already run on private storage.
    mineral_fertilizer.soil[1].potassium_ground_silicate_mol = std.math.floatMax(f64);
    mineral_fertilizer.surface[0].potassium_ground_silicate_mol = std.math.floatMax(f64);
    const water_before_failed_retry = grid.matrix_liquid_water_m3[0];
    const surface_water_before_failed_retry = surface_water[0];
    const ammonium_before_failed_retry = chemistry.aqueous[0].ammonium_non_band;
    const carbon_before_failed_retry = try soil_organic.totalCarbon_g_c(0);
    const band_before_failed_retry = (try fertilizer_band.geometry(0, .ammonium)).band_volume_fraction[0];
    const curves_before_failed_retry = retention_curves;
    try local_activity.beginAttempt();
    try std.testing.expectError(error.TillageMineralFertilizerConservationFailure, adapter.apply(&context, 0, 0.2, 1));
    local_activity.abortAttempt();
    try std.testing.expectEqual(water_before_failed_retry, grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(surface_water_before_failed_retry, surface_water[0]);
    try std.testing.expectEqual(ammonium_before_failed_retry, chemistry.aqueous[0].ammonium_non_band);
    try std.testing.expectEqual(carbon_before_failed_retry, try soil_organic.totalCarbon_g_c(0));
    try std.testing.expectEqual(band_before_failed_retry, (try fertilizer_band.geometry(0, .ammonium)).band_volume_fraction[0]);
    try std.testing.expectEqualDeep(curves_before_failed_retry, retention_curves);
    try std.testing.expectEqual(std.math.floatMax(f64), mineral_fertilizer.soil[1].potassium_ground_silicate_mol);
}
