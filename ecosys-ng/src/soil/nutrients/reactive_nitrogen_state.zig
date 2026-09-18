const std = @import("std");

/// Runtime storage for NITRO intermediates that are not members of the
/// equilibrium aqueous-ion network. Ammonium and nitrate remain authoritative
/// in `solute_chemistry_state`, gases remain authoritative in `gas_transport`,
/// and this state owns NO2 plus previous-step competitive-allocation history.
pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    process_unit_count_per_layer: usize,
    non_band_nitrite_g_n: []f64,
    band_nitrite_g_n: []f64,
    previous_total_non_band_ammonium_demand_g_n: []f64,
    previous_total_band_ammonium_demand_g_n: []f64,
    previous_total_non_band_nitrate_demand_g_n: []f64,
    previous_total_band_nitrate_demand_g_n: []f64,
    previous_total_non_band_nitrite_demand_g_n: []f64,
    previous_total_band_nitrite_demand_g_n: []f64,
    previous_total_nitrous_oxide_demand_g_n: []f64,
    /// UPTAKE/NITRO/REDIST ROXYX: the previous-hour running total of every
    /// microbial guild's own aerobic O2 demand at this layer
    /// (`redist.f:6628`), reset each hour before the new hour's demand
    /// accumulates. Consumed by the FOXYX read side alongside each
    /// root/mycorrhizal population's own `previous_oxygen_demand_g_o_per_h`.
    previous_total_aerobic_oxygen_demand_g_o: []f64,
    previous_non_band_ammonia_oxidation_capacity_g_n: []f64,
    previous_band_ammonia_oxidation_capacity_g_n: []f64,
    previous_non_band_nitrite_oxidation_capacity_g_n: []f64,
    previous_band_nitrite_oxidation_capacity_g_n: []f64,
    previous_non_band_nitrate_reduction_capacity_g_n: []f64,
    previous_band_nitrate_reduction_capacity_g_n: []f64,
    previous_non_band_nitrite_reduction_capacity_g_n: []f64,
    previous_band_nitrite_reduction_capacity_g_n: []f64,
    previous_nitrous_oxide_reduction_capacity_g_n: []f64,
    previous_non_band_microbial_ammonium_capacity_g_n: []f64,
    previous_band_microbial_ammonium_capacity_g_n: []f64,
    previous_non_band_microbial_nitrate_capacity_g_n: []f64,
    previous_band_microbial_nitrate_capacity_g_n: []f64,
    previous_aerobic_oxygen_demand_g_o: []f64,
    previous_doc_respiration_demand_g_c: []f64,
    previous_acetate_respiration_demand_g_c: []f64,
    previous_non_band_chemodenitrification_capacity_g_n: []f64,
    previous_band_chemodenitrification_capacity_g_n: []f64,
    initial_nitrification_inhibition_activity: []f64,
    current_nitrification_inhibition_activity: []f64,

    /// Releases the successfully allocated `[]f64` prefix from `init` in
    /// field order. Keeping the reflected loop out of line avoids cloning it
    /// at every fallible allocation edge in `init`.
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
        @setEvalBranchQuota(4000);
        if (layer_count == 0 or process_unit_count_per_layer == 0) return error.InvalidReactiveNitrogenDimensions;
        var result: State = undefined;
        result.allocator = allocator;
        result.layer_count = layer_count;
        result.process_unit_count_per_layer = process_unit_count_per_layer;
        var allocated: usize = 0;
        errdefer result.deinitAllocatedPrefix(allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            const count = if (isLayerField(field.name)) layer_count else try std.math.mul(usize, layer_count, process_unit_count_per_layer);
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

    pub fn processUnitIndex(self: State, layer: usize, process_unit: usize) !usize {
        if (layer >= self.layer_count or process_unit >= self.process_unit_count_per_layer) return error.ReactiveNitrogenIndexOutOfBounds;
        return layer * self.process_unit_count_per_layer + process_unit;
    }

    pub fn validateLayer(self: State, layer: usize) !void {
        if (layer >= self.layer_count) return error.ReactiveNitrogenIndexOutOfBounds;
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            if (isLayerField(field.name)) {
                const value = @field(self, field.name)[layer];
                if (!std.math.isFinite(value) or value < 0) return error.InvalidReactiveNitrogenState;
            } else {
                const first = layer * self.process_unit_count_per_layer;
                for (@field(self, field.name)[first .. first + self.process_unit_count_per_layer]) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidReactiveNitrogenState;
            }
        };
    }
};

fn isLayerField(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "non_band_") or
        std.mem.startsWith(u8, name, "band_") or
        std.mem.startsWith(u8, name, "dissolved_") or
        std.mem.startsWith(u8, name, "previous_total_") or
        std.mem.startsWith(u8, name, "previous_non_band_chemo") or
        std.mem.startsWith(u8, name, "previous_band_chemo") or
        std.mem.endsWith(u8, name, "nitrification_inhibition_activity");
}

test "reactive nitrogen state is runtime sized beyond source dimensions" {
    var state = try State.init(std.testing.allocator, 13, 77);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 13), state.non_band_nitrite_g_n.len);
    try std.testing.expectEqual(@as(usize, 1001), state.previous_non_band_nitrite_reduction_capacity_g_n.len);
    const index = try state.processUnitIndex(12, 76);
    state.previous_non_band_nitrite_reduction_capacity_g_n[index] = 0.25;
    try state.validateLayer(12);
}

test "reactive nitrogen validation rejects NaN before process execution" {
    var state = try State.init(std.testing.allocator, 2, 3);
    defer state.deinit();
    state.non_band_nitrite_g_n[1] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidReactiveNitrogenState, state.validateLayer(1));
}

test "reactive nitrogen state releases every partial allocation prefix" {
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
