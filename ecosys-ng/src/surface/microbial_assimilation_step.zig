const std = @import("std");
const compute = @import("../core/compute.zig");
const organic = @import("../soil/organic/initialization.zig");
const metabolism = @import("../soil/microbial/metabolism.zig");
const respiration = @import("microbial_respiration_step.zig");

pub const structural_component_count: usize = 2;

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    transfer: []organic.ElementPool,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceMicrobialAssimilationCells;
        const transfer = try allocator.alloc(organic.ElementPool, try std.math.mul(usize, try std.math.mul(usize, cell_count, respiration.unit_count_per_cell), structural_component_count));
        @memset(transfer, .{});
        return .{ .allocator = allocator, .cell_count = cell_count, .transfer = transfer };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.transfer);
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    surface_organic: *const organic.State,
    growth_temperature_response: []const f64,
    matric_plus_osmotic_potential_megapascal: []const f64,
    microbial_nitrogen_to_carbon_g_n_per_g_c: []const f64,
    microbial_phosphorus_to_carbon_g_p_per_g_c: []const f64,
    labile_structural_fraction: f64,
    transfer_rate_per_h: f64,
    timestep_h: f64,
};

/// NITRO CGOMZ and CGOMS/CGONS/CGOPS for litter K=1..3, N=1..7.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |cell| for (0..respiration.litter_complex_count) |complex| for (0..respiration.source_population_count) |population| {
        const local_unit = complex * respiration.source_population_count + population;
        const unit = cell * respiration.unit_count_per_cell + local_unit;
        const microbial = ((cell * organic.microbial_substrate_count + complex) * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
        const response = context.growth_temperature_response[cell] * @exp((if (population == 2) @as(f64, 0.05) else 0.10) * context.matric_plus_osmotic_potential_megapascal[cell]);
        const ratio_base = (complex * organic.microbial_population_count + population) * organic.kinetic_fraction_count;
        const value = try metabolism.assimilateNonstructural(.{
            .nonstructural = toMetabolic(context.surface_organic.microbial[microbial + 2]),
            .temperature_water_response = response,
            .nonstructural_to_structural_rate_per_h = context.transfer_rate_per_h,
            .timestep_h = context.timestep_h,
            .structural_partition = .{ context.labile_structural_fraction, 1 - context.labile_structural_fraction },
            .maximum_nitrogen_per_carbon = .{ context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio_base], context.microbial_nitrogen_to_carbon_g_n_per_g_c[ratio_base + 1] },
            .maximum_phosphorus_per_carbon = .{ context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio_base], context.microbial_phosphorus_to_carbon_g_p_per_g_c[ratio_base + 1] },
        });
        for (0..structural_component_count) |component| context.result.transfer[(unit * structural_component_count) + component] = fromMetabolic(value.structural[component]);
    };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const ratio_count = organic.substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count;
    if (range.first > range.end or range.end > context.result.cell_count or context.surface_organic.layer_count != context.result.cell_count or context.growth_temperature_response.len != context.result.cell_count or context.matric_plus_osmotic_potential_megapascal.len != context.result.cell_count or context.microbial_nitrogen_to_carbon_g_n_per_g_c.len != ratio_count or context.microbial_phosphorus_to_carbon_g_p_per_g_c.len != ratio_count) return error.SurfaceMicrobialAssimilationDimensionMismatch;
    inline for (.{ context.labile_structural_fraction, context.transfer_rate_per_h, context.timestep_h }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceMicrobialAssimilationParameter;
    if (context.labile_structural_fraction > 1 or context.timestep_h <= 0) return error.InvalidSurfaceMicrobialAssimilationParameter;
}

fn toMetabolic(value: organic.ElementPool) metabolism.ElementalPool {
    return .{ .carbon_g_c = value.carbon_g_c, .nitrogen_g_n = value.nitrogen_g_n, .phosphorus_g_p = value.phosphorus_g_p };
}

fn fromMetabolic(value: metabolism.ElementalPool) organic.ElementPool {
    return .{ .carbon_g_c = value.carbon_g_c, .nitrogen_g_n = value.nitrogen_g_n, .phosphorus_g_p = value.phosphorus_g_p };
}

test "surface assimilation reproduces CGOMS split and conserves elements" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.microbial[2] = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.2 };
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const n = [_]f64{0.1} ** (organic.substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    const p = [_]f64{0.02} ** (organic.substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .growth_temperature_response = &.{1}, .matric_plus_osmotic_potential_megapascal = &.{0}, .microbial_nitrogen_to_carbon_g_n_per_g_c = &n, .microbial_phosphorus_to_carbon_g_p_per_g_c = &p, .labile_structural_fraction = 0.55, .transfer_rate_per_h = 0.25, .timestep_h = 1 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.375), state.transfer[0].carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.125), state.transfer[1].carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), state.transfer[0].nitrogen_g_n + state.transfer[1].nitrogen_g_n, 1e-15);
}
