const std = @import("std");

pub const Unit = enum {
    megagram,
    gram,
    mole,
};

pub const Component = struct {
    name: []const u8,
    unit: Unit,
};

pub const FluxState = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    component_count: usize,
    east: []f64,
    west: []f64,
    south: []f64,
    north: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, component_count: usize) !FluxState {
        if (cell_count == 0 or component_count == 0) return error.InvalidErodedConstituentDimensions;
        const count = try std.math.mul(usize, cell_count, component_count);
        var result: FluxState = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        result.component_count = component_count;
        var allocated: usize = 0;
        errdefer freeAllocated(&result, allocated);
        inline for (.{ "east", "west", "south", "north" }) |name| {
            @field(result, name) = try allocator.alloc(f64, count);
            @memset(@field(result, name), 0);
            allocated += 1;
        }
        return result;
    }

    pub fn deinit(self: *FluxState) void {
        inline for (.{ "east", "west", "south", "north" }) |name| self.allocator.free(@field(self, name));
        self.* = undefined;
    }
};

pub const PackedWorkspace = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    component_count: usize,
    pools: []f64,
    exported: []f64,
    flux: FluxState,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, component_count: usize) !PackedWorkspace {
        if (cell_count == 0 or component_count == 0) return error.InvalidErodedConstituentDimensions;
        const length = try std.math.mul(usize, cell_count, component_count);
        const pools = try allocator.alloc(f64, length);
        errdefer allocator.free(pools);
        const exported = try allocator.alloc(f64, length);
        errdefer allocator.free(exported);
        const flux = try FluxState.init(allocator, cell_count, component_count);
        @memset(pools, 0);
        @memset(exported, 0);
        return .{ .allocator = allocator, .cell_count = cell_count, .component_count = component_count, .pools = pools, .exported = exported, .flux = flux };
    }

    pub fn deinit(self: *PackedWorkspace) void {
        self.flux.deinit();
        self.allocator.free(self.exported);
        self.allocator.free(self.pools);
        self.* = undefined;
    }
};

pub const DirectionalSediment = struct {
    east_megagrams: []const f64,
    west_megagrams: []const f64,
    south_megagrams: []const f64,
    north_megagrams: []const f64,
};

/// Ports every EROSION `FSEDER * pool` expression through a runtime component
/// axis. Components retain their physical unit; the dimensionless transported
/// surface-mass fraction applies identically to Mg minerals, mol sorbed and
/// precipitated species, and g organic C/N/P pools in the Fortran source.
pub fn calculateFluxes(state: *FluxState, components: []const Component, surface_soil_mass_megagrams: []const f64, surface_pool_amounts: []const f64, cumulative_sediment: DirectionalSediment) !void {
    if (components.len != state.component_count or surface_soil_mass_megagrams.len != state.cell_count or surface_pool_amounts.len != state.east.len or cumulative_sediment.east_megagrams.len != state.cell_count or cumulative_sediment.west_megagrams.len != state.cell_count or cumulative_sediment.south_megagrams.len != state.cell_count or cumulative_sediment.north_megagrams.len != state.cell_count) return error.ErodedConstituentDimensionMismatch;
    for (components) |component| if (component.name.len == 0) return error.EmptyErodedComponentName;
    try calculatePackedFluxes(state, surface_soil_mass_megagrams, surface_pool_amounts, cumulative_sediment);
}

/// Runtime packed-pool variant used by the live soil chemistry and organic
/// bridges. Physical units remain owned by each packed component; erosion
/// applies only the dimensionless transported surface-mass fraction.
///
/// NOTE (EROSION-XER-DIRECTIONAL-CLOBBER-001, docs/discrepancy_register.md):
/// `erosion.f`'s `X*ER`/`X*EB` per-species flux family has a legacy `NN`-loop
/// self-clobber (`erosion.f:676--765`) that zeroes the east/south-bound slot
/// immediately after writing it, so the oracle only ever transports eroded
/// constituents west/north. This function deliberately applies the
/// transported fraction symmetrically to all four directions and does not
/// reproduce that oracle asymmetry. Currently inert either way: no production
/// site configuration selects an erosion-enabled disturbance mode (see
/// `docs/traceability/erosion_unbound_family_disposition.md`). If the erosion
/// path is ever revived, re-argue this against the disposition note rather
/// than assuming it.
pub fn calculatePackedFluxes(state: *FluxState, surface_soil_mass_megagrams: []const f64, surface_pool_amounts: []const f64, cumulative_sediment: DirectionalSediment) !void {
    if (surface_soil_mass_megagrams.len != state.cell_count or surface_pool_amounts.len != state.east.len or cumulative_sediment.east_megagrams.len != state.cell_count or cumulative_sediment.west_megagrams.len != state.cell_count or cumulative_sediment.south_megagrams.len != state.cell_count or cumulative_sediment.north_megagrams.len != state.cell_count) return error.ErodedConstituentDimensionMismatch;
    inline for (.{ state.east, state.west, state.south, state.north }) |values| @memset(values, 0);
    for (0..state.cell_count) |cell| {
        const soil_mass_megagrams = surface_soil_mass_megagrams[cell];
        if (!std.math.isFinite(soil_mass_megagrams) or soil_mass_megagrams <= 0) return error.InvalidSurfaceSoilMass;
        const sediment_by_direction = [_]f64{ cumulative_sediment.east_megagrams[cell], cumulative_sediment.west_megagrams[cell], cumulative_sediment.south_megagrams[cell], cumulative_sediment.north_megagrams[cell] };
        const output_by_direction = [_][]f64{ state.east, state.west, state.south, state.north };
        for (sediment_by_direction, output_by_direction) |sediment_megagrams, output| {
            if (!std.math.isFinite(sediment_megagrams) or sediment_megagrams < 0) return error.InvalidDirectionalSediment;
            const transported_fraction = @min(1, sediment_megagrams / soil_mass_megagrams);
            for (0..state.component_count) |component| {
                const index = cell * state.component_count + component;
                const pool = surface_pool_amounts[index];
                if (!std.math.isFinite(pool) or pool < 0) return error.InvalidSurfaceConstituentPool;
                output[index] = transported_fraction * pool;
            }
        }
    }
}

pub fn routePackedPools(allocator: std.mem.Allocator, columns: usize, rows: usize, component_count: usize, surface_soil_mass_megagrams: []const f64, surface_pool_amounts: []f64, cumulative_sediment: DirectionalSediment, exported_amounts: []f64) !void {
    const cell_count = try std.math.mul(usize, columns, rows);
    if (cell_count == 0 or component_count == 0 or surface_soil_mass_megagrams.len != cell_count or surface_pool_amounts.len != try std.math.mul(usize, cell_count, component_count) or exported_amounts.len != surface_pool_amounts.len) return error.ErodedConstituentDimensionMismatch;
    var flux = try FluxState.init(allocator, cell_count, component_count);
    defer flux.deinit();
    try calculatePackedFluxes(&flux, surface_soil_mass_megagrams, surface_pool_amounts, cumulative_sediment);
    try applyFluxes(columns, rows, flux, surface_pool_amounts, exported_amounts);
}

pub fn routePackedWorkspace(workspace: *PackedWorkspace, columns: usize, rows: usize, surface_soil_mass_megagrams: []const f64, cumulative_sediment: DirectionalSediment) !void {
    if (try std.math.mul(usize, columns, rows) != workspace.cell_count) return error.ErodedConstituentDimensionMismatch;
    try calculatePackedFluxes(&workspace.flux, surface_soil_mass_megagrams, workspace.pools, cumulative_sediment);
    try applyFluxes(columns, rows, workspace.flux, workspace.pools, workspace.exported);
}

/// Applies the REDIST-facing directional pools conservatively. The validation
/// pass completes before mutation, so an invalid flux cannot partially update
/// model state. External face fluxes are accumulated by source and component.
pub fn applyFluxes(columns: usize, rows: usize, flux: FluxState, surface_pool_amounts: []f64, exported_amounts: []f64) !void {
    if (columns == 0 or rows == 0 or try std.math.mul(usize, columns, rows) != flux.cell_count or surface_pool_amounts.len != flux.east.len or exported_amounts.len != flux.east.len) return error.ErodedConstituentDimensionMismatch;
    const component_count = flux.component_count;
    // Validate the complete transaction and ensure combined outgoing faces do
    // not exceed a source pool, rather than permitting silent negative pools.
    for (0..flux.cell_count) |cell| for (0..component_count) |component| {
        const index = cell * component_count + component;
        const pool = surface_pool_amounts[index];
        const outgoing = flux.east[index] + flux.west[index] + flux.south[index] + flux.north[index];
        if (!std.math.isFinite(pool) or pool < 0 or !std.math.isFinite(outgoing) or outgoing < 0) return error.InvalidErodedConstituentTransaction;
        const tolerance = 64 * std.math.floatEps(f64) * @max(1, pool);
        if (outgoing > pool + tolerance) return error.ErodedConstituentOutflowExceedsPool;
    };
    @memset(exported_amounts, 0);
    // Source-indexed faces make each transfer explicit. This deterministic
    // reduction can later consume independently generated parallel tile fluxes.
    for (0..rows) |row| for (0..columns) |column| {
        const cell = row * columns + column;
        for (0..component_count) |component| {
            const source = cell * component_count + component;
            const face_values = [_]f64{ flux.east[source], flux.west[source], flux.south[source], flux.north[source] };
            surface_pool_amounts[source] -= face_values[0] + face_values[1] + face_values[2] + face_values[3];
            if (column + 1 < columns) surface_pool_amounts[(cell + 1) * component_count + component] += face_values[0] else exported_amounts[source] += face_values[0];
            if (column > 0) surface_pool_amounts[(cell - 1) * component_count + component] += face_values[1] else exported_amounts[source] += face_values[1];
            if (row + 1 < rows) surface_pool_amounts[(cell + columns) * component_count + component] += face_values[2] else exported_amounts[source] += face_values[2];
            if (row > 0) surface_pool_amounts[(cell - columns) * component_count + component] += face_values[3] else exported_amounts[source] += face_values[3];
        }
    };
    for (surface_pool_amounts) |pool| if (!std.math.isFinite(pool) or pool < 0) return error.InvalidErodedConstituentStateUpdate;
}

fn freeAllocated(state: *FluxState, count: usize) void {
    var visited: usize = 0;
    inline for (.{ "east", "west", "south", "north" }) |name| {
        if (visited < count) state.allocator.free(@field(state, name));
        visited += 1;
    }
}

test "erosion fraction applies without converting component units" {
    var flux = try FluxState.init(std.testing.allocator, 1, 3);
    defer flux.deinit();
    const components = [_]Component{ .{ .name = "sand", .unit = .megagram }, .{ .name = "exchangeable_ammonium", .unit = .mole }, .{ .name = "microbial_carbon", .unit = .gram } };
    try calculateFluxes(&flux, &components, &.{10}, &.{ 4, 100, 2000 }, .{ .east_megagrams = &.{1}, .west_megagrams = &.{0}, .south_megagrams = &.{0}, .north_megagrams = &.{0} });
    try std.testing.expectEqual(@as(f64, 0.4), flux.east[0]);
    try std.testing.expectEqual(@as(f64, 10), flux.east[1]);
    try std.testing.expectEqual(@as(f64, 200), flux.east[2]);
}

test "packed runtime components route without artificial descriptors" {
    var pools = [_]f64{ 4, 100, 1, 2 };
    var exported: [4]f64 = undefined;
    try routePackedPools(std.testing.allocator, 2, 1, 2, &.{ 10, 10 }, &pools, .{ .east_megagrams = &.{ 1, 0 }, .west_megagrams = &.{ 0, 0 }, .south_megagrams = &.{ 0, 0 }, .north_megagrams = &.{ 0, 0 } }, &exported);
    try std.testing.expectApproxEqAbs(@as(f64, 3.6), pools[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 90), pools[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.4), pools[2], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 12), pools[3], 1e-14);
}

test "erosion fraction retains Fortran one-point-zero cap" {
    var flux = try FluxState.init(std.testing.allocator, 1, 1);
    defer flux.deinit();
    const components = [_]Component{.{ .name = "clay", .unit = .megagram }};
    try calculateFluxes(&flux, &components, &.{2}, &.{1.5}, .{ .east_megagrams = &.{3}, .west_megagrams = &.{0}, .south_megagrams = &.{0}, .north_megagrams = &.{0} });
    try std.testing.expectEqual(@as(f64, 1.5), flux.east[0]);
}

test "internal constituent transfer conserves each physical pool" {
    var flux = try FluxState.init(std.testing.allocator, 2, 3);
    defer flux.deinit();
    flux.east[0] = 0.4;
    flux.east[1] = 10;
    flux.east[2] = 200;
    var pools = [_]f64{ 4, 100, 2000, 1, 2, 3 };
    var exported: [6]f64 = undefined;
    const initial = [_]f64{ pools[0] + pools[3], pools[1] + pools[4], pools[2] + pools[5] };
    try applyFluxes(2, 1, flux, &pools, &exported);
    try std.testing.expectApproxEqAbs(initial[0], pools[0] + pools[3], 1e-14);
    try std.testing.expectApproxEqAbs(initial[1], pools[1] + pools[4], 1e-14);
    try std.testing.expectApproxEqAbs(initial[2], pools[2] + pools[5], 1e-14);
}

test "external constituent transfer is recorded as export" {
    var flux = try FluxState.init(std.testing.allocator, 1, 1);
    defer flux.deinit();
    flux.north[0] = 0.25;
    var pools = [_]f64{1};
    var exported: [1]f64 = undefined;
    try applyFluxes(1, 1, flux, &pools, &exported);
    try std.testing.expectEqual(@as(f64, 0.75), pools[0]);
    try std.testing.expectEqual(@as(f64, 0.25), exported[0]);
}

test "combined face outflow cannot silently make a pool negative" {
    var flux = try FluxState.init(std.testing.allocator, 1, 1);
    defer flux.deinit();
    flux.east[0] = 0.6;
    flux.west[0] = 0.6;
    var pools = [_]f64{1};
    var exported: [1]f64 = undefined;
    try std.testing.expectError(error.ErodedConstituentOutflowExceedsPool, applyFluxes(1, 1, flux, &pools, &exported));
    try std.testing.expectEqual(@as(f64, 1), pools[0]);
}
