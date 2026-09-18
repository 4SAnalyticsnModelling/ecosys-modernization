const std = @import("std");

pub const State = struct {
    leaf_carbon_g_c: []f64,
    leaf_nitrogen_g_n: []f64,
    leaf_phosphorus_g_p: []f64,
    leaf_protein_g: []f64,
    leaf_area_m2: []f64,
    branch_leaf_area_m2: *f64,
};

pub const Inputs = struct {
    first_node: usize,
    last_node: usize,
    carbon_growth_g_c_per_node: f64,
    nitrogen_growth_g_n_per_node: f64,
    phosphorus_growth_g_p_per_node: f64,
    protein_per_nitrogen_g_per_g_n: f64,
    protein_per_phosphorus_g_per_g_p: f64,
    etiolation_factor: f64,
    base_specific_leaf_area_m2_per_g_c: f64,
    minimum_leaf_carbon_g_c: f64,
    plant_population: f64,
    leaf_mass_exponent: f64,
    turgor_expansion_fraction: f64,
};

/// grosub.f lines 2294--2321: publish equal leaf growth to an inclusive runtime
/// node window. The fixed modulo-25 ring is intentionally replaced by explicit
/// runtime indexes; all scientific assignment and arithmetic order is retained.
pub fn publish(state: State, inputs: Inputs) !void {
    const node_count = state.leaf_carbon_g_c.len;
    inline for (.{
        state.leaf_nitrogen_g_n,
        state.leaf_phosphorus_g_p,
        state.leaf_protein_g,
        state.leaf_area_m2,
    }) |values| if (values.len != node_count)
        return error.LeafNodeGrowthDimensionMismatch;
    if (inputs.first_node > inputs.last_node or inputs.last_node >= node_count)
        return error.LeafNodeGrowthIndexOutOfBounds;
    inline for (@typeInfo(Inputs).@"struct".fields[2..]) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteLeafNodeGrowthInput;
    }
    if (inputs.carbon_growth_g_c_per_node < 0 or
        inputs.nitrogen_growth_g_n_per_node < 0 or
        inputs.phosphorus_growth_g_p_per_node < 0 or
        inputs.protein_per_nitrogen_g_per_g_n < 0 or
        inputs.protein_per_phosphorus_g_per_g_p < 0 or
        inputs.etiolation_factor < 0 or
        inputs.base_specific_leaf_area_m2_per_g_c < 0 or
        inputs.minimum_leaf_carbon_g_c < 0 or
        inputs.plant_population <= 0 or
        inputs.turgor_expansion_fraction < 0)
        return error.InvalidLeafNodeGrowthInput;

    var branch_area_after_m2 = state.branch_leaf_area_m2.*;
    if (!std.math.isFinite(branch_area_after_m2) or branch_area_after_m2 < 0)
        return error.InvalidLeafNodeGrowthState;
    for (inputs.first_node..inputs.last_node + 1) |node| {
        const result = try previewNode(state, inputs, node);
        branch_area_after_m2 += result.area_growth_m2;
        if (!std.math.isFinite(branch_area_after_m2))
            return error.NonFiniteLeafNodeGrowthResult;
    }

    for (inputs.first_node..inputs.last_node + 1) |node| {
        // WGLF, WGLFN, WGLFP, WSLF
        state.leaf_carbon_g_c[node] += inputs.carbon_growth_g_c_per_node;
        state.leaf_nitrogen_g_n[node] += inputs.nitrogen_growth_g_n_per_node;
        state.leaf_phosphorus_g_p[node] += inputs.phosphorus_growth_g_p_per_node;
        state.leaf_protein_g[node] += @min(
            inputs.nitrogen_growth_g_n_per_node * inputs.protein_per_nitrogen_g_per_g_n,
            inputs.phosphorus_growth_g_p_per_node * inputs.protein_per_phosphorus_g_per_g_p,
        );
        // SLA and GROA use the just-updated WGLF.
        const specific_leaf_area_m2_per_g_c = inputs.etiolation_factor *
            inputs.base_specific_leaf_area_m2_per_g_c *
            std.math.pow(
                f64,
                @max(inputs.minimum_leaf_carbon_g_c, state.leaf_carbon_g_c[node]) /
                    inputs.plant_population,
                inputs.leaf_mass_exponent,
            ) * inputs.turgor_expansion_fraction;
        const area_growth_m2 = inputs.carbon_growth_g_c_per_node *
            specific_leaf_area_m2_per_g_c;
        // ARLFB precedes ARLF in the source.
        state.branch_leaf_area_m2.* += area_growth_m2;
        state.leaf_area_m2[node] += area_growth_m2;
    }
}

const Preview = struct { area_growth_m2: f64 };

fn previewNode(state: State, inputs: Inputs, node: usize) !Preview {
    const carbon_g_c = state.leaf_carbon_g_c[node] + inputs.carbon_growth_g_c_per_node;
    const nitrogen_g_n = state.leaf_nitrogen_g_n[node] + inputs.nitrogen_growth_g_n_per_node;
    const phosphorus_g_p = state.leaf_phosphorus_g_p[node] + inputs.phosphorus_growth_g_p_per_node;
    const protein_g = state.leaf_protein_g[node] + @min(
        inputs.nitrogen_growth_g_n_per_node * inputs.protein_per_nitrogen_g_per_g_n,
        inputs.phosphorus_growth_g_p_per_node * inputs.protein_per_phosphorus_g_per_g_p,
    );
    const specific_leaf_area_m2_per_g_c = inputs.etiolation_factor *
        inputs.base_specific_leaf_area_m2_per_g_c *
        std.math.pow(
            f64,
            @max(inputs.minimum_leaf_carbon_g_c, carbon_g_c) / inputs.plant_population,
            inputs.leaf_mass_exponent,
        ) * inputs.turgor_expansion_fraction;
    const area_growth_m2 = inputs.carbon_growth_g_c_per_node * specific_leaf_area_m2_per_g_c;
    inline for (.{
        carbon_g_c,
        nitrogen_g_n,
        phosphorus_g_p,
        protein_g,
        specific_leaf_area_m2_per_g_c,
        area_growth_m2,
        state.leaf_area_m2[node] + area_growth_m2,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.NonFiniteLeafNodeGrowthResult;
    return .{ .area_growth_m2 = area_growth_m2 };
}

fn sampleInputs() Inputs {
    return .{
        .first_node = 1,
        .last_node = 2,
        .carbon_growth_g_c_per_node = 0.5,
        .nitrogen_growth_g_n_per_node = 0.04,
        .phosphorus_growth_g_p_per_node = 0.01,
        .protein_per_nitrogen_g_per_g_n = 2,
        .protein_per_phosphorus_g_per_g_p = 10,
        .etiolation_factor = 1.5,
        .base_specific_leaf_area_m2_per_g_c = 0.02,
        .minimum_leaf_carbon_g_c = 0.1,
        .plant_population = 2,
        .leaf_mass_exponent = 0.5,
        .turgor_expansion_fraction = 0.8,
    };
}

test "GROSUB leaf state_update uses updated carbon and source SLA order" {
    var carbon = [_]f64{ 9, 1.5, 3, 12 };
    var nitrogen = [_]f64{ 0, 0.1, 0.2, 0 };
    var phosphorus = [_]f64{ 0, 0.02, 0.03, 0 };
    var protein = [_]f64{ 0, 0.1, 0.2, 0 };
    var area = [_]f64{ 0, 0.4, 0.8, 0 };
    var branch_area: f64 = 1.2;
    const state: State = .{
        .leaf_carbon_g_c = &carbon,
        .leaf_nitrogen_g_n = &nitrogen,
        .leaf_phosphorus_g_p = &phosphorus,
        .leaf_protein_g = &protein,
        .leaf_area_m2 = &area,
        .branch_leaf_area_m2 = &branch_area,
    };
    const inputs = sampleInputs();
    const first_growth = 0.5 * 1.5 * 0.02 *
        std.math.pow(f64, (1.5 + 0.5) / 2.0, 0.5) * 0.8;
    const second_growth = 0.5 * 1.5 * 0.02 *
        std.math.pow(f64, (3.0 + 0.5) / 2.0, 0.5) * 0.8;
    try publish(state, inputs);
    try std.testing.expectEqual(@as(f64, 2), carbon[1]);
    try std.testing.expectEqual(@as(f64, 3.5), carbon[2]);
    try std.testing.expectEqual(@as(f64, 0.18), protein[1]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4) + first_growth, area[1], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2) + first_growth + second_growth, branch_area, 1.0e-15);
    try std.testing.expectEqual(@as(f64, 9), carbon[0]);
}

test "runtime node extent is not capped at twenty five" {
    var carbon: [31]f64 = @splat(1);
    var nitrogen: [31]f64 = @splat(0);
    var phosphorus: [31]f64 = @splat(0);
    var protein: [31]f64 = @splat(0);
    var area: [31]f64 = @splat(0);
    var branch_area: f64 = 0;
    const state: State = .{
        .leaf_carbon_g_c = &carbon,
        .leaf_nitrogen_g_n = &nitrogen,
        .leaf_phosphorus_g_p = &phosphorus,
        .leaf_protein_g = &protein,
        .leaf_area_m2 = &area,
        .branch_leaf_area_m2 = &branch_area,
    };
    var inputs = sampleInputs();
    inputs.first_node = 29;
    inputs.last_node = 30;
    try publish(state, inputs);
    try std.testing.expectEqual(@as(f64, 1), carbon[28]);
    try std.testing.expectEqual(@as(f64, 1.5), carbon[29]);
    try std.testing.expectEqual(@as(f64, 1.5), carbon[30]);
}

test "invalid late node result leaves the whole window unchanged" {
    var carbon = [_]f64{ 1, std.math.floatMax(f64) };
    var nitrogen = [_]f64{ 0, 0 };
    var phosphorus = [_]f64{ 0, 0 };
    var protein = [_]f64{ 0, 0 };
    var area = [_]f64{ 0, 0 };
    var branch_area: f64 = 0;
    const state: State = .{
        .leaf_carbon_g_c = &carbon,
        .leaf_nitrogen_g_n = &nitrogen,
        .leaf_phosphorus_g_p = &phosphorus,
        .leaf_protein_g = &protein,
        .leaf_area_m2 = &area,
        .branch_leaf_area_m2 = &branch_area,
    };
    var inputs = sampleInputs();
    inputs.first_node = 0;
    inputs.last_node = 1;
    inputs.carbon_growth_g_c_per_node = std.math.floatMax(f64);
    try std.testing.expectError(error.NonFiniteLeafNodeGrowthResult, publish(state, inputs));
    try std.testing.expectEqual(@as(f64, 1), carbon[0]);
    try std.testing.expectEqual(@as(f64, 0), branch_area);
}

test "mismatched node dimensions and invalid windows fail" {
    var carbon = [_]f64{ 1, 1 };
    var nitrogen = [_]f64{0};
    var phosphorus = [_]f64{ 0, 0 };
    var protein = [_]f64{ 0, 0 };
    var area = [_]f64{ 0, 0 };
    var branch_area: f64 = 0;
    var state: State = .{
        .leaf_carbon_g_c = &carbon,
        .leaf_nitrogen_g_n = &nitrogen,
        .leaf_phosphorus_g_p = &phosphorus,
        .leaf_protein_g = &protein,
        .leaf_area_m2 = &area,
        .branch_leaf_area_m2 = &branch_area,
    };
    try std.testing.expectError(error.LeafNodeGrowthDimensionMismatch, publish(state, sampleInputs()));
    nitrogen = undefined;
    var nitrogen_two = [_]f64{ 0, 0 };
    state.leaf_nitrogen_g_n = &nitrogen_two;
    var inputs = sampleInputs();
    inputs.first_node = 1;
    inputs.last_node = 2;
    try std.testing.expectError(error.LeafNodeGrowthIndexOutOfBounds, publish(state, inputs));
}
