const std = @import("std");

const liquid_water_heat_capacity_megajoules_per_m3_k: f64 = 4.19;

/// Exact current-hour canopy/surface-water activity, retained in direction-
/// separated form before any cell sum can cancel simultaneous transfers.
/// `residual_heat_*` is EXTRACT `THFLXC`: the accepted intercepted-water
/// energy change after removing signed `FLWC+FLWD` atmospheric enthalpy.
pub const CellActivity = struct {
    atmospheric_water_input_m3: f64 = 0,
    atmospheric_water_output_m3: f64 = 0,
    drainage_water_to_lower_boundary_m3: f64 = 0,
    retained_precipitation_heat_input_megajoules: f64 = 0,
    drainage_heat_to_lower_boundary_megajoules: f64 = 0,
    residual_heat_input_megajoules: f64 = 0,
    residual_heat_output_megajoules: f64 = 0,

    pub fn validate(self: CellActivity) !void {
        inline for (std.meta.fields(CellActivity)) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidCanopyConservationActivity;
        }
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    activity_by_cell: []CellActivity,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0)
            return error.InvalidCanopyConservationDimensions;
        const activity = try allocator.alloc(CellActivity, cell_count);
        @memset(activity, .{});
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .activity_by_cell = activity,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.activity_by_cell);
        self.* = undefined;
    }

    pub fn reset(self: *State) void {
        @memset(self.activity_by_cell, .{});
    }
};

pub const Inputs = struct {
    air_temperature_k_by_cell: []const f64,
    living_retention_m3_per_h_by_plant: []const f64,
    standing_dead_retention_m3_per_h_by_plant: []const f64,
    transpiration_m3_per_h_by_plant: []const f64,
    living_evaporation_m3_per_h_by_plant: []const f64,
    standing_dead_evaporation_m3_per_h_by_plant: []const f64,
    thflxc_megajoules_per_h_by_plant: []const f64,
    thflxc_megajoules_per_h_by_cell: []const f64,
};

/// Publishes one atomic, allocation-free current-hour sidecar. Source signs
/// match UPTAKE/EXTRACT: positive evaporation/transpiration is condensation
/// into the canopy; negative is atmospheric loss. Positive `FLWC/FLWD` is
/// atmospheric retention; negative is canopy drainage delivered below the
/// canopy. The per-cell `THFLXC` owner is checked against the plant partition
/// before any prior sidecar value is replaced.
pub fn refresh(state: *State, inputs: Inputs) !void {
    const plant_count = try std.math.mul(
        usize,
        state.cell_count,
        state.species_count,
    );
    if (inputs.air_temperature_k_by_cell.len != state.cell_count or
        inputs.thflxc_megajoules_per_h_by_cell.len != state.cell_count)
        return error.InvalidCanopyConservationDimensions;
    inline for (std.meta.fields(Inputs)[1 .. std.meta.fields(Inputs).len - 1]) |field|
        if (@field(inputs, field.name).len != plant_count)
            return error.InvalidCanopyConservationDimensions;

    for (0..state.cell_count) |cell| _ = try candidate(state, inputs, cell);
    for (0..state.cell_count) |cell|
        state.activity_by_cell[cell] = candidate(state, inputs, cell) catch unreachable;
}

fn candidate(state: *const State, inputs: Inputs, cell: usize) !CellActivity {
    const air_temperature_k = inputs.air_temperature_k_by_cell[cell];
    const cell_thflxc = inputs.thflxc_megajoules_per_h_by_cell[cell];
    if (!std.math.isFinite(air_temperature_k) or air_temperature_k <= 0 or
        !std.math.isFinite(cell_thflxc))
        return error.InvalidCanopyConservationInput;

    var result: CellActivity = .{};
    var reconstructed_thflxc: f64 = 0;
    const first = cell * state.species_count;
    for (first..first + state.species_count) |plant| {
        const live_retention = inputs.living_retention_m3_per_h_by_plant[plant];
        const dead_retention = inputs.standing_dead_retention_m3_per_h_by_plant[plant];
        const transpiration = inputs.transpiration_m3_per_h_by_plant[plant];
        const live_evaporation = inputs.living_evaporation_m3_per_h_by_plant[plant];
        const dead_evaporation = inputs.standing_dead_evaporation_m3_per_h_by_plant[plant];
        const thflxc = inputs.thflxc_megajoules_per_h_by_plant[plant];
        inline for (.{
            live_retention,
            dead_retention,
            transpiration,
            live_evaporation,
            dead_evaporation,
            thflxc,
        }) |value| if (!std.math.isFinite(value))
            return error.InvalidCanopyConservationInput;

        inline for (.{ live_retention, dead_retention }) |retention| {
            const enthalpy = @abs(retention) *
                liquid_water_heat_capacity_megajoules_per_m3_k *
                air_temperature_k;
            if (!std.math.isFinite(enthalpy))
                return error.CanopyConservationOverflow;
            if (retention >= 0) {
                result.atmospheric_water_input_m3 = try addFiniteNonnegative(
                    result.atmospheric_water_input_m3,
                    retention,
                );
                result.retained_precipitation_heat_input_megajoules =
                    try addFiniteNonnegative(
                        result.retained_precipitation_heat_input_megajoules,
                        enthalpy,
                    );
            } else {
                result.drainage_water_to_lower_boundary_m3 = try addFiniteNonnegative(
                    result.drainage_water_to_lower_boundary_m3,
                    -retention,
                );
                result.drainage_heat_to_lower_boundary_megajoules =
                    try addFiniteNonnegative(
                        result.drainage_heat_to_lower_boundary_megajoules,
                        enthalpy,
                    );
            }
        }
        inline for (.{ transpiration, live_evaporation, dead_evaporation }) |water| {
            if (water >= 0)
                result.atmospheric_water_input_m3 = try addFiniteNonnegative(
                    result.atmospheric_water_input_m3,
                    water,
                )
            else
                result.atmospheric_water_output_m3 = try addFiniteNonnegative(
                    result.atmospheric_water_output_m3,
                    -water,
                );
        }
        if (thflxc >= 0)
            result.residual_heat_input_megajoules = try addFiniteNonnegative(
                result.residual_heat_input_megajoules,
                thflxc,
            )
        else
            result.residual_heat_output_megajoules = try addFiniteNonnegative(
                result.residual_heat_output_megajoules,
                -thflxc,
            );
        reconstructed_thflxc = try addFinite(reconstructed_thflxc, thflxc);
    }

    const parity_scale = @max(1, @max(@abs(reconstructed_thflxc), @abs(cell_thflxc)));
    if (@abs(reconstructed_thflxc - cell_thflxc) >
        64 * std.math.floatEps(f64) * parity_scale)
        return error.CanopyConservationCellPartitionMismatch;
    try result.validate();
    return result;
}

fn addFinite(left: f64, right: f64) !f64 {
    const result = left + right;
    if (!std.math.isFinite(result)) return error.CanopyConservationOverflow;
    return result;
}

fn addFiniteNonnegative(left: f64, right: f64) !f64 {
    if (!std.math.isFinite(right) or right < 0)
        return error.InvalidCanopyConservationActivity;
    return addFinite(left, right);
}

test "sidecar preserves simultaneous retention drainage and vapor directions" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try refresh(&state, .{
        .air_temperature_k_by_cell = &.{280},
        .living_retention_m3_per_h_by_plant = &.{ 2, -0.5 },
        .standing_dead_retention_m3_per_h_by_plant = &.{ -0.25, 1 },
        .transpiration_m3_per_h_by_plant = &.{ -3, 0.5 },
        .living_evaporation_m3_per_h_by_plant = &.{ 4, -1 },
        .standing_dead_evaporation_m3_per_h_by_plant = &.{ -2, 0.25 },
        .thflxc_megajoules_per_h_by_plant = &.{ 10, -4 },
        .thflxc_megajoules_per_h_by_cell = &.{6},
    });
    const activity = state.activity_by_cell[0];
    try std.testing.expectEqual(@as(f64, 7.75), activity.atmospheric_water_input_m3);
    try std.testing.expectEqual(@as(f64, 6), activity.atmospheric_water_output_m3);
    try std.testing.expectEqual(@as(f64, 0.75), activity.drainage_water_to_lower_boundary_m3);
    try std.testing.expectEqual(@as(f64, 10), activity.residual_heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 4), activity.residual_heat_output_megajoules);
    try std.testing.expectApproxEqAbs(
        3 * 4.19 * 280,
        activity.retained_precipitation_heat_input_megajoules,
        32 * std.math.floatEps(f64) * 3 * 4.19 * 280,
    );
    try std.testing.expectApproxEqAbs(
        0.75 * 4.19 * 280,
        activity.drainage_heat_to_lower_boundary_megajoules,
        32 * std.math.floatEps(f64) * 0.75 * 4.19 * 280,
    );
}

test "late partition mismatch leaves prior sidecar unchanged" {
    var state = try State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    state.activity_by_cell[0].atmospheric_water_input_m3 = 7;
    state.activity_by_cell[1].residual_heat_output_megajoules = 8;
    try std.testing.expectError(
        error.CanopyConservationCellPartitionMismatch,
        refresh(&state, .{
            .air_temperature_k_by_cell = &.{ 280, 281 },
            .living_retention_m3_per_h_by_plant = &.{ 0, 0 },
            .standing_dead_retention_m3_per_h_by_plant = &.{ 0, 0 },
            .transpiration_m3_per_h_by_plant = &.{ 0, 0 },
            .living_evaporation_m3_per_h_by_plant = &.{ 0, 0 },
            .standing_dead_evaporation_m3_per_h_by_plant = &.{ 0, 0 },
            .thflxc_megajoules_per_h_by_plant = &.{ 1, 2 },
            .thflxc_megajoules_per_h_by_cell = &.{ 1, 3 },
        }),
    );
    try std.testing.expectEqual(@as(f64, 7), state.activity_by_cell[0].atmospheric_water_input_m3);
    try std.testing.expectEqual(@as(f64, 8), state.activity_by_cell[1].residual_heat_output_megajoules);
}

test "late nonfinite producer leaves prior sidecar unchanged" {
    var state = try State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    state.activity_by_cell[0].atmospheric_water_output_m3 = 3;
    state.activity_by_cell[1].residual_heat_input_megajoules = 4;
    try std.testing.expectError(
        error.InvalidCanopyConservationInput,
        refresh(&state, .{
            .air_temperature_k_by_cell = &.{ 280, 281 },
            .living_retention_m3_per_h_by_plant = &.{ 0, 0 },
            .standing_dead_retention_m3_per_h_by_plant = &.{ 0, 0 },
            .transpiration_m3_per_h_by_plant = &.{ 0, 0 },
            .living_evaporation_m3_per_h_by_plant = &.{ 0, std.math.nan(f64) },
            .standing_dead_evaporation_m3_per_h_by_plant = &.{ 0, 0 },
            .thflxc_megajoules_per_h_by_plant = &.{ 0, 0 },
            .thflxc_megajoules_per_h_by_cell = &.{ 0, 0 },
        }),
    );
    try std.testing.expectEqual(@as(f64, 3), state.activity_by_cell[0].atmospheric_water_output_m3);
    try std.testing.expectEqual(@as(f64, 4), state.activity_by_cell[1].residual_heat_input_megajoules);
}

test "production publishes canopy sidecar after accepted uptake transaction" {
    const production = @embedFile("../../ecosys_ng.zig");
    const allocation_marker = "try ecosys.canopy_conservation_sidecar.State.init(";
    const ownership_marker = "resources.ownDeinit(&owners.canopy_conservation_sidecar_state);";
    const owner_declaration_marker = "var plant_state_update_owners: PlantStateUpdateOwners = undefined;";
    const initialization_call_marker = "try initializePlantStateUpdateOwners(";
    const binding_marker =
        ".canopy_conservation_sidecar_state = &plant_state_update_owners.canopy_conservation_sidecar_state,";
    const refresh_marker = "try ecosys.canopy_conservation_sidecar.refresh(";
    const timeline_marker = "try runTimeline(&timeline_context,";
    const allocation = std.mem.indexOf(
        u8,
        production,
        allocation_marker,
    ) orelse return error.MissingCanopyConservationSidecarState;
    const ownership = std.mem.indexOfPos(
        u8,
        production,
        allocation,
        ownership_marker,
    ) orelse return error.MissingCanopyConservationSidecarOwnership;
    const owner_declaration = std.mem.indexOfPos(
        u8,
        production,
        ownership,
        owner_declaration_marker,
    ) orelse return error.MissingCanopyConservationSidecarOwnerDeclaration;
    const initialization_call = std.mem.indexOfPos(
        u8,
        production,
        owner_declaration,
        initialization_call_marker,
    ) orelse return error.MissingCanopyConservationSidecarInitializationCall;
    const transaction = std.mem.indexOf(
        u8,
        production,
        "try ecosys.uptake_coupled_transaction.apply(",
    ) orelse return error.MissingUptakeTransaction;
    const publish = std.mem.indexOfPos(
        u8,
        production,
        transaction,
        refresh_marker,
    ) orelse return error.MissingCanopyConservationSidecarPublication;
    const plant_partition = std.mem.indexOfPos(
        u8,
        production,
        publish,
        ".thflxc_megajoules_per_h_by_plant =",
    ) orelse return error.MissingCanopyConservationPlantPartition;
    const cell_owner = std.mem.indexOfPos(
        u8,
        production,
        plant_partition,
        ".thflxc_megajoules_per_h_by_cell =",
    ) orelse return error.MissingCanopyConservationCellOwner;
    const context_binding = std.mem.indexOf(
        u8,
        production,
        binding_marker,
    ) orelse return error.MissingCanopyConservationSidecarContextBinding;
    const timeline_call = std.mem.indexOf(
        u8,
        production,
        timeline_marker,
    ) orelse return error.MissingTimelineCall;
    // The helper registers cleanup against the named owner's final stack
    // address. Main initializes that owner before binding the same field into
    // the driver context and crossing the noinline timeline boundary.
    try std.testing.expect(
        allocation < ownership and
            ownership < owner_declaration and
            owner_declaration < initialization_call and
            initialization_call < context_binding and
            context_binding < timeline_call,
    );
    try std.testing.expect(transaction < publish and publish < plant_partition and plant_partition < cell_owner);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production, allocation_marker));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production, ownership_marker));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production, owner_declaration_marker));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production, initialization_call_marker));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production, binding_marker));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production, refresh_marker));
    // Journaled and unjournaled branches share the same initialized owner.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, production, timeline_marker));
}
