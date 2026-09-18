// **A8a DISPOSITION: superseded, do not bind.** This module recomputes the
// legacy `FSEDER = AMIN1(1.0, XSEDER/BKVLNU)` transported-mass fraction
// (`erosion.f:542`, restated `:1178`) and multiplies it into one named list of
// surface-layer pools. Production factors that differently: the identical
// clamped fraction is computed once per cell in
// `erosion/eroded_constituents.zig` `calculatePackedFluxes` (`:105`) and
// applied to a packed pool array whose membership and order are declared by
// the four `soil/profile/erosion_*_bridge.zig` modules, dispatched from
// `stages/hourly_science_sediment.zig:57, :77, :90, :105`. This kernel has no
// call site anywhere in the tree, so binding it would not install a competing
// writer; it would duplicate a fraction already derived from the same inputs.
//
// Group B of docs/traceability/erosion_unbound_family_disposition.md

const std = @import("std");

pub const ElementalPools = struct {
    carbon_g: []const f64,
    nitrogen_g: []const f64,
    phosphorus_g: []const f64,
};

pub const ElementalFluxes = struct {
    carbon_g_per_step: []f64,
    nitrogen_g_per_step: []f64,
    phosphorus_g_per_step: []f64,
};

pub const AdsorbedPools = struct {
    carbon_g: []const f64,
    nitrogen_g: []const f64,
    phosphorus_g: []const f64,
    acetate_g_c: []const f64,
};

pub const AdsorbedFluxes = struct {
    carbon_g_per_step: []f64,
    nitrogen_g_per_step: []f64,
    phosphorus_g_per_step: []f64,
    acetate_g_c_per_step: []f64,
};

pub const SomPools = struct {
    carbon_g: []const f64,
    colonized_carbon_g: []const f64,
    nitrogen_g: []const f64,
    phosphorus_g: []const f64,
};

pub const SomFluxes = struct {
    carbon_g_per_step: []f64,
    colonized_carbon_g_per_step: []f64,
    nitrogen_g_per_step: []f64,
    phosphorus_g_per_step: []f64,
};

pub const Dimensions = struct {
    microbial_substrate_class_count: usize, // legacy K=0..5
    microbial_functional_group_count: usize, // legacy NO=1..7
    microbial_kinetic_pool_count: usize, // legacy M=1..3
    residue_class_count: usize, // legacy K=0..4
    residue_kinetic_pool_count: usize, // legacy M=1..2
    som_kinetic_pool_count: usize, // legacy M=1..5
};

pub const Inputs = struct {
    transported_surface_mass_fraction: f64, // FSEDER
    dimensions: Dimensions,
    microbial: ElementalPools, // OMC,OMN,OMP
    residue: ElementalPools, // ORC,ORN,ORP
    adsorbed: AdsorbedPools, // OHC,OHN,OHP,OHA
    som: SomPools, // OSC,OSA,OSN,OSP
};

pub const Outputs = struct {
    microbial: ElementalFluxes,
    residue: ElementalFluxes,
    adsorbed: AdsorbedFluxes,
    som: SomFluxes,
};

fn finiteNonnegative(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value) or value < 0) return false;
    return true;
}

fn elementalLengthsMatch(input: ElementalPools, output: ElementalFluxes, count: usize) bool {
    return input.carbon_g.len == count and input.nitrogen_g.len == count and input.phosphorus_g.len == count and output.carbon_g_per_step.len == count and output.nitrogen_g_per_step.len == count and output.phosphorus_g_per_step.len == count;
}

fn writeTriple(staged: []f64, offset: usize, count: usize, index: usize, fraction: f64, pools: ElementalPools) !void {
    staged[offset + index] = fraction * pools.carbon_g[index];
    staged[offset + count + index] = fraction * pools.nitrogen_g[index];
    staged[offset + 2 * count + index] = fraction * pools.phosphorus_g[index];
    inline for (0..3) |field| if (!std.math.isFinite(staged[offset + field * count + index])) return error.NonFiniteErosionOrganicMatterResult;
}

/// Direct translation of EROSION 652--675 for one runtime cell face.
pub fn calculate(allocator: std.mem.Allocator, inputs: Inputs, outputs: Outputs) !void {
    const d = inputs.dimensions;
    if (d.microbial_substrate_class_count == 0 or d.microbial_functional_group_count == 0 or d.microbial_kinetic_pool_count == 0 or d.residue_class_count == 0 or d.residue_kinetic_pool_count == 0 or d.som_kinetic_pool_count == 0) return error.ErosionOrganicMatterDimensionMismatch;
    const microbial_count = try std.math.mul(usize, try std.math.mul(usize, d.microbial_substrate_class_count, d.microbial_functional_group_count), d.microbial_kinetic_pool_count);
    const residue_count = try std.math.mul(usize, d.residue_class_count, d.residue_kinetic_pool_count);
    const som_count = try std.math.mul(usize, d.residue_class_count, d.som_kinetic_pool_count);
    const microbial_field_count = try std.math.mul(usize, 3, microbial_count);
    const residue_field_count = try std.math.mul(usize, 3, residue_count);
    const adsorbed_field_count = try std.math.mul(usize, 4, d.residue_class_count);
    const som_field_count = try std.math.mul(usize, 4, som_count);
    if (!elementalLengthsMatch(inputs.microbial, outputs.microbial, microbial_count) or !elementalLengthsMatch(inputs.residue, outputs.residue, residue_count)) return error.ErosionOrganicMatterDimensionMismatch;
    inline for (.{ inputs.adsorbed.carbon_g, inputs.adsorbed.nitrogen_g, inputs.adsorbed.phosphorus_g, inputs.adsorbed.acetate_g_c, outputs.adsorbed.carbon_g_per_step, outputs.adsorbed.nitrogen_g_per_step, outputs.adsorbed.phosphorus_g_per_step, outputs.adsorbed.acetate_g_c_per_step }) |values| if (values.len != d.residue_class_count) return error.ErosionOrganicMatterDimensionMismatch;
    inline for (.{ inputs.som.carbon_g, inputs.som.colonized_carbon_g, inputs.som.nitrogen_g, inputs.som.phosphorus_g, outputs.som.carbon_g_per_step, outputs.som.colonized_carbon_g_per_step, outputs.som.nitrogen_g_per_step, outputs.som.phosphorus_g_per_step }) |values| if (values.len != som_count) return error.ErosionOrganicMatterDimensionMismatch;
    if (!std.math.isFinite(inputs.transported_surface_mass_fraction) or inputs.transported_surface_mass_fraction < 0 or inputs.transported_surface_mass_fraction > 1) return error.InvalidErosionOrganicMatterFraction;
    inline for (.{ inputs.microbial.carbon_g, inputs.microbial.nitrogen_g, inputs.microbial.phosphorus_g, inputs.residue.carbon_g, inputs.residue.nitrogen_g, inputs.residue.phosphorus_g, inputs.adsorbed.carbon_g, inputs.adsorbed.nitrogen_g, inputs.adsorbed.phosphorus_g, inputs.adsorbed.acetate_g_c, inputs.som.carbon_g, inputs.som.colonized_carbon_g, inputs.som.nitrogen_g, inputs.som.phosphorus_g }) |values| if (!finiteNonnegative(values)) return error.InvalidErosionOrganicMatterPool;

    const staged_count = try std.math.add(usize, try std.math.add(usize, microbial_field_count, residue_field_count), try std.math.add(usize, adsorbed_field_count, som_field_count));
    const staged = try allocator.alloc(f64, staged_count);
    defer allocator.free(staged);
    var offset: usize = 0;
    for (0..d.microbial_substrate_class_count) |class| for (0..d.microbial_functional_group_count) |group| for (0..d.microbial_kinetic_pool_count) |pool| {
        const index = (class * d.microbial_functional_group_count + group) * d.microbial_kinetic_pool_count + pool;
        try writeTriple(staged, offset, microbial_count, index, inputs.transported_surface_mass_fraction, inputs.microbial);
    };
    offset += microbial_field_count;
    for (0..d.residue_class_count) |class| {
        for (0..d.residue_kinetic_pool_count) |pool| {
            const index = class * d.residue_kinetic_pool_count + pool;
            try writeTriple(staged, offset, residue_count, index, inputs.transported_surface_mass_fraction, inputs.residue);
        }
        const adsorbed_fields = [_]f64{ inputs.adsorbed.carbon_g[class], inputs.adsorbed.nitrogen_g[class], inputs.adsorbed.phosphorus_g[class], inputs.adsorbed.acetate_g_c[class] };
        for (adsorbed_fields, 0..) |value, field| staged[offset + residue_field_count + field * d.residue_class_count + class] = inputs.transported_surface_mass_fraction * value;
        for (0..d.som_kinetic_pool_count) |pool| {
            const index = class * d.som_kinetic_pool_count + pool;
            const som_fields = [_]f64{ inputs.som.carbon_g[index], inputs.som.colonized_carbon_g[index], inputs.som.nitrogen_g[index], inputs.som.phosphorus_g[index] };
            for (som_fields, 0..) |value, field| staged[offset + residue_field_count + adsorbed_field_count + field * som_count + index] = inputs.transported_surface_mass_fraction * value;
        }
    }
    for (staged) |value| if (!std.math.isFinite(value)) return error.NonFiniteErosionOrganicMatterResult;

    offset = 0;
    @memcpy(outputs.microbial.carbon_g_per_step, staged[offset..][0..microbial_count]);
    @memcpy(outputs.microbial.nitrogen_g_per_step, staged[offset + microbial_count ..][0..microbial_count]);
    @memcpy(outputs.microbial.phosphorus_g_per_step, staged[offset + 2 * microbial_count ..][0..microbial_count]);
    offset += microbial_field_count;
    @memcpy(outputs.residue.carbon_g_per_step, staged[offset..][0..residue_count]);
    @memcpy(outputs.residue.nitrogen_g_per_step, staged[offset + residue_count ..][0..residue_count]);
    @memcpy(outputs.residue.phosphorus_g_per_step, staged[offset + 2 * residue_count ..][0..residue_count]);
    offset += residue_field_count;
    inline for (.{ outputs.adsorbed.carbon_g_per_step, outputs.adsorbed.nitrogen_g_per_step, outputs.adsorbed.phosphorus_g_per_step, outputs.adsorbed.acetate_g_c_per_step }) |values| {
        @memcpy(values, staged[offset..][0..d.residue_class_count]);
        offset += d.residue_class_count;
    }
    inline for (.{ outputs.som.carbon_g_per_step, outputs.som.colonized_carbon_g_per_step, outputs.som.nitrogen_g_per_step, outputs.som.phosphorus_g_per_step }) |values| {
        @memcpy(values, staged[offset..][0..som_count]);
        offset += som_count;
    }
}

test "EROSION organic matter flux uses runtime structural dimensions" {
    const microbial = [_]f64{ 1, 2, 3, 4 };
    const residue = [_]f64{ 5, 6 };
    const adsorbed = [_]f64{7};
    const som = [_]f64{ 8, 9, 10 };
    var microbial_out: [3][4]f64 = @splat(@splat(-1));
    var residue_out: [3][2]f64 = @splat(@splat(-1));
    var adsorbed_out: [4][1]f64 = @splat(@splat(-1));
    var som_out: [4][3]f64 = @splat(@splat(-1));
    try calculate(std.testing.allocator, .{
        .transported_surface_mass_fraction = 0.25,
        .dimensions = .{ .microbial_substrate_class_count = 2, .microbial_functional_group_count = 1, .microbial_kinetic_pool_count = 2, .residue_class_count = 1, .residue_kinetic_pool_count = 2, .som_kinetic_pool_count = 3 },
        .microbial = .{ .carbon_g = &microbial, .nitrogen_g = &microbial, .phosphorus_g = &microbial },
        .residue = .{ .carbon_g = &residue, .nitrogen_g = &residue, .phosphorus_g = &residue },
        .adsorbed = .{ .carbon_g = &adsorbed, .nitrogen_g = &adsorbed, .phosphorus_g = &adsorbed, .acetate_g_c = &adsorbed },
        .som = .{ .carbon_g = &som, .colonized_carbon_g = &som, .nitrogen_g = &som, .phosphorus_g = &som },
    }, .{
        .microbial = .{ .carbon_g_per_step = &microbial_out[0], .nitrogen_g_per_step = &microbial_out[1], .phosphorus_g_per_step = &microbial_out[2] },
        .residue = .{ .carbon_g_per_step = &residue_out[0], .nitrogen_g_per_step = &residue_out[1], .phosphorus_g_per_step = &residue_out[2] },
        .adsorbed = .{ .carbon_g_per_step = &adsorbed_out[0], .nitrogen_g_per_step = &adsorbed_out[1], .phosphorus_g_per_step = &adsorbed_out[2], .acetate_g_c_per_step = &adsorbed_out[3] },
        .som = .{ .carbon_g_per_step = &som_out[0], .colonized_carbon_g_per_step = &som_out[1], .nitrogen_g_per_step = &som_out[2], .phosphorus_g_per_step = &som_out[3] },
    });
    try std.testing.expectEqualSlices(f64, &.{ 0.25, 0.5, 0.75, 1 }, &microbial_out[0]);
    try std.testing.expectEqualSlices(f64, &.{ 1.25, 1.5 }, &residue_out[2]);
    try std.testing.expectEqual(@as(f64, 1.75), adsorbed_out[3][0]);
    try std.testing.expectEqualSlices(f64, &.{ 2, 2.25, 2.5 }, &som_out[1]);
}

test "EROSION organic matter late invalid pool leaves all outputs unchanged" {
    const one = [_]f64{1};
    const invalid = [_]f64{std.math.nan(f64)};
    var outputs: [14][1]f64 = @splat(.{9});
    try std.testing.expectError(error.InvalidErosionOrganicMatterPool, calculate(std.testing.allocator, .{
        .transported_surface_mass_fraction = 0.5,
        .dimensions = .{ .microbial_substrate_class_count = 1, .microbial_functional_group_count = 1, .microbial_kinetic_pool_count = 1, .residue_class_count = 1, .residue_kinetic_pool_count = 1, .som_kinetic_pool_count = 1 },
        .microbial = .{ .carbon_g = &one, .nitrogen_g = &one, .phosphorus_g = &one },
        .residue = .{ .carbon_g = &one, .nitrogen_g = &one, .phosphorus_g = &one },
        .adsorbed = .{ .carbon_g = &one, .nitrogen_g = &one, .phosphorus_g = &one, .acetate_g_c = &one },
        .som = .{ .carbon_g = &one, .colonized_carbon_g = &one, .nitrogen_g = &one, .phosphorus_g = &invalid },
    }, .{
        .microbial = .{ .carbon_g_per_step = &outputs[0], .nitrogen_g_per_step = &outputs[1], .phosphorus_g_per_step = &outputs[2] },
        .residue = .{ .carbon_g_per_step = &outputs[3], .nitrogen_g_per_step = &outputs[4], .phosphorus_g_per_step = &outputs[5] },
        .adsorbed = .{ .carbon_g_per_step = &outputs[6], .nitrogen_g_per_step = &outputs[7], .phosphorus_g_per_step = &outputs[8], .acetate_g_c_per_step = &outputs[9] },
        .som = .{ .carbon_g_per_step = &outputs[10], .colonized_carbon_g_per_step = &outputs[11], .nitrogen_g_per_step = &outputs[12], .phosphorus_g_per_step = &outputs[13] },
    }));
    for (outputs) |value| try std.testing.expectEqual(@as(f64, 9), value[0]);
}
