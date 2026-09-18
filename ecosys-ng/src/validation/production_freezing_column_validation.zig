//! Independent 500-cell Appendix C validation of the production heat solver.
//! The dedicated build step supplies ECOSYS_VALIDATE_FULL_FREEZING_COLUMN=1;
//! ordinary suites skip this expensive benchmark in every optimization mode.
//! Explicit runs require ReleaseSafe (shipping qualification) or ReleaseFast
//! (cross-check). An explicit unsupported mode fails instead of silently skipping.
//! Four accepted checkpoints and normal completion are emitted as raw evidence;
//! neither registration, admission tests nor ordinary-suite skips prove execution.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../core/config.zig");
const grid_module = @import("../state/grid.zig");
const heat_solver = @import("../soil/heat/solver.zig");
const retention = @import("../soil/water/retention.zig");
const stefan = @import("stefan_freezing_validation.zig");

test "production dual-phase heat residual passes Appendix C checkpoints" {
    const enabled = std.testing.environ.getAlloc(std.testing.allocator, "ECOSYS_VALIDATE_FULL_FREEZING_COLUMN") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(enabled);
    try requireBenchmarkAdmission(builtin.mode, enabled);
    std.debug.print("\nECOSYS_FREEZING_BENCHMARK start optimize={s} cells=500 time_step_s=10 final_steps=648000\n", .{@tagName(builtin.mode)});
    const allocator = std.testing.allocator;
    const cell_count: usize = 500;
    const cell_thickness_m = 0.01;
    const time_step_s = 10.0;
    const parameters: stefan.Parameters = .{};
    const cfg = try config.SimulationConfig.init(
        .{
            .lon_count = 1,
            .lat_count = 1,
            .soil_layers = cell_count,
            .plant_populations = 1,
        },
        .{ .worker_threads = 1, .tile_cells = cell_count },
        .{
            .relative_tolerance = 1.0e-8,
            .absolute_tolerance = 1.0e-11,
            .max_nonlinear_iterations = 80,
        },
    );
    var grid = try grid_module.GridState.init(allocator, cfg);
    defer grid.deinit();
    const face_count = cell_count - 1;
    const faces = try allocator.alloc(heat_solver.Face, face_count);
    defer allocator.free(faces);
    for (faces, 0..) |*face, index| face.* = .{
        .source_cell = index,
        .destination_cell = index + 1,
        // `calculateFaceFlux` uses twice the conductivity product over the
        // two weighted path terms, so equal entries are the full
        // centre-to-centre spacing (the STARTS/WATSUB DLYR convention).
        .source_path_length_m = cell_thickness_m,
        .destination_path_length_m = cell_thickness_m,
        .face_area_m2 = 1,
    };
    const heat_capacity_megajoules_per_k = try allocator.alloc(f64, cell_count);
    defer allocator.free(heat_capacity_megajoules_per_k);
    const minimum_heat_capacity_megajoules_per_k =
        try allocator.alloc(f64, cell_count);
    defer allocator.free(minimum_heat_capacity_megajoules_per_k);
    const bulk_density_megagrams_per_m3 =
        try allocator.alloc(f64, cell_count);
    defer allocator.free(bulk_density_megagrams_per_m3);
    const liquid_water_fraction = try allocator.alloc(f64, cell_count);
    defer allocator.free(liquid_water_fraction);
    const ice_fraction = try allocator.alloc(f64, cell_count);
    defer allocator.free(ice_fraction);
    const air_fraction = try allocator.alloc(f64, cell_count);
    defer allocator.free(air_fraction);
    const solid_conductivity_numerator =
        try allocator.alloc(f64, cell_count);
    defer allocator.free(solid_conductivity_numerator);
    const solid_conductivity_denominator =
        try allocator.alloc(f64, cell_count);
    defer allocator.free(solid_conductivity_denominator);
    const is_top_layer = try allocator.alloc(bool, cell_count);
    defer allocator.free(is_top_layer);
    const zero = try allocator.alloc(f64, cell_count);
    defer allocator.free(zero);
    const cell_volume_m3 = try allocator.alloc(f64, cell_count);
    defer allocator.free(cell_volume_m3);
    const mualem_van_genuchten =
        try allocator.alloc(
            retention.MualemVanGenuchtenParameters,
            cell_count,
        );
    defer allocator.free(mualem_van_genuchten);
    const depths_m = try allocator.alloc(f64, cell_count);
    defer allocator.free(depths_m);
    const ice_water_equivalent_fraction =
        try allocator.alloc(f64, cell_count);
    defer allocator.free(ice_water_equivalent_fraction);
    const production_curve: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0,
        .saturated_water_content_m3_per_m3 = 1,
        .alpha_per_m = 400,
        .n = 2.5,
        .saturated_hydraulic_conductivity_m_per_h = 1,
    };
    @memset(grid.soil_temperature_k, parameters.initial_temperature_c + 273.15);
    @memset(grid.matrix_liquid_water_m3, cell_thickness_m);
    @memset(grid.liquid_water_m3, cell_thickness_m);
    @memset(grid.matrix_pore_capacity_m3, cell_thickness_m);
    @memset(minimum_heat_capacity_megajoules_per_k, 0);
    @memset(bulk_density_megagrams_per_m3, 0);
    @memset(liquid_water_fraction, 1);
    @memset(ice_fraction, 0);
    @memset(air_fraction, 0);
    @memset(solid_conductivity_numerator, 0);
    @memset(solid_conductivity_denominator, 0);
    @memset(is_top_layer, false);
    is_top_layer[0] = true;
    @memset(zero, 0);
    @memset(cell_volume_m3, cell_thickness_m);
    @memset(mualem_van_genuchten, production_curve);
    for (depths_m, 0..) |*depth_m, cell|
        depth_m.* = (@as(f64, @floatFromInt(cell)) + 0.5) *
            cell_thickness_m;
    const boundary_cell = [_]usize{ 0, cell_count - 1 };
    const boundary_temperature_k = [_]f64{
        parameters.surface_temperature_c + 273.15,
        parameters.initial_temperature_c + 273.15,
    };
    const boundary_distance_m = [_]f64{
        0.5 * cell_thickness_m,
        0.5 * cell_thickness_m,
    };
    const boundary_area_m2 = [_]f64{ 1, 1 };
    const empty_macropore_curve: [0]retention.MualemVanGenuchtenParameters = .{};
    const properties: heat_solver.Properties = .{
        .heat_capacity_megajoules_per_k = heat_capacity_megajoules_per_k,
        .minimum_heat_capacity_megajoules_per_k = minimum_heat_capacity_megajoules_per_k,
        .bulk_density_megagrams_per_m3 = bulk_density_megagrams_per_m3,
        .liquid_water_fraction = liquid_water_fraction,
        .ice_fraction = ice_fraction,
        .air_fraction = air_fraction,
        .fraction_of_pore_volume_air_filled = air_fraction,
        .solid_conductivity_numerator_m_megajoules_per_h_k = solid_conductivity_numerator,
        .solid_conductivity_denominator = solid_conductivity_denominator,
        .is_top_soil_layer = is_top_layer,
        .top_snow_heat_capacity_megajoules_per_k = zero,
        .maximum_negligible_snow_heat_capacity_megajoules_per_k = zero,
        .snow_storage_heat_flux_megajoules = zero,
        .cell_heat_source_megajoules = zero,
        .liquid_water_heat_capacity_megajoules_per_m3_k = parameters.unfrozen_thermal_conductivity_w_per_m_k /
            parameters.unfrozen_thermal_diffusivity_m2_per_s * 1.0e-6,
        .turbulence = .{
            .water_fraction_threshold = 1,
            .air_fraction_threshold = 1,
            .water_rayleigh_coefficient = 0,
            .air_rayleigh_coefficient = 0,
            .water_nusselt_denominator = 1,
            .air_nusselt_denominator = 1,
        },
        .time_step_hours = time_step_s / 3600.0,
        .dirichlet_thermal_boundaries = .{
            .cell_index = &boundary_cell,
            .temperature_k = &boundary_temperature_k,
            .distance_from_cell_center_m = &boundary_distance_m,
            .face_area_m2 = &boundary_area_m2,
        },
        .enthalpy_coupling = .{
            .matrix_liquid_water_m3 = grid.matrix_liquid_water_m3,
            .matrix_ice_water_equivalent_m3 = grid.matrix_ice_water_m3,
            .porous_medium_volume_m3 = cell_volume_m3,
            .mualem_van_genuchten = mualem_van_genuchten,
            .gravitational_water_potential_mpa_per_m = 0.00980665,
            .pure_water_melting_temperature_k = 273.15,
            .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = parameters.frozen_volumetric_heat_capacity_j_per_m3_k *
                1.0e-6,
            .latent_heat_of_fusion_megajoules_per_m3 = parameters.latent_heat_of_fusion_j_per_kg *
                parameters.water_density_kg_per_m3 * 1.0e-6,
            .ice_density_megagrams_per_m3 = 0.917,
            .solver_options = .{
                .max_iterations = 80,
                .absolute_enthalpy_tolerance_megajoules = 1.0e-13,
                .relative_enthalpy_tolerance = 1.0e-11,
            },
            .macropore_mualem_van_genuchten = &empty_macropore_curve,
        },
    };
    const zero_face_flux = try allocator.alloc(f64, face_count);
    defer allocator.free(zero_face_flux);
    @memset(zero_face_flux, 0);
    const heat_face_flux = try allocator.alloc(f64, face_count);
    defer allocator.free(heat_face_flux);
    var workspace = try heat_solver.Workspace.init(
        allocator,
        cell_count,
        face_count,
        0,
    );
    defer workspace.deinit();
    const analytical = try stefan.solveSimilarityParameter(
        parameters,
        100,
        1.0e-12,
    );
    const checkpoint_days = [_]usize{ 3, 15, 40, 75 };
    var checkpoint_index: usize = 0;
    const final_step = checkpoint_days[checkpoint_days.len - 1] *
        86_400 / @as(usize, @intFromFloat(time_step_s));
    var step: usize = 0;
    while (step < final_step) {
        for (0..cell_count) |cell| {
            const liquid_m3 = grid.matrix_liquid_water_m3[cell];
            const ice_m3 = grid.matrix_ice_water_m3[cell];
            heat_capacity_megajoules_per_k[cell] =
                properties.liquid_water_heat_capacity_megajoules_per_m3_k *
                liquid_m3 +
                parameters.frozen_volumetric_heat_capacity_j_per_m3_k *
                    1.0e-6 * ice_m3;
            liquid_water_fraction[cell] = liquid_m3 / cell_thickness_m;
            ice_fraction[cell] = ice_m3 / cell_thickness_m;
        }
        _ = heat_solver.solveWithWorkspace(
            &workspace,
            &grid,
            faces,
            properties,
            .{
                .liquid_water_m3 = zero_face_flux,
                .vapor_m3 = zero_face_flux,
                .macropore_water_m3 = zero_face_flux,
            },
            heat_face_flux,
            .{
                .max_iterations = 80,
                .absolute_tolerance_k = 1.0e-8,
                .relative_tolerance = 1.0e-10,
                .dense_newton_max_components = 0,
            },
        ) catch |err| {
            std.log.err(
                "production Appendix C solve failed: step={d} elapsed_s={e} error={s} top_temperature_k={e} second_temperature_k={e} third_temperature_k={e}",
                .{ step, @as(f64, @floatFromInt(step)) * time_step_s, @errorName(err), grid.soil_temperature_k[0], grid.soil_temperature_k[1], grid.soil_temperature_k[2] },
            );
            return err;
        };
        step += 1;
        if (checkpoint_index < checkpoint_days.len and
            step * @as(usize, @intFromFloat(time_step_s)) ==
                checkpoint_days[checkpoint_index] * 86_400)
        {
            for (ice_water_equivalent_fraction, grid.matrix_ice_water_m3) |*fraction, ice_m3|
                fraction.* = ice_m3 / cell_thickness_m;
            const elapsed_time_s =
                @as(f64, @floatFromInt(step)) * time_step_s;
            const metrics = try stefan.compareProfile(
                analytical,
                elapsed_time_s,
                depths_m,
                grid.soil_temperature_k,
                ice_water_equivalent_fraction,
                1.0e-6,
            );
            if (metrics.root_mean_square_temperature_error_k >= 0.25 or
                metrics.maximum_absolute_temperature_error_k >= 1.5 or
                metrics.absolute_interface_depth_error_m > 0.05)
            {
                std.log.err(
                    "production Appendix C checkpoint failed: days={d} rmse_k={e} max_error_k={e} analytical_front_m={e} simulated_front_m={e} front_error_m={e}",
                    .{
                        checkpoint_days[checkpoint_index],
                        metrics.root_mean_square_temperature_error_k,
                        metrics.maximum_absolute_temperature_error_k,
                        metrics.analytical_interface_depth_m,
                        metrics.simulated_interface_depth_m,
                        metrics.absolute_interface_depth_error_m,
                    },
                );
            }
            try std.testing.expect(
                metrics.root_mean_square_temperature_error_k < 0.25,
            );
            try std.testing.expect(
                metrics.maximum_absolute_temperature_error_k < 1.5,
            );
            try std.testing.expect(
                metrics.absolute_interface_depth_error_m <= 0.05,
            );
            std.debug.print("\nECOSYS_FREEZING_BENCHMARK checkpoint days={d} step={d} rmse_k={e} max_error_k={e} analytical_front_m={e} simulated_front_m={e} front_error_m={e}\n", .{
                checkpoint_days[checkpoint_index],
                step,
                metrics.root_mean_square_temperature_error_k,
                metrics.maximum_absolute_temperature_error_k,
                metrics.analytical_interface_depth_m,
                metrics.simulated_interface_depth_m,
                metrics.absolute_interface_depth_error_m,
            });
            checkpoint_index += 1;
        }
    }
    try std.testing.expectEqual(checkpoint_days.len, checkpoint_index);
    std.debug.print("\nECOSYS_FREEZING_BENCHMARK complete checkpoints={d} steps={d}\n", .{ checkpoint_index, step });
}

fn requireBenchmarkAdmission(mode: std.builtin.OptimizeMode, enabled: ?[]const u8) !void {
    const value = enabled orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, value, "1")) return error.SkipZigTest;
    switch (mode) {
        .ReleaseSafe, .ReleaseFast => {},
        .Debug, .ReleaseSmall => return error.FreezingColumnRequiresReleaseSafeOrReleaseFast,
    }
}

test "freezing benchmark admission is explicit and permits shipping ReleaseSafe" {
    inline for (.{ .Debug, .ReleaseSafe, .ReleaseFast, .ReleaseSmall }) |mode| {
        try std.testing.expectError(error.SkipZigTest, requireBenchmarkAdmission(mode, null));
        try std.testing.expectError(error.SkipZigTest, requireBenchmarkAdmission(mode, "0"));
    }
    try requireBenchmarkAdmission(.ReleaseSafe, "1");
    try requireBenchmarkAdmission(.ReleaseFast, "1");
    try std.testing.expectError(error.FreezingColumnRequiresReleaseSafeOrReleaseFast, requireBenchmarkAdmission(.Debug, "1"));
    try std.testing.expectError(error.FreezingColumnRequiresReleaseSafeOrReleaseFast, requireBenchmarkAdmission(.ReleaseSmall, "1"));
}
