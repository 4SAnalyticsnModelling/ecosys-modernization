//! `hourly_science` declarations: support.
//!
//! Split out of `hourly_science.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const ecosys = @import("ecosys_ng");
const biogeochemistry_batches = @import("biogeochemistry_batches.zig");
const diagnostics = @import("diagnostics.zig");
const plant_daily = @import("plant_daily.zig");
const root_processes = @import("root_processes.zig");
const soil_chemistry_convergence = @import("soil_chemistry_convergence.zig");
const surface_litter_convergence = @import("surface_litter_convergence.zig");
const tile_kernels = @import("tile_kernels.zig");

pub fn ensureCanopyGrowthNodeTopology(canopy: *ecosys.canopy_photosynthesis.State, growth_stages: *const ecosys.plant_growth_stages.State, samples_per_node: usize) !void {
    if (samples_per_node == 0 or growth_stages.branches.len != canopy.branch_node_offsets.len - 1) return error.CanopyGrowthTopologyDimensionMismatch;
    for (growth_stages.branches, 0..) |stage, branch| {
        const desired_node_count = try std.math.add(usize, stage.newest_growing_leaf_ordinal, 1);
        while (true) {
            const nodes = try canopy.nodeRange(branch);
            if (nodes.end - nodes.first >= desired_node_count) break;
            _ = try canopy.appendNode(branch, samples_per_node);
        }
    }
}

pub fn diagnosticGasNitrogen_g(state: *const ecosys.gas_transport.State) !f64 {
    var total_g_n: f64 = 0;
    inline for (.{ ecosys.gas_transport.Species.nitrogen, .nitrous_oxide, .ammonia }) |species| {
        for (0..state.cell_count) |layer| {
            const index = try ecosys.gas_transport.massIndex(layer, species, state.cell_count);
            total_g_n += state.gaseous_mass_g[index] + state.dissolved_mass_g[index] +
                state.macropore_dissolved_mass_g[index] + state.band_dissolved_mass_g[index];
        }
    }
    if (!std.math.isFinite(total_g_n)) return error.NonFiniteDiagnosticGasNitrogen;
    return total_g_n;
}

pub fn snowpackInternalNonSaltFluxFromSpeciesAmounts(
    amounts: []const f64,
) ecosys.snowpack_internal_solute_aggregation.SoluteFlux {
    return .{
        .carbon_dioxide_g_c_per_step = amounts[@intFromEnum(ecosys.snow_solute_transport.Species.carbon_dioxide_carbon)],
        .methane_g_c_per_step = amounts[@intFromEnum(ecosys.snow_solute_transport.Species.methane_carbon)],
        .oxygen_g_o_per_step = amounts[@intFromEnum(ecosys.snow_solute_transport.Species.oxygen)],
        .dinitrogen_g_n_per_step = amounts[@intFromEnum(ecosys.snow_solute_transport.Species.dinitrogen_nitrogen)],
        .nitrous_oxide_g_n_per_step = amounts[@intFromEnum(ecosys.snow_solute_transport.Species.nitrous_oxide_nitrogen)],
        .ammonium_g_n_per_step = amounts[@intFromEnum(ecosys.snow_solute_transport.Species.ammonium_nitrogen)],
        .ammonia_g_n_per_step = amounts[@intFromEnum(ecosys.snow_solute_transport.Species.ammonia_nitrogen)],
        .nitrate_g_n_per_step = amounts[@intFromEnum(ecosys.snow_solute_transport.Species.nitrate_nitrogen)],
        .hydrogen_phosphate_g_p_per_step = amounts[@intFromEnum(ecosys.snow_solute_transport.Species.hydrogen_phosphate_phosphorus)],
        .dihydrogen_phosphate_g_p_per_step = amounts[@intFromEnum(ecosys.snow_solute_transport.Species.dihydrogen_phosphate_phosphorus)],
    };
}
