const std = @import("std");
const snow = @import("../solute/snow_solute_transport.zig");
const snow_cover_fraction = @import("snow_cover_fraction.zig");

/// WATSUB's universal conductive-face limiter (`HFLWX` versus `HFLWC`).
/// `watsub.f:1541--1565` (internal snow), `:1786--1796` (snow/soil surface),
/// `:2025--2033` (snow/litter), `:2142--2149` (litter/soil), `:5186--5192`
/// (soil/soil) all form the conductance flux first, then keep whichever of the
/// conductance form and the joint-equilibrium bound has the smaller magnitude,
/// with the conductance form's sign. Exported so every base-of-pack lane books
/// the identical limited value on both sides instead of re-deriving it.
pub fn acceptedEqualizingHeat(
    unlimited_heat_megajoules: f64,
    first_temperature_k: f64,
    second_temperature_k: f64,
    first_capacity_megajoules_per_k: f64,
    second_capacity_megajoules_per_k: f64,
) !f64 {
    inline for (.{ unlimited_heat_megajoules, first_temperature_k, second_temperature_k, first_capacity_megajoules_per_k, second_capacity_megajoules_per_k }) |value|
        if (!std.math.isFinite(value)) return error.InvalidSnowHeatInterfaceLedger;
    if (first_temperature_k <= 0 or second_temperature_k <= 0 or
        first_capacity_megajoules_per_k <= 0 or second_capacity_megajoules_per_k <= 0)
        return error.InvalidSnowHeatInterfaceLedger;
    const equilibrium_temperature = (first_temperature_k * first_capacity_megajoules_per_k +
        second_temperature_k * second_capacity_megajoules_per_k) /
        (first_capacity_megajoules_per_k + second_capacity_megajoules_per_k);
    const equalization_heat = (first_temperature_k - equilibrium_temperature) * first_capacity_megajoules_per_k;
    return if (unlimited_heat_megajoules >= 0)
        @max(0, @min(equalization_heat, unlimited_heat_megajoules))
    else
        @min(0, @max(equalization_heat, unlimited_heat_megajoules));
}

pub const Parameters = struct {
    conductivity_scale_m_megajoules_per_h_k: f64,
    conductivity_density_exponent_m3_per_megagram: f64,
    conductivity_log10_intercept: f64,
    maximum_effective_density_megagrams_per_m3: f64,
    ice_density_megagrams_per_m3: f64,
};

/// WATSUB 1436--1441 `DENSW1`. Snow-layer bulk density from the current solid,
/// liquid, and ice inventories, capped at the runtime maximum effective
/// density. A layer with no representable volume falls back to the supplied
/// minimum snow density, matching the source's `DENS0` branch.
pub fn effectiveDensityMegagramsPerM3(
    parameters: Parameters,
    solid_snow_water_equivalent_m3: f64,
    liquid_water_volume_m3: f64,
    ice_volume_m3: f64,
    total_layer_volume_m3: f64,
    minimum_density_megagrams_per_m3: f64,
) f64 {
    if (!(total_layer_volume_m3 > 0)) return minimum_density_megagrams_per_m3;
    return @min(parameters.maximum_effective_density_megagrams_per_m3, (solid_snow_water_equivalent_m3 + liquid_water_volume_m3 + ice_volume_m3 * parameters.ice_density_megagrams_per_m3) / total_layer_volume_m3);
}

/// WATSUB 1448 `TCND1W`, the J. Glaciology 43:26--41 snow conductivity law.
/// Returned in the same `MJ m-1 h-1 K-1` convention the soil and litter
/// conductivity owners use, so the harmonic interface conductance may pair
/// snow with either recipient directly.
pub fn conductivityMMegajoulesPerHK(parameters: Parameters, density_megagrams_per_m3: f64) f64 {
    return parameters.conductivity_scale_m_megajoules_per_h_k * std.math.pow(f64, 10, parameters.conductivity_density_exponent_m3_per_megagram * density_megagrams_per_m3 + parameters.conductivity_log10_intercept);
}

pub const Options = struct {
    /// Physical integration factor for WATSUB `HFLWC` (`XNPYX`). This is
    /// intentionally distinct from inventory availability factors used by
    /// the mass-transfer kernels.
    physical_time_step_hours: f64,
    full_snow_cover_depth_m: f64,
    /// WATSUB `FSNW(DPTHS0)`, frozen by the caller before same-substep
    /// precipitation changes snow depth. Empty is allowed for isolated calls.
    snow_cover_fraction_by_cell: []const f64 = &.{},
    /// Accepted signed interface heat, indexed by the lower/destination snow
    /// layer. Entry zero in every column is zero; positive moves downward.
    /// Empty is allowed for isolated callers.
    accepted_interface_heat_megajoules: []f64 = &.{},
    /// Restrict this call to one local upper-layer face in every cell. The
    /// coupled WATSUB driver uses this to preserve the source's top-down
    /// layer order; isolated callers may omit it to traverse every face.
    local_face_index: ?usize = null,
};

pub const Report = struct {
    iterations: u16,
    converged: bool,
    maximum_temperature_change_k: f64,
};

/// WATSUB 1539--1565 explicit internal snow conduction. Each face uses the
/// accepted interim temperatures and the source harmonic conductance. The
/// unlimited heat is capped at the two-layer equalization heat, preventing a
/// temperature inversion, and all accepted faces are applied atomically.
pub fn solve(allocator: std.mem.Allocator, state: *snow.State, parameters: Parameters, options: Options) !Report {
    inline for (.{ parameters.conductivity_scale_m_megajoules_per_h_k, parameters.conductivity_density_exponent_m3_per_megagram, parameters.conductivity_log10_intercept, parameters.maximum_effective_density_megagrams_per_m3, parameters.ice_density_megagrams_per_m3, options.physical_time_step_hours, options.full_snow_cover_depth_m }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSnowHeatParameter;
    if (parameters.conductivity_scale_m_megajoules_per_h_k <= 0 or parameters.maximum_effective_density_megagrams_per_m3 <= 0 or parameters.ice_density_megagrams_per_m3 <= 0 or options.physical_time_step_hours <= 0 or options.physical_time_step_hours > 1 or options.full_snow_cover_depth_m <= 0) return error.InvalidSnowHeatParameter;
    const count = state.cell_count * state.layer_capacity;
    if (options.snow_cover_fraction_by_cell.len != 0 and
        options.snow_cover_fraction_by_cell.len != state.cell_count)
        return error.SnowHeatCoverDimensionMismatch;
    if (options.accepted_interface_heat_megajoules.len != 0 and
        options.accepted_interface_heat_megajoules.len != count)
        return error.SnowHeatInterfaceLedgerDimensionMismatch;
    if (options.local_face_index) |face|
        if (face + 1 >= state.layer_capacity) return error.SnowHeatFaceOutOfBounds;
    const temperature = try allocator.dupe(f64, state.temperature_k);
    defer allocator.free(temperature);
    const accepted_interface_heat = try allocator.alloc(f64, count);
    defer allocator.free(accepted_interface_heat);
    @memset(accepted_interface_heat, 0);
    const energy_delta = try allocator.alloc(f64, count);
    defer allocator.free(energy_delta);
    @memset(energy_delta, 0);
    var report: Report = .{ .iterations = 1, .converged = true, .maximum_temperature_change_k = 0 };

    for (0..state.cell_count) |cell| {
        const base = cell * state.layer_capacity;
        const depth_m = state.cumulative_depth_m[base + state.layer_capacity - 1];
        // WATSUB 886--892: every snow-side conductance uses the shared
        // square-root FSNW law, including the partial-cover FSNX floor.
        const snow_cover = if (options.snow_cover_fraction_by_cell.len == 0)
            (try snow_cover_fraction.evaluate(depth_m, options.full_snow_cover_depth_m)).snow_fraction
        else
            options.snow_cover_fraction_by_cell[cell];
        if (!std.math.isFinite(snow_cover) or snow_cover < 0 or snow_cover > 1)
            return error.InvalidSnowHeatCoverFraction;
        const first_face = options.local_face_index orelse 0;
        const face_end = if (options.local_face_index) |face| face + 1 else state.layer_capacity -| 1;
        for (first_face..face_end) |layer| {
            const first = base + layer;
            const second = first + 1;
            const first_volume = state.total_layer_volume_m3[first];
            const second_volume = state.total_layer_volume_m3[second];
            const first_threshold = snow.activation_heat_capacity_megajoules_per_m2_k * state.horizontal_area_m2[first];
            const second_threshold = snow.activation_heat_capacity_megajoules_per_m2_k * state.horizontal_area_m2[second];
            if (state.heat_capacity_megajoules_per_k[first] <= first_threshold or
                state.heat_capacity_megajoules_per_k[second] <= second_threshold or
                first_volume <= 0 or second_volume <= 0)
            {
                continue;
            }
            const first_density = @min(parameters.maximum_effective_density_megagrams_per_m3, (state.solid_snow_water_equivalent_m3[first] + state.liquid_water_volume_m3[first] + state.ice_volume_m3[first] * parameters.ice_density_megagrams_per_m3) / first_volume);
            const second_density = @min(parameters.maximum_effective_density_megagrams_per_m3, (state.solid_snow_water_equivalent_m3[second] + state.liquid_water_volume_m3[second] + state.ice_volume_m3[second] * parameters.ice_density_megagrams_per_m3) / second_volume);
            const first_conductivity = conductivityMMegajoulesPerHK(parameters, first_density);
            const second_conductivity = conductivityMMegajoulesPerHK(parameters, second_density);
            const denominator = first_conductivity * state.layer_thickness_m[second] + second_conductivity * state.layer_thickness_m[first];
            const conductance = if (denominator > 0)
                2 * first_conductivity * second_conductivity / denominator * state.horizontal_area_m2[first] * snow_cover
            else
                0;
            if (!std.math.isFinite(conductance) or conductance < 0) return error.InvalidSnowHeatConductance;
            const first_capacity = state.heat_capacity_megajoules_per_k[first];
            const second_capacity = state.heat_capacity_megajoules_per_k[second];
            const unlimited_heat = conductance * (temperature[first] - temperature[second]) * options.physical_time_step_hours;
            const signed_heat = try acceptedEqualizingHeat(
                unlimited_heat,
                temperature[first],
                temperature[second],
                first_capacity,
                second_capacity,
            );
            accepted_interface_heat[second] = signed_heat;
            energy_delta[first] -= signed_heat;
            energy_delta[second] += signed_heat;
        }
    }
    var net_energy_delta: f64 = 0;
    for (temperature, state.heat_capacity_megajoules_per_k, energy_delta, 0..) |*next_temperature, capacity, delta, index| {
        if (!std.math.isFinite(capacity) or capacity < 0 or !std.math.isFinite(next_temperature.*) or next_temperature.* <= 0)
            return error.InvalidSnowHeatState;
        net_energy_delta += delta;
        if (capacity > 0) {
            next_temperature.* += delta / capacity;
            if (!std.math.isFinite(next_temperature.*) or next_temperature.* <= 0)
                return error.InvalidSnowHeatTemperature;
            report.maximum_temperature_change_k = @max(
                report.maximum_temperature_change_k,
                @abs(next_temperature.* - state.temperature_k[index]),
            );
        } else if (delta != 0) return error.InvalidSnowHeatZeroCapacityTransfer;
    }
    if (!std.math.isFinite(net_energy_delta) or
        @abs(net_energy_delta) > 64 * std.math.floatEps(f64) * @max(1, sumAbsolute(accepted_interface_heat)))
        return error.SnowHeatConservationFailure;
    @memcpy(state.temperature_k, temperature);
    if (options.accepted_interface_heat_megajoules.len != 0)
        @memcpy(options.accepted_interface_heat_megajoules, accepted_interface_heat);
    return report;
}

fn sumAbsolute(values: []const f64) f64 {
    var total: f64 = 0;
    for (values) |value| total += @abs(value);
    return total;
}

test "internal snow conduction conserves sensible energy and reduces gradient" {
    var state = try snow.State.init(std.testing.allocator, 1, 3);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.15}, &.{2}, &.{268}, &.{ 0.05, 0.10, 0.20 }, 0.1, snow.test_thermodynamics);
    state.temperature_k[0] = 280;
    state.temperature_k[1] = 270;
    state.temperature_k[2] = 260;
    const energy_by_layer_before = [_]f64{
        state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0],
        state.heat_capacity_megajoules_per_k[1] * state.temperature_k[1],
        state.heat_capacity_megajoules_per_k[2] * state.temperature_k[2],
    };
    var accepted_interface_heat = [_]f64{ 99, 99, 99 };
    var energy_before: f64 = 0;
    for (state.heat_capacity_megajoules_per_k, state.temperature_k) |capacity, temperature_k| energy_before += capacity * temperature_k;
    const report = try solve(std.testing.allocator, &state, .{ .conductivity_scale_m_megajoules_per_h_k = 0.0036, .conductivity_density_exponent_m3_per_megagram = 2.650, .conductivity_log10_intercept = -1.652, .maximum_effective_density_megagrams_per_m3 = 0.6, .ice_density_megagrams_per_m3 = 0.92 }, .{ .physical_time_step_hours = 1, .full_snow_cover_depth_m = 0.07, .accepted_interface_heat_megajoules = &accepted_interface_heat });
    var energy_after: f64 = 0;
    for (state.heat_capacity_megajoules_per_k, state.temperature_k) |capacity, temperature_k| energy_after += capacity * temperature_k;
    try std.testing.expect(report.converged);
    try std.testing.expectEqual(@as(f64, 0), accepted_interface_heat[0]);
    try std.testing.expect(accepted_interface_heat[1] > 0);
    try std.testing.expect(accepted_interface_heat[2] > 0);
    try std.testing.expectApproxEqAbs(
        -accepted_interface_heat[1],
        state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0] - energy_by_layer_before[0],
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        accepted_interface_heat[1] - accepted_interface_heat[2],
        state.heat_capacity_megajoules_per_k[1] * state.temperature_k[1] - energy_by_layer_before[1],
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        accepted_interface_heat[2],
        state.heat_capacity_megajoules_per_k[2] * state.temperature_k[2] - energy_by_layer_before[2],
        1e-12,
    );
    try std.testing.expect(@abs(state.temperature_k[0] - state.temperature_k[2]) < 20);
    try std.testing.expectApproxEqAbs(energy_before, energy_after, 1e-10);
}

test "snow heat conduction binds WATSUB square-root cover and partial-cover floor" {
    const quarter = try snow_cover_fraction.evaluate(0.0175, 0.07);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), quarter.snow_fraction, 1e-15);
    const near_full = try snow_cover_fraction.evaluate(0.06999999, 0.07);
    try std.testing.expectEqual(@as(f64, 0.999), near_full.snow_fraction);
}

test "WATSUB explicit conduction uses uncapped flux then exact equalization cap" {
    // C1=C2=1, G*dt=1, dT=10 gives HFLWC=10 and HFLWX=5.
    // The former backward-Euler translation returned 10/3.
    try std.testing.expectApproxEqAbs(
        @as(f64, 5),
        try acceptedEqualizingHeat(10, 280, 270, 1, 1),
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 2),
        try acceptedEqualizingHeat(2, 280, 270, 1, 1),
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, -5),
        try acceptedEqualizingHeat(-10, 270, 280, 1, 1),
        1e-15,
    );
}

test "snow conduction solver applies frozen pre-input square-root cover" {
    var half_cover = try snow.State.init(std.testing.allocator, 1, 2);
    defer half_cover.deinit();
    try half_cover.initializePhysicalState(&.{0.1}, &.{1}, &.{268}, &.{ 0.05, 0.10 }, 0.1, snow.test_thermodynamics);
    half_cover.temperature_k[0] = 274;
    half_cover.temperature_k[1] = 273;
    var full_cover = try snow.State.init(std.testing.allocator, 1, 2);
    defer full_cover.deinit();
    try full_cover.initializePhysicalState(&.{0.1}, &.{1}, &.{268}, &.{ 0.05, 0.10 }, 0.1, snow.test_thermodynamics);
    full_cover.temperature_k[0] = 274;
    full_cover.temperature_k[1] = 273;
    const half = (try snow_cover_fraction.evaluate(0.0175, 0.07)).snow_fraction;
    const full = (try snow_cover_fraction.evaluate(0.07, 0.07)).snow_fraction;
    var half_flux = [_]f64{ 0, 0 };
    var full_flux = [_]f64{ 0, 0 };
    const parameters: Parameters = .{ .conductivity_scale_m_megajoules_per_h_k = 0.0036, .conductivity_density_exponent_m3_per_megagram = 2.650, .conductivity_log10_intercept = -1.652, .maximum_effective_density_megagrams_per_m3 = 0.6, .ice_density_megagrams_per_m3 = 0.92 };
    _ = try solve(std.testing.allocator, &half_cover, parameters, .{ .physical_time_step_hours = 0.01, .full_snow_cover_depth_m = 0.07, .snow_cover_fraction_by_cell = &.{half}, .accepted_interface_heat_megajoules = &half_flux });
    _ = try solve(std.testing.allocator, &full_cover, parameters, .{ .physical_time_step_hours = 0.01, .full_snow_cover_depth_m = 0.07, .snow_cover_fraction_by_cell = &.{full}, .accepted_interface_heat_megajoules = &full_flux });
    try std.testing.expect(full_flux[1] > 0);
    try std.testing.expectApproxEqAbs(0.5, half_flux[1] / full_flux[1], 1e-12);
}
