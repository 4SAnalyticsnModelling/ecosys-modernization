const std = @import("std");
const reactive_nitrogen = @import("reactive_nitrogen_state.zig");
const phosphorus_history = @import("../microbial/phosphorus_state.zig");

/// The eight separately allocated soil solution domains represented by the
/// source RNH4Y/RNHBY/RNO3Y/RN3BY/RPO4Y/RPOBY/RP14Y/RP1BY arrays.
pub const SoilPool = enum(u8) {
    ammonium_non_band,
    ammonium_band,
    nitrate_non_band,
    nitrate_band,
    h2po4_non_band,
    h2po4_band,
    hpo4_non_band,
    hpo4_band,
};

pub const soil_pool_count: usize = @typeInfo(SoilPool).@"enum".fields.len;

/// Surface litter has no fertilizer-band subdivision in the source L=0
/// domain. These are RNH4Y/RNO3Y/RPO4Y/RP14Y at L=0.
pub const SurfacePool = enum(u8) { ammonium, nitrate, h2po4, hpo4 };
pub const surface_pool_count: usize = @typeInfo(SurfacePool).@"enum".fields.len;

/// Stable source-order slots: K=1..3,N=1..7 followed by K=5,N=1,2,3,5.
/// Keeping the slots explicit preserves REDIST's serial accumulation order.
pub const surface_heterotroph_count: usize = 21;
pub const surface_autotroph_count: usize = 4;
pub const surface_mineral_competitor_count: usize = surface_heterotroph_count + surface_autotroph_count;
pub const surface_denitrifier_count: usize = 3;

/// Checkpoint-owned, previous *accepted external hour* demand totals.  This is
/// the single read-side denominator owner shared by microbial redox/mineral
/// processes and root/mycorrhizal uptake. It is never changed during an hour
/// attempt; `Attempt.publishAccepted` is its only production writer.
pub const State = struct {
    allocator: std.mem.Allocator,
    soil_layer_count: usize,
    surface_cell_count: usize,
    soil_previous_total: [soil_pool_count][]f64,
    surface_previous_total: [surface_pool_count][]f64,
    surface_mineral_previous_capacity: [surface_pool_count][]f64,
    topsoil_residual_previous_capacity: [surface_pool_count][]f64,
    surface_ammonia_oxidation_previous_capacity: []f64,
    surface_denitrification_previous_capacity: []f64,

    pub fn init(allocator: std.mem.Allocator, soil_layer_count: usize, surface_cell_count: usize) !State {
        if (soil_layer_count == 0 or surface_cell_count == 0)
            return error.InvalidNutrientCompetitionHistoryDimensions;
        var result: State = .{
            .allocator = allocator,
            .soil_layer_count = soil_layer_count,
            .surface_cell_count = surface_cell_count,
            .soil_previous_total = undefined,
            .surface_previous_total = undefined,
            .surface_mineral_previous_capacity = undefined,
            .topsoil_residual_previous_capacity = undefined,
            .surface_ammonia_oxidation_previous_capacity = &.{},
            .surface_denitrification_previous_capacity = &.{},
        };
        var soil_allocated: usize = 0;
        var surface_allocated: usize = 0;
        var surface_mineral_allocated: usize = 0;
        var topsoil_residual_allocated: usize = 0;
        errdefer {
            for (result.soil_previous_total[0..soil_allocated]) |values| allocator.free(values);
            for (result.surface_previous_total[0..surface_allocated]) |values| allocator.free(values);
            for (result.surface_mineral_previous_capacity[0..surface_mineral_allocated]) |values| allocator.free(values);
            for (result.topsoil_residual_previous_capacity[0..topsoil_residual_allocated]) |values| allocator.free(values);
            if (result.surface_ammonia_oxidation_previous_capacity.len != 0) allocator.free(result.surface_ammonia_oxidation_previous_capacity);
            if (result.surface_denitrification_previous_capacity.len != 0) allocator.free(result.surface_denitrification_previous_capacity);
        }
        for (&result.soil_previous_total) |*values| {
            values.* = try allocator.alloc(f64, soil_layer_count);
            @memset(values.*, 0);
            soil_allocated += 1;
        }
        for (&result.surface_previous_total) |*values| {
            values.* = try allocator.alloc(f64, surface_cell_count);
            @memset(values.*, 0);
            surface_allocated += 1;
        }
        const mineral_count = try std.math.mul(usize, surface_cell_count, surface_mineral_competitor_count);
        for (&result.surface_mineral_previous_capacity) |*values| {
            values.* = try allocator.alloc(f64, mineral_count);
            @memset(values.*, 0);
            surface_mineral_allocated += 1;
        }
        for (&result.topsoil_residual_previous_capacity) |*values| {
            values.* = try allocator.alloc(f64, mineral_count);
            @memset(values.*, 0);
            topsoil_residual_allocated += 1;
        }
        result.surface_ammonia_oxidation_previous_capacity = try allocator.alloc(f64, surface_cell_count);
        @memset(result.surface_ammonia_oxidation_previous_capacity, 0);
        result.surface_denitrification_previous_capacity = try allocator.alloc(f64, try std.math.mul(usize, surface_cell_count, surface_denitrifier_count));
        @memset(result.surface_denitrification_previous_capacity, 0);
        return result;
    }

    pub fn deinit(self: *State) void {
        for (self.soil_previous_total) |values| self.allocator.free(values);
        for (self.surface_previous_total) |values| self.allocator.free(values);
        for (self.surface_mineral_previous_capacity) |values| self.allocator.free(values);
        for (self.topsoil_residual_previous_capacity) |values| self.allocator.free(values);
        self.allocator.free(self.surface_ammonia_oxidation_previous_capacity);
        self.allocator.free(self.surface_denitrification_previous_capacity);
        self.* = undefined;
    }

    pub fn soilTotal(self: *const State, pool: SoilPool, layer: usize) !f64 {
        if (layer >= self.soil_layer_count) return error.NutrientCompetitionHistoryIndexOutOfBounds;
        return self.soil_previous_total[@intFromEnum(pool)][layer];
    }

    pub fn surfaceTotal(self: *const State, pool: SurfacePool, cell: usize) !f64 {
        if (cell >= self.surface_cell_count) return error.NutrientCompetitionHistoryIndexOutOfBounds;
        return self.surface_previous_total[@intFromEnum(pool)][cell];
    }

    pub fn surfaceMineralCapacity(self: *const State, pool: SurfacePool, cell: usize, competitor: usize) !f64 {
        if (cell >= self.surface_cell_count or competitor >= surface_mineral_competitor_count)
            return error.NutrientCompetitionHistoryIndexOutOfBounds;
        return self.surface_mineral_previous_capacity[@intFromEnum(pool)][cell * surface_mineral_competitor_count + competitor];
    }

    pub fn topsoilResidualCapacity(self: *const State, pool: SurfacePool, cell: usize, competitor: usize) !f64 {
        if (cell >= self.surface_cell_count or competitor >= surface_mineral_competitor_count)
            return error.NutrientCompetitionHistoryIndexOutOfBounds;
        return self.topsoil_residual_previous_capacity[@intFromEnum(pool)][cell * surface_mineral_competitor_count + competitor];
    }

    pub fn surfaceAmmoniaOxidationCapacity(self: *const State, cell: usize) !f64 {
        if (cell >= self.surface_cell_count) return error.NutrientCompetitionHistoryIndexOutOfBounds;
        return self.surface_ammonia_oxidation_previous_capacity[cell];
    }

    pub fn surfaceDenitrificationCapacity(self: *const State, cell: usize, complex: usize) !f64 {
        if (cell >= self.surface_cell_count or complex >= surface_denitrifier_count)
            return error.NutrientCompetitionHistoryIndexOutOfBounds;
        return self.surface_denitrification_previous_capacity[cell * surface_denitrifier_count + complex];
    }

    pub fn validate(self: *const State) !void {
        if (self.soil_layer_count == 0 or self.surface_cell_count == 0)
            return error.InvalidNutrientCompetitionHistoryDimensions;
        for (self.soil_previous_total) |values| {
            if (values.len != self.soil_layer_count) return error.InvalidNutrientCompetitionHistoryDimensions;
            for (values) |value| if (!std.math.isFinite(value) or value < 0)
                return error.InvalidNutrientCompetitionHistoryValue;
        }
        for (self.surface_previous_total) |values| {
            if (values.len != self.surface_cell_count) return error.InvalidNutrientCompetitionHistoryDimensions;
            for (values) |value| if (!std.math.isFinite(value) or value < 0)
                return error.InvalidNutrientCompetitionHistoryValue;
        }
        for (self.surface_mineral_previous_capacity) |values| try validateSlice(values, self.surface_cell_count * surface_mineral_competitor_count);
        for (self.topsoil_residual_previous_capacity) |values| try validateSlice(values, self.surface_cell_count * surface_mineral_competitor_count);
        try validateSlice(self.surface_ammonia_oxidation_previous_capacity, self.surface_cell_count);
        try validateSlice(self.surface_denitrification_previous_capacity, self.surface_cell_count * surface_denitrifier_count);
    }
};

/// Attempt-local R*X accumulator. Each soil layer or surface cell is written
/// only by the worker owning that complete grid column; root additions occur
/// later in deterministic cell/plant/domain/layer order. No cross-worker
/// floating-point reduction is permitted.
pub const Attempt = struct {
    allocator: std.mem.Allocator,
    soil_layer_count: usize,
    surface_cell_count: usize,
    soil_next_total: [soil_pool_count][]f64,
    surface_next_total: [surface_pool_count][]f64,
    surface_mineral_next_capacity: [surface_pool_count][]f64,
    topsoil_residual_next_capacity: [surface_pool_count][]f64,
    surface_ammonia_oxidation_next_capacity: []f64,
    surface_denitrification_next_capacity: []f64,
    active: bool = false,

    pub fn init(allocator: std.mem.Allocator, soil_layer_count: usize, surface_cell_count: usize) !Attempt {
        if (soil_layer_count == 0 or surface_cell_count == 0)
            return error.InvalidNutrientCompetitionHistoryDimensions;
        var result: Attempt = .{
            .allocator = allocator,
            .soil_layer_count = soil_layer_count,
            .surface_cell_count = surface_cell_count,
            .soil_next_total = undefined,
            .surface_next_total = undefined,
            .surface_mineral_next_capacity = undefined,
            .topsoil_residual_next_capacity = undefined,
            .surface_ammonia_oxidation_next_capacity = &.{},
            .surface_denitrification_next_capacity = &.{},
        };
        var soil_allocated: usize = 0;
        var surface_allocated: usize = 0;
        var surface_mineral_allocated: usize = 0;
        var topsoil_residual_allocated: usize = 0;
        errdefer {
            for (result.soil_next_total[0..soil_allocated]) |values| allocator.free(values);
            for (result.surface_next_total[0..surface_allocated]) |values| allocator.free(values);
            for (result.surface_mineral_next_capacity[0..surface_mineral_allocated]) |values| allocator.free(values);
            for (result.topsoil_residual_next_capacity[0..topsoil_residual_allocated]) |values| allocator.free(values);
            if (result.surface_ammonia_oxidation_next_capacity.len != 0) allocator.free(result.surface_ammonia_oxidation_next_capacity);
            if (result.surface_denitrification_next_capacity.len != 0) allocator.free(result.surface_denitrification_next_capacity);
        }
        for (&result.soil_next_total) |*values| {
            values.* = try allocator.alloc(f64, soil_layer_count);
            @memset(values.*, 0);
            soil_allocated += 1;
        }
        for (&result.surface_next_total) |*values| {
            values.* = try allocator.alloc(f64, surface_cell_count);
            @memset(values.*, 0);
            surface_allocated += 1;
        }
        const mineral_count = try std.math.mul(usize, surface_cell_count, surface_mineral_competitor_count);
        for (&result.surface_mineral_next_capacity) |*values| {
            values.* = try allocator.alloc(f64, mineral_count);
            @memset(values.*, 0);
            surface_mineral_allocated += 1;
        }
        for (&result.topsoil_residual_next_capacity) |*values| {
            values.* = try allocator.alloc(f64, mineral_count);
            @memset(values.*, 0);
            topsoil_residual_allocated += 1;
        }
        result.surface_ammonia_oxidation_next_capacity = try allocator.alloc(f64, surface_cell_count);
        @memset(result.surface_ammonia_oxidation_next_capacity, 0);
        result.surface_denitrification_next_capacity = try allocator.alloc(f64, try std.math.mul(usize, surface_cell_count, surface_denitrifier_count));
        @memset(result.surface_denitrification_next_capacity, 0);
        return result;
    }

    pub fn deinit(self: *Attempt) void {
        for (self.soil_next_total) |values| self.allocator.free(values);
        for (self.surface_next_total) |values| self.allocator.free(values);
        for (self.surface_mineral_next_capacity) |values| self.allocator.free(values);
        for (self.topsoil_residual_next_capacity) |values| self.allocator.free(values);
        self.allocator.free(self.surface_ammonia_oxidation_next_capacity);
        self.allocator.free(self.surface_denitrification_next_capacity);
        self.* = undefined;
    }

    pub fn begin(self: *Attempt) void {
        for (self.soil_next_total) |values| @memset(values, 0);
        for (self.surface_next_total) |values| @memset(values, 0);
        for (self.surface_mineral_next_capacity) |values| @memset(values, 0);
        for (self.topsoil_residual_next_capacity) |values| @memset(values, 0);
        @memset(self.surface_ammonia_oxidation_next_capacity, 0);
        @memset(self.surface_denitrification_next_capacity, 0);
        self.active = true;
    }

    pub fn setSoil(self: *Attempt, layer: usize, totals: [soil_pool_count]f64) !void {
        if (!self.active) return error.InactiveNutrientCompetitionAttempt;
        if (layer >= self.soil_layer_count) return error.NutrientCompetitionHistoryIndexOutOfBounds;
        for (totals, 0..) |value, pool| {
            try validateContribution(value);
            self.soil_next_total[pool][layer] = value;
        }
    }

    pub fn addSoil(self: *Attempt, layer: usize, additions: [soil_pool_count]f64) !void {
        if (!self.active) return error.InactiveNutrientCompetitionAttempt;
        if (layer >= self.soil_layer_count) return error.NutrientCompetitionHistoryIndexOutOfBounds;
        for (additions, 0..) |addition, pool| {
            try validateContribution(addition);
            const next = self.soil_next_total[pool][layer] + addition;
            try validateContribution(next);
            self.soil_next_total[pool][layer] = next;
        }
    }

    pub fn recordSurfaceMineral(self: *Attempt, cell: usize, competitor: usize, capacities: [surface_pool_count]f64) !void {
        if (!self.active) return error.InactiveNutrientCompetitionAttempt;
        if (cell >= self.surface_cell_count or competitor >= surface_mineral_competitor_count)
            return error.NutrientCompetitionHistoryIndexOutOfBounds;
        const index = cell * surface_mineral_competitor_count + competitor;
        for (capacities, 0..) |capacity, pool| {
            try validateContribution(capacity);
            self.surface_mineral_next_capacity[pool][index] = capacity;
        }
    }

    /// REDIST adds the combined surface-residual capacity to the source NU
    /// layer's non-band R*X accumulator; it does not split that capacity by
    /// fertilizer zone.
    pub fn recordTopsoilResidual(self: *Attempt, layer: usize, cell: usize, competitor: usize, capacities: [surface_pool_count]f64) !void {
        if (!self.active) return error.InactiveNutrientCompetitionAttempt;
        if (layer >= self.soil_layer_count or cell >= self.surface_cell_count or competitor >= surface_mineral_competitor_count)
            return error.NutrientCompetitionHistoryIndexOutOfBounds;
        const index = cell * surface_mineral_competitor_count + competitor;
        const target = [_]usize{
            @intFromEnum(SoilPool.ammonium_non_band),
            @intFromEnum(SoilPool.nitrate_non_band),
            @intFromEnum(SoilPool.h2po4_non_band),
            @intFromEnum(SoilPool.hpo4_non_band),
        };
        for (capacities, 0..) |capacity, pool| {
            try validateContribution(capacity);
            self.topsoil_residual_next_capacity[pool][index] = capacity;
            const next = self.soil_next_total[target[pool]][layer] + capacity;
            try validateContribution(next);
            self.soil_next_total[target[pool]][layer] = next;
        }
    }

    pub fn recordSurfaceAmmoniaOxidation(self: *Attempt, cell: usize, capacity: f64) !void {
        if (!self.active) return error.InactiveNutrientCompetitionAttempt;
        if (cell >= self.surface_cell_count) return error.NutrientCompetitionHistoryIndexOutOfBounds;
        try validateContribution(capacity);
        self.surface_ammonia_oxidation_next_capacity[cell] = capacity;
    }

    pub fn recordSurfaceDenitrification(self: *Attempt, cell: usize, complex: usize, capacity: f64) !void {
        if (!self.active) return error.InactiveNutrientCompetitionAttempt;
        if (cell >= self.surface_cell_count or complex >= surface_denitrifier_count)
            return error.NutrientCompetitionHistoryIndexOutOfBounds;
        try validateContribution(capacity);
        self.surface_denitrification_next_capacity[cell * surface_denitrifier_count + complex] = capacity;
    }

    /// Reconstructs REDIST 308--330 in exact K,N source order. Producers run
    /// in a different stage order (K=5 NH4 oxidation is prepared before K<=2
    /// mineral exchange and denitrification), so stage-time accumulation would
    /// change floating-point association and no longer reproduce R*X.
    fn rebuildSurfaceTotalsInSourceOrder(self: *Attempt) !void {
        for (self.surface_next_total) |values| @memset(values, 0);
        for (0..self.surface_cell_count) |cell| {
            for (0..surface_mineral_competitor_count) |competitor| {
                if (competitor == surface_heterotroph_count)
                    try addChecked(&self.surface_next_total[@intFromEnum(SurfacePool.ammonium)][cell], self.surface_ammonia_oxidation_next_capacity[cell]);
                if (competitor < surface_heterotroph_count and competitor % 7 == 1) {
                    const complex = competitor / 7;
                    try addChecked(&self.surface_next_total[@intFromEnum(SurfacePool.nitrate)][cell], self.surface_denitrification_next_capacity[cell * surface_denitrifier_count + complex]);
                }
                for (0..surface_pool_count) |pool|
                    try addChecked(&self.surface_next_total[pool][cell], self.surface_mineral_next_capacity[pool][cell * surface_mineral_competitor_count + competitor]);
            }
        }
    }

    /// No mutation occurs before the complete next state is preflighted.
    /// Mirroring the legacy total fields keeps older internal diagnostics
    /// coherent while all production consumers use `accepted` directly.
    pub fn publishAccepted(
        self: *Attempt,
        accepted: *State,
        reactive: *reactive_nitrogen.State,
        phosphorus: *phosphorus_history.State,
    ) !void {
        if (!self.active) return error.InactiveNutrientCompetitionAttempt;
        if (accepted.soil_layer_count != self.soil_layer_count or
            accepted.surface_cell_count != self.surface_cell_count or
            reactive.layer_count != self.soil_layer_count or
            phosphorus.layer_count != self.soil_layer_count)
            return error.InvalidNutrientCompetitionHistoryDimensions;
        try self.rebuildSurfaceTotalsInSourceOrder();
        for (self.soil_next_total) |values| for (values) |value| try validateContribution(value);
        for (self.surface_next_total) |values| for (values) |value| try validateContribution(value);

        for (accepted.soil_previous_total, self.soil_next_total) |destination, source|
            @memcpy(destination, source);
        for (accepted.surface_previous_total, self.surface_next_total) |destination, source|
            @memcpy(destination, source);
        for (accepted.surface_mineral_previous_capacity, self.surface_mineral_next_capacity) |destination, source|
            @memcpy(destination, source);
        for (accepted.topsoil_residual_previous_capacity, self.topsoil_residual_next_capacity) |destination, source|
            @memcpy(destination, source);
        @memcpy(accepted.surface_ammonia_oxidation_previous_capacity, self.surface_ammonia_oxidation_next_capacity);
        @memcpy(accepted.surface_denitrification_previous_capacity, self.surface_denitrification_next_capacity);

        @memcpy(reactive.previous_total_non_band_ammonium_demand_g_n, self.soil_next_total[@intFromEnum(SoilPool.ammonium_non_band)]);
        @memcpy(reactive.previous_total_band_ammonium_demand_g_n, self.soil_next_total[@intFromEnum(SoilPool.ammonium_band)]);
        @memcpy(reactive.previous_total_non_band_nitrate_demand_g_n, self.soil_next_total[@intFromEnum(SoilPool.nitrate_non_band)]);
        @memcpy(reactive.previous_total_band_nitrate_demand_g_n, self.soil_next_total[@intFromEnum(SoilPool.nitrate_band)]);
        @memcpy(phosphorus.previous_total_non_band_h2po4_demand_g_p, self.soil_next_total[@intFromEnum(SoilPool.h2po4_non_band)]);
        @memcpy(phosphorus.previous_total_band_h2po4_demand_g_p, self.soil_next_total[@intFromEnum(SoilPool.h2po4_band)]);
        @memcpy(phosphorus.previous_total_non_band_hpo4_demand_g_p, self.soil_next_total[@intFromEnum(SoilPool.hpo4_non_band)]);
        @memcpy(phosphorus.previous_total_band_hpo4_demand_g_p, self.soil_next_total[@intFromEnum(SoilPool.hpo4_band)]);
        self.active = false;
    }
};

fn validateContribution(value: f64) !void {
    if (!std.math.isFinite(value) or value < 0)
        return error.InvalidNutrientCompetitionHistoryValue;
}

fn validateSlice(values: []const f64, expected_len: usize) !void {
    if (values.len != expected_len) return error.InvalidNutrientCompetitionHistoryDimensions;
    for (values) |value| try validateContribution(value);
}

test "mixed accepted history publishes atomically and failed retry cannot mutate it" {
    var accepted = try State.init(std.testing.allocator, 2, 1);
    defer accepted.deinit();
    var attempt = try Attempt.init(std.testing.allocator, 2, 1);
    defer attempt.deinit();
    var reactive = try reactive_nitrogen.State.init(std.testing.allocator, 2, 1);
    defer reactive.deinit();
    var phosphorus = try phosphorus_history.State.init(std.testing.allocator, 2, 1);
    defer phosphorus.deinit();

    accepted.soil_previous_total[0][0] = 7;
    attempt.begin();
    try attempt.setSoil(0, .{ 2, 3, 5, 7, 11, 13, 17, 19 });
    try attempt.recordTopsoilResidual(0, 0, 0, .{ 23, 29, 31, 37 });
    try attempt.addSoil(0, .{ 41, 43, 47, 53, 59, 61, 67, 71 });
    try attempt.recordSurfaceMineral(0, 0, .{ 73, 79, 83, 89 });
    try attempt.recordSurfaceAmmoniaOxidation(0, 97);
    try attempt.recordSurfaceDenitrification(0, 2, 101);
    try std.testing.expectEqual(@as(f64, 7), accepted.soil_previous_total[0][0]);
    try std.testing.expectEqual(@as(f64, 66), attempt.soil_next_total[@intFromEnum(SoilPool.ammonium_non_band)][0]);
    try std.testing.expectEqual(@as(f64, 121), attempt.soil_next_total[@intFromEnum(SoilPool.hpo4_non_band)][0]);
    try attempt.publishAccepted(&accepted, &reactive, &phosphorus);
    try std.testing.expectEqual(@as(f64, 66), accepted.soil_previous_total[@intFromEnum(SoilPool.ammonium_non_band)][0]);
    try std.testing.expectEqual(@as(f64, 180), accepted.surface_previous_total[@intFromEnum(SurfacePool.nitrate)][0]);

    // A failed attempt is discarded simply by beginning the retry; accepted
    // state remains byte-for-byte unchanged.
    attempt.begin();
    try attempt.setSoil(0, .{ 901, 902, 903, 904, 905, 906, 907, 908 });
    try std.testing.expectEqual(@as(f64, 66), accepted.soil_previous_total[0][0]);
    attempt.begin();
    try std.testing.expectEqual(@as(f64, 0), attempt.soil_next_total[0][0]);
    try attempt.setSoil(0, .{ 41, 43, 47, 53, 59, 61, 67, 71 });
    try attempt.recordSurfaceMineral(0, 0, .{ 73, 79, 83, 89 });
    try attempt.publishAccepted(&accepted, &reactive, &phosphorus);
    try std.testing.expectEqual(@as(f64, 41), accepted.soil_previous_total[0][0]);
    try std.testing.expectEqual(@as(f64, 89), accepted.surface_previous_total[3][0]);
    try std.testing.expectEqual(@as(f64, 41), reactive.previous_total_non_band_ammonium_demand_g_n[0]);
    try std.testing.expectEqual(@as(f64, 67), phosphorus.previous_total_non_band_hpo4_demand_g_p[0]);
}

fn addChecked(destination: *f64, addition: f64) !void {
    try validateContribution(addition);
    const next = destination.* + addition;
    try validateContribution(next);
    destination.* = next;
}
