const std = @import("std");

pub const Tissue = struct {
    area_m2: f64,
    carbon_g_c: f64,
    nitrogen_g_n: f64,
    phosphorus_g_p: f64,
};

pub const Inputs = struct {
    branch: Tissue,
    node: Tissue,
    node_protein_g: f64,
    senescing_snapshot: Tissue,
    area_removal_fraction: f64,
    mass_removal_fraction: f64,
    protein_per_nitrogen_g_per_g_n: f64,
    protein_per_phosphorus_g_per_g_p: f64,
    branch_mobile_carbon_g_c: f64,
    branch_mobile_nitrogen_g_n: f64,
    branch_mobile_phosphorus_g_p: f64,
    recycled_carbon_g_c: f64,
    recycled_nitrogen_g_n: f64,
    recycled_phosphorus_g_p: f64,
};

pub const Result = struct {
    branch: Tissue,
    node: Tissue,
    node_protein_g: f64,
    branch_mobile_carbon_g_c: f64,
    branch_mobile_nitrogen_g_n: f64,
    branch_mobile_phosphorus_g_p: f64,
};

/// GROSUB 2630--2654. Calculates the complete leaf-state state_update before
/// the caller mutates branch, node, or mobile pools.
pub fn calculate(inputs: Inputs) !Result {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        const value = @field(inputs, field.name);
        if (field.type == f64 and (!std.math.isFinite(value) or value < 0))
            return error.InvalidLeafSenescenceStateUpdateInput;
    }
    inline for (.{ inputs.branch, inputs.node, inputs.senescing_snapshot }) |tissue|
        inline for (@typeInfo(Tissue).@"struct".fields) |field| {
            const value = @field(tissue, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidLeafSenescenceStateUpdateInput;
        };
    if (inputs.area_removal_fraction > 1 or inputs.mass_removal_fraction > 1)
        return error.InvalidLeafSenescenceStateUpdateInput;

    const removed_area_m2 = inputs.area_removal_fraction * inputs.senescing_snapshot.area_m2;
    const removed_carbon_g_c = inputs.mass_removal_fraction * inputs.senescing_snapshot.carbon_g_c;
    const removed_nitrogen_g_n = inputs.mass_removal_fraction * inputs.senescing_snapshot.nitrogen_g_n;
    const removed_phosphorus_g_p = inputs.mass_removal_fraction * inputs.senescing_snapshot.phosphorus_g_p;
    const protein_removal_g = inputs.mass_removal_fraction * @max(
        inputs.senescing_snapshot.nitrogen_g_n * inputs.protein_per_nitrogen_g_per_g_n,
        inputs.senescing_snapshot.phosphorus_g_p * inputs.protein_per_phosphorus_g_per_g_p,
    );
    // GROSUB 2646-2648/3008-3010 explicitly floors this derived protein
    // diagnostic. Conserved leaf C/N/P inventories below remain fail-closed.
    const next_node_protein_g = @max(0, inputs.node_protein_g - protein_removal_g);
    const result: Result = .{
        .branch = subtract(inputs.branch, removed_area_m2, removed_carbon_g_c, removed_nitrogen_g_n, removed_phosphorus_g_p),
        .node = subtract(inputs.node, removed_area_m2, removed_carbon_g_c, removed_nitrogen_g_n, removed_phosphorus_g_p),
        .node_protein_g = next_node_protein_g,
        .branch_mobile_carbon_g_c = inputs.branch_mobile_carbon_g_c + inputs.recycled_carbon_g_c,
        .branch_mobile_nitrogen_g_n = inputs.branch_mobile_nitrogen_g_n + inputs.recycled_nitrogen_g_n,
        .branch_mobile_phosphorus_g_p = inputs.branch_mobile_phosphorus_g_p + inputs.recycled_phosphorus_g_p,
    };
    inline for (.{ result.branch, result.node }) |tissue|
        inline for (@typeInfo(Tissue).@"struct".fields) |field| {
            const value = @field(tissue, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.LeafSenescenceStateUpdateOverdraw;
        };
    inline for (.{ result.node_protein_g, result.branch_mobile_carbon_g_c, result.branch_mobile_nitrogen_g_n, result.branch_mobile_phosphorus_g_p }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidLeafSenescenceStateUpdateResult;
    return result;
}

fn subtract(tissue: Tissue, area_m2: f64, carbon_g_c: f64, nitrogen_g_n: f64, phosphorus_g_p: f64) Tissue {
    return .{
        .area_m2 = tissue.area_m2 - area_m2,
        .carbon_g_c = tissue.carbon_g_c - carbon_g_c,
        .nitrogen_g_n = tissue.nitrogen_g_n - nitrogen_g_n,
        .phosphorus_g_p = tissue.phosphorus_g_p - phosphorus_g_p,
    };
}

test "GROSUB protein removal uses original senescing nutrient snapshot" {
    const result = try calculate(.{
        .branch = .{ .area_m2 = 4, .carbon_g_c = 8, .nitrogen_g_n = 4, .phosphorus_g_p = 1 },
        .node = .{ .area_m2 = 4, .carbon_g_c = 8, .nitrogen_g_n = 4, .phosphorus_g_p = 1 },
        .node_protein_g = 20,
        .senescing_snapshot = .{ .area_m2 = 4, .carbon_g_c = 8, .nitrogen_g_n = 4, .phosphorus_g_p = 1 },
        .area_removal_fraction = 0.5,
        .mass_removal_fraction = 0.5,
        .protein_per_nitrogen_g_per_g_n = 3,
        .protein_per_phosphorus_g_per_g_p = 5,
        .branch_mobile_carbon_g_c = 1,
        .branch_mobile_nitrogen_g_n = 2,
        .branch_mobile_phosphorus_g_p = 3,
        .recycled_carbon_g_c = 0.1,
        .recycled_nitrogen_g_n = 0.2,
        .recycled_phosphorus_g_p = 0.3,
    });
    try std.testing.expectEqual(@as(f64, 14), result.node_protein_g);
    try std.testing.expectEqual(@as(f64, 2), result.node.nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 2), result.branch.nitrogen_g_n);
}

test "late overdraw leaves caller-owned state untouched" {
    const inputs: Inputs = .{
        .branch = .{ .area_m2 = 1, .carbon_g_c = 1, .nitrogen_g_n = 1, .phosphorus_g_p = 1 },
        .node = .{ .area_m2 = 0.1, .carbon_g_c = 1, .nitrogen_g_n = 1, .phosphorus_g_p = 1 },
        .node_protein_g = 1,
        .senescing_snapshot = .{ .area_m2 = 1, .carbon_g_c = 1, .nitrogen_g_n = 1, .phosphorus_g_p = 1 },
        .area_removal_fraction = 0.5,
        .mass_removal_fraction = 0,
        .protein_per_nitrogen_g_per_g_n = 1,
        .protein_per_phosphorus_g_per_g_p = 1,
        .branch_mobile_carbon_g_c = 0,
        .branch_mobile_nitrogen_g_n = 0,
        .branch_mobile_phosphorus_g_p = 0,
        .recycled_carbon_g_c = 0,
        .recycled_nitrogen_g_n = 0,
        .recycled_phosphorus_g_p = 0,
    };
    try std.testing.expectError(error.LeafSenescenceStateUpdateOverdraw, calculate(inputs));
}
