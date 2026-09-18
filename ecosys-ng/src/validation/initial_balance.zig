const std = @import("std");

/// Domain-integrated STARTS balance accumulators. Flux sign conventions are
/// retained from the source: input and output owners remain separate.
pub const State = struct {
    precipitation_input_m3: f64,
    heat_input_megajoules: f64,
    carbon_dioxide_input_g_c: f64,
    oxygen_input_g_o: f64,
    hydrogen_input_g_h: f64,
    nitrogen_input_g_n: f64,
    dinitrogen_input_g_n: f64,
    phosphorus_input_g_p: f64,
    organic_input_g_c: f64,
    organic_input_g_n: f64,
    organic_input_g_p: f64,
    water_output_m3: f64,
    evaporation_output_m3: f64,
    runoff_output_m3: f64,
    heat_output_megajoules: f64,
    oxygen_output_g_o: f64,
    hydrogen_output_g_h: f64,
    sediment_output_g: f64,
    carbon_output_g_c: f64,
    nitrogen_output_g_n: f64,
    phosphorus_output_g_p: f64,
    plant_carbon_sink_g_c: f64,
    plant_nitrogen_sink_g_n: f64,
    plant_phosphorus_sink_g_p: f64,
    salt_input_mol: f64,
    salt_output_mol: f64,
    sky_sine_sum: f64,
    silicate_surface_area_m2_per_m3: f64,
};

/// Exact source-order translation of legacy `STARTS` lines 104--131.
///
/// Initialization deliberately overwrites every field without inspecting the
/// preceding bytes; this is the owner that makes the state valid.
pub fn initialize(state: *State) void {
    state.precipitation_input_m3 = 0.0;
    state.heat_input_megajoules = 0.0;
    state.carbon_dioxide_input_g_c = 0.0;
    state.oxygen_input_g_o = 0.0;
    state.hydrogen_input_g_h = 0.0;
    state.nitrogen_input_g_n = 0.0;
    state.dinitrogen_input_g_n = 0.0;
    state.phosphorus_input_g_p = 0.0;
    state.organic_input_g_c = 0.0;
    state.organic_input_g_n = 0.0;
    state.organic_input_g_p = 0.0;
    state.water_output_m3 = 0.0;
    state.evaporation_output_m3 = 0.0;
    state.runoff_output_m3 = 0.0;
    state.heat_output_megajoules = 0.0;
    state.oxygen_output_g_o = 0.0;
    state.hydrogen_output_g_h = 0.0;
    state.sediment_output_g = 0.0;
    state.carbon_output_g_c = 0.0;
    state.nitrogen_output_g_n = 0.0;
    state.phosphorus_output_g_p = 0.0;
    state.plant_carbon_sink_g_c = 0.0;
    state.plant_nitrogen_sink_g_n = 0.0;
    state.plant_phosphorus_sink_g_p = 0.0;
    state.salt_input_mol = 0.0;
    state.salt_output_mol = 0.0;
    state.sky_sine_sum = 0.0;
    state.silicate_surface_area_m2_per_m3 = 0.0;
}

fn filled(value: f64) State {
    var state: State = undefined;
    inline for (@typeInfo(State).@"struct".fields) |field| {
        @field(state, field.name) = value;
    }
    return state;
}

test "STARTS initializes every balance field in lines 104 through 131" {
    var state = filled(7.0);
    initialize(&state);

    inline for (@typeInfo(State).@"struct".fields) |field| {
        try std.testing.expectEqual(@as(f64, 0.0), @field(state, field.name));
    }
}

test "initialization replaces invalid prior storage rather than propagating it" {
    var state = filled(std.math.nan(f64));
    initialize(&state);

    inline for (@typeInfo(State).@"struct".fields) |field| {
        try std.testing.expect(std.math.isFinite(@field(state, field.name)));
        try std.testing.expectEqual(@as(f64, 0.0), @field(state, field.name));
    }
}
