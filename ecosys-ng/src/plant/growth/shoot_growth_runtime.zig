const std = @import("std");

const CellRange = @import("../../core/compute.zig").CellRange;

const canopy_module = @import("../../canopy/photosynthesis/photosynthesis.zig");

const branch_reserve_equilibration = @import("branch_reserve_equilibration.zig");

const coefficient_basis_module = @import("shoot_growth_coefficient_basis.zig");

const execution_calendar_date = @import("../../driver/execution_calendar_date.zig");

const stages_module = @import("../lifecycle/growth_stages.zig");

const dormancy_module = @import("../lifecycle/dormancy.zig");

const development_module = @import("../lifecycle/phenology.zig");

const partition_module = @import("../partition/organ.zig");

const metabolism_module = @import("shoot_growth_metabolism.zig");

const traits_module = @import("../../state/plant_traits.zig");

const litter_partition_module = @import("../partition/litter.zig");

const symbiosis_module = @import("../../canopy/symbiosis/plant_symbiotic_fixation.zig");

const soil_exchange_module = @import("../exchange/soil.zig");

const gas_transport_module = @import("../../soil/gas/transport.zig");
const surface_gas_parameters_module = @import("../../surface/gas_parameters.zig");

const root_system_module = @import("../root/plant_root_system.zig");

const root_uptake_module = @import("../root/plant_root_nutrient_uptake.zig");

const growth_temperature_module = @import("../response/growth_temperature.zig");

const stalk_growing_node_window = @import("stalk_growing_node_window.zig");

const storage_carbon_branch_survival = @import("storage_carbon_branch_survival.zig");

const main_stalk_death_propagation = @import("main_stalk_death_propagation.zig");

const leaf_structural_nutrient_recycling = @import("../../canopy/leaf/structural_nutrient_recycling.zig");
const shoot_recycling_fraction = @import("shoot_recycling_fraction.zig");

const seasonal_growth_flag_reset = @import("seasonal_growth_flag_reset.zig");

const end_of_season_reproductive_turnover = @import("end_of_season_reproductive_turnover.zig");

const seasonal_stalk_standing_dead_turnover = @import("seasonal_stalk_standing_dead_turnover.zig");

const CarbonExchange = @import("../../canopy/photosynthesis/carbon_exchange.zig").State;
const InternalRootShootActivity = @import("../accounting/internal_root_shoot_activity.zig");

pub const PlantParameters = struct {
    photosynthesis_pathway: u8,
    growth_habit: u8,
    leaf_phenology_type: u8 = 0,
    determinacy_type: u8,
    turnover_type: u8,
    root_profile_type: u8,
    nitrogen_fixation_type: u8,
    internode_extension_enabled: bool,
    stomatal_turgor_shape_per_megapascal: f64,
    specific_leaf_area_m2_per_g_c: f64,
    specific_sheath_length_m_per_g_c: f64,
    specific_internode_length_m_per_g_c: f64,
    sheath_vertical_projection_fraction: f64,
    stalk_vertical_projection_fraction: f64,
    maximum_individual_seed_carbon_g: f64,
    grain_fill_g_c_per_seed_h_25c: f64,
    symbiont_growth_yield_g_c_per_g_c: f64,
    symbiont_nitrogen_to_carbon_g_n_per_g_c: f64,
    symbiont_phosphorus_to_carbon_g_p_per_g_c: f64,
    growth_yield_g_c_per_g_c: [partition_module.organ_count]f64,
    nitrogen_to_carbon_g_n_per_g_c: [partition_module.organ_count]f64,
    phosphorus_to_carbon_g_p_per_g_c: [partition_module.organ_count]f64,
    root_growth_yield_g_c_per_g_c: f64,
    root_nitrogen_to_carbon_g_n_per_g_c: f64,
    root_phosphorus_to_carbon_g_p_per_g_c: f64,
};

pub fn parametersFromTraits(traits: traits_module.PlantTraits) PlantParameters {
    const yield = traits.organ_growth_yield_g_c_per_g_c;
    const nitrogen = traits.organ_nitrogen_to_carbon_ratio;
    const phosphorus = traits.organ_phosphorus_to_carbon_ratio;
    return .{
        .photosynthesis_pathway = traits.functional_type.photosynthesis_pathway,
        .growth_habit = traits.functional_type.growth_habit,
        .leaf_phenology_type = traits.functional_type.leaf_phenology_type,
        .determinacy_type = traits.functional_type.determinacy_type,
        .turnover_type = traits.functional_type.aboveground_turnover_type,
        .root_profile_type = traits.functional_type.root_profile_type,
        .nitrogen_fixation_type = traits.functional_type.nitrogen_fixation_type,
        .internode_extension_enabled = traits.morphology.specific_internode_length_m_per_g_c > 0,
        .stomatal_turgor_shape_per_megapascal = traits.water_relations.stomatal_turgor_shape,
        .specific_leaf_area_m2_per_g_c = traits.morphology.specific_leaf_area_m2_per_g_c,
        .specific_sheath_length_m_per_g_c = traits.morphology.specific_petiole_length_m_per_g_c,
        .specific_internode_length_m_per_g_c = traits.morphology.specific_internode_length_m_per_g_c,
        .sheath_vertical_projection_fraction = @sin(traits.morphology.petiole_angle_degrees * std.math.pi / 180),
        .stalk_vertical_projection_fraction = @sin(traits.morphology.stem_angle_degrees * std.math.pi / 180),
        .maximum_individual_seed_carbon_g = traits.morphology.maximum_seed_mass_g,
        .grain_fill_g_c_per_seed_h_25c = traits.morphology.grain_filling_g_per_seed_h,
        .symbiont_growth_yield_g_c_per_g_c = yield.symbiont,
        .symbiont_nitrogen_to_carbon_g_n_per_g_c = nitrogen.symbiont,
        .symbiont_phosphorus_to_carbon_g_p_per_g_c = phosphorus.symbiont,
        .growth_yield_g_c_per_g_c = .{ yield.leaf, yield.petiole, yield.stalk, yield.stalk_reserve, yield.husk, yield.ear, yield.grain },
        .nitrogen_to_carbon_g_n_per_g_c = .{ nitrogen.leaf, nitrogen.petiole, nitrogen.stalk, nitrogen.stalk_reserve, nitrogen.husk, nitrogen.ear, nitrogen.grain },
        .phosphorus_to_carbon_g_p_per_g_c = .{ phosphorus.leaf, phosphorus.petiole, phosphorus.stalk, phosphorus.stalk_reserve, phosphorus.husk, phosphorus.ear, phosphorus.grain },
        .root_growth_yield_g_c_per_g_c = yield.root,
        .root_nitrogen_to_carbon_g_n_per_g_c = nitrogen.root,
        .root_phosphorus_to_carbon_g_p_per_g_c = phosphorus.root,
    };
}

pub fn inactivePlantParameters() PlantParameters {
    return .{
        .photosynthesis_pathway = 3,
        .growth_habit = 0,
        .determinacy_type = 0,
        .turnover_type = 0,
        .root_profile_type = 0,
        .nitrogen_fixation_type = 0,
        .internode_extension_enabled = false,
        .stomatal_turgor_shape_per_megapascal = 0,
        .specific_leaf_area_m2_per_g_c = 0,
        .specific_sheath_length_m_per_g_c = 0,
        .specific_internode_length_m_per_g_c = 0,
        .sheath_vertical_projection_fraction = 0,
        .stalk_vertical_projection_fraction = 0,
        .maximum_individual_seed_carbon_g = 0,
        .grain_fill_g_c_per_seed_h_25c = 0,
        .symbiont_growth_yield_g_c_per_g_c = 0.4,
        .symbiont_nitrogen_to_carbon_g_n_per_g_c = 0.1,
        .symbiont_phosphorus_to_carbon_g_p_per_g_c = 0.02,
        .growth_yield_g_c_per_g_c = @splat(0.5),
        .nitrogen_to_carbon_g_n_per_g_c = @splat(0),
        .phosphorus_to_carbon_g_p_per_g_c = @splat(0),
        .root_growth_yield_g_c_per_g_c = 0.5,
        .root_nitrogen_to_carbon_g_n_per_g_c = 0,
        .root_phosphorus_to_carbon_g_p_per_g_c = 0,
    };
}

pub const OrganCoefficientBasis = struct {
    growth_yield_g_c_per_g_c: [partition_module.organ_count]f64,
    nitrogen_to_carbon_g_n_per_g_c: [partition_module.organ_count]f64,
    phosphorus_to_carbon_g_p_per_g_c: [partition_module.organ_count]f64,
};

/// GROSUB 868--882. Before emergence both prospective shoot organs take the
/// root coefficient basis (DMLFB=DMSHB=DMRT, CNLFB=CNSHB=CNRTW,
/// CPLFB=CPSHB=CPRTW); after emergence each keeps its own PFT coefficient.
/// The remaining five organ slots are untouched in both cases, exactly as the
/// source weighted sum at 883--900 reads them.
pub fn organCoefficientBasis(
    parameters: PlantParameters,
    growth_nutrient_ratios: metabolism_module.GrowthNutrientRatios,
    emerged: bool,
) !OrganCoefficientBasis {
    const selected = try coefficient_basis_module.select(.{
        .emergence = if (emerged) .emerged else .pre_emergence,
        .leaf_growth_yield_g_c_per_g_c = parameters.growth_yield_g_c_per_g_c[0],
        .petiole_growth_yield_g_c_per_g_c = parameters.growth_yield_g_c_per_g_c[1],
        .leaf_nitrogen_to_carbon_g_n_per_g_c = growth_nutrient_ratios.nitrogen_to_carbon_g_n_per_g_c[0],
        .petiole_nitrogen_to_carbon_g_n_per_g_c = growth_nutrient_ratios.nitrogen_to_carbon_g_n_per_g_c[1],
        .leaf_phosphorus_to_carbon_g_p_per_g_c = growth_nutrient_ratios.phosphorus_to_carbon_g_p_per_g_c[0],
        .petiole_phosphorus_to_carbon_g_p_per_g_c = growth_nutrient_ratios.phosphorus_to_carbon_g_p_per_g_c[1],
        .root_growth_yield_g_c_per_g_c = parameters.root_growth_yield_g_c_per_g_c,
        .root_nitrogen_to_carbon_g_n_per_g_c = parameters.root_nitrogen_to_carbon_g_n_per_g_c,
        .root_phosphorus_to_carbon_g_p_per_g_c = parameters.root_phosphorus_to_carbon_g_p_per_g_c,
    });
    var result: OrganCoefficientBasis = .{
        .growth_yield_g_c_per_g_c = parameters.growth_yield_g_c_per_g_c,
        .nitrogen_to_carbon_g_n_per_g_c = growth_nutrient_ratios.nitrogen_to_carbon_g_n_per_g_c,
        .phosphorus_to_carbon_g_p_per_g_c = growth_nutrient_ratios.phosphorus_to_carbon_g_p_per_g_c,
    };
    result.growth_yield_g_c_per_g_c[0] = selected.leaf_growth_yield_g_c_per_g_c;
    result.growth_yield_g_c_per_g_c[1] = selected.petiole_growth_yield_g_c_per_g_c;
    result.nitrogen_to_carbon_g_n_per_g_c[0] = selected.leaf_nitrogen_to_carbon_g_n_per_g_c;
    result.nitrogen_to_carbon_g_n_per_g_c[1] = selected.petiole_nitrogen_to_carbon_g_n_per_g_c;
    result.phosphorus_to_carbon_g_p_per_g_c[0] = selected.leaf_phosphorus_to_carbon_g_p_per_g_c;
    result.phosphorus_to_carbon_g_p_per_g_c[1] = selected.petiole_phosphorus_to_carbon_g_p_per_g_c;
    return result;
}

test "GROSUB 868--882 pre-emergence branches use the root coefficient basis" {
    var parameters = inactivePlantParameters();
    parameters.growth_yield_g_c_per_g_c = .{ 0.81, 0.72, 0.7, 0.7, 0.7, 0.7, 0.7 };
    parameters.nitrogen_to_carbon_g_n_per_g_c = .{ 0.041, 0.022, 0.005, 0.005, 0.005, 0.005, 0.005 };
    parameters.phosphorus_to_carbon_g_p_per_g_c = .{ 0.0041, 0.0022, 0.0005, 0.0005, 0.0005, 0.0005, 0.0005 };
    parameters.root_growth_yield_g_c_per_g_c = 0.63;
    parameters.root_nitrogen_to_carbon_g_n_per_g_c = 0.031;
    parameters.root_phosphorus_to_carbon_g_p_per_g_c = 0.0031;
    const ratios = try metabolism_module.growthNutrientRatios(
        parameters.nitrogen_to_carbon_g_n_per_g_c,
        parameters.phosphorus_to_carbon_g_p_per_g_c,
    );

    const after = try organCoefficientBasis(parameters, ratios, true);
    try std.testing.expectEqual(@as(f64, 0.81), after.growth_yield_g_c_per_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0.72), after.growth_yield_g_c_per_g_c[1]);
    try std.testing.expectEqual(@as(f64, 0.041), after.nitrogen_to_carbon_g_n_per_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0.0022), after.phosphorus_to_carbon_g_p_per_g_c[1]);

    const before = try organCoefficientBasis(parameters, ratios, false);
    try std.testing.expectEqual(@as(f64, 0.63), before.growth_yield_g_c_per_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0.63), before.growth_yield_g_c_per_g_c[1]);
    try std.testing.expectEqual(@as(f64, 0.031), before.nitrogen_to_carbon_g_n_per_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0.031), before.nitrogen_to_carbon_g_n_per_g_c[1]);
    try std.testing.expectEqual(@as(f64, 0.0031), before.phosphorus_to_carbon_g_p_per_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0.0031), before.phosphorus_to_carbon_g_p_per_g_c[1]);
    // The remaining five organ slots are identical either way.
    for (2..partition_module.organ_count) |organ| {
        try std.testing.expectEqual(after.growth_yield_g_c_per_g_c[organ], before.growth_yield_g_c_per_g_c[organ]);
        try std.testing.expectEqual(after.nitrogen_to_carbon_g_n_per_g_c[organ], before.nitrogen_to_carbon_g_n_per_g_c[organ]);
    }

    // Non-vacuity: pre-emergence shoot coefficients must track the root
    // parameters. Before this binding they were the leaf and petiole values
    // and moving the root basis changed nothing.
    var perturbed = parameters;
    perturbed.root_growth_yield_g_c_per_g_c = 0.3;
    const moved = try organCoefficientBasis(perturbed, ratios, false);
    try std.testing.expectEqual(@as(f64, 0.3), moved.growth_yield_g_c_per_g_c[0]);
    try std.testing.expect(moved.growth_yield_g_c_per_g_c[0] != before.growth_yield_g_c_per_g_c[0]);
    // The emerged path is untouched by the root parameters.
    const unmoved = try organCoefficientBasis(perturbed, ratios, true);
    try std.testing.expectEqual(after.growth_yield_g_c_per_g_c[0], unmoved.growth_yield_g_c_per_g_c[0]);
}

pub const NodeGrowthParameters = struct {
    protein_per_nitrogen_g_protein_per_g_n: f64,
    protein_per_phosphorus_g_protein_per_g_p: f64,
    leaf_mass_exponent: f64,
    sheath_mass_exponent: f64,
    internode_mass_exponent: f64,
    minimum_leaf_carbon_g_c_per_m2_cell: f64,
    minimum_sheath_carbon_g_c_per_m2_cell: f64,
    minimum_internode_carbon_g_c_per_m2_cell: f64,
    leaf_nutrient_exchange_fraction: f64,
    branch_reserve_carbon_exchange_fraction_per_h: f64,
    branch_reserve_nutrient_exchange_fraction_per_h: f64,
    minimum_grain_nutrient_fraction: f64,
    reserve_nitrogen_half_saturation_g_n_per_g_c: f64,
    reserve_phosphorus_half_saturation_g_p_per_g_c: f64,
    physiological_maturity_no_fill_h: f64,
    maximum_previous_stalk_nodes_in_rolling_window: usize,
    annual_leafoff_delay_h_by_phenology: [4]f64,
    leaf_storage_exchange_fraction_per_h_by_turnover: [6]f64,

    pub fn validate(self: NodeGrowthParameters) !void {
        inline for (@typeInfo(NodeGrowthParameters).@"struct".fields) |field| {
            if (field.type == f64) {
                if (!std.math.isFinite(@field(self, field.name))) return error.NonFiniteShootNodeGrowthParameter;
            }
        }
        for (self.leaf_storage_exchange_fraction_per_h_by_turnover) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidShootNodeGrowthParameter;
        for (self.annual_leafoff_delay_h_by_phenology) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidShootNodeGrowthParameter;
        if (self.protein_per_nitrogen_g_protein_per_g_n < 0 or self.protein_per_phosphorus_g_protein_per_g_p < 0 or self.minimum_leaf_carbon_g_c_per_m2_cell < 0 or self.minimum_sheath_carbon_g_c_per_m2_cell < 0 or self.minimum_internode_carbon_g_c_per_m2_cell < 0 or self.leaf_nutrient_exchange_fraction < 0 or self.branch_reserve_carbon_exchange_fraction_per_h < 0 or self.branch_reserve_nutrient_exchange_fraction_per_h < 0 or self.minimum_grain_nutrient_fraction < 0 or self.minimum_grain_nutrient_fraction > 1 or self.reserve_nitrogen_half_saturation_g_n_per_g_c < 0 or self.reserve_phosphorus_half_saturation_g_p_per_g_c < 0 or self.physiological_maturity_no_fill_h <= 0) return error.InvalidShootNodeGrowthParameter;
    }
};

pub fn sourceNodeGrowthParameters() NodeGrowthParameters {
    return .{
        .protein_per_nitrogen_g_protein_per_g_n = 2.5,
        .protein_per_phosphorus_g_protein_per_g_p = 25,
        .leaf_mass_exponent = -0.333,
        .sheath_mass_exponent = -0.50,
        .internode_mass_exponent = -0.667,
        .minimum_leaf_carbon_g_c_per_m2_cell = 0.002,
        .minimum_sheath_carbon_g_c_per_m2_cell = 2,
        .minimum_internode_carbon_g_c_per_m2_cell = 2,
        .leaf_nutrient_exchange_fraction = 1.0e-3,
        .branch_reserve_carbon_exchange_fraction_per_h = 5.0e-3,
        .branch_reserve_nutrient_exchange_fraction_per_h = 5.0e-2,
        .minimum_grain_nutrient_fraction = 0.75,
        .reserve_nitrogen_half_saturation_g_n_per_g_c = 0.005,
        .reserve_phosphorus_half_saturation_g_p_per_g_c = 0.001,
        .physiological_maturity_no_fill_h = 72,
        .maximum_previous_stalk_nodes_in_rolling_window = 23,
        .annual_leafoff_delay_h_by_phenology = .{ 360, 1440, 720, 720 },
        .leaf_storage_exchange_fraction_per_h_by_turnover = .{ 5.0e-3, 5.0e-3, 5.0e-6, 5.0e-6, 5.0e-5, 5.0e-4 },
    };
}

pub const BranchMobileExchangeParameters = struct {
    carbon_exchange_fraction_per_h: f64,
    nutrient_exchange_fraction_per_h: f64,
    remobilization_redistribution_fraction_per_h: f64,

    pub fn validate(self: BranchMobileExchangeParameters) !void {
        inline for (@typeInfo(BranchMobileExchangeParameters).@"struct".fields) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value)) return error.NonFiniteBranchMobileExchangeParameter;
            if (value < 0 or value > 1) return error.InvalidBranchMobileExchangeParameter;
        }
    }
};

pub fn sourceBranchMobileExchangeParameters() BranchMobileExchangeParameters {
    return .{ .carbon_exchange_fraction_per_h = 0.01, .nutrient_exchange_fraction_per_h = 0.01, .remobilization_redistribution_fraction_per_h = 0.05 };
}

pub const shoot_recycling_profile_count = 6;

pub const SenescenceRecyclingParameters = struct {
    minimum_carbon_fraction_by_root_profile: [shoot_recycling_profile_count]f64,
    responsive_carbon_fraction_by_root_profile: [shoot_recycling_profile_count]f64,
    maximum_nitrogen_fraction_by_root_profile: [shoot_recycling_profile_count]f64,
    maximum_phosphorus_fraction_by_root_profile: [shoot_recycling_profile_count]f64,

    pub fn coefficients(self: *const SenescenceRecyclingParameters) shoot_recycling_fraction.ProfileCoefficients {
        return .{
            .minimum_carbon_fraction = &self.minimum_carbon_fraction_by_root_profile,
            .responsive_carbon_fraction = &self.responsive_carbon_fraction_by_root_profile,
            .maximum_nitrogen_fraction = &self.maximum_nitrogen_fraction_by_root_profile,
            .maximum_phosphorus_fraction = &self.maximum_phosphorus_fraction_by_root_profile,
        };
    }

    pub fn validate(self: *const SenescenceRecyclingParameters) !void {
        // The source table is indexed by IGTYP=0:5. Delegate value and
        // cross-field validation to the equation owner for every profile.
        _ = try shoot_recycling_fraction.calculate(
            false,
            0,
            .{
                .mobile_carbon_g_c_per_g_c = 0,
                .mobile_nitrogen_g_n_per_g_c = 0,
                .mobile_phosphorus_g_p_per_g_c = 0,
            },
            .{ .nitrogen_g_n_per_g_c = 1, .phosphorus_g_p_per_g_c = 1 },
            self.coefficients(),
        );
    }
};

/// GROSUB DATA RCCZ/RCCY/RCCX/RCCQ, indexed by IGTYP=0:5.
pub fn sourceSenescenceRecyclingParameters() SenescenceRecyclingParameters {
    return .{
        .minimum_carbon_fraction_by_root_profile = .{0.167} ** shoot_recycling_profile_count,
        .responsive_carbon_fraction_by_root_profile = .{0.333} ** shoot_recycling_profile_count,
        .maximum_nitrogen_fraction_by_root_profile = .{0.667} ** shoot_recycling_profile_count,
        .maximum_phosphorus_fraction_by_root_profile = .{0.667} ** shoot_recycling_profile_count,
    };
}

/// Production adapter for GROSUB 2509--2529. The authoritative IGTYP is the
/// reconstructed per-plant `PlantParameters.root_profile_type`; inputs are the
/// HFUNC branch concentrations, never the dimensional mobile pool masses.
pub fn senescenceRecyclingFractionsForPlant(
    emerged: bool,
    parameters: PlantParameters,
    concentrations: shoot_recycling_fraction.Concentrations,
    inhibition: shoot_recycling_fraction.Inhibition,
    coefficients: *const SenescenceRecyclingParameters,
) !canopy_module.RecyclingFractions {
    const result = try shoot_recycling_fraction.calculate(
        emerged,
        parameters.root_profile_type,
        concentrations,
        inhibition,
        coefficients.coefficients(),
    );
    return .{
        .carbon = result.carbon,
        .nitrogen = result.nitrogen,
        .phosphorus = result.phosphorus,
    };
}

test "GROSUB shoot recycling binds unequal profiles through authoritative plant IGTYP" {
    var coefficients = sourceSenescenceRecyclingParameters();
    coefficients.minimum_carbon_fraction_by_root_profile[0] = 0.10;
    coefficients.responsive_carbon_fraction_by_root_profile[0] = 0.20;
    coefficients.maximum_nitrogen_fraction_by_root_profile[0] = 0.30;
    coefficients.maximum_phosphorus_fraction_by_root_profile[0] = 0.40;
    coefficients.minimum_carbon_fraction_by_root_profile[2] = 0.35;
    coefficients.responsive_carbon_fraction_by_root_profile[2] = 0.45;
    coefficients.maximum_nitrogen_fraction_by_root_profile[2] = 0.75;
    coefficients.maximum_phosphorus_fraction_by_root_profile[2] = 0.85;

    const concentrations: shoot_recycling_fraction.Concentrations = .{
        .mobile_carbon_g_c_per_g_c = 0.20,
        .mobile_nitrogen_g_n_per_g_c = 0.02,
        .mobile_phosphorus_g_p_per_g_c = 0.002,
    };
    const inhibition: shoot_recycling_fraction.Inhibition = .{
        .nitrogen_g_n_per_g_c = 0.025,
        .phosphorus_g_p_per_g_c = 0.0025,
    };
    var shallow = inactivePlantParameters();
    shallow.root_profile_type = 0;
    var deep = shallow;
    deep.root_profile_type = 2;

    const shallow_result = try senescenceRecyclingFractionsForPlant(
        true,
        shallow,
        concentrations,
        inhibition,
        &coefficients,
    );
    const deep_result = try senescenceRecyclingFractionsForPlant(
        true,
        deep,
        concentrations,
        inhibition,
        &coefficients,
    );
    const carbon_constraint = @min(
        concentrations.mobile_nitrogen_g_n_per_g_c /
            (concentrations.mobile_nitrogen_g_n_per_g_c + concentrations.mobile_carbon_g_c_per_g_c * inhibition.nitrogen_g_n_per_g_c),
        concentrations.mobile_phosphorus_g_p_per_g_c /
            (concentrations.mobile_phosphorus_g_p_per_g_c + concentrations.mobile_carbon_g_c_per_g_c * inhibition.phosphorus_g_p_per_g_c),
    );
    const nitrogen_constraint = concentrations.mobile_carbon_g_c_per_g_c /
        (concentrations.mobile_carbon_g_c_per_g_c + concentrations.mobile_nitrogen_g_n_per_g_c / inhibition.nitrogen_g_n_per_g_c);
    const phosphorus_constraint = concentrations.mobile_carbon_g_c_per_g_c /
        (concentrations.mobile_carbon_g_c_per_g_c + concentrations.mobile_phosphorus_g_p_per_g_c / inhibition.phosphorus_g_p_per_g_c);

    try std.testing.expectApproxEqAbs(@as(f64, 0.10) + carbon_constraint * 0.20, shallow_result.carbon, 1.0e-15);
    try std.testing.expectApproxEqAbs(nitrogen_constraint * 0.30, shallow_result.nitrogen, 1.0e-15);
    try std.testing.expectApproxEqAbs(phosphorus_constraint * 0.40, shallow_result.phosphorus, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.35) + carbon_constraint * 0.45, deep_result.carbon, 1.0e-15);
    try std.testing.expectApproxEqAbs(nitrogen_constraint * 0.75, deep_result.nitrogen, 1.0e-15);
    try std.testing.expectApproxEqAbs(phosphorus_constraint * 0.85, deep_result.phosphorus, 1.0e-15);
    try std.testing.expect(shallow_result.carbon != deep_result.carbon);
    try std.testing.expect(shallow_result.nitrogen != deep_result.nitrogen);
    try std.testing.expect(shallow_result.phosphorus != deep_result.phosphorus);
}

pub const ApplyContext = struct {
    canopy: *canopy_module.State,
    growth_stages: *stages_module.State,
    dormancy: *dormancy_module.RuntimeState,
    development: *development_module.BranchDevelopmentState,
    plant_parameters: []const PlantParameters,
    active_by_plant: []const bool,
    emerged_by_plant: []const bool,
    leaf_appearance_rate_at_25c_per_h_by_plant: []const f64,
    sowing_depth_m_by_plant: []const f64,
    roots: *root_system_module.State,
    soil_temperature_k: []const f64,
    soil_layer_capacity: usize,
    root_growth_temperature_parameters: growth_temperature_module.Parameters,
    canopy_temperature_k_by_plant: []const f64,
    canopy_total_water_potential_mpa_by_plant: []const f64,
    total_aerodynamic_resistance_h_per_m_by_plant: []const f64,
    stomatal_resistance_h_per_m_by_plant: []const f64,
    plant_radiation_fraction: []const f64,
    /// Cell-major live atmospheric gas carrier. Canopy exchange selects the
    /// ammonia concentration belonging to the plant's mapped cell.
    atmospheric_concentration_g_per_m3: []const f64,
    ammonia_solubility_at_25_c: f64,
    canopy_ammonia_parameters: soil_exchange_module.CanopyAmmoniaExchangeParameters,
    partition_parameters: partition_module.Parameters,
    metabolism_parameters: metabolism_module.Parameters,
    phenology_parameters: development_module.Parameters,
    node_growth_parameters: NodeGrowthParameters,
    branch_mobile_exchange_parameters: BranchMobileExchangeParameters,
    storage_remobilization_duration_h_by_growth_habit: [2]f64,
    cell_area_m2: []const f64,
    stalk_volume_m3_per_g_c: f64,
    structural_presence_threshold_g_per_plant: f64,
    grain_fill_detection_threshold_g_per_plant: f64,
    day_of_year: u16,
    hour_of_day: u8,
    solar_noon_hour_by_cell: []const u8,
    execution_year: u16,
    timestep_h: f64,
    seasonal_litterfall_rate_per_h: f64,
    seasonal_litterfall_delay_threshold_h: f64,
    dormancy_parameters_by_plant: []const dormancy_module.Parameters,
    litter_partition: *const litter_partition_module.State,
    senescence_recycling: SenescenceRecyclingParameters,
    senescence_products_by_plant: []canopy_module.SenescenceProducts,
    /// True only when the source-order main-branch IFLGR transaction was
    /// admitted during this biological step. The orchestrator clears it
    /// before each call and consumes it for automatic self-seeding.
    seasonal_turnover_event_by_plant: ?[]bool = null,
    senescence_demand_tolerance_g_c: f64,
    leaf_area_presence_tolerance_m2: f64,
    symbiosis_parameters: symbiosis_module.RuntimeParameters,
    /// WTHR ICHKF by horizontal cell. This is the only external suppression
    /// flag in the GROSUB initial-infection gate.
    fire_active_this_hour: []const bool,
    /// Per-cell, per-external-hour WTNDI source additions. The vegetation
    /// finalizer atomically consumes this into cell and landscape ledgers.
    symbiotic_inoculum_input_by_cell: []symbiosis_module.Pool,
    carbon_exchange: ?*CarbonExchange = null,
    /// Exact accepted canopy-to-root-layer transfer for pre-emergence shoot
    /// respiration, whose CO2 owner is the planting-root layer.
    accepted_internal_activity: *InternalRootShootActivity.State,
};

const SeasonalTurnoverWorkspace = struct {
    internode_length_m: []f64,
    internode_mass: []seasonal_stalk_standing_dead_turnover.ElementMass,
};

fn state_updateExactSeasonalTurnover(
    context: *ApplyContext,
    plant: usize,
    branch: usize,
    parameters: PlantParameters,
    workspace: SeasonalTurnoverWorkspace,
) !bool {
    const canopy = context.canopy;
    const nodes = try canopy.nodeRange(branch);
    const node_count = nodes.end - nodes.first;
    if (workspace.internode_length_m.len < node_count or workspace.internode_mass.len < node_count)
        return error.SeasonalTurnoverWorkspaceTooSmall;
    var flag_state: seasonal_growth_flag_reset.BranchState = .{
        .accumulated_leafout_h = context.dormancy.branches[branch].accumulated_leafout_h,
        .accumulated_leafoff_h = context.dormancy.branches[branch].accumulated_leafoff_h,
        .leafout_disabled = context.dormancy.branches[branch].leafout_disabled,
        .leafoff_disabled = context.dormancy.branches[branch].leafoff_disabled,
        .reproductive_growth_disabled = context.dormancy.branches[branch].reproductive_growth_disabled,
        .reproductive_litterfall_delay_h = context.dormancy.branches[branch].reproductive_litterfall_delay_h,
        .leafout_initialization_disabled = !context.development.leafout_initialization_enabled[branch],
    };
    _ = try seasonal_growth_flag_reset.applyBranch(&flag_state, .{
        .required_leafout_h = context.dormancy_parameters_by_plant[plant].required_leafout_h,
        .required_leafoff_h = context.dormancy_parameters_by_plant[plant].required_leafoff_h,
        .growth_habit = if (parameters.growth_habit == 0) .annual else .perennial,
        .phenology = try stages_module.phenologyTypeFromReadq(parameters.leaf_phenology_type),
        .first_biological_iteration = true,
    });

    var husk: end_of_season_reproductive_turnover.ElementMass = .{ .carbon_g_c = canopy.branch_husk_carbon_g[branch], .nitrogen_g_n = canopy.branch_husk_nitrogen_g[branch], .phosphorus_g_p = canopy.branch_husk_phosphorus_g[branch] };
    var ear: end_of_season_reproductive_turnover.ElementMass = .{ .carbon_g_c = canopy.branch_ear_carbon_g[branch], .nitrogen_g_n = canopy.branch_ear_nitrogen_g[branch], .phosphorus_g_p = canopy.branch_ear_phosphorus_g[branch] };
    var grain: end_of_season_reproductive_turnover.ElementMass = .{ .carbon_g_c = canopy.branch_grain_carbon_g[branch], .nitrogen_g_n = canopy.branch_grain_nitrogen_g[branch], .phosphorus_g_p = canopy.branch_grain_phosphorus_g[branch] };
    var storage: end_of_season_reproductive_turnover.ElementMass = .{ .carbon_g_c = canopy.plant_seed_storage_carbon_g[plant], .nitrogen_g_n = canopy.plant_seed_storage_nitrogen_g[plant], .phosphorus_g_p = canopy.plant_seed_storage_phosphorus_g[plant] };
    var potential_sites = canopy.branch_potential_seed_site_count[branch];
    var seed_count = canopy.branch_seed_count[branch];
    var individual_seed_carbon = canopy.branch_individual_seed_carbon_g[branch];
    var products = context.senescence_products_by_plant[plant];
    const nonfoliar = try context.litter_partition.get(plant, .non_foliar);
    const admitted = try end_of_season_reproductive_turnover.apply(.{
        .reproductive_growth_disabled = &flag_state.reproductive_growth_disabled,
        .litterfall_delay_h = &flag_state.reproductive_litterfall_delay_h,
        .husk = &husk,
        .ear = &ear,
        .grain = &grain,
        .potential_seed_site_count = &potential_sites,
        .seed_count = &seed_count,
        .individual_seed_carbon_g_c = &individual_seed_carbon,
        .plant_seed_storage = &storage,
        .litter_carbon_g_c = &products.nonwoody_carbon_g,
        .litter_nitrogen_g_n = &products.nonwoody_nitrogen_g,
        .litter_phosphorus_g_p = &products.nonwoody_phosphorus_g,
    }, .{
        .timestep_h = context.timestep_h,
        .litterfall_rate_per_h = context.seasonal_litterfall_rate_per_h,
        .litterfall_delay_threshold_h = context.seasonal_litterfall_delay_threshold_h,
        .growth_habit = if (parameters.growth_habit == 0) .annual else .perennial,
        .phenology = try stages_module.phenologyTypeFromReadq(parameters.leaf_phenology_type),
        .nonfoliar_kinetics = .{ .carbon = &nonfoliar.carbon, .nitrogen = &nonfoliar.nitrogen, .phosphorus = &nonfoliar.phosphorus },
    });

    var stalk: seasonal_stalk_standing_dead_turnover.ElementMass = .{ .carbon_g_c = canopy.branch_stalk_carbon_g[branch], .nitrogen_g_n = canopy.branch_stalk_nitrogen_g[branch], .phosphorus_g_p = canopy.branch_stalk_phosphorus_g[branch] };
    var senescing_stalk: seasonal_stalk_standing_dead_turnover.ElementMass = .{ .carbon_g_c = canopy.branch_senescing_stalk_carbon_g[branch], .nitrogen_g_n = canopy.branch_senescing_stalk_nitrogen_g[branch], .phosphorus_g_p = canopy.branch_senescing_stalk_phosphorus_g[branch] };
    const lengths = workspace.internode_length_m[0..node_count];
    const masses = workspace.internode_mass[0..node_count];
    for (nodes.first..nodes.end, 0..) |node, local| {
        lengths[local] = canopy.node_internode_length_m[node];
        masses[local] = .{ .carbon_g_c = canopy.node_internode_carbon_g[node], .nitrogen_g_n = canopy.node_internode_nitrogen_g[node], .phosphorus_g_p = canopy.node_internode_phosphorus_g[node] };
    }
    const first_kinetic = plant * 4;
    var standing_carbon = canopy.plant_standing_dead_carbon_by_kinetic_g[first_kinetic..][0..4].*;
    var standing_nitrogen = canopy.plant_standing_dead_nitrogen_by_kinetic_g[first_kinetic..][0..4].*;
    var standing_phosphorus = canopy.plant_standing_dead_phosphorus_by_kinetic_g[first_kinetic..][0..4].*;
    const standing_before = .{ sumFour(standing_carbon), sumFour(standing_nitrogen), sumFour(standing_phosphorus) };
    if (admitted) {
        const stalk_kinetics = try context.litter_partition.get(plant, .stalk);
        _ = try seasonal_stalk_standing_dead_turnover.apply(.{
            .stalk = &stalk,
            .senescing_stalk = &senescing_stalk,
            .internode_length_m = lengths,
            .internode_mass = masses,
            .standing_dead_carbon_g_c = &standing_carbon,
            .standing_dead_nitrogen_g_n = &standing_nitrogen,
            .standing_dead_phosphorus_g_p = &standing_phosphorus,
        }, .{
            .aboveground_turnover_type = parameters.turnover_type,
            .root_profile_type = parameters.root_profile_type,
            .growth_habit = if (parameters.growth_habit == 0) .annual else .perennial,
            .litterfall_rate_per_h = context.seasonal_litterfall_rate_per_h,
            .timestep_h = context.timestep_h,
            .stalk_kinetics = .{ .carbon = &stalk_kinetics.carbon, .nitrogen = &stalk_kinetics.nitrogen, .phosphorus = &stalk_kinetics.phosphorus },
        });
    }

    context.dormancy.branches[branch].leafout_disabled = flag_state.leafout_disabled;
    context.dormancy.branches[branch].leafoff_disabled = flag_state.leafoff_disabled;
    context.dormancy.branches[branch].reproductive_growth_disabled = flag_state.reproductive_growth_disabled;
    context.dormancy.branches[branch].reproductive_litterfall_delay_h = flag_state.reproductive_litterfall_delay_h;
    context.development.leafout_initialization_enabled[branch] = !flag_state.leafout_initialization_disabled;
    canopy.branch_husk_carbon_g[branch] = husk.carbon_g_c;
    canopy.branch_husk_nitrogen_g[branch] = husk.nitrogen_g_n;
    canopy.branch_husk_phosphorus_g[branch] = husk.phosphorus_g_p;
    canopy.branch_ear_carbon_g[branch] = ear.carbon_g_c;
    canopy.branch_ear_nitrogen_g[branch] = ear.nitrogen_g_n;
    canopy.branch_ear_phosphorus_g[branch] = ear.phosphorus_g_p;
    canopy.branch_grain_carbon_g[branch] = grain.carbon_g_c;
    canopy.branch_grain_nitrogen_g[branch] = grain.nitrogen_g_n;
    canopy.branch_grain_phosphorus_g[branch] = grain.phosphorus_g_p;
    canopy.branch_potential_seed_site_count[branch] = potential_sites;
    canopy.branch_seed_count[branch] = seed_count;
    canopy.branch_individual_seed_carbon_g[branch] = individual_seed_carbon;
    canopy.plant_seed_storage_carbon_g[plant] = storage.carbon_g_c;
    canopy.plant_seed_storage_nitrogen_g[plant] = storage.nitrogen_g_n;
    canopy.plant_seed_storage_phosphorus_g[plant] = storage.phosphorus_g_p;
    context.senescence_products_by_plant[plant] = products;
    if (admitted) {
        canopy.branch_stalk_carbon_g[branch] = stalk.carbon_g_c;
        canopy.branch_stalk_nitrogen_g[branch] = stalk.nitrogen_g_n;
        canopy.branch_stalk_phosphorus_g[branch] = stalk.phosphorus_g_p;
        canopy.branch_senescing_stalk_carbon_g[branch] = senescing_stalk.carbon_g_c;
        canopy.branch_senescing_stalk_nitrogen_g[branch] = senescing_stalk.nitrogen_g_n;
        canopy.branch_senescing_stalk_phosphorus_g[branch] = senescing_stalk.phosphorus_g_p;
        for (nodes.first..nodes.end, 0..) |node, local| {
            canopy.node_internode_length_m[node] = lengths[local];
            canopy.node_internode_carbon_g[node] = masses[local].carbon_g_c;
            canopy.node_internode_nitrogen_g[node] = masses[local].nitrogen_g_n;
            canopy.node_internode_phosphorus_g[node] = masses[local].phosphorus_g_p;
        }
        canopy.plant_standing_dead_carbon_by_kinetic_g[first_kinetic..][0..4].* = standing_carbon;
        canopy.plant_standing_dead_nitrogen_by_kinetic_g[first_kinetic..][0..4].* = standing_nitrogen;
        canopy.plant_standing_dead_phosphorus_by_kinetic_g[first_kinetic..][0..4].* = standing_phosphorus;
        canopy.plant_standing_dead_carbon_g[plant] += sumFour(standing_carbon) - standing_before[0];
        canopy.plant_standing_dead_nitrogen_g[plant] += sumFour(standing_nitrogen) - standing_before[1];
        canopy.plant_standing_dead_phosphorus_g[plant] += sumFour(standing_phosphorus) - standing_before[2];
    }
    return admitted;
}

fn sumFour(values: [4]f64) f64 {
    var total: f64 = 0;
    for (values) |value| total += value;
    return total;
}

const PreEmergenceRootStateUpdate = struct {
    respiration_unlimited_by_oxygen_g_c_per_h: f64,
    respiration_unlimited_by_carbon_g_c_per_h: f64,
    actual_respiration_g_c_per_h: f64,
    aqueous_carbon_dioxide_g_c: f64,
    aqueous_carbon_dioxide_reaction_g_c_per_h: f64,
};

fn litterKinetics(fractions: litter_partition_module.ElementFractions) canopy_module.KineticFractions {
    return .{ .carbon = fractions.carbon, .nitrogen = fractions.nitrogen, .phosphorus = fractions.phosphorus };
}

fn senescenceLitterParameters(context: *const ApplyContext, plant: usize, branch: usize) !canopy_module.SenescenceLitterParameters {
    const foliar = try context.litter_partition.get(plant, .foliar);
    const sheath = try context.litter_partition.get(plant, .non_foliar);
    const stalk = try context.litter_partition.get(plant, .stalk);
    const woody = try context.litter_partition.get(plant, .coarse_wood);
    const parameters = context.plant_parameters[plant];
    const composition = try metabolism_module.shootWoodComposition(.{
        .biomass_turnover_type = parameters.turnover_type,
        .root_profile_type = parameters.root_profile_type,
        .stalk_carbon_g_c = context.canopy.branch_stalk_carbon_g[branch],
        .sapwood_carbon_g_c = context.canopy.branch_sapwood_carbon_g[branch],
        .structural_presence_threshold_g_c = context.senescence_demand_tolerance_g_c,
        .stalk_nitrogen_to_carbon_g_n_per_g_c = parameters.nitrogen_to_carbon_g_n_per_g_c[2],
        .leaf_nitrogen_to_carbon_g_n_per_g_c = parameters.nitrogen_to_carbon_g_n_per_g_c[0],
        .sheath_nitrogen_to_carbon_g_n_per_g_c = parameters.nitrogen_to_carbon_g_n_per_g_c[1],
        .stalk_phosphorus_to_carbon_g_p_per_g_c = parameters.phosphorus_to_carbon_g_p_per_g_c[2],
        .leaf_phosphorus_to_carbon_g_p_per_g_c = parameters.phosphorus_to_carbon_g_p_per_g_c[0],
        .sheath_phosphorus_to_carbon_g_p_per_g_c = parameters.phosphorus_to_carbon_g_p_per_g_c[1],
    });
    const nonwoody = [2]f64{ 0, 1 };
    return .{
        .woody_carbon_fraction = nonwoody,
        .leaf_woody_nitrogen_fraction = nonwoody,
        .sheath_woody_nitrogen_fraction = nonwoody,
        .stalk_woody_nitrogen_fraction = composition.stalk_nitrogen_fraction,
        .leaf_woody_phosphorus_fraction = nonwoody,
        .sheath_woody_phosphorus_fraction = nonwoody,
        .stalk_woody_phosphorus_fraction = composition.stalk_phosphorus_fraction,
        .woody_kinetics = litterKinetics(woody),
        .leaf_kinetics = litterKinetics(foliar),
        .sheath_kinetics = litterKinetics(sheath),
        .stalk_kinetics = litterKinetics(stalk),
    };
}

fn validateNodeGrowthTransaction(
    canopy: *const canopy_module.State,
    branch: usize,
    newest_node: usize,
    first_growing_node: usize,
    leaf_sheath_last_node: usize,
    stalk_first_node: usize,
    stalk_last_node: usize,
    maximum_concurrently_growing_nodes: usize,
    leaf: canopy_module.LeafGrowth,
    sheath: canopy_module.LeafGrowth,
    stalk: canopy_module.LeafGrowth,
    plant: PlantParameters,
    controls: NodeGrowthParameters,
    etoliation_factor: f64,
    turgor_expansion_fraction: f64,
    cell_area_m2: f64,
    plant_density_per_m2: f64,
    stalk_volume_m3_per_g_c: f64,
) !void {
    try controls.validate();
    inline for (.{
        plant.specific_leaf_area_m2_per_g_c,
        plant.specific_sheath_length_m_per_g_c,
        plant.specific_internode_length_m_per_g_c,
        plant.sheath_vertical_projection_fraction,
        plant.stalk_vertical_projection_fraction,
        etoliation_factor,
        turgor_expansion_fraction,
        cell_area_m2,
        plant_density_per_m2,
        stalk_volume_m3_per_g_c,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteShootNodeGrowthInput;
    if (plant.specific_leaf_area_m2_per_g_c < 0 or plant.specific_sheath_length_m_per_g_c < 0 or plant.specific_internode_length_m_per_g_c < 0 or plant.sheath_vertical_projection_fraction < 0 or plant.sheath_vertical_projection_fraction > 1 or plant.stalk_vertical_projection_fraction < 0 or plant.stalk_vertical_projection_fraction > 1 or etoliation_factor < 0 or turgor_expansion_fraction < 0 or turgor_expansion_fraction > 1 or cell_area_m2 <= 0 or plant_density_per_m2 <= 0 or stalk_volume_m3_per_g_c <= 0 or maximum_concurrently_growing_nodes == 0) return error.InvalidShootNodeGrowthInput;
    inline for (.{ leaf, sheath, stalk }) |growth| inline for (.{ growth.carbon_g, growth.nitrogen_g, growth.phosphorus_g }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidShootNodeGrowthInput;
    const nodes = try canopy.nodeRange(branch);
    if (newest_node >= nodes.end - nodes.first or leaf_sheath_last_node >= nodes.end - nodes.first or first_growing_node > leaf_sheath_last_node or stalk_last_node >= nodes.end - nodes.first or stalk_first_node > stalk_last_node) return error.CanopyNodeIndexOutOfBounds;
    const first = @max(first_growing_node, leaf_sheath_last_node + 1 -| maximum_concurrently_growing_nodes);
    const count_f64: f64 = @floatFromInt(leaf_sheath_last_node - first + 1);
    var leaf_area_growth_m2: f64 = 0;
    for (first..leaf_sheath_last_node + 1) |local_node| {
        const node = nodes.first + local_node;
        const leaf_carbon = canopy.node_leaf_carbon_g[node] + leaf.carbon_g / count_f64;
        const leaf_nitrogen = canopy.node_leaf_nitrogen_g[node] + leaf.nitrogen_g / count_f64;
        const leaf_phosphorus = canopy.node_leaf_phosphorus_g[node] + leaf.phosphorus_g / count_f64;
        const leaf_protein = canopy.node_leaf_protein_g[node] + @min(leaf.nitrogen_g / count_f64 * controls.protein_per_nitrogen_g_protein_per_g_n, leaf.phosphorus_g / count_f64 * controls.protein_per_phosphorus_g_protein_per_g_p);
        const leaf_specific_area = etoliation_factor * plant.specific_leaf_area_m2_per_g_c * std.math.pow(f64, @max(controls.minimum_leaf_carbon_g_c_per_m2_cell * cell_area_m2, leaf_carbon) / plant_density_per_m2, controls.leaf_mass_exponent) * turgor_expansion_fraction;
        const leaf_area = canopy.node_leaf_area_m2[node] + leaf.carbon_g / count_f64 * leaf_specific_area;
        leaf_area_growth_m2 += leaf.carbon_g / count_f64 * leaf_specific_area;
        const sheath_carbon = canopy.node_sheath_carbon_g[node] + sheath.carbon_g / count_f64;
        const sheath_nitrogen = canopy.node_sheath_nitrogen_g[node] + sheath.nitrogen_g / count_f64;
        const sheath_phosphorus = canopy.node_sheath_phosphorus_g[node] + sheath.phosphorus_g / count_f64;
        const sheath_protein = canopy.node_sheath_protein_g[node] + @min(sheath.nitrogen_g / count_f64 * controls.protein_per_nitrogen_g_protein_per_g_n, sheath.phosphorus_g / count_f64 * controls.protein_per_phosphorus_g_protein_per_g_p);
        const sheath_specific_length = etoliation_factor * plant.specific_sheath_length_m_per_g_c * std.math.pow(f64, @max(controls.minimum_sheath_carbon_g_c_per_m2_cell * cell_area_m2, sheath_carbon) / plant_density_per_m2, controls.sheath_mass_exponent) * turgor_expansion_fraction;
        const sheath_height = canopy.node_sheath_height_m[node] + if (leaf_carbon > 0) sheath.carbon_g / count_f64 / plant_density_per_m2 * sheath_specific_length * plant.sheath_vertical_projection_fraction else 0;
        inline for (.{ leaf_carbon, leaf_nitrogen, leaf_phosphorus, leaf_protein, leaf_specific_area, leaf_area, sheath_carbon, sheath_nitrogen, sheath_phosphorus, sheath_protein, sheath_specific_length, sheath_height }) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteShootNodeGrowthResult;
    }
    if (!std.math.isFinite(canopy.branch_leaf_area_m2[branch] + leaf_area_growth_m2)) return error.NonFiniteShootNodeGrowthResult;
    {
        const stalk_count_f64: f64 = @floatFromInt(stalk_last_node - stalk_first_node + 1);
        var previous_height_m = if (stalk_first_node > 0) canopy.node_height_m[nodes.first + stalk_first_node - 1] else 0;
        for (stalk_first_node..stalk_last_node + 1) |local_node| {
            const node = nodes.first + local_node;
            const carbon = canopy.node_internode_carbon_g[node] + stalk.carbon_g / stalk_count_f64;
            const nitrogen = canopy.node_internode_nitrogen_g[node] + stalk.nitrogen_g / stalk_count_f64;
            const phosphorus = canopy.node_internode_phosphorus_g[node] + stalk.phosphorus_g / stalk_count_f64;
            const specific_length = @sqrt(etoliation_factor) * plant.specific_internode_length_m_per_g_c * std.math.pow(f64, @max(controls.minimum_internode_carbon_g_c_per_m2_cell * cell_area_m2, carbon) / plant_density_per_m2, controls.internode_mass_exponent) * turgor_expansion_fraction;
            const length = canopy.node_internode_length_m[node] + stalk.carbon_g / stalk_count_f64 / plant_density_per_m2 * specific_length * plant.stalk_vertical_projection_fraction;
            const height = previous_height_m + length;
            inline for (.{ carbon, nitrogen, phosphorus, specific_length, length, height }) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteShootNodeGrowthResult;
            previous_height_m = height;
        }
    }
}

fn equilibratePlantBranchReserves(canopy: *canopy_module.State, branches: canopy_module.Range, main_branch: ?usize, controls: NodeGrowthParameters, timestep_h: f64, presence_threshold_g_c: f64) !void {
    if (branches.end > canopy.branch_reserve_carbon_g.len or branches.first >= branches.end) return error.CanopyBranchIndexOutOfBounds;
    if (branches.end - branches.first <= 1 or main_branch == null) return;
    const main = main_branch.?;
    if (main < branches.first or main >= branches.end) return error.CanopyBranchIndexOutOfBounds;
    const branch_count = branches.end - branches.first;
    const workspace_values = try canopy.allocator.alloc(f64, try std.math.mul(usize, branch_count, 3));
    defer canopy.allocator.free(workspace_values);
    try branch_reserve_equilibration.apply(.{
        .sapwood_carbon_g_c = canopy.branch_sapwood_carbon_g,
        .reserve_carbon_g_c = canopy.branch_reserve_carbon_g,
        .reserve_nitrogen_g_n = canopy.branch_reserve_nitrogen_g,
        .reserve_phosphorus_g_p = canopy.branch_reserve_phosphorus_g,
    }, .{
        .reserve_carbon_g_c = workspace_values[0..branch_count],
        .reserve_nitrogen_g_n = workspace_values[branch_count .. 2 * branch_count],
        .reserve_phosphorus_g_p = workspace_values[2 * branch_count .. 3 * branch_count],
    }, .{
        .first_branch = branches.first,
        .end_branch = branches.end,
        .main_branch = main,
        .carbon_exchange_fraction_per_h = controls.branch_reserve_carbon_exchange_fraction_per_h,
        .nutrient_exchange_fraction_per_h = controls.branch_reserve_nutrient_exchange_fraction_per_h,
        .timestep_h = timestep_h,
        .structural_presence_threshold_g_c = presence_threshold_g_c,
    });
}

pub fn redistributeMainBranchMobileDuringRemobilization(
    canopy: *canopy_module.State,
    main_branch: usize,
    lateral_branch: usize,
    temperature_response: f64,
    parameters: BranchMobileExchangeParameters,
    timestep_h: f64,
) !void {
    try parameters.validate();
    if (main_branch >= canopy.branch_mobile_carbon_g.len or lateral_branch >= canopy.branch_mobile_carbon_g.len or main_branch == lateral_branch) return error.CanopyBranchIndexOutOfBounds;
    inline for (.{ temperature_response, timestep_h }) |value| if (!std.math.isFinite(value)) return error.NonFiniteBranchMobileExchangeState;
    if (temperature_response < 0 or timestep_h <= 0) return error.InvalidBranchMobileExchangeParameter;
    inline for (.{
        .{"branch_mobile_carbon_g"},
        .{"branch_mobile_nitrogen_g"},
        .{"branch_mobile_phosphorus_g"},
    }) |fields| {
        const field = fields[0];
        const main_pool = @field(canopy, field)[main_branch];
        const lateral_pool = @field(canopy, field)[lateral_branch];
        if (!std.math.isFinite(main_pool) or main_pool < 0 or !std.math.isFinite(lateral_pool) or lateral_pool < 0) return error.NonFiniteBranchMobileExchangeState;
        const transfer = @max(0, parameters.remobilization_redistribution_fraction_per_h * temperature_response * (0.5 * (main_pool + lateral_pool) - lateral_pool) * timestep_h);
        if (!std.math.isFinite(transfer) or transfer > main_pool) return error.BranchMobileExchangeExhaustedPool;
        @field(canopy, field)[main_branch] = main_pool - transfer;
        @field(canopy, field)[lateral_branch] = lateral_pool + transfer;
    }
}

pub fn equilibratePlantBranchMobilePools(
    canopy: *canopy_module.State,
    growth_stages: *const stages_module.State,
    development: *const development_module.BranchDevelopmentState,
    branches: canopy_module.Range,
    remobilization_duration_h: f64,
    parameters: BranchMobileExchangeParameters,
    timestep_h: f64,
    tolerance_g: f64,
) !void {
    try parameters.validate();
    if (branches.end > canopy.branch_mobile_carbon_g.len or branches.end > development.branch_count or branches.end > growth_stages.branches.len or branches.first >= branches.end) return error.CanopyBranchIndexOutOfBounds;
    if (branches.end - branches.first <= 1) return;
    inline for (.{ remobilization_duration_h, timestep_h, tolerance_g }) |value| if (!std.math.isFinite(value)) return error.NonFiniteBranchMobileExchangeParameter;
    if (remobilization_duration_h <= 0 or timestep_h <= 0 or tolerance_g < 0) return error.InvalidBranchMobileExchangeParameter;
    var total_tissue_carbon_g_c: f64 = 0;
    var total_mobile_carbon_g_c: f64 = 0;
    var total_mobile_nitrogen_g_n: f64 = 0;
    var total_mobile_phosphorus_g_p: f64 = 0;
    var eligible_count: usize = 0;
    for (branches.first..branches.end) |branch| {
        if (growth_stages.branches[branch].dead or development.remobilization_progress_h[branch] <= remobilization_duration_h) continue;
        const leaf = canopy.branch_leaf_carbon_g[branch];
        const sheath = canopy.branch_sheath_carbon_g[branch];
        const tissue = leaf + sheath;
        const carbon = canopy.branch_mobile_carbon_g[branch];
        const nitrogen = canopy.branch_mobile_nitrogen_g[branch];
        const phosphorus = canopy.branch_mobile_phosphorus_g[branch];
        inline for (.{ leaf, sheath, tissue, carbon, nitrogen, phosphorus }) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteBranchMobileExchangeState;
        total_tissue_carbon_g_c += tissue;
        total_mobile_carbon_g_c += carbon;
        total_mobile_nitrogen_g_n += nitrogen;
        total_mobile_phosphorus_g_p += phosphorus;
        eligible_count += 1;
    }
    inline for (.{ total_tissue_carbon_g_c, total_mobile_carbon_g_c, total_mobile_nitrogen_g_n, total_mobile_phosphorus_g_p }) |total|
        if (!std.math.isFinite(total)) return error.NonFiniteBranchMobileExchangeState;
    if (eligible_count <= 1 or total_tissue_carbon_g_c <= tolerance_g or total_mobile_carbon_g_c <= tolerance_g) return;
    // Validate every simultaneous source-order image before publishing any
    // branch.  This makes a late overdraw fail atomically.
    for (branches.first..branches.end) |branch| {
        if (growth_stages.branches[branch].dead or development.remobilization_progress_h[branch] <= remobilization_duration_h) continue;
        const tissue = canopy.branch_leaf_carbon_g[branch] + canopy.branch_sheath_carbon_g[branch];
        const carbon = canopy.branch_mobile_carbon_g[branch];
        const nitrogen = canopy.branch_mobile_nitrogen_g[branch];
        const phosphorus = canopy.branch_mobile_phosphorus_g[branch];
        const carbon_flux = parameters.carbon_exchange_fraction_per_h *
            (total_mobile_carbon_g_c * tissue - carbon * total_tissue_carbon_g_c) /
            total_tissue_carbon_g_c * timestep_h;
        const nitrogen_flux = parameters.nutrient_exchange_fraction_per_h *
            (total_mobile_nitrogen_g_n * carbon - nitrogen * total_mobile_carbon_g_c) /
            total_mobile_carbon_g_c * timestep_h;
        const phosphorus_flux = parameters.nutrient_exchange_fraction_per_h *
            (total_mobile_phosphorus_g_p * carbon - phosphorus * total_mobile_carbon_g_c) /
            total_mobile_carbon_g_c * timestep_h;
        const next_carbon = canopy.branch_mobile_carbon_g[branch] + carbon_flux;
        const next_nitrogen = canopy.branch_mobile_nitrogen_g[branch] + nitrogen_flux;
        const next_phosphorus = canopy.branch_mobile_phosphorus_g[branch] + phosphorus_flux;
        inline for (.{ next_carbon, next_nitrogen, next_phosphorus }) |value| if (!std.math.isFinite(value) or value < 0) return error.BranchMobileExchangeExhaustedPool;
    }
    for (branches.first..branches.end) |branch| {
        if (growth_stages.branches[branch].dead or development.remobilization_progress_h[branch] <= remobilization_duration_h) continue;
        const tissue = canopy.branch_leaf_carbon_g[branch] + canopy.branch_sheath_carbon_g[branch];
        const carbon = canopy.branch_mobile_carbon_g[branch];
        const nitrogen = canopy.branch_mobile_nitrogen_g[branch];
        const phosphorus = canopy.branch_mobile_phosphorus_g[branch];
        const carbon_flux = parameters.carbon_exchange_fraction_per_h *
            (total_mobile_carbon_g_c * tissue - carbon * total_tissue_carbon_g_c) /
            total_tissue_carbon_g_c * timestep_h;
        const nitrogen_flux = parameters.nutrient_exchange_fraction_per_h *
            (total_mobile_nitrogen_g_n * carbon - nitrogen * total_mobile_carbon_g_c) /
            total_mobile_carbon_g_c * timestep_h;
        const phosphorus_flux = parameters.nutrient_exchange_fraction_per_h *
            (total_mobile_phosphorus_g_p * carbon - phosphorus * total_mobile_carbon_g_c) /
            total_mobile_carbon_g_c * timestep_h;
        canopy.branch_mobile_carbon_g[branch] = carbon + carbon_flux;
        canopy.branch_mobile_nitrogen_g[branch] = nitrogen + nitrogen_flux;
        canopy.branch_mobile_phosphorus_g[branch] = phosphorus + phosphorus_flux;
    }
}

fn addSymbiontLitter(
    destination: *canopy_module.SenescenceProducts,
    litter: symbiosis_module.Pool,
    kinetics: litter_partition_module.ElementFractions,
) !void {
    inline for (.{ litter.carbon_g_c, litter.nitrogen_g_n, litter.phosphorus_g_p }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidCanopySymbiontLitter;
    for (0..4) |fraction| {
        destination.nonwoody_carbon_g[fraction] += litter.carbon_g_c * kinetics.carbon[fraction];
        destination.nonwoody_nitrogen_g[fraction] += litter.nitrogen_g_n * kinetics.nitrogen[fraction];
        destination.nonwoody_phosphorus_g[fraction] += litter.phosphorus_g_p * kinetics.phosphorus[fraction];
    }
}

/// GROSUB end-of-season reproductive turnover. Husk and ear always enter
/// non-foliar litter; grain from a deciduous annual is retained in seasonal
/// seed storage, while other grain follows the same litter kinetics.
pub fn state_updateEndOfSeasonReproductiveTurnover(
    canopy: *canopy_module.State,
    branch: usize,
    plant: usize,
    turnover_fraction: f64,
    self_seeding_annual: bool,
    kinetics: litter_partition_module.ElementFractions,
    products: *canopy_module.SenescenceProducts,
) !void {
    try kinetics.validate();
    if (branch >= canopy.branch_husk_carbon_g.len or plant >= canopy.plant_seed_storage_carbon_g.len)
        return error.ReproductiveTurnoverIndexOutOfBounds;
    if (!std.math.isFinite(turnover_fraction) or turnover_fraction < 0 or turnover_fraction > 1)
        return error.InvalidReproductiveTurnoverFraction;
    const remaining = 1 - turnover_fraction;
    const husk_ear: canopy_module.ElementalMass = .{
        .carbon_g = turnover_fraction * (canopy.branch_husk_carbon_g[branch] + canopy.branch_ear_carbon_g[branch]),
        .nitrogen_g = turnover_fraction * (canopy.branch_husk_nitrogen_g[branch] + canopy.branch_ear_nitrogen_g[branch]),
        .phosphorus_g = turnover_fraction * (canopy.branch_husk_phosphorus_g[branch] + canopy.branch_ear_phosphorus_g[branch]),
    };
    const grain: canopy_module.ElementalMass = .{
        .carbon_g = turnover_fraction * canopy.branch_grain_carbon_g[branch],
        .nitrogen_g = turnover_fraction * canopy.branch_grain_nitrogen_g[branch],
        .phosphorus_g = turnover_fraction * canopy.branch_grain_phosphorus_g[branch],
    };
    inline for (.{ husk_ear.carbon_g, husk_ear.nitrogen_g, husk_ear.phosphorus_g, grain.carbon_g, grain.nitrogen_g, grain.phosphorus_g }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidReproductiveTurnoverState;
    var litter = husk_ear;
    if (self_seeding_annual) {
        const next_carbon_g = canopy.plant_seed_storage_carbon_g[plant] + grain.carbon_g;
        const next_nitrogen_g = canopy.plant_seed_storage_nitrogen_g[plant] + grain.nitrogen_g;
        const next_phosphorus_g = canopy.plant_seed_storage_phosphorus_g[plant] + grain.phosphorus_g;
        inline for (.{ next_carbon_g, next_nitrogen_g, next_phosphorus_g }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidReproductiveTurnoverState;
        canopy.plant_seed_storage_carbon_g[plant] = next_carbon_g;
        canopy.plant_seed_storage_nitrogen_g[plant] = next_nitrogen_g;
        canopy.plant_seed_storage_phosphorus_g[plant] = next_phosphorus_g;
    } else {
        litter.carbon_g += grain.carbon_g;
        litter.nitrogen_g += grain.nitrogen_g;
        litter.phosphorus_g += grain.phosphorus_g;
    }
    for (0..4) |fraction| {
        products.nonwoody_carbon_g[fraction] += litter.carbon_g * kinetics.carbon[fraction];
        products.nonwoody_nitrogen_g[fraction] += litter.nitrogen_g * kinetics.nitrogen[fraction];
        products.nonwoody_phosphorus_g[fraction] += litter.phosphorus_g * kinetics.phosphorus[fraction];
    }
    inline for (.{
        "branch_husk_carbon_g",
        "branch_husk_nitrogen_g",
        "branch_husk_phosphorus_g",
        "branch_ear_carbon_g",
        "branch_ear_nitrogen_g",
        "branch_ear_phosphorus_g",
        "branch_grain_carbon_g",
        "branch_grain_nitrogen_g",
        "branch_grain_phosphorus_g",
        "branch_potential_seed_site_count",
        "branch_seed_count",
        "branch_individual_seed_carbon_g",
    }) |field_name| @field(canopy, field_name)[branch] *= remaining;
}

/// Transfers the FSNRX fraction of a perennial herbaceous/shrub branch's
/// total stalk into its four standing-dead kinetic pools. GROSUB also reduces
/// the senescing-stalk subset and every internode by the same fraction.
pub fn state_updateSeasonalStalkToStandingDead(
    canopy: *canopy_module.State,
    branch: usize,
    plant: usize,
    turnover_fraction: f64,
    kinetics: litter_partition_module.ElementFractions,
) !void {
    try kinetics.validate();
    if (branch >= canopy.branch_stalk_carbon_g.len or plant >= canopy.plant_standing_dead_carbon_g.len)
        return error.SeasonalStalkTurnoverIndexOutOfBounds;
    if (!std.math.isFinite(turnover_fraction) or turnover_fraction < 0 or turnover_fraction > 1)
        return error.InvalidSeasonalStalkTurnoverFraction;
    const removed: canopy_module.ElementalMass = .{
        .carbon_g = turnover_fraction * canopy.branch_stalk_carbon_g[branch],
        .nitrogen_g = turnover_fraction * canopy.branch_stalk_nitrogen_g[branch],
        .phosphorus_g = turnover_fraction * canopy.branch_stalk_phosphorus_g[branch],
    };
    inline for (.{ removed.carbon_g, removed.nitrogen_g, removed.phosphorus_g }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSeasonalStalkTurnoverState;
    const next_totals = canopy_module.ElementalMass{
        .carbon_g = canopy.plant_standing_dead_carbon_g[plant] + removed.carbon_g,
        .nitrogen_g = canopy.plant_standing_dead_nitrogen_g[plant] + removed.nitrogen_g,
        .phosphorus_g = canopy.plant_standing_dead_phosphorus_g[plant] + removed.phosphorus_g,
    };
    inline for (.{ next_totals.carbon_g, next_totals.nitrogen_g, next_totals.phosphorus_g }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSeasonalStalkTurnoverState;
    canopy.plant_standing_dead_carbon_g[plant] = next_totals.carbon_g;
    canopy.plant_standing_dead_nitrogen_g[plant] = next_totals.nitrogen_g;
    canopy.plant_standing_dead_phosphorus_g[plant] = next_totals.phosphorus_g;
    const first_kinetic = plant * 4;
    for (0..4) |kinetic| {
        canopy.plant_standing_dead_carbon_by_kinetic_g[first_kinetic + kinetic] += removed.carbon_g * kinetics.carbon[kinetic];
        canopy.plant_standing_dead_nitrogen_by_kinetic_g[first_kinetic + kinetic] += removed.nitrogen_g * kinetics.nitrogen[kinetic];
        canopy.plant_standing_dead_phosphorus_by_kinetic_g[first_kinetic + kinetic] += removed.phosphorus_g * kinetics.phosphorus[kinetic];
    }
    const remaining = 1 - turnover_fraction;
    canopy.branch_stalk_carbon_g[branch] *= remaining;
    canopy.branch_stalk_nitrogen_g[branch] *= remaining;
    canopy.branch_stalk_phosphorus_g[branch] *= remaining;
    canopy.branch_senescing_stalk_carbon_g[branch] *= remaining;
    canopy.branch_senescing_stalk_nitrogen_g[branch] *= remaining;
    canopy.branch_senescing_stalk_phosphorus_g[branch] *= remaining;
    const nodes = try canopy.nodeRange(branch);
    for (nodes.first..nodes.end) |node| {
        canopy.node_internode_length_m[node] *= remaining;
        canopy.node_internode_carbon_g[node] *= remaining;
        canopy.node_internode_nitrogen_g[node] *= remaining;
        canopy.node_internode_phosphorus_g[node] *= remaining;
    }
}

/// Final GROSUB DEATHC backstop after node/stalk senescence could not satisfy
/// excess respiration. Seasonal plant storage is consumed first. Exhaustion
/// kills perennial and evergreen-annual branches; deciduous annuals instead
/// force completion of leafoff and await their scheduled harvest.
pub fn state_updateSenescenceStorageBackstop(
    canopy: *canopy_module.State,
    growth: *stages_module.State,
    development: *development_module.BranchDevelopmentState,
    dormancy: *dormancy_module.RuntimeState,
    plant: usize,
    branch: usize,
    remaining_respiration_demand_g_c: f64,
    perennial: bool,
    evergreen: bool,
    required_leafoff_h: f64,
    tolerance_g_c: f64,
) !bool {
    inline for (.{ remaining_respiration_demand_g_c, required_leafoff_h, tolerance_g_c }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSenescenceStorageBackstop;
    if (remaining_respiration_demand_g_c < 0 or required_leafoff_h < 0 or tolerance_g_c < 0)
        return error.InvalidSenescenceStorageBackstop;
    if (plant >= canopy.plant_seed_storage_carbon_g.len or branch >= growth.branches.len or
        branch >= development.dead.len or branch >= dormancy.branches.len)
        return error.SenescenceStorageBackstopIndexOutOfBounds;
    const storage_g_c = canopy.plant_seed_storage_carbon_g[plant];
    if (!std.math.isFinite(storage_g_c) or storage_g_c < 0) return error.InvalidSenescenceStorageBackstopState;
    if (remaining_respiration_demand_g_c <= tolerance_g_c) return false;

    var status: storage_carbon_branch_survival.BranchStatus = if (growth.branches[branch].dead or development.dead[branch]) .dead else .alive;
    const outcome = try storage_carbon_branch_survival.apply(.{
        .plant_storage_carbon_g_c = &canopy.plant_seed_storage_carbon_g[plant],
        .branch_stalk_carbon_g_c = &canopy.branch_stalk_carbon_g[branch],
        .branch_status = &status,
        .leafoff_accumulated_h = &dormancy.branches[branch].accumulated_leafoff_h,
    }, .{
        .remaining_respiration_g_c_per_timestep = remaining_respiration_demand_g_c,
        .growth_habit = if (perennial) .perennial else .annual,
        .phenology = if (evergreen) .evergreen else .seasonal,
        .leafoff_required_h = required_leafoff_h,
    });
    if (outcome.outcome == .branch_died) {
        growth.branches[branch].dead = true;
        development.dead[branch] = true;
        return true;
    }
    return false;
}

/// GROSUB 8845 phenology reset applied after a naturally dead branch has
/// published its remaining inventories. Runtime initialization controls are
/// retained while transient stage, dormancy, and milestone state is cleared.
pub fn resetNaturalDeadBranch(
    growth: *stages_module.State,
    development: *development_module.BranchDevelopmentState,
    dormancy: *dormancy_module.RuntimeState,
    branch: usize,
) !void {
    if (branch >= growth.branches.len or branch >= development.branch_count or branch >= dormancy.branches.len)
        return error.NaturalDeadBranchIndexOutOfBounds;
    const branch_order = growth.branches[branch].branch_order;
    const maturity_group = development.maturity_group[branch];
    const initial_stage = development.initial_reproductive_stage[branch];
    const perennial_scaling = development.perennial_node_scaling[branch];
    const maximum_nodes = development.maximum_concurrently_growing_nodes[branch];
    if (!std.math.isFinite(maturity_group) or !std.math.isFinite(initial_stage) or !std.math.isFinite(perennial_scaling) or
        maturity_group < 0 or initial_stage < 0 or perennial_scaling < 0)
        return error.InvalidNaturalDeadBranchInitialization;

    try development.clearRangeForReconstruction(branch, branch + 1);
    if (perennial_scaling >= 1 and maximum_nodes > 0)
        try development.initializeRange(branch, branch + 1, maturity_group, initial_stage, false, perennial_scaling, maximum_nodes);
    development.dead[branch] = true;
    try dormancy.clearRangeForReconstruction(branch, branch + 1);
    dormancy.branches[branch].leafout_disabled = true;
    growth.branches[branch] = .{
        .dead = true,
        .branch_order = branch_order,
        .initiated_node_count = initial_stage,
    };
}

fn advanceCanopySymbiosis(
    context: *ApplyContext,
    cell: usize,
    plant: usize,
    branch: usize,
    parameters: PlantParameters,
    growth_temperature: f64,
    maintenance_temperature: f64,
    water: canopy_module.CanopyWaterGrowthResponse,
    physiological_maturity_reached: bool,
) !void {
    const fixation_type = parameters.nitrogen_fixation_type;
    context.canopy.branch_symbiotic_fixed_nitrogen_g_n_per_h[branch] = 0;
    context.canopy.branch_symbiotic_respiration_g_c_per_h[branch] = 0;
    if (fixation_type < 4 or fixation_type > 6) return;
    try context.symbiosis_parameters.validate();

    const current_structural: symbiosis_module.Pool = .{
        .carbon_g_c = context.canopy.branch_symbiont_structural_carbon_g[branch],
        .nitrogen_g_n = context.canopy.branch_symbiont_structural_nitrogen_g[branch],
        .phosphorus_g_p = context.canopy.branch_symbiont_structural_phosphorus_g[branch],
    };
    const structural = try symbiosis_module.initializeCanopyInfection(
        fixation_type,
        true,
        context.fire_active_this_hour[cell],
        current_structural,
        context.symbiosis_parameters.initial_bacterial_carbon_g_c_per_m2,
        context.cell_area_m2[cell],
        parameters.symbiont_nitrogen_to_carbon_g_n_per_g_c,
        parameters.symbiont_phosphorus_to_carbon_g_p_per_g_c,
    );
    const current_mobile: symbiosis_module.Pool = .{
        .carbon_g_c = context.canopy.branch_symbiont_mobile_carbon_g[branch],
        .nitrogen_g_n = context.canopy.branch_symbiont_mobile_nitrogen_g[branch],
        .phosphorus_g_p = context.canopy.branch_symbiont_mobile_phosphorus_g[branch],
    };
    const external_inoculum_input = try symbiosis_module.infectionExternalInput(
        current_structural,
        structural,
    );
    const host_tissue_carbon_g_c = context.canopy.branch_leaf_carbon_g[branch] + context.canopy.branch_sheath_carbon_g[branch];
    const host_leaf_area_m2 = context.canopy.branch_leaf_area_m2[branch];
    const zerop_g_c = context.structural_presence_threshold_g_per_plant * context.canopy.plant_population_count[plant];
    const zerop2_g_c = context.grain_fill_detection_threshold_g_per_plant * context.canopy.plant_population_count[plant];
    const metabolism = try symbiosis_module.calculate(.{
        .structural = structural,
        .nonstructural = current_mobile,
        .decomposition_density = try symbiosis_module.canopyDecompositionDensity(
            structural.carbon_g_c,
            host_leaf_area_m2,
            zerop2_g_c,
        ),
        .temperature_response = growth_temperature,
        .growth_water_response = water.growth_fraction,
        .maintenance_temperature_response = maintenance_temperature,
        .maintenance_water_response = water.water_potential_expansion_fraction,
        .timestep_h = context.timestep_h,
        .structural_presence_threshold_g_c = zerop_g_c,
        .ratio_division_threshold = context.structural_presence_threshold_g_per_plant,
        .fixation_respiration_presence_threshold_g_c = zerop_g_c,
    }, try symbiosis_module.metabolicParameters(
        context.symbiosis_parameters,
        fixation_type,
        parameters.symbiont_nitrogen_to_carbon_g_n_per_g_c,
        parameters.symbiont_phosphorus_to_carbon_g_p_per_g_c,
        parameters.symbiont_growth_yield_g_c_per_g_c,
    ));

    const host_mobile: symbiosis_module.Pool = .{
        .carbon_g_c = context.canopy.branch_mobile_carbon_g[branch],
        .nitrogen_g_n = context.canopy.branch_mobile_nitrogen_g[branch],
        .phosphorus_g_p = context.canopy.branch_mobile_phosphorus_g[branch],
    };
    const exchange = if (host_mobile.carbon_g_c > zerop_g_c and host_tissue_carbon_g_c > zerop2_g_c and (parameters.growth_habit != 0 or !physiological_maturity_reached))
        try symbiosis_module.equilibrateHostAndSymbiont(
            host_mobile,
            metabolism.next_nonstructural,
            host_tissue_carbon_g_c,
            metabolism.next_structural.carbon_g_c,
            context.symbiosis_parameters.initial_bacterial_carbon_g_c_per_m2 * context.cell_area_m2[cell],
            context.symbiosis_parameters.host_exchange_fraction_per_h_by_fixation_type[fixation_type - 1],
            context.timestep_h,
            zerop_g_c,
            zerop2_g_c,
            zerop_g_c,
        )
    else
        symbiosis_module.HostExchange{ .next_host = host_mobile, .next_symbiont = metabolism.next_nonstructural, .host_to_symbiont = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 } };
    const foliar_litter = try context.litter_partition.get(plant, .foliar);
    var products: canopy_module.SenescenceProducts = .{};
    try addSymbiontLitter(&products, metabolism.litterfall, foliar_litter);

    // All fallible symbiosis work is complete. Stage the exact WTNDI source
    // immediately before the associated plant state publication.
    try symbiosis_module.accumulateExternalInput(
        &context.symbiotic_inoculum_input_by_cell[cell],
        external_inoculum_input,
    );
    context.canopy.branch_symbiont_structural_carbon_g[branch] = metabolism.next_structural.carbon_g_c;
    context.canopy.branch_symbiont_structural_nitrogen_g[branch] = metabolism.next_structural.nitrogen_g_n;
    context.canopy.branch_symbiont_structural_phosphorus_g[branch] = metabolism.next_structural.phosphorus_g_p;
    context.canopy.branch_symbiont_mobile_carbon_g[branch] = exchange.next_symbiont.carbon_g_c;
    context.canopy.branch_symbiont_mobile_nitrogen_g[branch] = exchange.next_symbiont.nitrogen_g_n;
    context.canopy.branch_symbiont_mobile_phosphorus_g[branch] = exchange.next_symbiont.phosphorus_g_p;
    context.canopy.branch_mobile_carbon_g[branch] = exchange.next_host.carbon_g_c;
    context.canopy.branch_mobile_nitrogen_g[branch] = exchange.next_host.nitrogen_g_n;
    context.canopy.branch_mobile_phosphorus_g[branch] = exchange.next_host.phosphorus_g_p;
    context.canopy.branch_symbiotic_fixed_nitrogen_g_n_per_h[branch] = metabolism.fixed_nitrogen_g_n / context.timestep_h;
    context.canopy.branch_symbiotic_respiration_g_c_per_h[branch] = metabolism.total_respiration_g_c / context.timestep_h;
    if (context.carbon_exchange) |ledger| ledger.symbiont_respiration_g_c_per_h[branch] = context.canopy.branch_symbiotic_respiration_g_c_per_h[branch];
    canopy_module.addSenescenceProducts(&context.senescence_products_by_plant[plant], products);
}

/// Executes GROSUB PART → respiration/nutrient limitation → organ growth for
/// independent runtime branches. C3 uses atmospheric Rubisco product; C4 uses
/// only bundle-sheath Rubisco product published after the mesophyll transaction.
pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    const canopy = context.canopy;
    const plant_count = canopy.cell_count * canopy.species_count;
    inline for (.{
        context.plant_parameters,
        context.active_by_plant,
        context.emerged_by_plant,
        context.leaf_appearance_rate_at_25c_per_h_by_plant,
        context.sowing_depth_m_by_plant,
        context.canopy_temperature_k_by_plant,
        context.canopy_total_water_potential_mpa_by_plant,
        context.total_aerodynamic_resistance_h_per_m_by_plant,
        context.stomatal_resistance_h_per_m_by_plant,
        context.plant_radiation_fraction,
    }) |values| if (values.len != plant_count) return error.ShootGrowthRuntimeDimensionMismatch;
    if (range.end > canopy.cell_count or context.cell_area_m2.len != canopy.cell_count or context.solar_noon_hour_by_cell.len != canopy.cell_count or context.fire_active_this_hour.len != canopy.cell_count or context.symbiotic_inoculum_input_by_cell.len != canopy.cell_count or context.atmospheric_concentration_g_per_m3.len != canopy.cell_count * gas_transport_module.species_count or context.hour_of_day > 23 or context.growth_stages.plant_count != plant_count or context.dormancy.branches.len != canopy.branch_node_offsets.len - 1 or context.development.branch_count != canopy.branch_node_offsets.len - 1 or context.dormancy_parameters_by_plant.len != plant_count or context.litter_partition.plant_count != plant_count or context.senescence_products_by_plant.len != plant_count or (context.seasonal_turnover_event_by_plant != null and context.seasonal_turnover_event_by_plant.?.len != plant_count) or context.accepted_internal_activity.cell_count != canopy.cell_count or context.accepted_internal_activity.soil_layer_count != context.soil_layer_capacity or !std.math.isFinite(context.timestep_h) or context.timestep_h <= 0 or !std.math.isFinite(context.seasonal_litterfall_rate_per_h) or context.seasonal_litterfall_rate_per_h <= 0 or !std.math.isFinite(context.seasonal_litterfall_delay_threshold_h) or context.seasonal_litterfall_delay_threshold_h <= 0 or !std.math.isFinite(context.structural_presence_threshold_g_per_plant) or context.structural_presence_threshold_g_per_plant < 0 or !std.math.isFinite(context.grain_fill_detection_threshold_g_per_plant) or context.grain_fill_detection_threshold_g_per_plant < 0 or !std.math.isFinite(context.senescence_demand_tolerance_g_c) or context.senescence_demand_tolerance_g_c < 0 or !std.math.isFinite(context.leaf_area_presence_tolerance_m2) or context.leaf_area_presence_tolerance_m2 < 0) return error.ShootGrowthRuntimeDimensionMismatch;
    for (context.solar_noon_hour_by_cell) |hour| if (hour > 23) return error.ShootGrowthRuntimeDimensionMismatch;
    for (context.leaf_appearance_rate_at_25c_per_h_by_plant) |rate| if (!std.math.isFinite(rate) or rate < 0) return error.InvalidShootLeafAppearanceRate;
    _ = execution_calendar_date.fromDayOfYear(
        context.day_of_year,
        context.execution_year,
    ) catch return error.InvalidShootGrowthRuntimeDate;
    try context.senescence_recycling.validate();
    try context.node_growth_parameters.validate();
    try context.symbiosis_parameters.validate();
    try context.canopy_ammonia_parameters.validate();
    for (0..canopy.cell_count) |cell| {
        const ammonia = try surface_gas_parameters_module.atmosphericConcentrationForCell(
            context.atmospheric_concentration_g_per_m3,
            canopy.cell_count,
            cell,
            .ammonia,
        );
        if (!std.math.isFinite(ammonia) or ammonia < 0) return error.InvalidShootGrowthRuntimeAmmoniaInput;
    }
    if (!std.math.isFinite(context.ammonia_solubility_at_25_c) or context.ammonia_solubility_at_25_c <= 0) return error.InvalidShootGrowthRuntimeAmmoniaInput;
    var maximum_node_count: usize = 0;
    for (0..canopy.branch_node_offsets.len - 1) |branch| maximum_node_count = @max(maximum_node_count, canopy.branch_node_offsets[branch + 1] - canopy.branch_node_offsets[branch]);
    const recycling_nitrogen_g_n = try canopy.allocator.alloc(f64, maximum_node_count);
    defer canopy.allocator.free(recycling_nitrogen_g_n);
    const recycling_phosphorus_g_p = try canopy.allocator.alloc(f64, maximum_node_count);
    defer canopy.allocator.free(recycling_phosphorus_g_p);
    const recycling_protein_g = try canopy.allocator.alloc(f64, maximum_node_count);
    defer canopy.allocator.free(recycling_protein_g);
    const seasonal_internode_length_m = try canopy.allocator.alloc(f64, maximum_node_count);
    defer canopy.allocator.free(seasonal_internode_length_m);
    const seasonal_internode_mass = try canopy.allocator.alloc(seasonal_stalk_standing_dead_turnover.ElementMass, maximum_node_count);
    defer canopy.allocator.free(seasonal_internode_mass);
    for (range.first..range.end) |cell| for (0..canopy.species_count) |species| {
        const plant = try canopy.plantIndex(cell, species);
        if (!context.active_by_plant[plant]) continue;
        const parameters = context.plant_parameters[plant];
        const water = try canopy_module.canopyWaterGrowthResponse(
            parameters.root_profile_type == 0,
            canopy.plant_canopy_turgor_potential_megapascal[plant],
            context.phenology_parameters.minimum_turgor_potential_megapascal,
            context.canopy_total_water_potential_mpa_by_plant[plant],
            parameters.stomatal_turgor_shape_per_megapascal,
        );
        const planting_layer = context.roots.planting_layer_by_plant[plant];
        if (planting_layer >= context.soil_layer_capacity) return error.ShootGrowthPlantingLayerOutOfBounds;
        const planting_soil = cell * context.soil_layer_capacity + planting_layer;
        if (planting_soil >= context.soil_temperature_k.len) return error.ShootGrowthPlantingLayerOutOfBounds;
        const emerged = context.emerged_by_plant[plant];
        const canopy_growth_temperature = @min(1, canopy.plant_uptake_growth_temperature_response[plant]);
        const planting_root_growth_temperature = try root_uptake_module.rootGrowthTemperatureResponse(
            context.soil_temperature_k[planting_soil],
            canopy.plant_thermal_adaptation_offset_c[plant],
            context.root_growth_temperature_parameters,
        );
        const growth_temperature = if (emerged) canopy_growth_temperature else planting_root_growth_temperature;
        const maintenance_temperature_response = try metabolism_module.maintenanceTemperatureFraction(
            if (emerged) context.canopy_temperature_k_by_plant[plant] else context.soil_temperature_k[planting_soil],
            canopy.plant_thermal_adaptation_offset_c[plant],
        );
        const maintenance_temperature = if (emerged) @min(1, maintenance_temperature_response) else maintenance_temperature_response;
        const planting_root = try context.roots.layerIndex(plant, 0, planting_layer);
        const branches = try canopy.branchRange(plant);
        const main_branch = try context.growth_stages.mainLivingBranch(plant);
        // HFUNC NB1: fixed at PFT reconstruction and never reassigned by
        // grosub.f. Deliberately distinct from `main_branch` above, which
        // tracks the currently-alive lowest-order branch used for growth
        // partitioning and skips dead branches -- the main-stalk-death
        // propagation check below needs the true, possibly-dead trunk.
        const main_stalk_branch = try context.growth_stages.mainStalkBranch(plant);
        const presence_threshold_g_c = try metabolism_module.plantScaledPresenceThresholdG(
            context.structural_presence_threshold_g_per_plant,
            canopy.plant_population_count[plant],
        );
        canopy.plant_leaf_sheath_partition_fraction[plant] = 0;
        var plant_leaf_area_m2: f64 = 0;
        for (branches.first..branches.end) |branch| plant_leaf_area_m2 += canopy.branch_leaf_area_m2[branch];
        const canopy_dry_matter_fraction = try soil_exchange_module.canopyDryMatterFraction(context.canopy_total_water_potential_mpa_by_plant[plant], context.canopy_ammonia_parameters);
        for (branches.first..branches.end) |branch| {
            canopy.branch_canopy_ammonia_exchange_g_n_per_h[branch] = 0;
            if (context.carbon_exchange) |ledger| {
                if (ledger.branchCount() != canopy.branch_node_offsets.len - 1) return error.CanopyCarbonExchangeDimensionMismatch;
                ledger.shoot_respiration_g_c_per_h[branch] = 0;
                ledger.symbiont_respiration_g_c_per_h[branch] = 0;
            }
            if (context.growth_stages.branches[branch].dead or context.development.dead[branch]) continue;
            const stage = context.growth_stages.branches[branch];
            const physiological_maturity_reached = context.development.stage_day[branch * 10 + 9] != 0;
            const partition = try partition_module.calculate(context.partition_parameters, .{
                .floral_initiation_started = stage.floral_initiation_day != 0,
                .anthesis_started = stage.anthesis_day != 0,
                .grain_fill_started = stage.grain_fill_start_day != 0,
                .physiological_maturity_reached = physiological_maturity_reached,
                .determinate = parameters.determinacy_type == 0,
                .perennial = parameters.growth_habit != 0,
                .turnover_type = parameters.turnover_type,
                .leaf_phenology_type = parameters.leaf_phenology_type,
                .normalized_vegetative_stage = @max(0, stage.accumulated_vegetative_stage),
                .normalized_reproductive_stage = @max(0, stage.accumulated_reproductive_stage),
                .internode_extension_enabled = parameters.internode_extension_enabled,
                .reserve_carbon_g_c = canopy.branch_reserve_carbon_g[branch],
                .sapwood_carbon_g_c = canopy.branch_sapwood_carbon_g[branch],
                .shoot_remobilization_enabled = context.dormancy.branches[branch].shoot_remobilization_enabled,
            });
            if (main_branch != null and branch == main_branch.?)
                canopy.plant_leaf_sheath_partition_fraction[plant] = @max(0, partition.fraction[0] + partition.fraction[1]);
            const growth_nutrient_ratios = try metabolism_module.growthNutrientRatios(
                parameters.nitrogen_to_carbon_g_n_per_g_c,
                parameters.phosphorus_to_carbon_g_p_per_g_c,
            );
            // GROSUB 868--882: before emergence, both prospective shoot organs
            // take the root coefficient basis (DMLFB=DMSHB=DMRT, CNLFB=CNSHB=
            // CNRTW, CPLFB=CPSHB=CPRTW). Only after emergence do leaf and
            // petiole use their own PFT coefficients.
            const basis = try organCoefficientBasis(parameters, growth_nutrient_ratios, emerged);
            const basis_growth_yield = basis.growth_yield_g_c_per_g_c;
            const basis_nitrogen = basis.nitrogen_to_carbon_g_n_per_g_c;
            const basis_phosphorus = basis.phosphorus_to_carbon_g_p_per_g_c;
            const coefficients = try metabolism_module.coefficients(
                partition.fraction,
                basis_growth_yield,
                basis_nitrogen,
                basis_phosphorus,
                context.metabolism_parameters.minimum_leaf_nutrient_fraction,
            );
            const structural_nitrogen_g_n = try metabolism_module.structuralNitrogenForMaintenance(.{
                .leaf_nitrogen_g_n = canopy.branch_leaf_nitrogen_g[branch],
                .sheath_or_petiole_nitrogen_g_n = canopy.branch_sheath_nitrogen_g[branch],
                .sapwood_carbon_g_c = canopy.branch_sapwood_carbon_g[branch],
                .stalk_nitrogen_per_carbon_g_n_per_g_c = parameters.nitrogen_to_carbon_g_n_per_g_c[2],
                .husk_nitrogen_g_n = canopy.branch_husk_nitrogen_g[branch],
                .ear_nitrogen_g_n = canopy.branch_ear_nitrogen_g[branch],
                .grain_nitrogen_g_n = canopy.branch_grain_nitrogen_g[branch],
                .physiological_maturity_reached = physiological_maturity_reached,
            });
            const fixed_carbon_g_c = if (emerged) canopy.branch_shoot_carbohydrate_g_c_per_h[branch] * context.timestep_h else 0;
            var pre_emergence_root_state_update: ?PreEmergenceRootStateUpdate = null;
            const fluxes = if (emerged)
                try metabolism_module.calculate(context.metabolism_parameters, coefficients, .{
                    .mobile_carbon_g_c = canopy.branch_mobile_carbon_g[branch],
                    .mobile_nitrogen_g_n = canopy.branch_mobile_nitrogen_g[branch],
                    .mobile_phosphorus_g_p = canopy.branch_mobile_phosphorus_g[branch],
                    .mobile_carbon_concentration_g_c_per_g_c = canopy.branch_mobile_carbon_concentration_g_per_g[branch],
                    .mobile_nitrogen_concentration_g_n_per_g_c = canopy.branch_mobile_nitrogen_concentration_g_per_g[branch],
                    .mobile_phosphorus_concentration_g_p_per_g_c = canopy.branch_mobile_phosphorus_concentration_g_per_g[branch],
                    .structural_nitrogen_g_n = structural_nitrogen_g_n,
                    .fixed_carbon_g_c = fixed_carbon_g_c,
                    .growth_temperature_fraction = growth_temperature,
                    .maintenance_temperature_fraction = maintenance_temperature,
                    .growth_water_fraction = water.growth_fraction,
                    .maintenance_water_fraction = try metabolism_module.maintenanceWaterFraction(parameters.root_profile_type, parameters.leaf_phenology_type, water.growth_fraction),
                    .termination_fraction = canopy.branch_c3_feedback_fraction[branch],
                    .nutrient_growth_fraction = canopy.plant_nitrogen_phosphorus_fixation_constraint_fraction[plant],
                    .metabolically_active = parameters.growth_habit != 0 or !physiological_maturity_reached,
                    .timestep_h = context.timestep_h,
                })
            else blk: {
                const paired = try metabolism_module.calculatePreEmergence(context.metabolism_parameters, coefficients, .{
                    .mobile_carbon_g_c = canopy.branch_mobile_carbon_g[branch],
                    .mobile_nitrogen_g_n = canopy.branch_mobile_nitrogen_g[branch],
                    .mobile_phosphorus_g_p = canopy.branch_mobile_phosphorus_g[branch],
                    .mobile_carbon_concentration_g_c_per_g_c = canopy.branch_mobile_carbon_concentration_g_per_g[branch],
                    .mobile_nitrogen_concentration_g_n_per_g_c = canopy.branch_mobile_nitrogen_concentration_g_per_g[branch],
                    .mobile_phosphorus_concentration_g_p_per_g_c = canopy.branch_mobile_phosphorus_concentration_g_per_g[branch],
                    .structural_nitrogen_g_n = structural_nitrogen_g_n,
                    .growth_temperature_fraction = growth_temperature,
                    .maintenance_temperature_fraction = maintenance_temperature,
                    .growth_water_fraction = water.growth_fraction,
                    .maintenance_water_fraction = try metabolism_module.maintenanceWaterFraction(parameters.root_profile_type, parameters.leaf_phenology_type, water.growth_fraction),
                    .termination_fraction = canopy.branch_c3_feedback_fraction[branch],
                    .nutrient_growth_fraction = canopy.plant_nitrogen_phosphorus_fixation_constraint_fraction[plant],
                    .oxygen_limitation_fraction = std.math.clamp(context.roots.oxygen_process_constraint_fraction[planting_root], 0, 1),
                    .timestep_h = context.timestep_h,
                });
                const actual_respiration_g_c_per_h = paired.total_respiration_actual_g_c / context.timestep_h;
                const state_update: PreEmergenceRootStateUpdate = .{
                    .respiration_unlimited_by_oxygen_g_c_per_h = context.roots.respiration_unlimited_by_oxygen_g_c_per_h[planting_root] + paired.total_respiration_oxygen_unlimited_g_c / context.timestep_h,
                    .respiration_unlimited_by_carbon_g_c_per_h = context.roots.respiration_unlimited_by_carbon_g_c_per_h[planting_root] + actual_respiration_g_c_per_h,
                    .actual_respiration_g_c_per_h = context.roots.actual_respiration_g_c_per_h[planting_root] + actual_respiration_g_c_per_h,
                    .aqueous_carbon_dioxide_g_c = context.roots.aqueous_carbon_dioxide_g_c[planting_root] + paired.total_respiration_actual_g_c,
                    .aqueous_carbon_dioxide_reaction_g_c_per_h = context.roots.aqueous_carbon_dioxide_reaction_g_c_per_h[planting_root] + actual_respiration_g_c_per_h,
                };
                inline for (@typeInfo(PreEmergenceRootStateUpdate).@"struct".fields) |field| {
                    if (!std.math.isFinite(@field(state_update, field.name)) or @field(state_update, field.name) < 0)
                        return error.NonFinitePreEmergenceRootStateUpdate;
                }
                pre_emergence_root_state_update = state_update;
                break :blk metabolism_module.Fluxes{
                    .substrate_respiration_g_c = paired.substrate_respiration_actual_g_c,
                    .maintenance_respiration_g_c = paired.substrate_respiration_actual_g_c - paired.growth_respiration_actual_g_c + paired.excess_maintenance_actual_g_c,
                    .growth_respiration_g_c = paired.growth_respiration_actual_g_c,
                    .excess_maintenance_respiration_g_c = paired.excess_maintenance_actual_g_c,
                    .growth_carbon_consumption_g_c = paired.growth_carbon_consumption_actual_g_c,
                    .assimilated_nitrogen_g_n = paired.assimilated_nitrogen_actual_g_n,
                    .assimilated_phosphorus_g_p = paired.assimilated_phosphorus_actual_g_p,
                    .nitrogen_assimilation_respiration_g_c = paired.nitrogen_assimilation_respiration_actual_g_c,
                    .total_respiration_g_c = paired.total_respiration_actual_g_c,
                };
            };
            const canopy_ammonia_exchange_g_n = try soil_exchange_module.canopyAmmoniaExchangeGNPerStep(.{
                .parameters = context.canopy_ammonia_parameters,
                .atmospheric_ammonia_g_n_per_m3 = try surface_gas_parameters_module.atmosphericConcentrationForCell(
                    context.atmospheric_concentration_g_per_m3,
                    canopy.cell_count,
                    cell,
                    .ammonia,
                ),
                .canopy_temperature_c = context.canopy_temperature_k_by_plant[plant] - 273.15,
                .ammonia_solubility_at_25_c = context.ammonia_solubility_at_25_c,
                .canopy_dry_matter_fraction = canopy_dry_matter_fraction,
                .branch_mobile_nitrogen_concentration_g_n_per_g_c = canopy.branch_mobile_nitrogen_concentration_g_per_g[branch],
                .branch_mobile_nitrogen_g_n = canopy.branch_mobile_nitrogen_g[branch],
                .branch_live_structural_carbon_g_c = canopy.branch_leaf_carbon_g[branch] + canopy.branch_sheath_carbon_g[branch] + canopy.branch_stalk_carbon_g[branch],
                .branch_leaf_area_m2 = canopy.branch_leaf_area_m2[branch],
                .plant_leaf_area_m2 = plant_leaf_area_m2,
                .total_aerodynamic_resistance_h_per_m = context.total_aerodynamic_resistance_h_per_m_by_plant[plant],
                .stomatal_resistance_h_per_m = context.stomatal_resistance_h_per_m_by_plant[plant],
                .plant_radiation_fraction = context.plant_radiation_fraction[plant],
                .cell_area_m2 = context.cell_area_m2[cell],
                .timestep_h = context.timestep_h,
                .negligible_carbon_g_c = context.senescence_demand_tolerance_g_c,
            });
            canopy.branch_canopy_ammonia_exchange_g_n_per_h[branch] = canopy_ammonia_exchange_g_n / context.timestep_h;
            if (context.carbon_exchange) |ledger| ledger.shoot_respiration_g_c_per_h[branch] = fluxes.total_respiration_g_c / context.timestep_h;
            const organ_growth = try canopy_module.calculateOrganGrowth(
                fluxes.growth_carbon_consumption_g_c,
                partition.fraction,
                basis_growth_yield,
                basis_nitrogen,
                basis_phosphorus,
                context.metabolism_parameters.minimum_leaf_nutrient_fraction,
                canopy.plant_nitrogen_phosphorus_fixation_constraint_fraction[plant],
                coefficients.shoot_growth_yield_g_c_per_g_c,
            );
            var branch_organ_growth = organ_growth;
            const grain_precursor_growth: canopy_module.LeafGrowth = .{ .carbon_g = organ_growth.carbon_g[6], .nitrogen_g = organ_growth.nitrogen_g[6], .phosphorus_g = organ_growth.phosphorus_g[6] };
            if (stage.grain_fill_start_day != 0) {
                branch_organ_growth.carbon_g[6] = 0;
                branch_organ_growth.nitrogen_g[6] = 0;
                branch_organ_growth.phosphorus_g[6] = 0;
            }
            // GROSUB CCE/ETOL (grosub.f:2255-2259) is the same
            // AMIN1(CZPOLB/(CZPOLB+CCPOLB*CNKI), CPPOLB/(CPPOLB+CCPOLB*CPKI))
            // formula as CNPG, driven by nonstructural concentrations
            // (HFUNC CZPOLB/CCPOLB/CPPOLB), not raw mobile-pool masses.
            const nutrient_constraint = try metabolism_module.nutrientConstraint(
                context.metabolism_parameters,
                canopy.branch_mobile_carbon_concentration_g_per_g[branch],
                canopy.branch_mobile_nitrogen_concentration_g_per_g[branch],
                canopy.branch_mobile_phosphorus_concentration_g_per_g[branch],
            );
            const etoliation_factor = 1 + nutrient_constraint;
            const nodes = try canopy.nodeRange(branch);
            const newest_node = @min(stage.newest_growing_leaf_ordinal, nodes.end - nodes.first - 1);
            const growth_window = try @import("shoot_growing_node_window.zig").calculate(.{
                .newest_growing_node = newest_node,
                .maximum_concurrently_growing_nodes = context.development.maximum_concurrently_growing_nodes[branch],
                .runtime_node_count = nodes.end - nodes.first,
                .is_main_branch = main_branch != null and branch == main_branch.?,
                .canopy_height_m = canopy.plant_hypocotyledon_height_m[plant],
                .sowing_depth_m = context.sowing_depth_m_by_plant[plant],
            });
            const stalk_growth_window = try stalk_growing_node_window.calculate(.{
                .newest_growing_node = newest_node,
                .maximum_concurrently_growing_nodes = context.development.maximum_concurrently_growing_nodes[branch],
                .maximum_previous_nodes_in_rolling_window = context.node_growth_parameters.maximum_previous_stalk_nodes_in_rolling_window,
                .runtime_node_count = nodes.end - nodes.first,
                .emergence_date_is_set = context.development.stage_day[branch * 10] != 0,
            });
            const first_growing_node = growth_window.first_node;
            const leaf_growth: canopy_module.LeafGrowth = .{ .carbon_g = organ_growth.carbon_g[0], .nitrogen_g = organ_growth.nitrogen_g[0], .phosphorus_g = organ_growth.phosphorus_g[0] };
            const sheath_growth: canopy_module.LeafGrowth = .{ .carbon_g = organ_growth.carbon_g[1], .nitrogen_g = organ_growth.nitrogen_g[1], .phosphorus_g = organ_growth.phosphorus_g[1] };
            const stalk_growth: canopy_module.LeafGrowth = .{ .carbon_g = organ_growth.carbon_g[2], .nitrogen_g = organ_growth.nitrogen_g[2], .phosphorus_g = organ_growth.phosphorus_g[2] };
            try validateNodeGrowthTransaction(
                canopy,
                branch,
                newest_node,
                first_growing_node,
                growth_window.last_node,
                stalk_growth_window.first_node,
                stalk_growth_window.last_node,
                context.development.maximum_concurrently_growing_nodes[branch],
                leaf_growth,
                sheath_growth,
                stalk_growth,
                parameters,
                context.node_growth_parameters,
                etoliation_factor,
                water.turgor_expansion_fraction,
                context.cell_area_m2[cell],
                canopy.plant_population_per_m2[plant],
                context.stalk_volume_m3_per_g_c,
            );
            const pool_fluxes: canopy_module.BranchMobilePoolFluxes = .{
                .fixed_carbon_g = fixed_carbon_g_c,
                .maintenance_respiration_demand_g_c = fluxes.maintenance_respiration_g_c,
                .available_respirable_carbon_g_c = fluxes.substrate_respiration_g_c,
                .growth_and_respiration_g_c = fluxes.growth_carbon_consumption_g_c,
                .nitrogen_assimilation_respiration_g_c = fluxes.nitrogen_assimilation_respiration_g_c,
                .assimilated_nitrogen_g = fluxes.assimilated_nitrogen_g_n,
                .canopy_ammonia_exchange_g_n = canopy_ammonia_exchange_g_n,
                .assimilated_phosphorus_g = fluxes.assimilated_phosphorus_g_p,
            };
            const next_pools = try canopy_module.previewBranchMobilePools(canopy, branch, pool_fluxes);
            try canopy_module.validateBranchOrganGrowthTransaction(canopy, branch, branch_organ_growth);
            // All fallible arithmetic is complete: publish the branch once.
            if (pre_emergence_root_state_update) |state_update| {
                try context.accepted_internal_activity.recordCanopyToRoot(cell, planting_layer, .{
                    .carbon_g_c = fluxes.total_respiration_g_c,
                });
                context.roots.respiration_unlimited_by_oxygen_g_c_per_h[planting_root] = state_update.respiration_unlimited_by_oxygen_g_c_per_h;
                context.roots.respiration_unlimited_by_carbon_g_c_per_h[planting_root] = state_update.respiration_unlimited_by_carbon_g_c_per_h;
                context.roots.actual_respiration_g_c_per_h[planting_root] = state_update.actual_respiration_g_c_per_h;
                context.roots.aqueous_carbon_dioxide_g_c[planting_root] = state_update.aqueous_carbon_dioxide_g_c;
                context.roots.aqueous_carbon_dioxide_reaction_g_c_per_h[planting_root] = state_update.aqueous_carbon_dioxide_reaction_g_c_per_h;
                canopy.branch_shoot_carbohydrate_g_c_per_h[branch] = 0;
            }
            canopy.branch_mobile_carbon_g[branch] = next_pools.carbon_g_c;
            canopy.branch_mobile_nitrogen_g[branch] = next_pools.nitrogen_g_n;
            canopy.branch_mobile_phosphorus_g[branch] = next_pools.phosphorus_g_p;
            const remaining_excess_maintenance_g_c = try canopy_module.consumeReserveForRespiration(
                canopy,
                branch,
                context.dormancy.branches[branch].shoot_remobilization_enabled,
                fluxes.excess_maintenance_respiration_g_c,
                context.metabolism_parameters.maximum_mobile_carbon_oxidation_per_h,
                growth_temperature,
                context.timestep_h,
            );
            try canopy_module.applyBranchOrganGrowth(canopy, branch, branch_organ_growth);
            canopy_module.distributeLeafGrowth(
                canopy,
                branch,
                growth_window.last_node,
                first_growing_node,
                context.development.maximum_concurrently_growing_nodes[branch],
                leaf_growth,
                context.node_growth_parameters.protein_per_nitrogen_g_protein_per_g_n,
                context.node_growth_parameters.protein_per_phosphorus_g_protein_per_g_p,
                etoliation_factor,
                parameters.specific_leaf_area_m2_per_g_c,
                context.node_growth_parameters.minimum_leaf_carbon_g_c_per_m2_cell * context.cell_area_m2[cell],
                canopy.plant_population_per_m2[plant],
                context.node_growth_parameters.leaf_mass_exponent,
                water.turgor_expansion_fraction,
            ) catch unreachable;
            canopy_module.distributeSheathGrowth(
                canopy,
                branch,
                growth_window.last_node,
                first_growing_node,
                context.development.maximum_concurrently_growing_nodes[branch],
                sheath_growth,
                context.node_growth_parameters.protein_per_nitrogen_g_protein_per_g_n,
                context.node_growth_parameters.protein_per_phosphorus_g_protein_per_g_p,
                etoliation_factor,
                parameters.specific_sheath_length_m_per_g_c,
                context.node_growth_parameters.minimum_sheath_carbon_g_c_per_m2_cell * context.cell_area_m2[cell],
                canopy.plant_population_per_m2[plant],
                context.node_growth_parameters.sheath_mass_exponent,
                water.turgor_expansion_fraction,
                parameters.sheath_vertical_projection_fraction,
            ) catch unreachable;
            const stalk_geometry = canopy_module.distributeStalkGrowth(
                canopy,
                branch,
                stalk_growth_window.first_node,
                stalk_growth_window.last_node,
                stalk_growth,
                etoliation_factor,
                parameters.specific_internode_length_m_per_g_c,
                context.node_growth_parameters.minimum_internode_carbon_g_c_per_m2_cell * context.cell_area_m2[cell],
                canopy.plant_population_per_m2[plant],
                context.node_growth_parameters.internode_mass_exponent,
                water.turgor_expansion_fraction,
                parameters.stalk_vertical_projection_fraction,
                context.stalk_volume_m3_per_g_c,
            ) catch unreachable;
            if (main_branch != null and
                try metabolism_module.shouldRefreshStemDiameter(.{
                    .day_of_year = context.day_of_year,
                    .hour_of_day = context.hour_of_day,
                    .integer_solar_noon_hour = context.solar_noon_hour_by_cell[cell],
                    .biological_iteration = 1,
                    .branch_index = branch,
                    .main_branch_index = main_branch.?,
                    .biomass_turnover_type = parameters.turnover_type,
                    .root_profile_type = parameters.root_profile_type,
                }) and stalk_geometry.stem_diameter_m > 0)
            {
                canopy.plant_stem_diameter_m[plant] = stalk_geometry.stem_diameter_m;
            }
            const dormancy_state = context.dormancy.branches[branch];
            const recycling = try senescenceRecyclingFractionsForPlant(
                context.emerged_by_plant[plant],
                parameters,
                .{
                    .mobile_carbon_g_c_per_g_c = canopy.branch_mobile_carbon_concentration_g_per_g[branch],
                    .mobile_nitrogen_g_n_per_g_c = canopy.branch_mobile_nitrogen_concentration_g_per_g[branch],
                    .mobile_phosphorus_g_p_per_g_c = canopy.branch_mobile_phosphorus_concentration_g_per_g[branch],
                },
                .{
                    .nitrogen_g_n_per_g_c = context.metabolism_parameters.mobile_nitrogen_inhibition_g_n_per_g_c,
                    .phosphorus_g_p_per_g_c = context.metabolism_parameters.mobile_phosphorus_inhibition_g_p_per_g_c,
                },
                &context.senescence_recycling,
            );
            const litter_parameters = try senescenceLitterParameters(context, plant, branch);
            _ = try canopy_module.state_updateSelectedNodeSenescence(
                canopy,
                branch,
                .{
                    .lowest_node_remobilization_enabled = stage.lowest_node_nutrient_remobilization_enabled,
                    .refresh_snapshot = stage.new_leaf_remobilization_enabled,
                    .newest_node_within_branch = newest_node,
                    .requested_remobilization_fraction = growth_temperature * context.leaf_appearance_rate_at_25c_per_h_by_plant[plant] * context.timestep_h,
                    .structural_presence_threshold_g_c = presence_threshold_g_c,
                },
                recycling,
                context.node_growth_parameters.protein_per_nitrogen_g_protein_per_g_n,
                context.node_growth_parameters.protein_per_phosphorus_g_protein_per_g_p,
                litter_parameters,
                &context.senescence_products_by_plant[plant],
            );
            const senescence_demand = try canopy_module.senescenceDemand(
                dormancy_state.shoot_remobilization_enabled,
                dormancy_state.phenological_remobilization_enabled,
                parameters.growth_habit != 0,
                plant_leaf_area_m2,
                context.cell_area_m2[cell],
                context.node_growth_parameters.leaf_storage_exchange_fraction_per_h_by_turnover[@min(@as(usize, parameters.turnover_type), 5)],
                canopy.branch_leaf_carbon_g[branch] + canopy.branch_sheath_carbon_g[branch],
                dormancy_state.remobilization_elapsed_h,
                context.dormancy_parameters_by_plant[plant].full_senescence_duration_h,
                context.timestep_h,
                remaining_excess_maintenance_g_c,
                newest_node,
                0,
            );
            var remaining_senescence_respiration_g_c: f64 = 0;
            if (senescence_demand.total_respiration_g_c > context.senescence_demand_tolerance_g_c) {
                const senescence = try canopy_module.state_updateBranchSenescenceDemand(
                    canopy,
                    branch,
                    .{
                        .total_respiration_demand_g_c = senescence_demand.total_respiration_g_c,
                        .phenological_senescence_fraction = senescence_demand.phenological_fraction,
                        .first_node_within_branch = senescence_demand.first_preceding_node,
                        .last_node_within_branch = newest_node,
                        .node_group_count = senescence_demand.node_group_count,
                        .perennial = parameters.growth_habit != 0,
                        .leaf_presence_threshold_g_c = presence_threshold_g_c,
                        .demand_tolerance_g_c = context.senescence_demand_tolerance_g_c,
                    },
                    recycling,
                    context.node_growth_parameters.protein_per_nitrogen_g_protein_per_g_n,
                    context.node_growth_parameters.protein_per_phosphorus_g_protein_per_g_p,
                    litter_parameters,
                );
                canopy_module.addSenescenceProducts(&context.senescence_products_by_plant[plant], senescence.products);
                remaining_senescence_respiration_g_c = senescence.remaining_respiration_demand_g_c;
            }
            const branch_died = try state_updateSenescenceStorageBackstop(
                canopy,
                context.growth_stages,
                context.development,
                context.dormancy,
                plant,
                branch,
                remaining_senescence_respiration_g_c,
                parameters.growth_habit != 0,
                parameters.leaf_phenology_type == 0,
                context.dormancy_parameters_by_plant[plant].required_leafoff_h,
                context.senescence_demand_tolerance_g_c,
            );
            _ = branch_died;
            if (main_stalk_branch) |stalk| {
                if (main_stalk_death_propagation.shouldPropagate(
                    parameters.turnover_type != 0,
                    parameters.root_profile_type > 1,
                    context.growth_stages.branches[stalk].dead or context.development.dead[stalk],
                )) {
                    context.growth_stages.branches[branch].dead = true;
                    context.development.dead[branch] = true;
                }
            }
            const first_recycling_node = newest_node -| 24;
            try leaf_structural_nutrient_recycling.apply(.{
                .leaf_carbon_g_c = canopy.node_leaf_carbon_g[nodes.first..nodes.end],
                .leaf_nitrogen_g_n = canopy.node_leaf_nitrogen_g[nodes.first..nodes.end],
                .leaf_phosphorus_g_p = canopy.node_leaf_phosphorus_g[nodes.first..nodes.end],
                .leaf_protein_g = canopy.node_leaf_protein_g[nodes.first..nodes.end],
                .branch_leaf_nitrogen_g_n = &canopy.branch_leaf_nitrogen_g[branch],
                .branch_leaf_phosphorus_g_p = &canopy.branch_leaf_phosphorus_g[branch],
                .mobile_carbon_g_c = canopy.branch_mobile_carbon_g[branch],
                .mobile_nitrogen_g_n = &canopy.branch_mobile_nitrogen_g[branch],
                .mobile_phosphorus_g_p = &canopy.branch_mobile_phosphorus_g[branch],
            }, .{
                .nitrogen_g_n = recycling_nitrogen_g_n,
                .phosphorus_g_p = recycling_phosphorus_g_p,
                .protein_g = recycling_protein_g,
            }, .{
                .first_node = first_recycling_node,
                .end_node = newest_node + 1,
                .carbon_pool_threshold_g_c = presence_threshold_g_c,
                .minimum_relative_leaf_nutrient_fraction = context.metabolism_parameters.minimum_leaf_nutrient_fraction,
                .maximum_leaf_nitrogen_per_carbon_g_n_per_g_c = parameters.nitrogen_to_carbon_g_n_per_g_c[0],
                .maximum_leaf_phosphorus_per_carbon_g_p_per_g_c = parameters.phosphorus_to_carbon_g_p_per_g_c[0],
                .protein_per_nitrogen_g_per_g_n = context.node_growth_parameters.protein_per_nitrogen_g_protein_per_g_n,
                .protein_per_phosphorus_g_per_g_p = context.node_growth_parameters.protein_per_phosphorus_g_protein_per_g_p,
            });
            const seasonal_turnover_admitted = try state_updateExactSeasonalTurnover(context, plant, branch, parameters, .{
                .internode_length_m = seasonal_internode_length_m,
                .internode_mass = seasonal_internode_mass,
            });
            if (seasonal_turnover_admitted and main_branch != null and branch == main_branch.?) {
                if (context.seasonal_turnover_event_by_plant) |events| events[plant] = true;
            }
            const grain_fill = try canopy_module.fillGrainFromReserve(
                canopy,
                branch,
                stage.grain_fill_start_day != 0,
                canopy.branch_seed_count[branch],
                parameters.maximum_individual_seed_carbon_g,
                parameters.grain_fill_g_c_per_seed_h_25c,
                try metabolism_module.grainFillTemperatureResponse(
                    parameters.root_profile_type,
                    canopy_growth_temperature,
                    planting_root_growth_temperature,
                ),
                context.timestep_h,
                context.node_growth_parameters.minimum_grain_nutrient_fraction,
                parameters.nitrogen_to_carbon_g_n_per_g_c[6],
                parameters.phosphorus_to_carbon_g_p_per_g_c[6],
                context.node_growth_parameters.reserve_nitrogen_half_saturation_g_n_per_g_c,
                context.node_growth_parameters.reserve_phosphorus_half_saturation_g_p_per_g_c,
                grain_precursor_growth,
            );
            if (stage.seed_number_set_end_day != 0) {
                const detection_threshold_g_c = context.grain_fill_detection_threshold_g_per_plant * canopy.plant_population_count[plant];
                context.development.hours_without_grain_fill[branch] = if (grain_fill.carbon_translocated_g <= detection_threshold_g_c)
                    context.development.hours_without_grain_fill[branch] + context.timestep_h
                else
                    0;
                if (context.development.hours_without_grain_fill[branch] >= context.node_growth_parameters.physiological_maturity_no_fill_h and context.development.stage_day[branch * 10 + 9] == 0)
                    context.development.stage_day[branch * 10 + 9] = context.day_of_year;
                if (try metabolism_module.shouldForceAnnualLeafoff(
                    parameters.growth_habit,
                    parameters.leaf_phenology_type,
                    context.development.hours_without_grain_fill[branch],
                    context.node_growth_parameters.physiological_maturity_no_fill_h,
                    context.node_growth_parameters.annual_leafoff_delay_h_by_phenology,
                )) {
                    context.dormancy.branches[branch].accumulated_leafoff_h =
                        context.dormancy_parameters_by_plant[plant].required_leafoff_h + 0.5;
                }
            }
            try advanceCanopySymbiosis(
                context,
                cell,
                plant,
                branch,
                parameters,
                growth_temperature,
                maintenance_temperature,
                water,
                physiological_maturity_reached,
            );
        }
        const growth_habit: usize = if (context.plant_parameters[plant].growth_habit == 0) 0 else 1;
        try equilibratePlantBranchMobilePools(canopy, context.growth_stages, context.development, branches, context.storage_remobilization_duration_h_by_growth_habit[growth_habit], context.branch_mobile_exchange_parameters, context.timestep_h, presence_threshold_g_c);
        try equilibratePlantBranchReserves(canopy, branches, main_branch, context.node_growth_parameters, context.timestep_h, presence_threshold_g_c);
    };
}

test "live C3 branch state_updates mobile pools and organ growth atomically" {
    var canopy = try canopy_module.State.init(std.testing.allocator, 1, 1, &.{1}, &.{3}, &.{ 0, 0, 0 });
    defer canopy.deinit();
    canopy.plant_uptake_growth_temperature_response[0] = 1;
    var stages = try stages_module.State.init(std.testing.allocator, &.{1});
    defer stages.deinit();
    var dormancy = try dormancy_module.RuntimeState.init(std.testing.allocator, 1);
    defer dormancy.deinit();
    var development = try development_module.BranchDevelopmentState.init(std.testing.allocator, 1);
    defer development.deinit();
    var litter_partition = try litter_partition_module.State.init(std.testing.allocator, 1);
    defer litter_partition.deinit();
    var litter_traits = std.mem.zeroes(traits_module.PlantTraits);
    litter_traits.functional_type.root_profile_type = 1;
    try litter_partition.initializePlant(0, litter_traits, @import("../initialization/seed_and_population.zig").compatibilityStandingDeadPartitionParameters());
    var senescence_products = [_]canopy_module.SenescenceProducts{.{}};
    var carbon_exchange = try CarbonExchange.init(std.testing.allocator, 1);
    defer carbon_exchange.deinit();
    var roots = try root_system_module.State.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    const dormancy_parameters = [_]dormancy_module.Parameters{.{
        .required_leafout_h = 2,
        .required_leafoff_h = 2,
        .leafout_temperature_threshold_c = 5,
        .leafoff_temperature_threshold_c = 0,
        .chilling_temperature_c = -5,
        .drought_leafout_total_water_potential_megapascal = -0.1,
        .combined_leafout_turgor_potential_megapascal = 0.1,
        .leafoff_total_water_potential_megapascal = -1.5,
        .drought_leafoff_total_water_potential_megapascal = -2.0,
        .maximum_photoperiod_counter_h = 3600,
        .evergreen_leafoff_remobilization_start_fraction = 0.75,
        .deciduous_leafoff_remobilization_start_fraction = 0.5,
        .full_senescence_duration_h = 480,
    }};
    stages.branches[0].newest_growing_leaf_ordinal = 2;
    stages.branches[0].floral_initiation_day = 1;
    stages.branches[0].accumulated_vegetative_stage = 0.5;
    canopy.branch_mobile_carbon_g[0] = 100;
    canopy.branch_mobile_nitrogen_g[0] = 10;
    canopy.branch_mobile_phosphorus_g[0] = 1;
    canopy.branch_mobile_carbon_concentration_g_per_g[0] = 0.05;
    canopy.branch_mobile_nitrogen_concentration_g_per_g[0] = 0.05;
    canopy.branch_mobile_phosphorus_concentration_g_per_g[0] = 0.01;
    canopy.branch_fixed_carbon_g_c_per_h[0] = 1;
    canopy.branch_shoot_carbohydrate_g_c_per_h[0] = 1;
    canopy.branch_c3_feedback_fraction[0] = 1;
    canopy.plant_population_per_m2[0] = 10;
    canopy.plant_canopy_turgor_potential_megapascal[0] = 0.5;
    canopy.plant_nitrogen_phosphorus_fixation_constraint_fraction[0] = 1;
    const plant_parameters = PlantParameters{
        .photosynthesis_pathway = 3,
        .growth_habit = 0,
        .determinacy_type = 0,
        .turnover_type = 0,
        .root_profile_type = 1,
        .nitrogen_fixation_type = 0,
        .internode_extension_enabled = true,
        .stomatal_turgor_shape_per_megapascal = 1,
        .specific_leaf_area_m2_per_g_c = 0.02,
        .specific_sheath_length_m_per_g_c = 0.4,
        .specific_internode_length_m_per_g_c = 0.5,
        .sheath_vertical_projection_fraction = 0.8,
        .stalk_vertical_projection_fraction = 0.9,
        .maximum_individual_seed_carbon_g = 0.5,
        .grain_fill_g_c_per_seed_h_25c = 0.01,
        .symbiont_growth_yield_g_c_per_g_c = 0.4,
        .symbiont_nitrogen_to_carbon_g_n_per_g_c = 0.1,
        .symbiont_phosphorus_to_carbon_g_p_per_g_c = 0.02,
        .growth_yield_g_c_per_g_c = @splat(0.8),
        .nitrogen_to_carbon_g_n_per_g_c = @splat(0.04),
        .phosphorus_to_carbon_g_p_per_g_c = @splat(0.004),
        .root_growth_yield_g_c_per_g_c = 0.6,
        .root_nitrogen_to_carbon_g_n_per_g_c = 0.03,
        .root_phosphorus_to_carbon_g_p_per_g_c = 0.003,
    };
    var plant_parameter_values = [_]PlantParameters{plant_parameters};
    var active = [_]bool{true};
    var emerged = [_]bool{true};
    var leaf_appearance_rate_at_25c_per_h = [_]f64{0.02};
    var sowing_depth_m = [_]f64{0.03};
    var temperature_k = [_]f64{298.15};
    var water_potential_megapascal = [_]f64{-0.1};
    var aerodynamic_resistance_h_per_m = [_]f64{0.01};
    var stomatal_resistance_h_per_m = [_]f64{0.02};
    var radiation_fraction = [_]f64{0.5};
    var cell_area_m2 = [_]f64{100};
    var solar_noon_hour = [_]u8{12};
    var fire_active_this_hour = [_]bool{false};
    var symbiotic_inoculum_input_by_cell = [_]symbiosis_module.Pool{.{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 }};
    var accepted_internal_activity = try InternalRootShootActivity.State.init(std.testing.allocator, 1, 1);
    defer accepted_internal_activity.deinit();
    development.maximum_concurrently_growing_nodes[0] = 2;
    var context: ApplyContext = .{
        .canopy = &canopy,
        .growth_stages = &stages,
        .dormancy = &dormancy,
        .development = &development,
        .plant_parameters = &plant_parameter_values,
        .active_by_plant = &active,
        .emerged_by_plant = &emerged,
        .leaf_appearance_rate_at_25c_per_h_by_plant = &leaf_appearance_rate_at_25c_per_h,
        .sowing_depth_m_by_plant = &sowing_depth_m,
        .roots = &roots,
        .soil_temperature_k = &temperature_k,
        .soil_layer_capacity = 1,
        .root_growth_temperature_parameters = growth_temperature_module.compatibilityParameters(),
        .canopy_temperature_k_by_plant = &temperature_k,
        .canopy_total_water_potential_mpa_by_plant = &water_potential_megapascal,
        .total_aerodynamic_resistance_h_per_m_by_plant = &aerodynamic_resistance_h_per_m,
        .stomatal_resistance_h_per_m_by_plant = &stomatal_resistance_h_per_m,
        .plant_radiation_fraction = &radiation_fraction,
        .atmospheric_concentration_g_per_m3 = &.{ 0, 0, 0, 0, 0, 0, 0 },
        .ammonia_solubility_at_25_c = 285.2,
        .canopy_ammonia_parameters = soil_exchange_module.compatibilityCanopyAmmoniaExchangeParameters(),
        .partition_parameters = partition_module.compatibilityParameters(),
        .metabolism_parameters = metabolism_module.compatibilityParameters(),
        .phenology_parameters = development_module.compatibilityParameters(),
        .node_growth_parameters = sourceNodeGrowthParameters(),
        .branch_mobile_exchange_parameters = sourceBranchMobileExchangeParameters(),
        .storage_remobilization_duration_h_by_growth_habit = .{ 45.8, 138.4 },
        .cell_area_m2 = &cell_area_m2,
        .stalk_volume_m3_per_g_c = 4.0e-6,
        .structural_presence_threshold_g_per_plant = 1.0e-12,
        .grain_fill_detection_threshold_g_per_plant = 1.0e-12,
        .day_of_year = 150,
        .hour_of_day = 12,
        .solar_noon_hour_by_cell = &solar_noon_hour,
        .execution_year = 2000,
        .timestep_h = 1,
        .seasonal_litterfall_rate_per_h = 2.884e-3,
        .seasonal_litterfall_delay_threshold_h = 240,
        .dormancy_parameters_by_plant = &dormancy_parameters,
        .litter_partition = &litter_partition,
        .senescence_recycling = sourceSenescenceRecyclingParameters(),
        .senescence_products_by_plant = &senescence_products,
        .senescence_demand_tolerance_g_c = 1.0e-12,
        .leaf_area_presence_tolerance_m2 = 1.0e-12,
        .symbiosis_parameters = symbiosis_module.sourceRuntimeParameters(),
        .fire_active_this_hour = &fire_active_this_hour,
        .symbiotic_inoculum_input_by_cell = &symbiotic_inoculum_input_by_cell,
        .carbon_exchange = &carbon_exchange,
        .accepted_internal_activity = &accepted_internal_activity,
    };
    var seasonal_lengths: [3]f64 = undefined;
    var seasonal_masses: [3]seasonal_stalk_standing_dead_turnover.ElementMass = undefined;
    const seasonal_workspace: SeasonalTurnoverWorkspace = .{ .internode_length_m = &seasonal_lengths, .internode_mass = &seasonal_masses };

    // The entry IFLGR gate admits the threshold hour, then clears IFLGR/FLGQ
    // while both reproductive and perennial stalk turnover still state_update.
    plant_parameter_values[0].growth_habit = 1;
    plant_parameter_values[0].leaf_phenology_type = 1;
    context.seasonal_litterfall_rate_per_h = 0.25;
    context.seasonal_litterfall_delay_threshold_h = 240;
    dormancy.branches[0].reproductive_growth_disabled = true;
    dormancy.branches[0].reproductive_litterfall_delay_h = 239;
    canopy.branch_husk_carbon_g[0] = 2;
    canopy.branch_husk_nitrogen_g[0] = 0.2;
    canopy.branch_husk_phosphorus_g[0] = 0.02;
    canopy.branch_ear_carbon_g[0] = 2;
    canopy.branch_ear_nitrogen_g[0] = 0.2;
    canopy.branch_ear_phosphorus_g[0] = 0.02;
    canopy.branch_grain_carbon_g[0] = 4;
    canopy.branch_grain_nitrogen_g[0] = 0.4;
    canopy.branch_grain_phosphorus_g[0] = 0.04;
    canopy.branch_stalk_carbon_g[0] = 8;
    canopy.branch_stalk_nitrogen_g[0] = 0.8;
    canopy.branch_stalk_phosphorus_g[0] = 0.08;
    const seasonal_carbon_before = canopy.branch_husk_carbon_g[0] + canopy.branch_ear_carbon_g[0] + canopy.branch_grain_carbon_g[0] + canopy.branch_stalk_carbon_g[0];
    const seasonal_nitrogen_before = canopy.branch_husk_nitrogen_g[0] + canopy.branch_ear_nitrogen_g[0] + canopy.branch_grain_nitrogen_g[0] + canopy.branch_stalk_nitrogen_g[0];
    const seasonal_phosphorus_before = canopy.branch_husk_phosphorus_g[0] + canopy.branch_ear_phosphorus_g[0] + canopy.branch_grain_phosphorus_g[0] + canopy.branch_stalk_phosphorus_g[0];
    try std.testing.expect(try state_updateExactSeasonalTurnover(&context, 0, 0, plant_parameter_values[0], seasonal_workspace));
    var seasonal_litter_carbon: f64 = 0;
    var seasonal_litter_nitrogen: f64 = 0;
    var seasonal_litter_phosphorus: f64 = 0;
    for (senescence_products[0].nonwoody_carbon_g) |value| seasonal_litter_carbon += value;
    for (senescence_products[0].nonwoody_nitrogen_g) |value| seasonal_litter_nitrogen += value;
    for (senescence_products[0].nonwoody_phosphorus_g) |value| seasonal_litter_phosphorus += value;
    try std.testing.expect(!dormancy.branches[0].reproductive_growth_disabled);
    try std.testing.expectEqual(@as(f64, 0), dormancy.branches[0].reproductive_litterfall_delay_h);
    try std.testing.expectApproxEqAbs(seasonal_carbon_before, canopy.branch_husk_carbon_g[0] + canopy.branch_ear_carbon_g[0] + canopy.branch_grain_carbon_g[0] + canopy.branch_stalk_carbon_g[0] + seasonal_litter_carbon + canopy.plant_standing_dead_carbon_g[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(seasonal_nitrogen_before, canopy.branch_husk_nitrogen_g[0] + canopy.branch_ear_nitrogen_g[0] + canopy.branch_grain_nitrogen_g[0] + canopy.branch_stalk_nitrogen_g[0] + seasonal_litter_nitrogen + canopy.plant_standing_dead_nitrogen_g[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(seasonal_phosphorus_before, canopy.branch_husk_phosphorus_g[0] + canopy.branch_ear_phosphorus_g[0] + canopy.branch_grain_phosphorus_g[0] + canopy.branch_stalk_phosphorus_g[0] + seasonal_litter_phosphorus + canopy.plant_standing_dead_phosphorus_g[0], 1.0e-12);

    // A leafoff threshold opens IFLGR and performs turnover in the same call.
    dormancy.branches[0].leafout_disabled = true;
    dormancy.branches[0].leafoff_disabled = false;
    dormancy.branches[0].accumulated_leafoff_h = 2;
    dormancy.branches[0].reproductive_growth_disabled = false;
    canopy.branch_husk_carbon_g[0] = 1;
    try std.testing.expect(try state_updateExactSeasonalTurnover(&context, 0, 0, plant_parameter_values[0], seasonal_workspace));
    try std.testing.expect(dormancy.branches[0].reproductive_growth_disabled);
    try std.testing.expectEqual(@as(f64, 1), dormancy.branches[0].reproductive_litterfall_delay_h);

    // A late stalk-destination failure leaves the staged reproductive and
    // persistent flag transaction untouched.
    dormancy.branches[0].leafoff_disabled = true;
    dormancy.branches[0].reproductive_growth_disabled = true;
    dormancy.branches[0].reproductive_litterfall_delay_h = 10;
    canopy.branch_husk_carbon_g[0] = 1;
    const husk_before_failure = canopy.branch_husk_carbon_g[0];
    const flag_before_failure = dormancy.branches[0];
    canopy.plant_standing_dead_phosphorus_by_kinetic_g[3] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidSeasonalStalkTurnoverState, state_updateExactSeasonalTurnover(&context, 0, 0, plant_parameter_values[0], seasonal_workspace));
    try std.testing.expectEqual(husk_before_failure, canopy.branch_husk_carbon_g[0]);
    try std.testing.expectEqualDeep(flag_before_failure, dormancy.branches[0]);

    // Restore the general live-growth fixture after the focused transactions.
    canopy.plant_standing_dead_phosphorus_by_kinetic_g[3] = 0;
    canopy.plant_standing_dead_carbon_g[0] = 0;
    canopy.plant_standing_dead_nitrogen_g[0] = 0;
    canopy.plant_standing_dead_phosphorus_g[0] = 0;
    @memset(canopy.plant_standing_dead_carbon_by_kinetic_g, 0);
    @memset(canopy.plant_standing_dead_nitrogen_by_kinetic_g, 0);
    @memset(canopy.plant_standing_dead_phosphorus_by_kinetic_g, 0);
    @memset(senescence_products[0].nonwoody_carbon_g[0..], 0);
    @memset(senescence_products[0].nonwoody_nitrogen_g[0..], 0);
    @memset(senescence_products[0].nonwoody_phosphorus_g[0..], 0);
    canopy.branch_husk_carbon_g[0] = 0;
    canopy.branch_husk_nitrogen_g[0] = 0;
    canopy.branch_husk_phosphorus_g[0] = 0;
    canopy.branch_ear_carbon_g[0] = 0;
    canopy.branch_ear_nitrogen_g[0] = 0;
    canopy.branch_ear_phosphorus_g[0] = 0;
    canopy.branch_grain_carbon_g[0] = 0;
    canopy.branch_grain_nitrogen_g[0] = 0;
    canopy.branch_grain_phosphorus_g[0] = 0;
    canopy.branch_stalk_carbon_g[0] = 0;
    canopy.branch_stalk_nitrogen_g[0] = 0;
    canopy.branch_stalk_phosphorus_g[0] = 0;
    dormancy.branches[0] = .{};
    plant_parameter_values[0] = plant_parameters;
    context.seasonal_litterfall_rate_per_h = 2.884e-3;
    active[0] = false;
    context.day_of_year = 366;
    context.execution_year = 1900;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const mobile_carbon_before_invalid_date = canopy.branch_mobile_carbon_g[0];
    context.execution_year = 1901;
    try std.testing.expectError(
        error.InvalidShootGrowthRuntimeDate,
        applyTile(&context, .{ .first = 0, .end = 1 }),
    );
    try std.testing.expectEqual(
        mobile_carbon_before_invalid_date,
        canopy.branch_mobile_carbon_g[0],
    );
    active[0] = true;
    context.day_of_year = 150;
    context.execution_year = 2000;
    emerged[0] = false;
    roots.oxygen_process_constraint_fraction[0] = 0.5;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(roots.respiration_unlimited_by_oxygen_g_c_per_h[0] > 0);
    try std.testing.expect(roots.respiration_unlimited_by_carbon_g_c_per_h[0] > 0);
    try std.testing.expectEqual(
        roots.respiration_unlimited_by_carbon_g_c_per_h[0],
        roots.actual_respiration_g_c_per_h[0],
    );
    try std.testing.expect(roots.respiration_unlimited_by_oxygen_g_c_per_h[0] >= roots.actual_respiration_g_c_per_h[0]);
    try std.testing.expectEqual(roots.actual_respiration_g_c_per_h[0], roots.aqueous_carbon_dioxide_g_c[0]);
    try std.testing.expectEqual(roots.actual_respiration_g_c_per_h[0], roots.aqueous_carbon_dioxide_reaction_g_c_per_h[0]);
    try std.testing.expectEqual(
        roots.actual_respiration_g_c_per_h[0],
        accepted_internal_activity.canopy_to_root[0].carbon_g_c,
    );
    try std.testing.expectEqual(@as(f64, 0), canopy.branch_shoot_carbohydrate_g_c_per_h[0]);
    emerged[0] = true;
    canopy.branch_shoot_carbohydrate_g_c_per_h[0] = 1;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(canopy.branch_leaf_carbon_g[0] > 0);
    try std.testing.expect(canopy.branch_sheath_carbon_g[0] > 0);
    try std.testing.expect(canopy.branch_mobile_carbon_g[0] < 101);
    try std.testing.expect(canopy.branch_mobile_nitrogen_g[0] < 10);
    try std.testing.expect(canopy.branch_mobile_phosphorus_g[0] < 1);
    try std.testing.expect(carbon_exchange.shoot_respiration_g_c_per_h[0] > 0);
    try std.testing.expectApproxEqAbs(canopy.branch_leaf_carbon_g[0], canopy.node_leaf_carbon_g[1] + canopy.node_leaf_carbon_g[2], 1.0e-15);
    try std.testing.expectApproxEqAbs(canopy.branch_sheath_carbon_g[0], canopy.node_sheath_carbon_g[1] + canopy.node_sheath_carbon_g[2], 1.0e-15);
    try std.testing.expectApproxEqAbs(canopy.branch_leaf_nitrogen_g[0], canopy.node_leaf_nitrogen_g[1] + canopy.node_leaf_nitrogen_g[2], 1.0e-15);
    try std.testing.expectApproxEqAbs(canopy.branch_leaf_phosphorus_g[0], canopy.node_leaf_phosphorus_g[1] + canopy.node_leaf_phosphorus_g[2], 1.0e-15);
    try std.testing.expectEqual(canopy.node_leaf_carbon_g[1], canopy.node_leaf_carbon_g[2]);
    try std.testing.expectEqual(canopy.node_sheath_carbon_g[1], canopy.node_sheath_carbon_g[2]);
    try std.testing.expectEqual(canopy.node_internode_carbon_g[1], canopy.node_internode_carbon_g[2]);
    try std.testing.expect(canopy.node_internode_carbon_g[1] > 0);
    try std.testing.expect(canopy.node_leaf_area_m2[1] > 0);

    stages.branches[0].grain_fill_start_day = 140;
    stages.branches[0].seed_number_set_end_day = 145;
    canopy.branch_seed_count[0] = 10;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(canopy.branch_grain_carbon_g[0] > 0);
    try std.testing.expectEqual(@as(f64, 0), development.hours_without_grain_fill[0]);
    canopy.branch_seed_count[0] = 0;
    context.node_growth_parameters.physiological_maturity_no_fill_h = 1;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 1), development.hours_without_grain_fill[0]);
    try std.testing.expectEqual(@as(u32, 150), development.stage_day[9]);

    development.stage_day[9] = 0;
    canopy.branch_mobile_carbon_g[0] = 0;
    canopy.branch_reserve_carbon_g[0] = 0;
    canopy.branch_shoot_carbohydrate_g_c_per_h[0] = 0;
    const leaf_before_senescence_g_c = canopy.branch_leaf_carbon_g[0];
    try applyTile(&context, .{ .first = 0, .end = 1 });
    var litter_carbon_g_c: f64 = 0;
    for (senescence_products[0].woody_carbon_g, senescence_products[0].nonwoody_carbon_g) |woody, nonwoody| litter_carbon_g_c += woody + nonwoody;
    try std.testing.expect(canopy.branch_leaf_carbon_g[0] < leaf_before_senescence_g_c);
    try std.testing.expect(litter_carbon_g_c > 0);

    plant_parameter_values[0].nitrogen_fixation_type = 4;
    development.stage_day[9] = 0;
    stages.branches[0].seed_number_set_end_day = 0;
    canopy.branch_mobile_carbon_g[0] = 10;
    canopy.branch_mobile_nitrogen_g[0] = 1;
    canopy.branch_mobile_phosphorus_g[0] = 0.1;
    canopy.branch_shoot_carbohydrate_g_c_per_h[0] = 1;
    fire_active_this_hour[0] = true;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 0), canopy.branch_symbiont_structural_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), symbiotic_inoculum_input_by_cell[0].carbon_g_c);
    fire_active_this_hour[0] = false;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(canopy.branch_symbiont_structural_carbon_g[0] > 0);
    try std.testing.expect(canopy.branch_symbiont_mobile_carbon_g[0] > 0);
    try std.testing.expectEqual(@as(f64, 0.01), symbiotic_inoculum_input_by_cell[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0.001), symbiotic_inoculum_input_by_cell[0].nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 0.0002), symbiotic_inoculum_input_by_cell[0].phosphorus_g_p);
    canopy.branch_symbiont_structural_nitrogen_g[0] = 0.5 * canopy.branch_symbiont_structural_carbon_g[0] * plant_parameter_values[0].symbiont_nitrogen_to_carbon_g_n_per_g_c;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(canopy.branch_symbiotic_fixed_nitrogen_g_n_per_h[0] > 0);
}

test "live plant postprocess conserves pairwise branch reserve C N P" {
    var canopy = try canopy_module.State.init(std.testing.allocator, 1, 1, &.{3}, &.{ 1, 1, 1 }, &.{ 0, 0, 0 });
    defer canopy.deinit();
    canopy.plant_uptake_growth_temperature_response[0] = 1;
    canopy.branch_sapwood_carbon_g[0] = 1;
    canopy.branch_sapwood_carbon_g[1] = 2;
    canopy.branch_sapwood_carbon_g[2] = 1;
    canopy.branch_reserve_carbon_g[1] = 10;
    canopy.branch_reserve_carbon_g[2] = 4;
    canopy.branch_reserve_nitrogen_g[1] = 1;
    canopy.branch_reserve_nitrogen_g[2] = 0.4;
    canopy.branch_reserve_phosphorus_g[1] = 0.1;
    canopy.branch_reserve_phosphorus_g[2] = 0.04;
    const before_c = canopy.branch_reserve_carbon_g[0] + canopy.branch_reserve_carbon_g[1] + canopy.branch_reserve_carbon_g[2];
    const before_n = canopy.branch_reserve_nitrogen_g[0] + canopy.branch_reserve_nitrogen_g[1] + canopy.branch_reserve_nitrogen_g[2];
    const before_p = canopy.branch_reserve_phosphorus_g[0] + canopy.branch_reserve_phosphorus_g[1] + canopy.branch_reserve_phosphorus_g[2];
    try equilibratePlantBranchReserves(&canopy, try canopy.branchRange(0), 1, sourceNodeGrowthParameters(), 1, 0);
    try std.testing.expectApproxEqAbs(before_c, canopy.branch_reserve_carbon_g[0] + canopy.branch_reserve_carbon_g[1] + canopy.branch_reserve_carbon_g[2], 1.0e-15);
    try std.testing.expectApproxEqAbs(before_n, canopy.branch_reserve_nitrogen_g[0] + canopy.branch_reserve_nitrogen_g[1] + canopy.branch_reserve_nitrogen_g[2], 1.0e-15);
    try std.testing.expectApproxEqAbs(before_p, canopy.branch_reserve_phosphorus_g[0] + canopy.branch_reserve_phosphorus_g[1] + canopy.branch_reserve_phosphorus_g[2], 1.0e-15);
    try std.testing.expect(canopy.branch_reserve_carbon_g[0] > 0);
}

test {
    // Keeps the extracted tests discoverable by `zig build test`,
    // which only reaches files reachable by import.
    _ = @import("../../validation/shoot_growth_runtime_test.zig");
}
