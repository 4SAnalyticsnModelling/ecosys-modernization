const std = @import("std");
const organic = @import("../organic/initialization.zig");

pub const EnvironmentParameters = struct {
    surface_activity_half_saturation_g_c_per_m3: f64,
    soil_activity_half_saturation_g_c_per_m3: f64,
    surface_activity_inhibition_g_c_per_m3_per_step: f64,
    soil_activity_inhibition_g_c_per_m3_per_step: f64,
    dissolved_carbon_product_inhibition_g_c_per_m3: f64,
};

pub const EnvironmentInputs = struct {
    is_surface: bool,
    total_colonized_carbon_g_c: f64,
    microbial_activity_g_c_per_step: f64,
    biologically_active_water_m3: f64,
    soil_mass_megagrams: f64,
    bulk_volume_m3: f64,
    dissolved_carbon_concentration_g_c_per_m3: f64,
    timestep_h: f64,
    negligible_carbon_g_c: f64,
};

pub const Environment = struct {
    activity_concentration_g_c_per_m3_per_h: f64,
    decomposition_half_saturation_g_c_per_m3: f64,
    effective_colonized_concentration_sqrt_g_c_per_megagram: f64,
    microbial_density_response: f64,
    dissolved_carbon_product_response: f64,
};

pub fn environment(inputs: EnvironmentInputs, parameters: EnvironmentParameters) !Environment {
    inline for (@typeInfo(EnvironmentInputs).@"struct".fields) |field| if (field.type == f64 and (!std.math.isFinite(@field(inputs, field.name)) or @field(inputs, field.name) < 0)) return error.InvalidOrganicDecompositionEnvironment;
    inline for (@typeInfo(EnvironmentParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters, field.name)) or @field(parameters, field.name) <= 0) return error.InvalidOrganicDecompositionParameter;
    if (inputs.timestep_h <= 0) return error.InvalidOrganicDecompositionEnvironment;
    if (inputs.total_colonized_carbon_g_c <= inputs.negligible_carbon_g_c) return .{ .activity_concentration_g_c_per_m3_per_h = 0, .decomposition_half_saturation_g_c_per_m3 = 0, .effective_colonized_concentration_sqrt_g_c_per_megagram = 0, .microbial_density_response = 0, .dissolved_carbon_product_response = 0 };
    const activity_concentration = if (inputs.biologically_active_water_m3 > inputs.negligible_carbon_g_c) @min(1.0e5, inputs.microbial_activity_g_c_per_step / (inputs.biologically_active_water_m3 * inputs.timestep_h)) else 1.0e5;
    const base_half_saturation = if (inputs.is_surface) parameters.surface_activity_half_saturation_g_c_per_m3 else parameters.soil_activity_half_saturation_g_c_per_m3;
    const activity_inhibition = if (inputs.is_surface) parameters.surface_activity_inhibition_g_c_per_m3_per_step else parameters.soil_activity_inhibition_g_c_per_m3_per_step;
    const half_saturation = base_half_saturation * (1 + activity_concentration / activity_inhibition);
    const denominator = if (inputs.soil_mass_megagrams > inputs.negligible_carbon_g_c) inputs.soil_mass_megagrams else inputs.bulk_volume_m3;
    if (denominator <= 0) return error.InvalidOrganicDecompositionEnvironment;
    const effective_concentration = @sqrt(inputs.total_colonized_carbon_g_c / denominator);
    const density_response = effective_concentration / (effective_concentration + half_saturation);
    const product_response = 1 / (1 + inputs.dissolved_carbon_concentration_g_c_per_m3 / parameters.dissolved_carbon_product_inhibition_g_c_per_m3);
    const result: Environment = .{ .activity_concentration_g_c_per_m3_per_h = activity_concentration, .decomposition_half_saturation_g_c_per_m3 = half_saturation, .effective_colonized_concentration_sqrt_g_c_per_megagram = effective_concentration, .microbial_density_response = density_response, .dissolved_carbon_product_response = product_response };
    inline for (@typeInfo(Environment).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.NonFiniteOrganicDecompositionEnvironment;
    return result;
}

pub const NutrientLimitation = struct { nitrogen: f64, phosphorus: f64 };

pub fn nutrientLimitation(total_active_carbon_g_c: f64, total_active_nitrogen_g_n: f64, maximum_active_nitrogen_g_n: f64, total_active_phosphorus_g_p: f64, maximum_active_phosphorus_g_p: f64, negligible_carbon_g_c: f64) !NutrientLimitation {
    inline for (.{ total_active_carbon_g_c, total_active_nitrogen_g_n, maximum_active_nitrogen_g_n, total_active_phosphorus_g_p, maximum_active_phosphorus_g_p, negligible_carbon_g_c }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicDecompositionNutrientState;
    if (total_active_carbon_g_c <= negligible_carbon_g_c) return .{ .nitrogen = 1, .phosphorus = 1 };
    if (maximum_active_nitrogen_g_n <= 0 or maximum_active_phosphorus_g_p <= 0) return error.InvalidOrganicDecompositionNutrientState;
    return .{ .nitrogen = @min(1, @max(0.5, total_active_nitrogen_g_n / maximum_active_nitrogen_g_n)), .phosphorus = @min(1, @max(0.5, total_active_phosphorus_g_p / maximum_active_phosphorus_g_p)) };
}

pub const RateInputs = struct {
    pool: organic.ElementPool,
    active_carbon_g_c: f64,
    total_colonized_carbon_g_c: f64,
    specific_decomposition_rate_g_c_per_g_activity_h: f64,
    microbial_activity_g_c_per_step: f64,
    microbial_density_response: f64,
    dissolved_carbon_product_response: f64,
    growth_temperature_response: f64,
    nutrient_limitation: NutrientLimitation,
    timestep_h: f64,
    negligible_carbon_g_c: f64,
};

/// NITRO RDOSC/RDOSN/RDOSP and RDORC/RDORN/RDORP.
pub fn decompose(inputs: RateInputs) !organic.ElementPool {
    try validateRateInputs(inputs);
    if (inputs.pool.carbon_g_c <= inputs.negligible_carbon_g_c or inputs.total_colonized_carbon_g_c <= inputs.negligible_carbon_g_c) return .{};
    const nitrogen_per_carbon = @max(0, inputs.pool.nitrogen_g_n / inputs.pool.carbon_g_c);
    const phosphorus_per_carbon = @max(0, inputs.pool.phosphorus_g_p / inputs.pool.carbon_g_c);
    const carbon = @max(0, @min(inputs.active_carbon_g_c * inputs.timestep_h, inputs.specific_decomposition_rate_g_c_per_g_activity_h * inputs.microbial_activity_g_c_per_step * inputs.microbial_density_response * inputs.dissolved_carbon_product_response * inputs.growth_temperature_response * inputs.active_carbon_g_c / inputs.total_colonized_carbon_g_c));
    const nitrogen = @max(0, @min(inputs.pool.nitrogen_g_n * inputs.timestep_h, nitrogen_per_carbon * carbon)) / inputs.nutrient_limitation.nitrogen;
    const phosphorus = @max(0, @min(inputs.pool.phosphorus_g_p * inputs.timestep_h, phosphorus_per_carbon * carbon)) / inputs.nutrient_limitation.phosphorus;
    const result: organic.ElementPool = .{ .carbon_g_c = carbon, .nitrogen_g_n = nitrogen, .phosphorus_g_p = phosphorus };
    try validatePool(result);
    return result;
}

pub const StructuralProducts = struct {
    particulate: [organic.structural_fraction_count]organic.ElementPool,
    dissolved: [organic.structural_fraction_count]organic.ElementPool,
};

/// NITRO RHOSC/RHOSN/RHOSP and RCOSC/RCOSN/RCOSP for K <= 2.
pub fn partitionStructuralProducts(decomposed: [organic.structural_fraction_count]organic.ElementPool, allow_particulate_humification: bool, particulate_nitrogen_per_carbon_g_n_per_g_c: f64, particulate_phosphorus_per_carbon_g_p_per_g_c: f64) !StructuralProducts {
    if (!std.math.isFinite(particulate_nitrogen_per_carbon_g_n_per_g_c) or !std.math.isFinite(particulate_phosphorus_per_carbon_g_p_per_g_c) or particulate_nitrogen_per_carbon_g_n_per_g_c <= 0 or particulate_phosphorus_per_carbon_g_p_per_g_c <= 0) return error.InvalidParticulateOrganicRatio;
    for (decomposed) |pool| try validatePool(pool);
    var result: StructuralProducts = .{ .particulate = .{organic.ElementPool{}} ** organic.structural_fraction_count, .dissolved = undefined };
    if (allow_particulate_humification) {
        const lignin = decomposed[3];
        result.particulate[3].carbon_g_c = @max(0, @min(lignin.nitrogen_g_n / particulate_nitrogen_per_carbon_g_n_per_g_c, lignin.phosphorus_g_p / particulate_phosphorus_per_carbon_g_p_per_g_c, lignin.carbon_g_c));
        const non_lignin_limit = 0.10 * result.particulate[3].carbon_g_c;
        result.particulate[0].carbon_g_c = nutrientBoundedCarbon(decomposed[0], non_lignin_limit, particulate_nitrogen_per_carbon_g_n_per_g_c, particulate_phosphorus_per_carbon_g_p_per_g_c);
        result.particulate[1].carbon_g_c = nutrientBoundedCarbon(decomposed[1], non_lignin_limit, particulate_nitrogen_per_carbon_g_n_per_g_c, particulate_phosphorus_per_carbon_g_p_per_g_c);
        result.particulate[2].carbon_g_c = nutrientBoundedCarbon(decomposed[2], @max(0, non_lignin_limit - result.particulate[1].carbon_g_c), particulate_nitrogen_per_carbon_g_n_per_g_c, particulate_phosphorus_per_carbon_g_p_per_g_c);
        for (0..organic.structural_fraction_count) |fraction| {
            result.particulate[fraction].nitrogen_g_n = @min(decomposed[fraction].nitrogen_g_n, result.particulate[fraction].carbon_g_c * particulate_nitrogen_per_carbon_g_n_per_g_c);
            result.particulate[fraction].phosphorus_g_p = @min(decomposed[fraction].phosphorus_g_p, result.particulate[fraction].carbon_g_c * particulate_phosphorus_per_carbon_g_p_per_g_c);
        }
    }
    for (0..organic.structural_fraction_count) |fraction| result.dissolved[fraction] = subtract(decomposed[fraction], result.particulate[fraction]);
    return result;
}

pub const SorbedProducts = struct { organic: organic.ElementPool, acetate_carbon_g_c: f64 };

/// NITRO RDOHC/RDOHN/RDOHP and RDOHA.
pub fn decomposeSorbed(organic_pool: organic.ElementPool, acetate_carbon_g_c: f64, common: RateInputs, organic_rate: f64, acetate_rate: f64) !SorbedProducts {
    var organic_inputs = common;
    organic_inputs.pool = organic_pool;
    organic_inputs.active_carbon_g_c = organic_pool.carbon_g_c;
    organic_inputs.specific_decomposition_rate_g_c_per_g_activity_h = organic_rate;
    const organic_result = try decompose(organic_inputs);
    inline for (.{ acetate_carbon_g_c, acetate_rate }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicDecompositionInput;
    const acetate = if (common.total_colonized_carbon_g_c > common.negligible_carbon_g_c) @max(0, @min(acetate_carbon_g_c * common.timestep_h, acetate_rate * common.microbial_activity_g_c_per_step * common.microbial_density_response * common.growth_temperature_response * acetate_carbon_g_c / common.total_colonized_carbon_g_c)) else 0;
    if (!std.math.isFinite(acetate)) return error.NonFiniteOrganicDecompositionResult;
    return .{ .organic = organic_result, .acetate_carbon_g_c = acetate };
}

fn validateRateInputs(inputs: RateInputs) !void {
    try validatePool(inputs.pool);
    inline for (@typeInfo(RateInputs).@"struct".fields) |field| if (field.type == f64 and (!std.math.isFinite(@field(inputs, field.name)) or @field(inputs, field.name) < 0)) return error.InvalidOrganicDecompositionInput;
    if (inputs.timestep_h <= 0 or inputs.nutrient_limitation.nitrogen <= 0 or inputs.nutrient_limitation.nitrogen > 1 or inputs.nutrient_limitation.phosphorus <= 0 or inputs.nutrient_limitation.phosphorus > 1) return error.InvalidOrganicDecompositionInput;
}

fn nutrientBoundedCarbon(pool: organic.ElementPool, maximum: f64, nitrogen_ratio: f64, phosphorus_ratio: f64) f64 {
    return @max(0, @min(pool.carbon_g_c, pool.nitrogen_g_n / nitrogen_ratio, pool.phosphorus_g_p / phosphorus_ratio, maximum));
}

fn subtract(a: organic.ElementPool, b: organic.ElementPool) organic.ElementPool {
    return .{ .carbon_g_c = a.carbon_g_c - b.carbon_g_c, .nitrogen_g_n = a.nitrogen_g_n - b.nitrogen_g_n, .phosphorus_g_p = a.phosphorus_g_p - b.phosphorus_g_p };
}

fn validatePool(pool: organic.ElementPool) !void {
    inline for (@typeInfo(organic.ElementPool).@"struct".fields) |field| if (!std.math.isFinite(@field(pool, field.name)) or @field(pool, field.name) < 0) return error.InvalidOrganicDecompositionPool;
}

test "NITRO substrate decomposition reproduces density product and nutrient limitations" {
    const response = try environment(.{ .is_surface = true, .total_colonized_carbon_g_c = 100, .microbial_activity_g_c_per_step = 2, .biologically_active_water_m3 = 1, .soil_mass_megagrams = 0, .bulk_volume_m3 = 2, .dissolved_carbon_concentration_g_c_per_m3 = 50, .timestep_h = 1, .negligible_carbon_g_c = 1e-12 }, .{ .surface_activity_half_saturation_g_c_per_m3 = 12, .soil_activity_half_saturation_g_c_per_m3 = 8, .surface_activity_inhibition_g_c_per_m3_per_step = 50, .soil_activity_inhibition_g_c_per_m3_per_step = 50, .dissolved_carbon_product_inhibition_g_c_per_m3 = 100 });
    const nutrients = try nutrientLimitation(10, 0.2, 1, 0.02, 0.1, 1e-12);
    try std.testing.expectEqual(@as(f64, 0.5), nutrients.nitrogen);
    const result = try decompose(.{ .pool = .{ .carbon_g_c = 20, .nitrogen_g_n = 2, .phosphorus_g_p = 0.2 }, .active_carbon_g_c = 10, .total_colonized_carbon_g_c = 100, .specific_decomposition_rate_g_c_per_g_activity_h = 7.5, .microbial_activity_g_c_per_step = 2, .microbial_density_response = response.microbial_density_response, .dissolved_carbon_product_response = response.dissolved_carbon_product_response, .growth_temperature_response = 1, .nutrient_limitation = nutrients, .timestep_h = 1, .negligible_carbon_g_c = 1e-12 });
    try std.testing.expect(result.carbon_g_c > 0 and result.nitrogen_g_n > 0);
    try std.testing.expectApproxEqAbs(result.carbon_g_c * 0.1 / nutrients.nitrogen, result.nitrogen_g_n, 1e-14);
}

test "lignin humification and dissolved remainder conserve C N P" {
    const decomposed = [_]organic.ElementPool{
        .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 },
        .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 },
        .{ .carbon_g_c = 3, .nitrogen_g_n = 0.3, .phosphorus_g_p = 0.03 },
        .{ .carbon_g_c = 4, .nitrogen_g_n = 0.4, .phosphorus_g_p = 0.04 },
        .{ .carbon_g_c = 0.5, .nitrogen_g_n = 0.05, .phosphorus_g_p = 0.005 },
    };
    const products = try partitionStructuralProducts(decomposed, true, 0.05, 0.005);
    for (0..organic.structural_fraction_count) |fraction| inline for (@typeInfo(organic.ElementPool).@"struct".fields) |field| try std.testing.expectApproxEqAbs(@field(decomposed[fraction], field.name), @field(products.particulate[fraction], field.name) + @field(products.dissolved[fraction], field.name), 1e-14);
    try std.testing.expect(products.particulate[3].carbon_g_c > 0);
}
