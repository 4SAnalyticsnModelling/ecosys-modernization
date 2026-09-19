const std = @import("std");
const settling = @import("../redistribution/pond/particulate_settling.zig");
const inventory = @import("pond_inventory_transfer.zig");
const chemistry = @import("pond_chemistry_transfer.zig");
const surface_chemistry_module = @import("litter_chemistry.zig");
const soil_chemistry_module = @import("../soil/solute/chemistry_state.zig");
const transition = @import("pond_transition_step.zig");
const suspended_constituents = @import("../erosion/suspended_constituents.zig");
const organic_layer_remap = @import("../soil/organic/layer_remap.zig");
const fertilizer_layer_remap = @import("../soil/nutrients/fertilizer_layer_remap.zig");
const mineral_layer_remap = @import("../soil/nutrients/mineral_layer_remap.zig");
const chemistry_layer_remap = @import("../soil/chemistry/layer_remap.zig");
const soil_properties_module = @import("../soil/water/solver_properties.zig");
const charge_classification = @import("../soil/solute/charge_classification.zig");
const conservation_sidecar = @import("pond_conservation_sidecar.zig");
const legacy_water_negligible_floor = @import("../core/legacy_water_negligible_floor.zig");

pub const SeparatedSurfaceGeometry = settling.SeparatedSurfaceGeometry;
pub const MineralColumnGeometry = settling.MineralColumnGeometry;

pub const MineralSedimentOwners = struct {
    /// EROSION SED is not a REDIST L=0 particulate owner. Retained here only
    /// while callers migrate; this transaction validates but never mutates it.
    surface_sediment_megagrams: []f64,
    /// EROSION's surface-soil carrier likewise remains outside this transaction.
    surface_soil_mass_megagrams: []f64,
    /// Hourly REDIST TSEDSK diagnostic. L=0 contributes zero because source
    /// TSEDSK is incremented only by L>0 SAND/SILT/CLAY (`redist.f:359--378`).
    settled_sediment_megagrams: []f64,
    /// Legacy EROSION-attached arguments are accepted for ABI/source migration
    /// but intentionally left untouched by the REDIST L=0 transaction.
    suspended_constituents: ?*suspended_constituents.State = null,
    receiving_topsoil_constituent_pools: ?[]f64 = null,
    /// Exact accepted surface->actual-receiver activity. Optional only for
    /// narrow unit callers; the production stage binds its persistent pond
    /// workspace sidecar.
    accepted_sidecar: ?conservation_sidecar.CellSidecar = null,
    accepted_soil_layer_sidecar: ?conservation_sidecar.SoilLayerSidecar = null,
};

pub const ParticulateChemistryOwners = struct {
    surface: *surface_chemistry_module.State,
    soil: *soil_chemistry_module.State,
    surface_dry_mass_megagrams: []const f64,
    soil_dry_mass_megagrams: []f64,
    soil_matrix_water_m3: []const f64,
    /// issue-064 sibling: `ZEROS2(NY,NX)=ZERO2*DH(NY,NX)*DV(NY,NX)`
    /// (`starts.f:270`) per-cell footprint, used to floor
    /// `soil_matrix_water_m3` before it carries `transferPondParticulateLayerFraction`'s
    /// water-normalized solid/precipitate concentrations, exactly like
    /// issue-063's fix for `relayering.zig`'s sibling call to the same
    /// underlying `transferSolidLayerFraction`.
    cell_area_m2: []const f64,
    ammonium_non_band_fraction_by_cell: []const f64,
    phosphate_non_band_water_fraction_by_cell: []const f64,
    /// Required by the production path to settle L>0 SAND/SILT/CLAY and
    /// XCEC/XAEC. Optional only for narrow L0-only unit callers.
    soil_properties: ?*soil_properties_module.State = null,
    /// Cell-layer zone carriers for conservative L>0 solid chemistry.
    zone_fractions_by_layer: []const charge_classification.ZoneFractions = &.{},
};

/// Faithful separated-surface boundary for REDIST (`redist.f` lines 333--614).
/// Settling eligibility comes only from donor/receiver geometry and never from
/// retention transition state. A domain-wide preflight preserves atomic failure.
pub fn applyWithGeometry(
    owners: inventory.Owners,
    mineral_sediment: MineralSedimentOwners,
    geometry: settling.SeparatedSurfaceGeometry,
    timestep_h: f64,
) !void {
    try applyInternal(owners, null, mineral_sediment, geometry, timestep_h);
}

/// Complete separated-surface REDIST settling transaction.  Chemistry is
/// preflighted across the whole domain before any inventory, sediment, or
/// chemistry owner changes.
pub fn applyWithChemistryAndGeometry(
    owners: inventory.Owners,
    chemistry_owners: ParticulateChemistryOwners,
    mineral_sediment: MineralSedimentOwners,
    geometry: settling.SeparatedSurfaceGeometry,
    timestep_h: f64,
) !void {
    try applyInternal(owners, chemistry_owners, mineral_sediment, geometry, timestep_h);
}

/// Exposes the exact validated REDIST receiver selection to the production
/// caller so it can pack the same runtime layer that the atomic transaction
/// will mutate. This avoids silently packing the first terrestrial topsoil
/// when an open-water layer or a skipped thin layer is the actual receiver.
pub fn receivingLayer(
    geometry: settling.SeparatedSurfaceGeometry,
    cell: usize,
) !?usize {
    const eligibility = try settling.SeparatedSurfaceEligibility.init(geometry);
    return eligibility.receiver(cell);
}

pub fn firstMineralLayer(
    geometry: settling.MineralColumnGeometry,
    cell: usize,
) !usize {
    return settling.firstMineralLayer(geometry, cell);
}

fn applyInternal(
    owners: inventory.Owners,
    chemistry_owners: ?ParticulateChemistryOwners,
    mineral_sediment: MineralSedimentOwners,
    geometry: settling.SeparatedSurfaceGeometry,
    timestep_h: f64,
) !void {
    const fraction = try settling.settlingFraction(.{ .timestep_h = timestep_h });
    const eligibility = try settling.SeparatedSurfaceEligibility.init(geometry);
    if (geometry.cell_count != owners.surface_organic.layer_count or
        mineral_sediment.surface_sediment_megagrams.len != geometry.cell_count or
        mineral_sediment.surface_soil_mass_megagrams.len != geometry.cell_count or
        mineral_sediment.settled_sediment_megagrams.len != geometry.cell_count)
        return error.SurfacePondSettlingDimensionMismatch;
    const attached_state = mineral_sediment.suspended_constituents;
    const attached_topsoil = mineral_sediment.receiving_topsoil_constituent_pools;
    if ((attached_state == null) != (attached_topsoil == null))
        return error.SurfacePondSettlingDimensionMismatch;
    if (attached_state) |state| {
        const topsoil = attached_topsoil.?;
        if (state.cell_count != geometry.cell_count or
            state.sediment_megagrams.ptr != mineral_sediment.surface_sediment_megagrams.ptr or
            topsoil.len != state.pools.len)
            return error.SurfacePondSettlingDimensionMismatch;
    }
    if (mineral_sediment.accepted_sidecar) |sidecar|
        try sidecar.validateDimensions(geometry.cell_count);
    if (mineral_sediment.accepted_soil_layer_sidecar) |sidecar|
        try sidecar.validateDimensions(try std.math.mul(usize, geometry.cell_count, geometry.soil_layer_capacity));
    if (chemistry_owners) |chemistry_owner| {
        const soil_count = std.math.mul(usize, geometry.cell_count, geometry.soil_layer_capacity) catch
            return error.SurfacePondSettlingChemistryDimensionMismatch;
        if (chemistry_owner.surface.cells.len != geometry.cell_count or
            chemistry_owner.surface_dry_mass_megagrams.len != geometry.cell_count or
            chemistry_owner.soil.cell_count != soil_count or
            chemistry_owner.soil_dry_mass_megagrams.len != soil_count or
            chemistry_owner.soil_matrix_water_m3.len != soil_count or
            chemistry_owner.cell_area_m2.len != geometry.cell_count or
            chemistry_owner.ammonium_non_band_fraction_by_cell.len != geometry.cell_count or
            chemistry_owner.phosphate_non_band_water_fraction_by_cell.len != geometry.cell_count)
            return error.SurfacePondSettlingChemistryDimensionMismatch;
        if ((chemistry_owner.soil_properties == null) != (chemistry_owner.zone_fractions_by_layer.len == 0))
            return error.SurfacePondSettlingChemistryDimensionMismatch;
        if (chemistry_owner.soil_properties) |properties| {
            if (properties.layer_count != soil_count or chemistry_owner.zone_fractions_by_layer.len != soil_count)
                return error.SurfacePondSettlingChemistryDimensionMismatch;
        }
        for (0..geometry.cell_count) |cell| {
            inline for (.{
                chemistry_owner.ammonium_non_band_fraction_by_cell[cell],
                chemistry_owner.phosphate_non_band_water_fraction_by_cell[cell],
            }) |zone_fraction| if (!std.math.isFinite(zone_fraction) or zone_fraction <= 0 or zone_fraction > 1)
                return error.InvalidSurfacePondChemistryCarrier;
        }
    }

    // Domain preflight of every represented L>0 water-column donor occurs
    // before any owner changes. Commit retains REDIST's deepest-first order.
    for (0..geometry.cell_count) |cell| {
        const first = geometry.surface_soil_layer_by_cell[cell];
        const end = first + geometry.active_soil_layer_count_by_cell[cell];
        var source = end - 1;
        while (source > first) {
            source -= 1;
            const destination = (try eligibility.soilReceiver(cell, source)) orelse continue;
            try validateWaterColumnMove(owners, chemistry_owners, geometry, cell, source, destination, fraction);
        }
    }

    for (0..geometry.cell_count) |cell| {
        const suspended = mineral_sediment.surface_sediment_megagrams[cell];
        const soil = mineral_sediment.surface_soil_mass_megagrams[cell];
        const previous_diagnostic = mineral_sediment.settled_sediment_megagrams[cell];
        if (!std.math.isFinite(suspended) or suspended < 0 or
            !std.math.isFinite(soil) or soil < 0 or
            !std.math.isFinite(previous_diagnostic) or previous_diagnostic < 0)
            return error.InvalidSurfacePondSedimentInventory;
        const destination_soil_layer = try eligibility.receiver(cell) orelse continue;
        try inventory.validateParticulateFractionToSoil(owners, .{
            .cell = cell,
            .destination_soil_layer = destination_soil_layer,
            .fraction = fraction,
        });
        if (chemistry_owners) |chemistry_owner| {
            const destination = cell * geometry.soil_layer_capacity + destination_soil_layer;
            try chemistry.validateParticulateFractionToSoil(
                chemistry_owner.surface,
                chemistry_owner.soil,
                cell,
                destination,
                try particulateCarriers(chemistry_owner, cell, destination),
                fraction,
            );
        }
    }
    // No accepted sidecar is touched until every scientific owner and every
    // receiver in the domain has passed preflight.
    if (mineral_sediment.accepted_sidecar) |sidecar| sidecar.clear();
    if (mineral_sediment.accepted_soil_layer_sidecar) |sidecar| sidecar.clear();
    @memset(mineral_sediment.settled_sediment_megagrams, 0);
    for (0..geometry.cell_count) |cell| {
        const first = geometry.surface_soil_layer_by_cell[cell];
        const end = first + geometry.active_soil_layer_count_by_cell[cell];
        var source = end - 1;
        while (source > first) {
            source -= 1;
            const destination = (eligibility.soilReceiver(cell, source) catch unreachable) orelse continue;
            const source_flat = cell * geometry.soil_layer_capacity + source;
            var accepted = inventory.acceptedSoilParticulateTransfer(owners, cell, source, fraction) catch unreachable;
            if (chemistry_owners) |chemistry_owner| if (chemistry_owner.soil_properties) |properties| {
                const source_mass = chemistry_owner.soil_dry_mass_megagrams[source_flat];
                const source_zone = chemistry_owner.zone_fractions_by_layer[source_flat];
                accepted = accepted.add(chemistry.acceptedSoilParticulateTransfer(
                    chemistry_owner.soil,
                    source_flat,
                    source_mass,
                    chemistry_owner.soil_matrix_water_m3[source_flat],
                    source_zone,
                    fraction,
                ) catch unreachable) catch unreachable;
                accepted = accepted.add(.{
                    .sand_megagrams = fraction * properties.sand_mass_megagrams[source_flat],
                    .silt_megagrams = fraction * properties.silt_mass_megagrams[source_flat],
                    .clay_megagrams = fraction * properties.clay_mass_megagrams[source_flat],
                    .cation_exchange_capacity_mol = fraction * properties.cation_exchange_capacity_mol[source_flat],
                    .anion_exchange_capacity_mol = fraction * properties.anion_exchange_capacity_mol[source_flat],
                }) catch unreachable;
            };
            const deposited = transferWaterColumnMove(owners, chemistry_owners, geometry, cell, source, destination, fraction) catch unreachable;
            if (geometry.soil_bulk_density_megagrams_per_m3[cell * geometry.soil_layer_capacity + destination] > 0)
                mineral_sediment.settled_sediment_megagrams[cell] += deposited;
            if (mineral_sediment.accepted_soil_layer_sidecar) |sidecar| {
                sidecar.destination_soil_layer_by_source[source_flat] = destination;
                sidecar.transfer_by_source[source_flat] = accepted;
                sidecar.active_by_source[source_flat] = true;
            }
        }
    }
    for (0..geometry.cell_count) |cell| {
        const destination_soil_layer = (try eligibility.receiver(cell)) orelse continue;
        var accepted = inventory.acceptedParticulateTransfer(owners, .{
            .cell = cell,
            .destination_soil_layer = destination_soil_layer,
            .fraction = fraction,
        }) catch unreachable;
        if (chemistry_owners) |chemistry_owner| {
            const destination = cell * geometry.soil_layer_capacity + destination_soil_layer;
            accepted = accepted.add(chemistry.acceptedParticulateTransfer(
                chemistry_owner.surface,
                chemistry_owner.soil,
                cell,
                destination,
                particulateCarriers(chemistry_owner, cell, destination) catch unreachable,
                fraction,
            ) catch unreachable) catch unreachable;
        }
        inventory.transferParticulateFractionToSoil(owners, .{
            .cell = cell,
            .destination_soil_layer = destination_soil_layer,
            .fraction = fraction,
        }) catch unreachable;
        if (chemistry_owners) |chemistry_owner| {
            const destination = cell * geometry.soil_layer_capacity + destination_soil_layer;
            chemistry.transferParticulateFractionToSoil(
                chemistry_owner.surface,
                chemistry_owner.soil,
                cell,
                destination,
                particulateCarriers(chemistry_owner, cell, destination) catch unreachable,
                fraction,
            ) catch unreachable;
        }
        if (mineral_sediment.accepted_sidecar) |sidecar| {
            sidecar.destination_soil_layer[cell] = destination_soil_layer;
            sidecar.transfer[cell] = accepted;
            sidecar.active[cell] = true;
        }
    }
}

/// `ZEROS2(NY,NX) = ZERO2*DH(NY,NX)*DV(NY,NX)` (`starts.f:270`). issue-064
/// sibling of issue-063's `relayering.zig` fix: shares the same floor with
/// `chemistry_layer_remap`'s census-side `aqueousCarrierM3` so this file's
/// `transferSolidLayerFraction` call (via `transferPondParticulateLayerFraction`)
/// agrees with the census on the same water-carrier basis for the same
/// degenerate cell/layer.
fn legacyNegligibleWaterVolumeM3(cell_area_m2: f64) f64 {
    return legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(cell_area_m2);
}

/// `solute.f:610` keeps a water-normalized pool represented on the remembered
/// dry reference carrier whenever the live water carrier is at or below the
/// `ZEROS2` noise floor. Mirrors `relayering.zig`'s `solidTransferWaterCarrierM3`
/// exactly (issue-063/064): this file's pond-settling call to
/// `transferPondParticulateLayerFraction` previously received RAW, unfloored
/// live water for both carrier arguments, guarded only by
/// `transferOwnedAmount`'s bare `> 0` check.
fn solidTransferWaterCarrierM3(
    live_water_m3: f64,
    dry_reference_water_m3: f64,
    negligible_water_volume_m3: f64,
) !f64 {
    if (!std.math.isFinite(live_water_m3) or live_water_m3 < 0 or
        !std.math.isFinite(dry_reference_water_m3) or dry_reference_water_m3 < 0 or
        !std.math.isFinite(negligible_water_volume_m3) or negligible_water_volume_m3 < 0)
        return error.InvalidSurfacePondChemistryCarrier;
    return if (live_water_m3 > negligible_water_volume_m3) live_water_m3 else dry_reference_water_m3;
}

test "issue-064 sibling: pond settling's solidTransferWaterCarrierM3 substitutes the dry reference at and below the ZEROS2 floor" {
    // Mirrors `relayering.zig`'s own boundary test for the identical helper
    // (issue-063/064), confirming this file's separate, previously-unaudited
    // `transferPondParticulateLayerFraction` call site (surface pond settling,
    // flagged by issue-063's own disposition as "left for a future pass") now
    // agrees with the census's floored carrier basis instead of passing the
    // raw live water straight through.
    const negligible = legacyNegligibleWaterVolumeM3(1.0);
    try std.testing.expectEqual(@as(f64, 1.0e-6), negligible);
    try std.testing.expectEqual(@as(f64, 0.5), try solidTransferWaterCarrierM3(0, 0.5, negligible));
    try std.testing.expectEqual(@as(f64, 0.5), try solidTransferWaterCarrierM3(negligible, 0.5, negligible));
    const just_above = std.math.nextAfter(f64, negligible, std.math.inf(f64));
    try std.testing.expectEqual(just_above, try solidTransferWaterCarrierM3(just_above, 0.5, negligible));
    try std.testing.expectError(error.InvalidSurfacePondChemistryCarrier, solidTransferWaterCarrierM3(-1, 0.5, negligible));
}

test "issue-064 sibling: pond settling manufactures fake mass with a raw near-zero carrier but conserves mass when floored first" {
    // Direct reproduction at this file's actual mutator
    // (`transferPondParticulateLayerFraction`, via `chemistry_layer_remap`'s
    // shared `transferSolidLayerFraction`), matching the before/after pattern
    // issue-063 used for the sibling `relayering.zig` call site.
    const dry_reference_water_m3: f64 = 0.5;
    const negligible_water_volume_m3 = 1.0e-6; // ZEROS2 for a 1 m^2 cell.
    const raw_recipient_water_m3: f64 = 1.0e-9; // below the floor, nonzero.

    const censusCarrier = struct {
        fn call(live_water_m3: f64) f64 {
            return if (live_water_m3 > negligible_water_volume_m3) live_water_m3 else dry_reference_water_m3;
        }
    }.call;

    // --- OLD (pre-fix) caller behavior: raw, unfloored carrier passed straight through. ---
    {
        var chemistry_state = try soil_chemistry_module.State.init(std.testing.allocator, 2);
        defer chemistry_state.deinit();
        chemistry_state.geochemistry_solids[0].calcite_solid_mol_per_m3 = 100;
        chemistry_state.geochemistry_solids[1].calcite_solid_mol_per_m3 = 0.2;
        const equal_zones: chemistry_layer_remap.ZoneFractionTransition = .{
            .source_before = .{ .ammonium_non_band = 0.5, .ammonium_band = 0.5, .nitrate_non_band = 0.5, .nitrate_band = 0.5, .phosphate_non_band = 0.5, .phosphate_band = 0.5 },
            .destination_before = .{ .ammonium_non_band = 0.5, .ammonium_band = 0.5, .nitrate_non_band = 0.5, .nitrate_band = 0.5, .phosphate_non_band = 0.5, .phosphate_band = 0.5 },
            .source_after = .{ .ammonium_non_band = 0.5, .ammonium_band = 0.5, .nitrate_non_band = 0.5, .nitrate_band = 0.5, .phosphate_non_band = 0.5, .phosphate_band = 0.5 },
            .destination_after = .{ .ammonium_non_band = 0.5, .ammonium_band = 0.5, .nitrate_non_band = 0.5, .nitrate_band = 0.5, .phosphate_non_band = 0.5, .phosphate_band = 0.5 },
        };
        const recipient_census_before = chemistry_state.geochemistry_solids[1].calcite_solid_mol_per_m3 * censusCarrier(raw_recipient_water_m3);
        try chemistry_layer_remap.transferPondParticulateLayerFraction(&chemistry_state, 0, 1, 10, 10, 5.0, raw_recipient_water_m3, equal_zones, 10, 10, 0.001);
        const recipient_census_after = chemistry_state.geochemistry_solids[1].calcite_solid_mol_per_m3 * censusCarrier(raw_recipient_water_m3);
        try std.testing.expect(recipient_census_after - recipient_census_before > 1000 * 0.5);
    }

    // --- NEW (fixed) caller behavior: floors the carrier the same way the census does. ---
    {
        var chemistry_state = try soil_chemistry_module.State.init(std.testing.allocator, 2);
        defer chemistry_state.deinit();
        chemistry_state.geochemistry_solids[0].calcite_solid_mol_per_m3 = 100;
        chemistry_state.geochemistry_solids[1].calcite_solid_mol_per_m3 = 0.2;
        const equal_zones: chemistry_layer_remap.ZoneFractionTransition = .{
            .source_before = .{ .ammonium_non_band = 0.5, .ammonium_band = 0.5, .nitrate_non_band = 0.5, .nitrate_band = 0.5, .phosphate_non_band = 0.5, .phosphate_band = 0.5 },
            .destination_before = .{ .ammonium_non_band = 0.5, .ammonium_band = 0.5, .nitrate_non_band = 0.5, .nitrate_band = 0.5, .phosphate_non_band = 0.5, .phosphate_band = 0.5 },
            .source_after = .{ .ammonium_non_band = 0.5, .ammonium_band = 0.5, .nitrate_non_band = 0.5, .nitrate_band = 0.5, .phosphate_non_band = 0.5, .phosphate_band = 0.5 },
            .destination_after = .{ .ammonium_non_band = 0.5, .ammonium_band = 0.5, .nitrate_non_band = 0.5, .nitrate_band = 0.5, .phosphate_non_band = 0.5, .phosphate_band = 0.5 },
        };
        const floored_recipient_water_m3 = try solidTransferWaterCarrierM3(raw_recipient_water_m3, dry_reference_water_m3, negligible_water_volume_m3);
        const recipient_census_before = chemistry_state.geochemistry_solids[1].calcite_solid_mol_per_m3 * censusCarrier(raw_recipient_water_m3);
        try chemistry_layer_remap.transferPondParticulateLayerFraction(&chemistry_state, 0, 1, 10, 10, 5.0, floored_recipient_water_m3, equal_zones, 10, 10, 0.001);
        const recipient_census_after = chemistry_state.geochemistry_solids[1].calcite_solid_mol_per_m3 * censusCarrier(raw_recipient_water_m3);
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), recipient_census_after - recipient_census_before, 1e-9);
    }
}

fn validateWaterColumnMove(
    owners: inventory.Owners,
    chemistry_owners: ?ParticulateChemistryOwners,
    geometry: settling.SeparatedSurfaceGeometry,
    cell: usize,
    source_layer: usize,
    destination_layer: usize,
    fraction: f64,
) !void {
    const source = cell * geometry.soil_layer_capacity + source_layer;
    const destination = cell * geometry.soil_layer_capacity + destination_layer;
    try organic_layer_remap.validatePondParticulateLayerFraction(owners.soil_organic, source, destination, fraction);
    try fertilizer_layer_remap.validatePondParticulateLayerFraction(owners.soil_nitrogen_fertilizer, cell, source_layer, destination_layer, fraction);
    if (chemistry_owners) |chemistry_owner| if (chemistry_owner.soil_properties) |properties| {
        const source_mass = chemistry_owner.soil_dry_mass_megagrams[source];
        const destination_mass = chemistry_owner.soil_dry_mass_megagrams[destination];
        const moved_mineral = fraction * (properties.sand_mass_megagrams[source] +
            properties.silt_mass_megagrams[source] +
            properties.clay_mass_megagrams[source]);
        const destination_mass_after = if (geometry.soil_bulk_density_megagrams_per_m3[destination] > 0)
            destination_mass + moved_mineral
        else
            destination_mass;
        try mineral_layer_remap.validatePondParticulateLayerFraction(
            properties,
            source,
            destination,
            fraction,
            source_mass,
            destination_mass_after,
        );
        const source_zone = chemistry_owner.zone_fractions_by_layer[source];
        const destination_zone = chemistry_owner.zone_fractions_by_layer[destination];
        const negligible_water_volume_m3 = legacyNegligibleWaterVolumeM3(chemistry_owner.cell_area_m2[cell]);
        const source_water_carrier = try solidTransferWaterCarrierM3(
            chemistry_owner.soil_matrix_water_m3[source],
            chemistry_owner.soil.dry_reference_water_m3[source],
            negligible_water_volume_m3,
        );
        const destination_water_carrier = try solidTransferWaterCarrierM3(
            chemistry_owner.soil_matrix_water_m3[destination],
            chemistry_owner.soil.dry_reference_water_m3[destination],
            negligible_water_volume_m3,
        );
        try chemistry_layer_remap.validatePondParticulateLayerFraction(
            chemistry_owner.soil,
            source,
            destination,
            source_mass,
            destination_mass,
            source_water_carrier,
            destination_water_carrier,
            .{
                .source_before = source_zone,
                .destination_before = destination_zone,
                .source_after = source_zone,
                .destination_after = destination_zone,
            },
            source_mass,
            destination_mass_after,
            fraction,
        );
    };
}

fn transferWaterColumnMove(
    owners: inventory.Owners,
    chemistry_owners: ?ParticulateChemistryOwners,
    geometry: settling.SeparatedSurfaceGeometry,
    cell: usize,
    source_layer: usize,
    destination_layer: usize,
    fraction: f64,
) !f64 {
    const source = cell * geometry.soil_layer_capacity + source_layer;
    const destination = cell * geometry.soil_layer_capacity + destination_layer;
    try organic_layer_remap.transferPondParticulateLayerFraction(owners.soil_organic, source, destination, fraction);
    try fertilizer_layer_remap.transferPondParticulateLayerFraction(owners.soil_nitrogen_fertilizer, cell, source_layer, destination_layer, fraction);
    var deposited_mineral_megagrams: f64 = 0;
    if (chemistry_owners) |chemistry_owner| if (chemistry_owner.soil_properties) |properties| {
        const source_mass = chemistry_owner.soil_dry_mass_megagrams[source];
        const destination_mass = chemistry_owner.soil_dry_mass_megagrams[destination];
        deposited_mineral_megagrams = fraction * (properties.sand_mass_megagrams[source] +
            properties.silt_mass_megagrams[source] +
            properties.clay_mass_megagrams[source]);
        const destination_mass_after = if (geometry.soil_bulk_density_megagrams_per_m3[destination] > 0)
            destination_mass + deposited_mineral_megagrams
        else
            destination_mass;
        try mineral_layer_remap.transferPondParticulateLayerFraction(
            properties,
            source,
            destination,
            fraction,
            source_mass,
            destination_mass_after,
        );
        const source_zone = chemistry_owner.zone_fractions_by_layer[source];
        const destination_zone = chemistry_owner.zone_fractions_by_layer[destination];
        const negligible_water_volume_m3 = legacyNegligibleWaterVolumeM3(chemistry_owner.cell_area_m2[cell]);
        const source_water_carrier = try solidTransferWaterCarrierM3(
            chemistry_owner.soil_matrix_water_m3[source],
            chemistry_owner.soil.dry_reference_water_m3[source],
            negligible_water_volume_m3,
        );
        const destination_water_carrier = try solidTransferWaterCarrierM3(
            chemistry_owner.soil_matrix_water_m3[destination],
            chemistry_owner.soil.dry_reference_water_m3[destination],
            negligible_water_volume_m3,
        );
        try chemistry_layer_remap.transferPondParticulateLayerFraction(
            chemistry_owner.soil,
            source,
            destination,
            source_mass,
            destination_mass,
            source_water_carrier,
            destination_water_carrier,
            .{
                .source_before = source_zone,
                .destination_before = destination_zone,
                .source_after = source_zone,
                .destination_after = destination_zone,
            },
            source_mass,
            destination_mass_after,
            fraction,
        );
        chemistry_owner.soil_dry_mass_megagrams[destination] = destination_mass_after;
    };
    return deposited_mineral_megagrams;
}

fn particulateCarriers(owners: ParticulateChemistryOwners, cell: usize, destination: usize) !chemistry.ParticulateCarriers {
    const soil_water_m3 = owners.soil_matrix_water_m3[destination];
    const phosphate_water_m3 = soil_water_m3 * owners.phosphate_non_band_water_fraction_by_cell[cell];
    const carriers: chemistry.ParticulateCarriers = .{
        .surface_dry_mass_megagrams = owners.surface_dry_mass_megagrams[cell],
        .soil_dry_mass_megagrams = owners.soil_dry_mass_megagrams[destination],
        .soil_exchange_non_band_fraction = owners.ammonium_non_band_fraction_by_cell[cell],
        .soil_phosphate_non_band_fraction = owners.phosphate_non_band_water_fraction_by_cell[cell],
        .surface_mineral_reference_water_m3 = owners.surface.mineral_reference_water_m3[cell],
        .soil_phosphate_non_band_water_m3 = phosphate_water_m3,
    };
    inline for (@typeInfo(chemistry.ParticulateCarriers).@"struct".fields) |field|
        if (!std.math.isFinite(@field(carriers, field.name)))
            return error.InvalidSurfacePondChemistryCarrier;
    if (carriers.surface_dry_mass_megagrams < 0 or
        carriers.surface_mineral_reference_water_m3 < 0 or
        carriers.soil_dry_mass_megagrams < 0 or
        carriers.soil_phosphate_non_band_water_m3 < 0)
        return error.InvalidSurfacePondChemistryCarrier;
    return carriers;
}

test "REDIST L0 settles surface particulates without consuming EROSION suspension" {
    const organic = @import("../soil/organic/initialization.zig");
    const gas = @import("../soil/gas/transport.zig");
    const surface_fertilizer = @import("litter_fertilizer.zig");
    const soil_fertilizer = @import("../management/fertilizer_nitrogen_inventory.zig");
    const mineral = @import("../management/mineral_fertilizer_inventory.zig");
    var surface_organic = try organic.State.init(std.testing.allocator, 1);
    defer surface_organic.deinit();
    var soil_organic = try organic.State.init(std.testing.allocator, 1);
    defer soil_organic.deinit();
    var surface_gas = try gas.State.init(std.testing.allocator, 1);
    defer surface_gas.deinit();
    var soil_gas = try gas.State.init(std.testing.allocator, 1);
    defer soil_gas.deinit();
    var surface_n = try surface_fertilizer.State.init(std.testing.allocator, 1);
    defer surface_n.deinit();
    var soil_n = try soil_fertilizer.State.init(std.testing.allocator, 1, 1);
    defer soil_n.deinit();
    var mineral_state = try mineral.State.init(std.testing.allocator, 1, 1);
    defer mineral_state.deinit();
    surface_organic.microbial[0].carbon_g_c = 10;
    surface_organic.dissolved[0].carbon_g_c = 7;
    surface_n.cells[0].ammonium_mol_n = 20;
    mineral_state.surface[0].broadcast_monocalcium_phosphate_mol = 30;
    mineral_state.surface[0].gypsum_mol = 40;
    const owners: inventory.Owners = .{ .surface_organic = &surface_organic, .soil_organic = &soil_organic, .surface_gas = &surface_gas, .soil_gas = &soil_gas, .surface_nitrogen_fertilizer = &surface_n, .soil_nitrogen_fertilizer = &soil_n, .mineral_fertilizer = &mineral_state };
    var suspended_megagrams = [_]f64{2};
    var soil_mass_megagrams = [_]f64{10};
    var settled_megagrams = [_]f64{99};
    var sidecar_active = [_]bool{false};
    var sidecar_destination = [_]usize{99};
    var sidecar_transfer = [_]conservation_sidecar.Transfer{.{}};
    const attached_layout: suspended_constituents.Layout = .{
        .organic_cnp_count = 1,
        .nitrogen_fertilizer_count = 1,
        .dry_mineral_fertilizer_count = 1,
        .chemistry_live_and_pending_count = 1,
    };
    var attached = try suspended_constituents.State.initBorrowingSediment(
        std.testing.allocator,
        &suspended_megagrams,
        attached_layout,
    );
    defer attached.deinit();
    var receiving_attached = [_]f64{1} ** 9;
    var attached_before = [_]f64{0} ** 9;
    for (attached.pools, 0..) |*value, index| {
        value.* = 10 * @as(f64, @floatFromInt(index + 1));
        attached_before[index] = value.*;
    }
    try applyWithGeometry(owners, .{
        .surface_sediment_megagrams = &suspended_megagrams,
        .surface_soil_mass_megagrams = &soil_mass_megagrams,
        .settled_sediment_megagrams = &settled_megagrams,
        .suspended_constituents = &attached,
        .receiving_topsoil_constituent_pools = &receiving_attached,
        .accepted_sidecar = .{
            .active = &sidecar_active,
            .destination_soil_layer = &sidecar_destination,
            .transfer = &sidecar_transfer,
        },
    }, .{
        .cell_count = 1,
        .soil_layer_capacity = 1,
        .donor_bulk_density_megagrams_per_m3 = &.{0},
        .donor_layer_thickness_m = &.{0.1},
        .surface_soil_layer_by_cell = &.{0},
        .active_soil_layer_count_by_cell = &.{1},
        .soil_bulk_density_megagrams_per_m3 = &.{1.2},
        .soil_layer_thickness_m = &.{0.2},
        .minimum_receiver_thickness_m = 1e-6,
    }, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), soil_organic.microbial[0].carbon_g_c, 1e-15);
    try std.testing.expectEqual(@as(f64, 7), surface_organic.dissolved[0].carbon_g_c);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), soil_n.soil[0].broadcast_ammonium_mol_n, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.03), mineral_state.soil[0].broadcast_monocalcium_phosphate_mol, 1e-15);
    try std.testing.expectEqual(@as(f64, 40), mineral_state.surface[0].gypsum_mol);
    try std.testing.expectEqual(@as(f64, 0), mineral_state.soil[0].gypsum_mol);
    try std.testing.expectEqual(@as(f64, 2), suspended_megagrams[0]);
    try std.testing.expectEqual(@as(f64, 10), soil_mass_megagrams[0]);
    try std.testing.expectEqual(@as(f64, 0), settled_megagrams[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 12), suspended_megagrams[0] + soil_mass_megagrams[0], 1e-15);
    try std.testing.expect(sidecar_active[0]);
    try std.testing.expectEqual(@as(usize, 0), sidecar_destination[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), sidecar_transfer[0].carbon_g, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), sidecar_transfer[0].nitrogen_mol, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.06), sidecar_transfer[0].phosphorus_mol, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.03), sidecar_transfer[0].calcium_mol, 1e-15);
    for (0..attached.component_count) |component| {
        try std.testing.expectEqual(attached_before[component], attached.pools[component]);
        try std.testing.expectEqual(@as(f64, 1), receiving_attached[component]);
        try std.testing.expectEqual(@as(f64, 0), attached.settled_transfer_to_topsoil[component]);
    }
}

test "REDIST descending water-column residence prevents same-hour L0 cascade" {
    const organic = @import("../soil/organic/initialization.zig");
    const gas = @import("../soil/gas/transport.zig");
    const surface_fertilizer = @import("litter_fertilizer.zig");
    const soil_fertilizer = @import("../management/fertilizer_nitrogen_inventory.zig");
    const mineral = @import("../management/mineral_fertilizer_inventory.zig");
    var surface_organic = try organic.State.init(std.testing.allocator, 1);
    defer surface_organic.deinit();
    var soil_organic = try organic.State.init(std.testing.allocator, 3);
    defer soil_organic.deinit();
    var surface_gas = try gas.State.init(std.testing.allocator, 1);
    defer surface_gas.deinit();
    var soil_gas = try gas.State.init(std.testing.allocator, 3);
    defer soil_gas.deinit();
    var surface_n = try surface_fertilizer.State.init(std.testing.allocator, 1);
    defer surface_n.deinit();
    var soil_n = try soil_fertilizer.State.init(std.testing.allocator, 1, 3);
    defer soil_n.deinit();
    var mineral_state = try mineral.State.init(std.testing.allocator, 1, 3);
    defer mineral_state.deinit();
    const microbial_stride = organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count;
    surface_organic.microbial[0].carbon_g_c = 100;
    soil_organic.microbial[0].carbon_g_c = 10;
    soil_organic.microbial[microbial_stride].carbon_g_c = 20;
    soil_organic.dissolved[0].carbon_g_c = 30;
    surface_n.cells[0].ammonium_mol_n = 100;
    soil_n.soil[0].broadcast_ammonium_mol_n = 10;
    soil_n.soil[1].broadcast_ammonium_mol_n = 20;
    soil_n.soil[0].banded_ammonium_mol_n = 40;
    var suspended = [_]f64{5};
    var surface_soil = [_]f64{10};
    var settled = [_]f64{99};
    var layer_active = [_]bool{ false, false, false };
    var layer_destination = [_]usize{ 99, 99, 99 };
    var layer_transfer = [_]conservation_sidecar.Transfer{ .{}, .{}, .{} };
    try applyWithGeometry(.{
        .surface_organic = &surface_organic,
        .soil_organic = &soil_organic,
        .surface_gas = &surface_gas,
        .soil_gas = &soil_gas,
        .surface_nitrogen_fertilizer = &surface_n,
        .soil_nitrogen_fertilizer = &soil_n,
        .mineral_fertilizer = &mineral_state,
    }, .{
        .surface_sediment_megagrams = &suspended,
        .surface_soil_mass_megagrams = &surface_soil,
        .settled_sediment_megagrams = &settled,
        .accepted_soil_layer_sidecar = .{
            .active_by_source = &layer_active,
            .destination_soil_layer_by_source = &layer_destination,
            .transfer_by_source = &layer_transfer,
        },
    }, .{
        .cell_count = 1,
        .soil_layer_capacity = 3,
        .donor_bulk_density_megagrams_per_m3 = &.{0},
        .donor_layer_thickness_m = &.{0.1},
        .surface_soil_layer_by_cell = &.{0},
        .active_soil_layer_count_by_cell = &.{3},
        .soil_bulk_density_megagrams_per_m3 = &.{ 0, 0, 1.2 },
        .soil_layer_thickness_m = &.{ 0.1, 0.1, 0.2 },
        .minimum_receiver_thickness_m = 1e-6,
    }, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 99.9), surface_organic.microbial[0].carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 10.09), soil_organic.microbial[0].carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 19.99), soil_organic.microbial[microbial_stride].carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), soil_organic.microbial[2 * microbial_stride].carbon_g_c, 1e-14);
    try std.testing.expectEqual(@as(f64, 30), soil_organic.dissolved[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), soil_organic.dissolved[1].carbon_g_c);
    try std.testing.expectApproxEqAbs(@as(f64, 99.9), surface_n.cells[0].ammonium_mol_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 10.09), soil_n.soil[0].broadcast_ammonium_mol_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 19.99), soil_n.soil[1].broadcast_ammonium_mol_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), soil_n.soil[2].broadcast_ammonium_mol_n, 1e-14);
    try std.testing.expectEqual(@as(f64, 40), soil_n.soil[0].banded_ammonium_mol_n);
    try std.testing.expectEqual(@as(f64, 5), suspended[0]);
    try std.testing.expectEqual(@as(f64, 10), surface_soil[0]);
    try std.testing.expectEqual(@as(f64, 0), settled[0]);
}

test "REDIST water-column production owners conserve texture capacity and chemistry" {
    const organic = @import("../soil/organic/initialization.zig");
    const gas = @import("../soil/gas/transport.zig");
    const surface_fertilizer = @import("litter_fertilizer.zig");
    const soil_fertilizer = @import("../management/fertilizer_nitrogen_inventory.zig");
    const mineral = @import("../management/mineral_fertilizer_inventory.zig");
    var surface_organic = try organic.State.init(std.testing.allocator, 1);
    defer surface_organic.deinit();
    var soil_organic = try organic.State.init(std.testing.allocator, 3);
    defer soil_organic.deinit();
    var surface_gas = try gas.State.init(std.testing.allocator, 1);
    defer surface_gas.deinit();
    var soil_gas = try gas.State.init(std.testing.allocator, 3);
    defer soil_gas.deinit();
    var surface_n = try surface_fertilizer.State.init(std.testing.allocator, 1);
    defer surface_n.deinit();
    var soil_n = try soil_fertilizer.State.init(std.testing.allocator, 1, 3);
    defer soil_n.deinit();
    var mineral_state = try mineral.State.init(std.testing.allocator, 1, 3);
    defer mineral_state.deinit();
    var surface_chemistry = try surface_chemistry_module.State.init(std.testing.allocator, 1);
    defer surface_chemistry.deinit();
    var soil_chemistry = try soil_chemistry_module.State.init(std.testing.allocator, 3);
    defer soil_chemistry.deinit();
    @memset(surface_chemistry.mineral_reference_water_m3, 1);

    var properties: soil_properties_module.State = undefined;
    properties.layer_count = 3;
    var sand = [_]f64{ 6, 10, 0 };
    var silt = [_]f64{ 0, 0, 0 };
    var clay = [_]f64{ 0, 0, 0 };
    var rock = [_]f64{ 0.2, 0.3, 0.4 };
    var cec_mol = [_]f64{ 50, 100, 0 };
    var aec_mol = [_]f64{ 5, 10, 0 };
    var sand_fraction = [_]f64{ 0, 0, 0 };
    var silt_fraction = [_]f64{ 0, 0, 0 };
    var clay_fraction = [_]f64{ 0, 0, 0 };
    var cec = [_]f64{ 0, 0, 0 };
    var aec = [_]f64{ 0, 0, 0 };
    properties.sand_mass_megagrams = &sand;
    properties.silt_mass_megagrams = &silt;
    properties.clay_mass_megagrams = &clay;
    properties.rock_fraction = &rock;
    properties.cation_exchange_capacity_mol = &cec_mol;
    properties.anion_exchange_capacity_mol = &aec_mol;
    properties.sand_mass_fraction = &sand_fraction;
    properties.silt_mass_fraction = &silt_fraction;
    properties.clay_mass_fraction = &clay_fraction;
    properties.cation_exchange_capacity_mol_per_megagram = &cec;
    properties.anion_exchange_capacity_mol_per_megagram = &aec;
    soil_chemistry.pending_geochemistry_solids_mol[1].calcite_solid_mol_per_m3 = 10;
    const zones: charge_classification.ZoneFractions = .{
        .ammonium_non_band = 0.5,
        .ammonium_band = 0.5,
        .nitrate_non_band = 0.5,
        .nitrate_band = 0.5,
        .phosphate_non_band = 0.5,
        .phosphate_band = 0.5,
    };
    var soil_mass = [_]f64{ 0, 0, 10 };
    var suspended = [_]f64{5};
    var surface_soil = [_]f64{10};
    var settled = [_]f64{99};
    var layer_active = [_]bool{ false, false, false };
    var layer_destination = [_]usize{ 99, 99, 99 };
    var layer_transfer = [_]conservation_sidecar.Transfer{ .{}, .{}, .{} };
    try applyWithChemistryAndGeometry(.{
        .surface_organic = &surface_organic,
        .soil_organic = &soil_organic,
        .surface_gas = &surface_gas,
        .soil_gas = &soil_gas,
        .surface_nitrogen_fertilizer = &surface_n,
        .soil_nitrogen_fertilizer = &soil_n,
        .mineral_fertilizer = &mineral_state,
    }, .{
        .surface = &surface_chemistry,
        .soil = &soil_chemistry,
        .surface_dry_mass_megagrams = &.{0},
        .soil_dry_mass_megagrams = &soil_mass,
        .soil_matrix_water_m3 = &.{ 1, 1, 2 },
        .cell_area_m2 = &.{1},
        .ammonium_non_band_fraction_by_cell = &.{0.5},
        .phosphate_non_band_water_fraction_by_cell = &.{0.5},
        .soil_properties = &properties,
        .zone_fractions_by_layer = &.{ zones, zones, zones },
    }, .{
        .surface_sediment_megagrams = &suspended,
        .surface_soil_mass_megagrams = &surface_soil,
        .settled_sediment_megagrams = &settled,
        .accepted_soil_layer_sidecar = .{
            .active_by_source = &layer_active,
            .destination_soil_layer_by_source = &layer_destination,
            .transfer_by_source = &layer_transfer,
        },
    }, .{
        .cell_count = 1,
        .soil_layer_capacity = 3,
        .donor_bulk_density_megagrams_per_m3 = &.{0},
        .donor_layer_thickness_m = &.{0.1},
        .surface_soil_layer_by_cell = &.{0},
        .active_soil_layer_count_by_cell = &.{3},
        .soil_bulk_density_megagrams_per_m3 = &.{ 0, 0, 1.2 },
        .soil_layer_thickness_m = &.{ 0.1, 0.1, 0.2 },
        .minimum_receiver_thickness_m = 1e-6,
    }, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 5.994), sand[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 9.996), sand[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), sand[2], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 150), cec_mol[0] + cec_mol[1] + cec_mol[2], 1e-13);
    try std.testing.expectEqualDeep([_]f64{ 0.2, 0.3, 0.4 }, rock);
    try std.testing.expectApproxEqAbs(@as(f64, 10.01), soil_mass[2], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), settled[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 9.99), soil_chemistry.geochemistry_solids[1].calcite_solid_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), soil_chemistry.geochemistry_solids[2].calcite_solid_mol_per_m3 * 2, 1e-15);
    try std.testing.expectEqual(@as(f64, 5), suspended[0]);
    try std.testing.expect(layer_active[0]);
    try std.testing.expect(layer_active[1]);
    try std.testing.expect(!layer_active[2]);
    try std.testing.expectEqual(@as(usize, 1), layer_destination[0]);
    try std.testing.expectEqual(@as(usize, 2), layer_destination[1]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.006), layer_transfer[0].sand_megagrams, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), layer_transfer[1].sand_megagrams, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), layer_transfer[0].cation_exchange_capacity_mol, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), layer_transfer[1].cation_exchange_capacity_mol, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), layer_transfer[1].carbon_mol, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), layer_transfer[1].calcium_mol, 1e-15);
}

test "REDIST water-column preflight leaves L0 and earlier families unchanged on failure" {
    const organic = @import("../soil/organic/initialization.zig");
    const gas = @import("../soil/gas/transport.zig");
    const surface_fertilizer = @import("litter_fertilizer.zig");
    const soil_fertilizer = @import("../management/fertilizer_nitrogen_inventory.zig");
    const mineral = @import("../management/mineral_fertilizer_inventory.zig");
    var surface_organic = try organic.State.init(std.testing.allocator, 1);
    defer surface_organic.deinit();
    var soil_organic = try organic.State.init(std.testing.allocator, 2);
    defer soil_organic.deinit();
    var surface_gas = try gas.State.init(std.testing.allocator, 1);
    defer surface_gas.deinit();
    var soil_gas = try gas.State.init(std.testing.allocator, 2);
    defer soil_gas.deinit();
    var surface_n = try surface_fertilizer.State.init(std.testing.allocator, 1);
    defer surface_n.deinit();
    var soil_n = try soil_fertilizer.State.init(std.testing.allocator, 1, 2);
    defer soil_n.deinit();
    var mineral_state = try mineral.State.init(std.testing.allocator, 1, 2);
    defer mineral_state.deinit();
    surface_organic.microbial[0].carbon_g_c = 100;
    soil_organic.microbial[0].carbon_g_c = 10;
    soil_n.soil[0].broadcast_ammonium_mol_n = std.math.nan(f64);
    var suspended = [_]f64{5};
    var surface_soil = [_]f64{10};
    var settled = [_]f64{99};
    var sidecar_active = [_]bool{true};
    var sidecar_destination = [_]usize{7};
    var sidecar_transfer = [_]conservation_sidecar.Transfer{.{ .carbon_g = 3 }};
    var layer_active = [_]bool{ true, true };
    var layer_destination = [_]usize{ 8, 9 };
    var layer_transfer = [_]conservation_sidecar.Transfer{ .{ .sand_megagrams = 4 }, .{ .calcium_mol = 5 } };
    try std.testing.expectError(error.InvalidFertilizerLayerRemapState, applyWithGeometry(.{
        .surface_organic = &surface_organic,
        .soil_organic = &soil_organic,
        .surface_gas = &surface_gas,
        .soil_gas = &soil_gas,
        .surface_nitrogen_fertilizer = &surface_n,
        .soil_nitrogen_fertilizer = &soil_n,
        .mineral_fertilizer = &mineral_state,
    }, .{
        .surface_sediment_megagrams = &suspended,
        .surface_soil_mass_megagrams = &surface_soil,
        .settled_sediment_megagrams = &settled,
        .accepted_sidecar = .{
            .active = &sidecar_active,
            .destination_soil_layer = &sidecar_destination,
            .transfer = &sidecar_transfer,
        },
        .accepted_soil_layer_sidecar = .{
            .active_by_source = &layer_active,
            .destination_soil_layer_by_source = &layer_destination,
            .transfer_by_source = &layer_transfer,
        },
    }, .{
        .cell_count = 1,
        .soil_layer_capacity = 2,
        .donor_bulk_density_megagrams_per_m3 = &.{0},
        .donor_layer_thickness_m = &.{0.1},
        .surface_soil_layer_by_cell = &.{0},
        .active_soil_layer_count_by_cell = &.{2},
        .soil_bulk_density_megagrams_per_m3 = &.{ 0, 1.2 },
        .soil_layer_thickness_m = &.{ 0.1, 0.2 },
        .minimum_receiver_thickness_m = 1e-6,
    }, 1));
    try std.testing.expectEqual(@as(f64, 100), surface_organic.microbial[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 10), soil_organic.microbial[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), soil_organic.microbial[organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 99), settled[0]);
    try std.testing.expectEqualDeep([_]bool{true}, sidecar_active);
    try std.testing.expectEqualDeep([_]usize{7}, sidecar_destination);
    try std.testing.expectEqual(@as(f64, 3), sidecar_transfer[0].carbon_g);
    try std.testing.expectEqualDeep([_]bool{ true, true }, layer_active);
    try std.testing.expectEqualDeep([_]usize{ 8, 9 }, layer_destination);
    try std.testing.expectEqual(@as(f64, 4), layer_transfer[0].sand_megagrams);
    try std.testing.expectEqual(@as(f64, 5), layer_transfer[1].calcium_mol);
}

test "late particulate chemistry failure rolls back the complete settling domain" {
    const organic = @import("../soil/organic/initialization.zig");
    const gas = @import("../soil/gas/transport.zig");
    const surface_fertilizer = @import("litter_fertilizer.zig");
    const soil_fertilizer = @import("../management/fertilizer_nitrogen_inventory.zig");
    const mineral = @import("../management/mineral_fertilizer_inventory.zig");
    var surface_organic = try organic.State.init(std.testing.allocator, 2);
    defer surface_organic.deinit();
    var soil_organic = try organic.State.init(std.testing.allocator, 2);
    defer soil_organic.deinit();
    var surface_gas = try gas.State.init(std.testing.allocator, 2);
    defer surface_gas.deinit();
    var soil_gas = try gas.State.init(std.testing.allocator, 2);
    defer soil_gas.deinit();
    var surface_n = try surface_fertilizer.State.init(std.testing.allocator, 2);
    defer surface_n.deinit();
    var soil_n = try soil_fertilizer.State.init(std.testing.allocator, 2, 1);
    defer soil_n.deinit();
    var mineral_state = try mineral.State.init(std.testing.allocator, 2, 1);
    defer mineral_state.deinit();
    var surface_chemistry = try surface_chemistry_module.State.init(std.testing.allocator, 2);
    defer surface_chemistry.deinit();
    var soil_chemistry = try soil_chemistry_module.State.init(std.testing.allocator, 2);
    defer soil_chemistry.deinit();
    surface_organic.microbial[0].carbon_g_c = 10;
    surface_chemistry.cells[0].exchange.ammonium_mol_per_megagram = 4;
    surface_chemistry.cells[1].phosphate_minerals.monocalcium_phosphate_mol_per_m3 = std.math.inf(f64);
    @memset(surface_chemistry.mineral_reference_water_m3, 1);
    const owners: inventory.Owners = .{
        .surface_organic = &surface_organic,
        .soil_organic = &soil_organic,
        .surface_gas = &surface_gas,
        .soil_gas = &soil_gas,
        .surface_nitrogen_fertilizer = &surface_n,
        .soil_nitrogen_fertilizer = &soil_n,
        .mineral_fertilizer = &mineral_state,
    };
    var suspended = [_]f64{ 2, 3 };
    var surface_soil = [_]f64{ 10, 11 };
    var settled = [_]f64{ 8, 9 };
    const attached_layout: suspended_constituents.Layout = .{
        .organic_cnp_count = 1,
        .nitrogen_fertilizer_count = 1,
        .dry_mineral_fertilizer_count = 1,
        .chemistry_live_and_pending_count = 1,
    };
    var attached = try suspended_constituents.State.initBorrowingSediment(
        std.testing.allocator,
        &suspended,
        attached_layout,
    );
    defer attached.deinit();
    for (attached.pools, 0..) |*value, index|
        value.* = @as(f64, @floatFromInt(index + 1));
    const attached_before = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 };
    var receiving_attached = [_]f64{2} ** 18;
    const receiving_before = receiving_attached;
    var soil_dry_mass = [_]f64{ 1, 1 };
    try std.testing.expectError(
        error.NonFiniteSurfacePondChemistry,
        applyWithChemistryAndGeometry(
            owners,
            .{
                .surface = &surface_chemistry,
                .soil = &soil_chemistry,
                .surface_dry_mass_megagrams = &.{ 1, 1 },
                .soil_dry_mass_megagrams = &soil_dry_mass,
                .soil_matrix_water_m3 = &.{ 1, 1 },
                .cell_area_m2 = &.{ 1, 1 },
                .ammonium_non_band_fraction_by_cell = &.{ 1, 1 },
                .phosphate_non_band_water_fraction_by_cell = &.{ 1, 1 },
            },
            .{
                .surface_sediment_megagrams = &suspended,
                .surface_soil_mass_megagrams = &surface_soil,
                .settled_sediment_megagrams = &settled,
                .suspended_constituents = &attached,
                .receiving_topsoil_constituent_pools = &receiving_attached,
            },
            .{
                .cell_count = 2,
                .soil_layer_capacity = 1,
                .donor_bulk_density_megagrams_per_m3 = &.{ 0, 0 },
                .donor_layer_thickness_m = &.{ 0.1, 0.1 },
                .surface_soil_layer_by_cell = &.{ 0, 0 },
                .active_soil_layer_count_by_cell = &.{ 1, 1 },
                .soil_bulk_density_megagrams_per_m3 = &.{ 1.2, 1.2 },
                .soil_layer_thickness_m = &.{ 0.2, 0.2 },
                .minimum_receiver_thickness_m = 1e-6,
            },
            1,
        ),
    );
    try std.testing.expectEqual(@as(f64, 10), surface_organic.microbial[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), soil_organic.microbial[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 4), surface_chemistry.cells[0].exchange.ammonium_mol_per_megagram);
    try std.testing.expectEqual(@as(f64, 0), soil_chemistry.cation_exchange_mol_per_megagram[0].ammonium_non_band);
    try std.testing.expectEqualDeep([_]f64{ 2, 3 }, suspended);
    try std.testing.expectEqualDeep([_]f64{ 10, 11 }, surface_soil);
    try std.testing.expectEqualDeep([_]f64{ 8, 9 }, settled);
    try std.testing.expectEqualSlices(f64, &attached_before, attached.pools);
    try std.testing.expectEqualSlices(f64, &receiving_before, &receiving_attached);
}

test "late invalid sediment owner leaves mixed-unit particulate owners unchanged" {
    const organic = @import("../soil/organic/initialization.zig");
    const gas = @import("../soil/gas/transport.zig");
    const surface_fertilizer = @import("litter_fertilizer.zig");
    const soil_fertilizer = @import("../management/fertilizer_nitrogen_inventory.zig");
    const mineral = @import("../management/mineral_fertilizer_inventory.zig");
    var surface_organic = try organic.State.init(std.testing.allocator, 1);
    defer surface_organic.deinit();
    var soil_organic = try organic.State.init(std.testing.allocator, 1);
    defer soil_organic.deinit();
    var surface_gas = try gas.State.init(std.testing.allocator, 1);
    defer surface_gas.deinit();
    var soil_gas = try gas.State.init(std.testing.allocator, 1);
    defer soil_gas.deinit();
    var surface_n = try surface_fertilizer.State.init(std.testing.allocator, 1);
    defer surface_n.deinit();
    var soil_n = try soil_fertilizer.State.init(std.testing.allocator, 1, 1);
    defer soil_n.deinit();
    var mineral_state = try mineral.State.init(std.testing.allocator, 1, 1);
    defer mineral_state.deinit();
    surface_organic.microbial[0].carbon_g_c = 5;
    var suspended_megagrams = [_]f64{2};
    var soil_mass_megagrams = [_]f64{std.math.inf(f64)};
    var settled_megagrams = [_]f64{3};
    const owners: inventory.Owners = .{ .surface_organic = &surface_organic, .soil_organic = &soil_organic, .surface_gas = &surface_gas, .soil_gas = &soil_gas, .surface_nitrogen_fertilizer = &surface_n, .soil_nitrogen_fertilizer = &soil_n, .mineral_fertilizer = &mineral_state };
    try std.testing.expectError(error.InvalidSurfacePondSedimentInventory, applyWithGeometry(
        owners,
        .{ .surface_sediment_megagrams = &suspended_megagrams, .surface_soil_mass_megagrams = &soil_mass_megagrams, .settled_sediment_megagrams = &settled_megagrams },
        .{
            .cell_count = 1,
            .soil_layer_capacity = 1,
            .donor_bulk_density_megagrams_per_m3 = &.{0},
            .donor_layer_thickness_m = &.{0.1},
            .surface_soil_layer_by_cell = &.{0},
            .active_soil_layer_count_by_cell = &.{1},
            .soil_bulk_density_megagrams_per_m3 = &.{1.2},
            .soil_layer_thickness_m = &.{0.2},
            .minimum_receiver_thickness_m = 1e-6,
        },
        1,
    ));
    try std.testing.expectEqual(@as(f64, 5), surface_organic.microbial[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 2), suspended_megagrams[0]);
    try std.testing.expectEqual(@as(f64, 3), settled_megagrams[0]);
}

test "three cells discriminate retention transition from faithful settling eligibility" {
    const organic = @import("../soil/organic/initialization.zig");
    const gas = @import("../soil/gas/transport.zig");
    const surface_fertilizer = @import("litter_fertilizer.zig");
    const soil_fertilizer = @import("../management/fertilizer_nitrogen_inventory.zig");
    const mineral = @import("../management/mineral_fertilizer_inventory.zig");
    const cell_count = 3;
    var surface_organic = try organic.State.init(std.testing.allocator, cell_count);
    defer surface_organic.deinit();
    var soil_organic = try organic.State.init(std.testing.allocator, cell_count);
    defer soil_organic.deinit();
    var surface_gas = try gas.State.init(std.testing.allocator, cell_count);
    defer surface_gas.deinit();
    var soil_gas = try gas.State.init(std.testing.allocator, cell_count);
    defer soil_gas.deinit();
    var surface_n = try surface_fertilizer.State.init(std.testing.allocator, cell_count);
    defer surface_n.deinit();
    var soil_n = try soil_fertilizer.State.init(std.testing.allocator, cell_count, 1);
    defer soil_n.deinit();
    var mineral_state = try mineral.State.init(std.testing.allocator, cell_count, 1);
    defer mineral_state.deinit();
    var transitions = try transition.State.init(std.testing.allocator, cell_count);
    defer transitions.deinit();
    var transition_context: transition.ApplyContext = .{
        .result = &transitions,
        // Cell a is below retention. Cells b and c exceed it.
        .surface_liquid_water_m3 = &.{ 0.1, 0.3, 0.3 },
        .surface_ice_m3 = &.{ 0, 0, 0 },
        .surface_ponding_capacity_m3 = &.{ 0.2, 0.2, 0.2 },
        .surface_litter_volume_m3 = &.{ 0.1, 0.1, 0.1 },
        .surface_litter_water_capacity_m3 = &.{ 0.1, 0.1, 0.1 },
        .horizontal_area_m2 = &.{ 1, 1, 1 },
        .minimum_heat_capacity_megajoules_per_k = &.{ 0, 0, 0 },
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
    };
    try transition.applyTile(&transition_context, .{ .first = 0, .end = cell_count });
    try std.testing.expectEqualSlices(bool, &.{ false, true, true }, transitions.active);

    const microbial_stride = organic.microbial_substrate_count *
        organic.microbial_population_count * organic.kinetic_fraction_count;
    surface_organic.microbial[0 * microbial_stride].carbon_g_c = 10;
    surface_organic.microbial[1 * microbial_stride].carbon_g_c = 20;
    surface_organic.microbial[2 * microbial_stride].carbon_g_c = 30;
    const owners: inventory.Owners = .{
        .surface_organic = &surface_organic,
        .soil_organic = &soil_organic,
        .surface_gas = &surface_gas,
        .soil_gas = &soil_gas,
        .surface_nitrogen_fertilizer = &surface_n,
        .soil_nitrogen_fertilizer = &soil_n,
        .mineral_fertilizer = &mineral_state,
    };
    var suspended_megagrams = [_]f64{ 1, 2, 3 };
    var soil_mass_megagrams = [_]f64{ 10, 10, 10 };
    var settled_megagrams = [_]f64{ 9, 9, 9 };
    try applyWithGeometry(owners, .{
        .surface_sediment_megagrams = &suspended_megagrams,
        .surface_soil_mass_megagrams = &soil_mass_megagrams,
        .settled_sediment_megagrams = &settled_megagrams,
    }, .{
        .cell_count = cell_count,
        .soil_layer_capacity = 1,
        // Cells a and c are faithful water donors. Cell b is soil.
        .donor_bulk_density_megagrams_per_m3 = &.{ 0, 1.2, 0 },
        .donor_layer_thickness_m = &.{ 0.1, 0.1, 0.1 },
        .surface_soil_layer_by_cell = &.{ 0, 0, 0 },
        .active_soil_layer_count_by_cell = &.{ 1, 1, 1 },
        .soil_bulk_density_megagrams_per_m3 = &.{ 1.2, 1.2, 1.2 },
        .soil_layer_thickness_m = &.{ 0.2, 0.2, 0.2 },
        .minimum_receiver_thickness_m = 1e-6,
    }, 1);

    // (a) retention false, settling true.
    try std.testing.expectApproxEqAbs(@as(f64, 9.99), surface_organic.microbial[0 * microbial_stride].carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), soil_organic.microbial[0 * microbial_stride].carbon_g_c, 1e-15);
    try std.testing.expectEqual(@as(f64, 0), settled_megagrams[0]);
    // (b) retention true, settling false.
    try std.testing.expectEqual(@as(f64, 20), surface_organic.microbial[1 * microbial_stride].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), soil_organic.microbial[1 * microbial_stride].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), settled_megagrams[1]);
    // (c) both true. Transition selection precedes the independent settling call.
    try std.testing.expectApproxEqAbs(@as(f64, 29.97), surface_organic.microbial[2 * microbial_stride].carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.03), soil_organic.microbial[2 * microbial_stride].carbon_g_c, 1e-15);
    try std.testing.expectEqual(@as(f64, 0), settled_megagrams[2]);
}

test "HEAT-001: settled surface organic carbon requires the same fixed-temperature heat rebase as surface biogeochemistry" {
    // This pins the fix in `stages/hourly_sediment.zig`, which wraps this
    // transfer with the identical `litter_organic_heat_rebase` pattern already
    // used around `runSurfaceBiogeochemistryBySerialTile`.
    // `applyWithGeometry` here moves surface organic carbon into a soil layer
    // without touching any heat carrier, so the census's fixed-temperature
    // pricing of surface litter (`dry_organic_heat_capacity *
    // total_organic_carbon * T`) silently changes stored enthalpy unless the
    // caller books the same rebase used for biogeochemical carbon loss. If
    // this transfer ever stopped moving carbon, the first assertion below
    // would fail and the test would no longer exercise the defect.
    const organic = @import("../soil/organic/initialization.zig");
    const gas = @import("../soil/gas/transport.zig");
    const surface_fertilizer = @import("litter_fertilizer.zig");
    const soil_fertilizer = @import("../management/fertilizer_nitrogen_inventory.zig");
    const mineral = @import("../management/mineral_fertilizer_inventory.zig");
    const rebase = @import("litter_organic_heat_rebase.zig");
    var surface_organic = try organic.State.init(std.testing.allocator, 1);
    defer surface_organic.deinit();
    var soil_organic = try organic.State.init(std.testing.allocator, 1);
    defer soil_organic.deinit();
    var surface_gas = try gas.State.init(std.testing.allocator, 1);
    defer surface_gas.deinit();
    var soil_gas = try gas.State.init(std.testing.allocator, 1);
    defer soil_gas.deinit();
    var surface_n = try surface_fertilizer.State.init(std.testing.allocator, 1);
    defer surface_n.deinit();
    var soil_n = try soil_fertilizer.State.init(std.testing.allocator, 1, 1);
    defer soil_n.deinit();
    var mineral_state = try mineral.State.init(std.testing.allocator, 1, 1);
    defer mineral_state.deinit();
    surface_organic.microbial[0].carbon_g_c = 100;
    const owners: inventory.Owners = .{ .surface_organic = &surface_organic, .soil_organic = &soil_organic, .surface_gas = &surface_gas, .soil_gas = &soil_gas, .surface_nitrogen_fertilizer = &surface_n, .soil_nitrogen_fertilizer = &soil_n, .mineral_fertilizer = &mineral_state };
    var suspended_megagrams = [_]f64{2};
    var soil_mass_megagrams = [_]f64{10};
    var settled_megagrams = [_]f64{0};

    const carbon_before = [_]f64{try surface_organic.totalCarbon_g_c(0)};
    const temperature_k = [_]f64{280};

    try applyWithGeometry(owners, .{
        .surface_sediment_megagrams = &suspended_megagrams,
        .surface_soil_mass_megagrams = &soil_mass_megagrams,
        .settled_sediment_megagrams = &settled_megagrams,
    }, .{
        .cell_count = 1,
        .soil_layer_capacity = 1,
        .donor_bulk_density_megagrams_per_m3 = &.{0},
        .donor_layer_thickness_m = &.{0.1},
        .surface_soil_layer_by_cell = &.{0},
        .active_soil_layer_count_by_cell = &.{1},
        .soil_bulk_density_megagrams_per_m3 = &.{1.2},
        .soil_layer_thickness_m = &.{0.2},
        .minimum_receiver_thickness_m = 1e-6,
    }, 1);

    const carbon_after = [_]f64{try surface_organic.totalCarbon_g_c(0)};
    // The transfer must have actually moved surface carbon, or this test is
    // not exercising the mechanism the fix addresses.
    try std.testing.expect(carbon_after[0] < carbon_before[0]);

    const dry_organic_heat_capacity_megajoules_per_g_c_k = 2.496e-6;
    const booked = try rebase.landscapeOrganicCarbonRebaseHeatMegajoules(
        &carbon_before,
        &carbon_after,
        &temperature_k,
        dry_organic_heat_capacity_megajoules_per_g_c_k,
    );
    const expected = (carbon_after[0] - carbon_before[0]) *
        dry_organic_heat_capacity_megajoules_per_g_c_k * temperature_k[0];
    try std.testing.expectApproxEqRel(expected, booked, 1e-12);
    // Carbon left the surface pool at fixed temperature, so the credit the
    // caller must book into `landscape_boundary_ledger` is negative (heat
    // leaving the census through this transfer, matching the capacity that
    // just left with the carbon). Before the fix, `hourly_sediment.zig`
    // booked nothing for this transfer and this credit was silently dropped.
    try std.testing.expect(booked < 0);
}
