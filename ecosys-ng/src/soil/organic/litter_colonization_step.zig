const std = @import("std");
const compute = @import("../../core/compute.zig");
const organic = @import("initialization.zig");
const microbial = @import("../microbial/state.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const decomposition = @import("decomposition_step.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    colonized_carbon_increment_g_c: []f64,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize) !State {
        if (layer_count == 0) return error.ZeroSoilLitterColonizationLayers;
        const count = try std.math.mul(usize, try std.math.mul(usize, layer_count, organic.substrate_count), organic.structural_fraction_count);
        const values = try allocator.alloc(f64, count);
        @memset(values, 0);
        return .{ .allocator = allocator, .layer_count = layer_count, .colonized_carbon_increment_g_c = values };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.colonized_carbon_increment_g_c);
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    organic_state: *const organic.State,
    microbial_state: *const microbial.State,
    respiration_fluxes: *const fluxes.State,
    decomposition: *const decomposition.State,
    colonization_per_g_respired_carbon: [organic.substrate_count]f64,
    negligible_carbon_g_c: f64,
};

/// NITRO DOSAK/ROQCK: colonization is proportional to each OSC fraction and
/// is bounded so the staged OSA inventory can never exceed OSC.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const layer_stride = organic.substrate_count * organic.structural_fraction_count;
    const scratch = try context.result.allocator.alloc(f64, try std.math.mul(usize, range.end - range.first, layer_stride));
    defer context.result.allocator.free(scratch);
    for (range.first..range.end) |layer| for (0..organic.substrate_count) |substrate| {
        const scratch_base = (layer - range.first) * layer_stride + substrate * organic.structural_fraction_count;
        try calculateColonization(context.*, layer, substrate, scratch[scratch_base..][0..organic.structural_fraction_count]);
    };
    const destination_first = range.first * layer_stride;
    @memcpy(context.result.colonized_carbon_increment_g_c[destination_first..][0..scratch.len], scratch);
}

fn calculateColonization(context: ApplyContext, layer: usize, substrate: usize, output_g_c: []f64) !void {
    if (output_g_c.len != organic.structural_fraction_count) return error.SoilLitterColonizationDimensionMismatch;
    @memset(output_g_c, 0);
    const populations = context.microbial_state.population_count;
    const base = (layer * organic.substrate_count + substrate) * organic.structural_fraction_count;
    var total_structural_g_c: f64 = 0;
    var structural_after_g_c: [organic.structural_fraction_count]f64 = undefined;
    var colonized_after_g_c: [organic.structural_fraction_count]f64 = undefined;
    for (0..organic.structural_fraction_count) |fraction| {
        const index = base + fraction;
        const structural = context.organic_state.structural[index].carbon_g_c;
        const colonized = context.organic_state.colonized_structural_carbon_g_c[index];
        const decomposed = context.decomposition.structural_decomposition[index].carbon_g_c;
        inline for (.{ structural, colonized, decomposed }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilLitterColonizationState;
        structural_after_g_c[fraction] = structural - decomposed;
        colonized_after_g_c[fraction] = colonized - decomposed;
        if (!std.math.isFinite(structural_after_g_c[fraction]) or structural_after_g_c[fraction] < -context.negligible_carbon_g_c or
            !std.math.isFinite(colonized_after_g_c[fraction]) or colonized_after_g_c[fraction] < -context.negligible_carbon_g_c or
            colonized_after_g_c[fraction] > structural_after_g_c[fraction] + context.negligible_carbon_g_c)
            return error.InvalidSoilLitterColonizationState;
        total_structural_g_c += structural_after_g_c[fraction];
        if (!std.math.isFinite(total_structural_g_c)) return error.NonFiniteSoilLitterColonization;
    }
    if (total_structural_g_c <= context.negligible_carbon_g_c or substrate >= context.microbial_state.substrate_count) return;
    var unlimited_respiration_g_c: f64 = 0;
    for (0..populations) |population| {
        const unit = layer * context.respiration_fluxes.process_unit_count_per_layer + substrate * populations + population;
        const respiration_g_c = context.respiration_fluxes.substrate_unlimited_respiration_g_c[unit];
        if (!std.math.isFinite(respiration_g_c)) return error.InvalidSoilLitterColonizationState;
        unlimited_respiration_g_c += respiration_g_c;
        if (!std.math.isFinite(unlimited_respiration_g_c)) return error.NonFiniteSoilLitterColonization;
    }
    const requested_total_g_c = context.colonization_per_g_respired_carbon[substrate] * @max(0, unlimited_respiration_g_c);
    if (!std.math.isFinite(requested_total_g_c)) return error.NonFiniteSoilLitterColonization;
    for (0..organic.structural_fraction_count) |fraction| {
        const structural_g_c = @max(0, structural_after_g_c[fraction]);
        const colonized_g_c = @max(0, colonized_after_g_c[fraction]);
        const requested_g_c = requested_total_g_c * structural_g_c / total_structural_g_c;
        const increment_g_c = @max(0, @min(structural_g_c, colonized_g_c + requested_g_c) - colonized_g_c);
        if (!std.math.isFinite(increment_g_c) or increment_g_c < 0 or colonized_g_c + increment_g_c > structural_g_c + context.negligible_carbon_g_c)
            return error.NonFiniteSoilLitterColonization;
        output_g_c[fraction] = increment_g_c;
    }
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    if (range.first > range.end or range.end > context.result.layer_count or context.organic_state.layer_count != context.result.layer_count or context.respiration_fluxes.layer_count != context.result.layer_count or context.decomposition.layer_count != context.result.layer_count or context.microbial_state.cell_count * context.microbial_state.layer_count != context.result.layer_count or context.respiration_fluxes.process_unit_count_per_layer != context.microbial_state.substrate_count * context.microbial_state.population_count) return error.SoilLitterColonizationDimensionMismatch;
    for (context.colonization_per_g_respired_carbon) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilLitterColonizationParameter;
    if (!std.math.isFinite(context.negligible_carbon_g_c) or context.negligible_carbon_g_c < 0) return error.InvalidSoilLitterColonizationParameter;
}

test "NITRO soil litter colonization includes charcoal and is bounded" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    for (0..organic.structural_fraction_count) |fraction| {
        organic_state.structural[fraction].carbon_g_c = @floatFromInt(fraction + 1);
        organic_state.colonized_structural_carbon_g_c[fraction] = if (fraction == 4) 4.9 else 0;
    }
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, organic.substrate_count, 2);
    defer microbial_state.deinit();
    var respiration = try fluxes.State.init(std.testing.allocator, 1, organic.substrate_count * 2);
    defer respiration.deinit();
    respiration.substrate_unlimited_respiration_g_c[0] = 1;
    respiration.substrate_unlimited_respiration_g_c[1] = 1;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var decomposition_state = try decomposition.State.init(std.testing.allocator, 1);
    defer decomposition_state.deinit();
    var context: ApplyContext = .{ .result = &state, .organic_state = &organic_state, .microbial_state = &microbial_state, .respiration_fluxes = &respiration, .decomposition = &decomposition_state, .colonization_per_g_respired_carbon = .{ 15, 2, 5, 1, 0.5 }, .negligible_carbon_g_c = 1e-12 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.colonized_carbon_increment_g_c[0] > 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), state.colonized_carbon_increment_g_c[4], 1e-15);
    var total_structural_g_c: f64 = 0;
    var total_colonized_after_g_c: f64 = 0;
    for (0..organic.structural_fraction_count) |fraction| {
        const colonized_after = organic_state.colonized_structural_carbon_g_c[fraction] + state.colonized_carbon_increment_g_c[fraction];
        try std.testing.expect(colonized_after <= organic_state.structural[fraction].carbon_g_c);
        total_structural_g_c += organic_state.structural[fraction].carbon_g_c;
        total_colonized_after_g_c += colonized_after;
    }
    try std.testing.expect(total_colonized_after_g_c <= total_structural_g_c);
}

test "NITRO 3860-3902 litter colonization tile rolls back on late non-finite owner" {
    var organic_state = try organic.State.init(std.testing.allocator, 2);
    defer organic_state.deinit();
    organic_state.structural[0].carbon_g_c = 2;
    organic_state.structural[organic.substrate_count * organic.structural_fraction_count].carbon_g_c = std.math.nan(f64);
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 2, organic.substrate_count, 1);
    defer microbial_state.deinit();
    var respiration = try fluxes.State.init(std.testing.allocator, 2, organic.substrate_count);
    defer respiration.deinit();
    respiration.substrate_unlimited_respiration_g_c[0] = 1;
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(state.colonized_carbon_increment_g_c, 7);
    var decomposition_state = try decomposition.State.init(std.testing.allocator, 2);
    defer decomposition_state.deinit();
    var context: ApplyContext = .{ .result = &state, .organic_state = &organic_state, .microbial_state = &microbial_state, .respiration_fluxes = &respiration, .decomposition = &decomposition_state, .colonization_per_g_respired_carbon = .{ 1, 1, 1, 1, 1 }, .negligible_carbon_g_c = 1e-12 };

    try std.testing.expectError(
        error.InvalidSoilLitterColonizationState,
        applyTile(&context, .{ .first = 0, .end = 2 }),
    );

    for (state.colonized_carbon_increment_g_c) |value| try std.testing.expectEqual(@as(f64, 7), value);
}
