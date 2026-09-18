const std = @import("std");
const compute = @import("../core/compute.zig");
const organic = @import("../soil/organic/initialization.zig");
const decomposition = @import("../soil/biogeochemistry/organic_substrate_decomposition.zig");
const respiration = @import("microbial_respiration_step.zig");
const priming = @import("organic_priming_step.zig");

pub const Parameters = struct {
    structural_rate_g_c_per_g_activity_h: [respiration.litter_complex_count][organic.structural_fraction_count]f64,
    microbial_residue_rate_g_c_per_g_activity_h: [organic.residue_fraction_count]f64,
    sorbed_organic_rate_g_c_per_g_activity_h: f64,
    sorbed_acetate_rate_g_c_per_g_activity_h: f64,
    environment: decomposition.EnvironmentParameters,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    structural_decomposition: []organic.ElementPool,
    particulate_products: []organic.ElementPool,
    dissolved_structural_products: []organic.ElementPool,
    microbial_residue_decomposition: []organic.ElementPool,
    sorbed_organic_decomposition: []organic.ElementPool,
    sorbed_acetate_decomposition_g_c: []f64,
    post_priming_activity_g_c_per_step: []f64,
    microbial_density_response: []f64,
    dissolved_carbon_product_response: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceOrganicDecompositionCells;
        const complexes = try std.math.mul(usize, cell_count, respiration.litter_complex_count);
        const structural_count = try std.math.mul(usize, complexes, organic.structural_fraction_count);
        const residue_count = try std.math.mul(usize, complexes, organic.residue_fraction_count);
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        result.structural_decomposition = try allocator.alloc(organic.ElementPool, structural_count);
        errdefer allocator.free(result.structural_decomposition);
        result.particulate_products = try allocator.alloc(organic.ElementPool, structural_count);
        errdefer allocator.free(result.particulate_products);
        result.dissolved_structural_products = try allocator.alloc(organic.ElementPool, structural_count);
        errdefer allocator.free(result.dissolved_structural_products);
        result.microbial_residue_decomposition = try allocator.alloc(organic.ElementPool, residue_count);
        errdefer allocator.free(result.microbial_residue_decomposition);
        result.sorbed_organic_decomposition = try allocator.alloc(organic.ElementPool, complexes);
        errdefer allocator.free(result.sorbed_organic_decomposition);
        result.sorbed_acetate_decomposition_g_c = try allocator.alloc(f64, complexes);
        errdefer allocator.free(result.sorbed_acetate_decomposition_g_c);
        result.post_priming_activity_g_c_per_step = try allocator.alloc(f64, complexes);
        errdefer allocator.free(result.post_priming_activity_g_c_per_step);
        result.microbial_density_response = try allocator.alloc(f64, complexes);
        errdefer allocator.free(result.microbial_density_response);
        result.dissolved_carbon_product_response = try allocator.alloc(f64, complexes);
        @memset(result.structural_decomposition, .{});
        @memset(result.particulate_products, .{});
        @memset(result.dissolved_structural_products, .{});
        @memset(result.microbial_residue_decomposition, .{});
        @memset(result.sorbed_organic_decomposition, .{});
        @memset(result.sorbed_acetate_decomposition_g_c, 0);
        @memset(result.post_priming_activity_g_c_per_step, 0);
        @memset(result.microbial_density_response, 0);
        @memset(result.dissolved_carbon_product_response, 0);
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64 or field.type == []organic.ElementPool) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    surface_organic: *const organic.State,
    respiration: *const respiration.State,
    priming: *const priming.State,
    biologically_active_water_m3: []const f64,
    litter_bulk_volume_m3: []const f64,
    growth_temperature_response: []const f64,
    microbial_nitrogen_to_carbon_g_n_per_g_c: []const f64,
    microbial_phosphorus_to_carbon_g_p_per_g_c: []const f64,
    particulate_nitrogen_per_carbon_g_n_per_g_c: f64,
    particulate_phosphorus_per_carbon_g_p_per_g_c: f64,
    labile_biomass_fraction: f64,
    timestep_h: f64,
    negligible_carbon_g_c: f64,
    parameters: Parameters,
};

/// Surface NITRO RDOS*, RHOS*/RCOS*, RDOR*, and RDOH* derivation.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |cell| for (0..respiration.litter_complex_count) |complex| {
        const compact = cell * respiration.litter_complex_count + complex;
        var total_active_carbon_g_c: f64 = 0;
        var total_active_nitrogen_g_n: f64 = 0;
        var maximum_active_nitrogen_g_n: f64 = 0;
        var total_active_phosphorus_g_p: f64 = 0;
        var maximum_active_phosphorus_g_p: f64 = 0;
        var activity_g_c: f64 = context.priming.exchange.activity_change_g_c[compact];
        for (0..respiration.source_population_count) |population| {
            const unit = cell * respiration.unit_count_per_cell + complex * respiration.source_population_count + population;
            activity_g_c += context.respiration.unlimited_respiration_g_c[unit];
            const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
            const labile = context.surface_organic.microbial[microbial];
            const active_carbon = labile.carbon_g_c / context.labile_biomass_fraction;
            const ratio_base = (complex * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
            const active_nitrogen_ratio = if (labile.carbon_g_c > context.negligible_carbon_g_c) labile.nitrogen_g_n / labile.carbon_g_c else context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio_base];
            const active_phosphorus_ratio = if (labile.carbon_g_c > context.negligible_carbon_g_c) labile.phosphorus_g_p / labile.carbon_g_c else context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio_base];
            total_active_carbon_g_c += active_carbon;
            total_active_nitrogen_g_n += active_carbon * active_nitrogen_ratio;
            maximum_active_nitrogen_g_n += active_carbon * context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio_base];
            total_active_phosphorus_g_p += active_carbon * active_phosphorus_ratio;
            maximum_active_phosphorus_g_p += active_carbon * context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio_base];
        }
        context.result.post_priming_activity_g_c_per_step[compact] = activity_g_c;
        const nutrient = try decomposition.nutrientLimitation(total_active_carbon_g_c, total_active_nitrogen_g_n, maximum_active_nitrogen_g_n, total_active_phosphorus_g_p, maximum_active_phosphorus_g_p, context.negligible_carbon_g_c);
        const structural_base = (cell * organic.substrate_count + complex) * organic.structural_fraction_count;
        const residue_base = (cell * organic.substrate_count + complex) * organic.residue_fraction_count;
        var total_colonized_g_c: f64 = 0;
        for (0..organic.structural_fraction_count) |fraction| total_colonized_g_c += context.surface_organic.colonized_structural_carbon_g_c[structural_base + fraction];
        for (0..organic.residue_fraction_count) |fraction| total_colonized_g_c += context.surface_organic.residue[residue_base + fraction].carbon_g_c;
        const mobile = cell * organic.substrate_count + complex;
        total_colonized_g_c += context.surface_organic.adsorbed[mobile].carbon_g_c + context.surface_organic.adsorbed_acetate_carbon_g_c[mobile];
        const active_water = context.biologically_active_water_m3[cell];
        const dissolved_concentration = if (active_water > context.negligible_carbon_g_c) context.surface_organic.dissolved[mobile].carbon_g_c / active_water else 0;
        const response = try decomposition.environment(.{ .is_surface = true, .total_colonized_carbon_g_c = total_colonized_g_c, .microbial_activity_g_c_per_step = activity_g_c, .biologically_active_water_m3 = active_water, .soil_mass_megagrams = 0, .bulk_volume_m3 = context.litter_bulk_volume_m3[cell], .dissolved_carbon_concentration_g_c_per_m3 = dissolved_concentration, .timestep_h = context.timestep_h, .negligible_carbon_g_c = context.negligible_carbon_g_c }, context.parameters.environment);
        context.result.microbial_density_response[compact] = response.microbial_density_response;
        context.result.dissolved_carbon_product_response[compact] = response.dissolved_carbon_product_response;
        var structural_decomposed: [organic.structural_fraction_count]organic.ElementPool = undefined;
        for (0..organic.structural_fraction_count) |fraction| {
            structural_decomposed[fraction] = try decomposition.decompose(.{ .pool = context.surface_organic.structural[structural_base + fraction], .active_carbon_g_c = context.surface_organic.colonized_structural_carbon_g_c[structural_base + fraction], .total_colonized_carbon_g_c = total_colonized_g_c, .specific_decomposition_rate_g_c_per_g_activity_h = context.parameters.structural_rate_g_c_per_g_activity_h[complex][fraction], .microbial_activity_g_c_per_step = activity_g_c, .microbial_density_response = response.microbial_density_response, .dissolved_carbon_product_response = response.dissolved_carbon_product_response, .growth_temperature_response = context.growth_temperature_response[cell], .nutrient_limitation = nutrient, .timestep_h = context.timestep_h, .negligible_carbon_g_c = context.negligible_carbon_g_c });
            context.result.structural_decomposition[compact * organic.structural_fraction_count + fraction] = structural_decomposed[fraction];
        }
        const products = try decomposition.partitionStructuralProducts(structural_decomposed, true, context.particulate_nitrogen_per_carbon_g_n_per_g_c, context.particulate_phosphorus_per_carbon_g_p_per_g_c);
        for (0..organic.structural_fraction_count) |fraction| {
            context.result.particulate_products[compact * organic.structural_fraction_count + fraction] = products.particulate[fraction];
            context.result.dissolved_structural_products[compact * organic.structural_fraction_count + fraction] = products.dissolved[fraction];
        }
        for (0..organic.residue_fraction_count) |fraction| context.result.microbial_residue_decomposition[compact * organic.residue_fraction_count + fraction] = try decomposition.decompose(.{ .pool = context.surface_organic.residue[residue_base + fraction], .active_carbon_g_c = context.surface_organic.residue[residue_base + fraction].carbon_g_c, .total_colonized_carbon_g_c = total_colonized_g_c, .specific_decomposition_rate_g_c_per_g_activity_h = context.parameters.microbial_residue_rate_g_c_per_g_activity_h[fraction], .microbial_activity_g_c_per_step = activity_g_c, .microbial_density_response = response.microbial_density_response, .dissolved_carbon_product_response = response.dissolved_carbon_product_response, .growth_temperature_response = context.growth_temperature_response[cell], .nutrient_limitation = nutrient, .timestep_h = context.timestep_h, .negligible_carbon_g_c = context.negligible_carbon_g_c });
        const common: decomposition.RateInputs = .{ .pool = .{}, .active_carbon_g_c = 0, .total_colonized_carbon_g_c = total_colonized_g_c, .specific_decomposition_rate_g_c_per_g_activity_h = 0, .microbial_activity_g_c_per_step = activity_g_c, .microbial_density_response = response.microbial_density_response, .dissolved_carbon_product_response = response.dissolved_carbon_product_response, .growth_temperature_response = context.growth_temperature_response[cell], .nutrient_limitation = nutrient, .timestep_h = context.timestep_h, .negligible_carbon_g_c = context.negligible_carbon_g_c };
        const sorbed = try decomposition.decomposeSorbed(context.surface_organic.adsorbed[mobile], context.surface_organic.adsorbed_acetate_carbon_g_c[mobile], common, context.parameters.sorbed_organic_rate_g_c_per_g_activity_h, context.parameters.sorbed_acetate_rate_g_c_per_g_activity_h);
        context.result.sorbed_organic_decomposition[compact] = sorbed.organic;
        context.result.sorbed_acetate_decomposition_g_c[compact] = sorbed.acetate_carbon_g_c;
    };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const cells = context.result.cell_count;
    const ratios = organic.substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count;
    if (range.first > range.end or range.end > cells or context.surface_organic.layer_count != cells or context.respiration.cell_count != cells or context.priming.cellCount() != cells or context.biologically_active_water_m3.len != cells or context.litter_bulk_volume_m3.len != cells or context.growth_temperature_response.len != cells or context.microbial_nitrogen_to_carbon_g_n_per_g_c.len != ratios or context.microbial_phosphorus_to_carbon_g_p_per_g_c.len != ratios) return error.SurfaceOrganicDecompositionDimensionMismatch;
    inline for (.{ context.particulate_nitrogen_per_carbon_g_n_per_g_c, context.particulate_phosphorus_per_carbon_g_p_per_g_c, context.labile_biomass_fraction, context.timestep_h, context.negligible_carbon_g_c }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceOrganicDecompositionParameter;
    if (context.particulate_nitrogen_per_carbon_g_n_per_g_c <= 0 or context.particulate_phosphorus_per_carbon_g_p_per_g_c <= 0 or context.labile_biomass_fraction <= 0 or context.labile_biomass_fraction > 1 or context.timestep_h <= 0) return error.InvalidSurfaceOrganicDecompositionParameter;
}

test "surface structural residue and sorbed decomposition are derived together" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.structural[3] = .{ .carbon_g_c = 10, .nitrogen_g_n = 0.5, .phosphorus_g_p = 0.05 };
    organic_state.colonized_structural_carbon_g_c[3] = 10;
    organic_state.residue[0] = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 };
    organic_state.adsorbed[0] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    organic_state.adsorbed_acetate_carbon_g_c[0] = 1;
    organic_state.microbial[0] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    var respiration_state = try respiration.State.init(std.testing.allocator, 1);
    defer respiration_state.deinit();
    respiration_state.unlimited_respiration_g_c[0] = 1;
    var priming_state = try priming.State.init(std.testing.allocator, 1);
    defer priming_state.deinit();
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const n = [_]f64{0.1} ** (organic.substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    const p = [_]f64{0.01} ** (organic.substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    const structural_rates = [_][organic.structural_fraction_count]f64{.{ 7.5, 7.5, 1.5, 0.5, 0.0015 }} ** respiration.litter_complex_count;
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .respiration = &respiration_state, .priming = &priming_state, .biologically_active_water_m3 = &.{1}, .litter_bulk_volume_m3 = &.{1}, .growth_temperature_response = &.{1}, .microbial_nitrogen_to_carbon_g_n_per_g_c = &n, .microbial_phosphorus_to_carbon_g_p_per_g_c = &p, .particulate_nitrogen_per_carbon_g_n_per_g_c = 0.05, .particulate_phosphorus_per_carbon_g_p_per_g_c = 0.005, .labile_biomass_fraction = 0.55, .timestep_h = 1, .negligible_carbon_g_c = 1e-12, .parameters = .{ .structural_rate_g_c_per_g_activity_h = structural_rates, .microbial_residue_rate_g_c_per_g_activity_h = .{ 7.5, 1.5 }, .sorbed_organic_rate_g_c_per_g_activity_h = 0.25, .sorbed_acetate_rate_g_c_per_g_activity_h = 0.25, .environment = .{ .surface_activity_half_saturation_g_c_per_m3 = 10, .soil_activity_half_saturation_g_c_per_m3 = 10, .surface_activity_inhibition_g_c_per_m3_per_step = 50, .soil_activity_inhibition_g_c_per_m3_per_step = 50, .dissolved_carbon_product_inhibition_g_c_per_m3 = 1200 } } };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.structural_decomposition[3].carbon_g_c > 0);
    try std.testing.expect(state.microbial_residue_decomposition[0].carbon_g_c > 0);
    try std.testing.expect(state.sorbed_organic_decomposition[0].carbon_g_c > 0);
    try std.testing.expect(state.sorbed_acetate_decomposition_g_c[0] > 0);
}
