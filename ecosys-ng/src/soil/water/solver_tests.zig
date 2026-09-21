//! `solver` declarations: tests.
//!
//! Split out of `solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const numerics = @import("../../core/numerics.zig");
const grid_module = @import("../../state/grid.zig");
const retention = @import("retention.zig");
const water_flux = @import("flux.zig");
const transport_hydrology = @import("../../transport/hydrology.zig");
const water_boundary = @import("boundary.zig");
const boundary_topology = @import("../profile/boundary_topology.zig");
const group_conserved = @import("solver_conserved.zig");
const group_fixtures = @import("solver_fixtures.zig");
const group_flux = @import("solver_flux.zig");
const group_hydraulics = @import("solver_hydraulics.zig");
const group_residual = @import("solver_residual.zig");
const group_solve = @import("solver_solve.zig");
const group_types = @import("solver_types.zig");

test "runtime NPH hybrid water solve exits early and conserves both pore domains" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 0.35;
    grid.matrix_liquid_water_m3[1] = 0.15;
    grid.macropore_liquid_water_m3[0] = 0.08;
    grid.macropore_liquid_water_m3[1] = 0.02;
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.macropore_pore_capacity_m3, 0.1);
    const curves = [_]retention.ResolvedCurve{ group_fixtures.testCurve(), group_fixtures.testCurve() };
    const matrix_parameters = [_]retention.MualemVanGenuchtenParameters{ group_fixtures.testMatrixMualemVanGenuchten(), group_fixtures.testMatrixMualemVanGenuchten() };
    const macropore_parameters = [_]retention.MualemVanGenuchtenParameters{ group_fixtures.testMacroporeMualemVanGenuchten(), group_fixtures.testMacroporeMualemVanGenuchten() };
    const macropore_spacing_m = [_]f64{ 0.2, 0.2 };
    const macropore_radius_m = [_]f64{ 0.001, 0.001 };
    const dual_domain_disabled = [_]bool{ false, false };
    const bulk = [_]f64{ 1, 1 };
    const gravity = [_]f64{ 0, 0 };
    const osmotic = [_]f64{ 0, 0 };
    const thickness = [_]f64{ 0.1, 0.1 };
    var micro_flux = [_]f64{0};
    var macro_flux = [_]f64{0};
    const before_micro = grid.matrix_liquid_water_m3[0] + grid.matrix_liquid_water_m3[1];
    const before_macro = grid.macropore_liquid_water_m3[0] + grid.macropore_liquid_water_m3[1];
    const result = try group_solve.solve(std.testing.allocator, &grid, &.{.{ .source_cell = 0, .destination_cell = 1, .direction = .horizontal, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 1 }}, .{ .matrix_bulk_volume_m3 = &bulk, .retention_curve = &curves, .mualem_van_genuchten_parameters = &matrix_parameters, .macropore_mualem_van_genuchten_parameters = &macropore_parameters, .macropore_spacing_m = &macropore_spacing_m, .macropore_radius_m = &macropore_radius_m, .dual_domain_exchange_enabled = &dual_domain_disabled, .gravitational_potential_megapascal = &gravity, .osmotic_potential_megapascal = &osmotic, .vertical_thickness_m = &thickness, .osmotic_potential_multiplier = 1 }, &micro_flux, &macro_flux, .{ .max_iterations = 40 });
    try std.testing.expect(result.iterations < 40);
    try std.testing.expect(result.newton_raphson_steps + result.picard_steps > 0);
    try std.testing.expectEqual(result.picard_steps, result.anderson_steps);
    try std.testing.expect(result.newton_raphson_steps + result.anderson_steps < result.iterations);
    try std.testing.expect(result.dense_jacobian_assemblies > 0);
    try std.testing.expect(result.dense_jacobian_reuses > 0);
    try std.testing.expect(result.dense_jacobian_assemblies < result.newton_raphson_steps);
    try std.testing.expectApproxEqAbs(before_micro, grid.matrix_liquid_water_m3[0] + grid.matrix_liquid_water_m3[1], 1e-12);
    try std.testing.expectApproxEqAbs(before_macro, grid.macropore_liquid_water_m3[0] + grid.macropore_liquid_water_m3[1], 1e-12);
    try std.testing.expect(micro_flux[0] > 0);
    try std.testing.expect(macro_flux[0] > 0);
}

test "vertical Richards residual routes physical ice expansion conservatively" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.macropore_pore_capacity_m3, 0);
    grid.matrix_ice_water_m3[0] = 0;
    grid.matrix_ice_water_m3[1] = 0.1834;

    const base = [_]f64{ 0.2, 0.31, 0, 0 };
    var target: [4]f64 = undefined;
    var residual: [4]f64 = undefined;
    var scratch: [4]f64 = undefined;
    var micro_flux = [_]f64{0};
    var macro_flux = [_]f64{0};
    const curves = [_]retention.ResolvedCurve{ group_fixtures.testCurve(), group_fixtures.testCurve() };
    const matrix_parameters = [_]retention.MualemVanGenuchtenParameters{ group_fixtures.testMatrixMualemVanGenuchten(), group_fixtures.testMatrixMualemVanGenuchten() };
    const macropore_parameters = [_]retention.MualemVanGenuchtenParameters{ group_fixtures.testMacroporeMualemVanGenuchten(), group_fixtures.testMacroporeMualemVanGenuchten() };
    const pair = [_]f64{ 1, 1 };
    const zeros = [_]f64{ 0, 0 };
    const spacing = [_]f64{ 0.2, 0.2 };
    const radius = [_]f64{ 0.001, 0.001 };
    const disabled = [_]bool{ false, false };
    try group_residual.residualAt(
        &grid,
        &.{.{ .source_cell = 0, .destination_cell = 1, .axis = .z, .direction = .vertical, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 0 }},
        .{
            .matrix_bulk_volume_m3 = &pair,
            .retention_curve = &curves,
            .mualem_van_genuchten_parameters = &matrix_parameters,
            .macropore_mualem_van_genuchten_parameters = &macropore_parameters,
            .macropore_spacing_m = &spacing,
            .macropore_radius_m = &radius,
            .dual_domain_exchange_enabled = &disabled,
            .ice_density_megagrams_per_m3 = 0.917,
            .gravitational_potential_megapascal = &zeros,
            .osmotic_potential_megapascal = &zeros,
            .vertical_thickness_m = &pair,
            .osmotic_potential_multiplier = 1,
        },
        &base,
        &base,
        &target,
        &residual,
        &scratch,
        &micro_flux,
        &macro_flux,
    );
    const physical_deficit_m3 = 0.5 - 0.31 - 0.1834 / 0.917;
    try std.testing.expect(physical_deficit_m3 < 0);
    try std.testing.expectApproxEqAbs(physical_deficit_m3, micro_flux[0], 32 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(@as(f64, 0.51), target[0] + target[1], 32 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(@as(f64, 0.2) - physical_deficit_m3, target[0], 32 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(@as(f64, 0.31) + physical_deficit_m3, target[1], 32 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(@as(f64, 0), try group_flux.physicalPoreSpaceM3(0.5, target[1], 0.1834, 0.917), 32 * std.math.floatEps(f64));
}

test "vertical Richards residual routes accepted HOUR1 material contraction conservatively" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    const refreshed_capacity_m3 = 2.5561067029162293e-1;
    const accepted_liquid_m3 = 2.556106976262672e-1;
    const excess_m3 = accepted_liquid_m3 - refreshed_capacity_m3;
    grid.matrix_pore_capacity_m3[0] = 0.5;
    grid.matrix_pore_capacity_m3[1] = refreshed_capacity_m3;
    @memset(grid.macropore_pore_capacity_m3, 0);

    const base = [_]f64{ 0.2, accepted_liquid_m3, 0, 0 };
    var target: [4]f64 = undefined;
    var residual: [4]f64 = undefined;
    var scratch: [4]f64 = undefined;
    var micro_flux = [_]f64{0};
    var macro_flux = [_]f64{0};
    const curves = [_]retention.ResolvedCurve{ group_fixtures.testCurve(), group_fixtures.testCurve() };
    const matrix_parameters = [_]retention.MualemVanGenuchtenParameters{ group_fixtures.testMatrixMualemVanGenuchten(), group_fixtures.testMatrixMualemVanGenuchten() };
    const macropore_parameters = [_]retention.MualemVanGenuchtenParameters{ group_fixtures.testMacroporeMualemVanGenuchten(), group_fixtures.testMacroporeMualemVanGenuchten() };
    const pair = [_]f64{ 1, 1 };
    const zeros = [_]f64{ 0, 0 };
    const spacing = [_]f64{ 0.2, 0.2 };
    const radius = [_]f64{ 0.001, 0.001 };
    const disabled = [_]bool{ false, false };
    try group_residual.residualAt(
        &grid,
        &.{.{ .source_cell = 0, .destination_cell = 1, .axis = .z, .direction = .vertical, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 0 }},
        .{
            .matrix_bulk_volume_m3 = &pair,
            .retention_curve = &curves,
            .mualem_van_genuchten_parameters = &matrix_parameters,
            .macropore_mualem_van_genuchten_parameters = &macropore_parameters,
            .macropore_spacing_m = &spacing,
            .macropore_radius_m = &radius,
            .dual_domain_exchange_enabled = &disabled,
            .gravitational_potential_megapascal = &zeros,
            .osmotic_potential_megapascal = &zeros,
            .vertical_thickness_m = &pair,
            .osmotic_potential_multiplier = 1,
        },
        &base,
        &base,
        &target,
        &residual,
        &scratch,
        &micro_flux,
        &macro_flux,
    );
    try std.testing.expect(excess_m3 > 0);
    try std.testing.expectApproxEqAbs(-excess_m3, micro_flux[0], 32 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(base[0] + excess_m3, target[0], 32 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(refreshed_capacity_m3, target[1], 32 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(base[0] + base[1], target[0] + target[1], 32 * std.math.floatEps(f64));
}

test "vertical mechanical relief overfills a full shallower recipient like the oracle" {
    // MECHANICAL-RELIEF-DONOR-BOUND-ONLY-001 / issue-083. `watsub.f:4898-4902`
    // adds the excess-relief term on top of the already recipient-clamped
    // Darcy term with a DONOR-ONLY bound
    //   `FLQL=FLQL+AMIN1(0.0,AMAX1(-VOLW2(N6,N5,N4)*XNPHX,VOLP1Z(N6,N5,N4)))`
    // so the oracle knowingly pushes liquid into a recipient that has no air
    // space left, and `:4927-4932` re-clamps `VOLP2` rather than refusing.
    // Here layer 0 is EXACTLY full, so the recipient clamp this term used to
    // inherit would have zeroed the relief and left the overfilled column
    // permanently jammed -- the hour-3,253 signature.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    const full_recipient_capacity_m3 = 0.20;
    const deep_capacity_m3 = 0.30;
    const excess_m3 = 0.04;
    grid.matrix_pore_capacity_m3[0] = full_recipient_capacity_m3;
    grid.matrix_pore_capacity_m3[1] = deep_capacity_m3;
    @memset(grid.macropore_pore_capacity_m3, 0);

    // Layer 0 holds exactly its capacity: zero spare room for a recipient
    // clamp to work with. Layer 1 enters over its own capacity.
    const base = [_]f64{ full_recipient_capacity_m3, deep_capacity_m3 + excess_m3, 0, 0 };
    var target: [4]f64 = undefined;
    var residual: [4]f64 = undefined;
    var scratch: [4]f64 = undefined;
    var micro_flux = [_]f64{0};
    var macro_flux = [_]f64{0};
    const curves = [_]retention.ResolvedCurve{ group_fixtures.testCurve(), group_fixtures.testCurve() };
    const matrix_parameters = [_]retention.MualemVanGenuchtenParameters{ group_fixtures.testMatrixMualemVanGenuchten(), group_fixtures.testMatrixMualemVanGenuchten() };
    const macropore_parameters = [_]retention.MualemVanGenuchtenParameters{ group_fixtures.testMacroporeMualemVanGenuchten(), group_fixtures.testMacroporeMualemVanGenuchten() };
    const pair = [_]f64{ 1, 1 };
    const zeros = [_]f64{ 0, 0 };
    const spacing = [_]f64{ 0.2, 0.2 };
    const radius = [_]f64{ 0.001, 0.001 };
    const disabled = [_]bool{ false, false };
    try group_residual.residualAt(
        &grid,
        &.{.{ .source_cell = 0, .destination_cell = 1, .axis = .z, .direction = .vertical, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 0 }},
        .{
            .matrix_bulk_volume_m3 = &pair,
            .retention_curve = &curves,
            .mualem_van_genuchten_parameters = &matrix_parameters,
            .macropore_mualem_van_genuchten_parameters = &macropore_parameters,
            .macropore_spacing_m = &spacing,
            .macropore_radius_m = &radius,
            .dual_domain_exchange_enabled = &disabled,
            .gravitational_potential_megapascal = &zeros,
            .osmotic_potential_megapascal = &zeros,
            .vertical_thickness_m = &pair,
            .osmotic_potential_multiplier = 1,
        },
        &base,
        &base,
        &target,
        &residual,
        &scratch,
        &micro_flux,
        &macro_flux,
    );
    const tolerance = 32 * std.math.floatEps(f64);
    // The full excess moves, even though the recipient had no air space.
    try std.testing.expectApproxEqAbs(-excess_m3, micro_flux[0], tolerance);
    try std.testing.expectApproxEqAbs(deep_capacity_m3, target[1], tolerance);
    // The recipient is now deliberately over ITS own capacity -- the exact
    // behavior `VOLP2=AMAX1(0.0,..)` exists to absorb, and the thing the old
    // recipient clamp forbade.
    try std.testing.expectApproxEqAbs(full_recipient_capacity_m3 + excess_m3, target[0], tolerance);
    try std.testing.expect(target[0] > grid.matrix_pore_capacity_m3[0]);
    // Relief is a transfer, never a source or a sink.
    try std.testing.expectApproxEqAbs(base[0] + base[1], target[0] + target[1], tolerance);
}

test "one-iteration water ceiling performs no hidden post-ceiling state_update" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 1 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 0.35;
    grid.matrix_liquid_water_m3[1] = 0.15;
    grid.macropore_liquid_water_m3[0] = 0.08;
    grid.macropore_liquid_water_m3[1] = 0.02;
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.macropore_pore_capacity_m3, 0.1);
    const curves = [_]retention.ResolvedCurve{ group_fixtures.testCurve(), group_fixtures.testCurve() };
    const matrix_parameters = [_]retention.MualemVanGenuchtenParameters{ group_fixtures.testMatrixMualemVanGenuchten(), group_fixtures.testMatrixMualemVanGenuchten() };
    const macropore_parameters = [_]retention.MualemVanGenuchtenParameters{ group_fixtures.testMacroporeMualemVanGenuchten(), group_fixtures.testMacroporeMualemVanGenuchten() };
    const pair = [_]f64{ 1, 1 };
    const zeros = [_]f64{ 0, 0 };
    const spacing = [_]f64{ 0.2, 0.2 };
    const radius = [_]f64{ 0.001, 0.001 };
    const disabled = [_]bool{ false, false };
    const thickness = [_]f64{ 0.1, 0.1 };
    var micro_flux = [_]f64{99};
    var macro_flux = [_]f64{88};
    const before_matrix = [_]f64{ grid.matrix_liquid_water_m3[0], grid.matrix_liquid_water_m3[1] };
    const before_macro = [_]f64{ grid.macropore_liquid_water_m3[0], grid.macropore_liquid_water_m3[1] };
    const faces = [_]group_types.Face{.{ .source_cell = 0, .destination_cell = 1, .direction = .horizontal, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 1 }};
    const properties: group_types.Properties = .{ .matrix_bulk_volume_m3 = &pair, .retention_curve = &curves, .mualem_van_genuchten_parameters = &matrix_parameters, .macropore_mualem_van_genuchten_parameters = &macropore_parameters, .macropore_spacing_m = &spacing, .macropore_radius_m = &radius, .dual_domain_exchange_enabled = &disabled, .gravitational_potential_megapascal = &zeros, .osmotic_potential_megapascal = &zeros, .vertical_thickness_m = &thickness, .osmotic_potential_multiplier = 1 };
    const result = group_solve.solve(std.testing.allocator, &grid, &faces, properties, &micro_flux, &macro_flux, .{ .max_iterations = 1, .absolute_tolerance_m3 = 1e-30, .relative_tolerance = 1e-30 });
    try std.testing.expectError(error.SoilWaterSolverDidNotConverge, result);
    try std.testing.expectEqualSlices(f64, &before_matrix, grid.matrix_liquid_water_m3);
    try std.testing.expectEqualSlices(f64, &before_macro, grid.macropore_liquid_water_m3);
    try std.testing.expectEqual(@as(f64, 99), micro_flux[0]);
    try std.testing.expectEqual(@as(f64, 88), macro_flux[0]);
    try std.testing.expectError(error.InvalidSoilWaterSolverOptions, group_solve.solve(std.testing.allocator, &grid, &faces, properties, &micro_flux, &macro_flux, .{ .max_iterations = 2, .anderson_recovery = false }));
    try std.testing.expectError(error.InvalidSoilWaterSolverOptions, group_solve.solve(std.testing.allocator, &grid, &faces, properties, &micro_flux, &macro_flux, .{ .max_iterations = 2, .maximum_newton_fraction = 1.01 }));
    try std.testing.expectEqualSlices(f64, &before_matrix, grid.matrix_liquid_water_m3);
    try std.testing.expectEqualSlices(f64, &before_macro, grid.macropore_liquid_water_m3);
    try std.testing.expectEqual(@as(f64, 99), micro_flux[0]);
    try std.testing.expectEqual(@as(f64, 88), macro_flux[0]);
}

test "subsurface irrigation is an external source in the Richards residual" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{
            .lon_count = 1,
            .lat_count = 1,
            .soil_layers = 1,
            .plant_populations = 1,
        },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{
            .relative_tolerance = 1e-8,
            .absolute_tolerance = 1e-12,
            .max_nonlinear_iterations = 20,
        },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 0.2;
    grid.matrix_pore_capacity_m3[0] = 0.5;
    grid.macropore_liquid_water_m3[0] = 0;
    grid.macropore_pore_capacity_m3[0] = 0;
    var dense_jacobian_values: [4]f64 = undefined;
    var dense_jacobian_cache: group_types.DenseJacobianCache = .{
        .values = &dense_jacobian_values,
    };
    const properties: group_types.Properties = .{
        .matrix_bulk_volume_m3 = &.{1},
        .retention_curve = &.{group_fixtures.testCurve()},
        .mualem_van_genuchten_parameters = &.{group_fixtures.testMatrixMualemVanGenuchten()},
        .macropore_mualem_van_genuchten_parameters = &.{group_fixtures.testMacroporeMualemVanGenuchten()},
        .macropore_spacing_m = &.{1},
        .macropore_radius_m = &.{0},
        .dual_domain_exchange_enabled = &.{false},
        .gravitational_potential_megapascal = &.{0},
        .osmotic_potential_megapascal = &.{0},

        .matrix_external_source_m3_per_step = &.{0.03},
        .vertical_thickness_m = &.{1},
        .osmotic_potential_multiplier = 1,
        .dense_jacobian_cache = &dense_jacobian_cache,
    };
    var matrix_flux: [0]f64 = .{};
    var macropore_flux: [0]f64 = .{};
    const result = try group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{},
        properties,
        &matrix_flux,
        &macropore_flux,
        .{
            .max_iterations = 20,
            .absolute_tolerance_m3 = 1e-12,
            .relative_tolerance = 1e-10,
        },
    );
    try std.testing.expect(result.iterations < 20);
    try std.testing.expectEqual(@as(u16, 1), result.dense_jacobian_assemblies);
    try std.testing.expectEqual(@as(u16, 0), result.dense_jacobian_reuses);
    try std.testing.expect(result.dense_jacobian_cache_supplied);
    try std.testing.expect(!result.dense_jacobian_cache_loaded);
    try std.testing.expect(result.dense_jacobian_ready_at_publication);
    try std.testing.expect(!result.conservative_map_publication);
    try std.testing.expect(result.dense_jacobian_cache_published);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.23),
        grid.matrix_liquid_water_m3[0],
        1e-11,
    );
    const warm_result = try group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{},
        properties,
        &matrix_flux,
        &macropore_flux,
        .{
            .max_iterations = 20,
            .absolute_tolerance_m3 = 1e-12,
            .relative_tolerance = 1e-10,
        },
    );
    try std.testing.expectEqual(@as(u16, 0), warm_result.dense_jacobian_assemblies);
    try std.testing.expect(warm_result.dense_jacobian_reuses > 0);
    try std.testing.expect(warm_result.dense_jacobian_cache_loaded);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.26),
        grid.matrix_liquid_water_m3[0],
        1e-11,
    );
    // A dry-cell source is inside the nonlinear band but cannot be discarded
    // by the physical mass gate. Publishing its conservative map must not
    // throw away the valid approximate Jacobian needed by the next substep.
    grid.matrix_liquid_water_m3[0] = 0;
    grid.matrix_air_volume_m3[0] = grid.matrix_pore_capacity_m3[0];
    var dry_properties = properties;
    var cell_boundary_exchange = [_]f64{0};
    var layer_boundary_exchange = [_]f64{0};
    dry_properties.boundary_water_exchange_m3_per_step = &cell_boundary_exchange;
    dry_properties.boundary_water_exchange_m3_per_layer_per_step = &layer_boundary_exchange;
    dry_properties.matrix_external_source_m3_per_step = &.{1e-14};
    const physical_options: group_types.Options = .{
        .max_iterations = 20,
        .absolute_tolerance_m3 = 1e-12,
        .relative_tolerance = 1e-10,
        .cell_area_m2 = &.{1},
        .conservation_relative_tolerance = 1e-9,
    };
    const jacobian_before_correction = dense_jacobian_values;
    const corrected = try group_solve.solve(std.testing.allocator, &grid, &.{}, dry_properties, &matrix_flux, &macropore_flux, physical_options);
    try std.testing.expect(corrected.conservative_map_publication);
    try std.testing.expect(corrected.dense_jacobian_cache_loaded);
    try std.testing.expect(corrected.dense_jacobian_ready_at_publication);
    try std.testing.expect(corrected.dense_jacobian_cache_published);
    try std.testing.expectEqual(@as(f64, 1e-14), grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqualSlices(f64, &jacobian_before_correction, dense_jacobian_cache.values);
    dry_properties.matrix_external_source_m3_per_step = properties.matrix_external_source_m3_per_step;
    const next = try group_solve.solve(std.testing.allocator, &grid, &.{}, dry_properties, &matrix_flux, &macropore_flux, physical_options);
    try std.testing.expect(next.dense_jacobian_cache_loaded);
    try std.testing.expect(next.dense_jacobian_reuses > 0);
    try std.testing.expectEqual(@as(u16, 0), next.dense_jacobian_assemblies);
    try std.testing.expectApproxEqAbs(@as(f64, 0.03 + 1e-14), grid.matrix_liquid_water_m3[0], 1e-14);
}

test "simultaneous Richards residual is independent of face ordering" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{
            .lon_count = 3,
            .lat_count = 1,
            .soil_layers = 1,
            .plant_populations = 1,
        },
        .{ .worker_threads = 1, .tile_cells = 3 },
        .{
            .relative_tolerance = 1e-8,
            .absolute_tolerance = 1e-11,
            .max_nonlinear_iterations = 20,
        },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    const initial_matrix_water_m3 = [_]f64{ 0.38, 0.24, 0.12 };
    @memcpy(grid.matrix_liquid_water_m3, &initial_matrix_water_m3);
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.macropore_liquid_water_m3, 0);
    @memset(grid.macropore_pore_capacity_m3, 0);
    const curves = [_]retention.ResolvedCurve{
        group_fixtures.testCurve(),
        group_fixtures.testCurve(),
        group_fixtures.testCurve(),
    };
    const matrix_parameters =
        [_]retention.MualemVanGenuchtenParameters{
            group_fixtures.testMatrixMualemVanGenuchten(),
            group_fixtures.testMatrixMualemVanGenuchten(),
            group_fixtures.testMatrixMualemVanGenuchten(),
        };
    const macropore_parameters =
        [_]retention.MualemVanGenuchtenParameters{
            group_fixtures.testMacroporeMualemVanGenuchten(),
            group_fixtures.testMacroporeMualemVanGenuchten(),
            group_fixtures.testMacroporeMualemVanGenuchten(),
        };
    const scalar = [_]f64{ 1, 1, 1 };
    const zero = [_]f64{ 0, 0, 0 };
    const disabled = [_]bool{ false, false, false };
    const properties: group_types.Properties = .{
        .matrix_bulk_volume_m3 = &scalar,
        .retention_curve = &curves,
        .mualem_van_genuchten_parameters = &matrix_parameters,
        .macropore_mualem_van_genuchten_parameters = &macropore_parameters,
        .macropore_spacing_m = &scalar,
        .macropore_radius_m = &zero,
        .dual_domain_exchange_enabled = &disabled,
        .gravitational_potential_megapascal = &zero,
        .osmotic_potential_megapascal = &zero,

        .vertical_thickness_m = &scalar,
        .osmotic_potential_multiplier = 1,
    };
    const face_01: group_types.Face = .{
        .source_cell = 0,
        .destination_cell = 1,
        .direction = .horizontal,
        .source_path_length_m = 1,
        .destination_path_length_m = 1,
        .face_area_m2 = 1,
    };
    const face_12: group_types.Face = .{
        .source_cell = 1,
        .destination_cell = 2,
        .direction = .horizontal,
        .source_path_length_m = 1,
        .destination_path_length_m = 1,
        .face_area_m2 = 1,
    };
    const trial = [_]f64{ 0.38, 0.24, 0.12, 0, 0, 0 };
    var target_a = [_]f64{0} ** 6;
    var residual_a = [_]f64{0} ** 6;
    var scratch_a = [_]f64{0} ** 6;
    var matrix_flux_a = [_]f64{0} ** 2;
    var macropore_flux_a = [_]f64{0} ** 2;
    try group_residual.residualAt(
        &grid,
        &.{ face_01, face_12 },
        properties,
        &trial,
        &trial,
        &target_a,
        &residual_a,
        &scratch_a,
        &matrix_flux_a,
        &macropore_flux_a,
    );
    var target_b = [_]f64{0} ** 6;
    var residual_b = [_]f64{0} ** 6;
    var scratch_b = [_]f64{0} ** 6;
    var matrix_flux_b = [_]f64{0} ** 2;
    var macropore_flux_b = [_]f64{0} ** 2;
    try group_residual.residualAt(
        &grid,
        &.{ face_12, face_01 },
        properties,
        &trial,
        &trial,
        &target_b,
        &residual_b,
        &scratch_b,
        &matrix_flux_b,
        &macropore_flux_b,
    );
    for (residual_a, residual_b) |first, second|
        try std.testing.expectApproxEqAbs(first, second, 1e-15);
}

test "water warm Jacobian rejection rebuilds without changing accepted physics" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 20 },
    );
    var baseline = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer baseline.deinit();
    var warm = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer warm.deinit();
    for ([_]*grid_module.GridState{ &baseline, &warm }) |grid| {
        @memcpy(grid.matrix_liquid_water_m3, &[_]f64{ 0.3, 0.2 });
        @memcpy(grid.matrix_air_volume_m3, &[_]f64{ 0.2, 0.3 });
        @memset(grid.matrix_pore_capacity_m3, 0.5);
        @memset(grid.macropore_liquid_water_m3, 0);
        @memset(grid.macropore_pore_capacity_m3, 0);
    }
    const faces = [_]group_types.Face{.{ .source_cell = 0, .destination_cell = 1, .direction = .horizontal, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 1 }};
    var cell_exchange = [_]f64{ 0, 0 };
    var layer_exchange = [_]f64{ 0, 0 };
    var properties: group_types.Properties = .{
        .matrix_bulk_volume_m3 = &.{ 1, 1 },
        .retention_curve = &.{ group_fixtures.testCurve(), group_fixtures.testCurve() },
        .mualem_van_genuchten_parameters = &.{ group_fixtures.testMatrixMualemVanGenuchten(), group_fixtures.testMatrixMualemVanGenuchten() },
        .macropore_mualem_van_genuchten_parameters = &.{ group_fixtures.testMacroporeMualemVanGenuchten(), group_fixtures.testMacroporeMualemVanGenuchten() },
        .macropore_spacing_m = &.{ 0.2, 0.2 },
        .macropore_radius_m = &.{ 0.001, 0.001 },
        .dual_domain_exchange_enabled = &.{ false, false },
        .gravitational_potential_megapascal = &.{ 0, 0 },
        .osmotic_potential_megapascal = &.{ 0, 0 },
        .vertical_thickness_m = &.{ 0.1, 0.1 },
        .osmotic_potential_multiplier = 1,
        .boundary_water_exchange_m3_per_step = &cell_exchange,
        .boundary_water_exchange_m3_per_layer_per_step = &layer_exchange,
    };
    const options: group_types.Options = .{ .max_iterations = 20, .cell_area_m2 = &.{ 1, 1 }, .conservation_relative_tolerance = 1e-9 };
    var baseline_micro: [1]f64 = undefined;
    var baseline_macro: [1]f64 = undefined;
    var warm_micro: [1]f64 = undefined;
    var warm_macro: [1]f64 = undefined;
    const expected = try group_solve.solve(std.testing.allocator, &baseline, &faces, properties, &baseline_micro, &baseline_macro, options);
    // Deliberately unusable numerical scratch, never scientific state. The
    // failed warm direction must rebuild within the existing outer attempt.
    var values = [_]f64{std.math.nan(f64)} ** 16;
    var cache: group_types.DenseJacobianCache = .{ .values = &values, .dimension = 4, .valid = true };
    properties.dense_jacobian_cache = &cache;
    const actual = try group_solve.solve(std.testing.allocator, &warm, &faces, properties, &warm_micro, &warm_macro, options);
    try std.testing.expect(actual.dense_jacobian_cache_loaded);
    try std.testing.expect(actual.dense_jacobian_reuses > 0);
    try std.testing.expectEqual(expected.dense_jacobian_assemblies, actual.dense_jacobian_assemblies);
    try std.testing.expectEqual(expected.iterations, actual.iterations);
    try std.testing.expectEqual(expected.newton_raphson_steps, actual.newton_raphson_steps);
    try std.testing.expectEqual(expected.anderson_steps, actual.anderson_steps);
    try std.testing.expectEqualSlices(f64, baseline.matrix_liquid_water_m3, warm.matrix_liquid_water_m3);
    try std.testing.expectEqualSlices(f64, &baseline_micro, &warm_micro);
    try std.testing.expectEqualSlices(f64, &baseline_macro, &warm_macro);
}

test "lower drainage and lateral water-table recharge converge inside NPH residual" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 0.4;
    grid.macropore_liquid_water_m3[0] = 0.05;
    grid.matrix_pore_capacity_m3[0] = 0.5;
    grid.macropore_pore_capacity_m3[0] = 0.1;
    var site = try @import("../../state/site.zig").parse(std.testing.allocator, @import("../../core/test_fixtures.zig").site_source, 1, 1);
    defer site.deinit();
    var topography = try @import("../../state/topography.zig").fromUnits(std.testing.allocator, &.{.{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1 }});
    defer topography.deinit();
    var terrain = try @import("../../state/terrain_hydrology.zig").State.initMapped(std.testing.allocator, topography, &.{0}, &.{1}, &.{1}, 1, 1);
    defer terrain.deinit();
    var topology = try boundary_topology.State.initMapped(std.testing.allocator, &grid, &terrain, 1, 1, &.{1}, &.{1}, &.{site});
    defer topology.deinit();
    for (topology.faces) |*boundary_face| if (boundary_face.is_lower_boundary) {
        boundary_face.natural_exchange_fraction = 1;
    };
    const curves = [_]retention.ResolvedCurve{group_fixtures.testCurve()};
    const matrix_parameters = [_]retention.MualemVanGenuchtenParameters{group_fixtures.testMatrixMualemVanGenuchten()};
    const macropore_parameters = [_]retention.MualemVanGenuchtenParameters{group_fixtures.testMacroporeMualemVanGenuchten()};
    const macropore_spacing_m = [_]f64{0.2};
    const macropore_radius_m = [_]f64{0.001};
    const dual_domain_disabled = [_]bool{false};
    const one = [_]f64{1};
    const zero = [_]f64{0};
    const thickness = [_]f64{0.1};
    const macro_conductivity = [_]f64{0.001};
    const before_matrix = grid.matrix_liquid_water_m3[0];
    const before_macro = grid.macropore_liquid_water_m3[0];
    _ = try group_solve.solve(std.testing.allocator, &grid, &.{}, .{ .matrix_bulk_volume_m3 = &one, .retention_curve = &curves, .mualem_van_genuchten_parameters = &matrix_parameters, .macropore_mualem_van_genuchten_parameters = &macropore_parameters, .macropore_spacing_m = &macropore_spacing_m, .macropore_radius_m = &macropore_radius_m, .dual_domain_exchange_enabled = &dual_domain_disabled, .gravitational_potential_megapascal = &zero, .osmotic_potential_megapascal = &zero, .vertical_thickness_m = &thickness, .osmotic_potential_multiplier = 1, .boundary_topology = &topology, .boundary_face_area_m2 = &one, .boundary_macropore_hydraulic_conductivity_m2_per_h_megapascal = &macro_conductivity, .boundary_layer_volume_m3 = &one, .boundary_layer_midpoint_depth_m = &thickness, .boundary_layer_bottom_depth_m = &one }, &.{}, &.{}, .{ .max_iterations = 20 });
    try std.testing.expect(grid.matrix_liquid_water_m3[0] < before_matrix);
    try std.testing.expect(grid.macropore_liquid_water_m3[0] < before_macro);
    try std.testing.expect(grid.matrix_liquid_water_m3[0] >= 0);
    try std.testing.expect(grid.macropore_liquid_water_m3[0] >= 0);

    // Reuse the self-contained state to exercise lateral water-table recharge
    // through all four perimeter faces of the one-cell runtime grid.
    topology.natural_water_table_depth_m[0] = 0.01;
    topology.water_table_mode[0] = 1;
    for (topology.faces) |*boundary_face| {
        boundary_face.natural_exchange_fraction = if (boundary_face.is_lower_boundary) 0 else 1;
        boundary_face.artificial_exchange_fraction = 0;
    }
    grid.matrix_liquid_water_m3[0] = 0.1;
    grid.macropore_liquid_water_m3[0] = 0.01;
    _ = try group_solve.solve(std.testing.allocator, &grid, &.{}, .{ .matrix_bulk_volume_m3 = &one, .retention_curve = &curves, .mualem_van_genuchten_parameters = &matrix_parameters, .macropore_mualem_van_genuchten_parameters = &macropore_parameters, .macropore_spacing_m = &macropore_spacing_m, .macropore_radius_m = &macropore_radius_m, .dual_domain_exchange_enabled = &dual_domain_disabled, .gravitational_potential_megapascal = &zero, .osmotic_potential_megapascal = &zero, .vertical_thickness_m = &thickness, .osmotic_potential_multiplier = 1, .boundary_topology = &topology, .boundary_face_area_m2 = &one, .boundary_macropore_hydraulic_conductivity_m2_per_h_megapascal = &macro_conductivity, .boundary_layer_volume_m3 = &one, .boundary_layer_midpoint_depth_m = &thickness, .boundary_layer_bottom_depth_m = &one }, &.{}, &.{}, .{ .max_iterations = 20 });
    try std.testing.expect(grid.matrix_liquid_water_m3[0] > 0.1);
    try std.testing.expect(grid.macropore_liquid_water_m3[0] > 0.01);

    // Artificial drainage is retained separately for OUTSD UVOLY and is
    // published only from the converged residual, never from trial iterates.
    topology.water_table_mode[0] = 3;
    topology.artificial_water_table_depth_m[0] = 0.2;
    for (topology.faces) |*boundary_face| {
        boundary_face.natural_exchange_fraction = 0;
        boundary_face.artificial_exchange_fraction = if (boundary_face.is_lower_boundary) 0 else 1;
        boundary_face.artificial_water_table_distance_m = 1;
        if (!boundary_face.is_lower_boundary) {
            boundary_face.direction_sign = 1;
            boundary_face.slope_sine = 1;
        }
    }
    grid.matrix_liquid_water_m3[0] = 0.499;
    grid.macropore_liquid_water_m3[0] = 0.05;
    grid.matric_potential_megapascal[0] = -1.0e300;
    var artificial_drainage = [_]f64{0};
    var boundary_exchange = [_]f64{0};
    var boundary_exchange_by_layer = [_]f64{0};
    const bottom = [_]f64{0.3};
    const before_drainage = grid.matrix_liquid_water_m3[0] +
        grid.macropore_liquid_water_m3[0];
    _ = try group_solve.solve(std.testing.allocator, &grid, &.{}, .{ .matrix_bulk_volume_m3 = &one, .retention_curve = &curves, .mualem_van_genuchten_parameters = &matrix_parameters, .macropore_mualem_van_genuchten_parameters = &macropore_parameters, .macropore_spacing_m = &macropore_spacing_m, .macropore_radius_m = &macropore_radius_m, .dual_domain_exchange_enabled = &dual_domain_disabled, .gravitational_potential_megapascal = &zero, .osmotic_potential_megapascal = &zero, .vertical_thickness_m = &thickness, .osmotic_potential_multiplier = 1, .boundary_topology = &topology, .boundary_face_area_m2 = &one, .boundary_macropore_hydraulic_conductivity_m2_per_h_megapascal = &macro_conductivity, .boundary_layer_volume_m3 = &one, .boundary_layer_midpoint_depth_m = &thickness, .boundary_layer_bottom_depth_m = &bottom, .artificial_drainage_outflow_m3_per_step = &artificial_drainage, .boundary_water_exchange_m3_per_step = &boundary_exchange, .boundary_water_exchange_m3_per_layer_per_step = &boundary_exchange_by_layer }, &.{}, &.{}, .{ .max_iterations = 20, .conservation_relative_tolerance = 1e-9, .cell_area_m2 = &one });
    try std.testing.expect(artificial_drainage[0] >= 0);
    const accepted_change = grid.matrix_liquid_water_m3[0] +
        grid.macropore_liquid_water_m3[0] - before_drainage;
    try std.testing.expectApproxEqAbs(
        accepted_change,
        boundary_exchange[0],
        2048 * std.math.floatEps(f64),
    );
}

test "artificial tile-drain boundary never fabricates recharge inflow when discharge is disabled" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    var site = try @import("../../state/site.zig").parse(std.testing.allocator, @import("../../core/test_fixtures.zig").site_source, 1, 1);
    defer site.deinit();
    var topography = try @import("../../state/topography.zig").fromUnits(std.testing.allocator, &.{.{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1 }});
    defer topography.deinit();
    var terrain = try @import("../../state/terrain_hydrology.zig").State.initMapped(std.testing.allocator, topography, &.{0}, &.{1}, &.{1}, 1, 1);
    defer terrain.deinit();
    var topology = try boundary_topology.State.initMapped(std.testing.allocator, &grid, &terrain, 1, 1, &.{1}, &.{1}, &.{site});
    defer topology.deinit();
    const curves = [_]retention.ResolvedCurve{group_fixtures.testCurve()};
    const matrix_parameters = [_]retention.MualemVanGenuchtenParameters{group_fixtures.testMatrixMualemVanGenuchten()};
    const macropore_parameters = [_]retention.MualemVanGenuchtenParameters{group_fixtures.testMacroporeMualemVanGenuchten()};
    const macropore_spacing_m = [_]f64{0.2};
    const macropore_radius_m = [_]f64{0.001};
    const dual_domain_disabled = [_]bool{false};
    const one = [_]f64{1};
    const zero = [_]f64{0};
    const thickness = [_]f64{0.1};
    const macro_conductivity = [_]f64{0.001};

    // Below an artificial tile-drain table with discharge disabled this
    // step, the Fortran reference applies no flux at this face at all --
    // watsub.f's only blocks referencing the artificial-table controls are
    // strictly discharge-only. Place the table shallower than the layer's
    // midpoint depth (the recharge-eligible region) and disable discharge
    // by making this layer's matric potential exceed its own base value.
    topology.water_table_mode[0] = 3;
    topology.artificial_water_table_depth_m[0] = 0.05;
    for (topology.faces) |*boundary_face| {
        boundary_face.natural_exchange_fraction = 0;
        boundary_face.artificial_exchange_fraction = if (boundary_face.is_lower_boundary) 0 else 1;
        boundary_face.artificial_water_table_distance_m = 1;
        if (!boundary_face.is_lower_boundary) {
            boundary_face.direction_sign = 1;
            boundary_face.slope_sine = 1;
        }
    }
    grid.matrix_liquid_water_m3[0] = 0.2;
    grid.macropore_liquid_water_m3[0] = 0.01;
    grid.matrix_pore_capacity_m3[0] = 0.5;
    grid.macropore_pore_capacity_m3[0] = 0.1;
    grid.matric_potential_megapascal[0] = 1.0e300;
    const before_matrix = grid.matrix_liquid_water_m3[0];
    const before_macro = grid.macropore_liquid_water_m3[0];
    const bottom = [_]f64{0.3};
    var artificial_drainage = [_]f64{0};
    _ = try group_solve.solve(std.testing.allocator, &grid, &.{}, .{ .matrix_bulk_volume_m3 = &one, .retention_curve = &curves, .mualem_van_genuchten_parameters = &matrix_parameters, .macropore_mualem_van_genuchten_parameters = &macropore_parameters, .macropore_spacing_m = &macropore_spacing_m, .macropore_radius_m = &macropore_radius_m, .dual_domain_exchange_enabled = &dual_domain_disabled, .gravitational_potential_megapascal = &zero, .osmotic_potential_megapascal = &zero, .vertical_thickness_m = &thickness, .osmotic_potential_multiplier = 1, .boundary_topology = &topology, .boundary_face_area_m2 = &one, .boundary_macropore_hydraulic_conductivity_m2_per_h_megapascal = &macro_conductivity, .boundary_layer_volume_m3 = &one, .boundary_layer_midpoint_depth_m = &thickness, .boundary_layer_bottom_depth_m = &bottom, .artificial_drainage_outflow_m3_per_step = &artificial_drainage }, &.{}, &.{}, .{ .max_iterations = 20 });
    // No fabricated recharge: storage must not increase above its pre-solve
    // value from this face while discharge is disabled -- the Fortran
    // reference has no recharge pathway below an artificial tile drain.
    try std.testing.expect(grid.matrix_liquid_water_m3[0] <= before_matrix + 1e-9);
    try std.testing.expect(grid.macropore_liquid_water_m3[0] <= before_macro + 1e-9);
}

test "artificial drain state_update preserves REDIST UVOLY loss sign" {
    var outflow = [_]f64{0};
    group_flux.recordArtificialDrainage(&outflow, 0, 1, -0.25);
    group_flux.recordArtificialDrainage(&outflow, 0, -1, 0.5);
    group_flux.recordArtificialDrainage(&outflow, 0, 1, 0.1);
    try std.testing.expectEqual(@as(f64, 0.75), outflow[0]);
}

test "reduced Newton coordinates remove pore-domain conservation nullspaces" {
    var jacobian = [_]f64{
        -1, 1,  0,  0,
        1,  -1, 0,  0,
        0,  0,  -1, 1,
        0,  0,  1,  -1,
    };
    const residual = [_]f64{ 1, -1, 2, -2 };
    var delta = [_]f64{0} ** 4;
    var reduced_jacobian = [_]f64{0} ** 16;
    var reduced_rhs = [_]f64{0} ** 4;
    var reduced_index = [_]usize{0} ** 4;
    var micro_parent = [_]usize{ 0, 0 };
    var macro_parent = [_]usize{ 0, 0 };
    const component_size = [_]usize{ 2, 1 };
    try std.testing.expect(group_conserved.solveConservedNewtonSystem(&jacobian, &residual, &delta, &reduced_jacobian, &reduced_rhs, &reduced_index, 4, 2, &micro_parent, &component_size, &macro_parent, &component_size));
    try std.testing.expectApproxEqAbs(@as(f64, 0), delta[0] + delta[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0), delta[2] + delta[3], 1e-15);
    for (0..4) |row| {
        var linearized_residual = residual[row];
        for (0..4) |column| linearized_residual += jacobian[row * 4 + column] * delta[column];
        try std.testing.expectApproxEqAbs(@as(f64, 0), linearized_residual, 1e-12);
    }
    @memset(&delta, 0);
    @memset(&reduced_jacobian, 0);
    @memset(&reduced_rhs, 0);
    micro_parent = .{ 0, 0 };
    macro_parent = .{ 0, 0 };
    try std.testing.expect(group_conserved.solveConservedTrustRegionSystem(&jacobian, &residual, &.{ 1, 1, 1, 1 }, .{ .max_iterations = 1 }, &delta, &reduced_jacobian, &reduced_rhs, &reduced_index, 4, 2, &micro_parent, &component_size, &macro_parent, &component_size, 1e-8));
    try std.testing.expectApproxEqAbs(@as(f64, 0), delta[0] + delta[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0), delta[2] + delta[3], 1e-15);
}

test "whole-step residual retains every independent storage coordinate" {
    var parent = [_]usize{ 0, 0 };
    var size = [_]usize{ 2, 1 };
    group_conserved.releaseIndependentStorageCoordinates(&parent, &size);
    try std.testing.expectEqual(@as(usize, 1), size[0]);
}

test "rejected water solve leaves grid and published flux unchanged" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 0.35;
    grid.matrix_liquid_water_m3[1] = 0.15;
    grid.matrix_ice_water_m3[0] = 0.2;
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    const curves = [_]retention.ResolvedCurve{ group_fixtures.testCurve(), group_fixtures.testCurve() };
    const matrix_parameters = [_]retention.MualemVanGenuchtenParameters{ group_fixtures.testMatrixMualemVanGenuchten(), group_fixtures.testMatrixMualemVanGenuchten() };
    const macropore_parameters = [_]retention.MualemVanGenuchtenParameters{ group_fixtures.testMacroporeMualemVanGenuchten(), group_fixtures.testMacroporeMualemVanGenuchten() };
    const macropore_spacing_m = [_]f64{ 0.2, 0.2 };
    const macropore_radius_m = [_]f64{ 0.001, 0.001 };
    const dual_domain_disabled = [_]bool{ false, false };
    const pair = [_]f64{ 1, 1 };
    const zeros = [_]f64{ 0, 0 };
    const thickness = [_]f64{ 0.1, 0.1 };
    var micro_flux = [_]f64{99};
    var macro_flux = [_]f64{88};
    try std.testing.expectError(error.SoilWaterSolverDidNotConverge, group_solve.solve(std.testing.allocator, &grid, &.{.{ .source_cell = 0, .destination_cell = 1, .direction = .horizontal, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 1 }}, .{ .matrix_bulk_volume_m3 = &pair, .retention_curve = &curves, .mualem_van_genuchten_parameters = &matrix_parameters, .macropore_mualem_van_genuchten_parameters = &macropore_parameters, .macropore_spacing_m = &macropore_spacing_m, .macropore_radius_m = &macropore_radius_m, .dual_domain_exchange_enabled = &dual_domain_disabled, .gravitational_potential_megapascal = &zeros, .osmotic_potential_megapascal = &zeros, .vertical_thickness_m = &thickness, .osmotic_potential_multiplier = 1 }, &micro_flux, &macro_flux, .{ .max_iterations = 1, .absolute_tolerance_m3 = 1.0e-30, .relative_tolerance = 1.0e-30 }));
    try std.testing.expectEqual(@as(f64, 0.35), grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 99), micro_flux[0]);
    try std.testing.expectEqual(@as(f64, 88), macro_flux[0]);
}

test "converged WATSUB flux binds to shared hydrology and solute faces" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 0.35;
    grid.matrix_liquid_water_m3[1] = 0.15;
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    grid.matrix_air_volume_m3[0] = 0.15;
    grid.matrix_air_volume_m3[1] = 0.35;
    @memcpy(grid.air_volume_m3, grid.matrix_air_volume_m3);
    var snow = try @import("../solute/snow_solute_transport.zig").State.init(std.testing.allocator, 2, 1);
    defer snow.deinit();
    var hydrology = try transport_hydrology.State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();
    try hydrology.syncStorage(&grid, &snow);
    var shared_faces = try transport_hydrology.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer shared_faces.deinit();
    const curves = [_]retention.ResolvedCurve{ group_fixtures.testCurve(), group_fixtures.testCurve() };
    const matrix_parameters = [_]retention.MualemVanGenuchtenParameters{ group_fixtures.testMatrixMualemVanGenuchten(), group_fixtures.testMatrixMualemVanGenuchten() };
    const macropore_parameters = [_]retention.MualemVanGenuchtenParameters{ group_fixtures.testMacroporeMualemVanGenuchten(), group_fixtures.testMacroporeMualemVanGenuchten() };
    const macropore_spacing_m = [_]f64{ 0.2, 0.2 };
    const macropore_radius_m = [_]f64{ 0.001, 0.001 };
    const dual_domain_disabled = [_]bool{ false, false };
    const bulk = [_]f64{ 1, 1 };
    const zeros = [_]f64{ 0, 0 };
    const thickness = [_]f64{ 0.1, 0.1 };
    const one = [_]f64{1};
    _ = try group_solve.solveAndBindTransportFaces(std.testing.allocator, &grid, &hydrology, &shared_faces, .{ .source_path_length_m = &one, .destination_path_length_m = &one, .face_area_m2 = &one }, .{ .matrix_bulk_volume_m3 = &bulk, .retention_curve = &curves, .mualem_van_genuchten_parameters = &matrix_parameters, .macropore_mualem_van_genuchten_parameters = &macropore_parameters, .macropore_spacing_m = &macropore_spacing_m, .macropore_radius_m = &macropore_radius_m, .dual_domain_exchange_enabled = &dual_domain_disabled, .gravitational_potential_megapascal = &zeros, .osmotic_potential_megapascal = &zeros, .vertical_thickness_m = &thickness, .osmotic_potential_multiplier = 1 }, .{ .max_iterations = 40 });
    try std.testing.expectEqual(@as(u2, 0), shared_faces.direction_axis[0]);
    try std.testing.expect(shared_faces.micropore_faces[0].water_flux_m3_per_step > 0);
    try std.testing.expectEqual(shared_faces.micropore_faces[0].water_flux_m3_per_step, hydrology.micropore_face_flux_m3_per_step[0]);
    try std.testing.expectEqualSlices(f64, grid.matrix_liquid_water_m3, hydrology.micropore_water_volume_m3);

    shared_faces.active_by_face[0] = false;
    grid.matrix_liquid_water_m3[0..2].* = .{ 0.35, 0.15 };
    grid.matrix_air_volume_m3[0..2].* = .{ 0.15, 0.35 };
    @memcpy(grid.air_volume_m3, grid.matrix_air_volume_m3);
    hydrology.micropore_face_flux_m3_per_step[0] = 99;
    _ = try group_solve.solveAndBindTransportFaces(std.testing.allocator, &grid, &hydrology, &shared_faces, .{ .source_path_length_m = &one, .destination_path_length_m = &one, .face_area_m2 = &one }, .{ .matrix_bulk_volume_m3 = &bulk, .retention_curve = &curves, .mualem_van_genuchten_parameters = &matrix_parameters, .macropore_mualem_van_genuchten_parameters = &macropore_parameters, .macropore_spacing_m = &macropore_spacing_m, .macropore_radius_m = &macropore_radius_m, .dual_domain_exchange_enabled = &dual_domain_disabled, .gravitational_potential_megapascal = &zeros, .osmotic_potential_megapascal = &zeros, .vertical_thickness_m = &thickness, .osmotic_potential_multiplier = 1 }, .{ .max_iterations = 40 });
    try std.testing.expectEqualSlices(f64, &.{ 0.35, 0.15 }, grid.matrix_liquid_water_m3);
    try std.testing.expectEqual(@as(f64, 0), shared_faces.micropore_faces[0].water_flux_m3_per_step);
    try std.testing.expectEqual(@as(f64, 0), hydrology.micropore_face_flux_m3_per_step[0]);
}

test "original Mualem conductivity stays isotropic when no lateral array is supplied" {
    // Back-compat falsifier for `SOIL-HCOND-AXIS-ISOTROPY-001`: a caller that
    // never populates `lateral_saturated_hydraulic_conductivity_m_per_h` (every
    // caller that predates that defect fix) must keep exactly its previous,
    // axis-blind behaviour.
    const curves = [_]retention.ResolvedCurve{group_fixtures.testCurve()};
    const scalar = [_]f64{1};
    const parameters = [_]retention.MualemVanGenuchtenParameters{group_fixtures.testMatrixMualemVanGenuchten()};
    const properties: group_types.Properties = .{ .matrix_bulk_volume_m3 = &scalar, .retention_curve = &curves, .mualem_van_genuchten_parameters = &parameters, .gravitational_potential_megapascal = &scalar, .osmotic_potential_megapascal = &scalar, .vertical_thickness_m = &scalar, .osmotic_potential_multiplier = 1 };
    const x_conductivity = try group_hydraulics.conductivityAt(properties, 0, 0, 0.3, 0);
    try std.testing.expectEqual(x_conductivity, try group_hydraulics.conductivityAt(properties, 0, 1, 0.3, 0));
    try std.testing.expectEqual(x_conductivity, try group_hydraulics.conductivityAt(properties, 0, 2, 0.3, 0));
}

test "SOIL-HCOND-AXIS-ISOTROPY-001: lateral and vertical Mualem conductivity diverge when SCNH != SCNV" {
    // Mirrors `ecosys_f77/hour1.f:2281-2293`: one shared dimensionless
    // relative-conductivity shape (`YK*SUM1/SUM2`), scaled by `SCNV` for the
    // vertical axis (`N.EQ.3`) and by `SCNH` for the lateral axes (`N=1,2`).
    const curves = [_]retention.ResolvedCurve{group_fixtures.testCurve()};
    const scalar = [_]f64{1};
    const parameters = [_]retention.MualemVanGenuchtenParameters{group_fixtures.testMatrixMualemVanGenuchten()};
    const lateral_saturated_hydraulic_conductivity_m_per_h =
        [_]f64{parameters[0].saturated_hydraulic_conductivity_m_per_h * 4.0};
    const properties: group_types.Properties = .{
        .matrix_bulk_volume_m3 = &scalar,
        .retention_curve = &curves,
        .mualem_van_genuchten_parameters = &parameters,
        .lateral_saturated_hydraulic_conductivity_m_per_h = &lateral_saturated_hydraulic_conductivity_m_per_h,
        .gravitational_potential_megapascal = &scalar,
        .osmotic_potential_megapascal = &scalar,
        .vertical_thickness_m = &scalar,
        .osmotic_potential_multiplier = 1,
    };
    const vertical_conductivity = try group_hydraulics.conductivityAt(properties, 0, 2, 0.3, 0);
    const x_conductivity = try group_hydraulics.conductivityAt(properties, 0, 0, 0.3, 0);
    const y_conductivity = try group_hydraulics.conductivityAt(properties, 0, 1, 0.3, 0);
    // Same dimensionless shape, so the lateral/vertical ratio reproduces the
    // saturated-conductivity ratio exactly.
    try std.testing.expectApproxEqRel(vertical_conductivity * 4.0, x_conductivity, 1.0e-12);
    try std.testing.expectEqual(x_conductivity, y_conductivity);

    // The interval-averaged (Kirchhoff) face form must show the same
    // direction-specific scaling.
    const neighbour_head_m = try parameters[0].pressureHeadAtWaterContent(0.15);
    const vertical_interval = try group_hydraulics.intervalAveragedConductivityAt(properties, 0, 2, 0.3, neighbour_head_m, 0);
    const lateral_interval = try group_hydraulics.intervalAveragedConductivityAt(properties, 0, 0, 0.3, neighbour_head_m, 0);
    try std.testing.expectApproxEqRel(vertical_interval * 4.0, lateral_interval, 1.0e-9);
}

test "root uptake and Richards faces share one unsaturated conductivity" {
    // Plant root uptake resistance calls `group_hydraulics.unsaturatedConductivityM2PerHMpa`
    // directly while the Richards residual calls `group_hydraulics.conductivityAt`. If those two
    // ever diverge, the plant and the soil disagree about how fast water reaches
    // a root at the same water content, and the disagreement shows up only as a
    // slow water-balance drift. Pin them to bit equality across the curve.
    const curves = [_]retention.ResolvedCurve{group_fixtures.testCurve()};
    const scalar = [_]f64{1};
    const multiplier = [_]f64{0.25};
    const ice_density_megagrams_per_m3 = 0.917;
    const parameters = [_]retention.MualemVanGenuchtenParameters{group_fixtures.testMatrixMualemVanGenuchten()};
    const properties: group_types.Properties = .{
        .matrix_bulk_volume_m3 = &scalar,
        .retention_curve = &curves,
        .mualem_van_genuchten_parameters = &parameters,
        .gravitational_potential_megapascal = &scalar,
        .osmotic_potential_megapascal = &scalar,

        .rainfall_conductivity_multiplier = &multiplier,
        .vertical_thickness_m = &scalar,
        .osmotic_potential_multiplier = 1,
        .frozen_hydraulic_impedance_exponent = 7,
        .ice_density_megagrams_per_m3 = ice_density_megagrams_per_m3,
    };
    for ([_]f64{ 0.05, 0.12, 0.2, 0.28, 0.35, 0.42 }) |water_fraction| {
        for ([_]f64{ 0, 0.03, 0.1 }) |ice_m3| {
            const solver_conductivity = try group_hydraulics.conductivityAt(properties, 0, 2, water_fraction, ice_m3);
            const plant_conductivity = try group_hydraulics.unsaturatedConductivityM2PerHMpa(.{
                .parameters = parameters[0],
                .water_fraction = water_fraction,
                .ice_water_equivalent_m3 = ice_m3,
                .matrix_bulk_volume_m3 = scalar[0],
                .conductivity_multiplier = multiplier[0],
                .frozen_hydraulic_impedance_exponent = properties.frozen_hydraulic_impedance_exponent,
                .ice_density_megagrams_per_m3 = ice_density_megagrams_per_m3,
                .gravitational_water_potential_mpa_per_m = properties.gravitational_water_potential_mpa_per_m,
            });
            try std.testing.expectEqual(solver_conductivity, plant_conductivity);
            try std.testing.expect(plant_conductivity >= 0);
        }
    }
    try std.testing.expectError(error.InvalidUnsaturatedConductivityInput, group_hydraulics.unsaturatedConductivityM2PerHMpa(.{
        .parameters = parameters[0],
        .water_fraction = 0.3,
        .ice_water_equivalent_m3 = 0,
        .matrix_bulk_volume_m3 = 0,
    }));
}

test "rainfall damage scales Mualem conductivity without changing parameters" {
    const curves = [_]retention.ResolvedCurve{group_fixtures.testCurve()};
    const scalar = [_]f64{1};
    const multiplier = [_]f64{0.25};
    const parameters = [_]retention.MualemVanGenuchtenParameters{group_fixtures.testMatrixMualemVanGenuchten()};
    const unscaled: group_types.Properties = .{ .matrix_bulk_volume_m3 = &scalar, .retention_curve = &curves, .mualem_van_genuchten_parameters = &parameters, .gravitational_potential_megapascal = &scalar, .osmotic_potential_megapascal = &scalar, .vertical_thickness_m = &scalar, .osmotic_potential_multiplier = 1 };
    var scaled = unscaled;
    scaled.rainfall_conductivity_multiplier = &multiplier;
    try std.testing.expectApproxEqAbs(0.25 * try group_hydraulics.conductivityAt(unscaled, 0, 0, 0.3, 0), try group_hydraulics.conductivityAt(scaled, 0, 0, 0.3, 0), 1e-15);
    try std.testing.expectEqual(group_fixtures.testMatrixMualemVanGenuchten(), parameters[0]);
}

test "Richards residual uses runtime Mualem van Genuchten head and conductivity" {
    const parameters: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.05,
        .saturated_water_content_m3_per_m3 = 0.45,
        .alpha_per_m = 3.6,
        .n = 1.56,
        .saturated_hydraulic_conductivity_m_per_h = 0.012,
    };
    const water_content_m3_per_m3 = 0.25;
    const pressure_head_m =
        try parameters.pressureHeadAtWaterContent(water_content_m3_per_m3);
    const expected_conductivity_m_per_h =
        try parameters.hydraulicConductivityMPerH(pressure_head_m);
    const scalar = [_]f64{1};
    const curve = [_]retention.ResolvedCurve{group_fixtures.testCurve()};
    const parameter_slice = [_]retention.MualemVanGenuchtenParameters{parameters};
    const properties: group_types.Properties = .{
        .matrix_bulk_volume_m3 = &scalar,
        .retention_curve = &curve,
        .mualem_van_genuchten_parameters = &parameter_slice,
        .gravitational_potential_megapascal = &scalar,
        .osmotic_potential_megapascal = &scalar,

        .vertical_thickness_m = &scalar,
        .osmotic_potential_multiplier = 1,
    };
    try std.testing.expectApproxEqAbs(
        pressure_head_m * group_hydraulics.waterPressureMpaPerM(),
        try group_hydraulics.matricPotentialMpaAt(properties, 0, water_content_m3_per_m3),
        1.0e-14,
    );
    try std.testing.expectApproxEqAbs(
        expected_conductivity_m_per_h,
        try group_hydraulics.conductivityAt(properties, 0, 2, water_content_m3_per_m3, 0) *
            group_hydraulics.waterPressureMpaPerM(),
        1.0e-14,
    );
}

test "Dall'Amico ice impedance scales runtime Mualem conductivity" {
    const parameters: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.05,
        .saturated_water_content_m3_per_m3 = 0.45,
        .alpha_per_m = 3.6,
        .n = 1.56,
        .saturated_hydraulic_conductivity_m_per_h = 0.012,
    };
    const curves = [_]retention.ResolvedCurve{group_fixtures.testCurve()};
    const scalar = [_]f64{1};
    const zero = [_]f64{0};
    const ice = [_]f64{0.2};
    const parameters_slice = [_]retention.MualemVanGenuchtenParameters{parameters};
    const unfrozen: group_types.Properties = .{ .matrix_bulk_volume_m3 = &scalar, .retention_curve = &curves, .mualem_van_genuchten_parameters = &parameters_slice, .gravitational_potential_megapascal = &zero, .osmotic_potential_megapascal = &zero, .vertical_thickness_m = &scalar, .osmotic_potential_multiplier = 1, .frozen_hydraulic_impedance_exponent = 7 };
    const water_content_m3_per_m3 = 0.25;
    const unfrozen_conductivity =
        try group_hydraulics.conductivityAt(unfrozen, 0, 2, water_content_m3_per_m3, 0);
    const frozen_conductivity =
        try group_hydraulics.conductivityAt(unfrozen, 0, 2, water_content_m3_per_m3, ice[0]);
    // q = 0.2 / (0.45 - 0.05) = 0.5; impedance = 10^(-7q).
    try std.testing.expectApproxEqRel(
        unfrozen_conductivity * std.math.pow(f64, 10, -3.5),
        frozen_conductivity,
        1e-12,
    );
}

test "macropore Richards flow uses runtime shape and conserves pore water" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 40 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.matrix_liquid_water_m3, 0.25);
    @memset(grid.macropore_pore_capacity_m3, 0.1);
    grid.macropore_liquid_water_m3[0] = 0.08;
    grid.macropore_liquid_water_m3[1] = 0.02;
    const before = grid.macropore_liquid_water_m3[0] +
        grid.macropore_liquid_water_m3[1];
    const curves = [_]retention.ResolvedCurve{ group_fixtures.testCurve(), group_fixtures.testCurve() };
    const matrix_parameters = [_]retention.MualemVanGenuchtenParameters{ group_fixtures.testMatrixMualemVanGenuchten(), group_fixtures.testMatrixMualemVanGenuchten() };
    const macro_parameters = [_]retention.MualemVanGenuchtenParameters{
        .{ .residual_water_content_m3_per_m3 = 0, .saturated_water_content_m3_per_m3 = 1, .alpha_per_m = 15, .n = 2.68, .saturated_hydraulic_conductivity_m_per_h = 0.1 },
        .{ .residual_water_content_m3_per_m3 = 0, .saturated_water_content_m3_per_m3 = 1, .alpha_per_m = 15, .n = 2.68, .saturated_hydraulic_conductivity_m_per_h = 0.1 },
    };
    const pair = [_]f64{ 1, 1 };
    const zeros = [_]f64{ 0, 0 };
    const spacing = [_]f64{ 0.2, 0.2 };
    const radius = [_]f64{ 0.001, 0.001 };
    const exchange_disabled = [_]bool{ false, false };
    var matrix_flux = [_]f64{0};
    var macropore_flux = [_]f64{0};
    _ = try group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{.{ .source_cell = 0, .destination_cell = 1, .direction = .horizontal, .source_path_length_m = 1, .destination_path_length_m = 1, .face_area_m2 = 1 }},
        .{ .matrix_bulk_volume_m3 = &pair, .retention_curve = &curves, .mualem_van_genuchten_parameters = &matrix_parameters, .macropore_mualem_van_genuchten_parameters = &macro_parameters, .macropore_spacing_m = &spacing, .macropore_radius_m = &radius, .dual_domain_exchange_enabled = &exchange_disabled, .gravitational_potential_megapascal = &zeros, .osmotic_potential_megapascal = &zeros, .vertical_thickness_m = &pair, .osmotic_potential_multiplier = 1 },
        &matrix_flux,
        &macropore_flux,
        .{ .max_iterations = 40 },
    );
    try std.testing.expect(macropore_flux[0] > 0);
    try std.testing.expectApproxEqAbs(
        before,
        grid.macropore_liquid_water_m3[0] + grid.macropore_liquid_water_m3[1],
        1e-12,
    );
    // The macropore flux is donor-bounded because the runtime Mualem
    // parameters and CNDH-derived Ksat, not a precomputed face conductance
    // (removed: `SOIL-WATER-DEAD-MACROPORE-FACE-CONDUCTANCE-001`), control
    // this branch.
    try std.testing.expect(macropore_flux[0] <= 0.08);
}

test "Gerke van Genuchten exchange converges inside the water residual" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 40 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_pore_capacity_m3[0] = 0.45;
    grid.matrix_liquid_water_m3[0] = 0.10;
    grid.macropore_pore_capacity_m3[0] = 0.10;
    grid.macropore_liquid_water_m3[0] = 0.08;
    const before = grid.matrix_liquid_water_m3[0] +
        grid.macropore_liquid_water_m3[0];
    const matrix_parameters = [_]retention.MualemVanGenuchtenParameters{.{
        .residual_water_content_m3_per_m3 = 0.05,
        .saturated_water_content_m3_per_m3 = 0.45,
        .alpha_per_m = 3.6,
        .n = 1.56,
        .saturated_hydraulic_conductivity_m_per_h = 0.01,
    }};
    const macropore_parameters = [_]retention.MualemVanGenuchtenParameters{.{
        .residual_water_content_m3_per_m3 = 0,
        .saturated_water_content_m3_per_m3 = 1,
        .alpha_per_m = 15,
        .n = 2.68,
        .saturated_hydraulic_conductivity_m_per_h = 0.1,
    }};
    const curves = [_]retention.ResolvedCurve{group_fixtures.testCurve()};
    const one = [_]f64{1};
    const zero = [_]f64{0};
    const spacing = [_]f64{0.2};
    const radius = [_]f64{0.001};
    const enabled = [_]bool{true};
    const result = try group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{},
        .{
            .matrix_bulk_volume_m3 = &one,
            .retention_curve = &curves,
            .mualem_van_genuchten_parameters = &matrix_parameters,
            .macropore_mualem_van_genuchten_parameters = &macropore_parameters,
            .macropore_spacing_m = &spacing,
            .macropore_radius_m = &radius,
            .dual_domain_exchange_enabled = &enabled,
            .gravitational_potential_megapascal = &zero,
            .osmotic_potential_megapascal = &zero,

            .vertical_thickness_m = &one,
            .osmotic_potential_multiplier = 1,
        },
        &.{},
        &.{},
        .{ .max_iterations = 40 },
    );
    try std.testing.expect(result.iterations < 40);
    try std.testing.expect(grid.matrix_liquid_water_m3[0] > 0.10);
    try std.testing.expect(grid.macropore_liquid_water_m3[0] < 0.08);
    try std.testing.expectApproxEqAbs(
        before,
        grid.matrix_liquid_water_m3[0] + grid.macropore_liquid_water_m3[0],
        1e-12,
    );
}

test "large geospatial dual-domain volume converges within runtime NPH" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{
            .lon_count = 1,
            .lat_count = 1,
            .soil_layers = 1,
            .plant_populations = 1,
        },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{
            .relative_tolerance = 1e-8,
            .absolute_tolerance = 1e-11,
            .max_nonlinear_iterations = 20,
        },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    const matrix_bulk_volume_m3 = [_]f64{1.0e7};
    grid.matrix_pore_capacity_m3[0] = 4.5e6;
    grid.matrix_liquid_water_m3[0] = 1.0e6;
    grid.macropore_pore_capacity_m3[0] = 1.0e6;
    grid.macropore_liquid_water_m3[0] = 8.0e5;
    const water_before_m3 = grid.matrix_liquid_water_m3[0] +
        grid.macropore_liquid_water_m3[0];
    const matrix_parameters =
        [_]retention.MualemVanGenuchtenParameters{.{
            .residual_water_content_m3_per_m3 = 0.05,
            .saturated_water_content_m3_per_m3 = 0.45,
            .alpha_per_m = 3.6,
            .n = 1.56,
            .saturated_hydraulic_conductivity_m_per_h = 0.01,
        }};
    const macropore_parameters =
        [_]retention.MualemVanGenuchtenParameters{.{
            .residual_water_content_m3_per_m3 = 0,
            .saturated_water_content_m3_per_m3 = 1,
            .alpha_per_m = 15,
            .n = 2.68,
            .saturated_hydraulic_conductivity_m_per_h = 0.1,
        }};
    const curves = [_]retention.ResolvedCurve{group_fixtures.testCurve()};
    const zero = [_]f64{0};
    const one = [_]f64{1};
    const spacing_m = [_]f64{0.2};
    const radius_m = [_]f64{0.001};
    const exchange_enabled = [_]bool{true};
    const result = try group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{},
        .{
            .matrix_bulk_volume_m3 = &matrix_bulk_volume_m3,
            .retention_curve = &curves,
            .mualem_van_genuchten_parameters = &matrix_parameters,
            .macropore_mualem_van_genuchten_parameters = &macropore_parameters,
            .macropore_spacing_m = &spacing_m,
            .macropore_radius_m = &radius_m,
            .dual_domain_exchange_enabled = &exchange_enabled,
            .gravitational_potential_megapascal = &zero,
            .osmotic_potential_megapascal = &zero,

            .vertical_thickness_m = &one,
            .osmotic_potential_multiplier = 1,
        },
        &.{},
        &.{},
        .{
            .max_iterations = 20,
            .absolute_tolerance_m3 = 1e-11,
            .relative_tolerance = 1e-8,
        },
    );
    try std.testing.expect(result.iterations <= 20);
    try std.testing.expect(result.maximum_scaled_residual <= 1);
    try std.testing.expectApproxEqAbs(
        water_before_m3,
        grid.matrix_liquid_water_m3[0] +
            grid.macropore_liquid_water_m3[0],
        1e-11 + water_before_m3 * 1e-8,
    );
}

test "water solver rejects an unusable divergence watch" {
    // Mirrors `core/numerics.zig`'s and `plant_root_salt_exchange.zig`'s own
    // "...rejects an unusable divergence watch" tests: a patience of zero
    // would fire on the first non-improving iteration and a growth factor
    // below one would fire on an improving one, so `validateInputs` must
    // reject both before the solve ever starts.
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_pore_capacity_m3[0] = 1;
    grid.matrix_liquid_water_m3[0] = 0.5;
    const matrix_bulk_volume_m3 = [_]f64{1};
    const matrix_parameters = [_]retention.MualemVanGenuchtenParameters{group_fixtures.testMatrixMualemVanGenuchten()};
    const macropore_parameters = [_]retention.MualemVanGenuchtenParameters{group_fixtures.testMacroporeMualemVanGenuchten()};
    const curves = [_]retention.ResolvedCurve{group_fixtures.testCurve()};
    const zero = [_]f64{0};
    const one = [_]f64{1};
    const spacing_m = [_]f64{0.2};
    const radius_m = [_]f64{0.001};
    const exchange_disabled = [_]bool{false};
    const properties: group_types.Properties = .{
        .matrix_bulk_volume_m3 = &matrix_bulk_volume_m3,
        .retention_curve = &curves,
        .mualem_van_genuchten_parameters = &matrix_parameters,
        .macropore_mualem_van_genuchten_parameters = &macropore_parameters,
        .macropore_spacing_m = &spacing_m,
        .macropore_radius_m = &radius_m,
        .dual_domain_exchange_enabled = &exchange_disabled,
        .gravitational_potential_megapascal = &zero,
        .osmotic_potential_megapascal = &zero,
        .vertical_thickness_m = &one,
        .osmotic_potential_multiplier = 1,
    };
    try std.testing.expectError(error.InvalidSoilWaterSolverOptions, group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{},
        properties,
        &.{},
        &.{},
        .{ .max_iterations = 20, .divergence_patience = 0 },
    ));
    try std.testing.expectError(error.InvalidSoilWaterSolverOptions, group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{},
        properties,
        &.{},
        &.{},
        .{ .max_iterations = 20, .divergence_growth_factor = 0.5 },
    ));
    try std.testing.expectError(error.InvalidSoilWaterSolverOptions, group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{},
        properties,
        &.{},
        &.{},
        .{ .max_iterations = 20, .stagnation_patience = 0 },
    ));
    try std.testing.expectError(error.InvalidSoilWaterSolverOptions, group_solve.solve(
        std.testing.allocator,
        &grid,
        &.{},
        properties,
        &.{},
        &.{},
        .{ .max_iterations = 20, .oscillation_patience = 0 },
    ));
}
