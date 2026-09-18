const std = @import("std");
const gas_transport = @import("../soil/gas/transport.zig");
const allocation = @import("../soil/gas/oxygen_allocation.zig");
const oxygen_solver = @import("../soil/gas/oxygen_solver.zig");
const compute = @import("../core/compute.zig");

pub fn aqueousOxygenDiffusivity_m2_per_step(reference_m2_per_h: f64, litter_temperature_k: f64, timestep_h: f64) !f64 {
    inline for (.{ reference_m2_per_h, litter_temperature_k, timestep_h }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceOxygenDiffusivityInput;
    if (reference_m2_per_h < 0 or litter_temperature_k <= 0 or timestep_h <= 0) return error.InvalidSurfaceOxygenDiffusivityInput;
    const result = reference_m2_per_h * std.math.pow(f64, litter_temperature_k / 298.15, 6) * timestep_h;
    if (!std.math.isFinite(result) or result < 0) return error.NonFiniteSurfaceOxygenDiffusivity;
    return result;
}

pub const ApplyContext = struct {
    result: *allocation.State,
    litter_gas: *gas_transport.State,
    litter_water_m3: []const f64,
    gaseous_oxygen_flux_g_o: []const f64,
    aqueous_oxygen_flux_g_o: []const f64,
    oxygen_solubility_water_to_air: []const f64,
    gas_exchange_rate_per_step: []const f64,
    maximum_aqueous_oxygen_concentration_g_o_per_m3: []const f64,
    populations: []const allocation.Population,
    allocation_parameters: allocation.Parameters,
    solver_options: oxygen_solver.Options,
};

/// Cell-tiled L=0 oxygen allocation. Population inputs are cell-major and may
/// contain any runtime population count. The implicit solve replaces the
/// source's repeated full sub-hour cycles and exits as soon as it converges.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const population_count = context.result.population_count;
    const oxygen_offset = @intFromEnum(gas_transport.Species.oxygen);
    for (range.first..range.end) |cell| {
        const gas_index = cell * gas_transport.species_count + oxygen_offset;
        var shared: allocation.SharedLayer = .{
            .gaseous_oxygen_g_o = context.litter_gas.gaseous_mass_g[gas_index],
            .aqueous_oxygen_g_o = context.litter_gas.dissolved_mass_g[gas_index],
            .gaseous_flux_g_o = context.gaseous_oxygen_flux_g_o[cell],
            .aqueous_flux_g_o = context.aqueous_oxygen_flux_g_o[cell],
            .water_volume_m3 = context.litter_water_m3[cell],
            .air_volume_m3 = context.litter_gas.air_volume_m3[cell],
            .oxygen_solubility_water_to_air = context.oxygen_solubility_water_to_air[cell],
            .gas_exchange_rate_per_step = context.gas_exchange_rate_per_step[cell],
            .maximum_aqueous_oxygen_concentration_g_o_per_m3 = context.maximum_aqueous_oxygen_concentration_g_o_per_m3[cell],
        };
        const first = cell * population_count;
        try allocation.solveLayer(context.result, cell, 0, &shared, context.populations[first .. first + population_count], context.allocation_parameters, context.solver_options);
        context.litter_gas.gaseous_mass_g[gas_index] = shared.gaseous_oxygen_g_o;
        context.litter_gas.dissolved_mass_g[gas_index] = shared.aqueous_oxygen_g_o;
    }
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const cells = context.litter_gas.cell_count;
    if (range.first > range.end or range.end > cells or context.result.cell_count != cells or context.result.layer_count != 1) return error.SurfaceOxygenDimensionMismatch;
    inline for (.{ context.litter_water_m3, context.gaseous_oxygen_flux_g_o, context.aqueous_oxygen_flux_g_o, context.oxygen_solubility_water_to_air, context.gas_exchange_rate_per_step, context.maximum_aqueous_oxygen_concentration_g_o_per_m3 }) |values| if (values.len != cells) return error.SurfaceOxygenDimensionMismatch;
    if (context.populations.len != try std.math.mul(usize, cells, context.result.population_count)) return error.SurfaceOxygenDimensionMismatch;
}

test "surface oxygen tile supports runtime populations and conserves oxygen" {
    var gas = try gas_transport.State.init(std.testing.allocator, 2);
    defer gas.deinit();
    var result = try allocation.State.init(std.testing.allocator, 2, 1, 8);
    defer result.deinit();
    var populations = [_]allocation.Population{.{ .is_aerobic = true, .previous_oxygen_demand_g_o = 1, .fallback_active_fraction = 1, .uptake_conductance_m3_per_step = 0.02, .oxygen_half_saturation_g_o_per_m3 = 0.1, .maximum_oxygen_uptake_g_o = 0.01 }} ** 16;
    gas.air_volume_m3[1] = 2;
    const oxygen = try gas_transport.massIndex(1, .oxygen, 2);
    gas.gaseous_mass_g[oxygen] = 1;
    gas.dissolved_mass_g[oxygen] = 0.2;
    var context: ApplyContext = .{
        .result = &result,
        .litter_gas = &gas,
        .litter_water_m3 = &.{ 1, 1 },
        .gaseous_oxygen_flux_g_o = &.{ 0, 0.1 },
        .aqueous_oxygen_flux_g_o = &.{ 0, 0 },
        .oxygen_solubility_water_to_air = &.{ 0.03, 0.03 },
        .gas_exchange_rate_per_step = &.{ 0.5, 0.5 },
        .maximum_aqueous_oxygen_concentration_g_o_per_m3 = &.{ 1, 1 },
        .populations = &populations,
        .allocation_parameters = .{ .minimum_allocation_fraction = 0.001, .negligible_demand_g_o = 1e-12 },
        .solver_options = .{ .absolute_tolerance_g_o = 1e-12, .relative_tolerance = 1e-10, .derivative_floor = 1e-14, .picard_relaxation = 0.5, .gas_max_iterations = 80 },
    };
    try applyTile(&context, .{ .first = 1, .end = 2 });
    var uptake: f64 = 0;
    for (result.oxygen_uptake_g_o[8..16]) |value| uptake += value;
    try std.testing.expectApproxEqAbs(@as(f64, 1.3), gas.gaseous_mass_g[oxygen] + gas.dissolved_mass_g[oxygen] + uptake, 1e-9);
    for (result.iterations[8..16]) |iterations| try std.testing.expect(iterations < 80);
}

test "surface aqueous oxygen diffusivity reproduces HOUR1 equation" {
    try std.testing.expectApproxEqAbs(@as(f64, 8.57e-6), try aqueousOxygenDiffusivity_m2_per_step(8.57e-6, 298.15, 1), 1e-20);
}
