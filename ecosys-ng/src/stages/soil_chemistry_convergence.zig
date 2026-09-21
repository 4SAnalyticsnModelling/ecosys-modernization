//! Hourly soil chemistry convergence loop (NITRO/SOLUTE equivalent).
//!
//! Extracted verbatim from `ecosys_ng.zig` so the entry point holds only
//! `main`. Declaration bodies are unchanged.

const std = @import("std");
const ecosys = @import("ecosys_ng");
const diagnostics = @import("diagnostics.zig");

/// Owns the short-lived slices used by one hourly chemistry invocation.
///
/// Keeping the individual allocations preserves their types, sizes, failure
/// points, and lifetimes.  The type-erased stack only centralizes the cleanup
/// edges which otherwise get duplicated at every `try` in the large chemistry
/// control-flow graph.  Entries are always released in defer-equivalent LIFO
/// order.
const ScratchAllocations = struct {
    const capacity = 64;

    const Entry = struct {
        pointer: *anyopaque,
        len: usize,
        free_fn: *const fn (std.mem.Allocator, *anyopaque, usize) void,
    };

    allocator: std.mem.Allocator,
    entries: [capacity]Entry = undefined,
    count: usize = 0,

    fn init(allocator: std.mem.Allocator) ScratchAllocations {
        return .{ .allocator = allocator };
    }

    fn mark(self: *const ScratchAllocations) usize {
        return self.count;
    }

    fn alloc(self: *ScratchAllocations, comptime T: type, len: usize) ![]T {
        const values = try self.allocator.alloc(T, len);
        self.register(T, values);
        return values;
    }

    fn dupe(self: *ScratchAllocations, comptime T: type, values: []const T) ![]T {
        const duplicate = try self.allocator.dupe(T, values);
        self.register(T, duplicate);
        return duplicate;
    }

    fn register(self: *ScratchAllocations, comptime T: type, values: []T) void {
        std.debug.assert(self.count < capacity);
        self.entries[self.count] = .{
            .pointer = @ptrCast(values.ptr),
            .len = values.len,
            .free_fn = &struct {
                fn free(
                    allocator: std.mem.Allocator,
                    erased_pointer: *anyopaque,
                    len: usize,
                ) void {
                    const pointer: [*]T = @ptrCast(@alignCast(erased_pointer));
                    allocator.free(pointer[0..len]);
                }
            }.free,
        };
        self.count += 1;
    }

    noinline fn releaseTo(self: *ScratchAllocations, mark_count: usize) void {
        std.debug.assert(mark_count <= self.count);
        while (self.count > mark_count) {
            self.count -= 1;
            const entry = self.entries[self.count];
            entry.free_fn(self.allocator, entry.pointer, entry.len);
        }
    }

    noinline fn deinit(self: *ScratchAllocations) void {
        self.releaseTo(0);
        self.* = undefined;
    }
};

/// Validates the physical carriers shared by the production chemistry paths.
/// Zero density is the translated SOLUTE open-water branch: reactions use
/// source soil/water volume while immobile per-Mg amounts stay pending.
fn hourlyChemistrySoilMass(
    bulk_volume_m3: f64,
    bulk_density_megagrams_per_m3: f64,
    water_volume_m3: f64,
) !f64 {
    if (!std.math.isFinite(bulk_volume_m3) or bulk_volume_m3 <= 0 or
        !std.math.isFinite(bulk_density_megagrams_per_m3) or bulk_density_megagrams_per_m3 < 0 or
        !std.math.isFinite(water_volume_m3) or water_volume_m3 < 0)
        return error.InvalidHourlySoilChemistryGeometry;
    const soil_mass_megagrams = bulk_volume_m3 * bulk_density_megagrams_per_m3;
    if (!std.math.isFinite(soil_mass_megagrams))
        return error.InvalidHourlySoilChemistryGeometry;
    return soil_mass_megagrams;
}

/// `solute.f:610`-style `ZEROS2` floor (issue-073 Finding C), for
/// `updateFertilizerBandGeometry`'s own nitrate/phosphate/precipitate mass
/// pools -- distinct call site from, but the same floor shape as,
/// `solveHourlyReactionLayer`'s own already-established gate earlier in this
/// same file. Below the floor, substitutes the persistent
/// `dry_reference_water_m3` carrier instead of scaling every pool by a
/// vanishing live-water multiplier, keeping this function's pools
/// consistent with what the reaction solver assumed for the same layer this
/// same hour.
fn fertilizerBandGeometryCarrierM3(water_volume_m3: f64, floor_m3: f64, dry_reference_water_m3: f64) f64 {
    return if (water_volume_m3 > floor_m3) water_volume_m3 else dry_reference_water_m3;
}

test "issue-073 Finding C: fertilizerBandGeometryCarrierM3 substitutes the dry reference below the floor, passes the live carrier through above it" {
    const floor_m3: f64 = 1e-6;
    const dry_reference_m3: f64 = 0.4;
    // Below the floor (tiny-but-nonzero): substitutes the retained carrier.
    try std.testing.expectEqual(dry_reference_m3, fertilizerBandGeometryCarrierM3(floor_m3 / 2, floor_m3, dry_reference_m3));
    // Exactly zero: still substitutes (matches legacy's ZEROS2 gate, not an
    // exact-zero-only guard).
    try std.testing.expectEqual(dry_reference_m3, fertilizerBandGeometryCarrierM3(0, floor_m3, dry_reference_m3));
    // Above the floor: the live carrier passes through unchanged.
    try std.testing.expectEqual(@as(f64, 1), fertilizerBandGeometryCarrierM3(1, floor_m3, dry_reference_m3));

    // OLD/NEW comparison at a tiny-but-nonzero water_volume_m3: the OLD
    // (unguarded) multiplication would have manufactured a >99.99% fake
    // mass loss relative to the correct (dry-reference) mass.
    const concentration_mol_per_m3: f64 = 10;
    const old_mol = concentration_mol_per_m3 * (floor_m3 / 2);
    const new_mol = concentration_mol_per_m3 * fertilizerBandGeometryCarrierM3(floor_m3 / 2, floor_m3, dry_reference_m3);
    try std.testing.expect(old_mol < new_mol * 1e-4);
}

pub noinline fn convergeHourlySoilChemistry(
    context: anytype,
    fertilizer_band_hour: ecosys.fertilizer_band_phase_coordinator.HourToken,
    failure_report: ?ecosys.solute_failure_reporter.Request,
) !void {
    var scratch_allocations = ScratchAllocations.init(context.allocator);
    defer scratch_allocations.deinit();

    if (context.microbial_thermal_adaptation.cell_count != context.grid.cell_count)
        return error.MicrobialThermalAdaptationDimensionMismatch;
    for (context.microbial_thermal_adaptation.thermal_adaptation_offset_k) |offset_k|
        if (!std.math.isFinite(offset_k))
            return error.NonFiniteMicrobialThermalAdaptationOffset;
    if (context.executed_weather_hours.* < 24) {
        var diagnostic_root_n_g: f64 = 0;
        if (@hasField(@TypeOf(context), "root_soil_ammonia_exchange_state_update_state")) {
            const state_update = context.root_soil_ammonia_exchange_state_update_state;
            for (state_update.non_band_exchange_g_n_per_h_by_layer, state_update.band_exchange_g_n_per_h_by_layer) |non_band, band|
                diagnostic_root_n_g += @max(0, non_band) + @max(0, band);
        }
        if (@hasField(@TypeOf(context), "root_nutrient_uptake_state_update_state")) {
            const state_update = context.root_nutrient_uptake_state_update_state;
            diagnostic_root_n_g += diagnosticPositiveRootNitrogenUptake_g(state_update);
        }
        std.log.debug("root nitrogen exchange already published to canonical owners: g_n={e}", .{diagnostic_root_n_g});
    }
    // REDIST may leave an immobile amount without a concentration carrier
    // after a layer is fully ponded downward. Reconstitute those explicit
    // extensive owners before any fertilizer or reaction operation reads the
    // cell. Zero-water owners remain pending and conserved.
    for (0..context.grid.cell_count) |cell| {
        const first_layer = cell * context.grid.soil_layer_capacity;
        for (0..context.grid.active_soil_layer_count[cell]) |layer_within_cell| {
            const layer = first_layer + layer_within_cell;
            const bulk_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3[layer];
            const bulk_density_megagrams_per_m3 = context.soil_solver_properties.bulk_density_megagrams_per_m3[layer];
            const water_m3 = context.grid.matrix_liquid_water_m3[layer];
            const soil_mass_megagrams = try hourlyChemistrySoilMass(
                bulk_volume_m3,
                bulk_density_megagrams_per_m3,
                water_m3,
            );
            const materialize_fractions = try context.fertilizer_band.scienceZoneFractions(cell, layer_within_cell);
            if (cell == 0 and layer_within_cell == 0)
                diagnostics.traceMaterializePendingSolidsLayer0(context, "before_materialize_pending_solids", water_m3, materialize_fractions);
            try context.soil_chemistry.materializePendingSolids(
                layer,
                soil_mass_megagrams,
                water_m3,
                materialize_fractions,
            );
            if (cell == 0 and layer_within_cell == 0)
                diagnostics.traceMaterializePendingSolidsLayer0(context, "after_materialize_pending_solids", water_m3, materialize_fractions);
        }
    }
    diagnostics.tracePublishWettedPhosphateLayer0(context, "before_publish_wetted");
    try ecosys.mineral_fertilizer_inventory.publishWetted(
        context.mineral_fertilizer_inventory,
        context.soil_chemistry,
        context.surface_litter_chemistry,
        context.grid.matrix_liquid_water_m3,
        context.surface_precipitation.litter_water_m3,
        context.fertilizer_band,
        .{
            .water_volume_m3 = context.config.physical_tolerance.water_volume_m3,
            .fraction = context.config.physical_tolerance.dimensionless,
            .relative = context.config.physical_tolerance.relative,
        },
    );
    diagnostics.tracePublishWettedPhosphateLayer0(context, "after_publish_wetted");
    {
        const reaction_scratch_mark = scratch_allocations.mark();
        defer scratch_allocations.releaseTo(reaction_scratch_mark);
        try applyFertilizerDissolution(context, &scratch_allocations);
        try solveHourlyReactionCells(context, failure_report, &scratch_allocations);
        try diagnostics.tracePhosphateBandGeometryLayer0(context, "before_update_fertilizer_band_geometry");
        try updateFertilizerBandGeometry(context, &scratch_allocations);
        try diagnostics.tracePhosphateBandGeometryLayer0(context, "after_update_fertilizer_band_geometry");
    }
    try publishHourlyChemistry(context, fertilizer_band_hour);
}

noinline fn applyFertilizerDissolution(
    context: anytype,
    scratch_allocations: *ScratchAllocations,
) !void {
    const chemistry_parameters = context.chemistry_reaction_parameters.*;
    var staged_soil_fertilizer = try scratch_allocations.dupe(
        @TypeOf(context.soil_fertilizer_inventory.soil[0]),
        context.soil_fertilizer_inventory.soil,
    );
    var staged_aqueous = try scratch_allocations.dupe(
        @TypeOf(context.soil_chemistry.aqueous[0]),
        context.soil_chemistry.aqueous,
    );
    const staged_gaseous_mass_g = try scratch_allocations.dupe(
        f64,
        context.gas_transport.gaseous_mass_g,
    );
    const staged_urease_inhibition = try scratch_allocations.dupe(
        f64,
        context.soil_fertilizer_inventory
            .current_urease_inhibition_fraction,
    );

    for (0..context.grid.cell_count) |cell| {
        const first_layer = cell * context.grid.soil_layer_capacity;
        for (0..context.grid.active_soil_layer_count[cell]) |layer_within_cell| {
            const layer = first_layer + layer_within_cell;
            const water_volume_m3 = context.grid.matrix_liquid_water_m3[layer];
            const bulk_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3[layer];
            const soil_mass_megagrams = try hourlyChemistrySoilMass(
                bulk_volume_m3,
                context.soil_solver_properties.bulk_density_megagrams_per_m3[layer],
                water_volume_m3,
            );
            if (water_volume_m3 <= context.config.physical_tolerance.waterVolume(bulk_volume_m3)) continue;
            const water_content_m3_per_m3 = water_volume_m3 / bulk_volume_m3;
            const biologically_active_water_m3 = context.soil_nitrogen_flux_workspace.layer_biologically_active_water_m3[layer];
            if (!std.math.isFinite(biologically_active_water_m3) or biologically_active_water_m3 < 0)
                return error.InvalidHourlySoilChemistryGeometry;
            const temperature_response = try ecosys.soil_microbial_metabolism.growthTemperatureResponse(
                context.grid.soil_temperature_k[layer],
                context.microbial_thermal_adaptation.thermal_adaptation_offset_k[cell],
            );
            // SOLUTE legacy mapping:
            // TOQCK <- total maintenance respiration from NITRO workspace
            // VOLQ <- biologically active soil water from NITRO workspace
            // TFNQ <- microbial-temperature growth factor from soil temperature state
            const toqck_g_c_per_step = context.soil_nitrogen_flux_workspace.total_maintenance_respiration_g_c[layer];
            const volq_m3 = biologically_active_water_m3;
            const tfnq = temperature_response;
            const fertilizer_parameters = try chemistry_parameters.surface_fertilizer.forFormulation(
                context.soil_fertilizer_inventory.formulation[layer],
                1,
            );
            const science_zone_fractions = try context.fertilizer_band.scienceZoneFractions(cell, layer_within_cell);
            const hydrolysis = try ecosys.soil_fertilizer_dissolution.ureaHydrolysis(
                .{
                    .broadcast_urea_mol_n = context.soil_fertilizer_inventory.soil[layer].broadcast_urea_mol_n,
                    .banded_urea_mol_n = context.soil_fertilizer_inventory.soil[layer].banded_urea_mol_n,
                    .soil_mass_megagrams = soil_mass_megagrams,
                    .water_volume_m3 = water_volume_m3,
                    .biologically_active_water_volume_m3 = volq_m3,
                    .total_microbial_respiration_activity_g_c_per_step = toqck_g_c_per_step,
                    .temperature_response = tfnq,
                    .initial_inhibitor_activity = context.soil_fertilizer_inventory.initial_urease_inhibition_fraction[layer],
                    .current_inhibitor_activity = context.soil_fertilizer_inventory.current_urease_inhibition_fraction[layer],
                    .timestep_h = 1,
                },
                .{
                    .minimum_half_saturation_mol_n_per_megagram = fertilizer_parameters.minimum_urea_half_saturation_mol_n_per_megagram,
                    .microbial_activity_inhibition_g_c_per_m3_h = fertilizer_parameters.microbial_activity_inhibition_g_c_per_m3_per_h,
                    .specific_hydrolysis_mol_n_per_g_c_h = fertilizer_parameters.specific_urea_hydrolysis_mol_n_per_g_c,
                    .inhibitor_decline_rate_per_h = fertilizer_parameters.urease_inhibition_decline_fraction_per_step,
                    .negligible_biologically_active_water_m3 = context.config.physical_tolerance.water_volume_m3,
                    .negligible_inhibitor_activity = context.config.physical_tolerance.dimensionless,
                    .negligible_fertilizer_amount_mol_n = context.config.physical_tolerance.amount_mol,
                    .negligible_soil_mass_megagrams = context.config.physical_tolerance.soil_mass_megagrams,
                    .negligible_water_volume_m3 = context.config.physical_tolerance.water_volume_m3,
                    .physical_relative_tolerance = context.config.physical_tolerance.relative,
                },
            );
            const dissolved = try ecosys.soil_fertilizer_dissolution.dissolution(
                staged_soil_fertilizer[layer],
                hydrolysis,
                .{
                    .ammonium_non_band = science_zone_fractions.ammonium_non_band,
                    .ammonium_band = science_zone_fractions.ammonium_band,
                    .nitrate_non_band = science_zone_fractions.nitrate_non_band,
                    .nitrate_band = science_zone_fractions.nitrate_band,
                },
                .{
                    .ammonium_per_h = fertilizer_parameters.ammonium_dissolution_fraction_per_step,
                    .ammonia_per_h = fertilizer_parameters.ammonia_dissolution_fraction_per_step,
                    .nitrate_per_h = fertilizer_parameters.nitrate_dissolution_fraction_per_step,
                },
                water_content_m3_per_m3,
                1,
            );
            const ammonia_gas_index = try ecosys.gas_transport.massIndex(
                layer,
                .ammonia,
                context.gas_transport.cell_count,
            );
            try ecosys.soil_fertilizer_dissolution.state_updateToRecipients(
                &staged_soil_fertilizer[layer],
                &staged_aqueous[layer],
                &staged_gaseous_mass_g[ammonia_gas_index],
                dissolved,
                .{
                    .ammonium_non_band = science_zone_fractions.ammonium_non_band,
                    .ammonium_band = science_zone_fractions.ammonium_band,
                    .nitrate_non_band = science_zone_fractions.nitrate_non_band,
                    .nitrate_band = science_zone_fractions.nitrate_band,
                },
                water_volume_m3,
                context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
            );
            staged_urease_inhibition[layer] =
                hydrolysis.next_inhibitor_activity;
        }
    }
    @memcpy(context.soil_fertilizer_inventory.soil, staged_soil_fertilizer);
    @memcpy(context.soil_chemistry.aqueous, staged_aqueous);
    @memcpy(context.gas_transport.gaseous_mass_g, staged_gaseous_mass_g);
    @memcpy(
        context.soil_fertilizer_inventory
            .current_urease_inhibition_fraction,
        staged_urease_inhibition,
    );
}

const HourlyReactionFailure = struct {
    solver_error: anyerror,
    solver_parameters: ?ecosys.solute_chemistry_state.ReactionParameters = null,
};

fn hourlyReactionSolverOptions(context: anytype) ecosys.solute_reaction_solver.Options {
    return .{
        .absolute_tolerance_mol_per_m3 = context.config.nonlinear_tolerance.reaction_mol_per_m3,
        .absolute_tolerance_mol_per_megagram = context.config.nonlinear_tolerance.reaction_mol_per_megagram,
        .relative_tolerance = context.config.nonlinear_tolerance.relative,
        .picard_relaxation = context.config.picard_relaxation,
        .max_iterations = context.iteration_limits.solute_reaction_max_iterations,
    };
}

// Temporary bounded scientific-sensitivity capture. These are successful
// solve inputs/outputs, not failures or alternate acceptance candidates.
fn captureEarlyReactionState(
    context: anytype,
    layer_within_cell: usize,
    layer: usize,
    parameters: ecosys.solute_chemistry_state.ReactionParameters,
    options: ecosys.solute_reaction_solver.Options,
    label: []const u8,
) !void {
    const snapshot = ecosys.solute_failure_snapshot;
    var replay = try snapshot.capture(context.allocator, context.soil_chemistry, layer, parameters, options, .{
        .scene_hour = context.executed_weather_hours.* + 1,
        .soil_layer_id = layer_within_cell,
        .packed_cell_index = layer,
    });
    defer replay.deinit();
    const path = try std.fmt.allocPrint(context.allocator, "ecosys-ng-solute-diagnostic-hour{d}-layer{d}-{s}.bin", .{ context.executed_weather_hours.* + 1, layer_within_cell, label });
    defer context.allocator.free(path);
    var file = try std.Io.Dir.cwd().createFileAtomic(context.io, path, .{ .replace = true });
    defer file.deinit(context.io);
    const buffer = try context.allocator.alloc(u8, 64 * 1024);
    defer context.allocator.free(buffer);
    var writer = file.file.writerStreaming(context.io, buffer);
    try snapshot.write(context.allocator, &writer.interface, &replay);
    try writer.interface.flush();
    try file.file.sync(context.io);
    try file.replace(context.io);
    std.log.info("TEMP_SOLUTE_CAPTURE path={s}", .{path});
}

noinline fn solveHourlyReactionLayer(
    context: anytype,
    workspace: *ecosys.solute_reaction_solver.Workspace,
    cell: usize,
    layer_within_cell: usize,
    layer: usize,
    failure: *?HourlyReactionFailure,
) !void {
    const water_volume_m3 = context.grid.matrix_liquid_water_m3[layer];
    const bulk_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3[layer];
    const soil_mass_megagrams = try hourlyChemistrySoilMass(
        bulk_volume_m3,
        context.soil_solver_properties.bulk_density_megagrams_per_m3[layer],
        water_volume_m3,
    );
    // ISSUE-065 DRY_CARRIER_TRACE: does the SOLUTE reaction network's own
    // VOLW-floor gate (faithful to solute.f:160-161's
    // `VOLW(L,NY,NX).GT.ZEROS2(NY,NX)`) fire for cell 0/layer 0 at hour
    // 2894, and is it booked/logged anywhere the way WATSUB 6907 books its
    // heat discard? Gated to the same established hour window/cell/layer.
    const solute_gate_trace_2894 = context.executed_weather_hours.* >= 2888 and
        context.executed_weather_hours.* < 2896 and cell == 0 and layer_within_cell == 0;
    const solute_gate_floor_m3 = context.config.physical_tolerance.waterVolume(bulk_volume_m3);
    const solute_gate_skipped = water_volume_m3 <= solute_gate_floor_m3;
    if (solute_gate_trace_2894) std.log.info(
        "DRY_CARRIER_TRACE site=solute_reaction_gate hour={d} cell={d} layer={d} water_volume_m3={e} floor_m3={e} dry_reference_water_m3={e} skipped={} aqueous_carbon_dioxide_mol_per_m3={e}",
        .{
            context.executed_weather_hours.* + 1,
            cell,
            layer_within_cell,
            water_volume_m3,
            solute_gate_floor_m3,
            context.soil_chemistry.dry_reference_water_m3[layer],
            solute_gate_skipped,
            context.soil_chemistry.aqueous[layer].carbon_dioxide,
        },
    );
    if (solute_gate_skipped) return;
    // SOLUTE TUPN3S/TUPN3B is already applied atomically at the
    // root/gas owner boundary. Reapplying it here was a duplicate
    // soil loss; the former `@max(0, ...)` also hid an unmet donor.
    // SOLUTE lines 374-375 (TUPNH4/TUPNHB): deduct previous-hour
    // root NH4 uptake from initial aqueous NH4 concentrations before
    // SOLUTE equilibration. Index 0 = non-band NH4, index 4 = band NH4.
    if (@hasField(@TypeOf(context), "root_nutrient_uptake_state_update_state")) {
        const pub_state = context.root_nutrient_uptake_state_update_state;
        const g_n_nonband = pub_state.uptake_g_element_per_h_by_nutrient_and_layer[0][layer];
        const g_n_band = pub_state.uptake_g_element_per_h_by_nutrient_and_layer[4][layer];
        const next_non_band = try remainingAmmoniumConcentration(
            context.soil_chemistry.aqueous[layer].ammonium_non_band,
            g_n_nonband,
            14.0,
            water_volume_m3,
        );
        const next_band = try remainingAmmoniumConcentration(
            context.soil_chemistry.aqueous[layer].ammonium_band,
            g_n_band,
            14.0,
            water_volume_m3,
        );
        context.soil_chemistry.aqueous[layer].ammonium_non_band = next_non_band;
        context.soil_chemistry.aqueous[layer].ammonium_band = next_band;
    }
    var parameters = context.soil_chemistry_layer_parameters[layer];
    parameters.fractions = try context.fertilizer_band.scienceZoneFractions(
        cell,
        layer_within_cell,
    );
    const prepared_zones = try ecosys.soil_fertilizer_dissolution
        .prepareLayerZones(.{
        .water_volume_m3 = water_volume_m3,
        .soil_mass_megagrams = soil_mass_megagrams,
        .soil_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3[layer],
        .fractions = .{
            .ammonium_non_band = parameters.fractions.ammonium_non_band,
            .ammonium_band = parameters.fractions.ammonium_band,
            .nitrate_non_band = parameters.fractions.nitrate_non_band,
            .nitrate_band = parameters.fractions.nitrate_band,
            .phosphate_non_band = parameters.fractions.phosphate_non_band,
            .phosphate_band = parameters.fractions.phosphate_band,
        },
        .positive_soil_mass_threshold_megagrams = context.config.physical_tolerance.soilMass(soil_mass_megagrams),
    });
    const shared_ratio = try ecosys.soil_fertilizer_dissolution
        .normalizationBasisPerWaterVolume(
        prepared_zones.whole_layer_normalization_basis,
        water_volume_m3,
    );
    parameters.cation_exchange_water_ratios = .{
        .shared_megagrams_per_m3 = shared_ratio,
        .ammonium_non_band_megagrams_per_m3 = try ecosys.soil_fertilizer_dissolution.normalizationBasisPerWaterVolume(
            prepared_zones.ammonium_non_band_normalization_basis,
            prepared_zones.ammonium_non_band_water_m3,
        ),
        .ammonium_band_megagrams_per_m3 = try ecosys.soil_fertilizer_dissolution.normalizationBasisPerWaterVolume(
            prepared_zones.ammonium_band_normalization_basis,
            prepared_zones.ammonium_band_water_m3,
        ),
    };
    parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = try ecosys.soil_fertilizer_dissolution.normalizationBasisPerWaterVolume(
        prepared_zones.phosphate_non_band_normalization_basis,
        prepared_zones.phosphate_non_band_water_m3,
    );
    parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = try ecosys.soil_fertilizer_dissolution.normalizationBasisPerWaterVolume(
        prepared_zones.phosphate_band_normalization_basis,
        prepared_zones.phosphate_band_water_m3,
    );
    parameters.total_carboxyl_sites_mol_per_megagram = context.chemistry_reaction_parameters.*.surface_litter.carboxyl_sites_mol_per_megagram_c *
        1.0e-6 * context.soil_solver_properties.total_organic_carbon_g_per_megagram[layer];
    // SOLUTE line 2934: CCO21 = CCO2S/12 = (CO2S/VOLW)/12 mol/m³ water.
    // Without dissolved CO2, bicarbonate/carbonate are zero and the
    // charge balance diverges to pH ~2.7 from the very first hour.
    {
        const co2_idx = try ecosys.gas_transport.massIndex(layer, .carbon_dioxide, context.gas_transport.cell_count);
        context.soil_chemistry.aqueous[layer].carbon_dioxide = try dissolvedCarbonDioxideConcentration(
            context.gas_transport.dissolved_mass_g[co2_idx],
            water_volume_m3,
        );
    }
    const solver_options = hourlyReactionSolverOptions(context);
    const capture_early_state = !@import("builtin").is_test and
        context.executed_weather_hours.* < 2 and cell == 0 and layer_within_cell < 3;
    if (capture_early_state)
        captureEarlyReactionState(context, layer_within_cell, layer, parameters, solver_options, "before") catch |err|
            std.log.warn("early reaction diagnostic capture failed: error={s}", .{@errorName(err)});
    const profile_first_hour = ecosys.solute_reaction_solver.diagnosticRuntimeProfilingEnabled and
        !@import("builtin").is_test and
        context.executed_weather_hours.* == 0;
    if (profile_first_hour) {
        ecosys.solute_reaction_solver.resetDiagnosticEvaluationCounts();
        ecosys.solute_reaction_solver.resetDiagnosticReactionSpanBoundsSiteStats();
        ecosys.solute_reaction_solver.resetDiagnosticStrategyCallCounts();
        ecosys.solute_reaction_solver.resetDiagnosticSelectedCandidateCounts();
        ecosys.solute_reaction_solver.resetDiagnosticAdmissibilityBacktrackStats();
    }
    const reaction_start = if (profile_first_hour)
        std.Io.Clock.now(.boot, context.io)
    else
        undefined;
    const reaction_result = ecosys.solute_reaction_solver.solveCellWithWorkspace(
        workspace,
        context.soil_chemistry,
        layer,
        parameters,
        solver_options,
    ) catch |err| {
        failure.* = .{
            .solver_error = err,
            .solver_parameters = parameters,
        };
        return;
    };
    if (capture_early_state)
        captureEarlyReactionState(context, layer_within_cell, layer, parameters, solver_options, "after") catch |err|
            std.log.warn("early reaction diagnostic capture failed: error={s}", .{@errorName(err)});
    if (profile_first_hour) {
        const counts = ecosys.solute_reaction_solver.diagnosticEvaluationCounts();
        const backtracks = ecosys.solute_reaction_solver.diagnosticAdmissibilityBacktrackStats();
        std.log.info(
            "hourly chemistry layer profile: cell={d} layer={d} packed_cell_index={d} elapsed_ms={d} iterations={d} newton_steps={d} anderson_steps={d} max_scaled_residual={e} full_network_evaluations={d} reaction_span_evaluations={d} admissibility_calls={d} admissibility_attempts={d} admissibility_max_attempts={d}",
            .{
                cell,
                layer_within_cell,
                layer,
                reaction_start.durationTo(std.Io.Clock.now(.boot, context.io)).toMilliseconds(),
                reaction_result.iterations,
                reaction_result.newton_raphson_steps,
                reaction_result.anderson_steps,
                reaction_result.maximum_scaled_residual,
                counts.full_network,
                counts.reaction_span,
                backtracks.calls,
                backtracks.total_attempts,
                backtracks.max_attempts,
            },
        );
        inline for (@typeInfo(ecosys.solute_reaction_solver.DiagnosticStrategy).@"enum".fields) |field| {
            const strategy: ecosys.solute_reaction_solver.DiagnosticStrategy = @enumFromInt(field.value);
            const evaluations = ecosys.solute_reaction_solver.diagnosticStrategyEvaluationCounts(strategy);
            const calls = ecosys.solute_reaction_solver.diagnosticStrategyCallCount(strategy);
            if (calls != 0 or evaluations.full_network != 0 or evaluations.reaction_span != 0)
                std.log.info(
                    "hourly chemistry strategy profile: cell={d} layer={d} strategy={s} calls={d} full_network_evaluations={d} reaction_span_evaluations={d}",
                    .{ cell, layer_within_cell, field.name, calls, evaluations.full_network, evaluations.reaction_span },
                );
        }
        inline for (@typeInfo(ecosys.solute_reaction_solver.DiagnosticSelectedCandidate).@"enum".fields) |field| {
            const candidate: ecosys.solute_reaction_solver.DiagnosticSelectedCandidate = @enumFromInt(field.value);
            const count = ecosys.solute_reaction_solver.diagnosticSelectedCandidateCount(candidate);
            if (count != 0)
                std.log.info(
                    "hourly chemistry accepted-candidate profile: cell={d} layer={d} candidate={s} count={d}",
                    .{ cell, layer_within_cell, field.name, count },
                );
        }
        inline for (@typeInfo(ecosys.solute_reaction_solver.DiagnosticReactionSpanBoundsSite).@"enum".fields) |field| {
            const site: ecosys.solute_reaction_solver.DiagnosticReactionSpanBoundsSite = @enumFromInt(field.value);
            const site_stats = ecosys.solute_reaction_solver.diagnosticReactionSpanBoundsSiteStats(site);
            if (site_stats.calls != 0 or site_stats.reaction_span_evaluations != 0)
                std.log.info(
                    "hourly chemistry span profile: cell={d} layer={d} site={s} calls={d} full_network_evaluations={d} reaction_span_evaluations={d}",
                    .{ cell, layer_within_cell, field.name, site_stats.calls, site_stats.full_network_evaluations, site_stats.reaction_span_evaluations },
                );
        }
    }
    try context.soil_chemistry.publishAcceptedWaterEquilibriumBalance(
        layer,
        reaction_result.accepted_water_equilibrium_extent_mol_per_m3,
        water_volume_m3,
    );
}

noinline fn solveHourlyReactionLayerRange(
    worker_context: anytype,
    worker_layers: ecosys.compute.StridedIndexRange,
    worker_index: usize,
) !void {
    const context = worker_context.science_context;
    if (worker_index >= context.soil_chemistry_solver_workspaces.len)
        return error.SoilChemistryWorkerIndexOutOfBounds;
    const workspace = &context.soil_chemistry_solver_workspaces[worker_index];
    var layers = worker_layers;
    while (layers.next()) |layer| {
        const cell = layer / context.grid.soil_layer_capacity;
        const layer_within_cell = layer % context.grid.soil_layer_capacity;
        if (layer_within_cell >= context.grid.active_soil_layer_count[cell]) continue;
        solveHourlyReactionLayer(
            context,
            workspace,
            cell,
            layer_within_cell,
            layer,
            &worker_context.failures[layer],
        ) catch |err| {
            worker_context.failures[layer] = .{ .solver_error = err };
        };
    }
}

noinline fn solveHourlyReactionCells(
    context: anytype,
    failure_report: ?ecosys.solute_failure_reporter.Request,
    scratch_allocations: *ScratchAllocations,
) !void {
    if (context.soil_chemistry_solver_workspaces.len < context.executor.statistics().effective_threads)
        return error.InsufficientSoilChemistryWorkerWorkspaces;
    const failures = try scratch_allocations.alloc(?HourlyReactionFailure, context.grid.layer_count);
    @memset(failures, null);
    var worker_context = .{
        .science_context = context,
        .failures = failures,
    };
    try context.executor.runIndependentStridedIndexed(
        .{ .first = 0, .end = context.grid.layer_count },
        &worker_context,
        solveHourlyReactionLayerRange,
    );
    for (0..context.grid.cell_count) |cell| {
        const first_layer = cell * context.grid.soil_layer_capacity;
        for (0..context.grid.active_soil_layer_count[cell]) |layer_within_cell| {
            const layer = first_layer + layer_within_cell;
            const failure = failures[layer] orelse continue;
            if (failure.solver_parameters) |parameters| {
                if (!@import("builtin").is_test) std.log.warn(
                    "SOLUTE hourly reaction solver failed: cell={d} layer={d} packed_cell_index={d} error={s} failure_report_bound={}",
                    .{ cell, layer_within_cell, layer, @errorName(failure.solver_error), failure_report != null },
                );
                if (failure_report) |report| {
                    var contextual_report = report;
                    contextual_report.context.global_cell_id = @intCast(cell);
                    contextual_report.context.soil_layer_id = @intCast(layer_within_cell);
                    contextual_report.context.packed_cell_index = @intCast(layer);
                    return ecosys.solute_failure_reporter.reportPreservingSolverError(
                        context.allocator,
                        contextual_report,
                        context.soil_chemistry,
                        layer,
                        parameters,
                        hourlyReactionSolverOptions(context),
                        failure.solver_error,
                    );
                }
            }
            return failure.solver_error;
        }
    }
    // After solute solver equilibrates CO2(aq) ↔ HCO3⁻, sync gas_state
    // dissolved CO2 with the post-equilibration chemistry CO2(aq).  Without
    // this update, the inventory counts pre-equilibration dissolved CO2 from
    // gas_state alongside post-equilibration micropore HCO3⁻ from
    // exportChemistry, creating a systematic carbon balance drift equal to
    // the equilibrium shift in each layer.
    for (0..context.grid.cell_count) |sync_cell| {
        const sync_first = sync_cell * context.grid.soil_layer_capacity;
        for (0..context.grid.active_soil_layer_count[sync_cell]) |sync_local_layer| {
            const sync_layer = sync_first + sync_local_layer;
            const sync_water_m3 = context.grid.matrix_liquid_water_m3[sync_layer];
            const sync_bulk_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3[sync_layer];
            if (!std.math.isFinite(sync_water_m3) or sync_water_m3 < 0 or !std.math.isFinite(sync_bulk_volume_m3) or sync_bulk_volume_m3 <= 0)
                return error.InvalidHourlySoilChemistryGeometry;
            if (sync_water_m3 <= context.config.physical_tolerance.waterVolume(sync_bulk_volume_m3)) continue;
            const sync_co2_idx = try ecosys.gas_transport.massIndex(sync_layer, .carbon_dioxide, context.gas_transport.cell_count);
            context.gas_transport.dissolved_mass_g[sync_co2_idx] = context.soil_chemistry.aqueous[sync_layer].carbon_dioxide * 12.0 * sync_water_m3;
        }
    }
}

noinline fn updateFertilizerBandGeometry(
    context: anytype,
    scratch_allocations: *ScratchAllocations,
) !void {
    for (0..context.grid.cell_count) |cell| {
        const active_layer_count = context.grid.active_soil_layer_count[cell];
        if (active_layer_count == 0) continue;
        if (active_layer_count > context.grid.soil_layer_capacity)
            return error.InvalidHourlySoilChemistryGeometry;
        const first_layer = cell * context.grid.soil_layer_capacity;
        const cell_scratch_mark = scratch_allocations.mark();
        defer scratch_allocations.releaseTo(cell_scratch_mark);
        var layer_properties = try scratch_allocations.alloc(
            ecosys.fertilizer_band_nitrate_phosphate.LayerProperties,
            active_layer_count,
        );
        const nitrate_geometry = try context.fertilizer_band.geometry(
            cell,
            .nitrate,
        );
        const phosphate_geometry = try context.fertilizer_band.geometry(
            cell,
            .phosphate,
        );
        const nitrate_row_width_m = nitrate_geometry.row_spacing_m;
        const phosphate_row_width_m = phosphate_geometry.row_spacing_m;
        const nitrate_application: ecosys.fertilizer_band_nitrate_phosphate.BandApplication = if (nitrate_row_width_m > 0) .banded else .unbanded;
        const phosphate_application: ecosys.fertilizer_band_nitrate_phosphate.BandApplication = if (phosphate_row_width_m > 0) .banded else .unbanded;
        var nonband_fractional_change = try scratch_allocations.alloc(f64, active_layer_count);
        var layer_top_depth_m: f64 = 0;
        for (0..active_layer_count) |local_layer| {
            const global_layer = first_layer + local_layer;
            const layer_thickness = context.soil_solver_properties.layer_thickness_m[global_layer];
            if (!std.math.isFinite(layer_thickness) or layer_thickness < 0)
                return error.InvalidHourlySoilChemistryGeometry;
            const water_volume_m3 = context.grid.matrix_liquid_water_m3[global_layer];
            const pore_capacity_m3 = context.grid.matrix_pore_capacity_m3[global_layer];
            if (!std.math.isFinite(water_volume_m3) or water_volume_m3 < 0 or !std.math.isFinite(pore_capacity_m3) or pore_capacity_m3 < 0)
                return error.InvalidHourlySoilChemistryGeometry;
            const water_fraction = if (pore_capacity_m3 > 0) blk: {
                const raw_fraction = water_volume_m3 / pore_capacity_m3;
                const fraction_tolerance = context.config.physical_tolerance.fraction(1);
                if (!std.math.isFinite(raw_fraction) or raw_fraction > 1 + fraction_tolerance)
                    return error.InvalidHourlySoilChemistryWaterFraction;
                break :blk if (raw_fraction > 1) 1 else raw_fraction;
            } else 0;
            const top_depth_m = layer_top_depth_m;
            layer_top_depth_m += layer_thickness;
            layer_properties[local_layer] = .{
                .top_depth_m = top_depth_m,
                .bottom_depth_m = layer_top_depth_m,
                .thickness_m = layer_thickness,
                .tortuosity = context.runscript.root_nutrient_parameters.liquid_tortuosity_coefficient * water_fraction * water_fraction,
                .nitrate_diffusivity_m2_h = try context.runscript.root_nutrient_parameters.diffusivityM2PerH(
                    1,
                    context.grid.soil_temperature_k[global_layer],
                ),
                .phosphate_diffusivity_m2_h = try context.runscript.root_nutrient_parameters.diffusivityM2PerH(
                    2,
                    context.grid.soil_temperature_k[global_layer],
                ),
            };
        }
        const nitrate_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const nitrate_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const nitrite_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const nitrite_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const fertilizer_nitrate_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const fertilizer_nitrate_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const hydrogen_phosphate_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const hydrogen_phosphate_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const dihydrogen_phosphate_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const dihydrogen_phosphate_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const adsorbed_oh0_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const adsorbed_oh0_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const adsorbed_oh1_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const adsorbed_oh1_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const adsorbed_oh2_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const adsorbed_oh2_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const adsorbed_hpo4_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const adsorbed_hpo4_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const adsorbed_h2po4_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const adsorbed_h2po4_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const aluminum_phosphate_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const aluminum_phosphate_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const iron_phosphate_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const iron_phosphate_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const dicalcium_phosphate_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const dicalcium_phosphate_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const hydroxyapatite_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const hydroxyapatite_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const monocalcium_phosphate_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const monocalcium_phosphate_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const phosphate_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const phosphate_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const phosphoric_acid_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const phosphoric_acid_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const iron_hpo4_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const iron_hpo4_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const iron_h2po4_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const iron_h2po4_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const calcium_hpo4_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const calcium_hpo4_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const calcium_h2po4_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const calcium_h2po4_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const calcium_phosphate_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const calcium_phosphate_band_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const magnesium_hpo4_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);
        const magnesium_hpo4_band_pools = try scratch_allocations.alloc(f64, active_layer_count);

        for (0..active_layer_count) |local_layer| {
            const global_layer = first_layer + local_layer;
            const layer = context.soil_chemistry.aqueous[global_layer];
            const non_band = context.soil_chemistry.non_band_phosphate[global_layer];
            const band = context.soil_chemistry.band_phosphate[global_layer];
            const water_volume_m3 = context.grid.matrix_liquid_water_m3[global_layer];
            const bulk_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3[global_layer];
            const soil_mass_megagrams = try hourlyChemistrySoilMass(
                bulk_volume_m3,
                context.soil_solver_properties.bulk_density_megagrams_per_m3[global_layer],
                water_volume_m3,
            );
            // issue-073 Finding C: below `solveHourlyReactionLayer`'s own
            // ZEROS2-equivalent floor (same file, same layer, same hour --
            // `context.config.physical_tolerance.waterVolume(bulk_volume_m3)`),
            // that function returns early and leaves this layer's aqueous
            // concentrations at their stale (pre-hour) values instead of
            // updating them against the collapsed carrier. Scaling those
            // stale concentrations by the raw (collapsed) water_volume_m3
            // here would manufacture a spurious near-zero mass pool
            // inconsistent with what the reaction solver itself assumed for
            // the same layer this same hour. Substituting the persistent
            // `dry_reference_water_m3` carrier keeps this function's pools
            // consistent with `solveHourlyReactionLayer`'s own dry-reference
            // bookkeeping, mirroring the fix pattern this defect class uses
            // everywhere else in this codebase.
            const fertilizer_band_water_floor_m3 = context.config.physical_tolerance.waterVolume(bulk_volume_m3);
            const effective_water_volume_m3 = fertilizerBandGeometryCarrierM3(
                water_volume_m3,
                fertilizer_band_water_floor_m3,
                context.soil_chemistry.dry_reference_water_m3[global_layer],
            );
            const nitrate_nonband_g_n = layer.nitrate_non_band * effective_water_volume_m3 * 14.0;
            const nitrate_band_g_n = layer.nitrate_band * effective_water_volume_m3 * 14.0;
            const nitrite_nonband_g_n = context.soil_reactive_nitrogen.non_band_nitrite_g_n[global_layer];
            const nitrite_band_g_n = context.soil_reactive_nitrogen.band_nitrite_g_n[global_layer];
            if (!std.math.isFinite(nitrate_nonband_g_n) or !std.math.isFinite(nitrate_band_g_n) or !std.math.isFinite(nitrite_nonband_g_n) or !std.math.isFinite(nitrite_band_g_n))
                return error.InvalidHourlySoilChemistryGeometry;
            const fertilizer_nitrate_nonband_g_n = context.soil_fertilizer_inventory.soil[global_layer].broadcast_nitrate_mol_n * 14.0;
            const fertilizer_nitrate_band_g_n = context.soil_fertilizer_inventory.soil[global_layer].banded_nitrate_mol_n * 14.0;
            if (!std.math.isFinite(fertilizer_nitrate_nonband_g_n) or !std.math.isFinite(fertilizer_nitrate_band_g_n))
                return error.InvalidHourlySoilChemistryGeometry;
            const hydrogen_phosphate_nonband_mol = non_band.dissolved_hpo4_mol_p_per_m3 * effective_water_volume_m3;
            const hydrogen_phosphate_band_mol = band.dissolved_hpo4_mol_p_per_m3 * effective_water_volume_m3;
            const dihydrogen_phosphate_nonband_mol = non_band.dissolved_h2po4_mol_p_per_m3 * effective_water_volume_m3;
            const dihydrogen_phosphate_band_mol = band.dissolved_h2po4_mol_p_per_m3 * effective_water_volume_m3;
            if (!(std.math.isFinite(hydrogen_phosphate_nonband_mol) and std.math.isFinite(hydrogen_phosphate_band_mol) and std.math.isFinite(dihydrogen_phosphate_nonband_mol) and std.math.isFinite(dihydrogen_phosphate_band_mol)))
                return error.InvalidHourlySoilChemistryGeometry;
            const adsorbed_oh0_nonband_mol = non_band.deprotonated_site_mol_per_megagram * soil_mass_megagrams;
            const adsorbed_oh0_band_mol = band.deprotonated_site_mol_per_megagram * soil_mass_megagrams;
            const adsorbed_oh1_nonband_mol = non_band.hydroxyl_site_mol_per_megagram * soil_mass_megagrams;
            const adsorbed_oh1_band_mol = band.hydroxyl_site_mol_per_megagram * soil_mass_megagrams;
            const adsorbed_oh2_nonband_mol = non_band.protonated_site_mol_per_megagram * soil_mass_megagrams;
            const adsorbed_oh2_band_mol = band.protonated_site_mol_per_megagram * soil_mass_megagrams;
            const adsorbed_hpo4_nonband_mol = non_band.adsorbed_hpo4_mol_p_per_megagram * soil_mass_megagrams;
            const adsorbed_hpo4_band_mol = band.adsorbed_hpo4_mol_p_per_megagram * soil_mass_megagrams;
            const adsorbed_h2po4_nonband_mol = non_band.adsorbed_h2po4_mol_p_per_megagram * soil_mass_megagrams;
            const adsorbed_h2po4_band_mol = band.adsorbed_h2po4_mol_p_per_megagram * soil_mass_megagrams;
            const aluminum_phosphate_nonband_mol = non_band.aluminum_phosphate_solid_mol_per_m3 * effective_water_volume_m3;
            const aluminum_phosphate_band_mol = band.aluminum_phosphate_solid_mol_per_m3 * effective_water_volume_m3;
            const iron_phosphate_nonband_mol = non_band.iron_phosphate_solid_mol_per_m3 * effective_water_volume_m3;
            const iron_phosphate_band_mol = band.iron_phosphate_solid_mol_per_m3 * effective_water_volume_m3;
            const dicalcium_phosphate_nonband_mol = non_band.dicalcium_phosphate_solid_mol_per_m3 * effective_water_volume_m3;
            const dicalcium_phosphate_band_mol = band.dicalcium_phosphate_solid_mol_per_m3 * effective_water_volume_m3;
            const hydroxyapatite_nonband_mol = non_band.hydroxyapatite_solid_mol_per_m3 * effective_water_volume_m3;
            const hydroxyapatite_band_mol = band.hydroxyapatite_solid_mol_per_m3 * effective_water_volume_m3;
            const monocalcium_phosphate_nonband_mol = non_band.monocalcium_phosphate_solid_mol_per_m3 * effective_water_volume_m3;
            const monocalcium_phosphate_band_mol = band.monocalcium_phosphate_solid_mol_per_m3 * effective_water_volume_m3;
            if (!std.math.isFinite(adsorbed_oh0_nonband_mol) or !std.math.isFinite(adsorbed_oh0_band_mol) or !std.math.isFinite(adsorbed_oh1_nonband_mol) or !std.math.isFinite(adsorbed_oh1_band_mol) or !std.math.isFinite(adsorbed_oh2_nonband_mol) or !std.math.isFinite(adsorbed_oh2_band_mol) or !std.math.isFinite(adsorbed_hpo4_nonband_mol) or !std.math.isFinite(adsorbed_hpo4_band_mol) or !std.math.isFinite(adsorbed_h2po4_nonband_mol) or !std.math.isFinite(adsorbed_h2po4_band_mol) or !std.math.isFinite(aluminum_phosphate_nonband_mol) or !std.math.isFinite(aluminum_phosphate_band_mol) or !std.math.isFinite(iron_phosphate_nonband_mol) or !std.math.isFinite(iron_phosphate_band_mol) or !std.math.isFinite(dicalcium_phosphate_nonband_mol) or !std.math.isFinite(dicalcium_phosphate_band_mol) or !std.math.isFinite(hydroxyapatite_nonband_mol) or !std.math.isFinite(hydroxyapatite_band_mol) or !std.math.isFinite(monocalcium_phosphate_nonband_mol) or !std.math.isFinite(monocalcium_phosphate_band_mol))
                return error.InvalidHourlySoilChemistryGeometry;
            const phosphate_nonband_mol = non_band.dissolved_po4_mol_p_per_m3 * effective_water_volume_m3;
            const phosphate_band_mol = band.dissolved_po4_mol_p_per_m3 * effective_water_volume_m3;
            const phosphoric_acid_nonband_mol = non_band.dissolved_h3po4_mol_p_per_m3 * effective_water_volume_m3;
            const phosphoric_acid_band_mol = band.dissolved_h3po4_mol_p_per_m3 * effective_water_volume_m3;
            const iron_hpo4_nonband_mol = non_band.iron_hpo4_pair_mol_per_m3 * effective_water_volume_m3;
            const iron_hpo4_band_mol = band.iron_hpo4_pair_mol_per_m3 * effective_water_volume_m3;
            const iron_h2po4_nonband_mol = non_band.iron_h2po4_pair_mol_per_m3 * effective_water_volume_m3;
            const iron_h2po4_band_mol = band.iron_h2po4_pair_mol_per_m3 * effective_water_volume_m3;
            const calcium_hpo4_nonband_mol = non_band.calcium_po4_pair_mol_per_m3 * effective_water_volume_m3;
            const calcium_hpo4_band_mol = band.calcium_po4_pair_mol_per_m3 * effective_water_volume_m3;
            const calcium_h2po4_nonband_mol = non_band.calcium_h2po4_pair_mol_per_m3 * effective_water_volume_m3;
            const calcium_h2po4_band_mol = band.calcium_h2po4_pair_mol_per_m3 * effective_water_volume_m3;
            const calcium_phosphate_nonband_mol = non_band.calcium_po4_pair_mol_per_m3 * effective_water_volume_m3;
            const calcium_phosphate_band_mol = band.calcium_po4_pair_mol_per_m3 * effective_water_volume_m3;
            const magnesium_hpo4_nonband_mol = non_band.magnesium_hpo4_pair_mol_per_m3 * effective_water_volume_m3;
            const magnesium_hpo4_band_mol = band.magnesium_hpo4_pair_mol_per_m3 * effective_water_volume_m3;
            if (!std.math.isFinite(phosphate_nonband_mol) or !std.math.isFinite(phosphate_band_mol) or !std.math.isFinite(phosphoric_acid_nonband_mol) or !std.math.isFinite(phosphoric_acid_band_mol) or !std.math.isFinite(iron_hpo4_nonband_mol) or !std.math.isFinite(iron_hpo4_band_mol) or !std.math.isFinite(iron_h2po4_nonband_mol) or !std.math.isFinite(iron_h2po4_band_mol) or !std.math.isFinite(calcium_hpo4_nonband_mol) or !std.math.isFinite(calcium_hpo4_band_mol) or !std.math.isFinite(calcium_h2po4_nonband_mol) or !std.math.isFinite(calcium_h2po4_band_mol) or !std.math.isFinite(calcium_phosphate_nonband_mol) or !std.math.isFinite(calcium_phosphate_band_mol) or !std.math.isFinite(magnesium_hpo4_nonband_mol) or !std.math.isFinite(magnesium_hpo4_band_mol))
                return error.InvalidHourlySoilChemistryGeometry;
            nitrate_nonband_pools[local_layer] = nitrate_nonband_g_n;
            nitrate_band_pools[local_layer] = nitrate_band_g_n;
            nitrite_nonband_pools[local_layer] = nitrite_nonband_g_n;
            nitrite_band_pools[local_layer] = nitrite_band_g_n;
            fertilizer_nitrate_nonband_pools[local_layer] = fertilizer_nitrate_nonband_g_n;
            fertilizer_nitrate_band_pools[local_layer] = fertilizer_nitrate_band_g_n;
            hydrogen_phosphate_nonband_pools[local_layer] = hydrogen_phosphate_nonband_mol;
            hydrogen_phosphate_band_pools[local_layer] = hydrogen_phosphate_band_mol;
            dihydrogen_phosphate_nonband_pools[local_layer] = dihydrogen_phosphate_nonband_mol;
            dihydrogen_phosphate_band_pools[local_layer] = dihydrogen_phosphate_band_mol;
            adsorbed_oh0_nonband_pools[local_layer] = adsorbed_oh0_nonband_mol;
            adsorbed_oh0_band_pools[local_layer] = adsorbed_oh0_band_mol;
            adsorbed_oh1_nonband_pools[local_layer] = adsorbed_oh1_nonband_mol;
            adsorbed_oh1_band_pools[local_layer] = adsorbed_oh1_band_mol;
            adsorbed_oh2_nonband_pools[local_layer] = adsorbed_oh2_nonband_mol;
            adsorbed_oh2_band_pools[local_layer] = adsorbed_oh2_band_mol;
            adsorbed_hpo4_nonband_pools[local_layer] = adsorbed_hpo4_nonband_mol;
            adsorbed_hpo4_band_pools[local_layer] = adsorbed_hpo4_band_mol;
            adsorbed_h2po4_nonband_pools[local_layer] = adsorbed_h2po4_nonband_mol;
            adsorbed_h2po4_band_pools[local_layer] = adsorbed_h2po4_band_mol;
            aluminum_phosphate_nonband_pools[local_layer] = aluminum_phosphate_nonband_mol;
            aluminum_phosphate_band_pools[local_layer] = aluminum_phosphate_band_mol;
            iron_phosphate_nonband_pools[local_layer] = iron_phosphate_nonband_mol;
            iron_phosphate_band_pools[local_layer] = iron_phosphate_band_mol;
            dicalcium_phosphate_nonband_pools[local_layer] = dicalcium_phosphate_nonband_mol;
            dicalcium_phosphate_band_pools[local_layer] = dicalcium_phosphate_band_mol;
            hydroxyapatite_nonband_pools[local_layer] = hydroxyapatite_nonband_mol;
            hydroxyapatite_band_pools[local_layer] = hydroxyapatite_band_mol;
            monocalcium_phosphate_nonband_pools[local_layer] = monocalcium_phosphate_nonband_mol;
            monocalcium_phosphate_band_pools[local_layer] = monocalcium_phosphate_band_mol;
            phosphate_nonband_pools[local_layer] = phosphate_nonband_mol;
            phosphate_band_pools[local_layer] = phosphate_band_mol;
            phosphoric_acid_nonband_pools[local_layer] = phosphoric_acid_nonband_mol;
            phosphoric_acid_band_pools[local_layer] = phosphoric_acid_band_mol;
            iron_hpo4_nonband_pools[local_layer] = iron_hpo4_nonband_mol;
            iron_hpo4_band_pools[local_layer] = iron_hpo4_band_mol;
            iron_h2po4_nonband_pools[local_layer] = iron_h2po4_nonband_mol;
            iron_h2po4_band_pools[local_layer] = iron_h2po4_band_mol;
            calcium_hpo4_nonband_pools[local_layer] = calcium_hpo4_nonband_mol;
            calcium_hpo4_band_pools[local_layer] = calcium_hpo4_band_mol;
            calcium_h2po4_nonband_pools[local_layer] = calcium_h2po4_nonband_mol;
            calcium_h2po4_band_pools[local_layer] = calcium_h2po4_band_mol;
            calcium_phosphate_nonband_pools[local_layer] = calcium_phosphate_nonband_mol;
            calcium_phosphate_band_pools[local_layer] = calcium_phosphate_band_mol;
            magnesium_hpo4_nonband_pools[local_layer] = magnesium_hpo4_nonband_mol;
            magnesium_hpo4_band_pools[local_layer] = magnesium_hpo4_band_mol;
        }

        var nitrate_geometry_for_update = ecosys.fertilizer_band_nitrate_phosphate.BandGeometry{
            .total_depth_m = nitrate_geometry.lower_edge_depth_m,
            .penetration_front_depth_m = nitrate_geometry.upper_edge_depth_m,
            .layer_depth_m = nitrate_geometry.band_depth_m[0..active_layer_count],
            .layer_width_m = nitrate_geometry.band_width_m[0..active_layer_count],
            .nonband_volume_fraction = nitrate_geometry.non_band_volume_fraction[0..active_layer_count],
            .band_volume_fraction = nitrate_geometry.band_volume_fraction[0..active_layer_count],
            .nonband_fractional_change_per_timestep = nonband_fractional_change[0..active_layer_count],
        };
        var phosphate_geometry_for_update = ecosys.fertilizer_band_nitrate_phosphate.BandGeometry{
            .total_depth_m = phosphate_geometry.lower_edge_depth_m,
            .penetration_front_depth_m = phosphate_geometry.upper_edge_depth_m,
            .layer_depth_m = phosphate_geometry.band_depth_m[0..active_layer_count],
            .layer_width_m = phosphate_geometry.band_width_m[0..active_layer_count],
            .nonband_volume_fraction = phosphate_geometry.non_band_volume_fraction[0..active_layer_count],
            .band_volume_fraction = phosphate_geometry.band_volume_fraction[0..active_layer_count],
            .nonband_fractional_change_per_timestep = nonband_fractional_change[0..active_layer_count],
        };
        var nitrate_pools = ecosys.fertilizer_band_nitrate_phosphate.NitratePools{
            .nitrate_nonband_g_n = nitrate_nonband_pools,
            .nitrate_band_g_n = nitrate_band_pools,
            .nitrite_nonband_g_n = nitrite_nonband_pools,
            .nitrite_band_g_n = nitrite_band_pools,
            .fertilizer_nitrate_nonband_g_n = fertilizer_nitrate_nonband_pools,
            .fertilizer_nitrate_band_g_n = fertilizer_nitrate_band_pools,
        };
        var phosphate_pools = ecosys.fertilizer_band_nitrate_phosphate.PhosphatePools{
            .hydrogen_phosphate_nonband_mol = hydrogen_phosphate_nonband_pools,
            .hydrogen_phosphate_band_mol = hydrogen_phosphate_band_pools,
            .dihydrogen_phosphate_nonband_mol = dihydrogen_phosphate_nonband_pools,
            .dihydrogen_phosphate_band_mol = dihydrogen_phosphate_band_pools,
            .adsorbed_oh0_nonband_mol = adsorbed_oh0_nonband_pools,
            .adsorbed_oh0_band_mol = adsorbed_oh0_band_pools,
            .adsorbed_oh1_nonband_mol = adsorbed_oh1_nonband_pools,
            .adsorbed_oh1_band_mol = adsorbed_oh1_band_pools,
            .adsorbed_oh2_nonband_mol = adsorbed_oh2_nonband_pools,
            .adsorbed_oh2_band_mol = adsorbed_oh2_band_pools,
            .adsorbed_hpo4_nonband_mol = adsorbed_hpo4_nonband_pools,
            .adsorbed_hpo4_band_mol = adsorbed_hpo4_band_pools,
            .adsorbed_h2po4_nonband_mol = adsorbed_h2po4_nonband_pools,
            .adsorbed_h2po4_band_mol = adsorbed_h2po4_band_pools,
            .aluminum_phosphate_nonband_mol = aluminum_phosphate_nonband_pools,
            .aluminum_phosphate_band_mol = aluminum_phosphate_band_pools,
            .iron_phosphate_nonband_mol = iron_phosphate_nonband_pools,
            .iron_phosphate_band_mol = iron_phosphate_band_pools,
            .dicalcium_phosphate_nonband_mol = dicalcium_phosphate_nonband_pools,
            .dicalcium_phosphate_band_mol = dicalcium_phosphate_band_pools,
            .hydroxyapatite_nonband_mol = hydroxyapatite_nonband_pools,
            .hydroxyapatite_band_mol = hydroxyapatite_band_pools,
            .monocalcium_phosphate_nonband_mol = monocalcium_phosphate_nonband_pools,
            .monocalcium_phosphate_band_mol = monocalcium_phosphate_band_pools,
            .phosphate_nonband_mol = phosphate_nonband_pools,
            .phosphate_band_mol = phosphate_band_pools,
            .phosphoric_acid_nonband_mol = phosphoric_acid_nonband_pools,
            .phosphoric_acid_band_mol = phosphoric_acid_band_pools,
            .iron_hpo4_nonband_mol = iron_hpo4_nonband_pools,
            .iron_hpo4_band_mol = iron_hpo4_band_pools,
            .iron_h2po4_nonband_mol = iron_h2po4_nonband_pools,
            .iron_h2po4_band_mol = iron_h2po4_band_pools,
            .calcium_hpo4_nonband_mol = calcium_hpo4_nonband_pools,
            .calcium_hpo4_band_mol = calcium_hpo4_band_pools,
            .calcium_h2po4_nonband_mol = calcium_h2po4_nonband_pools,
            .calcium_h2po4_band_mol = calcium_h2po4_band_pools,
            .calcium_phosphate_nonband_mol = calcium_phosphate_nonband_pools,
            .calcium_phosphate_band_mol = calcium_phosphate_band_pools,
            .magnesium_hpo4_nonband_mol = magnesium_hpo4_nonband_pools,
            .magnesium_hpo4_band_mol = magnesium_hpo4_band_pools,
        };
        for (0..active_layer_count) |layer_within_cell| {
            try ecosys.fertilizer_band_nitrate_phosphate.updateLayer(
                .{
                    .first_active_layer_index = 0,
                    .layer_index = layer_within_cell,
                    .solute_timestep_h = 1,
                    .depth_threshold_m = 0,
                    .minimum_layer_thickness_m = context.runscript.soil_geometry_parameters.minimum_layer_thickness_m,
                    .absent_band_fraction_threshold = context.config.physical_tolerance.fraction(1),
                    .maximum_band_volume_fraction = 0.9999,
                    .nitrate_application = nitrate_application,
                    .nitrate_row_width_m = nitrate_row_width_m,
                    .phosphate_application = phosphate_application,
                    .phosphate_row_width_m = phosphate_row_width_m,
                    .salinity_chemistry = if (context.salinity_enabled_by_cell[cell])
                        .enabled
                    else
                        .disabled,
                    .layers = layer_properties,
                },
                &nitrate_geometry_for_update,
                &nitrate_pools,
                &phosphate_geometry_for_update,
                &phosphate_pools,
            );
        }
    }
}

noinline fn publishHourlyChemistry(
    context: anytype,
    fertilizer_band_hour: ecosys.fertilizer_band_phase_coordinator.HourToken,
) !void {
    // ISSUE-065 (seventeenth pass): bracket every call in this function with
    // a direct trace of term 1 (the aqueous/transport-basis dissolved-
    // phosphate `amount_mol`), per the sixteenth addendum's by-elimination
    // proof that the entire hour-2,894 phosphorus residual must live here if
    // it is inside this function at all.
    try diagnostics.tracePhosphateAqueousTransportTermLayer0(context, "before_validate_carrier_volumes");
    try ecosys.soil_aqueous_transport_bridge.validateCarrierVolumesScaled(
        context.micropore_solute_state,
        context.grid.matrix_liquid_water_m3,
        context.config.physical_tolerance.water_volume_m3,
        context.config.physical_tolerance.relative,
    );
    try diagnostics.tracePhosphateAqueousTransportTermLayer0(context, "after_validate_carrier_volumes");
    try context.mineral_nitrogen_transport.refreshMatrixFromReactionState(
        context.soil_chemistry,
        context.soil_reactive_nitrogen,
        context.grid.matrix_liquid_water_m3,
        context.fertilizer_band,
        context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
        context.config.physical_tolerance.water_volume_m3,
    );
    try diagnostics.tracePhosphateAqueousTransportTermLayer0(context, "after_refresh_matrix_from_reaction_state");
    try ecosys.soil_aqueous_transport_bridge.exportChemistry(
        context.soil_chemistry,
        context.micropore_solute_state,
        context.fertilizer_band,
        context.config.physical_tolerance.water_volume_m3,
    );
    try diagnostics.tracePhosphateAqueousTransportTermLayer0(context, "after_export_chemistry");
    try ecosys.fertilizer_band_production.consumeUndissolved(
        context.allocator,
        context.fertilizer_band,
        fertilizer_band_hour,
        context.soil_fertilizer_inventory,
        context.mineral_fertilizer_inventory,
        context.soil_chemistry,
        context.soil_reactive_nitrogen,
        context.salinity_enabled_by_cell,
    );
    try diagnostics.tracePhosphateAqueousTransportTermLayer0(context, "after_consume_undissolved");
}

fn diagnosticPositiveRootNitrogenUptake_g(state_update: anytype) f64 {
    var total_g_n: f64 = 0;
    inline for ([_]usize{ 0, 1, 4, 5 }) |pool| {
        for (state_update.uptake_g_element_per_h_by_nutrient_and_layer[pool]) |amount_g_n| {
            total_g_n += @max(0, amount_g_n);
        }
    }
    return total_g_n;
}

fn remainingAmmoniumConcentration(
    current_mol_per_m3: f64,
    uptake_g_n: f64,
    nitrogen_molar_mass_g_per_mol: f64,
    water_volume_m3: f64,
) !f64 {
    inline for (.{ current_mol_per_m3, nitrogen_molar_mass_g_per_mol, water_volume_m3 }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidRootAmmoniumUptake;
    if (!std.math.isFinite(uptake_g_n)) return error.InvalidRootAmmoniumUptake;
    if (nitrogen_molar_mass_g_per_mol == 0 or water_volume_m3 == 0)
        return error.InvalidRootAmmoniumUptake;
    // Negative exchange is handled as exudation by its recipient path, not as
    // a withdrawal from this ammonium donor.
    if (uptake_g_n <= 0) return current_mol_per_m3;
    const next = current_mol_per_m3 - uptake_g_n / (nitrogen_molar_mass_g_per_mol * water_volume_m3);
    if (!std.math.isFinite(next) or next < 0) return error.RootAmmoniumUptakeExceedsPool;
    return next;
}

fn exerciseScratchAllocationFailure(allocator: std.mem.Allocator) !void {
    var scratch = ScratchAllocations.init(allocator);
    defer scratch.deinit();
    _ = try scratch.alloc(u8, 3);
    _ = try scratch.alloc(u16, 5);
    _ = try scratch.alloc(f64, 7);
}

test "hourly chemistry scratch releases partial allocation prefixes" {
    for (0..3) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            exerciseScratchAllocationFailure(failing.allocator()),
        );
    }
}

test "hourly chemistry scratch releases cell scope and owner scope in reverse order" {
    var backing_memory: [256]u8 = undefined;
    var backing = std.heap.FixedBufferAllocator.init(&backing_memory);
    var scratch = ScratchAllocations.init(backing.allocator());
    var scratch_live = true;
    defer if (scratch_live) scratch.deinit();

    _ = try scratch.alloc(u8, 8);
    const cell_mark = scratch.mark();
    const first_cell_allocation = try scratch.alloc(u8, 16);
    _ = try scratch.alloc(u8, 24);
    scratch.releaseTo(cell_mark);

    // FixedBufferAllocator only rewinds its cursor when frees arrive in LIFO
    // order. Reusing this exact address therefore verifies the cleanup order.
    const replacement = try scratch.alloc(u8, 40);
    try std.testing.expectEqual(first_cell_allocation.ptr, replacement.ptr);

    scratch.deinit();
    scratch_live = false;
    try std.testing.expectEqual(@as(usize, 0), backing.end_index);
}

test "hourly chemistry reaches source-volume fallback while per-mass owners remain pending" {
    const soil_mass_megagrams = try hourlyChemistrySoilMass(2, 0, 0.5);
    try std.testing.expectEqual(@as(f64, 0), soil_mass_megagrams);
    try std.testing.expectError(
        error.InvalidHourlySoilChemistryGeometry,
        hourlyChemistrySoilMass(2, -1e-12, 0.5),
    );

    const zones = try ecosys.soil_fertilizer_dissolution.prepareLayerZones(.{
        .water_volume_m3 = 0.5,
        .soil_mass_megagrams = soil_mass_megagrams,
        .soil_volume_m3 = 2,
        .fractions = .{
            .ammonium_non_band = 1,
            .ammonium_band = 0,
            .nitrate_non_band = 1,
            .nitrate_band = 0,
            .phosphate_non_band = 1,
            .phosphate_band = 0,
        },
        .positive_soil_mass_threshold_megagrams = 1e-12,
    });
    try std.testing.expectEqual(@as(f64, 2), zones.whole_layer_normalization_basis);
    try std.testing.expectEqual(
        @as(f64, 4),
        try ecosys.soil_fertilizer_dissolution.normalizationBasisPerWaterVolume(
            zones.whole_layer_normalization_basis,
            0.5,
        ),
    );

    var chemistry = try ecosys.solute_chemistry_state.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    chemistry.pending_carboxyl_bound_hydrogen_mol[0] = 3;
    chemistry.pending_non_band_phosphate_mol[0].deprotonated_site_mol_per_megagram = 5;
    chemistry.pending_non_band_phosphate_mol[0].aluminum_phosphate_solid_mol_per_m3 = 6;
    chemistry.pending_geochemistry_solids_mol[0].gibbsite_solid_mol_per_m3 = 4;
    try chemistry.materializePendingSolids(0, soil_mass_megagrams, 0.5, .{
        .ammonium_non_band = 1,
        .ammonium_band = 0,
        .nitrate_non_band = 1,
        .nitrate_band = 0,
        .phosphate_non_band = 1,
        .phosphate_band = 0,
    });
    // Per-Mg owners cannot be materialized and therefore remain extensive.
    try std.testing.expectEqual(@as(f64, 3), chemistry.pending_carboxyl_bound_hydrogen_mol[0]);
    try std.testing.expectEqual(@as(f64, 5), chemistry.pending_non_band_phosphate_mol[0].deprotonated_site_mol_per_megagram);
    // Water-volume owners become usable by the downstream chemistry exactly once.
    try std.testing.expectEqual(@as(f64, 12), chemistry.non_band_phosphate[0].aluminum_phosphate_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0), chemistry.pending_non_band_phosphate_mol[0].aluminum_phosphate_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 8), chemistry.geochemistry_solids[0].gibbsite_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0), chemistry.pending_geochemistry_solids_mol[0].gibbsite_solid_mol_per_m3);
}

test "root ammonium uptake rejects overdraw instead of clipping" {
    try std.testing.expectEqual(@as(f64, 0.5), try remainingAmmoniumConcentration(1, 7, 14, 1));
    try std.testing.expectEqual(@as(f64, 1), try remainingAmmoniumConcentration(1, -7, 14, 1));
    try std.testing.expectError(error.RootAmmoniumUptakeExceedsPool, remainingAmmoniumConcentration(1, 14.0000000001, 14, 1));
    try std.testing.expectError(error.InvalidRootAmmoniumUptake, remainingAmmoniumConcentration(1, std.math.nan(f64), 14, 1));
}

fn dissolvedCarbonDioxideConcentration(dissolved_co2_g_c: f64, water_volume_m3: f64) !f64 {
    if (!std.math.isFinite(dissolved_co2_g_c) or dissolved_co2_g_c < 0 or
        !std.math.isFinite(water_volume_m3) or water_volume_m3 <= 0)
        return error.InvalidHourlySoilChemistryDissolvedCarbonDioxide;
    const concentration_mol_per_m3 = dissolved_co2_g_c / (12.0 * water_volume_m3);
    if (!std.math.isFinite(concentration_mol_per_m3) or concentration_mol_per_m3 < 0)
        return error.InvalidHourlySoilChemistryDissolvedCarbonDioxide;
    return concentration_mol_per_m3;
}

test "dissolved carbon dioxide rejects invalid mass instead of clipping" {
    try std.testing.expectEqual(@as(f64, 0.5), try dissolvedCarbonDioxideConcentration(12, 2));
    try std.testing.expectError(error.InvalidHourlySoilChemistryDissolvedCarbonDioxide, dissolvedCarbonDioxideConcentration(-1e-30, 1));
    try std.testing.expectError(error.InvalidHourlySoilChemistryDissolvedCarbonDioxide, dissolvedCarbonDioxideConcentration(std.math.nan(f64), 1));
    try std.testing.expectError(error.InvalidHourlySoilChemistryDissolvedCarbonDioxide, dissolvedCarbonDioxideConcentration(1, 0));
}
