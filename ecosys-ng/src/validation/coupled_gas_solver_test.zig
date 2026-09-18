//! Tests for `coupled_gas_solver.zig`.
//!
//! Extracted verbatim so the module beside it contains only the model
//! code. Tests that use private declarations of that module stay there,
//! since a sibling file can only reach `pub` declarations.

const atmosphere = @import("../soil/gas/atmosphere_exchange.zig");
const gas = @import("../soil/gas/transport.zig");
const numerics = @import("../core/numerics.zig");
const std = @import("std");
const coupled_gas_solver = @import("../soil/gas/coupled_gas_solver.zig");
test "coupled coupled_gas_solver.solve converges before NPH times NPG and conserves closed system" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.air_volume_m3[0] = 1;
    state.air_volume_m3[1] = 1;
    state.temperature_k[0] = 300;
    state.temperature_k[1] = 300;
    state.gaseous_mass_g[0] = 2;
    state.dissolved_mass_g[0] = 1;
    const n = 2 * gas.species_count;
    const conductance = [_]f64{0.01} ** gas.species_count;
    const water = [_]f64{ 1, 1 };
    const no_band_water = [_]f64{ 0, 0 };
    const solubility = [_]f64{1} ** n;
    const exchange = [_]f64{0.1} ** n;
    const no_exchange = [_]f64{0} ** n;
    const no_bubbling = [_]bool{ false, false };
    var accepted_face_flux_g = [_]f64{0} ** gas.species_count;
    const result = try coupled_gas_solver.solve(std.testing.allocator, &state, .{ .faces = &[_]gas.Face{.{ .first_cell = 0, .second_cell = 1 }}, .face_conductance_m3_per_step = &conductance, .atmospheric_boundaries = &.{}, .water_volume_m3 = &water, .band_water_volume_m3 = &no_band_water, .mass_solubility_ratio = &solubility, .gas_water_exchange_rate_per_step = &exchange, .band_gas_water_exchange_rate_per_step = &no_exchange, .bubbling_enabled = &no_bubbling, .face_flux_g_by_component = &accepted_face_flux_g }, .{ .max_iterations = 80 });
    try std.testing.expect(result.iterations < 80);
    try std.testing.expect(accepted_face_flux_g[0] > 0);
    var total: f64 = 0;
    for (state.gaseous_mass_g, state.dissolved_mass_g, state.band_dissolved_mass_g) |gaseous, dissolved, band| total += gaseous + dissolved + band;
    try std.testing.expectApproxEqAbs(@as(f64, 3), total, 1e-10);
}

test "dimensionless dense Newton resolves gram gas beside hundred-megagram dissolved pools" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.air_volume_m3[0] = 1;
    state.temperature_k[0] = 300;
    const oxygen = @intFromEnum(gas.Species.oxygen);
    const nitrogen = @intFromEnum(gas.Species.nitrogen);
    state.gaseous_mass_g[oxygen] = 2;
    state.dissolved_mass_g[oxygen] = 1.0e8;
    state.gaseous_mass_g[nitrogen] = 1.8;
    state.dissolved_mass_g[nitrogen] = 1.36e8;
    const initial_oxygen_g =
        state.gaseous_mass_g[oxygen] + state.dissolved_mass_g[oxygen];
    const initial_nitrogen_g =
        state.gaseous_mass_g[nitrogen] + state.dissolved_mass_g[nitrogen];
    const water = [_]f64{1.0e8};
    const no_band_water = [_]f64{0};
    const solubility = [_]f64{1} ** gas.species_count;
    const exchange = [_]f64{1} ** gas.species_count;
    const no_exchange = [_]f64{0} ** gas.species_count;
    const no_bubbling = [_]bool{false};
    const result = try coupled_gas_solver.solve(
        std.testing.allocator,
        &state,
        .{
            .faces = &.{},
            .face_conductance_m3_per_step = &.{},
            .atmospheric_boundaries = &.{},
            .water_volume_m3 = &water,
            .band_water_volume_m3 = &no_band_water,
            .mass_solubility_ratio = &solubility,
            .gas_water_exchange_rate_per_step = &exchange,
            .band_gas_water_exchange_rate_per_step = &no_exchange,
            .bubbling_enabled = &no_bubbling,
        },
        .{
            .absolute_tolerance_g = 1.0e-11,
            .relative_tolerance = 1.0e-8,
            .max_iterations = 80,
        },
    );
    try std.testing.expect(result.iterations < 80);
    try std.testing.expectApproxEqAbs(
        initial_oxygen_g,
        state.gaseous_mass_g[oxygen] + state.dissolved_mass_g[oxygen],
        1.0e-7,
    );
    try std.testing.expectApproxEqAbs(
        initial_nitrogen_g,
        state.gaseous_mass_g[nitrogen] + state.dissolved_mass_g[nitrogen],
        1.0e-7,
    );
}

test "scale-separated face converges two pressure-coupled donor species conservatively" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(state.air_volume_m3, 1);
    @memset(state.temperature_k, 300);
    const carbon_dioxide = @intFromEnum(gas.Species.carbon_dioxide);
    const methane = @intFromEnum(gas.Species.methane);
    state.gaseous_mass_g[carbon_dioxide] = 1;
    state.gaseous_mass_g[methane] = 2;
    state.gaseous_mass_g[gas.species_count + carbon_dioxide] = 1.0e8;
    state.gaseous_mass_g[gas.species_count + methane] = 2.0e8;
    const initial_carbon_dioxide =
        state.gaseous_mass_g[carbon_dioxide] +
        state.gaseous_mass_g[gas.species_count + carbon_dioxide];
    const initial_methane =
        state.gaseous_mass_g[methane] +
        state.gaseous_mass_g[gas.species_count + methane];
    var conductance = [_]f64{0} ** gas.species_count;
    conductance[carbon_dioxide] = 1.0e-9;
    conductance[methane] = 1.0e-9;
    const n = 2 * gas.species_count;
    const zero_water = [_]f64{ 0, 0 };
    const solubility = [_]f64{1} ** n;
    const no_exchange = [_]f64{0} ** n;
    const no_bubbling = [_]bool{ false, false };
    const result = try coupled_gas_solver.solve(
        std.testing.allocator,
        &state,
        .{
            .faces = &.{.{
                .first_cell = 0,
                .second_cell = 1,
            }},
            .face_conductance_m3_per_step = &conductance,
            .atmospheric_boundaries = &.{},
            .water_volume_m3 = &zero_water,
            .band_water_volume_m3 = &zero_water,
            .mass_solubility_ratio = &solubility,
            .gas_water_exchange_rate_per_step = &no_exchange,
            .band_gas_water_exchange_rate_per_step = &no_exchange,
            .bubbling_enabled = &no_bubbling,
        },
        .{ .max_iterations = 80 },
    );
    try std.testing.expect(result.iterations < 80);
    try std.testing.expectApproxEqAbs(
        initial_carbon_dioxide,
        state.gaseous_mass_g[carbon_dioxide] +
            state.gaseous_mass_g[gas.species_count + carbon_dioxide],
        1.0e-7,
    );
    try std.testing.expectApproxEqAbs(
        initial_methane,
        state.gaseous_mass_g[methane] +
            state.gaseous_mass_g[gas.species_count + methane],
        1.0e-7,
    );
}

test "scale-separated face closes a sub-inventory oxygen residual conservatively" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(state.air_volume_m3, 1);
    @memset(state.temperature_k, 300);
    const oxygen = @intFromEnum(gas.Species.oxygen);
    state.gaseous_mass_g[oxygen] = 2.9218919364755397e-1;
    state.gaseous_mass_g[gas.species_count + oxygen] =
        4.596233521006912e7;
    const initial_oxygen_g =
        state.gaseous_mass_g[oxygen] +
        state.gaseous_mass_g[gas.species_count + oxygen];
    var conductance = [_]f64{0} ** gas.species_count;
    conductance[oxygen] = 5.165116406442861e-12;
    const n = 2 * gas.species_count;
    const zero_water = [_]f64{ 0, 0 };
    const solubility = [_]f64{1} ** n;
    const no_exchange = [_]f64{0} ** n;
    const no_bubbling = [_]bool{ false, false };
    const result = try coupled_gas_solver.solve(
        std.testing.allocator,
        &state,
        .{
            .faces = &.{.{
                .first_cell = 0,
                .second_cell = 1,
            }},
            .face_conductance_m3_per_step = &conductance,
            .atmospheric_boundaries = &.{},
            .water_volume_m3 = &zero_water,
            .band_water_volume_m3 = &zero_water,
            .mass_solubility_ratio = &solubility,
            .gas_water_exchange_rate_per_step = &no_exchange,
            .band_gas_water_exchange_rate_per_step = &no_exchange,
            .bubbling_enabled = &no_bubbling,
        },
        .{
            .absolute_tolerance_g = 1.0e-12,
            .relative_tolerance = 1.0e-8,
            .max_iterations = 80,
        },
    );
    try std.testing.expect(result.iterations < 80);
    try std.testing.expectApproxEqAbs(
        initial_oxygen_g,
        state.gaseous_mass_g[oxygen] +
            state.gaseous_mass_g[gas.species_count + oxygen],
        1.0e-8,
    );
}

test "six-cell pressure-coupled gaseous manifold converges within the hard ceiling" {
    var state = try gas.State.init(std.testing.allocator, 6);
    defer state.deinit();
    @memset(state.air_volume_m3, 1);
    @memset(state.temperature_k, 300);

    const carbon_dioxide = @intFromEnum(gas.Species.carbon_dioxide);
    const nitrogen = @intFromEnum(gas.Species.nitrogen);
    const carbon_profile = [_]f64{ 2.2, 3.3, 11.0, 3.38, 3.37, 3.38 };
    const nitrogen_profile = [_]f64{ 1.1, 4.8, 2.0, 5.6, 2.4, 4.1 };
    for (carbon_profile, nitrogen_profile, 0..) |carbon, nitrogen_mass, cell| {
        const start = cell * gas.species_count;
        state.gaseous_mass_g[start + carbon_dioxide] = carbon;
        state.gaseous_mass_g[start + nitrogen] = nitrogen_mass;
    }
    var initial_total_g: f64 = 0;
    for (state.gaseous_mass_g) |mass| initial_total_g += mass;

    var conductance = [_]f64{0} ** (5 * gas.species_count);
    const face_conductances = [_]f64{ 0.2716, 0.1047, 0.0785, 0.0784, 0.0783 };
    for (face_conductances, 0..) |face_conductance, face| {
        conductance[face * gas.species_count + carbon_dioxide] = face_conductance;
        conductance[face * gas.species_count + nitrogen] = face_conductance;
    }
    const faces = [_]gas.Face{
        .{ .first_cell = 0, .second_cell = 1 },
        .{ .first_cell = 1, .second_cell = 2 },
        .{ .first_cell = 2, .second_cell = 3 },
        .{ .first_cell = 3, .second_cell = 4 },
        .{ .first_cell = 4, .second_cell = 5 },
    };
    const water = [_]f64{0} ** 6;
    const n = 6 * gas.species_count;
    const solubility = [_]f64{1} ** n;
    const no_exchange = [_]f64{0} ** n;
    const no_bubbling = [_]bool{false} ** 6;
    var accepted_face_flux_g = [_]f64{0} ** (5 * gas.species_count);

    const result = try coupled_gas_solver.solve(
        std.testing.allocator,
        &state,
        .{
            .faces = &faces,
            .face_conductance_m3_per_step = &conductance,
            .atmospheric_boundaries = &.{},
            .water_volume_m3 = &water,
            .band_water_volume_m3 = &water,
            .mass_solubility_ratio = &solubility,
            .gas_water_exchange_rate_per_step = &no_exchange,
            .band_gas_water_exchange_rate_per_step = &no_exchange,
            .bubbling_enabled = &no_bubbling,
            .face_flux_g_by_component = &accepted_face_flux_g,
        },
        .{ .max_iterations = 100 },
    );
    try std.testing.expect(result.iterations < 100);
    for (state.gaseous_mass_g, state.dissolved_mass_g, state.band_dissolved_mass_g) |gaseous, dissolved, band| {
        try std.testing.expect(gaseous >= 0);
        try std.testing.expect(dissolved >= 0);
        try std.testing.expect(band >= 0);
    }
    var final_total_g: f64 = 0;
    for (state.gaseous_mass_g, state.dissolved_mass_g, state.band_dissolved_mass_g) |gaseous, dissolved, band| {
        final_total_g += gaseous + dissolved + band;
    }
    try std.testing.expectApproxEqAbs(initial_total_g, final_total_g, 1e-10);
    try std.testing.expect(accepted_face_flux_g[carbon_dioxide] != 0);
    try std.testing.expect(accepted_face_flux_g[nitrogen] != 0);
}

test "low-air receiver releases a pressure-coupled zero gas bound within the hard ceiling" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.air_volume_m3[0] = 1.5e-2;
    state.air_volume_m3[1] = 5.5e-4;
    @memset(state.temperature_k, 300);
    const nitrous_oxide = @intFromEnum(gas.Species.nitrous_oxide);
    state.gaseous_mass_g[nitrous_oxide] = 51;
    const initial_total_g = state.gaseous_mass_g[nitrous_oxide];
    var conductance = [_]f64{0} ** gas.species_count;
    conductance[nitrous_oxide] = 3.1e-7;
    const water = [_]f64{ 0, 0 };
    const n = 2 * gas.species_count;
    const solubility = [_]f64{1} ** n;
    const no_exchange = [_]f64{0} ** n;
    const no_bubbling = [_]bool{ false, false };
    var face_flux = [_]f64{0} ** gas.species_count;
    const result = try coupled_gas_solver.solve(
        std.testing.allocator,
        &state,
        .{
            .faces = &.{.{
                .first_cell = 0,
                .second_cell = 1,
            }},
            .face_conductance_m3_per_step = &conductance,
            .atmospheric_boundaries = &.{},
            .water_volume_m3 = &water,
            .band_water_volume_m3 = &water,
            .mass_solubility_ratio = &solubility,
            .gas_water_exchange_rate_per_step = &no_exchange,
            .band_gas_water_exchange_rate_per_step = &no_exchange,
            .bubbling_enabled = &no_bubbling,
            .face_flux_g_by_component = &face_flux,
        },
        .{ .max_iterations = 100 },
    );
    try std.testing.expect(result.iterations < 100);
    try std.testing.expect(state.gaseous_mass_g[gas.species_count + nitrous_oxide] > 0);
    try std.testing.expect(face_flux[nitrous_oxide] > 0);
    try std.testing.expectApproxEqAbs(
        initial_total_g,
        state.gaseous_mass_g[nitrous_oxide] +
            state.gaseous_mass_g[gas.species_count + nitrous_oxide],
        1e-10,
    );
}

test "low-air aqueous release activates a zero gas bound conservatively" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.air_volume_m3[0] = 7.812971757631404e-5;
    state.temperature_k[0] = 300;
    const nitrogen = @intFromEnum(gas.Species.nitrogen);
    state.dissolved_mass_g[nitrogen] = 5.352569637558869;
    const initial_total_g = state.dissolved_mass_g[nitrogen];
    const water = [_]f64{0.1};
    const no_band_water = [_]f64{0};
    const solubility = [_]f64{1} ** gas.species_count;
    const exchange = [_]f64{1} ** gas.species_count;
    const no_exchange = [_]f64{0} ** gas.species_count;
    const no_bubbling = [_]bool{false};
    const result = try coupled_gas_solver.solve(
        std.testing.allocator,
        &state,
        .{
            .faces = &.{},
            .face_conductance_m3_per_step = &.{},
            .atmospheric_boundaries = &.{},
            .water_volume_m3 = &water,
            .band_water_volume_m3 = &no_band_water,
            .mass_solubility_ratio = &solubility,
            .gas_water_exchange_rate_per_step = &exchange,
            .band_gas_water_exchange_rate_per_step = &no_exchange,
            .bubbling_enabled = &no_bubbling,
        },
        .{ .max_iterations = 100 },
    );
    try std.testing.expect(result.iterations < 100);
    try std.testing.expect(state.gaseous_mass_g[nitrogen] > 0);
    try std.testing.expectApproxEqAbs(
        initial_total_g,
        state.gaseous_mass_g[nitrogen] + state.dissolved_mass_g[nitrogen],
        1e-10,
    );
}

test "simultaneous atmospheric sources release every zero-inventory bound" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(state.air_volume_m3, 1);
    @memset(state.temperature_k, 300);
    const oxygen = @intFromEnum(gas.Species.oxygen);
    var external = [_]f64{0} ** gas.species_count;
    external[oxygen] = 0.01;
    const conductance = [_]f64{0.1} ** gas.species_count;
    const boundaries = [_]atmosphere.Boundary{
        .{ .cell_index = 0, .aerodynamic_conductance_m3_per_step = 0.1, .interior_conductance_m3_per_step = conductance, .atmospheric_concentration_g_per_m3 = external },
        .{ .cell_index = 1, .aerodynamic_conductance_m3_per_step = 0.1, .interior_conductance_m3_per_step = conductance, .atmospheric_concentration_g_per_m3 = external },
    };
    const n = 2 * gas.species_count;
    const water = [_]f64{ 0, 0 };
    const solubility = [_]f64{1} ** n;
    const no_exchange = [_]f64{0} ** n;
    const no_bubbling = [_]bool{ false, false };
    const result = try coupled_gas_solver.solve(std.testing.allocator, &state, .{
        .faces = &.{},
        .face_conductance_m3_per_step = &.{},
        .atmospheric_boundaries = &boundaries,
        .water_volume_m3 = &water,
        .band_water_volume_m3 = &water,
        .mass_solubility_ratio = &solubility,
        .gas_water_exchange_rate_per_step = &no_exchange,
        .band_gas_water_exchange_rate_per_step = &no_exchange,
        .bubbling_enabled = &no_bubbling,
    }, .{ .max_iterations = 80 });
    try std.testing.expect(result.iterations < 80);
    try std.testing.expect(state.gaseous_mass_g[oxygen] > 0);
    try std.testing.expect(state.gaseous_mass_g[gas.species_count + oxygen] > 0);
}

test "surface and subsurface boundary fluxes remain independently classified" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.air_volume_m3[0] = 1;
    state.temperature_k[0] = 300;
    const carbon_dioxide = @intFromEnum(gas.Species.carbon_dioxide);
    // Ideal-capacity inventory suppresses the pressure correction so this
    // test isolates the two boundary ledgers.
    state.gaseous_mass_g[carbon_dioxide] = 1.2194e4 / 300.0 * 12.0;
    const initial_mass_g = state.gaseous_mass_g[carbon_dioxide];
    var high_external = [_]f64{0} ** gas.species_count;
    high_external[carbon_dioxide] = initial_mass_g + 1;
    const zero_external = [_]f64{0} ** gas.species_count;
    const conductance = [_]f64{0.1} ** gas.species_count;
    const surface = atmosphere.Boundary{
        .cell_index = 0,
        .aerodynamic_conductance_m3_per_step = 0.1,
        .interior_conductance_m3_per_step = conductance,
        .atmospheric_concentration_g_per_m3 = high_external,
    };
    const subsurface = atmosphere.Boundary{
        .cell_index = 0,
        .aerodynamic_conductance_m3_per_step = 0.1,
        .interior_conductance_m3_per_step = conductance,
        .atmospheric_concentration_g_per_m3 = zero_external,
    };
    const n = gas.species_count;
    const water = [_]f64{0};
    const solubility = [_]f64{1} ** n;
    const no_exchange = [_]f64{0} ** n;
    const no_bubbling = [_]bool{false};
    var surface_flux = [_]f64{0} ** n;
    var subsurface_flux = [_]f64{0} ** n;
    _ = try coupled_gas_solver.solve(std.testing.allocator, &state, .{
        .faces = &.{},
        .face_conductance_m3_per_step = &.{},
        .atmospheric_boundaries = &.{surface},
        .subsurface_boundaries = &.{subsurface},
        .water_volume_m3 = &water,
        .band_water_volume_m3 = &water,
        .mass_solubility_ratio = &solubility,
        .gas_water_exchange_rate_per_step = &no_exchange,
        .band_gas_water_exchange_rate_per_step = &no_exchange,
        .bubbling_enabled = &no_bubbling,
        .atmospheric_flux_g_by_component = &surface_flux,
        .subsurface_flux_g_by_component = &subsurface_flux,
    }, .{ .max_iterations = 80 });
    try std.testing.expect(surface_flux[carbon_dioxide] > 0);
    try std.testing.expect(subsurface_flux[carbon_dioxide] < 0);
    try std.testing.expectApproxEqAbs(
        initial_mass_g + surface_flux[carbon_dioxide] + subsurface_flux[carbon_dioxide],
        state.gaseous_mass_g[carbon_dioxide],
        1e-9,
    );
}

test "TRNSFRS bubbling transfers dissolved mass to the REDIST release layer" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(state.air_volume_m3, 1);
    @memset(state.temperature_k, 300);
    const carbon_dioxide = @intFromEnum(gas.Species.carbon_dioxide);
    const source = gas.species_count + carbon_dioxide;
    state.dissolved_mass_g[source] = 600;
    const initial_total_g = state.dissolved_mass_g[source];
    const n = 2 * gas.species_count;
    const water = [_]f64{ 1, 1 };
    const no_band_water = [_]f64{ 0, 0 };
    const solubility = [_]f64{1} ** n;
    const no_exchange = [_]f64{0} ** n;
    const bubbling = [_]bool{ false, true };
    const receivers = [_]?usize{ 0, 0 };
    _ = try coupled_gas_solver.solve(std.testing.allocator, &state, .{
        .faces = &.{},
        .face_conductance_m3_per_step = &.{},
        .atmospheric_boundaries = &.{},
        .water_volume_m3 = &water,
        .band_water_volume_m3 = &no_band_water,
        .mass_solubility_ratio = &solubility,
        .gas_water_exchange_rate_per_step = &no_exchange,
        .band_gas_water_exchange_rate_per_step = &no_exchange,
        .bubbling_enabled = &bubbling,
        .bubble_receiver_cell_by_cell = &receivers,
    }, .{ .max_iterations = 200 });
    try std.testing.expect(state.gaseous_mass_g[carbon_dioxide] > 0);
    try std.testing.expectApproxEqAbs(
        initial_total_g,
        state.gaseous_mass_g[carbon_dioxide] + state.dissolved_mass_g[source],
        1e-9,
    );
}

test "bubble without a gas release layer is published as a boundary loss" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.air_volume_m3[0] = 1;
    state.temperature_k[0] = 300;
    const carbon_dioxide = @intFromEnum(gas.Species.carbon_dioxide);
    state.dissolved_mass_g[carbon_dioxide] = 600;
    const initial_total_g = state.dissolved_mass_g[carbon_dioxide];
    const water = [_]f64{1};
    const no_band_water = [_]f64{0};
    const solubility = [_]f64{1} ** gas.species_count;
    const no_exchange = [_]f64{0} ** gas.species_count;
    const bubbling = [_]bool{true};
    const receivers = [_]?usize{null};
    // `redist.f:6541-6549` is the oracle for the missing release layer: on the
    // `LG.EQ.0` branch the bubble flux enters CIB/CHB/OIB/ZGB/Z2B/ZHB/HGB, the
    // same accumulators the atmospheric boundary fluxes use, and from there
    // CO2GIN/HCO2G/UCO2G/XCNET. It is surface gas exchange, not profile
    // drainage, so the subsurface ledger must stay untouched. `X*BBL` is
    // `AMIN1(0.0, ...)` in `trnsfr.f:5842-5849`, so the published sign is a loss.
    var atmospheric_flux = [_]f64{0} ** gas.species_count;
    var subsurface_flux = [_]f64{0} ** gas.species_count;
    _ = try coupled_gas_solver.solve(std.testing.allocator, &state, .{
        .faces = &.{},
        .face_conductance_m3_per_step = &.{},
        .atmospheric_boundaries = &.{},
        .water_volume_m3 = &water,
        .band_water_volume_m3 = &no_band_water,
        .mass_solubility_ratio = &solubility,
        .gas_water_exchange_rate_per_step = &no_exchange,
        .band_gas_water_exchange_rate_per_step = &no_exchange,
        .bubbling_enabled = &bubbling,
        .bubble_receiver_cell_by_cell = &receivers,
        .atmospheric_flux_g_by_component = &atmospheric_flux,
        .subsurface_flux_g_by_component = &subsurface_flux,
    }, .{ .max_iterations = 200 });
    try std.testing.expect(atmospheric_flux[carbon_dioxide] < 0);
    try std.testing.expectApproxEqAbs(
        initial_total_g + atmospheric_flux[carbon_dioxide],
        state.dissolved_mass_g[carbon_dioxide],
        1e-9,
    );
    // No receiver layer exists, so nothing may reach the gaseous phase either.
    try std.testing.expectEqual(@as(f64, 0), state.gaseous_mass_g[carbon_dioxide]);
    for (subsurface_flux) |flux| try std.testing.expectEqual(@as(f64, 0), flux);
}

test "failed coupled coupled_gas_solver.solve rolls back all three phases" {
    // The non-convergence this fixture requires is structural, not a tuned
    // tolerance. `max_iterations = 1` grants a single counted slot, and the
    // solver's mandatory Newton -> Anderson -> Newton-retry ordering needs at
    // least three, so the one slot may hold at most one Newton update
    // (`coupled_gas_solver_solve.zig` returns
    // `CoupledGasSolverDidNotConverge` the moment the final slot is reached
    // before Anderson). The residual below is deliberately *not* affine --
    // multi-species pressure displacement allocates the bulk molar correction
    // by resident mole fraction, bubbling redistributes the supersaturated
    // aqueous mixture by the same rational weighting, and both the face and
    // the phase-exchange donors carry active inventory bounds -- so a single
    // exact Newton step cannot land on the fixed point. An affine fixture
    // (one boundary species, empty inventory, no face, no bubbling) is solved
    // exactly in one Newton step and no longer fails at all; that is why this
    // fixture carries a genuinely nonlinear map instead.
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(state.air_volume_m3, 1);
    @memset(state.temperature_k, 300);
    const carbon_dioxide = @intFromEnum(gas.Species.carbon_dioxide);
    const methane = @intFromEnum(gas.Species.methane);
    const oxygen = @intFromEnum(gas.Species.oxygen);
    const nitrogen = @intFromEnum(gas.Species.nitrogen);
    const ammonia = @intFromEnum(gas.Species.ammonia);
    const n = 2 * gas.species_count;
    // Every phase holds inventory, so the rollback comparison below is a real
    // comparison of a restored state rather than a comparison of zeros.
    state.gaseous_mass_g[carbon_dioxide] = 3;
    state.gaseous_mass_g[oxygen] = 12;
    state.gaseous_mass_g[gas.species_count + methane] = 7;
    state.gaseous_mass_g[gas.species_count + nitrogen] = 5;
    // Aqueous mixtures above the ideal-gas carrier capacity, so bubbling is
    // active in both cells: 150/12 mol exceeds 1.2194e4 * 0.2 / 300 mol and
    // 200/12 mol exceeds 1.2194e4 * 0.3 / 300 mol.
    state.dissolved_mass_g[carbon_dioxide] = 150;
    state.dissolved_mass_g[oxygen] = 9;
    state.dissolved_mass_g[gas.species_count + methane] = 200;
    state.band_dissolved_mass_g[ammonia] = 4;
    state.band_dissolved_mass_g[gas.species_count + ammonia] = 6;
    var before_gaseous: [n]f64 = undefined;
    var before_dissolved: [n]f64 = undefined;
    var before_band: [n]f64 = undefined;
    @memcpy(&before_gaseous, state.gaseous_mass_g);
    @memcpy(&before_dissolved, state.dissolved_mass_g);
    @memcpy(&before_band, state.band_dissolved_mass_g);

    var external = [_]f64{0} ** gas.species_count;
    external[oxygen] = 0.28;
    external[carbon_dioxide] = 2.0e-4;
    external[nitrogen] = 0.92;
    const conductance = [_]f64{0.1} ** gas.species_count;
    const boundaries = [_]atmosphere.Boundary{
        .{ .cell_index = 0, .aerodynamic_conductance_m3_per_step = 0.1, .interior_conductance_m3_per_step = conductance, .atmospheric_concentration_g_per_m3 = external },
        .{ .cell_index = 1, .aerodynamic_conductance_m3_per_step = 0.1, .interior_conductance_m3_per_step = conductance, .atmospheric_concentration_g_per_m3 = external },
    };
    const faces = [_]gas.Face{.{ .first_cell = 0, .second_cell = 1 }};
    const face_conductance = [_]f64{0.05} ** gas.species_count;
    const water = [_]f64{ 0.2, 0.3 };
    const band_water = [_]f64{ 0.05, 0.1 };
    const solubility = [_]f64{1} ** n;
    const exchange = [_]f64{0.3} ** n;
    const band_exchange = [_]f64{0.2} ** n;
    const bubbling = [_]bool{true} ** 2;
    const receivers = [_]?usize{ 0, 0 };
    var atmospheric_ledger = [_]f64{7} ** n;
    var subsurface_ledger = [_]f64{8} ** n;
    try std.testing.expectError(
        error.CoupledGasSolverDidNotConverge,
        coupled_gas_solver.solve(std.testing.allocator, &state, .{
            .faces = &faces,
            .face_conductance_m3_per_step = &face_conductance,
            .atmospheric_boundaries = &boundaries,
            .water_volume_m3 = &water,
            .band_water_volume_m3 = &band_water,
            .mass_solubility_ratio = &solubility,
            .gas_water_exchange_rate_per_step = &exchange,
            .band_gas_water_exchange_rate_per_step = &band_exchange,
            .bubbling_enabled = &bubbling,
            .bubble_receiver_cell_by_cell = &receivers,
            .atmospheric_flux_g_by_component = &atmospheric_ledger,
            .subsurface_flux_g_by_component = &subsurface_ledger,
        }, .{
            .absolute_tolerance_g = 1e-14,
            .relative_tolerance = 1e-12,
            .max_iterations = 1,
        }),
    );
    try std.testing.expectEqualSlices(f64, &before_gaseous, state.gaseous_mass_g);
    try std.testing.expectEqualSlices(f64, &before_dissolved, state.dissolved_mass_g);
    try std.testing.expectEqualSlices(f64, &before_band, state.band_dissolved_mass_g);
    for (atmospheric_ledger, subsurface_ledger) |atmospheric_value, subsurface_value| {
        try std.testing.expectEqual(@as(f64, 7), atmospheric_value);
        try std.testing.expectEqual(@as(f64, 8), subsurface_value);
    }
}
