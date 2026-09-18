// **A8a DISPOSITION: SUPERSEDED BY THE CORRECTED BOUND INITIALIZATION OWNER;
// SOIL-INITSAT-001 IS CLOSED.** After mapped hydrology and per-cell topology
// geometry are available, `driver/model_initialization.zig` applies the
// adjusted natural-water-table saturation to every active layer at/below its
// surface-relative midpoint. Production binds it before gas/chemistry phase
// initialization and tests domain-atomic validation and inactive-layer safety.
//
// **HISTORICAL A8a DISPOSITION: superseded on the sentinel ladder, but it exposes a real
// defect in the owner. Keep unbound.** `hour1.f:2131--2163` decodes the soil
// file's `THW`/`THI` codes into initial water and ice once, on the first hour of
// the first day of the initialization year. Production's owner is
// `soil/water/hydrology.zig`: `decodeWaterFraction:129--135` and
// `decodeIceFraction:137--144` reproduce the ladder term for term (`>1` porosity,
// `==1` field capacity, `==0` wilting point, `<0` zero, else pass through) with
// the same `AMAX1(0.0,AMIN1(...))` clamp of ice against the porosity left over
// after water, and `init:76--100` publishes the volumes and air space that
// `hour1.f:2154--2162` publishes. Supersession is by lifetime: the owner runs
// once at construction from the parsed profile, so the
// `I.EQ.IBEGIN.AND.J.EQ.1.AND.IYRC.EQ.IDATA(9)` guard this candidate carries as
// three booleans has no state to guard. The candidate's `.estimated` /
// `.supplied` `RetentionMode`, standing in for `DATA(20)`, likewise has no
// production analogue -- the owner always publishes.
//
// Do not bind it as a fix, and do not read this banner as saying production is
// correct. The owner drops the *second* term of both guards,
// `.OR.DPTH(L).GE.DTBLZ(NY,NX)`, which saturates any layer whose midpoint lies
// below the initial natural water table regardless of its code. `init` takes no
// water table argument at all. At Ottawa this is not vacuous: the table is at
// 1.0 m with zero surface slope, layer ten spans 0.80--1.30 m (midpoint 1.05 m)
// with water code `1`, so production starts it at field capacity 0.33 against a
// porosity of 0.511. Note the candidate reproduces the same defect in a
// different place -- it takes `water_table_depth_m` and tests
// `layer_depth_m >= water_table_depth_m` at `:46`/`:58`, but nothing supplies it.
// Filed as SOIL-INITSAT-001 in docs/discrepancy_register.md, which carries the
// magnitude, the reason the ice half agrees anyway, and the knock-on effect on
// `soil/profile/boundary_topology.zig:197`.

const std = @import("std");

pub const RetentionMode = enum {
    supplied,
    estimated,
};

pub const Inputs = struct {
    is_first_simulation_day: bool,
    is_first_hour: bool,
    is_initialization_year: bool,
    retention_mode: RetentionMode,
    water_initialization_code: f64,
    ice_initialization_code: f64,
    layer_depth_m: f64,
    water_table_depth_m: f64,
    porosity_m3_m3: f64,
    field_capacity_m3_m3: f64,
    wilting_point_m3_m3: f64,
    micropore_volume_m3: f64,
    macropore_volume_m3: f64,
    mineral_heat_capacity_megajoules_k: f64,
};

pub const State = struct {
    water_content_m3_m3: f64,
    ice_content_m3_m3: f64,
    micropore_water_m3: f64,
    previous_micropore_water_m3: f64,
    macropore_water_m3: f64,
    micropore_ice_m3: f64,
    macropore_ice_m3: f64,
    heat_capacity_megajoules_k: f64,
    previous_water_content_m3_m3: f64,
    previous_ice_content_m3_m3: f64,
};

/// `hour1.f` lines 2131--2163 for one runtime soil layer. Sentinel codes retain
/// source equality branches; codes strictly between zero and one preserve
/// the caller's existing concentration.
pub fn apply(inputs: Inputs, state: *State) !void {
    try validate(inputs, state.*);
    if (!(inputs.is_first_simulation_day and inputs.is_first_hour and
        inputs.is_initialization_year)) return;
    if (inputs.water_initialization_code > 1.0 or
        inputs.layer_depth_m >= inputs.water_table_depth_m)
        state.water_content_m3_m3 = inputs.porosity_m3_m3
    else if (inputs.water_initialization_code == 1.0)
        state.water_content_m3_m3 = inputs.field_capacity_m3_m3
    else if (inputs.water_initialization_code == 0.0)
        state.water_content_m3_m3 = inputs.wilting_point_m3_m3
    else if (inputs.water_initialization_code < 0.0)
        state.water_content_m3_m3 = 0.0;

    const remaining_porosity =
        inputs.porosity_m3_m3 - state.water_content_m3_m3;
    if (inputs.ice_initialization_code > 1.0 or
        inputs.layer_depth_m >= inputs.water_table_depth_m)
        state.ice_content_m3_m3 =
            @max(0.0, @min(inputs.porosity_m3_m3, remaining_porosity))
    else if (inputs.ice_initialization_code == 1.0)
        state.ice_content_m3_m3 =
            @max(0.0, @min(inputs.field_capacity_m3_m3, remaining_porosity))
    else if (inputs.ice_initialization_code == 0.0)
        state.ice_content_m3_m3 =
            @max(0.0, @min(inputs.wilting_point_m3_m3, remaining_porosity))
    else if (inputs.ice_initialization_code < 0.0)
        state.ice_content_m3_m3 = 0.0;

    if (inputs.retention_mode == .estimated) {
        state.micropore_water_m3 =
            state.water_content_m3_m3 * inputs.micropore_volume_m3;
        state.previous_micropore_water_m3 = state.micropore_water_m3;
        state.macropore_water_m3 =
            state.water_content_m3_m3 * inputs.macropore_volume_m3;
        state.micropore_ice_m3 =
            state.ice_content_m3_m3 * inputs.micropore_volume_m3;
        state.macropore_ice_m3 =
            state.ice_content_m3_m3 * inputs.macropore_volume_m3;
        state.heat_capacity_megajoules_k = inputs.mineral_heat_capacity_megajoules_k +
            4.19 * (state.micropore_water_m3 + state.macropore_water_m3) +
            1.9274 * (state.micropore_ice_m3 + state.macropore_ice_m3);
        state.previous_water_content_m3_m3 = state.water_content_m3_m3;
        state.previous_ice_content_m3_m3 = state.ice_content_m3_m3;
    }
}

fn validate(inputs: Inputs, state: State) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field|
        if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteSoilInitializationInput;
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (!std.math.isFinite(@field(state, field.name)))
            return error.NonFiniteSoilInitializationState;
    if (inputs.porosity_m3_m3 < 0 or inputs.field_capacity_m3_m3 < 0 or
        inputs.wilting_point_m3_m3 < 0 or inputs.micropore_volume_m3 < 0 or
        inputs.macropore_volume_m3 < 0 or inputs.mineral_heat_capacity_megajoules_k < 0)
        return error.InvalidSoilInitializationInput;
}

test "first-run codes initialize water then ice and publish volumes" {
    var state: State = std.mem.zeroes(State);
    try apply(.{
        .is_first_simulation_day = true,
        .is_first_hour = true,
        .is_initialization_year = true,
        .retention_mode = .estimated,
        .water_initialization_code = 1,
        .ice_initialization_code = 1,
        .layer_depth_m = 0.1,
        .water_table_depth_m = 1,
        .porosity_m3_m3 = 0.5,
        .field_capacity_m3_m3 = 0.3,
        .wilting_point_m3_m3 = 0.1,
        .micropore_volume_m3 = 2,
        .macropore_volume_m3 = 1,
        .mineral_heat_capacity_megajoules_k = 5,
    }, &state);
    try std.testing.expectEqual(@as(f64, 0.3), state.water_content_m3_m3);
    try std.testing.expectEqual(@as(f64, 0.2), state.ice_content_m3_m3);
    try std.testing.expectEqual(@as(f64, 0.6), state.micropore_water_m3);
    try std.testing.expectApproxEqAbs(
        @as(f64, 5 + 4.19 * 0.9 + 1.9274 * 0.6),
        state.heat_capacity_megajoules_k,
        1e-14,
    );
}

test "noninitial execution leaves state unchanged" {
    var state: State = std.mem.zeroes(State);
    state.water_content_m3_m3 = 0.42;
    try apply(.{
        .is_first_simulation_day = false,
        .is_first_hour = true,
        .is_initialization_year = true,
        .retention_mode = .estimated,
        .water_initialization_code = 1,
        .ice_initialization_code = 1,
        .layer_depth_m = 0,
        .water_table_depth_m = 1,
        .porosity_m3_m3 = 0.5,
        .field_capacity_m3_m3 = 0.3,
        .wilting_point_m3_m3 = 0.1,
        .micropore_volume_m3 = 1,
        .macropore_volume_m3 = 1,
        .mineral_heat_capacity_megajoules_k = 1,
    }, &state);
    try std.testing.expectEqual(@as(f64, 0.42), state.water_content_m3_m3);
}
