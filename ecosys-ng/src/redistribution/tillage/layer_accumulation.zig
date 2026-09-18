// **A8a DISPOSITION: BOUND THROUGH ATOMIC RUNTIME ADAPTER.**
// `redistribution/tillage/runtime_adapter.zig` invokes this kernel in source
// order from the scheduled disturbance dispatcher and publishes atomically.
//
// **HISTORICAL A8a DISPOSITION: GAP, translated and validated but unreached. Do not bind here.**
//
// REDIST 11886--12126 builds the 10 FI and 139 TI mixing totals over the
// tillage depth. Its `Inputs` are already runtime-shaped (`first_soil_layer`,
// `tillage_depth_m`, `cumulative_layer_bottom_m`), which is why this reads as
// unfinished wiring rather than abandoned work: nothing constructs them.
//
// The whole directory has one importer, `src/module_index.zig`.
// `disturbance_management_dispatch.applyEvent:95` handles `.tillage` for roots
// and plants only, and its `ApplyContext:41--61` carries no soil-column state,
// so the omission is structural. The gap is live: `f25til98` fires codes 10,
// 10, and 8 during 1998, and `day.f:347--349` gives XCORP = 0.0, 0.0, and 0.2,
// all passing the `redist.f:11277` gate.
//
// Binding requires a new soil-side disturbance path and an ordering decision
// against the existing root-side response, which is A1's call under the
// shared-state rule.
//
// mixing totals group of
// docs/traceability/redistribution_tillage_unbound_family_disposition.md
//
const std = @import("std");
const ice_units = @import("../../core/ice_units.zig");

pub const fi_family_count = 10;
pub const ti_family_count = 139;
pub const Family = struct { layer_values: []const f64 };
pub const OrganicSources = struct {
    microbial_c_n_p: [3][]const f64, // each 6*7*3*layers
    residue_c_n_p: [3][]const f64, // each 5*2*layers
    soluble_c_n_p_a_h: [8][]const f64, // each 5*layers
    som_c_a_n_p: [4][]const f64, // each 5*5*layers
};
pub const Inputs = struct {
    first_soil_layer: usize,
    last_soil_layer: usize,
    tillage_depth_m: f64,
    cumulative_layer_bottom_m: []const f64,
    layer_thickness_m: []const f64,
    minimum_layer_thickness_m: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    physical_ice_heat_capacity_megajoules_per_m3_k: f64,
    ice_density_megagrams_per_m3: f64,
    fi_families: []const Family,
    ti_families: []const Family,
    water_m3: []const f64,
    bound_water_m3: []const f64,
    ice_m3: []const f64,
    bound_ice_m3: []const f64,
    temperature_k: []const f64,
    organic: OrganicSources,
    urea_surface_candidate: []const f64,
    urea_incorporated_candidate: []const f64,
    fixation_candidate: []const f64,
    fixation_amount_g_n: []const f64,
};
pub const Accumulators = struct {
    fi_totals: []f64,
    ti_totals: []f64,
    thermal_energy_megajoules: *f64,
    microbial_c_n_p: [3][]f64,
    residue_c_n_p: [3][]f64,
    soluble_c_n_p_a_h: [8][]f64,
    som_c_a_n_p: [4][]f64,
    urea_surface_maximum: *f64,
    urea_incorporated_maximum: *f64,
    fixation_maximum: *f64,
    fixation_total_g_n: *f64,
    last_eligible_layer: *usize,
};

fn finite(v: []const f64) bool {
    for (v) |x| if (!std.math.isFinite(x)) return false;
    return true;
}
fn validateOrganic(layers: usize, sources: OrganicSources, totals: Accumulators) !void {
    for (0..3) |i| {
        if (sources.microbial_c_n_p[i].len != 126 * layers or totals.microbial_c_n_p[i].len != 126 or sources.residue_c_n_p[i].len != 10 * layers or totals.residue_c_n_p[i].len != 10) return error.TillageLayerAccumulationDimensionMismatch;
        if (!finite(sources.microbial_c_n_p[i]) or !finite(totals.microbial_c_n_p[i]) or !finite(sources.residue_c_n_p[i]) or !finite(totals.residue_c_n_p[i])) return error.InvalidTillageLayerAccumulationInput;
    }
    for (0..8) |i| {
        if (sources.soluble_c_n_p_a_h[i].len != 5 * layers or totals.soluble_c_n_p_a_h[i].len != 5)
            return error.TillageLayerAccumulationDimensionMismatch;
        if (!finite(sources.soluble_c_n_p_a_h[i]) or !finite(totals.soluble_c_n_p_a_h[i]))
            return error.InvalidTillageLayerAccumulationInput;
    }
    for (0..4) |i| {
        if (sources.som_c_a_n_p[i].len != 25 * layers or totals.som_c_a_n_p[i].len != 25)
            return error.TillageLayerAccumulationDimensionMismatch;
        if (!finite(sources.som_c_a_n_p[i]) or !finite(totals.som_c_a_n_p[i]))
            return error.InvalidTillageLayerAccumulationInput;
    }
}
noinline fn accumulatePools(count: usize, layers: usize, ti: f64, sources: []const f64, totals: []f64) !void {
    for (0..count) |pool| {
        totals[pool] += ti * sources[pool * layers];
        if (!std.math.isFinite(totals[pool])) return error.NonFiniteTillageLayerAccumulationResult;
    }
}

/// Direct translation of REDIST 11886--12126 for one cell's runtime soil column.
pub noinline fn accumulate(allocator: std.mem.Allocator, inputs: Inputs, totals: Accumulators) !f64 {
    const layers = inputs.cumulative_layer_bottom_m.len;
    if (layers == 0 or inputs.first_soil_layer > inputs.last_soil_layer or inputs.last_soil_layer >= layers or inputs.layer_thickness_m.len != layers or inputs.fi_families.len != fi_family_count or inputs.ti_families.len != ti_family_count or totals.fi_totals.len != fi_family_count or totals.ti_totals.len != ti_family_count) return error.TillageLayerAccumulationDimensionMismatch;
    inline for (.{ inputs.water_m3, inputs.bound_water_m3, inputs.ice_m3, inputs.bound_ice_m3, inputs.temperature_k, inputs.urea_surface_candidate, inputs.urea_incorporated_candidate, inputs.fixation_candidate, inputs.fixation_amount_g_n }) |values| if (values.len != layers or !finite(values)) return error.TillageLayerAccumulationDimensionMismatch;
    for (inputs.fi_families) |family| if (family.layer_values.len != layers or !finite(family.layer_values)) return error.TillageLayerAccumulationDimensionMismatch;
    for (inputs.ti_families) |family| if (family.layer_values.len != layers or !finite(family.layer_values)) return error.TillageLayerAccumulationDimensionMismatch;
    if (!finite(inputs.cumulative_layer_bottom_m) or !finite(inputs.layer_thickness_m) or !finite(totals.fi_totals) or !finite(totals.ti_totals)) return error.InvalidTillageLayerAccumulationInput;
    inline for (.{ inputs.tillage_depth_m, inputs.minimum_layer_thickness_m, inputs.liquid_water_heat_capacity_megajoules_per_m3_k, inputs.physical_ice_heat_capacity_megajoules_per_m3_k, inputs.ice_density_megagrams_per_m3, totals.thermal_energy_megajoules.*, totals.urea_surface_maximum.*, totals.urea_incorporated_maximum.*, totals.fixation_maximum.*, totals.fixation_total_g_n.* }) |x| if (!std.math.isFinite(x)) return error.InvalidTillageLayerAccumulationInput;
    try validateOrganic(layers, inputs.organic, totals);
    const mixing_depth = @min(inputs.tillage_depth_m, inputs.cumulative_layer_bottom_m[inputs.last_soil_layer]);
    if (mixing_depth <= 0 or inputs.minimum_layer_thickness_m < 0 or inputs.liquid_water_heat_capacity_megajoules_per_m3_k <= 0) return error.InvalidTillageLayerAccumulationInput;
    const ice_heat_capacity_per_water_equivalent_m3_k = ice_units.heatCapacityPerWaterEquivalentM3K(
        inputs.physical_ice_heat_capacity_megajoules_per_m3_k,
        inputs.ice_density_megagrams_per_m3,
    ) catch return error.InvalidTillageLayerAccumulationInput;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const fi_totals = try arena.allocator().dupe(f64, totals.fi_totals);
    const ti_totals = try arena.allocator().dupe(f64, totals.ti_totals);
    var microbial: [3][]f64 = undefined;
    var residue: [3][]f64 = undefined;
    var soluble: [8][]f64 = undefined;
    var som: [4][]f64 = undefined;
    for (0..3) |i| {
        microbial[i] = try arena.allocator().dupe(f64, totals.microbial_c_n_p[i]);
        residue[i] = try arena.allocator().dupe(f64, totals.residue_c_n_p[i]);
    }
    for (0..8) |i| soluble[i] = try arena.allocator().dupe(f64, totals.soluble_c_n_p_a_h[i]);
    for (0..4) |i| som[i] = try arena.allocator().dupe(f64, totals.som_c_a_n_p[i]);
    var energy = totals.thermal_energy_megajoules.*;
    var max_surface = totals.urea_surface_maximum.*;
    var max_incorporated = totals.urea_incorporated_maximum.*;
    var max_fixation = totals.fixation_maximum.*;
    var fixation_total = totals.fixation_total_g_n.*;
    var last = inputs.first_soil_layer;
    for (inputs.first_soil_layer..inputs.last_soil_layer + 1) |layer| {
        const thickness = inputs.layer_thickness_m[layer];
        const layer_top = inputs.cumulative_layer_bottom_m[layer] - thickness;
        if (layer_top >= mixing_depth or thickness <= inputs.minimum_layer_thickness_m) continue;
        const overlap = @min(thickness, mixing_depth - layer_top);
        const fi = overlap / mixing_depth;
        const ti = overlap / thickness;
        for (inputs.fi_families, 0..) |family, i| {
            fi_totals[i] += fi * family.layer_values[layer];
            if (!std.math.isFinite(fi_totals[i])) return error.NonFiniteTillageLayerAccumulationResult;
        }
        for (inputs.ti_families, 0..) |family, i| {
            ti_totals[i] += ti * family.layer_values[layer];
            if (!std.math.isFinite(ti_totals[i])) return error.NonFiniteTillageLayerAccumulationResult;
        }
        energy += ti * (inputs.liquid_water_heat_capacity_megajoules_per_m3_k * (inputs.water_m3[layer] + inputs.bound_water_m3[layer]) + ice_heat_capacity_per_water_equivalent_m3_k * (inputs.ice_m3[layer] + inputs.bound_ice_m3[layer])) * inputs.temperature_k[layer];
        for (0..3) |i| {
            try accumulatePools(126, layers, ti, inputs.organic.microbial_c_n_p[i][layer..], microbial[i]);
            try accumulatePools(10, layers, ti, inputs.organic.residue_c_n_p[i][layer..], residue[i]);
        }
        for (0..8) |i| try accumulatePools(5, layers, ti, inputs.organic.soluble_c_n_p_a_h[i][layer..], soluble[i]);
        for (0..4) |i| try accumulatePools(25, layers, ti, inputs.organic.som_c_a_n_p[i][layer..], som[i]);
        max_surface = @max(max_surface, inputs.urea_surface_candidate[layer]);
        max_incorporated = @max(max_incorporated, inputs.urea_incorporated_candidate[layer]);
        max_fixation = @max(max_fixation, inputs.fixation_candidate[layer]);
        fixation_total += inputs.fixation_amount_g_n[layer];
        last = layer;
        inline for (.{ energy, max_surface, max_incorporated, max_fixation, fixation_total }) |x| if (!std.math.isFinite(x)) return error.NonFiniteTillageLayerAccumulationResult;
    }
    @memcpy(totals.fi_totals, fi_totals);
    @memcpy(totals.ti_totals, ti_totals);
    for (0..3) |i| {
        @memcpy(totals.microbial_c_n_p[i], microbial[i]);
        @memcpy(totals.residue_c_n_p[i], residue[i]);
    }
    for (0..8) |i| @memcpy(totals.soluble_c_n_p_a_h[i], soluble[i]);
    for (0..4) |i| @memcpy(totals.som_c_a_n_p[i], som[i]);
    totals.thermal_energy_megajoules.* = energy;
    totals.urea_surface_maximum.* = max_surface;
    totals.urea_incorporated_maximum.* = max_incorporated;
    totals.fixation_maximum.* = max_fixation;
    totals.fixation_total_g_n.* = fixation_total;
    totals.last_eligible_layer.* = last;
    return mixing_depth;
}

test "REDIST tillage layer accumulation preserves overlap weights runtime layers and atomic totals" {
    const bottoms = [_]f64{ 0.1, 0.3 };
    const thickness = [_]f64{ 0.1, 0.2 };
    const source = [_]f64{ 2, 4 };
    var fi_families: [fi_family_count]Family = @splat(.{ .layer_values = &source });
    var ti_families: [ti_family_count]Family = @splat(.{ .layer_values = &source });
    var fi_totals: [fi_family_count]f64 = @splat(0);
    var ti_totals: [ti_family_count]f64 = @splat(0);
    var microbial_source: [3][252]f64 = @splat(@splat(1));
    var residue_source: [3][20]f64 = @splat(@splat(1));
    var soluble_source: [8][10]f64 = @splat(@splat(1));
    var som_source: [4][50]f64 = @splat(@splat(1));
    var microbial_totals: [3][126]f64 = @splat(@splat(0));
    var residue_totals: [3][10]f64 = @splat(@splat(0));
    var soluble_totals: [8][5]f64 = @splat(@splat(0));
    var som_totals: [4][25]f64 = @splat(@splat(0));
    var microbial_source_slices: [3][]const f64 = undefined;
    var residue_source_slices: [3][]const f64 = undefined;
    var microbial_total_slices: [3][]f64 = undefined;
    var residue_total_slices: [3][]f64 = undefined;
    inline for (0..3) |i| {
        microbial_source_slices[i] = &microbial_source[i];
        residue_source_slices[i] = &residue_source[i];
        microbial_total_slices[i] = &microbial_totals[i];
        residue_total_slices[i] = &residue_totals[i];
    }
    var soluble_source_slices: [8][]const f64 = undefined;
    var soluble_total_slices: [8][]f64 = undefined;
    inline for (0..8) |i| {
        soluble_source_slices[i] = &soluble_source[i];
        soluble_total_slices[i] = &soluble_totals[i];
    }
    var som_source_slices: [4][]const f64 = undefined;
    var som_total_slices: [4][]f64 = undefined;
    inline for (0..4) |i| {
        som_source_slices[i] = &som_source[i];
        som_total_slices[i] = &som_totals[i];
    }
    var energy: f64 = 0;
    var max_a: f64 = 0;
    var max_b: f64 = 0;
    var max_c: f64 = 0;
    var fixation: f64 = 0;
    var last: usize = 0;
    const rho_ice = 0.917;
    const mixing_depth = try accumulate(std.testing.allocator, .{ .first_soil_layer = 0, .last_soil_layer = 1, .tillage_depth_m = 0.2, .cumulative_layer_bottom_m = &bottoms, .layer_thickness_m = &thickness, .minimum_layer_thickness_m = 0.001, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .physical_ice_heat_capacity_megajoules_per_m3_k = 1.9274, .ice_density_megagrams_per_m3 = rho_ice, .fi_families = &fi_families, .ti_families = &ti_families, .water_m3 = &source, .bound_water_m3 = &source, .ice_m3 = &source, .bound_ice_m3 = &source, .temperature_k = &.{ 300, 300 }, .organic = .{ .microbial_c_n_p = microbial_source_slices, .residue_c_n_p = residue_source_slices, .soluble_c_n_p_a_h = soluble_source_slices, .som_c_a_n_p = som_source_slices }, .urea_surface_candidate = &source, .urea_incorporated_candidate = &source, .fixation_candidate = &source, .fixation_amount_g_n = &source }, .{ .fi_totals = &fi_totals, .ti_totals = &ti_totals, .thermal_energy_megajoules = &energy, .microbial_c_n_p = microbial_total_slices, .residue_c_n_p = residue_total_slices, .soluble_c_n_p_a_h = soluble_total_slices, .som_c_a_n_p = som_total_slices, .urea_surface_maximum = &max_a, .urea_incorporated_maximum = &max_b, .fixation_maximum = &max_c, .fixation_total_g_n = &fixation, .last_eligible_layer = &last });
    try std.testing.expectEqual(@as(f64, 0.2), mixing_depth);
    try std.testing.expectApproxEqAbs(@as(f64, 3), fi_totals[0], 1e-12); // .5*2 + .5*4
    try std.testing.expectApproxEqAbs(@as(f64, 4), ti_totals[0], 1e-12); // 1*2 + .5*4
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), microbial_totals[0][0], 1e-12);
    try std.testing.expectEqual(@as(usize, 1), last);
    const expected_energy = (1.0 * 2.0 + 0.5 * 4.0) * 2.0 * (4.19 + 1.9274 / rho_ice) * 300.0;
    try std.testing.expectApproxEqAbs(expected_energy, energy, 1e-9);
}
