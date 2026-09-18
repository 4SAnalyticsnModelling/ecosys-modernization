const std = @import("std");
const anaerobic = @import("anaerobic_growth_respiration.zig");

pub const AcetotrophicInputs = struct {
    soil_temperature_k: f64,
    aqueous_acetate_concentration_g_c_per_m3: f64,
    aqueous_acetate_g_c: f64,
    acetate_competition_fraction: f64,
    nutrient_limitation_fraction: f64,
    water_stress_fraction: f64,
    temperature_response: f64,
    active_biomass_g_c: f64,
    timestep_h: f64,
};

pub const AcetotrophicParameters = struct {
    acetate_inhibition_concentration_g_c_per_m3: f64,
    acetate_half_saturation_g_c_per_m3: f64,
    specific_respiration_per_h: f64,
    reference_energy_yield_kj_per_g_c: f64,
    growth_energy_requirement_kj_per_g_c: f64,
    minimum_growth_respiration_fraction: f64,
    /// Source `NITRO.F` 1002 divisor `GOMM=GOMX/24.0`, gram carbon per mole.
    /// Defaults to the source value so existing callers are unchanged.
    feedback_carbon_basis_g_c_per_mol: f64 =
        anaerobic.source_carbon_basis.acetotrophic_methanogenesis_g_c_per_mol,
    /// Source `8.3143E-03` at line 1000, kilojoule per mole per kelvin.
    gas_constant_kilojoule_per_mol_kelvin: f64 =
        anaerobic.source_feedback_environment.gas_constant_kilojoule_per_mol_kelvin,
};

pub const AcetotrophicResult = struct {
    acetate_oxidation_g_c: f64,
    methane_production_g_c: f64,
    growth_respiration_fraction: f64,
    substrate_unlimited_oxidation_g_c: f64,
};

/// Acetotrophic NITRO branch: acetate feedback changes energy yield, while
/// biomass kinetics and the finite acetate pool independently limit oxidation.
pub fn acetotrophic(inputs: AcetotrophicInputs, parameters: AcetotrophicParameters) !AcetotrophicResult {
    try validateStruct(inputs, error.InvalidAcetotrophicMethanogenesisInput);
    try validateStruct(parameters, error.InvalidAcetotrophicMethanogenesisParameter);
    if (inputs.soil_temperature_k <= 0 or inputs.aqueous_acetate_concentration_g_c_per_m3 < 0 or inputs.aqueous_acetate_g_c < 0 or inputs.acetate_competition_fraction < 0 or inputs.nutrient_limitation_fraction < 0 or inputs.water_stress_fraction < 0 or inputs.temperature_response < 0 or inputs.active_biomass_g_c < 0 or inputs.timestep_h <= 0 or parameters.acetate_inhibition_concentration_g_c_per_m3 <= 0 or parameters.acetate_half_saturation_g_c_per_m3 <= 0 or parameters.specific_respiration_per_h < 0 or parameters.growth_energy_requirement_kj_per_g_c <= 0 or parameters.minimum_growth_respiration_fraction < 0 or parameters.minimum_growth_respiration_fraction > 1 or parameters.feedback_carbon_basis_g_c_per_mol <= 0 or parameters.gas_constant_kilojoule_per_mol_kelvin <= 0) return error.InvalidAcetotrophicMethanogenesis;
    // Source NITRO.F 1000--1002: GOMX then GOMM. The 24 gram carbon per mole
    // basis is a runtime parameter, not a literal.
    const feedback_kj_per_g_c = parameters.gas_constant_kilojoule_per_mol_kelvin * inputs.soil_temperature_k * @log(@max(std.math.floatMin(f64), inputs.aqueous_acetate_concentration_g_c_per_m3 / parameters.acetate_inhibition_concentration_g_c_per_m3)) / parameters.feedback_carbon_basis_g_c_per_mol;
    const respiration_fraction = @max(parameters.minimum_growth_respiration_fraction, @min(1, 1 / (1 + @max(0, parameters.reference_energy_yield_kj_per_g_c + feedback_kj_per_g_c) / parameters.growth_energy_requirement_kj_per_g_c)));
    const monod = inputs.aqueous_acetate_concentration_g_c_per_m3 / (inputs.aqueous_acetate_concentration_g_c_per_m3 + parameters.acetate_half_saturation_g_c_per_m3);
    const unlimited = @max(0, parameters.specific_respiration_per_h * inputs.nutrient_limitation_fraction * inputs.water_stress_fraction * inputs.active_biomass_g_c * inputs.timestep_h);
    const kinetic_limit = unlimited * monod * inputs.temperature_response;
    const supply_limit = @max(0, inputs.aqueous_acetate_g_c * inputs.acetate_competition_fraction * respiration_fraction * inputs.timestep_h);
    const oxidation = @min(kinetic_limit, supply_limit);
    return .{ .acetate_oxidation_g_c = oxidation, .methane_production_g_c = 0.5 * oxidation, .growth_respiration_fraction = respiration_fraction, .substrate_unlimited_oxidation_g_c = unlimited };
}

pub const HydrogenotrophicInputs = struct {
    aqueous_hydrogen_concentration_g_h_per_m3: f64,
    aqueous_hydrogen_g_h: f64,
    fermentation_hydrogen_production_g_h: f64,
    temperature_water_response: f64,
    nutrient_limitation_fraction: f64,
    aqueous_co2_limitation_fraction: f64,
    active_biomass_g_c: f64,
    timestep_h: f64,
    hydrogen_feedback_energy_kj_per_mol: f64,
};

pub const HydrogenotrophicParameters = struct {
    hydrogen_half_saturation_g_h_per_m3: f64,
    specific_co2_reduction_g_c_per_g_c_h: f64,
    reference_energy_yield_kj_per_g_c: f64,
    growth_energy_requirement_kj_per_g_c: f64,
    minimum_growth_respiration_fraction: f64,
    hydrogen_supply_conversion_g_c_per_g_h: f64,
    /// GAS-METHANOGENESIS-DOUBLE-0.111-001: retained only for runtime
    /// parameter-file back-compatibility (`soil_methane` record field 10).
    /// No longer applied in `hydrogenotrophic` below: the upstream
    /// `respiration_products_step.zig` publisher already performs the single
    /// `NITRO.F:1321` `0.111*TRH2G` conversion from gram-carbon to gram-H
    /// before this field's input (`inputs.fermentation_hydrogen_production_g_h`)
    /// is populated, so re-multiplying here double-applied the factor
    /// (~0.111^2 instead of 0.111) and suppressed hydrogenotrophic CH4
    /// production roughly 9x whenever fermentation dominated the H2 supply.
    fermentation_hydrogen_to_pool_fraction: f64,
    /// Source `NITRO.F` 1317 divisor `GH2H=GH2X/12.0`, gram carbon per mole.
    /// Defaults to the source value so existing callers are unchanged.
    feedback_carbon_basis_g_c_per_mol: f64 =
        anaerobic.source_carbon_basis.hydrogenotrophic_methanogenesis_g_c_per_mol,
};

pub const HydrogenotrophicResult = struct { co2_reduction_g_c: f64, methane_production_g_c: f64, growth_respiration_fraction: f64 };

pub fn hydrogenotrophic(inputs: HydrogenotrophicInputs, parameters: HydrogenotrophicParameters) !HydrogenotrophicResult {
    try validateStruct(inputs, error.InvalidHydrogenotrophicMethanogenesisInput);
    try validateStruct(parameters, error.InvalidHydrogenotrophicMethanogenesisParameter);
    if (inputs.aqueous_hydrogen_concentration_g_h_per_m3 < 0 or inputs.aqueous_hydrogen_g_h < 0 or inputs.fermentation_hydrogen_production_g_h < 0 or inputs.temperature_water_response < 0 or inputs.nutrient_limitation_fraction < 0 or inputs.aqueous_co2_limitation_fraction < 0 or inputs.active_biomass_g_c < 0 or inputs.timestep_h <= 0 or parameters.hydrogen_half_saturation_g_h_per_m3 <= 0 or parameters.specific_co2_reduction_g_c_per_g_c_h < 0 or parameters.growth_energy_requirement_kj_per_g_c <= 0 or parameters.minimum_growth_respiration_fraction < 0 or parameters.minimum_growth_respiration_fraction > 1 or parameters.hydrogen_supply_conversion_g_c_per_g_h <= 0 or parameters.fermentation_hydrogen_to_pool_fraction < 0 or parameters.feedback_carbon_basis_g_c_per_mol <= 0) return error.InvalidHydrogenotrophicMethanogenesis;
    // Source NITRO.F 1317--1319. The 12 gram carbon per mole basis is a runtime
    // parameter, not a literal; the hydrogenotrophic basis is six times finer
    // than the fermenter's 72, which is why they cannot share one divisor.
    const hydrogen_feedback_kj_per_g_c = try anaerobic.hydrogenotrophicCarbonBasisFeedback_kilojoule_per_g_c(
        inputs.hydrogen_feedback_energy_kj_per_mol,
        .{
            .fermentation_g_c_per_mol = anaerobic.source_carbon_basis.fermentation_g_c_per_mol,
            .acetotrophic_methanogenesis_g_c_per_mol = anaerobic.source_carbon_basis.acetotrophic_methanogenesis_g_c_per_mol,
            .hydrogenotrophic_methanogenesis_g_c_per_mol = parameters.feedback_carbon_basis_g_c_per_mol,
        },
    );
    const respiration_fraction = @max(parameters.minimum_growth_respiration_fraction, @min(1, 1 / (1 + @max(0, parameters.reference_energy_yield_kj_per_g_c + hydrogen_feedback_kj_per_g_c) / parameters.growth_energy_requirement_kj_per_g_c)));
    const unlimited = parameters.specific_co2_reduction_g_c_per_g_c_h * inputs.temperature_water_response * inputs.nutrient_limitation_fraction * inputs.aqueous_co2_limitation_fraction * inputs.active_biomass_g_c * inputs.timestep_h;
    const monod = inputs.aqueous_hydrogen_concentration_g_h_per_m3 / (inputs.aqueous_hydrogen_concentration_g_h_per_m3 + parameters.hydrogen_half_saturation_g_h_per_m3);
    // GAS-METHANOGENESIS-DOUBLE-0.111-001: `inputs.fermentation_hydrogen_production_g_h`
    // is already gram-H (converted once, at NITRO.F:973's single point of
    // use, by respiration_products_step.zig:82's `0.111 * respiration_g_c`);
    // it must be added directly, matching NITRO.F:1321
    // `H2GSX=H2GS(L,NY,NX)+0.111*TRH2G`, not re-scaled by
    // `fermentation_hydrogen_to_pool_fraction` again.
    const hydrogen_supply_g_h = inputs.aqueous_hydrogen_g_h + inputs.fermentation_hydrogen_production_g_h;
    const reduction = @max(0, @min(unlimited * monod, parameters.hydrogen_supply_conversion_g_c_per_g_h * hydrogen_supply_g_h * inputs.timestep_h));
    return .{ .co2_reduction_g_c = reduction, .methane_production_g_c = reduction, .growth_respiration_fraction = respiration_fraction };
}

fn validateStruct(value: anytype, comptime failure: anyerror) !void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(value, field.name))) return failure;
}

test "acetotrophic methane is half of acetate oxidation" {
    const result = try acetotrophic(.{ .soil_temperature_k = 293, .aqueous_acetate_concentration_g_c_per_m3 = 2, .aqueous_acetate_g_c = 5, .acetate_competition_fraction = 0.8, .nutrient_limitation_fraction = 0.9, .water_stress_fraction = 1, .temperature_response = 0.8, .active_biomass_g_c = 1, .timestep_h = 1 }, .{ .acetate_inhibition_concentration_g_c_per_m3 = 1, .acetate_half_saturation_g_c_per_m3 = 0.5, .specific_respiration_per_h = 0.2, .reference_energy_yield_kj_per_g_c = 1, .growth_energy_requirement_kj_per_g_c = 10, .minimum_growth_respiration_fraction = 0.05 });
    try std.testing.expect(result.acetate_oxidation_g_c > 0);
    try std.testing.expectApproxEqAbs(0.5 * result.acetate_oxidation_g_c, result.methane_production_g_c, 1e-15);
}

test "hydrogenotrophic methane respects finite hydrogen supply" {
    const result = try hydrogenotrophic(.{ .aqueous_hydrogen_concentration_g_h_per_m3 = 1, .aqueous_hydrogen_g_h = 0.01, .fermentation_hydrogen_production_g_h = 0, .temperature_water_response = 1, .nutrient_limitation_fraction = 1, .aqueous_co2_limitation_fraction = 1, .active_biomass_g_c = 10, .timestep_h = 1, .hydrogen_feedback_energy_kj_per_mol = 0 }, .{ .hydrogen_half_saturation_g_h_per_m3 = 0.1, .specific_co2_reduction_g_c_per_g_c_h = 1, .reference_energy_yield_kj_per_g_c = 1, .growth_energy_requirement_kj_per_g_c = 10, .minimum_growth_respiration_fraction = 0.05, .hydrogen_supply_conversion_g_c_per_g_h = 1.5, .fermentation_hydrogen_to_pool_fraction = 0.111 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.015), result.methane_production_g_c, 1e-15);
}

test "GAS-METHANOGENESIS-DOUBLE-0.111-001: fermentation hydrogen input is added once, not rescaled" {
    // `fermentation_hydrogen_production_g_h` here stands in for
    // respiration_products_step.zig's already-converted `hydrogen_g_h`
    // publisher output (gram-H, NITRO.F:973's RGOMP already multiplied by
    // 0.111 once at its point of use). NITRO.F:1321 adds it to the standing
    // aqueous pool with no further scaling: H2GSX=H2GS+0.111*TRH2G, where
    // the *source's* TRH2G is the unconverted gram-carbon accumulator, but
    // this kernel's input is already gram-H, so the correct combination is
    // a plain sum. Supply is deliberately made the binding constraint
    // (a small `hydrogen_supply_conversion_g_c_per_g_h`, and a saturated
    // kinetic term) so `co2_reduction_g_c` isolates the supply-side
    // arithmetic: it must equal
    // `hydrogen_supply_conversion_g_c_per_g_h * (aqueous_hydrogen_g_h +
    // fermentation_hydrogen_production_g_h)`, not the ~9x-smaller value a
    // reintroduced double-0.111 scaling would produce.
    const aqueous_hydrogen_g_h: f64 = 0.01;
    const fermentation_hydrogen_production_g_h: f64 = 0.111 * 1.0; // e.g. RGOMP=1 g C already converted upstream
    const hydrogen_supply_conversion_g_c_per_g_h: f64 = 0.001;
    const result = try hydrogenotrophic(.{
        .aqueous_hydrogen_concentration_g_h_per_m3 = 100,
        .aqueous_hydrogen_g_h = aqueous_hydrogen_g_h,
        .fermentation_hydrogen_production_g_h = fermentation_hydrogen_production_g_h,
        .temperature_water_response = 1,
        .nutrient_limitation_fraction = 1,
        .aqueous_co2_limitation_fraction = 1,
        .active_biomass_g_c = 1e9,
        .timestep_h = 1,
        .hydrogen_feedback_energy_kj_per_mol = 0,
    }, .{
        .hydrogen_half_saturation_g_h_per_m3 = 0.1,
        .specific_co2_reduction_g_c_per_g_c_h = 1,
        .reference_energy_yield_kj_per_g_c = 1,
        .growth_energy_requirement_kj_per_g_c = 10,
        .minimum_growth_respiration_fraction = 0.05,
        .hydrogen_supply_conversion_g_c_per_g_h = hydrogen_supply_conversion_g_c_per_g_h,
        .fermentation_hydrogen_to_pool_fraction = 0.111,
    });
    const expected = hydrogen_supply_conversion_g_c_per_g_h * (aqueous_hydrogen_g_h + fermentation_hydrogen_production_g_h);
    try std.testing.expectApproxEqAbs(expected, result.co2_reduction_g_c, 1e-15);
}
