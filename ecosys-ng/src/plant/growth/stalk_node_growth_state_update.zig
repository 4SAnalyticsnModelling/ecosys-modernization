// **A8a DISPOSITION: REJECTED by lane A1.** do not bind. The verdict is recorded in
// `docs/traceability/a1b_bind_safe_batch_dispositions.md` lines 70--215 and is
// cited here rather than reopened. This pass confirmed only that GROSUB
// 2432--2487 is the code that verdict describes: node stalk C/N/P accumulation,
// `HTNODX`/`HTNODE` height chaining, and the monthly `DSTK` diagnostic.
// Group B of docs/traceability/plant_growth_unbound_family_disposition.md
const std = @import("std");

pub const State = struct {
    internode_carbon_g_c: []f64,
    internode_nitrogen_g_n: []f64,
    internode_phosphorus_g_p: []f64,
    internode_length_m: []f64,
    cumulative_node_height_m: []f64,
};

pub const Growth = struct {
    carbon_g_c_per_node: f64,
    nitrogen_g_n_per_node: f64,
    phosphorus_g_p_per_node: f64,
};

pub const Geometry = struct {
    etiolation_factor: f64,
    base_specific_internode_length_m_per_g_c: f64,
    minimum_internode_carbon_g_c: f64,
    plant_population: f64,
    internode_mass_exponent: f64,
    turgor_extension_fraction: f64,
    stalk_vertical_projection_fraction: f64,
};

pub const DiagnosticContext = struct {
    day_index: usize,
    hour_index: usize,
    integer_solar_noon_hour: usize,
    biological_iteration: usize,
    is_main_branch: bool,
    shoot_turnover_type: u8,
    root_profile_type: u8,
    stalk_volume_m3_per_g_c: f64,
};

pub const Inputs = struct {
    first_node: usize,
    last_node: usize,
    growth: Growth,
    geometry: Geometry,
    diagnostic: DiagnosticContext,
};

pub const Result = struct {
    /// Null means GROSUB did not assign DSTK at this call.
    stem_diameter_update_m: ?f64,
};

/// grosub.f lines 2432--2487. Logical runtime node indexes replace the fixed
/// modulo-25 storage ring. Previous height always means the preceding logical
/// node, including beyond node 25; it is never inferred from storage adjacency.
pub fn publish(state: State, inputs: Inputs) !Result {
    const runtime_node_count = state.internode_carbon_g_c.len;
    inline for (.{
        state.internode_nitrogen_g_n,
        state.internode_phosphorus_g_p,
        state.internode_length_m,
        state.cumulative_node_height_m,
    }) |values| if (values.len != runtime_node_count)
        return error.StalkNodeGrowthDimensionMismatch;
    if (inputs.first_node > inputs.last_node or inputs.last_node >= runtime_node_count)
        return error.StalkNodeGrowthIndexOutOfBounds;
    try validateInputs(inputs);

    var preceding_height_m: f64 = if (inputs.first_node > 0)
        state.cumulative_node_height_m[inputs.first_node - 1]
    else
        0;
    const height_before_first_m = preceding_height_m;
    var first_preview: NodePreview = undefined;
    for (inputs.first_node..inputs.last_node + 1) |node| {
        const next = try previewNode(state, inputs.growth, inputs.geometry, node, preceding_height_m);
        if (node == inputs.first_node) first_preview = next;
        preceding_height_m = next.cumulative_height_m;
    }
    const diameter_update_m = try previewDiameter(inputs, first_preview, height_before_first_m);

    for (inputs.first_node..inputs.last_node + 1) |node| {
        state.internode_carbon_g_c[node] += inputs.growth.carbon_g_c_per_node;
        state.internode_nitrogen_g_n[node] += inputs.growth.nitrogen_g_n_per_node;
        state.internode_phosphorus_g_p[node] += inputs.growth.phosphorus_g_p_per_node;
        const specific_length_m_per_g_c = @sqrt(inputs.geometry.etiolation_factor) *
            inputs.geometry.base_specific_internode_length_m_per_g_c *
            std.math.pow(
                f64,
                @max(inputs.geometry.minimum_internode_carbon_g_c, state.internode_carbon_g_c[node]) /
                    inputs.geometry.plant_population,
                inputs.geometry.internode_mass_exponent,
            ) * inputs.geometry.turgor_extension_fraction;
        const length_growth_m = inputs.growth.carbon_g_c_per_node /
            inputs.geometry.plant_population * specific_length_m_per_g_c;
        state.internode_length_m[node] += length_growth_m *
            inputs.geometry.stalk_vertical_projection_fraction;
        state.cumulative_node_height_m[node] = state.internode_length_m[node] +
            if (node != 0) state.cumulative_node_height_m[node - 1] else 0;
    }

    return .{ .stem_diameter_update_m = diameter_update_m };
}

fn previewDiameter(inputs: Inputs, first: NodePreview, previous_height_m: f64) !?f64 {
    if (!diagnosticEnabled(inputs.diagnostic)) return null;
    const height_difference_m = first.cumulative_height_m - previous_height_m;
    // Source sets only RSTK when height is not positive and leaves DSTK intact.
    if (height_difference_m <= 0) return null;
    const radius_m = @sqrt(
        inputs.diagnostic.stalk_volume_m3_per_g_c *
            (@max(0.0, first.carbon_g_c) / inputs.geometry.plant_population) /
            (3.1416 * height_difference_m),
    );
    var diameter_m = 2.0 * radius_m;
    if (inputs.first_node > 1)
        diameter_m *= std.math.pow(f64, @as(f64, @floatFromInt(inputs.first_node)), 0.167);
    if (!std.math.isFinite(radius_m) or radius_m < 0 or
        !std.math.isFinite(diameter_m) or diameter_m < 0)
        return error.NonFiniteStalkDiameterResult;
    return diameter_m;
}

const NodePreview = struct {
    carbon_g_c: f64,
    cumulative_height_m: f64,
};

fn previewNode(
    state: State,
    growth: Growth,
    geometry: Geometry,
    node: usize,
    preceding_height_m: f64,
) !NodePreview {
    const carbon_g_c = state.internode_carbon_g_c[node] + growth.carbon_g_c_per_node;
    const nitrogen_g_n = state.internode_nitrogen_g_n[node] + growth.nitrogen_g_n_per_node;
    const phosphorus_g_p = state.internode_phosphorus_g_p[node] + growth.phosphorus_g_p_per_node;
    const specific_length_m_per_g_c = @sqrt(geometry.etiolation_factor) *
        geometry.base_specific_internode_length_m_per_g_c *
        std.math.pow(
            f64,
            @max(geometry.minimum_internode_carbon_g_c, carbon_g_c) /
                geometry.plant_population,
            geometry.internode_mass_exponent,
        ) * geometry.turgor_extension_fraction;
    const length_growth_m = growth.carbon_g_c_per_node /
        geometry.plant_population * specific_length_m_per_g_c;
    const internode_length_m = state.internode_length_m[node] +
        length_growth_m * geometry.stalk_vertical_projection_fraction;
    const cumulative_height_m = internode_length_m + if (node != 0) preceding_height_m else 0;
    inline for (.{
        carbon_g_c,
        nitrogen_g_n,
        phosphorus_g_p,
        specific_length_m_per_g_c,
        length_growth_m,
        internode_length_m,
        cumulative_height_m,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.NonFiniteStalkNodeGrowthResult;
    return .{ .carbon_g_c = carbon_g_c, .cumulative_height_m = cumulative_height_m };
}

fn validateInputs(inputs: Inputs) !void {
    inline for (@typeInfo(Growth).@"struct".fields) |field| {
        const value = @field(inputs.growth, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidStalkNodeGrowth;
    }
    inline for (@typeInfo(Geometry).@"struct".fields) |field| {
        const value = @field(inputs.geometry, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteStalkNodeGrowthInput;
    }
    if (inputs.geometry.etiolation_factor < 0 or
        inputs.geometry.base_specific_internode_length_m_per_g_c < 0 or
        inputs.geometry.minimum_internode_carbon_g_c < 0 or
        inputs.geometry.plant_population <= 0 or
        inputs.geometry.turgor_extension_fraction < 0 or
        inputs.geometry.stalk_vertical_projection_fraction < 0 or
        inputs.geometry.stalk_vertical_projection_fraction > 1)
        return error.InvalidStalkNodeGrowth;
    if (diagnosticEnabled(inputs.diagnostic) and
        (!std.math.isFinite(inputs.diagnostic.stalk_volume_m3_per_g_c) or
            inputs.diagnostic.stalk_volume_m3_per_g_c < 0))
        return error.InvalidStalkDiameterInput;
}

fn diagnosticEnabled(context: DiagnosticContext) bool {
    return context.day_index / 30 * 30 == context.day_index and
        context.hour_index == context.integer_solar_noon_hour and
        context.biological_iteration == 1 and
        context.is_main_branch and
        context.shoot_turnover_type != 0 and
        context.root_profile_type != 0;
}

fn sampleInputs() Inputs {
    return .{
        .first_node = 1,
        .last_node = 3,
        .growth = .{
            .carbon_g_c_per_node = 0.5,
            .nitrogen_g_n_per_node = 0.05,
            .phosphorus_g_p_per_node = 0.01,
        },
        .geometry = .{
            .etiolation_factor = 1.44,
            .base_specific_internode_length_m_per_g_c = 0.4,
            .minimum_internode_carbon_g_c = 0.1,
            .plant_population = 2,
            .internode_mass_exponent = 0.5,
            .turgor_extension_fraction = 0.8,
            .stalk_vertical_projection_fraction = 0.6,
        },
        .diagnostic = .{
            .day_index = 60,
            .hour_index = 12,
            .integer_solar_noon_hour = 12,
            .biological_iteration = 1,
            .is_main_branch = true,
            .shoot_turnover_type = 1,
            .root_profile_type = 1,
            .stalk_volume_m3_per_g_c = 1.0e-6,
        },
    };
}

test "runtime chronology propagates height beyond node twenty five" {
    var carbon: [29]f64 = @splat(1);
    var nitrogen: [29]f64 = @splat(0);
    var phosphorus: [29]f64 = @splat(0);
    var length: [29]f64 = @splat(0.1);
    var height: [29]f64 = undefined;
    for (0..height.len) |node| height[node] = 0.1 * @as(f64, @floatFromInt(node + 1));
    const state: State = .{
        .internode_carbon_g_c = &carbon,
        .internode_nitrogen_g_n = &nitrogen,
        .internode_phosphorus_g_p = &phosphorus,
        .internode_length_m = &length,
        .cumulative_node_height_m = &height,
    };
    var inputs = sampleInputs();
    inputs.first_node = 26;
    inputs.last_node = 28;
    inputs.diagnostic.day_index = 61;
    const result = try publish(state, inputs);
    try std.testing.expectEqual(@as(?f64, null), result.stem_diameter_update_m);
    try std.testing.expect(height[26] > height[25]);
    try std.testing.expectApproxEqAbs(height[27], height[26] + length[27], 1.0e-15);
    try std.testing.expectApproxEqAbs(height[28], height[27] + length[28], 1.0e-15);
}

test "DSTK update requires every source diagnostic gate" {
    var carbon = [_]f64{ 1, 1, 1, 1 };
    var nitrogen = [_]f64{ 0, 0, 0, 0 };
    var phosphorus = [_]f64{ 0, 0, 0, 0 };
    var length = [_]f64{ 0.1, 0.1, 0.1, 0.1 };
    var height = [_]f64{ 0.1, 0.2, 0.3, 0.4 };
    const state: State = .{
        .internode_carbon_g_c = &carbon,
        .internode_nitrogen_g_n = &nitrogen,
        .internode_phosphorus_g_p = &phosphorus,
        .internode_length_m = &length,
        .cumulative_node_height_m = &height,
    };
    var inputs = sampleInputs();
    const enabled = try publish(state, inputs);
    try std.testing.expect(enabled.stem_diameter_update_m != null);
    inputs.diagnostic.day_index = 61;
    const disabled = try publish(state, inputs);
    try std.testing.expectEqual(@as(?f64, null), disabled.stem_diameter_update_m);
}

test "late invalid node leaves prior stalk nodes unchanged" {
    var carbon = [_]f64{ 1, 1, std.math.floatMax(f64) };
    var nitrogen = [_]f64{ 0, 0, 0 };
    var phosphorus = [_]f64{ 0, 0, 0 };
    var length = [_]f64{ 0.1, 0.1, 0.1 };
    var height = [_]f64{ 0.1, 0.2, 0.3 };
    const state: State = .{
        .internode_carbon_g_c = &carbon,
        .internode_nitrogen_g_n = &nitrogen,
        .internode_phosphorus_g_p = &phosphorus,
        .internode_length_m = &length,
        .cumulative_node_height_m = &height,
    };
    var inputs = sampleInputs();
    inputs.first_node = 1;
    inputs.last_node = 2;
    inputs.growth.carbon_g_c_per_node = std.math.floatMax(f64);
    try std.testing.expectError(error.NonFiniteStalkNodeGrowthResult, publish(state, inputs));
    try std.testing.expectEqual(@as(f64, 1), carbon[1]);
    try std.testing.expectEqual(@as(f64, 0.2), height[1]);
}

test "runtime dimension and index mismatches fail explicitly" {
    var carbon = [_]f64{ 1, 1 };
    var one = [_]f64{0};
    var two = [_]f64{ 0, 0 };
    var state: State = .{
        .internode_carbon_g_c = &carbon,
        .internode_nitrogen_g_n = &one,
        .internode_phosphorus_g_p = &two,
        .internode_length_m = &two,
        .cumulative_node_height_m = &two,
    };
    try std.testing.expectError(error.StalkNodeGrowthDimensionMismatch, publish(state, sampleInputs()));
    state.internode_nitrogen_g_n = &two;
    var inputs = sampleInputs();
    inputs.first_node = 1;
    inputs.last_node = 2;
    try std.testing.expectError(error.StalkNodeGrowthIndexOutOfBounds, publish(state, inputs));
}
