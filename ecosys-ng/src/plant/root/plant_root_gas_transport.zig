const std = @import("std");
const gas_transport = @import("../../soil/gas/transport.zig");
const grid_module = @import("../../state/grid.zig");
const root_exchange = @import("plant_root_gas_exchange.zig");
const root_system = @import("plant_root_system.zig");
const plant_water = @import("water_balance.zig");
const soil_properties = @import("../../soil/water/solver_properties.zig");
const charge_classification = @import("../../soil/solute/charge_classification.zig");

pub const Settings = struct {
    liquid_tortuosity_coefficient: f64,
    minimum_aqueous_volume_m3: f64,
    minimum_gaseous_volume_m3: f64,
    minimum_root_surface_area_m2: f64,
    absolute_tolerance_g_by_species: [root_exchange.transported_gas_count]f64,
    relative_tolerance: f64,
    maximum_iterations: u16,
};

pub fn advance(
    roots: *root_system.State,
    water: *const plant_water.Workspace,
    grid: *const grid_module.GridState,
    properties: *const soil_properties.State,
    soil_gas: *gas_transport.State,
    parameters: root_exchange.RuntimeParameters,
    atmospheric_concentration_g_per_m3: []const f64,
    biological_domain_count_by_plant: []const u8,
    active_by_plant: []const bool,
    zone_fractions_source: anytype,
    settings: Settings,
) !void {
    try validate(roots, water, grid, properties, soil_gas, atmospheric_concentration_g_per_m3, biological_domain_count_by_plant, active_by_plant, settings);
    for (0..grid.cell_count) |cell| {
        const plant_first = cell * (roots.plant_count / grid.cell_count);
        const species_per_cell = roots.plant_count / grid.cell_count;
        for (0..grid.active_soil_layer_count[cell]) |layer| {
            const soil = try grid.layerIndex(cell, layer);
            const zone_fractions = try rootGasFractionsAt(zone_fractions_source, soil);
            const ammonium_band_fraction = zone_fractions.ammonium_band;
            const soil_water_m3 = grid.matrix_liquid_water_m3[soil];
            if (soil_water_m3 <= 0) continue;
            const bulk_volume_m3 = properties.matrix_bulk_volume_m3[soil];
            const water_fraction = if (bulk_volume_m3 > 0) std.math.clamp(soil_water_m3 / bulk_volume_m3, 0, 1) else 0;
            const tortuosity = settings.liquid_tortuosity_coefficient * water_fraction * water_fraction;
            const film_m = try root_exchange.soilWaterFilmThicknessM(parameters, grid.matric_potential_megapascal[soil], layer == 0);
            for (0..species_per_cell) |species| {
                const plant = plant_first + species;
                if (!active_by_plant[plant] or roots.roots_dead[plant]) continue;
                const population = water.plant_population_count[plant];
                if (population <= 0) continue;
                const domain_count = biological_domain_count_by_plant[plant];
                for (0..domain_count) |domain| {
                    const root = try roots.layerIndex(plant, domain, layer);
                    if (roots.aqueous_volume_m3[root] <= settings.minimum_aqueous_volume_m3 or
                        roots.root_surface_area_m2_per_plant[root] <= settings.minimum_root_surface_area_m2)
                        continue;
                    inline for (non_oxygen_gases) |gas| {
                        if (domain == 0 or gas == .carbon_dioxide) {
                            if (gas != .ammonia or ammonium_band_fraction < 1) try exchangeSoilAqueous(
                                roots,
                                water,
                                grid,
                                soil_gas,
                                parameters,
                                root,
                                soil,
                                gas,
                                if (gas == .ammonia) soil_water_m3 * zone_fractions.ammonium_non_band else soil_water_m3,
                                tortuosity,
                                film_m,
                                population,
                                false,
                            );
                            if (gas == .ammonia and ammonium_band_fraction > 0) try exchangeSoilAqueous(
                                roots,
                                water,
                                grid,
                                soil_gas,
                                parameters,
                                root,
                                soil,
                                gas,
                                soil_water_m3 * ammonium_band_fraction,
                                tortuosity,
                                film_m,
                                population,
                                true,
                            );
                        }
                    }
                    // UPTAKE RCO2A enters the root aqueous pool after the
                    // soil-root concentration-gradient transaction and before
                    // root phase exchange.
                    const respiration_g_c = roots.actual_respiration_g_c_per_h[root];
                    const next_aqueous_co2_g_c = roots.aqueous_carbon_dioxide_g_c[root] + respiration_g_c;
                    const next_reaction_g_c = roots.aqueous_carbon_dioxide_reaction_g_c_per_h[root] + respiration_g_c;
                    if (!std.math.isFinite(respiration_g_c) or respiration_g_c < 0 or
                        !std.math.isFinite(next_aqueous_co2_g_c) or !std.math.isFinite(next_reaction_g_c))
                        return error.NonFiniteRootRespirationGasSource;
                    roots.aqueous_carbon_dioxide_g_c[root] = next_aqueous_co2_g_c;
                    roots.aqueous_carbon_dioxide_reaction_g_c_per_h[root] = next_reaction_g_c;
                }

                // The source permits root internal gas transport only in the
                // primary biological domain.
                const root = try roots.layerIndex(plant, 0, layer);
                if (roots.gaseous_volume_m3[root] <= settings.minimum_gaseous_volume_m3) continue;
                const topology = try roots.layerTopology(
                    plant,
                    0,
                    layer,
                    population,
                    properties.layer_thickness_m[soil],
                    water.woody_root_fraction[plant],
                    roots.average_secondary_length_m[root],
                );
                const cross_section_m = try root_exchange.rootGasCrossSectionPerLengthM(
                    population,
                    topology.primary_axis_count,
                    topology.secondary_axis_count,
                    water.primary_root_radius_m[plant],
                    water.secondary_root_radius_m[plant],
                    properties.layer_thickness_m[soil],
                    topology.average_secondary_length_m,
                    water.root_biome_fraction[root],
                );
                inline for (non_oxygen_gases) |gas| {
                    const environment = try root_exchange.gasEnvironment(parameters, gas, grid.soil_temperature_k[soil], 0);
                    const gas_species = transportSpecies(gas);
                    const gas_slot = @intFromEnum(gas);
                    const root_gas = rootGaseousPool(roots, gas);
                    const root_aqueous = rootAqueousPool(roots, gas);
                    const result = try root_exchange.solveRootPhaseAtmosphereExchangeG(.{
                        .gaseous_mass_g = root_gas[root],
                        .aqueous_mass_g = root_aqueous[root],
                        .gaseous_volume_m3 = roots.gaseous_volume_m3[root],
                        .aqueous_volume_m3 = roots.aqueous_volume_m3[root],
                        .water_to_air_mass_solubility_ratio = environment.water_to_air_mass_solubility_ratio,
                        .atmosphere_concentration_g_per_m3 = atmospheric_concentration_g_per_m3[cell * gas_transport.species_count + @intFromEnum(gas_species)],
                        .atmosphere_conductance_m3_per_h = environment.gaseous_diffusivity_m2_per_h * cross_section_m,
                        .phase_equilibration_fraction = std.math.clamp(
                            roots.current_porosity_fraction_by_domain[try roots.domainIndex(plant, 0)],
                            0,
                            1,
                        ),
                        .maximum_iterations = settings.maximum_iterations,
                        .absolute_tolerance_g = settings.absolute_tolerance_g_by_species[gas_slot],
                        .relative_tolerance = settings.relative_tolerance,
                    });
                    const ledger = root * root_system.transported_root_gas_count + gas_slot;
                    const next_phase = roots.aqueous_to_gaseous_root_exchange_g_per_h[ledger] + result.aqueous_to_gaseous_exchange_g_per_h;
                    const next_atmosphere = roots.atmosphere_to_root_gas_exchange_g_per_h[ledger] + result.atmosphere_to_root_exchange_g_per_h;
                    if (!std.math.isFinite(next_phase) or !std.math.isFinite(next_atmosphere)) return error.NonFiniteRootGasLedger;
                    root_gas[root] = result.final_gaseous_mass_g;
                    root_aqueous[root] = result.final_aqueous_mass_g;
                    roots.aqueous_to_gaseous_root_exchange_g_per_h[ledger] = next_phase;
                    roots.atmosphere_to_root_gas_exchange_g_per_h[ledger] = next_atmosphere;
                }
            }
        }
    }
    try roots.validateFinite();
}

fn rootGasFractionsAt(source: anytype, soil: usize) !charge_classification.ZoneFractions {
    const fractions = if (comptime @TypeOf(source) == charge_classification.ZoneFractions)
        source
    else
        try source.scienceZoneFractionsForFlatIndex(soil);
    if (!std.math.isFinite(fractions.ammonium_non_band) or fractions.ammonium_non_band < 0 or fractions.ammonium_non_band > 1 or
        !std.math.isFinite(fractions.ammonium_band) or fractions.ammonium_band < 0 or fractions.ammonium_band > 1 or
        @abs(fractions.ammonium_non_band + fractions.ammonium_band - 1) > 16 * std.math.floatEps(f64))
        return error.InvalidRootGasTransportSettings;
    return fractions;
}

pub const OxygenSettings = struct {
    liquid_tortuosity_coefficient: f64,
    minimum_active_layer_thickness_m: f64,
    minimum_population_fraction: f64,
    oxygen_half_saturation_g_o_per_m3: f64,
    significance_threshold_g_o: f64,
    significance_threshold_fraction: f64,
};

/// UPTAKE 1872--2600's oxygen exception (see
/// `docs/traceability/a7b_reconcile_root_gas_cluster.md`): oxygen draws
/// competitively on the same soil and root aqueous pools that `advance`
/// exchanges passively for the other five gases, so it is bound as a sibling
/// pass over the identical cell/layer/species/domain nest rather than folded
/// into `non_oxygen_gases`. Source order is UPTAKE (this function) before
/// GROSUB (`root_processes.applyRootMetabolism`), so callers must invoke this
/// before that respiration pass consumes
/// `roots.oxygen_process_constraint_fraction`.
///
/// `refreshOxygenPopulationCompetitionFraction` (UPTAKE FOXYX) couples every
/// population sharing one soil layer, so unlike the per-root non-oxygen gas
/// loop it cannot run over the whole multi-cell `roots` array in one call:
/// that would mix competition across unrelated soil columns. Each cell
/// therefore gets its own byte-identical-to-production-layout view: the same
/// backing arrays, sliced to that cell's plant range, with `plant_count`
/// reduced to match. `refreshOxygenProcessConstraint` (UPTAKE/GROSUB WFR) has
/// no such cross-plant coupling, so it runs once over the whole array after
/// the per-cell passes complete.
pub fn advanceOxygen(
    allocator: std.mem.Allocator,
    roots: *root_system.State,
    water: *const plant_water.Workspace,
    grid: *const grid_module.GridState,
    properties: *const soil_properties.State,
    soil_gas: *gas_transport.State,
    parameters: root_exchange.RuntimeParameters,
    biological_domain_count_by_plant: []const u8,
    active_by_plant: []const bool,
    previous_total_aerobic_oxygen_demand_g_o_by_soil: []const f64,
    settings: OxygenSettings,
) !root_exchange.OxygenConstraintTotals {
    try validateOxygen(roots, water, grid, properties, soil_gas, biological_domain_count_by_plant, active_by_plant, previous_total_aerobic_oxygen_demand_g_o_by_soil, settings);

    const species_per_cell = roots.plant_count / grid.cell_count;
    const domain_layer_per_cell = species_per_cell * root_system.biological_domain_count * roots.soil_layer_count;

    const layer_thickness_scratch = try allocator.alloc(f64, roots.soil_layer_count);
    defer allocator.free(layer_thickness_scratch);
    const previous_microbial_scratch = try allocator.alloc(f64, roots.soil_layer_count);
    defer allocator.free(previous_microbial_scratch);
    const total_previous_scratch = try allocator.alloc(f64, roots.soil_layer_count);
    defer allocator.free(total_previous_scratch);

    for (0..grid.cell_count) |cell| {
        const plant_first = cell * species_per_cell;
        const domain_layer_first = plant_first * root_system.biological_domain_count * roots.soil_layer_count;
        const first_soil = try grid.layerIndex(cell, 0);

        for (0..roots.soil_layer_count) |layer| {
            const soil = first_soil + layer;
            layer_thickness_scratch[layer] = properties.layer_thickness_m[soil];
            previous_microbial_scratch[layer] = previous_total_aerobic_oxygen_demand_g_o_by_soil[soil];
        }

        // A cell-scoped view: same backing memory as `roots`, windowed to
        // this cell's plant range so `refreshOxygenPopulationCompetitionFraction`
        // couples competition only within this soil column.
        var view = roots.*;
        view.plant_count = species_per_cell;
        view.oxygen_demand_g_o_per_h = roots.oxygen_demand_g_o_per_h[domain_layer_first..][0..domain_layer_per_cell];
        view.previous_oxygen_demand_g_o_per_h = roots.previous_oxygen_demand_g_o_per_h[domain_layer_first..][0..domain_layer_per_cell];
        view.population_competition_fraction_g_o = roots.population_competition_fraction_g_o[domain_layer_first..][0..domain_layer_per_cell];
        view.current_deepest_rooted_layer_by_plant = roots.current_deepest_rooted_layer_by_plant[plant_first..][0..species_per_cell];

        try root_exchange.refreshOxygenPopulationCompetitionFraction(
            &view,
            biological_domain_count_by_plant[plant_first..][0..species_per_cell],
            water.root_biome_fraction[domain_layer_first..][0..domain_layer_per_cell],
            previous_microbial_scratch,
            layer_thickness_scratch,
            settings.minimum_active_layer_thickness_m,
            settings.minimum_population_fraction,
            settings.significance_threshold_g_o,
            total_previous_scratch,
        );

        for (0..grid.active_soil_layer_count[cell]) |layer| {
            const soil = first_soil + layer;
            const soil_water_m3 = grid.matrix_liquid_water_m3[soil];
            if (soil_water_m3 <= 0) continue;
            const bulk_volume_m3 = properties.matrix_bulk_volume_m3[soil];
            const water_fraction = if (bulk_volume_m3 > 0) std.math.clamp(soil_water_m3 / bulk_volume_m3, 0, 1) else 0;
            const tortuosity = settings.liquid_tortuosity_coefficient * water_fraction * water_fraction;
            const film_m = try root_exchange.soilWaterFilmThicknessM(parameters, grid.matric_potential_megapascal[soil], layer == 0);
            const environment = try root_exchange.oxygenEnvironment(parameters, grid.soil_temperature_k[soil], 0);
            const soil_oxygen_pool = try soil_gas.dissolvedMass(soil, .oxygen);

            for (0..species_per_cell) |species| {
                const plant = plant_first + species;
                if (!active_by_plant[plant] or roots.roots_dead[plant]) continue;
                const population = water.plant_population_count[plant];
                if (population <= 0) continue;
                const domain_count = biological_domain_count_by_plant[plant];
                for (0..domain_count) |domain| {
                    const root = try roots.layerIndex(plant, domain, layer);
                    if (roots.aqueous_volume_m3[root] <= 0 or roots.root_surface_area_m2_per_plant[root] <= 0) continue;

                    // UPTAKE RTARRX/RRADS radial path, shared by the soil-facing
                    // and root-internal (DIFOP) conductances; only the
                    // tortuosity multiplier differs (`plant_root_gas_exchange.zig`
                    // Finding 4: DIFOP carries no soil-tortuosity factor).
                    const soil_to_surface_transport_m3_per_step = try root_exchange.radialAqueousConductanceM3PerH(
                        environment.aqueous_diffusivity_m2_per_h,
                        tortuosity,
                        water.root_surface_area_per_radius_m[root],
                        water.root_cylinder_radius_m[root],
                        film_m,
                    );
                    // Source gates DIFOP (root-internal O2 transport) to the
                    // primary axis only, matching the non-oxygen restriction
                    // to domain 0 above.
                    const root_internal_transport_m3_per_step = if (domain == 0) try root_exchange.radialAqueousConductanceM3PerH(
                        environment.aqueous_diffusivity_m2_per_h,
                        1.0,
                        water.root_surface_area_per_radius_m[root],
                        water.root_cylinder_radius_m[root],
                        film_m,
                    ) else 0;

                    const result = try root_exchange.solveOxygenUptake(.{
                        .soil_to_surface_transport_m3_per_step = soil_to_surface_transport_m3_per_step,
                        .root_internal_transport_m3_per_step = root_internal_transport_m3_per_step,
                        .water_advection_m3_per_step = @max(0, -roots.water_uptake_m3_per_h[root]) / population,
                        .soil_oxygen_g_o_per_m3 = soil_oxygen_pool.* / soil_water_m3,
                        .root_oxygen_g_o_per_m3 = if (roots.aqueous_volume_m3[root] > 0) roots.aqueous_oxygen_g_o[root] / roots.aqueous_volume_m3[root] else 0,
                        .oxygen_demand_g_o_per_plant_step = roots.oxygen_demand_g_o_per_h[root] / population,
                        .oxygen_half_saturation_g_o_per_m3 = settings.oxygen_half_saturation_g_o_per_m3,
                        .plant_population_count = population,
                        .population_competition_fraction = roots.population_competition_fraction_g_o[root],
                        .soil_aqueous_oxygen_g_o = soil_oxygen_pool.*,
                        .root_aqueous_oxygen_g_o = roots.aqueous_oxygen_g_o[root],
                        .significance_threshold_g_o = settings.significance_threshold_g_o,
                    });

                    try root_exchange.state_updateOxygenUptake(roots, plant, domain, layer, population, result, soil_oxygen_pool);
                }
            }
        }
    }

    const deepest_by_plant_domain = try allocator.alloc(usize, roots.plant_count * root_system.biological_domain_count);
    defer allocator.free(deepest_by_plant_domain);
    for (0..roots.plant_count) |plant| {
        for (0..root_system.biological_domain_count) |domain|
            deepest_by_plant_domain[plant * root_system.biological_domain_count + domain] = roots.current_deepest_rooted_layer_by_plant[plant];
    }

    const totals = try root_exchange.refreshOxygenProcessConstraint(
        roots,
        biological_domain_count_by_plant,
        water.root_biome_fraction,
        deepest_by_plant_domain,
        settings.significance_threshold_g_o,
        settings.significance_threshold_fraction,
    );
    try roots.validateFinite();
    return totals;
}

fn validateOxygen(
    roots: *const root_system.State,
    water: *const plant_water.Workspace,
    grid: *const grid_module.GridState,
    properties: *const soil_properties.State,
    soil_gas: *const gas_transport.State,
    domains: []const u8,
    active: []const bool,
    previous_total_aerobic_oxygen_demand_g_o_by_soil: []const f64,
    settings: OxygenSettings,
) !void {
    if (grid.cell_count == 0 or roots.plant_count % grid.cell_count != 0 or water.plant_count != roots.plant_count or
        roots.soil_layer_count != grid.soil_layer_capacity or soil_gas.cell_count != grid.layer_count or
        properties.layer_thickness_m.len != grid.layer_count or domains.len != roots.plant_count or active.len != roots.plant_count or
        previous_total_aerobic_oxygen_demand_g_o_by_soil.len != grid.layer_count)
        return error.RootOxygenTransportDimensionMismatch;
    if (!std.math.isFinite(settings.liquid_tortuosity_coefficient) or settings.liquid_tortuosity_coefficient < 0 or
        !std.math.isFinite(settings.minimum_active_layer_thickness_m) or settings.minimum_active_layer_thickness_m < 0 or
        !std.math.isFinite(settings.minimum_population_fraction) or settings.minimum_population_fraction < 0 or
        !std.math.isFinite(settings.oxygen_half_saturation_g_o_per_m3) or settings.oxygen_half_saturation_g_o_per_m3 <= 0 or
        !std.math.isFinite(settings.significance_threshold_g_o) or settings.significance_threshold_g_o < 0 or
        !std.math.isFinite(settings.significance_threshold_fraction) or settings.significance_threshold_fraction < 0)
        return error.InvalidRootOxygenTransportSettings;
    for (domains) |count| if (count == 0 or count > root_system.biological_domain_count) return error.RootOxygenTransportDimensionMismatch;
    for (previous_total_aerobic_oxygen_demand_g_o_by_soil) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootOxygenTransportInput;
}

const non_oxygen_gases = [_]root_exchange.TransportedGas{
    .carbon_dioxide,
    .methane,
    .nitrous_oxide,
    .ammonia,
    .hydrogen,
};

fn exchangeSoilAqueous(
    roots: *root_system.State,
    water: *const plant_water.Workspace,
    grid: *const grid_module.GridState,
    soil_gas: *gas_transport.State,
    parameters: root_exchange.RuntimeParameters,
    root: usize,
    soil: usize,
    gas: root_exchange.TransportedGas,
    soil_water_m3: f64,
    tortuosity: f64,
    film_m: f64,
    population: f64,
    band: bool,
) !void {
    const species = transportSpecies(gas);
    const component = try gas_transport.massIndex(soil, species, soil_gas.cell_count);
    const soil_pool = if (band) &soil_gas.band_dissolved_mass_g[component] else &soil_gas.dissolved_mass_g[component];
    const root_pool = &rootAqueousPool(roots, gas)[root];
    const biome_fraction = water.root_biome_fraction[root];
    if (biome_fraction <= 0 or soil_pool.* <= 0 and root_pool.* <= 0) return;
    const environment = try root_exchange.gasEnvironment(parameters, gas, grid.soil_temperature_k[soil], 0);
    const conductance = try root_exchange.radialAqueousConductanceM3PerH(
        environment.aqueous_diffusivity_m2_per_h,
        tortuosity,
        water.root_surface_area_per_radius_m[root],
        water.root_cylinder_radius_m[root],
        film_m,
    );
    const exchange_g = try root_exchange.soilRootAqueousExchangeG(.{
        .soil_dissolved_mass_g = soil_pool.* * biome_fraction,
        .root_dissolved_mass_g = root_pool.*,
        .soil_water_volume_m3 = soil_water_m3 * biome_fraction,
        .root_water_volume_m3 = roots.aqueous_volume_m3[root],
        .water_advection_m3_per_step = @max(0, -roots.water_uptake_m3_per_h[root]) / population,
        .aqueous_diffusive_conductance_m3_per_step = conductance,
        .plant_population_count = population,
        .equilibration_fraction = 1,
    });
    const ledger = root * root_system.transported_root_gas_count + @intFromEnum(gas);
    try root_exchange.state_updateSoilRootAqueousExchangeWithLedgerG(
        soil_pool,
        root_pool,
        &roots.soil_to_root_gas_exchange_g_per_h[ledger],
        exchange_g,
    );
    if (gas == .ammonia) {
        if (band) {
            roots.ammonia_band_soil_exchange_g_n_per_h[root] += exchange_g;
        } else {
            roots.ammonia_nonband_soil_exchange_g_n_per_h[root] += exchange_g;
        }
    }
}

fn transportSpecies(gas: root_exchange.TransportedGas) gas_transport.Species {
    return switch (gas) {
        .carbon_dioxide => .carbon_dioxide,
        .methane => .methane,
        .nitrous_oxide => .nitrous_oxide,
        .ammonia => .ammonia,
        .hydrogen => .hydrogen,
        .oxygen => .oxygen,
    };
}

fn rootGaseousPool(roots: *root_system.State, gas: root_exchange.TransportedGas) []f64 {
    return switch (gas) {
        .carbon_dioxide => roots.gaseous_carbon_dioxide_g_c,
        .methane => roots.gaseous_methane_g_c,
        .nitrous_oxide => roots.gaseous_nitrous_oxide_g_n,
        .ammonia => roots.gaseous_ammonia_g_n,
        .hydrogen => roots.gaseous_hydrogen_g_h,
        .oxygen => roots.gaseous_oxygen_g_o,
    };
}

fn rootAqueousPool(roots: *root_system.State, gas: root_exchange.TransportedGas) []f64 {
    return switch (gas) {
        .carbon_dioxide => roots.aqueous_carbon_dioxide_g_c,
        .methane => roots.aqueous_methane_g_c,
        .nitrous_oxide => roots.aqueous_nitrous_oxide_g_n,
        .ammonia => roots.aqueous_ammonia_g_n,
        .hydrogen => roots.aqueous_hydrogen_g_h,
        .oxygen => roots.aqueous_oxygen_g_o,
    };
}

fn validate(
    roots: *const root_system.State,
    water: *const plant_water.Workspace,
    grid: *const grid_module.GridState,
    properties: *const soil_properties.State,
    soil_gas: *const gas_transport.State,
    atmospheric_concentration_g_per_m3: []const f64,
    domains: []const u8,
    active: []const bool,
    settings: Settings,
) !void {
    if (grid.cell_count == 0 or roots.plant_count % grid.cell_count != 0 or water.plant_count != roots.plant_count or
        roots.soil_layer_count != grid.soil_layer_capacity or soil_gas.cell_count != grid.layer_count or
        properties.layer_thickness_m.len != grid.layer_count or atmospheric_concentration_g_per_m3.len != grid.cell_count * gas_transport.species_count or domains.len != roots.plant_count or active.len != roots.plant_count)
        return error.RootGasTransportDimensionMismatch;
    if (!std.math.isFinite(settings.liquid_tortuosity_coefficient) or settings.liquid_tortuosity_coefficient < 0 or
        !std.math.isFinite(settings.minimum_aqueous_volume_m3) or settings.minimum_aqueous_volume_m3 <= 0 or
        !std.math.isFinite(settings.minimum_gaseous_volume_m3) or settings.minimum_gaseous_volume_m3 <= 0 or
        !std.math.isFinite(settings.minimum_root_surface_area_m2) or settings.minimum_root_surface_area_m2 <= 0 or
        !std.math.isFinite(settings.relative_tolerance) or settings.relative_tolerance <= 0 or settings.maximum_iterations == 0)
        return error.InvalidRootGasTransportSettings;
    for (settings.absolute_tolerance_g_by_species) |tolerance_g| if (!std.math.isFinite(tolerance_g) or tolerance_g <= 0) return error.InvalidRootGasTransportSettings;
    for (domains) |count| if (count == 0 or count > root_system.biological_domain_count) return error.RootGasTransportDimensionMismatch;
}

const config_module = @import("../../core/config.zig");
const retention_module = @import("../../soil/water/retention.zig");

// Proves the `EXEC-O2-BALANCE-007` binding is live from a production-shaped
// entry point, not merely exercised by `plant_root_gas_exchange.zig`'s own
// unit tests: two cells, two competing species per cell, one aerobic (soil
// oxygen present) and one anaerobic (soil oxygen absent, root-internal
// fallback only). It also proves the per-cell windowing that
// `refreshOxygenPopulationCompetitionFraction` requires: the two cells carry
// deliberately different previous-hour demand ratios (1:3 versus 3:1), and
// only a caller that scopes the competition refresh to one soil column at a
// time can reproduce both ratios exactly. A caller that accidentally passed
// the whole multi-cell array through in one call would pool all four
// populations' previous demand into one denominator and report a uniform,
// wrong fraction for every plant instead.
test "advanceOxygen debits soil and root aqueous O2 through the production entry point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cfg = try config_module.SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 2 },
        .{ .worker_threads = 1, .tile_cells = 64 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-11, .max_nonlinear_iterations = 40 },
    );
    var grid = try grid_module.GridState.init(allocator, cfg);
    for (0..grid.layer_count) |soil| {
        grid.matrix_liquid_water_m3[soil] = 1.0;
        grid.matric_potential_megapascal[soil] = -0.05;
    }

    var properties: soil_properties.State = .{
        .allocator = allocator,
        .layer_count = grid.layer_count,
        .retention_curve = try allocator.alloc(retention_module.ResolvedCurve, 0),
        .matrix_bulk_volume_m3 = try allocator.alloc(f64, grid.layer_count),
        .layer_volume_m3 = try allocator.alloc(f64, grid.layer_count),
        .layer_thickness_m = try allocator.alloc(f64, grid.layer_count),
        .layer_midpoint_depth_m = try allocator.alloc(f64, grid.layer_count),
        .layer_bottom_depth_m = try allocator.alloc(f64, grid.layer_count),
        .bulk_density_megagrams_per_m3 = try allocator.alloc(f64, grid.layer_count),
        .sand_mass_fraction = try allocator.alloc(f64, grid.layer_count),
        .silt_mass_fraction = try allocator.alloc(f64, grid.layer_count),
        .clay_mass_fraction = try allocator.alloc(f64, grid.layer_count),
        .sand_mass_megagrams = try allocator.alloc(f64, grid.layer_count),
        .silt_mass_megagrams = try allocator.alloc(f64, grid.layer_count),
        .clay_mass_megagrams = try allocator.alloc(f64, grid.layer_count),
        .total_organic_carbon_g_per_megagram = try allocator.alloc(f64, grid.layer_count),
        .cation_exchange_capacity_mol_per_megagram = try allocator.alloc(f64, grid.layer_count),
        .anion_exchange_capacity_mol_per_megagram = try allocator.alloc(f64, grid.layer_count),
        .cation_exchange_capacity_mol = try allocator.alloc(f64, grid.layer_count),
        .anion_exchange_capacity_mol = try allocator.alloc(f64, grid.layer_count),
        .porosity_fraction = try allocator.alloc(f64, grid.layer_count),
        .micropore_fraction = try allocator.alloc(f64, grid.layer_count),
        .macropore_fraction = try allocator.alloc(f64, grid.layer_count),
        .rock_fraction = try allocator.alloc(f64, grid.layer_count),
        .supplied_field_capacity_fraction = try allocator.alloc(f64, grid.layer_count),
        .supplied_wilting_point_fraction = try allocator.alloc(f64, grid.layer_count),
        .field_capacity_water_potential_megapascal = try allocator.alloc(f64, grid.layer_count),
        .wilting_point_water_potential_megapascal = try allocator.alloc(f64, grid.layer_count),
        .supplied_vertical_saturated_hydraulic_conductivity_m_per_h = try allocator.alloc(f64, grid.layer_count),
        .supplied_lateral_saturated_hydraulic_conductivity_m_per_h = try allocator.alloc(f64, grid.layer_count),
        .supplied_lateral_conductivity_m2_per_h_megapascal = try allocator.alloc(f64, grid.layer_count),
        .van_genuchten_inflection_pressure_head_m = try allocator.alloc(f64, grid.layer_count),
        .charcoal_retention_increment_fraction = try allocator.alloc(f64, grid.layer_count),
        .previous_charcoal_carbon_g_c = try allocator.alloc(f64, grid.layer_count),
        .field_capacity_fraction = try allocator.alloc(f64, grid.layer_count),
        .wilting_point_fraction = try allocator.alloc(f64, grid.layer_count),
        .saturation_water_potential_megapascal = try allocator.alloc(f64, grid.layer_count),
        .rainfall_conductivity_multiplier = try allocator.alloc(f64, grid.layer_count),
        .saturated_lateral_conductivity_m2_per_h_megapascal = try allocator.alloc(f64, grid.layer_count),
    };
    @memset(properties.matrix_bulk_volume_m3, 1.0);
    @memset(properties.layer_thickness_m, 0.1);
    @memset(properties.previous_charcoal_carbon_g_c, 0);

    var soil_gas = try gas_transport.State.init(allocator, grid.layer_count);
    // Cell 0 has plenty of dissolved soil oxygen; cell 1 has none, forcing
    // its plants onto the root-internal (DIFOP) fallback path exclusively.
    (try soil_gas.dissolvedMass(0, .oxygen)).* = 1.0;
    (try soil_gas.dissolvedMass(1, .oxygen)).* = 0.0;

    var roots = try root_system.State.init(allocator, 4, 1, 1);
    @memset(roots.roots_dead, false);
    var water = try plant_water.Workspace.init(allocator, 2, 2, 1);
    @memset(water.plant_population_count, 10);

    // Plants 0,1 share cell 0 (soil available); plants 2,3 share cell 1
    // (soil unavailable). Demand ratios are deliberately mirror-imaged
    // (1:3 in cell 0, 3:1 in cell 1) so cross-cell leakage would be visible
    // as a uniform, wrong ratio in both cells instead of the correct,
    // opposite ratios.
    const demand_g_o_per_h = [4]f64{ 0.001, 0.003, 0.006, 0.002 };
    const biome_fraction = [4]f64{ 0.25, 0.75, 0.75, 0.25 };
    for (0..4) |plant| {
        const root = try roots.layerIndex(plant, 0, 0);
        roots.oxygen_demand_g_o_per_h[root] = demand_g_o_per_h[plant];
        roots.previous_oxygen_demand_g_o_per_h[root] = demand_g_o_per_h[plant];
        water.root_biome_fraction[root] = biome_fraction[plant];
        roots.aqueous_volume_m3[root] = 0.01;
        roots.root_surface_area_m2_per_plant[root] = 0.01;
        water.root_surface_area_per_radius_m[root] = 30;
        water.root_cylinder_radius_m[root] = 1.0e-4;
        // Cell 0 (plants 0,1): root-internal concentration matches the
        // ample soil concentration exactly, which keeps
        // `solveOxygenUptake`'s internal flux algebraically non-negative
        // regardless of the exact uptake magnitude. Cell 1 (plants 2,3):
        // soil is unavailable, so this is the population's only oxygen
        // source.
        roots.aqueous_oxygen_g_o[root] = 0.01;
    }

    const biological_domain_count_by_plant = [4]u8{ 1, 1, 1, 1 };
    const active_by_plant = [4]bool{ true, true, true, true };
    // No microbial competition, to isolate the root/root competition ratio.
    const previous_total_aerobic_oxygen_demand_g_o_by_soil = [_]f64{ 0, 0 };

    const totals = try advanceOxygen(
        allocator,
        &roots,
        &water,
        &grid,
        &properties,
        &soil_gas,
        root_exchange.compatibilityParameters(),
        &biological_domain_count_by_plant,
        &active_by_plant,
        &previous_total_aerobic_oxygen_demand_g_o_by_soil,
        .{
            .liquid_tortuosity_coefficient = 0.3,
            .minimum_active_layer_thickness_m = 0.01,
            .minimum_population_fraction = 0.01,
            .oxygen_half_saturation_g_o_per_m3 = 0.064,
            .significance_threshold_g_o = 1.0e-9,
            .significance_threshold_fraction = 1.0e-9,
        },
    );

    // The per-cell competition windowing reproduces the exact, opposite
    // ratios; a caller that mixed the two cells' plants together could not
    // report both 0.25/0.75 (cell 0) and 0.75/0.25 (cell 1).
    const root0 = try roots.layerIndex(0, 0, 0);
    const root1 = try roots.layerIndex(1, 0, 0);
    const root2 = try roots.layerIndex(2, 0, 0);
    const root3 = try roots.layerIndex(3, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), roots.population_competition_fraction_g_o[root0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), roots.population_competition_fraction_g_o[root1], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), roots.population_competition_fraction_g_o[root2], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), roots.population_competition_fraction_g_o[root3], 1.0e-12);

    // Liveness: the solver's output is no longer a structural zero anywhere
    // reachable from this production entry point.
    try std.testing.expect(roots.oxygen_uptake_g_o_per_h[root0] > 0);
    try std.testing.expect(roots.oxygen_uptake_g_o_per_h[root1] > 0);
    try std.testing.expect(roots.oxygen_uptake_g_o_per_h[root2] > 0);
    try std.testing.expect(roots.oxygen_uptake_g_o_per_h[root3] > 0);
    try std.testing.expect(roots.oxygen_process_constraint_fraction[root0] > 0);
    try std.testing.expect(roots.oxygen_process_constraint_fraction[root1] > 0);
    try std.testing.expect(roots.oxygen_process_constraint_fraction[root2] > 0);
    try std.testing.expect(roots.oxygen_process_constraint_fraction[root3] > 0);
    try std.testing.expect(totals.uptake_g_o_per_h > 0);

    // The soil pool in cell 0 was actually debited; cell 1's pool stays at
    // its structural zero (there was nothing to draw), and its plants drew
    // only from their own root-internal reservoir instead.
    try std.testing.expect((try soil_gas.dissolvedMass(0, .oxygen)).* < 1.0);
    try std.testing.expect((try soil_gas.dissolvedMass(0, .oxygen)).* > 0);
    try std.testing.expectEqual(@as(f64, 0), (try soil_gas.dissolvedMass(1, .oxygen)).*);
    try std.testing.expect(roots.aqueous_oxygen_g_o[root2] < 0.01);
    try std.testing.expect(roots.aqueous_oxygen_g_o[root3] < 0.01);
}

test "NH3 nonband and band root exchange conserves one canonical donor exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cfg = try config_module.SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(allocator, cfg);
    grid.soil_temperature_k[0] = 298.15;
    var soil_gas = try gas_transport.State.init(allocator, 1);
    const ammonia = @intFromEnum(gas_transport.Species.ammonia);
    soil_gas.dissolved_mass_g[ammonia] = 1;
    soil_gas.band_dissolved_mass_g[ammonia] = 0.5;
    var roots = try root_system.State.init(allocator, 1, 1, 1);
    var water = try plant_water.Workspace.init(allocator, 1, 1, 1);
    const root = try roots.layerIndex(0, 0, 0);
    roots.aqueous_ammonia_g_n[root] = 0.1;
    roots.aqueous_volume_m3[root] = 0.02;
    water.root_biome_fraction[root] = 1;
    water.plant_population_count[0] = 10;
    water.root_surface_area_per_radius_m[root] = 30;
    water.root_cylinder_radius_m[root] = 1e-4;
    const before = soil_gas.dissolved_mass_g[ammonia] + soil_gas.band_dissolved_mass_g[ammonia] + roots.aqueous_ammonia_g_n[root];
    try exchangeSoilAqueous(&roots, &water, &grid, &soil_gas, root_exchange.compatibilityParameters(), root, 0, .ammonia, 0.75, 0.3, 0.001, 10, false);
    try exchangeSoilAqueous(&roots, &water, &grid, &soil_gas, root_exchange.compatibilityParameters(), root, 0, .ammonia, 0.25, 0.3, 0.001, 10, true);
    const after = soil_gas.dissolved_mass_g[ammonia] + soil_gas.band_dissolved_mass_g[ammonia] + roots.aqueous_ammonia_g_n[root];
    const tolerance = 64 * std.math.floatEps(f64) * @max(1, @abs(before));
    try std.testing.expectApproxEqAbs(before, after, tolerance);
    const ledger = root * root_system.transported_root_gas_count + @intFromEnum(root_exchange.TransportedGas.ammonia);
    try std.testing.expectApproxEqAbs(
        roots.aqueous_ammonia_g_n[root] - 0.1,
        roots.soil_to_root_gas_exchange_g_per_h[ledger],
        tolerance,
    );
    try std.testing.expectApproxEqAbs(
        roots.soil_to_root_gas_exchange_g_per_h[ledger],
        roots.ammonia_nonband_soil_exchange_g_n_per_h[root] + roots.ammonia_band_soil_exchange_g_n_per_h[root],
        tolerance,
    );
}
