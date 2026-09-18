const std = @import("std");
const compute = @import("../../core/compute.zig");
const organic = @import("initialization.zig");
const microbial = @import("../microbial/state.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const priming = @import("../biogeochemistry/organic_priming_exchange.zig");
const metabolism = @import("../microbial/metabolism.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    exchange: priming.State,
    microbial_snapshot: []organic.ElementPool,
    microbial_temperature_water_response: []f64,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize, population_count: usize) !State {
        var exchange = try priming.State.init(allocator, layer_count, organic.substrate_count, population_count, organic.kinetic_fraction_count);
        errdefer exchange.deinit();
        const microbial_count = try std.math.mul(usize, try std.math.mul(usize, try std.math.mul(usize, layer_count, organic.substrate_count), population_count), organic.kinetic_fraction_count);
        const snapshot = try allocator.alloc(organic.ElementPool, microbial_count);
        errdefer allocator.free(snapshot);
        const response = try allocator.alloc(f64, try std.math.mul(usize, try std.math.mul(usize, layer_count, organic.substrate_count), population_count));
        @memset(snapshot, .{});
        @memset(response, 0);
        return .{ .allocator = allocator, .exchange = exchange, .microbial_snapshot = snapshot, .microbial_temperature_water_response = response };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.microbial_temperature_water_response);
        self.allocator.free(self.microbial_snapshot);
        self.exchange.deinit();
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    organic_state: *const organic.State,
    microbial_state: *const microbial.State,
    respiration_fluxes: *const fluxes.State,
    soil_temperature_k: []const f64,
    matric_plus_osmotic_potential_megapascal: []const f64,
    thermal_adaptation_offset_k_by_cell: []const f64,
    dissolved_priming_rate_per_h: f64,
    microbial_priming_rate_per_h: f64,
    timestep_h: f64,
    negligible_carbon_g_c: f64,
};

/// NITRO XFRK/XFRC/XFRN/XFRP/XFRA and XFMC/XFMN/XFMP for soil layers.
/// Pairwise changes remain extensive, equal-and-opposite, and unpublished.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const populations = context.microbial_state.population_count;
    const microbial_per_layer = organic.substrate_count * populations * organic.kinetic_fraction_count;
    const response_per_layer = organic.substrate_count * populations;
    for (range.first..range.end) |layer| {
        var substrate_carbon_g_c: [organic.substrate_count]f64 = .{0} ** organic.substrate_count;
        var activity_g_c: [organic.substrate_count]f64 = .{0} ** organic.substrate_count;
        var dissolved_available_after_uptake: [organic.substrate_count]organic.ElementPool = undefined;
        var acetate_available_after_uptake_g_c: [organic.substrate_count]f64 = undefined;
        const snapshot = context.result.microbial_snapshot[layer * microbial_per_layer ..][0..microbial_per_layer];
        const response = context.result.microbial_temperature_water_response[layer * response_per_layer ..][0..response_per_layer];
        @memset(snapshot, .{});
        const growth_temperature = try metabolism.growthTemperatureResponse(context.soil_temperature_k[layer], context.thermal_adaptation_offset_k_by_cell[layer / context.microbial_state.layer_count]);
        for (0..organic.substrate_count) |substrate| {
            const mobile = layer * organic.substrate_count + substrate;
            dissolved_available_after_uptake[substrate] = context.organic_state.dissolved[mobile];
            acetate_available_after_uptake_g_c[substrate] = context.organic_state.dissolved_acetate_carbon_g_c[mobile];
            const structural_base = mobile * organic.structural_fraction_count;
            for (0..organic.structural_fraction_count) |fraction| substrate_carbon_g_c[substrate] += context.organic_state.structural[structural_base + fraction].carbon_g_c;
            const residue_base = mobile * organic.residue_fraction_count;
            for (0..organic.residue_fraction_count) |fraction| substrate_carbon_g_c[substrate] += context.organic_state.residue[residue_base + fraction].carbon_g_c;
            substrate_carbon_g_c[substrate] += context.organic_state.adsorbed[mobile].carbon_g_c + context.organic_state.adsorbed_acetate_carbon_g_c[mobile];
            for (0..populations) |population| {
                if (substrate < context.microbial_state.substrate_count) {
                    const unit = layer * context.respiration_fluxes.process_unit_count_per_layer + substrate * populations + population;
                    dissolved_available_after_uptake[substrate].carbon_g_c -= context.respiration_fluxes.doc_uptake_g_c[unit];
                    dissolved_available_after_uptake[substrate].nitrogen_g_n -= context.respiration_fluxes.dissolved_organic_nitrogen_uptake_g_n[unit];
                    dissolved_available_after_uptake[substrate].phosphorus_g_p -= context.respiration_fluxes.dissolved_organic_phosphorus_uptake_g_p[unit];
                    acetate_available_after_uptake_g_c[substrate] -= context.respiration_fluxes.acetate_uptake_g_c[unit];
                    activity_g_c[substrate] += context.respiration_fluxes.substrate_unlimited_respiration_g_c[unit];
                    const runtime_index = try context.microbial_state.populationIndex(layer / context.microbial_state.layer_count, layer % context.microbial_state.layer_count, substrate, population);
                    const base = (substrate * populations + population) * organic.kinetic_fraction_count;
                    snapshot[base] = fromMicrobial(context.microbial_state.structural[runtime_index * 2]);
                    snapshot[base + 1] = fromMicrobial(context.microbial_state.structural[runtime_index * 2 + 1]);
                    snapshot[base + 2] = fromMicrobial(context.microbial_state.nonstructural[runtime_index]);
                }
                const water_sensitivity: f64 = if (population == 2) 0.05 else 0.10;
                response[substrate * populations + population] = growth_temperature * @exp(water_sensitivity * context.matric_plus_osmotic_potential_megapascal[layer]);
            }
            inline for (@typeInfo(organic.ElementPool).@"struct".fields) |field| if (@field(dissolved_available_after_uptake[substrate], field.name) < -context.negligible_carbon_g_c) {
                std.log.err(
                    "soil microbial uptake overdraw before priming: layer={d} substrate={d} pool={s} source={e} aggregate_uptake={e} remainder={e}",
                    .{ layer, substrate, field.name, @field(context.organic_state.dissolved[mobile], field.name), @field(context.organic_state.dissolved[mobile], field.name) - @field(dissolved_available_after_uptake[substrate], field.name), @field(dissolved_available_after_uptake[substrate], field.name) },
                );
                if (field.name[0] == 'c') for (0..populations) |population| {
                    const unit = layer * context.respiration_fluxes.process_unit_count_per_layer + substrate * populations + population;
                    std.log.err(
                        "soil uptake population terms: population={d} doc_uptake_g_c={e} acetate_uptake_g_c={e} aerobic_respiration_g_c={e} denitrification_respiration_g_c={e} fixation_respiration_g_c={e} maintenance_g_c={e} growth_respiration_g_c={e} doc_share={e}",
                        .{ population, context.respiration_fluxes.doc_uptake_g_c[unit], context.respiration_fluxes.acetate_uptake_g_c[unit], context.respiration_fluxes.actual_aerobic_respiration_g_c[unit], context.respiration_fluxes.denitrification_respiration_g_c[unit], context.respiration_fluxes.nitrogen_fixation_respiration_g_c[unit], context.respiration_fluxes.total_maintenance_respiration_g_c[unit], context.respiration_fluxes.growth_respiration_g_c[unit], context.respiration_fluxes.doc_competition_fraction[unit] },
                    );
                };
                return error.SoilOrganicPrimingUptakeOverdraw;
            };
            dissolved_available_after_uptake[substrate].carbon_g_c = @max(0, dissolved_available_after_uptake[substrate].carbon_g_c);
            dissolved_available_after_uptake[substrate].nitrogen_g_n = @max(0, dissolved_available_after_uptake[substrate].nitrogen_g_n);
            dissolved_available_after_uptake[substrate].phosphorus_g_p = @max(0, dissolved_available_after_uptake[substrate].phosphorus_g_p);
            if (acetate_available_after_uptake_g_c[substrate] < -context.negligible_carbon_g_c) {
                std.log.err(
                    "soil microbial uptake overdraw before priming: layer={d} substrate={d} pool=acetate_carbon_g_c source={e} aggregate_uptake={e} remainder={e}",
                    .{ layer, substrate, context.organic_state.dissolved_acetate_carbon_g_c[mobile], context.organic_state.dissolved_acetate_carbon_g_c[mobile] - acetate_available_after_uptake_g_c[substrate], acetate_available_after_uptake_g_c[substrate] },
                );
                return error.SoilOrganicPrimingUptakeOverdraw;
            }
            acetate_available_after_uptake_g_c[substrate] = @max(0, acetate_available_after_uptake_g_c[substrate]);
        }
        try priming.deriveCell(&context.result.exchange, layer, .{
            .substrate_carbon_g_c = &substrate_carbon_g_c,
            .microbial_activity_g_c_per_step = &activity_g_c,
            .dissolved = context.organic_state.dissolved[layer * organic.substrate_count ..][0..organic.substrate_count],
            .dissolved_available_after_uptake = &dissolved_available_after_uptake,
            .dissolved_acetate_carbon_g_c = context.organic_state.dissolved_acetate_carbon_g_c[layer * organic.substrate_count ..][0..organic.substrate_count],
            .dissolved_acetate_available_after_uptake_g_c = &acetate_available_after_uptake_g_c,
            .microbial = snapshot,
            .microbial_temperature_water_response = response,
            .dissolved_priming_rate_per_h = context.dissolved_priming_rate_per_h,
            .microbial_priming_rate_per_h = context.microbial_priming_rate_per_h,
            .decomposition_temperature_response = std.math.pow(f64, context.soil_temperature_k[layer] / 298.15, 6),
            .timestep_h = context.timestep_h,
            .negligible_carbon_g_c = context.negligible_carbon_g_c,
        });
    }
}

fn fromMicrobial(pool: anytype) organic.ElementPool {
    return .{ .carbon_g_c = pool.carbon_g_c, .nitrogen_g_n = pool.nitrogen_g_n, .phosphorus_g_p = pool.phosphorus_g_p };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.result.exchange.cell_count;
    if (range.first > range.end or range.end > layers or context.organic_state.layer_count != layers or context.microbial_state.cell_count * context.microbial_state.layer_count != layers or context.respiration_fluxes.layer_count != layers or context.soil_temperature_k.len != layers or context.matric_plus_osmotic_potential_megapascal.len != layers or context.thermal_adaptation_offset_k_by_cell.len != context.microbial_state.cell_count or context.result.exchange.population_count != context.microbial_state.population_count) return error.SoilOrganicPrimingDimensionMismatch;
    inline for (.{ context.dissolved_priming_rate_per_h, context.microbial_priming_rate_per_h, context.timestep_h, context.negligible_carbon_g_c }) |value| if (!std.math.isFinite(value)) return error.InvalidSoilOrganicPrimingParameter;
    for (context.thermal_adaptation_offset_k_by_cell) |value| if (!std.math.isFinite(value)) return error.InvalidSoilOrganicPrimingParameter;
    if (context.dissolved_priming_rate_per_h < 0 or context.microbial_priming_rate_per_h < 0 or context.timestep_h <= 0 or context.negligible_carbon_g_c < 0) return error.InvalidSoilOrganicPrimingParameter;
}

test "soil priming conserves dissolved activity and runtime microbial elements" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.structural[0].carbon_g_c = 10;
    organic_state.structural[organic.structural_fraction_count].carbon_g_c = 20;
    organic_state.dissolved[0] = .{ .carbon_g_c = 4, .nitrogen_g_n = 0.4, .phosphorus_g_p = 0.04 };
    organic_state.dissolved[1] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, organic.substrate_count, 2);
    defer microbial_state.deinit();
    microbial_state.structural[0] = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 };
    microbial_state.structural[4] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    var respiration = try fluxes.State.init(std.testing.allocator, 1, organic.substrate_count * 2);
    defer respiration.deinit();
    respiration.substrate_unlimited_respiration_g_c[0] = 2;
    respiration.substrate_unlimited_respiration_g_c[2] = 0.5;
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    var context: ApplyContext = .{ .result = &state, .organic_state = &organic_state, .microbial_state = &microbial_state, .respiration_fluxes = &respiration, .soil_temperature_k = &.{298.15}, .matric_plus_osmotic_potential_megapascal = &.{0}, .thermal_adaptation_offset_k_by_cell = &.{0}, .dissolved_priming_rate_per_h = 0.01, .microbial_priming_rate_per_h = 0.001, .timestep_h = 1, .negligible_carbon_g_c = 1e-12 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    var dissolved_c: f64 = 0;
    var microbial_c: f64 = 0;
    for (state.exchange.dissolved_change) |pool| dissolved_c += pool.carbon_g_c;
    for (state.exchange.microbial_change) |pool| microbial_c += pool.carbon_g_c;
    try std.testing.expectApproxEqAbs(@as(f64, 0), dissolved_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0), microbial_c, 1e-14);
    try std.testing.expect(state.exchange.dissolved_change[0].carbon_g_c != 0);
}
