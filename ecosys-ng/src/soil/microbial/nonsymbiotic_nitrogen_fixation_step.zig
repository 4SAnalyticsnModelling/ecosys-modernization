const std = @import("std");
const compute = @import("../../core/compute.zig");
const gas = @import("../gas/transport.zig");
const microbial = @import("state.zig");
const metabolism = @import("metabolism.zig");
const organic = @import("../organic/initialization.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const parameters_module = @import("../nutrients/nitrogen_parameters.zig");

pub const ApplyContext = struct {
    result: *fluxes.State,
    microbial_state: *const microbial.State,
    gas_state: *const gas.State,
    water_volume_m3: []const f64,
    parameters: parameters_module.Parameters,
    timestep_h: f64,
};

/// NITRO RGN2P/RGN2F/RN2FX for user-selected aerobic and anaerobic
/// diazotroph populations in the five source heterotrophic substrates K=0..4.
///
/// Corrected formulation, see `docs/model_changes.md` NITRO-N2FIX-SUPPLY.
/// The source bounds fixation only by the intensive Monod ratio on
/// `CZ2GS = Z2GS/VOLW`. That ratio saturates as the aqueous phase vanishes
/// because `VOLW` divides out, so a frozen layer whose dissolved N2 pool is
/// effectively empty still reports full N2 availability and fixes at the
/// nonstructural-carbon ceiling. This owner additionally bounds the layer's
/// total fixation by the dissolved N2 mass actually present, apportioned
/// among the competing diazotroph populations in proportion to their
/// unbounded demand. The bound is inactive whenever the pool can supply the
/// demand, which is every layer with an appreciable liquid phase.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const population_count = context.microbial_state.population_count;
    const substrate_count = context.microbial_state.substrate_count;
    const fixing_substrate_count = @min(substrate_count, organic.substrate_count);
    const p = context.parameters.nonsymbiotic_nitrogen_fixation;
    for (range.first..range.end) |layer| {
        const first = layer * context.result.process_unit_count_per_layer;
        @memset(context.result.nitrogen_fixation_respiration_g_c[first .. first + context.result.process_unit_count_per_layer], 0);
        @memset(context.result.fixed_dinitrogen_g_n[first .. first + context.result.process_unit_count_per_layer], 0);
        // hour1.f:3781-3788 sets CZ2GS = Z2GS/VOLW only when VOLW > ZEROS2,
        // otherwise CZ2GS = 0. nitro.f:2537 then uses that intensive Monod
        // factor, so a vanished carrier contributes identically zero fixation.
        if (context.water_volume_m3[layer] == 0) continue;
        const dinitrogen_index = try gas.massIndex(layer, .nitrogen, context.gas_state.cell_count);
        const dissolved_dinitrogen_g_n = @max(0, context.gas_state.dissolved_mass_g[dinitrogen_index]);
        const dinitrogen_concentration = dissolved_dinitrogen_g_n / context.water_volume_m3[layer];
        // First pass: the source-faithful unbounded demand of every unit.
        var layer_demand_g_n: f64 = 0;
        for (0..fixing_substrate_count) |substrate| for (0..population_count) |population| {
            const runtime_index = try context.microbial_state.populationIndex(layer / context.microbial_state.layer_count, layer % context.microbial_state.layer_count, substrate, population);
            const unit = layer * context.result.process_unit_count_per_layer + substrate * population_count + population;
            const is_aerobic = population == p.aerobic_diazotroph_population_index;
            const is_anaerobic = population == p.anaerobic_diazotroph_population_index;
            const value = try metabolism.nonsymbioticNitrogenFixation(.{
                .is_diazotroph = is_aerobic or is_anaerobic,
                .nonstructural_carbon_g_c = context.microbial_state.nonstructural[runtime_index].carbon_g_c,
                .nonstructural_nitrogen_g_n = context.microbial_state.nonstructural[runtime_index].nitrogen_g_n,
                .maximum_nitrogen_per_carbon_g_n_per_g_c = context.parameters.heterotrophic_respiration.target_nitrogen_per_carbon_g_n_per_g_c,
                .nitrogen_fixation_yield_g_n_per_g_c = if (is_aerobic) p.aerobic_yield_g_n_per_g_c else p.anaerobic_yield_g_n_per_g_c,
                .growth_respiration_g_c = context.result.growth_respiration_g_c[unit],
                .aqueous_dinitrogen_concentration_g_n_per_m3 = dinitrogen_concentration,
                .dinitrogen_half_saturation_g_n_per_m3 = p.dinitrogen_half_saturation_g_n_per_m3,
                .nonstructural_to_structural_rate_per_h = p.nonstructural_to_structural_rate_per_h,
                .timestep_h = context.timestep_h,
            });
            context.result.nitrogen_fixation_respiration_g_c[unit] = value.fixation_respiration_g_c;
            context.result.fixed_dinitrogen_g_n[unit] = value.fixed_nitrogen_g_n;
            layer_demand_g_n += value.fixed_nitrogen_g_n;
        };
        // Second pass: scale to the dissolved N2 the layer can actually give.
        // Proportional apportionment is the only allocation that is both
        // conservative and independent of population traversal order.
        if (layer_demand_g_n > dissolved_dinitrogen_g_n) {
            const supply_share = if (layer_demand_g_n > 0) dissolved_dinitrogen_g_n / layer_demand_g_n else 0;
            if (!std.math.isFinite(supply_share) or supply_share < 0 or supply_share > 1) return error.InvalidSoilNitrogenFixationSupplyShare;
            for (0..fixing_substrate_count * population_count) |offset| {
                const unit = first + offset;
                context.result.fixed_dinitrogen_g_n[unit] *= supply_share;
                context.result.nitrogen_fixation_respiration_g_c[unit] *= supply_share;
            }
            std.log.debug("soil dissolved N2 limits fixation: layer={d} demand_g_n={e} available_g_n={e} share={e}", .{ layer, layer_demand_g_n, dissolved_dinitrogen_g_n, supply_share });
        }
    }
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.gas_state.cell_count;
    const p = context.parameters.nonsymbiotic_nitrogen_fixation;
    if (range.first > range.end or range.end > layers or context.microbial_state.cell_count * context.microbial_state.layer_count != layers or context.result.layer_count != layers or context.result.process_unit_count_per_layer != context.microbial_state.substrate_count * context.microbial_state.population_count or context.water_volume_m3.len != layers) return error.SoilNitrogenFixationDimensionMismatch;
    if (p.aerobic_diazotroph_population_index >= context.microbial_state.population_count or p.anaerobic_diazotroph_population_index >= context.microbial_state.population_count) return error.SoilDiazotrophPopulationIndexOutOfBounds;
    if (!std.math.isFinite(context.timestep_h) or context.timestep_h <= 0) return error.InvalidSoilNitrogenFixationInput;
    for (range.first..range.end) |layer| if (!std.math.isFinite(context.water_volume_m3[layer]) or context.water_volume_m3[layer] < 0) return error.InvalidSoilNitrogenFixationInput;
}

const test_parameter_source =
    "soil_nitrification 0.001 0.0002 7000 14 1.4 1.4 0.125 0.125 0.3 0.1 0.5 2.667 3.429 1.143\n" ++
    "soil_denitrification 0.001 1.4 1.4 0.014 1 0.429 0.429 0.214 0.875\nsoil_autotrophic_denitrification 0.5 0.333\n" ++
    "soil_chemodenitrification 0.0005 0.001 1e-12 0.5 0 0.5\nnitrous_acid_dissociation_mol_per_m3 0.45\nsoil_microbial_thermal_adaptation_offset_k 0\n" ++
    "soil_nitrifier_indices 5 0 1 1\nsoil_nitrifier_environment 0.55 0.1 0.1 0.01 0.01 12 0.1\n" ++
    "soil_oxygen_uptake 1e-6 2.3866348449e11 0.064 -1.5e4 0.5 12 12 0.5 0.7 0.001 1e-12\n" ++
    "soil_heterotrophic_respiration 0.125 0.1 0.01 12 12 0.5 0.42016806722689076 0.1 2.667 0.01 0.01 1e-6 1 0.7142857142857143\n" ++
    "soil_microbial_mineral_exchange 0.014 0.0125 0.40 0.014 0.03 0.35 0.003 0.009 0.18 31\n" ++
    "soil_nonsymbiotic_nitrogen_fixation 5 6 0.25 0.02 0.14 0.25\n" ++
    "soil_microbial_turnover 0.01 0.001 0.167 0.333 0.333 0.333 0.150 0.300 0.333 0.25 2.0 5.0 1.0 0.5 0.182e-6";

test "runtime soil diazotroph roles fix dissolved dinitrogen" {
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 7);
    defer microbial_state.deinit();
    for (0..7) |population| microbial_state.nonstructural[population].carbon_g_c = 1;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[try gas.massIndex(0, .nitrogen, 1)] = 1;
    var result = try fluxes.State.init(std.testing.allocator, 1, 7);
    defer result.deinit();
    result.growth_respiration_g_c[5] = 0.5;
    result.growth_respiration_g_c[6] = 0.5;
    var context: ApplyContext = .{ .result = &result, .microbial_state = &microbial_state, .gas_state = &gas_state, .water_volume_m3 = &.{1}, .parameters = try parameters_module.parse(test_parameter_source), .timestep_h = 1 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(result.fixed_dinitrogen_g_n[5] > 0);
    try std.testing.expect(result.fixed_dinitrogen_g_n[6] > 0);
    try std.testing.expect(result.fixed_dinitrogen_g_n[5] > result.fixed_dinitrogen_g_n[6]);
    try std.testing.expectEqual(@as(f64, 0), result.fixed_dinitrogen_g_n[0]);
    try std.testing.expectApproxEqAbs(result.nitrogen_fixation_respiration_g_c[5] * 0.25, result.fixed_dinitrogen_g_n[5], 1e-15);
}

test "SOIL-N2FIX-DRY-LAYER-001 a vanished carrier skips fixation instead of fatal" {
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 7);
    defer microbial_state.deinit();
    for (0..7) |population| microbial_state.nonstructural[population].carbon_g_c = 1;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[try gas.massIndex(0, .nitrogen, 1)] = 1;
    var result = try fluxes.State.init(std.testing.allocator, 1, 7);
    defer result.deinit();
    result.growth_respiration_g_c[5] = 0.5;
    var context: ApplyContext = .{ .result = &result, .microbial_state = &microbial_state, .gas_state = &gas_state, .water_volume_m3 = &.{0}, .parameters = try parameters_module.parse(test_parameter_source), .timestep_h = 1 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 0), result.fixed_dinitrogen_g_n[5]);
}

test "NITRO K5 autotrophic substrate cannot fix N2 or dilute heterotrophic supply" {
    const substrate_count = organic.microbial_substrate_count;
    const population_count = organic.microbial_population_count;
    const process_units = substrate_count * population_count;
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, substrate_count, population_count);
    defer microbial_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    const available_g_n: f64 = 0.01;
    gas_state.dissolved_mass_g[try gas.massIndex(0, .nitrogen, 1)] = available_g_n;
    var result = try fluxes.State.init(std.testing.allocator, 1, process_units);
    defer result.deinit();

    const aerobic_population: usize = 5;
    const anaerobic_population: usize = 6;
    inline for (.{ aerobic_population, anaerobic_population }) |population| {
        const heterotrophic_unit = population;
        const autotrophic_unit = organic.autotrophic_substrate_index * population_count + population;
        microbial_state.nonstructural[heterotrophic_unit].carbon_g_c = 1000;
        microbial_state.nonstructural[autotrophic_unit].carbon_g_c = 1000;
        result.growth_respiration_g_c[heterotrophic_unit] = 500;
        result.growth_respiration_g_c[autotrophic_unit] = 500;
        // Prove this call clears stale owner data for source-excluded K=5.
        result.fixed_dinitrogen_g_n[autotrophic_unit] = 7;
        result.nitrogen_fixation_respiration_g_c[autotrophic_unit] = 11;
    }
    var context: ApplyContext = .{ .result = &result, .microbial_state = &microbial_state, .gas_state = &gas_state, .water_volume_m3 = &.{1}, .parameters = try parameters_module.parse(test_parameter_source), .timestep_h = 1 };
    try applyTile(&context, .{ .first = 0, .end = 1 });

    var heterotrophic_fixed_g_n: f64 = 0;
    inline for (.{ aerobic_population, anaerobic_population }) |population| {
        heterotrophic_fixed_g_n += result.fixed_dinitrogen_g_n[population];
        const autotrophic_unit = organic.autotrophic_substrate_index * population_count + population;
        try std.testing.expectEqual(@as(f64, 0), result.fixed_dinitrogen_g_n[autotrophic_unit]);
        try std.testing.expectEqual(@as(f64, 0), result.nitrogen_fixation_respiration_g_c[autotrophic_unit]);
    }
    try std.testing.expectApproxEqRel(available_g_n, heterotrophic_fixed_g_n, 1e-12);
}

/// Fixture reproducing the Arctic Tundra IQ frozen-layer geometry: a large
/// nonstructural carbon inventory, ample growth respiration, and a dissolved
/// N2 pool and liquid-water volume that are both near zero. The concentration
/// `dissolved/water` is unchanged by freezing because both shrink together,
/// which is exactly why the source's intensive Monod term cannot see the
/// shortage.
fn frozenLayerFixture(
    microbial_state: *microbial.State,
    gas_state: *gas.State,
    result: *fluxes.State,
    dissolved_dinitrogen_g_n: f64,
) void {
    for (0..7) |population| {
        microbial_state.nonstructural[population].carbon_g_c = 1000;
        microbial_state.nonstructural[population].nitrogen_g_n = 0;
        result.growth_respiration_g_c[population] = 500;
    }
    gas_state.dissolved_mass_g[gas.massIndex(0, .nitrogen, 1) catch unreachable] = dissolved_dinitrogen_g_n;
}

// Tier 3 conservation closure, and the direct regression for
// `examples-ng/Arctic Tundra IQ/FINDING_soil_nitrogen_conservation_closure.md`.
test "NITRO-N2FIX-SUPPLY frozen layer cannot fix more N2 than it dissolves" {
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 7);
    defer microbial_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    var result = try fluxes.State.init(std.testing.allocator, 1, 7);
    defer result.deinit();
    // The measured Arctic Tundra IQ ratio: 1.41e1 g N dissolved against a
    // demand of order 7.79e3 g N, a factor of about 550.
    const available_g_n: f64 = 1.41e1;
    frozenLayerFixture(&microbial_state, &gas_state, &result, available_g_n);
    var context: ApplyContext = .{ .result = &result, .microbial_state = &microbial_state, .gas_state = &gas_state, .water_volume_m3 = &.{1e-6}, .parameters = try parameters_module.parse(test_parameter_source), .timestep_h = 1 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    var total_fixed_g_n: f64 = 0;
    for (result.fixed_dinitrogen_g_n) |value| {
        try std.testing.expect(std.math.isFinite(value) and value >= 0);
        total_fixed_g_n += value;
    }
    // The whole point: the draw cannot exceed the pool. Without the bound this
    // fixture fixes 62.5 g N against 14.1 g N available.
    try std.testing.expect(total_fixed_g_n <= available_g_n * (1 + 1e-12));
    try std.testing.expectApproxEqRel(available_g_n, total_fixed_g_n, 1e-12);
    // Tier 1 dimensional consistency: yield converts respiration to fixed N.
    inline for (.{ .{ 5, 0.25 }, .{ 6, 0.02 } }) |pair| {
        const unit: usize = pair[0];
        const yield: f64 = pair[1];
        try std.testing.expectApproxEqAbs(result.nitrogen_fixation_respiration_g_c[unit] * yield, result.fixed_dinitrogen_g_n[unit], 1e-12);
    }
}

// Tier 4 controlled process benchmark: the bound is a one-sided constraint,
// so a layer that can supply the demand must be bit-identical to the
// unbounded source formulation. This is what confines the behaviour change
// to frozen and aqueous-free columns and leaves Ottawa untouched.
//
// The comparison holds the aqueous N2 *concentration* fixed and varies only
// the extensive pool, by scaling water volume with dissolved mass. That is the
// only controlled contrast that isolates the new bound: the source's Monod
// factor is a function of concentration alone, so any change in the total at
// fixed concentration must come from the supply bound and from nothing else.
test "NITRO-N2FIX-SUPPLY leaves an amply supplied layer unchanged" {
    var totals: [2]f64 = .{ 0, 0 };
    // Identical concentration of 1e6 g N m-3 in both cases; the pool and the
    // water volume differ by six orders of magnitude. The demand this fixture
    // generates is of order 6e1 g N, far below either pool, so the second pass
    // must not trigger at all.
    for ([2]f64{ 1e6, 1e12 }, 0..) |available_g_n, case| {
        const water_volume_m3 = available_g_n / 1e6;
        var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 7);
        defer microbial_state.deinit();
        var gas_state = try gas.State.init(std.testing.allocator, 1);
        defer gas_state.deinit();
        var result = try fluxes.State.init(std.testing.allocator, 1, 7);
        defer result.deinit();
        frozenLayerFixture(&microbial_state, &gas_state, &result, available_g_n);
        var context: ApplyContext = .{ .result = &result, .microbial_state = &microbial_state, .gas_state = &gas_state, .water_volume_m3 = &.{water_volume_m3}, .parameters = try parameters_module.parse(test_parameter_source), .timestep_h = 1 };
        try applyTile(&context, .{ .first = 0, .end = 1 });
        var total: f64 = 0;
        for (result.fixed_dinitrogen_g_n) |value| total += value;
        try std.testing.expect(total > 0);
        try std.testing.expect(total < available_g_n);
        totals[case] = total;
    }
    // Raising the pool by six orders of magnitude at fixed concentration
    // changes nothing bit-for-bit, which demonstrates the bound is inactive
    // rather than merely small here.
    try std.testing.expectEqual(totals[0], totals[1]);
    // Independently: the step total must equal the unbounded source
    // formulation evaluated directly, so the ample-supply path is not merely
    // self-consistent but agrees with the pre-change equations.
    const p = (try parameters_module.parse(test_parameter_source)).nonsymbiotic_nitrogen_fixation;
    const target_n_per_c = (try parameters_module.parse(test_parameter_source)).heterotrophic_respiration.target_nitrogen_per_carbon_g_n_per_g_c;
    var unbounded_total: f64 = 0;
    for (0..7) |population| {
        const is_aerobic = population == p.aerobic_diazotroph_population_index;
        const is_anaerobic = population == p.anaerobic_diazotroph_population_index;
        const value = try metabolism.nonsymbioticNitrogenFixation(.{
            .is_diazotroph = is_aerobic or is_anaerobic,
            .nonstructural_carbon_g_c = 1000,
            .nonstructural_nitrogen_g_n = 0,
            .maximum_nitrogen_per_carbon_g_n_per_g_c = target_n_per_c,
            .nitrogen_fixation_yield_g_n_per_g_c = if (is_aerobic) p.aerobic_yield_g_n_per_g_c else p.anaerobic_yield_g_n_per_g_c,
            .growth_respiration_g_c = 500,
            .aqueous_dinitrogen_concentration_g_n_per_m3 = 1e6,
            .dinitrogen_half_saturation_g_n_per_m3 = p.dinitrogen_half_saturation_g_n_per_m3,
            .nonstructural_to_structural_rate_per_h = p.nonstructural_to_structural_rate_per_h,
            .timestep_h = 1,
        });
        unbounded_total += value.fixed_nitrogen_g_n;
    }
    try std.testing.expectEqual(unbounded_total, totals[0]);
}

// Tier 2 valid physical domain: an empty pool admits exactly zero fixation,
// and a negative stored mass is treated as empty rather than as a source.
test "NITRO-N2FIX-SUPPLY an empty or negative dissolved N2 pool fixes nothing" {
    for ([2]f64{ 0, -1e-9 }) |stored_g_n| {
        var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 7);
        defer microbial_state.deinit();
        var gas_state = try gas.State.init(std.testing.allocator, 1);
        defer gas_state.deinit();
        var result = try fluxes.State.init(std.testing.allocator, 1, 7);
        defer result.deinit();
        frozenLayerFixture(&microbial_state, &gas_state, &result, stored_g_n);
        var context: ApplyContext = .{ .result = &result, .microbial_state = &microbial_state, .gas_state = &gas_state, .water_volume_m3 = &.{1e-9}, .parameters = try parameters_module.parse(test_parameter_source), .timestep_h = 1 };
        try applyTile(&context, .{ .first = 0, .end = 1 });
        for (result.fixed_dinitrogen_g_n) |value| try std.testing.expectEqual(@as(f64, 0), value);
        for (result.nitrogen_fixation_respiration_g_c) |value| try std.testing.expectEqual(@as(f64, 0), value);
    }
}
