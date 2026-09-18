// **A8a DISPOSITION: superseded, by distribution rather than by a single
// owner.** `redist.f:4046--4133` is one Fortran block because F77 has nowhere
// else to put it; production splits it across four owners chosen by lifetime
// and by consumer, so there is no single file to point at and no residual.
//
// Geometry (`redist.f:4048--4052`, `:4117--4123`) is owned by
// `soil/solute/snow_solute_transport.zig:173--186 refreshCellGeometry`. It
// recomputes `total_layer_volume_m3` as `solid/density + liquid + ice`,
// `layer_thickness_m` as `total/horizontal_area_m2`, and the running
// `cumulative_depth_m`, which is the same three formulas in the same order.
// The `ELSE` arm at `:4117--4123` needs no counterpart: a layer whose
// inventory has drained to zero gets `total = 0`, `thickness = 0`, and a
// `cumulative_depth_m` that therefore equals the layer above it, which is
// exactly `CDPTHS(L)=CDPTHS(L-1)`. The reset is an identity of the refresh, not
// a separate branch, so it cannot fall out of step with the active arm.
// `refreshCellGeometry` runs after every mass-moving snow step
// (`snow_compaction.zig:75`, `snow_phase_change.zig:219`,
// `snow_relayering.zig:89` and `:101`, `snow_vapor_equilibrium.zig:170` and
// `:181`), so geometry is republished at each of the points `redist.f` reaches
// this block, not once per candidate call.
//
// The heat-capacity formula (`redist.f:4072--4074`) has five production sites,
// all carrying the same `2.095 / 4.19 / 1.9274` coefficients on solid, liquid
// plus vapor, and ice: `snow_relayering.zig:66--67`,
// `snow_vapor_equilibrium.zig:58`, `snow_solute_transport.zig:125` and `:135`,
// and the initialization at `:109`. Each recomputes it at the moment it has
// just changed an inventory, which is why binding a separate publisher would
// be a second writer of a quantity that is already correct on entry.
//
// The column totals (`redist.f:4089--4093`) are not stored. `DPTHS` is read
// off the geometry cursor at `stages/hourly_science_snow_energy.zig:125` and
// `stages/hourly_science_driver.zig:61` as the deepest layer's
// `cumulative_depth_m`, which is the same sum by construction; `VOLSS` is
// summed in place at `hourly_science_snow_energy.zig:126--128` for the one
// consumer that wants it; and `VOLWS`/`VOLIS`/`VOLS` are reduced on demand by
// `validation/landscape_mass_inventory_snow.zig:42--62`. This is the
// accumulate-at-consumption shape: a stored total is a second copy that can go
// stale against its summands across the six refresh sites above, and the
// snowpack is precisely where that staleness would be invisible, because every
// term is near zero for most of the year.
//
// The Celsius field (`redist.f:4133 TCW`) is likewise reconstructed at use,
// `state.temperature_k[index] - 273.15` at `snow_compaction.zig:61` and the
// clamped snowfall form at `:54`. `snow.State` deliberately carries no
// `temperature_c`, so the two representations cannot disagree.
//
// The temperature update itself (`redist.f:4077--4087`) is the one part this
// module already declines, and its own header states why: the heat, vapor, and
// Dall'Amico phase solvers have state_updateted `temperature_k` before control would
// reach here, so reapplying `THFLWW + XHFLF0 + XHFLV0` would count those
// increments twice. That reasoning is confirmed, not merely accepted:
// `snow_heat_conduction.zig:104--111` writes `temperature_k` from its own
// implicit solve and `snow_phase_change.zig:73--90` writes it again from the
// enthalpy Newton step, both before this point in the hourly order.
//
// Two observations recorded so a later pass does not mistake them for new
// findings. First, the `VHCPWX` floor guarding `redist.f:4075--4078` and the
// air/neighbour temperature substitute in its `ELSE` arm are the subject of the
// existing note, not of this disposition; production substitutes a
// `capacity > 0` test and leaves an emptied layer's stale `temperature_k` in
// place, which is harmless only because every consumer gates on capacity
// (`snow_phase_change.zig:75`, `snow_vapor_diffusion.zig:114`). Second,
// `redist.f:4127--4130` inherits `DENSS` from `L-1` for an inactive layer
// whereas `snow_compaction.zig:47--52` leaves the inherited density untouched;
// these agree whenever the layer above was itself inactive, and the value is
// unread while `solid == 0`, so it is not filed as a divergence.
//
// snowpack group of docs/traceability/a1b_snowpack_minimum_heat_capacity_unbound.md

const std = @import("std");

pub const Parameters = struct {
    solid_snow_heat_capacity_megajoules_per_m3_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    celsius_zero_temperature_k: f64,
    absolute_heat_capacity_tolerance_megajoules_per_k: f64,
    relative_heat_capacity_tolerance: f64,
};

pub const CellInputs = struct {
    horizontal_area_m2: f64,
    atmospheric_temperature_k: f64,
    initial_snow_density_megagrams_per_m3: f64,
    inactive_phase_volume_threshold_m3: f64,
};

pub const LayerState = struct {
    active: []bool,
    solid_snow_water_equivalent_m3: []f64,
    liquid_water_m3: []f64,
    water_vapor_equivalent_m3: []f64,
    ice_volume_m3: []f64,
    snow_density_megagrams_per_m3: []f64,
    temperature_k: []f64,
    temperature_c: []f64,
    heat_capacity_megajoules_per_k: []f64,
    total_layer_volume_m3: []f64,
    layer_thickness_m: []f64,
    cumulative_depth_m: []f64,
};

pub const ColumnTotals = struct {
    solid_snow_water_equivalent_m3: f64 = 0,
    liquid_water_m3: f64 = 0,
    ice_volume_m3: f64 = 0,
    snowpack_volume_m3: f64 = 0,
    snowpack_depth_m: f64 = 0,
};

pub const ClearedInactiveStorage = struct {
    solid_snow_water_equivalent_m3: f64 = 0,
    liquid_water_m3: f64 = 0,
    water_vapor_equivalent_m3: f64 = 0,
    ice_volume_m3: f64 = 0,
    sensible_energy_megajoules: f64 = 0,
};

pub const Report = struct {
    column_totals: ColumnTotals = .{},
    cleared_inactive_storage: ClearedInactiveStorage = .{},
    inactive_layer_count: usize = 0,
};

pub const LayerCandidate = struct {
    active: bool,
    solid_snow_water_equivalent_m3: f64,
    liquid_water_m3: f64,
    water_vapor_equivalent_m3: f64,
    ice_volume_m3: f64,
    snow_density_megagrams_per_m3: f64,
    temperature_k: f64,
    temperature_c: f64,
    heat_capacity_megajoules_per_k: f64,
    total_layer_volume_m3: f64,
    layer_thickness_m: f64,
    cumulative_depth_m: f64,
};

/// Publishes enhanced snow-solver state into layer geometry and column totals.
///
/// Traceability: `REDIST` lines 4046--4133. Geometry, the active-layer gate,
/// column accumulation, inactive-layer reset, and Celsius conversion retain
/// source order. The legacy `THFLWW + XHFLF0 + XHFLV0` temperature update is
/// intentionally absent: ecosys-ng's heat, vapor, and Dall'Amico phase solvers
/// have already state_updateted `temperature_k` and `heat_capacity_megajoules_per_k`.
/// Reapplying those energy increments here would count them twice.
///
/// One invocation owns one cell's runtime layer slices. Independent cells can
/// therefore run in parallel without shared mutation. The caller supplies
/// `workspace` so validation and calculation complete before atomic state_update.
pub fn publishCell(
    state: LayerState,
    inputs: CellInputs,
    parameters: Parameters,
    workspace: []LayerCandidate,
) !Report {
    try validateDimensions(state, workspace);
    try validateParameters(inputs, parameters);
    try validateWorkspaceOwnership(state, workspace);

    const report = try prepareCandidates(state, inputs, parameters, workspace);
    state_updateCandidates(state, workspace);
    return report;
}

fn prepareCandidates(
    state: LayerState,
    inputs: CellInputs,
    parameters: Parameters,
    workspace: []LayerCandidate,
) !Report {
    var report: Report = .{};
    var cumulative_depth_m: f64 = 0;
    for (workspace, 0..) |*candidate, layer| {
        try validateLayerInputs(state, layer);
        const phase_volume_m3 =
            state.solid_snow_water_equivalent_m3[layer] +
            state.liquid_water_m3[layer] +
            state.ice_volume_m3[layer];
        if (!std.math.isFinite(phase_volume_m3))
            return error.NonFiniteSnowpackStateUpdateResult;

        if (phase_volume_m3 > inputs.inactive_phase_volume_threshold_m3) {
            candidate.* = try prepareActiveLayer(
                state,
                inputs,
                parameters,
                layer,
                cumulative_depth_m,
            );
            cumulative_depth_m = candidate.cumulative_depth_m;
            try addActiveLayerToTotals(&report.column_totals, candidate.*);
        } else {
            candidate.* = try prepareInactiveLayer(
                state,
                inputs,
                parameters,
                workspace,
                layer,
                cumulative_depth_m,
            );
            try recordInactiveCleanup(&report, state, layer);
        }
    }
    try validateReport(report);
    return report;
}

fn prepareActiveLayer(
    state: LayerState,
    inputs: CellInputs,
    parameters: Parameters,
    layer: usize,
    previous_depth_m: f64,
) !LayerCandidate {
    const density_megagrams_per_m3 = state.snow_density_megagrams_per_m3[layer];
    if (density_megagrams_per_m3 <= 0) return error.InvalidActiveSnowDensity;
    const total_volume_m3 =
        state.solid_snow_water_equivalent_m3[layer] / density_megagrams_per_m3 +
        state.liquid_water_m3[layer] +
        state.ice_volume_m3[layer];
    const thickness_m = @max(0, total_volume_m3) / inputs.horizontal_area_m2;
    const cumulative_depth_m = previous_depth_m + thickness_m;
    const calculated_capacity_megajoules_per_k =
        parameters.solid_snow_heat_capacity_megajoules_per_m3_k *
        state.solid_snow_water_equivalent_m3[layer] +
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
            (state.liquid_water_m3[layer] +
                state.water_vapor_equivalent_m3[layer]) +
        parameters.ice_heat_capacity_megajoules_per_m3_k *
            state.ice_volume_m3[layer];
    inline for (.{
        total_volume_m3,
        thickness_m,
        cumulative_depth_m,
        calculated_capacity_megajoules_per_k,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteSnowpackStateUpdateResult;
    try requireConsistentHeatCapacity(
        state.heat_capacity_megajoules_per_k[layer],
        calculated_capacity_megajoules_per_k,
        parameters,
    );
    const temperature_c =
        state.temperature_k[layer] - parameters.celsius_zero_temperature_k;
    if (!std.math.isFinite(temperature_c))
        return error.NonFiniteSnowpackStateUpdateResult;

    return .{
        .active = true,
        .solid_snow_water_equivalent_m3 = state.solid_snow_water_equivalent_m3[layer],
        .liquid_water_m3 = state.liquid_water_m3[layer],
        .water_vapor_equivalent_m3 = state.water_vapor_equivalent_m3[layer],
        .ice_volume_m3 = state.ice_volume_m3[layer],
        .snow_density_megagrams_per_m3 = density_megagrams_per_m3,
        .temperature_k = state.temperature_k[layer],
        .temperature_c = temperature_c,
        .heat_capacity_megajoules_per_k = calculated_capacity_megajoules_per_k,
        .total_layer_volume_m3 = total_volume_m3,
        .layer_thickness_m = thickness_m,
        .cumulative_depth_m = cumulative_depth_m,
    };
}

fn prepareInactiveLayer(
    state: LayerState,
    inputs: CellInputs,
    parameters: Parameters,
    workspace: []const LayerCandidate,
    layer: usize,
    cumulative_depth_m: f64,
) !LayerCandidate {
    const temperature_k = if (layer == 0)
        inputs.atmospheric_temperature_k
    else
        workspace[layer - 1].temperature_k;
    const density_megagrams_per_m3 = if (layer == 0)
        inputs.initial_snow_density_megagrams_per_m3
    else
        workspace[layer - 1].snow_density_megagrams_per_m3;
    const temperature_c =
        temperature_k - parameters.celsius_zero_temperature_k;
    inline for (.{ temperature_k, density_megagrams_per_m3, temperature_c }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteSnowpackStateUpdateResult;
    _ = state;

    return .{
        .active = false,
        .solid_snow_water_equivalent_m3 = 0,
        .liquid_water_m3 = 0,
        .water_vapor_equivalent_m3 = 0,
        .ice_volume_m3 = 0,
        .snow_density_megagrams_per_m3 = density_megagrams_per_m3,
        .temperature_k = temperature_k,
        .temperature_c = temperature_c,
        .heat_capacity_megajoules_per_k = 0,
        .total_layer_volume_m3 = 0,
        .layer_thickness_m = 0,
        .cumulative_depth_m = cumulative_depth_m,
    };
}

fn addActiveLayerToTotals(
    totals: *ColumnTotals,
    layer: LayerCandidate,
) !void {
    totals.solid_snow_water_equivalent_m3 +=
        layer.solid_snow_water_equivalent_m3;
    totals.liquid_water_m3 += layer.liquid_water_m3;
    totals.ice_volume_m3 += layer.ice_volume_m3;
    totals.snowpack_volume_m3 += layer.total_layer_volume_m3;
    totals.snowpack_depth_m += layer.layer_thickness_m;
    inline for (@typeInfo(ColumnTotals).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(totals.*, field.name)))
            return error.NonFiniteSnowpackStateUpdateResult;
    }
}

fn recordInactiveCleanup(
    report: *Report,
    state: LayerState,
    layer: usize,
) !void {
    report.inactive_layer_count = std.math.add(
        usize,
        report.inactive_layer_count,
        1,
    ) catch return error.SnowpackStateUpdateCountOverflow;
    report.cleared_inactive_storage.solid_snow_water_equivalent_m3 +=
        state.solid_snow_water_equivalent_m3[layer];
    report.cleared_inactive_storage.liquid_water_m3 +=
        state.liquid_water_m3[layer];
    report.cleared_inactive_storage.water_vapor_equivalent_m3 +=
        state.water_vapor_equivalent_m3[layer];
    report.cleared_inactive_storage.ice_volume_m3 +=
        state.ice_volume_m3[layer];
    report.cleared_inactive_storage.sensible_energy_megajoules +=
        state.heat_capacity_megajoules_per_k[layer] * state.temperature_k[layer];
}

fn state_updateCandidates(state: LayerState, candidates: []const LayerCandidate) void {
    for (candidates, 0..) |candidate, layer| {
        state.active[layer] = candidate.active;
        inline for (.{
            .{ state.solid_snow_water_equivalent_m3, candidate.solid_snow_water_equivalent_m3 },
            .{ state.liquid_water_m3, candidate.liquid_water_m3 },
            .{ state.water_vapor_equivalent_m3, candidate.water_vapor_equivalent_m3 },
            .{ state.ice_volume_m3, candidate.ice_volume_m3 },
            .{ state.snow_density_megagrams_per_m3, candidate.snow_density_megagrams_per_m3 },
            .{ state.temperature_k, candidate.temperature_k },
            .{ state.temperature_c, candidate.temperature_c },
            .{ state.heat_capacity_megajoules_per_k, candidate.heat_capacity_megajoules_per_k },
            .{ state.total_layer_volume_m3, candidate.total_layer_volume_m3 },
            .{ state.layer_thickness_m, candidate.layer_thickness_m },
            .{ state.cumulative_depth_m, candidate.cumulative_depth_m },
        }) |destination_and_value| {
            destination_and_value[0][layer] = destination_and_value[1];
        }
    }
}

fn validateDimensions(state: LayerState, workspace: []LayerCandidate) !void {
    const layer_count = state.active.len;
    if (layer_count == 0) return error.InvalidSnowpackStateUpdateDimensions;
    inline for (@typeInfo(LayerState).@"struct".fields) |field| {
        if (@field(state, field.name).len != layer_count)
            return error.SnowpackStateUpdateDimensionMismatch;
    }
    if (workspace.len != layer_count)
        return error.SnowpackStateUpdateDimensionMismatch;
}

fn validateParameters(inputs: CellInputs, parameters: Parameters) !void {
    inline for (@typeInfo(CellInputs).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteSnowpackStateUpdateParameter;
    }
    inline for (@typeInfo(Parameters).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(parameters, field.name)))
            return error.NonFiniteSnowpackStateUpdateParameter;
    }
    if (inputs.horizontal_area_m2 <= 0 or
        inputs.atmospheric_temperature_k <= 0 or
        inputs.initial_snow_density_megagrams_per_m3 <= 0 or
        inputs.inactive_phase_volume_threshold_m3 < 0 or
        parameters.solid_snow_heat_capacity_megajoules_per_m3_k <= 0 or
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or
        parameters.ice_heat_capacity_megajoules_per_m3_k <= 0 or
        parameters.celsius_zero_temperature_k <= 0 or
        parameters.absolute_heat_capacity_tolerance_megajoules_per_k < 0 or
        parameters.relative_heat_capacity_tolerance < 0)
    {
        return error.InvalidSnowpackStateUpdateParameter;
    }
}

fn validateLayerInputs(state: LayerState, layer: usize) !void {
    inline for (.{
        state.solid_snow_water_equivalent_m3[layer],
        state.liquid_water_m3[layer],
        state.water_vapor_equivalent_m3[layer],
        state.ice_volume_m3[layer],
        state.snow_density_megagrams_per_m3[layer],
        state.temperature_k[layer],
        state.heat_capacity_megajoules_per_k[layer],
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteSnowpackStateUpdateState;
    if (state.solid_snow_water_equivalent_m3[layer] < 0 or
        state.liquid_water_m3[layer] < 0 or
        state.water_vapor_equivalent_m3[layer] < 0 or
        state.ice_volume_m3[layer] < 0 or
        state.snow_density_megagrams_per_m3[layer] < 0 or
        state.temperature_k[layer] <= 0 or
        state.heat_capacity_megajoules_per_k[layer] < 0)
    {
        return error.InvalidSnowpackStateUpdateState;
    }
}

fn requireConsistentHeatCapacity(
    state_updateted_megajoules_per_k: f64,
    calculated_megajoules_per_k: f64,
    parameters: Parameters,
) !void {
    const tolerance_megajoules_per_k =
        parameters.absolute_heat_capacity_tolerance_megajoules_per_k +
        parameters.relative_heat_capacity_tolerance *
            @max(@abs(state_updateted_megajoules_per_k), @abs(calculated_megajoules_per_k));
    if (!std.math.isFinite(tolerance_megajoules_per_k))
        return error.NonFiniteSnowpackStateUpdateResult;
    if (@abs(state_updateted_megajoules_per_k - calculated_megajoules_per_k) >
        tolerance_megajoules_per_k)
    {
        return error.InconsistentStateUpdatetedSnowHeatCapacity;
    }
}

fn validateReport(report: Report) !void {
    inline for (@typeInfo(ColumnTotals).@"struct".fields) |field| {
        const value = @field(report.column_totals, field.name);
        if (!std.math.isFinite(value))
            return error.NonFiniteSnowpackStateUpdateResult;
        if (value < 0) return error.InvalidSnowpackStateUpdateResult;
    }
    inline for (@typeInfo(ClearedInactiveStorage).@"struct".fields) |field| {
        const value = @field(report.cleared_inactive_storage, field.name);
        if (!std.math.isFinite(value))
            return error.NonFiniteSnowpackStateUpdateResult;
        if (value < 0) return error.InvalidSnowpackStateUpdateResult;
    }
}

fn validateWorkspaceOwnership(
    state: LayerState,
    workspace: []LayerCandidate,
) !void {
    const workspace_start = @intFromPtr(workspace.ptr);
    const workspace_bytes = std.math.mul(
        usize,
        workspace.len,
        @sizeOf(LayerCandidate),
    ) catch return error.SnowpackStateUpdateDimensionOverflow;
    inline for (@typeInfo(LayerState).@"struct".fields) |field| {
        const values = @field(state, field.name);
        const value_type = @typeInfo(@TypeOf(values)).pointer.child;
        const state_bytes = std.math.mul(
            usize,
            values.len,
            @sizeOf(value_type),
        ) catch return error.SnowpackStateUpdateDimensionOverflow;
        if (rangesOverlap(
            workspace_start,
            workspace_bytes,
            @intFromPtr(values.ptr),
            state_bytes,
        )) return error.SnowpackStateUpdateWorkspaceOverlap;
    }
}

fn rangesOverlap(
    left_start: usize,
    left_bytes: usize,
    right_start: usize,
    right_bytes: usize,
) bool {
    const left_end = std.math.add(usize, left_start, left_bytes) catch
        return true;
    const right_end = std.math.add(usize, right_start, right_bytes) catch
        return true;
    return left_start < right_end and right_start < left_end;
}

const TestStorage = struct {
    allocator: std.mem.Allocator,
    state: LayerState,

    fn init(allocator: std.mem.Allocator, layer_count: usize) !TestStorage {
        var storage: TestStorage = undefined;
        storage.allocator = allocator;
        inline for (@typeInfo(LayerState).@"struct".fields) |field| {
            const slice_type = field.type;
            const value_type = @typeInfo(slice_type).pointer.child;
            @field(storage.state, field.name) =
                try allocator.alloc(value_type, layer_count);
        }
        @memset(storage.state.active, false);
        inline for (@typeInfo(LayerState).@"struct".fields[1..]) |field|
            @memset(@field(storage.state, field.name), 0);
        return storage;
    }

    fn deinit(self: *TestStorage) void {
        inline for (@typeInfo(LayerState).@"struct".fields) |field|
            self.allocator.free(@field(self.state, field.name));
        self.* = undefined;
    }
};

const test_parameters: Parameters = .{
    .solid_snow_heat_capacity_megajoules_per_m3_k = 2,
    .liquid_water_heat_capacity_megajoules_per_m3_k = 4,
    .ice_heat_capacity_megajoules_per_m3_k = 1.5,
    .celsius_zero_temperature_k = 273.15,
    .absolute_heat_capacity_tolerance_megajoules_per_k = 1e-12,
    .relative_heat_capacity_tolerance = 1e-12,
};

const test_inputs: CellInputs = .{
    .horizontal_area_m2 = 2,
    .atmospheric_temperature_k = 265,
    .initial_snow_density_megagrams_per_m3 = 0.2,
    .inactive_phase_volume_threshold_m3 = 1e-9,
};

fn setLayer(
    state: LayerState,
    layer: usize,
    solid_m3: f64,
    liquid_m3: f64,
    vapor_m3: f64,
    ice_m3: f64,
    density_megagrams_per_m3: f64,
    temperature_k: f64,
) void {
    state.solid_snow_water_equivalent_m3[layer] = solid_m3;
    state.liquid_water_m3[layer] = liquid_m3;
    state.water_vapor_equivalent_m3[layer] = vapor_m3;
    state.ice_volume_m3[layer] = ice_m3;
    state.snow_density_megagrams_per_m3[layer] = density_megagrams_per_m3;
    state.temperature_k[layer] = temperature_k;
    state.heat_capacity_megajoules_per_k[layer] =
        test_parameters.solid_snow_heat_capacity_megajoules_per_m3_k * solid_m3 +
        test_parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
            (liquid_m3 + vapor_m3) +
        test_parameters.ice_heat_capacity_megajoules_per_m3_k * ice_m3;
}

test "REDIST active snow geometry preserves enhanced thermal state_update" {
    var storage = try TestStorage.init(std.testing.allocator, 2);
    defer storage.deinit();
    setLayer(storage.state, 0, 0.2, 0.1, 0.01, 0.05, 0.4, 270);
    setLayer(storage.state, 1, 0.1, 0, 0.02, 0, 0.5, 268);
    const workspace =
        try std.testing.allocator.alloc(LayerCandidate, 2);
    defer std.testing.allocator.free(workspace);

    const report = try publishCell(
        storage.state,
        test_inputs,
        test_parameters,
        workspace,
    );

    try std.testing.expect(storage.state.active[0]);
    try std.testing.expect(storage.state.active[1]);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.65),
        storage.state.total_layer_volume_m3[0],
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.325),
        storage.state.layer_thickness_m[0],
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.425),
        storage.state.cumulative_depth_m[1],
        1e-14,
    );
    try std.testing.expectEqual(@as(f64, 270), storage.state.temperature_k[0]);
    try std.testing.expectApproxEqAbs(
        @as(f64, -3.15),
        storage.state.temperature_c[0],
        1e-13,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.3),
        report.column_totals.solid_snow_water_equivalent_m3,
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.85),
        report.column_totals.snowpack_volume_m3,
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        report.column_totals.snowpack_depth_m,
        storage.state.cumulative_depth_m[1],
        1e-14,
    );
}

test "inactive layers reset explicitly and inherit source-order boundary state" {
    var storage = try TestStorage.init(std.testing.allocator, 3);
    defer storage.deinit();
    setLayer(storage.state, 0, 0, 0, 4e-10, 0, 0, 275);
    setLayer(storage.state, 1, 0.12, 0, 0, 0, 0.3, 269);
    setLayer(storage.state, 2, 2e-10, 0, 3e-10, 0, 0.1, 271);
    const workspace =
        try std.testing.allocator.alloc(LayerCandidate, 3);
    defer std.testing.allocator.free(workspace);

    const report = try publishCell(
        storage.state,
        test_inputs,
        test_parameters,
        workspace,
    );

    try std.testing.expect(!storage.state.active[0]);
    try std.testing.expectEqual(
        test_inputs.atmospheric_temperature_k,
        storage.state.temperature_k[0],
    );
    try std.testing.expectEqual(
        test_inputs.initial_snow_density_megagrams_per_m3,
        storage.state.snow_density_megagrams_per_m3[0],
    );
    try std.testing.expect(storage.state.active[1]);
    try std.testing.expect(!storage.state.active[2]);
    try std.testing.expectEqual(
        storage.state.temperature_k[1],
        storage.state.temperature_k[2],
    );
    try std.testing.expectEqual(
        storage.state.snow_density_megagrams_per_m3[1],
        storage.state.snow_density_megagrams_per_m3[2],
    );
    try std.testing.expectEqual(@as(f64, 0), storage.state.temperature_c[2] -
        (storage.state.temperature_k[2] -
            test_parameters.celsius_zero_temperature_k));
    try std.testing.expectEqual(@as(usize, 2), report.inactive_layer_count);
    try std.testing.expectApproxEqAbs(
        @as(f64, 7e-10),
        report.cleared_inactive_storage.water_vapor_equivalent_m3,
        1e-20,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 2e-10),
        report.cleared_inactive_storage.solid_snow_water_equivalent_m3,
        1e-20,
    );
    try std.testing.expectEqual(
        storage.state.cumulative_depth_m[1],
        storage.state.cumulative_depth_m[2],
    );
}

test "runtime layer count has no fixed snowpack extent" {
    const layer_count: usize = 17;
    var storage = try TestStorage.init(std.testing.allocator, layer_count);
    defer storage.deinit();
    for (0..layer_count) |layer|
        setLayer(storage.state, layer, 0.01, 0, 0, 0, 0.25, 266);
    const workspace =
        try std.testing.allocator.alloc(LayerCandidate, layer_count);
    defer std.testing.allocator.free(workspace);

    const report = try publishCell(
        storage.state,
        test_inputs,
        test_parameters,
        workspace,
    );

    try std.testing.expectApproxEqAbs(
        @as(f64, 0.17),
        report.column_totals.solid_snow_water_equivalent_m3,
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.34),
        report.column_totals.snowpack_depth_m,
        1e-14,
    );
}

test "heat-capacity discrepancy fails without partial state state_update" {
    var storage = try TestStorage.init(std.testing.allocator, 2);
    defer storage.deinit();
    setLayer(storage.state, 0, 0.1, 0, 0, 0, 0.25, 268);
    setLayer(storage.state, 1, 0.1, 0, 0, 0, 0.25, 268);
    storage.state.heat_capacity_megajoules_per_k[1] += 0.1;
    @memset(storage.state.total_layer_volume_m3, 99);
    @memset(storage.state.layer_thickness_m, 98);
    const workspace =
        try std.testing.allocator.alloc(LayerCandidate, 2);
    defer std.testing.allocator.free(workspace);

    try std.testing.expectError(
        error.InconsistentStateUpdatetedSnowHeatCapacity,
        publishCell(storage.state, test_inputs, test_parameters, workspace),
    );
    try std.testing.expectEqual(
        @as(f64, 99),
        storage.state.total_layer_volume_m3[0],
    );
    try std.testing.expectEqual(
        @as(f64, 98),
        storage.state.layer_thickness_m[0],
    );
    try std.testing.expect(!storage.state.active[0]);
}

test "dimension and non-finite failures are diagnostic" {
    var storage = try TestStorage.init(std.testing.allocator, 2);
    defer storage.deinit();
    setLayer(storage.state, 0, 0.1, 0, 0, 0, 0.25, 268);
    setLayer(storage.state, 1, 0.1, 0, 0, 0, 0.25, 268);
    const short_workspace =
        try std.testing.allocator.alloc(LayerCandidate, 1);
    defer std.testing.allocator.free(short_workspace);
    try std.testing.expectError(
        error.SnowpackStateUpdateDimensionMismatch,
        publishCell(
            storage.state,
            test_inputs,
            test_parameters,
            short_workspace,
        ),
    );

    const workspace =
        try std.testing.allocator.alloc(LayerCandidate, 2);
    defer std.testing.allocator.free(workspace);
    storage.state.temperature_k[1] = std.math.nan(f64);
    try std.testing.expectError(
        error.NonFiniteSnowpackStateUpdateState,
        publishCell(storage.state, test_inputs, test_parameters, workspace),
    );
}
