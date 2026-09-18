// **A8a DISPOSITION: superseded; this is the netting accumulator that production
// deliberately does not have.** `redist.f:2415--2435` and `:2587--2595` are the
// two arms of the `N.EQ.3` vertical face loop over snow layers. Both add the
// layer's own inflow `XFLWS/XFLWW/XFLWV/XFLWI/XHFLWW` into the `TFLW*`/`THFLWW`
// staging accumulators; the first arm, taken when `LS.LT.JS` and the next layer is
// above the minimum heat capacity (`:2422`), additionally subtracts that next
// layer's inflow `X*(LS2)`, so the accumulator holds a *divergence*; the `ELSE` at
// `:2587` is the bottom-of-pack case, where there is no lower snow layer to
// subtract and only the ground transfers `FLSWR/FLSW/FLSWH` (liquid to residue,
// soil matrix, macropore), `FLSVR/FLSV` (vapor) and `HFLSWR/HFLSW` (heat) leave.
// Note that both arms subtract the ground transfers; what the `LS2` test selects
// is only whether the lower-snow-face term is present. The module reproduces that
// faithfully, including the `null` lower transfer standing in for the `ELSE`.
//
// Production has no `TFLW*` array to net into. Each of the three quantities this
// module combines is state_updateted at its own site, in its own units, by its own
// owner:
//
//   - the inter-layer face flux is `snow_melt_water_routing.calculate:45--53`
//     (`stages/hourly_science_driver.zig:192`), which computes the downward
//     liquid for each face and clamps it to the receiving layer's air-filled
//     volume, then `snow_solute_transport.state_updateMeltWater:155--160` applies it as
//     a paired debit and credit `candidate[dst-1] -= flux; candidate[dst] += flux`.
//     That pairing *is* the `X(LS) - X(LS+1)` divergence, expressed once per face
//     rather than accumulated per layer, which is why production cannot lose or
//     double-count the shared face term.
//   - the ground transfers are the bottom-layer split in the same routing module
//     at `:56--67`, into `snow_to_litter_water_flux_m3_per_step` (legacy `FLSWR`)
//     and the micropore and macropore fluxes (`FLSW`, `FLSWH`), debited from the
//     lowest active layer at `state_updateMeltWater:162--167` and credited to the
//     surface at `hourly_science_snow_energy.zig:130--133`.
//   - the convective heat `XHFLWW`/`HFLSWR`/`HFLSW` is not staged at all.
//     Production carries temperature and heat capacity per layer and lets
//     `snow_heat_conduction`, `snow_phase_change` and `snow_vapor_equilibrium`
//     each republish `temperature_k` and `heat_capacity_megajoules_per_k`
//     atomically, so there is no separate heat-flux ledger to accumulate into.
//
// This is the same supersession shape as `snowpack_phase_inventory_update`, one
// step upstream: that module applies the staged increments, this one builds them.
// Both are unbindable for the same structural reason, and binding either would
// require manufacturing the staging arrays production removed.
//
// One caution recorded rather than filed. The active-layer test here is legacy
// `VHCPW > VHCPWX`, and `VHCPWX` has no production writer: the exact translation
// at `soil/heat/lower_soil_heat_boundary_initialization.zig:151--168` is
// unreachable, and `snow_melt_water_routing` instead tests the boolean `active`
// flag while `snow_relayering` is handed the legacy universal solver scalar. So
// production's substitute for this gate is a flag plus a volume tolerance rather
// than a heat-capacity floor. That is the pre-existing question in the cited note
// and is not made worse by leaving this module unbound.
//
// snowpack face aggregation group of docs/traceability/a1b_snowpack_minimum_heat_capacity_unbound.md

const std = @import("std");

/// Water-equivalent volumes and convective heat crossing a snow-layer face.
/// Every field is signed and integrated over one model step.
pub const LayerFlux = struct {
    solid_snow_m3_per_step: f64 = 0,
    liquid_water_m3_per_step: f64 = 0,
    water_vapor_m3_per_step: f64 = 0,
    ice_m3_per_step: f64 = 0,
    convective_heat_megajoules_per_step: f64 = 0,
};

/// Transfers from a snow layer to the residue and soil surface. These are
/// subtracted from that layer's net balance in their source order.
pub const GroundTransfer = struct {
    liquid_to_residue_m3_per_step: f64 = 0,
    liquid_to_soil_matrix_m3_per_step: f64 = 0,
    liquid_to_soil_macropore_m3_per_step: f64 = 0,
    vapor_to_residue_m3_per_step: f64 = 0,
    vapor_to_soil_m3_per_step: f64 = 0,
    heat_to_residue_megajoules_per_step: f64 = 0,
    heat_to_soil_megajoules_per_step: f64 = 0,
};

pub const Inputs = struct {
    /// Current snow heat capacity [snow_layer], MJ K^-1.
    heat_capacity_megajoules_per_k_by_layer: []const f64,
    /// The source presence threshold, MJ K^-1.
    minimum_heat_capacity_megajoules_per_k: f64,
    /// `XFLW*(LS)` at each layer's upper face [snow_layer].
    upper_face_transfer_by_layer: []const LayerFlux,
    /// `FLS*` and `HFLS*` losses [snow_layer].
    ground_transfer_by_layer: []const GroundTransfer,
};

pub const State = struct {
    /// Accumulated `TFLW*` and `THFLWW` [snow_layer].
    net_flux_by_layer: []LayerFlux,
};

/// Caller-owned runtime scratch provides atomic state state_update without allocating
/// in the per-cell snow transport kernel.
pub const Workspace = struct {
    net_flux_by_layer: []LayerFlux,
};

/// Aggregates vertical water and heat divergence for one snow column.
///
/// Traceability: REDIST.F lines 2415--2435 and 2587--2595. For each active
/// source layer, an active lower snow layer gives `X(LS) - X(LS+1)`;
/// otherwise the current layer is the lower snow/ground interface and the
/// residue, soil-matrix, soil-macropore, vapor, and heat transfers are
/// subtracted. Runtime slice lengths replace the source `JS` extent. Candidate
/// values are state_updateted only after all layers remain finite.
pub fn aggregate(inputs: Inputs, state: *State, workspace: Workspace) !void {
    try validateDimensions(inputs, state.*, workspace);
    try validateInputs(inputs, state.*, workspace);
    @memcpy(workspace.net_flux_by_layer, state.net_flux_by_layer);

    for (
        inputs.heat_capacity_megajoules_per_k_by_layer,
        inputs.upper_face_transfer_by_layer,
        inputs.ground_transfer_by_layer,
        0..,
    ) |heat_capacity, upper_transfer, ground_transfer, layer| {
        if (heat_capacity <= inputs.minimum_heat_capacity_megajoules_per_k) continue;

        const lower_transfer: ?LayerFlux =
            if (layer + 1 < inputs.heat_capacity_megajoules_per_k_by_layer.len and
            inputs.heat_capacity_megajoules_per_k_by_layer[layer + 1] >
                inputs.minimum_heat_capacity_megajoules_per_k)
                inputs.upper_face_transfer_by_layer[layer + 1]
            else
                null;
        try updateLayer(
            &workspace.net_flux_by_layer[layer],
            upper_transfer,
            lower_transfer,
            ground_transfer,
        );
    }

    @memcpy(state.net_flux_by_layer, workspace.net_flux_by_layer);
}

fn validateDimensions(inputs: Inputs, state: State, workspace: Workspace) !void {
    const layer_count = inputs.heat_capacity_megajoules_per_k_by_layer.len;
    if (layer_count == 0) return error.InvalidSnowpackAggregationDimensions;
    if (inputs.upper_face_transfer_by_layer.len != layer_count or
        inputs.ground_transfer_by_layer.len != layer_count or
        state.net_flux_by_layer.len != layer_count or
        workspace.net_flux_by_layer.len != layer_count)
    {
        return error.SnowpackAggregationDimensionMismatch;
    }
}

fn validateInputs(inputs: Inputs, state: State, workspace: Workspace) !void {
    if (!std.math.isFinite(inputs.minimum_heat_capacity_megajoules_per_k))
        return error.NonFiniteSnowpackAggregationInput;
    if (inputs.minimum_heat_capacity_megajoules_per_k < 0)
        return error.InvalidSnowpackHeatCapacity;

    for (inputs.heat_capacity_megajoules_per_k_by_layer) |capacity| {
        if (!std.math.isFinite(capacity))
            return error.NonFiniteSnowpackAggregationInput;
        if (capacity < 0) return error.InvalidSnowpackHeatCapacity;
    }
    try validateFiniteSlice(inputs.upper_face_transfer_by_layer);
    try validateFiniteSlice(inputs.ground_transfer_by_layer);
    try validateFiniteSlice(state.net_flux_by_layer);

    if (overlap(workspace.net_flux_by_layer, state.net_flux_by_layer) or
        overlap(workspace.net_flux_by_layer, inputs.upper_face_transfer_by_layer))
    {
        return error.SnowpackAggregationWorkspaceOverlap;
    }
}

fn validateFiniteSlice(values: anytype) !void {
    for (values) |value| {
        inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field|
            if (!std.math.isFinite(@field(value, field.name)))
                return error.NonFiniteSnowpackAggregationInput;
    }
}

fn updateLayer(
    candidate: *LayerFlux,
    upper: LayerFlux,
    lower: ?LayerFlux,
    ground: GroundTransfer,
) !void {
    candidate.solid_snow_m3_per_step = try add(
        candidate.solid_snow_m3_per_step,
        upper.solid_snow_m3_per_step,
    );
    if (lower) |flux| {
        candidate.solid_snow_m3_per_step = try subtract(
            candidate.solid_snow_m3_per_step,
            flux.solid_snow_m3_per_step,
        );
    }

    candidate.liquid_water_m3_per_step = try add(
        candidate.liquid_water_m3_per_step,
        upper.liquid_water_m3_per_step,
    );
    if (lower) |flux| {
        candidate.liquid_water_m3_per_step = try subtract(
            candidate.liquid_water_m3_per_step,
            flux.liquid_water_m3_per_step,
        );
    }
    candidate.liquid_water_m3_per_step = try subtract(
        candidate.liquid_water_m3_per_step,
        ground.liquid_to_residue_m3_per_step,
    );
    candidate.liquid_water_m3_per_step = try subtract(
        candidate.liquid_water_m3_per_step,
        ground.liquid_to_soil_matrix_m3_per_step,
    );
    candidate.liquid_water_m3_per_step = try subtract(
        candidate.liquid_water_m3_per_step,
        ground.liquid_to_soil_macropore_m3_per_step,
    );

    candidate.water_vapor_m3_per_step = try add(
        candidate.water_vapor_m3_per_step,
        upper.water_vapor_m3_per_step,
    );
    if (lower) |flux| {
        candidate.water_vapor_m3_per_step = try subtract(
            candidate.water_vapor_m3_per_step,
            flux.water_vapor_m3_per_step,
        );
    }
    candidate.water_vapor_m3_per_step = try subtract(
        candidate.water_vapor_m3_per_step,
        ground.vapor_to_residue_m3_per_step,
    );
    candidate.water_vapor_m3_per_step = try subtract(
        candidate.water_vapor_m3_per_step,
        ground.vapor_to_soil_m3_per_step,
    );

    candidate.ice_m3_per_step = try add(
        candidate.ice_m3_per_step,
        upper.ice_m3_per_step,
    );
    if (lower) |flux| {
        candidate.ice_m3_per_step = try subtract(
            candidate.ice_m3_per_step,
            flux.ice_m3_per_step,
        );
    }

    candidate.convective_heat_megajoules_per_step = try add(
        candidate.convective_heat_megajoules_per_step,
        upper.convective_heat_megajoules_per_step,
    );
    if (lower) |flux| {
        candidate.convective_heat_megajoules_per_step = try subtract(
            candidate.convective_heat_megajoules_per_step,
            flux.convective_heat_megajoules_per_step,
        );
    }
    candidate.convective_heat_megajoules_per_step = try subtract(
        candidate.convective_heat_megajoules_per_step,
        ground.heat_to_residue_megajoules_per_step,
    );
    candidate.convective_heat_megajoules_per_step = try subtract(
        candidate.convective_heat_megajoules_per_step,
        ground.heat_to_soil_megajoules_per_step,
    );
}

fn add(current: f64, contribution: f64) !f64 {
    const result = current + contribution;
    if (!std.math.isFinite(result))
        return error.NonFiniteSnowpackAggregationResult;
    return result;
}

fn subtract(current: f64, contribution: f64) !f64 {
    const result = current - contribution;
    if (!std.math.isFinite(result))
        return error.NonFiniteSnowpackAggregationResult;
    return result;
}

fn overlap(left: []const LayerFlux, right: []const LayerFlux) bool {
    if (left.len == 0 or right.len == 0) return false;
    const item_size = @sizeOf(LayerFlux);
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_bytes = std.math.mul(usize, left.len, item_size) catch return true;
    const right_bytes = std.math.mul(usize, right.len, item_size) catch return true;
    const left_end = std.math.add(usize, left_start, left_bytes) catch return true;
    const right_end = std.math.add(usize, right_start, right_bytes) catch return true;
    return left_start < right_end and right_start < left_end;
}

fn filledFlux(value: f64) LayerFlux {
    return .{
        .solid_snow_m3_per_step = value,
        .liquid_water_m3_per_step = value,
        .water_vapor_m3_per_step = value,
        .ice_m3_per_step = value,
        .convective_heat_megajoules_per_step = value,
    };
}

fn expectFlux(actual: LayerFlux, expected: f64) !void {
    inline for (@typeInfo(LayerFlux).@"struct".fields) |field|
        try std.testing.expectEqual(expected, @field(actual, field.name));
}

test "active snow layers retain source divergence and update order" {
    const capacities = [_]f64{ 2, 2, 2 };
    const transfers = [_]LayerFlux{
        filledFlux(10),
        filledFlux(6),
        filledFlux(2),
    };
    const ground = [_]GroundTransfer{.{}} ** 3;
    var totals = [_]LayerFlux{.{}} ** 3;
    var scratch: [3]LayerFlux = undefined;
    var state = State{ .net_flux_by_layer = &totals };

    try aggregate(.{
        .heat_capacity_megajoules_per_k_by_layer = &capacities,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .upper_face_transfer_by_layer = &transfers,
        .ground_transfer_by_layer = &ground,
    }, &state, .{ .net_flux_by_layer = &scratch });

    try expectFlux(state.net_flux_by_layer[0], 4);
    try expectFlux(state.net_flux_by_layer[1], 4);
    try expectFlux(state.net_flux_by_layer[2], 2);
}

test "column water and heat balances close exactly at ground interfaces" {
    const capacities = [_]f64{ 2, 2, 2 };
    const transfers = [_]LayerFlux{
        filledFlux(10),
        filledFlux(6),
        filledFlux(2),
    };
    const ground = [_]GroundTransfer{
        .{},
        .{},
        .{
            .liquid_to_residue_m3_per_step = 1,
            .liquid_to_soil_matrix_m3_per_step = 2,
            .liquid_to_soil_macropore_m3_per_step = 3,
            .vapor_to_residue_m3_per_step = 1,
            .vapor_to_soil_m3_per_step = 2,
            .heat_to_residue_megajoules_per_step = 1,
            .heat_to_soil_megajoules_per_step = 2,
        },
    };
    var totals = [_]LayerFlux{.{}} ** 3;
    var scratch: [3]LayerFlux = undefined;
    var state = State{ .net_flux_by_layer = &totals };

    try aggregate(.{
        .heat_capacity_megajoules_per_k_by_layer = &capacities,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .upper_face_transfer_by_layer = &transfers,
        .ground_transfer_by_layer = &ground,
    }, &state, .{ .net_flux_by_layer = &scratch });

    var column = LayerFlux{};
    for (state.net_flux_by_layer) |layer| {
        inline for (@typeInfo(LayerFlux).@"struct".fields) |field|
            @field(column, field.name) += @field(layer, field.name);
    }
    try std.testing.expectEqual(@as(f64, 10), column.solid_snow_m3_per_step);
    try std.testing.expectEqual(@as(f64, 4), column.liquid_water_m3_per_step);
    try std.testing.expectEqual(@as(f64, 7), column.water_vapor_m3_per_step);
    try std.testing.expectEqual(@as(f64, 10), column.ice_m3_per_step);
    try std.testing.expectEqual(@as(f64, 7), column.convective_heat_megajoules_per_step);
}

test "inactive layers and gaps preserve REDIST capacity gates" {
    const capacities = [_]f64{ 2, 0, 2 };
    const transfers = [_]LayerFlux{
        filledFlux(10),
        filledFlux(6),
        filledFlux(2),
    };
    const ground = [_]GroundTransfer{.{}} ** 3;
    var totals = [_]LayerFlux{ filledFlux(100), filledFlux(100), filledFlux(100) };
    var scratch: [3]LayerFlux = undefined;
    var state = State{ .net_flux_by_layer = &totals };

    try aggregate(.{
        .heat_capacity_megajoules_per_k_by_layer = &capacities,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .upper_face_transfer_by_layer = &transfers,
        .ground_transfer_by_layer = &ground,
    }, &state, .{ .net_flux_by_layer = &scratch });

    try expectFlux(state.net_flux_by_layer[0], 110);
    try expectFlux(state.net_flux_by_layer[1], 100);
    try expectFlux(state.net_flux_by_layer[2], 102);
}

test "runtime snow layer extent is not a compile-time model parameter" {
    const capacities = [_]f64{2} ** 7;
    const transfers = [_]LayerFlux{filledFlux(1)} ** 7;
    const ground = [_]GroundTransfer{.{}} ** 7;
    var totals = [_]LayerFlux{.{}} ** 7;
    var scratch: [7]LayerFlux = undefined;
    var state = State{ .net_flux_by_layer = &totals };

    try aggregate(.{
        .heat_capacity_megajoules_per_k_by_layer = &capacities,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .upper_face_transfer_by_layer = &transfers,
        .ground_transfer_by_layer = &ground,
    }, &state, .{ .net_flux_by_layer = &scratch });

    for (state.net_flux_by_layer[0..6]) |layer| try expectFlux(layer, 0);
    try expectFlux(state.net_flux_by_layer[6], 1);
}

test "source arithmetic association is retained" {
    const capacities = [_]f64{ 2, 2 };
    const transfers = [_]LayerFlux{ filledFlux(-1.0e16), filledFlux(1) };
    const ground = [_]GroundTransfer{.{}} ** 2;
    var totals = [_]LayerFlux{ filledFlux(1.0e16), .{} };
    var scratch: [2]LayerFlux = undefined;
    var state = State{ .net_flux_by_layer = &totals };

    try aggregate(.{
        .heat_capacity_megajoules_per_k_by_layer = &capacities,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .upper_face_transfer_by_layer = &transfers,
        .ground_transfer_by_layer = &ground,
    }, &state, .{ .net_flux_by_layer = &scratch });

    try expectFlux(state.net_flux_by_layer[0], -1);
}

test "nonfinite input and overflow preserve state atomically" {
    const capacities = [_]f64{ 2, 2 };
    var transfers = [_]LayerFlux{ filledFlux(1), filledFlux(1) };
    transfers[1].convective_heat_megajoules_per_step = std.math.nan(f64);
    const ground = [_]GroundTransfer{.{}} ** 2;
    var totals = [_]LayerFlux{filledFlux(3)} ** 2;
    var scratch: [2]LayerFlux = undefined;
    var state = State{ .net_flux_by_layer = &totals };
    const workspace = Workspace{ .net_flux_by_layer = &scratch };

    try std.testing.expectError(
        error.NonFiniteSnowpackAggregationInput,
        aggregate(.{
            .heat_capacity_megajoules_per_k_by_layer = &capacities,
            .minimum_heat_capacity_megajoules_per_k = 1,
            .upper_face_transfer_by_layer = &transfers,
            .ground_transfer_by_layer = &ground,
        }, &state, workspace),
    );
    for (state.net_flux_by_layer) |layer| try expectFlux(layer, 3);

    transfers[1] = filledFlux(0);
    transfers[0] = filledFlux(std.math.floatMax(f64));
    totals[0] = filledFlux(std.math.floatMax(f64));
    try std.testing.expectError(
        error.NonFiniteSnowpackAggregationResult,
        aggregate(.{
            .heat_capacity_megajoules_per_k_by_layer = &capacities,
            .minimum_heat_capacity_megajoules_per_k = 1,
            .upper_face_transfer_by_layer = &transfers,
            .ground_transfer_by_layer = &ground,
        }, &state, workspace),
    );
    try expectFlux(state.net_flux_by_layer[0], std.math.floatMax(f64));
    try expectFlux(state.net_flux_by_layer[1], 3);
}

test "dimension and workspace alias failures precede mutation" {
    const capacities = [_]f64{ 2, 2 };
    const transfers = [_]LayerFlux{ filledFlux(1), filledFlux(1) };
    const ground = [_]GroundTransfer{.{}} ** 2;
    var totals = [_]LayerFlux{filledFlux(5)} ** 2;
    var state = State{ .net_flux_by_layer = &totals };

    try std.testing.expectError(
        error.SnowpackAggregationWorkspaceOverlap,
        aggregate(.{
            .heat_capacity_megajoules_per_k_by_layer = &capacities,
            .minimum_heat_capacity_megajoules_per_k = 1,
            .upper_face_transfer_by_layer = &transfers,
            .ground_transfer_by_layer = &ground,
        }, &state, .{ .net_flux_by_layer = &totals }),
    );
    for (state.net_flux_by_layer) |layer| try expectFlux(layer, 5);

    var short_scratch: [1]LayerFlux = undefined;
    try std.testing.expectError(
        error.SnowpackAggregationDimensionMismatch,
        aggregate(.{
            .heat_capacity_megajoules_per_k_by_layer = &capacities,
            .minimum_heat_capacity_megajoules_per_k = 1,
            .upper_face_transfer_by_layer = &transfers,
            .ground_transfer_by_layer = &ground,
        }, &state, .{ .net_flux_by_layer = &short_scratch }),
    );
    for (state.net_flux_by_layer) |layer| try expectFlux(layer, 5);
}
