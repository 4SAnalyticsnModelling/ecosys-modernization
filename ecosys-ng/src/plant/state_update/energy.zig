const std = @import("std");

/// Runtime-sized EXTRACT `TRNP/TLEP/TSHP/TGHP` state_update. Values are
/// extensive MJ per hour for one plant population in one horizontal cell.
pub const State = struct {
    allocator: std.mem.Allocator,
    plant_count: usize,
    net_radiation_megajoules_per_h: []f64,
    latent_heat_megajoules_per_h: []f64,
    sensible_heat_megajoules_per_h: []f64,
    storage_heat_megajoules_per_h: []f64,

    pub fn init(allocator: std.mem.Allocator, plant_count: usize) !State {
        if (plant_count == 0) return error.InvalidPlantEnergyStateUpdateDimensions;
        const net = try allocator.alloc(f64, plant_count);
        errdefer allocator.free(net);
        const latent = try allocator.alloc(f64, plant_count);
        errdefer allocator.free(latent);
        const sensible = try allocator.alloc(f64, plant_count);
        errdefer allocator.free(sensible);
        const storage = try allocator.alloc(f64, plant_count);
        @memset(net, 0);
        @memset(latent, 0);
        @memset(sensible, 0);
        @memset(storage, 0);
        return .{
            .allocator = allocator,
            .plant_count = plant_count,
            .net_radiation_megajoules_per_h = net,
            .latent_heat_megajoules_per_h = latent,
            .sensible_heat_megajoules_per_h = sensible,
            .storage_heat_megajoules_per_h = storage,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.storage_heat_megajoules_per_h);
        self.allocator.free(self.sensible_heat_megajoules_per_h);
        self.allocator.free(self.latent_heat_megajoules_per_h);
        self.allocator.free(self.net_radiation_megajoules_per_h);
        self.* = undefined;
    }
};

pub const Inputs = struct {
    living_net_radiation_megajoules: []const f64,
    living_latent_heat_megajoules: []const f64,
    living_sensible_heat_megajoules: []const f64,
    living_storage_heat_megajoules: []const f64,
    living_convective_water_heat_megajoules: []const f64,
    standing_dead_net_radiation_megajoules: []const f64,
    standing_dead_latent_heat_megajoules: []const f64,
    standing_dead_sensible_heat_megajoules: []const f64,
    standing_dead_storage_heat_megajoules: []const f64,
    standing_dead_convective_water_heat_megajoules: []const f64,
};

const Candidate = struct {
    net_radiation_megajoules_per_h: f64,
    latent_heat_megajoules_per_h: f64,
    sensible_heat_megajoules_per_h: f64,
    storage_heat_megajoules_per_h: f64,
};

/// Exact EXTRACT lines 618–635 state_update. The source order is living canopy
/// followed by standing dead for each runtime plant. Storage retains the
/// legacy sign `TGHP -= HFLXC - VFLXC`.
pub fn refresh(state: *State, inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field|
        if (@field(inputs, field.name).len != state.plant_count)
            return error.InvalidPlantEnergyStateUpdateDimensions;
    for (0..state.plant_count) |plant| _ = try candidate(inputs, plant);
    for (0..state.plant_count) |plant| {
        const next = candidate(inputs, plant) catch unreachable;
        state.net_radiation_megajoules_per_h[plant] = next.net_radiation_megajoules_per_h;
        state.latent_heat_megajoules_per_h[plant] = next.latent_heat_megajoules_per_h;
        state.sensible_heat_megajoules_per_h[plant] = next.sensible_heat_megajoules_per_h;
        state.storage_heat_megajoules_per_h[plant] = next.storage_heat_megajoules_per_h;
    }
}

fn candidate(inputs: Inputs, plant: usize) !Candidate {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        const value = @field(inputs, field.name)[plant];
        if (!std.math.isFinite(value))
            return error.NonFinitePlantEnergyStateUpdateInput;
    }
    const result: Candidate = .{
        .net_radiation_megajoules_per_h = inputs.living_net_radiation_megajoules[plant] +
            inputs.standing_dead_net_radiation_megajoules[plant],
        .latent_heat_megajoules_per_h = inputs.living_latent_heat_megajoules[plant] +
            inputs.standing_dead_latent_heat_megajoules[plant],
        .sensible_heat_megajoules_per_h = inputs.living_sensible_heat_megajoules[plant] +
            inputs.standing_dead_sensible_heat_megajoules[plant],
        .storage_heat_megajoules_per_h = -(inputs.living_storage_heat_megajoules[plant] -
            inputs.living_convective_water_heat_megajoules[plant]) -
            (inputs.standing_dead_storage_heat_megajoules[plant] -
                inputs.standing_dead_convective_water_heat_megajoules[plant]),
    };
    inline for (@typeInfo(Candidate).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFinitePlantEnergyStateUpdate;
    return result;
}

test "EXTRACT plant energy state_update preserves signs and runtime species order" {
    var state = try State.init(std.testing.allocator, 3);
    defer state.deinit();
    try refresh(&state, .{
        .living_net_radiation_megajoules = &.{ 1, 2, 3 },
        .living_latent_heat_megajoules = &.{ 4, 5, 6 },
        .living_sensible_heat_megajoules = &.{ 7, 8, 9 },
        .living_storage_heat_megajoules = &.{ 10, 11, 12 },
        .living_convective_water_heat_megajoules = &.{ 0.5, 1, 1.5 },
        .standing_dead_net_radiation_megajoules = &.{ 0.1, 0.2, 0.3 },
        .standing_dead_latent_heat_megajoules = &.{ 0.4, 0.5, 0.6 },
        .standing_dead_sensible_heat_megajoules = &.{ 0.7, 0.8, 0.9 },
        .standing_dead_storage_heat_megajoules = &.{ 1, 2, 3 },
        .standing_dead_convective_water_heat_megajoules = &.{ 0.05, 0.1, 0.15 },
    });
    try std.testing.expectApproxEqAbs(@as(f64, 3.3), state.net_radiation_megajoules_per_h[2], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 6.6), state.latent_heat_megajoules_per_h[2], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 9.9), state.sensible_heat_megajoules_per_h[2], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -13.35), state.storage_heat_megajoules_per_h[2], 1e-14);
    var published_net: f64 = 0;
    var published_latent: f64 = 0;
    var published_sensible: f64 = 0;
    var published_storage: f64 = 0;
    for (0..state.plant_count) |plant| {
        published_net += state.net_radiation_megajoules_per_h[plant];
        published_latent += state.latent_heat_megajoules_per_h[plant];
        published_sensible += state.sensible_heat_megajoules_per_h[plant];
        published_storage += state.storage_heat_megajoules_per_h[plant];
    }
    try std.testing.expectApproxEqAbs(@as(f64, 6.6), published_net, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 16.5), published_latent, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 26.4), published_sensible, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, -35.7), published_storage, 1e-14);
}

test "late invalid plant leaves complete state_update unchanged" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(state.net_radiation_megajoules_per_h, 7);
    @memset(state.latent_heat_megajoules_per_h, 8);
    const invalid = [_]f64{ 1, std.math.nan(f64) };
    try std.testing.expectError(error.NonFinitePlantEnergyStateUpdateInput, refresh(&state, .{
        .living_net_radiation_megajoules = &invalid,
        .living_latent_heat_megajoules = &.{ 0, 0 },
        .living_sensible_heat_megajoules = &.{ 0, 0 },
        .living_storage_heat_megajoules = &.{ 0, 0 },
        .living_convective_water_heat_megajoules = &.{ 0, 0 },
        .standing_dead_net_radiation_megajoules = &.{ 0, 0 },
        .standing_dead_latent_heat_megajoules = &.{ 0, 0 },
        .standing_dead_sensible_heat_megajoules = &.{ 0, 0 },
        .standing_dead_storage_heat_megajoules = &.{ 0, 0 },
        .standing_dead_convective_water_heat_megajoules = &.{ 0, 0 },
    }));
    try std.testing.expectEqualSlices(f64, &.{ 7, 7 }, state.net_radiation_megajoules_per_h);
    try std.testing.expectEqualSlices(f64, &.{ 8, 8 }, state.latent_heat_megajoules_per_h);
}
