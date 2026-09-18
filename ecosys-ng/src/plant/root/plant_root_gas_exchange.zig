const std = @import("std");
const plant_root_system = @import("plant_root_system.zig");
const rooted_layer_eligibility = @import("rooted_layer_eligibility.zig");
const numerics = @import("../../core/numerics.zig");
const PlantRootState = plant_root_system.State;

pub const TransportedGas = enum(u8) {
    carbon_dioxide,
    methane,
    nitrous_oxide,
    ammonia,
    hydrogen,
    oxygen,
};
pub const transported_gas_count = @typeInfo(TransportedGas).@"enum".fields.len;

pub const RuntimeParameters = struct {
    reference_temperature_k: f64,
    gaseous_diffusivity_m2_per_h_at_reference: [transported_gas_count]f64,
    aqueous_diffusivity_m2_per_h_at_reference: [transported_gas_count]f64,
    water_to_air_mass_solubility_at_25c: [transported_gas_count]f64,
    solubility_activity_coefficient: [transported_gas_count]f64,
    solubility_temperature_intercept: [transported_gas_count]f64,
    solubility_temperature_coefficient_per_c: [transported_gas_count]f64,
    gaseous_diffusivity_temperature_exponent: f64,
    oxygen_aqueous_diffusivity_m2_per_h_at_reference: f64,
    aqueous_diffusivity_temperature_exponent: f64,
    oxygen_solubility_at_25c: f64,
    oxygen_solubility_activity_coefficient: f64,
    oxygen_solubility_temperature_intercept: f64,
    oxygen_solubility_temperature_coefficient_per_c: f64,
    pure_water_solute_concentration_mol_per_m3: f64,
    oxygen_to_carbon_respiration_ratio_g_o_per_g_c: f64,
    minimum_soil_water_film_m: f64,
    soil_water_film_scale_m: f64,
    soil_water_film_log_intercept: f64,
    /// `watsub.f:3796`/`:3801`: litter and the surface soil layer (`NUM`)
    /// use a distinct log intercept from every layer below them
    /// (`soil_water_film_log_intercept`, `watsub.f:5223`). The vertical
    /// destination in that lower loop is always `L+1` or deeper, so the
    /// surface layer's own value is never overwritten by the other one.
    soil_water_film_surface_log_intercept: f64,
    soil_water_film_potential_exponent: f64,
};

/// Source HOUR1/UPTAKE coefficients represented as a runtime value. This is a
/// compatibility initializer, not a compile-time dimensional parameter.
pub fn compatibilityParameters() RuntimeParameters {
    return .{
        .reference_temperature_k = 298.15,
        .gaseous_diffusivity_m2_per_h_at_reference = .{ 4.68e-2, 7.80e-2, 5.57e-2, 6.67e-2, 5.57e-2, 6.43e-2 },
        .aqueous_diffusivity_m2_per_h_at_reference = .{ 4.25e-6, 7.08e-6, 5.72e-6, 4.00e-6, 7.34e-6, 8.57e-6 },
        .water_to_air_mass_solubility_at_25c = .{ 7.391e-1, 3.156e-2, 5.241e-1, 2.852e2, 3.156e-2, 2.925e-2 },
        .solubility_activity_coefficient = .{ 0.14, 0.14, 0.23, 0.07, 0.14, 0.31 },
        .solubility_temperature_intercept = .{ 0.843, 0.597, 0.897, 0.513, 0.597, 0.516 },
        .solubility_temperature_coefficient_per_c = .{ 0.0281, 0.0199, 0.0299, 0.0171, 0.0199, 0.0172 },
        .gaseous_diffusivity_temperature_exponent = 1.75,
        .oxygen_aqueous_diffusivity_m2_per_h_at_reference = 8.57e-6,
        .aqueous_diffusivity_temperature_exponent = 6,
        .oxygen_solubility_at_25c = 2.925e-2,
        .oxygen_solubility_activity_coefficient = 0.31,
        .oxygen_solubility_temperature_intercept = 0.516,
        .oxygen_solubility_temperature_coefficient_per_c = 0.0172,
        .pure_water_solute_concentration_mol_per_m3 = 5.56e4,
        .oxygen_to_carbon_respiration_ratio_g_o_per_g_c = 2.667,
        .minimum_soil_water_film_m = 1.0e-6,
        .soil_water_film_scale_m = 0.5,
        .soil_water_film_log_intercept = -13.833,
        .soil_water_film_surface_log_intercept = -13.650,
        .soil_water_film_potential_exponent = -0.857,
    };
}

pub const OxygenEnvironment = struct {
    aqueous_diffusivity_m2_per_h: f64,
    water_to_air_mass_solubility_ratio: f64,
};

pub fn validateRuntimeParameters(parameters: RuntimeParameters) !void {
    inline for (@typeInfo(RuntimeParameters).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(parameters, field.name))) return error.NonFiniteRootGasParameter;
    inline for (.{
        parameters.gaseous_diffusivity_m2_per_h_at_reference,
        parameters.aqueous_diffusivity_m2_per_h_at_reference,
        parameters.water_to_air_mass_solubility_at_25c,
        parameters.solubility_activity_coefficient,
        parameters.solubility_temperature_intercept,
        parameters.solubility_temperature_coefficient_per_c,
    }) |values| for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootGasParameter;
    if (parameters.reference_temperature_k <= 0 or parameters.gaseous_diffusivity_temperature_exponent < 0 or parameters.oxygen_aqueous_diffusivity_m2_per_h_at_reference < 0 or parameters.aqueous_diffusivity_temperature_exponent < 0 or parameters.oxygen_solubility_at_25c < 0 or parameters.oxygen_solubility_activity_coefficient < 0 or parameters.oxygen_solubility_temperature_coefficient_per_c < 0 or parameters.pure_water_solute_concentration_mol_per_m3 <= 0 or parameters.oxygen_to_carbon_respiration_ratio_g_o_per_g_c < 0 or parameters.minimum_soil_water_film_m <= 0 or parameters.soil_water_film_scale_m <= 0) return error.InvalidRootGasParameter;
    for (parameters.gaseous_diffusivity_m2_per_h_at_reference) |value| if (value < 0) return error.InvalidRootGasParameter;
    for (parameters.aqueous_diffusivity_m2_per_h_at_reference) |value| if (value < 0) return error.InvalidRootGasParameter;
    for (parameters.water_to_air_mass_solubility_at_25c) |value| if (value < 0) return error.InvalidRootGasParameter;
    for (parameters.solubility_activity_coefficient) |value| if (value < 0) return error.InvalidRootGasParameter;
    for (parameters.solubility_temperature_coefficient_per_c) |value| if (value < 0) return error.InvalidRootGasParameter;
}

pub const GasEnvironment = struct {
    gaseous_diffusivity_m2_per_h: f64,
    aqueous_diffusivity_m2_per_h: f64,
    water_to_air_mass_solubility_ratio: f64,
};

/// HOUR1 temperature and ion-activity response for any transported root gas.
pub fn gasEnvironment(parameters: RuntimeParameters, gas: TransportedGas, soil_temperature_k: f64, total_ion_activity_mol_per_m3: f64) !GasEnvironment {
    try validateRuntimeParameters(parameters);
    if (!std.math.isFinite(soil_temperature_k) or soil_temperature_k <= 0 or !std.math.isFinite(total_ion_activity_mol_per_m3) or total_ion_activity_mol_per_m3 < 0) return error.InvalidRootGasEnvironment;
    const index = @intFromEnum(gas);
    const temperature_c = soil_temperature_k - 273.15;
    const water_solute_fraction = parameters.pure_water_solute_concentration_mol_per_m3 /
        (parameters.pure_water_solute_concentration_mol_per_m3 + total_ion_activity_mol_per_m3);
    const result = GasEnvironment{
        .gaseous_diffusivity_m2_per_h = parameters.gaseous_diffusivity_m2_per_h_at_reference[index] *
            std.math.pow(f64, soil_temperature_k / parameters.reference_temperature_k, parameters.gaseous_diffusivity_temperature_exponent),
        .aqueous_diffusivity_m2_per_h = parameters.aqueous_diffusivity_m2_per_h_at_reference[index] *
            std.math.pow(f64, soil_temperature_k / parameters.reference_temperature_k, parameters.aqueous_diffusivity_temperature_exponent),
        .water_to_air_mass_solubility_ratio = parameters.water_to_air_mass_solubility_at_25c[index] /
            @exp(parameters.solubility_activity_coefficient[index]) *
            @exp(parameters.solubility_temperature_intercept[index] - parameters.solubility_temperature_coefficient_per_c[index] * temperature_c) *
            water_solute_fraction,
    };
    inline for (@typeInfo(GasEnvironment).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.NonFiniteRootGasEnvironment;
    return result;
}

/// WATSUB soil FILM equation used by UPTAKE and NITRO radial diffusion.
/// `is_surface_layer` selects `watsub.f:3796`/`:3801`'s litter/surface-layer
/// log intercept over `:5223`'s value for every layer below the surface.
pub fn soilWaterFilmThicknessM(parameters: RuntimeParameters, matric_potential_megapascal: f64, is_surface_layer: bool) !f64 {
    try validateRuntimeParameters(parameters);
    if (!std.math.isFinite(matric_potential_megapascal) or matric_potential_megapascal > 0) return error.InvalidSoilMatricPotentialForWaterFilm;
    const suction_megapascal =
        @max(std.math.floatMin(f64), -matric_potential_megapascal);
    const log_intercept = if (is_surface_layer) parameters.soil_water_film_surface_log_intercept else parameters.soil_water_film_log_intercept;
    const film = parameters.soil_water_film_scale_m * @exp(log_intercept + parameters.soil_water_film_potential_exponent * @log(suction_megapascal));
    if (!std.math.isFinite(film)) return error.NonFiniteSoilWaterFilm;
    return @max(parameters.minimum_soil_water_film_m, film);
}

/// UPTAKE logarithmic radial path and RTARRX aqueous conductance geometry.
pub fn radialAqueousConductanceM3PerH(aqueous_diffusivity_m2_per_h: f64, tortuosity_water_fraction: f64, root_surface_area_per_radius_m: f64, root_radius_m: f64, water_film_thickness_m: f64) !f64 {
    inline for (.{ aqueous_diffusivity_m2_per_h, tortuosity_water_fraction, root_surface_area_per_radius_m, root_radius_m, water_film_thickness_m }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootAqueousDiffusionInput;
    if (root_radius_m <= 0 or water_film_thickness_m <= 0) return error.InvalidRootAqueousDiffusionInput;
    const radial_path = @log((water_film_thickness_m + root_radius_m) / root_radius_m);
    if (radial_path <= 0) return error.InvalidRootAqueousDiffusionPath;
    const conductance = tortuosity_water_fraction * aqueous_diffusivity_m2_per_h * root_surface_area_per_radius_m / radial_path;
    if (!std.math.isFinite(conductance)) return error.NonFiniteRootAqueousDiffusion;
    return conductance;
}

/// HOUR1 TFACL, FH2O and SOXYL equations.
pub fn oxygenEnvironment(parameters: RuntimeParameters, soil_temperature_k: f64, total_ion_activity_mol_per_m3: f64) !OxygenEnvironment {
    const environment = try gasEnvironment(parameters, .oxygen, soil_temperature_k, total_ion_activity_mol_per_m3);
    return .{
        .aqueous_diffusivity_m2_per_h = environment.aqueous_diffusivity_m2_per_h,
        .water_to_air_mass_solubility_ratio = environment.water_to_air_mass_solubility_ratio,
    };
}

/// UPTAKE ROXYP = 2.667 * RCO2M for every runtime root/mycorrhizal layer.
pub fn refreshOxygenDemand(roots: *PlantRootState, parameters: RuntimeParameters) !void {
    _ = try oxygenEnvironment(parameters, parameters.reference_temperature_k, 0);
    if (roots.oxygen_demand_g_o_per_h.len != roots.respiration_unlimited_by_oxygen_g_c_per_h.len) return error.PlantRootGasDimensionMismatch;
    for (roots.respiration_unlimited_by_oxygen_g_c_per_h, roots.oxygen_demand_g_o_per_h) |respiration, *demand| {
        if (!std.math.isFinite(respiration) or respiration < 0) return error.InvalidRootRespiration;
        demand.* = parameters.oxygen_to_carbon_respiration_ratio_g_o_per_g_c * respiration;
        if (!std.math.isFinite(demand.*)) return error.NonFiniteRootOxygenDemand;
    }
}

/// UPTAKE/NITRO/EXTRACT/REDIST FOXYX for O2: `uptake.f:1810-1814`. Every
/// admitted root/mycorrhizal population's competition-for-O2 fraction is the
/// larger of the source minimum-share floor (`FPP = FMN * FPQ`) and its own
/// share of the combined previous-hour O2 demand at that soil layer
/// (`ROXYP/ROXYY`); when the combined previous-hour demand is not significant
/// the biome root fraction (`FPQ`) is retained unconditionally, exactly as the
/// source `ROXYY.GT.ZEROS` guard avoids a divide-by-zero. Both demand
/// components are strictly previous-hour (microbial `previous_total_...` and
/// root/mycorrhizal `previous_oxygen_demand_g_o_per_h`, both snapshotted
/// before this hour's own demand is computed), so a population's own
/// same-hour demand cannot influence its own same-hour fraction.
///
/// `total_previous_oxygen_demand_g_o_by_layer` is caller-owned scratch sized
/// `roots.soil_layer_count`; its contents on entry are ignored and it is
/// fully overwritten. This mirrors the admission topology already used by
/// `root_processes_uptake.applyRootNutrientUptake`, but is a small,
/// standalone, allocation-free function so it can be exercised directly in
/// unit tests without a grid/cell workspace.
pub fn refreshOxygenPopulationCompetitionFraction(
    roots: *PlantRootState,
    biological_domain_count_by_plant: []const u8,
    root_biome_fraction: []const f64,
    previous_total_microbial_oxygen_demand_g_o: []const f64,
    layer_thickness_m: []const f64,
    minimum_active_layer_thickness_m: f64,
    minimum_population_fraction: f64,
    significance_threshold_g_o: f64,
    total_previous_oxygen_demand_g_o_by_layer: []f64,
) !void {
    if (root_biome_fraction.len != roots.oxygen_demand_g_o_per_h.len or
        root_biome_fraction.len != roots.previous_oxygen_demand_g_o_per_h.len or
        root_biome_fraction.len != roots.population_competition_fraction_g_o.len)
        return error.PlantRootGasDimensionMismatch;
    if (previous_total_microbial_oxygen_demand_g_o.len != roots.soil_layer_count or
        layer_thickness_m.len != roots.soil_layer_count or
        total_previous_oxygen_demand_g_o_by_layer.len != roots.soil_layer_count)
        return error.PlantRootGasDimensionMismatch;
    if (biological_domain_count_by_plant.len != roots.plant_count) return error.PlantRootGasDimensionMismatch;
    if (!std.math.isFinite(minimum_active_layer_thickness_m) or minimum_active_layer_thickness_m < 0)
        return error.InvalidRootOxygenCompetitionInput;
    if (!std.math.isFinite(minimum_population_fraction) or minimum_population_fraction < 0)
        return error.InvalidRootOxygenCompetitionInput;
    if (!std.math.isFinite(significance_threshold_g_o) or significance_threshold_g_o < 0)
        return error.InvalidRootOxygenCompetitionInput;
    for (previous_total_microbial_oxygen_demand_g_o) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidRootOxygenCompetitionInput;

    @memcpy(total_previous_oxygen_demand_g_o_by_layer, previous_total_microbial_oxygen_demand_g_o);

    for (0..roots.plant_count) |plant| {
        if (biological_domain_count_by_plant[plant] < 1 or biological_domain_count_by_plant[plant] > plant_root_system.biological_domain_count)
            return error.PlantRootGasDimensionMismatch;
        var iterator = try rooted_layer_eligibility.Iterator.init(.{
            .plant = plant,
            .active_biological_domain_count = biological_domain_count_by_plant[plant],
            .first_active_soil_layer = 0,
            .deepest_rooted_soil_layer = roots.current_deepest_rooted_layer_by_plant[plant],
            .layer_thickness_m = layer_thickness_m,
            .minimum_active_layer_thickness_m = minimum_active_layer_thickness_m,
        });
        while (iterator.next()) |coordinate| {
            const root = try roots.layerIndex(coordinate.plant, coordinate.biological_domain, coordinate.soil_layer);
            const demand = roots.previous_oxygen_demand_g_o_per_h[root];
            if (!std.math.isFinite(demand) or demand < 0) return error.InvalidRootOxygenCompetitionInput;
            total_previous_oxygen_demand_g_o_by_layer[coordinate.soil_layer] += demand;
        }
    }
    for (total_previous_oxygen_demand_g_o_by_layer) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteRootOxygenCompetitionTotal;

    for (0..roots.plant_count) |plant| {
        var iterator = try rooted_layer_eligibility.Iterator.init(.{
            .plant = plant,
            .active_biological_domain_count = biological_domain_count_by_plant[plant],
            .first_active_soil_layer = 0,
            .deepest_rooted_soil_layer = roots.current_deepest_rooted_layer_by_plant[plant],
            .layer_thickness_m = layer_thickness_m,
            .minimum_active_layer_thickness_m = minimum_active_layer_thickness_m,
        });
        while (iterator.next()) |coordinate| {
            const root = try roots.layerIndex(coordinate.plant, coordinate.biological_domain, coordinate.soil_layer);
            const biome = root_biome_fraction[root];
            if (!std.math.isFinite(biome) or biome < 0) return error.InvalidRootOxygenCompetitionInput;
            const total = total_previous_oxygen_demand_g_o_by_layer[coordinate.soil_layer];
            const own = roots.previous_oxygen_demand_g_o_per_h[root];
            const fraction = if (total > significance_threshold_g_o)
                @max(minimum_population_fraction * biome, own / total)
            else
                biome;
            if (!std.math.isFinite(fraction)) return error.NonFiniteRootOxygenCompetitionFraction;
            roots.population_competition_fraction_g_o[root] = fraction;
        }
    }
}

/// UPTAKE OSTR: plant-wide oxygen-limited uptake divided by unlimited demand,
/// summed across both root and mycorrhizal domains and every runtime layer.
pub fn fillPlantOxygenUptakeToDemandFraction(roots: *const PlantRootState, biological_domain_count_by_plant: []const u8, output: []f64) !void {
    if (output.len != roots.plant_count or biological_domain_count_by_plant.len != roots.plant_count) return error.PlantRootGasDimensionMismatch;
    for (0..roots.plant_count) |plant| {
        const biological_domain_count = biological_domain_count_by_plant[plant];
        if (biological_domain_count < 1 or biological_domain_count > plant_root_system.biological_domain_count)
            return error.PlantRootGasDimensionMismatch;
        var uptake_g_o_per_h: f64 = 0;
        var demand_g_o_per_h: f64 = 0;
        for (0..biological_domain_count) |domain| for (0..roots.soil_layer_count) |layer| {
            const index = try roots.layerIndex(plant, domain, layer);
            const uptake = roots.oxygen_uptake_g_o_per_h[index];
            const demand = roots.oxygen_demand_g_o_per_h[index];
            if (!std.math.isFinite(uptake) or uptake < 0 or !std.math.isFinite(demand) or demand < 0) return error.InvalidRootOxygenConstraintState;
            uptake_g_o_per_h += uptake;
            demand_g_o_per_h += demand;
        };
        output[plant] = if (demand_g_o_per_h > 0) std.math.clamp(uptake_g_o_per_h / demand_g_o_per_h, 0, 1) else 0;
        if (!std.math.isFinite(output[plant])) return error.NonFiniteRootOxygenConstraintTotals;
    }
}

test "UPTAKE OSTR aggregates all runtime root domains and layers per plant" {
    var roots = try PlantRootState.init(std.testing.allocator, 2, 3, 1);
    defer roots.deinit();
    for (0..plant_root_system.biological_domain_count) |domain| for (0..3) |layer| {
        const index = try roots.layerIndex(0, domain, layer);
        roots.oxygen_uptake_g_o_per_h[index] = 1;
        roots.oxygen_demand_g_o_per_h[index] = 4;
    };
    const inactive_mycorrhizal_layer = try roots.layerIndex(1, 1, 0);
    roots.oxygen_uptake_g_o_per_h[inactive_mycorrhizal_layer] = 9;
    roots.oxygen_demand_g_o_per_h[inactive_mycorrhizal_layer] = 10;
    var output: [2]f64 = undefined;
    const biological_domain_counts = [_]u8{ 2, 1 };
    try fillPlantOxygenUptakeToDemandFraction(&roots, &biological_domain_counts, &output);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), output[0], 1.0e-15);
    try std.testing.expectEqual(@as(f64, 0), output[1]);
}

/// UPTAKE WFR and profile OSTRN/OSTRD accounting. Layers below the deepest
/// active root layer inherit the preceding layer constraint; other inactive
/// layers remain unconstrained exactly as in the source branch.
pub const OxygenConstraintTotals = struct {
    uptake_g_o_per_h: f64,
    demand_g_o_per_h: f64,
};

pub fn refreshOxygenProcessConstraint(
    roots: *PlantRootState,
    biological_domain_count_by_plant: []const u8,
    root_biome_fraction: []const f64,
    deepest_active_layer_by_plant_domain: []const usize,
    significance_threshold_g_o: f64,
    significance_threshold_fraction: f64,
) !OxygenConstraintTotals {
    const expected_domains = try std.math.mul(usize, roots.plant_count, plant_root_system.biological_domain_count);
    if (root_biome_fraction.len != roots.oxygen_demand_g_o_per_h.len or deepest_active_layer_by_plant_domain.len != expected_domains or biological_domain_count_by_plant.len != roots.plant_count) return error.PlantRootGasDimensionMismatch;
    if (!std.math.isFinite(significance_threshold_g_o) or significance_threshold_g_o < 0 or !std.math.isFinite(significance_threshold_fraction) or significance_threshold_fraction < 0) return error.InvalidRootOxygenConstraintInput;
    var totals: OxygenConstraintTotals = .{ .uptake_g_o_per_h = 0, .demand_g_o_per_h = 0 };
    for (0..roots.plant_count) |plant| for (0..biological_domain_count_by_plant[plant]) |domain| {
        if (biological_domain_count_by_plant[plant] < 1 or biological_domain_count_by_plant[plant] > plant_root_system.biological_domain_count)
            return error.PlantRootGasDimensionMismatch;
        const deepest = deepest_active_layer_by_plant_domain[plant * plant_root_system.biological_domain_count + domain];
        if (deepest >= roots.soil_layer_count) return error.InvalidDeepestRootLayer;
        for (0..roots.soil_layer_count) |layer| {
            const index = try roots.layerIndex(plant, domain, layer);
            const demand = roots.oxygen_demand_g_o_per_h[index];
            const uptake = roots.oxygen_uptake_g_o_per_h[index];
            const fraction = root_biome_fraction[index];
            inline for (.{ demand, uptake, roots.aqueous_volume_m3[index], fraction }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootOxygenConstraintState;
            if (demand > significance_threshold_g_o and roots.aqueous_volume_m3[index] > significance_threshold_g_o and fraction > significance_threshold_fraction) {
                roots.oxygen_process_constraint_fraction[index] = std.math.clamp(uptake / demand, 0, 1);
            } else if (layer > deepest) {
                roots.oxygen_process_constraint_fraction[index] = roots.oxygen_process_constraint_fraction[index - 1];
            } else {
                roots.oxygen_process_constraint_fraction[index] = 1;
            }
            totals.demand_g_o_per_h += demand;
            totals.uptake_g_o_per_h += uptake;
        }
    };
    if (!std.math.isFinite(totals.demand_g_o_per_h) or !std.math.isFinite(totals.uptake_g_o_per_h)) return error.NonFiniteRootOxygenConstraintTotals;
    return totals;
}

/// UPTAKE RTCR1/RTCR2/RTCRA root-atmosphere gas-transfer geometry.
pub fn rootGasCrossSectionPerLengthM(
    plant_population_count: f64,
    primary_axis_count: f64,
    secondary_axis_count: f64,
    primary_radius_m: f64,
    secondary_radius_m: f64,
    primary_root_depth_m: f64,
    average_secondary_length_m: f64,
    primary_root_layer_fraction: f64,
) !f64 {
    inline for (.{ plant_population_count, primary_axis_count, secondary_axis_count, primary_radius_m, secondary_radius_m, primary_root_depth_m, average_secondary_length_m, primary_root_layer_fraction }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootGasGeometry;
    if (plant_population_count <= 0 or primary_radius_m <= 0 or secondary_radius_m <= 0 or primary_root_depth_m <= 0 or average_secondary_length_m <= 0 or primary_root_layer_fraction > 1) return error.InvalidRootGasGeometry;
    if (primary_root_layer_fraction == 0) return 0;
    const primary = @max(plant_population_count, primary_axis_count) * std.math.pi * primary_radius_m * primary_radius_m / primary_root_depth_m;
    const secondary = secondary_axis_count * std.math.pi * secondary_radius_m * secondary_radius_m / average_secondary_length_m / primary_root_layer_fraction;
    return if (secondary > primary) primary * secondary / (primary + secondary) else primary;
}

pub const OxygenUptakeInput = struct {
    soil_to_surface_transport_m3_per_step: f64,
    root_internal_transport_m3_per_step: f64,
    water_advection_m3_per_step: f64,
    soil_oxygen_g_o_per_m3: f64,
    root_oxygen_g_o_per_m3: f64,
    oxygen_demand_g_o_per_plant_step: f64,
    oxygen_half_saturation_g_o_per_m3: f64,
    plant_population_count: f64,
    population_competition_fraction: f64,
    soil_aqueous_oxygen_g_o: f64,
    root_aqueous_oxygen_g_o: f64,
    significance_threshold_g_o: f64,
};

pub const OxygenUptakeResult = struct {
    uptake_g_o_per_plant_step: f64,
    root_surface_concentration_g_o_per_m3: f64,
    soil_to_root_flux_g_o_per_plant_step: f64,
    internal_root_flux_g_o_per_plant_step: f64,
};

pub const AqueousExchangeInput = struct {
    soil_dissolved_mass_g: f64,
    root_dissolved_mass_g: f64,
    soil_water_volume_m3: f64,
    root_water_volume_m3: f64,
    water_advection_m3_per_step: f64,
    aqueous_diffusive_conductance_m3_per_step: f64,
    plant_population_count: f64,
    equilibration_fraction: f64,
};

/// UPTAKE RDFC*/RDX*/RUP* signed soil-root exchange used by CO2, CH4,
/// N2O, NH3, and H2. Positive flux moves soil -> root; negative flux moves
/// root -> soil. The concentration-gradient candidate is bounded by the exact
/// two-compartment equal-concentration extent before any state is changed.
pub fn soilRootAqueousExchangeG(input: AqueousExchangeInput) !f64 {
    inline for (@typeInfo(AqueousExchangeInput).@"struct".fields) |field| {
        const value = @field(input, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteRootAqueousExchangeInput;
    }
    if (input.soil_dissolved_mass_g < 0 or input.root_dissolved_mass_g < 0 or input.soil_water_volume_m3 <= 0 or input.root_water_volume_m3 <= 0 or input.water_advection_m3_per_step < 0 or input.aqueous_diffusive_conductance_m3_per_step < 0 or input.plant_population_count <= 0 or input.equilibration_fraction < 0 or input.equilibration_fraction > 1) return error.InvalidRootAqueousExchangeInput;
    const soil_concentration = input.soil_dissolved_mass_g / input.soil_water_volume_m3;
    const root_concentration = input.root_dissolved_mass_g / input.root_water_volume_m3;
    const candidate_per_plant = input.water_advection_m3_per_step * soil_concentration +
        input.aqueous_diffusive_conductance_m3_per_step * (soil_concentration - root_concentration);
    const total_water = input.root_water_volume_m3 + input.soil_water_volume_m3;
    const equilibrium_extent = (input.root_water_volume_m3 * input.soil_dissolved_mass_g -
        input.soil_water_volume_m3 * input.root_dissolved_mass_g) / total_water * input.equilibration_fraction;
    const population_candidate = candidate_per_plant * input.plant_population_count;
    const result = if (candidate_per_plant > 0)
        @min(@max(0.0, equilibrium_extent), population_candidate)
    else
        @max(@min(0.0, equilibrium_extent), population_candidate);
    if (!std.math.isFinite(result)) return error.NonFiniteRootAqueousExchange;
    return result;
}

/// Conservative state_update of a previously calculated signed exchange.
/// Validation precedes both writes, so a failed state_update leaves both pools intact.
pub fn state_updateSoilRootAqueousExchangeG(soil_dissolved_mass_g: *f64, root_dissolved_mass_g: *f64, soil_to_root_exchange_g: f64) !void {
    if (!std.math.isFinite(soil_dissolved_mass_g.*) or soil_dissolved_mass_g.* < 0 or !std.math.isFinite(root_dissolved_mass_g.*) or root_dissolved_mass_g.* < 0 or !std.math.isFinite(soil_to_root_exchange_g)) return error.InvalidRootAqueousExchangeStateUpdate;
    const next_soil = soil_dissolved_mass_g.* - soil_to_root_exchange_g;
    const next_root = root_dissolved_mass_g.* + soil_to_root_exchange_g;
    if (next_soil < 0 or next_root < 0) return error.InsufficientAqueousGasForRootExchange;
    if (!std.math.isFinite(next_soil) or !std.math.isFinite(next_root)) return error.NonFiniteRootAqueousExchangeStateUpdate;
    soil_dissolved_mass_g.* = next_soil;
    root_dissolved_mass_g.* = next_root;
}

/// StateUpdates and publishes the accepted exchange as one transaction.
pub fn state_updateSoilRootAqueousExchangeWithLedgerG(
    soil_dissolved_mass_g: *f64,
    root_dissolved_mass_g: *f64,
    accepted_soil_to_root_exchange_g_per_h: *f64,
    soil_to_root_exchange_g: f64,
) !void {
    if (!std.math.isFinite(accepted_soil_to_root_exchange_g_per_h.*)) return error.InvalidRootAqueousExchangeLedger;
    const next_soil = soil_dissolved_mass_g.* - soil_to_root_exchange_g;
    const next_root = root_dissolved_mass_g.* + soil_to_root_exchange_g;
    const next_accepted = accepted_soil_to_root_exchange_g_per_h.* + soil_to_root_exchange_g;
    if (!std.math.isFinite(soil_dissolved_mass_g.*) or soil_dissolved_mass_g.* < 0 or
        !std.math.isFinite(root_dissolved_mass_g.*) or root_dissolved_mass_g.* < 0 or
        !std.math.isFinite(soil_to_root_exchange_g) or !std.math.isFinite(next_soil) or
        !std.math.isFinite(next_root) or !std.math.isFinite(next_accepted))
        return error.InvalidRootAqueousExchangeStateUpdate;
    if (next_soil < 0 or next_root < 0) return error.InsufficientAqueousGasForRootExchange;
    soil_dissolved_mass_g.* = next_soil;
    root_dissolved_mass_g.* = next_root;
    accepted_soil_to_root_exchange_g_per_h.* = next_accepted;
}

pub const RootPhaseAtmosphereInput = struct {
    gaseous_mass_g: f64,
    aqueous_mass_g: f64,
    gaseous_volume_m3: f64,
    aqueous_volume_m3: f64,
    water_to_air_mass_solubility_ratio: f64,
    atmosphere_concentration_g_per_m3: f64,
    atmosphere_conductance_m3_per_h: f64,
    phase_equilibration_fraction: f64,
    maximum_iterations: u16,
    absolute_tolerance_g: f64,
    relative_tolerance: f64,
};

pub const RootPhaseAtmosphereResult = struct {
    aqueous_to_gaseous_exchange_g_per_h: f64,
    atmosphere_to_root_exchange_g_per_h: f64,
    final_gaseous_mass_g: f64,
    final_aqueous_mass_g: f64,
    iterations: u16,
};

const AtmosphereSolveContext = struct {
    gaseous_mass_after_phase_g: f64,
    gaseous_volume_m3: f64,
    atmosphere_concentration_g_per_m3: f64,
    conductance_m3_per_h: f64,

    fn residual(self: AtmosphereSolveContext, flux_g: f64) f64 {
        return flux_g - self.fixedPoint(flux_g);
    }
    fn derivative(self: AtmosphereSolveContext, _: f64) f64 {
        return 1.0 + self.conductance_m3_per_h / self.gaseous_volume_m3;
    }
    fn fixedPoint(self: AtmosphereSolveContext, flux_g: f64) f64 {
        return self.conductance_m3_per_h *
            (self.atmosphere_concentration_g_per_m3 -
                (self.gaseous_mass_after_phase_g + flux_g) / self.gaseous_volume_m3);
    }
};

/// Whole-hour replacement for the UPTAKE NPT root phase/atmosphere loop.
/// The phase extent retains the source equilibrium bound. The implicit
/// atmosphere transaction is solved locally by Newton–Raphson/Picard and exits
/// immediately on convergence; no other model state is cycled.
pub fn solveRootPhaseAtmosphereExchangeG(input: RootPhaseAtmosphereInput) !RootPhaseAtmosphereResult {
    inline for (@typeInfo(RootPhaseAtmosphereInput).@"struct".fields) |field| switch (field.type) {
        f64 => if (!std.math.isFinite(@field(input, field.name))) return error.NonFiniteRootPhaseAtmosphereInput,
        else => {},
    };
    if (input.gaseous_mass_g < 0 or input.aqueous_mass_g < 0 or input.gaseous_volume_m3 <= 0 or
        input.aqueous_volume_m3 < 0 or input.water_to_air_mass_solubility_ratio < 0 or
        input.atmosphere_concentration_g_per_m3 < 0 or input.atmosphere_conductance_m3_per_h < 0 or
        input.phase_equilibration_fraction < 0 or input.phase_equilibration_fraction > 1 or
        input.maximum_iterations == 0 or input.absolute_tolerance_g <= 0 or input.relative_tolerance <= 0)
        return error.InvalidRootPhaseAtmosphereInput;

    const soluble_water_volume_m3 = input.aqueous_volume_m3 * input.water_to_air_mass_solubility_ratio;
    const phase_denominator_m3 = soluble_water_volume_m3 + input.gaseous_volume_m3;
    const gaseous_to_aqueous_g = if (phase_denominator_m3 > 0)
        std.math.clamp(
            input.phase_equilibration_fraction *
                (input.gaseous_mass_g * soluble_water_volume_m3 -
                    input.aqueous_mass_g * input.gaseous_volume_m3) /
                phase_denominator_m3,
            -input.aqueous_mass_g,
            input.gaseous_mass_g,
        )
    else
        0;
    const aqueous_to_gaseous_g = -gaseous_to_aqueous_g;
    const gaseous_after_phase_g = input.gaseous_mass_g + aqueous_to_gaseous_g;
    const aqueous_after_phase_g = input.aqueous_mass_g - aqueous_to_gaseous_g;
    const conductance_m3_per_h = @min(input.atmosphere_conductance_m3_per_h, input.gaseous_volume_m3);
    if (conductance_m3_per_h == 0) return .{
        .aqueous_to_gaseous_exchange_g_per_h = aqueous_to_gaseous_g,
        .atmosphere_to_root_exchange_g_per_h = 0,
        .final_gaseous_mass_g = gaseous_after_phase_g,
        .final_aqueous_mass_g = aqueous_after_phase_g,
        .iterations = 0,
    };
    const lower_flux_g = -gaseous_after_phase_g;
    const upper_flux_g = conductance_m3_per_h * input.atmosphere_concentration_g_per_m3;
    if (lower_flux_g == upper_flux_g) return .{
        .aqueous_to_gaseous_exchange_g_per_h = aqueous_to_gaseous_g,
        .atmosphere_to_root_exchange_g_per_h = lower_flux_g,
        .final_gaseous_mass_g = 0,
        .final_aqueous_mass_g = aqueous_after_phase_g,
        .iterations = 0,
    };
    const context = AtmosphereSolveContext{
        .gaseous_mass_after_phase_g = gaseous_after_phase_g,
        .gaseous_volume_m3 = input.gaseous_volume_m3,
        .atmosphere_concentration_g_per_m3 = input.atmosphere_concentration_g_per_m3,
        .conductance_m3_per_h = conductance_m3_per_h,
    };
    const solved = try numerics.newtonPicard(
        context,
        AtmosphereSolveContext.residual,
        AtmosphereSolveContext.derivative,
        AtmosphereSolveContext.fixedPoint,
        lower_flux_g,
        upper_flux_g,
        0,
        .{
            .absolute_tolerance = input.absolute_tolerance_g,
            .relative_tolerance = input.relative_tolerance,
            .residual_scale = @max(input.absolute_tolerance_g, input.gaseous_mass_g + input.aqueous_mass_g),
            .max_iterations = input.maximum_iterations,
        },
    );
    const final_gaseous_mass_g = gaseous_after_phase_g + solved.root;
    if (!std.math.isFinite(final_gaseous_mass_g) or final_gaseous_mass_g < 0) return error.InvalidRootPhaseAtmosphereResult;
    return .{
        .aqueous_to_gaseous_exchange_g_per_h = aqueous_to_gaseous_g,
        .atmosphere_to_root_exchange_g_per_h = solved.root,
        .final_gaseous_mass_g = final_gaseous_mass_g,
        .final_aqueous_mass_g = aqueous_after_phase_g,
        .iterations = solved.iterations,
    };
}

/// Exact UPTAKE aqueous O2 transport/Monod solution. The source evaluates the
/// smaller quadratic root as (-B-sqrt(B^2-4C))/2; the equivalent expression
/// 2C/(-B+sqrt(...)) avoids catastrophic cancellation when uptake is small.
pub fn solveOxygenUptake(input: OxygenUptakeInput) !OxygenUptakeResult {
    inline for (@typeInfo(OxygenUptakeInput).@"struct".fields) |field| {
        const value = @field(input, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteRootOxygenInput;
        if (value < 0) return error.InvalidRootOxygenInput;
    }
    if (input.plant_population_count <= 0) return error.InvalidPlantPopulation;

    const soil_transport = input.soil_to_surface_transport_m3_per_step + input.water_advection_m3_per_step;
    const total_transport = input.soil_to_surface_transport_m3_per_step + input.root_internal_transport_m3_per_step;
    var transported_oxygen = soil_transport * input.soil_oxygen_g_o_per_m3 +
        input.root_internal_transport_m3_per_step * input.root_oxygen_g_o_per_m3;
    var transport = total_transport;
    var soil_available = true;

    if (!(transported_oxygen > 0 and input.soil_aqueous_oxygen_g_o > input.significance_threshold_g_o)) {
        transported_oxygen = input.root_internal_transport_m3_per_step * input.root_oxygen_g_o_per_m3;
        transport = input.root_internal_transport_m3_per_step;
        soil_available = false;
    }
    if (!(transported_oxygen > 0 and input.root_aqueous_oxygen_g_o > input.significance_threshold_g_o) or transport <= 0) {
        return .{ .uptake_g_o_per_plant_step = 0, .root_surface_concentration_g_o_per_m3 = 0, .soil_to_root_flux_g_o_per_plant_step = 0, .internal_root_flux_g_o_per_plant_step = 0 };
    }

    const minus_b = input.oxygen_demand_g_o_per_plant_step +
        transport * input.oxygen_half_saturation_g_o_per_m3 + transported_oxygen;
    const c = transported_oxygen * input.oxygen_demand_g_o_per_plant_step;
    const discriminant = @max(0.0, minus_b * minus_b - 4.0 * c);
    const root = if (c == 0) 0 else 2.0 * c / (minus_b + @sqrt(discriminant));
    const surface_concentration = @max(0.0, (transported_oxygen - root) / transport);

    const soil_flux = if (soil_available)
        input.water_advection_m3_per_step * input.soil_oxygen_g_o_per_m3 +
            input.soil_to_surface_transport_m3_per_step * (input.soil_oxygen_g_o_per_m3 - surface_concentration)
    else
        0;
    var internal_flux = input.root_internal_transport_m3_per_step * (input.root_oxygen_g_o_per_m3 - surface_concentration);
    if (!soil_available) {
        const available_per_plant = input.population_competition_fraction * input.root_aqueous_oxygen_g_o / input.plant_population_count;
        internal_flux = @min(@max(0.0, available_per_plant), internal_flux);
    }

    const result = OxygenUptakeResult{
        .uptake_g_o_per_plant_step = root,
        .root_surface_concentration_g_o_per_m3 = surface_concentration,
        .soil_to_root_flux_g_o_per_plant_step = soil_flux,
        .internal_root_flux_g_o_per_plant_step = internal_flux,
    };
    inline for (@typeInfo(OxygenUptakeResult).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteRootOxygenResult;
    return result;
}

/// Atomically state_updates the source RUPOXS/RUPOXP accounting. Fluxes returned by
/// solveOxygenUptake are per plant, while both stored root pools and soil pools
/// are extensive per grid cell, hence the population conversion here.
pub fn state_updateOxygenUptake(
    roots: *PlantRootState,
    plant: usize,
    domain: usize,
    layer: usize,
    plant_population_count: f64,
    result: OxygenUptakeResult,
    soil_aqueous_oxygen_g_o: *f64,
) !void {
    if (!std.math.isFinite(plant_population_count) or plant_population_count <= 0 or !std.math.isFinite(soil_aqueous_oxygen_g_o.*) or soil_aqueous_oxygen_g_o.* < 0) return error.InvalidRootOxygenStateUpdateInput;
    inline for (@typeInfo(OxygenUptakeResult).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteRootOxygenResult;
    if (result.soil_to_root_flux_g_o_per_plant_step < 0 or result.internal_root_flux_g_o_per_plant_step < 0 or result.uptake_g_o_per_plant_step < 0) return error.InvalidRootOxygenFlux;

    const index = try roots.layerIndex(plant, domain, layer);
    const soil_uptake = result.soil_to_root_flux_g_o_per_plant_step * plant_population_count;
    const internal_uptake = result.internal_root_flux_g_o_per_plant_step * plant_population_count;
    const total_uptake = soil_uptake + internal_uptake;
    if (soil_uptake > soil_aqueous_oxygen_g_o.* or internal_uptake > roots.aqueous_oxygen_g_o[index]) return error.InsufficientOxygenForRootStateUpdate;

    const next_soil = soil_aqueous_oxygen_g_o.* - soil_uptake;
    const next_root = roots.aqueous_oxygen_g_o[index] - internal_uptake;
    const next_soil_total = roots.oxygen_uptake_from_soil_g_o_per_h[index] + soil_uptake;
    const next_root_total = roots.oxygen_uptake_from_root_pool_g_o_per_h[index] + internal_uptake;
    const next_total = roots.oxygen_uptake_g_o_per_h[index] + total_uptake;
    inline for (.{ next_soil, next_root, next_soil_total, next_root_total, next_total }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootOxygenStateUpdate;

    soil_aqueous_oxygen_g_o.* = next_soil;
    roots.aqueous_oxygen_g_o[index] = next_root;
    roots.oxygen_uptake_from_soil_g_o_per_h[index] = next_soil_total;
    roots.oxygen_uptake_from_root_pool_g_o_per_h[index] = next_root_total;
    roots.oxygen_uptake_g_o_per_h[index] = next_total;
}

test "UPTAKE oxygen quadratic preserves the smaller physical root" {
    const input = OxygenUptakeInput{
        .soil_to_surface_transport_m3_per_step = 0.2,
        .root_internal_transport_m3_per_step = 0.1,
        .water_advection_m3_per_step = 0.02,
        .soil_oxygen_g_o_per_m3 = 8,
        .root_oxygen_g_o_per_m3 = 4,
        .oxygen_demand_g_o_per_plant_step = 0.6,
        .oxygen_half_saturation_g_o_per_m3 = 0.5,
        .plant_population_count = 10,
        .population_competition_fraction = 0.2,
        .soil_aqueous_oxygen_g_o = 8,
        .root_aqueous_oxygen_g_o = 4,
        .significance_threshold_g_o = 1.0e-12,
    };
    const result = try solveOxygenUptake(input);
    const x = (input.soil_to_surface_transport_m3_per_step + input.water_advection_m3_per_step) * input.soil_oxygen_g_o_per_m3 + input.root_internal_transport_m3_per_step * input.root_oxygen_g_o_per_m3;
    const transport = input.soil_to_surface_transport_m3_per_step + input.root_internal_transport_m3_per_step;
    const residual = result.uptake_g_o_per_plant_step * result.uptake_g_o_per_plant_step -
        (input.oxygen_demand_g_o_per_plant_step + transport * input.oxygen_half_saturation_g_o_per_m3 + x) * result.uptake_g_o_per_plant_step +
        x * input.oxygen_demand_g_o_per_plant_step;
    try std.testing.expectApproxEqAbs(@as(f64, 0), residual, 1.0e-12);
    try std.testing.expect(result.uptake_g_o_per_plant_step <= input.oxygen_demand_g_o_per_plant_step);
}

test "UPTAKE signed aqueous gas exchange retains directional source bounds" {
    const into_root = try soilRootAqueousExchangeG(.{
        .soil_dissolved_mass_g = 8,
        .root_dissolved_mass_g = 1,
        .soil_water_volume_m3 = 2,
        .root_water_volume_m3 = 1,
        .water_advection_m3_per_step = 0.1,
        .aqueous_diffusive_conductance_m3_per_step = 0.2,
        .plant_population_count = 2,
        .equilibration_fraction = 0.5,
    });
    const candidate = (0.1 * 4.0 + 0.2 * (4.0 - 1.0)) * 2.0;
    const extent = (1.0 * 8.0 - 2.0 * 1.0) / 3.0 * 0.5;
    try std.testing.expectApproxEqAbs(@min(extent, candidate), into_root, 1.0e-12);

    const into_soil = try soilRootAqueousExchangeG(.{
        .soil_dissolved_mass_g = 1,
        .root_dissolved_mass_g = 8,
        .soil_water_volume_m3 = 2,
        .root_water_volume_m3 = 1,
        .water_advection_m3_per_step = 0,
        .aqueous_diffusive_conductance_m3_per_step = 0.2,
        .plant_population_count = 2,
        .equilibration_fraction = 0.5,
    });
    try std.testing.expect(into_soil < 0);
    var soil: f64 = 1;
    var root: f64 = 8;
    const before = soil + root;
    try state_updateSoilRootAqueousExchangeG(&soil, &root, into_soil);
    try std.testing.expectApproxEqAbs(before, soil + root, 1.0e-12);
}

test "UPTAKE aqueous gas state_update rejects depletion atomically" {
    var soil: f64 = 0.1;
    var root: f64 = 0.2;
    try std.testing.expectError(error.InsufficientAqueousGasForRootExchange, state_updateSoilRootAqueousExchangeG(&soil, &root, 0.3));
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), soil, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), root, 1.0e-12);
}

test "HOUR1 oxygen environment retains temperature and ion-activity equations" {
    const parameters = compatibilityParameters();
    const result = try oxygenEnvironment(parameters, 298.15, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 8.57e-6), result.aqueous_diffusivity_m2_per_h, 1.0e-16);
    const expected_solubility = 2.925e-2 / @exp(0.31) * @exp(0.516 - 0.0172 * 25.0);
    try std.testing.expectApproxEqAbs(expected_solubility, result.water_to_air_mass_solubility_ratio, 1.0e-14);
    const saline = try oxygenEnvironment(parameters, 298.15, 5.56e4);
    try std.testing.expectApproxEqAbs(0.5 * result.water_to_air_mass_solubility_ratio, saline.water_to_air_mass_solubility_ratio, 1.0e-14);
}

test "WATSUB water film and UPTAKE radial conductance retain source equations" {
    const parameters = compatibilityParameters();
    const potential_megapascal: f64 = -0.1;
    const expected_film = @max(1.0e-6, 0.5 * @exp(-13.833 - 0.857 * @log(-potential_megapascal)));
    const film = try soilWaterFilmThicknessM(parameters, potential_megapascal, false);
    try std.testing.expectApproxEqAbs(expected_film, film, 1.0e-16);
    const diffusivity: f64 = 8.57e-6;
    const tortuosity_water_fraction: f64 = 0.2;
    const surface_per_radius_m: f64 = 30;
    const radius_m: f64 = 1.0e-4;
    const expected = tortuosity_water_fraction * diffusivity * surface_per_radius_m / @log((film + radius_m) / radius_m);
    try std.testing.expectApproxEqAbs(expected, try radialAqueousConductanceM3PerH(diffusivity, tortuosity_water_fraction, surface_per_radius_m, radius_m, film), 1.0e-15);
}

test "UPTAKE oxygen demand refresh covers arbitrary root domains and layers" {
    var roots = try PlantRootState.init(std.testing.allocator, 3, 4, 7);
    defer roots.deinit();
    for (roots.respiration_unlimited_by_oxygen_g_c_per_h, 0..) |*respiration, index| respiration.* = @as(f64, @floatFromInt(index)) * 0.01;
    const parameters = compatibilityParameters();
    try refreshOxygenDemand(&roots, parameters);
    for (roots.oxygen_demand_g_o_per_h, 0..) |demand, index| try std.testing.expectApproxEqAbs(parameters.oxygen_to_carbon_respiration_ratio_g_o_per_g_c * @as(f64, @floatFromInt(index)) * 0.01, demand, 1.0e-12);
}

test "UPTAKE FOXYX falls back to biome fraction when previous-hour O2 demand is zero" {
    var roots = try PlantRootState.init(std.testing.allocator, 1, 2, 1);
    defer roots.deinit();
    roots.current_deepest_rooted_layer_by_plant[0] = 1;
    const root = try roots.layerIndex(0, 0, 0);
    const domain_layer_count = roots.oxygen_demand_g_o_per_h.len;
    const root_biome_fraction = try std.testing.allocator.alloc(f64, domain_layer_count);
    defer std.testing.allocator.free(root_biome_fraction);
    @memset(root_biome_fraction, 0);
    root_biome_fraction[root] = 0.3;
    const layer_thickness = [_]f64{ 1, 1 };
    const previous_total_microbial = [_]f64{ 0, 0 };
    var scratch = [_]f64{ 0, 0 };
    const biological_domain_counts = [_]u8{1};
    try refreshOxygenPopulationCompetitionFraction(
        &roots,
        &biological_domain_counts,
        root_biome_fraction,
        &previous_total_microbial,
        &layer_thickness,
        0,
        0.05,
        1.0e-12,
        &scratch,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), roots.population_competition_fraction_g_o[root], 1.0e-15);
}

test "UPTAKE FOXYX computes proportional share across populations and microbial demand" {
    var roots = try PlantRootState.init(std.testing.allocator, 2, 1, 1);
    defer roots.deinit();
    roots.current_deepest_rooted_layer_by_plant[0] = 0;
    roots.current_deepest_rooted_layer_by_plant[1] = 0;
    const root0 = try roots.layerIndex(0, 0, 0);
    const root1 = try roots.layerIndex(1, 0, 0);
    roots.previous_oxygen_demand_g_o_per_h[root0] = 3;
    roots.previous_oxygen_demand_g_o_per_h[root1] = 1;
    const domain_layer_count = roots.oxygen_demand_g_o_per_h.len;
    const root_biome_fraction = try std.testing.allocator.alloc(f64, domain_layer_count);
    defer std.testing.allocator.free(root_biome_fraction);
    @memset(root_biome_fraction, 0.1);
    const layer_thickness = [_]f64{1};
    const previous_total_microbial = [_]f64{0};
    var scratch = [_]f64{0};
    const biological_domain_counts = [_]u8{ 1, 1 };
    try refreshOxygenPopulationCompetitionFraction(
        &roots,
        &biological_domain_counts,
        root_biome_fraction,
        &previous_total_microbial,
        &layer_thickness,
        0,
        0.05,
        1.0e-12,
        &scratch,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), roots.population_competition_fraction_g_o[root0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), roots.population_competition_fraction_g_o[root1], 1.0e-12);
}

test "UPTAKE FOXYX reflects previous-hour demand only, not this hour's own demand" {
    var roots = try PlantRootState.init(std.testing.allocator, 2, 1, 1);
    defer roots.deinit();
    roots.current_deepest_rooted_layer_by_plant[0] = 0;
    roots.current_deepest_rooted_layer_by_plant[1] = 0;
    const root0 = try roots.layerIndex(0, 0, 0);
    const root1 = try roots.layerIndex(1, 0, 0);
    // End of the prior hour: root0 demanded 2, root1 demanded 6.
    roots.oxygen_demand_g_o_per_h[root0] = 2;
    roots.oxygen_demand_g_o_per_h[root1] = 6;
    roots.resetHourlyFluxes();
    try std.testing.expectApproxEqAbs(@as(f64, 2), roots.previous_oxygen_demand_g_o_per_h[root0], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0), roots.oxygen_demand_g_o_per_h[root0], 1.0e-15);
    // This hour's own demand recompute diverges sharply from last hour.
    roots.oxygen_demand_g_o_per_h[root0] = 1000;
    roots.oxygen_demand_g_o_per_h[root1] = 0;

    const domain_layer_count = roots.oxygen_demand_g_o_per_h.len;
    const root_biome_fraction = try std.testing.allocator.alloc(f64, domain_layer_count);
    defer std.testing.allocator.free(root_biome_fraction);
    @memset(root_biome_fraction, 0.1);
    const layer_thickness = [_]f64{1};
    const previous_total_microbial = [_]f64{0};
    var scratch = [_]f64{0};
    const biological_domain_counts = [_]u8{ 1, 1 };
    try refreshOxygenPopulationCompetitionFraction(
        &roots,
        &biological_domain_counts,
        root_biome_fraction,
        &previous_total_microbial,
        &layer_thickness,
        0,
        0.05,
        1.0e-12,
        &scratch,
    );
    // Previous-hour total is 2 + 6 = 8, so root0's own share is 2/8 = 0.25,
    // unaffected by its own this-hour demand of 1000.
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), roots.population_competition_fraction_g_o[root0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), roots.population_competition_fraction_g_o[root1], 1.0e-12);
}

test "UPTAKE oxygen constraint limits active roots and propagates below root zone" {
    var roots = try PlantRootState.init(std.testing.allocator, 1, 3, 1);
    defer roots.deinit();
    const root0 = try roots.layerIndex(0, 0, 0);
    const root1 = try roots.layerIndex(0, 0, 1);
    const root2 = try roots.layerIndex(0, 0, 2);
    roots.oxygen_demand_g_o_per_h[root0] = 2;
    roots.oxygen_uptake_g_o_per_h[root0] = 0.5;
    roots.aqueous_volume_m3[root0] = 1;
    roots.oxygen_demand_g_o_per_h[root1] = 4;
    roots.oxygen_uptake_g_o_per_h[root1] = 2;
    roots.aqueous_volume_m3[root1] = 1;
    const fractions = [_]f64{ 1, 1, 1, 0, 0, 0 };
    const deepest = [_]usize{ 1, 0 };
    const biological_domain_counts = [_]u8{1};
    const totals = try refreshOxygenProcessConstraint(&roots, &biological_domain_counts, &fractions, &deepest, 1.0e-12, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), roots.oxygen_process_constraint_fraction[root0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), roots.oxygen_process_constraint_fraction[root1], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), roots.oxygen_process_constraint_fraction[root2], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 6), totals.demand_g_o_per_h, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), totals.uptake_g_o_per_h, 1.0e-12);
}

test "UPTAKE root gas geometry retains primary-secondary source branch" {
    const population: f64 = 10;
    const primary_count: f64 = 20;
    const secondary_count: f64 = 100;
    const primary_radius: f64 = 1.0e-3;
    const secondary_radius: f64 = 1.0e-4;
    const depth: f64 = 0.5;
    const secondary_length: f64 = 0.1;
    const layer_fraction: f64 = 0.25;
    const primary = @max(population, primary_count) * std.math.pi * primary_radius * primary_radius / depth;
    const secondary = secondary_count * std.math.pi * secondary_radius * secondary_radius / secondary_length / layer_fraction;
    const expected = if (secondary > primary) primary * secondary / (primary + secondary) else primary;
    try std.testing.expectApproxEqAbs(expected, try rootGasCrossSectionPerLengthM(population, primary_count, secondary_count, primary_radius, secondary_radius, depth, secondary_length, layer_fraction), 1.0e-15);
    try std.testing.expectEqual(@as(f64, 0), try rootGasCrossSectionPerLengthM(population, primary_count, secondary_count, primary_radius, secondary_radius, depth, secondary_length, 0));
}

test "UPTAKE oxygen fallback uses internal root oxygen and competition cap" {
    const result = try solveOxygenUptake(.{
        .soil_to_surface_transport_m3_per_step = 0,
        .root_internal_transport_m3_per_step = 0.5,
        .water_advection_m3_per_step = 0,
        .soil_oxygen_g_o_per_m3 = 0,
        .root_oxygen_g_o_per_m3 = 4,
        .oxygen_demand_g_o_per_plant_step = 1,
        .oxygen_half_saturation_g_o_per_m3 = 0.5,
        .plant_population_count = 10,
        .population_competition_fraction = 0.25,
        .soil_aqueous_oxygen_g_o = 0,
        .root_aqueous_oxygen_g_o = 4,
        .significance_threshold_g_o = 1.0e-12,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0), result.soil_to_root_flux_g_o_per_plant_step, 1.0e-12);
    try std.testing.expect(result.internal_root_flux_g_o_per_plant_step <= 0.1 + 1.0e-12);
}

test "UPTAKE oxygen state_update is extensive, conservative, and atomic" {
    var roots = try PlantRootState.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    const index = try roots.layerIndex(0, 0, 0);
    roots.aqueous_oxygen_g_o[index] = 0.6;
    var soil_oxygen: f64 = 1.0;
    const result = OxygenUptakeResult{
        .uptake_g_o_per_plant_step = 0.1,
        .root_surface_concentration_g_o_per_m3 = 1,
        .soil_to_root_flux_g_o_per_plant_step = 0.2,
        .internal_root_flux_g_o_per_plant_step = 0.1,
    };
    try state_updateOxygenUptake(&roots, 0, 0, 0, 2, result, &soil_oxygen);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), soil_oxygen, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), roots.aqueous_oxygen_g_o[index], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), roots.oxygen_uptake_g_o_per_h[index], 1.0e-12);

    const before = roots.oxygen_uptake_g_o_per_h[index];
    try std.testing.expectError(error.InsufficientOxygenForRootStateUpdate, state_updateOxygenUptake(&roots, 0, 0, 0, 10, result, &soil_oxygen));
    try std.testing.expectApproxEqAbs(before, roots.oxygen_uptake_g_o_per_h[index], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), soil_oxygen, 1.0e-12);
}

test "accepted aqueous gas transaction is checkpoint-ready and atomic" {
    var soil: f64 = 4;
    var root: f64 = 1;
    var accepted: f64 = 0.25;
    try state_updateSoilRootAqueousExchangeWithLedgerG(&soil, &root, &accepted, 1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), soil, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), root, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.75), accepted, 1e-15);

    const soil_before = soil;
    const root_before = root;
    const accepted_before = accepted;
    try std.testing.expectError(error.InsufficientAqueousGasForRootExchange, state_updateSoilRootAqueousExchangeWithLedgerG(&soil, &root, &accepted, 9));
    try std.testing.expectEqual(soil_before, soil);
    try std.testing.expectEqual(root_before, root);
    try std.testing.expectEqual(accepted_before, accepted);
}

test "HOUR1 runtime environments cover every transported root gas" {
    const parameters = compatibilityParameters();
    inline for (@typeInfo(TransportedGas).@"enum".fields, 0..) |field, index| {
        const environment = try gasEnvironment(parameters, @enumFromInt(field.value), parameters.reference_temperature_k, 0);
        try std.testing.expectApproxEqAbs(parameters.gaseous_diffusivity_m2_per_h_at_reference[index], environment.gaseous_diffusivity_m2_per_h, 1e-15);
        try std.testing.expectApproxEqAbs(parameters.aqueous_diffusivity_m2_per_h_at_reference[index], environment.aqueous_diffusivity_m2_per_h, 1e-15);
        const expected_solubility = parameters.water_to_air_mass_solubility_at_25c[index] /
            @exp(parameters.solubility_activity_coefficient[index]) *
            @exp(parameters.solubility_temperature_intercept[index] -
                parameters.solubility_temperature_coefficient_per_c[index] * 25);
        try std.testing.expectApproxEqAbs(expected_solubility, environment.water_to_air_mass_solubility_ratio, 1e-13);
    }
}

test "surface layer water film uses watsub.f:3796's intercept, not the subsurface one" {
    // watsub.f:3795-3801 sets litter and the surface soil layer's FILM from
    // a -13.650 intercept; watsub.f:5215-5223 sets every layer below it
    // from a distinct -13.833 intercept, and the two never collide because
    // the second block's destination layer is always L+1 or deeper.
    const parameters = compatibilityParameters();
    const potential_megapascal: f64 = -0.1;
    const surface_film = try soilWaterFilmThicknessM(parameters, potential_megapascal, true);
    const subsurface_film = try soilWaterFilmThicknessM(parameters, potential_megapascal, false);
    const expected_surface = 0.5 * @exp(-13.650 - 0.857 * @log(-potential_megapascal));
    const expected_subsurface = 0.5 * @exp(-13.833 - 0.857 * @log(-potential_megapascal));
    try std.testing.expectApproxEqAbs(expected_surface, surface_film, 1.0e-16);
    try std.testing.expectApproxEqAbs(expected_subsurface, subsurface_film, 1.0e-16);
    try std.testing.expect(surface_film != subsurface_film);
}

test "saturated matric potential uses the finite water-film limit" {
    const film_m =
        try soilWaterFilmThicknessM(compatibilityParameters(), 0, false);
    try std.testing.expect(std.math.isFinite(film_m));
    try std.testing.expect(film_m > 0);
    try std.testing.expectError(
        error.InvalidSoilMatricPotentialForWaterFilm,
        soilWaterFilmThicknessM(compatibilityParameters(), 1e-9, false),
    );
}

test "whole-hour root phase atmosphere solve converges locally and conserves mass" {
    const result = try solveRootPhaseAtmosphereExchangeG(.{
        .gaseous_mass_g = 0.8,
        .aqueous_mass_g = 0.2,
        .gaseous_volume_m3 = 0.4,
        .aqueous_volume_m3 = 0.6,
        .water_to_air_mass_solubility_ratio = 0.5,
        .atmosphere_concentration_g_per_m3 = 0.25,
        .atmosphere_conductance_m3_per_h = 0.1,
        .phase_equilibration_fraction = 1,
        .maximum_iterations = 12,
        .absolute_tolerance_g = 1e-13,
        .relative_tolerance = 1e-10,
    });
    try std.testing.expect(result.iterations < 12);
    try std.testing.expectApproxEqAbs(
        @as(f64, 1) + result.atmosphere_to_root_exchange_g_per_h,
        result.final_gaseous_mass_g + result.final_aqueous_mass_g,
        1e-12,
    );
    try std.testing.expect(result.final_gaseous_mass_g >= 0);
    try std.testing.expect(result.final_aqueous_mass_g >= 0);
}
