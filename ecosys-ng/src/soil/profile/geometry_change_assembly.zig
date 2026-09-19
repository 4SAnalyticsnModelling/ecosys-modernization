const std = @import("std");
const Geometry = @import("layer_geometry.zig");
const DepthDisturbance = @import("depth_disturbance.zig");

/// Reconstructs the REDIST SOC accumulation reset at the deepest layer and at
/// an organic-to-mineral horizon crossing. Pond-underlayer resets can be ORed
/// into the caller-owned result when runtime pond layers are present.
pub fn buildOrganicAccumulationReset(
    reset_by_layer: []bool,
    geometry: *const Geometry.State,
    organic_carbon_g_c_per_megagram: []const f64,
    organic_horizon_threshold_g_c_per_megagram: f64,
) !void {
    const layer_count = geometry.cell_count * geometry.layer_capacity;
    if (reset_by_layer.len != layer_count or organic_carbon_g_c_per_megagram.len != layer_count) return error.SoilGeometryChangeAssemblyDimensionMismatch;
    if (!std.math.isFinite(organic_horizon_threshold_g_c_per_megagram) or organic_horizon_threshold_g_c_per_megagram < 0) return error.InvalidOrganicHorizonThreshold;
    for (organic_carbon_g_c_per_megagram) |concentration| if (!std.math.isFinite(concentration) or concentration < 0) return error.InvalidOrganicCarbonConcentration;
    for (0..geometry.cell_count) |cell| {
        const first = geometry.first_active_layer[cell];
        const active_count = geometry.active_layer_count[cell];
        if (active_count == 0 or first + active_count > geometry.layer_capacity) return error.InvalidOrganicCarbonActiveLayerRange;
    }
    @memset(reset_by_layer, false);
    for (0..geometry.cell_count) |cell| {
        const first = geometry.first_active_layer[cell];
        const end = first + geometry.active_layer_count[cell];
        const base = cell * geometry.layer_capacity;
        reset_by_layer[base + end - 1] = true;
        for (first..end - 1) |layer| {
            reset_by_layer[base + layer] =
                organic_carbon_g_c_per_megagram[base + layer] >= organic_horizon_threshold_g_c_per_megagram and
                organic_carbon_g_c_per_megagram[base + layer + 1] < organic_horizon_threshold_g_c_per_megagram;
        }
    }
}

/// Builds REDIST `DDLYXE` for every active boundary. Erosion/deposition shifts
/// the entire soil profile datum uniformly and therefore preserves all layer
/// thicknesses. Positive sediment is deposition; negative sediment is erosion.
///
/// Deliberately does not reproduce the legacy f77src/redist.f:7842-7864
/// (`NN=3` erosion leg of the `DO 225` loop) top-of-profile boundary-carry
/// omission -- unlike the pond/freeze-thaw/SOC-active-arm siblings, the
/// erosion leg's soil branch never writes `DDLYX(LX-1,3)`/`DDLYR(LX-1,3)`
/// when `LX.EQ.NU`. Assigning every boundary explicitly here (including the
/// top one, via the loop bound `end_boundary + 1`) avoids that gap as a side
/// effect of this uniform design (see
/// audit/issues/issue-035-redist-erosion-soc-top-boundary-carry-omission.md).
pub fn assembleErosionBoundaryChangeM(
    output_boundary_change_m: []f64,
    geometry: *const Geometry.State,
    net_sediment_megagrams_by_cell: []const f64,
    snow_deposited_sediment_megagrams_by_cell: []const f64,
    horizontal_area_m2_by_cell: []const f64,
    surface_soil_mass_megagrams_by_cell: []const f64,
    surface_soil_volume_m3_by_cell: []const f64,
    receiving_soil_bulk_density_megagrams_per_m3_by_cell: []const f64,
    enabled: bool,
    negligible_sediment_megagrams: f64,
) !void {
    const boundary_count = geometry.cell_count * (geometry.layer_capacity + 1);
    if (output_boundary_change_m.len != boundary_count or net_sediment_megagrams_by_cell.len != geometry.cell_count or snow_deposited_sediment_megagrams_by_cell.len != geometry.cell_count or horizontal_area_m2_by_cell.len != geometry.cell_count or surface_soil_mass_megagrams_by_cell.len != geometry.cell_count or surface_soil_volume_m3_by_cell.len != geometry.cell_count or receiving_soil_bulk_density_megagrams_per_m3_by_cell.len != geometry.cell_count) return error.SoilGeometryChangeAssemblyDimensionMismatch;
    if (!std.math.isFinite(negligible_sediment_megagrams) or negligible_sediment_megagrams < 0) return error.InvalidErosionGeometryThreshold;
    for (0..geometry.cell_count) |cell| {
        inline for (.{ net_sediment_megagrams_by_cell[cell], snow_deposited_sediment_megagrams_by_cell[cell], horizontal_area_m2_by_cell[cell], surface_soil_mass_megagrams_by_cell[cell], surface_soil_volume_m3_by_cell[cell], receiving_soil_bulk_density_megagrams_per_m3_by_cell[cell] }) |value| if (!std.math.isFinite(value)) return error.InvalidErosionGeometryInput;
        if (horizontal_area_m2_by_cell[cell] <= 0 or surface_soil_mass_megagrams_by_cell[cell] <= 0 or surface_soil_volume_m3_by_cell[cell] <= 0 or receiving_soil_bulk_density_megagrams_per_m3_by_cell[cell] <= 0 or snow_deposited_sediment_megagrams_by_cell[cell] < 0) return error.InvalidErosionGeometryInput;
        const first = geometry.first_active_layer[cell];
        const active_count = geometry.active_layer_count[cell];
        if (active_count == 0 or first + active_count > geometry.layer_capacity) return error.InvalidErosionActiveLayerRange;
        if (enabled and (@abs(net_sediment_megagrams_by_cell[cell]) > negligible_sediment_megagrams or snow_deposited_sediment_megagrams_by_cell[cell] > negligible_sediment_megagrams)) {
            _ = try DepthDisturbance.erosionDepthChange_m(.{
                .net_sediment_megagrams = net_sediment_megagrams_by_cell[cell],
                .snow_deposited_sediment_megagrams = snow_deposited_sediment_megagrams_by_cell[cell],
                .horizontal_area_m2 = horizontal_area_m2_by_cell[cell],
                .surface_soil_mass_megagrams = surface_soil_mass_megagrams_by_cell[cell],
                .surface_soil_volume_m3 = surface_soil_volume_m3_by_cell[cell],
                .receiving_soil_bulk_density_megagrams_per_m3 = receiving_soil_bulk_density_megagrams_per_m3_by_cell[cell],
            });
        }
    }

    @memset(output_boundary_change_m, 0);
    if (!enabled) return;
    for (0..geometry.cell_count) |cell| {
        const net_sediment_megagrams = net_sediment_megagrams_by_cell[cell];
        const snow_sediment_megagrams = snow_deposited_sediment_megagrams_by_cell[cell];
        if (@abs(net_sediment_megagrams) <= negligible_sediment_megagrams and snow_sediment_megagrams <= negligible_sediment_megagrams) continue;
        const change_m = try DepthDisturbance.erosionDepthChange_m(.{
            .net_sediment_megagrams = net_sediment_megagrams,
            .snow_deposited_sediment_megagrams = snow_sediment_megagrams,
            .horizontal_area_m2 = horizontal_area_m2_by_cell[cell],
            .surface_soil_mass_megagrams = surface_soil_mass_megagrams_by_cell[cell],
            .surface_soil_volume_m3 = surface_soil_volume_m3_by_cell[cell],
            .receiving_soil_bulk_density_megagrams_per_m3 = receiving_soil_bulk_density_megagrams_per_m3_by_cell[cell],
        });
        const first = geometry.first_active_layer[cell];
        const end_boundary = first + geometry.active_layer_count[cell];
        const boundary_base = cell * (geometry.layer_capacity + 1);
        for (first..end_boundary + 1) |boundary| output_boundary_change_m[boundary_base + boundary] = change_m;
    }
}

/// Builds REDIST `DDLYX(*,4)`/`DDLYR(*,4)`. `reset_accumulation_by_layer`
/// represents the exact source branch at the profile bottom, below a pond, or
/// across the configured organic-carbon horizon (`CORGC >= FORGC` above and
/// `< FORGC` below).
pub fn assembleOrganicCarbonBoundaryChangeM(
    output_boundary_change_m: []f64,
    geometry: *const Geometry.State,
    organic_carbon_change_g_c: []const f64,
    macropore_fraction: []const f64,
    reference_bulk_density_megagrams_per_m3: []const f64,
    initial_layer_thickness_m: []const f64,
    current_layer_thickness_m: []const f64,
    reset_accumulation_by_layer: []const bool,
    horizontal_area_m2_by_cell: []const f64,
    organic_carbon_specific_volume_m3_per_g: f64,
    enabled: bool,
    negligible_carbon_change_g_c: f64,
) !void {
    const layer_count = geometry.cell_count * geometry.layer_capacity;
    const boundary_count = geometry.cell_count * (geometry.layer_capacity + 1);
    if (output_boundary_change_m.len != boundary_count or organic_carbon_change_g_c.len != layer_count or macropore_fraction.len != layer_count or reference_bulk_density_megagrams_per_m3.len != layer_count or initial_layer_thickness_m.len != layer_count or current_layer_thickness_m.len != layer_count or reset_accumulation_by_layer.len != layer_count or horizontal_area_m2_by_cell.len != geometry.cell_count) return error.SoilGeometryChangeAssemblyDimensionMismatch;
    if (!std.math.isFinite(organic_carbon_specific_volume_m3_per_g) or organic_carbon_specific_volume_m3_per_g <= 0 or !std.math.isFinite(negligible_carbon_change_g_c) or negligible_carbon_change_g_c < 0) return error.InvalidOrganicCarbonGeometryParameter;
    for (horizontal_area_m2_by_cell) |area_m2| if (!std.math.isFinite(area_m2) or area_m2 <= 0) return error.InvalidOrganicCarbonGeometryArea;
    for (organic_carbon_change_g_c, macropore_fraction, reference_bulk_density_megagrams_per_m3, initial_layer_thickness_m, current_layer_thickness_m) |carbon_change_g_c, macro_fraction, bulk_density, initial_thickness, current_thickness| {
        inline for (.{ carbon_change_g_c, macro_fraction, bulk_density, initial_thickness, current_thickness }) |value| if (!std.math.isFinite(value)) return error.InvalidOrganicCarbonGeometryLayer;
        if (macro_fraction < 0 or macro_fraction >= 1 or bulk_density < 0 or initial_thickness <= 0 or current_thickness <= 0) return error.InvalidOrganicCarbonGeometryLayer;
    }
    for (0..geometry.cell_count) |cell| {
        const first = geometry.first_active_layer[cell];
        const active_count = geometry.active_layer_count[cell];
        if (active_count == 0 or first + active_count > geometry.layer_capacity) return error.InvalidOrganicCarbonActiveLayerRange;
    }

    @memset(output_boundary_change_m, 0);
    if (!enabled) return;
    for (0..geometry.cell_count) |cell| {
        const first = geometry.first_active_layer[cell];
        const active_count = geometry.active_layer_count[cell];
        const layer_base = cell * geometry.layer_capacity;
        const boundary_base = cell * (geometry.layer_capacity + 1);
        var deeper_cumulative_m: f64 = 0;
        var offset = active_count;
        while (offset > 0) {
            offset -= 1;
            const layer = first + offset;
            const index = layer_base + layer;
            const carbon_change_g_c = organic_carbon_change_g_c[index];
            var current_cumulative_m: f64 = deeper_cumulative_m;
            var bottom_boundary_change_m: f64 = deeper_cumulative_m;
            if (@abs(carbon_change_g_c) > negligible_carbon_change_g_c) {
                // Open-water slots have no mineral-mass depth carrier. They
                // are valid when unchanged, but a nonzero mineral SOC geometry
                // contribution on such a slot is scientifically undefined.
                if (reference_bulk_density_megagrams_per_m3[index] <= 0)
                    return error.InvalidOrganicCarbonGeometryLayer;
                const local_change_m = try DepthDisturbance.organicCarbonDepthChange_m(.{
                    .organic_carbon_change_g = carbon_change_g_c,
                    .horizontal_area_m2 = horizontal_area_m2_by_cell[cell],
                    .macropore_fraction = macropore_fraction[index],
                    .reference_bulk_density_megagrams_per_m3 = reference_bulk_density_megagrams_per_m3[index],
                    .organic_carbon_specific_volume_m3_per_g = organic_carbon_specific_volume_m3_per_g,
                });
                if (reset_accumulation_by_layer[index]) {
                    current_cumulative_m = local_change_m;
                    bottom_boundary_change_m = 0;
                } else {
                    current_cumulative_m = local_change_m + deeper_cumulative_m;
                    bottom_boundary_change_m = deeper_cumulative_m + initial_layer_thickness_m[index] - current_layer_thickness_m[index];
                }
            }
            if (!std.math.isFinite(current_cumulative_m) or !std.math.isFinite(bottom_boundary_change_m)) return error.NonFiniteOrganicCarbonGeometryChange;
            output_boundary_change_m[boundary_base + layer + 1] = bottom_boundary_change_m;
            deeper_cumulative_m = current_cumulative_m;
        }
        // Deliberately does not reproduce the legacy f77src/redist.f:7920-7930
        // (`NN=4` SOC leg's negligible arm of the `DO 225` loop) top-of-profile
        // boundary-carry omission -- this unconditional write at the top
        // boundary runs regardless of whether the top layer's own
        // organic-carbon change was itself negligible (see
        // audit/issues/issue-035-redist-erosion-soc-top-boundary-carry-omission.md).
        output_boundary_change_m[boundary_base + first] = deeper_cumulative_m;
    }
}

/// Builds REDIST `DDLYX(*,2)`/`DDLYR(*,2)` boundary changes from the accepted
/// WATSUB `DVOLI` ledger. The bottom datum remains fixed; displacement is
/// accumulated from the deepest active layer toward the surface.
pub fn assembleFreezeThawBoundaryChangeM(
    output_boundary_change_m: []f64,
    geometry: *const Geometry.State,
    total_ice_volume_change_m3: []const f64,
    soil_matrix_fraction: []const f64,
    horizontal_area_m2_by_cell: []const f64,
    ice_to_water_specific_volume_difference: f64,
    negligible_ice_volume_change_m3: f64,
) !void {
    const layer_count = geometry.cell_count * geometry.layer_capacity;
    const boundary_count = geometry.cell_count * (geometry.layer_capacity + 1);
    if (output_boundary_change_m.len != boundary_count or total_ice_volume_change_m3.len != layer_count or soil_matrix_fraction.len != layer_count or horizontal_area_m2_by_cell.len != geometry.cell_count) return error.SoilGeometryChangeAssemblyDimensionMismatch;
    if (!std.math.isFinite(ice_to_water_specific_volume_difference) or ice_to_water_specific_volume_difference < 0 or !std.math.isFinite(negligible_ice_volume_change_m3) or negligible_ice_volume_change_m3 < 0) return error.InvalidFreezeThawGeometryParameter;
    for (horizontal_area_m2_by_cell) |area_m2| if (!std.math.isFinite(area_m2) or area_m2 <= 0) return error.InvalidFreezeThawGeometryArea;
    for (total_ice_volume_change_m3, soil_matrix_fraction) |ice_change_m3, matrix_fraction| {
        if (!std.math.isFinite(ice_change_m3) or !std.math.isFinite(matrix_fraction) or matrix_fraction <= 0 or matrix_fraction > 1) return error.InvalidFreezeThawGeometryLayer;
        const displacement_m = ice_change_m3 * ice_to_water_specific_volume_difference / matrix_fraction;
        if (!std.math.isFinite(displacement_m)) return error.NonFiniteFreezeThawGeometryChange;
    }

    @memset(output_boundary_change_m, 0);
    for (0..geometry.cell_count) |cell| {
        const first = geometry.first_active_layer[cell];
        const active_count = geometry.active_layer_count[cell];
        if (active_count == 0 or first + active_count > geometry.layer_capacity) return error.InvalidFreezeThawActiveLayerRange;
        const boundary_base = cell * (geometry.layer_capacity + 1);
        const layer_base = cell * geometry.layer_capacity;
        var cumulative_change_m: f64 = 0;
        var offset = active_count;
        while (offset > 0) {
            offset -= 1;
            const layer = first + offset;
            const ice_change_m3 = total_ice_volume_change_m3[layer_base + layer];
            if (@abs(ice_change_m3) > negligible_ice_volume_change_m3) {
                cumulative_change_m += ice_change_m3 * ice_to_water_specific_volume_difference /
                    (soil_matrix_fraction[layer_base + layer] * horizontal_area_m2_by_cell[cell]);
            }
            if (!std.math.isFinite(cumulative_change_m)) return error.NonFiniteFreezeThawGeometryChange;
            output_boundary_change_m[boundary_base + layer] = cumulative_change_m;
        }
        // boundary `first + active_count` remains zero: REDIST anchors the
        // bottom profile datum and expands or contracts upward.
    }
}

test "REDIST freeze thaw assembly accumulates DVOLI upward from a fixed bottom" {
    var geometry = try Geometry.State.init(std.testing.allocator, 1, 3);
    defer geometry.deinit();
    try Geometry.initializeCell(&geometry, 0, 0, &.{ 0.1, 0.2, 0.3 }, 0, 1e-9);
    var boundary_change = [_]f64{0} ** 4;
    try assembleFreezeThawBoundaryChangeM(&boundary_change, &geometry, &.{ 1, -0.5, 2 }, &.{ 0.5, 0.5, 1 }, &.{10}, 0.1, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.03), boundary_change[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), boundary_change[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), boundary_change[2], 1e-14);
    try std.testing.expectEqual(@as(f64, 0), boundary_change[3]);
}

test "REDIST freeze thaw assembly validates before clearing caller output" {
    var geometry = try Geometry.State.init(std.testing.allocator, 1, 1);
    defer geometry.deinit();
    var boundary_change = [_]f64{ 7, 8 };
    try std.testing.expectError(error.InvalidFreezeThawGeometryLayer, assembleFreezeThawBoundaryChangeM(&boundary_change, &geometry, &.{1}, &.{0}, &.{1}, 0.083, 0));
    try std.testing.expectEqualSlices(f64, &.{ 7, 8 }, &boundary_change);
}

test "REDIST erosion assembly shifts the datum without changing thickness" {
    var geometry = try Geometry.State.init(std.testing.allocator, 1, 2);
    defer geometry.deinit();
    try Geometry.initializeCell(&geometry, 0, 0, &.{ 0.2, 0.3 }, 0, 1e-9);
    var erosion = [_]f64{0} ** 3;
    try assembleErosionBoundaryChangeM(&erosion, &geometry, &.{-2}, &.{0.5}, &.{10}, &.{20}, &.{10}, &.{1}, true, 1e-12);
    // -2 Mg / (10 m2 * 2 Mg m-3) + 0.5 Mg / (10 m2 * 1 Mg m-3)
    try std.testing.expectApproxEqAbs(@as(f64, -0.05), erosion[0], 1e-14);
    try std.testing.expectEqualSlices(f64, &.{ erosion[0], erosion[0], erosion[0] }, &erosion);
    const zero = [_]f64{0} ** 3;
    try Geometry.applyDisturbances(&geometry, .{ .pond_m = &zero, .freeze_thaw_m = &zero, .erosion_m = &erosion, .organic_carbon_m = &zero }, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), geometry.layer_thickness_m[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), geometry.layer_thickness_m[1], 1e-14);
}

test "REDIST SOC assembly retains horizon reset and thickness correction" {
    var geometry = try Geometry.State.init(std.testing.allocator, 1, 3);
    defer geometry.deinit();
    try Geometry.initializeCell(&geometry, 0, 0, &.{ 0.1, 0.2, 0.3 }, 0, 1e-9);
    var carbon = [_]f64{0} ** 4;
    try assembleOrganicCarbonBoundaryChangeM(
        &carbon,
        &geometry,
        &.{ 100, 200, 300 },
        &.{ 0, 0, 0 },
        &.{ 1, 1, 1 },
        &.{ 0.11, 0.22, 0.3 },
        &.{ 0.1, 0.2, 0.3 },
        &.{ false, true, true },
        &.{10},
        1.0e-6,
        true,
        0,
    );
    // Bottom reset: 300e-6/10 = 3e-5 m. The middle horizon resets again.
    // The top adds its local 1e-5 m above the middle 2e-5 m cumulative;
    // its bottom boundary also retains the 0.01 m initial-current correction.
    try std.testing.expectApproxEqAbs(@as(f64, 3e-5), carbon[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.002e-2), carbon[1], 1e-14);
    try std.testing.expectEqual(@as(f64, 0), carbon[2]);
    try std.testing.expectEqual(@as(f64, 0), carbon[3]);
}

test "REDIST SOC assembly skips unchanged zero-density open-water layer" {
    var geometry = try Geometry.State.init(std.testing.allocator, 1, 2);
    defer geometry.deinit();
    try Geometry.initializeCell(&geometry, 0, 0, &.{ 0.1, 0.2 }, 0, 1e-9);
    var carbon = [_]f64{0} ** 3;
    try assembleOrganicCarbonBoundaryChangeM(
        &carbon,
        &geometry,
        &.{ 0, 10 },
        &.{ 0, 0 },
        &.{ 0, 1 },
        &.{ 0.1, 0.2 },
        &.{ 0.1, 0.2 },
        &.{ false, true },
        &.{1},
        1e-6,
        true,
        0,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1e-5), carbon[0], 1e-15);
    // The unchanged water slot contributes no local depth, while the deeper
    // mineral displacement still propagates through both of its boundaries.
    try std.testing.expectApproxEqAbs(@as(f64, 1e-5), carbon[1], 1e-15);
    try std.testing.expectEqual(@as(f64, 0), carbon[2]);
    try std.testing.expectError(
        error.InvalidOrganicCarbonGeometryLayer,
        assembleOrganicCarbonBoundaryChangeM(
            &carbon,
            &geometry,
            &.{ 1, 10 },
            &.{ 0, 0 },
            &.{ 0, 1 },
            &.{ 0.1, 0.2 },
            &.{ 0.1, 0.2 },
            &.{ false, true },
            &.{1},
            1e-6,
            true,
            0,
        ),
    );
}

test "REDIST SOC reset mask uses runtime FORGC and deepest active layers" {
    var geometry = try Geometry.State.init(std.testing.allocator, 2, 4);
    defer geometry.deinit();
    try Geometry.initializeCell(&geometry, 0, 0, &.{ 0.1, 0.1, 0.1, 0.1 }, 0, 1e-9);
    try Geometry.initializeCell(&geometry, 1, 1, &.{ 0.2, 0.2 }, 0, 1e-9);
    var reset = [_]bool{false} ** 8;
    try buildOrganicAccumulationReset(&reset, &geometry, &.{ 150_000, 120_000, 90_000, 80_000, 0, 130_000, 80_000, 0 }, 110_000);
    try std.testing.expectEqualSlices(bool, &.{ false, true, false, true }, reset[0..4]);
    try std.testing.expectEqualSlices(bool, &.{ false, true, true, false }, reset[4..8]);
}
