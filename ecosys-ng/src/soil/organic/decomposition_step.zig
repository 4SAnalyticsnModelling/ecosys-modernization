const std = @import("std");
const compute = @import("../../core/compute.zig");
const organic = @import("initialization.zig");
const microbial = @import("../microbial/state.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const metabolism = @import("../microbial/metabolism.zig");
const decomposition = @import("../biogeochemistry/organic_substrate_decomposition.zig");
const parameters_module = @import("parameters.zig");
const priming_step = @import("priming_step.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    structural_decomposition: []organic.ElementPool,
    particulate_products: []organic.ElementPool,
    dissolved_structural_products: []organic.ElementPool,
    microbial_residue_decomposition: []organic.ElementPool,
    sorbed_organic_decomposition: []organic.ElementPool,
    sorbed_acetate_decomposition_g_c: []f64,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize) !State {
        if (layer_count == 0) return error.ZeroSoilOrganicDecompositionLayers;
        var result: State = .{ .allocator = allocator, .layer_count = layer_count, .structural_decomposition = undefined, .particulate_products = undefined, .dissolved_structural_products = undefined, .microbial_residue_decomposition = undefined, .sorbed_organic_decomposition = undefined, .sorbed_acetate_decomposition_g_c = undefined };
        const structural_count = try std.math.mul(usize, try std.math.mul(usize, layer_count, organic.substrate_count), organic.structural_fraction_count);
        const residue_count = try std.math.mul(usize, try std.math.mul(usize, layer_count, organic.substrate_count), organic.residue_fraction_count);
        const mobile_count = try std.math.mul(usize, layer_count, organic.substrate_count);
        var allocated: usize = 0;
        errdefer {
            if (allocated > 5) allocator.free(result.sorbed_acetate_decomposition_g_c);
            if (allocated > 4) allocator.free(result.sorbed_organic_decomposition);
            if (allocated > 3) allocator.free(result.microbial_residue_decomposition);
            if (allocated > 2) allocator.free(result.dissolved_structural_products);
            if (allocated > 1) allocator.free(result.particulate_products);
            if (allocated > 0) allocator.free(result.structural_decomposition);
        }
        result.structural_decomposition = try allocator.alloc(organic.ElementPool, structural_count);
        allocated += 1;
        result.particulate_products = try allocator.alloc(organic.ElementPool, structural_count);
        allocated += 1;
        result.dissolved_structural_products = try allocator.alloc(organic.ElementPool, structural_count);
        allocated += 1;
        result.microbial_residue_decomposition = try allocator.alloc(organic.ElementPool, residue_count);
        allocated += 1;
        result.sorbed_organic_decomposition = try allocator.alloc(organic.ElementPool, mobile_count);
        allocated += 1;
        result.sorbed_acetate_decomposition_g_c = try allocator.alloc(f64, mobile_count);
        allocated += 1;
        @memset(result.structural_decomposition, .{});
        @memset(result.particulate_products, .{});
        @memset(result.dissolved_structural_products, .{});
        @memset(result.microbial_residue_decomposition, .{});
        @memset(result.sorbed_organic_decomposition, .{});
        @memset(result.sorbed_acetate_decomposition_g_c, 0);
        return result;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.sorbed_acetate_decomposition_g_c);
        self.allocator.free(self.sorbed_organic_decomposition);
        self.allocator.free(self.microbial_residue_decomposition);
        self.allocator.free(self.dissolved_structural_products);
        self.allocator.free(self.particulate_products);
        self.allocator.free(self.structural_decomposition);
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    organic_state: *const organic.State,
    microbial_state: *const microbial.State,
    respiration_fluxes: *const fluxes.State,
    priming: ?*const priming_step.State = null,
    soil_temperature_k: []const f64,
    matrix_bulk_volume_m3: []const f64,
    bulk_density_megagrams_per_m3: []const f64,
    microbial_nitrogen_to_carbon_g_n_per_g_c: []const f64,
    microbial_phosphorus_to_carbon_g_p_per_g_c: []const f64,
    substrate_nitrogen_to_carbon_g_n_per_g_c: []const f64,
    substrate_phosphorus_to_carbon_g_p_per_g_c: []const f64,
    thermal_adaptation_offset_k_by_cell: []const f64,
    parameters: parameters_module.SoilOrganicDecompositionParameters,
    timestep_h: f64,
    negligible_carbon_g_c: f64,
};

pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const populations = context.microbial_state.population_count;
    for (range.first..range.end) |layer| for (0..organic.substrate_count) |substrate| {
        const mobile = layer * organic.substrate_count + substrate;
        const structural_base = mobile * organic.structural_fraction_count;
        const residue_base = mobile * organic.residue_fraction_count;
        var colonized_g_c: f64 = 0;
        for (0..organic.structural_fraction_count) |fraction| colonized_g_c += context.organic_state.colonized_structural_carbon_g_c[structural_base + fraction];
        for (0..organic.residue_fraction_count) |fraction| colonized_g_c += context.organic_state.residue[residue_base + fraction].carbon_g_c;
        colonized_g_c += context.organic_state.adsorbed[mobile].carbon_g_c + context.organic_state.adsorbed_acetate_carbon_g_c[mobile];
        var activity_g_c: f64 = 0;
        if (substrate < context.microbial_state.substrate_count) {
            for (0..populations) |population| activity_g_c += context.respiration_fluxes.substrate_unlimited_respiration_g_c[layer * context.respiration_fluxes.process_unit_count_per_layer + substrate * populations + population];
        }
        if (context.priming) |priming| activity_g_c += priming.exchange.activity_change_g_c[mobile];
        var actual_c: f64 = 0;
        var actual_n: f64 = 0;
        var actual_p: f64 = 0;
        var maximum_n: f64 = 0;
        var maximum_p: f64 = 0;
        if (substrate < context.microbial_state.substrate_count) for (0..populations) |population| {
            const runtime_index = try context.microbial_state.populationIndex(layer / context.microbial_state.layer_count, layer % context.microbial_state.layer_count, substrate, population);
            const target_base = (substrate * populations + population) * organic.kinetic_fraction_count;
            const pools = [3]@TypeOf(context.microbial_state.nonstructural[0]){ context.microbial_state.structural[runtime_index * 2], context.microbial_state.structural[runtime_index * 2 + 1], context.microbial_state.nonstructural[runtime_index] };
            for (pools, 0..) |pool, component| {
                const primed: organic.ElementPool = if (context.priming) |priming| priming.exchange.microbial_change[(layer * organic.substrate_count * populations + substrate * populations + population) * organic.kinetic_fraction_count + component] else .{};
                const carbon = pool.carbon_g_c + primed.carbon_g_c;
                actual_c += carbon;
                actual_n += pool.nitrogen_g_n + primed.nitrogen_g_n;
                actual_p += pool.phosphorus_g_p + primed.phosphorus_g_p;
                maximum_n += carbon * context.microbial_nitrogen_to_carbon_g_n_per_g_c[target_base + component];
                maximum_p += carbon * context.microbial_phosphorus_to_carbon_g_p_per_g_c[target_base + component];
            }
        };
        const nutrient = try decomposition.nutrientLimitation(actual_c, actual_n, maximum_n, actual_p, maximum_p, context.negligible_carbon_g_c);
        const substrate_fraction = if (substrate < context.microbial_state.substrate_count) context.respiration_fluxes.substrate_complex_fraction[layer * context.respiration_fluxes.process_unit_count_per_layer + substrate * populations] else 0;
        const active_water_m3 = context.respiration_fluxes.layer_biologically_active_water_m3[layer];
        const effective_water_m3 = active_water_m3 * substrate_fraction;
        const primed_doc_g_c = if (context.priming) |priming| priming.exchange.dissolved_change[mobile].carbon_g_c else 0;
        const doc_concentration = if (effective_water_m3 > context.negligible_carbon_g_c) (context.organic_state.dissolved[mobile].carbon_g_c + primed_doc_g_c) / effective_water_m3 else 0;
        const environment = try decomposition.environment(.{ .is_surface = false, .total_colonized_carbon_g_c = colonized_g_c, .microbial_activity_g_c_per_step = activity_g_c, .biologically_active_water_m3 = active_water_m3, .soil_mass_megagrams = context.matrix_bulk_volume_m3[layer] * context.bulk_density_megagrams_per_m3[layer], .bulk_volume_m3 = context.matrix_bulk_volume_m3[layer], .dissolved_carbon_concentration_g_c_per_m3 = doc_concentration, .timestep_h = context.timestep_h, .negligible_carbon_g_c = context.negligible_carbon_g_c }, context.parameters.environment);
        const temperature = try metabolism.growthTemperatureResponse(context.soil_temperature_k[layer], context.thermal_adaptation_offset_k_by_cell[layer / context.microbial_state.layer_count]);
        var decomposed: [organic.structural_fraction_count]organic.ElementPool = undefined;
        for (0..organic.structural_fraction_count) |fraction| {
            decomposed[fraction] = try decomposition.decompose(.{ .pool = context.organic_state.structural[structural_base + fraction], .active_carbon_g_c = context.organic_state.colonized_structural_carbon_g_c[structural_base + fraction], .total_colonized_carbon_g_c = colonized_g_c, .specific_decomposition_rate_g_c_per_g_activity_h = context.parameters.structural_rate_g_c_per_g_activity_h[substrate][fraction], .microbial_activity_g_c_per_step = activity_g_c, .microbial_density_response = environment.microbial_density_response, .dissolved_carbon_product_response = environment.dissolved_carbon_product_response, .growth_temperature_response = temperature, .nutrient_limitation = nutrient, .timestep_h = context.timestep_h, .negligible_carbon_g_c = context.negligible_carbon_g_c });
            context.result.structural_decomposition[structural_base + fraction] = decomposed[fraction];
        }
        const products = try decomposition.partitionStructuralProducts(decomposed, substrate <= 2, context.substrate_nitrogen_to_carbon_g_n_per_g_c[3], context.substrate_phosphorus_to_carbon_g_p_per_g_c[3]);
        for (0..organic.structural_fraction_count) |fraction| {
            context.result.particulate_products[structural_base + fraction] = products.particulate[fraction];
            context.result.dissolved_structural_products[structural_base + fraction] = products.dissolved[fraction];
        }
        for (0..organic.residue_fraction_count) |fraction| context.result.microbial_residue_decomposition[residue_base + fraction] = try decomposition.decompose(.{ .pool = context.organic_state.residue[residue_base + fraction], .active_carbon_g_c = context.organic_state.residue[residue_base + fraction].carbon_g_c, .total_colonized_carbon_g_c = colonized_g_c, .specific_decomposition_rate_g_c_per_g_activity_h = context.parameters.microbial_residue_rate_g_c_per_g_activity_h[fraction], .microbial_activity_g_c_per_step = activity_g_c, .microbial_density_response = environment.microbial_density_response, .dissolved_carbon_product_response = environment.dissolved_carbon_product_response, .growth_temperature_response = temperature, .nutrient_limitation = nutrient, .timestep_h = context.timestep_h, .negligible_carbon_g_c = context.negligible_carbon_g_c });
        const sorbed = try decomposition.decomposeSorbed(context.organic_state.adsorbed[mobile], context.organic_state.adsorbed_acetate_carbon_g_c[mobile], .{ .pool = .{}, .active_carbon_g_c = 0, .total_colonized_carbon_g_c = colonized_g_c, .specific_decomposition_rate_g_c_per_g_activity_h = 0, .microbial_activity_g_c_per_step = activity_g_c, .microbial_density_response = environment.microbial_density_response, .dissolved_carbon_product_response = environment.dissolved_carbon_product_response, .growth_temperature_response = temperature, .nutrient_limitation = nutrient, .timestep_h = context.timestep_h, .negligible_carbon_g_c = context.negligible_carbon_g_c }, context.parameters.sorbed_organic_rate_g_c_per_g_activity_h, context.parameters.sorbed_acetate_rate_g_c_per_g_activity_h);
        context.result.sorbed_organic_decomposition[mobile] = sorbed.organic;
        context.result.sorbed_acetate_decomposition_g_c[mobile] = sorbed.acetate_carbon_g_c;
    };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.result.layer_count;
    const ratio_count = context.microbial_state.substrate_count * context.microbial_state.population_count * organic.kinetic_fraction_count;
    if (range.first > range.end or range.end > layers or context.organic_state.layer_count != layers or context.microbial_state.cell_count * context.microbial_state.layer_count != layers or context.respiration_fluxes.layer_count != layers or (context.priming != null and context.priming.?.exchange.cell_count != layers) or context.soil_temperature_k.len != layers or context.matrix_bulk_volume_m3.len != layers or context.bulk_density_megagrams_per_m3.len != layers or context.thermal_adaptation_offset_k_by_cell.len != context.microbial_state.cell_count or context.microbial_nitrogen_to_carbon_g_n_per_g_c.len != ratio_count or context.microbial_phosphorus_to_carbon_g_p_per_g_c.len != ratio_count or context.substrate_nitrogen_to_carbon_g_n_per_g_c.len != organic.substrate_count or context.substrate_phosphorus_to_carbon_g_p_per_g_c.len != organic.substrate_count) return error.SoilOrganicDecompositionDimensionMismatch;
    for (context.thermal_adaptation_offset_k_by_cell) |value| if (!std.math.isFinite(value)) return error.NonFiniteMicrobialThermalAdaptationOffset;
}

test "soil decomposition stages structural residue sorbed and charcoal fluxes" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    for (0..organic.structural_fraction_count) |fraction| {
        organic_state.structural[fraction] = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.1 };
        organic_state.colonized_structural_carbon_g_c[fraction] = 5;
    }
    organic_state.residue[0] = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 };
    organic_state.adsorbed[0] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    organic_state.adsorbed_acetate_carbon_g_c[0] = 1;
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, organic.substrate_count, 1);
    defer microbial_state.deinit();
    microbial_state.structural[0] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    var respiration = try fluxes.State.init(std.testing.allocator, 1, organic.substrate_count);
    defer respiration.deinit();
    respiration.substrate_unlimited_respiration_g_c[0] = 1;
    respiration.substrate_complex_fraction[0] = 1;
    respiration.layer_biologically_active_water_m3[0] = 1;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const rates = [_][organic.structural_fraction_count]f64{.{ 7.5, 7.5, 1.5, 0.5, 0.0015 }} ** organic.substrate_count;
    var context: ApplyContext = .{ .result = &state, .organic_state = &organic_state, .microbial_state = &microbial_state, .respiration_fluxes = &respiration, .soil_temperature_k = &.{293.15}, .matrix_bulk_volume_m3 = &.{1}, .bulk_density_megagrams_per_m3 = &.{1}, .microbial_nitrogen_to_carbon_g_n_per_g_c = &.{ 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1 }, .microbial_phosphorus_to_carbon_g_p_per_g_c = &.{ 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01 }, .substrate_nitrogen_to_carbon_g_n_per_g_c = &.{ 0.0333, 0.0333, 0.0333, 0.05, 0.167 }, .substrate_phosphorus_to_carbon_g_p_per_g_c = &.{ 0.00333, 0.00333, 0.00333, 0.005, 0.0167 }, .thermal_adaptation_offset_k_by_cell = &.{0}, .parameters = .{ .structural_rate_g_c_per_g_activity_h = rates, .microbial_residue_rate_g_c_per_g_activity_h = .{ 7.5, 1.5 }, .sorbed_organic_rate_g_c_per_g_activity_h = 0.25, .sorbed_acetate_rate_g_c_per_g_activity_h = 0.25, .environment = .{ .surface_activity_half_saturation_g_c_per_m3 = 10, .soil_activity_half_saturation_g_c_per_m3 = 10, .surface_activity_inhibition_g_c_per_m3_per_step = 50, .soil_activity_inhibition_g_c_per_m3_per_step = 50, .dissolved_carbon_product_inhibition_g_c_per_m3 = 1200 } }, .timestep_h = 1, .negligible_carbon_g_c = 1e-12 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.structural_decomposition[0].carbon_g_c > 0);
    try std.testing.expect(state.structural_decomposition[4].carbon_g_c > 0);
    try std.testing.expect(state.microbial_residue_decomposition[0].carbon_g_c > 0);
    try std.testing.expect(state.sorbed_organic_decomposition[0].carbon_g_c > 0);
    try std.testing.expect(state.sorbed_acetate_decomposition_g_c[0] > 0);
}
