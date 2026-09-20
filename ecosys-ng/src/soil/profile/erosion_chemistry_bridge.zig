const std = @import("std");
const chemistry_module = @import("../solute/chemistry_state.zig");
const phosphate = @import("../solute/phosphate_network.zig");
const cation = @import("../solute/cation_exchange.zig");
const geochemistry = @import("../solute/geochemistry_network.zig");
const ZoneFractions = @import("../solute/charge_classification.zig").ZoneFractions;
const constituents = @import("../../erosion/eroded_constituents.zig");
const legacy_water_negligible_floor = @import("../../core/legacy_water_negligible_floor.zig");

pub const component_count: usize = @typeInfo(cation.Cations).@"struct".fields.len +
    2 * phosphateErodibleFieldCount() +
    @typeInfo(geochemistry.SolidState).@"struct".fields.len + 1;

pub const Exported = struct {
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
    inorganic_carbon_g_c: f64 = 0,
    ion_mol: f64 = 0,
};

pub fn route(
    columns: usize,
    rows: usize,
    soil_layer_capacity: usize,
    erosion_fraction_soil_mass_megagrams: []const f64,
    canonical_topsoil_mass_megagrams: []const f64,
    topsoil_water_volume_m3: []const f64,
    cell_area_m2: []const f64,
    zone_fractions_by_cell: []const ZoneFractions,
    chemistry: *chemistry_module.State,
    sediment: constituents.DirectionalSediment,
    workspace: *constituents.PackedWorkspace,
) !void {
    const cells = try std.math.mul(usize, columns, rows);
    if (soil_layer_capacity == 0 or chemistry.cell_count != try std.math.mul(usize, cells, soil_layer_capacity) or erosion_fraction_soil_mass_megagrams.len != cells or canonical_topsoil_mass_megagrams.len != cells or zone_fractions_by_cell.len != cells or topsoil_water_volume_m3.len != chemistry.cell_count or cell_area_m2.len != cells or workspace.cell_count != cells or workspace.component_count != component_count) return error.ChemistryErosionDimensionMismatch;
    try pack(cells, soil_layer_capacity, canonical_topsoil_mass_megagrams, topsoil_water_volume_m3, cell_area_m2, zone_fractions_by_cell, chemistry, workspace.pools);
    try constituents.routePackedWorkspace(workspace, columns, rows, erosion_fraction_soil_mass_megagrams, sediment);
    try unpack(cells, soil_layer_capacity, canonical_topsoil_mass_megagrams, topsoil_water_volume_m3, cell_area_m2, zone_fractions_by_cell, chemistry, workspace.pools);
}

/// REDIST `ZXE/PXE/PPE/CXE/SEX/SEP` external solid-chemistry loss.
pub noinline fn exported(
    workspace: *const constituents.PackedWorkspace,
    carbon_g_per_mol: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !Exported {
    if (workspace.component_count != component_count or
        workspace.exported.len !=
            try std.math.mul(usize, workspace.cell_count, component_count))
        return error.ChemistryErosionDimensionMismatch;
    inline for (.{ carbon_g_per_mol, nitrogen_g_per_mol, phosphorus_g_per_mol }) |mass|
        if (!std.math.isFinite(mass) or mass <= 0)
            return error.InvalidChemistryErosionMolarMass;
    var result: Exported = .{};
    for (0..workspace.cell_count) |cell| {
        var cursor = cell * component_count;
        inline for (@typeInfo(cation.Cations).@"struct".fields) |field| {
            const amount = try exportedAmount(workspace.exported[cursor]);
            cursor += 1;
            // Mineral N (ammonium) is tracked in its own nitrogen_g_n balance,
            // never in ion_mol -- matching subsurface_irrigation_chemistry.zig's
            // "REDIST keeps aqueous N and P in their own balances; its SBU ion
            // boundary contains free H and the salt-system carriers only"
            // convention. ion_inventory_mol structurally excludes ammonium from
            // its cation-exchange sum, so crediting it here as well would double-
            // book nitrogen mass into two ledgers meant to stay disjoint.
            if (comptime std.mem.startsWith(u8, field.name, "ammonium")) {
                result.nitrogen_g_n += amount * nitrogen_g_per_mol;
            } else {
                result.ion_mol += amount;
            }
        }
        // Carboxyl-bound hydrogen.
        result.ion_mol += try exportedAmount(workspace.exported[cursor]);
        cursor += 1;
        inline for (0..2) |_| inline for (@typeInfo(phosphate.State).@"struct".fields) |field| {
            if (comptime isErodiblePhosphateField(field.name)) {
                const amount = try exportedAmount(workspace.exported[cursor]);
                cursor += 1;
                result.phosphorus_g_p +=
                    amount * phosphateAtoms(field.name) * phosphorus_g_per_mol;
                result.ion_mol += amount * phosphateIonAtoms(field.name);
            }
        };
        inline for (@typeInfo(geochemistry.SolidState).@"struct".fields) |field| {
            const amount = try exportedAmount(workspace.exported[cursor]);
            cursor += 1;
            result.ion_mol += amount * geochemistryIonAtoms(field.name);
            if (comptime std.mem.eql(u8, field.name, "calcite_solid_mol_per_m3"))
                result.inorganic_carbon_g_c += amount * carbon_g_per_mol;
        }
        if (cursor != (cell + 1) * component_count)
            return error.ChemistryErosionDimensionMismatch;
    }
    inline for (std.meta.fields(Exported)) |field|
        if (!std.math.isFinite(@field(result, field.name)) or
            @field(result, field.name) < 0)
            return error.ChemistryErosionExportOverflow;
    return result;
}

fn exportedAmount(value: f64) !f64 {
    if (!std.math.isFinite(value) or value < 0)
        return error.InvalidChemistryErosionExport;
    return value;
}

fn phosphateAtoms(comptime name: []const u8) f64 {
    if (std.mem.indexOf(u8, name, "adsorbed_") != null) return 1;
    if (std.mem.indexOf(u8, name, "aluminum_phosphate") != null or
        std.mem.indexOf(u8, name, "iron_phosphate") != null or
        std.mem.indexOf(u8, name, "dicalcium_phosphate") != null)
        return 1;
    if (std.mem.indexOf(u8, name, "hydroxyapatite") != null) return 3;
    if (std.mem.indexOf(u8, name, "monocalcium_phosphate") != null) return 2;
    return 0;
}

fn phosphateIonAtoms(comptime name: []const u8) f64 {
    if (std.mem.indexOf(u8, name, "deprotonated_site") != null) return 1;
    if (std.mem.indexOf(u8, name, "hydroxyl_site") != null) return 2;
    if (std.mem.indexOf(u8, name, "protonated_site") != null) return 3;
    if (std.mem.indexOf(u8, name, "adsorbed_hpo4") != null) return 3;
    if (std.mem.indexOf(u8, name, "adsorbed_h2po4") != null) return 4;
    if (std.mem.indexOf(u8, name, "aluminum_phosphate") != null or
        std.mem.indexOf(u8, name, "iron_phosphate") != null)
        return 2;
    if (std.mem.indexOf(u8, name, "dicalcium_phosphate") != null) return 3;
    if (std.mem.indexOf(u8, name, "hydroxyapatite") != null) return 9;
    if (std.mem.indexOf(u8, name, "monocalcium_phosphate") != null) return 7;
    return 0;
}

fn geochemistryIonAtoms(comptime name: []const u8) f64 {
    if (std.mem.indexOf(u8, name, "gibbsite") != null or
        std.mem.indexOf(u8, name, "iron_hydroxide") != null)
        return 4;
    if (std.mem.indexOf(u8, name, "calcite") != null or
        std.mem.indexOf(u8, name, "gypsum") != null)
        return 2;
    return 1;
}

pub fn pack(cells: usize, layer_capacity: usize, soil_mass_megagrams: []const f64, water_m3: []const f64, cell_area_m2: []const f64, fractions_by_cell: []const ZoneFractions, chemistry: *const chemistry_module.State, output: []f64) !void {
    return packMapped(cells, layer_capacity, &.{}, soil_mass_megagrams, water_m3, cell_area_m2, fractions_by_cell, chemistry, output);
}

pub fn packMapped(cells: usize, layer_capacity: usize, top_layer_by_cell: []const usize, soil_mass_megagrams: []const f64, water_m3: []const f64, cell_area_m2: []const f64, fractions_by_cell: []const ZoneFractions, chemistry: *const chemistry_module.State, output: []f64) !void {
    if (top_layer_by_cell.len != 0 and top_layer_by_cell.len != cells) return error.ChemistryErosionDimensionMismatch;
    if (cell_area_m2.len != cells) return error.ChemistryErosionDimensionMismatch;
    for (0..cells) |cell| {
        const local = if (top_layer_by_cell.len == 0) 0 else top_layer_by_cell[cell];
        if (local >= layer_capacity) return error.ChemistryErosionDimensionMismatch;
        const layer = cell * layer_capacity + local;
        const soil_mass = soil_mass_megagrams[cell];
        const water = water_m3[layer];
        const fractions = fractions_by_cell[cell];
        // A zero soil-mass carrier is the reference open-water branch. Live
        // per-mass concentrations are zero there and extensive chemistry is
        // retained in the explicit pending owners packed below.
        if (!std.math.isFinite(soil_mass) or soil_mass < 0 or !std.math.isFinite(water) or water < 0) return error.InvalidChemistryErosionState;
        try validateFractions(fractions);
        const negligible_water_volume_m3 = legacyNegligibleWaterVolumeM3(cell_area_m2[cell]);
        const water_carrier = try erosionWaterCarrierM3(water, chemistry.dry_reference_water_m3[layer], negligible_water_volume_m3);
        var cursor = cell * component_count;
        inline for (@typeInfo(cation.Cations).@"struct".fields) |field| {
            try put(
                @field(chemistry.cation_exchange_mol_per_megagram[layer], field.name) *
                    cationCarrier(field.name, soil_mass, fractions) +
                    @field(chemistry.pending_cation_exchange_mol[layer], field.name),
                output,
                &cursor,
            );
        }
        try put(chemistry.carboxyl_bound_hydrogen_mol_per_megagram[layer] * soil_mass + chemistry.pending_carboxyl_bound_hydrogen_mol[layer], output, &cursor);
        inline for (.{
            .{ chemistry.non_band_phosphate[layer], chemistry.pending_non_band_phosphate_mol[layer], fractions.phosphate_non_band },
            .{ chemistry.band_phosphate[layer], chemistry.pending_band_phosphate_mol[layer], fractions.phosphate_band },
        }) |zone| inline for (@typeInfo(phosphate.State).@"struct".fields) |field| {
            if (comptime isErodiblePhosphateField(field.name)) {
                const scale = (if (comptime std.mem.endsWith(u8, field.name, "_per_megagram")) soil_mass else water_carrier) * zone[2];
                try put(@field(zone[0], field.name) * scale + @field(zone[1], field.name), output, &cursor);
            }
        };
        inline for (@typeInfo(geochemistry.SolidState).@"struct".fields) |field| {
            try put(@field(chemistry.geochemistry_solids[layer], field.name) * water_carrier + @field(chemistry.pending_geochemistry_solids_mol[layer], field.name), output, &cursor);
        }
        if (cursor != (cell + 1) * component_count) return error.ChemistryErosionDimensionMismatch;
    }
}

pub fn unpack(cells: usize, layer_capacity: usize, soil_mass_megagrams: []const f64, water_m3: []const f64, cell_area_m2: []const f64, fractions_by_cell: []const ZoneFractions, chemistry: *chemistry_module.State, input: []const f64) !void {
    return unpackMapped(cells, layer_capacity, &.{}, soil_mass_megagrams, water_m3, cell_area_m2, fractions_by_cell, chemistry, input);
}

pub fn unpackMapped(cells: usize, layer_capacity: usize, top_layer_by_cell: []const usize, soil_mass_megagrams: []const f64, water_m3: []const f64, cell_area_m2: []const f64, fractions_by_cell: []const ZoneFractions, chemistry: *chemistry_module.State, input: []const f64) !void {
    if (top_layer_by_cell.len != 0 and top_layer_by_cell.len != cells) return error.ChemistryErosionDimensionMismatch;
    if (cell_area_m2.len != cells) return error.ChemistryErosionDimensionMismatch;
    for (input) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidChemistryErosionCandidate;
    for (0..cells) |cell| {
        const local = if (top_layer_by_cell.len == 0) 0 else top_layer_by_cell[cell];
        if (local >= layer_capacity) return error.ChemistryErosionDimensionMismatch;
        const layer = cell * layer_capacity + local;
        const soil_mass = soil_mass_megagrams[cell];
        const water = water_m3[layer];
        const fractions = fractions_by_cell[cell];
        try validateFractions(fractions);
        const negligible_water_volume_m3 = legacyNegligibleWaterVolumeM3(cell_area_m2[cell]);
        const water_carrier = try erosionWaterCarrierM3(water, chemistry.dry_reference_water_m3[layer], negligible_water_volume_m3);
        var cursor = cell * component_count;
        inline for (@typeInfo(cation.Cations).@"struct".fields) |field| {
            const next = try ownedConcentration(input[cursor], cationCarrier(field.name, soil_mass, fractions));
            @field(chemistry.cation_exchange_mol_per_megagram[layer], field.name) = next.concentration;
            @field(chemistry.pending_cation_exchange_mol[layer], field.name) = next.pending_mol;
            cursor += 1;
        }
        const carboxyl = try ownedConcentration(input[cursor], soil_mass);
        chemistry.carboxyl_bound_hydrogen_mol_per_megagram[layer] = carboxyl.concentration;
        chemistry.pending_carboxyl_bound_hydrogen_mol[layer] = carboxyl.pending_mol;
        cursor += 1;
        inline for (.{
            .{ &chemistry.non_band_phosphate[layer], &chemistry.pending_non_band_phosphate_mol[layer], fractions.phosphate_non_band },
            .{ &chemistry.band_phosphate[layer], &chemistry.pending_band_phosphate_mol[layer], fractions.phosphate_band },
        }) |zone| inline for (@typeInfo(phosphate.State).@"struct".fields) |field| {
            if (comptime isErodiblePhosphateField(field.name)) {
                const scale = (if (comptime std.mem.endsWith(u8, field.name, "_per_megagram")) soil_mass else water_carrier) * zone[2];
                const next = try ownedConcentration(input[cursor], scale);
                @field(zone[0].*, field.name) = next.concentration;
                @field(zone[1].*, field.name) = next.pending_mol;
                cursor += 1;
            }
        };
        inline for (@typeInfo(geochemistry.SolidState).@"struct".fields) |field| {
            const next = try ownedConcentration(input[cursor], water_carrier);
            @field(chemistry.geochemistry_solids[layer], field.name) = next.concentration;
            @field(chemistry.pending_geochemistry_solids_mol[layer], field.name) = next.pending_mol;
            cursor += 1;
        }
    }
}

/// `ZEROS2(NY,NX) = ZERO2*DH(NY,NX)*DV(NY,NX)` (`starts.f:270`). issue-065:
/// shares the same floor `landscape_mass_inventory_phosphorus_ions.zig`'s
/// census already applies through its own `aqueousCarrierM3`, and
/// `water_carrier_rebase.zig`'s mutator already applies through its own
/// `sourceWaterM3`, so this file's `packMapped`/`unpackMapped` round-trip
/// agrees with both on the same water-carrier basis for the same degenerate
/// cell/layer.
fn legacyNegligibleWaterVolumeM3(cell_area_m2: f64) f64 {
    return legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(cell_area_m2);
}

/// `solute.f:610` keeps a water-normalized pool represented on the
/// remembered dry reference carrier whenever the live water carrier is at or
/// below the `ZEROS2` noise floor. issue-065: `packMapped`/`unpackMapped`'s
/// geochemistry-solid loop and the water-scaled half of the phosphate zones
/// previously multiplied/divided by the RAW, unsubstituted `water_m3[layer]`
/// carrier -- unlike every other consumer of this same condition
/// (`water_carrier_rebase.zig`'s `sourceWaterM3`, the census's
/// `aqueousCarrierM3`). At a layer whose live water has collapsed to exactly
/// `0` (post-WATSUB-commit dry transition) while `dry_reference_water_m3`
/// still holds the true pre-collapse volume, `packMapped` packed
/// `concentration * 0 ~= 0` (discarding the true extensive mass with no
/// ledger entry) and `unpackMapped`'s `ownedConcentration(~0, scale=0)` then
/// forcibly reset the concentration to exactly `0` -- a double-sided silent
/// destruction (hour 2,894, `carbon_dioxide_carbon_g` and nine sibling
/// elements, issue-065). Deliberately mirrors `relayering.zig`'s own private
/// `solidTransferWaterCarrierM3`/`landscape_mass_inventory_phosphorus_ions.zig`'s
/// `aqueousCarrierM3` rather than importing either: this file is a distinct
/// production mutator with its own error set.
fn erosionWaterCarrierM3(
    live_water_m3: f64,
    dry_reference_water_m3: f64,
    negligible_water_volume_m3: f64,
) !f64 {
    if (!std.math.isFinite(live_water_m3) or live_water_m3 < 0 or
        !std.math.isFinite(dry_reference_water_m3) or dry_reference_water_m3 < 0 or
        !std.math.isFinite(negligible_water_volume_m3) or negligible_water_volume_m3 < 0)
        return error.InvalidChemistryErosionState;
    return if (live_water_m3 > negligible_water_volume_m3) live_water_m3 else dry_reference_water_m3;
}

fn put(value: f64, output: []f64, cursor: *usize) !void {
    if (!std.math.isFinite(value) or value < 0) return error.InvalidChemistryErosionState;
    output[cursor.*] = value;
    cursor.* += 1;
}

const OwnedConcentration = struct { concentration: f64, pending_mol: f64 };

fn ownedConcentration(amount: f64, scale: f64) !OwnedConcentration {
    if (!std.math.isFinite(amount) or amount < 0 or !std.math.isFinite(scale) or scale < 0)
        return error.InvalidChemistryErosionCandidate;
    if (scale > 0) {
        const value = amount / scale;
        if (!std.math.isFinite(value)) return error.InvalidChemistryErosionCandidate;
        return .{ .concentration = value, .pending_mol = 0 };
    }
    return .{ .concentration = 0, .pending_mol = amount };
}

fn cationCarrier(comptime name: []const u8, soil_mass: f64, fractions: ZoneFractions) f64 {
    if (std.mem.eql(u8, name, "ammonium_non_band")) return soil_mass * fractions.ammonium_non_band;
    if (std.mem.eql(u8, name, "ammonium_band")) return soil_mass * fractions.ammonium_band;
    return soil_mass;
}

fn validateFractions(fractions: ZoneFractions) !void {
    inline for (std.meta.fields(ZoneFractions)) |field| {
        const value = @field(fractions, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidChemistryErosionState;
    }
    inline for (.{
        .{ fractions.ammonium_non_band, fractions.ammonium_band },
        .{ fractions.nitrate_non_band, fractions.nitrate_band },
        .{ fractions.phosphate_non_band, fractions.phosphate_band },
    }) |pair| if (@abs(pair[0] + pair[1] - 1) > 64 * std.math.floatEps(f64))
        return error.InvalidChemistryErosionState;
}

fn isErodiblePhosphateField(comptime name: []const u8) bool {
    @setEvalBranchQuota(10_000);
    return std.mem.endsWith(u8, name, "_per_megagram") or std.mem.indexOf(u8, name, "_solid_mol_per_m3") != null;
}

fn phosphateErodibleFieldCount() usize {
    comptime var count: usize = 0;
    inline for (@typeInfo(phosphate.State).@"struct".fields) |field| if (isErodiblePhosphateField(field.name)) {
        count += 1;
    };
    return count;
}

const test_non_band_fractions: ZoneFractions = .{
    .ammonium_non_band = 1,
    .ammonium_band = 0,
    .nitrate_non_band = 1,
    .nitrate_band = 0,
    .phosphate_non_band = 1,
    .phosphate_band = 0,
};

test "solid chemistry amounts follow sediment while retaining native concentrations" {
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 2);
    defer chemistry.deinit();
    chemistry.cation_exchange_mol_per_megagram[0].calcium = 2;
    chemistry.carboxyl_bound_hydrogen_mol_per_megagram[0] = 4;
    chemistry.non_band_phosphate[0].adsorbed_hpo4_mol_p_per_megagram = 3;
    chemistry.non_band_phosphate[0].aluminum_phosphate_solid_mol_per_m3 = 10;
    chemistry.geochemistry_solids[0].gibbsite_solid_mol_per_m3 = 20;
    var workspace = try constituents.PackedWorkspace.init(std.testing.allocator, 2, component_count);
    defer workspace.deinit();
    try route(2, 1, 1, &.{ 10, 10 }, &.{ 10, 10 }, &.{ 1, 1 }, &.{ 1, 1 }, &.{ test_non_band_fractions, test_non_band_fractions }, &chemistry, .{ .east_megagrams = &.{ 1, 0 }, .west_megagrams = &.{ 0, 0 }, .south_megagrams = &.{ 0, 0 }, .north_megagrams = &.{ 0, 0 } }, &workspace);
    try std.testing.expectApproxEqAbs(@as(f64, 1.8), chemistry.cation_exchange_mol_per_megagram[0].calcium, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), chemistry.cation_exchange_mol_per_megagram[1].calcium, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 3.6), chemistry.carboxyl_bound_hydrogen_mol_per_megagram[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), chemistry.carboxyl_bound_hydrogen_mol_per_megagram[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.7), chemistry.non_band_phosphate[0].adsorbed_hpo4_mol_p_per_megagram, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), chemistry.non_band_phosphate[1].adsorbed_hpo4_mol_p_per_megagram, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 9), chemistry.non_band_phosphate[0].aluminum_phosphate_solid_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1), chemistry.non_band_phosphate[1].aluminum_phosphate_solid_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 18), chemistry.geochemistry_solids[0].gibbsite_solid_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2), chemistry.geochemistry_solids[1].gibbsite_solid_mol_per_m3, 1e-14);
}

test "external solid chemistry export reproduces REDIST C N P ion counts" {
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    chemistry.cation_exchange_mol_per_megagram[0].ammonium_non_band = 10;
    chemistry.cation_exchange_mol_per_megagram[0].calcium = 20;
    chemistry.carboxyl_bound_hydrogen_mol_per_megagram[0] = 30;
    chemistry.non_band_phosphate[0].adsorbed_hpo4_mol_p_per_megagram = 40;
    chemistry.non_band_phosphate[0].hydroxyapatite_solid_mol_per_m3 = 50;
    chemistry.geochemistry_solids[0].calcite_solid_mol_per_m3 = 60;
    var workspace = try constituents.PackedWorkspace.init(
        std.testing.allocator,
        1,
        component_count,
    );
    defer workspace.deinit();
    try route(1, 1, 1, &.{10}, &.{10}, &.{1}, &.{1}, &.{test_non_band_fractions}, &chemistry, .{
        .east_megagrams = &.{1},
        .west_megagrams = &.{0},
        .south_megagrams = &.{0},
        .north_megagrams = &.{0},
    }, &workspace);
    const loss = try exported(&workspace, 12, 14, 31);
    try std.testing.expectApproxEqAbs(@as(f64, 140), loss.nitrogen_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(
        @as(f64, 31 * (40 + 15)),
        loss.phosphorus_g_p,
        1e-12,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 72), loss.inorganic_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(
        @as(f64, 20 + 30 + 120 + 45 + 12),
        loss.ion_mol,
        1e-12,
    );
}

test "external solid chemistry export never double-books ammonium into ion_mol" {
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    chemistry.cation_exchange_mol_per_megagram[0].ammonium_non_band = 10;
    chemistry.cation_exchange_mol_per_megagram[0].ammonium_band = 5;
    var workspace = try constituents.PackedWorkspace.init(
        std.testing.allocator,
        1,
        component_count,
    );
    defer workspace.deinit();
    const split_ammonium: ZoneFractions = .{
        .ammonium_non_band = 0.5,
        .ammonium_band = 0.5,
        .nitrate_non_band = 1,
        .nitrate_band = 0,
        .phosphate_non_band = 1,
        .phosphate_band = 0,
    };
    try route(1, 1, 1, &.{10}, &.{10}, &.{1}, &.{1}, &.{split_ammonium}, &chemistry, .{
        .east_megagrams = &.{1},
        .west_megagrams = &.{0},
        .south_megagrams = &.{0},
        .north_megagrams = &.{0},
    }, &workspace);
    const loss = try exported(&workspace, 12, 14, 31);
    // Both ammonium pools are exported and credited to nitrogen_g_n...
    try std.testing.expectApproxEqAbs(@as(f64, 0.5 * (10 + 5) * 14), loss.nitrogen_g_n, 1e-12);
    // ...and to nothing else: ion_inventory_mol structurally excludes mineral N,
    // so ion_mol must stay exactly zero here (no other ion-bearing pool was set).
    try std.testing.expectApproxEqAbs(@as(f64, 0), loss.ion_mol, 1e-12);
}

test "issue-065: OLD raw-carrier pack/unpack arithmetic would destroy geochemistry-solid mass at hour 2894's exact and near-zero degenerate water content" {
    // Reproduces issue-065's ninth addendum's own execution evidence: at
    // hour 2,894, cell 0/layer 0's live water collapses to exactly `0`
    // while `dry_reference_water_m3` correctly still holds the pre-collapse
    // volume `6.058232575064708e-3` m3 (the addendum's own recorded value),
    // and the true carbon mass at that instant was `7.4773772550351785` g C
    // (the addendum's own `before_erosion_redist_transport` trace value,
    // via `calcite_solid_mol_per_m3`). The OLD `packMapped` multiplied this
    // layer's geochemistry-solid concentrations by the RAW live water
    // (`water_m3[layer]`, not `chemistry.dry_reference_water_m3[layer]`),
    // and the OLD `unpackMapped` divided by that same raw carrier via
    // `ownedConcentration` -- both mechanisms below are exercised through
    // still-present production primitives (`ownedConcentration` is
    // unchanged; only the carrier callers now pass to it changed), not a
    // reimplementation, so this test cannot silently drift from reality.
    const dry_reference_water_m3: f64 = 6.058232575064708e-3;
    const carbon_g_per_mol: f64 = 12.0;
    const carbon_g_before: f64 = 7.4773772550351785;
    const concentration_mol_per_m3 = carbon_g_before / carbon_g_per_mol / dry_reference_water_m3;
    const true_mass_mol = concentration_mol_per_m3 * dry_reference_water_m3;
    try std.testing.expectApproxEqAbs(carbon_g_before, true_mass_mol * carbon_g_per_mol, 1e-9);

    // Case 1: live water exactly `0`, matching hour 2,894 exactly.
    {
        const live_water_m3: f64 = 0;
        const packed_old = concentration_mol_per_m3 * live_water_m3;
        try std.testing.expectEqual(@as(f64, 0), packed_old);
        const restored_old = try ownedConcentration(packed_old, live_water_m3);
        // `scale <= 0` forces the concentration to exactly `0`, discarding
        // the true nonzero concentration outright -- the "double-sided
        // silent destruction" the addendum describes.
        try std.testing.expectEqual(@as(f64, 0), restored_old.concentration);
        try std.testing.expect(true_mass_mol > 0);
    }

    // Case 2: live water near-zero but nonzero (below the shared `ZEROS2`
    // floor for a 1 m^2 cell, `1.0e-6`), matching the task's "near-zero-but-
    // nonzero" framing. The packed extensive amount -- what any downstream
    // erosion routing/export math actually operates on -- is wrong by many
    // orders of magnitude relative to the true extensive mass, because the
    // OLD carrier never substitutes `dry_reference_water_m3` at all.
    {
        const live_water_m3: f64 = 1.0e-9;
        const packed_old = concentration_mol_per_m3 * live_water_m3;
        try std.testing.expect(packed_old / true_mass_mol < 1.0e-6);
    }
}

test "issue-065: NEW packMapped/unpackMapped round trip preserves geochemistry-solid mass at hour 2894's exact and near-zero degenerate water content" {
    // Same scenario as the OLD-behavior test above, exercised through the
    // actual (fixed) public `pack`/`unpack` entry points end to end, with no
    // sediment routing perturbation (isolating the carrier-basis fix
    // itself, matching this issue's own east/west/south/north-zero pattern
    // used elsewhere in this file).
    const dry_reference_water_m3: f64 = 6.058232575064708e-3;
    const carbon_g_per_mol: f64 = 12.0;
    const carbon_g_before: f64 = 7.4773772550351785;
    const concentration_mol_per_m3 = carbon_g_before / carbon_g_per_mol / dry_reference_water_m3;

    inline for (.{ @as(f64, 0), @as(f64, 1.0e-9) }) |live_water_m3| {
        var chemistry = try chemistry_module.State.init(std.testing.allocator, 1);
        defer chemistry.deinit();
        chemistry.geochemistry_solids[0].calcite_solid_mol_per_m3 = concentration_mol_per_m3;
        chemistry.dry_reference_water_m3[0] = dry_reference_water_m3;
        var workspace = try constituents.PackedWorkspace.init(std.testing.allocator, 1, component_count);
        defer workspace.deinit();
        try pack(1, 1, &.{10}, &.{live_water_m3}, &.{1}, &.{test_non_band_fractions}, &chemistry, workspace.pools);
        try unpack(1, 1, &.{10}, &.{live_water_m3}, &.{1}, &.{test_non_band_fractions}, &chemistry, workspace.pools);
        // The concentration -- and therefore the true extensive mass it
        // represents against the remembered dry reference carrier -- is
        // preserved exactly through the round trip, unlike the OLD
        // mechanism's forced zero.
        try std.testing.expectApproxEqAbs(
            concentration_mol_per_m3,
            chemistry.geochemistry_solids[0].calcite_solid_mol_per_m3,
            1e-9 * concentration_mol_per_m3,
        );
        const mass_g_c_after = chemistry.geochemistry_solids[0].calcite_solid_mol_per_m3 * dry_reference_water_m3 * carbon_g_per_mol;
        try std.testing.expectApproxEqAbs(carbon_g_before, mass_g_c_after, 1e-6);
    }
}
