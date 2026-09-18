const std = @import("std");
const organic = @import("../organic/initialization.zig");

pub const Metabolism = enum {
    aerobic_heterotroph,
    fermenting_heterotroph,
    acetotrophic_methanogen,
};

pub const PopulationParameters = struct {
    metabolism: Metabolism,
    substrate_unlimited_respiration_per_h: f64,
};

/// Source NITRO population roles, kept behind one runtime-index adapter until
/// the soil parameter file supplies an explicit role for every population.
pub fn sourceMetabolism(population: usize) Metabolism {
    return switch (population) {
        3, 6 => .fermenting_heterotroph,
        4 => .acetotrophic_methanogen,
        else => .aerobic_heterotroph,
    };
}

pub const Inputs = struct {
    carbon_pool_count: usize,
    population_parameters: []const PopulationParameters,
    nutrient_limitation_fraction: []const f64, // carbon pool x population
    water_stress_fraction: []const f64, // carbon pool x population
    active_biomass_g_c: []const f64, // carbon pool x population
    oxygen_limitation_fraction: []const f64, // carbon pool x population
    timestep_h: f64,
};

pub const AerobicSubstrateInputs = struct {
    unlimited_respiration_g_c: f64,
    dissolved_organic_carbon_g_c: f64,
    dissolved_acetate_carbon_g_c: f64,
    biologically_active_water_m3: f64,
    substrate_complex_fraction: f64,
    doc_half_saturation_g_c_per_m3: f64,
    acetate_half_saturation_g_c_per_m3: f64,
    doc_biological_demand_fraction: f64,
    acetate_biological_demand_fraction: f64,
    doc_respiration_requirement_g_c_per_g_c: f64,
    acetate_respiration_requirement_g_c_per_g_c: f64,
    temperature_response: f64,
    timestep_h: f64,
};

pub const AerobicSubstrateResult = struct {
    doc_concentration_g_c_per_m3: f64,
    acetate_concentration_g_c_per_m3: f64,
    doc_fraction: f64,
    acetate_fraction: f64,
    doc_respiration_g_c: f64,
    acetate_respiration_g_c: f64,
    substrate_limited_respiration_g_c: f64,
    potential_oxygen_demand_g_o: f64,
};

/// NITRO RGOCY -> RGOCZ/RGOAZ -> RGOMP -> ROXYP for an aerobic
/// heterotroph. This preserves the distinction between unlimited ROQCD used
/// by fertilizer hydrolysis and substrate-limited respiration used for O2.
pub fn aerobicSubstrateLimitedRespiration(inputs: AerobicSubstrateInputs) !AerobicSubstrateResult {
    inline for (@typeInfo(AerobicSubstrateInputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteAerobicSubstrateInput;
    if (inputs.unlimited_respiration_g_c < 0 or inputs.dissolved_organic_carbon_g_c < 0 or inputs.dissolved_acetate_carbon_g_c < 0 or inputs.biologically_active_water_m3 < 0 or inputs.substrate_complex_fraction < 0 or inputs.substrate_complex_fraction > 1 or inputs.doc_half_saturation_g_c_per_m3 <= 0 or inputs.acetate_half_saturation_g_c_per_m3 <= 0 or inputs.doc_biological_demand_fraction < 0 or inputs.doc_biological_demand_fraction > 1 or inputs.acetate_biological_demand_fraction < 0 or inputs.acetate_biological_demand_fraction > 1 or inputs.doc_respiration_requirement_g_c_per_g_c < 0 or inputs.acetate_respiration_requirement_g_c_per_g_c < 0 or inputs.temperature_response < 0 or inputs.timestep_h <= 0) return error.InvalidAerobicSubstrateInput;
    const effective_water = inputs.biologically_active_water_m3 * inputs.substrate_complex_fraction;
    const doc_concentration = if (inputs.biologically_active_water_m3 > 0) inputs.dissolved_organic_carbon_g_c / (if (effective_water > 0) effective_water else inputs.biologically_active_water_m3) else 0;
    const acetate_concentration = if (inputs.biologically_active_water_m3 > 0) inputs.dissolved_acetate_carbon_g_c / (if (effective_water > 0) effective_water else inputs.biologically_active_water_m3) else 0;
    const total_dissolved = inputs.dissolved_organic_carbon_g_c + inputs.dissolved_acetate_carbon_g_c;
    const doc_fraction: f64 = if (inputs.dissolved_organic_carbon_g_c > 0 and inputs.dissolved_acetate_carbon_g_c > 0) inputs.dissolved_organic_carbon_g_c / total_dissolved else if (inputs.dissolved_organic_carbon_g_c > 0) 1.0 else 0.0;
    const acetate_fraction = 1 - doc_fraction;
    const doc_unconstrained = inputs.unlimited_respiration_g_c * doc_concentration / (doc_concentration + inputs.doc_half_saturation_g_c_per_m3) * doc_fraction * inputs.temperature_response;
    const acetate_unconstrained = inputs.unlimited_respiration_g_c * acetate_concentration / (acetate_concentration + inputs.acetate_half_saturation_g_c_per_m3) * acetate_fraction * inputs.temperature_response;
    const doc_supply = inputs.dissolved_organic_carbon_g_c * inputs.doc_biological_demand_fraction * inputs.doc_respiration_requirement_g_c_per_g_c * inputs.timestep_h;
    const acetate_supply = inputs.dissolved_acetate_carbon_g_c * inputs.acetate_biological_demand_fraction * inputs.acetate_respiration_requirement_g_c_per_g_c * inputs.timestep_h;
    const doc_respiration = @min(doc_supply, doc_unconstrained);
    const acetate_respiration = @min(acetate_supply, acetate_unconstrained);
    const substrate_limited = doc_respiration + acetate_respiration;
    const result: AerobicSubstrateResult = .{ .doc_concentration_g_c_per_m3 = doc_concentration, .acetate_concentration_g_c_per_m3 = acetate_concentration, .doc_fraction = doc_fraction, .acetate_fraction = acetate_fraction, .doc_respiration_g_c = doc_respiration, .acetate_respiration_g_c = acetate_respiration, .substrate_limited_respiration_g_c = substrate_limited, .potential_oxygen_demand_g_o = 2.667 * substrate_limited };
    inline for (@typeInfo(AerobicSubstrateResult).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.NonFiniteAerobicSubstrateResult;
    return result;
}

/// NITRO.F ROQCD -> ROQCK -> TOQCK aggregation. Acetotrophic methanogens set
/// ROQCD to zero in the source. Priming transfers are omitted here because
/// every transfer is equal and opposite between pools and therefore cannot
/// change the layer-total activity used by SOLUTE urea hydrolysis.
pub fn totalActivity_g_c_per_step(inputs: Inputs) !f64 {
    if (inputs.carbon_pool_count == 0 or inputs.population_parameters.len == 0 or !std.math.isFinite(inputs.timestep_h) or inputs.timestep_h <= 0) return error.InvalidMicrobialActivityDimensions;
    const count = try std.math.mul(usize, inputs.carbon_pool_count, inputs.population_parameters.len);
    inline for (.{ inputs.nutrient_limitation_fraction, inputs.water_stress_fraction, inputs.active_biomass_g_c, inputs.oxygen_limitation_fraction }) |values| if (values.len != count) return error.InvalidMicrobialActivityDimensions;
    for (inputs.population_parameters) |parameters| if (!std.math.isFinite(parameters.substrate_unlimited_respiration_per_h) or parameters.substrate_unlimited_respiration_per_h < 0) return error.InvalidMicrobialActivityParameter;

    var total: f64 = 0;
    for (0..inputs.carbon_pool_count) |pool| for (inputs.population_parameters, 0..) |parameters, population| {
        const index = pool * inputs.population_parameters.len + population;
        const nutrient = inputs.nutrient_limitation_fraction[index];
        const water = inputs.water_stress_fraction[index];
        const biomass = inputs.active_biomass_g_c[index];
        const oxygen = inputs.oxygen_limitation_fraction[index];
        inline for (.{ nutrient, water, biomass, oxygen }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidMicrobialActivityInput;
        if (nutrient > 1 or water > 1 or oxygen > 1) return error.InvalidMicrobialActivityInput;
        const unlimited = switch (parameters.metabolism) {
            .aerobic_heterotroph, .fermenting_heterotroph => parameters.substrate_unlimited_respiration_per_h * nutrient * water * biomass * inputs.timestep_h,
            .acetotrophic_methanogen => 0,
        };
        total += unlimited * (if (parameters.metabolism == .aerobic_heterotroph) oxygen else 1);
    };
    if (!std.math.isFinite(total) or total < 0) return error.NonFiniteMicrobialRespirationActivity;
    return total;
}

test "fermentation activity is independent of oxygen limitation" {
    const populations = [_]PopulationParameters{.{ .metabolism = .fermenting_heterotroph, .substrate_unlimited_respiration_per_h = 0.2 }};
    const one = [_]f64{1};
    const zero = [_]f64{0};
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), try totalActivity_g_c_per_step(.{
        .carbon_pool_count = 1,
        .population_parameters = &populations,
        .nutrient_limitation_fraction = &one,
        .water_stress_fraction = &one,
        .active_biomass_g_c = &.{2},
        .oxygen_limitation_fraction = &zero,
        .timestep_h = 1,
    }), 1e-15);
}

pub const SurfaceParameters = struct {
    population_parameters: []const PopulationParameters,
    target_nitrogen_per_carbon_g_n_per_g_c: []const f64, // pool x population
    target_phosphorus_per_carbon_g_p_per_g_c: []const f64, // pool x population
    labile_biomass_fraction: f64,
};

/// Derives the L=0 activity directly from runtime organic pools. NITRO sets
/// KL=2 at the litter surface, so only woody, fine-residue, and manure carbon
/// complexes participate. The first kinetic fraction is OMC(1); division by
/// FL(1) reconstructs active OMA before N/P, water, and oxygen limitation.
pub fn totalSurfaceActivity_g_c_per_step(state: *const organic.State, cell: usize, matric_plus_osmotic_potential_megapascal: f64, oxygen_limitation_fraction: []const f64, parameters: SurfaceParameters, timestep_h: f64) !f64 {
    const pool_count: usize = 3;
    const population_count = parameters.population_parameters.len;
    if (cell >= state.layer_count or population_count == 0 or population_count != organic.microbial_population_count or !std.math.isFinite(parameters.labile_biomass_fraction) or parameters.labile_biomass_fraction <= 0 or parameters.labile_biomass_fraction > 1 or !std.math.isFinite(matric_plus_osmotic_potential_megapascal) or !std.math.isFinite(timestep_h) or timestep_h <= 0) return error.InvalidSurfaceMicrobialActivityInput;
    const count = try std.math.mul(usize, pool_count, population_count);
    if (parameters.target_nitrogen_per_carbon_g_n_per_g_c.len != count or parameters.target_phosphorus_per_carbon_g_p_per_g_c.len != count or oxygen_limitation_fraction.len != count) return error.InvalidSurfaceMicrobialActivityInput;

    var total: f64 = 0;
    for (0..pool_count) |pool| for (parameters.population_parameters, 0..) |population_parameters, population| {
        const target_index = pool * population_count + population;
        const target_n = parameters.target_nitrogen_per_carbon_g_n_per_g_c[target_index];
        const target_p = parameters.target_phosphorus_per_carbon_g_p_per_g_c[target_index];
        const oxygen = oxygen_limitation_fraction[target_index];
        if (!std.math.isFinite(target_n) or !std.math.isFinite(target_p) or target_n <= 0 or target_p <= 0 or !std.math.isFinite(oxygen) or oxygen < 0 or oxygen > 1 or !std.math.isFinite(population_parameters.substrate_unlimited_respiration_per_h) or population_parameters.substrate_unlimited_respiration_per_h < 0) return error.InvalidSurfaceMicrobialActivityInput;
        const microbial_index = (((cell * organic.microbial_substrate_count + pool) * organic.microbial_population_count + population) * organic.kinetic_fraction_count);
        const labile = state.microbial[microbial_index];
        if (!std.math.isFinite(labile.carbon_g_c) or !std.math.isFinite(labile.nitrogen_g_n) or !std.math.isFinite(labile.phosphorus_g_p) or labile.carbon_g_c < 0 or labile.nitrogen_g_n < 0 or labile.phosphorus_g_p < 0) return error.InvalidSurfaceMicrobialActivityInput;
        const actual_n = if (labile.carbon_g_c > 0) labile.nitrogen_g_n / labile.carbon_g_c else target_n;
        const actual_p = if (labile.carbon_g_c > 0) labile.phosphorus_g_p / labile.carbon_g_c else target_p;
        const nitrogen_factor = @min(1, @max(0.1, std.math.pow(f64, actual_n / target_n, 0.25)));
        const phosphorus_factor = @min(1, @max(0.1, std.math.pow(f64, actual_p / target_p, 0.25)));
        const nutrient_factor = @min(nitrogen_factor, phosphorus_factor);
        const is_fungus = population == 2; // source N=3
        const water_factor = @exp((if (is_fungus) @as(f64, 0.05) else 0.10) * matric_plus_osmotic_potential_megapascal);
        const active_biomass_g_c = labile.carbon_g_c / parameters.labile_biomass_fraction;
        const unlimited = switch (population_parameters.metabolism) {
            .aerobic_heterotroph, .fermenting_heterotroph => population_parameters.substrate_unlimited_respiration_per_h * nutrient_factor * water_factor * active_biomass_g_c * timestep_h,
            .acetotrophic_methanogen => 0,
        };
        total += unlimited * (if (population_parameters.metabolism == .aerobic_heterotroph) oxygen else 1);
    };
    if (!std.math.isFinite(total) or total < 0) return error.NonFiniteMicrobialRespirationActivity;
    return total;
}

test "runtime microbial activity reproduces NITRO population rules" {
    const populations = [_]PopulationParameters{
        .{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 0.2 },
        .{ .metabolism = .fermenting_heterotroph, .substrate_unlimited_respiration_per_h = 0.1 },
        .{ .metabolism = .acetotrophic_methanogen, .substrate_unlimited_respiration_per_h = 99 },
    };
    const result = try totalActivity_g_c_per_step(.{
        .carbon_pool_count = 2,
        .population_parameters = &populations,
        .nutrient_limitation_fraction = &.{ 1, 0.5, 1, 0.5, 1, 1 },
        .water_stress_fraction = &.{ 1, 1, 1, 1, 0.5, 1 },
        .active_biomass_g_c = &.{ 10, 10, 100, 20, 20, 100 },
        .oxygen_limitation_fraction = &.{ 0.5, 1, 1, 1, 0.25, 1 },
        .timestep_h = 1,
    });
    const expected = 0.2 * 1 * 1 * 10 * 0.5 + 0.1 * 0.5 * 1 * 10 + 0.2 * 0.5 * 1 * 20 + 0.1 * 1 * 0.5 * 20;
    try std.testing.expectApproxEqAbs(expected, result, 1e-14);
}

test "aerobic substrate limitation reproduces NITRO RGOMP and ROXYP" {
    const result = try aerobicSubstrateLimitedRespiration(.{ .unlimited_respiration_g_c = 2, .dissolved_organic_carbon_g_c = 3, .dissolved_acetate_carbon_g_c = 1, .biologically_active_water_m3 = 2, .substrate_complex_fraction = 0.5, .doc_half_saturation_g_c_per_m3 = 12, .acetate_half_saturation_g_c_per_m3 = 12, .doc_biological_demand_fraction = 0.4, .acetate_biological_demand_fraction = 0.6, .doc_respiration_requirement_g_c_per_g_c = 0.5, .acetate_respiration_requirement_g_c_per_g_c = 0.25, .temperature_response = 0.8, .timestep_h = 1 });
    const doc_unconstrained: f64 = 2.0 * 3.0 / (3.0 + 12.0) * 0.75 * 0.8;
    const acetate_unconstrained: f64 = 2.0 * 1.0 / (1.0 + 12.0) * 0.25 * 0.8;
    const expected = @min(3 * 0.4 * 0.5, doc_unconstrained) + @min(1 * 0.6 * 0.25, acetate_unconstrained);
    try std.testing.expectApproxEqAbs(expected, result.substrate_limited_respiration_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(2.667 * expected, result.potential_oxygen_demand_g_o, 1e-15);
}

test "activity aggregation supports runtime population counts beyond legacy seven" {
    const populations = [_]PopulationParameters{.{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 1 }} ** 11;
    const values = [_]f64{1} ** 22;
    const biomass = [_]f64{2} ** 22;
    try std.testing.expectEqual(@as(f64, 44), try totalActivity_g_c_per_step(.{ .carbon_pool_count = 2, .population_parameters = &populations, .nutrient_limitation_fraction = &values, .water_stress_fraction = &values, .active_biomass_g_c = &biomass, .oxygen_limitation_fraction = &values, .timestep_h = 1 }));
}

test "surface activity derives OMA and nutrient limitation from litter pools" {
    var state = try organic.State.init(std.testing.allocator, 1);
    defer state.deinit();
    const populations = [_]PopulationParameters{
        .{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 0.125 },
        .{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 0.125 },
        .{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 0.125 },
        .{ .metabolism = .fermenting_heterotroph, .substrate_unlimited_respiration_per_h = 0.125 },
        .{ .metabolism = .acetotrophic_methanogen, .substrate_unlimited_respiration_per_h = 0.125 },
        .{ .metabolism = .aerobic_heterotroph, .substrate_unlimited_respiration_per_h = 0.125 },
        .{ .metabolism = .fermenting_heterotroph, .substrate_unlimited_respiration_per_h = 0.125 },
    };
    const target_n = [_]f64{0.1} ** 21;
    const target_p = [_]f64{0.01} ** 21;
    const oxygen = [_]f64{1} ** 21;
    state.microbial[0] = .{ .carbon_g_c = 5.5, .nitrogen_g_n = 0.55, .phosphorus_g_p = 0.055 };
    const result = try totalSurfaceActivity_g_c_per_step(&state, 0, 0, &oxygen, .{ .population_parameters = &populations, .target_nitrogen_per_carbon_g_n_per_g_c = &target_n, .target_phosphorus_per_carbon_g_p_per_g_c = &target_p, .labile_biomass_fraction = 0.55 }, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), result, 1e-14);
}
