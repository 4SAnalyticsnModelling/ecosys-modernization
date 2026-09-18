const std = @import("std");

pub const Source = enum(u8) {
    precipitation = 1,
    irrigation = 2,
    soil = 3,
};

pub const State = struct {
    total_carboxyl_sites_mol_per_megagram: f64, // XCOOH
    protonated_carboxyl_sites_mol_per_megagram: f64, // XHC1
};

pub const Parameters = struct {
    substrate_limit_fraction: f64, // FION
    minimum_unprotonated_sites_mol_per_megagram: f64, // ZEROC
    carboxyl_dissociation_mol_per_m3: f64, // DPCOH
    maximum_exchange_mol_per_megagram_iteration: f64, // TADC
};

pub const SurfaceParameters = struct {
    minimum_unprotonated_sites_mol_per_megagram: f64, // ZEROC
    carboxyl_dissociation_mol_per_m3: f64, // DPCOH
    maximum_exchange_mol_per_megagram_iteration: f64, // TADC
};

pub const Diagnostics = struct {
    substrate_limit_mol_per_megagram_iteration: f64, // XMIN
    unprotonated_carboxyl_sites_mol_per_megagram: f64, // XCOO
    equilibrium_unprotonated_sites_mol_per_megagram: f64, // XCOOQ
};

pub const StepResult = struct {
    protonation_rate_mol_per_megagram_iteration: f64, // RXHC
    diagnostics: ?Diagnostics,
};

/// Direct translation of `starte.f` lines 812--825 for one runtime soil layer.
/// A positive rate protonates carboxyl sites; a negative rate dissociates them.
/// Non-soil sources explicitly return zero without inspecting dormant state.
pub fn step(
    source: Source,
    hydrogen_activity_mol_per_m3: f64,
    parameters: Parameters,
    state: *State,
) !StepResult {
    if (source != .soil) return .{
        .protonation_rate_mol_per_megagram_iteration = 0,
        .diagnostics = null,
    };

    inline for (@typeInfo(State).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(state.*, field.name)))
            return error.NonFiniteCarboxylProtonExchangeState;
    }
    inline for (@typeInfo(Parameters).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(parameters, field.name)))
            return error.NonFiniteCarboxylProtonExchangeParameter;
    }
    if (!std.math.isFinite(hydrogen_activity_mol_per_m3) or
        hydrogen_activity_mol_per_m3 <= 0 or
        state.total_carboxyl_sites_mol_per_megagram < 0 or
        state.protonated_carboxyl_sites_mol_per_megagram < 0 or
        state.protonated_carboxyl_sites_mol_per_megagram > state.total_carboxyl_sites_mol_per_megagram or
        parameters.substrate_limit_fraction < 0 or
        parameters.minimum_unprotonated_sites_mol_per_megagram < 0 or
        parameters.carboxyl_dissociation_mol_per_m3 <= 0 or
        parameters.maximum_exchange_mol_per_megagram_iteration < 0)
        return error.InvalidCarboxylProtonExchangeInput;

    const substrate_limit = parameters.substrate_limit_fraction *
        @min(
            state.protonated_carboxyl_sites_mol_per_megagram,
            hydrogen_activity_mol_per_m3,
        );
    const unprotonated = @max(
        parameters.minimum_unprotonated_sites_mol_per_megagram,
        state.total_carboxyl_sites_mol_per_megagram -
            state.protonated_carboxyl_sites_mol_per_megagram,
    );
    const equilibrium_unprotonated = @min(
        state.total_carboxyl_sites_mol_per_megagram,
        parameters.carboxyl_dissociation_mol_per_m3 *
            state.protonated_carboxyl_sites_mol_per_megagram /
            hydrogen_activity_mol_per_m3,
    );
    const rate = @max(
        -parameters.maximum_exchange_mol_per_megagram_iteration,
        -substrate_limit,
        @min(
            parameters.maximum_exchange_mol_per_megagram_iteration,
            substrate_limit,
            unprotonated - equilibrium_unprotonated,
        ),
    );
    const next_protonated = state.protonated_carboxyl_sites_mol_per_megagram + rate;
    inline for (.{ substrate_limit, unprotonated, equilibrium_unprotonated, rate, next_protonated }) |value| {
        if (!std.math.isFinite(value))
            return error.NonFiniteCarboxylProtonExchangeResult;
    }
    if (next_protonated < 0 or next_protonated > state.total_carboxyl_sites_mol_per_megagram)
        return error.InvalidCarboxylProtonExchangeResult;
    state.protonated_carboxyl_sites_mol_per_megagram = next_protonated;
    return .{
        .protonation_rate_mol_per_megagram_iteration = rate,
        .diagnostics = .{
            .substrate_limit_mol_per_megagram_iteration = substrate_limit,
            .unprotonated_carboxyl_sites_mol_per_megagram = unprotonated,
            .equilibrium_unprotonated_sites_mol_per_megagram = equilibrium_unprotonated,
        },
    };
}

/// Exact surface-litter startup recurrence from `starte.f:1896--1900`.
/// This differs from both the profile STARTE rate above and hourly SOLUTE:
/// the source has no FION substrate term here and uses
/// `AMAX1(-TADC*XHC1,-TADC,AMIN1(TADC,XCOO-XCOOQ))` once per MRXN cycle.
pub fn surfaceStep(
    hydrogen_activity_mol_per_m3: f64,
    parameters: SurfaceParameters,
    state: *State,
) !StepResult {
    inline for (@typeInfo(State).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(state.*, field.name)))
            return error.NonFiniteCarboxylProtonExchangeState;
    }
    inline for (@typeInfo(SurfaceParameters).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(parameters, field.name)))
            return error.NonFiniteCarboxylProtonExchangeParameter;
    }
    if (!std.math.isFinite(hydrogen_activity_mol_per_m3) or
        hydrogen_activity_mol_per_m3 <= 0 or
        state.total_carboxyl_sites_mol_per_megagram < 0 or
        state.protonated_carboxyl_sites_mol_per_megagram < 0 or
        state.protonated_carboxyl_sites_mol_per_megagram > state.total_carboxyl_sites_mol_per_megagram or
        parameters.minimum_unprotonated_sites_mol_per_megagram < 0 or
        parameters.carboxyl_dissociation_mol_per_m3 <= 0 or
        parameters.maximum_exchange_mol_per_megagram_iteration < 0)
        return error.InvalidCarboxylProtonExchangeInput;

    const unprotonated = @max(
        parameters.minimum_unprotonated_sites_mol_per_megagram,
        state.total_carboxyl_sites_mol_per_megagram -
            state.protonated_carboxyl_sites_mol_per_megagram,
    );
    const equilibrium_unprotonated = @min(
        state.total_carboxyl_sites_mol_per_megagram,
        parameters.carboxyl_dissociation_mol_per_m3 *
            state.protonated_carboxyl_sites_mol_per_megagram /
            hydrogen_activity_mol_per_m3,
    );
    const rate = @max(
        -parameters.maximum_exchange_mol_per_megagram_iteration *
            state.protonated_carboxyl_sites_mol_per_megagram,
        -parameters.maximum_exchange_mol_per_megagram_iteration,
        @min(
            parameters.maximum_exchange_mol_per_megagram_iteration,
            unprotonated - equilibrium_unprotonated,
        ),
    );
    const next_protonated = state.protonated_carboxyl_sites_mol_per_megagram + rate;
    inline for (.{ unprotonated, equilibrium_unprotonated, rate, next_protonated }) |value| {
        if (!std.math.isFinite(value))
            return error.NonFiniteCarboxylProtonExchangeResult;
    }
    if (next_protonated < 0 or
        next_protonated > state.total_carboxyl_sites_mol_per_megagram)
        return error.InvalidCarboxylProtonExchangeResult;
    state.protonated_carboxyl_sites_mol_per_megagram = next_protonated;
    return .{
        .protonation_rate_mol_per_megagram_iteration = rate,
        .diagnostics = .{
            .substrate_limit_mol_per_megagram_iteration = 0,
            .unprotonated_carboxyl_sites_mol_per_megagram = unprotonated,
            .equilibrium_unprotonated_sites_mol_per_megagram = equilibrium_unprotonated,
        },
    };
}

fn sourceParameters() Parameters {
    return .{
        .substrate_limit_fraction = 0.5,
        .minimum_unprotonated_sites_mol_per_megagram = 1.0e-48,
        .carboxyl_dissociation_mol_per_m3 = 1,
        .maximum_exchange_mol_per_megagram_iteration = 0.75,
    };
}

test "STARTE soil carboxyl exchange preserves bound order and state_updates rate" {
    var state: State = .{
        .total_carboxyl_sites_mol_per_megagram = 10,
        .protonated_carboxyl_sites_mol_per_megagram = 4,
    };
    const result = try step(.soil, 2, sourceParameters(), &state);
    try std.testing.expectEqual(@as(f64, 0.75), result.protonation_rate_mol_per_megagram_iteration);
    try std.testing.expectEqual(@as(f64, 1), result.diagnostics.?.substrate_limit_mol_per_megagram_iteration);
    try std.testing.expectEqual(@as(f64, 6), result.diagnostics.?.unprotonated_carboxyl_sites_mol_per_megagram);
    try std.testing.expectEqual(@as(f64, 2), result.diagnostics.?.equilibrium_unprotonated_sites_mol_per_megagram);
    try std.testing.expectEqual(@as(f64, 4.75), state.protonated_carboxyl_sites_mol_per_megagram);
}

test "STARTE non-soil carboxyl branch returns zero with dormant invalid state" {
    var state: State = .{
        .total_carboxyl_sites_mol_per_megagram = std.math.nan(f64),
        .protonated_carboxyl_sites_mol_per_megagram = std.math.nan(f64),
    };
    const result = try step(.irrigation, std.math.nan(f64), .{
        .substrate_limit_fraction = std.math.nan(f64),
        .minimum_unprotonated_sites_mol_per_megagram = std.math.nan(f64),
        .carboxyl_dissociation_mol_per_m3 = std.math.nan(f64),
        .maximum_exchange_mol_per_megagram_iteration = std.math.nan(f64),
    }, &state);
    try std.testing.expectEqual(@as(f64, 0), result.protonation_rate_mol_per_megagram_iteration);
    try std.testing.expect(result.diagnostics == null);
    try std.testing.expect(std.math.isNan(state.protonated_carboxyl_sites_mol_per_megagram));
}

test "STARTE soil carboxyl exchange rejects late invalid state atomically" {
    var state: State = .{
        .total_carboxyl_sites_mol_per_megagram = 10,
        .protonated_carboxyl_sites_mol_per_megagram = 11,
    };
    const before = state;
    try std.testing.expectError(
        error.InvalidCarboxylProtonExchangeInput,
        step(.soil, 2, sourceParameters(), &state),
    );
    try std.testing.expectEqualDeep(before, state);
}

test "STARTE surface carboxyl exchange preserves its distinct source bounds" {
    var state: State = .{
        .total_carboxyl_sites_mol_per_megagram = 50,
        .protonated_carboxyl_sites_mol_per_megagram = 5,
    };
    const result = try surfaceStep(0.01, .{
        .minimum_unprotonated_sites_mol_per_megagram = 1.0e-48,
        .carboxyl_dissociation_mol_per_m3 = 0.1,
        .maximum_exchange_mol_per_megagram_iteration = 0.01,
    }, &state);
    // XCOO-XCOOQ requests -5, while both source lower bounds are -0.01
    // and -0.05. AMAX1 therefore publishes exactly -0.01.
    try std.testing.expectEqual(
        @as(f64, -0.01),
        result.protonation_rate_mol_per_megagram_iteration,
    );
    try std.testing.expectEqual(@as(f64, 4.99), state.protonated_carboxyl_sites_mol_per_megagram);
}
