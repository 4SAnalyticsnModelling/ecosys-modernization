// **A8a DISPOSITION: superseded, and the citation below is wrong.**
//
// The doc comment cites hour1.f:223-230; that range is the solar-noon FERT block. The
// range matching these six fields one-to-one is hour1.f:207--214
// (TRNP/TLEP/TSHP/TGHP/TTRAN/HCNET). TRNP/TLEP/TSHP/TGHP are owned by
// plant_energy_state_update.refresh (src/plant/state_update/energy.zig:74, bound at
// src/ecosys_ng.zig:4987), which assigns rather than accumulates so a preceding zero
// pass is unobservable. TTRAN is owned by plant_water_state_update.refresh, which
// resets its own accumulators at src/plant/state_update/water.zig:105 immediately
// before summing. HCNET is owned by canopy_carbon_exchange.State.reset
// (src/canopy/photosynthesis/carbon_exchange.zig:32), already bound at the HOUR1 site
// src/ecosys_ng.zig:3620. Do not bind this module.
// hourly flux reset group of docs/traceability/plant_reset_unbound_family_disposition.md
const std = @import("std");

pub const State = struct {
    net_radiation_megajoules_by_species: []f64,
    latent_heat_megajoules_by_species: []f64,
    sensible_heat_megajoules_by_species: []f64,
    ground_heat_megajoules_by_species: []f64,
    transpiration_m3_by_species: []f64,
    net_canopy_carbon_g_c_by_species: []f64,
};

/// Exact runtime-species HOUR1 reset from hour1.f:223-230.
pub fn apply(state: *State, first_subhourly_iteration: bool) !bool {
    const count = state.net_radiation_megajoules_by_species.len;
    inline for (@typeInfo(State).@"struct".fields) |field| {
        const values = @field(state.*, field.name);
        if (values.len != count)
            return error.HourlyPlantFluxResetDimensionMismatch;
        for (values) |value|
            if (!std.math.isFinite(value))
                return error.NonFiniteHourlyPlantFluxState;
    }
    if (!first_subhourly_iteration) return false;
    inline for (@typeInfo(State).@"struct".fields) |field|
        @memset(@field(state.*, field.name), 0);
    return true;
}

fn exampleState(
    radiation: []f64,
    latent: []f64,
    sensible: []f64,
    ground: []f64,
    transpiration: []f64,
    carbon: []f64,
) State {
    return .{
        .net_radiation_megajoules_by_species = radiation,
        .latent_heat_megajoules_by_species = latent,
        .sensible_heat_megajoules_by_species = sensible,
        .ground_heat_megajoules_by_species = ground,
        .transpiration_m3_by_species = transpiration,
        .net_canopy_carbon_g_c_by_species = carbon,
    };
}

test "first subhour resets all fluxes for arbitrary runtime species" {
    var radiation = [_]f64{ 1, 2, 3, 4, 5, 6, 7 };
    var latent = radiation;
    var sensible = radiation;
    var ground = radiation;
    var transpiration = radiation;
    var carbon = radiation;
    var state = exampleState(
        &radiation,
        &latent,
        &sensible,
        &ground,
        &transpiration,
        &carbon,
    );
    try std.testing.expect(try apply(&state, true));
    inline for (@typeInfo(State).@"struct".fields) |field|
        for (@field(state, field.name)) |value|
            try std.testing.expectEqual(@as(f64, 0), value);
}

test "later nonlinear iterations retain plant flux accumulation" {
    var radiation = [_]f64{1};
    var latent = [_]f64{2};
    var sensible = [_]f64{3};
    var ground = [_]f64{4};
    var transpiration = [_]f64{5};
    var carbon = [_]f64{6};
    var state = exampleState(
        &radiation,
        &latent,
        &sensible,
        &ground,
        &transpiration,
        &carbon,
    );
    try std.testing.expect(!try apply(&state, false));
    try std.testing.expectEqual(@as(f64, 1), radiation[0]);
    try std.testing.expectEqual(@as(f64, 6), carbon[0]);
}

test "cell with zero plant species is a valid reset" {
    var radiation: [0]f64 = .{};
    var latent: [0]f64 = .{};
    var sensible: [0]f64 = .{};
    var ground: [0]f64 = .{};
    var transpiration: [0]f64 = .{};
    var carbon: [0]f64 = .{};
    var state = exampleState(
        &radiation,
        &latent,
        &sensible,
        &ground,
        &transpiration,
        &carbon,
    );
    try std.testing.expect(try apply(&state, true));
}

test "dimension mismatch leaves every runtime species ledger unchanged" {
    var radiation = [_]f64{ 1, 2 };
    var latent = [_]f64{2};
    var sensible = [_]f64{ 3, 4 };
    var ground = [_]f64{ 4, 5 };
    var transpiration = [_]f64{ 5, 6 };
    var carbon = [_]f64{ 6, 7 };
    var state = exampleState(
        &radiation,
        &latent,
        &sensible,
        &ground,
        &transpiration,
        &carbon,
    );
    try std.testing.expectError(
        error.HourlyPlantFluxResetDimensionMismatch,
        apply(&state, true),
    );
    try std.testing.expectEqual(@as(f64, 1), radiation[0]);
    try std.testing.expectEqual(@as(f64, 7), carbon[1]);
}

test "nonfinite late species leaves all plant ledgers unchanged" {
    var radiation = [_]f64{ 1, 2 };
    var latent = [_]f64{ 2, 3 };
    var sensible = [_]f64{ 3, 4 };
    var ground = [_]f64{ 4, 5 };
    var transpiration = [_]f64{ 5, 6 };
    var carbon = [_]f64{ 6, std.math.nan(f64) };
    var state = exampleState(
        &radiation,
        &latent,
        &sensible,
        &ground,
        &transpiration,
        &carbon,
    );
    try std.testing.expectError(
        error.NonFiniteHourlyPlantFluxState,
        apply(&state, true),
    );
    try std.testing.expectEqual(@as(f64, 1), radiation[0]);
    try std.testing.expect(std.math.isNan(carbon[1]));
}
