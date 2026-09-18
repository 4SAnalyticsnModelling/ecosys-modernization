const std = @import("std");
const grid_module = @import("../../state/grid.zig");

pub const BoundaryFlux = struct {
    matrix_water_m3: f64,
    macropore_water_m3: f64,
    convective_heat_megajoules: f64,
};

pub const StateUpdateOptions = struct {
    ice_density_megagrams_per_m3: f64 = 1,
    admissibility_absolute_tolerance_m3: f64 = 0,
    admissibility_relative_tolerance: f64 = 64 * std.math.floatEps(f64),
};

pub const FreeDrainageInputs = struct {
    direction_sign: f64,
    slope_sine: f64,
    matrix_hydraulic_conductivity_m2_per_h_megapascal: f64,
    macropore_hydraulic_conductivity_m2_per_h_megapascal: f64,
    face_area_m2: f64,
    matrix_water_available_m3: f64,
    macropore_water_available_m3: f64,
    recharge_frequency_divisor: f64,
    recharge_time_multiplier: f64,
    time_fraction: f64,
    source_temperature_k: f64,
};

/// WATSUB lower boundary when no water table controls the face. The different
/// placement of XNPHX in matrix and macropore expressions is intentional.
pub fn freeDrainage(inputs: FreeDrainageInputs) !BoundaryFlux {
    try validateFiniteStruct(inputs);
    if (@abs(inputs.direction_sign) != 1 or inputs.matrix_hydraulic_conductivity_m2_per_h_megapascal < 0 or inputs.macropore_hydraulic_conductivity_m2_per_h_megapascal < 0 or inputs.face_area_m2 < 0 or inputs.matrix_water_available_m3 < 0 or inputs.macropore_water_available_m3 < 0 or inputs.recharge_frequency_divisor <= 0 or inputs.recharge_time_multiplier < 0 or inputs.time_fraction <= 0 or inputs.time_fraction > 1 or inputs.source_temperature_k <= 0) return error.InvalidSoilWaterBoundaryInput;
    const gravity_gradient = inputs.direction_sign * 0.0098 * -@abs(inputs.slope_sine);
    const matrix_requested = gravity_gradient * inputs.matrix_hydraulic_conductivity_m2_per_h_megapascal * inputs.face_area_m2 * inputs.time_fraction;
    const matrix = std.math.clamp(matrix_requested, -inputs.matrix_water_available_m3, inputs.matrix_water_available_m3) / inputs.recharge_frequency_divisor * inputs.recharge_time_multiplier;
    const macro_requested = gravity_gradient * inputs.macropore_hydraulic_conductivity_m2_per_h_megapascal * inputs.face_area_m2;
    const macro = std.math.clamp(macro_requested, -inputs.macropore_water_available_m3, inputs.macropore_water_available_m3) / inputs.recharge_frequency_divisor * inputs.recharge_time_multiplier * inputs.time_fraction;
    return checkedBoundaryFlux(matrix, macro, inputs.source_temperature_k);
}

pub const WaterTableDischargeInputs = struct {
    direction_sign: f64,
    slope_sine: f64,
    directional_layer_width_m: f64,
    water_table_slope: f64,
    matric_potential_megapascal: f64,
    saturation_water_potential_megapascal: f64,
    layer_midpoint_depth_m: f64,
    external_water_table_depth_m: f64,
    internal_water_table_depth_m: f64,
    hydraulic_conductivity_m2_per_h_megapascal: f64,
    face_area_m2: f64,
    /// `GRID-INV-001`. Distance from the cell to the external water table, the
    /// length over which the head difference becomes a gradient. A stated model
    /// input with units; it must not be folded into a material property nor into
    /// `recharge_frequency_divisor`, which is a frequency and not a length.
    external_separation_distance_m: f64,
    fraction_face_below_water_table: f64,
    recharge_frequency_divisor: f64,
    recharge_time_multiplier: f64,
    time_fraction: f64,
    source_temperature_k: f64,
};

/// Micropore discharge above either natural or artificial water table. For an
/// artificial drain the caller accumulates this into both FLWL and FLWLY.
pub fn matrixDischarge(inputs: WaterTableDischargeInputs, artificial_drain: bool) !BoundaryFlux {
    try validateFiniteStruct(inputs);
    if (@abs(inputs.direction_sign) != 1 or inputs.directional_layer_width_m <= 0 or inputs.hydraulic_conductivity_m2_per_h_megapascal < 0 or inputs.face_area_m2 < 0 or inputs.external_separation_distance_m <= 0 or inputs.fraction_face_below_water_table < 0 or inputs.fraction_face_below_water_table > 1 or inputs.recharge_frequency_divisor < 0 or inputs.recharge_time_multiplier < 0 or inputs.time_fraction <= 0 or inputs.time_fraction > 1 or inputs.source_temperature_k <= 0) return error.InvalidSoilWaterBoundaryInput;
    // `GRID-INV-002`: `slope_sine` is already dimensionless, so it enters as a
    // gradient. It used to be multiplied by the cell width, which gave the
    // gravity-driven part a different power of cell width from the head-driven
    // part, so no single rescaling could make the expression invariant.
    const slope_gradient = inputs.direction_sign * 0.0049 * inputs.slope_sine * (1.0 - inputs.water_table_slope);
    const saturation_term = if (artificial_drain) 0.0 else inputs.saturation_water_potential_megapascal;
    var driving = @min(0.0, -inputs.matric_potential_megapascal + saturation_term + 0.0098 * (inputs.layer_midpoint_depth_m - inputs.external_water_table_depth_m) - 0.0098 * @max(0.0, inputs.layer_midpoint_depth_m - inputs.internal_water_table_depth_m));
    driving /= inputs.external_separation_distance_m;
    if (driving < 0) driving -= slope_gradient;
    const unsigned_flux = driving * inputs.hydraulic_conductivity_m2_per_h_megapascal * inputs.face_area_m2 * (1.0 - inputs.fraction_face_below_water_table) / (inputs.recharge_frequency_divisor + 1.0) * inputs.recharge_time_multiplier * inputs.time_fraction;
    return checkedBoundaryFlux(inputs.direction_sign * unsigned_flux, 0, inputs.source_temperature_k);
}

pub const MacroporeDischargeInputs = struct {
    direction_sign: f64,
    slope_sine: f64,
    directional_layer_width_m: f64,
    water_table_slope: f64,
    macropore_water_depth_m: f64,
    external_water_table_depth_m: f64,
    internal_water_table_depth_m: f64,
    hydraulic_conductivity_m2_per_h_megapascal: f64,
    face_area_m2: f64,
    /// `GRID-INV-001`; see `WaterTableDischargeInputs`.
    external_separation_distance_m: f64,
    fraction_face_below_water_table: f64,
    recharge_frequency_divisor: f64,
    recharge_time_multiplier: f64,
    time_fraction: f64,
    available_macropore_water_m3: f64,
    incoming_vertical_macropore_water_m3: f64,
    outgoing_vertical_macropore_water_m3: f64,
    source_temperature_k: f64,
};

pub fn macroporeDischarge(inputs: MacroporeDischargeInputs) !BoundaryFlux {
    try validateFiniteStruct(inputs);
    if (@abs(inputs.direction_sign) != 1 or inputs.directional_layer_width_m <= 0 or inputs.hydraulic_conductivity_m2_per_h_megapascal < 0 or inputs.face_area_m2 < 0 or inputs.external_separation_distance_m <= 0 or inputs.fraction_face_below_water_table < 0 or inputs.fraction_face_below_water_table > 1 or inputs.recharge_frequency_divisor <= 0 or inputs.recharge_time_multiplier < 0 or inputs.time_fraction <= 0 or inputs.time_fraction > 1 or inputs.available_macropore_water_m3 < 0 or inputs.source_temperature_k <= 0) return error.InvalidSoilWaterBoundaryInput;
    const slope_gradient = inputs.direction_sign * 0.0049 * inputs.slope_sine * (1.0 - inputs.water_table_slope);
    var driving = (0.0098 * (inputs.macropore_water_depth_m - inputs.external_water_table_depth_m) - 0.0098 * @max(0.0, inputs.macropore_water_depth_m - inputs.internal_water_table_depth_m)) / inputs.external_separation_distance_m;
    if (driving < 0) driving -= slope_gradient;
    const requested = driving * inputs.hydraulic_conductivity_m2_per_h_megapascal * inputs.face_area_m2 * (1.0 - inputs.fraction_face_below_water_table) / inputs.recharge_frequency_divisor * inputs.recharge_time_multiplier * inputs.time_fraction;
    const donor_bound = @min(0.0, -(inputs.available_macropore_water_m3 + inputs.incoming_vertical_macropore_water_m3 - inputs.outgoing_vertical_macropore_water_m3));
    const limited = @max(requested, donor_bound);
    return checkedBoundaryFlux(0, inputs.direction_sign * limited, inputs.source_temperature_k);
}

pub const RechargeInputs = struct {
    direction_sign: f64,
    slope_sine: f64,
    directional_layer_width_m: f64,
    water_table_slope: f64,
    matric_potential_megapascal: f64,
    layer_or_macropore_water_depth_m: f64,
    external_water_table_depth_m: f64,
    hydraulic_conductivity_m2_per_h_megapascal: f64,
    face_area_m2: f64,
    /// `GRID-INV-001`; see `WaterTableDischargeInputs`.
    external_separation_distance_m: f64,
    fraction_face_below_water_table: f64,
    recharge_frequency_divisor: f64,
    recharge_time_multiplier: f64,
    time_fraction: f64,
    available_air_volume_m3: f64,
    source_temperature_k: f64,
};

pub fn recharge(inputs: RechargeInputs, macropore: bool) !BoundaryFlux {
    try validateFiniteStruct(inputs);
    if (@abs(inputs.direction_sign) != 1 or inputs.directional_layer_width_m <= 0 or inputs.hydraulic_conductivity_m2_per_h_megapascal < 0 or inputs.face_area_m2 < 0 or inputs.external_separation_distance_m <= 0 or inputs.fraction_face_below_water_table < 0 or inputs.fraction_face_below_water_table > 1 or inputs.recharge_frequency_divisor <= 0 or inputs.recharge_time_multiplier < 0 or inputs.time_fraction <= 0 or inputs.time_fraction > 1 or inputs.available_air_volume_m3 < 0 or inputs.source_temperature_k <= 0) return error.InvalidSoilWaterBoundaryInput;
    const slope_gradient = inputs.direction_sign * 0.0049 * inputs.slope_sine * (1.0 - inputs.water_table_slope);
    var driving = @max(0.0, -(if (macropore) 0.0 else inputs.matric_potential_megapascal) + 0.0098 * (inputs.layer_or_macropore_water_depth_m - inputs.external_water_table_depth_m)) / inputs.external_separation_distance_m;
    if (driving > 0) driving += slope_gradient;
    const requested = driving * inputs.hydraulic_conductivity_m2_per_h_megapascal * inputs.face_area_m2 * inputs.fraction_face_below_water_table / inputs.recharge_frequency_divisor * inputs.recharge_time_multiplier * inputs.time_fraction;
    const limited = @min(requested, inputs.available_air_volume_m3);
    return if (macropore) checkedBoundaryFlux(0, inputs.direction_sign * limited, inputs.source_temperature_k) else checkedBoundaryFlux(inputs.direction_sign * limited, 0, inputs.source_temperature_k);
}

pub fn geothermalHeatFluxMj(lower_layer_temperature_k: f64, deep_temperature_k: f64, conductivity_m_megajoules_per_h_k: f64, deep_source_depth_m: f64, lower_boundary_depth_m: f64, face_area_m2: f64, time_fraction: f64) !f64 {
    inline for (.{ lower_layer_temperature_k, deep_temperature_k, conductivity_m_megajoules_per_h_k, deep_source_depth_m, lower_boundary_depth_m, face_area_m2, time_fraction }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilWaterBoundaryInput;
    if (lower_layer_temperature_k <= 0 or deep_temperature_k <= 0 or conductivity_m_megajoules_per_h_k < 0 or deep_source_depth_m <= lower_boundary_depth_m or face_area_m2 < 0 or time_fraction <= 0 or time_fraction > 1) return error.InvalidSoilWaterBoundaryInput;
    return (lower_layer_temperature_k - deep_temperature_k) * conductivity_m_megajoules_per_h_k / (deep_source_depth_m - lower_boundary_depth_m) * face_area_m2 * time_fraction;
}

/// Atomically publishes all external WATSUB oriented water and convective-heat
/// face fluxes. `direction_sign` is source XN and converts each face value to
/// a source-layer storage change. Multiple faces may target one runtime layer.
/// No grid field changes unless every accumulated candidate is finite and
/// inside its liquid pore capacity.
pub fn state_updateFluxes(allocator: std.mem.Allocator, grid: *grid_module.GridState, boundary_layer_index: []const usize, direction_sign: []const f64, fluxes: []const BoundaryFlux, cell_heat_source_megajoules: []f64, options: StateUpdateOptions) !void {
    if (boundary_layer_index.len != fluxes.len or direction_sign.len != fluxes.len or cell_heat_source_megajoules.len != grid.layer_count) return error.SoilWaterBoundaryDimensionMismatch;
    inline for (.{ options.ice_density_megagrams_per_m3, options.admissibility_absolute_tolerance_m3, options.admissibility_relative_tolerance }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSoilWaterBoundaryInput;
    if (options.ice_density_megagrams_per_m3 <= 0 or options.ice_density_megagrams_per_m3 > 1 or
        options.admissibility_absolute_tolerance_m3 < 0 or options.admissibility_relative_tolerance < 0)
        return error.InvalidSoilWaterBoundaryInput;
    const matrix_change_m3 = try allocator.alloc(f64, grid.layer_count);
    defer allocator.free(matrix_change_m3);
    const macropore_change_m3 = try allocator.alloc(f64, grid.layer_count);
    defer allocator.free(macropore_change_m3);
    const heat_change_megajoules = try allocator.alloc(f64, grid.layer_count);
    defer allocator.free(heat_change_megajoules);
    @memset(matrix_change_m3, 0);
    @memset(macropore_change_m3, 0);
    @memset(heat_change_megajoules, 0);
    for (boundary_layer_index, direction_sign, fluxes) |layer, sign, flux| {
        if (layer >= grid.layer_count) return error.SoilWaterBoundaryLayerOutOfBounds;
        if (!std.math.isFinite(sign) or @abs(sign) != 1) return error.InvalidSoilWaterBoundaryDirectionSign;
        inline for (@typeInfo(BoundaryFlux).@"struct".fields) |field| if (!std.math.isFinite(@field(flux, field.name))) return error.NonFiniteSoilWaterBoundaryFlux;
        matrix_change_m3[layer] += sign * flux.matrix_water_m3;
        macropore_change_m3[layer] += sign * flux.macropore_water_m3;
        heat_change_megajoules[layer] += sign * flux.convective_heat_megajoules;
    }
    for (0..grid.layer_count) |layer| {
        const matrix = grid.matrix_liquid_water_m3[layer] + matrix_change_m3[layer];
        const macropore = grid.macropore_liquid_water_m3[layer] + macropore_change_m3[layer];
        const heat = cell_heat_source_megajoules[layer] + heat_change_megajoules[layer];
        if (!std.math.isFinite(matrix) or !std.math.isFinite(macropore) or !std.math.isFinite(heat)) return error.NonFiniteSoilWaterBoundaryCandidate;
        if (matrix < 0 or macropore < 0) return error.NegativeSoilWaterBoundaryCandidate;
        const matrix_physical_ice_m3 = grid.matrix_ice_water_m3[layer] / options.ice_density_megagrams_per_m3;
        const macropore_physical_ice_m3 = grid.macropore_ice_water_m3[layer] / options.ice_density_megagrams_per_m3;
        const matrix_air_m3 = grid.matrix_pore_capacity_m3[layer] - matrix - matrix_physical_ice_m3;
        const macropore_air_m3 = grid.macropore_pore_capacity_m3[layer] - macropore - macropore_physical_ice_m3;
        if (matrix_air_m3 < -admissibilityToleranceM3(options, grid.matrix_pore_capacity_m3[layer], matrix, matrix_physical_ice_m3) or
            macropore_air_m3 < -admissibilityToleranceM3(options, grid.macropore_pore_capacity_m3[layer], macropore, macropore_physical_ice_m3))
            return error.SoilWaterBoundaryCandidateExceedsPoreCapacity;
    }
    for (0..grid.layer_count) |layer| {
        grid.matrix_liquid_water_m3[layer] += matrix_change_m3[layer];
        grid.macropore_liquid_water_m3[layer] += macropore_change_m3[layer];
        grid.liquid_water_m3[layer] = grid.matrix_liquid_water_m3[layer] + grid.macropore_liquid_water_m3[layer];
        const matrix_air_m3 = grid.matrix_pore_capacity_m3[layer] - grid.matrix_liquid_water_m3[layer] -
            grid.matrix_ice_water_m3[layer] / options.ice_density_megagrams_per_m3;
        const macropore_air_m3 = grid.macropore_pore_capacity_m3[layer] - grid.macropore_liquid_water_m3[layer] -
            grid.macropore_ice_water_m3[layer] / options.ice_density_megagrams_per_m3;
        // Only the non-conserved, derived air carrier is normalized, and only
        // after the scaled absolute+relative admissibility check above.
        grid.matrix_air_volume_m3[layer] = if (matrix_air_m3 < 0) 0 else matrix_air_m3;
        grid.macropore_air_volume_m3[layer] = if (macropore_air_m3 < 0) 0 else macropore_air_m3;
        grid.air_volume_m3[layer] = grid.matrix_air_volume_m3[layer] + grid.macropore_air_volume_m3[layer];
        cell_heat_source_megajoules[layer] += heat_change_megajoules[layer];
    }
}

fn admissibilityToleranceM3(options: StateUpdateOptions, capacity_m3: f64, liquid_m3: f64, physical_ice_m3: f64) f64 {
    const scale_m3 = @max(@abs(capacity_m3), @max(@abs(liquid_m3), @abs(physical_ice_m3)));
    return options.admissibility_absolute_tolerance_m3 + options.admissibility_relative_tolerance * scale_m3;
}

fn checkedBoundaryFlux(matrix: f64, macro: f64, temperature_k: f64) !BoundaryFlux {
    const heat_megajoules = 4.19 * temperature_k * (matrix + macro);
    if (!std.math.isFinite(matrix) or !std.math.isFinite(macro) or !std.math.isFinite(heat_megajoules)) return error.NonFiniteSoilWaterBoundaryFlux;
    return .{ .matrix_water_m3 = matrix, .macropore_water_m3 = macro, .convective_heat_megajoules = heat_megajoules };
}

fn validateFiniteStruct(value: anytype) !void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| if (!std.math.isFinite(@field(value, field.name))) return error.NonFiniteSoilWaterBoundaryInput;
}

test "free drainage preserves WATSUB direction and donor bounds" {
    const flux = try freeDrainage(.{ .direction_sign = 1, .slope_sine = 1, .matrix_hydraulic_conductivity_m2_per_h_megapascal = 100, .macropore_hydraulic_conductivity_m2_per_h_megapascal = 100, .face_area_m2 = 1, .matrix_water_available_m3 = 0.2, .macropore_water_available_m3 = 0.1, .recharge_frequency_divisor = 1, .recharge_time_multiplier = 1, .time_fraction = 1, .source_temperature_k = 280 });
    try std.testing.expectEqual(@as(f64, -0.2), flux.matrix_water_m3);
    try std.testing.expectEqual(@as(f64, -0.1), flux.macropore_water_m3);
}

test "matrix discharge and recharge have opposite water-table signs" {
    const discharge = try matrixDischarge(.{ .direction_sign = 1, .slope_sine = 0, .directional_layer_width_m = 1, .water_table_slope = 0, .matric_potential_megapascal = -0.1, .saturation_water_potential_megapascal = -0.0005, .layer_midpoint_depth_m = 0.2, .external_water_table_depth_m = 20, .internal_water_table_depth_m = 20, .hydraulic_conductivity_m2_per_h_megapascal = 1, .face_area_m2 = 1, .external_separation_distance_m = 1, .fraction_face_below_water_table = 0, .recharge_frequency_divisor = 1, .recharge_time_multiplier = 1, .time_fraction = 1, .source_temperature_k = 280 }, false);
    const recharge_flux = try recharge(.{ .direction_sign = 1, .slope_sine = 0, .directional_layer_width_m = 1, .water_table_slope = 0, .matric_potential_megapascal = -0.1, .layer_or_macropore_water_depth_m = 2, .external_water_table_depth_m = 1, .hydraulic_conductivity_m2_per_h_megapascal = 1, .face_area_m2 = 1, .external_separation_distance_m = 1, .fraction_face_below_water_table = 1, .recharge_frequency_divisor = 1, .recharge_time_multiplier = 1, .time_fraction = 1, .available_air_volume_m3 = 1, .source_temperature_k = 280 }, false);
    try std.testing.expect(discharge.matrix_water_m3 < 0);
    try std.testing.expect(recharge_flux.matrix_water_m3 > 0);
}

test "geothermal flux follows lower minus deep temperature" {
    try std.testing.expectApproxEqAbs(@as(f64, 10), try geothermalHeatFluxMj(290, 280, 1, 2, 1, 1, 1), 1e-12);
}

test "boundary state_update aggregates runtime faces and is atomic on late failure" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    @memset(grid.matrix_pore_capacity_m3, 1);
    @memset(grid.macropore_pore_capacity_m3, 1);
    @memset(grid.matrix_liquid_water_m3, 0.5);
    @memset(grid.macropore_liquid_water_m3, 0.25);
    @memset(grid.liquid_water_m3, 0.75);
    var heat = [_]f64{ 1, 2 };
    try state_updateFluxes(std.testing.allocator, &grid, &.{ 0, 0 }, &.{ 1, 1 }, &.{ .{ .matrix_water_m3 = -0.1, .macropore_water_m3 = 0.05, .convective_heat_megajoules = -2 }, .{ .matrix_water_m3 = 0.02, .macropore_water_m3 = 0, .convective_heat_megajoules = 0.5 } }, &heat, .{});
    try std.testing.expectApproxEqAbs(@as(f64, 0.42), grid.matrix_liquid_water_m3[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), grid.macropore_liquid_water_m3[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), heat[0], 1e-15);
    const before_matrix = grid.matrix_liquid_water_m3[0];
    const before_heat = heat[0];
    try std.testing.expectError(error.NegativeSoilWaterBoundaryCandidate, state_updateFluxes(std.testing.allocator, &grid, &.{ 0, 1 }, &.{ 1, 1 }, &.{ .{ .matrix_water_m3 = 0.1, .macropore_water_m3 = 0, .convective_heat_megajoules = 1 }, .{ .matrix_water_m3 = -2, .macropore_water_m3 = 0, .convective_heat_megajoules = 0 } }, &heat, .{}));
    try std.testing.expectEqual(before_matrix, grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(before_heat, heat[0]);
}

test "boundary update uses physical ice and scaled admissibility without changing mass" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.matrix_pore_capacity_m3[0] = 1;
    grid.macropore_pore_capacity_m3[0] = 0;
    grid.matrix_liquid_water_m3[0] = 0.5;
    grid.macropore_liquid_water_m3[0] = 0;
    grid.matrix_ice_water_m3[0] = 0.4585;
    grid.macropore_ice_water_m3[0] = 0;
    grid.liquid_water_m3[0] = 0.5;
    var heat = [_]f64{1};
    const options: StateUpdateOptions = .{
        .ice_density_megagrams_per_m3 = 0.917,
        .admissibility_absolute_tolerance_m3 = 1e-14,
        .admissibility_relative_tolerance = 1e-12,
    };
    try state_updateFluxes(std.testing.allocator, &grid, &.{}, &.{}, &.{}, &heat, options);
    try std.testing.expectApproxEqAbs(@as(f64, 0), grid.matrix_air_volume_m3[0], 1e-15);
    try std.testing.expectEqual(@as(f64, 0.5), grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 0.4585), grid.matrix_ice_water_m3[0]);

    grid.matrix_liquid_water_m3[0] += 1e-6;
    grid.liquid_water_m3[0] += 1e-6;
    try std.testing.expectError(
        error.SoilWaterBoundaryCandidateExceedsPoreCapacity,
        state_updateFluxes(std.testing.allocator, &grid, &.{}, &.{}, &.{}, &heat, options),
    );
}
