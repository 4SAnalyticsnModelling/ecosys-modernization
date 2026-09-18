const std = @import("std");
const compute = @import("../core/compute.zig");
const organic = @import("../soil/organic/initialization.zig");
const respiration = @import("microbial_respiration_step.zig");

pub const Parameters = struct {
    exchange_rate_per_h: f64,
    adsorption_coefficient: f64,
    surface_anion_exchange_capacity_mol_per_megagram: f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    doc_sorption_g_c: []f64,
    acetate_sorption_g_c: []f64,
    don_sorption_g_n: []f64,
    dop_sorption_g_p: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceOrganicSorptionCells;
        const count = try std.math.mul(usize, cell_count, respiration.litter_complex_count);
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        var allocated: usize = 0;
        errdefer inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64 and allocated > 0) {
            allocated -= 1;
            allocator.free(@field(result, field.name));
        };
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            @field(result, field.name) = try allocator.alloc(f64, count);
            @memset(@field(result, field.name), 0);
            allocated += 1;
        };
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    surface_organic: *const organic.State,
    litter_water_m3: []const f64,
    litter_dry_mass_megagrams: []const f64,
    timestep_h: f64,
    negligible_water_volume_m3: f64,
    negligible_carbon_g_c: f64,
    negligible_nitrogen_g_n: f64,
    negligible_phosphorus_g_p: f64,
    parameters: Parameters,
};

/// NITRO surface CSORP/CSORPA/ZSORP/PSORP. Positive values adsorb;
/// negative values desorb. State pools remain read-only until atomic state_update.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |cell| {
        var colonized_by_complex_g_c: [respiration.litter_complex_count]f64 = undefined;
        var total_colonized_g_c: f64 = 0;
        for (0..respiration.litter_complex_count) |complex| {
            var colonized: f64 = 0;
            const structural_base = (cell * organic.substrate_count + complex) * organic.structural_fraction_count;
            for (0..organic.structural_fraction_count) |fraction| colonized += context.surface_organic.colonized_structural_carbon_g_c[structural_base + fraction];
            const residue_base = (cell * organic.substrate_count + complex) * organic.residue_fraction_count;
            for (0..organic.residue_fraction_count) |fraction| colonized += context.surface_organic.residue[residue_base + fraction].carbon_g_c;
            const mobile = cell * organic.substrate_count + complex;
            colonized += context.surface_organic.adsorbed[mobile].carbon_g_c + context.surface_organic.adsorbed_acetate_carbon_g_c[mobile];
            colonized_by_complex_g_c[complex] = colonized;
            total_colonized_g_c += colonized;
        }
        for (0..respiration.litter_complex_count) |complex| {
            const compact = cell * respiration.litter_complex_count + complex;
            context.result.doc_sorption_g_c[compact] = 0;
            context.result.acetate_sorption_g_c[compact] = 0;
            context.result.don_sorption_g_n[compact] = 0;
            context.result.dop_sorption_g_p[compact] = 0;
            const complex_fraction = if (total_colonized_g_c > context.negligible_carbon_g_c) colonized_by_complex_g_c[complex] / total_colonized_g_c else 1;
            if (context.litter_water_m3[cell] <= context.negligible_water_volume_m3 or complex_fraction <= 0) continue;
            const mobile = cell * organic.substrate_count + complex;
            const dissolved = context.surface_organic.dissolved[mobile];
            const acetate = context.surface_organic.dissolved_acetate_carbon_g_c[mobile];
            const sorbed = context.surface_organic.adsorbed[mobile];
            const sorbed_acetate = context.surface_organic.adsorbed_acetate_carbon_g_c[mobile];
            const dissolved_carbon_fraction: f64 = if (dissolved.carbon_g_c > context.negligible_carbon_g_c and acetate > context.negligible_carbon_g_c) dissolved.carbon_g_c / (dissolved.carbon_g_c + acetate) else if (dissolved.carbon_g_c > context.negligible_carbon_g_c) 1 else 0;
            const acetate_fraction: f64 = if (dissolved.carbon_g_c > context.negligible_carbon_g_c and acetate > context.negligible_carbon_g_c) 1 - dissolved_carbon_fraction else if (acetate > context.negligible_carbon_g_c) 1 else 0;
            const sorption_capacity_volume = context.litter_dry_mass_megagrams[cell] * context.parameters.surface_anion_exchange_capacity_mol_per_megagram * context.parameters.adsorption_coefficient * complex_fraction;
            const water_volume = context.litter_water_m3[cell] * complex_fraction;
            context.result.doc_sorption_g_c[compact] = transfer(@max(context.negligible_carbon_g_c, dissolved.carbon_g_c), @max(context.negligible_carbon_g_c, sorbed.carbon_g_c), sorption_capacity_volume, water_volume, dissolved_carbon_fraction, context.parameters.exchange_rate_per_h, context.timestep_h);
            context.result.acetate_sorption_g_c[compact] = transfer(@max(context.negligible_carbon_g_c, acetate), @max(context.negligible_carbon_g_c, sorbed_acetate), sorption_capacity_volume, water_volume, acetate_fraction, context.parameters.exchange_rate_per_h, context.timestep_h);
            context.result.don_sorption_g_n[compact] = transfer(@max(context.negligible_nitrogen_g_n, dissolved.nitrogen_g_n), @max(context.negligible_nitrogen_g_n, sorbed.nitrogen_g_n), sorption_capacity_volume, water_volume, 0, context.parameters.exchange_rate_per_h, context.timestep_h);
            context.result.dop_sorption_g_p[compact] = transfer(@max(context.negligible_phosphorus_g_p, dissolved.phosphorus_g_p), @max(context.negligible_phosphorus_g_p, sorbed.phosphorus_g_p), sorption_capacity_volume, water_volume, 0, context.parameters.exchange_rate_per_h, context.timestep_h);
        }
    }
}

fn transfer(dissolved: f64, sorbed: f64, capacity_volume: f64, water_volume: f64, carbon_fraction: f64, rate_per_h: f64, timestep_h: f64) f64 {
    const capacity = if (carbon_fraction > 0) carbon_fraction * capacity_volume else capacity_volume;
    const water = if (carbon_fraction > 0) carbon_fraction * water_volume else water_volume;
    const denominator = capacity + water;
    if (denominator <= 0) return 0;
    return rate_per_h * (dissolved * capacity - sorbed * water) / denominator * timestep_h;
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const cells = context.result.cell_count;
    if (range.first > range.end or range.end > cells or context.surface_organic.layer_count != cells or context.litter_water_m3.len != cells or context.litter_dry_mass_megagrams.len != cells) return error.SurfaceOrganicSorptionDimensionMismatch;
    inline for (.{ context.timestep_h, context.negligible_water_volume_m3, context.negligible_carbon_g_c, context.negligible_nitrogen_g_n, context.negligible_phosphorus_g_p, context.parameters.exchange_rate_per_h, context.parameters.adsorption_coefficient, context.parameters.surface_anion_exchange_capacity_mol_per_megagram }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceOrganicSorptionParameter;
    if (context.timestep_h <= 0 or context.parameters.adsorption_coefficient <= 0 or context.parameters.surface_anion_exchange_capacity_mol_per_megagram <= 0) return error.InvalidSurfaceOrganicSorptionParameter;
}

test "surface DOC DON DOP and acetate sorption is conservative by construction" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.colonized_structural_carbon_g_c[0] = 10;
    organic_state.dissolved[0] = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 };
    organic_state.dissolved_acetate_carbon_g_c[0] = 1;
    organic_state.adsorbed[0] = .{ .carbon_g_c = 0.1, .nitrogen_g_n = 0.01, .phosphorus_g_p = 0.001 };
    organic_state.adsorbed_acetate_carbon_g_c[0] = 0.05;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .litter_water_m3 = &.{1}, .litter_dry_mass_megagrams = &.{0.01}, .timestep_h = 1, .negligible_water_volume_m3 = 1e-12, .negligible_carbon_g_c = 1e-12, .negligible_nitrogen_g_n = 1e-12, .negligible_phosphorus_g_p = 1e-12, .parameters = .{ .exchange_rate_per_h = 0.1, .adsorption_coefficient = 1, .surface_anion_exchange_capacity_mol_per_megagram = 500 } };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.doc_sorption_g_c[0] > 0);
    try std.testing.expect(state.acetate_sorption_g_c[0] > 0);
    try std.testing.expect(state.don_sorption_g_n[0] > 0);
    try std.testing.expect(state.dop_sorption_g_p[0] > 0);
}
