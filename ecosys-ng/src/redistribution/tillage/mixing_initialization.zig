// **A8a DISPOSITION: BOUND THROUGH ATOMIC RUNTIME ADAPTER.**
// `redistribution/tillage/runtime_adapter.zig` invokes this kernel in source
// order from the scheduled disturbance dispatcher and publishes atomically.
//
// **HISTORICAL A8a DISPOSITION: GAP, translated and validated but unreached. Do not bind here.**
//
// REDIST 11419--11620 zeroes the six fertilizer band depths, the
// TOMC/TORC/TOQC/TOHC/TOSC mixing workspaces, and the five urea and fixation
// maxima. It is a pure workspace reset with no production analogue because
// production has no soil-side tillage workspace to reset.
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
// workspace reset group of
// docs/traceability/redistribution_tillage_unbound_family_disposition.md
//
const std = @import("std");

pub const scalar_accumulator_count = 157;
pub const CellState = struct {
    ammonium_band_depth_m: []f64, // DPNH4
    ammonium_band_extent_m: []f64, // DPNHX
    nitrate_band_depth_m: []f64, // DPNO3
    nitrate_band_extent_m: []f64, // DPNOX
    phosphate_band_depth_m: []f64, // DPPO4
    phosphate_band_extent_m: []f64, // DPPOX
    disturbance_flag: []u8, // IFLGS
    soil_energy_megajoules: []f64, // ENGYP
};
pub const Workspace = struct {
    /// REDIST 11434--11587 and 11616--11620, in exact source order.
    scalar_accumulators: []f64,
    microbial_carbon_g_c: []f64, // TOMC, 6*7*3
    microbial_nitrogen_g_n: []f64, // TOMN
    microbial_phosphorus_g_p: []f64, // TOMP
    residue_carbon_g_c: []f64, // TORC, 5*2
    residue_nitrogen_g_n: []f64, // TORN
    residue_phosphorus_g_p: []f64, // TORP
    soluble_fraction_totals: []f64, // TOQC/QN/QP/QA/HC/HN/HP/HA, 8*5
    som_fraction_totals: []f64, // TOSC/OSA/OSN/OSP, 4*5*5
};

fn finiteSlice(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

/// Direct translation of REDIST 11419--11620 for one runtime-indexed cell.
/// Returns CORP, the applied mixing fraction `1 - XCORP`.
pub fn initializeCell(cell: usize, soil_mixing_remaining_fraction: f64, state: CellState, workspace: Workspace) !f64 {
    const cell_count = state.ammonium_band_depth_m.len;
    if (cell_count == 0 or cell >= cell_count) return error.TillageMixingInitializationDimensionMismatch;
    inline for (std.meta.fields(CellState)) |field|
        if (@field(state, field.name).len != cell_count) return error.TillageMixingInitializationDimensionMismatch;
    if (workspace.scalar_accumulators.len != scalar_accumulator_count or
        workspace.microbial_carbon_g_c.len != 6 * 7 * 3 or workspace.microbial_nitrogen_g_n.len != 6 * 7 * 3 or workspace.microbial_phosphorus_g_p.len != 6 * 7 * 3 or
        workspace.residue_carbon_g_c.len != 5 * 2 or workspace.residue_nitrogen_g_n.len != 5 * 2 or workspace.residue_phosphorus_g_p.len != 5 * 2 or
        workspace.soluble_fraction_totals.len != 8 * 5 or workspace.som_fraction_totals.len != 4 * 5 * 5)
        return error.TillageMixingInitializationDimensionMismatch;
    if (!std.math.isFinite(soil_mixing_remaining_fraction)) return error.InvalidTillageMixingInitializationInput;
    inline for (std.meta.fields(CellState)) |field| {
        if (comptime std.mem.eql(u8, field.name, "disturbance_flag")) continue;
        if (!finiteSlice(@field(state, field.name))) return error.InvalidTillageMixingInitializationInput;
    }
    inline for (std.meta.fields(Workspace)) |field|
        if (!finiteSlice(@field(workspace, field.name))) return error.InvalidTillageMixingInitializationInput;
    const mixing_fraction = 1.0 - soil_mixing_remaining_fraction;
    if (!std.math.isFinite(mixing_fraction)) return error.NonFiniteTillageMixingInitializationResult;

    state.ammonium_band_depth_m[cell] = 0;
    state.ammonium_band_extent_m[cell] = 0;
    state.nitrate_band_depth_m[cell] = 0;
    state.nitrate_band_extent_m[cell] = 0;
    state.phosphate_band_depth_m[cell] = 0;
    state.phosphate_band_extent_m[cell] = 0;
    state.disturbance_flag[cell] = 1;
    state.soil_energy_megajoules[cell] = 0;
    @memset(workspace.scalar_accumulators, 0);
    @memset(workspace.microbial_carbon_g_c, 0);
    @memset(workspace.microbial_nitrogen_g_n, 0);
    @memset(workspace.microbial_phosphorus_g_p, 0);
    @memset(workspace.residue_carbon_g_c, 0);
    @memset(workspace.residue_nitrogen_g_n, 0);
    @memset(workspace.residue_phosphorus_g_p, 0);
    @memset(workspace.soluble_fraction_totals, 0);
    @memset(workspace.som_fraction_totals, 0);
    return mixing_fraction;
}

test "REDIST tillage mixing initialization zeros exact runtime workspace axes" {
    var cell_values: [7][2]f64 = @splat(@splat(3));
    var flags = [_]u8{ 0, 0 };
    var scalars: [scalar_accumulator_count]f64 = @splat(4);
    var microbial_c: [126]f64 = @splat(4);
    var microbial_n: [126]f64 = @splat(4);
    var microbial_p: [126]f64 = @splat(4);
    var residue_c: [10]f64 = @splat(4);
    var residue_n: [10]f64 = @splat(4);
    var residue_p: [10]f64 = @splat(4);
    var soluble: [40]f64 = @splat(4);
    var som: [100]f64 = @splat(4);
    const mixing = try initializeCell(1, 0.25, .{ .ammonium_band_depth_m = &cell_values[0], .ammonium_band_extent_m = &cell_values[1], .nitrate_band_depth_m = &cell_values[2], .nitrate_band_extent_m = &cell_values[3], .phosphate_band_depth_m = &cell_values[4], .phosphate_band_extent_m = &cell_values[5], .disturbance_flag = &flags, .soil_energy_megajoules = &cell_values[6] }, .{ .scalar_accumulators = &scalars, .microbial_carbon_g_c = &microbial_c, .microbial_nitrogen_g_n = &microbial_n, .microbial_phosphorus_g_p = &microbial_p, .residue_carbon_g_c = &residue_c, .residue_nitrogen_g_n = &residue_n, .residue_phosphorus_g_p = &residue_p, .soluble_fraction_totals = &soluble, .som_fraction_totals = &som });
    try std.testing.expectEqual(@as(f64, 0.75), mixing);
    try std.testing.expectEqual(@as(f64, 0), cell_values[0][1]);
    try std.testing.expectEqual(@as(f64, 3), cell_values[0][0]);
    try std.testing.expectEqual(@as(u8, 1), flags[1]);
    try std.testing.expectEqual(@as(f64, 0), scalars[156]);
    try std.testing.expectEqual(@as(f64, 0), microbial_c[125]);
    try std.testing.expectEqual(@as(f64, 0), som[99]);
}

test "REDIST tillage initialization invalid late scratch is atomic" {
    var cell_values: [7][1]f64 = @splat(@splat(3));
    var flags = [_]u8{0};
    var scalars: [scalar_accumulator_count]f64 = @splat(4);
    scalars[156] = std.math.inf(f64);
    var microbial_c: [126]f64 = @splat(4);
    var microbial_n: [126]f64 = @splat(4);
    var microbial_p: [126]f64 = @splat(4);
    var residue_c: [10]f64 = @splat(4);
    var residue_n: [10]f64 = @splat(4);
    var residue_p: [10]f64 = @splat(4);
    var soluble: [40]f64 = @splat(4);
    var som: [100]f64 = @splat(4);
    try std.testing.expectError(error.InvalidTillageMixingInitializationInput, initializeCell(0, 0.25, .{ .ammonium_band_depth_m = &cell_values[0], .ammonium_band_extent_m = &cell_values[1], .nitrate_band_depth_m = &cell_values[2], .nitrate_band_extent_m = &cell_values[3], .phosphate_band_depth_m = &cell_values[4], .phosphate_band_extent_m = &cell_values[5], .disturbance_flag = &flags, .soil_energy_megajoules = &cell_values[6] }, .{ .scalar_accumulators = &scalars, .microbial_carbon_g_c = &microbial_c, .microbial_nitrogen_g_n = &microbial_n, .microbial_phosphorus_g_p = &microbial_p, .residue_carbon_g_c = &residue_c, .residue_nitrogen_g_n = &residue_n, .residue_phosphorus_g_p = &residue_p, .soluble_fraction_totals = &soluble, .som_fraction_totals = &som }));
    try std.testing.expectEqual(@as(f64, 3), cell_values[0][0]);
    try std.testing.expectEqual(@as(u8, 0), flags[0]);
    try std.testing.expectEqual(@as(f64, 4), microbial_c[0]);
}
