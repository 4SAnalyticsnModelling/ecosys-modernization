const std = @import("std");
const chemistry_module = @import("../solute/chemistry_state.zig");
const phosphate = @import("../solute/phosphate_network.zig");
const cation = @import("../solute/cation_exchange.zig");
const geochemistry = @import("../solute/geochemistry_network.zig");
const ZoneFractions = @import("../solute/charge_classification.zig").ZoneFractions;
const constituents = @import("../../erosion/eroded_constituents.zig");

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
    zone_fractions_by_cell: []const ZoneFractions,
    chemistry: *chemistry_module.State,
    sediment: constituents.DirectionalSediment,
    workspace: *constituents.PackedWorkspace,
) !void {
    const cells = try std.math.mul(usize, columns, rows);
    if (soil_layer_capacity == 0 or chemistry.cell_count != try std.math.mul(usize, cells, soil_layer_capacity) or erosion_fraction_soil_mass_megagrams.len != cells or canonical_topsoil_mass_megagrams.len != cells or zone_fractions_by_cell.len != cells or topsoil_water_volume_m3.len != chemistry.cell_count or workspace.cell_count != cells or workspace.component_count != component_count) return error.ChemistryErosionDimensionMismatch;
    try pack(cells, soil_layer_capacity, canonical_topsoil_mass_megagrams, topsoil_water_volume_m3, zone_fractions_by_cell, chemistry, workspace.pools);
    try constituents.routePackedWorkspace(workspace, columns, rows, erosion_fraction_soil_mass_megagrams, sediment);
    try unpack(cells, soil_layer_capacity, canonical_topsoil_mass_megagrams, topsoil_water_volume_m3, zone_fractions_by_cell, chemistry, workspace.pools);
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

pub fn pack(cells: usize, layer_capacity: usize, soil_mass_megagrams: []const f64, water_m3: []const f64, fractions_by_cell: []const ZoneFractions, chemistry: *const chemistry_module.State, output: []f64) !void {
    return packMapped(cells, layer_capacity, &.{}, soil_mass_megagrams, water_m3, fractions_by_cell, chemistry, output);
}

pub fn packMapped(cells: usize, layer_capacity: usize, top_layer_by_cell: []const usize, soil_mass_megagrams: []const f64, water_m3: []const f64, fractions_by_cell: []const ZoneFractions, chemistry: *const chemistry_module.State, output: []f64) !void {
    if (top_layer_by_cell.len != 0 and top_layer_by_cell.len != cells) return error.ChemistryErosionDimensionMismatch;
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
                const scale = (if (comptime std.mem.endsWith(u8, field.name, "_per_megagram")) soil_mass else water) * zone[2];
                try put(@field(zone[0], field.name) * scale + @field(zone[1], field.name), output, &cursor);
            }
        };
        inline for (@typeInfo(geochemistry.SolidState).@"struct".fields) |field| {
            try put(@field(chemistry.geochemistry_solids[layer], field.name) * water + @field(chemistry.pending_geochemistry_solids_mol[layer], field.name), output, &cursor);
        }
        if (cursor != (cell + 1) * component_count) return error.ChemistryErosionDimensionMismatch;
    }
}

pub fn unpack(cells: usize, layer_capacity: usize, soil_mass_megagrams: []const f64, water_m3: []const f64, fractions_by_cell: []const ZoneFractions, chemistry: *chemistry_module.State, input: []const f64) !void {
    return unpackMapped(cells, layer_capacity, &.{}, soil_mass_megagrams, water_m3, fractions_by_cell, chemistry, input);
}

pub fn unpackMapped(cells: usize, layer_capacity: usize, top_layer_by_cell: []const usize, soil_mass_megagrams: []const f64, water_m3: []const f64, fractions_by_cell: []const ZoneFractions, chemistry: *chemistry_module.State, input: []const f64) !void {
    if (top_layer_by_cell.len != 0 and top_layer_by_cell.len != cells) return error.ChemistryErosionDimensionMismatch;
    for (input) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidChemistryErosionCandidate;
    for (0..cells) |cell| {
        const local = if (top_layer_by_cell.len == 0) 0 else top_layer_by_cell[cell];
        if (local >= layer_capacity) return error.ChemistryErosionDimensionMismatch;
        const layer = cell * layer_capacity + local;
        const soil_mass = soil_mass_megagrams[cell];
        const water = water_m3[layer];
        const fractions = fractions_by_cell[cell];
        try validateFractions(fractions);
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
                const scale = (if (comptime std.mem.endsWith(u8, field.name, "_per_megagram")) soil_mass else water) * zone[2];
                const next = try ownedConcentration(input[cursor], scale);
                @field(zone[0].*, field.name) = next.concentration;
                @field(zone[1].*, field.name) = next.pending_mol;
                cursor += 1;
            }
        };
        inline for (@typeInfo(geochemistry.SolidState).@"struct".fields) |field| {
            const next = try ownedConcentration(input[cursor], water);
            @field(chemistry.geochemistry_solids[layer], field.name) = next.concentration;
            @field(chemistry.pending_geochemistry_solids_mol[layer], field.name) = next.pending_mol;
            cursor += 1;
        }
    }
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
    try route(2, 1, 1, &.{ 10, 10 }, &.{ 10, 10 }, &.{ 1, 1 }, &.{ test_non_band_fractions, test_non_band_fractions }, &chemistry, .{ .east_megagrams = &.{ 1, 0 }, .west_megagrams = &.{ 0, 0 }, .south_megagrams = &.{ 0, 0 }, .north_megagrams = &.{ 0, 0 } }, &workspace);
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
    try route(1, 1, 1, &.{10}, &.{10}, &.{1}, &.{test_non_band_fractions}, &chemistry, .{
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
    try route(1, 1, 1, &.{10}, &.{10}, &.{1}, &.{split_ammonium}, &chemistry, .{
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
