const std = @import("std");
const allocation = @import("soil/gas/oxygen_allocation.zig");
const SharedLayer = allocation.SharedLayer;
const Population = allocation.Population;
const State = allocation.State;
const solveLayer = allocation.solveLayer;

fn run(layer: *SharedLayer, state: *State) !void {
    var populations: [19]Population = undefined;
    for (&populations, 0..) |*population, index| population.* = .{
        .is_aerobic = index < 3,
        .previous_oxygen_demand_g_o = if (index < 3) 2e-11 else 0,
        .fallback_active_fraction = 1,
        .uptake_conductance_m3_per_step = 0.02,
        .oxygen_half_saturation_g_o_per_m3 = 0.1,
        .maximum_oxygen_uptake_g_o = 1e-13,
    };
    try solveLayer(state, 1, 2, layer, &populations, .{
        .minimum_allocation_fraction = 0.001,
        .negligible_demand_g_o = 1e-12,
    }, .{ .absolute_tolerance_g_o = 1e-12, .relative_tolerance = 1e-10, .derivative_floor = 1e-14, .picard_relaxation = 0.5, .gas_max_iterations = 80 });
}

test "prefix drift reproduction (HEAD, no fix)" {
    var state = try State.init(std.testing.allocator, 2, 3, 19);
    defer state.deinit();
    const cells = try std.testing.allocator.alloc(f64, 2);
    defer std.testing.allocator.free(cells);
    cells[0] = 3.39519326554e-313;
    cells[1] = 0.0;
    var layer: SharedLayer = .{ .gaseous_oxygen_g_o = cells[0], .aqueous_oxygen_g_o = cells[1], .gaseous_flux_g_o = 0, .aqueous_flux_g_o = 0, .water_volume_m3 = 2, .air_volume_m3 = 3, .oxygen_solubility_water_to_air = 0.03, .gas_exchange_rate_per_step = 0.5, .maximum_aqueous_oxygen_concentration_g_o_per_m3 = 1 };
    try run(&layer, &state);
    std.debug.print("prefix bits: g {x} -> {x} | a {x} -> {x}\n", .{ @as(u64, @bitCast(cells[0])), @as(u64, @bitCast(layer.gaseous_oxygen_g_o)), @as(u64, @bitCast(cells[1])), @as(u64, @bitCast(layer.aqueous_oxygen_g_o)) });
    const baseb: usize = (1 * 3 + 2) * 19;
    std.debug.print("prefix fracs: {{x}}... {{x}}", .{});
    std.debug.print(" {x} {x} {x} upt {{..}}\n", .{ @as(u64, @bitCast(state.allocation_fraction[baseb])), @as(u64, @bitCast(state.allocation_fraction[baseb + 1])), @as(u64, @bitCast(state.allocation_fraction[baseb + 2])) });
    try std.testing.expectEqual(cells[0], layer.gaseous_oxygen_g_o);
    try std.testing.expectEqual(cells[1], layer.aqueous_oxygen_g_o);
}
