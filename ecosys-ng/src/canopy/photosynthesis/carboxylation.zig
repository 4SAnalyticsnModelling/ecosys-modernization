const std = @import("std");
const CellRange = @import("../../core/compute.zig").CellRange;
const Canopy = @import("photosynthesis.zig").State;
const C4CarbonParameters = @import("photosynthesis.zig").C4CarbonParameters;
const LayerState = @import("../radiation/layer_distribution.zig").State;
const Interception = @import("../energy/interception.zig").State;
const Optics = @import("../radiation/optics.zig").State;
const Geometry = @import("../morphology/geometry.zig").Geometry;
const biochemistry = @import("biochemistry.zig");
const stomatal = @import("../energy/stomatal_resistance.zig");
const solver = @import("leaf_co2_solver.zig");
const water_response = @import("carboxylation_water_response.zig");
const CarbonExchange = @import("carbon_exchange.zig").State;
const c4_node_exchange_eligibility = @import("c4_node_exchange_eligibility.zig");

pub const ApplyContext = struct {
    canopy: *Canopy,
    layers: *const LayerState,
    interception: *const Interception,
    optics: *const Optics,
    geometry: *const Geometry,
    parameters_by_plant: []const biochemistry.Parameters,
    c4_carbon_parameters: C4CarbonParameters,
    direct_incidence_fraction: []const f64,
    canopy_temperature_k_by_plant: []const f64,
    stomatal_resistance_h_per_m_by_plant: []const f64,
    minimum_stomatal_resistance_h_per_m_by_plant: []const f64,
    shallow_root_profile_by_plant: []const u8,
    canopy_total_water_potential_mpa_by_plant: []const f64,
    minimum_co2_stomatal_resistance_s_per_m: f64,
    leaf_carbon_presence_threshold_g_c_per_plant: f64,
    atmospheric_co2_umol_per_mol_by_cell: []const f64,
    picard_relaxation: f64,
    max_iterations: u16,
    timestep_h: f64,
    carbon_exchange: ?*CarbonExchange = null,
};

/// Ports the GROSUB direct/diffuse leaf loops onto runtime samples. Each beam
/// has its own bounded 100-step Newtonâ€“Picard CO2 diffusion balance and exits
/// immediately at the legacy 0.005 normalized mismatch.
pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    const canopy = context.canopy;
    const plant_count = canopy.cell_count * canopy.species_count;
    const inclination_count = context.geometry.leaf_inclination_sine.len;
    const azimuth_count = context.geometry.leaf_azimuth_radians.len;
    const angular_count = try std.math.mul(usize, inclination_count, azimuth_count);
    const expected_samples = try std.math.mul(usize, context.layers.layer_count, angular_count);
    inline for (.{
        context.parameters_by_plant,
        context.canopy_temperature_k_by_plant,
        context.stomatal_resistance_h_per_m_by_plant,
        context.minimum_stomatal_resistance_h_per_m_by_plant,
        context.shallow_root_profile_by_plant,
        context.canopy_total_water_potential_mpa_by_plant,
    }) |values| if (values.len != plant_count) return error.CanopyCarboxylationDimensionMismatch;
    if (range.end > canopy.cell_count or context.atmospheric_co2_umol_per_mol_by_cell.len != canopy.cell_count or context.layers.cell_count != canopy.cell_count or context.interception.cell_count != canopy.cell_count or context.optics.cell_count != canopy.cell_count or context.direct_incidence_fraction.len != canopy.cell_count * angular_count) return error.CanopyCarboxylationDimensionMismatch;
    if (!std.math.isFinite(context.leaf_carbon_presence_threshold_g_c_per_plant) or
        context.leaf_carbon_presence_threshold_g_c_per_plant < 0 or
        !std.math.isFinite(context.minimum_co2_stomatal_resistance_s_per_m) or
        context.minimum_co2_stomatal_resistance_s_per_m <= 0)
        return error.InvalidCanopyC4LeafCarbonThreshold;
    for (canopy.plant_population_count) |population| if (!std.math.isFinite(population) or population < 0)
        return error.InvalidCanopyPlantPopulation;
    for (range.first..range.end) |cell| for (0..canopy.species_count) |species| {
        const atmospheric_co2_umol_per_mol = context.atmospheric_co2_umol_per_mol_by_cell[cell];
        if (!std.math.isFinite(atmospheric_co2_umol_per_mol) or atmospheric_co2_umol_per_mol <= 0) return error.InvalidAtmosphericCo2;
        const plant = try canopy.plantIndex(cell, species);
        canopy.plant_carboxylation_umol_per_s[plant] = 0;
        canopy.plant_maximum_turgor_carboxylation_umol_per_s[plant] = 0;
        canopy.plant_gross_primary_productivity_g_c_per_h[plant] = 0;
        const branches = try canopy.branchRange(plant);
        var active_leaf_area_m2: f64 = 0;
        for (branches.first..branches.end) |branch| {
            canopy.branch_carboxylation_umol_per_s[branch] = 0;
            canopy.branch_fixed_carbon_g_c_per_h[branch] = 0;
            canopy.branch_shoot_carbohydrate_g_c_per_h[branch] = 0;
            if (context.carbon_exchange) |ledger| {
                if (ledger.branchCount() != canopy.branch_node_offsets.len - 1) return error.CanopyCarbonExchangeDimensionMismatch;
                ledger.fixed_carbon_g_c_per_h[branch] = 0;
                ledger.c4_leakage_g_c_per_h[branch] = 0;
            }
            const nodes = try canopy.nodeRange(branch);
            for (nodes.first..nodes.end) |node| {
                const samples = try canopy.sampleRange(node);
                for (samples.first..samples.end) |sample| {
                    canopy.sample_carboxylation_umol_per_s[sample] = 0;
                    canopy.sample_bundle_sheath_carboxylation_umol_per_s[sample] = 0;
                    canopy.sample_intercellular_co2_umol_per_mol[sample] = 0;
                    active_leaf_area_m2 += canopy.sample_exposed_leaf_area_m2[sample];
                }
            }
        }
        if (active_leaf_area_m2 <= 0) continue;
        const current_resistance_h_per_m = context.stomatal_resistance_h_per_m_by_plant[plant];
        const minimum_resistance_h_per_m = context.minimum_stomatal_resistance_h_per_m_by_plant[plant];
        const cuticular_resistance_h_per_m = canopy.plant_cuticular_water_vapor_resistance_h_per_m[plant];
        if (!std.math.isFinite(current_resistance_h_per_m) or current_resistance_h_per_m <= 0 or !std.math.isFinite(minimum_resistance_h_per_m) or minimum_resistance_h_per_m < 0 or minimum_resistance_h_per_m > current_resistance_h_per_m or !std.math.isFinite(cuticular_resistance_h_per_m) or cuticular_resistance_h_per_m < minimum_resistance_h_per_m) return error.InvalidCanopyStomatalResistance;
        const canopy_temperature_k = context.canopy_temperature_k_by_plant[plant];
        if (!std.math.isFinite(canopy_temperature_k) or canopy_temperature_k <= 0) return error.InvalidCanopyCarboxylationTemperature;
        const air_amount_mol_per_m3 = 12_194.0 / canopy_temperature_k;
        const resistance_span_h_per_m = cuticular_resistance_h_per_m - minimum_resistance_h_per_m;
        const stomatal_turgor_response = if (resistance_span_h_per_m > 0)
            (current_resistance_h_per_m - minimum_resistance_h_per_m) / resistance_span_h_per_m
        else
            0;
        const shallow_root_growth_water_response = @exp(0.05 * context.canopy_total_water_potential_mpa_by_plant[plant]);
        const atmospheric_to_intercellular_co2_umol_per_m3 = air_amount_mol_per_m3 * atmospheric_co2_umol_per_mol *
            (1 - context.parameters_by_plant[plant].intercellular_to_atmospheric_co2_ratio);
        for (branches.first..branches.end) |branch| {
            canopy.branch_carboxylation_umol_per_s[branch] = 0;
            canopy.branch_fixed_carbon_g_c_per_h[branch] = 0;
            canopy.branch_shoot_carbohydrate_g_c_per_h[branch] = 0;
            const nodes = try canopy.nodeRange(branch);
            for (nodes.first..nodes.end) |node| {
                const feedback = switch (context.parameters_by_plant[plant].pathway) {
                    .c3 => canopy.branch_c3_feedback_fraction[branch],
                    .c4 => canopy.node_c4_feedback_fraction[node],
                };
                const samples = try canopy.sampleRange(node);
                if (samples.end - samples.first != expected_samples) return error.CanopySampleTopologyMismatch;
                var node_bundle_sheath_fixation_umol_per_s: f64 = 0;
                var node_intercellular_co2_area_sum: f64 = 0;
                var node_active_area_m2: f64 = 0;
                for (0..context.layers.layer_count) |layer| for (0..inclination_count) |inclination| for (0..azimuth_count) |azimuth| {
                    const local_angle = inclination * azimuth_count + azimuth;
                    const sample = samples.first + layer * angular_count + local_angle;
                    const boundary_above = cell * (context.layers.layer_count + 1) + layer + 1;
                    var diffuse_incidence: f64 = 0;
                    for (0..context.geometry.sky_azimuth_radians.len) |sky| diffuse_incidence += context.geometry.diffuse_incidence_fraction[context.geometry.index(sky, inclination, azimuth)];
                    canopy.sample_direct_par_umol_per_m2_s[sample] = context.optics.direct_leaf_par_micromol_per_m2_per_s[plant] * context.direct_incidence_fraction[cell * angular_count + local_angle];
                    canopy.sample_diffuse_par_umol_per_m2_s[sample] = context.optics.diffuse_leaf_par_micromol_per_m2_per_s[plant] * diffuse_incidence;
                    canopy.sample_direct_transmission_fraction[sample] = context.interception.direct_boundary_transmission_fraction[boundary_above];
                    canopy.sample_diffuse_transmission_fraction[sample] = context.interception.diffuse_boundary_transmission_fraction[boundary_above];
                    const area_m2 = canopy.sample_exposed_leaf_area_m2[sample];
                    var fixation_umol_per_s: f64 = 0;
                    var bundle_sheath_fixation_umol_per_s: f64 = 0;
                    var intercellular_sum: f64 = 0;
                    var active_beams: f64 = 0;
                    for ([_][2]f64{
                        .{ canopy.sample_direct_par_umol_per_m2_s[sample], canopy.sample_direct_transmission_fraction[sample] },
                        .{ canopy.sample_diffuse_par_umol_per_m2_s[sample], canopy.sample_diffuse_transmission_fraction[sample] },
                    }) |beam| if (area_m2 > 0 and beam[0] > 0 and beam[1] > 0 and canopy.node_co2_unlimited_carboxylation_umol_per_m2_s[node] > 0) {
                        const electron_transport = try stomatal.lightLimitedElectronTransport(beam[0], canopy.node_light_saturated_electron_transport_umol_per_m2_s[node]);
                        // GROSUB 1025--1053 (and the three direct/diffuse,
                        // C3/C4 repeats): each illuminated beam derives its
                        // own zero-water-stress CO2 resistance `RS=DCO2/VL`,
                        // then `RSL`, conductance, and non-stomatal water
                        // response. RSMN's plant-level water resistance only
                        // reconstructs the shared turgor response WFNSC; it is
                        // not substituted for this beam's RS.
                        const preliminary_carboxylation_umol_per_m2_s = @min(
                            canopy.node_co2_limited_carboxylation_umol_per_m2_s[node],
                            electron_transport * canopy.node_carboxylation_umol_co2_per_umol_electron[node],
                        ) * feedback;
                        const beam_water = try water_response.calculate(.{
                            .preliminary_carboxylation_umol_per_m2_s = preliminary_carboxylation_umol_per_m2_s,
                            .negligible_carboxylation_umol_per_m2_s = 1.0e-12,
                            .atmospheric_to_intercellular_co2_umol_per_m3 = atmospheric_to_intercellular_co2_umol_per_m3,
                            .minimum_stomatal_resistance_s_per_m = context.minimum_co2_stomatal_resistance_s_per_m,
                            .cuticular_resistance_s_per_m = canopy.plant_cuticular_co2_resistance_s_per_m[plant],
                            .stomatal_turgor_response = stomatal_turgor_response,
                            .air_amount_mol_per_m3 = air_amount_mol_per_m3,
                            .root_profile = if (context.shallow_root_profile_by_plant[plant] == 0) .shallow else .non_shallow,
                            .shallow_root_growth_water_response = shallow_root_growth_water_response,
                        });
                        if (!beam_water.admitted) continue;
                        const result = try solver.solve(.{
                            .canopy_air_co2_umol_per_mol = atmospheric_co2_umol_per_mol,
                            .co2_solubility_umol_per_l_per_umol_per_mol = canopy.node_co2_solubility_umol_per_l_per_umol_per_mol[node],
                            .compensation_point_umol_per_l = canopy.node_co2_compensation_umol_per_l[node],
                            .electron_requirement_umol_e_per_umol_co2 = if (context.parameters_by_plant[plant].pathway == .c3) 4.5 else context.c4_carbon_parameters.electron_requirement_umol_e_per_umol_co2,
                            .maximum_carboxylation_umol_per_m2_s = canopy.node_co2_unlimited_carboxylation_umol_per_m2_s[node],
                            .carboxylation_half_saturation_umol_per_l = canopy.node_carboxylation_half_saturation_umol_per_l[node],
                            .electron_transport_umol_e_per_m2_s = electron_transport,
                            .water_stress_fraction = beam_water.c4_water_response,
                            .biochemical_feedback_fraction = feedback,
                            .stomatal_conductance_mol_per_m2_s = beam_water.stomatal_conductance_mol_per_m2_s,
                        }, context.parameters_by_plant[plant].intercellular_to_atmospheric_co2_ratio * atmospheric_co2_umol_per_mol, context.picard_relaxation, context.max_iterations);
                        fixation_umol_per_s += result.carboxylation_umol_per_m2_s * area_m2 * beam[1];
                        if (context.parameters_by_plant[plant].pathway == .c4) {
                            const bundle_electron_transport = try stomatal.lightLimitedElectronTransport(beam[0], canopy.node_bundle_sheath_light_saturated_electron_transport_umol_per_m2_s[node]);
                            const bundle_rate = @min(
                                canopy.node_bundle_sheath_co2_limited_carboxylation_umol_per_m2_s[node],
                                bundle_electron_transport * canopy.node_bundle_sheath_carboxylation_umol_co2_per_umol_electron[node],
                            ) * beam_water.c3_water_response * canopy.branch_c3_feedback_fraction[branch];
                            bundle_sheath_fixation_umol_per_s += bundle_rate * area_m2 * beam[1];
                        }
                        intercellular_sum += result.intercellular_co2_umol_per_mol;
                        active_beams += 1;
                    };
                    if (!std.math.isFinite(fixation_umol_per_s)) return error.NonFiniteCanopyCarboxylation;
                    canopy.sample_carboxylation_umol_per_s[sample] = fixation_umol_per_s;
                    canopy.sample_bundle_sheath_carboxylation_umol_per_s[sample] = bundle_sheath_fixation_umol_per_s;
                    canopy.sample_intercellular_co2_umol_per_mol[sample] = if (active_beams > 0) intercellular_sum / active_beams else 0;
                    if (active_beams > 0) {
                        node_intercellular_co2_area_sum += canopy.sample_intercellular_co2_umol_per_mol[sample] * area_m2;
                        node_active_area_m2 += area_m2;
                    }
                    node_bundle_sheath_fixation_umol_per_s += bundle_sheath_fixation_umol_per_s;
                    canopy.plant_carboxylation_umol_per_s[plant] += fixation_umol_per_s;
                    canopy.branch_carboxylation_umol_per_s[branch] += fixation_umol_per_s;
                };
                // stomate.f:87/347/395/570/617 `CH2O`: canopy carboxylation
                // capacity at maximum canopy turgor, using this node's
                // capacity (`node_co2_limited_carboxylation_umol_per_m2_s`,
                // already evaluated at the fixed intercellular:atmospheric CO2
                // ratio, never the diffusion-solved value above) and `feedback`
                // (`FDBK`/`FDBK4`) only -- no water-stress term. This must stay
                // independent of `plant_carboxylation_umol_per_s` above, which
                // is GROSUB's actual, water-stress-limited fixation and is the
                // wrong input for STOMATE's `RSMN` (`UPTAKE-003`'s substitution
                // conflated the two; see `CANOPY-STOMATE-RSMN-WATER-STRESS-001`).
                canopy.plant_maximum_turgor_carboxylation_umol_per_s[plant] += try stomatal.integrateCarboxylationUmolPerS(
                    canopy.sample_direct_par_umol_per_m2_s[samples.first..samples.end],
                    canopy.sample_diffuse_par_umol_per_m2_s[samples.first..samples.end],
                    canopy.sample_exposed_leaf_area_m2[samples.first..samples.end],
                    canopy.sample_direct_transmission_fraction[samples.first..samples.end],
                    canopy.sample_diffuse_transmission_fraction[samples.first..samples.end],
                    canopy.node_co2_limited_carboxylation_umol_per_m2_s[node],
                    canopy.node_light_saturated_electron_transport_umol_per_m2_s[node],
                    canopy.node_carboxylation_umol_co2_per_umol_electron[node],
                    feedback,
                );
                if (try c4_node_exchange_eligibility.admitsNode(
                    context.parameters_by_plant[plant].pathway == .c4,
                    canopy.node_leaf_carbon_g[node],
                    context.leaf_carbon_presence_threshold_g_c_per_plant * canopy.plant_population_count[plant],
                )) {
                    const intercellular_co2_umol_per_mol = if (node_active_area_m2 > 0)
                        node_intercellular_co2_area_sum / node_active_area_m2
                    else
                        context.parameters_by_plant[plant].intercellular_to_atmospheric_co2_ratio * atmospheric_co2_umol_per_mol;
                    const bundle_sheath_fixation_g_c = node_bundle_sheath_fixation_umol_per_s * 0.0432 * context.timestep_h;
                    const c4_fluxes = try @import("photosynthesis.zig").advanceC4CarbonPools(
                        canopy,
                        node,
                        canopyNodeFixation(canopy, samples) * 0.0432 * context.timestep_h,
                        bundle_sheath_fixation_g_c,
                        intercellular_co2_umol_per_mol * canopy.node_co2_solubility_umol_per_l_per_umol_per_mol[node],
                        context.c4_carbon_parameters,
                        context.timestep_h,
                    );
                    if (context.carbon_exchange) |ledger| ledger.c4_leakage_g_c_per_h[branch] += c4_fluxes.bundle_sheath_co2_leakage_g_c / context.timestep_h;
                    canopy.branch_shoot_carbohydrate_g_c_per_h[branch] += bundle_sheath_fixation_g_c / context.timestep_h;
                }
            }
            // 12e-6 g C per umol CO2 Ã— 3600 s per hour.
            canopy.branch_fixed_carbon_g_c_per_h[branch] = canopy.branch_carboxylation_umol_per_s[branch] * 0.0432;
            if (context.carbon_exchange) |ledger| ledger.fixed_carbon_g_c_per_h[branch] = canopy.branch_fixed_carbon_g_c_per_h[branch];
            if (context.parameters_by_plant[plant].pathway == .c3)
                canopy.branch_shoot_carbohydrate_g_c_per_h[branch] = canopy.branch_fixed_carbon_g_c_per_h[branch];
            canopy.plant_gross_primary_productivity_g_c_per_h[plant] += canopy.branch_fixed_carbon_g_c_per_h[branch];
        }
        if (!std.math.isFinite(canopy.plant_carboxylation_umol_per_s[plant])) return error.NonFiniteCanopyCarboxylation;
        if (!std.math.isFinite(canopy.plant_maximum_turgor_carboxylation_umol_per_s[plant])) return error.NonFiniteCanopyCarboxylation;
    };
}

fn canopyNodeFixation(canopy: *const Canopy, samples: anytype) f64 {
    var fixation_umol_per_s: f64 = 0;
    for (samples.first..samples.end) |sample| fixation_umol_per_s += canopy.sample_carboxylation_umol_per_s[sample];
    return fixation_umol_per_s;
}

test "runtime sample uses bounded leaf CO2 convergence and publishes fixation" {
    var canopy = try Canopy.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    var layers = try LayerState.init(std.testing.allocator, 1, 1, 1, 1, 1, &canopy);
    defer layers.deinit();
    var interception = try Interception.init(std.testing.allocator, 1, 1, 1);
    defer interception.deinit();
    var geometry = try Geometry.init(std.testing.allocator, .{ .leaf_inclination_class_count = 1, .leaf_azimuth_class_count = 1, .diffuse_sky_sector_count = 1 });
    defer geometry.deinit();
    var carbon_exchange = try CarbonExchange.init(std.testing.allocator, 1);
    defer carbon_exchange.deinit();
    var active = [_]bool{true};
    var coefficient = [_]f64{1};
    var direct_par = [_]f64{1000};
    var zero = [_]f64{0};
    const optics: Optics = .{
        .allocator = std.testing.allocator,
        .cell_count = 1,
        .species_count = 1,
        .species_is_active = &active,
        .leaf_shortwave_absorptivity = &coefficient,
        .leaf_par_absorptivity = &coefficient,
        .leaf_shortwave_albedo = &zero,
        .leaf_par_albedo = &zero,
        .leaf_shortwave_transmission = &zero,
        .leaf_par_transmission = &zero,
        .direct_leaf_shortwave_megajoules_per_m2 = &zero,
        .diffuse_leaf_shortwave_megajoules_per_m2 = &zero,
        .direct_leaf_par_micromol_per_m2_per_s = &direct_par,
        .diffuse_leaf_par_micromol_per_m2_per_s = &zero,
    };
    canopy.sample_exposed_leaf_area_m2[0] = 1;
    canopy.node_co2_unlimited_carboxylation_umol_per_m2_s[0] = 75;
    canopy.node_co2_limited_carboxylation_umol_per_m2_s[0] = 60;
    canopy.node_co2_solubility_umol_per_l_per_umol_per_mol[0] = 0.03;
    canopy.node_co2_compensation_umol_per_l[0] = 1.2;
    canopy.node_carboxylation_half_saturation_umol_per_l[0] = 15;
    canopy.node_light_saturated_electron_transport_umol_per_m2_s[0] = 150;
    canopy.node_carboxylation_umol_co2_per_umol_electron[0] = 0.2;
    canopy.branch_c3_feedback_fraction[0] = 1;
    var parameters = [_]biochemistry.Parameters{.{
        .pathway = .c3,
        .growth_habit = 0,
        .phenology_type = 0,
        .aboveground_turnover_type = 0,
        .rubisco_carboxylation_umol_per_g_protein_s = 75,
        .rubisco_oxygenation_umol_per_g_protein_s = 20,
        .pep_carboxylation_umol_per_g_protein_s = 40,
        .rubisco_co2_half_saturation_umol_per_l = 30,
        .rubisco_o2_half_saturation_umol_per_l = 300,
        .pep_co2_half_saturation_umol_per_l = 10,
        .rubisco_leaf_protein_fraction = 0.2,
        .pep_leaf_protein_fraction = 0.1,
        .chlorophyll_electron_transport_umol_per_g_protein_s = 100,
        .c3_chlorophyll_leaf_protein_fraction = 0.1,
        .c4_chlorophyll_leaf_protein_fraction = 0.1,
        .intercellular_to_atmospheric_co2_ratio = 0.7,
    }};
    var direct_incidence = [_]f64{1};
    var temperature_k = [_]f64{298.15};
    var resistance_h_per_m = [_]f64{0.01};
    var minimum_resistance_h_per_m = [_]f64{0.005};
    var root_profile = [_]u8{1};
    var total_water_potential_megapascal = [_]f64{-0.5};
    canopy.plant_cuticular_water_vapor_resistance_h_per_m[0] = 0.02;
    canopy.plant_cuticular_co2_resistance_s_per_m[0] = 112.32;
    var context: ApplyContext = .{
        .canopy = &canopy,
        .layers = &layers,
        .interception = &interception,
        .optics = &optics,
        .geometry = &geometry,
        .parameters_by_plant = &parameters,
        .c4_carbon_parameters = @import("photosynthesis.zig").sourceC4CarbonParameters(),
        .direct_incidence_fraction = &direct_incidence,
        .canopy_temperature_k_by_plant = &temperature_k,
        .stomatal_resistance_h_per_m_by_plant = &resistance_h_per_m,
        .minimum_stomatal_resistance_h_per_m_by_plant = &minimum_resistance_h_per_m,
        .shallow_root_profile_by_plant = &root_profile,
        .canopy_total_water_potential_mpa_by_plant = &total_water_potential_megapascal,
        .minimum_co2_stomatal_resistance_s_per_m = 2.78e-3 * 3600.0,
        .leaf_carbon_presence_threshold_g_c_per_plant = 0,
        .atmospheric_co2_umol_per_mol_by_cell = &.{420},
        .picard_relaxation = 0.5,
        .max_iterations = 100,
        .timestep_h = 1,
        .carbon_exchange = &carbon_exchange,
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(canopy.sample_carboxylation_umol_per_s[0] > 0);
    try std.testing.expectEqual(canopy.sample_carboxylation_umol_per_s[0], canopy.plant_carboxylation_umol_per_s[0]);
    try std.testing.expect(canopy.sample_intercellular_co2_umol_per_mol[0] > 0);
    try std.testing.expectApproxEqAbs(canopy.plant_carboxylation_umol_per_s[0] * 0.0432, canopy.branch_fixed_carbon_g_c_per_h[0], 1e-14);
    try std.testing.expectEqual(canopy.branch_fixed_carbon_g_c_per_h[0], canopy.plant_gross_primary_productivity_g_c_per_h[0]);
    try std.testing.expectEqual(canopy.branch_fixed_carbon_g_c_per_h[0], carbon_exchange.fixed_carbon_g_c_per_h[0]);

    // GROSUB's IGTYP=0 arm uses WFNSG=exp(0.05*PSILT), not the
    // vascular-canopy turgor response. Prove the production caller carries
    // total canopy water potential through to fixed-carbon publication.
    root_profile[0] = 0;
    total_water_potential_megapascal[0] = -0.1;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const shallow_wet_fixation = canopy.plant_carboxylation_umol_per_s[0];
    total_water_potential_megapascal[0] = -20;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const shallow_dry_fixation = canopy.plant_carboxylation_umol_per_s[0];
    try std.testing.expect(shallow_dry_fixation < shallow_wet_fixation);
    try std.testing.expectEqual(shallow_dry_fixation * 0.0432, canopy.branch_fixed_carbon_g_c_per_h[0]);
    root_profile[0] = 1;
    total_water_potential_megapascal[0] = -0.5;

    canopy.sample_exposed_leaf_area_m2[0] = 0;
    resistance_h_per_m[0] = 0;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 0), canopy.plant_carboxylation_umol_per_s[0]);
    try std.testing.expectEqual(@as(f64, 0), canopy.branch_fixed_carbon_g_c_per_h[0]);
    try std.testing.expectEqual(@as(f64, 0), carbon_exchange.fixed_carbon_g_c_per_h[0]);

    parameters[0].pathway = .c4;
    canopy.sample_exposed_leaf_area_m2[0] = 1;
    resistance_h_per_m[0] = 0.01;
    canopy.node_leaf_carbon_g[0] = 1;
    canopy.node_c3_nonstructural_carbon_g[0] = 1;
    canopy.node_c4_mesophyll_nonstructural_carbon_g[0] = 1;
    canopy.node_bundle_sheath_co2_carbon_g[0] = 1.0e-5;
    canopy.node_bundle_sheath_co2_limited_carboxylation_umol_per_m2_s[0] = 50;
    canopy.node_bundle_sheath_light_saturated_electron_transport_umol_per_m2_s[0] = 120;
    canopy.node_bundle_sheath_carboxylation_umol_co2_per_umol_electron[0] = 0.2;
    canopy.branch_c4_feedback_fraction[0] = 1;
    canopy.node_c4_feedback_fraction[0] = 1;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(canopy.sample_bundle_sheath_carboxylation_umol_per_s[0] > 0);
    try std.testing.expect(canopy.branch_shoot_carbohydrate_g_c_per_h[0] > 0);
    try std.testing.expect(canopy.branch_fixed_carbon_g_c_per_h[0] > canopy.branch_shoot_carbohydrate_g_c_per_h[0]);
    try std.testing.expectEqual(canopy.branch_fixed_carbon_g_c_per_h[0], carbon_exchange.fixed_carbon_g_c_per_h[0]);
    try std.testing.expect(carbon_exchange.c4_leakage_g_c_per_h[0] >= 0);
}
