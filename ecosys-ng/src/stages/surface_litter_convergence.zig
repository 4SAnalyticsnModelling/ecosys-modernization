//! Surface litter chemistry convergence and its denitrification map.
//!
//! Extracted verbatim from `ecosys_ng.zig` so the entry point holds only
//! `main`. Declaration bodies are unchanged.

const std = @import("std");
const ecosys = @import("ecosys_ng");
const tile_kernels = @import("tile_kernels.zig");
pub const SurfaceDenitrificationRespirationMap = struct {
    destination_g_c: []f64,
    source_g_c: []const f64,
};

pub fn mapSurfaceDenitrificationRespiration(
    context: *SurfaceDenitrificationRespirationMap,
    cells: ecosys.compute.CellRange,
) !void {
    for (cells.first..cells.end) |cell| {
        for (0..ecosys.surface_microbial_respiration_step.litter_complex_count) |complex| {
            const compact =
                cell * ecosys.surface_microbial_respiration_step.litter_complex_count +
                complex;
            const unit =
                cell * ecosys.surface_microbial_respiration_step.unit_count_per_cell +
                complex *
                    ecosys.surface_microbial_respiration_step.source_population_count +
                ecosys.surface_denitrification_step.denitrifier_population;
            context.destination_g_c[unit] = context.source_g_c[compact];
        }
    }
}

pub fn convergeSurfaceLitterChemistry(context: anytype) !void {
    {
        const reaction_parameters = context.chemistry_reaction_parameters.*;
        context.surface_litter_chemistry_diagnostics.reset();
        var litter_chemistry_context: ecosys.surface_litter_chemistry_step.ApplyContext = .{
            .state = context.surface_litter_chemistry,
            .surface_organic = context.surface_organic,
            .litter_water_m3 = context.surface_precipitation.litter_water_m3,
            .chemistry_parameters = reaction_parameters,
            .cation_selectivity_by_cell = context.surface_litter_cation_selectivity,
            .litter_dry_mass_megagrams = context.surface_litter_geometry.dry_mass_megagrams,
            .salinity_enabled_by_cell = context.salinity_enabled_by_cell,
            .solver_options = .{
                .absolute_tolerance_mol_per_m3 = context.config.nonlinear_tolerance.reaction_mol_per_m3,
                .absolute_tolerance_mol_per_megagram = context.config.nonlinear_tolerance.reaction_mol_per_megagram,
                .relative_tolerance = context.config.nonlinear_tolerance.relative,
                .picard_relaxation = context.config.picard_relaxation,
                // Retained for shared option validation and non-hourly solver
                // callers. The production surface-litter SOLUTE path applies
                // one undivided hourly ledger in both salt modes; it has no
                // MRXN equilibrium loop.
                .max_iterations = context.iteration_limits.initial_solute_reaction_max_iterations,
            },
            .diagnostics = context.surface_litter_chemistry_diagnostics,
        };
        // Gas state owns aqueous CO2 storage; chemistry only proposes changes
        // to it. Reconcile before solving, or chemistry spends a stock that gas
        // transport has already drained. See
        // SURFACE-LITTER-CO2-DUAL-INVENTORY-001.
        try ecosys.surface_litter_chemistry_step.seedCarbonDioxideFromGasInventory(
            context.surface_litter_chemistry,
            context.litter_gas_transport,
            context.surface_precipitation.litter_water_m3,
            12,
            context.config.physical_tolerance.water_volume_m3,
        );
        try tile_kernels.runKernelAcrossSerialTiles(context, &litter_chemistry_context, ecosys.surface_litter_chemistry_step.applyTile);
        // The returned value is the carbon the negligibility floor created. It
        // is bound, not discarded with `_ =`: a discarded return is exactly how
        // the stage census once reported 346 tillage applications per hour that
        // never happened. The callee logs the magnitude, and the amount is
        // bounded by `physical_tolerance.carbon_g` per cell per hour -- 2.6e-5
        // g C over the whole 30-year horizon for a one-cell deck. A dedicated
        // ledger line, modelled on
        // `diagnostic_litter_soil_organic_heat_rebase_megajoules`, is the
        // follow-up tracked as SURFACE-LITTER-CO2-FLOOR-UNLEDGERED-001.
        const floor_created_carbon_g_c = try ecosys.surface_litter_chemistry_step.publishAcceptedCarbonDioxideChanges(
            context.litter_gas_transport,
            context.surface_litter_chemistry_diagnostics,
            12,
            context.config.physical_tolerance.carbon_g,
            context.config.physical_tolerance.relative,
        );
        if (!std.math.isFinite(floor_created_carbon_g_c) or floor_created_carbon_g_c < 0)
            return error.InvalidLitterCarbonDioxideFloorAccounting;
    }
}
