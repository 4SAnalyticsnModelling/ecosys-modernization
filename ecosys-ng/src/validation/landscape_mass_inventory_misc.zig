//! `landscape_mass_inventory` declarations: misc.
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
const soil_properties = @import("../soil/water/solver_properties.zig");
const suspended = @import("../erosion/suspended_constituents.zig");
const erosion_organic_bridge = @import("../soil/profile/erosion_organic_bridge.zig");
const organic_state = @import("../soil/organic/initialization.zig");
const erosion_fertilizer_bridge = @import("../soil/profile/erosion_fertilizer_bridge.zig");
const erosion_chemistry_bridge = @import("../soil/profile/erosion_chemistry_bridge.zig");
const dry_mineral_fertilizer = @import("../management/mineral_fertilizer_inventory.zig");
const cation_exchange = @import("../soil/solute/cation_exchange.zig");
const phosphate_network = @import("../soil/solute/phosphate_network.zig");
const geochemistry_network = @import("../soil/solute/geochemistry_network.zig");
const group_support = @import("landscape_mass_inventory_support.zig");

pub fn aggregateSoilMineralTexture(grid: *const grid_module.GridState, properties: *const soil_properties.State) !group_support.Storage {
    return aggregateSoilMineralTextureRange(grid, properties, 0, grid.cell_count, null);
}

pub fn aggregateSoilMineralTextureCell(grid: *const grid_module.GridState, properties: *const soil_properties.State, cell: usize) !group_support.Storage {
    if (cell >= grid.cell_count) return error.LandscapeCellIndexOutOfBounds;
    return aggregateSoilMineralTextureRange(grid, properties, cell, cell + 1, null);
}

pub fn aggregateSoilMineralTextureLayer(grid: *const grid_module.GridState, properties: *const soil_properties.State, cell: usize, layer: usize) !group_support.Storage {
    if (cell >= grid.cell_count or layer >= grid.soil_layer_capacity)
        return error.LandscapeCellIndexOutOfBounds;
    return aggregateSoilMineralTextureRange(grid, properties, cell, cell + 1, layer);
}

fn aggregateSoilMineralTextureRange(grid: *const grid_module.GridState, properties: *const soil_properties.State, first_cell: usize, end_cell: usize, local_layer_filter: ?usize) !group_support.Storage {
    if (properties.layer_count != grid.layer_count or
        properties.sand_mass_megagrams.len != grid.layer_count or
        properties.silt_mass_megagrams.len != grid.layer_count or
        properties.clay_mass_megagrams.len != grid.layer_count or
        properties.rock_fraction.len != grid.layer_count or
        properties.cation_exchange_capacity_mol.len != grid.layer_count or
        properties.anion_exchange_capacity_mol.len != grid.layer_count or
        first_cell > end_cell or end_cell > grid.cell_count)
        return error.SoilMineralTextureInventoryDimensionMismatch;
    var result: group_support.Storage = .{};
    for (first_cell..end_cell) |cell| {
        const active = grid.active_soil_layer_count[cell];
        if (active > grid.soil_layer_capacity) return error.InvalidActiveSoilLayerCount;
        const first_layer = if (local_layer_filter) |layer| @min(layer, active) else 0;
        const end_layer = if (local_layer_filter) |layer| @min(layer + 1, active) else active;
        for (first_layer..end_layer) |layer| {
            const index = cell * grid.soil_layer_capacity + layer;
            inline for (.{ properties.sand_mass_megagrams[index], properties.silt_mass_megagrams[index], properties.clay_mass_megagrams[index], properties.rock_fraction[index], properties.cation_exchange_capacity_mol[index], properties.anion_exchange_capacity_mol[index] }) |value|
                if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilMineralTextureInventory;
            result.sand_megagrams += properties.sand_mass_megagrams[index];
            result.silt_megagrams += properties.silt_mass_megagrams[index];
            result.clay_megagrams += properties.clay_mass_megagrams[index];
            result.rock_additive += properties.rock_fraction[index];
            result.cation_exchange_capacity_mol += properties.cation_exchange_capacity_mol[index];
            result.anion_exchange_capacity_mol += properties.anion_exchange_capacity_mol[index];
        }
    }
    try result.validate();
    return result;
}

pub fn aggregateSuspendedConstituents(
    state: *const suspended.State,
    organic_profile: *const organic_state.State,
    carbon_g_per_mol: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !group_support.Storage {
    return aggregateSuspendedRange(state, organic_profile, carbon_g_per_mol, nitrogen_g_per_mol, phosphorus_g_per_mol, 0, state.cell_count);
}

pub fn aggregateSuspendedConstituentsCell(
    state: *const suspended.State,
    organic_profile: *const organic_state.State,
    carbon_g_per_mol: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    cell: usize,
) !group_support.Storage {
    if (cell >= state.cell_count) return error.LandscapeCellIndexOutOfBounds;
    return aggregateSuspendedRange(state, organic_profile, carbon_g_per_mol, nitrogen_g_per_mol, phosphorus_g_per_mol, cell, cell + 1);
}

/// Converts one exact accepted packed suspended-constituent transfer into the
/// same canonical storage basis as the persistent suspended inventory. The
/// producer supplies native extensive amounts in its runtime layout; keeping
/// this conversion beside the census prevents erosion accounting from
/// drifting to a second stoichiometry table.
pub fn aggregateSuspendedComponentAmounts(
    layout: suspended.Layout,
    organic_profile: *const organic_state.State,
    carbon_g_per_mol: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    amounts: []const f64,
) !group_support.Storage {
    try layout.validate();
    try group_support.validateOrganicDimensions(
        organic_profile,
        error.SuspendedInventoryDimensionMismatch,
    );
    if (!std.math.isFinite(carbon_g_per_mol) or carbon_g_per_mol <= 0 or
        !std.math.isFinite(nitrogen_g_per_mol) or nitrogen_g_per_mol <= 0 or
        !std.math.isFinite(phosphorus_g_per_mol) or phosphorus_g_per_mol <= 0 or
        layout.organic_cnp_count != try erosion_organic_bridge.componentCount(organic_profile) or
        layout.nitrogen_fertilizer_count != erosion_fertilizer_bridge.component_count or
        layout.dry_mineral_fertilizer_count != @typeInfo(dry_mineral_fertilizer.Inventory).@"struct".fields.len or
        layout.chemistry_live_and_pending_count != erosion_chemistry_bridge.component_count or
        amounts.len != try layout.componentCount())
        return error.SuspendedInventoryDimensionMismatch;

    const texture = try layout.range(.mineral_texture);
    const exchange = try layout.range(.exchange_capacity);
    const organic_range = try layout.range(.organic_cnp);
    const nitrogen_range = try layout.range(.nitrogen_fertilizer);
    const dry_range = try layout.range(.dry_mineral_fertilizer);
    const chemistry_range = try layout.range(.chemistry_live_and_pending);
    for (amounts) |amount|
        if (!std.math.isFinite(amount) or amount < 0)
            return error.InvalidSuspendedInventory;
    var result: group_support.Storage = .{
        .sand_megagrams = amounts[texture.start + 0],
        .silt_megagrams = amounts[texture.start + 1],
        .clay_megagrams = amounts[texture.start + 2],
        .cation_exchange_capacity_mol = amounts[exchange.start + 0],
        .anion_exchange_capacity_mol = amounts[exchange.start + 1],
    };
    for (0..organic_range.len) |component|
        try addSuspendedComposition(&result, amounts[organic_range.start + component], try organicComposition(organic_profile, component));
    for (0..nitrogen_range.len) |component|
        try addSuspendedComposition(&result, amounts[nitrogen_range.start + component], .{ .mineral_nitrogen_g = nitrogen_g_per_mol });
    for (0..dry_range.len) |component|
        try addSuspendedComposition(&result, amounts[dry_range.start + component], dryComposition(component, carbon_g_per_mol, phosphorus_g_per_mol));
    for (0..chemistry_range.len) |component|
        try addSuspendedComposition(&result, amounts[chemistry_range.start + component], try chemistryComposition(component, carbon_g_per_mol, nitrogen_g_per_mol, phosphorus_g_per_mol));
    try result.validate();
    return result;
}

const SuspendedComposition = struct {
    residue_carbon_g: f64 = 0,
    organic_carbon_g: f64 = 0,
    inorganic_carbon_g: f64 = 0,
    residue_nitrogen_g: f64 = 0,
    organic_nitrogen_g: f64 = 0,
    mineral_nitrogen_g: f64 = 0,
    residue_phosphorus_g: f64 = 0,
    organic_phosphorus_g: f64 = 0,
    phosphate_phosphorus_g: f64 = 0,
    aluminum_mol: f64 = 0,
    iron_mol: f64 = 0,
    calcium_mol: f64 = 0,
    magnesium_mol: f64 = 0,
    sodium_mol: f64 = 0,
    potassium_mol: f64 = 0,
    sulfur_mol: f64 = 0,
    silicon_mol: f64 = 0,
};

fn aggregateSuspendedRange(
    state: *const suspended.State,
    organic_profile: *const organic_state.State,
    carbon_g_per_mol: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    first_cell: usize,
    end_cell: usize,
) !group_support.Storage {
    try state.validate();
    try group_support.validateOrganicDimensions(
        organic_profile,
        error.SuspendedInventoryDimensionMismatch,
    );
    if (first_cell > end_cell or end_cell > state.cell_count or
        !std.math.isFinite(carbon_g_per_mol) or carbon_g_per_mol <= 0 or
        !std.math.isFinite(nitrogen_g_per_mol) or nitrogen_g_per_mol <= 0 or
        !std.math.isFinite(phosphorus_g_per_mol) or phosphorus_g_per_mol <= 0 or
        state.layout.organic_cnp_count != try erosion_organic_bridge.componentCount(organic_profile) or
        state.layout.nitrogen_fertilizer_count != erosion_fertilizer_bridge.component_count or
        state.layout.dry_mineral_fertilizer_count != @typeInfo(dry_mineral_fertilizer.Inventory).@"struct".fields.len or
        state.layout.chemistry_live_and_pending_count != erosion_chemistry_bridge.component_count)
        return error.SuspendedInventoryDimensionMismatch;
    var result: group_support.Storage = .{};
    for (first_cell..end_cell) |cell| {
        const first = cell * state.component_count;
        try result.add(try aggregateSuspendedComponentAmounts(
            state.layout,
            organic_profile,
            carbon_g_per_mol,
            nitrogen_g_per_mol,
            phosphorus_g_per_mol,
            state.pools[first .. first + state.component_count],
        ));
    }
    try result.validate();
    return result;
}

fn addSuspendedComposition(storage: *group_support.Storage, amount: f64, composition: SuspendedComposition) !void {
    if (!std.math.isFinite(amount) or amount < 0) return error.InvalidSuspendedInventory;
    const mappings = .{
        .{ "residue_carbon_g", "residue_carbon_g" },
        .{ "organic_carbon_g", "organic_carbon_g" },
        .{ "inorganic_carbon_g", "carbon_dioxide_carbon_g" },
        .{ "residue_nitrogen_g", "residue_nitrogen_g" },
        .{ "organic_nitrogen_g", "organic_nitrogen_g" },
        .{ "mineral_nitrogen_g", "ammonium_nitrogen_g" },
        .{ "residue_phosphorus_g", "residue_phosphorus_g" },
        .{ "organic_phosphorus_g", "organic_phosphorus_g" },
        .{ "phosphate_phosphorus_g", "phosphate_phosphorus_g" },
        .{ "aluminum_mol", "aluminum_mol" },
        .{ "iron_mol", "iron_mol" },
        .{ "calcium_mol", "calcium_mol" },
        .{ "magnesium_mol", "magnesium_mol" },
        .{ "sodium_mol", "sodium_mol" },
        .{ "potassium_mol", "potassium_mol" },
        .{ "sulfur_mol", "sulfur_mol" },
        .{ "silicon_mol", "silicon_mol" },
    };
    inline for (mappings) |mapping| {
        const next = @field(storage, mapping[1]) + amount * @field(composition, mapping[0]);
        if (!std.math.isFinite(next)) return error.NonFiniteLandscapeInventory;
        @field(storage, mapping[1]) = next;
    }
}

fn organicComposition(state: *const organic_state.State, component: usize) !SuspendedComposition {
    var cursor: usize = 0;
    const microbial_pool_count = state.microbial.len / state.layer_count;
    const microbial_component_count = 3 * microbial_pool_count;
    if (component < cursor + microbial_component_count) {
        const local = component - cursor;
        const pool = local / 3;
        const substrate = pool /
            (organic_state.microbial_population_count * organic_state.kinetic_fraction_count);
        return organicElement(local % 3, substrate == 4);
    }
    cursor += microbial_component_count;

    const residue_pool_count = state.residue.len / state.layer_count;
    const residue_component_count = 3 * residue_pool_count;
    if (component < cursor + residue_component_count) {
        const local = component - cursor;
        const substrate = (local / 3) / organic_state.residue_fraction_count;
        return organicElement(local % 3, substrate == 4);
    }
    cursor += residue_component_count;

    const adsorbed_pool_count = state.adsorbed.len / state.layer_count;
    const adsorbed_component_count = 3 * adsorbed_pool_count;
    if (component < cursor + adsorbed_component_count) {
        const local = component - cursor;
        return organicElement(local % 3, local / 3 == 4);
    }
    cursor += adsorbed_component_count;

    const acetate = state.adsorbed_acetate_carbon_g_c.len / state.layer_count;
    if (component < cursor + acetate)
        return organicCarbon(component - cursor == 4);
    cursor += acetate;

    const structural = 3 * (state.structural.len / state.layer_count);
    if (component < cursor + structural) {
        const local = component - cursor;
        const substrate = (local / 3) / organic_state.structural_fraction_count;
        return organicElement(local % 3, substrate == 4);
    }
    cursor += structural;
    const annotations = state.colonized_structural_carbon_g_c.len / state.layer_count;
    if (component < cursor + annotations) return .{};
    return error.SuspendedInventoryDimensionMismatch;
}

fn organicElement(index: usize, is_humus: bool) SuspendedComposition {
    if (!is_humus) return switch (index) {
        0 => .{ .residue_carbon_g = 1 },
        1 => .{ .residue_nitrogen_g = 1 },
        2 => .{ .residue_phosphorus_g = 1 },
        else => unreachable,
    };
    return switch (index) {
        0 => .{ .organic_carbon_g = 1 },
        1 => .{ .organic_nitrogen_g = 1 },
        2 => .{ .organic_phosphorus_g = 1 },
        else => unreachable,
    };
}

fn organicCarbon(is_humus: bool) SuspendedComposition {
    return if (is_humus)
        .{ .organic_carbon_g = 1 }
    else
        .{ .residue_carbon_g = 1 };
}

fn dryComposition(component: usize, carbon_g_per_mol: f64, phosphorus_g_per_mol: f64) SuspendedComposition {
    inline for (@typeInfo(dry_mineral_fertilizer.Inventory).@"struct".fields, 0..) |field, index| if (component == index) {
        if (comptime std.mem.indexOf(u8, field.name, "monocalcium_phosphate") != null) return .{ .phosphate_phosphorus_g = 2 * phosphorus_g_per_mol, .calcium_mol = 1 };
        if (comptime std.mem.eql(u8, field.name, "hydroxyapatite_mol")) return .{ .phosphate_phosphorus_g = 3 * phosphorus_g_per_mol, .calcium_mol = 5 };
        if (comptime std.mem.eql(u8, field.name, "calcite_mol")) return .{ .inorganic_carbon_g = carbon_g_per_mol, .calcium_mol = 1 };
        if (comptime std.mem.eql(u8, field.name, "gypsum_mol")) return .{ .calcium_mol = 1, .sulfur_mol = 1 };
        if (comptime std.mem.startsWith(u8, field.name, "aluminum_")) return .{ .aluminum_mol = 1, .silicon_mol = 0.75 };
        if (comptime std.mem.startsWith(u8, field.name, "iron_")) return .{ .iron_mol = 1, .silicon_mol = 0.75 };
        if (comptime std.mem.startsWith(u8, field.name, "calcium_")) return .{ .calcium_mol = 1, .silicon_mol = 0.5 };
        if (comptime std.mem.startsWith(u8, field.name, "magnesium_")) return .{ .magnesium_mol = 1, .silicon_mol = 0.5 };
        if (comptime std.mem.startsWith(u8, field.name, "sodium_")) return .{ .sodium_mol = 1, .silicon_mol = 0.25 };
        if (comptime std.mem.startsWith(u8, field.name, "potassium_")) return .{ .potassium_mol = 1, .silicon_mol = 0.25 };
        unreachable;
    };
    unreachable;
}

fn chemistryComposition(component: usize, carbon_g_per_mol: f64, nitrogen_g_per_mol: f64, phosphorus_g_per_mol: f64) !SuspendedComposition {
    @setEvalBranchQuota(10_000);
    var cursor: usize = 0;
    inline for (@typeInfo(cation_exchange.Cations).@"struct".fields) |field| {
        if (component == cursor) return chemistryCation(field.name, nitrogen_g_per_mol);
        cursor += 1;
    }
    if (component == cursor) return .{};
    cursor += 1;
    inline for (0..2) |_| inline for (@typeInfo(phosphate_network.State).@"struct".fields) |field| if (comptime isErodiblePhosphateField(field.name)) {
        if (component == cursor) return phosphateComposition(field.name, phosphorus_g_per_mol);
        cursor += 1;
    };
    inline for (@typeInfo(geochemistry_network.SolidState).@"struct".fields) |field| {
        if (component == cursor) return geochemistryComposition(field.name, carbon_g_per_mol);
        cursor += 1;
    }
    return error.SuspendedInventoryDimensionMismatch;
}

fn chemistryCation(comptime name: []const u8, nitrogen_g_per_mol: f64) SuspendedComposition {
    if (std.mem.startsWith(u8, name, "ammonium")) return .{ .mineral_nitrogen_g = nitrogen_g_per_mol };
    if (std.mem.eql(u8, name, "aluminum")) return .{ .aluminum_mol = 1 };
    if (std.mem.eql(u8, name, "iron")) return .{ .iron_mol = 1 };
    if (std.mem.eql(u8, name, "calcium")) return .{ .calcium_mol = 1 };
    if (std.mem.eql(u8, name, "magnesium")) return .{ .magnesium_mol = 1 };
    if (std.mem.eql(u8, name, "sodium")) return .{ .sodium_mol = 1 };
    if (std.mem.eql(u8, name, "potassium")) return .{ .potassium_mol = 1 };
    return .{};
}

fn phosphateComposition(comptime name: []const u8, phosphorus_g_per_mol: f64) SuspendedComposition {
    var result: SuspendedComposition = .{ .phosphate_phosphorus_g = phosphateAtoms(name) * phosphorus_g_per_mol };
    if (std.mem.indexOf(u8, name, "aluminum_phosphate") != null) result.aluminum_mol = 1;
    if (std.mem.indexOf(u8, name, "iron_phosphate") != null) result.iron_mol = 1;
    if (std.mem.indexOf(u8, name, "dicalcium_phosphate") != null) result.calcium_mol = 1;
    if (std.mem.indexOf(u8, name, "hydroxyapatite") != null) result.calcium_mol = 5;
    if (std.mem.indexOf(u8, name, "monocalcium_phosphate") != null) result.calcium_mol = 1;
    return result;
}

fn geochemistryComposition(comptime name: []const u8, carbon_g_per_mol: f64) SuspendedComposition {
    if (std.mem.eql(u8, name, "gibbsite_solid_mol_per_m3")) return .{ .aluminum_mol = 1 };
    if (std.mem.eql(u8, name, "iron_hydroxide_solid_mol_per_m3")) return .{ .iron_mol = 1 };
    if (std.mem.eql(u8, name, "calcite_solid_mol_per_m3")) return .{ .inorganic_carbon_g = carbon_g_per_mol, .calcium_mol = 1 };
    if (std.mem.eql(u8, name, "gypsum_solid_mol_per_m3")) return .{ .calcium_mol = 1, .sulfur_mol = 1 };
    const silicon: f64 = if (comptime (std.mem.startsWith(u8, name, "aluminum_") or std.mem.startsWith(u8, name, "iron_"))) 0.75 else if (comptime (std.mem.startsWith(u8, name, "calcium_") or std.mem.startsWith(u8, name, "magnesium_"))) 0.5 else 0.25;
    if (std.mem.startsWith(u8, name, "aluminum_")) return .{ .aluminum_mol = 1, .silicon_mol = silicon };
    if (std.mem.startsWith(u8, name, "iron_")) return .{ .iron_mol = 1, .silicon_mol = silicon };
    if (std.mem.startsWith(u8, name, "calcium_")) return .{ .calcium_mol = 1, .silicon_mol = silicon };
    if (std.mem.startsWith(u8, name, "magnesium_")) return .{ .magnesium_mol = 1, .silicon_mol = silicon };
    if (std.mem.startsWith(u8, name, "sodium_")) return .{ .sodium_mol = 1, .silicon_mol = silicon };
    if (std.mem.startsWith(u8, name, "potassium_")) return .{ .potassium_mol = 1, .silicon_mol = silicon };
    unreachable;
}

fn isErodiblePhosphateField(comptime name: []const u8) bool {
    return std.mem.endsWith(u8, name, "_per_megagram") or std.mem.indexOf(u8, name, "_solid_mol_per_m3") != null;
}

fn phosphateAtoms(comptime name: []const u8) f64 {
    if (std.mem.indexOf(u8, name, "adsorbed_") != null) return 1;
    if (std.mem.indexOf(u8, name, "aluminum_phosphate") != null or std.mem.indexOf(u8, name, "iron_phosphate") != null or std.mem.indexOf(u8, name, "dicalcium_phosphate") != null) return 1;
    if (std.mem.indexOf(u8, name, "hydroxyapatite") != null) return 3;
    if (std.mem.indexOf(u8, name, "monocalcium_phosphate") != null) return 2;
    return 0;
}

pub var diagnostic_soil_matrix_ice_water_equivalent_m3: f64 = 0;

pub var diagnostic_soil_macropore_ice_water_equivalent_m3: f64 = 0;

/// HEAT-001 measurement instrumentation (temporary): summed water-vapor
/// water-equivalent volume across every active soil layer/cell, reset and
/// accumulated once per `aggregateSoilPhysicalAndGas` call. Used to measure
/// the real hourly Δvapor this defect's vaporization-latent-heat lead
/// depends on -- never obtained by two prior forks stopped before producing
/// it. Remove once HEAT-001 is closed or this lead is fully refuted.
pub var diagnostic_soil_vapor_water_equivalent_m3: f64 = 0;

/// HEAT-001 measurement instrumentation (temporary): summed dry-solid
/// extensive heat capacity (`dry_solid_heat_capacity_megajoules_per_m3_k *
/// layer_volume_m3`) across every active soil layer/cell. Absent erosion
/// texture change, this should be bit-for-bit constant hour to hour; if it
/// drifts, that drift times temperature is a direct, previously
/// unmeasured contributor to the census's heat_megajoules. Remove once
/// checked.
pub var diagnostic_soil_dry_solid_extensive_heat_capacity: f64 = 0;

test "mineral texture census is extensive while ROCK keeps source additive invariant" {
    var grid: grid_module.GridState = undefined;
    grid.cell_count = 2;
    grid.soil_layer_capacity = 2;
    grid.layer_count = 4;
    var active = [_]usize{ 2, 1 };
    grid.active_soil_layer_count = &active;
    var properties: soil_properties.State = undefined;
    properties.layer_count = 4;
    var sand = [_]f64{ 1, 2, 3, 99 };
    var silt = [_]f64{ 4, 5, 6, 99 };
    var clay = [_]f64{ 7, 8, 9, 99 };
    var rock = [_]f64{ 0.1, 0.2, 0.3, 0.9 };
    properties.sand_mass_megagrams = &sand;
    properties.silt_mass_megagrams = &silt;
    properties.clay_mass_megagrams = &clay;
    properties.rock_fraction = &rock;
    var cec = [_]f64{ 10, 20, 30, 999 };
    var aec = [_]f64{ 1, 2, 3, 999 };
    properties.cation_exchange_capacity_mol = &cec;
    properties.anion_exchange_capacity_mol = &aec;
    const all = try aggregateSoilMineralTexture(&grid, &properties);
    try std.testing.expectApproxEqAbs(@as(f64, 6), all.sand_megagrams, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 15), all.silt_megagrams, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 24), all.clay_megagrams, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), all.rock_additive, 1e-15);
    try std.testing.expectEqual(@as(f64, 60), all.cation_exchange_capacity_mol);
    try std.testing.expectEqual(@as(f64, 6), all.anion_exchange_capacity_mol);
    const cell = try aggregateSoilMineralTextureCell(&grid, &properties, 1);
    try std.testing.expectEqual(@as(f64, 3), cell.sand_megagrams);
    try std.testing.expectEqual(@as(f64, 0.3), cell.rock_additive);
    try std.testing.expectEqual(@as(f64, 30), cell.cation_exchange_capacity_mol);
    try std.testing.expectEqual(@as(f64, 3), cell.anion_exchange_capacity_mol);
}

test "suspended organic census preserves REDIST residue and humus provenance" {
    var organic_profile = try organic_state.State.init(std.testing.allocator, 1);
    defer organic_profile.deinit();
    const organic_count = try erosion_organic_bridge.componentCount(&organic_profile);
    const layout: suspended.Layout = .{
        .organic_cnp_count = organic_count,
        .nitrogen_fertilizer_count = erosion_fertilizer_bridge.component_count,
        .dry_mineral_fertilizer_count = @typeInfo(dry_mineral_fertilizer.Inventory).@"struct".fields.len,
        .chemistry_live_and_pending_count = erosion_chemistry_bridge.component_count,
    };
    var state = try suspended.State.init(std.testing.allocator, 1, layout);
    defer state.deinit();
    const range = try layout.range(.organic_cnp);

    // Packed organic-family order is microbial, residue, adsorbed, acetate,
    // structural, annotation. Only source substrate K=4 is soil organic/SOM;
    // K=5 autotrophs and every other substrate remain residue-category C/N/P.
    const humus_microbial = range.start + (4 * organic_state.microbial_population_count * organic_state.kinetic_fraction_count) * 3;
    state.pools[humus_microbial + 0] = 1;
    state.pools[humus_microbial + 1] = 2;
    state.pools[humus_microbial + 2] = 3;
    const residue_microbial = range.start + (5 * organic_state.microbial_population_count * organic_state.kinetic_fraction_count) * 3;
    state.pools[residue_microbial + 0] = 14;
    state.pools[residue_microbial + 1] = 15;
    state.pools[residue_microbial + 2] = 16;

    const microbial_components = 3 * organic_state.microbial_substrate_count * organic_state.microbial_population_count * organic_state.kinetic_fraction_count;
    const humus_residue = range.start + microbial_components + (4 * organic_state.residue_fraction_count) * 3;
    state.pools[humus_residue + 0] = 4;
    state.pools[humus_residue + 1] = 5;
    state.pools[humus_residue + 2] = 6;
    const residue_components = 3 * organic_state.substrate_count * organic_state.residue_fraction_count;
    const humus_adsorbed = range.start + microbial_components + residue_components + 4 * 3;
    state.pools[humus_adsorbed + 0] = 7;
    state.pools[humus_adsorbed + 1] = 8;
    state.pools[humus_adsorbed + 2] = 9;
    const adsorbed_components = 3 * organic_state.substrate_count;
    const acetate_start = range.start + microbial_components + residue_components + adsorbed_components;
    state.pools[acetate_start + 4] = 10;

    const structural_start = acetate_start + organic_state.substrate_count;
    const residue_structural = structural_start + (3 * organic_state.structural_fraction_count) * 3;
    state.pools[residue_structural + 0] = 17;
    state.pools[residue_structural + 1] = 18;
    state.pools[residue_structural + 2] = 19;
    const humus_structural = structural_start + (4 * organic_state.structural_fraction_count) * 3;
    state.pools[humus_structural + 0] = 11;
    state.pools[humus_structural + 1] = 12;
    state.pools[humus_structural + 2] = 13;
    const annotation_start = structural_start + 3 * organic_state.substrate_count * organic_state.structural_fraction_count;
    state.pools[annotation_start] = 1000; // annotation, never a second C pool

    const inventory = try aggregateSuspendedConstituents(&state, &organic_profile, 12, 14, 31);
    try std.testing.expectEqual(@as(f64, 33), inventory.organic_carbon_g);
    try std.testing.expectEqual(@as(f64, 27), inventory.organic_nitrogen_g);
    try std.testing.expectEqual(@as(f64, 31), inventory.organic_phosphorus_g);
    try std.testing.expectEqual(@as(f64, 31), inventory.residue_carbon_g);
    try std.testing.expectEqual(@as(f64, 33), inventory.residue_nitrogen_g);
    try std.testing.expectEqual(@as(f64, 35), inventory.residue_phosphorus_g);
}

test "suspended census rejects chemistry layouts that cannot match the bridge" {
    var organic_profile = try organic_state.State.init(std.testing.allocator, 1);
    defer organic_profile.deinit();
    var state = try suspended.State.init(std.testing.allocator, 1, .{
        .organic_cnp_count = try erosion_organic_bridge.componentCount(&organic_profile),
        .nitrogen_fertilizer_count = erosion_fertilizer_bridge.component_count,
        .dry_mineral_fertilizer_count = @typeInfo(dry_mineral_fertilizer.Inventory).@"struct".fields.len,
        .chemistry_live_and_pending_count = erosion_chemistry_bridge.component_count + 1,
    });
    defer state.deinit();
    try std.testing.expectError(
        error.SuspendedInventoryDimensionMismatch,
        aggregateSuspendedConstituents(&state, &organic_profile, 12, 14, 31),
    );
}
