const std = @import("std");
const compute = @import("../../core/compute.zig");
const microbial = @import("state.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const respiration_activity = @import("respiration_activity.zig");
const organic = @import("../organic/initialization.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    process_unit_count_per_layer: usize,
    carbon_dioxide_g_c: []f64,
    acetate_g_c: []f64,
    methane_g_c: []f64,
    hydrogen_g_h: []f64,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize, process_unit_count_per_layer: usize) !State {
        if (layer_count == 0 or process_unit_count_per_layer == 0) return error.InvalidSoilRespirationProductDimensions;
        const count = try std.math.mul(usize, layer_count, process_unit_count_per_layer);
        const co2 = try allocator.alloc(f64, count);
        errdefer allocator.free(co2);
        const acetate = try allocator.alloc(f64, count);
        errdefer allocator.free(acetate);
        const methane = try allocator.alloc(f64, count);
        errdefer allocator.free(methane);
        const hydrogen = try allocator.alloc(f64, count);
        @memset(co2, 0);
        @memset(acetate, 0);
        @memset(methane, 0);
        @memset(hydrogen, 0);
        return .{ .allocator = allocator, .layer_count = layer_count, .process_unit_count_per_layer = process_unit_count_per_layer, .carbon_dioxide_g_c = co2, .acetate_g_c = acetate, .methane_g_c = methane, .hydrogen_g_h = hydrogen };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.hydrogen_g_h);
        self.allocator.free(self.methane_g_c);
        self.allocator.free(self.acetate_g_c);
        self.allocator.free(self.carbon_dioxide_g_c);
        self.* = undefined;
    }
};

pub const ApplyContext = struct { result: *State, microbial_state: *const microbial.State, respiration_fluxes: *const fluxes.State };

/// NITRO RCO2X/RCH3X/RCH4X/RH2GX for K=0..4. Source populations N=4/7
/// ferment; N=5 is acetotrophic methanogenic; the others respire to CO2.
///
/// The loop below runs over every substrate complex, including the autotrophic
/// complex (organic.autotrophic_substrate_index = 5), for which NITRO.F
/// 1649--1663 takes a *different* branch: at K.EQ.5 with N.EQ.5 the products
/// are RCO2X=0, RCH4X=RGOMO (all carbon to methane, none to CO2) and RH2GX=0,
/// whereas K.LE.4 splits 0.50/0.50. Applying the K.LE.4 split at K=5 would
/// therefore mis-partition hydrogenotrophic carbon.
///
/// That is harmless here only because of one upstream invariant:
/// soil/microbial/substrate_uptake_step.zig clamps its substrate loop to
/// @min(substrate_count, organic.substrate_count) = 5, so
/// actual_aerobic_respiration_g_c is never written for substrate index 5 and
/// stays at its workspace reset value of zero. Every K=5 product is then a
/// multiple of zero and the branch difference cannot be observed. The
/// hydrogenotrophic K=5 path is instead owned by soil/gas/methane_step.zig,
/// which reads the aggregated hydrogen_g_h/methane_g_c sums published here.
///
/// The invariant is load-bearing, not incidental: if the uptake clamp is ever
/// widened to cover the autotrophic complex, this kernel must gain the K=5
/// branch first. "autotrophic complex respiration is zero so the K=5 product
/// branch is unobservable" below pins it.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const populations = context.microbial_state.population_count;
    for (range.first..range.end) |layer| for (0..context.microbial_state.substrate_count) |substrate| for (0..populations) |population| {
        const unit = layer * context.result.process_unit_count_per_layer + substrate * populations + population;
        const respiration_g_c = context.respiration_fluxes.actual_aerobic_respiration_g_c[unit];
        var co2_g_c: f64 = respiration_g_c;
        var acetate_g_c: f64 = 0;
        var methane_g_c: f64 = 0;
        var hydrogen_g_h: f64 = 0;
        switch (respiration_activity.sourceMetabolism(population)) {
            .fermenting_heterotroph => {
                co2_g_c = 0.333 * respiration_g_c;
                acetate_g_c = 0.667 * respiration_g_c;
                hydrogen_g_h = 0.111 * respiration_g_c;
            },
            .acetotrophic_methanogen => {
                co2_g_c = 0.5 * respiration_g_c;
                methane_g_c = 0.5 * respiration_g_c;
            },
            .aerobic_heterotroph => {},
        }
        context.result.carbon_dioxide_g_c[unit] = co2_g_c;
        context.result.acetate_g_c[unit] = acetate_g_c;
        context.result.methane_g_c[unit] = methane_g_c;
        context.result.hydrogen_g_h[unit] = hydrogen_g_h;
        inline for (.{ co2_g_c, acetate_g_c, methane_g_c, hydrogen_g_h }) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteSoilRespirationProduct;
        if (@abs(respiration_g_c - co2_g_c - acetate_g_c - methane_g_c) > 1e-12 * @max(1, respiration_g_c)) return error.SoilRespirationCarbonBalanceFailure;
    };
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.result.layer_count;
    if (range.first > range.end or range.end > layers or context.microbial_state.cell_count * context.microbial_state.layer_count != layers or context.respiration_fluxes.layer_count != layers or context.result.process_unit_count_per_layer != context.microbial_state.substrate_count * context.microbial_state.population_count or context.respiration_fluxes.process_unit_count_per_layer != context.result.process_unit_count_per_layer) return error.InvalidSoilRespirationProductDimensions;
}

test "legacy soil populations route respiration to CO2 acetate methane and hydrogen" {
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 7);
    defer microbial_state.deinit();
    var respiration = try fluxes.State.init(std.testing.allocator, 1, 7);
    defer respiration.deinit();
    @memset(respiration.actual_aerobic_respiration_g_c, 1);
    var state = try State.init(std.testing.allocator, 1, 7);
    defer state.deinit();
    var context: ApplyContext = .{ .result = &state, .microbial_state = &microbial_state, .respiration_fluxes = &respiration };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 1), state.carbon_dioxide_g_c[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.667), state.acetate_g_c[3], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.111), state.hydrogen_g_h[6], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), state.methane_g_c[4], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), state.carbon_dioxide_g_c[4] + state.methane_g_c[4], 1e-15);
}

test "autotrophic complex respiration is zero so the K=5 product branch is unobservable" {
    // Guards the invariant documented on applyTile. Stated against the
    // upstream clamp, not by calling the kernel under test, so it does not
    // become tautological.
    try std.testing.expect(organic.autotrophic_substrate_index >= organic.substrate_count);
    try std.testing.expectEqual(organic.substrate_count, @min(organic.microbial_substrate_count, organic.substrate_count));

    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, organic.microbial_substrate_count, 7);
    defer microbial_state.deinit();
    const units = organic.microbial_substrate_count * 7;
    var respiration = try fluxes.State.init(std.testing.allocator, 1, units);
    defer respiration.deinit();
    // Only the heterotrophic complexes receive respiration, exactly as the
    // clamped uptake loop leaves the workspace.
    for (0..organic.substrate_count) |substrate| for (0..7) |population| {
        respiration.actual_aerobic_respiration_g_c[substrate * 7 + population] = 1;
    };
    var state = try State.init(std.testing.allocator, 1, units);
    defer state.deinit();
    var context: ApplyContext = .{ .result = &state, .microbial_state = &microbial_state, .respiration_fluxes = &respiration };
    try applyTile(&context, .{ .first = 0, .end = 1 });

    // Every product on the autotrophic complex is identically zero, so the
    // absent K=5 branch changes nothing that is published.
    for (0..7) |population| {
        const unit = organic.autotrophic_substrate_index * 7 + population;
        try std.testing.expectEqual(@as(f64, 0), state.carbon_dioxide_g_c[unit]);
        try std.testing.expectEqual(@as(f64, 0), state.acetate_g_c[unit]);
        try std.testing.expectEqual(@as(f64, 0), state.methane_g_c[unit]);
        try std.testing.expectEqual(@as(f64, 0), state.hydrogen_g_h[unit]);
    }

    // Falsifiability companion: the claim "unobservable" is only meaningful
    // because the two branches genuinely disagree. With nonzero respiration on
    // the autotrophic complex this kernel emits the K.LE.4 split (0.5 CO2 /
    // 0.5 CH4) where NITRO.F 1656--1660 requires 0 CO2 / all CH4.
    respiration.actual_aerobic_respiration_g_c[organic.autotrophic_substrate_index * 7 + 4] = 1;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const methanogen = organic.autotrophic_substrate_index * 7 + 4;
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), state.carbon_dioxide_g_c[methanogen], 1e-15);
    try std.testing.expect(state.carbon_dioxide_g_c[methanogen] != 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), state.methane_g_c[methanogen], 1e-15);
}
