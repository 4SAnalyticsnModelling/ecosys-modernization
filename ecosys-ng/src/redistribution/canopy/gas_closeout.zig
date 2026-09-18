// **A8a DISPOSITION: BOUND; ATMOS-TKQ-001 is closed for gas closeout.**
//
// Exact translation of `redist.f:10991--11002`, verified line by line including
// the constants: `FMOLQ = 1.2194E+04/TKQ`, the `8.333E+04` coefficient on the CO2
// and CH4 legs against `3.125E+04` on the O2 leg, the `OXYC` canopy oxygen
// content at `1.429E-03*273.15/TKQ*ZT*AREA`, and the three cumulative exchange
// accumulations. This is the canopy gas drawdown: the atmospheric mixing ratio
// reduced by net ecosystem exchange acting across the aerodynamic boundary-layer
// resistance.
//
// `atmosphere/canopy_gas_state.zig` calls `closeCell` for every cell from its
// atomic `closeAcceptedHour`: TKQ/VPQ are blended first, all nine persisted
// carrier fields and cumulative ledgers are staged, and publication happens
// only after every cell validates. `ecosys_ng.zig` invokes that owner after all
// current-hour soil, litter, root, plant, and fire contributors are booked.
// HOUR1 then consumes the carried CO2Q/CH4Q/OXYQ and TKQ at the beginning of the
// following accepted hour, and checkpoints preserve the complete carrier.

const std = @import("std");

pub const Inputs = struct {
    cell_area_m2: []const f64, // AREA(3,NU)
    canopy_air_temperature_k: []const f64, // TKQ
    atmosphere_co2_umol_mol: []const f64, // CO2E
    atmosphere_ch4_umol_mol: []const f64, // CH4E
    atmosphere_o2_umol_mol: []const f64, // OXYE
    aerodynamic_resistance_h_m: []const f64, // RAB
    timestep_h: []const f64, // XNFH
    canopy_height_m: []const f64, // ZT
    co2_net_input_g_c_step: []const f64, // XCNET
    ch4_net_input_g_c_step: []const f64, // XHNET
    o2_net_input_g_o_step: []const f64, // XONET
};
pub const State = struct {
    canopy_co2_umol_mol: []f64, // CO2Q
    canopy_ch4_umol_mol: []f64, // CH4Q
    canopy_o2_umol_mol: []f64, // OXYQ
    canopy_oxygen_content_g_o: []f64, // OXYC
    cumulative_co2_exchange_g_c: []f64, // ZCNET
    cumulative_ch4_exchange_g_c: []f64, // ZHNET
    cumulative_o2_exchange_g_o: []f64, // ZONET
};
pub const Diagnostics = struct {
    co2_flux_g_c_m2_step: f64, // CNETX
    ch4_flux_g_c_m2_step: f64, // HNETX
    o2_flux_g_o_m2_step: f64, // ONETX
    canopy_air_molar_density_mol_m3: f64, // FMOLQ
};

fn finiteSlice(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

/// Direct translation of REDIST 10991--11002 for one runtime-indexed cell.
pub fn closeCell(cell: usize, inputs: Inputs, state: State) !Diagnostics {
    const cell_count = inputs.cell_area_m2.len;
    if (cell_count == 0 or cell >= cell_count) return error.CanopyGasCloseoutDimensionMismatch;
    inline for (std.meta.fields(Inputs)) |field|
        if (@field(inputs, field.name).len != cell_count) return error.CanopyGasCloseoutDimensionMismatch;
    inline for (std.meta.fields(State)) |field|
        if (@field(state, field.name).len != cell_count) return error.CanopyGasCloseoutDimensionMismatch;
    inline for (std.meta.fields(Inputs)) |field|
        if (!finiteSlice(@field(inputs, field.name))) return error.InvalidCanopyGasCloseoutInput;
    inline for (std.meta.fields(State)) |field|
        if (!finiteSlice(@field(state, field.name))) return error.InvalidCanopyGasCloseoutInput;
    if (inputs.cell_area_m2[cell] <= 0 or inputs.canopy_air_temperature_k[cell] <= 0 or
        inputs.timestep_h[cell] <= 0 or inputs.aerodynamic_resistance_h_m[cell] < 0 or
        inputs.canopy_height_m[cell] < 0 or inputs.atmosphere_co2_umol_mol[cell] < 0 or
        inputs.atmosphere_ch4_umol_mol[cell] < 0 or inputs.atmosphere_o2_umol_mol[cell] < 0)
        return error.InvalidCanopyGasCloseoutInput;

    const co2_flux = inputs.co2_net_input_g_c_step[cell] / inputs.cell_area_m2[cell];
    const ch4_flux = inputs.ch4_net_input_g_c_step[cell] / inputs.cell_area_m2[cell];
    const o2_flux = inputs.o2_net_input_g_o_step[cell] / inputs.cell_area_m2[cell];
    const molar_density = 1.2194e4 / inputs.canopy_air_temperature_k[cell];
    const next_co2 = inputs.atmosphere_co2_umol_mol[cell] - 8.333e4 * co2_flux / molar_density * inputs.aerodynamic_resistance_h_m[cell] / inputs.timestep_h[cell];
    const next_ch4 = inputs.atmosphere_ch4_umol_mol[cell] - 8.333e4 * ch4_flux / molar_density * inputs.aerodynamic_resistance_h_m[cell] / inputs.timestep_h[cell];
    const next_o2 = inputs.atmosphere_o2_umol_mol[cell] - 3.125e4 * o2_flux / molar_density * inputs.aerodynamic_resistance_h_m[cell] / inputs.timestep_h[cell];
    const next_oxygen_content = next_o2 * 1.429e-3 * 273.15 / inputs.canopy_air_temperature_k[cell] * inputs.canopy_height_m[cell] * inputs.cell_area_m2[cell];
    const next_cumulative_co2 = state.cumulative_co2_exchange_g_c[cell] + inputs.co2_net_input_g_c_step[cell];
    const next_cumulative_ch4 = state.cumulative_ch4_exchange_g_c[cell] + inputs.ch4_net_input_g_c_step[cell];
    const next_cumulative_o2 = state.cumulative_o2_exchange_g_o[cell] + inputs.o2_net_input_g_o_step[cell];
    inline for (.{ co2_flux, ch4_flux, o2_flux, molar_density, next_co2, next_ch4, next_o2, next_oxygen_content, next_cumulative_co2, next_cumulative_ch4, next_cumulative_o2 }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteCanopyGasCloseoutResult;
    if (next_co2 < 0 or next_ch4 < 0 or next_o2 < 0 or next_oxygen_content < 0)
        return error.InvalidCanopyGasConcentrationResult;

    state.canopy_co2_umol_mol[cell] = next_co2;
    state.canopy_ch4_umol_mol[cell] = next_ch4;
    state.canopy_o2_umol_mol[cell] = next_o2;
    state.canopy_oxygen_content_g_o[cell] = next_oxygen_content;
    state.cumulative_co2_exchange_g_c[cell] = next_cumulative_co2;
    state.cumulative_ch4_exchange_g_c[cell] = next_cumulative_ch4;
    state.cumulative_o2_exchange_g_o[cell] = next_cumulative_o2;
    return .{ .co2_flux_g_c_m2_step = co2_flux, .ch4_flux_g_c_m2_step = ch4_flux, .o2_flux_g_o_m2_step = o2_flux, .canopy_air_molar_density_mol_m3 = molar_density };
}

test "REDIST canopy gas closeout preserves conversions order and runtime cell" {
    const area = [_]f64{ 10, 20 };
    const temperature = [_]f64{ 300, 305 };
    const ambient_co2 = [_]f64{ 400, 410 };
    const ambient_ch4 = [_]f64{ 2, 3 };
    const ambient_o2 = [_]f64{ 210000, 209000 };
    const resistance = [_]f64{ 0.01, 0.02 };
    const timestep = [_]f64{ 1, 2 };
    const height = [_]f64{ 2, 3 };
    const co2_net = [_]f64{ 0.01, -0.02 };
    const ch4_net = [_]f64{ 0.001, -0.002 };
    const o2_net = [_]f64{ 0.02, 0.03 };
    var co2 = [_]f64{ 0, 0 };
    var ch4 = [_]f64{ 0, 0 };
    var o2 = [_]f64{ 0, 0 };
    var oxygen_content = [_]f64{ 0, 0 };
    var cumulative_co2 = [_]f64{ 1, 2 };
    var cumulative_ch4 = [_]f64{ 3, 4 };
    var cumulative_o2 = [_]f64{ 5, 6 };
    const result = try closeCell(1, .{ .cell_area_m2 = &area, .canopy_air_temperature_k = &temperature, .atmosphere_co2_umol_mol = &ambient_co2, .atmosphere_ch4_umol_mol = &ambient_ch4, .atmosphere_o2_umol_mol = &ambient_o2, .aerodynamic_resistance_h_m = &resistance, .timestep_h = &timestep, .canopy_height_m = &height, .co2_net_input_g_c_step = &co2_net, .ch4_net_input_g_c_step = &ch4_net, .o2_net_input_g_o_step = &o2_net }, .{ .canopy_co2_umol_mol = &co2, .canopy_ch4_umol_mol = &ch4, .canopy_o2_umol_mol = &o2, .canopy_oxygen_content_g_o = &oxygen_content, .cumulative_co2_exchange_g_c = &cumulative_co2, .cumulative_ch4_exchange_g_c = &cumulative_ch4, .cumulative_o2_exchange_g_o = &cumulative_o2 });
    const density = 1.2194e4 / 305.0;
    try std.testing.expectApproxEqAbs(-0.001, result.co2_flux_g_c_m2_step, 1e-15);
    try std.testing.expectApproxEqAbs(density, result.canopy_air_molar_density_mol_m3, 1e-12);
    try std.testing.expectApproxEqAbs(410 - 8.333e4 * -0.001 / density * 0.02 / 2.0, co2[1], 1e-12);
    try std.testing.expectEqual(@as(f64, 1.98), cumulative_co2[1]);
    try std.testing.expectEqual(@as(f64, 3.998), cumulative_ch4[1]);
    try std.testing.expectEqual(@as(f64, 6.03), cumulative_o2[1]);
    try std.testing.expectEqual(@as(f64, 0), co2[0]);
}

test "REDIST canopy gas invalid concentration result is atomic" {
    const one = [_]f64{1};
    const low = [_]f64{0.1};
    const high_flux = [_]f64{100};
    var concentration = [_]f64{7};
    var oxygen_content = [_]f64{8};
    var cumulative = [_]f64{9};
    try std.testing.expectError(error.InvalidCanopyGasConcentrationResult, closeCell(0, .{ .cell_area_m2 = &one, .canopy_air_temperature_k = &one, .atmosphere_co2_umol_mol = &low, .atmosphere_ch4_umol_mol = &low, .atmosphere_o2_umol_mol = &low, .aerodynamic_resistance_h_m = &one, .timestep_h = &one, .canopy_height_m = &one, .co2_net_input_g_c_step = &high_flux, .ch4_net_input_g_c_step = &high_flux, .o2_net_input_g_o_step = &high_flux }, .{ .canopy_co2_umol_mol = &concentration, .canopy_ch4_umol_mol = &concentration, .canopy_o2_umol_mol = &concentration, .canopy_oxygen_content_g_o = &oxygen_content, .cumulative_co2_exchange_g_c = &cumulative, .cumulative_ch4_exchange_g_c = &cumulative, .cumulative_o2_exchange_g_o = &cumulative }));
    try std.testing.expectEqual(@as(f64, 7), concentration[0]);
    try std.testing.expectEqual(@as(f64, 8), oxygen_content[0]);
    try std.testing.expectEqual(@as(f64, 9), cumulative[0]);
}
