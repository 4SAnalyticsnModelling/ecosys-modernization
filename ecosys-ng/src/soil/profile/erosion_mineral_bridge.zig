const std = @import("std");
const properties_module = @import("../water/solver_properties.zig");
const constituents = @import("../../erosion/eroded_constituents.zig");

pub const component_count: usize = 5;

pub const State = struct {
    initialized: bool,
    workspace: constituents.PackedWorkspace,
    staged_surface_soil_mass_megagrams: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        var workspace = try constituents.PackedWorkspace.init(allocator, cell_count, component_count);
        errdefer workspace.deinit();
        const staged = try allocator.alloc(f64, cell_count);
        @memset(staged, 0);
        return .{ .initialized = false, .workspace = workspace, .staged_surface_soil_mass_megagrams = staged };
    }

    pub fn deinit(self: *State) void {
        self.workspace.allocator.free(self.staged_surface_soil_mass_megagrams);
        self.workspace.deinit();
        self.* = undefined;
    }
};

pub fn route(columns: usize, rows: usize, layer_capacity: usize, surface_soil_mass_megagrams: []f64, properties: *properties_module.State, sediment: constituents.DirectionalSediment, state: *State) !void {
    const cells = try std.math.mul(usize, columns, rows);
    if (layer_capacity == 0 or properties.layer_count != try std.math.mul(usize, cells, layer_capacity) or surface_soil_mass_megagrams.len != cells or state.workspace.cell_count != cells or properties.sand_mass_megagrams.len != properties.layer_count or properties.silt_mass_megagrams.len != properties.layer_count or properties.clay_mass_megagrams.len != properties.layer_count or properties.cation_exchange_capacity_mol.len != properties.layer_count or properties.anion_exchange_capacity_mol.len != properties.layer_count) return error.MineralErosionDimensionMismatch;
    // erosion.f:551-555 / redist.f:5201-5205 re-derive every X*ER flux from the
    // single live SAND/SILT/CLAY/XCEC/XAEC arrays each hour; there is no
    // shadow copy in the Fortran reference. Reseeding `state.workspace.pools`
    // from `properties` on every call (not just the first) preserves that
    // invariant: any other subroutine that mutates the live mineral/CEC/AEC
    // arrays between erosion passes (e.g. the DIST-022 charcoal amendment in
    // `fertilizer_management_dispatch.zig`) is picked up immediately, instead
    // of being silently reverted by `refreshSurfaceProperties` below once
    // `state.initialized` latched true on hour one.
    for (0..cells) |cell| {
        const layer = cell * layer_capacity;
        const mass = surface_soil_mass_megagrams[cell];
        const sand = properties.sand_mass_fraction[layer];
        const clay = properties.clay_mass_fraction[layer];
        const silt = @max(0, 1 - sand - clay);
        inline for (.{ mass, sand, silt, clay, properties.cation_exchange_capacity_mol_per_megagram[layer], properties.anion_exchange_capacity_mol_per_megagram[layer] }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidMineralErosionState;
        if (mass <= 0) return error.InvalidMineralErosionState;
        const first = cell * component_count;
        state.workspace.pools[first + 0] = properties.sand_mass_megagrams[layer];
        state.workspace.pools[first + 1] = properties.silt_mass_megagrams[layer];
        state.workspace.pools[first + 2] = properties.clay_mass_megagrams[layer];
        const authoritative_mass = state.workspace.pools[first + 0] + state.workspace.pools[first + 1] + state.workspace.pools[first + 2];
        if (!std.math.isFinite(authoritative_mass) or authoritative_mass < 0) return error.InvalidMineralErosionState;
        state.workspace.pools[first + 3] = properties.cation_exchange_capacity_mol[layer];
        state.workspace.pools[first + 4] = properties.anion_exchange_capacity_mol[layer];
    }
    state.initialized = true;
    try constituents.calculatePackedFluxes(&state.workspace.flux, surface_soil_mass_megagrams, state.workspace.pools, sediment);
    try stageSurfaceSoilMass(columns, rows, surface_soil_mass_megagrams, sediment, state.staged_surface_soil_mass_megagrams);
    try constituents.applyFluxes(columns, rows, state.workspace.flux, state.workspace.pools, state.workspace.exported);
    @memcpy(surface_soil_mass_megagrams, state.staged_surface_soil_mass_megagrams);
    try refreshSurfaceProperties(layer_capacity, surface_soil_mass_megagrams, properties, state);
}

fn stageSurfaceSoilMass(columns: usize, rows: usize, mass_megagrams: []const f64, sediment: constituents.DirectionalSediment, staged_megagrams: []f64) !void {
    const cells = try std.math.mul(usize, columns, rows);
    if (cells == 0 or mass_megagrams.len != cells or staged_megagrams.len != cells or sediment.east_megagrams.len != cells or sediment.west_megagrams.len != cells or sediment.south_megagrams.len != cells or sediment.north_megagrams.len != cells) return error.MineralErosionDimensionMismatch;
    @memcpy(staged_megagrams, mass_megagrams);
    for (0..cells) |cell| {
        const outgoing = sediment.east_megagrams[cell] + sediment.west_megagrams[cell] + sediment.south_megagrams[cell] + sediment.north_megagrams[cell];
        inline for (.{ mass_megagrams[cell], sediment.east_megagrams[cell], sediment.west_megagrams[cell], sediment.south_megagrams[cell], sediment.north_megagrams[cell], outgoing }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidMineralErosionState;
        if (mass_megagrams[cell] <= 0 or outgoing > mass_megagrams[cell] + 64 * std.math.floatEps(f64) * @max(1, mass_megagrams[cell])) return error.InvalidMineralErosionState;
        staged_megagrams[cell] -= outgoing;
    }
    for (0..rows) |row| for (0..columns) |column| {
        const cell = row * columns + column;
        if (column + 1 < columns) staged_megagrams[cell + 1] += sediment.east_megagrams[cell];
        if (column > 0) staged_megagrams[cell - 1] += sediment.west_megagrams[cell];
        if (row + 1 < rows) staged_megagrams[cell + columns] += sediment.south_megagrams[cell];
        if (row > 0) staged_megagrams[cell - columns] += sediment.north_megagrams[cell];
    };
    for (staged_megagrams) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidMineralErosionCandidate;
}

/// Reconstructs the mutable topsoil property view from the authoritative
/// extensive mineral ledger after routing or checkpoint restore.
pub fn refreshSurfaceProperties(layer_capacity: usize, surface_soil_mass_megagrams: []f64, properties: *properties_module.State, state: *const State) !void {
    const cells = surface_soil_mass_megagrams.len;
    if (!state.initialized or layer_capacity == 0 or properties.layer_count != try std.math.mul(usize, cells, layer_capacity) or state.workspace.cell_count != cells or state.workspace.component_count != component_count or properties.sand_mass_megagrams.len != properties.layer_count or properties.silt_mass_megagrams.len != properties.layer_count or properties.clay_mass_megagrams.len != properties.layer_count or properties.cation_exchange_capacity_mol.len != properties.layer_count or properties.anion_exchange_capacity_mol.len != properties.layer_count) return error.MineralErosionDimensionMismatch;
    for (0..cells) |cell| {
        const first = cell * component_count;
        const mineral_mass = state.workspace.pools[first] + state.workspace.pools[first + 1] + state.workspace.pools[first + 2];
        const layer = cell * layer_capacity;
        // FSEDER's mutable BKVLNU denominator controls only the transported
        // fraction. HOUR1's canonical concentration carrier remains
        // BKVL=BKDS*VOLX until the later geometry transaction rebuilds it.
        const canonical_soil_mass = properties.bulk_density_megagrams_per_m3[layer] *
            properties.matrix_bulk_volume_m3[layer];
        if (!std.math.isFinite(mineral_mass) or mineral_mass < 0 or
            !std.math.isFinite(surface_soil_mass_megagrams[cell]) or surface_soil_mass_megagrams[cell] <= 0 or
            !std.math.isFinite(canonical_soil_mass) or canonical_soil_mass <= 0)
            return error.InvalidMineralErosionCandidate;
        properties.sand_mass_fraction[layer] = state.workspace.pools[first] / canonical_soil_mass;
        properties.silt_mass_fraction[layer] = state.workspace.pools[first + 1] / canonical_soil_mass;
        properties.clay_mass_fraction[layer] = state.workspace.pools[first + 2] / canonical_soil_mass;
        properties.sand_mass_megagrams[layer] = state.workspace.pools[first];
        properties.silt_mass_megagrams[layer] = state.workspace.pools[first + 1];
        properties.clay_mass_megagrams[layer] = state.workspace.pools[first + 2];
        properties.cation_exchange_capacity_mol_per_megagram[layer] = state.workspace.pools[first + 3] / canonical_soil_mass;
        properties.anion_exchange_capacity_mol_per_megagram[layer] = state.workspace.pools[first + 4] / canonical_soil_mass;
        properties.cation_exchange_capacity_mol[layer] = state.workspace.pools[first + 3];
        properties.anion_exchange_capacity_mol[layer] = state.workspace.pools[first + 4];
    }
}

test "mineral texture and exchange capacity follow sediment mass" {
    var properties: properties_module.State = undefined;
    properties.layer_count = 2;
    var sand = [_]f64{ 0.6, 0.2 };
    var silt_fraction = [_]f64{ 0.3, 0.5 };
    var clay = [_]f64{ 0.1, 0.3 };
    var cec = [_]f64{ 10, 20 };
    var aec = [_]f64{ 1, 2 };
    properties.sand_mass_fraction = &sand;
    properties.silt_mass_fraction = &silt_fraction;
    properties.clay_mass_fraction = &clay;
    var matrix_volume = [_]f64{ 10, 10 };
    var bulk_density = [_]f64{ 1, 1 };
    properties.matrix_bulk_volume_m3 = &matrix_volume;
    properties.bulk_density_megagrams_per_m3 = &bulk_density;
    var sand_mass = [_]f64{ 6, 2 };
    var silt_mass = [_]f64{ 3, 5 };
    var clay_mass = [_]f64{ 1, 3 };
    properties.sand_mass_megagrams = &sand_mass;
    properties.silt_mass_megagrams = &silt_mass;
    properties.clay_mass_megagrams = &clay_mass;
    properties.cation_exchange_capacity_mol_per_megagram = &cec;
    properties.anion_exchange_capacity_mol_per_megagram = &aec;
    var cec_mol = [_]f64{ 100, 200 };
    var aec_mol = [_]f64{ 10, 20 };
    properties.cation_exchange_capacity_mol = &cec_mol;
    properties.anion_exchange_capacity_mol = &aec_mol;
    var mass = [_]f64{ 10, 10 };
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    try route(2, 1, 1, &mass, &properties, .{ .east_megagrams = &.{ 1, 0 }, .west_megagrams = &.{ 0, 0 }, .south_megagrams = &.{ 0, 0 }, .north_megagrams = &.{ 0, 0 } }, &state);
    try std.testing.expectApproxEqAbs(@as(f64, 9), mass[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 11), mass[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.54), sand[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.26), sand[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 9), cec[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 21), cec[1], 1e-14);
}

test "route picks up a mid-run CEC/AEC amendment instead of reverting to the hour-one cache" {
    // Regression for the erosion_mineral_bridge one-time-cache defect: a
    // shallow charcoal/biochar amendment (fertilizer_management_dispatch.zig,
    // the DIST-022 fix) writes directly into the same solver_properties.State
    // arrays this bridge owns. erosion.f:551-555 re-derives every X*ER flux
    // from the live SAND/XCEC/XAEC arrays each hour, so the next erosion pass
    // must see the amended value, not silently revert it.
    var properties: properties_module.State = undefined;
    properties.layer_count = 1;
    var sand = [_]f64{0.6};
    var silt_fraction = [_]f64{0.3};
    var clay = [_]f64{0.1};
    var cec = [_]f64{10};
    var aec = [_]f64{1};
    properties.sand_mass_fraction = &sand;
    properties.silt_mass_fraction = &silt_fraction;
    properties.clay_mass_fraction = &clay;
    var matrix_volume = [_]f64{10};
    var bulk_density = [_]f64{1};
    properties.matrix_bulk_volume_m3 = &matrix_volume;
    properties.bulk_density_megagrams_per_m3 = &bulk_density;
    var sand_mass = [_]f64{6};
    var silt_mass = [_]f64{3};
    var clay_mass = [_]f64{1};
    properties.sand_mass_megagrams = &sand_mass;
    properties.silt_mass_megagrams = &silt_mass;
    properties.clay_mass_megagrams = &clay_mass;
    properties.cation_exchange_capacity_mol_per_megagram = &cec;
    properties.anion_exchange_capacity_mol_per_megagram = &aec;
    var cec_mol = [_]f64{100};
    var aec_mol = [_]f64{10};
    properties.cation_exchange_capacity_mol = &cec_mol;
    properties.anion_exchange_capacity_mol = &aec_mol;
    var mass = [_]f64{10};
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const no_sediment = constituents.DirectionalSediment{ .east_megagrams = &.{0}, .west_megagrams = &.{0}, .south_megagrams = &.{0}, .north_megagrams = &.{0} };
    // Hour one seeds the cache.
    try route(1, 1, 1, &mass, &properties, no_sediment, &state);
    try std.testing.expectApproxEqAbs(@as(f64, 100), cec_mol[0], 1e-14);
    // A same-layer charcoal amendment bumps CEC/AEC directly on the live
    // solver_properties arrays, exactly as fertilizer_management_dispatch.zig
    // does for a shallow (first-layer) application depth.
    cec_mol[0] = 150;
    aec_mol[0] = 16;
    // The very next hourly erosion pass must observe the amendment rather
    // than re-imposing the hour-one snapshot.
    try route(1, 1, 1, &mass, &properties, no_sediment, &state);
    try std.testing.expectApproxEqAbs(@as(f64, 150), cec_mol[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 16), aec_mol[0], 1e-14);
}
