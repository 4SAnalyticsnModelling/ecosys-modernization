// **A8a DISPOSITION: superseded by distribution over the solvers that produce
// each phase transfer.** `redist.f:3960--3986` is an accumulate-then-total block,
// and production splits it by *which solver owns the transfer* rather than
// applying pre-computed increments in one place.
//
// The four inventory updates at `:3979--3986` each have a distinct owner:
//
//   - `-XWFLFS` / `+XWFLFS` and `+XWFLFI` / `-XWFLFI/DENSI`, the freeze-thaw
//     exchange between solid, liquid and ice, are `snow_phase_change.zig:110--120`.
//     That module does not receive an increment; it computes the phase heat by
//     Newton step with a Picard fallback, clamps it to the latent heat actually
//     available in the frozen or liquid reservoir, and then moves the mass,
//     splitting the thawed water equivalent between solid and ice by
//     `solid_fraction` and dividing the frozen part by `DENSI` on the way into
//     `ice_volume_m3` exactly as `:3986` does.
//   - `+XWFLVS` / `-XWFLVS` and `+XWFLVW` / `-XWFLVW`, the vapor exchange, are
//     `snow_vapor_equilibrium.zig`, which publishes solid, liquid, vapor,
//     temperature and heat capacity together at `:166--170`.
//   - `TFLWS/TFLWW/TFLWV/TFLWI`, the net transport fluxes, arrive through three
//     separate state_updateters: `snow_solute_transport.state_updateAtmosphericWater:117--143`
//     for the top-layer atmospheric input, `state_updateMeltWater:145--170` for the
//     downward liquid cascade and the ground discharge, and
//     `snow_relayering.apply` for the inter-layer redistribution.
//
// The module's own header already concedes the substantive half of this: it says
// `:3979--3986` are "intentionally modernized" because production has no
// `XWFLF*` staged transfers to reconstruct. That is the supersession. What the
// module then offers is a *generic* applier of signed deltas plus a
// water-equivalent conservation check
// (`solid + liquid + vapor + ice*DENSI = 0`). Production enforces the same
// conservation inside each owner instead, where the constraint can be tied to the
// mechanism: `snow_phase_change` gets it structurally by construction, and
// `snow_vapor_equilibrium`'s test at `:174--188` asserts the three-phase sum is
// invariant to `1e-14`.
//
// The reset half is also already owned, and it is a reset only. `:3960--3964`
// zero the five column totals at the top of the layer loop, and this module
// mirrors that by assigning `state.column_totals = .{}` at `:66` and never
// filling them. Production does not store those totals at all; it accumulates
// them at the point of consumption, `hourly_science_snow_energy.zig:124--128`
// republishing `snow_depth_m` from the deepest cumulative depth and summing the
// per-layer solid water equivalent for `surface_precipitation`. This is the same
// pattern recorded for `snowpack_geometry_temperature_update` and
// `snowpack_initial_state`, and the reason is the same: a stored total is a second
// copy that can go stale between the six sites that move snow mass.
//
// Binding this module would insert a second writer of all four phase arrays
// between solvers that each publish atomically and then call
// `refreshCellGeometry`, and it would require someone upstream to *manufacture*
// the `XWFLF*`-shaped increments that production deliberately does not have.
// There is no gap: every term of `:3979--3986` is accounted for above.
//
// snowpack phase inventory group of docs/traceability/a1b_snowpack_minimum_heat_capacity_unbound.md

const std = @import("std");

/// Snow-layer phase storage. Solid and vapor are water-equivalent volumes.
pub const PhaseStorage = struct {
    solid_snow_water_equivalent_m3: f64 = 0,
    liquid_water_m3: f64 = 0,
    water_vapor_equivalent_m3: f64 = 0,
    ice_volume_m3: f64 = 0,
};

pub const ColumnTotals = struct {
    solid_snow_water_equivalent_m3: f64 = 0,
    liquid_water_m3: f64 = 0,
    ice_volume_m3: f64 = 0,
    snowpack_volume_m3: f64 = 0,
    snowpack_depth_m: f64 = 0,
};

pub const Inputs = struct {
    ice_density_megagrams_per_m3: f64,
    absolute_phase_balance_tolerance_m3: f64,
    relative_phase_balance_tolerance: f64,
    /// Signed external transport over one model step [snow_layer].
    transport_increment_by_layer: []const PhaseStorage,
    /// Signed internal delta from the enhanced snow phase solver [snow_layer].
    phase_solver_increment_by_layer: []const PhaseStorage,
};

pub const State = struct {
    storage_by_layer: []PhaseStorage,
    column_totals: ColumnTotals,
};

pub const Workspace = struct {
    storage_by_layer: []PhaseStorage,
};

/// Applies transport and enhanced phase-solver changes to snow inventories.
///
/// Traceability: REDIST.F lines 3960--3986. Lines 3960--3965 reset column
/// totals before runtime layer traversal. Lines 3979--3986 are intentionally
/// modernized: instead of reconstructing legacy `XWFLF*` phase transfers, this
/// kernel consumes direct signed deltas from ecosys-ng's Newton/Picard snow
/// phase solver. Each internal delta must conserve water-equivalent volume:
///
/// solid + liquid + vapor + ice_volume * ice_density = 0.
///
/// External transport is then added in the original solid, liquid, vapor, ice
/// storage order. The legacy `VOLWSLX` assignment only served commented debug
/// output and has no state equivalent. Runtime layers state_update atomically.
pub fn update(inputs: Inputs, state: *State, workspace: Workspace) !void {
    try validateDimensions(inputs, state.*, workspace);
    try validateInputs(inputs, state.*, workspace);
    @memcpy(workspace.storage_by_layer, state.storage_by_layer);

    for (
        workspace.storage_by_layer,
        inputs.transport_increment_by_layer,
        inputs.phase_solver_increment_by_layer,
    ) |*candidate, transport, phase| {
        try validatePhaseBalance(inputs, phase);
        try applyIncrement(candidate, transport, phase);
    }

    @memcpy(state.storage_by_layer, workspace.storage_by_layer);
    state.column_totals = .{};
}

fn validateDimensions(inputs: Inputs, state: State, workspace: Workspace) !void {
    const layer_count = state.storage_by_layer.len;
    if (layer_count == 0) return error.InvalidSnowpackPhaseDimensions;
    if (inputs.transport_increment_by_layer.len != layer_count or
        inputs.phase_solver_increment_by_layer.len != layer_count or
        workspace.storage_by_layer.len != layer_count)
    {
        return error.SnowpackPhaseDimensionMismatch;
    }
}

fn validateInputs(inputs: Inputs, state: State, workspace: Workspace) !void {
    if (!std.math.isFinite(inputs.ice_density_megagrams_per_m3) or
        inputs.ice_density_megagrams_per_m3 <= 0 or
        !std.math.isFinite(inputs.absolute_phase_balance_tolerance_m3) or
        inputs.absolute_phase_balance_tolerance_m3 < 0 or
        !std.math.isFinite(inputs.relative_phase_balance_tolerance) or
        inputs.relative_phase_balance_tolerance < 0)
    {
        return error.InvalidSnowpackPhaseParameters;
    }
    try validateStorageSlice(state.storage_by_layer, .nonnegative);
    try validateStorageSlice(inputs.transport_increment_by_layer, .signed);
    try validateStorageSlice(inputs.phase_solver_increment_by_layer, .signed);
    try validateTotals(state.column_totals);
    if (overlap(workspace.storage_by_layer, state.storage_by_layer) or
        overlap(
            workspace.storage_by_layer,
            inputs.transport_increment_by_layer,
        ) or
        overlap(
            workspace.storage_by_layer,
            inputs.phase_solver_increment_by_layer,
        ))
    {
        return error.SnowpackPhaseWorkspaceOverlap;
    }
}

const StorageDomain = enum {
    nonnegative,
    signed,
};

fn validateStorageSlice(
    values: []const PhaseStorage,
    domain: StorageDomain,
) !void {
    for (values) |value| {
        inline for (@typeInfo(PhaseStorage).@"struct".fields) |field| {
            const scalar = @field(value, field.name);
            if (!std.math.isFinite(scalar))
                return error.NonFiniteSnowpackPhaseState;
            if (domain == .nonnegative and scalar < 0)
                return error.NegativeSnowpackPhaseStorage;
        }
    }
}

fn validateTotals(totals: ColumnTotals) !void {
    inline for (@typeInfo(ColumnTotals).@"struct".fields) |field| {
        const value = @field(totals, field.name);
        if (!std.math.isFinite(value))
            return error.NonFiniteSnowpackPhaseState;
        if (value < 0) return error.NegativeSnowpackPhaseStorage;
    }
}

fn validatePhaseBalance(inputs: Inputs, phase: PhaseStorage) !void {
    const ice_water_equivalent_m3 =
        phase.ice_volume_m3 * inputs.ice_density_megagrams_per_m3;
    if (!std.math.isFinite(ice_water_equivalent_m3))
        return error.NonFiniteSnowpackPhaseResult;
    const residual_m3 =
        phase.solid_snow_water_equivalent_m3 +
        phase.liquid_water_m3 +
        phase.water_vapor_equivalent_m3 +
        ice_water_equivalent_m3;
    if (!std.math.isFinite(residual_m3))
        return error.NonFiniteSnowpackPhaseResult;
    const scale_m3 =
        @abs(phase.solid_snow_water_equivalent_m3) +
        @abs(phase.liquid_water_m3) +
        @abs(phase.water_vapor_equivalent_m3) +
        @abs(ice_water_equivalent_m3);
    const tolerance_m3 =
        inputs.absolute_phase_balance_tolerance_m3 +
        inputs.relative_phase_balance_tolerance * scale_m3;
    if (!std.math.isFinite(tolerance_m3))
        return error.NonFiniteSnowpackPhaseResult;
    if (@abs(residual_m3) > tolerance_m3)
        return error.NonConservativeSnowpackPhaseIncrement;
}

fn applyIncrement(
    candidate: *PhaseStorage,
    transport: PhaseStorage,
    phase: PhaseStorage,
) !void {
    inline for (@typeInfo(PhaseStorage).@"struct".fields) |field| {
        const after_transport = @field(candidate.*, field.name) +
            @field(transport, field.name);
        if (!std.math.isFinite(after_transport))
            return error.NonFiniteSnowpackPhaseResult;
        const result = after_transport + @field(phase, field.name);
        if (!std.math.isFinite(result))
            return error.NonFiniteSnowpackPhaseResult;
        if (result < 0) return error.NegativeSnowpackPhaseStorage;
        @field(candidate.*, field.name) = result;
    }
}

fn overlap(left: []const PhaseStorage, right: []const PhaseStorage) bool {
    if (left.len == 0 or right.len == 0) return false;
    const item_size = @sizeOf(PhaseStorage);
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_bytes = std.math.mul(usize, left.len, item_size) catch return true;
    const right_bytes = std.math.mul(usize, right.len, item_size) catch return true;
    const left_end = std.math.add(usize, left_start, left_bytes) catch return true;
    const right_end = std.math.add(usize, right_start, right_bytes) catch return true;
    return left_start < right_end and right_start < left_end;
}

fn expectStorage(actual: PhaseStorage, expected: PhaseStorage) !void {
    inline for (@typeInfo(PhaseStorage).@"struct".fields) |field|
        try std.testing.expectEqual(
            @field(expected, field.name),
            @field(actual, field.name),
        );
}

fn filledStorage(value: f64) PhaseStorage {
    var result: PhaseStorage = undefined;
    inline for (@typeInfo(PhaseStorage).@"struct".fields) |field|
        @field(result, field.name) = value;
    return result;
}

fn testInputs(
    transport: []const PhaseStorage,
    phase: []const PhaseStorage,
) Inputs {
    return .{
        .ice_density_megagrams_per_m3 = 0.9,
        .absolute_phase_balance_tolerance_m3 = 1.0e-12,
        .relative_phase_balance_tolerance = 1.0e-12,
        .transport_increment_by_layer = transport,
        .phase_solver_increment_by_layer = phase,
    };
}

test "transport and conservative enhanced phase deltas update runtime layers" {
    const transport = [_]PhaseStorage{
        .{
            .solid_snow_water_equivalent_m3 = 1,
            .liquid_water_m3 = 2,
            .water_vapor_equivalent_m3 = 3,
            .ice_volume_m3 = 4,
        },
        .{
            .solid_snow_water_equivalent_m3 = -1,
            .liquid_water_m3 = 1,
        },
    };
    const phase = [_]PhaseStorage{
        .{
            .solid_snow_water_equivalent_m3 = -0.9,
            .liquid_water_m3 = 0.9,
        },
        .{
            .liquid_water_m3 = -0.9,
            .ice_volume_m3 = 1,
        },
    };
    var storage = [_]PhaseStorage{
        filledStorage(10),
        filledStorage(10),
    };
    var scratch: [2]PhaseStorage = undefined;
    var state = State{
        .storage_by_layer = &storage,
        .column_totals = filledTotals(7),
    };
    try update(testInputs(&transport, &phase), &state, .{
        .storage_by_layer = &scratch,
    });
    try expectStorage(storage[0], .{
        .solid_snow_water_equivalent_m3 = 10.1,
        .liquid_water_m3 = 12.9,
        .water_vapor_equivalent_m3 = 13,
        .ice_volume_m3 = 14,
    });
    try expectStorage(storage[1], .{
        .solid_snow_water_equivalent_m3 = 9,
        .liquid_water_m3 = 10.1,
        .water_vapor_equivalent_m3 = 10,
        .ice_volume_m3 = 11,
    });
    try expectTotals(state.column_totals, 0);
}

fn filledTotals(value: f64) ColumnTotals {
    var result: ColumnTotals = undefined;
    inline for (@typeInfo(ColumnTotals).@"struct".fields) |field|
        @field(result, field.name) = value;
    return result;
}

fn expectTotals(actual: ColumnTotals, expected: f64) !void {
    inline for (@typeInfo(ColumnTotals).@"struct".fields) |field|
        try std.testing.expectEqual(expected, @field(actual, field.name));
}

test "internal phase change preserves water equivalent within roundoff" {
    const transport = [_]PhaseStorage{.{}};
    const phase = [_]PhaseStorage{.{
        .solid_snow_water_equivalent_m3 = -0.3,
        .liquid_water_m3 = 0.12,
        .water_vapor_equivalent_m3 = 0.09,
        .ice_volume_m3 = 0.1,
    }};
    var storage = [_]PhaseStorage{.{
        .solid_snow_water_equivalent_m3 = 1,
        .liquid_water_m3 = 1,
        .water_vapor_equivalent_m3 = 1,
        .ice_volume_m3 = 1,
    }};
    const before =
        storage[0].solid_snow_water_equivalent_m3 +
        storage[0].liquid_water_m3 +
        storage[0].water_vapor_equivalent_m3 +
        0.9 * storage[0].ice_volume_m3;
    var scratch: [1]PhaseStorage = undefined;
    var state = State{
        .storage_by_layer = &storage,
        .column_totals = .{},
    };
    try update(testInputs(&transport, &phase), &state, .{
        .storage_by_layer = &scratch,
    });
    const after =
        storage[0].solid_snow_water_equivalent_m3 +
        storage[0].liquid_water_m3 +
        storage[0].water_vapor_equivalent_m3 +
        0.9 * storage[0].ice_volume_m3;
    try std.testing.expectApproxEqAbs(before, after, 1.0e-15);
}

test "nonconservative phase delta fails without resetting totals or storage" {
    const transport = [_]PhaseStorage{.{}};
    const phase = [_]PhaseStorage{.{
        .liquid_water_m3 = 0.1,
    }};
    var storage = [_]PhaseStorage{filledStorage(2)};
    var scratch: [1]PhaseStorage = undefined;
    var state = State{
        .storage_by_layer = &storage,
        .column_totals = filledTotals(3),
    };
    try std.testing.expectError(
        error.NonConservativeSnowpackPhaseIncrement,
        update(testInputs(&transport, &phase), &state, .{
            .storage_by_layer = &scratch,
        }),
    );
    try expectStorage(storage[0], filledStorage(2));
    try expectTotals(state.column_totals, 3);
}

test "dimension alias and negative-result errors preserve state atomically" {
    const transport = [_]PhaseStorage{.{
        .liquid_water_m3 = -3,
    }};
    const phase = [_]PhaseStorage{.{}};
    var storage = [_]PhaseStorage{filledStorage(2)};
    var scratch: [1]PhaseStorage = undefined;
    var state = State{
        .storage_by_layer = &storage,
        .column_totals = filledTotals(4),
    };
    var inputs = testInputs(&transport, &phase);
    inputs.phase_solver_increment_by_layer = &.{};
    try std.testing.expectError(
        error.SnowpackPhaseDimensionMismatch,
        update(inputs, &state, .{ .storage_by_layer = &scratch }),
    );
    try expectStorage(storage[0], filledStorage(2));

    inputs.phase_solver_increment_by_layer = &phase;
    try std.testing.expectError(
        error.SnowpackPhaseWorkspaceOverlap,
        update(inputs, &state, .{ .storage_by_layer = &storage }),
    );
    try expectStorage(storage[0], filledStorage(2));

    try std.testing.expectError(
        error.NegativeSnowpackPhaseStorage,
        update(inputs, &state, .{ .storage_by_layer = &scratch }),
    );
    try expectStorage(storage[0], filledStorage(2));
    try expectTotals(state.column_totals, 4);
}

test "late overflow leaves every layer and total unchanged" {
    const transport = [_]PhaseStorage{
        .{},
        .{ .ice_volume_m3 = std.math.floatMax(f64) },
    };
    const phase = [_]PhaseStorage{ .{}, .{} };
    var storage = [_]PhaseStorage{
        filledStorage(2),
        filledStorage(std.math.floatMax(f64)),
    };
    var scratch: [2]PhaseStorage = undefined;
    var state = State{
        .storage_by_layer = &storage,
        .column_totals = filledTotals(6),
    };
    try std.testing.expectError(
        error.NonFiniteSnowpackPhaseResult,
        update(testInputs(&transport, &phase), &state, .{
            .storage_by_layer = &scratch,
        }),
    );
    try expectStorage(storage[0], filledStorage(2));
    try expectStorage(storage[1], filledStorage(std.math.floatMax(f64)));
    try expectTotals(state.column_totals, 6);
}
