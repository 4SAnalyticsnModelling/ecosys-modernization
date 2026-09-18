const std = @import("std");
const water_flux = @import("../soil/water/flux.zig");
const retention = @import("../soil/water/retention.zig");
const solver = @import("../soil/water/solver.zig");

pub const LitterSoilInputs = struct {
    litter_water_m3: f64,
    soil_matrix_water_m3: f64,
    litter_air_m3: f64,
    soil_matrix_air_m3: f64,
    litter_volume_m3: f64,
    soil_matrix_bulk_volume_m3: f64,
    litter_water_fraction: f64,
    soil_water_fraction: f64,
    /// Retention and conductivity curve for the surface residue pool. The
    /// litter layer is a porous medium like any other, so it uses the same
    /// Mualem-van Genuchten formulation as the soil matrix rather than a
    /// separate residue conductivity class table.
    litter_parameters: retention.MualemVanGenuchtenParameters,
    soil_parameters: retention.MualemVanGenuchtenParameters,
    /// Gravitational and osmotic components only; the matric component is
    /// evaluated from each pool's own curve so the two endpoints of the face
    /// cannot disagree about the constitutive relation.
    litter_external_water_potential_megapascal: f64,
    soil_external_water_potential_megapascal: f64,
    litter_ice_water_equivalent_m3: f64 = 0,
    soil_ice_water_equivalent_m3: f64 = 0,
    conductivity_multiplier: f64 = 1,
    frozen_hydraulic_impedance_exponent: f64 = 0,
    ice_density_megagrams_per_m3: f64 = 0.917,
    gravitational_water_potential_mpa_per_m: f64 = 0.0098,
    litter_thickness_m: f64,
    soil_thickness_m: f64,
    soil_face_area_m2: f64,
    litter_cover_fraction: f64,
    wet_litter_cover_fraction: f64,
    time_fraction: f64,
    soil_excess_pore_volume_m3: f64,
    litter_temperature_k: f64,
    soil_temperature_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
};

pub const LitterSoilFlux = struct { water_m3: f64, unenhanced_water_m3: f64, convective_heat_megajoules: f64 };

/// WATSUB's top-mineral-layer freezing term when no residue pore domain is
/// present. The authoritative surface-water owner still receives the expelled
/// liquid; zero litter cover suppresses Darcy exchange, not mechanical
/// displacement. Negative flux is soil to surface and carries the donor's
/// sensible heat with exactly the same sign.
pub fn bareSurfaceSoilFreezingFlux(
    soil_matrix_water_m3: f64,
    soil_excess_pore_volume_m3: f64,
    time_fraction: f64,
    soil_temperature_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
) !LitterSoilFlux {
    inline for (.{ soil_temperature_k, liquid_water_heat_capacity_megajoules_per_m3_k }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSurfaceWaterInput;
    if (soil_temperature_k <= 0 or liquid_water_heat_capacity_megajoules_per_m3_k <= 0)
        return error.InvalidSurfaceWaterInput;
    const water_m3 = try water_flux.mechanicalFreezingDisplacementM3(
        soil_matrix_water_m3,
        soil_excess_pore_volume_m3,
        time_fraction,
    );
    return .{
        .water_m3 = water_m3,
        .unenhanced_water_m3 = water_m3,
        .convective_heat_megajoules = liquid_water_heat_capacity_megajoules_per_m3_k *
            soil_temperature_k * water_m3,
    };
}

/// NPR is now only the caller's convergence ceiling; this evaluates one
/// nonlinear litter-soil face for a whole-step Newton/Picard residual.
pub fn litterSoilFlux(inputs: LitterSoilInputs) !LitterSoilFlux {
    inline for (@typeInfo(LitterSoilInputs).@"struct".fields) |field| {
        if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteSurfaceWaterInput;
    }
    if (inputs.litter_cover_fraction < 0 or inputs.litter_cover_fraction > 1 or inputs.wet_litter_cover_fraction < 0 or inputs.wet_litter_cover_fraction > 1 or inputs.litter_temperature_k <= 0 or inputs.soil_temperature_k <= 0 or inputs.liquid_water_heat_capacity_megajoules_per_m3_k <= 0) return error.InvalidSurfaceWaterInput;
    const litter_conductivity = try solver.unsaturatedConductivityM2PerHMpa(.{
        .parameters = inputs.litter_parameters,
        .water_fraction = inputs.litter_water_fraction,
        .matrix_bulk_volume_m3 = inputs.litter_volume_m3,
        .ice_water_equivalent_m3 = inputs.litter_ice_water_equivalent_m3,
        .conductivity_multiplier = inputs.conductivity_multiplier,
        .frozen_hydraulic_impedance_exponent = inputs.frozen_hydraulic_impedance_exponent,
        .ice_density_megagrams_per_m3 = inputs.ice_density_megagrams_per_m3,
        .gravitational_water_potential_mpa_per_m = inputs.gravitational_water_potential_mpa_per_m,
    });
    const soil_conductivity = try solver.unsaturatedConductivityM2PerHMpa(.{
        .parameters = inputs.soil_parameters,
        .water_fraction = inputs.soil_water_fraction,
        .matrix_bulk_volume_m3 = inputs.soil_matrix_bulk_volume_m3,
        .ice_water_equivalent_m3 = inputs.soil_ice_water_equivalent_m3,
        .conductivity_multiplier = inputs.conductivity_multiplier,
        .frozen_hydraulic_impedance_exponent = inputs.frozen_hydraulic_impedance_exponent,
        .ice_density_megagrams_per_m3 = inputs.ice_density_megagrams_per_m3,
        .gravitational_water_potential_mpa_per_m = inputs.gravitational_water_potential_mpa_per_m,
    });
    const litter_total_potential_megapascal = inputs.litter_external_water_potential_megapascal +
        try matricPotentialMpa(inputs.litter_parameters, inputs.litter_water_fraction, inputs.gravitational_water_potential_mpa_per_m);
    const soil_total_potential_megapascal = inputs.soil_external_water_potential_megapascal +
        try matricPotentialMpa(inputs.soil_parameters, inputs.soil_water_fraction, inputs.gravitational_water_potential_mpa_per_m);
    // Scaling both endpoint conductivities scales the harmonic conductance by
    // CVRD exactly; CVRDW scales the face area in FLQX.
    const flux = try water_flux.calculateMatrixFaceFlux(.{ .direction = .vertical, .source_water_m3 = inputs.litter_water_m3, .destination_water_m3 = inputs.soil_matrix_water_m3, .source_air_m3 = inputs.litter_air_m3, .destination_air_m3 = inputs.soil_matrix_air_m3, .source_micropore_volume_m3 = inputs.litter_volume_m3, .destination_micropore_volume_m3 = inputs.soil_matrix_bulk_volume_m3, .source_water_fraction = inputs.litter_water_fraction, .destination_water_fraction = inputs.soil_water_fraction, .source_total_water_potential_megapascal = litter_total_potential_megapascal, .destination_total_water_potential_megapascal = soil_total_potential_megapascal, .source_hydraulic_conductivity_m2_per_h_megapascal = litter_conductivity * inputs.litter_cover_fraction, .destination_hydraulic_conductivity_m2_per_h_megapascal = soil_conductivity * inputs.litter_cover_fraction, .source_path_length_m = inputs.litter_thickness_m, .destination_path_length_m = inputs.soil_thickness_m, .face_area_m2 = inputs.soil_face_area_m2 * inputs.wet_litter_cover_fraction, .time_fraction = inputs.time_fraction, .destination_excess_pore_volume_m3 = inputs.soil_excess_pore_volume_m3 });
    const donor_temperature = if (flux.limited_water_m3 > 0) inputs.litter_temperature_k else inputs.soil_temperature_k;
    return .{ .water_m3 = flux.limited_water_m3, .unenhanced_water_m3 = flux.transport_water_m3, .convective_heat_megajoules = inputs.liquid_water_heat_capacity_megajoules_per_m3_k * donor_temperature * flux.limited_water_m3 };
}

/// Matric potential from the van Genuchten curve, in MPa. Water content is
/// bounded to the curve's own domain so a pool sitting numerically at or below
/// residual does not produce an infinite head.
fn matricPotentialMpa(
    parameters: retention.MualemVanGenuchtenParameters,
    water_fraction: f64,
    gravitational_water_potential_mpa_per_m: f64,
) !f64 {
    const bounded = std.math.clamp(
        water_fraction,
        parameters.residual_water_content_m3_per_m3,
        parameters.saturated_water_content_m3_per_m3,
    );
    const pressure_head_m = try parameters.pressureHeadAtWaterContent(bounded);
    return pressure_head_m * gravitational_water_potential_mpa_per_m;
}

pub fn pondToSoilWaterM3(pond_water_m3: f64, surface_area_m2: f64, time_fraction: f64) !f64 {
    inline for (.{ pond_water_m3, surface_area_m2, time_fraction }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceWaterInput;
    if (pond_water_m3 < 0 or surface_area_m2 <= 0 or time_fraction <= 0 or time_fraction > 1) return error.InvalidSurfaceWaterInput;
    // The retained film is a depth, so it scales with the footprint. Dividing
    // by the area, as this did, made a coarser cell retain *less* total water
    // than a fine one, which is backwards.
    return @max(0.0, pond_water_m3 - pond_retention_depth_m * surface_area_m2) * time_fraction;
}

/// Ponded-water film retained against drainage to the soil surface, as a depth.
/// Numerically equal to the legacy `0.01` on the unit-area decks.
pub const pond_retention_depth_m: f64 = 0.01;

/// Per-step ceiling on the depth of water entering the Manning solve. See the
/// unit argument on `runoff.Parameters.maximum_hydraulic_depth_m`; legacy
/// `watsub.f:3844` compares this same constant against a bare depth.
pub const maximum_hydraulic_depth_m: f64 = 1.0e-3;

pub fn litterOverflowToMacroporeM3(excess_litter_water_m3: f64, macropore_air_m3: f64, time_fraction: f64) !f64 {
    inline for (.{ excess_litter_water_m3, macropore_air_m3, time_fraction }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceWaterInput;
    if (excess_litter_water_m3 < 0 or macropore_air_m3 < 0 or time_fraction <= 0 or time_fraction > 1) return error.InvalidSurfaceWaterInput;
    return @min(excess_litter_water_m3 * time_fraction, macropore_air_m3);
}

pub const StoragePartition = struct {
    retained_liquid_water_m3: f64,
    retained_ice_m3: f64,
    excess_liquid_water_m3: f64,
    excess_ice_m3: f64,
    total_excess_water_and_ice_m3: f64,
};

pub fn partitionSurfaceStorage(liquid_water_m3: f64, ice_water_equivalent_m3: f64, litter_retention_capacity_m3: f64, ice_density_megagrams_per_m3: f64) !StoragePartition {
    inline for (.{ liquid_water_m3, ice_water_equivalent_m3, litter_retention_capacity_m3, ice_density_megagrams_per_m3 }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceWaterInput;
    if (liquid_water_m3 < 0 or ice_water_equivalent_m3 < 0 or litter_retention_capacity_m3 < 0 or ice_density_megagrams_per_m3 <= 0 or ice_density_megagrams_per_m3 > 1) return error.InvalidSurfaceWaterInput;
    const physical_ice_m3 = ice_water_equivalent_m3 / ice_density_megagrams_per_m3;
    const physical_total = liquid_water_m3 + physical_ice_m3;
    const retained_fraction = if (physical_total > 0) @min(1, litter_retention_capacity_m3 / physical_total) else 1;
    const retained_liquid = retained_fraction * liquid_water_m3;
    const retained_ice_we = retained_fraction * ice_water_equivalent_m3;
    return .{ .retained_liquid_water_m3 = retained_liquid, .retained_ice_m3 = retained_ice_we, .excess_liquid_water_m3 = liquid_water_m3 - retained_liquid, .excess_ice_m3 = (ice_water_equivalent_m3 - retained_ice_we) / ice_density_megagrams_per_m3, .total_excess_water_and_ice_m3 = @max(0.0, physical_total - litter_retention_capacity_m3) };
}

pub const RunoffInputs = struct {
    soil_surface_present: bool,
    total_excess_water_and_ice_m3: f64,
    excess_liquid_water_m3: f64,
    ground_surface_retention_capacity_m3: f64,
    soil_surface_depth_m: f64,
    natural_water_table_depth_m: f64,
    surface_area_m2: f64,
    surface_slope: f64,
    roughness_height_m: f64,
    flow_width_m: f64,
};

pub const Runoff = struct { water_m3_per_step: f64, velocity_m_per_s: f64, available_ponded_water_m3: f64 };

/// WATSUB Manning runoff calculation and its per-step availability cap.
/// Directional partitioning remains in surface_solute_routing.zig. The cap is
/// applied as a depth times the footprint so that refining or coarsening the
/// grid does not change per-area overland flow; on the unit-area legacy decks
/// this is numerically identical to the original absolute `1.0e-3`.
pub fn runoff(inputs: RunoffInputs) !Runoff {
    inline for (@typeInfo(RunoffInputs).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteSurfaceWaterInput;
    if (inputs.total_excess_water_and_ice_m3 < 0 or inputs.excess_liquid_water_m3 < 0 or inputs.ground_surface_retention_capacity_m3 < 0 or inputs.surface_area_m2 <= 0 or inputs.surface_slope < 0 or inputs.roughness_height_m <= 0 or inputs.flow_width_m < 0) return error.InvalidSurfaceWaterInput;
    const maximum_hydraulic_volume_m3 = maximum_hydraulic_depth_m * inputs.surface_area_m2;
    const available = if (inputs.soil_surface_present and inputs.total_excess_water_and_ice_m3 > inputs.ground_surface_retention_capacity_m3)
        @min(maximum_hydraulic_volume_m3, (inputs.total_excess_water_and_ice_m3 - inputs.ground_surface_retention_capacity_m3) * if (inputs.total_excess_water_and_ice_m3 > 0) inputs.excess_liquid_water_m3 / inputs.total_excess_water_and_ice_m3 else 0)
    else if (!inputs.soil_surface_present and inputs.soil_surface_depth_m <= inputs.natural_water_table_depth_m)
        // This branch's second operand is a depth in the legacy source, so the
        // cap is compared against a depth and the product converts to volume.
        @min(maximum_hydraulic_depth_m, inputs.natural_water_table_depth_m - inputs.soil_surface_depth_m) * inputs.surface_area_m2
    else
        0;
    if (available <= 0) return .{ .water_m3_per_step = 0, .velocity_m_per_s = 0, .available_ponded_water_m3 = 0 };
    const hydraulic_radius_m = available / inputs.surface_area_m2;
    const velocity = std.math.pow(f64, hydraulic_radius_m, 0.67) * @sqrt(inputs.surface_slope) / inputs.roughness_height_m;
    const requested = velocity * hydraulic_radius_m * inputs.flow_width_m * 3.6e3;
    return .{ .water_m3_per_step = @min(requested, available), .velocity_m_per_s = velocity, .available_ponded_water_m3 = available };
}

pub fn surfaceWaterFilmThicknessM(matric_potential_megapascal: f64, heat_capacity_active: bool) !f64 {
    if (!std.math.isFinite(matric_potential_megapascal) or matric_potential_megapascal >= 0) return error.InvalidSurfaceMatricPotential;
    if (!heat_capacity_active) return 1e-6;
    return @max(1e-6, 0.5 * @exp(-13.650 - 0.857 * @log(-matric_potential_megapascal)));
}

test "surface storage partitions liquid and ice proportionally" {
    const rho = 0.917;
    const result = try partitionSurfaceStorage(0.8, 0.2, 0.5, rho);
    const physical_total = 0.8 + 0.2 / rho;
    const fraction = 0.5 / physical_total;
    try std.testing.expectApproxEqAbs(0.8 * fraction, result.retained_liquid_water_m3, 1e-12);
    try std.testing.expectApproxEqAbs(0.2 * fraction, result.retained_ice_m3, 1e-12);
    try std.testing.expectApproxEqAbs(physical_total - 0.5, result.total_excess_water_and_ice_m3, 1e-12);
}

test "topsoil freezing displacement enters litter with donor heat" {
    const litter_parameters: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.01,
        .saturated_water_content_m3_per_m3 = 0.5,
        .alpha_per_m = 3,
        .n = 1.5,
        .saturated_hydraulic_conductivity_m_per_h = 0,
    };
    const soil_parameters: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.05,
        .saturated_water_content_m3_per_m3 = 0.5,
        .alpha_per_m = 3.6,
        .n = 1.56,
        .saturated_hydraulic_conductivity_m_per_h = 0,
    };
    const result = try litterSoilFlux(.{
        .litter_water_m3 = 0.1,
        .soil_matrix_water_m3 = 0.31,
        .litter_air_m3 = 0.9,
        .soil_matrix_air_m3 = 0,
        .litter_volume_m3 = 1,
        .soil_matrix_bulk_volume_m3 = 1,
        .litter_water_fraction = 0.1,
        .soil_water_fraction = 0.31,
        .litter_parameters = litter_parameters,
        .soil_parameters = soil_parameters,
        .litter_external_water_potential_megapascal = 0,
        .soil_external_water_potential_megapascal = 0,
        .litter_thickness_m = 0.1,
        .soil_thickness_m = 0.1,
        .soil_face_area_m2 = 0,
        .litter_cover_fraction = 0,
        .wet_litter_cover_fraction = 0,
        .time_fraction = 1,
        .soil_excess_pore_volume_m3 = -0.01,
        .litter_temperature_k = 280,
        .soil_temperature_k = 270,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
    });
    try std.testing.expectEqual(@as(f64, -0.01), result.water_m3);
    try std.testing.expectEqual(result.water_m3, result.unenhanced_water_m3);
    try std.testing.expectApproxEqAbs(@as(f64, -4.19 * 270 * 0.01), result.convective_heat_megajoules, 32 * std.math.floatEps(f64));
}

test "bare topsoil freezing displacement enters surface pond conservatively" {
    const soil_water_before_m3: f64 = 0.31;
    const surface_water_before_m3: f64 = 0.04;
    const result = try bareSurfaceSoilFreezingFlux(
        soil_water_before_m3,
        -0.01,
        1,
        270,
        4.19,
    );
    const soil_water_after_m3 = soil_water_before_m3 + result.water_m3;
    const surface_water_after_m3 = surface_water_before_m3 - result.water_m3;
    try std.testing.expectEqual(@as(f64, -0.01), result.water_m3);
    try std.testing.expectEqual(
        soil_water_before_m3 + surface_water_before_m3,
        soil_water_after_m3 + surface_water_after_m3,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, -4.19 * 270 * 0.01),
        result.convective_heat_megajoules,
        32 * std.math.floatEps(f64),
    );
}

test "Manning runoff is capped by available ponded water" {
    const result = try runoff(.{ .soil_surface_present = true, .total_excess_water_and_ice_m3 = 1, .excess_liquid_water_m3 = 1, .ground_surface_retention_capacity_m3 = 0, .soil_surface_depth_m = 0, .natural_water_table_depth_m = 1, .surface_area_m2 = 1, .surface_slope = 1, .roughness_height_m = 0.01, .flow_width_m = 1 });
    try std.testing.expectEqual(@as(f64, 1e-3), result.available_ponded_water_m3);
    try std.testing.expect(result.water_m3_per_step <= 1e-3);
    try std.testing.expect(result.velocity_m_per_s > 0);
}

test "GRID-INV-S1 surface runoff depth is invariant to cell footprint" {
    // Same physical state (0.1 m of ponded excess, same slope, same roughness),
    // expressed on cells spanning four orders of magnitude in footprint. A
    // grid-invariant kernel must report the same runoff *depth* from each.
    const ponded_depth_m: f64 = 0.1;
    var reference_depth_m: f64 = undefined;
    for ([_]f64{ 1, 10, 100, 1.0e4 }, 0..) |area_m2, index| {
        const result = try runoff(.{
            .soil_surface_present = true,
            .total_excess_water_and_ice_m3 = ponded_depth_m * area_m2,
            .excess_liquid_water_m3 = ponded_depth_m * area_m2,
            .ground_surface_retention_capacity_m3 = 0,
            .soil_surface_depth_m = 0,
            .natural_water_table_depth_m = 1,
            .surface_area_m2 = area_m2,
            .surface_slope = 1,
            .roughness_height_m = 0.01,
            // Flow width is a length, so it scales as the square root of a
            // square footprint; holding it fixed would confound the test.
            .flow_width_m = @sqrt(area_m2),
        });
        try std.testing.expect(result.water_m3_per_step > 0);
        const depth_m = result.water_m3_per_step / area_m2;
        if (index == 0) reference_depth_m = depth_m;
        // Relative, because the quantity itself spans four decades in volume.
        try std.testing.expectApproxEqRel(reference_depth_m, depth_m, 1e-12);
        try std.testing.expectApproxEqRel(
            maximum_hydraulic_depth_m,
            result.available_ponded_water_m3 / area_m2,
            1e-12,
        );
    }
}

test "GRID-INV-S1 pond retention depth is invariant to cell footprint" {
    const ponded_depth_m: f64 = 0.1;
    var reference_depth_m: f64 = undefined;
    for ([_]f64{ 1, 10, 100, 1.0e4 }, 0..) |area_m2, index| {
        const drained_m3 = try pondToSoilWaterM3(ponded_depth_m * area_m2, area_m2, 1);
        const depth_m = drained_m3 / area_m2;
        if (index == 0) reference_depth_m = depth_m;
        try std.testing.expectApproxEqRel(reference_depth_m, depth_m, 1e-12);
    }
    // And the retained film is the documented depth, not a per-cell artifact.
    try std.testing.expectApproxEqRel(
        @as(f64, 0.1 - pond_retention_depth_m),
        try pondToSoilWaterM3(0.1 * 100, 100, 1) / 100,
        1e-12,
    );
}

test "pond and litter overflow preserve source limits" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.09), try pondToSoilWaterM3(0.1, 1, 1), 1e-12);
    try std.testing.expectEqual(@as(f64, 0.02), try litterOverflowToMacroporeM3(0.1, 0.02, 1));
}
