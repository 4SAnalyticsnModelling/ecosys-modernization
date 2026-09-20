const std = @import("std");
const builtin = @import("builtin");
const compute = @import("../../core/compute.zig");
const gas = @import("../gas/transport.zig");
const organic = @import("../organic/initialization.zig");
const microbial = @import("../microbial/state.zig");
const chemistry = @import("../solute/chemistry_state.zig");
const zones = @import("../solute/charge_classification.zig");
const reactive = @import("reactive_nitrogen_state.zig");
const phosphorus = @import("../microbial/phosphorus_state.zig");
const competition_history = @import("competition_history.zig");
const fluxes = @import("nitrogen_flux_workspace.zig");
const turnover = @import("../microbial/turnover_step.zig");
const colonization = @import("../organic/litter_colonization_step.zig");
const organic_sorption = @import("../organic/sorption_step.zig");
const organic_decomposition = @import("../organic/decomposition_step.zig");
const organic_priming = @import("../organic/priming_step.zig");
const respiration_products = @import("../microbial/respiration_products_step.zig");
const methane_step = @import("../gas/methane_step.zig");
const transformation_aggregation = @import("../biogeochemistry/transformation_aggregation.zig");
const biochemical_acidity = @import("../chemistry/biochemical_acidity.zig");
const scoped_conservation = @import("../../validation/scoped_conservation.zig");

pub const ApplyContext = struct {
    reactive_nitrogen: *reactive.State,
    phosphorus_history: *phosphorus.State,
    nutrient_competition_attempt: ?*competition_history.Attempt = null,
    chemistry_state: *chemistry.State,
    gas_state: *gas.State,
    organic_state: *organic.State,
    microbial_state: *microbial.State,
    flux_workspace: *const fluxes.State,
    microbial_turnover: *const turnover.State,
    litter_colonization: *const colonization.State,
    organic_sorption: *const organic_sorption.State,
    organic_decomposition: *const organic_decomposition.State,
    organic_priming: ?*const organic_priming.State = null,
    respiration_products: ?*const respiration_products.State = null,
    methane: ?*const methane_step.State = null,
    autotrophic_substrate_index: usize = std.math.maxInt(usize),
    hydrogenotroph_population_index: usize = 0,
    methanotroph_population_index: usize = 0,
    // HUMUS-DEPTH-PARTITION-001: indexed by the flat layer index, not the
    // cell -- nitro.f reads CFOMC(1,L,..)/CFOMC(2,L,..) by the layer's own L
    // every hour, so every soil layer must carry its own humic/fulvic split
    // rather than reusing the top layer's value for the whole column.
    humus_partition_by_layer: []const [2]f64,
    water_volume_m3: []const f64,
    // ISSUE-065 (eighteenth pass): phosphate's dissolved concentration is the
    // only species family in this kernel read from and written back to
    // `chemistry_state` using the raw live carrier (`water_volume_m3[layer]`)
    // with no substitution for a layer that has gone dry within the hour.
    // Ammonium/nitrate deliberately keep the legacy `VOLW>ZEROS2` "skip the
    // update, leave the prior concentration alone" contract via
    // `concentrationFromMass`'s own `volume<=0 => return 0` guard combined
    // with `mineral_nitrogen_transport` owning their authoritative transport
    // carrier separately -- phosphate has no such second owner, so zeroing
    // its concentration here permanently destroys the extensive mass instead
    // of preserving it the way `soil_chemistry_water_carrier_rebase.zig`'s
    // `rememberDryCarrier`/`sourceWaterM3` do everywhere else in this
    // codebase. Default `0` preserves every existing caller/test's behavior
    // exactly (the substitution below is a no-op whenever
    // `water_volume_m3[layer] > 0`, true for every non-degenerate test).
    negligible_water_volume_m3: f64 = 0,
    zone_fractions: zones.ZoneFractions,
    zone_fractions_by_layer: []const zones.ZoneFractions = &.{},
    oxygen_satisfaction_fraction: []const f64,
    redox_satisfaction_fraction: []const f64,
    nitrogen_molar_mass_g_per_mol: f64,
    phosphorus_molar_mass_g_per_mol: f64,
    negligible_hydrogen_mol: f64,
    negligible_carbon_g_c: f64,
    fraction_tolerance: f64,
    salinity_enabled_by_cell: []const bool,
    soil_layer_capacity: usize,
    timestep_h: f64 = 1,
    hourly_signed_heterotrophic_respiration_g_c: ?[]f64 = null,
    hourly_carbon_dioxide_production_g_c: ?[]f64 = null,
};

pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |layer| try state_updateLayer(context, layer);
}

fn state_updateLayer(context: *ApplyContext, layer: usize) !void {
    try context.reactive_nitrogen.validateLayer(layer);
    const zone_fractions = zoneFractionsAt(context.*, layer);
    const water_m3 = context.water_volume_m3[layer];
    // ISSUE-065 (eighteenth pass): substitute the remembered dry-reference
    // carrier for every species' mass<->concentration round trip in this
    // function, matching `aqueous_transport_bridge.exportCarrierM3`'s
    // established substitution rule exactly. Raw `water_m3` is kept
    // unchanged for the acidity stage's own carrier
    // (`.water_volume_m3 = water_m3` below) and for the diagnostic-only
    // warning logs, so this fix touches nothing but the mass/concentration
    // round trip itself. `authoritativeLayerNitrogen_g_n`/
    // `authoritativeLayerPhosphorus_g_p` below apply the identical
    // substitution so the before/after transactional census
    // (`requireProjectedClosure`) stays self-consistent rather than comparing
    // a live-water-basis "before" against a dry-reference-basis "after".
    //
    // Ammonium/nitrate were previously left on the raw carrier because
    // `mineral_nitrogen_transport.publishMatrix` was believed to be the sole
    // authoritative writer of `chemistry.aqueous[cell].ammonium_non_band`/
    // `nitrate_non_band` (it already substitutes `dry_reference_water_m3`
    // correctly, per the twelfth addendum's own fix comment at
    // `mineral_nitrogen_transport.zig:178-187`). That belief is false: this
    // function's own `state_updateLayer` writes the SAME fields earlier in
    // the same hour (`.nitro` phase, before `mineral_nitrogen_transport`'s
    // `.solute`-phase pack/unpack ever runs), so a live-water zero here
    // corrupts the concentration `mineral_nitrogen_transport` packs from --
    // the identical two-writers-one-carrier-contract shape as the phosphate
    // defect this pass already confirmed and fixed via direct execution
    // evidence (hour 2,894's phosphorus residual cleared to roundoff after
    // this exact substitution; nitrogen's own residual is bit-for-bit
    // unaffected by that phosphate-only fix, confirming this is a distinct,
    // analogous defect rather than the same call).
    const effective_water_m3 = if (water_m3 > context.negligible_water_volume_m3)
        water_m3
    else
        context.chemistry_state.dry_reference_water_m3[layer];
    const n_mass = context.nitrogen_molar_mass_g_per_mol;
    var ammonium_non_band = context.chemistry_state.aqueous[layer].ammonium_non_band * effective_water_m3 * zone_fractions.ammonium_non_band * n_mass;
    var ammonium_band = context.chemistry_state.aqueous[layer].ammonium_band * effective_water_m3 * zone_fractions.ammonium_band * n_mass;
    if (ammonium_non_band > 1e8 or ammonium_band > 1e8) std.log.warn(
        "large ammonium entering state_update: layer={d} non_band_g={e} band_g={e} non_band_conc={e} water_m3={e}",
        .{ layer, ammonium_non_band, ammonium_band, context.chemistry_state.aqueous[layer].ammonium_non_band, water_m3 },
    );
    var nitrate_non_band = context.chemistry_state.aqueous[layer].nitrate_non_band * effective_water_m3 * zone_fractions.nitrate_non_band * n_mass;
    var nitrate_band = context.chemistry_state.aqueous[layer].nitrate_band * effective_water_m3 * zone_fractions.nitrate_band * n_mass;
    const p_mass = context.phosphorus_molar_mass_g_per_mol;
    var h2po4 = [2]f64{ context.chemistry_state.non_band_phosphate[layer].dissolved_h2po4_mol_p_per_m3 * effective_water_m3 * zone_fractions.phosphate_non_band * p_mass, context.chemistry_state.band_phosphate[layer].dissolved_h2po4_mol_p_per_m3 * effective_water_m3 * zone_fractions.phosphate_band * p_mass };
    var hpo4 = [2]f64{ context.chemistry_state.non_band_phosphate[layer].dissolved_hpo4_mol_p_per_m3 * effective_water_m3 * zone_fractions.phosphate_non_band * p_mass, context.chemistry_state.band_phosphate[layer].dissolved_hpo4_mol_p_per_m3 * effective_water_m3 * zone_fractions.phosphate_band * p_mass };
    var nitrite_non_band = context.reactive_nitrogen.non_band_nitrite_g_n[layer];
    var nitrite_band = context.reactive_nitrogen.band_nitrite_g_n[layer];
    const n2o_index = try gas.massIndex(layer, .nitrous_oxide, context.gas_state.cell_count);
    const n2_index = try gas.massIndex(layer, .nitrogen, context.gas_state.cell_count);
    const co2_index = try gas.massIndex(layer, .carbon_dioxide, context.gas_state.cell_count);
    const methane_index = try gas.massIndex(layer, .methane, context.gas_state.cell_count);
    const hydrogen_index = try gas.massIndex(layer, .hydrogen, context.gas_state.cell_count);
    const oxygen_index = try gas.massIndex(layer, .oxygen, context.gas_state.cell_count);
    var nitrous_oxide = context.gas_state.dissolved_mass_g[n2o_index];
    var dinitrogen = context.gas_state.dissolved_mass_g[n2_index];
    var carbon_dioxide = context.gas_state.dissolved_mass_g[co2_index];
    var methane = context.gas_state.dissolved_mass_g[methane_index];
    const carbon_dioxide_before = carbon_dioxide;
    const methane_before = methane;
    var hydrogen = context.gas_state.dissolved_mass_g[hydrogen_index];
    const hydrogen_before_g_h = hydrogen;
    const aqueous_oxygen = context.gas_state.dissolved_mass_g[oxygen_index];
    const gaseous_oxygen = context.gas_state.gaseous_mass_g[oxygen_index];
    const conserved_nitrogen_before_g_n = try authoritativeLayerNitrogen_g_n(context.*, layer);
    const conserved_phosphorus_before_g_p = try authoritativeLayerPhosphorus_g_p(context.*, layer);
    const first = layer * context.flux_workspace.process_unit_count_per_layer;
    const end = first + context.flux_workspace.process_unit_count_per_layer;
    const next_nonstructural = try context.microbial_state.allocator.alloc(microbial.ElementalPool, end - first);
    defer context.microbial_state.allocator.free(next_nonstructural);
    const next_structural = try context.microbial_state.allocator.alloc(microbial.ElementalPool, 2 * (end - first));
    defer context.microbial_state.allocator.free(next_structural);

    const published = try transformation_aggregation.calculateSupplyLimited(.{
        .complex_count = context.microbial_state.substrate_count,
        .population_count = context.microbial_state.population_count,
        .oxygen_satisfaction_fraction = context.oxygen_satisfaction_fraction[first..end],
        .redox_satisfaction_fraction = context.redox_satisfaction_fraction[first..end],
        .non_band_ammonia_oxidation_potential_g_n = context.flux_workspace.non_band_ammonia_oxidation_potential_g_n[first..end],
        .band_ammonia_oxidation_potential_g_n = context.flux_workspace.band_ammonia_oxidation_potential_g_n[first..end],
        .non_band_nitrite_oxidation_potential_g_n = context.flux_workspace.non_band_nitrite_oxidation_potential_g_n[first..end],
        .band_nitrite_oxidation_potential_g_n = context.flux_workspace.band_nitrite_oxidation_potential_g_n[first..end],
        .non_band_nitrate_reduction_potential_g_n = context.flux_workspace.non_band_nitrate_reduction_potential_g_n[first..end],
        .band_nitrate_reduction_potential_g_n = context.flux_workspace.band_nitrate_reduction_potential_g_n[first..end],
        .non_band_heterotrophic_nitrite_reduction_potential_g_n = context.flux_workspace.non_band_heterotrophic_nitrite_reduction_potential_g_n[first..end],
        .band_heterotrophic_nitrite_reduction_potential_g_n = context.flux_workspace.band_heterotrophic_nitrite_reduction_potential_g_n[first..end],
        .non_band_autotrophic_nitrite_reduction_potential_g_n = context.flux_workspace.non_band_autotrophic_nitrite_reduction_potential_g_n[first..end],
        .band_autotrophic_nitrite_reduction_potential_g_n = context.flux_workspace.band_autotrophic_nitrite_reduction_potential_g_n[first..end],
        .non_band_autotrophic_ammonium_oxidation_potential_g_n = context.flux_workspace.non_band_autotrophic_ammonium_oxidation_potential_g_n[first..end],
        .band_autotrophic_ammonium_oxidation_potential_g_n = context.flux_workspace.band_autotrophic_ammonium_oxidation_potential_g_n[first..end],
        .nitrous_oxide_reduction_potential_g_n = context.flux_workspace.nitrous_oxide_reduction_potential_g_n[first..end],
        .non_band_ammonium_exchange_g_n = context.flux_workspace.non_band_microbial_ammonium_exchange_g_n[first..end],
        .band_ammonium_exchange_g_n = context.flux_workspace.band_microbial_ammonium_exchange_g_n[first..end],
        .non_band_nitrate_exchange_g_n = context.flux_workspace.non_band_microbial_nitrate_exchange_g_n[first..end],
        .band_nitrate_exchange_g_n = context.flux_workspace.band_microbial_nitrate_exchange_g_n[first..end],
        .non_band_h2po4_exchange_g_p = context.flux_workspace.non_band_microbial_h2po4_exchange_g_p[first..end],
        .band_h2po4_exchange_g_p = context.flux_workspace.band_microbial_h2po4_exchange_g_p[first..end],
        .non_band_hpo4_exchange_g_p = context.flux_workspace.non_band_microbial_hpo4_exchange_g_p[first..end],
        .band_hpo4_exchange_g_p = context.flux_workspace.band_microbial_hpo4_exchange_g_p[first..end],
        .fixed_dinitrogen_g_n = context.flux_workspace.fixed_dinitrogen_g_n[first..end],
    });
    const ammonia_oxidation = published.ammonia_oxidation_g_n;
    const nitrite_oxidation = published.nitrite_oxidation_g_n;
    const nitrate_reduction = published.nitrate_reduction_g_n;
    const heterotrophic_nitrite_reduction = published.heterotrophic_nitrite_reduction_g_n;
    const autotrophic_nitrite_reduction = published.autotrophic_nitrite_reduction_g_n;
    const autotrophic_ammonium_oxidation = published.autotrophic_ammonium_oxidation_g_n;
    const nitrous_oxide_reduction = published.nitrous_oxide_reduction_g_n;
    const microbial_ammonium_exchange = published.ammonium_exchange_g_n;
    const microbial_nitrate_exchange = published.nitrate_exchange_g_n;
    const microbial_h2po4_exchange = published.h2po4_exchange_g_p;
    const microbial_hpo4_exchange = published.hpo4_exchange_g_p;
    const acidity = if (context.salinity_enabled_by_cell[layer / context.soil_layer_capacity]) try biochemical_acidity.stage(
        context.chemistry_state,
        layer,
        .{
            .water_volume_m3 = water_m3,
            .ammonia_oxidation_g_n = published.ammonia_oxidation_g_n,
            .nitrate_reduction_g_n = published.nitrate_reduction_g_n,
            .nitrite_reduction_g_n = published.heterotrophic_nitrite_reduction_g_n,
            .nitrous_oxide_reduction_g_n = published.nitrous_oxide_reduction_g_n,
            .lignin_decomposition_g_c = ligninDecompositionForAcidity(
                context.organic_decomposition,
                layer,
            ),
            .timestep_h = context.timestep_h,
            .negligible_hydrogen_mol = context.negligible_hydrogen_mol,
        },
    ) else null;
    var respiratory_carbon_dioxide_g_c: f64 = 0;
    var committed_carbon_dioxide_emission_g_c: f64 = 0;
    var fermentation_hydrogen_production_g_h: f64 = 0;
    for (first..end) |unit| {
        const redox = context.redox_satisfaction_fraction[unit];
        const aerobic_respiration_g_c = if (context.respiration_products) |products| products.carbon_dioxide_g_c[unit] else context.flux_workspace.actual_aerobic_respiration_g_c[unit];
        const denitrification_respiration_g_c = context.flux_workspace.denitrification_respiration_g_c[unit] * redox;
        const fixation_respiration_g_c = context.flux_workspace.nitrogen_fixation_respiration_g_c[unit];
        const respiration_g_c = aerobic_respiration_g_c + denitrification_respiration_g_c + fixation_respiration_g_c;
        respiratory_carbon_dioxide_g_c += respiration_g_c;
        // K=5 autotrophic RGOMD is paired with CGOMD in
        // autotrophic_carbon_step and committed there as the source net
        // CGROMC transfer. Crediting it here as heterotrophic respiration
        // would count RGOMD twice and create carbon.
        const substrate = (unit - first) / context.microbial_state.population_count;
        committed_carbon_dioxide_emission_g_c += respiration_g_c - if (substrate == context.autotrophic_substrate_index) denitrification_respiration_g_c else 0;
        if (context.respiration_products) |products| {
            if (context.methane == null) methane += products.methane_g_c[unit];
            const production_g_h = products.hydrogen_g_h[unit];
            fermentation_hydrogen_production_g_h += production_g_h;
            hydrogen += production_g_h;
        }
        for (0..2) |component| {
            const recycled_g_c = context.microbial_turnover.senescence[unit * 2 + component].recycled.carbon_g_c;
            respiratory_carbon_dioxide_g_c += recycled_g_c;
            committed_carbon_dioxide_emission_g_c += recycled_g_c;
        }
    }
    const chemo_nitrite = [2]f64{ context.flux_workspace.chemodenitrification_non_band_nitrite_reduction_g_n[layer], context.flux_workspace.chemodenitrification_band_nitrite_reduction_g_n[layer] };
    const chemo_n2o = context.flux_workspace.chemodenitrification_nitrous_oxide_production_g_n[layer];
    const chemo_n2 = context.flux_workspace.chemodenitrification_dinitrogen_production_g_n[layer];
    const chemo_don = context.flux_workspace.chemodenitrification_dissolved_organic_nitrogen_production_g_n[layer];
    const chemo_consumed = chemo_nitrite[0] + chemo_nitrite[1];
    const chemo_products = chemo_n2o + chemo_n2 + chemo_don;
    const chemo_closure = try scoped_conservation.evaluateTransfer(
        chemo_consumed,
        chemo_products,
        1,
        .{
            .absolute = 128 * std.math.floatEps(f64) * @max(chemo_consumed, chemo_products),
            .relative = 32 * std.math.floatEps(f64),
        },
    );
    if (!chemo_closure.accepted) return error.SoilNitrogenBalanceFailure;

    try applyZone(&ammonium_non_band, &nitrate_non_band, &nitrite_non_band, ammonia_oxidation[0], nitrite_oxidation[0], nitrate_reduction[0], heterotrophic_nitrite_reduction[0], autotrophic_nitrite_reduction[0], autotrophic_ammonium_oxidation[0], chemo_nitrite[0]);
    try applyZone(&ammonium_band, &nitrate_band, &nitrite_band, ammonia_oxidation[1], nitrite_oxidation[1], nitrate_reduction[1], heterotrophic_nitrite_reduction[1], autotrophic_nitrite_reduction[1], autotrophic_ammonium_oxidation[1], chemo_nitrite[1]);
    try applyMicrobialExchange(&ammonium_non_band, microbial_ammonium_exchange[0]);
    try applyMicrobialExchange(&ammonium_band, microbial_ammonium_exchange[1]);
    try applyMicrobialExchange(&nitrate_non_band, microbial_nitrate_exchange[0]);
    try applyMicrobialExchange(&nitrate_band, microbial_nitrate_exchange[1]);
    try applyMicrobialExchange(&h2po4[0], microbial_h2po4_exchange[0]);
    try applyMicrobialExchange(&h2po4[1], microbial_h2po4_exchange[1]);
    try applyMicrobialExchange(&hpo4[0], microbial_hpo4_exchange[0]);
    try applyMicrobialExchange(&hpo4[1], microbial_hpo4_exchange[1]);
    // This is the live N2O/N2 (RN2O/RN2G) partition commit. It is an
    // independent reimplementation of, not a call to,
    // `transformation_aggregation.zig`'s `calculateGasStateUpdate`, which is
    // dead code (GAS-STATE-UPDATE-DEAD-001, see that function's doc comment
    // and docs/discrepancy_register.md) -- a fix applied only there has no
    // simulation effect; fix the arithmetic here instead.
    const biological_n2o_input = heterotrophic_nitrite_reduction[0] + heterotrophic_nitrite_reduction[1] + autotrophic_nitrite_reduction[0] + autotrophic_nitrite_reduction[1];
    nitrous_oxide = try nonnegativeCandidate(
        nitrous_oxide + biological_n2o_input + chemo_n2o - nitrous_oxide_reduction,
        @abs(nitrous_oxide) + @abs(biological_n2o_input) + @abs(chemo_n2o) + @abs(nitrous_oxide_reduction),
        error.InsufficientSoilNitrousOxide,
    );
    dinitrogen = try nonnegativeCandidate(
        dinitrogen + nitrous_oxide_reduction + chemo_n2 - published.fixed_dinitrogen_g_n,
        @abs(dinitrogen) + @abs(nitrous_oxide_reduction) + @abs(chemo_n2) + @abs(published.fixed_dinitrogen_g_n),
        error.InsufficientSoilDinitrogen,
    );
    // This is the live RCO2O-equivalent CO2 commit. The former unread runtime
    // aggregation shadow was removed; `biogeochemical_gas_aggregation.zig`
    // remains only a pure reference-equation oracle.
    carbon_dioxide += committed_carbon_dioxide_emission_g_c;
    var methanogenesis_hydrogen_consumption_g_h: f64 = 0;
    if (context.methane) |methane_result| {
        methane = methane_result.aqueous_methane_after_g_c[layer];
        methanogenesis_hydrogen_consumption_g_h = methane_result.hydrogen_consumption_g_h[layer];
        hydrogen -= methanogenesis_hydrogen_consumption_g_h;
        // NITRO.F 2580--2583/3821: methanotroph combustion plus respiration
        // become CO2; hydrogenotroph gross CO2 uptake pays respiration and
        // the remainder is credited below to that population's
        // nonstructural carbon.
        carbon_dioxide += methane_result.methane_oxidation_combustion_g_c[layer] + methane_result.methane_oxidation_respiration_g_c[layer] - methane_result.hydrogenotrophic_carbon_dioxide_uptake_g_c[layer];
        hydrogen = try nonnegativeCandidate(
            hydrogen,
            @abs(hydrogen_before_g_h) + @abs(fermentation_hydrogen_production_g_h) + @abs(methanogenesis_hydrogen_consumption_g_h),
            error.InsufficientSoilMethanogenesisSubstrate,
        );
        carbon_dioxide = try nonnegativeCandidate(
            carbon_dioxide,
            @abs(carbon_dioxide_before) + @abs(committed_carbon_dioxide_emission_g_c) + @abs(methane_result.methane_oxidation_combustion_g_c[layer]) + @abs(methane_result.methane_oxidation_respiration_g_c[layer]) + @abs(methane_result.hydrogenotrophic_carbon_dioxide_uptake_g_c[layer]),
            error.InsufficientSoilMethanogenesisSubstrate,
        );
        // K=5,N=3 oxygen was already consumed exactly once by the shared
        // oxygen allocator. `methane_result.oxygen_demand_g_o` is the same
        // accepted process-unit uptake and must not debit the gas owner again.
    }
    const hydrogen_scale_g_h = @max(
        @max(hydrogen_before_g_h, hydrogen),
        @max(fermentation_hydrogen_production_g_h, methanogenesis_hydrogen_consumption_g_h),
    );
    const hydrogen_closure = try scoped_conservation.evaluate(.{
        .storage_before = hydrogen_before_g_h,
        .storage_after = hydrogen,
        .internal_production = fermentation_hydrogen_production_g_h,
        .internal_consumption = methanogenesis_hydrogen_consumption_g_h,
    }, .{
        .absolute = 128 * std.math.floatEps(f64) * hydrogen_scale_g_h,
        .relative = 32 * std.math.floatEps(f64),
    });
    if (!hydrogen_closure.accepted) return error.SoilHydrogenTransformationImbalance;

    var residue_total_g_c: f64 = 0;
    var residue_by_complex_g_c: [organic.substrate_count]f64 = .{0} ** organic.substrate_count;
    var dissolved_after: [organic.substrate_count]organic.ElementPool = undefined;
    var dissolved_acetate_after_g_c: [organic.substrate_count]f64 = undefined;
    var adsorbed_after: [organic.substrate_count]organic.ElementPool = undefined;
    var adsorbed_acetate_after_g_c: [organic.substrate_count]f64 = undefined;
    var carbon_nonnegative_roundoff_adjustment_g_c: f64 = 0;
    for (0..organic.substrate_count) |complex| for (0..organic.residue_fraction_count) |fraction| {
        const carbon = context.organic_state.residue[(layer * organic.substrate_count + complex) * organic.residue_fraction_count + fraction].carbon_g_c;
        residue_by_complex_g_c[complex] += carbon;
        residue_total_g_c += carbon;
    };
    for (0..organic.substrate_count) |complex| {
        const fraction: f64 = if (residue_total_g_c > context.negligible_carbon_g_c) residue_by_complex_g_c[complex] / residue_total_g_c else if (complex == 3) 1 else 0;
        const mobile = layer * organic.substrate_count + complex;
        var doc_uptake: f64 = 0;
        var don_uptake: f64 = 0;
        var dop_uptake: f64 = 0;
        var acetate_uptake: f64 = 0;
        var fermentation_acetate_g_c: f64 = 0;
        if (complex < context.microbial_state.substrate_count) for (0..context.microbial_state.population_count) |population| {
            const unit = first + complex * context.microbial_state.population_count + population;
            doc_uptake += context.flux_workspace.doc_uptake_g_c[unit];
            don_uptake += context.flux_workspace.dissolved_organic_nitrogen_uptake_g_n[unit];
            dop_uptake += context.flux_workspace.dissolved_organic_phosphorus_uptake_g_p[unit];
            acetate_uptake += context.flux_workspace.acetate_uptake_g_c[unit];
            if (context.respiration_products) |products| fermentation_acetate_g_c += products.acetate_g_c[unit];
        };
        const priming_dissolved: organic.ElementPool = if (context.organic_priming) |priming| priming.exchange.dissolved_change[mobile] else .{};
        const priming_acetate_g_c: f64 = if (context.organic_priming) |priming| priming.exchange.acetate_change_g_c[mobile] else 0;
        const source_dissolved = context.organic_state.dissolved[mobile];
        const current: organic.ElementPool = .{ .carbon_g_c = source_dissolved.carbon_g_c + priming_dissolved.carbon_g_c, .nitrogen_g_n = source_dissolved.nitrogen_g_n + priming_dissolved.nitrogen_g_n, .phosphorus_g_p = source_dissolved.phosphorus_g_p + priming_dissolved.phosphorus_g_p };
        var sorbed = context.organic_sorption.exchange[mobile];
        var decomposition_products: organic.ElementPool = .{};
        for (0..organic.structural_fraction_count) |structural_fraction| addPool(&decomposition_products, context.organic_decomposition.dissolved_structural_products[mobile * organic.structural_fraction_count + structural_fraction]);
        for (0..organic.residue_fraction_count) |residue_fraction| addPool(&decomposition_products, context.organic_decomposition.microbial_residue_decomposition[mobile * organic.residue_fraction_count + residue_fraction]);
        addPool(&decomposition_products, context.organic_decomposition.sorbed_organic_decomposition[mobile]);
        const current_adsorbed = context.organic_state.adsorbed[mobile];
        const decomposed_sorbed = context.organic_decomposition.sorbed_organic_decomposition[mobile];
        const dissolved_before_sorption: organic.ElementPool = .{ .carbon_g_c = current.carbon_g_c + decomposition_products.carbon_g_c - doc_uptake, .nitrogen_g_n = current.nitrogen_g_n + decomposition_products.nitrogen_g_n - don_uptake + chemo_don * fraction, .phosphorus_g_p = current.phosphorus_g_p + decomposition_products.phosphorus_g_p - dop_uptake };
        const adsorbed_before_sorption: organic.ElementPool = .{ .carbon_g_c = current_adsorbed.carbon_g_c - decomposed_sorbed.carbon_g_c, .nitrogen_g_n = current_adsorbed.nitrogen_g_n - decomposed_sorbed.nitrogen_g_n, .phosphorus_g_p = current_adsorbed.phosphorus_g_p - decomposed_sorbed.phosphorus_g_p };
        sorbed.doc_g_c = boundedExchange(sorbed.doc_g_c, dissolved_before_sorption.carbon_g_c, adsorbed_before_sorption.carbon_g_c);
        sorbed.don_g_n = boundedExchange(sorbed.don_g_n, dissolved_before_sorption.nitrogen_g_n, adsorbed_before_sorption.nitrogen_g_n);
        sorbed.dop_g_p = boundedExchange(sorbed.dop_g_p, dissolved_before_sorption.phosphorus_g_p, adsorbed_before_sorption.phosphorus_g_p);
        dissolved_after[complex] = .{ .carbon_g_c = dissolved_before_sorption.carbon_g_c - sorbed.doc_g_c, .nitrogen_g_n = dissolved_before_sorption.nitrogen_g_n - sorbed.don_g_n, .phosphorus_g_p = dissolved_before_sorption.phosphorus_g_p - sorbed.dop_g_p };
        const dissolved_acetate_before_sorption = context.organic_state.dissolved_acetate_carbon_g_c[mobile] + priming_acetate_g_c + context.organic_decomposition.sorbed_acetate_decomposition_g_c[mobile] + fermentation_acetate_g_c - acetate_uptake;
        const adsorbed_acetate_before_sorption = context.organic_state.adsorbed_acetate_carbon_g_c[mobile] - context.organic_decomposition.sorbed_acetate_decomposition_g_c[mobile];
        sorbed.acetate_g_c = boundedExchange(sorbed.acetate_g_c, dissolved_acetate_before_sorption, adsorbed_acetate_before_sorption);
        dissolved_acetate_after_g_c[complex] = dissolved_acetate_before_sorption - sorbed.acetate_g_c;
        adsorbed_after[complex] = .{ .carbon_g_c = current_adsorbed.carbon_g_c - decomposed_sorbed.carbon_g_c + sorbed.doc_g_c, .nitrogen_g_n = current_adsorbed.nitrogen_g_n - decomposed_sorbed.nitrogen_g_n + sorbed.don_g_n, .phosphorus_g_p = current_adsorbed.phosphorus_g_p - decomposed_sorbed.phosphorus_g_p + sorbed.dop_g_p };
        adsorbed_acetate_after_g_c[complex] = adsorbed_acetate_before_sorption + sorbed.acetate_g_c;
        inline for (@typeInfo(organic.ElementPool).@"struct".fields) |field| {
            const source_value = @field(source_dissolved, field.name);
            const priming_value = @field(priming_dissolved, field.name);
            const decomposition_value =
                @field(decomposition_products, field.name);
            const uptake_value = switch (field.name[0]) {
                'c' => doc_uptake,
                'n' => don_uptake - chemo_don * fraction,
                'p' => dop_uptake,
                else => unreachable,
            };
            const sorption_value = switch (field.name[0]) {
                'c' => sorbed.doc_g_c,
                'n' => sorbed.don_g_n,
                'p' => sorbed.dop_g_p,
                else => unreachable,
            };
            const raw_dissolved = @field(dissolved_after[complex], field.name);
            @field(dissolved_after[complex], field.name) =
                normalizeNonnegativeRoundoff(
                    raw_dissolved,
                    @abs(source_value) + @abs(priming_value) +
                        @abs(decomposition_value) + @abs(uptake_value) +
                        @abs(sorption_value),
                );
            if (field.name[0] == 'c') carbon_nonnegative_roundoff_adjustment_g_c +=
                @field(dissolved_after[complex], field.name) - raw_dissolved;
            const value = @field(dissolved_after[complex], field.name);
            if (!std.math.isFinite(value) or value < 0) {
                std.log.warn(
                    "invalid dissolved organic state_update: layer={d} complex={d} pool={s} value={e} source={e} priming={e} decomposition={e} uptake={e} proposed_sorption={e} bounded_sorption={e}",
                    .{ layer, complex, field.name, value, source_value, priming_value, decomposition_value, uptake_value, switch (field.name[0]) {
                        'c' => context.organic_sorption.exchange[mobile].doc_g_c,
                        'n' => context.organic_sorption.exchange[mobile].don_g_n,
                        'p' => context.organic_sorption.exchange[mobile].dop_g_p,
                        else => unreachable,
                    }, sorption_value },
                );
                return error.InvalidSoilNitrogenStateUpdate;
            }
        }
        const raw_dissolved_acetate = dissolved_acetate_after_g_c[complex];
        dissolved_acetate_after_g_c[complex] =
            normalizeNonnegativeRoundoff(
                raw_dissolved_acetate,
                @abs(dissolved_acetate_before_sorption) +
                    @abs(sorbed.acetate_g_c),
            );
        carbon_nonnegative_roundoff_adjustment_g_c +=
            dissolved_acetate_after_g_c[complex] - raw_dissolved_acetate;
        if (!std.math.isFinite(dissolved_acetate_after_g_c[complex]) or dissolved_acetate_after_g_c[complex] < 0) {
            std.log.warn("invalid dissolved acetate state_update: layer={d} complex={d} value_g_c={e}", .{ layer, complex, dissolved_acetate_after_g_c[complex] });
            return error.InvalidSoilNitrogenStateUpdate;
        }
        inline for (@typeInfo(organic.ElementPool).@"struct".fields) |field| {
            const raw_adsorbed = @field(adsorbed_after[complex], field.name);
            @field(adsorbed_after[complex], field.name) =
                normalizeNonnegativeRoundoff(
                    raw_adsorbed,
                    @abs(@field(current_adsorbed, field.name)) +
                        @abs(@field(decomposed_sorbed, field.name)) +
                        @abs(switch (field.name[0]) {
                            'c' => sorbed.doc_g_c,
                            'n' => sorbed.don_g_n,
                            'p' => sorbed.dop_g_p,
                            else => unreachable,
                        }),
                );
            if (field.name[0] == 'c') carbon_nonnegative_roundoff_adjustment_g_c +=
                @field(adsorbed_after[complex], field.name) - raw_adsorbed;
            const value = @field(adsorbed_after[complex], field.name);
            if (!std.math.isFinite(value) or value < 0) {
                std.log.warn("invalid adsorbed organic state_update: layer={d} complex={d} pool={s} value={e}", .{ layer, complex, field.name, value });
                return error.InvalidSoilNitrogenStateUpdate;
            }
        }
        const raw_adsorbed_acetate = adsorbed_acetate_after_g_c[complex];
        adsorbed_acetate_after_g_c[complex] =
            normalizeNonnegativeRoundoff(
                raw_adsorbed_acetate,
                @abs(adsorbed_acetate_before_sorption) +
                    @abs(sorbed.acetate_g_c),
            );
        carbon_nonnegative_roundoff_adjustment_g_c +=
            adsorbed_acetate_after_g_c[complex] - raw_adsorbed_acetate;
        if (!std.math.isFinite(adsorbed_acetate_after_g_c[complex]) or adsorbed_acetate_after_g_c[complex] < 0) {
            std.log.warn("invalid adsorbed acetate state_update: layer={d} complex={d} value_g_c={e}", .{ layer, complex, adsorbed_acetate_after_g_c[complex] });
            return error.InvalidSoilNitrogenStateUpdate;
        }
    }
    var residue_after: [organic.substrate_count * organic.residue_fraction_count]organic.ElementPool = undefined;
    @memcpy(&residue_after, context.organic_state.residue[layer * organic.substrate_count * organic.residue_fraction_count ..][0 .. organic.substrate_count * organic.residue_fraction_count]);
    var heterotrophic_residue_carbon_g_c: [organic.substrate_count - 1]f64 = .{0} ** (organic.substrate_count - 1);
    var total_heterotrophic_residue_carbon_g_c: f64 = 0;
    for (0..organic.substrate_count - 1) |complex| for (0..organic.residue_fraction_count) |component| {
        const carbon = residue_after[complex * organic.residue_fraction_count + component].carbon_g_c;
        heterotrophic_residue_carbon_g_c[complex] += carbon;
        total_heterotrophic_residue_carbon_g_c += carbon;
    };
    for (0..residue_after.len) |index| subtractPool(&residue_after[index], context.organic_decomposition.microbial_residue_decomposition[layer * residue_after.len + index]);
    const structural_first = layer * organic.substrate_count * organic.structural_fraction_count;
    var structural_after: [organic.substrate_count * organic.structural_fraction_count]organic.ElementPool = undefined;
    var colonized_after: [organic.substrate_count * organic.structural_fraction_count]f64 = undefined;
    @memcpy(&structural_after, context.organic_state.structural[structural_first..][0..structural_after.len]);
    @memcpy(&colonized_after, context.organic_state.colonized_structural_carbon_g_c[structural_first..][0..colonized_after.len]);
    var particulate_products: organic.ElementPool = .{};
    for (0..structural_after.len) |offset| {
        const decomposed = context.organic_decomposition.structural_decomposition[structural_first + offset];
        subtractPool(&structural_after[offset], decomposed);
        colonized_after[offset] -= decomposed.carbon_g_c;
        addPool(&particulate_products, context.organic_decomposition.particulate_products[structural_first + offset]);
        colonized_after[offset] += context.litter_colonization.colonized_carbon_increment_g_c[structural_first + offset];
    }
    const particulate_index = 3 * organic.structural_fraction_count;
    addPool(&structural_after[particulate_index], particulate_products);
    colonized_after[particulate_index] += particulate_products.carbon_g_c;
    const humus_first = (layer * organic.substrate_count + 4) * organic.structural_fraction_count;
    const humus_local = 4 * organic.structural_fraction_count;
    var humus_after = [2]organic.ElementPool{ structural_after[humus_local], structural_after[humus_local + 1] };
    var humus_colonized_after = [2]f64{ colonized_after[humus_local], colonized_after[humus_local + 1] };
    const humus_partition = context.humus_partition_by_layer[layer];
    // MICROBIAL-POOL-CARBON-OVERDRAW-HOUR-2678-001. Total carbon added by clamping
    // negative nonstructural pools to zero in the loop below, debited from the
    // layer's dissolved CO2 after it so the pair nets to zero.
    var microbial_carbon_clamp_g_c: f64 = 0;
    for (0..context.microbial_state.substrate_count) |substrate| for (0..context.microbial_state.population_count) |population| {
        if (!microbial.nitroPopulationEnabled(substrate, population)) continue;
        const runtime_index = try context.microbial_state.populationIndex(layer / context.microbial_state.layer_count, layer % context.microbial_state.layer_count, substrate, population);
        const unit = first + substrate * context.microbial_state.population_count + population;
        const priming_base = (layer * organic.substrate_count * context.microbial_state.population_count + substrate * context.microbial_state.population_count + population) * organic.kinetic_fraction_count;
        const priming_nonstructural: organic.ElementPool = if (context.organic_priming != null and substrate < organic.substrate_count) context.organic_priming.?.exchange.microbial_change[priming_base + 2] else .{};
        const source_nonstructural = context.microbial_state.nonstructural[runtime_index];
        const current: @TypeOf(source_nonstructural) = .{ .carbon_g_c = source_nonstructural.carbon_g_c + priming_nonstructural.carbon_g_c, .nitrogen_g_n = source_nonstructural.nitrogen_g_n + priming_nonstructural.nitrogen_g_n, .phosphorus_g_p = source_nonstructural.phosphorus_g_p + priming_nonstructural.phosphorus_g_p };
        const mineral_n = context.flux_workspace.non_band_microbial_ammonium_exchange_g_n[unit] + context.flux_workspace.band_microbial_ammonium_exchange_g_n[unit] + context.flux_workspace.non_band_microbial_nitrate_exchange_g_n[unit] + context.flux_workspace.band_microbial_nitrate_exchange_g_n[unit];
        const mineral_p = context.flux_workspace.non_band_microbial_h2po4_exchange_g_p[unit] + context.flux_workspace.band_microbial_h2po4_exchange_g_p[unit] + context.flux_workspace.non_band_microbial_hpo4_exchange_g_p[unit] + context.flux_workspace.band_microbial_hpo4_exchange_g_p[unit];
        const assimilated: @TypeOf(current) = .{
            .carbon_g_c = context.flux_workspace.labile_assimilation_g_c[unit] + context.flux_workspace.resistant_assimilation_g_c[unit],
            .nitrogen_g_n = context.flux_workspace.labile_assimilation_g_n[unit] + context.flux_workspace.resistant_assimilation_g_n[unit],
            .phosphorus_g_p = context.flux_workspace.labile_assimilation_g_p[unit] + context.flux_workspace.resistant_assimilation_g_p[unit],
        };
        var recycled: @TypeOf(current) = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
        var component_assimilation: [2]microbial.ElementalPool = undefined;
        var component_basal_recycled: [2]microbial.ElementalPool = undefined;
        var component_senescence_recycled: [2]microbial.ElementalPool = undefined;
        for (0..2) |component| {
            const basal = context.microbial_turnover.basal[unit * 2 + component];
            const senescence = context.microbial_turnover.senescence[unit * 2 + component];
            try validateMicrobialDecompositionBalance(basal);
            try validateMicrobialDecompositionBalance(senescence);
            component_assimilation[component] = if (component == 0)
                .{ .carbon_g_c = context.flux_workspace.labile_assimilation_g_c[unit], .nitrogen_g_n = context.flux_workspace.labile_assimilation_g_n[unit], .phosphorus_g_p = context.flux_workspace.labile_assimilation_g_p[unit] }
            else
                .{ .carbon_g_c = context.flux_workspace.resistant_assimilation_g_c[unit], .nitrogen_g_n = context.flux_workspace.resistant_assimilation_g_n[unit], .phosphorus_g_p = context.flux_workspace.resistant_assimilation_g_p[unit] };
            component_basal_recycled[component] = .{ .carbon_g_c = basal.recycled.carbon_g_c, .nitrogen_g_n = basal.recycled.nitrogen_g_n, .phosphorus_g_p = basal.recycled.phosphorus_g_p };
            component_senescence_recycled[component] = .{ .carbon_g_c = senescence.recycled.carbon_g_c, .nitrogen_g_n = senescence.recycled.nitrogen_g_n, .phosphorus_g_p = senescence.recycled.phosphorus_g_p };
            recycled.carbon_g_c += basal.recycled.carbon_g_c;
            recycled.nitrogen_g_n += basal.recycled.nitrogen_g_n + senescence.recycled.nitrogen_g_n;
            recycled.phosphorus_g_p += basal.recycled.phosphorus_g_p + senescence.recycled.phosphorus_g_p;
            const residue_product: organic.ElementPool = .{ .carbon_g_c = basal.microbial_residue.carbon_g_c + senescence.microbial_residue.carbon_g_c, .nitrogen_g_n = basal.microbial_residue.nitrogen_g_n + senescence.microbial_residue.nitrogen_g_n, .phosphorus_g_p = basal.microbial_residue.phosphorus_g_p + senescence.microbial_residue.phosphorus_g_p };
            if (substrate == context.autotrophic_substrate_index) {
                for (0..organic.substrate_count - 1) |complex| {
                    const fraction: f64 = if (total_heterotrophic_residue_carbon_g_c > context.negligible_carbon_g_c) heterotrophic_residue_carbon_g_c[complex] / total_heterotrophic_residue_carbon_g_c else if (complex == 3) 1 else 0;
                    const residue_index = complex * organic.residue_fraction_count + component;
                    residue_after[residue_index].carbon_g_c += residue_product.carbon_g_c * fraction;
                    residue_after[residue_index].nitrogen_g_n += residue_product.nitrogen_g_n * fraction;
                    residue_after[residue_index].phosphorus_g_p += residue_product.phosphorus_g_p * fraction;
                }
            } else {
                const residue_index = substrate * organic.residue_fraction_count + component;
                residue_after[residue_index].carbon_g_c += residue_product.carbon_g_c;
                residue_after[residue_index].nitrogen_g_n += residue_product.nitrogen_g_n;
                residue_after[residue_index].phosphorus_g_p += residue_product.phosphorus_g_p;
            }
            const humified_c = basal.humified.carbon_g_c + senescence.humified.carbon_g_c;
            const humified_n = basal.humified.nitrogen_g_n + senescence.humified.nitrogen_g_n;
            const humified_p = basal.humified.phosphorus_g_p + senescence.humified.phosphorus_g_p;
            for (0..2) |humus_class| {
                humus_after[humus_class].carbon_g_c += humified_c * humus_partition[humus_class];
                humus_after[humus_class].nitrogen_g_n += humified_n * humus_partition[humus_class];
                humus_after[humus_class].phosphorus_g_p += humified_p * humus_partition[humus_class];
                humus_colonized_after[humus_class] += humified_c * humus_partition[humus_class];
            }
            const priming_structural: organic.ElementPool = if (context.organic_priming != null and substrate < organic.substrate_count) context.organic_priming.?.exchange.microbial_change[priming_base + component] else .{};
            const source_structural = context.microbial_state.structural[runtime_index * 2 + component];
            const structural_current: @TypeOf(source_structural) = .{ .carbon_g_c = source_structural.carbon_g_c + priming_structural.carbon_g_c, .nitrogen_g_n = source_structural.nitrogen_g_n + priming_structural.nitrogen_g_n, .phosphorus_g_p = source_structural.phosphorus_g_p + priming_structural.phosphorus_g_p };
            const structural_assimilation: @TypeOf(current) = if (component == 0) .{ .carbon_g_c = context.flux_workspace.labile_assimilation_g_c[unit], .nitrogen_g_n = context.flux_workspace.labile_assimilation_g_n[unit], .phosphorus_g_p = context.flux_workspace.labile_assimilation_g_p[unit] } else .{ .carbon_g_c = context.flux_workspace.resistant_assimilation_g_c[unit], .nitrogen_g_n = context.flux_workspace.resistant_assimilation_g_n[unit], .phosphorus_g_p = context.flux_workspace.resistant_assimilation_g_p[unit] };
            const candidate_structural: @TypeOf(current) = .{ .carbon_g_c = structural_current.carbon_g_c + structural_assimilation.carbon_g_c - basal.decomposed.carbon_g_c - senescence.decomposed.carbon_g_c, .nitrogen_g_n = structural_current.nitrogen_g_n + structural_assimilation.nitrogen_g_n - basal.decomposed.nitrogen_g_n - senescence.decomposed.nitrogen_g_n, .phosphorus_g_p = structural_current.phosphorus_g_p + structural_assimilation.phosphorus_g_p - basal.decomposed.phosphorus_g_p - senescence.decomposed.phosphorus_g_p };
            inline for (@typeInfo(@TypeOf(candidate_structural)).@"struct".fields) |field| if (!std.math.isFinite(@field(candidate_structural, field.name)) or @field(candidate_structural, field.name) < 0) return error.InvalidSoilMicrobialStateUpdate;
            next_structural[(unit - first) * 2 + component] = candidate_structural;
        }
        const methane_nonstructural_gain_g_c: f64 = if (context.methane) |methane_result|
            if (substrate == context.autotrophic_substrate_index)
                if (population == context.hydrogenotroph_population_index)
                    methane_result.hydrogenotrophic_nonstructural_carbon_gain_g_c[layer]
                else if (population == context.methanotroph_population_index)
                    methane_result.methanotroph_nonstructural_carbon_gain_g_c[layer]
                else
                    0
            else
                0
        else
            0;
        const net_carbon_uptake_g_c = context.flux_workspace.nonstructural_carbon_gain_g_c[unit] + methane_nonstructural_gain_g_c;
        var next = try microbial.calculateNonstructuralStateUpdate(.{
            .current = current,
            .assimilation = component_assimilation,
            .basal_recycled = component_basal_recycled,
            .senescence_recycled = component_senescence_recycled,
            .net_carbon_uptake_g_c = net_carbon_uptake_g_c,
            .dissolved_organic_nitrogen_uptake_g_n = context.flux_workspace.dissolved_organic_nitrogen_uptake_g_n[unit],
            .mineral_nitrogen_exchange_g_n = mineral_n,
            .fixed_nitrogen_g_n = context.flux_workspace.fixed_dinitrogen_g_n[unit],
            .dissolved_organic_phosphorus_uptake_g_p = context.flux_workspace.dissolved_organic_phosphorus_uptake_g_p[unit],
            .mineral_phosphorus_exchange_g_p = mineral_p,
        });
        // MICROBIAL-POOL-CARBON-OVERDRAW-HOUR-2678-001. `net_carbon_uptake_g_c` is
        // uptake minus respiration and goes negative when respiration exceeds
        // uptake, which can drive the pool below zero -- measured once in 2,677
        // hours at `-1.2936078130910764e-7` g C (layer 0, substrate 1,
        // population 5, from a `1.82e-6` pool with `carbon_gain=-3.23e-6`).
        //
        // The oracle stores that negative and neutralises it on every read, via
        // `AMAX1(0.0, OMC(1..3,...))` at `nitro.f:431`, `:454`, `:2094` and
        // `:2532`, while writing unclamped at `:3824` and `:3832`. So the pool
        // *behaves* as zero everywhere the oracle consumes it; the negative is
        // never spent.
        //
        // Clamping here reproduces that observable behaviour with the pool held in
        // the non-negative domain the rest of this translation assumes -- fifteen
        // separate storage and audit guards across six modules encode that
        // assumption, and relaxing them all was measured to be an unbounded chain
        // for no frontier gain (see the register).
        //
        // Clamping *creates* carbon, so it is paid for exactly: the respiration
        // that could not be supplied produced no CO2, and the same amount is
        // removed from the layer's dissolved CO2 below. Both pools are in this
        // cell's inventory, so the hourly conservation gate sees an internal
        // transfer that nets to zero -- no new ledger lane, and nothing clipped
        // without being accounted.
        if (next.carbon_g_c < 0) {
            microbial_carbon_clamp_g_c += -next.carbon_g_c;
            std.log.info(
                "microbial nonstructural carbon clamped to zero, debited from CO2: layer={d} substrate={d} population={d} clamped_g_c={e} carbon_gain={e}",
                .{ layer, substrate, population, -next.carbon_g_c, net_carbon_uptake_g_c },
            );
            next.carbon_g_c = 0;
        }
        next_nonstructural[unit - first] = next;
        // `MICROBIAL-POOL-CARBON-OVERDRAW-HOUR-2678-001`. This is the production
        // duplicate of `microbial/state.zig`'s nonstructural guard, and it carried
        // the same invented domain: it rejected a negative pool outright.
        //
        // The oracle allows `OMC/OMN/OMP(3,...)` to go negative in storage and
        // clamps it on every read:
        //
        //   nitro.f:3821  CGROMC=CGOMC(N,K)-RGOMO(N,K)-RGOMD(N,K)-RGN2F(N,K)
        //   nitro.f:3832  OMC(3,...)=OMC(3,...)+CGROMC          <- no AMAX1
        //   nitro.f:2094  OMC3=AMAX1(0.0,OMC(3,...))            <- clamp on read
        //   nitro.f:2532  OMC3=AMAX1(0.0,OMC(3,...))            <- clamp on read
        //
        // `CGROMC` is uptake minus aerobic, denitrification and N2-fixation
        // respiration, so it is negative whenever respiration exceeds uptake --
        // which is precisely the measured state here: `carbon_gain=-3.233628224739175e-6`
        // drove `carbon_g_c` to `-1.2936078130910764e-7` from a `1.82e-6` pool at
        // layer 0, substrate 1, population 5. The two oracle `AMAX1` read sites are
        // only necessary because the stored value can be negative.
        //
        // Finiteness stays fatal -- NaN or infinity is never a state the oracle
        // produces. The warning is retained at `.info` so the event stays visible
        // without being terminal, and the always-on hourly conservation gate
        // remains the guarantee that nothing is silently created or destroyed.
        inline for (@typeInfo(@TypeOf(next)).@"struct".fields) |field| {
            const value = @field(next, field.name);
            if (!std.math.isFinite(value)) {
                std.log.warn(
                    "non-finite microbial nonstructural state_update: layer={d} substrate={d} population={d} pool={s} value={e} current={e} carbon_gain={e} assimilated={e} recycled={e} mineral_n={e} mineral_p={e}",
                    .{ layer, substrate, population, field.name, value, @field(current, field.name), net_carbon_uptake_g_c, @field(assimilated, field.name), @field(recycled, field.name), mineral_n, mineral_p },
                );
                return error.InvalidSoilMicrobialStateUpdate;
            }
            if (value < 0) std.log.info(
                "negative microbial nonstructural pool (oracle-permitted, clamped on read): layer={d} substrate={d} population={d} pool={s} value={e} carbon_gain={e}",
                .{ layer, substrate, population, field.name, value, net_carbon_uptake_g_c },
            );
        }
        const structural_values = [6]f64{ context.flux_workspace.labile_assimilation_g_c[unit], context.flux_workspace.labile_assimilation_g_n[unit], context.flux_workspace.labile_assimilation_g_p[unit], context.flux_workspace.resistant_assimilation_g_c[unit], context.flux_workspace.resistant_assimilation_g_n[unit], context.flux_workspace.resistant_assimilation_g_p[unit] };
        for (structural_values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilMicrobialStateUpdate;
    };
    // Pay for every clamp above out of the CO2 the unsupplied respiration did not
    // actually produce. `carbon_dioxide` is written back to
    // `gas_state.dissolved_mass_g[co2_index]` and the booked production ledger is
    // derived from `carbon_dioxide - carbon_dioxide_before`, so this single
    // subtraction keeps both the state and the booking consistent.
    if (microbial_carbon_clamp_g_c > 0) {
        carbon_dioxide = try nonnegativeCandidate(
            carbon_dioxide - microbial_carbon_clamp_g_c,
            @abs(carbon_dioxide) + @abs(microbial_carbon_clamp_g_c),
            error.InvalidSoilMicrobialStateUpdate,
        );
        respiratory_carbon_dioxide_g_c = @max(0, respiratory_carbon_dioxide_g_c - microbial_carbon_clamp_g_c);
    }
    for (residue_after) |pool| inline for (@typeInfo(organic.ElementPool).@"struct".fields) |field| if (!std.math.isFinite(@field(pool, field.name)) or @field(pool, field.name) < 0) return error.InvalidSoilMicrobialStateUpdate;
    for (structural_after) |pool| inline for (@typeInfo(organic.ElementPool).@"struct".fields) |field| if (!std.math.isFinite(@field(pool, field.name)) or @field(pool, field.name) < 0) return error.InvalidSoilOrganicDecompositionStateUpdate;
    for (humus_after) |pool| inline for (@typeInfo(organic.ElementPool).@"struct".fields) |field| if (!std.math.isFinite(@field(pool, field.name)) or @field(pool, field.name) < 0) return error.InvalidSoilMicrobialStateUpdate;
    for (&colonized_after, structural_after) |*colonized, pool| {
        colonized.* = try nonnegativeCandidate(
            colonized.*,
            @max(@abs(colonized.*), @abs(pool.carbon_g_c)),
            error.InvalidSoilLitterColonizationStateUpdate,
        );
        if (colonized.* > pool.carbon_g_c) return error.InvalidSoilLitterColonizationStateUpdate;
    }

    const ammonium_non_band_concentration = try concentrationFromMass(ammonium_non_band, effective_water_m3, zone_fractions.ammonium_non_band, n_mass);
    const ammonium_band_concentration = try concentrationFromMass(ammonium_band, effective_water_m3, zone_fractions.ammonium_band, n_mass);
    const nitrate_non_band_concentration = try concentrationFromMass(nitrate_non_band, effective_water_m3, zone_fractions.nitrate_non_band, n_mass);
    const nitrate_band_concentration = try concentrationFromMass(nitrate_band, effective_water_m3, zone_fractions.nitrate_band, n_mass);
    const non_band_h2po4_concentration = try concentrationFromMass(h2po4[0], effective_water_m3, zone_fractions.phosphate_non_band, p_mass);
    const band_h2po4_concentration = try concentrationFromMass(h2po4[1], effective_water_m3, zone_fractions.phosphate_band, p_mass);
    const non_band_hpo4_concentration = try concentrationFromMass(hpo4[0], effective_water_m3, zone_fractions.phosphate_non_band, p_mass);
    const band_hpo4_concentration = try concentrationFromMass(hpo4[1], effective_water_m3, zone_fractions.phosphate_band, p_mass);
    try validatePublishedAmmonium(
        layer,
        context.chemistry_state.water_mol_per_m3[layer],
        .{ ammonium_non_band_concentration, ammonium_band_concentration },
        .{ ammonium_non_band, ammonium_band },
        microbial_ammonium_exchange,
        .{
            ammonia_oxidation[0] + autotrophic_ammonium_oxidation[0],
            ammonia_oxidation[1] + autotrophic_ammonium_oxidation[1],
        },
        water_m3,
        .{
            zone_fractions.ammonium_non_band,
            zone_fractions.ammonium_band,
        },
    );
    const projected_carbon_delta_g_c = try projectedLayerCarbonDelta_g_c(
        context.*,
        layer,
        dissolved_after,
        dissolved_acetate_after_g_c,
        adsorbed_after,
        adsorbed_acetate_after_g_c,
        residue_after,
        structural_after,
        humus_after,
        next_nonstructural,
        next_structural,
        carbon_dioxide,
        methane,
    );
    try requireProjectedDeltaClosure(
        projected_carbon_delta_g_c,
        carbon_nonnegative_roundoff_adjustment_g_c,
        layer,
        error.InvalidSoilCarbonConservationClosure,
    );
    const projected_nitrogen_after_g_n = try projectedLayerNitrogen_g_n(
        context.*,
        layer,
        .{ ammonium_non_band, ammonium_band },
        .{ nitrate_non_band, nitrate_band },
        .{ nitrite_non_band, nitrite_band },
        nitrous_oxide,
        dinitrogen,
        dissolved_after,
        adsorbed_after,
        residue_after,
        structural_after,
        humus_after,
        next_nonstructural,
        next_structural,
    );
    try requireProjectedClosure(
        conserved_nitrogen_before_g_n,
        projected_nitrogen_after_g_n,
        layer,
        error.InvalidSoilNitrogenConservationClosure,
    );
    const projected_phosphorus_after_g_p = try projectedLayerPhosphorus_g_p(
        context.*,
        layer,
        h2po4,
        hpo4,
        dissolved_after,
        adsorbed_after,
        residue_after,
        structural_after,
        humus_after,
        next_nonstructural,
        next_structural,
    );
    try requireProjectedClosure(
        conserved_phosphorus_before_g_p,
        projected_phosphorus_after_g_p,
        layer,
        error.InvalidSoilPhosphorusConservationClosure,
    );

    // No authoritative C/N/P owner is changed before all projected candidate
    // censuses pass. The remainder is a publication-only commit; no residual
    // is injected into a carrier after the fact.
    context.chemistry_state.aqueous[layer].ammonium_non_band = ammonium_non_band_concentration;
    context.chemistry_state.aqueous[layer].ammonium_band = ammonium_band_concentration;
    context.chemistry_state.aqueous[layer].nitrate_non_band = nitrate_non_band_concentration;
    context.chemistry_state.aqueous[layer].nitrate_band = nitrate_band_concentration;
    context.chemistry_state.non_band_phosphate[layer].dissolved_h2po4_mol_p_per_m3 = non_band_h2po4_concentration;
    context.chemistry_state.band_phosphate[layer].dissolved_h2po4_mol_p_per_m3 = band_h2po4_concentration;
    context.chemistry_state.non_band_phosphate[layer].dissolved_hpo4_mol_p_per_m3 = non_band_hpo4_concentration;
    context.chemistry_state.band_phosphate[layer].dissolved_hpo4_mol_p_per_m3 = band_hpo4_concentration;
    // `stage` above validated both the layer and every published acidity
    // candidate. This commit must therefore be infallible: returning an error
    // after the C/N/P owners above were published would violate transaction
    // atomicity.
    if (acidity) |staged| biochemical_acidity.state_update(
        context.chemistry_state,
        layer,
        staged,
    ) catch unreachable;
    context.reactive_nitrogen.non_band_nitrite_g_n[layer] = nitrite_non_band;
    context.reactive_nitrogen.band_nitrite_g_n[layer] = nitrite_band;
    context.reactive_nitrogen.previous_non_band_chemodenitrification_capacity_g_n[layer] = context.flux_workspace.chemodenitrification_non_band_unlimited_reduction_g_n[layer];
    context.reactive_nitrogen.previous_band_chemodenitrification_capacity_g_n[layer] = context.flux_workspace.chemodenitrification_band_unlimited_reduction_g_n[layer];
    var next_non_band_ammonium_demand: f64 = 0;
    var next_band_ammonium_demand: f64 = 0;
    var next_non_band_nitrite_demand = context.flux_workspace.chemodenitrification_non_band_unlimited_reduction_g_n[layer];
    var next_band_nitrite_demand = context.flux_workspace.chemodenitrification_band_unlimited_reduction_g_n[layer];
    var next_non_band_nitrate_demand: f64 = 0;
    var next_band_nitrate_demand: f64 = 0;
    var next_nitrous_oxide_demand: f64 = 0;
    var next_h2po4_demand = [2]f64{ 0, 0 };
    var next_hpo4_demand = [2]f64{ 0, 0 };
    var next_aerobic_oxygen_demand: f64 = 0;
    for (first..end) |unit| {
        context.reactive_nitrogen.previous_aerobic_oxygen_demand_g_o[unit] = context.flux_workspace.aerobic_oxygen_demand_g_o[unit];
        next_aerobic_oxygen_demand += context.flux_workspace.aerobic_oxygen_demand_g_o[unit];
        context.reactive_nitrogen.previous_doc_respiration_demand_g_c[unit] = context.flux_workspace.doc_respiration_demand_g_c[unit];
        context.reactive_nitrogen.previous_acetate_respiration_demand_g_c[unit] = context.flux_workspace.acetate_respiration_demand_g_c[unit];
        context.reactive_nitrogen.previous_non_band_ammonia_oxidation_capacity_g_n[unit] = context.flux_workspace.non_band_ammonia_oxidation_capacity_g_n[unit];
        context.reactive_nitrogen.previous_band_ammonia_oxidation_capacity_g_n[unit] = context.flux_workspace.band_ammonia_oxidation_capacity_g_n[unit];
        context.reactive_nitrogen.previous_non_band_nitrite_oxidation_capacity_g_n[unit] = context.flux_workspace.non_band_nitrite_oxidation_capacity_g_n[unit];
        context.reactive_nitrogen.previous_band_nitrite_oxidation_capacity_g_n[unit] = context.flux_workspace.band_nitrite_oxidation_capacity_g_n[unit];
        context.reactive_nitrogen.previous_non_band_nitrate_reduction_capacity_g_n[unit] = context.flux_workspace.non_band_nitrate_reduction_capacity_g_n[unit];
        context.reactive_nitrogen.previous_band_nitrate_reduction_capacity_g_n[unit] = context.flux_workspace.band_nitrate_reduction_capacity_g_n[unit];
        context.reactive_nitrogen.previous_non_band_nitrite_reduction_capacity_g_n[unit] = context.flux_workspace.non_band_nitrite_reduction_capacity_g_n[unit];
        context.reactive_nitrogen.previous_band_nitrite_reduction_capacity_g_n[unit] = context.flux_workspace.band_nitrite_reduction_capacity_g_n[unit];
        context.reactive_nitrogen.previous_nitrous_oxide_reduction_capacity_g_n[unit] = context.flux_workspace.nitrous_oxide_reduction_capacity_g_n[unit];
        context.reactive_nitrogen.previous_non_band_microbial_ammonium_capacity_g_n[unit] = context.flux_workspace.non_band_microbial_ammonium_capacity_g_n[unit];
        context.reactive_nitrogen.previous_band_microbial_ammonium_capacity_g_n[unit] = context.flux_workspace.band_microbial_ammonium_capacity_g_n[unit];
        context.reactive_nitrogen.previous_non_band_microbial_nitrate_capacity_g_n[unit] = context.flux_workspace.non_band_microbial_nitrate_capacity_g_n[unit];
        context.reactive_nitrogen.previous_band_microbial_nitrate_capacity_g_n[unit] = context.flux_workspace.band_microbial_nitrate_capacity_g_n[unit];
        next_non_band_ammonium_demand += context.flux_workspace.non_band_ammonia_oxidation_capacity_g_n[unit];
        next_band_ammonium_demand += context.flux_workspace.band_ammonia_oxidation_capacity_g_n[unit];
        next_non_band_ammonium_demand += context.flux_workspace.non_band_microbial_ammonium_capacity_g_n[unit];
        next_band_ammonium_demand += context.flux_workspace.band_microbial_ammonium_capacity_g_n[unit];
        next_non_band_nitrite_demand += context.flux_workspace.non_band_nitrite_oxidation_capacity_g_n[unit] + context.flux_workspace.non_band_nitrite_reduction_capacity_g_n[unit];
        next_band_nitrite_demand += context.flux_workspace.band_nitrite_oxidation_capacity_g_n[unit] + context.flux_workspace.band_nitrite_reduction_capacity_g_n[unit];
        next_non_band_nitrate_demand += context.flux_workspace.non_band_nitrate_reduction_capacity_g_n[unit];
        next_band_nitrate_demand += context.flux_workspace.band_nitrate_reduction_capacity_g_n[unit];
        next_non_band_nitrate_demand += context.flux_workspace.non_band_microbial_nitrate_capacity_g_n[unit];
        next_band_nitrate_demand += context.flux_workspace.band_microbial_nitrate_capacity_g_n[unit];
        next_nitrous_oxide_demand += context.flux_workspace.nitrous_oxide_reduction_capacity_g_n[unit];
        context.phosphorus_history.previous_non_band_h2po4_capacity_g_p[unit] = context.flux_workspace.non_band_microbial_h2po4_capacity_g_p[unit];
        context.phosphorus_history.previous_band_h2po4_capacity_g_p[unit] = context.flux_workspace.band_microbial_h2po4_capacity_g_p[unit];
        context.phosphorus_history.previous_non_band_hpo4_capacity_g_p[unit] = context.flux_workspace.non_band_microbial_hpo4_capacity_g_p[unit];
        context.phosphorus_history.previous_band_hpo4_capacity_g_p[unit] = context.flux_workspace.band_microbial_hpo4_capacity_g_p[unit];
        next_h2po4_demand[0] += context.flux_workspace.non_band_microbial_h2po4_capacity_g_p[unit];
        next_h2po4_demand[1] += context.flux_workspace.band_microbial_h2po4_capacity_g_p[unit];
        next_hpo4_demand[0] += context.flux_workspace.non_band_microbial_hpo4_capacity_g_p[unit];
        next_hpo4_demand[1] += context.flux_workspace.band_microbial_hpo4_capacity_g_p[unit];
    }
    if (context.nutrient_competition_attempt) |attempt| {
        try attempt.setSoil(layer, .{
            next_non_band_ammonium_demand,
            next_band_ammonium_demand,
            next_non_band_nitrate_demand,
            next_band_nitrate_demand,
            next_h2po4_demand[0],
            next_h2po4_demand[1],
            next_hpo4_demand[0],
            next_hpo4_demand[1],
        });
    } else {
        // Standalone callers that do not own the outer-hour transaction retain
        // the legacy immediate publication contract. Production always binds
        // the accepted-history attempt.
        context.reactive_nitrogen.previous_total_non_band_ammonium_demand_g_n[layer] = next_non_band_ammonium_demand;
        context.reactive_nitrogen.previous_total_band_ammonium_demand_g_n[layer] = next_band_ammonium_demand;
        context.reactive_nitrogen.previous_total_non_band_nitrate_demand_g_n[layer] = next_non_band_nitrate_demand;
        context.reactive_nitrogen.previous_total_band_nitrate_demand_g_n[layer] = next_band_nitrate_demand;
        context.phosphorus_history.previous_total_non_band_h2po4_demand_g_p[layer] = next_h2po4_demand[0];
        context.phosphorus_history.previous_total_band_h2po4_demand_g_p[layer] = next_h2po4_demand[1];
        context.phosphorus_history.previous_total_non_band_hpo4_demand_g_p[layer] = next_hpo4_demand[0];
        context.phosphorus_history.previous_total_band_hpo4_demand_g_p[layer] = next_hpo4_demand[1];
    }
    context.reactive_nitrogen.previous_total_non_band_nitrite_demand_g_n[layer] = next_non_band_nitrite_demand;
    context.reactive_nitrogen.previous_total_band_nitrite_demand_g_n[layer] = next_band_nitrite_demand;
    context.reactive_nitrogen.previous_total_nitrous_oxide_demand_g_n[layer] = next_nitrous_oxide_demand;
    context.reactive_nitrogen.previous_total_aerobic_oxygen_demand_g_o[layer] = next_aerobic_oxygen_demand;
    context.reactive_nitrogen.current_nitrification_inhibition_activity[layer] = context.flux_workspace.layer_nitrification_inhibition_activity[layer];
    context.gas_state.dissolved_mass_g[n2o_index] = nitrous_oxide;
    context.gas_state.dissolved_mass_g[n2_index] = dinitrogen;
    context.gas_state.dissolved_mass_g[co2_index] = carbon_dioxide;
    context.gas_state.dissolved_mass_g[methane_index] = methane;
    if (context.hourly_signed_heterotrophic_respiration_g_c) |ledger|
        ledger[layer] = -((carbon_dioxide - carbon_dioxide_before) + (methane - methane_before));
    if (context.hourly_carbon_dioxide_production_g_c) |ledger|
        ledger[layer] = respiratory_carbon_dioxide_g_c + if (context.methane) |methane_result| methane_result.methane_oxidation_combustion_g_c[layer] + methane_result.methane_oxidation_respiration_g_c[layer] else 0;
    context.gas_state.dissolved_mass_g[hydrogen_index] = hydrogen;
    context.gas_state.dissolved_mass_g[oxygen_index] = aqueous_oxygen;
    context.gas_state.gaseous_mass_g[oxygen_index] = gaseous_oxygen;
    if (context.methane) |methane_result| context.gas_state.gaseous_mass_g[methane_index] = methane_result.gaseous_methane_after_g_c[layer];
    for (0..organic.substrate_count) |complex| {
        const mobile = layer * organic.substrate_count + complex;
        context.organic_state.dissolved[mobile] = dissolved_after[complex];
        context.organic_state.dissolved_acetate_carbon_g_c[mobile] = dissolved_acetate_after_g_c[complex];
        context.organic_state.adsorbed[mobile] = adsorbed_after[complex];
        context.organic_state.adsorbed_acetate_carbon_g_c[mobile] = adsorbed_acetate_after_g_c[complex];
    }
    @memcpy(context.organic_state.residue[layer * organic.substrate_count * organic.residue_fraction_count ..][0 .. organic.substrate_count * organic.residue_fraction_count], &residue_after);
    @memcpy(context.organic_state.structural[structural_first..][0..structural_after.len], &structural_after);
    @memcpy(context.organic_state.colonized_structural_carbon_g_c[structural_first..][0..colonized_after.len], &colonized_after);
    context.organic_state.structural[humus_first] = humus_after[0];
    context.organic_state.structural[humus_first + 1] = humus_after[1];
    context.organic_state.colonized_structural_carbon_g_c[humus_first] = humus_colonized_after[0];
    context.organic_state.colonized_structural_carbon_g_c[humus_first + 1] = humus_colonized_after[1];
    for (0..context.microbial_state.substrate_count) |substrate| for (0..context.microbial_state.population_count) |population| {
        if (!microbial.nitroPopulationEnabled(substrate, population)) continue;
        const runtime_index = context.microbial_state.populationIndex(layer / context.microbial_state.layer_count, layer % context.microbial_state.layer_count, substrate, population) catch unreachable;
        const unit = first + substrate * context.microbial_state.population_count + population;
        if (context.organic_priming != null and substrate < organic.substrate_count) {
            const priming_base = (layer * organic.substrate_count * context.microbial_state.population_count + substrate * context.microbial_state.population_count + population) * organic.kinetic_fraction_count;
            const changes = context.organic_priming.?.exchange.microbial_change[priming_base..][0..organic.kinetic_fraction_count];
            context.microbial_state.structural[runtime_index * 2].carbon_g_c += changes[0].carbon_g_c;
            context.microbial_state.structural[runtime_index * 2].nitrogen_g_n += changes[0].nitrogen_g_n;
            context.microbial_state.structural[runtime_index * 2].phosphorus_g_p += changes[0].phosphorus_g_p;
            context.microbial_state.structural[runtime_index * 2 + 1].carbon_g_c += changes[1].carbon_g_c;
            context.microbial_state.structural[runtime_index * 2 + 1].nitrogen_g_n += changes[1].nitrogen_g_n;
            context.microbial_state.structural[runtime_index * 2 + 1].phosphorus_g_p += changes[1].phosphorus_g_p;
        }
        context.microbial_state.nonstructural[runtime_index] = next_nonstructural[unit - first];
        for (0..2) |component| {
            context.microbial_state.structural[runtime_index * 2 + component] =
                next_structural[(unit - first) * 2 + component];
        }
    };
}

/// Complete carbon owner changed by one NITRO layer state_update. The organic
/// mirror is unchanged during the transaction, so including it in both
/// snapshots cancels exactly while the authoritative microbial state records
/// its actual change. Closing the residual in dissolved CO2 prevents many
/// partition products from manufacturing carbon through accumulated rounding.
fn authoritativeLayerCarbon_g_c(context: ApplyContext, layer: usize) !f64 {
    var total = try context.organic_state.totalCarbon_g_c(layer);
    const cell = layer / context.microbial_state.layer_count;
    const local_layer = layer % context.microbial_state.layer_count;
    for (0..context.microbial_state.substrate_count) |substrate|
        for (0..context.microbial_state.population_count) |population| {
            const population_index = try context.microbial_state.populationIndex(
                cell,
                local_layer,
                substrate,
                population,
            );
            total += context.microbial_state.nonstructural[population_index].carbon_g_c;
            total += context.microbial_state.structural[population_index * 2].carbon_g_c;
            total += context.microbial_state.structural[population_index * 2 + 1].carbon_g_c;
        };
    inline for (.{ gas.Species.carbon_dioxide, gas.Species.methane }) |species| {
        const index = try gas.massIndex(layer, species, context.gas_state.cell_count);
        total += context.gas_state.gaseous_mass_g[index];
        total += context.gas_state.dissolved_mass_g[index];
        total += context.gas_state.macropore_dissolved_mass_g[index];
        total += context.gas_state.band_dissolved_mass_g[index];
    }
    if (!std.math.isFinite(total)) return error.NonFiniteSoilCarbonConservationCensus;
    return total;
}

/// Complete nitrogen ownership changed by one NITRO layer state_update. Mineral
/// concentrations are converted back to tracked-element grams using the same
/// water volume and zone fractions used at state_update.
fn authoritativeLayerNitrogen_g_n(context: ApplyContext, layer: usize) !f64 {
    var total: f64 = context.reactive_nitrogen.non_band_nitrite_g_n[layer] +
        context.reactive_nitrogen.band_nitrite_g_n[layer];
    const water_m3 = context.water_volume_m3[layer];
    // ISSUE-065 (eighteenth pass): must match `state_updateLayer`'s own
    // `effective_water_m3` substitution exactly -- see that function's
    // comment for why. Otherwise this "before" census would use a different
    // carrier basis than the "after" census
    // (`projectedLayerNitrogen_g_n`/`projectedLayerCarbonDelta_g_c`, which
    // both sum the already-substituted mass values directly) and trip
    // `requireProjectedClosure` on every hour a layer is dry.
    const effective_water_m3 = if (water_m3 > context.negligible_water_volume_m3)
        water_m3
    else
        context.chemistry_state.dry_reference_water_m3[layer];
    const aqueous = context.chemistry_state.aqueous[layer];
    const zone_fractions = zoneFractionsAt(context, layer);
    total += context.nitrogen_molar_mass_g_per_mol * effective_water_m3 *
        (aqueous.ammonium_non_band * zone_fractions.ammonium_non_band +
            aqueous.ammonium_band * zone_fractions.ammonium_band +
            aqueous.nitrate_non_band * zone_fractions.nitrate_non_band +
            aqueous.nitrate_band * zone_fractions.nitrate_band);
    const organic_first = layer * organic.substrate_count;
    for (context.organic_state.dissolved[organic_first..][0..organic.substrate_count]) |pool|
        total += pool.nitrogen_g_n;
    for (context.organic_state.adsorbed[organic_first..][0..organic.substrate_count]) |pool|
        total += pool.nitrogen_g_n;
    const residue_first = layer * organic.substrate_count * organic.residue_fraction_count;
    for (context.organic_state.residue[residue_first..][0 .. organic.substrate_count * organic.residue_fraction_count]) |pool|
        total += pool.nitrogen_g_n;
    const structural_first = layer * organic.substrate_count * organic.structural_fraction_count;
    for (context.organic_state.structural[structural_first..][0 .. organic.substrate_count * organic.structural_fraction_count]) |pool|
        total += pool.nitrogen_g_n;
    const cell = layer / context.microbial_state.layer_count;
    const local_layer = layer % context.microbial_state.layer_count;
    for (0..context.microbial_state.substrate_count) |substrate|
        for (0..context.microbial_state.population_count) |population| {
            const population_index = try context.microbial_state.populationIndex(cell, local_layer, substrate, population);
            total += context.microbial_state.nonstructural[population_index].nitrogen_g_n;
            total += context.microbial_state.structural[population_index * 2].nitrogen_g_n;
            total += context.microbial_state.structural[population_index * 2 + 1].nitrogen_g_n;
        };
    inline for (.{ gas.Species.nitrogen, gas.Species.nitrous_oxide, gas.Species.ammonia }) |species| {
        const index = try gas.massIndex(layer, species, context.gas_state.cell_count);
        total += context.gas_state.gaseous_mass_g[index];
        total += context.gas_state.dissolved_mass_g[index];
        total += context.gas_state.macropore_dissolved_mass_g[index];
        total += context.gas_state.band_dissolved_mass_g[index];
    }
    if (!std.math.isFinite(total)) return error.NonFiniteSoilNitrogenConservationCensus;
    return total;
}

/// Phosphorus owners that NITRO can change in one layer. Other phosphate
/// speciation/mineral carriers are unchanged by this state update and thus
/// cancel identically across this process-local census.
fn authoritativeLayerPhosphorus_g_p(context: ApplyContext, layer: usize) !f64 {
    const water_m3 = context.water_volume_m3[layer];
    // ISSUE-065 (eighteenth pass): must match `state_updateLayer`'s own
    // `phosphate_water_m3` substitution exactly, or this "before" census
    // (read at the top of `state_updateLayer`, before any owner changes)
    // would use a different carrier basis than the "after" census
    // (`projectedLayerPhosphorus_g_p`, which sums the already-substituted
    // `h2po4`/`hpo4` extensive mass directly) and trip
    // `requireProjectedClosure` on every hour a layer is dry, not just the
    // hours this fix actually changes behavior for.
    const phosphate_water_m3 = if (water_m3 > context.negligible_water_volume_m3)
        water_m3
    else
        context.chemistry_state.dry_reference_water_m3[layer];
    const p_mass = context.phosphorus_molar_mass_g_per_mol;
    const non_band = context.chemistry_state.non_band_phosphate[layer];
    const band = context.chemistry_state.band_phosphate[layer];
    const zone_fractions = zoneFractionsAt(context, layer);
    var total = p_mass * phosphate_water_m3 *
        (zone_fractions.phosphate_non_band *
            (non_band.dissolved_h2po4_mol_p_per_m3 + non_band.dissolved_hpo4_mol_p_per_m3) +
            zone_fractions.phosphate_band *
                (band.dissolved_h2po4_mol_p_per_m3 + band.dissolved_hpo4_mol_p_per_m3));
    const organic_first = layer * organic.substrate_count;
    for (context.organic_state.dissolved[organic_first..][0..organic.substrate_count]) |pool| total += pool.phosphorus_g_p;
    for (context.organic_state.adsorbed[organic_first..][0..organic.substrate_count]) |pool| total += pool.phosphorus_g_p;
    const residue_first = layer * organic.substrate_count * organic.residue_fraction_count;
    for (context.organic_state.residue[residue_first..][0 .. organic.substrate_count * organic.residue_fraction_count]) |pool| total += pool.phosphorus_g_p;
    const structural_first = layer * organic.substrate_count * organic.structural_fraction_count;
    for (context.organic_state.structural[structural_first..][0 .. organic.substrate_count * organic.structural_fraction_count]) |pool| total += pool.phosphorus_g_p;
    const cell = layer / context.microbial_state.layer_count;
    const local_layer = layer % context.microbial_state.layer_count;
    for (0..context.microbial_state.substrate_count) |substrate|
        for (0..context.microbial_state.population_count) |population| {
            const population_index = try context.microbial_state.populationIndex(cell, local_layer, substrate, population);
            total += context.microbial_state.nonstructural[population_index].phosphorus_g_p;
            total += context.microbial_state.structural[population_index * 2].phosphorus_g_p;
            total += context.microbial_state.structural[population_index * 2 + 1].phosphorus_g_p;
        };
    if (!std.math.isFinite(total)) return error.NonFiniteSoilPhosphorusConservationCensus;
    return total;
}

fn zoneFractionsAt(context: ApplyContext, layer: usize) zones.ZoneFractions {
    return if (context.zone_fractions_by_layer.len == 0) context.zone_fractions else context.zone_fractions_by_layer[layer];
}

const ProjectedDelta = struct {
    residual: f64,
    activity: f64,
    arithmetic_roundoff_allowance: f64,
};

const CompensatedChangeSum = struct {
    sum: f64 = 0,
    correction: f64 = 0,
    activity: f64 = 0,
    before_magnitude: f64 = 0,
    after_magnitude: f64 = 0,
    addend_count: usize = 0,

    fn add(self: *CompensatedChangeSum, after: f64, before: f64) !void {
        if (!std.math.isFinite(after) or !std.math.isFinite(before))
            return error.NonFiniteSoilCarbonConservationCensus;
        const change = after - before;
        const next = self.sum + change;
        if (@abs(self.sum) >= @abs(change))
            self.correction += (self.sum - next) + change
        else
            self.correction += (change - next) + self.sum;
        self.sum = next;
        self.activity += @abs(change);
        self.before_magnitude += @abs(before);
        self.after_magnitude += @abs(after);
        self.addend_count += 1;
        inline for (.{ self.sum, self.correction, self.activity, self.before_magnitude, self.after_magnitude }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteSoilCarbonConservationCensus;
    }

    fn finish(self: CompensatedChangeSum) !ProjectedDelta {
        const residual = self.sum + self.correction;
        // The activity term bounds subtraction and compensated reduction. The
        // separate representation term covers the unavoidable rounding when
        // each candidate is constructed around an already-represented owner
        // (for example, a small decomposition debit from a large SOM pool).
        // This is an IEEE-754 floor, not a physical tolerance: it scales with
        // only the owners changed by NITRO and remains tight enough to reject a
        // 1e-11 g omission in the measured 338.5 g production case.
        const count_epsilon: f64 = @as(f64, @floatFromInt(self.addend_count)) * std.math.floatEps(f64);
        if (count_epsilon >= 1) return error.NonFiniteSoilCarbonConservationCensus;
        const standing_scale = std.math.nextAfter(
            f64,
            @max(self.before_magnitude, self.after_magnitude) / (1 - count_epsilon),
            std.math.inf(f64),
        );
        const reduction_allowance = 16 * std.math.floatEps(f64) *
            @max(std.math.floatMin(f64), self.activity);
        // A projected owner can be updated repeatedly in source order (the
        // two humus classes receive up to 84 microbial-component credits in
        // the production dimensions). 128 rounded owner constructions is the
        // explicit worst-case operation budget, not an empirical tolerance.
        const candidate_construction_rounding_ops: f64 = 128;
        const representation_allowance = candidate_construction_rounding_ops * std.math.floatEps(f64) *
            @max(std.math.floatMin(f64), standing_scale);
        const allowance = reduction_allowance + representation_allowance;
        if (!std.math.isFinite(residual) or !std.math.isFinite(allowance))
            return error.NonFiniteSoilCarbonConservationCensus;
        return .{
            .residual = residual,
            .activity = self.activity,
            .arithmetic_roundoff_allowance = allowance,
        };
    }
};

fn projectedLayerCarbonDelta_g_c(
    context: ApplyContext,
    layer: usize,
    dissolved_after: [organic.substrate_count]organic.ElementPool,
    dissolved_acetate_after_g_c: [organic.substrate_count]f64,
    adsorbed_after: [organic.substrate_count]organic.ElementPool,
    adsorbed_acetate_after_g_c: [organic.substrate_count]f64,
    residue_after: [organic.substrate_count * organic.residue_fraction_count]organic.ElementPool,
    structural_after: [organic.substrate_count * organic.structural_fraction_count]organic.ElementPool,
    humus_after: [2]organic.ElementPool,
    next_nonstructural: []const microbial.ElementalPool,
    next_structural: []const microbial.ElementalPool,
    carbon_dioxide_after_g_c: f64,
    methane_after_g_c: f64,
) !ProjectedDelta {
    var total: CompensatedChangeSum = .{};
    const mobile_first = layer * organic.substrate_count;
    for (0..organic.substrate_count) |index| {
        try total.add(dissolved_after[index].carbon_g_c, @max(0, context.organic_state.dissolved[mobile_first + index].carbon_g_c));
        try total.add(dissolved_acetate_after_g_c[index], context.organic_state.dissolved_acetate_carbon_g_c[mobile_first + index]);
        try total.add(adsorbed_after[index].carbon_g_c, @max(0, context.organic_state.adsorbed[mobile_first + index].carbon_g_c));
        try total.add(adsorbed_acetate_after_g_c[index], context.organic_state.adsorbed_acetate_carbon_g_c[mobile_first + index]);
    }
    const residue_first = layer * residue_after.len;
    for (residue_after, 0..) |candidate, index|
        try total.add(candidate.carbon_g_c, @max(0, context.organic_state.residue[residue_first + index].carbon_g_c));
    const structural_first = layer * structural_after.len;
    const humus_local = 4 * organic.structural_fraction_count;
    for (structural_after, 0..) |candidate, index| {
        const accepted = if (index == humus_local)
            humus_after[0]
        else if (index == humus_local + 1)
            humus_after[1]
        else
            candidate;
        try total.add(accepted.carbon_g_c, @max(0, context.organic_state.structural[structural_first + index].carbon_g_c));
    }

    const cell = layer / context.microbial_state.layer_count;
    const local_layer = layer % context.microbial_state.layer_count;
    for (0..context.microbial_state.substrate_count) |substrate|
        for (0..context.microbial_state.population_count) |population| {
            const population_index = try context.microbial_state.populationIndex(cell, local_layer, substrate, population);
            const local_unit = substrate * context.microbial_state.population_count + population;
            if (microbial.nitroPopulationEnabled(substrate, population)) {
                try total.add(next_nonstructural[local_unit].carbon_g_c, context.microbial_state.nonstructural[population_index].carbon_g_c);
                try total.add(next_structural[local_unit * 2].carbon_g_c, context.microbial_state.structural[population_index * 2].carbon_g_c);
                try total.add(next_structural[local_unit * 2 + 1].carbon_g_c, context.microbial_state.structural[population_index * 2 + 1].carbon_g_c);
            }
        };
    const carbon_dioxide_index = try gas.massIndex(layer, .carbon_dioxide, context.gas_state.cell_count);
    try total.add(carbon_dioxide_after_g_c, context.gas_state.dissolved_mass_g[carbon_dioxide_index]);
    const methane_index = try gas.massIndex(layer, .methane, context.gas_state.cell_count);
    if (context.methane) |methane_result|
        try total.add(methane_result.gaseous_methane_after_g_c[layer], context.gas_state.gaseous_mass_g[methane_index]);
    try total.add(methane_after_g_c, context.gas_state.dissolved_mass_g[methane_index]);
    return total.finish();
}

fn projectedLayerNitrogen_g_n(
    context: ApplyContext,
    layer: usize,
    ammonium_after_g_n: [2]f64,
    nitrate_after_g_n: [2]f64,
    nitrite_after_g_n: [2]f64,
    nitrous_oxide_after_g_n: f64,
    dinitrogen_after_g_n: f64,
    dissolved_after: [organic.substrate_count]organic.ElementPool,
    adsorbed_after: [organic.substrate_count]organic.ElementPool,
    residue_after: [organic.substrate_count * organic.residue_fraction_count]organic.ElementPool,
    structural_after: [organic.substrate_count * organic.structural_fraction_count]organic.ElementPool,
    humus_after: [2]organic.ElementPool,
    next_nonstructural: []const microbial.ElementalPool,
    next_structural: []const microbial.ElementalPool,
) !f64 {
    var total = ammonium_after_g_n[0] + ammonium_after_g_n[1] +
        nitrate_after_g_n[0] + nitrate_after_g_n[1] +
        nitrite_after_g_n[0] + nitrite_after_g_n[1];
    for (dissolved_after) |pool| total += pool.nitrogen_g_n;
    for (adsorbed_after) |pool| total += pool.nitrogen_g_n;
    for (residue_after) |pool| total += pool.nitrogen_g_n;
    const humus_local = 4 * organic.structural_fraction_count;
    for (structural_after, 0..) |candidate, index| {
        const accepted = if (index == humus_local)
            humus_after[0]
        else if (index == humus_local + 1)
            humus_after[1]
        else
            candidate;
        total += accepted.nitrogen_g_n;
    }
    const cell = layer / context.microbial_state.layer_count;
    const local_layer = layer % context.microbial_state.layer_count;
    for (0..context.microbial_state.substrate_count) |substrate|
        for (0..context.microbial_state.population_count) |population| {
            const population_index = try context.microbial_state.populationIndex(cell, local_layer, substrate, population);
            const local_unit = substrate * context.microbial_state.population_count + population;
            if (microbial.nitroPopulationEnabled(substrate, population)) {
                total += next_nonstructural[local_unit].nitrogen_g_n;
                total += next_structural[local_unit * 2].nitrogen_g_n;
                total += next_structural[local_unit * 2 + 1].nitrogen_g_n;
            } else {
                total += context.microbial_state.nonstructural[population_index].nitrogen_g_n;
                total += context.microbial_state.structural[population_index * 2].nitrogen_g_n;
                total += context.microbial_state.structural[population_index * 2 + 1].nitrogen_g_n;
            }
        };
    inline for (.{ gas.Species.nitrogen, gas.Species.nitrous_oxide, gas.Species.ammonia }) |species| {
        const index = try gas.massIndex(layer, species, context.gas_state.cell_count);
        total += context.gas_state.gaseous_mass_g[index];
        total += switch (species) {
            .nitrogen => dinitrogen_after_g_n,
            .nitrous_oxide => nitrous_oxide_after_g_n,
            .ammonia => context.gas_state.dissolved_mass_g[index],
            else => unreachable,
        };
        total += context.gas_state.macropore_dissolved_mass_g[index];
        total += context.gas_state.band_dissolved_mass_g[index];
    }
    if (!std.math.isFinite(total)) return error.NonFiniteSoilNitrogenConservationCensus;
    return total;
}

fn projectedLayerPhosphorus_g_p(
    context: ApplyContext,
    layer: usize,
    h2po4_after_g_p: [2]f64,
    hpo4_after_g_p: [2]f64,
    dissolved_after: [organic.substrate_count]organic.ElementPool,
    adsorbed_after: [organic.substrate_count]organic.ElementPool,
    residue_after: [organic.substrate_count * organic.residue_fraction_count]organic.ElementPool,
    structural_after: [organic.substrate_count * organic.structural_fraction_count]organic.ElementPool,
    humus_after: [2]organic.ElementPool,
    next_nonstructural: []const microbial.ElementalPool,
    next_structural: []const microbial.ElementalPool,
) !f64 {
    var total = h2po4_after_g_p[0] + h2po4_after_g_p[1] +
        hpo4_after_g_p[0] + hpo4_after_g_p[1];
    for (dissolved_after) |pool| total += pool.phosphorus_g_p;
    for (adsorbed_after) |pool| total += pool.phosphorus_g_p;
    for (residue_after) |pool| total += pool.phosphorus_g_p;
    const humus_local = 4 * organic.structural_fraction_count;
    for (structural_after, 0..) |candidate, index| {
        const accepted = if (index == humus_local)
            humus_after[0]
        else if (index == humus_local + 1)
            humus_after[1]
        else
            candidate;
        total += accepted.phosphorus_g_p;
    }
    const cell = layer / context.microbial_state.layer_count;
    const local_layer = layer % context.microbial_state.layer_count;
    for (0..context.microbial_state.substrate_count) |substrate|
        for (0..context.microbial_state.population_count) |population| {
            const population_index = try context.microbial_state.populationIndex(cell, local_layer, substrate, population);
            const local_unit = substrate * context.microbial_state.population_count + population;
            if (microbial.nitroPopulationEnabled(substrate, population)) {
                total += next_nonstructural[local_unit].phosphorus_g_p;
                total += next_structural[local_unit * 2].phosphorus_g_p;
                total += next_structural[local_unit * 2 + 1].phosphorus_g_p;
            } else {
                total += context.microbial_state.nonstructural[population_index].phosphorus_g_p;
                total += context.microbial_state.structural[population_index * 2].phosphorus_g_p;
                total += context.microbial_state.structural[population_index * 2 + 1].phosphorus_g_p;
            }
        };
    if (!std.math.isFinite(total)) return error.NonFiniteSoilPhosphorusConservationCensus;
    return total;
}

fn requireProjectedClosure(before: f64, after: f64, layer: usize, comptime failure: anyerror) !void {
    const scale = @max(@abs(before), @abs(after));
    const tolerances: scoped_conservation.Tolerance = .{
        .absolute = 64 * std.math.floatEps(f64) * @max(std.math.floatMin(f64), scale),
        .relative = 32 * std.math.floatEps(f64),
    };
    const closure = scoped_conservation.evaluate(.{
        .storage_before = before,
        .storage_after = after,
    }, tolerances) catch return failure;
    if (!closure.accepted) {
        if (!builtin.is_test) std.log.err("soil element projected closure failed: element_error={s} layer={d} before={e} after={e} residual={e} absolute_closure={e} normalized_relative={e} acceptance_limit={e} effective_limit={e} activity_scale={e} standing_scale={e}", .{ @errorName(failure), layer, before, after, after - before, closure.absolute, closure.normalized_relative, closure.acceptance_limit, closure.effective_acceptance_limit, closure.normalization_scale, scale });
        return failure;
    }
}

fn requireProjectedDeltaClosure(delta: ProjectedDelta, nonnegative_roundoff_adjustment: f64, layer: usize, comptime failure: anyerror) !void {
    if (!std.math.isFinite(delta.residual) or
        !std.math.isFinite(delta.activity) or delta.activity < 0 or
        !std.math.isFinite(delta.arithmetic_roundoff_allowance) or delta.arithmetic_roundoff_allowance < 0 or
        !std.math.isFinite(nonnegative_roundoff_adjustment) or nonnegative_roundoff_adjustment < 0)
        return failure;
    // Mapping a tiny negative owner to zero is a real one-sided storage
    // increment.  It must be closed by its paired carrier, not absorbed into
    // the changed-owner summation allowance.
    if (nonnegative_roundoff_adjustment != 0 or
        @abs(delta.residual) > delta.arithmetic_roundoff_allowance)
    {
        const normalized = if (delta.activity > 0)
            @abs(delta.residual) / delta.activity
        else
            @as(f64, 0);
        if (!builtin.is_test) std.log.err("soil carbon changed-owner closure failed: layer={d} residual_g_c={e} absolute_closure_g_c={e} normalized_relative={e} activity_g_c={e} arithmetic_roundoff_allowance_g_c={e} nonnegative_roundoff_adjustment_g_c={e}", .{ layer, delta.residual, @abs(delta.residual), normalized, delta.activity, delta.arithmetic_roundoff_allowance, nonnegative_roundoff_adjustment });
        return failure;
    }
}

test "compensated changed-owner census removes standing-stock cancellation" {
    var sum: CompensatedChangeSum = .{};
    try sum.add(1.0e16 + 2, 1.0e16);
    try sum.add(1, 2);
    try sum.add(0, 1);
    const delta = try sum.finish();
    try std.testing.expectEqual(@as(f64, 0), delta.residual);
    try std.testing.expectEqual(@as(f64, 4), delta.activity);
    try std.testing.expect(delta.arithmetic_roundoff_allowance > 0);

    var represented_transfer: CompensatedChangeSum = .{};
    try represented_transfer.add(338.5487366244 - 1.0e-12, 338.5487366244);
    try represented_transfer.add(1.0e-12, 0);
    const represented_delta = try represented_transfer.finish();
    try std.testing.expect(@abs(represented_delta.residual) > 0);
    try requireProjectedDeltaClosure(
        represented_delta,
        0,
        0,
        error.InvalidSoilCarbonConservationClosure,
    );

    for ([2]f64{ -1.0, 1.0 }) |sign| {
        var leaking: CompensatedChangeSum = .{};
        try leaking.add(338.5487366244 + sign * 1.0e-11, 338.5487366244);
        const leaking_delta = try leaking.finish();
        try std.testing.expect(leaking_delta.arithmetic_roundoff_allowance < @abs(leaking_delta.residual));
        try std.testing.expectError(
            error.InvalidSoilCarbonConservationClosure,
            requireProjectedDeltaClosure(
                leaking_delta,
                0,
                0,
                error.InvalidSoilCarbonConservationClosure,
            ),
        );
    }

    try std.testing.expectError(
        error.InvalidSoilCarbonConservationClosure,
        requireProjectedDeltaClosure(
            delta,
            std.math.floatEps(f64),
            0,
            error.InvalidSoilCarbonConservationClosure,
        ),
    );
}

/// NITRO RDOSL includes lignin (fraction 4 in one-based Fortran) from the
/// first three residue complexes only.
fn ligninDecompositionForAcidity(
    decomposition: *const organic_decomposition.State,
    layer: usize,
) f64 {
    const lignin_fraction: usize = 3;
    var total_g_c: f64 = 0;
    for (0..3) |substrate| {
        const index = (layer * organic.substrate_count + substrate) *
            organic.structural_fraction_count + lignin_fraction;
        total_g_c += decomposition.structural_decomposition[index].carbon_g_c;
    }
    return total_g_c;
}

fn normalizeNonnegativeRoundoff(value: f64, operation_scale: f64) f64 {
    if (!std.math.isFinite(value) or value >= 0 or
        !std.math.isFinite(operation_scale) or operation_scale < 0)
        return value;
    const cancellation_tolerance =
        64.0 * std.math.floatEps(f64) *
        @max(std.math.floatMin(f64), operation_scale);
    return if (value >= -cancellation_tolerance) 0 else value;
}

/// Discards a conservation-census difference that is smaller than the f64
/// representation floor of the census being differenced. Such a difference
/// carries no information about mass: it is the accumulation's own rounding,
/// and both its magnitude and its sign depend on summation order.
///
/// This is deliberately two-sided, unlike `normalizeNonnegativeRoundoff`. A
/// one-sided filter would let positive noise accumulate into a carrier while
/// rejecting negative noise, which is precisely the systematic drift that lane
/// A9 observed in `Arctic Tundra IQ` (every accepted closure negative).
///
/// The floor is derived from the operands via `floatEps`, so it is a property
/// of f64 and of the census magnitude, not a configured tolerance. It cannot be
/// widened to absorb a real imbalance: a discrepancy one part in `1e15` of a
/// `1e10 g N` census is `1e-5 g N`, still far below any physical process this
/// kernel represents, while anything physically meaningful is orders of
/// magnitude above the floor and passes through unchanged.
fn normalizeCensusRoundoff(difference: f64, census_scale: f64) f64 {
    if (!std.math.isFinite(difference) or !std.math.isFinite(census_scale) or census_scale < 0)
        return difference;
    const representation_floor =
        64.0 * std.math.floatEps(f64) * @max(std.math.floatMin(f64), census_scale);
    return if (@abs(difference) <= representation_floor) 0 else difference;
}

test "census roundoff filter discards representation noise symmetrically" {
    // The measured Arctic Tundra IQ layer-5 case, and its mirror image.
    const census: f64 = 1.3391410615279026e10;
    try std.testing.expectEqual(@as(f64, 0), normalizeCensusRoundoff(-3.814697265625e-6, census));
    try std.testing.expectEqual(@as(f64, 0), normalizeCensusRoundoff(3.814697265625e-6, census));
    // A physically meaningful imbalance at the same census scale survives. One
    // gram is 12 orders of magnitude above the floor here.
    try std.testing.expectEqual(@as(f64, 1), normalizeCensusRoundoff(1, census));
    try std.testing.expectEqual(@as(f64, -1), normalizeCensusRoundoff(-1, census));
    // The floor scales with the census and never exceeds it.
    try std.testing.expect(normalizeCensusRoundoff(1e-9, 1) == 1e-9);
    // Non-finite input is passed through so the caller's own guard reports it.
    try std.testing.expect(std.math.isNan(normalizeCensusRoundoff(std.math.nan(f64), census)));
}

fn applyMicrobialExchange(pool_g_n: *f64, exchange_g_n: f64) !void {
    if (!std.math.isFinite(exchange_g_n)) return error.InvalidSoilNitrogenFlux;
    pool_g_n.* = try nonnegativeCandidate(
        pool_g_n.* - exchange_g_n,
        @abs(pool_g_n.*) + @abs(exchange_g_n),
        error.InsufficientSoilMineralNitrogen,
    );
}

/// MICROBIAL-STATE-UPDATE-DEAD-001: `microbial.state.state_update`'s own
/// `validateDecomposition` enforces `decomposed == recycled + humified +
/// microbial_residue` on every basal/senescence decomposition split, but
/// that atomic commit has zero production callers -- this file hand-inlines
/// the same math without an equivalent check. Mirrors the same stoichiometry
/// assertion at the point where the real production commit consumes
/// `microbial_turnover.basal`/`.senescence`, so a future regression in
/// either the split itself or this file's hand-duplicated consumption of it
/// is caught here instead of silently drifting.
fn validateMicrobialDecompositionBalance(decomposition: anytype) !void {
    inline for (@typeInfo(@TypeOf(decomposition.decomposed)).@"struct".fields) |field| {
        const decomposed = @field(decomposition.decomposed, field.name);
        const products = @field(decomposition.recycled, field.name) +
            @field(decomposition.humified, field.name) +
            @field(decomposition.microbial_residue, field.name);
        const closure = scoped_conservation.evaluateTransfer(
            decomposed,
            products,
            1,
            .{
                .absolute = 128 * std.math.floatEps(f64) * @max(decomposed, products),
                .relative = 32 * std.math.floatEps(f64),
            },
        ) catch return error.InvalidMicrobialDecompositionBalance;
        if (!closure.accepted) return error.InvalidMicrobialDecompositionBalance;
    }
}

fn addPool(destination: *organic.ElementPool, source: organic.ElementPool) void {
    destination.carbon_g_c += source.carbon_g_c;
    destination.nitrogen_g_n += source.nitrogen_g_n;
    destination.phosphorus_g_p += source.phosphorus_g_p;
}

fn subtractPool(destination: *organic.ElementPool, source: organic.ElementPool) void {
    destination.carbon_g_c -= source.carbon_g_c;
    destination.nitrogen_g_n -= source.nitrogen_g_n;
    destination.phosphorus_g_p -= source.phosphorus_g_p;
}

fn applyZone(ammonium: *f64, nitrate: *f64, nitrite: *f64, ammonia_oxidation: f64, nitrite_oxidation: f64, nitrate_reduction: f64, heterotrophic_nitrite_reduction: f64, autotrophic_nitrite_reduction: f64, autotrophic_ammonium_oxidation: f64, chemo_nitrite_reduction: f64) !void {
    inline for (.{ ammonia_oxidation, nitrite_oxidation, nitrate_reduction, heterotrophic_nitrite_reduction, autotrophic_nitrite_reduction, autotrophic_ammonium_oxidation, chemo_nitrite_reduction }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilNitrogenFlux;
    const nitrite_available = nitrite.* + ammonia_oxidation + autotrophic_ammonium_oxidation + nitrate_reduction;
    const nitrite_consumed = nitrite_oxidation + heterotrophic_nitrite_reduction + autotrophic_nitrite_reduction + chemo_nitrite_reduction;
    ammonium.* = try nonnegativeCandidate(
        ammonium.* - ammonia_oxidation - autotrophic_ammonium_oxidation,
        @abs(ammonium.*) + @abs(ammonia_oxidation) + @abs(autotrophic_ammonium_oxidation),
        error.InsufficientSoilMineralNitrogen,
    );
    nitrate.* = try nonnegativeCandidate(
        nitrate.* + nitrite_oxidation - nitrate_reduction,
        @abs(nitrate.*) + @abs(nitrite_oxidation) + @abs(nitrate_reduction),
        error.InsufficientSoilMineralNitrogen,
    );
    nitrite.* = try nonnegativeCandidate(
        nitrite_available - nitrite_consumed,
        @abs(nitrite_available) + @abs(nitrite_consumed),
        error.InsufficientSoilNitrite,
    );
}

fn concentrationFromMass(mass_g_n: f64, water_m3: f64, fraction: f64, molar_mass: f64) !f64 {
    if (!std.math.isFinite(mass_g_n) or mass_g_n < 0) return error.InvalidSoilNitrogenStateUpdate;
    const volume = water_m3 * fraction;
    if (volume <= 0) {
        // nitro.f derives CNH4/CNO3 only inside VOLW > ZEROS2. Extensive mineral-N
        // remains in the transport owner; the intensive coordinate is undefined.
        return 0;
    }
    return mass_g_n / (volume * molar_mass);
}

fn nonnegativeCandidate(value: f64, operation_scale: f64, comptime failure: anyerror) !f64 {
    if (!std.math.isFinite(value) or !std.math.isFinite(operation_scale) or operation_scale < 0)
        return failure;
    const normalized = normalizeNonnegativeRoundoff(value, operation_scale);
    if (normalized < 0) {
        if (!builtin.is_test) std.log.err(
            "soil nitrogen state_update rejected negative candidate: error={s} value={e} operation_scale={e} roundoff_limit={e}",
            .{
                @errorName(failure),
                value,
                operation_scale,
                64.0 * std.math.floatEps(f64) *
                    @max(std.math.floatMin(f64), operation_scale),
            },
        );
        return failure;
    }
    return normalized;
}

test "nonnegative state update normalizes only operation-scale roundoff" {
    const scale: f64 = 10;
    const epsilon = std.math.floatEps(f64);
    try std.testing.expectEqual(
        @as(f64, 0),
        try nonnegativeCandidate(
            -32 * epsilon * scale,
            scale,
            error.InvalidTestCandidate,
        ),
    );
    try std.testing.expectEqual(
        @as(f64, 2),
        try nonnegativeCandidate(2, scale, error.InvalidTestCandidate),
    );
    try std.testing.expectError(
        error.InvalidTestCandidate,
        nonnegativeCandidate(
            -128 * epsilon * scale,
            scale,
            error.InvalidTestCandidate,
        ),
    );
}

fn validatePublishedAmmonium(
    layer: usize,
    water_mol_per_m3: f64,
    concentration_mol_per_m3: [2]f64,
    final_mass_g_n: [2]f64,
    microbial_exchange_g_n: [2]f64,
    oxidation_g_n: [2]f64,
    water_volume_m3: f64,
    zone_fraction: [2]f64,
) !void {
    if (!std.math.isFinite(water_mol_per_m3) or water_mol_per_m3 <= 0)
        return error.InvalidSoilNitrogenWaterMolarity;
    for (0..2) |zone| {
        if (concentration_mol_per_m3[zone] <= water_mol_per_m3) continue;
        std.log.warn(
            "soil nitrogen state_update exceeds water molarity: layer={d} zone={s} ammonium_mol_per_m3={e} water_mol_per_m3={e} final_mass_g_n={e} microbial_exchange_g_n={e} oxidation_g_n={e} water_volume_m3={e} zone_fraction={e}",
            .{
                layer,
                if (zone == 0) "non_band" else "band",
                concentration_mol_per_m3[zone],
                water_mol_per_m3,
                final_mass_g_n[zone],
                microbial_exchange_g_n[zone],
                oxidation_g_n[zone],
                water_volume_m3,
                zone_fraction[zone],
            },
        );
        return error.SoilNitrogenStateUpdateExceedsWaterMolarity;
    }
}

fn boundedExchange(proposed: f64, dissolved_available: f64, sorbed_available: f64) f64 {
    if (proposed >= 0) return @min(proposed, @max(0, dissolved_available));
    return @max(proposed, -@max(0, sorbed_available));
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const layers = context.reactive_nitrogen.layer_count;
    if (context.hourly_signed_heterotrophic_respiration_g_c) |ledger| if (ledger.len != layers) return error.HeterotrophicRespirationLedgerDimensionMismatch;
    if (context.hourly_carbon_dioxide_production_g_c) |ledger| if (ledger.len != layers) return error.CarbonDioxideProductionLedgerDimensionMismatch;
    // Reduced unit-test contexts may omit the source-only K=5 complex. Any
    // runtime state that includes it must bind its authoritative index even
    // when optional methane science is disabled.
    if (context.microbial_state.substrate_count > organic.substrate_count and context.autotrophic_substrate_index >= context.microbial_state.substrate_count)
        return error.SoilNitrogenStateUpdateDimensionMismatch;
    if (context.methane) |methane_result| {
        if (methane_result.layer_count != layers or
            context.hydrogenotroph_population_index >= context.microbial_state.population_count or
            context.methanotroph_population_index >= context.microbial_state.population_count or
            context.hydrogenotroph_population_index == context.methanotroph_population_index)
            return error.SoilNitrogenStateUpdateDimensionMismatch;
    }
    const units = try std.math.mul(usize, layers, context.reactive_nitrogen.process_unit_count_per_layer);
    if (context.soil_layer_capacity == 0 or layers % context.soil_layer_capacity != 0 or context.salinity_enabled_by_cell.len != layers / context.soil_layer_capacity or range.first > range.end or range.end > layers or context.phosphorus_history.layer_count != layers or context.microbial_turnover.layer_count != layers or context.litter_colonization.layer_count != layers or context.organic_sorption.layer_count != layers or context.organic_decomposition.layer_count != layers or (context.organic_priming != null and context.organic_priming.?.exchange.cell_count != layers) or (context.respiration_products != null and context.respiration_products.?.layer_count != layers) or context.chemistry_state.cell_count != layers or context.gas_state.cell_count != layers or context.organic_state.layer_count != layers or context.microbial_state.cell_count * context.microbial_state.layer_count != layers or context.flux_workspace.layer_count != layers or context.flux_workspace.process_unit_count_per_layer != context.reactive_nitrogen.process_unit_count_per_layer or context.flux_workspace.process_unit_count_per_layer != context.phosphorus_history.process_unit_count_per_layer or context.flux_workspace.process_unit_count_per_layer != context.microbial_turnover.process_unit_count_per_layer or context.flux_workspace.process_unit_count_per_layer != context.microbial_state.substrate_count * context.microbial_state.population_count or context.water_volume_m3.len != layers or context.oxygen_satisfaction_fraction.len != units or context.redox_satisfaction_fraction.len != units or context.humus_partition_by_layer.len != layers or (context.zone_fractions_by_layer.len != 0 and context.zone_fractions_by_layer.len != layers)) return error.SoilNitrogenStateUpdateDimensionMismatch;
    if (!std.math.isFinite(context.nitrogen_molar_mass_g_per_mol) or context.nitrogen_molar_mass_g_per_mol <= 0 or !std.math.isFinite(context.phosphorus_molar_mass_g_per_mol) or context.phosphorus_molar_mass_g_per_mol <= 0 or !std.math.isFinite(context.negligible_hydrogen_mol) or context.negligible_hydrogen_mol < 0 or !std.math.isFinite(context.negligible_carbon_g_c) or context.negligible_carbon_g_c < 0 or !std.math.isFinite(context.fraction_tolerance) or context.fraction_tolerance < 0 or !std.math.isFinite(context.timestep_h) or context.timestep_h <= 0) {
        std.log.warn("invalid nitrogen state_update units: nitrogen_g_per_mol={e} phosphorus_g_per_mol={e} negligible_hydrogen_mol={e} negligible_carbon_g_c={e} fraction_tolerance={e}", .{ context.nitrogen_molar_mass_g_per_mol, context.phosphorus_molar_mass_g_per_mol, context.negligible_hydrogen_mol, context.negligible_carbon_g_c, context.fraction_tolerance });
        return error.InvalidSoilNitrogenStateUpdate;
    }
    const fractions_to_validate = if (context.zone_fractions_by_layer.len == 0) @as([]const zones.ZoneFractions, &.{context.zone_fractions}) else context.zone_fractions_by_layer;
    for (fractions_to_validate) |fractions| inline for (.{ fractions.ammonium_non_band, fractions.ammonium_band, fractions.nitrate_non_band, fractions.nitrate_band, fractions.phosphate_non_band, fractions.phosphate_band }) |fraction| if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidSoilNitrogenZoneFraction;
    for (context.humus_partition_by_layer, 0..) |partition, layer| {
        if (!std.math.isFinite(partition[0]) or !std.math.isFinite(partition[1]) or partition[0] < 0 or partition[1] < 0 or @abs(partition[0] + partition[1] - 1) > context.fraction_tolerance) {
            std.log.warn("invalid humus partition: layer={d} active_fraction={e} passive_fraction={e} sum={e} tolerance={e}", .{ layer, partition[0], partition[1], partition[0] + partition[1], context.fraction_tolerance });
            return error.InvalidSoilNitrogenStateUpdate;
        }
    }
    for (context.oxygen_satisfaction_fraction, context.redox_satisfaction_fraction) |oxygen, redox| if (!std.math.isFinite(oxygen) or oxygen < 0 or oxygen > 1 or !std.math.isFinite(redox) or redox < 0 or redox > 1) return error.InvalidSoilNitrogenSatisfactionFraction;
}

test "day 12 ammonium is rejected at the nitrogen state_update boundary" {
    try std.testing.expectError(
        error.SoilNitrogenStateUpdateExceedsWaterMolarity,
        validatePublishedAmmonium(
            0,
            5.5555906256719943e4,
            .{ 1.3535910109655228e6, 0 },
            .{ 1.8950274153517318e7, 0 },
            .{ -1.8950274153517318e7, 0 },
            .{ 0, 0 },
            1,
            .{ 1, 0 },
        ),
    );
    try validatePublishedAmmonium(
        0,
        5.5555906256719943e4,
        .{ 6.232257392983944e-1, 0 },
        .{ 8.725160350177521, 0 },
        .{ 0, 0 },
        .{ 0, 0 },
        1,
        .{ 1, 0 },
    );
}

test "layer nitrogen state_update conserves zones gases and DON atomically" {
    var reactive_state = try reactive.State.init(std.testing.allocator, 1, 1);
    defer reactive_state.deinit();
    var phosphorus_state = try phosphorus.State.init(std.testing.allocator, 1, 1);
    defer phosphorus_state.deinit();
    var turnover_state = try turnover.State.init(std.testing.allocator, 1, 1);
    defer turnover_state.deinit();
    var colonization_state = try colonization.State.init(std.testing.allocator, 1);
    defer colonization_state.deinit();
    var sorption_state = try organic_sorption.State.init(std.testing.allocator, 1);
    defer sorption_state.deinit();
    var decomposition_state = try organic_decomposition.State.init(std.testing.allocator, 1);
    defer decomposition_state.deinit();
    turnover_state.basal[0] = .{
        .decomposed = .{ .carbon_g_c = 0.05, .nitrogen_g_n = 0.005, .phosphorus_g_p = 0.001 },
        .recycled = .{ .carbon_g_c = 0.02, .nitrogen_g_n = 0.002, .phosphorus_g_p = 0.0004 },
        .humified = .{ .carbon_g_c = 0.01, .nitrogen_g_n = 0.001, .phosphorus_g_p = 0.0002 },
        .microbial_residue = .{ .carbon_g_c = 0.02, .nitrogen_g_n = 0.002, .phosphorus_g_p = 0.0004 },
    };
    reactive_state.non_band_nitrite_g_n[0] = 0.2;
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    chemistry_state.aqueous[0].ammonium_non_band = 1;
    chemistry_state.aqueous[0].nitrate_non_band = 1;
    chemistry_state.aqueous[0].hydrogen = 1;
    chemistry_state.water_mol_per_m3[0] = 100;
    chemistry_state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 1;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.nitrogen)] = 0.1;
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer microbial_state.deinit();
    microbial_state.nonstructural[0] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.02 };
    organic_state.residue[0].carbon_g_c = 1;
    organic_state.dissolved[0].carbon_g_c = 1;
    organic_state.dissolved_acetate_carbon_g_c[0] = 0.5;
    var workspace = try fluxes.State.init(std.testing.allocator, 1, 1);
    defer workspace.deinit();
    workspace.non_band_ammonia_oxidation_potential_g_n[0] = 0.1;
    workspace.non_band_nitrite_oxidation_potential_g_n[0] = 0.05;
    workspace.non_band_nitrate_reduction_potential_g_n[0] = 0.03;
    workspace.non_band_nitrate_reduction_capacity_g_n[0] = 0.06;
    workspace.non_band_heterotrophic_nitrite_reduction_potential_g_n[0] = 0.04;
    workspace.non_band_nitrite_reduction_capacity_g_n[0] = 0.07;
    workspace.nitrous_oxide_reduction_capacity_g_n[0] = 0.08;
    workspace.chemodenitrification_non_band_nitrite_reduction_g_n[0] = 0.02;
    workspace.chemodenitrification_nitrous_oxide_production_g_n[0] = 0.01;
    workspace.chemodenitrification_dissolved_organic_nitrogen_production_g_n[0] = 0.01;
    workspace.doc_uptake_g_c[0] = 0.24;
    workspace.acetate_uptake_g_c[0] = 0.1;
    workspace.total_carbon_uptake_g_c[0] = 0.34;
    workspace.actual_aerobic_respiration_g_c[0] = 0.1;
    workspace.nonstructural_carbon_gain_g_c[0] = 0.2;
    workspace.nitrogen_fixation_respiration_g_c[0] = 0.04;
    workspace.fixed_dinitrogen_g_n[0] = 0.02;
    workspace.non_band_microbial_ammonium_exchange_g_n[0] = 0.02;
    workspace.non_band_microbial_ammonium_capacity_g_n[0] = 0.025;
    workspace.non_band_microbial_h2po4_exchange_g_p[0] = 0.02;
    workspace.non_band_microbial_h2po4_capacity_g_p[0] = 0.025;
    workspace.aerobic_oxygen_demand_g_o[0] = 0.12;
    workspace.labile_assimilation_g_c[0] = 0.11;
    workspace.labile_assimilation_g_n[0] = 0.011;
    workspace.labile_assimilation_g_p[0] = 0.0022;
    workspace.resistant_assimilation_g_c[0] = 0.09;
    workspace.resistant_assimilation_g_n[0] = 0.009;
    workspace.resistant_assimilation_g_p[0] = 0.0018;
    const before = 14.0 + 14.0 + 0.2 + 0.1 + 0.1;
    const phosphorus_before = 31.02;
    var context: ApplyContext = .{ .reactive_nitrogen = &reactive_state, .phosphorus_history = &phosphorus_state, .chemistry_state = &chemistry_state, .gas_state = &gas_state, .organic_state = &organic_state, .microbial_state = &microbial_state, .flux_workspace = &workspace, .microbial_turnover = &turnover_state, .litter_colonization = &colonization_state, .organic_sorption = &sorption_state, .organic_decomposition = &decomposition_state, .humus_partition_by_layer = &.{.{ 0.5, 0.5 }}, .water_volume_m3 = &.{1}, .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 }, .oxygen_satisfaction_fraction = &.{1}, .redox_satisfaction_fraction = &.{1}, .nitrogen_molar_mass_g_per_mol = 14, .phosphorus_molar_mass_g_per_mol = 31, .negligible_hydrogen_mol = 1e-12, .negligible_carbon_g_c = 1e-12, .fraction_tolerance = 1e-12, .salinity_enabled_by_cell = &.{true}, .soil_layer_capacity = 1 };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const after = chemistry_state.aqueous[0].ammonium_non_band * 14 + chemistry_state.aqueous[0].nitrate_non_band * 14 + reactive_state.non_band_nitrite_g_n[0] + gas_state.dissolved_mass_g[@intFromEnum(gas.Species.nitrous_oxide)] + gas_state.dissolved_mass_g[@intFromEnum(gas.Species.nitrogen)] + organic_state.dissolved[0].nitrogen_g_n + microbial_state.nonstructural[0].nitrogen_g_n + microbial_state.structural[0].nitrogen_g_n + microbial_state.structural[1].nitrogen_g_n + organic_state.residue[0].nitrogen_g_n + organic_state.structural[20].nitrogen_g_n + organic_state.structural[21].nitrogen_g_n;
    try std.testing.expectApproxEqAbs(before, after, 1e-12);
    const phosphorus_after = chemistry_state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 * 31 + microbial_state.nonstructural[0].phosphorus_g_p + microbial_state.structural[0].phosphorus_g_p + microbial_state.structural[1].phosphorus_g_p + organic_state.residue[0].phosphorus_g_p + organic_state.structural[20].phosphorus_g_p + organic_state.structural[21].phosphorus_g_p;
    try std.testing.expectApproxEqAbs(phosphorus_before, phosphorus_after, 1e-12);
    try std.testing.expectEqual(@as(f64, 0.06), reactive_state.previous_total_non_band_nitrate_demand_g_n[0]);
    try std.testing.expectEqual(@as(f64, 0.07), reactive_state.previous_total_non_band_nitrite_demand_g_n[0]);
    try std.testing.expectEqual(@as(f64, 0.08), reactive_state.previous_total_nitrous_oxide_demand_g_n[0]);
    try std.testing.expectEqual(@as(f64, 0.12), reactive_state.previous_aerobic_oxygen_demand_g_o[0]);
    try std.testing.expectEqual(@as(f64, 0.12), reactive_state.previous_total_aerobic_oxygen_demand_g_o[0]);
    try std.testing.expectEqual(@as(f64, 0.025), reactive_state.previous_non_band_microbial_ammonium_capacity_g_n[0]);
    try std.testing.expectEqual(@as(f64, 0.025), phosphorus_state.previous_non_band_h2po4_capacity_g_p[0]);
    try std.testing.expectEqual(@as(f64, 0.025), phosphorus_state.previous_total_non_band_h2po4_demand_g_p[0]);
    const carbon_after = organic_state.dissolved[0].carbon_g_c + organic_state.dissolved_acetate_carbon_g_c[0] + microbial_state.nonstructural[0].carbon_g_c + microbial_state.structural[0].carbon_g_c + microbial_state.structural[1].carbon_g_c + organic_state.residue[0].carbon_g_c + organic_state.structural[20].carbon_g_c + organic_state.structural[21].carbon_g_c + gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)];
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), carbon_after, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.06), microbial_state.structural[0].carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.09), microbial_state.structural[1].carbon_g_c, 1e-15);
    const expected_hydrogen_mol = 1 + 0.1429 * (0.1 - 0.03) - 0.0714 * 0.04;
    try std.testing.expectApproxEqAbs(expected_hydrogen_mol, chemistry_state.aqueous[0].hydrogen, 1e-15);
}

test "ISSUE-065: a dry layer's phosphate carrier round-trip reproduces the wet layer's result exactly, via dry_reference_water_m3" {
    // Regression for the eighteenth-pass finding: `state_updateLayer` used to
    // read AND write phosphate's dissolved concentration using the raw live
    // carrier (`context.water_volume_m3[layer]`) with no substitution, so a
    // layer with live water at/below the negligible floor had its phosphate
    // concentration silently collapsed toward zero (mass computed against a
    // zero carrier, then divided back by the same zero carrier via
    // `concentrationFromMass`'s `volume<=0 => return 0` guard) instead of
    // being preserved via `dry_reference_water_m3`, the mechanism this
    // codebase already uses everywhere else (`exportCarrierM3`,
    // `soil_chemistry_water_carrier_rebase.rebaseLayer`) to keep a dry
    // layer's true extensive amount recoverable.
    //
    // This test runs the SAME phosphate inputs (concentration=1,
    // fraction=1, p_mass=31, no microbial exchange flux) through two calls:
    // one with `water_volume_m3=1` (live, wet), one with
    // `water_volume_m3=0` and `dry_reference_water_m3=1` (dry, but
    // remembering the same value the wet case used live). If the
    // substitution is correct, both must publish the identical final
    // concentration -- not the dry case collapsing to zero.
    const wet = try runSinglePhosphateLayer(1, 0);
    const dry = try runSinglePhosphateLayer(0, 1);
    try std.testing.expectEqual(wet, dry);
    try std.testing.expect(dry != 0);
}

fn runSinglePhosphateLayer(live_water_m3: f64, dry_reference_water_m3: f64) !f64 {
    var reactive_state = try reactive.State.init(std.testing.allocator, 1, 1);
    defer reactive_state.deinit();
    var phosphorus_state = try phosphorus.State.init(std.testing.allocator, 1, 1);
    defer phosphorus_state.deinit();
    var turnover_state = try turnover.State.init(std.testing.allocator, 1, 1);
    defer turnover_state.deinit();
    var colonization_state = try colonization.State.init(std.testing.allocator, 1);
    defer colonization_state.deinit();
    var sorption_state = try organic_sorption.State.init(std.testing.allocator, 1);
    defer sorption_state.deinit();
    var decomposition_state = try organic_decomposition.State.init(std.testing.allocator, 1);
    defer decomposition_state.deinit();
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    chemistry_state.water_mol_per_m3[0] = 100;
    chemistry_state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 1;
    chemistry_state.dry_reference_water_m3[0] = dry_reference_water_m3;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer microbial_state.deinit();
    var workspace = try fluxes.State.init(std.testing.allocator, 1, 1);
    defer workspace.deinit();
    var context: ApplyContext = .{
        .reactive_nitrogen = &reactive_state,
        .phosphorus_history = &phosphorus_state,
        .chemistry_state = &chemistry_state,
        .gas_state = &gas_state,
        .organic_state = &organic_state,
        .microbial_state = &microbial_state,
        .flux_workspace = &workspace,
        .microbial_turnover = &turnover_state,
        .litter_colonization = &colonization_state,
        .organic_sorption = &sorption_state,
        .organic_decomposition = &decomposition_state,
        .humus_partition_by_layer = &.{.{ 0.5, 0.5 }},
        .water_volume_m3 = &.{live_water_m3},
        .negligible_water_volume_m3 = 1e-9,
        .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 },
        .oxygen_satisfaction_fraction = &.{1},
        .redox_satisfaction_fraction = &.{1},
        .nitrogen_molar_mass_g_per_mol = 14,
        .phosphorus_molar_mass_g_per_mol = 31,
        .negligible_hydrogen_mol = 1e-12,
        .negligible_carbon_g_c = 1e-12,
        .fraction_tolerance = 1e-12,
        .salinity_enabled_by_cell = &.{false},
        .soil_layer_capacity = 1,
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    return chemistry_state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3;
}

test "ISSUE-065: a dry layer's ammonium/nitrate carrier round-trip reproduces the wet layer's result exactly, via dry_reference_water_m3" {
    // Sibling regression to the phosphate case above: `state_updateLayer`'s
    // ammonium/nitrate mass<->concentration round trip had the identical
    // raw-live-carrier defect, mistakenly left alone on the theory that
    // `mineral_nitrogen_transport.publishMatrix` (which already substitutes
    // `dry_reference_water_m3` correctly) was the sole authoritative writer
    // of `chemistry.aqueous[cell].ammonium_non_band`/`nitrate_non_band`. It
    // is not: this function writes the same fields first, in the same hour,
    // so a live-water zero here silently destroys the extensive mineral-N
    // mass before `mineral_nitrogen_transport` ever sees it.
    const wet = try runSingleAmmoniumNitrateLayer(1, 0);
    const dry = try runSingleAmmoniumNitrateLayer(0, 1);
    try std.testing.expectEqual(wet.ammonium_non_band, dry.ammonium_non_band);
    try std.testing.expectEqual(wet.nitrate_non_band, dry.nitrate_non_band);
    try std.testing.expect(dry.ammonium_non_band != 0);
    try std.testing.expect(dry.nitrate_non_band != 0);
}

const AmmoniumNitrateResult = struct { ammonium_non_band: f64, nitrate_non_band: f64 };

fn runSingleAmmoniumNitrateLayer(live_water_m3: f64, dry_reference_water_m3: f64) !AmmoniumNitrateResult {
    var reactive_state = try reactive.State.init(std.testing.allocator, 1, 1);
    defer reactive_state.deinit();
    var phosphorus_state = try phosphorus.State.init(std.testing.allocator, 1, 1);
    defer phosphorus_state.deinit();
    var turnover_state = try turnover.State.init(std.testing.allocator, 1, 1);
    defer turnover_state.deinit();
    var colonization_state = try colonization.State.init(std.testing.allocator, 1);
    defer colonization_state.deinit();
    var sorption_state = try organic_sorption.State.init(std.testing.allocator, 1);
    defer sorption_state.deinit();
    var decomposition_state = try organic_decomposition.State.init(std.testing.allocator, 1);
    defer decomposition_state.deinit();
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    chemistry_state.water_mol_per_m3[0] = 100;
    chemistry_state.aqueous[0].ammonium_non_band = 1;
    chemistry_state.aqueous[0].nitrate_non_band = 1;
    chemistry_state.dry_reference_water_m3[0] = dry_reference_water_m3;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer microbial_state.deinit();
    var workspace = try fluxes.State.init(std.testing.allocator, 1, 1);
    defer workspace.deinit();
    var context: ApplyContext = .{
        .reactive_nitrogen = &reactive_state,
        .phosphorus_history = &phosphorus_state,
        .chemistry_state = &chemistry_state,
        .gas_state = &gas_state,
        .organic_state = &organic_state,
        .microbial_state = &microbial_state,
        .flux_workspace = &workspace,
        .microbial_turnover = &turnover_state,
        .litter_colonization = &colonization_state,
        .organic_sorption = &sorption_state,
        .organic_decomposition = &decomposition_state,
        .humus_partition_by_layer = &.{.{ 0.5, 0.5 }},
        .water_volume_m3 = &.{live_water_m3},
        .negligible_water_volume_m3 = 1e-9,
        .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 },
        .oxygen_satisfaction_fraction = &.{1},
        .redox_satisfaction_fraction = &.{1},
        .nitrogen_molar_mass_g_per_mol = 14,
        .phosphorus_molar_mass_g_per_mol = 31,
        .negligible_hydrogen_mol = 1e-12,
        .negligible_carbon_g_c = 1e-12,
        .fraction_tolerance = 1e-12,
        .salinity_enabled_by_cell = &.{false},
        .soil_layer_capacity = 1,
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    return .{
        .ammonium_non_band = chemistry_state.aqueous[0].ammonium_non_band,
        .nitrate_non_band = chemistry_state.aqueous[0].nitrate_non_band,
    };
}

test "methane carbon routes to authoritative K5 methanogen and methanotroph owners" {
    const substrate_count = 6;
    const population_count = 5;
    const units = substrate_count * population_count;
    var reactive_state = try reactive.State.init(std.testing.allocator, 1, units);
    defer reactive_state.deinit();
    var phosphorus_state = try phosphorus.State.init(std.testing.allocator, 1, units);
    defer phosphorus_state.deinit();
    var turnover_state = try turnover.State.init(std.testing.allocator, 1, units);
    defer turnover_state.deinit();
    var colonization_state = try colonization.State.init(std.testing.allocator, 1);
    defer colonization_state.deinit();
    var sorption_state = try organic_sorption.State.init(std.testing.allocator, 1);
    defer sorption_state.deinit();
    var decomposition_state = try organic_decomposition.State.init(std.testing.allocator, 1);
    defer decomposition_state.deinit();
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    chemistry_state.water_mol_per_m3[0] = 100;
    chemistry_state.aqueous[0].hydrogen = 1;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] = 2;
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.methane)] = 1;
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.hydrogen)] = 0.2;
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.oxygen)] = 2;
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, substrate_count, population_count);
    defer microbial_state.deinit();
    const autotrophic_substrate = 5;
    const methanotroph_population = 2;
    const hydrogenotroph_population = 4;
    const methanotroph_unit = autotrophic_substrate * population_count + methanotroph_population;
    const hydrogenotroph_unit = autotrophic_substrate * population_count + hydrogenotroph_population;
    microbial_state.nonstructural[methanotroph_unit].carbon_g_c = 1;
    microbial_state.nonstructural[hydrogenotroph_unit].carbon_g_c = 1;
    var workspace = try fluxes.State.init(std.testing.allocator, 1, units);
    defer workspace.deinit();
    const ammonia_oxidizer_unit = autotrophic_substrate * population_count;
    workspace.denitrification_respiration_g_c[ammonia_oxidizer_unit] = 0.1;
    var methane_state = try methane_step.State.init(std.testing.allocator, 1);
    defer methane_state.deinit();
    methane_state.aqueous_methane_after_g_c[0] = 0.6;
    methane_state.gaseous_methane_after_g_c[0] = 0;
    methane_state.hydrogenotrophic_methane_g_c[0] = 0.1;
    methane_state.hydrogenotrophic_carbon_dioxide_uptake_g_c[0] = 0.2;
    methane_state.hydrogenotrophic_nonstructural_carbon_gain_g_c[0] = 0.1;
    methane_state.hydrogen_consumption_g_h[0] = 0.1 / 1.5;
    methane_state.methane_oxidation_combustion_g_c[0] = 0.2;
    methane_state.methane_oxidation_respiration_g_c[0] = 0.05;
    methane_state.methanotroph_methane_uptake_g_c[0] = 0.3;
    methane_state.methanotroph_nonstructural_carbon_gain_g_c[0] = 0.25;
    methane_state.oxygen_demand_g_o[0] = 5.333 * 0.2 + 2.667 * 0.05;
    const satisfaction = [_]f64{1} ** units;
    var hourly_carbon_dioxide_production = [1]f64{0};
    var context: ApplyContext = .{
        .reactive_nitrogen = &reactive_state,
        .phosphorus_history = &phosphorus_state,
        .chemistry_state = &chemistry_state,
        .gas_state = &gas_state,
        .organic_state = &organic_state,
        .microbial_state = &microbial_state,
        .flux_workspace = &workspace,
        .microbial_turnover = &turnover_state,
        .litter_colonization = &colonization_state,
        .organic_sorption = &sorption_state,
        .organic_decomposition = &decomposition_state,
        .methane = &methane_state,
        .autotrophic_substrate_index = autotrophic_substrate,
        .hydrogenotroph_population_index = hydrogenotroph_population,
        .methanotroph_population_index = methanotroph_population,
        .humus_partition_by_layer = &.{.{ 0.5, 0.5 }},
        .water_volume_m3 = &.{1},
        .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 },
        .oxygen_satisfaction_fraction = &satisfaction,
        .redox_satisfaction_fraction = &satisfaction,
        .nitrogen_molar_mass_g_per_mol = 14,
        .phosphorus_molar_mass_g_per_mol = 31,
        .negligible_hydrogen_mol = 1e-12,
        .negligible_carbon_g_c = 1e-12,
        .fraction_tolerance = 1e-12,
        .salinity_enabled_by_cell = &.{false},
        .soil_layer_capacity = 1,
        .hourly_carbon_dioxide_production_g_c = &hourly_carbon_dioxide_production,
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.1), microbial_state.nonstructural[hydrogenotroph_unit].carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), microbial_state.nonstructural[methanotroph_unit].carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.05), gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)], 1e-15);
    // Gross source diagnostics retain RGOMD, while the gas owner waits for
    // autotrophic_carbon_step to commit the paired CGOMD-RGOMD net uptake.
    try std.testing.expectApproxEqAbs(@as(f64, 0.35), hourly_carbon_dioxide_production[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), gas_state.dissolved_mass_g[@intFromEnum(gas.Species.methane)], 1e-15);
    const after = gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] +
        gas_state.dissolved_mass_g[@intFromEnum(gas.Species.methane)] +
        microbial_state.nonstructural[hydrogenotroph_unit].carbon_g_c +
        microbial_state.nonstructural[methanotroph_unit].carbon_g_c;
    try std.testing.expectApproxEqAbs(@as(f64, 5), after, 1e-14);

    // K=5 is the nitrifier-autotroph complex independently of optional
    // methane science. Its RGOMD remains gross diagnostic activity here but
    // is committed only with its paired CGOMD by autotrophic_carbon_step.
    const co2_before_methane_disabled = gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)];
    context.methane = null;
    hourly_carbon_dioxide_production[0] = 0;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(co2_before_methane_disabled, gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)]);
    try std.testing.expectEqual(@as(f64, 0.1), hourly_carbon_dioxide_production[0]);
}

// HUMUS-DEPTH-PARTITION-001: the sole existing test exercising
// `humus_partition_by_layer` above passes a single-layer array, so it cannot
// distinguish the fixed per-layer indexing from the old bug (collapsing
// every layer to the top layer's shared split), since there is only one
// layer to collapse to. This test drives two soil layers, in one cell,
// through the same identical inputs except for a distinct
// `humus_partition_by_layer` value each, and asserts each layer's humus
// sub-pools receive its OWN split -- catching a future regression that
// re-derives `humus_partition_by_layer` from only layer 0 of each cell.
test "layer nitrogen state_update routes each layer's own humus partition, not the top layer's" {
    var reactive_state = try reactive.State.init(std.testing.allocator, 2, 1);
    defer reactive_state.deinit();
    var phosphorus_state = try phosphorus.State.init(std.testing.allocator, 2, 1);
    defer phosphorus_state.deinit();
    var turnover_state = try turnover.State.init(std.testing.allocator, 2, 1);
    defer turnover_state.deinit();
    var colonization_state = try colonization.State.init(std.testing.allocator, 2);
    defer colonization_state.deinit();
    var sorption_state = try organic_sorption.State.init(std.testing.allocator, 2);
    defer sorption_state.deinit();
    var decomposition_state = try organic_decomposition.State.init(std.testing.allocator, 2);
    defer decomposition_state.deinit();
    turnover_state.basal[0] = .{
        .decomposed = .{ .carbon_g_c = 0.05, .nitrogen_g_n = 0.005, .phosphorus_g_p = 0.001 },
        .recycled = .{ .carbon_g_c = 0.02, .nitrogen_g_n = 0.002, .phosphorus_g_p = 0.0004 },
        .humified = .{ .carbon_g_c = 0.01, .nitrogen_g_n = 0.001, .phosphorus_g_p = 0.0002 },
        .microbial_residue = .{ .carbon_g_c = 0.02, .nitrogen_g_n = 0.002, .phosphorus_g_p = 0.0004 },
    }; // layer 0, unit 0, component 0
    turnover_state.basal[2] = .{
        .decomposed = .{ .carbon_g_c = 0.05, .nitrogen_g_n = 0.005, .phosphorus_g_p = 0.001 },
        .recycled = .{ .carbon_g_c = 0.02, .nitrogen_g_n = 0.002, .phosphorus_g_p = 0.0004 },
        .humified = .{ .carbon_g_c = 0.01, .nitrogen_g_n = 0.001, .phosphorus_g_p = 0.0002 },
        .microbial_residue = .{ .carbon_g_c = 0.02, .nitrogen_g_n = 0.002, .phosphorus_g_p = 0.0004 },
    }; // layer 1, unit 1, component 0
    reactive_state.non_band_nitrite_g_n[0] = 0.2;
    reactive_state.non_band_nitrite_g_n[1] = 0.2;
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 2);
    defer chemistry_state.deinit();
    for (0..2) |layer| {
        chemistry_state.aqueous[layer].ammonium_non_band = 1;
        chemistry_state.aqueous[layer].nitrate_non_band = 1;
        chemistry_state.aqueous[layer].hydrogen = 1;
        chemistry_state.water_mol_per_m3[layer] = 100;
        chemistry_state.non_band_phosphate[layer].dissolved_h2po4_mol_p_per_m3 = 1;
    }
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[try gas.massIndex(0, .nitrogen, 2)] = 0.1;
    gas_state.dissolved_mass_g[try gas.massIndex(1, .nitrogen, 2)] = 0.1;
    var organic_state = try organic.State.init(std.testing.allocator, 2);
    defer organic_state.deinit();
    organic_state.residue[0].carbon_g_c = 1;
    organic_state.residue[1 * organic.substrate_count * organic.residue_fraction_count].carbon_g_c = 1;
    organic_state.dissolved[0].carbon_g_c = 1;
    organic_state.dissolved[1 * organic.substrate_count].carbon_g_c = 1;
    organic_state.dissolved_acetate_carbon_g_c[0] = 0.5;
    organic_state.dissolved_acetate_carbon_g_c[1 * organic.substrate_count] = 0.5;
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 2, 1, 1);
    defer microbial_state.deinit();
    microbial_state.nonstructural[0] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.02 };
    microbial_state.nonstructural[1] = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.02 };
    var workspace = try fluxes.State.init(std.testing.allocator, 2, 1);
    defer workspace.deinit();
    for (0..2) |unit| {
        workspace.non_band_ammonia_oxidation_potential_g_n[unit] = 0.1;
        workspace.non_band_nitrite_oxidation_potential_g_n[unit] = 0.05;
        workspace.non_band_nitrate_reduction_potential_g_n[unit] = 0.03;
        workspace.non_band_nitrate_reduction_capacity_g_n[unit] = 0.06;
        workspace.non_band_heterotrophic_nitrite_reduction_potential_g_n[unit] = 0.04;
        workspace.non_band_nitrite_reduction_capacity_g_n[unit] = 0.07;
        workspace.nitrous_oxide_reduction_capacity_g_n[unit] = 0.08;
        workspace.chemodenitrification_non_band_nitrite_reduction_g_n[unit] = 0.02;
        workspace.chemodenitrification_nitrous_oxide_production_g_n[unit] = 0.01;
        workspace.chemodenitrification_dissolved_organic_nitrogen_production_g_n[unit] = 0.01;
        workspace.doc_uptake_g_c[unit] = 0.24;
        workspace.acetate_uptake_g_c[unit] = 0.1;
        workspace.total_carbon_uptake_g_c[unit] = 0.34;
        workspace.actual_aerobic_respiration_g_c[unit] = 0.1;
        workspace.nonstructural_carbon_gain_g_c[unit] = 0.2;
        workspace.nitrogen_fixation_respiration_g_c[unit] = 0.04;
        workspace.fixed_dinitrogen_g_n[unit] = 0.02;
        workspace.non_band_microbial_ammonium_exchange_g_n[unit] = 0.02;
        workspace.non_band_microbial_ammonium_capacity_g_n[unit] = 0.025;
        workspace.non_band_microbial_h2po4_exchange_g_p[unit] = 0.02;
        workspace.non_band_microbial_h2po4_capacity_g_p[unit] = 0.025;
        workspace.aerobic_oxygen_demand_g_o[unit] = 0.12;
        workspace.labile_assimilation_g_c[unit] = 0.11;
        workspace.labile_assimilation_g_n[unit] = 0.011;
        workspace.labile_assimilation_g_p[unit] = 0.0022;
        workspace.resistant_assimilation_g_c[unit] = 0.09;
        workspace.resistant_assimilation_g_n[unit] = 0.009;
        workspace.resistant_assimilation_g_p[unit] = 0.0018;
    }
    // Deliberately distinct per-layer splits: layer 0 skews toward the
    // less-resistant (fast-turnover) pool, layer 1 toward the more-resistant
    // (slow-turnover) one -- the opposite of what re-deriving from layer 0
    // alone would produce for layer 1.
    const layer0_partition = [2]f64{ 0.9, 0.1 };
    const layer1_partition = [2]f64{ 0.2, 0.8 };
    var context: ApplyContext = .{ .reactive_nitrogen = &reactive_state, .phosphorus_history = &phosphorus_state, .chemistry_state = &chemistry_state, .gas_state = &gas_state, .organic_state = &organic_state, .microbial_state = &microbial_state, .flux_workspace = &workspace, .microbial_turnover = &turnover_state, .litter_colonization = &colonization_state, .organic_sorption = &sorption_state, .organic_decomposition = &decomposition_state, .humus_partition_by_layer = &.{ layer0_partition, layer1_partition }, .water_volume_m3 = &.{ 1, 1 }, .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 }, .oxygen_satisfaction_fraction = &.{ 1, 1 }, .redox_satisfaction_fraction = &.{ 1, 1 }, .nitrogen_molar_mass_g_per_mol = 14, .phosphorus_molar_mass_g_per_mol = 31, .negligible_hydrogen_mol = 1e-12, .negligible_carbon_g_c = 1e-12, .fraction_tolerance = 1e-12, .salinity_enabled_by_cell = &.{ true, true }, .soil_layer_capacity = 1 };
    try applyTile(&context, .{ .first = 0, .end = 2 });
    // Layer 0's humus sub-pools (structural[20]/[21]) must reflect layer 0's
    // own 0.9/0.1 split of its 0.01 g C humified product.
    try std.testing.expectApproxEqAbs(@as(f64, 0.01 * layer0_partition[0]), organic_state.structural[20].carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01 * layer0_partition[1]), organic_state.structural[21].carbon_g_c, 1e-15);
    // Layer 1's humus sub-pools (structural[45]/[46]) must reflect layer 1's
    // own 0.2/0.8 split, not layer 0's -- this is exactly what the old
    // per-cell collapse bug would have applied instead.
    const layer1_structural_first = 1 * organic.substrate_count * organic.structural_fraction_count;
    const layer1_humus_local = 4 * organic.structural_fraction_count;
    try std.testing.expectApproxEqAbs(@as(f64, 0.01 * layer1_partition[0]), organic_state.structural[layer1_structural_first + layer1_humus_local].carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01 * layer1_partition[1]), organic_state.structural[layer1_structural_first + layer1_humus_local + 1].carbon_g_c, 1e-15);
    // Explicitly confirm the two layers diverge -- if a regression re-derives
    // `humus_partition_by_layer` from only layer 0, this equality would hold
    // and the test above would already have failed, but this makes the
    // intent unambiguous.
    try std.testing.expect(organic_state.structural[20].carbon_g_c != organic_state.structural[layer1_structural_first + layer1_humus_local].carbon_g_c);
}

test "failed layer nitrogen state_update publishes no partial state" {
    var reactive_state = try reactive.State.init(std.testing.allocator, 1, 1);
    defer reactive_state.deinit();
    var phosphorus_state = try phosphorus.State.init(std.testing.allocator, 1, 1);
    defer phosphorus_state.deinit();
    var turnover_state = try turnover.State.init(std.testing.allocator, 1, 1);
    defer turnover_state.deinit();
    var colonization_state = try colonization.State.init(std.testing.allocator, 1);
    defer colonization_state.deinit();
    var sorption_state = try organic_sorption.State.init(std.testing.allocator, 1);
    defer sorption_state.deinit();
    var decomposition_state = try organic_decomposition.State.init(std.testing.allocator, 1);
    defer decomposition_state.deinit();
    reactive_state.non_band_nitrite_g_n[0] = 0.2;
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    chemistry_state.water_mol_per_m3[0] = 55_500;
    chemistry_state.aqueous[0].ammonium_non_band = 1;
    chemistry_state.aqueous[0].nitrate_non_band = 1;
    chemistry_state.aqueous[0].hydrogen = 1;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    var microbial_state = try microbial.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer microbial_state.deinit();
    var workspace = try fluxes.State.init(std.testing.allocator, 1, 1);
    defer workspace.deinit();
    workspace.non_band_ammonia_oxidation_potential_g_n[0] = 15;
    const chemistry_before = chemistry_state.aqueous[0];
    const nitrite_before = reactive_state.non_band_nitrite_g_n[0];
    const gas_before = gas_state.dissolved_mass_g[0..gas.species_count].*;
    const dissolved_before = organic_state.dissolved[0];
    var signed_ledger = [_]f64{12};
    var co2_ledger = [_]f64{34};
    var context: ApplyContext = .{ .reactive_nitrogen = &reactive_state, .phosphorus_history = &phosphorus_state, .chemistry_state = &chemistry_state, .gas_state = &gas_state, .organic_state = &organic_state, .microbial_state = &microbial_state, .flux_workspace = &workspace, .microbial_turnover = &turnover_state, .litter_colonization = &colonization_state, .organic_sorption = &sorption_state, .organic_decomposition = &decomposition_state, .humus_partition_by_layer = &.{.{ 0.5, 0.5 }}, .water_volume_m3 = &.{1}, .zone_fractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 }, .oxygen_satisfaction_fraction = &.{1}, .redox_satisfaction_fraction = &.{1}, .nitrogen_molar_mass_g_per_mol = 14, .phosphorus_molar_mass_g_per_mol = 31, .negligible_hydrogen_mol = 1e-12, .negligible_carbon_g_c = 1e-12, .fraction_tolerance = 1e-12, .salinity_enabled_by_cell = &.{true}, .soil_layer_capacity = 1, .hourly_signed_heterotrophic_respiration_g_c = &signed_ledger, .hourly_carbon_dioxide_production_g_c = &co2_ledger };
    try std.testing.expectError(error.InsufficientSoilMineralNitrogen, applyTile(&context, .{ .first = 0, .end = 1 }));
    try std.testing.expectEqualDeep(chemistry_before, chemistry_state.aqueous[0]);
    try std.testing.expectEqual(nitrite_before, reactive_state.non_band_nitrite_g_n[0]);
    try std.testing.expectEqualSlices(f64, &gas_before, gas_state.dissolved_mass_g[0..gas.species_count]);
    try std.testing.expectEqualDeep(dissolved_before, organic_state.dissolved[0]);
    try std.testing.expectEqual(@as(f64, 12), signed_ledger[0]);
    try std.testing.expectEqual(@as(f64, 34), co2_ledger[0]);

    // A late projected P imbalance must fail before any C/N/P owner or
    // accounting ledger is published.
    workspace.non_band_ammonia_oxidation_potential_g_n[0] = 0;
    decomposition_state.dissolved_structural_products[0].phosphorus_g_p = 1.0e-3;
    const phosphate_before = chemistry_state.non_band_phosphate[0];
    try std.testing.expectError(error.InvalidSoilPhosphorusConservationClosure, applyTile(&context, .{ .first = 0, .end = 1 }));
    try std.testing.expectEqualDeep(chemistry_before, chemistry_state.aqueous[0]);
    try std.testing.expectEqualDeep(phosphate_before, chemistry_state.non_band_phosphate[0]);
    try std.testing.expectEqual(nitrite_before, reactive_state.non_band_nitrite_g_n[0]);
    try std.testing.expectEqualSlices(f64, &gas_before, gas_state.dissolved_mass_g[0..gas.species_count]);
    try std.testing.expectEqualDeep(dissolved_before, organic_state.dissolved[0]);
    try std.testing.expectEqual(@as(f64, 12), signed_ledger[0]);
    try std.testing.expectEqual(@as(f64, 34), co2_ledger[0]);
}
