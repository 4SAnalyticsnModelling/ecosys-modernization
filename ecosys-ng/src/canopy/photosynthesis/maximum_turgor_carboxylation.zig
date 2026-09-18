//! Side-effect-free STOMATE CH2O producer.
//!
//! `stomate.f:55--73,87--629` recomputes gas solubility, Arrhenius capacity,
//! direct/diffuse light limitation, and maximum-turgor canopy fixation on
//! every call. UPTAKE calls STOMATE at entry and again at `:1228` using the
//! newly converged TKC. This kernel preserves that source order without
//! publishing capacity arrays or advancing the later `uptake.f:1591--1609`
//! chilling/heating state, so a failed coupled retry has no side effects.

const std = @import("std");
const Canopy = @import("photosynthesis.zig").State;
const C4CarbonParameters = @import("photosynthesis.zig").C4CarbonParameters;
const LayerState = @import("../radiation/layer_distribution.zig").State;
const Interception = @import("../energy/interception.zig").State;
const Optics = @import("../radiation/optics.zig").State;
const Geometry = @import("../morphology/geometry.zig").Geometry;
const biochemistry = @import("biochemistry.zig");
const stomatal = @import("../energy/stomatal_resistance.zig");
const minimum_stomatal = @import("../energy/minimum_stomatal_resistance.zig");
const c4_capacity = @import("c4_capacity.zig");
const Dormancy = @import("../../plant/lifecycle/dormancy.zig");
const BranchDevelopment = @import("../../plant/lifecycle/phenology.zig").BranchDevelopmentState;
const GrowthStages = @import("../../plant/lifecycle/growth_stages.zig").State;
const plant_topology = @import("../../state/plant_topology.zig");

pub const Context = struct {
    canopy: *const Canopy,
    layers: *const LayerState,
    interception: *const Interception,
    optics: *const Optics,
    geometry: *const Geometry,
    parameters_by_plant: []const biochemistry.Parameters,
    c4_carbon_parameters: C4CarbonParameters,
    direct_incidence_fraction: []const f64,
    atmospheric_co2_umol_per_mol_by_cell: []const f64,
    dormancy: *const Dormancy.RuntimeState,
    branch_development: *const BranchDevelopment,
    growth_stages: *const GrowthStages,
    dormancy_parameters_by_plant: []const Dormancy.Parameters,
    annual_termination_hours_without_grain_fill: f64,
    presence_threshold_g_per_plant: f64,
    plant: usize,
};

/// Adapter for `canopy_coupled_convergence.MaximumTurgorCarboxylationProducer`.
pub fn evaluateOpaque(raw_context: *const anyopaque, canopy_temperature_k: f64) anyerror!f64 {
    const context: *const Context = @ptrCast(@alignCast(raw_context));
    return compute(context.*, canopy_temperature_k);
}

pub fn compute(context: Context, canopy_temperature_k: f64) !f64 {
    const canopy = context.canopy;
    const plant_count = try std.math.mul(usize, canopy.cell_count, canopy.species_count);
    const inclination_count = context.geometry.leaf_inclination_sine.len;
    const azimuth_count = context.geometry.leaf_azimuth_radians.len;
    const angular_count = try std.math.mul(usize, inclination_count, azimuth_count);
    const expected_samples = try std.math.mul(usize, context.layers.layer_count, angular_count);
    if (context.plant >= plant_count or
        context.parameters_by_plant.len != plant_count or
        context.dormancy_parameters_by_plant.len != plant_count or
        context.atmospheric_co2_umol_per_mol_by_cell.len != canopy.cell_count or
        context.layers.cell_count != canopy.cell_count or
        context.layers.species_count != canopy.species_count or
        context.interception.cell_count != canopy.cell_count or
        context.interception.species_count != canopy.species_count or
        context.interception.layer_count != context.layers.layer_count or
        context.optics.cell_count != canopy.cell_count or
        context.optics.species_count != canopy.species_count or
        context.direct_incidence_fraction.len != canopy.cell_count * angular_count or
        context.dormancy.branches.len != canopy.branch_node_offsets.len - 1 or
        context.branch_development.branch_count != canopy.branch_node_offsets.len - 1 or
        context.growth_stages.branches.len != canopy.branch_node_offsets.len - 1)
        return error.MaximumTurgorCarboxylationDimensionMismatch;
    if (!std.math.isFinite(canopy_temperature_k) or canopy_temperature_k <= 0 or
        !std.math.isFinite(context.annual_termination_hours_without_grain_fill) or
        context.annual_termination_hours_without_grain_fill <= 0 or
        !std.math.isFinite(context.presence_threshold_g_per_plant) or
        context.presence_threshold_g_per_plant < 0)
        return error.InvalidMaximumTurgorCarboxylationInput;
    try context.c4_carbon_parameters.validate();

    const cell = context.plant / canopy.species_count;
    const atmospheric_co2 = context.atmospheric_co2_umol_per_mol_by_cell[cell];
    if (!std.math.isFinite(atmospheric_co2) or atmospheric_co2 <= 0)
        return error.InvalidAtmosphericCo2;
    const parameters = context.parameters_by_plant[context.plant];
    try parameters.validate();
    const population = canopy.plant_population_count[context.plant];
    if (!std.math.isFinite(population) or population < 0)
        return error.InvalidCanopyPlantPopulation;
    const gas = try stomatal.gasEnvironment(
        canopy_temperature_k,
        canopy.plant_thermal_adaptation_offset_c[context.plant],
        atmospheric_co2,
        parameters.intercellular_to_atmospheric_co2_ratio,
        canopy.plant_intercellular_oxygen_umol_per_mol[context.plant],
        parameters.rubisco_co2_half_saturation_umol_per_l,
        parameters.rubisco_o2_half_saturation_umol_per_l,
    );

    var total_umol_per_s: f64 = 0;
    const branches = try canopy.branchRange(context.plant);
    for (branches.first..branches.end) |branch| {
        const dormant = context.dormancy.branches[branch];
        const feedback = try stomatal.branchFeedback(
            parameters.phenology_type,
            parameters.growth_habit,
            parameters.aboveground_turnover_type,
            dormant.accumulated_leafout_h,
            context.dormancy_parameters_by_plant[context.plant].required_leafout_h,
            dormant.accumulated_leafoff_h,
            context.dormancy_parameters_by_plant[context.plant].required_leafoff_h,
            canopy.branch_mobile_carbon_g[branch],
            canopy.branch_mobile_nitrogen_g[branch],
            canopy.branch_mobile_phosphorus_g[branch],
            // HEAT is updated by UPTAKE only after the final STOMATE call
            // (`uptake.f:1591--1609`), so both calls read this entry value.
            canopy.plant_heat_stress_h[context.plant],
            context.branch_development.remobilization_progress_h[branch],
            context.branch_development.hours_without_grain_fill[branch],
            context.annual_termination_hours_without_grain_fill,
        );
        if (!feedback.photosynthetically_active or context.growth_stages.branches[branch].dead)
            continue;
        const nodes = try canopy.nodeRange(branch);
        const presence_threshold = context.presence_threshold_g_per_plant * population;
        for (nodes.first..nodes.end) |node| {
            const leaf_area = canopy.node_leaf_area_m2[node];
            const leaf_carbon = canopy.node_leaf_carbon_g[node];
            const leaf_protein = canopy.node_leaf_protein_g[node];
            inline for (.{ leaf_area, leaf_carbon, leaf_protein }) |value|
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidCanopyNodeBiochemistryState;
            if (leaf_area <= presence_threshold or leaf_carbon <= presence_threshold or leaf_protein <= 0)
                continue;

            const leaf_protein_per_area = leaf_protein / leaf_area;
            var co2_limited: f64 = undefined;
            var light_saturated: f64 = undefined;
            var carboxylation_per_electron: f64 = undefined;
            var biochemical_feedback: f64 = undefined;
            switch (parameters.pathway) {
                .c3 => {
                    const capacity = try stomatal.c3Capacity(
                        leaf_protein_per_area,
                        parameters.rubisco_leaf_protein_fraction,
                        parameters.c3_chlorophyll_leaf_protein_fraction,
                        parameters.rubisco_carboxylation_umol_per_g_protein_s,
                        parameters.rubisco_oxygenation_umol_per_g_protein_s,
                        parameters.chlorophyll_electron_transport_umol_per_g_protein_s,
                        gas,
                        gas.dissolved_co2_umol_per_l,
                    );
                    co2_limited = capacity.co2_limited_carboxylation_umol_per_m2_s;
                    light_saturated = capacity.light_saturated_electron_transport_umol_per_m2_s;
                    carboxylation_per_electron = capacity.carboxylation_umol_co2_per_umol_electron;
                    biochemical_feedback = feedback.c3_fraction;
                },
                .c4 => {
                    const capacity = try c4_capacity.compute(.{
                        .leaf_carbon_g_c = leaf_carbon,
                        .leaf_protein_surface_density_g_per_m2 = leaf_protein_per_area,
                        .mesophyll_nonstructural_carbon_g_c = canopy.node_c4_mesophyll_nonstructural_carbon_g[node],
                        .bundle_sheath_co2_carbon_g_c = canopy.node_bundle_sheath_co2_carbon_g[node],
                        .mesophyll_water_g_per_g_c = context.c4_carbon_parameters.mesophyll_water_g_per_g_c,
                        .bundle_sheath_water_g_per_g_c = context.c4_carbon_parameters.bundle_sheath_water_g_per_g_c,
                        .mesophyll_feedback_half_saturation_umol_per_l = context.c4_carbon_parameters.mesophyll_feedback_half_saturation_umol_per_l,
                        .annual_termination_fraction = feedback.annual_termination_fraction,
                        .pep_carboxylase_protein_fraction = parameters.pep_leaf_protein_fraction,
                        .mesophyll_chlorophyll_protein_fraction = parameters.c4_chlorophyll_leaf_protein_fraction,
                        .pep_carboxylation_umol_per_g_s_25c = parameters.pep_carboxylation_umol_per_g_protein_s,
                        .carboxylation_temperature_factor = gas.rubisco_carboxylation_temperature_factor,
                        .dissolved_co2_umol_per_l = gas.dissolved_co2_umol_per_l,
                        .co2_compensation_umol_per_l = context.c4_carbon_parameters.co2_compensation_umol_per_l,
                        .pep_co2_half_saturation_umol_per_l = parameters.pep_co2_half_saturation_umol_per_l,
                        .chlorophyll_electron_transport_umol_per_g_s_25c = parameters.chlorophyll_electron_transport_umol_per_g_protein_s,
                        .electron_transport_temperature_factor = gas.electron_transport_temperature_factor,
                        .electron_requirement_umol_e_per_umol_co2 = context.c4_carbon_parameters.electron_requirement_umol_e_per_umol_co2,
                    });
                    co2_limited = capacity.co2_limited_carboxylation_umol_per_m2_s;
                    light_saturated = capacity.light_saturated_electron_transport_umol_per_m2_s;
                    carboxylation_per_electron = capacity.carboxylation_umol_co2_per_umol_electron;
                    biochemical_feedback = capacity.feedback_fraction;
                },
            }

            const samples = try canopy.sampleRange(node);
            if (samples.end - samples.first != expected_samples)
                return error.CanopySampleTopologyMismatch;
            for (0..context.layers.layer_count) |layer| for (0..inclination_count) |inclination| for (0..azimuth_count) |azimuth| {
                const local_angle = inclination * azimuth_count + azimuth;
                const sample = samples.first + layer * angular_count + local_angle;
                const area = canopy.sample_exposed_leaf_area_m2[sample];
                if (!std.math.isFinite(area) or area < 0) return error.InvalidCanopySample;
                var diffuse_incidence: f64 = 0;
                for (0..context.geometry.sky_azimuth_radians.len) |sky|
                    diffuse_incidence += context.geometry.diffuse_incidence_fraction[
                        context.geometry.index(sky, inclination, azimuth)
                    ];
                const boundary_above = cell * (context.layers.layer_count + 1) + layer + 1;
                total_umol_per_s += try integrateBeam(
                    context.optics.direct_leaf_par_micromol_per_m2_per_s[context.plant] *
                        context.direct_incidence_fraction[cell * angular_count + local_angle],
                    area,
                    context.interception.direct_boundary_transmission_fraction[boundary_above],
                    co2_limited,
                    light_saturated,
                    carboxylation_per_electron,
                    biochemical_feedback,
                );
                total_umol_per_s += try integrateBeam(
                    context.optics.diffuse_leaf_par_micromol_per_m2_per_s[context.plant] * diffuse_incidence,
                    area,
                    context.interception.diffuse_boundary_transmission_fraction[boundary_above],
                    co2_limited,
                    light_saturated,
                    carboxylation_per_electron,
                    biochemical_feedback,
                );
            };
        }
    }
    if (!std.math.isFinite(total_umol_per_s)) return error.NonFiniteCanopyCarboxylation;
    return total_umol_per_s;
}

fn integrateBeam(
    par: f64,
    area: f64,
    transmission: f64,
    co2_limited: f64,
    light_saturated: f64,
    carboxylation_per_electron: f64,
    feedback: f64,
) !f64 {
    inline for (.{ par, area, transmission, co2_limited, light_saturated, carboxylation_per_electron, feedback }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteCanopySample;
    if (par < 0 or area < 0 or transmission < 0 or co2_limited < 0 or light_saturated < 0 or carboxylation_per_electron < 0 or feedback < 0)
        return error.InvalidCanopySample;
    if (par == 0 or area == 0 or transmission == 0) return 0;
    const electron_transport = try stomatal.lightLimitedElectronTransport(par, light_saturated);
    return @min(co2_limited, electron_transport * carboxylation_per_electron) * feedback * area * transmission;
}

test "current TKC causally changes pure STOMATE CH2O without publishing state" {
    var canopy = try Canopy.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    var layers = try LayerState.init(std.testing.allocator, 1, 1, 1, 1, 1, &canopy);
    defer layers.deinit();
    var interception = try Interception.init(std.testing.allocator, 1, 1, 1);
    defer interception.deinit();
    var geometry = try Geometry.init(std.testing.allocator, .{ .leaf_inclination_class_count = 1, .leaf_azimuth_class_count = 1, .diffuse_sky_sector_count = 1 });
    defer geometry.deinit();
    var dormancy = try Dormancy.RuntimeState.init(std.testing.allocator, 1);
    defer dormancy.deinit();
    var development = try BranchDevelopment.init(std.testing.allocator, 1);
    defer development.deinit();
    var growth = try GrowthStages.init(std.testing.allocator, &.{1});
    defer growth.deinit();

    canopy.plant_population_count[0] = 1;
    canopy.plant_intercellular_oxygen_umol_per_mol[0] = 210_000;
    canopy.node_leaf_area_m2[0] = 1;
    canopy.node_leaf_carbon_g[0] = 2;
    canopy.node_leaf_protein_g[0] = 1;
    canopy.sample_exposed_leaf_area_m2[0] = 1;
    interception.direct_boundary_transmission_fraction[1] = 1;
    interception.diffuse_boundary_transmission_fraction[1] = 1;
    var active = [_]bool{true};
    var one = [_]f64{1};
    var zero = [_]f64{0};
    var direct_par = [_]f64{1200};
    const optics: Optics = .{
        .allocator = std.testing.allocator,
        .cell_count = 1,
        .species_count = 1,
        .species_is_active = &active,
        .leaf_shortwave_absorptivity = &one,
        .leaf_par_absorptivity = &one,
        .leaf_shortwave_albedo = &zero,
        .leaf_par_albedo = &zero,
        .leaf_shortwave_transmission = &zero,
        .leaf_par_transmission = &zero,
        .direct_leaf_shortwave_megajoules_per_m2 = &zero,
        .diffuse_leaf_shortwave_megajoules_per_m2 = &zero,
        .direct_leaf_par_micromol_per_m2_per_s = &direct_par,
        .diffuse_leaf_par_micromol_per_m2_per_s = &zero,
    };
    var parameters = [_]biochemistry.Parameters{.{
        .pathway = .c3,
        .growth_habit = 0,
        .phenology_type = 0,
        .aboveground_turnover_type = 0,
        .rubisco_carboxylation_umol_per_g_protein_s = 75,
        .rubisco_oxygenation_umol_per_g_protein_s = 20,
        .pep_carboxylation_umol_per_g_protein_s = 0,
        .rubisco_co2_half_saturation_umol_per_l = 30,
        .rubisco_o2_half_saturation_umol_per_l = 300,
        .pep_co2_half_saturation_umol_per_l = 0,
        .rubisco_leaf_protein_fraction = 0.2,
        .pep_leaf_protein_fraction = 0,
        .chlorophyll_electron_transport_umol_per_g_protein_s = 100,
        .c3_chlorophyll_leaf_protein_fraction = 0.1,
        .c4_chlorophyll_leaf_protein_fraction = 0,
        .intercellular_to_atmospheric_co2_ratio = 0.7,
    }};
    const dormancy_parameters = [_]Dormancy.Parameters{.{
        .required_leafout_h = 2,
        .required_leafoff_h = 2,
        .leafout_temperature_threshold_c = 5,
        .leafoff_temperature_threshold_c = 0,
        .chilling_temperature_c = -5,
        .drought_leafout_total_water_potential_megapascal = -0.1,
        .combined_leafout_turgor_potential_megapascal = 0.1,
        .leafoff_total_water_potential_megapascal = -1.5,
        .drought_leafoff_total_water_potential_megapascal = -2,
        .maximum_photoperiod_counter_h = 3600,
        .evergreen_leafoff_remobilization_start_fraction = 0.75,
        .deciduous_leafoff_remobilization_start_fraction = 0.5,
        .full_senescence_duration_h = 480,
    }};
    var direct_incidence = [_]f64{1};
    const context: Context = .{
        .canopy = &canopy,
        .layers = &layers,
        .interception = &interception,
        .optics = &optics,
        .geometry = &geometry,
        .parameters_by_plant = &parameters,
        .c4_carbon_parameters = @import("photosynthesis.zig").sourceC4CarbonParameters(),
        .direct_incidence_fraction = &direct_incidence,
        .atmospheric_co2_umol_per_mol_by_cell = &.{420},
        .dormancy = &dormancy,
        .branch_development = &development,
        .growth_stages = &growth,
        .dormancy_parameters_by_plant = &dormancy_parameters,
        .annual_termination_hours_without_grain_fill = 336,
        .presence_threshold_g_per_plant = 1.0e-12,
        .plant = 0,
    };
    const heat_before = canopy.plant_heat_stress_h[0];
    const chill_before = canopy.plant_chilling_stress_h[0];
    const capacity_before = canopy.node_co2_limited_carboxylation_umol_per_m2_s[0];
    const published_before = canopy.plant_maximum_turgor_carboxylation_umol_per_s[0];
    const cool = try compute(context, 288.15);
    const warm = try compute(context, 308.15);
    try std.testing.expect(cool > 0 and warm > 0);
    try std.testing.expect(@abs(warm - cool) > 1.0e-6);
    try std.testing.expectEqual(heat_before, canopy.plant_heat_stress_h[0]);
    try std.testing.expectEqual(chill_before, canopy.plant_chilling_stress_h[0]);
    try std.testing.expectEqual(capacity_before, canopy.node_co2_limited_carboxylation_umol_per_m2_s[0]);
    try std.testing.expectEqual(published_before, canopy.plant_maximum_turgor_carboxylation_umol_per_s[0]);

    // HFUNC immediately precedes UPTAKE/STOMATE. Put a perennial in the exact
    // post-leafoff/pre-leafout inactive window, then advance one warm HFUNC
    // hour across the leafout threshold. The same-hour STOMATE producer and
    // its RSMN boundary must both observe the transition.
    parameters[0].growth_habit = 1;
    parameters[0].phenology_type = 1;
    dormancy.branches[0].accumulated_leafout_h = 1;
    dormancy.branches[0].accumulated_leafoff_h = 2;
    const before_hfunc = try compute(context, 288.15);
    try Dormancy.advance(&dormancy.branches[0], .{
        .day_of_year = 100,
        .execution_year = 2020,
        .latitude_deg_n = 53,
        .timestep_h = 1,
        .current_daylength_h = 13,
        .previous_daylength_h = 12.9,
        .maximum_seasonal_daylength_h = 17,
        .canopy_temperature_c = 15,
        .canopy_turgor_potential_megapascal = 0.2,
        .canopy_total_water_potential_megapascal = -0.05,
        .surface_soil_water_potential_megapascal = -0.1,
        .seed_layer_soil_water_potential_megapascal = -0.1,
        .emerged = true,
        .floral_initiated = false,
    }, dormancy_parameters[0], .perennial, .winter_deciduous);
    const after_hfunc = try compute(context, 288.15);
    try std.testing.expectEqual(@as(f64, 0), before_hfunc);
    try std.testing.expect(after_hfunc > 0);
    const rsm_before = try minimum_stomatal.compute(.{
        .photosynthesis_active = true,
        .canopy_co2_fixation_umol_per_s = before_hfunc,
        .negligible_fixation_umol_per_s = 1.0e-12,
        .canopy_radiation_fraction = 0.5,
        .co2_concentration_difference_umol_per_m3 = 500,
        .horizontal_cell_area_m2 = 1,
        .seconds_per_hour = 3_600,
        .cuticular_water_vapor_resistance_h_per_m = 0.03,
        .co2_to_water_cuticular_resistance_ratio = 1.56,
        .minimum_co2_stomatal_resistance_h_per_m = 2.78e-3,
        .co2_to_water_stomatal_resistance_ratio = 0.641,
    });
    const rsm_after = try minimum_stomatal.compute(.{
        .photosynthesis_active = true,
        .canopy_co2_fixation_umol_per_s = after_hfunc,
        .negligible_fixation_umol_per_s = 1.0e-12,
        .canopy_radiation_fraction = 0.5,
        .co2_concentration_difference_umol_per_m3 = 500,
        .horizontal_cell_area_m2 = 1,
        .seconds_per_hour = 3_600,
        .cuticular_water_vapor_resistance_h_per_m = 0.03,
        .co2_to_water_cuticular_resistance_ratio = 1.56,
        .minimum_co2_stomatal_resistance_h_per_m = 2.78e-3,
        .co2_to_water_stomatal_resistance_ratio = 0.641,
    });
    try std.testing.expect(rsm_after != rsm_before);
    parameters[0].growth_habit = 0;
    parameters[0].phenology_type = 0;
    dormancy.branches[0] = .{};

    // Cross-check the extracted producer against the capacity arrays written
    // by the existing STOMATE translation at the same TKC. This catches
    // future drift in kinetics, light response, feedback, or C3/C4 selection.
    var temperature = [_]f64{308.15};
    var apply_context: biochemistry.ApplyContext = .{
        .canopy = &canopy,
        .parameters_by_plant = &parameters,
        .c4_carbon_parameters = context.c4_carbon_parameters,
        .canopy_temperature_k_by_plant = &temperature,
        .atmospheric_co2_umol_per_mol_by_cell = &.{420},
        .dormancy = &dormancy,
        .branch_development = &development,
        .growth_stages = &growth,
        .dormancy_parameters_by_plant = &dormancy_parameters,
        .stress_parameters = biochemistry.compatibilityStressParameters(),
        .annual_termination_hours_without_grain_fill = 336,
        .presence_threshold_g_per_plant = 1.0e-12,
        .timestep_h = 1,
    };
    try biochemistry.applyTile(&apply_context, .{ .first = 0, .end = 1 });
    const direct = [_]f64{1200};
    const no_diffuse = [_]f64{0};
    const exposed = [_]f64{1};
    const transmitted = [_]f64{1};
    const c3_from_published_capacity = try stomatal.integrateCarboxylationUmolPerS(
        &direct,
        &no_diffuse,
        &exposed,
        &transmitted,
        &transmitted,
        canopy.node_co2_limited_carboxylation_umol_per_m2_s[0],
        canopy.node_light_saturated_electron_transport_umol_per_m2_s[0],
        canopy.node_carboxylation_umol_co2_per_umol_electron[0],
        canopy.branch_c3_feedback_fraction[0],
    );
    try std.testing.expectApproxEqRel(c3_from_published_capacity, warm, 1.0e-14);

    parameters[0].pathway = .c4;
    parameters[0].pep_carboxylation_umol_per_g_protein_s = 40;
    parameters[0].pep_co2_half_saturation_umol_per_l = 10;
    parameters[0].pep_leaf_protein_fraction = 0.1;
    parameters[0].c4_chlorophyll_leaf_protein_fraction = 0.1;
    const c4_pure = try compute(context, temperature[0]);
    try biochemistry.applyTile(&apply_context, .{ .first = 0, .end = 1 });
    const c4_from_published_capacity = try stomatal.integrateCarboxylationUmolPerS(
        &direct,
        &no_diffuse,
        &exposed,
        &transmitted,
        &transmitted,
        canopy.node_co2_limited_carboxylation_umol_per_m2_s[0],
        canopy.node_light_saturated_electron_transport_umol_per_m2_s[0],
        canopy.node_carboxylation_umol_co2_per_umol_electron[0],
        canopy.node_c4_feedback_fraction[0],
    );
    try std.testing.expect(c4_pure > 0);
    try std.testing.expectApproxEqRel(c4_from_published_capacity, c4_pure, 1.0e-14);

    // HFUNC inserts the branch before UPTAKE. Populate the newly published
    // node as the later HFUNC initialization would and prove that the same
    // final STOMATE scan sees it rather than retaining the entry topology.
    parameters[0].pathway = .c3;
    const before_topology = try compute(context, temperature[0]);
    const inserted = try plant_topology.appendShootBranch(.{
        .canopy = &canopy,
        .growth_stages = &growth,
        .dormancy = &dormancy,
        .branch_development = &development,
    }, 0, .{
        .sample_count_by_node = &.{1},
        .maturity_group = 1,
        .seed_initial_stage = 1,
        .leafout_initialization_enabled = false,
        .perennial_node_scaling = 1,
        .maximum_concurrently_growing_nodes = 1,
    });
    const new_nodes = try canopy.nodeRange(inserted);
    canopy.node_leaf_area_m2[new_nodes.first] = 1;
    canopy.node_leaf_carbon_g[new_nodes.first] = 2;
    canopy.node_leaf_protein_g[new_nodes.first] = 1;
    const new_samples = try canopy.sampleRange(new_nodes.first);
    canopy.sample_exposed_leaf_area_m2[new_samples.first] = 1;
    const after_topology = try compute(context, temperature[0]);
    try std.testing.expect(after_topology > before_topology);
}
