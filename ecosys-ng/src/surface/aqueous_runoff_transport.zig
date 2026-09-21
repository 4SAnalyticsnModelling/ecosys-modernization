const std = @import("std");
const Chemistry = @import("litter_chemistry.zig").State;
const ChemistryCell = @import("litter_chemistry.zig").Cell;
const runoff_carrier = @import("runoff_carrier.zig");
const mineral_transport = @import("mineral_transport.zig");
const organic_transport = @import("organic_transport.zig");
const dissolved_gas_transport = @import("dissolved_gas_transport.zig");
const organic = @import("../soil/organic/initialization.zig");
const gas = @import("../soil/gas/transport.zig");
const surface_routing = @import("../soil/solute/surface_solute_routing.zig");
const transport_species = @import("../soil/solute/transport_species.zig");
const overland_litter_salt = @import("../redistribution/surface/overland_flow_litter_salt_update.zig");
const daily_litter_salt = @import("../redistribution/inventory/daily_litter_salt.zig");
const legacy_water_negligible_floor = @import("../core/legacy_water_negligible_floor.zig");

pub const Directions = runoff_carrier.Directions;
pub const ElementMass = runoff_carrier.ElementMass;
pub const Species = transport_species.AqueousSpecies;
pub const species_count = Species.count;

/// The litter surface has one phosphate domain. Forty-two generic aqueous
/// coordinates are shared with soil; bare HPO4/H2PO4 stay with the dedicated
/// mineral runoff owner and all band coordinates are soil-only duplicates.
pub const surface_species_count: usize = overland_litter_salt.legacy_surface_species_count;

/// REDIST's tillage surface-salt source is the same 42-coordinate litter
/// registry used by overland transport, but not the same storage representation:
/// coordinates 0..11 are concentrations in `litter_chemistry`, while 12..41
/// are persistent extensive amounts in `surface_solute_routing`.  Keep this
/// bridge beside those two owners so a tillage caller cannot silently bind only
/// the first twelve coordinates or use the older H/OH/Al positional order.
pub const TillageSurfaceAmounts = [surface_species_count]f64;

comptime {
    if (@intFromEnum(Species.aluminum) != 0 or
        @intFromEnum(Species.iron) != 1 or
        @intFromEnum(Species.hydrogen) != 2 or
        @intFromEnum(Species.hydroxide) != 7 or
        @intFromEnum(Species.bicarbonate) != 11 or
        @intFromEnum(Species.aluminum_hydroxide_1) != 12 or
        @intFromEnum(Species.hydrogen_silicate) != 33 or
        @intFromEnum(Species.non_band_phosphate) != 34 or
        @intFromEnum(Species.non_band_magnesium_hpo4) != 41)
        @compileError("REDIST tillage surface-salt coordinate order changed");
}

/// `ZEROS2(NY,NX) = ZERO2*DH(NY,NX)*DV(NY,NX)` (`starts.f:270`). issue-069
/// Finding B: shared carrier-selection helper for `gatherTillageSurfaceAmounts`'s
/// water-carrier guard, mirroring `runtime_adapter.zig`'s
/// `tillageWaterCarrierM3` exactly (this file cannot import that private
/// helper, so it is deliberately re-derived here rather than imported, same
/// as `erosion_chemistry_bridge.zig`'s own `erosionWaterCarrierM3`). A bare
/// `> 0` guard treats any nonzero-but-negligible live water carrier as
/// "real", while `commitTillageSurfaceAmounts`'s own caller
/// (`runtime_adapter.zig`'s `surfaceOwnersAfter`, issue-064) already
/// substitutes the dry reference for the same field at the same floor --
/// that basis mismatch is the exact defect class already fixed at
/// issue-060/061/063/064/065/066's other instances. `>`, not `>=`, matches
/// legacy's own strict comparison (`solute.f:610`).
fn tillageSurfaceWaterCarrierM3(live_water_m3: f64, dry_reference_water_m3: f64, negligible_water_volume_m3: f64) f64 {
    return if (live_water_m3 > negligible_water_volume_m3) live_water_m3 else dry_reference_water_m3;
}

/// Gathers REDIST `TZALGS..TZM1PGS` amounts for one surface cell.  Wet free
/// ions use the current water carrier; a dry cell uses the chemistry owner's
/// retained reference carrier.  Complexes, HYSI, and the eight phosphate
/// complexes are already extensive and are copied without a second carrier.
pub fn gatherTillageSurfaceAmounts(
    chemistry: *const Chemistry,
    extensive: *const surface_routing.State,
    cell: usize,
    actual_water_m3: f64,
    negligible_water_volume_m3: f64,
) !TillageSurfaceAmounts {
    try validateTillageOwners(chemistry, extensive, cell, actual_water_m3);
    if (!std.math.isFinite(negligible_water_volume_m3) or negligible_water_volume_m3 < 0)
        return error.InvalidTillageSurfaceAqueousCarrier;
    // issue-069 Finding B: widened from an exact-zero-only guard
    // (`actual_water_m3 > 0`) to the shared `ZEROS2`-equivalent floor, so a
    // near-zero-but-nonzero raw carrier is no longer treated as "real" here
    // while its write-side sibling (`commitTillageSurfaceAmounts`'s caller,
    // issue-064) already substitutes the dry reference for the same field at
    // the same floor. Not reachable in the current Ottawa deck (no tillage
    // scheduled); fixed for the next deck that schedules one.
    const represented_carrier_m3 = tillageSurfaceWaterCarrierM3(actual_water_m3, chemistry.dry_reference_water_m3[cell], negligible_water_volume_m3);
    if (!std.math.isFinite(represented_carrier_m3) or represented_carrier_m3 < 0)
        return error.InvalidTillageSurfaceAqueousCarrier;

    var result: TillageSurfaceAmounts = @splat(0);
    const represented = representedConcentrations(chemistry.cells[cell]);
    for (represented, 0..) |concentration, species_index| {
        if (!std.math.isFinite(concentration) or concentration < 0)
            return error.InvalidTillageSurfaceAqueousOwner;
        if (represented_carrier_m3 == 0 and concentration != 0)
            return error.UnboundTillageSurfaceAqueousInventory;
        result[species_index] = concentration * represented_carrier_m3;
        if (!std.math.isFinite(result[species_index]))
            return error.InvalidTillageSurfaceAqueousOwner;
    }
    const first = cell * extensive.species_count;
    for (12..surface_species_count) |species_index| {
        const amount = extensive.amount_mol[first + species_index];
        if (!std.math.isFinite(amount) or amount < 0)
            return error.InvalidTillageSurfaceAqueousOwner;
        result[species_index] = amount;
    }
    return result;
}

/// Atomically publishes the remaining REDIST surface-salt amounts after a
/// tillage transfer. `represented_carrier_m3` is the retained wet or dry
/// carrier for coordinates 0..11.  Coordinates 12..41 remain extensive.
/// Soil-only coordinates 42..53 are deliberately untouched.
pub fn commitTillageSurfaceAmounts(
    chemistry: *Chemistry,
    extensive: *surface_routing.State,
    cell: usize,
    actual_water_m3: f64,
    represented_carrier_m3: f64,
    amounts: TillageSurfaceAmounts,
) !void {
    try validateTillageOwners(chemistry, extensive, cell, actual_water_m3);
    if (!std.math.isFinite(represented_carrier_m3) or represented_carrier_m3 < 0 or
        (actual_water_m3 > 0 and represented_carrier_m3 != actual_water_m3))
        return error.InvalidTillageSurfaceAqueousCarrier;

    var concentrations: [12]f64 = undefined;
    for (0..surface_species_count) |species_index| {
        const amount = amounts[species_index];
        if (!std.math.isFinite(amount) or amount < 0)
            return error.InvalidTillageSurfaceAqueousOwner;
        if (species_index < concentrations.len) {
            if (represented_carrier_m3 == 0 and amount != 0)
                return error.UnboundTillageSurfaceAqueousInventory;
            const concentration = if (represented_carrier_m3 > 0)
                amount / represented_carrier_m3
            else
                0;
            if (!std.math.isFinite(concentration) or concentration < 0)
                return error.InvalidTillageSurfaceAqueousOwner;
            concentrations[species_index] = concentration;
        }
    }

    var chemistry_candidate = chemistry.cells[cell];
    setRepresentedConcentrations(&chemistry_candidate, concentrations);
    const first = cell * extensive.species_count;
    chemistry.cells[cell] = chemistry_candidate;
    chemistry.dry_reference_water_m3[cell] = if (actual_water_m3 > 0)
        0
    else
        represented_carrier_m3;
    extensive.carrier_volume_m3[cell] = actual_water_m3;
    @memcpy(extensive.amount_mol[first..][0..surface_species_count], &amounts);
}

fn validateTillageOwners(
    chemistry: *const Chemistry,
    extensive: *const surface_routing.State,
    cell: usize,
    actual_water_m3: f64,
) !void {
    const cells = std.math.mul(usize, extensive.columns, extensive.rows) catch
        return error.SurfaceTillageOwnerDimensionMismatch;
    const amount_count = std.math.mul(usize, cells, species_count) catch
        return error.SurfaceTillageOwnerDimensionMismatch;
    if (cells == 0 or chemistry.cells.len != cells or
        chemistry.dry_reference_water_m3.len != cells or
        extensive.species_count != species_count or
        extensive.carrier_volume_m3.len != cells or
        extensive.amount_mol.len != amount_count or cell >= cells)
        return error.SurfaceTillageOwnerDimensionMismatch;
    if (!std.math.isFinite(actual_water_m3) or actual_water_m3 < 0)
        return error.InvalidTillageSurfaceAqueousCarrier;
}

/// Formula-bearing boundary export. Values are moles of atoms, not moles of
/// aqueous complexes, so consumers cannot hide an Al loss with a Na gain or a
/// sulfate loss with a chloride gain.
pub const Components = struct {
    aluminum_mol: f64 = 0,
    iron_mol: f64 = 0,
    hydrogen_mol: f64 = 0,
    calcium_mol: f64 = 0,
    magnesium_mol: f64 = 0,
    sodium_mol: f64 = 0,
    potassium_mol: f64 = 0,
    sulfur_mol: f64 = 0,
    chloride_mol: f64 = 0,
    carbon_mol: f64 = 0,
    phosphorus_mol: f64 = 0,
    silicon_mol: f64 = 0,
    oxygen_mol: f64 = 0,

    fn addScaled(self: *Components, coefficients: Components, amount_mol: f64) !void {
        inline for (@typeInfo(Components).@"struct".fields) |field| {
            const next = @field(self, field.name) +
                @field(coefficients, field.name) * amount_mol;
            if (!std.math.isFinite(next) or next < 0)
                return error.InvalidSurfaceAqueousComponentExport;
            @field(self, field.name) = next;
        }
    }
};

pub const Output = struct {
    /// Positive external loss, indexed `[cell * Species.count + species]`.
    /// Soil-only band species are always zero. PO4/H3PO4 have this generic
    /// owner; bare HPO4/H2PO4 remain in mineral transport.
    boundary_export_mol_by_cell_species: []f64,
    /// Formula-stoichiometric expansion of the species export for each source
    /// cell. The caller owns this storage; the adapter performs no hidden
    /// aggregation allocation.
    boundary_components_by_cell: []Components,
    /// Per-cell internal donor loss and recipient gain. These are separate
    /// rather than netted so simultaneous opposing flows remain visible to
    /// cell-scale conservation while cancelling exactly at domain scale.
    intercell_debit_components_by_cell: []Components,
    intercell_credit_components_by_cell: []Components,
};

pub const TransactionOwners = struct {
    chemistry: *Chemistry,
    nitrite_g_n: []f64,
    aqueous: *surface_routing.State,
    organic: *organic.State,
    gas: *gas.State,
};

pub const TransactionOutput = struct {
    inorganic_nitrogen_export_g_n_by_cell: []f64,
    inorganic_phosphorus_export_g_p_by_cell: []f64,
    dissolved_organic_carbon_export_g_c_by_cell: []f64,
    dissolved_organic_nitrogen_export_g_n_by_cell: []f64,
    dissolved_organic_phosphorus_export_g_p_by_cell: []f64,
    inorganic_carbon_export_g_c_by_cell: []f64,
    dissolved_oxygen_export_g_o_by_cell: []f64,
    dissolved_nitrogen_export_g_n_by_cell: []f64,
    dissolved_hydrogen_export_g_h_by_cell: []f64,
    /// Exact REDIST pseudo-ion count exported by the 42-coordinate generic
    /// litter salt owner, indexed by source cell.
    litter_salt_ion_export_mol_by_cell: []f64,
    aqueous_boundary_export_mol_by_cell_species: []f64,
    aqueous_boundary_components_by_cell: []Components,
    aqueous_intercell_debit_components_by_cell: []Components,
    aqueous_intercell_credit_components_by_cell: []Components,
    dedicated_intercell_debit_by_cell: []ElementMass,
    dedicated_intercell_credit_by_cell: []ElementMass,
};

/// One exhaustive owner decision for every coordinate in the authoritative
/// 54-species registry. An enum expansion cannot silently become immobile:
/// this switch must be extended before the module will compile.
pub const RunoffOwnership = enum {
    generic_aqueous,
    dedicated_mineral,
    soil_only,
};

pub fn runoffOwnership(species: Species) RunoffOwnership {
    return switch (species) {
        .aluminum,
        .iron,
        .hydrogen,
        .calcium,
        .magnesium,
        .sodium,
        .potassium,
        .hydroxide,
        .sulfate,
        .chloride,
        .carbonate,
        .bicarbonate,
        .aluminum_hydroxide_1,
        .aluminum_hydroxide_2,
        .aluminum_hydroxide_3,
        .aluminum_hydroxide_4,
        .aluminum_sulfate,
        .iron_hydroxide_1,
        .iron_hydroxide_2,
        .iron_hydroxide_3,
        .iron_hydroxide_4,
        .iron_sulfate,
        .calcium_hydroxide,
        .calcium_carbonate,
        .calcium_bicarbonate,
        .calcium_sulfate,
        .magnesium_hydroxide,
        .magnesium_carbonate,
        .magnesium_bicarbonate,
        .magnesium_sulfate,
        .sodium_carbonate,
        .sodium_sulfate,
        .potassium_sulfate,
        .hydrogen_silicate,
        .non_band_phosphate,
        .non_band_phosphoric_acid,
        .non_band_iron_hpo4,
        .non_band_iron_h2po4,
        .non_band_calcium_phosphate,
        .non_band_calcium_hpo4,
        .non_band_calcium_h2po4,
        .non_band_magnesium_hpo4,
        => .generic_aqueous,

        // Free litter HPO4/H2PO4 are chemistry fields, transported once by
        // `mineral_transport`; the canonical entries mirror the topsoil
        // owner used by the litter/topsoil interface.
        .non_band_hpo4,
        .non_band_h2po4,
        => .dedicated_mineral,

        // Litter has one phosphate domain. These ten band coordinates are
        // topsoil-only duplicates and have no physical surface inventory.
        .band_phosphate,
        .band_phosphoric_acid,
        .band_iron_hpo4,
        .band_iron_h2po4,
        .band_calcium_phosphate,
        .band_calcium_hpo4,
        .band_calcium_h2po4,
        .band_magnesium_hpo4,
        .band_hpo4,
        .band_h2po4,
        => .soil_only,
    };
}

/// True only for coordinates owned by this adapter. Molecular gases and
/// dissolved organic matter are outside this registry and remain with their
/// dedicated runoff owners. Free HPO4/H2PO4 use the dedicated mineral owner;
/// the ten band coordinates have no surface domain.
pub fn routesSpecies(species: Species) bool {
    return runoffOwnership(species) == .generic_aqueous;
}

/// Atomic chemistry <-> extensive runoff adapter.
///
/// Represented free-ion amounts are reconstructed from the pre-runoff water
/// carrier and litter chemistry. Complexes remain extensive-state owned. The
/// existing simultaneous runoff-carrier kernel then routes only coordinates
/// not owned by mineral-N/P, gas, or organic runoff. No caller state or output
/// changes unless every candidate amount, concentration, and formula-expanded
/// boundary export is valid.
pub fn advance(
    allocator: std.mem.Allocator,
    chemistry: *Chemistry,
    extensive: *surface_routing.State,
    columns: usize,
    rows: usize,
    post_runoff_water_m3: []const f64,
    runoff_water_change_m3: []const f64,
    directions: Directions,
    maximum_transport_fraction: f64,
    output: Output,
) !void {
    const cells = try std.math.mul(usize, columns, rows);
    const amount_count = try std.math.mul(usize, cells, species_count);
    if (chemistry.cells.len != cells or
        chemistry.dry_reference_water_m3.len != cells or
        extensive.columns != columns or extensive.rows != rows or
        extensive.species_count != species_count or
        extensive.carrier_volume_m3.len != cells or
        extensive.amount_mol.len != amount_count or
        post_runoff_water_m3.len != cells or
        runoff_water_change_m3.len != cells or
        output.boundary_export_mol_by_cell_species.len != amount_count or
        output.boundary_components_by_cell.len != cells or
        output.intercell_debit_components_by_cell.len != cells or
        output.intercell_credit_components_by_cell.len != cells)
        return error.SurfaceAqueousRunoffDimensionMismatch;
    inline for (.{
        directions.east_m3,
        directions.west_m3,
        directions.south_m3,
        directions.north_m3,
    }) |values| if (values.len != cells)
        return error.SurfaceAqueousRunoffDimensionMismatch;
    if (!std.math.isFinite(maximum_transport_fraction) or
        maximum_transport_fraction < 0 or maximum_transport_fraction > 1)
        return error.InvalidSurfaceAqueousRunoffParameter;

    const pre_runoff_water_m3 = try allocator.alloc(f64, cells);
    defer allocator.free(pre_runoff_water_m3);
    const original = try allocator.alloc(f64, amount_count);
    defer allocator.free(original);
    const changes = try allocator.alloc(f64, amount_count);
    defer allocator.free(changes);
    const species_export = try allocator.alloc(f64, amount_count);
    defer allocator.free(species_export);
    const accepted = try allocator.dupe(f64, extensive.amount_mol);
    defer allocator.free(accepted);
    const chemistry_candidate = try allocator.dupe(ChemistryCell, chemistry.cells);
    defer allocator.free(chemistry_candidate);
    const dry_reference_candidate = try allocator.dupe(f64, chemistry.dry_reference_water_m3);
    defer allocator.free(dry_reference_candidate);
    const component_export = try allocator.alloc(Components, cells);
    defer allocator.free(component_export);
    const intercell_debit = try allocator.alloc(Components, cells);
    defer allocator.free(intercell_debit);
    const intercell_credit = try allocator.alloc(Components, cells);
    defer allocator.free(intercell_credit);
    @memset(original, 0);
    @memset(component_export, .{});
    @memset(intercell_debit, .{});
    @memset(intercell_credit, .{});

    for (0..cells) |cell| {
        const post_water = post_runoff_water_m3[cell];
        const water_change = runoff_water_change_m3[cell];
        const pre_water = post_water - water_change;
        if (!std.math.isFinite(post_water) or post_water < 0 or
            !std.math.isFinite(water_change) or
            !std.math.isFinite(pre_water) or pre_water < 0)
            return error.InvalidSurfaceAqueousRunoffWater;
        pre_runoff_water_m3[cell] = pre_water;
        if (!std.math.isFinite(extensive.carrier_volume_m3[cell]) or
            extensive.carrier_volume_m3[cell] < 0 or
            !std.math.isFinite(chemistry.dry_reference_water_m3[cell]) or
            chemistry.dry_reference_water_m3[cell] < 0)
            return error.InvalidSurfaceAqueousRunoffState;

        const concentrations = representedConcentrations(chemistry.cells[cell]);
        for (concentrations, 0..) |concentration, species_index| {
            if (!std.math.isFinite(concentration) or concentration < 0)
                return error.InvalidSurfaceAqueousRunoffChemistry;
            const species: Species = @enumFromInt(species_index);
            if (routesSpecies(species)) {
                const amount = concentration * pre_water;
                if (!std.math.isFinite(amount) or amount < 0)
                    return error.InvalidSurfaceAqueousRunoffChemistry;
                original[cell * species_count + species_index] = amount;
            }
        }
        for (0..species_count) |species_index| {
            const amount = extensive.amount_mol[cell * species_count + species_index];
            if (!std.math.isFinite(amount) or amount < 0)
                return error.InvalidSurfaceAqueousRunoffState;
            const species: Species = @enumFromInt(species_index);
            if (routesSpecies(species) and species_index >= 12)
                original[cell * species_count + species_index] = amount;
        }
    }

    try runoff_carrier.calculateChanges(
        columns,
        rows,
        species_count,
        original,
        pre_runoff_water_m3,
        .{
            .east_m3 = directions.east_m3,
            .west_m3 = directions.west_m3,
            .south_m3 = directions.south_m3,
            .north_m3 = directions.north_m3,
        },
        maximum_transport_fraction,
        changes,
        species_export,
    );
    try overland_litter_salt.applyExtensiveChanges(
        original,
        changes,
        accepted,
        cells,
        species_count,
    );
    try accumulateIntercellComponents(
        columns,
        rows,
        original,
        pre_runoff_water_m3,
        .{
            .east_m3 = directions.east_m3,
            .west_m3 = directions.west_m3,
            .south_m3 = directions.south_m3,
            .north_m3 = directions.north_m3,
        },
        maximum_transport_fraction,
        intercell_debit,
        intercell_credit,
    );

    for (0..cells) |cell| {
        for (0..species_count) |species_index| {
            const species: Species = @enumFromInt(species_index);
            if (!routesSpecies(species)) {
                species_export[cell * species_count + species_index] = 0;
                continue;
            }
            const index = cell * species_count + species_index;
            const next = original[index] + changes[index];
            if (!std.math.isFinite(next) or next < 0)
                return error.InvalidSurfaceAqueousRunoffCandidate;
            accepted[index] = next;
            try component_export[cell].addScaled(formula(species), species_export[index]);
        }

        const post_water = post_runoff_water_m3[cell];
        if (post_water > 0) {
            var concentrations: [12]f64 = undefined;
            for (0..12) |species_index| {
                const species: Species = @enumFromInt(species_index);
                const value = if (routesSpecies(species))
                    accepted[cell * species_count + species_index] / post_water
                else
                    representedConcentrations(chemistry_candidate[cell])[species_index];
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidSurfaceAqueousRunoffCandidate;
                concentrations[species_index] = value;
            }
            setRepresentedConcentrations(&chemistry_candidate[cell], concentrations);
            dry_reference_candidate[cell] = 0;
        } else if (pre_runoff_water_m3[cell] > 0) {
            var total_outflow_m3: f64 = 0;
            inline for (.{
                directions.east_m3[cell],
                directions.west_m3[cell],
                directions.south_m3[cell],
                directions.north_m3[cell],
            }) |value| total_outflow_m3 += value;
            const transported_fraction = @min(
                maximum_transport_fraction,
                total_outflow_m3 / pre_runoff_water_m3[cell],
            );
            const reference_water = pre_runoff_water_m3[cell] * (1 - transported_fraction);
            var concentrations: [12]f64 = undefined;
            for (0..12) |species_index| {
                const amount = accepted[cell * species_count + species_index];
                if (reference_water > 0)
                    concentrations[species_index] = amount / reference_water
                else if (amount == 0)
                    concentrations[species_index] = 0
                else
                    return error.SurfaceAqueousMassWithoutDryReference;
                if (!std.math.isFinite(concentrations[species_index]) or
                    concentrations[species_index] < 0)
                    return error.InvalidSurfaceAqueousRunoffCandidate;
            }
            setRepresentedConcentrations(&chemistry_candidate[cell], concentrations);
            dry_reference_candidate[cell] = reference_water;
        }
    }

    @memcpy(extensive.amount_mol, accepted);
    @memcpy(extensive.carrier_volume_m3, post_runoff_water_m3);
    @memcpy(chemistry.cells, chemistry_candidate);
    @memcpy(chemistry.dry_reference_water_m3, dry_reference_candidate);
    @memcpy(output.boundary_export_mol_by_cell_species, species_export);
    @memcpy(output.boundary_components_by_cell, component_export);
    @memcpy(output.intercell_debit_components_by_cell, intercell_debit);
    @memcpy(output.intercell_credit_components_by_cell, intercell_credit);
}

fn accumulateIntercellComponents(
    columns: usize,
    rows: usize,
    original_amount_mol: []const f64,
    pre_runoff_water_m3: []const f64,
    directions: Directions,
    maximum_transport_fraction: f64,
    debit: []Components,
    credit: []Components,
) !void {
    const cells = columns * rows;
    for (0..cells) |source| {
        const directional = [_]f64{
            directions.east_m3[source],
            directions.west_m3[source],
            directions.south_m3[source],
            directions.north_m3[source],
        };
        var total_water_m3: f64 = 0;
        for (directional) |water_m3| total_water_m3 += water_m3;
        if (total_water_m3 == 0) continue;
        const donor_water_m3 = pre_runoff_water_m3[source];
        const transported_fraction = if (donor_water_m3 > 0)
            @min(maximum_transport_fraction, total_water_m3 / donor_water_m3)
        else
            maximum_transport_fraction;
        const column = source % columns;
        const row = source / columns;
        const neighbors = [_]?usize{
            if (column + 1 < columns) source + 1 else null,
            if (column > 0) source - 1 else null,
            if (row + 1 < rows) source + columns else null,
            if (row > 0) source - columns else null,
        };
        for (directional, neighbors) |water_m3, destination_optional| {
            const destination = destination_optional orelse continue;
            if (water_m3 == 0) continue;
            const direction_fraction = transported_fraction * water_m3 / total_water_m3;
            inline for (@typeInfo(Species).@"enum".fields) |field| {
                const species: Species = @enumFromInt(field.value);
                if (comptime !routesSpecies(species)) continue;
                const transfer_mol = original_amount_mol[source * species_count + field.value] * direction_fraction;
                try debit[source].addScaled(formula(species), transfer_mol);
                try credit[destination].addScaled(formula(species), transfer_mol);
            }
        }
    }
}

/// Runs every dissolved surface-runoff owner against the same immutable
/// runoff snapshot. All owners and outputs are private candidates until the
/// final infallible publish, so a failure in the last gas owner cannot retain
/// earlier mineral, aqueous, or organic changes.
pub fn advanceTransaction(
    allocator: std.mem.Allocator,
    owners: TransactionOwners,
    columns: usize,
    rows: usize,
    post_runoff_water_m3: []const f64,
    runoff_water_change_m3: []const f64,
    directions: Directions,
    maximum_transport_fraction: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    carbon_g_per_mol: f64,
    output: TransactionOutput,
) !void {
    const cells = try std.math.mul(usize, columns, rows);
    const aqueous_amount_count = try std.math.mul(usize, cells, species_count);
    if (output.inorganic_nitrogen_export_g_n_by_cell.len != cells or
        output.inorganic_phosphorus_export_g_p_by_cell.len != cells or
        output.dissolved_organic_carbon_export_g_c_by_cell.len != cells or
        output.dissolved_organic_nitrogen_export_g_n_by_cell.len != cells or
        output.dissolved_organic_phosphorus_export_g_p_by_cell.len != cells or
        output.inorganic_carbon_export_g_c_by_cell.len != cells or
        output.dissolved_oxygen_export_g_o_by_cell.len != cells or
        output.dissolved_nitrogen_export_g_n_by_cell.len != cells or
        output.dissolved_hydrogen_export_g_h_by_cell.len != cells or
        output.litter_salt_ion_export_mol_by_cell.len != cells or
        output.aqueous_boundary_export_mol_by_cell_species.len != aqueous_amount_count or
        output.aqueous_boundary_components_by_cell.len != cells or
        output.aqueous_intercell_debit_components_by_cell.len != cells or
        output.aqueous_intercell_credit_components_by_cell.len != cells or
        output.dedicated_intercell_debit_by_cell.len != cells or
        output.dedicated_intercell_credit_by_cell.len != cells)
        return error.SurfaceRunoffTransactionDimensionMismatch;
    inline for (.{ nitrogen_g_per_mol, phosphorus_g_per_mol, carbon_g_per_mol }) |molar_mass|
        if (!std.math.isFinite(molar_mass) or molar_mass <= 0)
            return error.InvalidSurfaceRunoffTransactionMolarMass;

    const chemistry_cells = try allocator.dupe(ChemistryCell, owners.chemistry.cells);
    defer allocator.free(chemistry_cells);
    const mineral_reference = try allocator.dupe(f64, owners.chemistry.mineral_reference_water_m3);
    defer allocator.free(mineral_reference);
    const dry_reference = try allocator.dupe(f64, owners.chemistry.dry_reference_water_m3);
    defer allocator.free(dry_reference);
    const water_equilibrium_balance = try allocator.dupe(
        f64,
        owners.chemistry.water_equilibrium_balance_mol,
    );
    defer allocator.free(water_equilibrium_balance);
    var chemistry_candidate: Chemistry = .{
        .allocator = allocator,
        .cells = chemistry_cells,
        .ph = owners.chemistry.ph,
        .mineral_reference_water_m3 = mineral_reference,
        .dry_reference_water_m3 = dry_reference,
        .water_equilibrium_balance_mol = water_equilibrium_balance,
    };
    const nitrite_candidate = try allocator.dupe(f64, owners.nitrite_g_n);
    defer allocator.free(nitrite_candidate);

    var aqueous_candidate = try surface_routing.State.init(allocator, columns, rows, species_count);
    defer aqueous_candidate.deinit();
    if (owners.aqueous.columns != columns or owners.aqueous.rows != rows or
        owners.aqueous.species_count != species_count or
        owners.aqueous.carrier_volume_m3.len != cells or
        owners.aqueous.amount_mol.len != aqueous_amount_count)
        return error.SurfaceRunoffTransactionDimensionMismatch;
    @memcpy(aqueous_candidate.carrier_volume_m3, owners.aqueous.carrier_volume_m3);
    @memcpy(aqueous_candidate.amount_mol, owners.aqueous.amount_mol);

    var organic_candidate = owners.organic.*;
    organic_candidate.dissolved = try allocator.dupe(@TypeOf(owners.organic.dissolved[0]), owners.organic.dissolved);
    defer allocator.free(organic_candidate.dissolved);
    organic_candidate.dissolved_acetate_carbon_g_c = try allocator.dupe(f64, owners.organic.dissolved_acetate_carbon_g_c);
    defer allocator.free(organic_candidate.dissolved_acetate_carbon_g_c);

    var gas_candidate = owners.gas.*;
    gas_candidate.dissolved_mass_g = try allocator.dupe(f64, owners.gas.dissolved_mass_g);
    defer allocator.free(gas_candidate.dissolved_mass_g);

    const nitrogen_export = try allocator.alloc(f64, cells);
    defer allocator.free(nitrogen_export);
    const phosphorus_export = try allocator.alloc(f64, cells);
    defer allocator.free(phosphorus_export);
    const mineral_ion_export = try allocator.alloc(f64, cells);
    defer allocator.free(mineral_ion_export);
    const organic_carbon_export = try allocator.alloc(f64, cells);
    defer allocator.free(organic_carbon_export);
    const organic_nitrogen_export = try allocator.alloc(f64, cells);
    defer allocator.free(organic_nitrogen_export);
    const organic_phosphorus_export = try allocator.alloc(f64, cells);
    defer allocator.free(organic_phosphorus_export);
    const inorganic_carbon_export = try allocator.alloc(f64, cells);
    defer allocator.free(inorganic_carbon_export);
    const dissolved_oxygen_export = try allocator.alloc(f64, cells);
    defer allocator.free(dissolved_oxygen_export);
    const dissolved_nitrogen_export = try allocator.alloc(f64, cells);
    defer allocator.free(dissolved_nitrogen_export);
    const dissolved_hydrogen_export = try allocator.alloc(f64, cells);
    defer allocator.free(dissolved_hydrogen_export);
    const mineral_intercell_debit = try allocator.alloc(ElementMass, cells);
    defer allocator.free(mineral_intercell_debit);
    const mineral_intercell_credit = try allocator.alloc(ElementMass, cells);
    defer allocator.free(mineral_intercell_credit);
    const organic_intercell_debit = try allocator.alloc(ElementMass, cells);
    defer allocator.free(organic_intercell_debit);
    const organic_intercell_credit = try allocator.alloc(ElementMass, cells);
    defer allocator.free(organic_intercell_credit);
    const gas_intercell_debit = try allocator.alloc(ElementMass, cells);
    defer allocator.free(gas_intercell_debit);
    const gas_intercell_credit = try allocator.alloc(ElementMass, cells);
    defer allocator.free(gas_intercell_credit);
    const dedicated_intercell_debit = try allocator.alloc(ElementMass, cells);
    defer allocator.free(dedicated_intercell_debit);
    const dedicated_intercell_credit = try allocator.alloc(ElementMass, cells);
    defer allocator.free(dedicated_intercell_credit);
    const aqueous_species_export = try allocator.alloc(f64, aqueous_amount_count);
    defer allocator.free(aqueous_species_export);
    const aqueous_components = try allocator.alloc(Components, cells);
    defer allocator.free(aqueous_components);
    const aqueous_intercell_debit = try allocator.alloc(Components, cells);
    defer allocator.free(aqueous_intercell_debit);
    const aqueous_intercell_credit = try allocator.alloc(Components, cells);
    defer allocator.free(aqueous_intercell_credit);
    const litter_salt_ion_export = try allocator.alloc(f64, cells);
    defer allocator.free(litter_salt_ion_export);

    try mineral_transport.advance(
        allocator,
        &chemistry_candidate,
        nitrite_candidate,
        columns,
        rows,
        post_runoff_water_m3,
        runoff_water_change_m3,
        .{
            .east_m3 = directions.east_m3,
            .west_m3 = directions.west_m3,
            .south_m3 = directions.south_m3,
            .north_m3 = directions.north_m3,
        },
        maximum_transport_fraction,
        nitrogen_g_per_mol,
        phosphorus_g_per_mol,
        .{
            .inorganic_nitrogen_export_g_n_by_cell = nitrogen_export,
            .inorganic_phosphorus_export_g_p_by_cell = phosphorus_export,
            .ion_export_mol_by_cell = mineral_ion_export,
            .intercell = .{ .debit_by_cell = mineral_intercell_debit, .credit_by_cell = mineral_intercell_credit },
        },
    );
    try advance(
        allocator,
        &chemistry_candidate,
        &aqueous_candidate,
        columns,
        rows,
        post_runoff_water_m3,
        runoff_water_change_m3,
        directions,
        maximum_transport_fraction,
        .{
            .boundary_export_mol_by_cell_species = aqueous_species_export,
            .boundary_components_by_cell = aqueous_components,
            .intercell_debit_components_by_cell = aqueous_intercell_debit,
            .intercell_credit_components_by_cell = aqueous_intercell_credit,
        },
    );
    try daily_litter_salt.boundaryIonExportByCell(
        aqueous_species_export,
        cells,
        species_count,
        litter_salt_ion_export,
    );
    for (litter_salt_ion_export, mineral_ion_export) |generic, dedicated| {
        const total = generic + dedicated;
        if (!std.math.isFinite(total) or total < 0)
            return error.InvalidSurfaceRunoffTransactionBoundaryExport;
    }
    for (litter_salt_ion_export, mineral_ion_export) |*generic, dedicated|
        generic.* += dedicated;
    try organic_transport.advance(
        allocator,
        &organic_candidate,
        columns,
        rows,
        post_runoff_water_m3,
        runoff_water_change_m3,
        .{
            .east_m3 = directions.east_m3,
            .west_m3 = directions.west_m3,
            .south_m3 = directions.south_m3,
            .north_m3 = directions.north_m3,
        },
        maximum_transport_fraction,
        .{
            .dissolved_organic_carbon_export_g_c_by_cell = organic_carbon_export,
            .dissolved_organic_nitrogen_export_g_n_by_cell = organic_nitrogen_export,
            .dissolved_organic_phosphorus_export_g_p_by_cell = organic_phosphorus_export,
            .intercell = .{ .debit_by_cell = organic_intercell_debit, .credit_by_cell = organic_intercell_credit },
        },
    );
    try dissolved_gas_transport.advance(
        allocator,
        &gas_candidate,
        columns,
        rows,
        post_runoff_water_m3,
        runoff_water_change_m3,
        .{
            .east_m3 = directions.east_m3,
            .west_m3 = directions.west_m3,
            .south_m3 = directions.south_m3,
            .north_m3 = directions.north_m3,
        },
        maximum_transport_fraction,
        .{
            .inorganic_carbon_export_g_c_by_cell = inorganic_carbon_export,
            .dissolved_oxygen_export_g_o_by_cell = dissolved_oxygen_export,
            .dissolved_nitrogen_export_g_n_by_cell = dissolved_nitrogen_export,
            .dissolved_hydrogen_export_g_h_by_cell = dissolved_hydrogen_export,
            .intercell = .{ .debit_by_cell = gas_intercell_debit, .credit_by_cell = gas_intercell_credit },
        },
    );
    for (0..cells) |cell| {
        const carbon = inorganic_carbon_export[cell] +
            aqueous_components[cell].carbon_mol * carbon_g_per_mol;
        const phosphorus = phosphorus_export[cell] +
            aqueous_components[cell].phosphorus_mol * phosphorus_g_per_mol;
        if (!std.math.isFinite(carbon) or carbon < 0 or
            !std.math.isFinite(phosphorus) or phosphorus < 0)
            return error.InvalidSurfaceRunoffTransactionBoundaryExport;
        inorganic_carbon_export[cell] = carbon;
        phosphorus_export[cell] = phosphorus;
        dedicated_intercell_debit[cell] = try (try mineral_intercell_debit[cell].add(
            organic_intercell_debit[cell],
        )).add(gas_intercell_debit[cell]);
        dedicated_intercell_credit[cell] = try (try mineral_intercell_credit[cell].add(
            organic_intercell_credit[cell],
        )).add(gas_intercell_credit[cell]);
    }

    @memcpy(owners.chemistry.cells, chemistry_candidate.cells);
    @memcpy(owners.chemistry.mineral_reference_water_m3, chemistry_candidate.mineral_reference_water_m3);
    @memcpy(owners.chemistry.dry_reference_water_m3, chemistry_candidate.dry_reference_water_m3);
    @memcpy(owners.chemistry.water_equilibrium_balance_mol, chemistry_candidate.water_equilibrium_balance_mol);
    @memcpy(owners.nitrite_g_n, nitrite_candidate);
    @memcpy(owners.aqueous.carrier_volume_m3, aqueous_candidate.carrier_volume_m3);
    @memcpy(owners.aqueous.amount_mol, aqueous_candidate.amount_mol);
    @memcpy(owners.organic.dissolved, organic_candidate.dissolved);
    @memcpy(owners.organic.dissolved_acetate_carbon_g_c, organic_candidate.dissolved_acetate_carbon_g_c);
    @memcpy(owners.gas.dissolved_mass_g, gas_candidate.dissolved_mass_g);
    @memcpy(output.inorganic_nitrogen_export_g_n_by_cell, nitrogen_export);
    @memcpy(output.inorganic_phosphorus_export_g_p_by_cell, phosphorus_export);
    @memcpy(output.dissolved_organic_carbon_export_g_c_by_cell, organic_carbon_export);
    @memcpy(output.dissolved_organic_nitrogen_export_g_n_by_cell, organic_nitrogen_export);
    @memcpy(output.dissolved_organic_phosphorus_export_g_p_by_cell, organic_phosphorus_export);
    @memcpy(output.inorganic_carbon_export_g_c_by_cell, inorganic_carbon_export);
    @memcpy(output.dissolved_oxygen_export_g_o_by_cell, dissolved_oxygen_export);
    @memcpy(output.dissolved_nitrogen_export_g_n_by_cell, dissolved_nitrogen_export);
    @memcpy(output.dissolved_hydrogen_export_g_h_by_cell, dissolved_hydrogen_export);
    @memcpy(output.litter_salt_ion_export_mol_by_cell, litter_salt_ion_export);
    @memcpy(output.aqueous_boundary_export_mol_by_cell_species, aqueous_species_export);
    @memcpy(output.aqueous_boundary_components_by_cell, aqueous_components);
    @memcpy(output.aqueous_intercell_debit_components_by_cell, aqueous_intercell_debit);
    @memcpy(output.aqueous_intercell_credit_components_by_cell, aqueous_intercell_credit);
    @memcpy(output.dedicated_intercell_debit_by_cell, dedicated_intercell_debit);
    @memcpy(output.dedicated_intercell_credit_by_cell, dedicated_intercell_credit);
}

fn representedConcentrations(cell: ChemistryCell) [12]f64 {
    return .{
        cell.aluminum_mol_per_m3,
        cell.iron_mol_per_m3,
        cell.hydrogen_mol_per_m3,
        cell.calcium_mol_per_m3,
        cell.magnesium_mol_per_m3,
        cell.sodium_mol_per_m3,
        cell.potassium_mol_per_m3,
        cell.hydroxide_mol_per_m3,
        cell.sulfate_mol_per_m3,
        cell.chloride_mol_per_m3,
        cell.carbonate_mol_per_m3,
        cell.bicarbonate_mol_per_m3,
    };
}

fn setRepresentedConcentrations(cell: *ChemistryCell, values: [12]f64) void {
    cell.aluminum_mol_per_m3 = values[0];
    cell.iron_mol_per_m3 = values[1];
    cell.hydrogen_mol_per_m3 = values[2];
    cell.calcium_mol_per_m3 = values[3];
    cell.magnesium_mol_per_m3 = values[4];
    cell.sodium_mol_per_m3 = values[5];
    cell.potassium_mol_per_m3 = values[6];
    cell.hydroxide_mol_per_m3 = values[7];
    cell.sulfate_mol_per_m3 = values[8];
    cell.chloride_mol_per_m3 = values[9];
    cell.carbonate_mol_per_m3 = values[10];
    cell.bicarbonate_mol_per_m3 = values[11];
}

test "REDIST tillage surface adapter binds all 42 authoritative coordinates in source order" {
    var chemistry = try Chemistry.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    var extensive = try surface_routing.State.init(std.testing.allocator, 1, 1, species_count);
    defer extensive.deinit();

    var represented: [12]f64 = undefined;
    for (&represented, 0..) |*value, index|
        value.* = @floatFromInt(index + 1);
    setRepresentedConcentrations(&chemistry.cells[0], represented);
    chemistry.dry_reference_water_m3[0] = 2;
    for (12..surface_species_count) |species_index|
        extensive.amount_mol[species_index] = @floatFromInt(species_index + 1);
    extensive.amount_mol[@intFromEnum(Species.band_phosphate)] = 99;

    const gathered = try gatherTillageSurfaceAmounts(&chemistry, &extensive, 0, 0, 0);
    for (0..12) |species_index|
        try std.testing.expectEqual(
            2 * @as(f64, @floatFromInt(species_index + 1)),
            gathered[species_index],
        );
    for (12..surface_species_count) |species_index|
        try std.testing.expectEqual(
            @as(f64, @floatFromInt(species_index + 1)),
            gathered[species_index],
        );

    var remaining = gathered;
    for (&remaining) |*amount| amount.* *= 0.5;
    try commitTillageSurfaceAmounts(&chemistry, &extensive, 0, 0, 1, remaining);
    try std.testing.expectEqual(@as(f64, 1), chemistry.cells[0].aluminum_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 2), chemistry.cells[0].iron_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 3), chemistry.cells[0].hydrogen_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 8), chemistry.cells[0].hydroxide_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 1), chemistry.dry_reference_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 0), extensive.carrier_volume_m3[0]);
    for (0..surface_species_count) |species_index|
        try std.testing.expectEqual(remaining[species_index], extensive.amount_mol[species_index]);
    try std.testing.expectEqual(
        @as(f64, 99),
        extensive.amount_mol[@intFromEnum(Species.band_phosphate)],
    );
    try std.testing.expectEqualDeep(
        remaining,
        try gatherTillageSurfaceAmounts(&chemistry, &extensive, 0, 0, 0),
    );
}

test "REDIST tillage surface owner publish rejects a late invalid coordinate atomically" {
    var chemistry = try Chemistry.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    var extensive = try surface_routing.State.init(std.testing.allocator, 1, 1, species_count);
    defer extensive.deinit();
    chemistry.cells[0].aluminum_mol_per_m3 = 4;
    chemistry.dry_reference_water_m3[0] = 0.5;
    extensive.carrier_volume_m3[0] = 0.25;
    extensive.amount_mol[@intFromEnum(Species.aluminum_hydroxide_1)] = 7;
    const chemistry_before = chemistry.cells[0];
    const dry_before = chemistry.dry_reference_water_m3[0];
    const carrier_before = extensive.carrier_volume_m3[0];
    const amounts_before = try std.testing.allocator.dupe(f64, extensive.amount_mol);
    defer std.testing.allocator.free(amounts_before);

    var invalid: TillageSurfaceAmounts = @splat(1);
    invalid[surface_species_count - 1] = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidTillageSurfaceAqueousOwner,
        commitTillageSurfaceAmounts(&chemistry, &extensive, 0, 0.25, 0.25, invalid),
    );
    try std.testing.expectEqualDeep(chemistry_before, chemistry.cells[0]);
    try std.testing.expectEqual(dry_before, chemistry.dry_reference_water_m3[0]);
    try std.testing.expectEqual(carrier_before, extensive.carrier_volume_m3[0]);
    try std.testing.expectEqualSlices(f64, amounts_before, extensive.amount_mol);
}

test "issue-069 Finding B: tillageSurfaceWaterCarrierM3 substitutes the dry reference at and below the ZEROS2 floor instead of only at exact zero" {
    const negligible = legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(1.0);
    try std.testing.expectEqual(@as(f64, 1.0e-6), negligible);

    // A near-zero-but-nonzero raw carrier -- the exact shape this defect
    // class manufactures fake mass from at issue-060/061/063/064/065/066's
    // other sites.
    const near_zero_raw_carrier: f64 = 1.0e-9;
    try std.testing.expect(near_zero_raw_carrier > 0);
    const dry_reference_m3: f64 = 0.5;
    const concentration_mol_per_m3: f64 = 20.0;

    // OLD guard (bare `> 0`, this file's behavior before this fix): the
    // near-zero raw carrier is accepted as "real", manufacturing a fake mass
    // more than eight orders of magnitude below the physically correct
    // value.
    const old_carrier = if (near_zero_raw_carrier > 0) near_zero_raw_carrier else dry_reference_m3;
    const old_mass_mol = concentration_mol_per_m3 * old_carrier;
    try std.testing.expectEqual(@as(f64, 1.0e-9), old_carrier);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0e-8), old_mass_mol, 1e-22);

    // NEW guard (this fix): the same near-zero raw carrier is at/below the
    // ZEROS2-equivalent floor, so the remembered dry reference is
    // substituted instead, producing a stable, physically sensible mass.
    const new_carrier = tillageSurfaceWaterCarrierM3(near_zero_raw_carrier, dry_reference_m3, negligible);
    const new_mass_mol = concentration_mol_per_m3 * new_carrier;
    try std.testing.expectEqual(dry_reference_m3, new_carrier);
    try std.testing.expectEqual(@as(f64, 10.0), new_mass_mol);
    try std.testing.expect(new_mass_mol / old_mass_mol > 1.0e8);

    // Strictly above the floor: both guards agree and keep the live carrier.
    const just_above = std.math.nextAfter(f64, negligible, std.math.inf(f64));
    try std.testing.expectEqual(just_above, tillageSurfaceWaterCarrierM3(just_above, dry_reference_m3, negligible));
    // At exactly the floor: OLD guard (`> 0`) would still have kept the live
    // carrier since `negligible > 0`, but NEW guard substitutes the dry
    // reference -- this is the boundary the fix actually widens.
    try std.testing.expect(negligible > 0);
    try std.testing.expectEqual(dry_reference_m3, tillageSurfaceWaterCarrierM3(negligible, dry_reference_m3, negligible));
}

test "issue-069 Finding B: near-zero-but-nonzero actual_water_m3 no longer manufactures a fake mass swing in gatherTillageSurfaceAmounts" {
    var chemistry = try Chemistry.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    var extensive = try surface_routing.State.init(std.testing.allocator, 1, 1, species_count);
    defer extensive.deinit();
    chemistry.cells[0].aluminum_mol_per_m3 = 20;
    chemistry.dry_reference_water_m3[0] = 0.5;

    const near_zero_raw_carrier: f64 = 1.0e-9;
    const negligible = legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(1.0);

    // OLD (pre-fix) behavior, replicated manually: the bare
    // `actual_water_m3 > 0` guard accepted the near-zero raw carrier as
    // "real", manufacturing a fake mass more than six orders of magnitude
    // below the physically correct value (dry-reference basis).
    const old_gathered_aluminum_mol = chemistry.cells[0].aluminum_mol_per_m3 * near_zero_raw_carrier;
    const true_mol = chemistry.cells[0].aluminum_mol_per_m3 * chemistry.dry_reference_water_m3[0];
    try std.testing.expect(old_gathered_aluminum_mol / true_mol < 1.0e-6);

    // NEW (fixed) behavior: the widened guard substitutes the dry reference
    // for the near-zero raw carrier, matching the physically correct basis
    // exactly, and stays stable across the ZEROS2-equivalent floor.
    const gathered = try gatherTillageSurfaceAmounts(&chemistry, &extensive, 0, near_zero_raw_carrier, negligible);
    try std.testing.expectEqual(true_mol, gathered[@intFromEnum(Species.aluminum)]);
}

/// Molecular formula of every runtime aqueous coordinate. `*_phosphate` is
/// PO4 and `*_phosphoric_acid` is H3PO4; HPO4/H2PO4 have separate explicit
/// chemistry fields and are not aliased onto these coordinates.
pub fn formula(species: Species) Components {
    return switch (species) {
        .aluminum => .{ .aluminum_mol = 1 },
        .iron => .{ .iron_mol = 1 },
        .hydrogen => .{ .hydrogen_mol = 1 },
        .calcium => .{ .calcium_mol = 1 },
        .magnesium => .{ .magnesium_mol = 1 },
        .sodium => .{ .sodium_mol = 1 },
        .potassium => .{ .potassium_mol = 1 },
        .hydroxide => .{ .hydrogen_mol = 1, .oxygen_mol = 1 },
        .sulfate => .{ .sulfur_mol = 1, .oxygen_mol = 4 },
        .chloride => .{ .chloride_mol = 1 },
        .carbonate => .{ .carbon_mol = 1, .oxygen_mol = 3 },
        .bicarbonate => .{ .hydrogen_mol = 1, .carbon_mol = 1, .oxygen_mol = 3 },
        .aluminum_hydroxide_1 => .{ .aluminum_mol = 1, .hydrogen_mol = 1, .oxygen_mol = 1 },
        .aluminum_hydroxide_2 => .{ .aluminum_mol = 1, .hydrogen_mol = 2, .oxygen_mol = 2 },
        .aluminum_hydroxide_3 => .{ .aluminum_mol = 1, .hydrogen_mol = 3, .oxygen_mol = 3 },
        .aluminum_hydroxide_4 => .{ .aluminum_mol = 1, .hydrogen_mol = 4, .oxygen_mol = 4 },
        .aluminum_sulfate => .{ .aluminum_mol = 1, .sulfur_mol = 1, .oxygen_mol = 4 },
        .iron_hydroxide_1 => .{ .iron_mol = 1, .hydrogen_mol = 1, .oxygen_mol = 1 },
        .iron_hydroxide_2 => .{ .iron_mol = 1, .hydrogen_mol = 2, .oxygen_mol = 2 },
        .iron_hydroxide_3 => .{ .iron_mol = 1, .hydrogen_mol = 3, .oxygen_mol = 3 },
        .iron_hydroxide_4 => .{ .iron_mol = 1, .hydrogen_mol = 4, .oxygen_mol = 4 },
        .iron_sulfate => .{ .iron_mol = 1, .sulfur_mol = 1, .oxygen_mol = 4 },
        .calcium_hydroxide => .{ .calcium_mol = 1, .hydrogen_mol = 1, .oxygen_mol = 1 },
        .calcium_carbonate => .{ .calcium_mol = 1, .carbon_mol = 1, .oxygen_mol = 3 },
        .calcium_bicarbonate => .{ .calcium_mol = 1, .hydrogen_mol = 1, .carbon_mol = 1, .oxygen_mol = 3 },
        .calcium_sulfate => .{ .calcium_mol = 1, .sulfur_mol = 1, .oxygen_mol = 4 },
        .magnesium_hydroxide => .{ .magnesium_mol = 1, .hydrogen_mol = 1, .oxygen_mol = 1 },
        .magnesium_carbonate => .{ .magnesium_mol = 1, .carbon_mol = 1, .oxygen_mol = 3 },
        .magnesium_bicarbonate => .{ .magnesium_mol = 1, .hydrogen_mol = 1, .carbon_mol = 1, .oxygen_mol = 3 },
        .magnesium_sulfate => .{ .magnesium_mol = 1, .sulfur_mol = 1, .oxygen_mol = 4 },
        .sodium_carbonate => .{ .sodium_mol = 1, .carbon_mol = 1, .oxygen_mol = 3 },
        .sodium_sulfate => .{ .sodium_mol = 1, .sulfur_mol = 1, .oxygen_mol = 4 },
        .potassium_sulfate => .{ .potassium_mol = 1, .sulfur_mol = 1, .oxygen_mol = 4 },
        .hydrogen_silicate => .{ .hydrogen_mol = 4, .silicon_mol = 1, .oxygen_mol = 4 },
        .non_band_phosphate, .band_phosphate => .{ .phosphorus_mol = 1, .oxygen_mol = 4 },
        .non_band_hpo4, .band_hpo4 => .{ .hydrogen_mol = 1, .phosphorus_mol = 1, .oxygen_mol = 4 },
        .non_band_h2po4, .band_h2po4 => .{ .hydrogen_mol = 2, .phosphorus_mol = 1, .oxygen_mol = 4 },
        .non_band_phosphoric_acid, .band_phosphoric_acid => .{ .hydrogen_mol = 3, .phosphorus_mol = 1, .oxygen_mol = 4 },
        .non_band_iron_hpo4, .band_iron_hpo4 => .{ .iron_mol = 1, .hydrogen_mol = 1, .phosphorus_mol = 1, .oxygen_mol = 4 },
        .non_band_iron_h2po4, .band_iron_h2po4 => .{ .iron_mol = 1, .hydrogen_mol = 2, .phosphorus_mol = 1, .oxygen_mol = 4 },
        .non_band_calcium_phosphate, .band_calcium_phosphate => .{ .calcium_mol = 1, .phosphorus_mol = 1, .oxygen_mol = 4 },
        .non_band_calcium_hpo4, .band_calcium_hpo4 => .{ .calcium_mol = 1, .hydrogen_mol = 1, .phosphorus_mol = 1, .oxygen_mol = 4 },
        .non_band_calcium_h2po4, .band_calcium_h2po4 => .{ .calcium_mol = 1, .hydrogen_mol = 2, .phosphorus_mol = 1, .oxygen_mol = 4 },
        .non_band_magnesium_hpo4, .band_magnesium_hpo4 => .{ .magnesium_mol = 1, .hydrogen_mol = 1, .phosphorus_mol = 1, .oxygen_mol = 4 },
    };
}

fn setRepresentedFixture(cell: anytype) void {
    cell.aluminum_mol_per_m3 = 1;
    cell.iron_mol_per_m3 = 2;
    cell.hydrogen_mol_per_m3 = 3;
    cell.calcium_mol_per_m3 = 4;
    cell.magnesium_mol_per_m3 = 5;
    cell.sodium_mol_per_m3 = 6;
    cell.potassium_mol_per_m3 = 7;
    cell.hydroxide_mol_per_m3 = 8;
    cell.sulfate_mol_per_m3 = 9;
    cell.chloride_mol_per_m3 = 10;
    cell.carbonate_mol_per_m3 = 11;
    cell.bicarbonate_mol_per_m3 = 12;
}

test "surface aqueous runoff routes every authoritative species once and publishes formula components" {
    const po4 = formula(.non_band_phosphate);
    const h3po4 = formula(.non_band_phosphoric_acid);
    try std.testing.expect(routesSpecies(.non_band_phosphate));
    try std.testing.expect(routesSpecies(.non_band_phosphoric_acid));
    try std.testing.expect(!routesSpecies(.non_band_hpo4));
    try std.testing.expect(!routesSpecies(.non_band_h2po4));
    try std.testing.expectEqual(@as(f64, 0), po4.hydrogen_mol);
    try std.testing.expectEqual(@as(f64, 1), po4.phosphorus_mol);
    try std.testing.expectEqual(@as(f64, 4), po4.oxygen_mol);
    try std.testing.expectEqual(@as(f64, 3), h3po4.hydrogen_mol);
    try std.testing.expectEqual(@as(f64, 1), h3po4.phosphorus_mol);
    try std.testing.expectEqual(@as(f64, 4), h3po4.oxygen_mol);
    var chemistry = try Chemistry.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    setRepresentedFixture(&chemistry.cells[0]);
    var extensive = try surface_routing.State.init(std.testing.allocator, 1, 1, species_count);
    defer extensive.deinit();
    extensive.carrier_volume_m3[0] = 1;
    for (extensive.amount_mol, 0..) |*amount, index|
        amount.* = @as(f64, @floatFromInt(index + 1));
    var species_export: [species_count]f64 = @splat(99);
    var components = [_]Components{.{}};
    var debit = [_]Components{.{}};
    var credit = [_]Components{.{}};
    const half = [_]f64{0.5};
    const zero = [_]f64{0};
    try advance(
        std.testing.allocator,
        &chemistry,
        &extensive,
        1,
        1,
        &.{0.5},
        &.{-0.5},
        .{ .east_m3 = &half, .west_m3 = &zero, .south_m3 = &zero, .north_m3 = &zero },
        1,
        .{ .boundary_export_mol_by_cell_species = &species_export, .boundary_components_by_cell = &components, .intercell_debit_components_by_cell = &debit, .intercell_credit_components_by_cell = &credit },
    );

    var expected_components: Components = .{};
    inline for (@typeInfo(Species).@"enum".fields) |field| {
        const species: Species = @enumFromInt(field.value);
        const index: usize = field.value;
        if (routesSpecies(species)) {
            const original = @as(f64, @floatFromInt(index + 1));
            try std.testing.expectEqual(0.5 * original, extensive.amount_mol[index]);
            try std.testing.expectEqual(0.5 * original, species_export[index]);
            try expected_components.addScaled(formula(species), 0.5 * original);
        } else {
            try std.testing.expectEqual(@as(f64, @floatFromInt(index + 1)), extensive.amount_mol[index]);
            try std.testing.expectEqual(@as(f64, 0), species_export[index]);
        }
    }
    inline for (@typeInfo(Components).@"struct".fields) |field|
        try std.testing.expectEqual(@field(expected_components, field.name), @field(components[0], field.name));
    try std.testing.expectEqual(@as(f64, 0.5), extensive.carrier_volume_m3[0]);
    // Water and every represented routed amount halve together, so their
    // concentrations remain unchanged.
    try std.testing.expectEqual(@as(f64, 6), chemistry.cells[0].sodium_mol_per_m3);
}

test "all 54 aqueous registry coordinates have exactly one runoff owner or physical exclusion" {
    try std.testing.expectEqual(@as(usize, 54), species_count);
    var generic_count: usize = 0;
    var mineral_count: usize = 0;
    var soil_only_count: usize = 0;
    inline for (@typeInfo(Species).@"enum".fields) |field| {
        const species: Species = @enumFromInt(field.value);
        const ownership = runoffOwnership(species);
        switch (ownership) {
            .generic_aqueous => generic_count += 1,
            .dedicated_mineral => mineral_count += 1,
            .soil_only => soil_only_count += 1,
        }
        try std.testing.expectEqual(
            ownership == .generic_aqueous,
            routesSpecies(species),
        );
        // The source-order 42-coordinate surface salt adapter and the
        // formula-bearing runtime adapter must select the identical set.
        try std.testing.expectEqual(
            ownership == .generic_aqueous,
            overland_litter_salt.routesSpecies(species),
        );
    }
    try std.testing.expectEqual(@as(usize, 42), generic_count);
    try std.testing.expectEqual(@as(usize, 2), mineral_count);
    try std.testing.expectEqual(@as(usize, 10), soil_only_count);
    try std.testing.expectEqual(RunoffOwnership.dedicated_mineral, runoffOwnership(.non_band_hpo4));
    try std.testing.expectEqual(RunoffOwnership.dedicated_mineral, runoffOwnership(.non_band_h2po4));
}

test "surface aqueous runoff internal all-species routing conserves every coordinate exactly" {
    var chemistry = try Chemistry.init(std.testing.allocator, 2);
    defer chemistry.deinit();
    setRepresentedFixture(&chemistry.cells[0]);
    var extensive = try surface_routing.State.init(std.testing.allocator, 2, 1, species_count);
    defer extensive.deinit();
    extensive.carrier_volume_m3[0] = 1;
    extensive.carrier_volume_m3[1] = 1;
    for (0..species_count) |species_index|
        extensive.amount_mol[species_index] = @as(f64, @floatFromInt(species_index + 1));
    var species_export: [2 * species_count]f64 = @splat(77);
    var components = [_]Components{ .{}, .{} };
    var debit = [_]Components{ .{}, .{} };
    var credit = [_]Components{ .{}, .{} };
    const east = [_]f64{ 0.5, 0 };
    const zero = [_]f64{ 0, 0 };
    try advance(
        std.testing.allocator,
        &chemistry,
        &extensive,
        2,
        1,
        &.{ 0.5, 1.5 },
        &.{ -0.5, 0.5 },
        .{ .east_m3 = &east, .west_m3 = &zero, .south_m3 = &zero, .north_m3 = &zero },
        1,
        .{ .boundary_export_mol_by_cell_species = &species_export, .boundary_components_by_cell = &components, .intercell_debit_components_by_cell = &debit, .intercell_credit_components_by_cell = &credit },
    );
    inline for (@typeInfo(Species).@"enum".fields) |field| {
        const index: usize = field.value;
        const species: Species = @enumFromInt(field.value);
        const total = extensive.amount_mol[index] + extensive.amount_mol[species_count + index];
        try std.testing.expectEqual(@as(f64, @floatFromInt(index + 1)), total);
        if (routesSpecies(species))
            try std.testing.expectEqual(@as(f64, 0), species_export[index]);
    }
    inline for (@typeInfo(Components).@"struct".fields) |field| {
        try std.testing.expectEqual(@field(debit[0], field.name), @field(credit[1], field.name));
        try std.testing.expectEqual(@as(f64, 0), @field(credit[0], field.name));
        try std.testing.expectEqual(@as(f64, 0), @field(debit[1], field.name));
    }
}

test "surface aqueous runoff late component failure rolls back state chemistry references and outputs exactly" {
    var chemistry = try Chemistry.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    setRepresentedFixture(&chemistry.cells[0]);
    chemistry.dry_reference_water_m3[0] = 3;
    var extensive = try surface_routing.State.init(std.testing.allocator, 1, 1, species_count);
    defer extensive.deinit();
    @memset(extensive.carrier_volume_m3, 1);
    for (extensive.amount_mol, 0..) |*amount, index|
        amount.* = @as(f64, @floatFromInt(index + 1));
    // Three independently valid Al-bearing complex exports overflow only when
    // formula components are accumulated, after the routing candidate exists.
    // This exercises the latest fallible stage before the atomic commit.
    extensive.amount_mol[@intFromEnum(Species.aluminum_hydroxide_1)] = std.math.floatMax(f64) / 2;
    extensive.amount_mol[@intFromEnum(Species.aluminum_hydroxide_2)] = std.math.floatMax(f64) / 2;
    extensive.amount_mol[@intFromEnum(Species.aluminum_hydroxide_3)] = std.math.floatMax(f64) / 2;
    const amounts_before = try std.testing.allocator.dupe(f64, extensive.amount_mol);
    defer std.testing.allocator.free(amounts_before);
    const carriers_before = try std.testing.allocator.dupe(f64, extensive.carrier_volume_m3);
    defer std.testing.allocator.free(carriers_before);
    const chemistry_before = try std.testing.allocator.dupe(@TypeOf(chemistry.cells[0]), chemistry.cells);
    defer std.testing.allocator.free(chemistry_before);
    const references_before = try std.testing.allocator.dupe(f64, chemistry.dry_reference_water_m3);
    defer std.testing.allocator.free(references_before);
    var species_export: [species_count]f64 = @splat(91);
    var components = [_]Components{.{ .sodium_mol = 17 }};
    var debit = [_]Components{.{ .sodium_mol = 19 }};
    var credit = [_]Components{.{ .sodium_mol = 23 }};
    const species_output_before = species_export;
    const component_output_before = components;
    const debit_output_before = debit;
    const credit_output_before = credit;
    const one = [_]f64{1};
    const zero = [_]f64{0};
    try std.testing.expectError(
        error.InvalidSurfaceAqueousComponentExport,
        advance(
            std.testing.allocator,
            &chemistry,
            &extensive,
            1,
            1,
            &.{0},
            &.{-1},
            .{ .east_m3 = &one, .west_m3 = &zero, .south_m3 = &zero, .north_m3 = &zero },
            1,
            .{ .boundary_export_mol_by_cell_species = &species_export, .boundary_components_by_cell = &components, .intercell_debit_components_by_cell = &debit, .intercell_credit_components_by_cell = &credit },
        ),
    );
    try std.testing.expectEqualSlices(f64, amounts_before, extensive.amount_mol);
    try std.testing.expectEqualSlices(f64, carriers_before, extensive.carrier_volume_m3);
    try std.testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(chemistry_before), std.mem.sliceAsBytes(chemistry.cells)));
    try std.testing.expectEqualSlices(f64, references_before, chemistry.dry_reference_water_m3);
    try std.testing.expectEqualSlices(f64, &species_output_before, &species_export);
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&component_output_before), std.mem.asBytes(&components)));
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&debit_output_before), std.mem.asBytes(&debit)));
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&credit_output_before), std.mem.asBytes(&credit)));
}

const TransactionTestOutputs = struct {
    nitrogen: [1]f64 = @splat(0),
    phosphorus: [1]f64 = @splat(0),
    organic_carbon: [1]f64 = @splat(0),
    organic_nitrogen: [1]f64 = @splat(0),
    organic_phosphorus: [1]f64 = @splat(0),
    inorganic_carbon: [1]f64 = @splat(0),
    oxygen: [1]f64 = @splat(0),
    nitrogen_gas: [1]f64 = @splat(0),
    hydrogen_gas: [1]f64 = @splat(0),
    litter_salt_ion_export: [1]f64 = @splat(0),
    aqueous_species: [species_count]f64 = @splat(0),
    boundary: [1]Components = @splat(.{}),
    debit: [1]Components = @splat(.{}),
    credit: [1]Components = @splat(.{}),
    dedicated_debit: [1]ElementMass = @splat(.{}),
    dedicated_credit: [1]ElementMass = @splat(.{}),

    fn slices(self: *TransactionTestOutputs) TransactionOutput {
        return .{
            .inorganic_nitrogen_export_g_n_by_cell = &self.nitrogen,
            .inorganic_phosphorus_export_g_p_by_cell = &self.phosphorus,
            .dissolved_organic_carbon_export_g_c_by_cell = &self.organic_carbon,
            .dissolved_organic_nitrogen_export_g_n_by_cell = &self.organic_nitrogen,
            .dissolved_organic_phosphorus_export_g_p_by_cell = &self.organic_phosphorus,
            .inorganic_carbon_export_g_c_by_cell = &self.inorganic_carbon,
            .dissolved_oxygen_export_g_o_by_cell = &self.oxygen,
            .dissolved_nitrogen_export_g_n_by_cell = &self.nitrogen_gas,
            .dissolved_hydrogen_export_g_h_by_cell = &self.hydrogen_gas,
            .litter_salt_ion_export_mol_by_cell = &self.litter_salt_ion_export,
            .aqueous_boundary_export_mol_by_cell_species = &self.aqueous_species,
            .aqueous_boundary_components_by_cell = &self.boundary,
            .aqueous_intercell_debit_components_by_cell = &self.debit,
            .aqueous_intercell_credit_components_by_cell = &self.credit,
            .dedicated_intercell_debit_by_cell = &self.dedicated_debit,
            .dedicated_intercell_credit_by_cell = &self.dedicated_credit,
        };
    }
};

test "production surface runoff binds the atomic owner transaction exactly once" {
    const source = @embedFile("../stages/hourly_gas_surface_water.zig");
    const water = std.mem.indexOf(u8, source, "surface_runoff.routeWithSurfaceBoundary(") orelse return error.MissingProductionSurfaceRunoff;
    const transaction = std.mem.indexOf(u8, source, "surface_aqueous_runoff_transport.advanceTransaction(") orelse return error.MissingProductionSurfaceAqueousTransaction;
    try std.testing.expect(water < transaction);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "surface_aqueous_runoff_transport.advanceTransaction("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "surface_mineral_transport.advance("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "surface_organic_transport.advance("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "surface_dissolved_gas_transport.advance("));
}

test "surface runoff transaction merges complex carbon and phosphorus boundary exports" {
    var chemistry = try Chemistry.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    chemistry.cells[0].carbonate_mol_per_m3 = 1;
    chemistry.cells[0].hpo4_mol_p_per_m3 = 2;
    var nitrite = [_]f64{0};
    var aqueous = try surface_routing.State.init(std.testing.allocator, 1, 1, species_count);
    defer aqueous.deinit();
    aqueous.carrier_volume_m3[0] = 1;
    aqueous.amount_mol[@intFromEnum(Species.non_band_iron_hpo4)] = 4;
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] = 8;
    var output: TransactionTestOutputs = .{};
    const half = [_]f64{0.5};
    const zero = [_]f64{0};
    try advanceTransaction(
        std.testing.allocator,
        .{ .chemistry = &chemistry, .nitrite_g_n = &nitrite, .aqueous = &aqueous, .organic = &organic_state, .gas = &gas_state },
        1,
        1,
        &.{0.5},
        &.{-0.5},
        .{ .east_m3 = &half, .west_m3 = &zero, .south_m3 = &zero, .north_m3 = &zero },
        1,
        14,
        31,
        12,
        output.slices(),
    );
    // 4 g-C gas plus 0.5 mol carbonate * 12 g-C/mol.
    try std.testing.expectEqual(@as(f64, 10), output.inorganic_carbon[0]);
    // Free HPO4 (mineral owner) and FeHPO4 (aqueous owner) each leave once.
    try std.testing.expectEqual(@as(f64, 93), output.phosphorus[0]);
    try std.testing.expectEqual(@as(f64, 2), output.boundary[0].phosphorus_mol);
    try std.testing.expectEqual(@as(f64, 0.5), output.boundary[0].carbon_mol);
    // Generic: 0.5 carbonate plus 2 mol FeHPO4 at weight 3. Dedicated:
    // 1 mol free HPO4 at REDIST SSB weight 2.
    try std.testing.expectEqual(@as(f64, 8.5), output.litter_salt_ion_export[0]);
}

test "late gas failure rolls back the complete surface runoff owner transaction" {
    var chemistry = try Chemistry.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    setRepresentedFixture(&chemistry.cells[0]);
    var nitrite = [_]f64{7};
    var aqueous = try surface_routing.State.init(std.testing.allocator, 1, 1, species_count);
    defer aqueous.deinit();
    aqueous.carrier_volume_m3[0] = 1;
    aqueous.amount_mol[@intFromEnum(Species.aluminum_hydroxide_1)] = 3;
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    organic_state.dissolved[0].carbon_g_c = 5;
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    gas_state.dissolved_mass_g[@intFromEnum(gas.Species.oxygen)] = std.math.nan(f64);
    var output: TransactionTestOutputs = .{
        .nitrogen = @splat(41),
        .phosphorus = @splat(41),
        .organic_carbon = @splat(41),
        .organic_nitrogen = @splat(41),
        .organic_phosphorus = @splat(41),
        .inorganic_carbon = @splat(41),
        .oxygen = @splat(41),
        .nitrogen_gas = @splat(41),
        .hydrogen_gas = @splat(41),
        .litter_salt_ion_export = @splat(41),
        .aqueous_species = @splat(41),
        .boundary = @splat(.{ .sodium_mol = 41 }),
        .debit = @splat(.{ .sodium_mol = 41 }),
        .credit = @splat(.{ .sodium_mol = 41 }),
        .dedicated_debit = @splat(.{ .nitrogen_g = 41 }),
        .dedicated_credit = @splat(.{ .hydrogen_g = 41 }),
    };
    const chemistry_before = try std.testing.allocator.dupe(ChemistryCell, chemistry.cells);
    defer std.testing.allocator.free(chemistry_before);
    const mineral_reference_before = chemistry.mineral_reference_water_m3[0];
    const dry_reference_before = chemistry.dry_reference_water_m3[0];
    const nitrite_before = nitrite;
    const aqueous_amount_before = aqueous.amount_mol[@intFromEnum(Species.aluminum_hydroxide_1)];
    const aqueous_carrier_before = aqueous.carrier_volume_m3[0];
    const organic_before = organic_state.dissolved[0];
    const output_before = output;
    const half = [_]f64{0.5};
    const zero = [_]f64{0};
    try std.testing.expectError(error.InvalidSurfaceDissolvedGasPool, advanceTransaction(
        std.testing.allocator,
        .{ .chemistry = &chemistry, .nitrite_g_n = &nitrite, .aqueous = &aqueous, .organic = &organic_state, .gas = &gas_state },
        1,
        1,
        &.{0.5},
        &.{-0.5},
        .{ .east_m3 = &half, .west_m3 = &zero, .south_m3 = &zero, .north_m3 = &zero },
        1,
        14,
        31,
        12,
        output.slices(),
    ));
    try std.testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(chemistry_before), std.mem.sliceAsBytes(chemistry.cells)));
    try std.testing.expectEqual(mineral_reference_before, chemistry.mineral_reference_water_m3[0]);
    try std.testing.expectEqual(dry_reference_before, chemistry.dry_reference_water_m3[0]);
    try std.testing.expectEqualSlices(f64, &nitrite_before, &nitrite);
    try std.testing.expectEqual(aqueous_amount_before, aqueous.amount_mol[@intFromEnum(Species.aluminum_hydroxide_1)]);
    try std.testing.expectEqual(aqueous_carrier_before, aqueous.carrier_volume_m3[0]);
    try std.testing.expectEqual(organic_before, organic_state.dissolved[0]);
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&output_before), std.mem.asBytes(&output)));
}
