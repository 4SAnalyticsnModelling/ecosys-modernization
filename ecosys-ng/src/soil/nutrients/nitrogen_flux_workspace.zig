const std = @import("std");
const compute = @import("../../core/compute.zig");

/// Derived, non-prognostic NITRO rates. Each tiled kernel writes only its own
/// layer range; inventories are published later by one atomic C/N/O state_update.
/// This separation replaces source full-model sub-hour cycling without
/// changing the sequential reaction science inside a converged step.
pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    process_unit_count_per_layer: usize,
    non_band_ammonia_oxidation_potential_g_n: []f64,
    band_ammonia_oxidation_potential_g_n: []f64,
    non_band_nitrite_oxidation_potential_g_n: []f64,
    band_nitrite_oxidation_potential_g_n: []f64,
    non_band_ammonia_oxidation_capacity_g_n: []f64,
    band_ammonia_oxidation_capacity_g_n: []f64,
    non_band_nitrite_oxidation_capacity_g_n: []f64,
    band_nitrite_oxidation_capacity_g_n: []f64,
    non_band_nitrate_reduction_potential_g_n: []f64,
    band_nitrate_reduction_potential_g_n: []f64,
    non_band_nitrate_reduction_capacity_g_n: []f64,
    band_nitrate_reduction_capacity_g_n: []f64,
    non_band_heterotrophic_nitrite_reduction_potential_g_n: []f64,
    band_heterotrophic_nitrite_reduction_potential_g_n: []f64,
    non_band_autotrophic_nitrite_reduction_potential_g_n: []f64,
    band_autotrophic_nitrite_reduction_potential_g_n: []f64,
    non_band_autotrophic_ammonium_oxidation_potential_g_n: []f64,
    band_autotrophic_ammonium_oxidation_potential_g_n: []f64,
    non_band_nitrite_reduction_capacity_g_n: []f64,
    band_nitrite_reduction_capacity_g_n: []f64,
    nitrous_oxide_reduction_capacity_g_n: []f64,
    nitrous_oxide_reduction_potential_g_n: []f64,
    aerobic_oxygen_demand_g_o: []f64,
    substrate_unlimited_respiration_g_c: []f64,
    doc_respiration_demand_g_c: []f64,
    acetate_respiration_demand_g_c: []f64,
    substrate_limited_respiration_g_c: []f64,
    aerobic_active_biomass_g_c: []f64,
    aerobic_fallback_active_fraction: []f64,
    doc_competition_fraction: []f64,
    substrate_complex_fraction: []f64,
    layer_biologically_active_water_m3: []f64,
    denitrification_respiration_g_c: []f64,
    labile_maintenance_respiration_g_c: []f64,
    resistant_maintenance_respiration_g_c: []f64,
    total_maintenance_respiration_g_c: []f64,
    growth_respiration_g_c: []f64,
    senescence_respiration_deficit_g_c: []f64,
    actual_aerobic_respiration_g_c: []f64,
    total_carbon_uptake_g_c: []f64,
    doc_uptake_g_c: []f64,
    acetate_uptake_g_c: []f64,
    dissolved_organic_nitrogen_uptake_g_n: []f64,
    dissolved_organic_phosphorus_uptake_g_p: []f64,
    nonstructural_carbon_gain_g_c: []f64,
    nitrogen_fixation_respiration_g_c: []f64,
    fixed_dinitrogen_g_n: []f64,
    labile_assimilation_g_c: []f64,
    labile_assimilation_g_n: []f64,
    labile_assimilation_g_p: []f64,
    resistant_assimilation_g_c: []f64,
    resistant_assimilation_g_n: []f64,
    resistant_assimilation_g_p: []f64,
    non_band_microbial_ammonium_exchange_g_n: []f64,
    band_microbial_ammonium_exchange_g_n: []f64,
    non_band_microbial_nitrate_exchange_g_n: []f64,
    band_microbial_nitrate_exchange_g_n: []f64,
    non_band_microbial_ammonium_capacity_g_n: []f64,
    band_microbial_ammonium_capacity_g_n: []f64,
    non_band_microbial_nitrate_capacity_g_n: []f64,
    band_microbial_nitrate_capacity_g_n: []f64,
    non_band_microbial_h2po4_exchange_g_p: []f64,
    band_microbial_h2po4_exchange_g_p: []f64,
    non_band_microbial_hpo4_exchange_g_p: []f64,
    band_microbial_hpo4_exchange_g_p: []f64,
    non_band_microbial_h2po4_capacity_g_p: []f64,
    band_microbial_h2po4_capacity_g_p: []f64,
    non_band_microbial_hpo4_capacity_g_p: []f64,
    band_microbial_hpo4_capacity_g_p: []f64,
    chemodenitrification_non_band_nitrite_reduction_g_n: []f64,
    chemodenitrification_band_nitrite_reduction_g_n: []f64,
    chemodenitrification_non_band_unlimited_reduction_g_n: []f64,
    chemodenitrification_band_unlimited_reduction_g_n: []f64,
    chemodenitrification_nitrous_oxide_production_g_n: []f64,
    chemodenitrification_dinitrogen_production_g_n: []f64,
    chemodenitrification_dissolved_organic_nitrogen_production_g_n: []f64,
    layer_nitrification_inhibition_activity: []f64,

    /// Releases the successfully allocated prefix from `init` in the same
    /// field order as the former inline `errdefer`. Keeping this out of line
    /// prevents every fallible allocation in `init` from receiving its own
    /// fully unrolled copy of the cleanup loop.
    noinline fn deinitAllocatedPrefix(self: *State, allocated_count: usize) void {
        var remaining = allocated_count;
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) {
                if (remaining == 0) return;
                self.allocator.free(@field(self, field.name));
                remaining -= 1;
            }
        }
    }

    pub fn init(allocator: std.mem.Allocator, layer_count: usize, process_unit_count_per_layer: usize) !State {
        @setEvalBranchQuota(16000);
        if (layer_count == 0 or process_unit_count_per_layer == 0) return error.InvalidSoilNitrogenFluxDimensions;
        var result: State = undefined;
        result.allocator = allocator;
        result.layer_count = layer_count;
        result.process_unit_count_per_layer = process_unit_count_per_layer;
        var allocated: usize = 0;
        errdefer result.deinitAllocatedPrefix(allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            const count = if (std.mem.startsWith(u8, field.name, "chemodenitrification_") or std.mem.startsWith(u8, field.name, "layer_")) layer_count else try std.math.mul(usize, layer_count, process_unit_count_per_layer);
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

pub const ResetContext = struct { state: *State };

pub fn resetTile(context: *ResetContext, range: compute.CellRange) !void {
    const state = context.state;
    if (range.first > range.end or range.end > state.layer_count) return error.SoilNitrogenFluxRangeOutOfBounds;
    const first_unit = try std.math.mul(usize, range.first, state.process_unit_count_per_layer);
    const end_unit = try std.math.mul(usize, range.end, state.process_unit_count_per_layer);
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        const values = @field(state, field.name);
        if (std.mem.startsWith(u8, field.name, "chemodenitrification_") or std.mem.startsWith(u8, field.name, "layer_"))
            @memset(values[range.first..range.end], 0)
        else
            @memset(values[first_unit..end_unit], 0);
    };
}

test "soil nitrogen flux workspace resets independent runtime layer tiles" {
    var state = try State.init(std.testing.allocator, 9, 33);
    defer state.deinit();
    @memset(state.non_band_ammonia_oxidation_potential_g_n, 4);
    @memset(state.chemodenitrification_non_band_nitrite_reduction_g_n, 4);
    var context: ResetContext = .{ .state = &state };
    try resetTile(&context, .{ .first = 2, .end = 5 });
    try std.testing.expectEqual(@as(f64, 4), state.non_band_ammonia_oxidation_potential_g_n[2 * 33 - 1]);
    try std.testing.expectEqual(@as(f64, 0), state.non_band_ammonia_oxidation_potential_g_n[2 * 33]);
    try std.testing.expectEqual(@as(f64, 0), state.chemodenitrification_non_band_nitrite_reduction_g_n[4]);
    try std.testing.expectEqual(@as(f64, 4), state.chemodenitrification_non_band_nitrite_reduction_g_n[5]);
}

test "soil nitrogen flux workspace releases every partial allocation prefix" {
    const allocation_count = comptime count: {
        var count: usize = 0;
        for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) count += 1;
        }
        break :count count;
    };

    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            State.init(failing.allocator(), 2, 3),
        );
    }
}
