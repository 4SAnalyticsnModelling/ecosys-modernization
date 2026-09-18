// **A8a DISPOSITION: SUPERSEDED BY THE BOUND OPERATION-21 RUNTIME OWNER.**
// `surface/litter_removal.applyRuntimeCell` posts hourly C/N/P exports, heat,
// and the optional net-biome-productivity debit after validating every owner;
// the dispatcher supplies the authoritative production ledgers.
//
// **HISTORICAL A8a DISPOSITION: GAP, keep unbound and do not banner as settled.**
//
// `redist.f` 11231--11259, verified. The closeout of REDIST operation 21, which
// production parses and then drops (DIST-021), so nothing here is superseded.
//
// This module holds the postings the designated applier
// `surface/litter_removal.zig` does not perform: it publishes
// `ORGC`/`ORGN`/`ORGCC`/`ORGNC`, forms the `HFLXD` heat debit with the same
// `2.496e-6` coefficient, increments the boundary totals `HEATOU`/`TCOU`/
// `TZOU`/`TPOU` and the per-cell dissolved exports `UDOCQ`/`UDONQ`/`UDOPQ`, and
// debits `TNBP` by the removed carbon. `litter_removal.apply` returns an
// `Accounting` value and stops, so the `TNBP` debit in particular would be easy
// to lose in an adapter and would show up only as a slow carbon drift.
//
// Family analysis and what closing DIST-021 requires: docs/traceability/
// redistribution_surface_litter_removal_group_is_a_second_translation_of_a_gap.md

const std = @import("std");

pub const Totals = struct {
    remaining_carbon_g_c: f64, // DC
    remaining_nitrogen_g_n: f64, // DN
    charcoal_remaining_carbon_g_c: f64, // DCC
    charcoal_remaining_nitrogen_g_n: f64, // DNC
    removed_carbon_g_c: f64, // OC
    removed_nitrogen_g_n: f64, // ON
    removed_phosphorus_g_p: f64, // OP
};
pub const FertilizerPools = struct {
    ammonium_g_n: f64, // ZNH4S
    ammonia_g_n: f64, // ZNH3S
    nitrate_g_n: f64, // ZNO3S
    nitrite_g_n: f64, // ZNO2S
    monohydrogen_phosphate_g_p: f64, // H1PO4
    dihydrogen_phosphate_g_p: f64, // H2PO4
    exchangeable_ammonium_mol: f64, // XN4
    fertilizer_ammonium_g_n: f64, // ZNH4FA
    fertilizer_ammonia_g_n: f64, // ZNH3FA
    fertilizer_urea_g_n: f64, // ZNHUFA
    fertilizer_nitrate_g_n: f64, // ZNO3FA
};
pub const State = struct {
    fertilizer: *FertilizerPools,
    organic_carbon_g_c: f64, // ORGC
    organic_nitrogen_g_n: f64, // ORGN
    charcoal_organic_carbon_g_c: f64, // ORGCC
    charcoal_organic_nitrogen_g_n: f64, // ORGNC
    initial_organic_carbon_g_c: f64, // ORGCX
    surface_temperature_k: f64, // TKS
    heat_output_megajoules: f64, // HEATOU
    carbon_output_g_c: f64, // TCOU
    nitrogen_output_g_n: f64, // TZOU
    phosphorus_output_g_p: f64, // TPOU
    dissolved_carbon_output_g_c: f64, // UDOCQ
    dissolved_nitrogen_output_g_n: f64, // UDONQ
    dissolved_phosphorus_output_g_p: f64, // UDOPQ
    net_biome_productivity_g_c: f64, // TNBP
};

fn finiteStruct(value: anytype) bool {
    inline for (std.meta.fields(@TypeOf(value))) |field|
        if (!std.math.isFinite(@field(value, field.name))) return false;
    return true;
}

/// Direct translation of REDIST 11231--11259 at surface layer 0.
pub fn closeout(removal_fraction: f64, initial: Totals, state: *State) !void {
    if (!std.math.isFinite(removal_fraction) or removal_fraction < 0 or removal_fraction > 0.999 or
        !finiteStruct(initial) or !finiteStruct(state.fertilizer.*))
        return error.InvalidSurfaceLitterCloseoutInput;
    inline for (std.meta.fields(Totals)) |field|
        if (@field(initial, field.name) < 0) return error.InvalidSurfaceLitterCloseoutInput;
    inline for (std.meta.fields(FertilizerPools)) |field|
        if (@field(state.fertilizer.*, field.name) < 0) return error.InvalidSurfaceLitterCloseoutInput;
    inline for (std.meta.fields(State)) |field| {
        if (comptime std.mem.eql(u8, field.name, "fertilizer")) continue;
        if (!std.math.isFinite(@field(state.*, field.name))) return error.InvalidSurfaceLitterCloseoutInput;
    }
    if (state.surface_temperature_k <= 0) return error.InvalidSurfaceLitterCloseoutInput;

    var totals = initial;
    var fertilizer = state.fertilizer.*;
    totals.removed_nitrogen_g_n += removal_fraction * (fertilizer.ammonium_g_n + fertilizer.ammonia_g_n + fertilizer.nitrate_g_n + fertilizer.nitrite_g_n);
    totals.removed_phosphorus_g_p += removal_fraction * (fertilizer.monohydrogen_phosphate_g_p + fertilizer.dihydrogen_phosphate_g_p);
    const remaining_fraction = 1.0 - removal_fraction;
    inline for (std.meta.fields(FertilizerPools)) |field|
        @field(fertilizer, field.name) = remaining_fraction * @field(fertilizer, field.name);
    const heat_flux_megajoules = 2.496e-6 * (state.initial_organic_carbon_g_c - totals.remaining_carbon_g_c - totals.charcoal_remaining_carbon_g_c) * state.surface_temperature_k;
    const next_heat = state.heat_output_megajoules + heat_flux_megajoules;
    const next_carbon = state.carbon_output_g_c + totals.removed_carbon_g_c;
    const next_nitrogen = state.nitrogen_output_g_n + totals.removed_nitrogen_g_n;
    const next_phosphorus = state.phosphorus_output_g_p + totals.removed_phosphorus_g_p;
    const next_doc = state.dissolved_carbon_output_g_c + totals.removed_carbon_g_c;
    const next_don = state.dissolved_nitrogen_output_g_n + totals.removed_nitrogen_g_n;
    const next_dop = state.dissolved_phosphorus_output_g_p + totals.removed_phosphorus_g_p;
    const next_nbp = state.net_biome_productivity_g_c - totals.removed_carbon_g_c;
    inline for (.{ totals.removed_nitrogen_g_n, totals.removed_phosphorus_g_p, heat_flux_megajoules, next_heat, next_carbon, next_nitrogen, next_phosphorus, next_doc, next_don, next_dop, next_nbp }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSurfaceLitterCloseoutResult;

    state.fertilizer.* = fertilizer;
    state.organic_carbon_g_c = totals.remaining_carbon_g_c;
    state.organic_nitrogen_g_n = totals.remaining_nitrogen_g_n;
    state.charcoal_organic_carbon_g_c = totals.charcoal_remaining_carbon_g_c;
    state.charcoal_organic_nitrogen_g_n = totals.charcoal_remaining_nitrogen_g_n;
    state.heat_output_megajoules = next_heat;
    state.carbon_output_g_c = next_carbon;
    state.nitrogen_output_g_n = next_nitrogen;
    state.phosphorus_output_g_p = next_phosphorus;
    state.dissolved_carbon_output_g_c = next_doc;
    state.dissolved_nitrogen_output_g_n = next_don;
    state.dissolved_phosphorus_output_g_p = next_dop;
    state.net_biome_productivity_g_c = next_nbp;
}

fn fertilizerPools(value: f64) FertilizerPools {
    return .{ .ammonium_g_n = value, .ammonia_g_n = value, .nitrate_g_n = value, .nitrite_g_n = value, .monohydrogen_phosphate_g_p = value, .dihydrogen_phosphate_g_p = value, .exchangeable_ammonium_mol = value, .fertilizer_ammonium_g_n = value, .fertilizer_ammonia_g_n = value, .fertilizer_urea_g_n = value, .fertilizer_nitrate_g_n = value };
}
fn testState(f: *FertilizerPools) State {
    return .{ .fertilizer = f, .organic_carbon_g_c = 0, .organic_nitrogen_g_n = 0, .charcoal_organic_carbon_g_c = 0, .charcoal_organic_nitrogen_g_n = 0, .initial_organic_carbon_g_c = 100, .surface_temperature_k = 300, .heat_output_megajoules = 0, .carbon_output_g_c = 0, .nitrogen_output_g_n = 0, .phosphorus_output_g_p = 0, .dissolved_carbon_output_g_c = 0, .dissolved_nitrogen_output_g_n = 0, .dissolved_phosphorus_output_g_p = 0, .net_biome_productivity_g_c = 50 };
}

test "REDIST surface litter fertilizer heat and output closeout preserves order" {
    var f = fertilizerPools(2);
    var state = testState(&f);
    try closeout(0.25, .{ .remaining_carbon_g_c = 60, .remaining_nitrogen_g_n = 10, .charcoal_remaining_carbon_g_c = 5, .charcoal_remaining_nitrogen_g_n = 2, .removed_carbon_g_c = 20, .removed_nitrogen_g_n = 3, .removed_phosphorus_g_p = 4 }, &state);
    try std.testing.expectEqual(@as(f64, 1.5), f.ammonium_g_n);
    try std.testing.expectEqual(@as(f64, 5), state.nitrogen_output_g_n);
    try std.testing.expectEqual(@as(f64, 5), state.phosphorus_output_g_p);
    try std.testing.expectApproxEqAbs(2.496e-6 * 35 * 300, state.heat_output_megajoules, 1e-15);
    try std.testing.expectEqual(@as(f64, 30), state.net_biome_productivity_g_c);
}

test "REDIST surface litter closeout overflow is atomic" {
    var f = fertilizerPools(1);
    var state = testState(&f);
    state.dissolved_phosphorus_output_g_p = std.math.floatMax(f64);
    try std.testing.expectError(error.NonFiniteSurfaceLitterCloseoutResult, closeout(0.25, .{ .remaining_carbon_g_c = 1, .remaining_nitrogen_g_n = 1, .charcoal_remaining_carbon_g_c = 1, .charcoal_remaining_nitrogen_g_n = 1, .removed_carbon_g_c = 1, .removed_nitrogen_g_n = 1, .removed_phosphorus_g_p = std.math.floatMax(f64) }, &state));
    try std.testing.expectEqual(@as(f64, 1), f.ammonium_g_n);
    try std.testing.expectEqual(@as(f64, 0), state.carbon_output_g_c);
}
