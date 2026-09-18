const std = @import("std");
const compute = @import("../core/compute.zig");
const organic = @import("../soil/organic/initialization.zig");
const respiration = @import("microbial_respiration_step.zig");
const decomposition = @import("organic_decomposition_step.zig");

pub const Parameters = struct {
    colonization_per_g_activity: [respiration.litter_complex_count]f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    colonized_carbon_increment_g_c: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceLitterColonizationCells;
        const values = try allocator.alloc(f64, try std.math.mul(usize, try std.math.mul(usize, cell_count, respiration.litter_complex_count), organic.structural_fraction_count));
        @memset(values, 0);
        return .{ .allocator = allocator, .cell_count = cell_count, .colonized_carbon_increment_g_c = values };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.colonized_carbon_increment_g_c);
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    surface_organic: *const organic.State,
    decomposition: *const decomposition.State,
    parameters: Parameters,
    negligible_carbon_g_c: f64,
};

/// NITRO DOSAK and the post-decomposition OSA colonization update.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |cell| for (0..respiration.litter_complex_count) |complex| {
        const compact = cell * respiration.litter_complex_count + complex;
        const base = compact * organic.structural_fraction_count;
        var remaining_total_g_c: f64 = 0;
        for (0..organic.structural_fraction_count) |fraction| {
            const index = (cell * organic.substrate_count + complex) * organic.structural_fraction_count + fraction;
            const decomposed = context.decomposition.structural_decomposition[base + fraction].carbon_g_c;
            remaining_total_g_c += context.surface_organic.structural[index].carbon_g_c - decomposed;
            context.result.colonized_carbon_increment_g_c[base + fraction] = 0;
        }
        if (remaining_total_g_c <= context.negligible_carbon_g_c) continue;
        const requested_total_g_c = context.parameters.colonization_per_g_activity[complex] * @max(0, context.decomposition.post_priming_activity_g_c_per_step[compact]);
        for (0..organic.structural_fraction_count) |fraction| {
            const index = (cell * organic.substrate_count + complex) * organic.structural_fraction_count + fraction;
            const decomposed = context.decomposition.structural_decomposition[base + fraction].carbon_g_c;
            const remaining = context.surface_organic.structural[index].carbon_g_c - decomposed;
            const colonized = context.surface_organic.colonized_structural_carbon_g_c[index] - decomposed;
            const requested = requested_total_g_c * remaining / remaining_total_g_c;
            context.result.colonized_carbon_increment_g_c[base + fraction] = @max(0, @min(remaining, colonized + requested) - colonized);
        }
    };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const cells = context.result.cell_count;
    if (range.first > range.end or range.end > cells or context.surface_organic.layer_count != cells or context.decomposition.cell_count != cells) return error.SurfaceLitterColonizationDimensionMismatch;
    for (context.parameters.colonization_per_g_activity) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceLitterColonizationParameter;
    if (!std.math.isFinite(context.negligible_carbon_g_c) or context.negligible_carbon_g_c < 0) return error.InvalidSurfaceLitterColonizationParameter;
}

test "post-decomposition litter colonization is bounded by remaining carbon" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.structural[0].carbon_g_c = 10;
    organic_state.colonized_structural_carbon_g_c[0] = 2;
    var decomposition_state = try decomposition.State.init(std.testing.allocator, 1);
    defer decomposition_state.deinit();
    decomposition_state.structural_decomposition[0].carbon_g_c = 1;
    decomposition_state.post_priming_activity_g_c_per_step[0] = 4;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .decomposition = &decomposition_state, .parameters = .{ .colonization_per_g_activity = .{ 0.25, 2, 5 } }, .negligible_carbon_g_c = 1e-12 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 1), state.colonized_carbon_increment_g_c[0], 1e-15);
    try std.testing.expect(organic_state.colonized_structural_carbon_g_c[0] - 1 + state.colonized_carbon_increment_g_c[0] <= organic_state.structural[0].carbon_g_c - 1);
}
