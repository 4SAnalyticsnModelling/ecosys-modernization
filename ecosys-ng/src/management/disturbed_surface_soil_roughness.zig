//! HOUR1 2927--2967 disturbed-surface runoff roughness (`ZM`).
//!
//! This is deliberately not aerodynamic `ZS/ZR`: HOUR1 2369--2371 selects
//! those independently from the soil/snow constants, while WATSUB 3850 alone
//! consumes `ZM` in the Manning runoff velocity. Production refreshes `ZM`
//! hourly from accepted extensive owners before aerodynamic and runoff work;
//! snow therefore retains its separate explicit aerodynamic override.
const std = @import("std");
const organic = @import("../soil/organic/initialization.zig");

pub const Inputs = struct {
    organic_carbon_g: f64,
    organic_residue_g: f64,
    bulk_volume_m3: f64,
    minimum_bulk_volume_m3: f64,
    sand_megagrams: f64,
    silt_megagrams: f64,
    clay_megagrams: f64,
    bulk_density_megagrams_m3: f64,
    surface_litter_volume_m3: f64,
    grid_cell_area_m2: f64,
    stalk_area_m2: f64,
    canopy_height_m: f64,
    mass_threshold_megagrams: f64,
    bulk_density_threshold_megagrams_m3: f64,
};

pub const Result = struct {
    adjusted_bulk_volume_m3: f64,
    organic_carbon_mass_fraction: f64,
    organic_residue_mass_fraction: f64,
    organic_carbon_concentration_g_per_megagram: f64,
    sand_mass_fraction: f64,
    silt_mass_fraction: f64,
    clay_mass_fraction: f64,
    characteristic_particle_size_um: f64,
    particle_roughness_m: f64,
    soil_surface_roughness_m: f64,
    total_surface_roughness_m: f64,
};

pub const RefreshTolerance = struct {
    soil_mass_absolute_megagrams: f64,
    volume_absolute_m3: f64,
    relative: f64,
};

/// Live HOUR1 owners. The top layer is geometry's current `NU`, not a fixed
/// layer-zero assumption, so relayering and pond transitions cannot redirect
/// the refresh to an inactive sentinel.
pub const RefreshContext = struct {
    surface_roughness_m: []f64,
    soil_layer_capacity: usize,
    first_active_layer_by_cell: []const usize,
    active_layer_count_by_cell: []const usize,
    soil_organic: *const organic.State,
    matrix_bulk_volume_m3: []const f64,
    sand_mass_megagrams: []const f64,
    silt_mass_megagrams: []const f64,
    clay_mass_megagrams: []const f64,
    bulk_density_megagrams_per_m3: []const f64,
    surface_litter_volume_m3: []const f64,
    grid_cell_area_m2: []const f64,
    stalk_area_m2: []const f64,
    canopy_height_m: []const f64,
    tolerance: RefreshTolerance,
};

pub const CalculationError = error{
    NonFiniteInput,
    NegativeInput,
    InvalidGridCellArea,
    InvalidCanopyHeight,
    NonFiniteResult,
};

/// Translates `hour1.f` lines 2927--2967 in legacy operation order.
pub fn calculate(inputs: Inputs) CalculationError!Result {
    inline for (std.meta.fields(Inputs)) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteInput;
        if (value < 0.0) return error.NegativeInput;
    }
    if (inputs.grid_cell_area_m2 <= 0.0) return error.InvalidGridCellArea;

    const organic_carbon_g = inputs.organic_carbon_g;
    const organic_residue_g = inputs.organic_residue_g;
    const adjusted_bulk_volume_m3 = @max(
        inputs.bulk_volume_m3,
        inputs.minimum_bulk_volume_m3 + 1.82e-6 * organic_carbon_g,
    );
    const normalized_mass_megagrams = inputs.sand_megagrams + inputs.silt_megagrams +
        inputs.clay_megagrams + 1.82e-6 * organic_carbon_g;

    var organic_carbon_fraction: f64 = 0.0;
    var organic_residue_fraction: f64 = 0.0;
    var organic_carbon_concentration_g_per_megagram: f64 = 0.0;
    var sand_fraction: f64 = 0.0;
    var silt_fraction: f64 = 1.0;
    var clay_fraction: f64 = 0.0;
    if (normalized_mass_megagrams > inputs.mass_threshold_megagrams) {
        organic_carbon_fraction = 1.82e-6 * organic_carbon_g / normalized_mass_megagrams;
        organic_residue_fraction = 1.82e-6 * organic_residue_g / normalized_mass_megagrams;
        organic_carbon_concentration_g_per_megagram = 0.55e6 * organic_carbon_fraction;
        sand_fraction = inputs.sand_megagrams / normalized_mass_megagrams;
        silt_fraction = inputs.silt_megagrams / normalized_mass_megagrams;
        clay_fraction = inputs.clay_megagrams / normalized_mass_megagrams;
    }

    const humified_organic_fraction = organic_carbon_fraction - organic_residue_fraction;
    var characteristic_particle_size_um: f64 = 0.0;
    var particle_roughness_m: f64 = 0.0;
    var soil_surface_roughness_m: f64 = 0.001;
    if (inputs.bulk_density_megagrams_m3 > inputs.bulk_density_threshold_megagrams_m3) {
        characteristic_particle_size_um = 1.0 * clay_fraction +
            10.0 * silt_fraction + 100.0 * sand_fraction +
            10.0 * humified_organic_fraction + 100.0 * organic_residue_fraction;
        particle_roughness_m = 0.041 *
            std.math.pow(f64, 1.0e-6 * characteristic_particle_size_um, 0.167);
        soil_surface_roughness_m = 0.01;
    }
    const total_surface_roughness_m = particle_roughness_m + soil_surface_roughness_m +
        1.0 * @min(
            soil_surface_roughness_m,
            inputs.surface_litter_volume_m3 / inputs.grid_cell_area_m2,
        ) +
        0.1 * inputs.stalk_area_m2 / inputs.grid_cell_area_m2 *
            soil_surface_roughness_m / @max(soil_surface_roughness_m, inputs.canopy_height_m);

    const result = Result{
        .adjusted_bulk_volume_m3 = adjusted_bulk_volume_m3,
        .organic_carbon_mass_fraction = organic_carbon_fraction,
        .organic_residue_mass_fraction = organic_residue_fraction,
        .organic_carbon_concentration_g_per_megagram = organic_carbon_concentration_g_per_megagram,
        .sand_mass_fraction = sand_fraction,
        .silt_mass_fraction = silt_fraction,
        .clay_mass_fraction = clay_fraction,
        .characteristic_particle_size_um = characteristic_particle_size_um,
        .particle_roughness_m = particle_roughness_m,
        .soil_surface_roughness_m = soil_surface_roughness_m,
        .total_surface_roughness_m = total_surface_roughness_m,
    };
    inline for (std.meta.fields(Result)) |field| {
        if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteResult;
    }
    return result;
}

/// Recomputes all cells transactionally. The first pass validates every
/// authoritative owner and candidate, so a bad later cell cannot publish an
/// earlier cell's `ZM`.
pub fn refresh(context: RefreshContext) !void {
    const cells = context.surface_roughness_m.len;
    const layers = std.math.mul(usize, cells, context.soil_layer_capacity) catch
        return error.DisturbedSurfaceRoughnessDimensionMismatch;
    if (cells == 0 or context.soil_layer_capacity == 0 or
        context.first_active_layer_by_cell.len != cells or
        context.active_layer_count_by_cell.len != cells or
        context.soil_organic.layer_count != layers or
        context.matrix_bulk_volume_m3.len != layers or
        context.sand_mass_megagrams.len != layers or
        context.silt_mass_megagrams.len != layers or
        context.clay_mass_megagrams.len != layers or
        context.bulk_density_megagrams_per_m3.len != layers or
        context.surface_litter_volume_m3.len != cells or
        context.grid_cell_area_m2.len != cells or
        context.stalk_area_m2.len != cells or
        context.canopy_height_m.len != cells)
        return error.DisturbedSurfaceRoughnessDimensionMismatch;
    inline for (.{
        context.tolerance.soil_mass_absolute_megagrams,
        context.tolerance.volume_absolute_m3,
        context.tolerance.relative,
    }) |value| if (!std.math.isFinite(value) or value <= 0)
        return error.InvalidDisturbedSurfaceRoughnessTolerance;

    for (0..cells) |cell| _ = try candidateForCell(context, cell);
    for (0..cells) |cell|
        context.surface_roughness_m[cell] =
            (try candidateForCell(context, cell)).total_surface_roughness_m;
}

fn candidateForCell(context: RefreshContext, cell: usize) !Result {
    const first = context.first_active_layer_by_cell[cell];
    const active = context.active_layer_count_by_cell[cell];
    if (active == 0 or first >= context.soil_layer_capacity or
        active > context.soil_layer_capacity - first)
        return error.InvalidDisturbedSurfaceActiveLayerRange;
    const layer = cell * context.soil_layer_capacity + first;
    const organic_carbon_g = try context.soil_organic.totalCarbon_g_c(layer);
    const organic_residue_g = try residueCarbonG(context.soil_organic, layer);
    if (!std.math.isFinite(organic_carbon_g) or organic_carbon_g < 0 or
        organic_residue_g > organic_carbon_g)
        return error.InvalidDisturbedSurfaceOrganicState;

    const mineral_mass_megagrams = context.sand_mass_megagrams[layer] +
        context.silt_mass_megagrams[layer] + context.clay_mass_megagrams[layer];
    const normalized_mass_megagrams = mineral_mass_megagrams +
        1.82e-6 * organic_carbon_g;
    if (!std.math.isFinite(mineral_mass_megagrams) or
        !std.math.isFinite(normalized_mass_megagrams) or
        mineral_mass_megagrams < 0 or normalized_mass_megagrams < 0)
        return error.InvalidDisturbedSurfaceMassScale;
    const mass_threshold_megagrams =
        context.tolerance.soil_mass_absolute_megagrams +
        context.tolerance.relative * @abs(normalized_mass_megagrams);
    const matrix_volume_m3 = context.matrix_bulk_volume_m3[layer];
    if (!std.math.isFinite(matrix_volume_m3) or matrix_volume_m3 < 0)
        return error.InvalidDisturbedSurfaceVolumeScale;
    const volume_threshold_m3 = context.tolerance.volume_absolute_m3 +
        context.tolerance.relative * @abs(matrix_volume_m3);
    const density_threshold_megagrams_per_m3 = mass_threshold_megagrams /
        @max(@abs(matrix_volume_m3), volume_threshold_m3);

    const result = try calculate(.{
        .organic_carbon_g = organic_carbon_g,
        .organic_residue_g = organic_residue_g,
        .bulk_volume_m3 = matrix_volume_m3,
        // STARTS BKVLNM is the top layer's mineral SAND+SILT+CLAY sum.
        .minimum_bulk_volume_m3 = mineral_mass_megagrams,
        .sand_megagrams = context.sand_mass_megagrams[layer],
        .silt_megagrams = context.silt_mass_megagrams[layer],
        .clay_megagrams = context.clay_mass_megagrams[layer],
        .bulk_density_megagrams_m3 = context.bulk_density_megagrams_per_m3[layer],
        .surface_litter_volume_m3 = context.surface_litter_volume_m3[cell],
        .grid_cell_area_m2 = context.grid_cell_area_m2[cell],
        .stalk_area_m2 = context.stalk_area_m2[cell],
        .canopy_height_m = context.canopy_height_m[cell],
        .mass_threshold_megagrams = mass_threshold_megagrams,
        .bulk_density_threshold_megagrams_m3 = density_threshold_megagrams_per_m3,
    });
    if (result.total_surface_roughness_m <= 0)
        return error.InvalidDisturbedSurfaceRoughnessResult;
    return result;
}

/// REDIST/HOUR1 `ORGR`: non-humus complexes K!=4, excluding the charcoal
/// structural fraction. This mirrors erosion_organic_bridge, but accepts the
/// geometry-selected top layer rather than assuming per-cell layer zero.
fn residueCarbonG(state: *const organic.State, layer: usize) !f64 {
    var total: f64 = 0;
    for (0..organic.substrate_count - 1) |substrate| {
        const substrate_carbon_g = try state.substrateCarbon_g_c(layer, substrate);
        const charcoal_index = (layer * organic.substrate_count + substrate) *
            organic.structural_fraction_count +
            (organic.structural_fraction_count - 1);
        const charcoal_carbon_g = state.structural[charcoal_index].carbon_g_c;
        if (!std.math.isFinite(charcoal_carbon_g) or charcoal_carbon_g < 0 or
            charcoal_carbon_g > substrate_carbon_g)
            return error.InvalidDisturbedSurfaceOrganicState;
        total += substrate_carbon_g - charcoal_carbon_g;
    }
    if (!std.math.isFinite(total) or total < 0)
        return error.InvalidDisturbedSurfaceOrganicState;
    return total;
}

test "disturbed mineral surface preserves composition and roughness equations" {
    const result = try calculate(.{
        .organic_carbon_g = 100_000.0,
        .organic_residue_g = 20_000.0,
        .bulk_volume_m3 = 2.0,
        .minimum_bulk_volume_m3 = 1.0,
        .sand_megagrams = 1.0,
        .silt_megagrams = 2.0,
        .clay_megagrams = 1.0,
        .bulk_density_megagrams_m3 = 1.0,
        .surface_litter_volume_m3 = 0.5,
        .grid_cell_area_m2 = 100.0,
        .stalk_area_m2 = 2.0,
        .canopy_height_m = 1.0,
        .mass_threshold_megagrams = 1.0e-12,
        .bulk_density_threshold_megagrams_m3 = 1.0e-12,
    });
    const normalized_mass = 1.0 + 2.0 + 1.0 + 1.82e-6 * 100_000.0;
    try std.testing.expectEqual(1.0 / normalized_mass, result.sand_mass_fraction);
    try std.testing.expect(result.total_surface_roughness_m > result.soil_surface_roughness_m);
}

test "empty surface uses legacy silt default and minimum roughness" {
    const result = try calculate(.{
        .organic_carbon_g = 0.0,
        .organic_residue_g = 0.0,
        .bulk_volume_m3 = 0.0,
        .minimum_bulk_volume_m3 = 0.0,
        .sand_megagrams = 0.0,
        .silt_megagrams = 0.0,
        .clay_megagrams = 0.0,
        .bulk_density_megagrams_m3 = 0.0,
        .surface_litter_volume_m3 = 0.0,
        .grid_cell_area_m2 = 1.0,
        .stalk_area_m2 = 0.0,
        .canopy_height_m = 0.0,
        .mass_threshold_megagrams = 0.0,
        .bulk_density_threshold_megagrams_m3 = 0.0,
    });
    try std.testing.expectEqual(@as(f64, 1.0), result.silt_mass_fraction);
    try std.testing.expectEqual(@as(f64, 0.001), result.total_surface_roughness_m);
}

test "hourly refresh responds to residue litter stalk and tillage state" {
    const cells = 5;
    var soil_organic = try organic.State.init(std.testing.allocator, cells);
    defer soil_organic.deinit();
    // Cells 0,2,3,4 carry humus; cell 1 carries the same total carbon as
    // non-humus residue so only the source's ORGR split changes.
    for ([_]usize{ 0, 2, 3, 4 }) |layer| {
        const index = (layer * organic.substrate_count +
            (organic.substrate_count - 1)) * organic.structural_fraction_count;
        soil_organic.structural[index].carbon_g_c = 100_000;
    }
    soil_organic.structural[
        (1 * organic.substrate_count) *
            organic.structural_fraction_count
    ].carbon_g_c = 100_000;
    var roughness = [_]f64{ 9, 9, 9, 9, 9 };
    try refresh(.{
        .surface_roughness_m = &roughness,
        .soil_layer_capacity = 1,
        .first_active_layer_by_cell = &.{ 0, 0, 0, 0, 0 },
        .active_layer_count_by_cell = &.{ 1, 1, 1, 1, 1 },
        .soil_organic = &soil_organic,
        .matrix_bulk_volume_m3 = &.{ 1, 1, 1, 1, 1 },
        .sand_mass_megagrams = &.{ 1, 1, 1, 1, 1 },
        .silt_mass_megagrams = &.{ 2, 2, 2, 2, 2 },
        .clay_mass_megagrams = &.{ 1, 1, 1, 1, 1 },
        .bulk_density_megagrams_per_m3 = &.{ 1, 1, 1, 1, 0 },
        .surface_litter_volume_m3 = &.{ 0, 0, 0.02, 0, 0 },
        .grid_cell_area_m2 = &.{ 1, 1, 1, 1, 1 },
        .stalk_area_m2 = &.{ 0, 0, 0, 2, 0 },
        .canopy_height_m = &.{ 1, 1, 1, 1, 0 },
        .tolerance = .{
            .soil_mass_absolute_megagrams = 1e-12,
            .volume_absolute_m3 = 1e-14,
            .relative = 1e-12,
        },
    });
    try std.testing.expect(roughness[1] > roughness[0]);
    try std.testing.expect(roughness[2] > roughness[0]);
    try std.testing.expect(roughness[3] > roughness[0]);
    // A zero-density disturbed/pond surface takes the exact HOUR1 ZSM floor.
    try std.testing.expectEqual(@as(f64, 0.001), roughness[4]);
}

test "hourly refresh uses geometry top and rejects a bad later cell atomically" {
    var soil_organic = try organic.State.init(std.testing.allocator, 4);
    defer soil_organic.deinit();
    var roughness = [_]f64{ 7, 8 };
    const base: RefreshContext = .{
        .surface_roughness_m = &roughness,
        .soil_layer_capacity = 2,
        .first_active_layer_by_cell = &.{ 1, 1 },
        .active_layer_count_by_cell = &.{ 1, 1 },
        .soil_organic = &soil_organic,
        // Inactive sentinels are deliberately non-finite; selected tops are
        // valid, proving no fixed layer-zero read occurs.
        .matrix_bulk_volume_m3 = &.{ std.math.nan(f64), 1, std.math.nan(f64), 1 },
        .sand_mass_megagrams = &.{ std.math.nan(f64), 1, std.math.nan(f64), 1 },
        .silt_mass_megagrams = &.{ std.math.nan(f64), 2, std.math.nan(f64), 2 },
        .clay_mass_megagrams = &.{ std.math.nan(f64), 1, std.math.nan(f64), 1 },
        .bulk_density_megagrams_per_m3 = &.{ std.math.nan(f64), 1, std.math.nan(f64), 1 },
        .surface_litter_volume_m3 = &.{ 0, 0 },
        .grid_cell_area_m2 = &.{ 1, 0 },
        .stalk_area_m2 = &.{ 0, 0 },
        .canopy_height_m = &.{ 0, 0 },
        .tolerance = .{
            .soil_mass_absolute_megagrams = 1e-12,
            .volume_absolute_m3 = 1e-14,
            .relative = 1e-12,
        },
    };
    try std.testing.expectError(error.InvalidGridCellArea, refresh(base));
    try std.testing.expectEqualSlices(f64, &.{ 7, 8 }, &roughness);

    var valid = base;
    valid.grid_cell_area_m2 = &.{ 1, 1 };
    try refresh(valid);
    const expected = try calculate(.{
        .organic_carbon_g = 0,
        .organic_residue_g = 0,
        .bulk_volume_m3 = 1,
        .minimum_bulk_volume_m3 = 4,
        .sand_megagrams = 1,
        .silt_megagrams = 2,
        .clay_megagrams = 1,
        .bulk_density_megagrams_m3 = 1,
        .surface_litter_volume_m3 = 0,
        .grid_cell_area_m2 = 1,
        .stalk_area_m2 = 0,
        .canopy_height_m = 0,
        .mass_threshold_megagrams = 5e-12,
        .bulk_density_threshold_megagrams_m3 = 5e-12,
    });
    try std.testing.expectEqual(expected.total_surface_roughness_m, roughness[0]);
    try std.testing.expectEqual(expected.total_surface_roughness_m, roughness[1]);
}

test "disturbed ZM changes Manning runoff without entering aerodynamics" {
    const surface_runoff = @import("../surface/runoff.zig");
    const terrain_module = @import("../state/terrain_hydrology.zig");
    const topography = @import("../state/topography.zig");
    const base_inputs: Inputs = .{
        .organic_carbon_g = 100_000,
        .organic_residue_g = 0,
        .bulk_volume_m3 = 1,
        .minimum_bulk_volume_m3 = 4,
        .sand_megagrams = 1,
        .silt_megagrams = 2,
        .clay_megagrams = 1,
        .bulk_density_megagrams_m3 = 1,
        .surface_litter_volume_m3 = 0,
        .grid_cell_area_m2 = 1,
        .stalk_area_m2 = 0,
        .canopy_height_m = 1,
        .mass_threshold_megagrams = 1e-12,
        .bulk_density_threshold_megagrams_m3 = 1e-12,
    };
    var disturbed_inputs = base_inputs;
    disturbed_inputs.organic_residue_g = 50_000;
    disturbed_inputs.surface_litter_volume_m3 = 0.01;
    disturbed_inputs.stalk_area_m2 = 2;
    const base = try calculate(base_inputs);
    const disturbed = try calculate(disturbed_inputs);
    try std.testing.expect(disturbed.total_surface_roughness_m >
        base.total_surface_roughness_m);

    var units = [_]topography.LandscapeUnit{.{
        .west_column = 1,
        .north_row = 1,
        .east_column = 1,
        .south_row = 1,
        .compass_aspect_degrees = 90,
        .geometric_aspect_degrees = 90,
        .slope_degrees = 5,
        .initial_snowpack_depth_m = 0,
        .soil_profile_file = "soil",
    }};
    var terrain = try terrain_module.State.initMapped(
        std.testing.allocator,
        .{ .allocator = std.testing.allocator, .units = &units },
        &.{0},
        &.{1},
        &.{1},
        1,
        1,
    );
    defer terrain.deinit();
    terrain.slope_m_per_m[0] = 1e-10;
    terrain.runoff_to_east[0] = true;
    terrain.east_west_runoff_fraction[0] = 1;
    terrain.north_south_runoff_fraction[0] = 0;
    var runoff = try surface_runoff.State.init(
        std.testing.allocator,
        1,
        base.total_surface_roughness_m,
    );
    defer runoff.deinit();
    const parameters: surface_runoff.Parameters = .{
        .ground_surface_retention_m3_per_m2 = 0,
        // Deliberately different: the live state, not this initialization
        // scalar, owns WATSUB's current `ZM`.
        .runoff_roughness_h_per_m_one_third = 0.5,
    };
    var water = [_]f64{0.02};
    try surface_runoff.route(
        &runoff,
        1,
        1,
        &terrain,
        &.{1},
        &water,
        &.{0},
        &.{0},
        &.{3},
        .{ .north = &.{0}, .east = &.{1}, .south = &.{0}, .west = &.{0} },
        parameters,
    );
    const base_velocity = runoff.runoff_velocity_m_per_s[0];
    const base_export = runoff.exported_water_m3[0];
    water[0] = 0.02;
    runoff.surface_roughness_m[0] = disturbed.total_surface_roughness_m;
    try surface_runoff.route(
        &runoff,
        1,
        1,
        &terrain,
        &.{1},
        &water,
        &.{0},
        &.{0},
        &.{3},
        .{ .north = &.{0}, .east = &.{1}, .south = &.{0}, .west = &.{0} },
        parameters,
    );
    try std.testing.expect(runoff.runoff_velocity_m_per_s[0] < base_velocity);
    try std.testing.expect(runoff.exported_water_m3[0] < base_export);
}

test "production binds ZM before aerodynamic and runoff work while snow ZS stays independent" {
    const driver_source = @embedFile("../stages/hourly_process_driver.zig");
    const gas_water_source = @embedFile("../stages/hourly_gas_surface_water.zig");
    const runoff_source = @embedFile("../surface/runoff.zig");
    const composition_source = @embedFile("../ecosys_ng.zig");
    const refresh_position = std.mem.indexOf(
        u8,
        driver_source,
        "ecosys.disturbed_surface_soil_roughness.refresh",
    ) orelse return error.TestExpectedRoughnessRefreshBinding;
    const aerodynamic_position = std.mem.indexOf(
        u8,
        driver_source,
        "ecosys.surface_aerodynamics.applyTile",
    ) orelse return error.TestExpectedSurfaceAerodynamicBinding;
    const source_ground_roughness_position = std.mem.indexOf(
        u8,
        driver_source,
        "ecosys.surface_aerodynamics.sourceGroundSurfaceRoughnessHeightM(",
    ) orelse return error.TestExpectedSourceGroundRoughnessBinding;
    try std.testing.expect(refresh_position < source_ground_roughness_position);
    try std.testing.expect(source_ground_roughness_position < aerodynamic_position);
    try std.testing.expect(std.mem.indexOf(
        u8,
        gas_water_source,
        "ecosys.surface_runoff.routeWithSurfaceBoundary",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        runoff_source,
        "state.surface_roughness_m[cell]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        composition_source,
        ".surface_stalk_area_m2 = runtime_environment_workspace_owners.surface_stalk_area_m2",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        gas_water_source,
        "disturbed_surface_soil_roughness",
    ) == null);
}
