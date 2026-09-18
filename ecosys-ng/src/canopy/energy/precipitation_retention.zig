const std = @import("std");
const LayerState = @import("../radiation/layer_distribution.zig").State;
const CanopyState = @import("../photosynthesis/photosynthesis.zig").State;
const InterceptionState = @import("interception.zig").State;
const BurialInputs = @import("interception.zig").BurialInputs;
const source_order = @import("precipitation_retention_source_order.zig");

pub const Parameters = struct {
    surface_water_capacity_m3_per_m2_by_root_profile: [4]f64,
    low_sun_extinction_per_area_index: f64,
    minimum_solar_angle_sine_for_radiation_shares: f64,

    pub fn validate(self: Parameters) !void {
        inline for (self.surface_water_capacity_m3_per_m2_by_root_profile) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidCanopyRetentionParameters;
        if (!std.math.isFinite(self.low_sun_extinction_per_area_index) or
            self.low_sun_extinction_per_area_index < 0 or
            !std.math.isFinite(self.minimum_solar_angle_sine_for_radiation_shares) or
            self.minimum_solar_angle_sine_for_radiation_shares < 0 or
            self.minimum_solar_angle_sine_for_radiation_shares > 1)
            return error.InvalidCanopyRetentionParameters;
    }
};

pub fn compatibilityParameters() Parameters {
    return .{
        .surface_water_capacity_m3_per_m2_by_root_profile = .{
            5.0e-4,
            2.5e-4,
            2.5e-4,
            2.5e-4,
        },
        .low_sun_extinction_per_area_index = 0.65,
        .minimum_solar_angle_sine_for_radiation_shares = 0.05,
    };
}

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    living_surface_area_m2: []f64,
    standing_dead_surface_area_m2: []f64,
    living_radiation_fraction: []f64,
    standing_dead_radiation_fraction: []f64,
    living_absorbed_shortwave_megajoules_per_m2: []f64,
    standing_dead_absorbed_shortwave_megajoules_per_m2: []f64,
    living_surface_water_m3: []f64,
    standing_dead_surface_water_m3: []f64,
    living_retention_m3_per_h: []f64,
    standing_dead_retention_m3_per_h: []f64,
    previous_water_energy_megajoules: []f64,
    cell_potential_interception_m3_per_h: []f64,
    cell_retention_m3_per_h: []f64,
    cell_throughfall_m3_per_h: []f64,

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

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0)
            return error.InvalidCanopyRetentionDimensions;
        const plant_count = try std.math.mul(usize, cell_count, species_count);
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        result.species_count = species_count;
        var allocated: usize = 0;
        errdefer result.deinitAllocatedPrefix(allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) {
                const count = if (comptime std.mem.startsWith(u8, field.name, "cell_"))
                    cell_count
                else
                    plant_count;
                @field(result, field.name) = try allocator.alloc(f64, count);
                @memset(@field(result, field.name), 0);
                allocated += 1;
            }
        }
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field|
            if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }
};

test "canopy precipitation retention releases every partial allocation prefix" {
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

pub fn refreshFromModel(
    state: *State,
    layers: *const LayerState,
    canopy: *const CanopyState,
    interception: *const InterceptionState,
    rainfall_m_by_cell: []const f64,
    cell_area_m2: []const f64,
    root_profile_type_by_plant: []const u8,
    solar_angle_sine_by_cell: []const f64,
    incident_ground_shortwave_megajoules_per_m2: []const f64,
    parameters: Parameters,
) !void {
    return refreshFromModelInternal(state, layers, canopy, interception, rainfall_m_by_cell, cell_area_m2, root_profile_type_by_plant, solar_angle_sine_by_cell, incident_ground_shortwave_megajoules_per_m2, parameters, null);
}

pub fn refreshFromModelWithBurial(
    state: *State,
    layers: *const LayerState,
    canopy: *const CanopyState,
    interception: *const InterceptionState,
    rainfall_m_by_cell: []const f64,
    cell_area_m2: []const f64,
    root_profile_type_by_plant: []const u8,
    solar_angle_sine_by_cell: []const f64,
    incident_ground_shortwave_megajoules_per_m2: []const f64,
    parameters: Parameters,
    burial: BurialInputs,
) !void {
    try burial.validate(state.cell_count);
    return refreshFromModelInternal(state, layers, canopy, interception, rainfall_m_by_cell, cell_area_m2, root_profile_type_by_plant, solar_angle_sine_by_cell, incident_ground_shortwave_megajoules_per_m2, parameters, burial);
}

fn refreshFromModelInternal(
    state: *State,
    layers: *const LayerState,
    canopy: *const CanopyState,
    interception: *const InterceptionState,
    rainfall_m_by_cell: []const f64,
    cell_area_m2: []const f64,
    root_profile_type_by_plant: []const u8,
    solar_angle_sine_by_cell: []const f64,
    incident_ground_shortwave_megajoules_per_m2: []const f64,
    parameters: Parameters,
    burial: ?BurialInputs,
) !void {
    try parameters.validate();
    const plant_count = try validateModelDimensions(
        state,
        layers,
        canopy,
        interception,
        rainfall_m_by_cell,
        cell_area_m2,
        root_profile_type_by_plant,
        solar_angle_sine_by_cell,
        incident_ground_shortwave_megajoules_per_m2,
    );
    var leaf_area_by_plant_m2 = try state.allocator.alloc(f64, plant_count);
    var stalk_area_by_plant_m2 = try state.allocator.alloc(f64, plant_count);
    defer {
        state.allocator.free(leaf_area_by_plant_m2);
        state.allocator.free(stalk_area_by_plant_m2);
    }
    for (0..plant_count) |plant| {
        const cell = plant / state.species_count;
        var living_leaf_area_m2: f64 = 0;
        var living_stalk_area_m2: f64 = 0;
        var dead_area_m2: f64 = 0;
        var dead_shortwave_megajoules_per_m2: f64 = 0;
        for (0..layers.layer_count) |layer| {
            if (burial) |inputs| if (!(try inputs.layerIsExposed(layers, cell, layer))) continue;
            const plant_layer = plant * layers.layer_count + layer;
            dead_area_m2 += layers.plant_standing_dead_area_m2[plant_layer];
            dead_shortwave_megajoules_per_m2 +=
                interception.standing_dead_absorbed_shortwave_by_layer_megajoules_per_m2[
                    plant_layer
                ];
        }
        const branch_first = canopy.plant_branch_offsets[plant];
        const branch_end = canopy.plant_branch_offsets[plant + 1];
        for (branch_first..branch_end) |branch| {
            const first = branch * layers.layer_count;
            for (0..layers.layer_count) |layer| {
                if (burial) |inputs| if (!(try inputs.layerIsExposed(layers, cell, layer))) continue;
                living_stalk_area_m2 += layers.branch_stalk_area_m2[first + layer];
            }
            const node_first = canopy.branch_node_offsets[branch];
            const node_end = canopy.branch_node_offsets[branch + 1];
            for (node_first..node_end) |node| {
                const node_layer_first = node * layers.layer_count;
                for (0..layers.layer_count) |layer| {
                    if (burial) |inputs| if (!(try inputs.layerIsExposed(layers, cell, layer))) continue;
                    living_leaf_area_m2 += layers.node_leaf_area_m2[node_layer_first + layer];
                }
            }
        }
        const live_shortwave = interception.absorbed_shortwave_megajoules_per_m2[plant];
        const living_area_m2 = living_leaf_area_m2 + living_stalk_area_m2;
        leaf_area_by_plant_m2[plant] = living_leaf_area_m2;
        stalk_area_by_plant_m2[plant] = living_stalk_area_m2;
        state.living_surface_area_m2[plant] = living_area_m2;
        state.standing_dead_surface_area_m2[plant] = dead_area_m2;
        state.living_absorbed_shortwave_megajoules_per_m2[plant] = live_shortwave;
        state.standing_dead_absorbed_shortwave_megajoules_per_m2[plant] =
            dead_shortwave_megajoules_per_m2;
    }
    // hour1.f:4713-4779 (ARLSS/TRADT/FRADP/FRADQ): the radiation-interception
    // share of a cell's precipitation is a SINGLE quantity shared by every
    // species present in that cell (TRADT, from either the high-sun
    // canopy+ground-absorption total or the low-sun leaf+stalk+dead-area
    // total), then split proportionally per species by that species' own
    // area/absorption share of the shared total. Computing each species'
    // fraction independently against its own denominator (as this file did
    // before this fix) lets multiple co-occurring species each claim close
    // to 100% of the cell's precipitation, fabricating water mass.
    for (0..state.cell_count) |cell| {
        const first = cell * state.species_count;
        const last = first + state.species_count;
        var cell_living_dead_area_total_m2: f64 = 0;
        var cell_absorbed_total_megajoules_per_m2: f64 = 0;
        for (first..last) |plant| {
            cell_living_dead_area_total_m2 +=
                state.living_surface_area_m2[plant] + state.standing_dead_surface_area_m2[plant];
            cell_absorbed_total_megajoules_per_m2 +=
                state.living_absorbed_shortwave_megajoules_per_m2[plant] +
                state.standing_dead_absorbed_shortwave_megajoules_per_m2[plant];
        }
        const shared_high_sun_total_megajoules_per_m2 = cell_absorbed_total_megajoules_per_m2 +
            incident_ground_shortwave_megajoules_per_m2[cell];
        const shared_low_sun_fraction = 1.0 -
            std.math.exp(-parameters.low_sun_extinction_per_area_index *
                cell_living_dead_area_total_m2 / cell_area_m2[cell]);
        const use_high_sun = solar_angle_sine_by_cell[cell] >
            parameters.minimum_solar_angle_sine_for_radiation_shares and
            shared_high_sun_total_megajoules_per_m2 > 0;
        for (first..last) |plant| {
            const live_shortwave = state.living_absorbed_shortwave_megajoules_per_m2[plant];
            const dead_shortwave = state.standing_dead_absorbed_shortwave_megajoules_per_m2[plant];
            const area_total_m2 =
                state.living_surface_area_m2[plant] + state.standing_dead_surface_area_m2[plant];
            const intercepted_fraction = sharedRadiationInterceptionFraction(.{
                .use_high_sun = use_high_sun,
                .plant_total_absorbed_megajoules_per_m2 = live_shortwave + dead_shortwave,
                .shared_high_sun_total_megajoules_per_m2 = shared_high_sun_total_megajoules_per_m2,
                .plant_area_total_m2 = area_total_m2,
                .shared_low_sun_fraction = shared_low_sun_fraction,
                .cell_living_dead_area_total_m2 = cell_living_dead_area_total_m2,
            });
            const live_share = if (live_shortwave + dead_shortwave > 0)
                live_shortwave / (live_shortwave + dead_shortwave)
            else if (area_total_m2 > 0)
                state.living_surface_area_m2[plant] / area_total_m2
            else
                0;
            state.living_radiation_fraction[plant] =
                intercepted_fraction * live_share;
            state.standing_dead_radiation_fraction[plant] =
                intercepted_fraction * (1.0 - live_share);
        }
        const totals = try source_order.compute(
            .{
                .precipitation_irrigation_m3_h = rainfall_m_by_cell[cell] * cell_area_m2[cell],
                .retention_capacity_m3_per_m2_by_vegetation_type = &parameters.surface_water_capacity_m3_per_m2_by_root_profile,
                .vegetation_type_by_species = root_profile_type_by_plant[first..last],
                .leaf_area_m2 = leaf_area_by_plant_m2[first..last],
                .stalk_area_m2 = stalk_area_by_plant_m2[first..last],
                .standing_dead_area_m2 = state.standing_dead_surface_area_m2[first..last],
                .live_water_content_m3 = state.living_surface_water_m3[first..last],
                .standing_dead_water_content_m3 = state.standing_dead_surface_water_m3[first..last],
                .live_radiation_fraction = state.living_radiation_fraction[first..last],
                .standing_dead_radiation_fraction = state.standing_dead_radiation_fraction[first..last],
            },
            .{
                .live_retention_flux_m3_h = state.living_retention_m3_per_h[first..last],
                .standing_dead_retention_flux_m3_h = state.standing_dead_retention_m3_per_h[first..last],
            },
        );
        state.cell_potential_interception_m3_per_h[cell] =
            totals.potential_interception_m3_h;
        state.cell_retention_m3_per_h[cell] = totals.retention_flux_m3_h;
        state.cell_throughfall_m3_per_h[cell] =
            rainfall_m_by_cell[cell] * cell_area_m2[cell] - totals.retention_flux_m3_h;
    }
}

pub fn state_updateRetention(state: *State, timestep_h: f64) !void {
    if (!std.math.isFinite(timestep_h) or timestep_h < 0)
        return error.InvalidCanopyRetentionTimestep;
    for (state.living_surface_water_m3, state.standing_dead_surface_water_m3, state.living_retention_m3_per_h, state.standing_dead_retention_m3_per_h) |living, dead, live_rate, dead_rate| {
        const next_living = living + live_rate * timestep_h;
        const next_dead = dead + dead_rate * timestep_h;
        if (!std.math.isFinite(next_living) or !std.math.isFinite(next_dead) or
            next_living < 0 or next_dead < 0)
            return error.InvalidCanopyRetentionStateUpdate;
    }
    for (state.living_surface_water_m3, state.standing_dead_surface_water_m3, state.living_retention_m3_per_h, state.standing_dead_retention_m3_per_h) |*living, *dead, live_rate, dead_rate| {
        living.* += live_rate * timestep_h;
        dead.* += dead_rate * timestep_h;
    }
}

pub fn state_updateSurfaceWater(
    state: *State,
    living_water_change_m3_per_h: []const f64,
    standing_dead_water_change_m3_per_h: []const f64,
    timestep_h: f64,
) !void {
    const plant_count = state.living_surface_water_m3.len;
    if (living_water_change_m3_per_h.len != plant_count or
        standing_dead_water_change_m3_per_h.len != plant_count)
        return error.CanopyRetentionDimensionMismatch;
    for (0..plant_count) |plant| {
        const next_living = state.living_surface_water_m3[plant] +
            (state.living_retention_m3_per_h[plant] +
                living_water_change_m3_per_h[plant]) * timestep_h;
        const next_dead = state.standing_dead_surface_water_m3[plant] +
            (state.standing_dead_retention_m3_per_h[plant] +
                standing_dead_water_change_m3_per_h[plant]) * timestep_h;
        if (!std.math.isFinite(next_living) or !std.math.isFinite(next_dead) or
            next_living < 0 or next_dead < 0)
            return error.InvalidCanopySurfaceWaterStateUpdate;
    }
    for (0..plant_count) |plant| {
        const next_living = state.living_surface_water_m3[plant] +
            (state.living_retention_m3_per_h[plant] +
                living_water_change_m3_per_h[plant]) * timestep_h;
        const next_dead = state.standing_dead_surface_water_m3[plant] +
            (state.standing_dead_retention_m3_per_h[plant] +
                standing_dead_water_change_m3_per_h[plant]) * timestep_h;
        state.living_surface_water_m3[plant] = next_living;
        state.standing_dead_surface_water_m3[plant] = next_dead;
    }
}

/// hour1.f:4733-4771 (TRADT/FRADP/FRADQ): one species' share of a cell's
/// intercepted radiation is that species' own absorbed radiation (or area,
/// in the low-sun branch) divided by a total SHARED by every species in the
/// cell, not by that species' own total. Summing this fraction over every
/// species sharing a cell therefore cannot exceed the shared fraction that
/// produced it (<=1), which is the invariant this function exists to
/// preserve -- see the regression test proving it below.
const SharedRadiationInterceptionInputs = struct {
    use_high_sun: bool,
    plant_total_absorbed_megajoules_per_m2: f64,
    shared_high_sun_total_megajoules_per_m2: f64,
    plant_area_total_m2: f64,
    shared_low_sun_fraction: f64,
    cell_living_dead_area_total_m2: f64,
};

fn sharedRadiationInterceptionFraction(inputs: SharedRadiationInterceptionInputs) f64 {
    if (inputs.use_high_sun) {
        return std.math.clamp(
            inputs.plant_total_absorbed_megajoules_per_m2 /
                inputs.shared_high_sun_total_megajoules_per_m2,
            0,
            1,
        );
    }
    if (inputs.cell_living_dead_area_total_m2 > 0) {
        return std.math.clamp(
            inputs.shared_low_sun_fraction * inputs.plant_area_total_m2 /
                inputs.cell_living_dead_area_total_m2,
            0,
            1,
        );
    }
    return 0;
}

fn retentionFlux(
    precipitation_share_m3_per_h: f64,
    capacity_m3: f64,
    stored_m3: f64,
) f64 {
    return @max(0, @min(precipitation_share_m3_per_h, capacity_m3 - stored_m3)) -
        @max(0, stored_m3 - capacity_m3);
}

fn validateModelDimensions(
    state: *const State,
    layers: *const LayerState,
    canopy: *const CanopyState,
    interception: *const InterceptionState,
    rainfall: []const f64,
    area: []const f64,
    profiles: []const u8,
    solar_sine: []const f64,
    ground_shortwave: []const f64,
) !usize {
    const plants = try std.math.mul(usize, state.cell_count, state.species_count);
    if (layers.cell_count != state.cell_count or
        layers.species_count != state.species_count or
        canopy.cell_count != state.cell_count or
        canopy.species_count != state.species_count or
        interception.cell_count != state.cell_count or
        interception.species_count != state.species_count or
        rainfall.len != state.cell_count or area.len != state.cell_count or
        solar_sine.len != state.cell_count or
        ground_shortwave.len != state.cell_count or profiles.len != plants)
        return error.CanopyRetentionDimensionMismatch;
    for (0..state.cell_count) |cell| {
        inline for (.{ rainfall[cell], area[cell], solar_sine[cell], ground_shortwave[cell] }) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidCanopyRetentionInput;
        if (area[cell] == 0 or solar_sine[cell] > 1)
            return error.InvalidCanopyRetentionInput;
    }
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (field.type == []f64) for (@field(state, field.name)) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidCanopyRetentionState;
    return plants;
}

test "shared radiation interception fraction: two species sharing a cell never claim more than the cell's shared fraction, unlike each dividing by its own total" {
    // Two species, each independently absorbing MORE than the ground-incident
    // radiation the buggy per-plant-denominator formula would have divided
    // by (i.e. each would individually clamp to 1.0 under the old formula).
    // Under hour1.f's shared-denominator formula, their fractions must sum to
    // <= 1 -- the cell cannot receive more precipitation-interception credit
    // than the shared total radiation it actually absorbed.
    const shared_total: f64 = 10.0;
    const species_a = sharedRadiationInterceptionFraction(.{
        .use_high_sun = true,
        .plant_total_absorbed_megajoules_per_m2 = 6.0,
        .shared_high_sun_total_megajoules_per_m2 = shared_total,
        .plant_area_total_m2 = 0,
        .shared_low_sun_fraction = 0,
        .cell_living_dead_area_total_m2 = 0,
    });
    const species_b = sharedRadiationInterceptionFraction(.{
        .use_high_sun = true,
        .plant_total_absorbed_megajoules_per_m2 = 4.0,
        .shared_high_sun_total_megajoules_per_m2 = shared_total,
        .plant_area_total_m2 = 0,
        .shared_low_sun_fraction = 0,
        .cell_living_dead_area_total_m2 = 0,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), species_a, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), species_b, 1.0e-15);
    try std.testing.expect(species_a + species_b <= 1.0 + 1.0e-15);

    // The buggy per-plant formula this fix replaced divided each species'
    // own absorption by a much smaller per-plant "incident" value, which
    // would clamp both of the above to 1.0 (sum = 2.0, fabricating mass).
    const buggy_a = std.math.clamp(@as(f64, 6.0) / 3.0, 0, 1);
    const buggy_b = std.math.clamp(@as(f64, 4.0) / 3.0, 0, 1);
    try std.testing.expect(buggy_a + buggy_b > 1.0);
}

test "shared radiation interception fraction: low-sun branch splits by area share of the shared total, sum never exceeds the shared fraction" {
    const shared_area_total: f64 = 5.0;
    const shared_fraction: f64 = 0.8;
    const species_a = sharedRadiationInterceptionFraction(.{
        .use_high_sun = false,
        .plant_total_absorbed_megajoules_per_m2 = 0,
        .shared_high_sun_total_megajoules_per_m2 = 0,
        .plant_area_total_m2 = 3.0,
        .shared_low_sun_fraction = shared_fraction,
        .cell_living_dead_area_total_m2 = shared_area_total,
    });
    const species_b = sharedRadiationInterceptionFraction(.{
        .use_high_sun = false,
        .plant_total_absorbed_megajoules_per_m2 = 0,
        .shared_high_sun_total_megajoules_per_m2 = 0,
        .plant_area_total_m2 = 2.0,
        .shared_low_sun_fraction = shared_fraction,
        .cell_living_dead_area_total_m2 = shared_area_total,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.48), species_a, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.32), species_b, 1.0e-15);
    try std.testing.expectApproxEqAbs(shared_fraction, species_a + species_b, 1.0e-14);
}

test "shared radiation interception fraction: single species sharing its own cell alone is unaffected (regression guard)" {
    // With only one species in the cell, the shared total equals that
    // species' own total, so the result must match the pre-fix per-plant
    // formula exactly -- this is the HOUR1-004-validated single-species case.
    const solo_high_sun = sharedRadiationInterceptionFraction(.{
        .use_high_sun = true,
        .plant_total_absorbed_megajoules_per_m2 = 0.6,
        .shared_high_sun_total_megajoules_per_m2 = 0.6,
        .plant_area_total_m2 = 0,
        .shared_low_sun_fraction = 0,
        .cell_living_dead_area_total_m2 = 0,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), solo_high_sun, 1.0e-15);

    const solo_low_sun = sharedRadiationInterceptionFraction(.{
        .use_high_sun = false,
        .plant_total_absorbed_megajoules_per_m2 = 0,
        .shared_high_sun_total_megajoules_per_m2 = 0,
        .plant_area_total_m2 = 4.0,
        .shared_low_sun_fraction = 0.42,
        .cell_living_dead_area_total_m2 = 4.0,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.42), solo_low_sun, 1.0e-15);
}

test "runtime canopy retention fills storage and publishes throughfall" {
    const flux = retentionFlux(0.2, 0.3, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), flux, 1.0e-15);
    try std.testing.expectApproxEqAbs(
        @as(f64, -0.1),
        retentionFlux(0, 0.1, 0.2),
        1.0e-15,
    );
}

test "runtime canopy retention state supports arbitrary species count" {
    var state = try State.init(std.testing.allocator, 2, 7);
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 14), state.living_surface_water_m3.len);
    try std.testing.expectEqual(@as(usize, 2), state.cell_throughfall_m3_per_h.len);
    for (state.previous_water_energy_megajoules) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
}

test "retention state_update rejects a late invalid value atomically" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    state.living_surface_water_m3[0] = 0.2;
    state.living_surface_water_m3[1] = 0.3;
    state.living_retention_m3_per_h[0] = 0.1;
    state.living_retention_m3_per_h[1] = -1;

    try std.testing.expectError(
        error.InvalidCanopyRetentionStateUpdate,
        state_updateRetention(&state, 1),
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 0.2, 0.3 },
        state.living_surface_water_m3,
    );
}

test "retention state_update rejects sub-legacy-tolerance water loss without clipping" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    state.living_surface_water_m3[0] = 0;
    state.living_surface_water_m3[1] = 0.3;
    state.living_retention_m3_per_h[0] = -5.0e-15;

    try std.testing.expectError(error.InvalidCanopyRetentionStateUpdate, state_updateRetention(&state, 1));
    try std.testing.expectEqualSlices(f64, &.{ 0, 0.3 }, state.living_surface_water_m3);

    state.living_retention_m3_per_h[0] = 0;
    try std.testing.expectError(
        error.InvalidCanopySurfaceWaterStateUpdate,
        state_updateSurfaceWater(&state, &.{ -5.0e-15, 0 }, &.{ 0, 0 }, 1),
    );
    try std.testing.expectEqualSlices(f64, &.{ 0, 0.3 }, state.living_surface_water_m3);
}

test "surface-water state_update rejects non-finite late input atomically" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    state.living_surface_water_m3[0] = 0.2;
    state.living_surface_water_m3[1] = 0.3;

    try std.testing.expectError(
        error.InvalidCanopySurfaceWaterStateUpdate,
        state_updateSurfaceWater(
            &state,
            &.{ 0.1, std.math.nan(f64) },
            &.{ 0, 0 },
            1,
        ),
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 0.2, 0.3 },
        state.living_surface_water_m3,
    );
}

test "production retention flux matches HOUR1 source-order kernel" {
    const precipitation_m3_per_h = 0.8;
    const capacity_m3_per_m2 = 0.1;
    const live_area_m2 = 3.0;
    const dead_area_m2 = 1.0;
    const live_water_m3 = 0.1;
    const dead_water_m3 = 0.2;
    const live_fraction = 0.2;
    const dead_fraction = 0.1;
    var source_live: [1]f64 = undefined;
    var source_dead: [1]f64 = undefined;
    const totals = try source_order.compute(.{
        .precipitation_irrigation_m3_h = precipitation_m3_per_h,
        .retention_capacity_m3_per_m2_by_vegetation_type = &.{capacity_m3_per_m2},
        .vegetation_type_by_species = &.{0},
        .leaf_area_m2 = &.{2},
        .stalk_area_m2 = &.{1},
        .standing_dead_area_m2 = &.{dead_area_m2},
        .live_water_content_m3 = &.{live_water_m3},
        .standing_dead_water_content_m3 = &.{dead_water_m3},
        .live_radiation_fraction = &.{live_fraction},
        .standing_dead_radiation_fraction = &.{dead_fraction},
    }, .{
        .live_retention_flux_m3_h = &source_live,
        .standing_dead_retention_flux_m3_h = &source_dead,
    });

    const production_live = retentionFlux(
        precipitation_m3_per_h * live_fraction,
        capacity_m3_per_m2 * live_area_m2,
        live_water_m3,
    );
    const production_dead = retentionFlux(
        precipitation_m3_per_h * dead_fraction,
        capacity_m3_per_m2 * dead_area_m2,
        dead_water_m3,
    );
    // Both source-order and production paths now use separate leaf and stalk
    // areas before aggregation.
    try std.testing.expectApproxEqAbs(source_live[0], production_live, 1.0e-15);
    try std.testing.expectApproxEqAbs(source_dead[0], production_dead, 1.0e-15);
    try std.testing.expectApproxEqAbs(
        totals.retention_flux_m3_h,
        production_live + production_dead,
        1.0e-15,
    );
}
