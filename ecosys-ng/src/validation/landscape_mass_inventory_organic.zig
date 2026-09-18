//! `landscape_mass_inventory` declarations: organic.
//!
//! Split out of `landscape_mass_inventory.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const snow = @import("../soil/solute/snow_solute_transport.zig");
const grid_module = @import("../state/grid.zig");
const gas = @import("../soil/gas/transport.zig");
const organic = @import("../soil/organic/initialization.zig");
const organic_transport = @import("../soil/organic/transport.zig");
const litter_chemistry = @import("../surface/litter_chemistry.zig");
const litter_fertilizer = @import("../surface/litter_fertilizer.zig");
const audit = @import("mass_balance_audit.zig");
const surface_precipitation = @import("../surface/precipitation.zig");
const canopy_retention = @import("../canopy/energy/precipitation_retention.zig");
const mineral_nitrogen = @import("../soil/biogeochemistry/mineral_nitrogen_transport.zig");
const nitrogen_fertilizer = @import("../management/fertilizer_nitrogen_inventory.zig");
const mineral_fertilizer = @import("../management/mineral_fertilizer_inventory.zig");
const soil_chemistry = @import("../soil/solute/chemistry_state.zig");
const solute_transport = @import("../soil/solute/transport.zig");
const solute_species = @import("../soil/solute/transport_species.zig");
const zone_classification = @import("../soil/solute/charge_classification.zig");
const plant_roots = @import("../plant/root/plant_root_system.zig");
const group_support = @import("landscape_mass_inventory_support.zig");

/// REDIST surface `DC/DN/DP + DCC/DNC/DPC` reconstruction. The resulting
/// values all belong to the EXEC residue category (`TLRSD*`), including
/// surface microbial biomass and fire-derived charcoal. The strict hourly
/// all-storage census includes every persistent surface-organic pool. In
/// particular, particulate/humus mobile pools and humus-associated microbial
/// biomass are live owners consumed by surface metabolism even though the
/// legacy aggregate selected a smaller reporting subset.
pub fn aggregateSurfaceOrganic(
    state: *const organic.State,
) !group_support.Storage {
    return aggregateSurfaceOrganicRange(state, 0, state.layer_count);
}

pub fn aggregateSurfaceOrganicCell(
    state: *const organic.State,
    cell: usize,
) !group_support.Storage {
    if (cell >= state.layer_count) return error.SurfaceOrganicInventoryCellOutOfBounds;
    return aggregateSurfaceOrganicRange(state, cell, cell + 1);
}

fn aggregateSurfaceOrganicRange(
    state: *const organic.State,
    first_cell: usize,
    end_cell: usize,
) !group_support.Storage {
    const expected_microbial = try group_support.product(&.{
        state.layer_count,
        organic.microbial_substrate_count,
        organic.microbial_population_count,
        organic.kinetic_fraction_count,
    });
    const expected_residue = try group_support.product(&.{
        state.layer_count,
        organic.substrate_count,
        organic.residue_fraction_count,
    });
    const expected_mobile = try group_support.product(&.{
        state.layer_count,
        organic.substrate_count,
    });
    const expected_structural = try group_support.product(&.{
        state.layer_count,
        organic.substrate_count,
        organic.structural_fraction_count,
    });
    if (state.microbial.len != expected_microbial or
        state.residue.len != expected_residue or
        state.dissolved.len != expected_mobile or
        state.adsorbed.len != expected_mobile or
        state.dissolved_acetate_carbon_g_c.len != expected_mobile or
        state.adsorbed_acetate_carbon_g_c.len != expected_mobile or
        state.structural.len != expected_structural or
        state.colonized_structural_carbon_g_c.len != expected_structural)
        return error.SurfaceOrganicInventoryDimensionMismatch;

    var result: group_support.Storage = .{};
    for (first_cell..end_cell) |cell| {
        // The runtime surface metabolism owns all six microbial substrates.
        // Excluding K=4 here made transfers into or out of that live pool look
        // like landscape C/N/P creation or loss.
        for (0..organic.microbial_substrate_count) |substrate| {
            const first =
                (cell * organic.microbial_substrate_count + substrate) *
                organic.microbial_population_count *
                organic.kinetic_fraction_count;
            const count =
                organic.microbial_population_count *
                organic.kinetic_fraction_count;
            for (state.microbial[first .. first + count]) |pool|
                try group_support.addResiduePool(&result, pool);
        }

        // Persistent residue, dissolved, adsorbed and acetate owners span all
        // five surface substrates. K=3..4 are not reporting-only mirrors.
        for (0..organic.substrate_count) |substrate| {
            const residue_first =
                (cell * organic.substrate_count + substrate) *
                organic.residue_fraction_count;
            for (state.residue[residue_first .. residue_first + organic.residue_fraction_count]) |pool| try group_support.addResiduePool(&result, pool);
            const mobile = cell * organic.substrate_count + substrate;
            try group_support.addResiduePool(&result, state.dissolved[mobile]);
            try group_support.addResiduePool(&result, state.adsorbed[mobile]);
            try group_support.addResidueCarbon(
                &result,
                state.dissolved_acetate_carbon_g_c[mobile],
            );
            try group_support.addResidueCarbon(
                &result,
                state.adsorbed_acetate_carbon_g_c[mobile],
            );
        }

        // OSC M=1..5, K=0..4. Fraction 5 is charcoal but remains TLRSD*.
        const structural_first =
            cell * organic.substrate_count * organic.structural_fraction_count;
        const structural_count =
            organic.substrate_count * organic.structural_fraction_count;
        for (state.structural[structural_first .. structural_first + structural_count]) |pool| try group_support.addResiduePool(&result, pool);
    }
    result.diagnostic_surface_organic_carbon_g =
        result.residue_carbon_g + result.organic_carbon_g;
    try result.validate();
    return result;
}

/// REDIST mineral-profile `DC/OC` split. Substrate K=4 is humus and enters
/// `TLORG*`; all other substrates enter `TLRSD*`. Unlike the surface block,
/// profile residue/mobile pools span K=0..4. Only runtime-active layers are
/// accepted as authoritative profile storage.
pub fn aggregateSoilOrganic(
    state: *const organic.State,
    grid: *const grid_module.GridState,
) !group_support.Storage {
    return aggregateSoilOrganicRange(state, grid, 0, grid.cell_count, null);
}

pub fn aggregateSoilOrganicCell(
    state: *const organic.State,
    grid: *const grid_module.GridState,
    cell: usize,
) !group_support.Storage {
    if (cell >= grid.cell_count) return error.SoilOrganicInventoryCellOutOfBounds;
    return aggregateSoilOrganicRange(state, grid, cell, cell + 1, null);
}

pub fn aggregateSoilOrganicLayer(
    state: *const organic.State,
    grid: *const grid_module.GridState,
    cell: usize,
    layer: usize,
) !group_support.Storage {
    if (cell >= grid.cell_count or layer >= grid.soil_layer_capacity)
        return error.SoilOrganicInventoryCellOutOfBounds;
    return aggregateSoilOrganicRange(state, grid, cell, cell + 1, layer);
}

fn aggregateSoilOrganicRange(
    state: *const organic.State,
    grid: *const grid_module.GridState,
    first_cell: usize,
    end_cell: usize,
    local_layer_filter: ?usize,
) !group_support.Storage {
    if (state.layer_count != grid.layer_count or
        grid.layer_count !=
            try std.math.mul(usize, grid.cell_count, grid.soil_layer_capacity) or
        grid.active_soil_layer_count.len != grid.cell_count)
        return error.SoilOrganicInventoryDimensionMismatch;
    try group_support.validateOrganicDimensions(state, error.SoilOrganicInventoryDimensionMismatch);

    var result: group_support.Storage = .{};
    for (first_cell..end_cell) |cell| {
        const active_layers = grid.active_soil_layer_count[cell];
        if (active_layers > grid.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        const first_layer = if (local_layer_filter) |layer| @min(layer, active_layers) else 0;
        const end_layer = if (local_layer_filter) |layer| @min(layer + 1, active_layers) else active_layers;
        for (first_layer..end_layer) |layer| {
            const layer_cell = cell * grid.soil_layer_capacity + layer;
            for (0..organic.microbial_substrate_count) |substrate| {
                const first =
                    (layer_cell * organic.microbial_substrate_count + substrate) *
                    organic.microbial_population_count *
                    organic.kinetic_fraction_count;
                const count =
                    organic.microbial_population_count *
                    organic.kinetic_fraction_count;
                for (state.microbial[first .. first + count]) |pool| {
                    if (substrate == 4)
                        try group_support.addOrganicPool(&result, pool)
                    else
                        try group_support.addResiduePool(&result, pool);
                }
            }
            for (0..organic.substrate_count) |substrate| {
                const is_humus = substrate == 4;
                const residue_first =
                    (layer_cell * organic.substrate_count + substrate) *
                    organic.residue_fraction_count;
                for (state.residue[residue_first .. residue_first + organic.residue_fraction_count]) |pool| {
                    if (is_humus)
                        try group_support.addOrganicPool(&result, pool)
                    else
                        try group_support.addResiduePool(&result, pool);
                }
                const mobile = layer_cell * organic.substrate_count + substrate;
                if (is_humus) {
                    try group_support.addOrganicPool(&result, state.dissolved[mobile]);
                    try group_support.addOrganicPool(&result, state.adsorbed[mobile]);
                    try group_support.addOrganicCarbon(
                        &result,
                        state.dissolved_acetate_carbon_g_c[mobile],
                    );
                    try group_support.addOrganicCarbon(
                        &result,
                        state.adsorbed_acetate_carbon_g_c[mobile],
                    );
                } else {
                    try group_support.addResiduePool(&result, state.dissolved[mobile]);
                    try group_support.addResiduePool(&result, state.adsorbed[mobile]);
                    try group_support.addResidueCarbon(
                        &result,
                        state.dissolved_acetate_carbon_g_c[mobile],
                    );
                    try group_support.addResidueCarbon(
                        &result,
                        state.adsorbed_acetate_carbon_g_c[mobile],
                    );
                }
                const structural_first =
                    (layer_cell * organic.substrate_count + substrate) *
                    organic.structural_fraction_count;
                for (state.structural[structural_first .. structural_first + organic.structural_fraction_count]) |pool| {
                    if (is_humus)
                        try group_support.addOrganicPool(&result, pool)
                    else
                        try group_support.addResiduePool(&result, pool);
                }
            }
        }
    }
    try result.validate();
    return result;
}

/// TRNSFR macropore DOC/acetate that persists between transport steps.
/// After `importMicroporeIntoProfile` the micropore amounts are in
/// `profile.dissolved` and counted by `aggregateSoilOrganic`. The macropore
/// amounts remain in the transport state and must be counted here to close the
/// EXEC carbon (and N/P) balance.
pub fn aggregateSoilOrganicTransportMacropore(
    transport: *const organic_transport.State,
    grid: *const grid_module.GridState,
) !group_support.Storage {
    return aggregateSoilOrganicTransportMacroporeRange(transport, grid, 0, grid.cell_count, null);
}

pub fn aggregateSoilOrganicTransportMacroporeCell(
    transport: *const organic_transport.State,
    grid: *const grid_module.GridState,
    cell: usize,
) !group_support.Storage {
    if (cell >= grid.cell_count) return error.SoilOrganicTransportInventoryCellOutOfBounds;
    return aggregateSoilOrganicTransportMacroporeRange(transport, grid, cell, cell + 1, null);
}

pub fn aggregateSoilOrganicTransportMacroporeLayer(
    transport: *const organic_transport.State,
    grid: *const grid_module.GridState,
    cell: usize,
    layer: usize,
) !group_support.Storage {
    if (cell >= grid.cell_count or layer >= grid.soil_layer_capacity)
        return error.SoilOrganicTransportInventoryCellOutOfBounds;
    return aggregateSoilOrganicTransportMacroporeRange(transport, grid, cell, cell + 1, layer);
}

fn aggregateSoilOrganicTransportMacroporeRange(
    transport: *const organic_transport.State,
    grid: *const grid_module.GridState,
    first_cell: usize,
    end_cell: usize,
    local_layer_filter: ?usize,
) !group_support.Storage {
    const layer_count = try std.math.mul(usize, grid.cell_count, grid.soil_layer_capacity);
    if (transport.layer_count != layer_count or
        grid.active_soil_layer_count.len != grid.cell_count or
        transport.macropore_amount_g.len !=
            try std.math.mul(usize, layer_count, organic_transport.component_count))
        return error.SoilOrganicTransportInventoryDimensionMismatch;

    var result: group_support.Storage = .{};
    for (first_cell..end_cell) |cell| {
        const active_layers = grid.active_soil_layer_count[cell];
        if (active_layers > grid.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        const first_layer = if (local_layer_filter) |layer| @min(layer, active_layers) else 0;
        const end_layer = if (local_layer_filter) |layer| @min(layer + 1, active_layers) else active_layers;
        for (first_layer..end_layer) |local_layer| {
            const flat_layer = cell * grid.soil_layer_capacity + local_layer;
            for (0..organic.substrate_count) |substrate| {
                const base =
                    flat_layer * organic_transport.component_count +
                    substrate * organic_transport.components_per_substrate;
                const doc_g_c = transport.macropore_amount_g[base + @intFromEnum(organic_transport.Component.dissolved_organic_carbon)];
                const don_g_n = transport.macropore_amount_g[base + @intFromEnum(organic_transport.Component.dissolved_organic_nitrogen)];
                const dop_g_p = transport.macropore_amount_g[base + @intFromEnum(organic_transport.Component.dissolved_organic_phosphorus)];
                const acetate_g_c = transport.macropore_amount_g[base + @intFromEnum(organic_transport.Component.dissolved_acetate_carbon)];
                inline for (.{ doc_g_c, don_g_n, dop_g_p, acetate_g_c }) |value| {
                    if (!std.math.isFinite(value))
                        return error.NonFiniteSoilOrganicTransportInventory;
                    if (value < 0) return error.NegativeSoilOrganicTransportInventory;
                }
                if (substrate == organic.substrate_count - 1) {
                    result.organic_carbon_g += doc_g_c + acetate_g_c;
                    result.organic_nitrogen_g += don_g_n;
                    result.organic_phosphorus_g += dop_g_p;
                } else {
                    result.residue_carbon_g += doc_g_c + acetate_g_c;
                    result.residue_nitrogen_g += don_g_n;
                    result.residue_phosphorus_g += dop_g_p;
                }
            }
        }
    }
    try result.validate();
    return result;
}
