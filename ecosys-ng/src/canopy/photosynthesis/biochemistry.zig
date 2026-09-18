const std = @import("std");
const CellRange = @import("../../core/compute.zig").CellRange;
const Canopy = @import("photosynthesis.zig").State;
const C4CarbonParameters = @import("photosynthesis.zig").C4CarbonParameters;
const stomatal = @import("../energy/stomatal_resistance.zig");
const Dormancy = @import("../../plant/lifecycle/dormancy.zig");
const BranchDevelopment = @import("../../plant/lifecycle/phenology.zig").BranchDevelopmentState;
const GrowthStages = @import("../../plant/lifecycle/growth_stages.zig").State;
const growth_temperature = @import("../../plant/response/growth_temperature.zig");
const c4_capacity = @import("c4_capacity.zig");

pub const Parameters = struct {
    pathway: enum { c3, c4 },
    growth_habit: u8,
    phenology_type: u8,
    aboveground_turnover_type: u8,
    rubisco_carboxylation_umol_per_g_protein_s: f64,
    rubisco_oxygenation_umol_per_g_protein_s: f64,
    pep_carboxylation_umol_per_g_protein_s: f64,
    rubisco_co2_half_saturation_umol_per_l: f64,
    rubisco_o2_half_saturation_umol_per_l: f64,
    pep_co2_half_saturation_umol_per_l: f64,
    rubisco_leaf_protein_fraction: f64,
    pep_leaf_protein_fraction: f64,
    chlorophyll_electron_transport_umol_per_g_protein_s: f64,
    c3_chlorophyll_leaf_protein_fraction: f64,
    c4_chlorophyll_leaf_protein_fraction: f64,
    intercellular_to_atmospheric_co2_ratio: f64,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field| if (field.type == f64) {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidCanopyBiochemistryParameter;
        };
        if (self.rubisco_carboxylation_umol_per_g_protein_s <= 0 or self.rubisco_co2_half_saturation_umol_per_l <= 0 or self.rubisco_o2_half_saturation_umol_per_l <= 0 or self.intercellular_to_atmospheric_co2_ratio <= 0 or self.intercellular_to_atmospheric_co2_ratio > 1) return error.InvalidCanopyBiochemistryParameter;
        // C3 trait records intentionally carry zero PEP capacity and affinity;
        // those fields are inactive science, not invalid state.
        if (self.pathway == .c4 and (self.pep_carboxylation_umol_per_g_protein_s <= 0 or self.pep_co2_half_saturation_umol_per_l <= 0)) return error.InvalidCanopyBiochemistryParameter;
        if (self.phenology_type > 5) return error.InvalidCanopyBiochemistryParameter;
    }
};

pub const ApplyContext = struct {
    canopy: *Canopy,
    parameters_by_plant: []const Parameters,
    c4_carbon_parameters: C4CarbonParameters,
    canopy_temperature_k_by_plant: []const f64,
    atmospheric_co2_umol_per_mol_by_cell: []const f64,
    dormancy: *const Dormancy.RuntimeState,
    branch_development: *const BranchDevelopment,
    growth_stages: *const GrowthStages,
    dormancy_parameters_by_plant: []const Dormancy.Parameters,
    stress_parameters: StressParameters,
    annual_termination_hours_without_grain_fill: f64,
    presence_threshold_g_per_plant: f64,
    timestep_h: f64,
};

pub const StressParameters = struct {
    maximum_chilling_h: f64,
    heat_accumulation_threshold_c: f64,
    heat_recovery_per_h: f64,
    growth_temperature: growth_temperature.Parameters,

    pub fn validate(self: StressParameters) !void {
        inline for (.{ self.maximum_chilling_h, self.heat_accumulation_threshold_c, self.heat_recovery_per_h }) |value| if (!std.math.isFinite(value)) return error.InvalidCanopyStressParameter;
        if (self.maximum_chilling_h < 0 or self.heat_recovery_per_h < 0) return error.InvalidCanopyStressParameter;
        try self.growth_temperature.validate();
    }
};

pub fn compatibilityStressParameters() StressParameters {
    return .{ .maximum_chilling_h = 24, .heat_accumulation_threshold_c = 60, .heat_recovery_per_h = 0.02, .growth_temperature = growth_temperature.compatibilityParameters() };
}

test "C3 parameters permit inactive zero PEP kinetics" {
    var parameters: Parameters = .{
        .pathway = .c3,
        .growth_habit = 1,
        .phenology_type = 1,
        .aboveground_turnover_type = 1,
        .rubisco_carboxylation_umol_per_g_protein_s = 45,
        .rubisco_oxygenation_umol_per_g_protein_s = 9.5,
        .pep_carboxylation_umol_per_g_protein_s = 0,
        .rubisco_co2_half_saturation_umol_per_l = 12.5,
        .rubisco_o2_half_saturation_umol_per_l = 500,
        .pep_co2_half_saturation_umol_per_l = 0,
        .rubisco_leaf_protein_fraction = 0.125,
        .pep_leaf_protein_fraction = 0,
        .chlorophyll_electron_transport_umol_per_g_protein_s = 405,
        .c3_chlorophyll_leaf_protein_fraction = 0.025,
        .c4_chlorophyll_leaf_protein_fraction = 0,
        .intercellular_to_atmospheric_co2_ratio = 0.7,
    };
    try parameters.validate();
    parameters.pathway = .c4;
    try std.testing.expectError(error.InvalidCanopyBiochemistryParameter, parameters.validate());
}

/// Publishes the temperature- and protein-dependent STOMATE capacity for every
/// runtime node. Radiation integration and the leaf CO2 balance consume these
/// arrays in later kernels.
pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    const canopy = context.canopy;
    try context.c4_carbon_parameters.validate();
    const plant_count = try std.math.mul(usize, canopy.cell_count, canopy.species_count);
    if (range.end > canopy.cell_count or context.atmospheric_co2_umol_per_mol_by_cell.len != canopy.cell_count or context.parameters_by_plant.len != plant_count or context.canopy_temperature_k_by_plant.len != plant_count or context.dormancy_parameters_by_plant.len != plant_count or context.dormancy.branches.len != canopy.branch_node_offsets.len - 1 or context.branch_development.branch_count != canopy.branch_node_offsets.len - 1 or context.growth_stages.branches.len != canopy.branch_node_offsets.len - 1) return error.CanopyBiochemistryDimensionMismatch;
    try context.stress_parameters.validate();
    if (!std.math.isFinite(context.timestep_h) or context.timestep_h <= 0 or !std.math.isFinite(context.annual_termination_hours_without_grain_fill) or context.annual_termination_hours_without_grain_fill <= 0 or !std.math.isFinite(context.presence_threshold_g_per_plant) or context.presence_threshold_g_per_plant < 0) return error.InvalidCanopyBiochemistryTimestep;
    for (range.first..range.end) |cell| for (0..canopy.species_count) |species| {
        const atmospheric_co2_umol_per_mol = context.atmospheric_co2_umol_per_mol_by_cell[cell];
        if (!std.math.isFinite(atmospheric_co2_umol_per_mol) or atmospheric_co2_umol_per_mol <= 0) return error.InvalidAtmosphericCo2;
        const plant = try canopy.plantIndex(cell, species);
        const parameters = context.parameters_by_plant[plant];
        try parameters.validate();
        const canopy_temperature_c = context.canopy_temperature_k_by_plant[plant] - 273.15;
        canopy.plant_uptake_growth_temperature_response[plant] = try growth_temperature.response(
            context.canopy_temperature_k_by_plant[plant] + canopy.plant_thermal_adaptation_offset_c[plant],
            context.stress_parameters.growth_temperature,
        );
        const gas = try stomatal.gasEnvironment(
            context.canopy_temperature_k_by_plant[plant],
            canopy.plant_thermal_adaptation_offset_c[plant],
            atmospheric_co2_umol_per_mol,
            parameters.intercellular_to_atmospheric_co2_ratio,
            canopy.plant_intercellular_oxygen_umol_per_mol[plant],
            parameters.rubisco_co2_half_saturation_umol_per_l,
            parameters.rubisco_o2_half_saturation_umol_per_l,
        );
        const branches = try canopy.branchRange(plant);
        for (branches.first..branches.end) |branch| {
            const dormancy = context.dormancy.branches[branch];
            const feedback = try stomatal.branchFeedback(
                parameters.phenology_type,
                parameters.growth_habit,
                parameters.aboveground_turnover_type,
                dormancy.accumulated_leafout_h,
                context.dormancy_parameters_by_plant[plant].required_leafout_h,
                dormancy.accumulated_leafoff_h,
                context.dormancy_parameters_by_plant[plant].required_leafoff_h,
                canopy.branch_mobile_carbon_g[branch],
                canopy.branch_mobile_nitrogen_g[branch],
                canopy.branch_mobile_phosphorus_g[branch],
                canopy.plant_heat_stress_h[plant],
                context.branch_development.remobilization_progress_h[branch],
                context.branch_development.hours_without_grain_fill[branch],
                context.annual_termination_hours_without_grain_fill,
            );
            canopy.branch_c3_feedback_fraction[branch] = feedback.c3_fraction;
            canopy.branch_c4_feedback_fraction[branch] = feedback.c4_fraction;
            const nodes = try canopy.nodeRange(branch);
            if (!feedback.photosynthetically_active) {
                for (nodes.first..nodes.end) |node| {
                    canopy.node_co2_unlimited_carboxylation_umol_per_m2_s[node] = 0;
                    canopy.node_co2_limited_carboxylation_umol_per_m2_s[node] = 0;
                    canopy.node_co2_compensation_umol_per_l[node] = 0;
                    canopy.node_co2_solubility_umol_per_l_per_umol_per_mol[node] = 0;
                    canopy.node_carboxylation_half_saturation_umol_per_l[node] = 0;
                    canopy.node_light_saturated_electron_transport_umol_per_m2_s[node] = 0;
                    canopy.node_carboxylation_umol_co2_per_umol_electron[node] = 0;
                    canopy.node_c4_feedback_fraction[node] = 0;
                    canopy.node_pep_carboxylase_surface_density_g_per_m2[node] = 0;
                    canopy.node_mesophyll_chlorophyll_surface_density_g_per_m2[node] = 0;
                    canopy.node_bundle_sheath_co2_limited_carboxylation_umol_per_m2_s[node] = 0;
                    canopy.node_bundle_sheath_light_saturated_electron_transport_umol_per_m2_s[node] = 0;
                    canopy.node_bundle_sheath_carboxylation_umol_co2_per_umol_electron[node] = 0;
                }
                continue;
            }
            if (context.growth_stages.branches[branch].dead) continue;
            const presence_threshold =
                context.presence_threshold_g_per_plant *
                canopy.plant_population_count[plant];
            for (nodes.first..nodes.end) |node| {
                const leaf_area_m2 = canopy.node_leaf_area_m2[node];
                const leaf_carbon_g = canopy.node_leaf_carbon_g[node];
                const leaf_protein_g = canopy.node_leaf_protein_g[node];
                if (!std.math.isFinite(leaf_area_m2) or leaf_area_m2 < 0 or !std.math.isFinite(leaf_carbon_g) or leaf_carbon_g < 0 or !std.math.isFinite(leaf_protein_g) or leaf_protein_g < 0) return error.InvalidCanopyNodeBiochemistryState;
                if (leaf_area_m2 <= presence_threshold or leaf_carbon_g <= presence_threshold or leaf_protein_g <= 0) {
                    canopy.node_co2_unlimited_carboxylation_umol_per_m2_s[node] = 0;
                    canopy.node_co2_limited_carboxylation_umol_per_m2_s[node] = 0;
                    canopy.node_co2_compensation_umol_per_l[node] = 0;
                    canopy.node_co2_solubility_umol_per_l_per_umol_per_mol[node] = 0;
                    canopy.node_carboxylation_half_saturation_umol_per_l[node] = 0;
                    canopy.node_light_saturated_electron_transport_umol_per_m2_s[node] = 0;
                    canopy.node_carboxylation_umol_co2_per_umol_electron[node] = 0;
                    canopy.node_c4_feedback_fraction[node] = 0;
                    canopy.node_pep_carboxylase_surface_density_g_per_m2[node] = 0;
                    canopy.node_mesophyll_chlorophyll_surface_density_g_per_m2[node] = 0;
                    canopy.node_bundle_sheath_co2_limited_carboxylation_umol_per_m2_s[node] = 0;
                    canopy.node_bundle_sheath_light_saturated_electron_transport_umol_per_m2_s[node] = 0;
                    canopy.node_bundle_sheath_carboxylation_umol_co2_per_umol_electron[node] = 0;
                    continue;
                }
                const leaf_protein_g_per_m2 = leaf_protein_g / leaf_area_m2;
                switch (parameters.pathway) {
                    .c3 => {
                        const capacity = try stomatal.c3Capacity(
                            leaf_protein_g_per_m2,
                            parameters.rubisco_leaf_protein_fraction,
                            parameters.c3_chlorophyll_leaf_protein_fraction,
                            parameters.rubisco_carboxylation_umol_per_g_protein_s,
                            parameters.rubisco_oxygenation_umol_per_g_protein_s,
                            parameters.chlorophyll_electron_transport_umol_per_g_protein_s,
                            gas,
                            gas.dissolved_co2_umol_per_l,
                        );
                        canopy.node_co2_unlimited_carboxylation_umol_per_m2_s[node] = capacity.co2_unlimited_carboxylation_umol_per_m2_s;
                        canopy.node_co2_limited_carboxylation_umol_per_m2_s[node] = capacity.co2_limited_carboxylation_umol_per_m2_s;
                        canopy.node_co2_compensation_umol_per_l[node] = capacity.co2_compensation_umol_per_l;
                        canopy.node_co2_solubility_umol_per_l_per_umol_per_mol[node] = gas.co2_solubility_umol_per_l_per_umol_per_mol;
                        canopy.node_carboxylation_half_saturation_umol_per_l[node] = gas.rubisco_co2_half_saturation_with_o2_umol_per_l;
                        canopy.node_light_saturated_electron_transport_umol_per_m2_s[node] = capacity.light_saturated_electron_transport_umol_per_m2_s;
                        canopy.node_carboxylation_umol_co2_per_umol_electron[node] = capacity.carboxylation_umol_co2_per_umol_electron;
                        canopy.node_c4_feedback_fraction[node] = 0;
                        canopy.node_pep_carboxylase_surface_density_g_per_m2[node] = 0;
                        canopy.node_mesophyll_chlorophyll_surface_density_g_per_m2[node] = 0;
                        canopy.node_bundle_sheath_co2_limited_carboxylation_umol_per_m2_s[node] = 0;
                        canopy.node_bundle_sheath_light_saturated_electron_transport_umol_per_m2_s[node] = 0;
                        canopy.node_bundle_sheath_carboxylation_umol_co2_per_umol_electron[node] = 0;
                    },
                    .c4 => {
                        const capacity = try c4_capacity.compute(.{
                            .leaf_carbon_g_c = canopy.node_leaf_carbon_g[node],
                            .leaf_protein_surface_density_g_per_m2 = leaf_protein_g_per_m2,
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
                        canopy.node_co2_unlimited_carboxylation_umol_per_m2_s[node] = capacity.co2_unlimited_carboxylation_umol_per_m2_s;
                        canopy.node_co2_limited_carboxylation_umol_per_m2_s[node] = capacity.co2_limited_carboxylation_umol_per_m2_s;
                        canopy.node_co2_compensation_umol_per_l[node] = context.c4_carbon_parameters.co2_compensation_umol_per_l;
                        canopy.node_co2_solubility_umol_per_l_per_umol_per_mol[node] = gas.co2_solubility_umol_per_l_per_umol_per_mol;
                        canopy.node_carboxylation_half_saturation_umol_per_l[node] = parameters.pep_co2_half_saturation_umol_per_l;
                        canopy.node_light_saturated_electron_transport_umol_per_m2_s[node] = capacity.light_saturated_electron_transport_umol_per_m2_s;
                        canopy.node_carboxylation_umol_co2_per_umol_electron[node] = capacity.carboxylation_umol_co2_per_umol_electron;
                        canopy.node_c4_feedback_fraction[node] = capacity.feedback_fraction;
                        canopy.node_pep_carboxylase_surface_density_g_per_m2[node] = capacity.pep_carboxylase_surface_density_g_per_m2;
                        canopy.node_mesophyll_chlorophyll_surface_density_g_per_m2[node] = capacity.chlorophyll_surface_density_g_per_m2;
                        const bundle_sheath_co2_umol_per_l = @max(0, context.c4_carbon_parameters.co2_concentration_umol_per_l_per_g_c_per_g_leaf_c * canopy.node_bundle_sheath_co2_carbon_g[node] / (canopy.node_leaf_carbon_g[node] * context.c4_carbon_parameters.bundle_sheath_water_g_per_g_c));
                        const bundle_capacity = try stomatal.c3Capacity(
                            leaf_protein_g_per_m2,
                            parameters.rubisco_leaf_protein_fraction,
                            parameters.c3_chlorophyll_leaf_protein_fraction,
                            parameters.rubisco_carboxylation_umol_per_g_protein_s,
                            parameters.rubisco_oxygenation_umol_per_g_protein_s,
                            parameters.chlorophyll_electron_transport_umol_per_g_protein_s,
                            gas,
                            bundle_sheath_co2_umol_per_l,
                        );
                        canopy.node_bundle_sheath_co2_limited_carboxylation_umol_per_m2_s[node] = bundle_capacity.co2_limited_carboxylation_umol_per_m2_s;
                        canopy.node_bundle_sheath_light_saturated_electron_transport_umol_per_m2_s[node] = bundle_capacity.light_saturated_electron_transport_umol_per_m2_s;
                        canopy.node_bundle_sheath_carboxylation_umol_co2_per_umol_electron[node] = bundle_capacity.carboxylation_umol_co2_per_umol_electron;
                    },
                }
            }
        }
        // UPTAKE 1225--1228 invokes the final STOMATE capacity pass before
        // CHILL/HEAT advance at 1591--1609. GROSUB then consumes those
        // already-published capacities. Advance the stress memories only
        // after this plant's capacity arrays have used their entry values;
        // otherwise current-hour heat would be applied one hour early.
        canopy.plant_chilling_stress_h[plant] = if (canopy_temperature_c < context.dormancy_parameters_by_plant[plant].chilling_temperature_c)
            @min(context.stress_parameters.maximum_chilling_h, canopy.plant_chilling_stress_h[plant] + context.timestep_h)
        else
            @max(0, canopy.plant_chilling_stress_h[plant] - context.timestep_h);
        canopy.plant_heat_stress_h[plant] = if (canopy_temperature_c > context.stress_parameters.heat_accumulation_threshold_c)
            canopy.plant_heat_stress_h[plant] + (canopy_temperature_c - context.stress_parameters.heat_accumulation_threshold_c) * context.timestep_h
        else
            @max(0, canopy.plant_heat_stress_h[plant] - context.stress_parameters.heat_recovery_per_h * context.timestep_h);
    };
}

test "node carboxylation admission follows GROSUB ARLF against population-scaled ZEROP" {
    // grosub.f:957--958 opens the per-node carboxylation block only when
    //   ARLF(K,NB,NZ,NY,NX) .GT. ZEROP(NZ,NY,NX)
    // and grosub.f:10914 / startq.f:886 define
    //   ZEROP(NZ,NY,NX) = ZERO * PP(NZ,NY,NX),
    // i.e. the threshold is population scaled. stomate.f:209--210 applies the
    // same node test (with the additional WGLF term) before publishing VCGRO /
    // VCGR4, and stomate.f:626--627 / :634--636 zero both capacities on the
    // else branch, so a node failing the area test carries zero capacity into
    // grosub. carboxylation.zig then requires
    //   node_co2_unlimited_carboxylation_umol_per_m2_s[node] > 0
    // before any beam contributes. The GROSUB mask is therefore reproduced
    // here rather than evaluated separately.
    var canopy = try Canopy.init(std.testing.allocator, 1, 1, &.{1}, &.{2}, &.{ 0, 0 });
    defer canopy.deinit();
    @memset(canopy.plant_intercellular_oxygen_umol_per_mol, 210_000);
    canopy.plant_population_count[0] = 40;
    const zero_area = 0.001;
    const zerop = zero_area * canopy.plant_population_count[0];
    // Node 0 sits strictly above ZEROP; node 1 sits exactly at it, which the
    // source .GT. comparison rejects.
    canopy.node_leaf_area_m2[0] = zerop * 1.5;
    canopy.node_leaf_area_m2[1] = zerop;
    for (0..2) |node| {
        canopy.node_leaf_protein_g[node] = 1;
        canopy.node_leaf_carbon_g[node] = 1000;
    }
    const parameters: Parameters = .{
        .pathway = .c4,
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
    };
    var temperatures = [_]f64{298.15};
    var dormancy = try Dormancy.RuntimeState.init(std.testing.allocator, 1);
    defer dormancy.deinit();
    var development = try BranchDevelopment.init(std.testing.allocator, 1);
    defer development.deinit();
    var growth_stages = try GrowthStages.init(std.testing.allocator, &.{1});
    defer growth_stages.deinit();
    const dormancy_parameter: Dormancy.Parameters = .{ .required_leafout_h = 2, .required_leafoff_h = 2, .leafout_temperature_threshold_c = 5, .leafoff_temperature_threshold_c = 0, .chilling_temperature_c = -5, .drought_leafout_total_water_potential_megapascal = -0.1, .combined_leafout_turgor_potential_megapascal = 0.1, .leafoff_total_water_potential_megapascal = -1.5, .drought_leafoff_total_water_potential_megapascal = -2.0, .maximum_photoperiod_counter_h = 3600, .evergreen_leafoff_remobilization_start_fraction = 0.75, .deciduous_leafoff_remobilization_start_fraction = 0.5, .full_senescence_duration_h = 480 };
    const dormancy_parameters = [_]Dormancy.Parameters{dormancy_parameter};
    var context: ApplyContext = .{
        .canopy = &canopy,
        .parameters_by_plant = &.{parameters},
        .c4_carbon_parameters = @import("photosynthesis.zig").sourceC4CarbonParameters(),
        .canopy_temperature_k_by_plant = &temperatures,
        .atmospheric_co2_umol_per_mol_by_cell = &.{420},
        .dormancy = &dormancy,
        .branch_development = &development,
        .growth_stages = &growth_stages,
        .dormancy_parameters_by_plant = &dormancy_parameters,
        .stress_parameters = compatibilityStressParameters(),
        .annual_termination_hours_without_grain_fill = 336,
        .presence_threshold_g_per_plant = zero_area,
        .timestep_h = 1,
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(canopy.node_co2_unlimited_carboxylation_umol_per_m2_s[0] > 0);
    try std.testing.expectEqual(@as(f64, 0), canopy.node_co2_unlimited_carboxylation_umol_per_m2_s[1]);
    // The threshold is population scaled, not a bare per-plant constant: with a
    // single plant the same absolute area now clears the test, so the admitted
    // set must change even though no leaf area moved.
    canopy.plant_population_count[0] = 1;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(canopy.node_co2_unlimited_carboxylation_umol_per_m2_s[1] > 0);
    // Falsifiability: the mask is not uniformly permissive. Driving one node's
    // area to zero must retract exactly that node.
    canopy.node_leaf_area_m2[0] = 0;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 0), canopy.node_co2_unlimited_carboxylation_umol_per_m2_s[0]);
    try std.testing.expect(canopy.node_co2_unlimited_carboxylation_umol_per_m2_s[1] > 0);
}

test "runtime C3 and C4 plants publish independent node capacities" {
    var canopy = try Canopy.init(std.testing.allocator, 1, 2, &.{ 1, 1 }, &.{ 1, 1 }, &.{ 0, 0 });
    defer canopy.deinit();
    @memset(canopy.plant_intercellular_oxygen_umol_per_mol, 210_000);
    canopy.node_leaf_area_m2[0] = 0.2;
    canopy.node_leaf_area_m2[1] = 0.25;
    canopy.node_leaf_protein_g[0] = 1;
    canopy.node_leaf_protein_g[1] = 1;
    canopy.node_leaf_carbon_g[0] = 10;
    canopy.node_leaf_carbon_g[1] = 10;
    const common: Parameters = .{
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
    };
    var c4 = common;
    c4.pathway = .c4;
    var temperatures = [_]f64{ 298.15, 298.15 };
    var dormancy = try Dormancy.RuntimeState.init(std.testing.allocator, 2);
    defer dormancy.deinit();
    var development = try BranchDevelopment.init(std.testing.allocator, 2);
    defer development.deinit();
    var growth_stages = try GrowthStages.init(std.testing.allocator, &.{ 1, 1 });
    defer growth_stages.deinit();
    development.hours_without_grain_fill[1] = 168;
    const dormancy_parameter: Dormancy.Parameters = .{ .required_leafout_h = 2, .required_leafoff_h = 2, .leafout_temperature_threshold_c = 5, .leafoff_temperature_threshold_c = 0, .chilling_temperature_c = -5, .drought_leafout_total_water_potential_megapascal = -0.1, .combined_leafout_turgor_potential_megapascal = 0.1, .leafoff_total_water_potential_megapascal = -1.5, .drought_leafoff_total_water_potential_megapascal = -2.0, .maximum_photoperiod_counter_h = 3600, .evergreen_leafoff_remobilization_start_fraction = 0.75, .deciduous_leafoff_remobilization_start_fraction = 0.5, .full_senescence_duration_h = 480 };
    const dormancy_parameters = [_]Dormancy.Parameters{ dormancy_parameter, dormancy_parameter };
    var context: ApplyContext = .{
        .canopy = &canopy,
        .parameters_by_plant = &.{ common, c4 },
        .c4_carbon_parameters = @import("photosynthesis.zig").sourceC4CarbonParameters(),
        .canopy_temperature_k_by_plant = &temperatures,
        .atmospheric_co2_umol_per_mol_by_cell = &.{420},
        .dormancy = &dormancy,
        .branch_development = &development,
        .growth_stages = &growth_stages,
        .dormancy_parameters_by_plant = &dormancy_parameters,
        .stress_parameters = compatibilityStressParameters(),
        .annual_termination_hours_without_grain_fill = 336,
        .presence_threshold_g_per_plant = 1.0e-12,
        .timestep_h = 1,
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const rt = 8.3143 * 298.15;
    const st = 710.0 * 298.15;
    const expected_tfn3 = @exp(25.229 - 62500.0 / rt) / (1 + @exp((197500.0 - st) / rt) + @exp((st - 222500.0) / rt));
    try std.testing.expectApproxEqAbs(expected_tfn3, canopy.plant_uptake_growth_temperature_response[0], 1.0e-14);
    try std.testing.expect(canopy.node_co2_limited_carboxylation_umol_per_m2_s[0] > 0);
    try std.testing.expect(canopy.node_co2_limited_carboxylation_umol_per_m2_s[1] > 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0), canopy.plant_heat_stress_h[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1), canopy.branch_c3_feedback_fraction[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), canopy.branch_c4_feedback_fraction[1], 1e-14);
    temperatures[0] = 267.15;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 1), canopy.plant_chilling_stress_h[0]);
    temperatures[0] = 298.15;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 0), canopy.plant_chilling_stress_h[0]);

    // UPTAKE advances HEAT only after final STOMATE. The first hot hour must
    // therefore publish capacity with entry HEAT=0, then store HEAT=1 for the
    // following hour; only the second call sees that feedback.
    temperatures[0] = 334.15;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 1), canopy.branch_c3_feedback_fraction[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1), canopy.plant_heat_stress_h[0], 1e-14);
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), canopy.branch_c3_feedback_fraction[0], 1e-14);
    canopy.plant_heat_stress_h[0] = 0;
    temperatures[0] = 298.15;

    canopy.node_co2_limited_carboxylation_umol_per_m2_s[0] = 77;
    growth_stages.branches[0].dead = true;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(
        @as(f64, 77),
        canopy.node_co2_limited_carboxylation_umol_per_m2_s[0],
    );

    growth_stages.branches[0].dead = false;
    context.presence_threshold_g_per_plant = 2;
    canopy.plant_population_count[0] = 1;
    canopy.node_leaf_carbon_g[0] = 2;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(
        @as(f64, 0),
        canopy.node_co2_limited_carboxylation_umol_per_m2_s[0],
    );
}
