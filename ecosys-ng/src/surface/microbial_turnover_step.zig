const std = @import("std");
const compute = @import("../core/compute.zig");
const organic = @import("../soil/organic/initialization.zig");
const metabolism = @import("../soil/microbial/metabolism.zig");
const respiration = @import("microbial_respiration_step.zig");
const maintenance = @import("microbial_maintenance_step.zig");

pub const structural_component_count: usize = 2;

pub const Parameters = struct {
    basal_decomposition_rate_per_h: [structural_component_count]f64,
    minimum_carbon_recycling_fraction: f64,
    carbon_recycling_range_fraction: f64,
    maximum_nitrogen_recycling_fraction: f64,
    maximum_phosphorus_recycling_fraction: f64,
    dissolved_priming_rate_per_h: f64,
    microbial_priming_rate_per_h: f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    basal: []metabolism.DecompositionResult,
    senescence: []metabolism.DecompositionResult,
    senescence_recycled_carbon_respiration_g_c: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceMicrobialTurnoverCells;
        const component_count = try std.math.mul(usize, try std.math.mul(usize, cell_count, respiration.unit_count_per_cell), structural_component_count);
        const basal = try allocator.alloc(metabolism.DecompositionResult, component_count);
        errdefer allocator.free(basal);
        const senescence = try allocator.alloc(metabolism.DecompositionResult, component_count);
        errdefer allocator.free(senescence);
        const senescence_respiration = try allocator.alloc(f64, component_count);
        @memset(basal, zeroResult());
        @memset(senescence, zeroResult());
        @memset(senescence_respiration, 0);
        return .{ .allocator = allocator, .cell_count = cell_count, .basal = basal, .senescence = senescence, .senescence_recycled_carbon_respiration_g_c = senescence_respiration };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.senescence_recycled_carbon_respiration_g_c);
        self.allocator.free(self.senescence);
        self.allocator.free(self.basal);
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    surface_organic: *const organic.State,
    maintenance: *const maintenance.State,
    growth_temperature_response: []const f64,
    matric_plus_osmotic_potential_megapascal: []const f64,
    humification_fraction: []const f64,
    microbial_nitrogen_to_carbon_g_n_per_g_c: []const f64,
    microbial_phosphorus_to_carbon_g_p_per_g_c: []const f64,
    labile_biomass_fraction: f64,
    decomposition_density_half_saturation_g_c_per_g_c: f64,
    humus_nitrogen_per_carbon_g_n_per_g_c: f64,
    humus_phosphorus_per_carbon_g_p_per_g_c: f64,
    negligible_carbon_g_c: f64,
    timestep_h: f64,
    parameters: Parameters,
};

/// NITRO RCCC/RCCN/RCCP, RXOM*, R3OM*, RDOM*, RHOM*/RCOM*,
/// and maintenance-deficit RXMM*/R3MM*/RHMM*/RCMM* for surface litter.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |cell| for (0..respiration.litter_complex_count) |complex| {
        var colonized_substrate_g_c: f64 = 0;
        for (0..organic.structural_fraction_count) |fraction| colonized_substrate_g_c += context.surface_organic.colonized_structural_carbon_g_c[(cell * organic.substrate_count + complex) * organic.structural_fraction_count + fraction];
        for (0..organic.residue_fraction_count) |fraction| colonized_substrate_g_c += context.surface_organic.residue[(cell * organic.substrate_count + complex) * organic.residue_fraction_count + fraction].carbon_g_c;
        const mobile = cell * organic.substrate_count + complex;
        colonized_substrate_g_c += context.surface_organic.adsorbed[mobile].carbon_g_c + context.surface_organic.adsorbed_acetate_carbon_g_c[mobile];

        for (0..respiration.source_population_count) |population| {
            const local_unit = complex * respiration.source_population_count + population;
            const unit = cell * respiration.unit_count_per_cell + local_unit;
            const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
            const labile = context.surface_organic.microbial[microbial];
            const resistant = context.surface_organic.microbial[microbial + 1];
            const nonstructural = context.surface_organic.microbial[microbial + 2];
            const ratio_base = (complex * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
            const recycling = try metabolism.recyclingFractions(toMetabolic(nonstructural), context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio_base], context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio_base], .{
                .minimum_carbon_fraction = context.parameters.minimum_carbon_recycling_fraction,
                .carbon_range_fraction = context.parameters.carbon_recycling_range_fraction,
                .maximum_nitrogen_fraction = context.parameters.maximum_nitrogen_recycling_fraction,
                .maximum_phosphorus_fraction = context.parameters.maximum_phosphorus_recycling_fraction,
            });
            const active_biomass_g_c = labile.carbon_g_c / context.labile_biomass_fraction;
            const concentration = if (colonized_substrate_g_c > context.negligible_carbon_g_c) active_biomass_g_c / colonized_substrate_g_c else 0;
            const decomposition_density_response = if (colonized_substrate_g_c > context.negligible_carbon_g_c) concentration / (concentration + context.decomposition_density_half_saturation_g_c_per_g_c) else 1;
            const water_response = @exp((if (population == 2) @as(f64, 0.05) else 0.10) * context.matric_plus_osmotic_potential_megapascal[cell]);
            const pools = [_]organic.ElementPool{ labile, resistant };
            for (0..structural_component_count) |component| {
                const index = unit * structural_component_count + component;
                context.result.basal[index] = try metabolism.decompose(.{
                    .pool = toMetabolic(pools[component]),
                    .temperature_response = context.growth_temperature_response[cell],
                    .water_response = water_response,
                    .basal_decomposition_rate_per_h = context.parameters.basal_decomposition_rate_per_h[component],
                    .microbial_carbon_response = decomposition_density_response,
                    .timestep_h = context.timestep_h,
                    .recycling = recycling,
                    .humification_fraction = context.humification_fraction[cell],
                    .humus_nitrogen_per_carbon_g_n_per_g_c = context.humus_nitrogen_per_carbon_g_n_per_g_c,
                    .humus_phosphorus_per_carbon_g_p_per_g_c = context.humus_phosphorus_per_carbon_g_p_per_g_c,
                });
            }
            const active_n = if (labile.carbon_g_c > context.negligible_carbon_g_c) labile.nitrogen_g_n / labile.carbon_g_c else context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio_base];
            const active_p = if (labile.carbon_g_c > context.negligible_carbon_g_c) labile.phosphorus_g_p / labile.carbon_g_c else context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio_base];
            const accelerated = try metabolism.acceleratedSenescence(.{
                .structural = .{ toMetabolic(labile), toMetabolic(resistant) },
                .component_maintenance_respiration_g_c = .{ context.maintenance.labile_maintenance_respiration_g_c[unit], context.maintenance.resistant_maintenance_respiration_g_c[unit] },
                .total_maintenance_respiration_g_c = context.maintenance.total_maintenance_respiration_g_c[unit],
                .senescence_respiration_deficit_g_c = context.maintenance.senescence_respiration_deficit_g_c[unit],
                .recycling = recycling,
                .active_nitrogen_per_carbon_g_n_per_g_c = active_n,
                .active_phosphorus_per_carbon_g_p_per_g_c = active_p,
                .humification_fraction = context.humification_fraction[cell],
                .humus_nitrogen_per_carbon_g_n_per_g_c = context.humus_nitrogen_per_carbon_g_n_per_g_c,
                .humus_phosphorus_per_carbon_g_p_per_g_c = context.humus_phosphorus_per_carbon_g_p_per_g_c,
                .negligible_g_c = context.negligible_carbon_g_c,
            });
            for (0..structural_component_count) |component| {
                const index = unit * structural_component_count + component;
                context.result.senescence[index] = accelerated.component[component];
                context.result.senescence_recycled_carbon_respiration_g_c[index] = accelerated.component[component].recycled.carbon_g_c;
            }
        }
    };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const cells = context.result.cell_count;
    const ratio_count = organic.substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count;
    if (range.first > range.end or range.end > cells or context.surface_organic.layer_count != cells or context.maintenance.cell_count != cells or context.growth_temperature_response.len != cells or context.matric_plus_osmotic_potential_megapascal.len != cells or context.humification_fraction.len != cells or context.microbial_nitrogen_to_carbon_g_n_per_g_c.len != ratio_count or context.microbial_phosphorus_to_carbon_g_p_per_g_c.len != ratio_count) return error.SurfaceMicrobialTurnoverDimensionMismatch;
    inline for (.{ context.labile_biomass_fraction, context.decomposition_density_half_saturation_g_c_per_g_c, context.humus_nitrogen_per_carbon_g_n_per_g_c, context.humus_phosphorus_per_carbon_g_p_per_g_c, context.negligible_carbon_g_c, context.timestep_h, context.parameters.minimum_carbon_recycling_fraction, context.parameters.carbon_recycling_range_fraction, context.parameters.maximum_nitrogen_recycling_fraction, context.parameters.maximum_phosphorus_recycling_fraction, context.parameters.dissolved_priming_rate_per_h, context.parameters.microbial_priming_rate_per_h }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceMicrobialTurnoverParameter;
    if (context.labile_biomass_fraction <= 0 or context.labile_biomass_fraction > 1 or context.decomposition_density_half_saturation_g_c_per_g_c <= 0 or context.humus_nitrogen_per_carbon_g_n_per_g_c <= 0 or context.humus_phosphorus_per_carbon_g_p_per_g_c <= 0 or context.timestep_h <= 0 or context.parameters.minimum_carbon_recycling_fraction + context.parameters.carbon_recycling_range_fraction > 1 or context.parameters.maximum_nitrogen_recycling_fraction > 1 or context.parameters.maximum_phosphorus_recycling_fraction > 1) return error.InvalidSurfaceMicrobialTurnoverParameter;
    for (context.parameters.basal_decomposition_rate_per_h) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceMicrobialTurnoverParameter;
    for (context.humification_fraction) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidSurfaceMicrobialTurnoverParameter;
}

fn toMetabolic(value: organic.ElementPool) metabolism.ElementalPool {
    return .{ .carbon_g_c = value.carbon_g_c, .nitrogen_g_n = value.nitrogen_g_n, .phosphorus_g_p = value.phosphorus_g_p };
}

fn zeroResult() metabolism.DecompositionResult {
    const zero: metabolism.ElementalPool = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    return .{ .decomposed = zero, .recycled = zero, .humified = zero, .microbial_residue = zero };
}

test "surface turnover reproduces recycling decomposition and senescence routing" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.microbial[0] = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.2 };
    organic_state.microbial[1] = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.5, .phosphorus_g_p = 0.1 };
    organic_state.microbial[2] = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.04 };
    organic_state.colonized_structural_carbon_g_c[0] = 20;
    var maintenance_state = try maintenance.State.init(std.testing.allocator, 1);
    defer maintenance_state.deinit();
    maintenance_state.labile_maintenance_respiration_g_c[0] = 0.6;
    maintenance_state.resistant_maintenance_respiration_g_c[0] = 0.4;
    maintenance_state.total_maintenance_respiration_g_c[0] = 1;
    maintenance_state.senescence_respiration_deficit_g_c[0] = 0.2;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const n = [_]f64{0.1} ** (organic.substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    const p = [_]f64{0.02} ** (organic.substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .maintenance = &maintenance_state, .growth_temperature_response = &.{1}, .matric_plus_osmotic_potential_megapascal = &.{0}, .humification_fraction = &.{0.2}, .microbial_nitrogen_to_carbon_g_n_per_g_c = &n, .microbial_phosphorus_to_carbon_g_p_per_g_c = &p, .labile_biomass_fraction = 0.5, .decomposition_density_half_saturation_g_c_per_g_c = 0.01, .humus_nitrogen_per_carbon_g_n_per_g_c = 0.167, .humus_phosphorus_per_carbon_g_p_per_g_c = 0.0167, .negligible_carbon_g_c = 1e-12, .timestep_h = 1, .parameters = .{ .basal_decomposition_rate_per_h = .{ 0.01, 0.001 }, .minimum_carbon_recycling_fraction = 0.167, .carbon_recycling_range_fraction = 0.333, .maximum_nitrogen_recycling_fraction = 0.333, .maximum_phosphorus_recycling_fraction = 0.333, .dissolved_priming_rate_per_h = 0.01, .microbial_priming_rate_per_h = 0.001 } };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.basal[0].decomposed.carbon_g_c > 0);
    try std.testing.expect(state.senescence[0].decomposed.carbon_g_c > 0);
    const results = [_]metabolism.DecompositionResult{ state.basal[0], state.senescence[0] };
    for (results) |result| try std.testing.expectApproxEqAbs(result.decomposed.carbon_g_c, result.recycled.carbon_g_c + result.humified.carbon_g_c + result.microbial_residue.carbon_g_c, 1e-12);
}
