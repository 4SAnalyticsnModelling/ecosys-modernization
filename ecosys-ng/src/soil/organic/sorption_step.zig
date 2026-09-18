const std = @import("std");
const compute = @import("../../core/compute.zig");
const organic = @import("initialization.zig");
const microbial = @import("../microbial/state.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const sorption = @import("sorption.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    exchange: []sorption.Flux,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize) !State {
        if (layer_count == 0) return error.ZeroSoilOrganicSorptionLayers;
        const exchange = try allocator.alloc(sorption.Flux, try std.math.mul(usize, layer_count, organic.substrate_count));
        @memset(exchange, .{ .doc_g_c = 0, .acetate_g_c = 0, .don_g_n = 0, .dop_g_p = 0 });
        return .{ .allocator = allocator, .layer_count = layer_count, .exchange = exchange };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.exchange);
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    organic_state: *const organic.State,
    microbial_state: *const microbial.State,
    respiration_fluxes: *const fluxes.State,
    water_volume_m3: []const f64,
    matrix_bulk_volume_m3: []const f64,
    bulk_density_megagrams_per_m3: []const f64,
    anion_exchange_capacity_mol_per_megagram: []const f64,
    sorption_rate_per_h: f64,
    adsorption_coefficient: f64,
    timestep_h: f64,
    negligible_water_volume_m3: f64,
    negligible_carbon_g_c: f64,
    negligible_nitrogen_g_n: f64,
    negligible_phosphorus_g_p: f64,
};

/// Layer-tiled NITRO CSORP/CSORPA/ZSORP/PSORP staging. Positive exchange
/// moves dissolved matter to the adsorbed inventory; negative exchange
/// desorbs it. StateUpdate is deferred to the combined soil transaction.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const populations = context.microbial_state.population_count;
    for (range.first..range.end) |layer| for (0..organic.substrate_count) |substrate| {
        const mobile = layer * organic.substrate_count + substrate;
        const substrate_fraction = if (substrate < context.microbial_state.substrate_count)
            context.respiration_fluxes.substrate_complex_fraction[layer * context.respiration_fluxes.process_unit_count_per_layer + substrate * populations]
        else
            0;
        const dissolved = context.organic_state.dissolved[mobile];
        const adsorbed = context.organic_state.adsorbed[mobile];
        const dissolved_total_c = dissolved.carbon_g_c + context.organic_state.dissolved_acetate_carbon_g_c[mobile];
        const doc_fraction = if (dissolved_total_c > context.negligible_carbon_g_c) dissolved.carbon_g_c / dissolved_total_c else 0;
        context.result.exchange[mobile] = try sorption.calculate(.{
            .dissolved = .{ .doc_g_c = dissolved.carbon_g_c, .acetate_g_c = context.organic_state.dissolved_acetate_carbon_g_c[mobile], .don_g_n = dissolved.nitrogen_g_n, .dop_g_p = dissolved.phosphorus_g_p },
            .adsorbed = .{ .doc_g_c = adsorbed.carbon_g_c, .acetate_g_c = context.organic_state.adsorbed_acetate_carbon_g_c[mobile], .don_g_n = adsorbed.nitrogen_g_n, .dop_g_p = adsorbed.phosphorus_g_p },
        }, .{
            .water_volume_m3 = context.water_volume_m3[layer],
            .soil_mass_megagrams = context.matrix_bulk_volume_m3[layer] * context.bulk_density_megagrams_per_m3[layer],
            .anion_exchange_capacity_mol_per_megagram = context.anion_exchange_capacity_mol_per_megagram[layer],
            .adsorption_coefficient = context.adsorption_coefficient,
            .substrate_complex_fraction = substrate_fraction,
            .doc_fraction_of_dissolved_carbon = doc_fraction,
            .acetate_fraction_of_dissolved_carbon = 1 - doc_fraction,
            .sorption_rate_per_h = context.sorption_rate_per_h,
            .timestep_h = context.timestep_h,
            .negligible_water_volume_m3 = context.negligible_water_volume_m3,
            .negligible_carbon_g_c = context.negligible_carbon_g_c,
            .negligible_nitrogen_g_n = context.negligible_nitrogen_g_n,
            .negligible_phosphorus_g_p = context.negligible_phosphorus_g_p,
        });
    };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.result.layer_count;
    if (range.first > range.end or range.end > layers or context.organic_state.layer_count != layers or context.microbial_state.cell_count * context.microbial_state.layer_count != layers or context.respiration_fluxes.layer_count != layers or context.respiration_fluxes.process_unit_count_per_layer != context.microbial_state.substrate_count * context.microbial_state.population_count or context.water_volume_m3.len != layers or context.matrix_bulk_volume_m3.len != layers or context.bulk_density_megagrams_per_m3.len != layers or context.anion_exchange_capacity_mol_per_megagram.len != layers) return error.SoilOrganicSorptionDimensionMismatch;
    inline for (.{ context.sorption_rate_per_h, context.adsorption_coefficient, context.timestep_h, context.negligible_water_volume_m3, context.negligible_carbon_g_c, context.negligible_nitrogen_g_n, context.negligible_phosphorus_g_p }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilOrganicSorptionParameter;
    if (context.timestep_h <= 0) return error.InvalidSoilOrganicSorptionParameter;
}

test "soil organic sorption stages conservative runtime substrate exchanges" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.dissolved[0] = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.1 };
    organic_state.dissolved_acetate_carbon_g_c[0] = 2;
    organic_state.adsorbed[0] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, organic.substrate_count, 1);
    defer microbial_state.deinit();
    var respiration = try fluxes.State.init(std.testing.allocator, 1, organic.substrate_count);
    defer respiration.deinit();
    respiration.substrate_complex_fraction[0] = 1;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var context: ApplyContext = .{ .result = &state, .organic_state = &organic_state, .microbial_state = &microbial_state, .respiration_fluxes = &respiration, .water_volume_m3 = &.{1}, .matrix_bulk_volume_m3 = &.{2}, .bulk_density_megagrams_per_m3 = &.{1}, .anion_exchange_capacity_mol_per_megagram = &.{100}, .sorption_rate_per_h = 0.1, .adsorption_coefficient = 1, .timestep_h = 1, .negligible_water_volume_m3 = 1e-12, .negligible_carbon_g_c = 1e-12, .negligible_nitrogen_g_n = 1e-12, .negligible_phosphorus_g_p = 1e-12 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.exchange[0].doc_g_c > 0);
    try std.testing.expect(state.exchange[0].don_g_n > 0);
    try std.testing.expectEqual(@as(f64, 10), organic_state.dissolved[0].carbon_g_c);
}
