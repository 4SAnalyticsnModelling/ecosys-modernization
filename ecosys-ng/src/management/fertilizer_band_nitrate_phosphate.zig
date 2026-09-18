const std = @import("std");

pub const BandApplication = enum { unbanded, banded };
pub const SalinityChemistry = enum { disabled, enabled };

pub const LayerProperties = struct {
    top_depth_m: f64,
    bottom_depth_m: f64,
    thickness_m: f64,
    tortuosity: f64,
    nitrate_diffusivity_m2_h: f64,
    phosphate_diffusivity_m2_h: f64,
};

pub const BandGeometry = struct {
    total_depth_m: f64,
    penetration_front_depth_m: f64,
    layer_depth_m: []f64,
    layer_width_m: []f64,
    nonband_volume_fraction: []f64,
    band_volume_fraction: []f64,
    nonband_fractional_change_per_timestep: []f64,
};

pub const NitratePools = struct {
    nitrate_nonband_g_n: []f64,
    nitrate_band_g_n: []f64,
    nitrite_nonband_g_n: []f64,
    nitrite_band_g_n: []f64,
    fertilizer_nitrate_nonband_g_n: []f64,
    fertilizer_nitrate_band_g_n: []f64,
};

pub const PhosphatePools = struct {
    hydrogen_phosphate_nonband_mol: []f64,
    hydrogen_phosphate_band_mol: []f64,
    dihydrogen_phosphate_nonband_mol: []f64,
    dihydrogen_phosphate_band_mol: []f64,
    adsorbed_oh0_nonband_mol: []f64,
    adsorbed_oh0_band_mol: []f64,
    adsorbed_oh1_nonband_mol: []f64,
    adsorbed_oh1_band_mol: []f64,
    adsorbed_oh2_nonband_mol: []f64,
    adsorbed_oh2_band_mol: []f64,
    adsorbed_hpo4_nonband_mol: []f64,
    adsorbed_hpo4_band_mol: []f64,
    adsorbed_h2po4_nonband_mol: []f64,
    adsorbed_h2po4_band_mol: []f64,
    aluminum_phosphate_nonband_mol: []f64,
    aluminum_phosphate_band_mol: []f64,
    iron_phosphate_nonband_mol: []f64,
    iron_phosphate_band_mol: []f64,
    dicalcium_phosphate_nonband_mol: []f64,
    dicalcium_phosphate_band_mol: []f64,
    hydroxyapatite_nonband_mol: []f64,
    hydroxyapatite_band_mol: []f64,
    monocalcium_phosphate_nonband_mol: []f64,
    monocalcium_phosphate_band_mol: []f64,
    phosphate_nonband_mol: []f64,
    phosphate_band_mol: []f64,
    phosphoric_acid_nonband_mol: []f64,
    phosphoric_acid_band_mol: []f64,
    iron_hpo4_nonband_mol: []f64,
    iron_hpo4_band_mol: []f64,
    iron_h2po4_nonband_mol: []f64,
    iron_h2po4_band_mol: []f64,
    calcium_hpo4_nonband_mol: []f64,
    calcium_hpo4_band_mol: []f64,
    calcium_h2po4_nonband_mol: []f64,
    calcium_h2po4_band_mol: []f64,
    calcium_phosphate_nonband_mol: []f64,
    calcium_phosphate_band_mol: []f64,
    magnesium_hpo4_nonband_mol: []f64,
    magnesium_hpo4_band_mol: []f64,
};

pub const Inputs = struct {
    first_active_layer_index: usize,
    layer_index: usize,
    solute_timestep_h: f64,
    depth_threshold_m: f64,
    minimum_layer_thickness_m: f64,
    absent_band_fraction_threshold: f64,
    maximum_band_volume_fraction: f64,
    nitrate_application: BandApplication,
    nitrate_row_width_m: f64,
    phosphate_application: BandApplication,
    phosphate_row_width_m: f64,
    salinity_chemistry: SalinityChemistry,
    layers: []const LayerProperties,
};

pub const UpdateError = error{
    LayerCountMismatch,
    LayerIndexOutOfBounds,
    NonFiniteInput,
    InvalidGeometry,
    InvalidFraction,
    NonPositivePreviousNonbandFraction,
    NonFiniteResult,
};

const GeometryDisposition = enum { unchanged, retained, amalgamate };

/// Translates `hour1.f` lines 4992--5200 for one soil layer.
/// Call after the NH4 update for the same layer.
pub fn updateLayer(
    inputs: Inputs,
    nitrate_geometry: *BandGeometry,
    nitrate_pools: *NitratePools,
    phosphate_geometry: *BandGeometry,
    phosphate_pools: *PhosphatePools,
) UpdateError!void {
    try validate(inputs, nitrate_geometry.*, nitrate_pools.*, phosphate_geometry.*, phosphate_pools.*);

    const nitrate_disposition = try updateGeometry(
        inputs,
        inputs.nitrate_application,
        inputs.nitrate_row_width_m,
        inputs.layers[inputs.layer_index].nitrate_diffusivity_m2_h,
        nitrate_geometry,
    );
    if (nitrate_disposition == .amalgamate) {
        amalgamateNitrate(inputs.layer_index, nitrate_pools);
    }

    const phosphate_disposition = try updateGeometry(
        inputs,
        inputs.phosphate_application,
        inputs.phosphate_row_width_m,
        inputs.layers[inputs.layer_index].phosphate_diffusivity_m2_h,
        phosphate_geometry,
    );
    if (phosphate_disposition == .amalgamate) {
        amalgamatePhosphate(inputs.layer_index, inputs.salinity_chemistry, phosphate_pools);
    }
}

fn updateGeometry(
    inputs: Inputs,
    application: BandApplication,
    row_width_m: f64,
    diffusivity_m2_h: f64,
    geometry: *BandGeometry,
) UpdateError!GeometryDisposition {
    if (application != .banded or row_width_m <= 0.0) return .unchanged;
    const index = inputs.layer_index;
    const layer = inputs.layers[index];
    if (index != inputs.first_active_layer_index and
        layer.top_depth_m >= geometry.total_depth_m)
    {
        geometry.nonband_fractional_change_per_timestep[index] = 0.0;
        geometry.layer_depth_m[index] = 0.0;
        geometry.layer_width_m[index] = 0.0;
        geometry.nonband_volume_fraction[index] = 1.0;
        geometry.band_volume_fraction[index] = 0.0;
        return .amalgamate;
    }

    var width_change_m: f64 = 0.0;
    if (geometry.layer_depth_m[index] > inputs.depth_threshold_m) {
        width_change_m = 0.5 * @sqrt(diffusivity_m2_h * layer.tortuosity) *
            inputs.solute_timestep_h;
        geometry.layer_width_m[index] =
            @min(row_width_m, geometry.layer_width_m[index] + width_change_m);
    } else {
        geometry.layer_width_m[index] = 0.0;
    }
    if (layer.bottom_depth_m >= geometry.penetration_front_depth_m and
        layer.top_depth_m < geometry.penetration_front_depth_m)
    {
        geometry.penetration_front_depth_m =
            @max(0.0, geometry.penetration_front_depth_m - width_change_m);
        geometry.layer_depth_m[index] =
            @min(layer.thickness_m, geometry.layer_depth_m[index] + width_change_m);
    }
    if (index > inputs.first_active_layer_index and
        geometry.penetration_front_depth_m < layer.top_depth_m and
        geometry.band_volume_fraction[index - 1] < inputs.absent_band_fraction_threshold)
    {
        geometry.layer_depth_m[index - 1] =
            layer.top_depth_m - geometry.penetration_front_depth_m;
        geometry.layer_width_m[index - 1] = geometry.layer_width_m[index];
    }
    if (layer.bottom_depth_m >= geometry.total_depth_m and
        layer.top_depth_m < geometry.total_depth_m)
    {
        geometry.total_depth_m += width_change_m;
        geometry.layer_depth_m[index] =
            @min(layer.thickness_m, geometry.layer_depth_m[index] + width_change_m);
    }
    if (geometry.total_depth_m > layer.bottom_depth_m and
        geometry.penetration_front_depth_m <= layer.top_depth_m)
    {
        if (index + 1 >= inputs.layers.len) return error.LayerIndexOutOfBounds;
        if (geometry.band_volume_fraction[index + 1] < inputs.absent_band_fraction_threshold) {
            geometry.layer_width_m[index + 1] = geometry.layer_width_m[index];
            geometry.layer_depth_m[index + 1] =
                geometry.total_depth_m - layer.bottom_depth_m;
        }
    }

    const previous_nonband_fraction = geometry.nonband_volume_fraction[index];
    if (previous_nonband_fraction <= 0.0) return error.NonPositivePreviousNonbandFraction;
    geometry.band_volume_fraction[index] = if (layer.thickness_m >
        inputs.minimum_layer_thickness_m)
        @max(0.0, @min(
            inputs.maximum_band_volume_fraction,
            geometry.layer_width_m[index] / row_width_m *
                geometry.layer_depth_m[index] / layer.thickness_m,
        ))
    else
        0.0;
    geometry.nonband_volume_fraction[index] = 1.0 - geometry.band_volume_fraction[index];
    geometry.nonband_fractional_change_per_timestep[index] = @min(
        0.0,
        (geometry.nonband_volume_fraction[index] - previous_nonband_fraction) /
            previous_nonband_fraction,
    );
    if (!std.math.isFinite(geometry.nonband_fractional_change_per_timestep[index])) {
        return error.NonFiniteResult;
    }
    return .retained;
}

fn amalgamateNitrate(index: usize, pools: *NitratePools) void {
    inline for (.{
        .{ "nitrate_nonband_g_n", "nitrate_band_g_n" },
        .{ "nitrite_nonband_g_n", "nitrite_band_g_n" },
        .{ "fertilizer_nitrate_nonband_g_n", "fertilizer_nitrate_band_g_n" },
    }) |names| {
        @field(pools, names[0])[index] += @field(pools, names[1])[index];
        @field(pools, names[1])[index] = 0.0;
    }
}

fn amalgamatePhosphate(
    index: usize,
    salinity_chemistry: SalinityChemistry,
    pools: *PhosphatePools,
) void {
    inline for (.{
        .{ "hydrogen_phosphate_nonband_mol", "hydrogen_phosphate_band_mol" },
        .{ "dihydrogen_phosphate_nonband_mol", "dihydrogen_phosphate_band_mol" },
        .{ "adsorbed_oh0_nonband_mol", "adsorbed_oh0_band_mol" },
        .{ "adsorbed_oh1_nonband_mol", "adsorbed_oh1_band_mol" },
        .{ "adsorbed_oh2_nonband_mol", "adsorbed_oh2_band_mol" },
        .{ "adsorbed_hpo4_nonband_mol", "adsorbed_hpo4_band_mol" },
        .{ "adsorbed_h2po4_nonband_mol", "adsorbed_h2po4_band_mol" },
        .{ "aluminum_phosphate_nonband_mol", "aluminum_phosphate_band_mol" },
        .{ "iron_phosphate_nonband_mol", "iron_phosphate_band_mol" },
        .{ "dicalcium_phosphate_nonband_mol", "dicalcium_phosphate_band_mol" },
        .{ "hydroxyapatite_nonband_mol", "hydroxyapatite_band_mol" },
        .{ "monocalcium_phosphate_nonband_mol", "monocalcium_phosphate_band_mol" },
    }) |names| {
        @field(pools, names[0])[index] += @field(pools, names[1])[index];
        @field(pools, names[1])[index] = 0.0;
    }
    if (salinity_chemistry == .enabled) {
        inline for (.{
            .{ "phosphate_nonband_mol", "phosphate_band_mol" },
            .{ "phosphoric_acid_nonband_mol", "phosphoric_acid_band_mol" },
            .{ "iron_hpo4_nonband_mol", "iron_hpo4_band_mol" },
            .{ "iron_h2po4_nonband_mol", "iron_h2po4_band_mol" },
            .{ "calcium_hpo4_nonband_mol", "calcium_hpo4_band_mol" },
            .{ "calcium_h2po4_nonband_mol", "calcium_h2po4_band_mol" },
            .{ "calcium_phosphate_nonband_mol", "calcium_phosphate_band_mol" },
            .{ "magnesium_hpo4_nonband_mol", "magnesium_hpo4_band_mol" },
        }) |names| {
            @field(pools, names[0])[index] += @field(pools, names[1])[index];
            @field(pools, names[1])[index] = 0.0;
        }
    }
}

fn validate(
    inputs: Inputs,
    nitrate_geometry: BandGeometry,
    nitrate_pools: NitratePools,
    phosphate_geometry: BandGeometry,
    phosphate_pools: PhosphatePools,
) UpdateError!void {
    const count = inputs.layers.len;
    if (inputs.layer_index >= count or inputs.first_active_layer_index > inputs.layer_index) {
        return error.LayerIndexOutOfBounds;
    }
    inline for (.{ nitrate_geometry, phosphate_geometry }) |geometry| {
        inline for (std.meta.fields(BandGeometry)) |field| {
            if (field.type == f64) {
                if (!std.math.isFinite(@field(geometry, field.name))) return error.NonFiniteInput;
            } else if (@field(geometry, field.name).len != count) {
                return error.LayerCountMismatch;
            } else for (@field(geometry, field.name)) |value| {
                if (!std.math.isFinite(value)) return error.NonFiniteInput;
            }
        }
    }
    inline for (.{ nitrate_pools, phosphate_pools }) |pools| {
        inline for (std.meta.fields(@TypeOf(pools))) |field| {
            if (@field(pools, field.name).len != count) return error.LayerCountMismatch;
            for (@field(pools, field.name)) |value| {
                if (!std.math.isFinite(value)) return error.NonFiniteInput;
            }
        }
    }
    const scalars = [_]f64{
        inputs.solute_timestep_h,            inputs.depth_threshold_m,
        inputs.minimum_layer_thickness_m,    inputs.absent_band_fraction_threshold,
        inputs.maximum_band_volume_fraction, inputs.nitrate_row_width_m,
        inputs.phosphate_row_width_m,
    };
    for (scalars) |value| if (!std.math.isFinite(value)) return error.NonFiniteInput;
    if (inputs.solute_timestep_h < 0.0 or inputs.depth_threshold_m < 0.0 or
        inputs.minimum_layer_thickness_m < 0.0 or inputs.nitrate_row_width_m < 0.0 or
        inputs.phosphate_row_width_m < 0.0)
    {
        return error.InvalidGeometry;
    }
    if (inputs.absent_band_fraction_threshold < 0.0 or
        inputs.maximum_band_volume_fraction <= 0.0 or
        inputs.maximum_band_volume_fraction >= 1.0)
    {
        return error.InvalidFraction;
    }
    for (inputs.layers) |layer| {
        inline for (std.meta.fields(LayerProperties)) |field| {
            if (!std.math.isFinite(@field(layer, field.name))) return error.NonFiniteInput;
        }
        if (layer.top_depth_m < 0.0 or layer.bottom_depth_m < layer.top_depth_m or
            layer.thickness_m < 0.0 or layer.tortuosity < 0.0 or
            layer.nitrate_diffusivity_m2_h < 0.0 or layer.phosphate_diffusivity_m2_h < 0.0)
        {
            return error.InvalidGeometry;
        }
    }
}

test "nitrate then phosphate geometry expands with distinct diffusivities" {
    const layers = [_]LayerProperties{.{
        .top_depth_m = 0.0,
        .bottom_depth_m = 0.1,
        .thickness_m = 0.1,
        .tortuosity = 0.25,
        .nitrate_diffusivity_m2_h = 4.0e-6,
        .phosphate_diffusivity_m2_h = 1.0e-6,
    }};
    var nitrate_storage = [_][1]f64{ .{0.02}, .{0.01}, .{0.99}, .{0.01}, .{0.0} };
    var phosphate_storage = nitrate_storage;
    var nitrate_geometry = geometryFrom(&nitrate_storage, 0.05);
    var phosphate_geometry = geometryFrom(&phosphate_storage, 0.05);
    var nitrate_pool_storage = std.mem.zeroes([6][1]f64);
    var phosphate_pool_storage = std.mem.zeroes([40][1]f64);
    var nitrate_pools = nitratePoolsFrom(&nitrate_pool_storage);
    var phosphate_pools = phosphatePoolsFrom(&phosphate_pool_storage);

    try updateLayer(testInputs(&layers, 0), &nitrate_geometry, &nitrate_pools, &phosphate_geometry, &phosphate_pools);
    try std.testing.expect(nitrate_storage[1][0] > phosphate_storage[1][0]);
    try std.testing.expectApproxEqAbs(1.0, nitrate_storage[2][0] + nitrate_storage[3][0], 1e-15);
    try std.testing.expectApproxEqAbs(1.0, phosphate_storage[2][0] + phosphate_storage[3][0], 1e-15);
}

test "amalgamation transfers nitrate and salinity phosphate pools" {
    const layers = [_]LayerProperties{
        .{ .top_depth_m = 0.0, .bottom_depth_m = 0.1, .thickness_m = 0.1, .tortuosity = 0.0, .nitrate_diffusivity_m2_h = 0.0, .phosphate_diffusivity_m2_h = 0.0 },
        .{ .top_depth_m = 0.1, .bottom_depth_m = 0.2, .thickness_m = 0.1, .tortuosity = 0.0, .nitrate_diffusivity_m2_h = 0.0, .phosphate_diffusivity_m2_h = 0.0 },
    };
    var nitrate_storage = [_][2]f64{ .{ 0.0, 0.02 }, .{ 0.0, 0.01 }, .{ 1.0, 0.8 }, .{ 0.0, 0.2 }, .{ 0.0, -0.1 } };
    var phosphate_storage = nitrate_storage;
    var nitrate_geometry = geometryFrom(&nitrate_storage, 0.05);
    var phosphate_geometry = geometryFrom(&phosphate_storage, 0.05);
    var nitrate_pool_storage = std.mem.zeroes([6][2]f64);
    var phosphate_pool_storage = std.mem.zeroes([40][2]f64);
    nitrate_pool_storage[0][1] = 2.0;
    nitrate_pool_storage[1][1] = 3.0;
    phosphate_pool_storage[24][1] = 5.0;
    phosphate_pool_storage[25][1] = 7.0;
    var nitrate_pools = nitratePoolsFrom(&nitrate_pool_storage);
    var phosphate_pools = phosphatePoolsFrom(&phosphate_pool_storage);
    var inputs = testInputs(&layers, 1);
    inputs.salinity_chemistry = .enabled;

    try updateLayer(inputs, &nitrate_geometry, &nitrate_pools, &phosphate_geometry, &phosphate_pools);
    try std.testing.expectEqual(@as(f64, 5.0), nitrate_pool_storage[0][1]);
    try std.testing.expectEqual(@as(f64, 0.0), nitrate_pool_storage[1][1]);
    try std.testing.expectEqual(@as(f64, 12.0), phosphate_pool_storage[24][1]);
    try std.testing.expectEqual(@as(f64, 0.0), phosphate_pool_storage[25][1]);
}

fn geometryFrom(storage: anytype, total_depth_m: f64) BandGeometry {
    return .{
        .total_depth_m = total_depth_m,
        .penetration_front_depth_m = total_depth_m,
        .layer_depth_m = &storage[0],
        .layer_width_m = &storage[1],
        .nonband_volume_fraction = &storage[2],
        .band_volume_fraction = &storage[3],
        .nonband_fractional_change_per_timestep = &storage[4],
    };
}

fn nitratePoolsFrom(storage: anytype) NitratePools {
    return .{
        .nitrate_nonband_g_n = &storage[0],
        .nitrate_band_g_n = &storage[1],
        .nitrite_nonband_g_n = &storage[2],
        .nitrite_band_g_n = &storage[3],
        .fertilizer_nitrate_nonband_g_n = &storage[4],
        .fertilizer_nitrate_band_g_n = &storage[5],
    };
}

fn phosphatePoolsFrom(storage: anytype) PhosphatePools {
    var result: PhosphatePools = undefined;
    inline for (std.meta.fields(PhosphatePools), 0..) |field, index| {
        @field(result, field.name) = &storage[index];
    }
    return result;
}

fn testInputs(layers: []const LayerProperties, index: usize) Inputs {
    return .{
        .first_active_layer_index = 0,
        .layer_index = index,
        .solute_timestep_h = 1.0,
        .depth_threshold_m = 0.0,
        .minimum_layer_thickness_m = 1e-9,
        .absent_band_fraction_threshold = 1e-12,
        .maximum_band_volume_fraction = 0.9999,
        .nitrate_application = .banded,
        .nitrate_row_width_m = 0.2,
        .phosphate_application = .banded,
        .phosphate_row_width_m = 0.2,
        .salinity_chemistry = .disabled,
        .layers = layers,
    };
}
