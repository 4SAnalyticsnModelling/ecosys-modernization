const std = @import("std");
const organic = @import("../organic/initialization.zig");
const constituents = @import("../../erosion/eroded_constituents.zig");
const erosion = @import("erosion.zig");

pub const ExportedElementsG = struct {
    carbon_g_c: f64 = 0,
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
};

pub fn componentCount(state: *const organic.State) !usize {
    if (state.layer_count == 0 or state.microbial.len % state.layer_count != 0 or state.residue.len % state.layer_count != 0 or state.adsorbed.len % state.layer_count != 0 or state.adsorbed_acetate_carbon_g_c.len % state.layer_count != 0 or state.structural.len % state.layer_count != 0 or state.colonized_structural_carbon_g_c.len % state.layer_count != 0) return error.OrganicErosionDimensionMismatch;
    return 3 * (state.microbial.len / state.layer_count + state.residue.len / state.layer_count + state.adsorbed.len / state.layer_count + state.structural.len / state.layer_count) +
        state.adsorbed_acetate_carbon_g_c.len / state.layer_count +
        state.colonized_structural_carbon_g_c.len / state.layer_count;
}

pub fn route(
    columns: usize,
    rows: usize,
    soil_layer_capacity: usize,
    surface_soil_mass_megagrams: []const f64,
    state: *organic.State,
    sediment: constituents.DirectionalSediment,
    workspace: *constituents.PackedWorkspace,
    accepted_carbon_net_change_g_c_by_layer: []f64,
) !void {
    const cells = try std.math.mul(usize, columns, rows);
    if (soil_layer_capacity == 0 or
        state.layer_count != try std.math.mul(usize, cells, soil_layer_capacity) or
        accepted_carbon_net_change_g_c_by_layer.len != state.layer_count)
        return error.OrganicErosionDimensionMismatch;
    const component_count = try componentCount(state);
    if (workspace.cell_count != cells or workspace.component_count != component_count) return error.OrganicErosionDimensionMismatch;
    try packSurface(state, cells, soil_layer_capacity, component_count, workspace.pools);
    try constituents.routePackedWorkspace(workspace, columns, rows, surface_soil_mass_megagrams, sediment);
    try publishAcceptedCarbonNetChange(
        columns,
        rows,
        soil_layer_capacity,
        state,
        workspace,
        accepted_carbon_net_change_g_c_by_layer,
    );
    try unpackSurface(state, cells, soil_layer_capacity, component_count, workspace.pools);
}

/// Publishes legacy DORGE from the accepted directional fluxes themselves.
/// Positive is net sediment deposition into a cell and negative is net loss.
/// Only the surface soil layer participates, exactly matching REDIST's
/// `IF(L.EQ.NU) DORGC=DORGC+DORGE` branch.
fn publishAcceptedCarbonNetChange(
    columns: usize,
    rows: usize,
    soil_layer_capacity: usize,
    state: *const organic.State,
    workspace: *const constituents.PackedWorkspace,
    output: []f64,
) !void {
    const cells = try std.math.mul(usize, columns, rows);
    if (workspace.cell_count != cells or output.len != state.layer_count)
        return error.OrganicErosionDimensionMismatch;
    @memset(output, 0);
    for (0..cells) |cell| {
        var cursor: usize = 0;
        var net_change_g_c: f64 = 0;
        inline for (.{ state.microbial, state.residue, state.adsorbed }) |pools| {
            const per_layer = pools.len / state.layer_count;
            for (0..per_layer) |_| {
                net_change_g_c += try componentNetChange(
                    &workspace.flux,
                    columns,
                    rows,
                    cell,
                    cursor,
                );
                cursor += 3;
            }
        }
        const acetate_per_layer = state.adsorbed_acetate_carbon_g_c.len / state.layer_count;
        for (0..acetate_per_layer) |_| {
            net_change_g_c += try componentNetChange(
                &workspace.flux,
                columns,
                rows,
                cell,
                cursor,
            );
            cursor += 1;
        }
        const structural_per_layer = state.structural.len / state.layer_count;
        for (0..structural_per_layer) |_| {
            net_change_g_c += try componentNetChange(
                &workspace.flux,
                columns,
                rows,
                cell,
                cursor,
            );
            cursor += 3;
        }
        // Colonized structural C is an annotation, not an additional C pool.
        cursor += state.colonized_structural_carbon_g_c.len / state.layer_count;
        if (cursor != workspace.component_count or !std.math.isFinite(net_change_g_c))
            return error.OrganicErosionDimensionMismatch;
        output[cell * soil_layer_capacity] = net_change_g_c;
    }
}

fn componentNetChange(
    flux: *const constituents.FluxState,
    columns: usize,
    rows: usize,
    cell: usize,
    component: usize,
) !f64 {
    if (cell >= flux.cell_count or component >= flux.component_count)
        return error.OrganicErosionDimensionMismatch;
    const row = cell / columns;
    const column = cell % columns;
    const source = cell * flux.component_count + component;
    var change = -(flux.east[source] + flux.west[source] +
        flux.south[source] + flux.north[source]);
    if (column > 0)
        change += flux.east[(cell - 1) * flux.component_count + component];
    if (column + 1 < columns)
        change += flux.west[(cell + 1) * flux.component_count + component];
    if (row > 0)
        change += flux.south[(cell - columns) * flux.component_count + component];
    if (row + 1 < rows)
        change += flux.north[(cell + columns) * flux.component_count + component];
    if (!std.math.isFinite(change)) return error.NonFiniteOrganicErosionCarbonChange;
    return change;
}

/// Refreshes HOUR1's ORGC concentration from the authoritative extensive
/// organic pools. Colonized structural carbon is an annotation of structural
/// carbon and is therefore not counted a second time.
pub fn refreshSurfaceOrganicCarbonGPerMg(
    state: *const organic.State,
    soil_layer_capacity: usize,
    surface_soil_mass_megagrams: []const f64,
    total_organic_carbon_g_per_megagram: []f64,
) !void {
    return refreshSurfaceOrganicCarbonGPerMgMapped(
        state,
        soil_layer_capacity,
        &.{},
        surface_soil_mass_megagrams,
        total_organic_carbon_g_per_megagram,
    );
}

pub fn refreshSurfaceOrganicCarbonGPerMgMapped(
    state: *const organic.State,
    soil_layer_capacity: usize,
    top_layer_by_cell: []const usize,
    canonical_soil_mass_megagrams: []const f64,
    total_organic_carbon_g_per_megagram: []f64,
) !void {
    const cells = canonical_soil_mass_megagrams.len;
    if (soil_layer_capacity == 0 or state.layer_count != try std.math.mul(usize, cells, soil_layer_capacity) or total_organic_carbon_g_per_megagram.len != state.layer_count) return error.OrganicErosionDimensionMismatch;
    if (top_layer_by_cell.len != 0 and top_layer_by_cell.len != cells)
        return error.OrganicErosionDimensionMismatch;
    for (0..cells) |cell| {
        const local = if (top_layer_by_cell.len == 0) 0 else top_layer_by_cell[cell];
        if (local >= soil_layer_capacity) return error.OrganicErosionDimensionMismatch;
        const layer = cell * soil_layer_capacity + local;
        const soil_mass_megagrams = canonical_soil_mass_megagrams[cell];
        if (!std.math.isFinite(soil_mass_megagrams) or soil_mass_megagrams < 0) return error.InvalidOrganicErosionState;
        var carbon_g: f64 = 0;
        inline for (.{ state.microbial, state.residue, state.adsorbed }) |pools| {
            const per_layer = pools.len / state.layer_count;
            for (pools[layer * per_layer ..][0..per_layer]) |pool| carbon_g += pool.carbon_g_c;
        }
        const acetate_per_layer = state.adsorbed_acetate_carbon_g_c.len / state.layer_count;
        for (state.adsorbed_acetate_carbon_g_c[layer * acetate_per_layer ..][0..acetate_per_layer]) |value| carbon_g += value;
        const structural_per_layer = state.structural.len / state.layer_count;
        for (state.structural[layer * structural_per_layer ..][0..structural_per_layer]) |pool| carbon_g += pool.carbon_g_c;
        if (!std.math.isFinite(carbon_g) or carbon_g < 0) return error.InvalidOrganicErosionState;
        // Extensive organic pools remain authoritative in open water. There
        // is no legitimate per-mineral-mass concentration when BKVL is zero.
        total_organic_carbon_g_per_megagram[layer] = if (soil_mass_megagrams > 0)
            carbon_g / soil_mass_megagrams
        else
            0;
    }
}

/// Publishes the accepted topsoil organic-carbon change from the persistent
/// suspension exchange. Positive packed transfer is topsoil -> suspension,
/// so the scientific DORGE owner receives its negative. Colonization remains
/// an annotation and is deliberately not counted as a second carbon pool.
pub fn publishLocalCarbonNetChange(
    state: *const organic.State,
    soil_layer_capacity: usize,
    signed_transfer_to_suspension: []const f64,
    output: []f64,
) !void {
    return publishLocalCarbonNetChangeMapped(
        state,
        soil_layer_capacity,
        &.{},
        signed_transfer_to_suspension,
        output,
    );
}

pub fn publishLocalCarbonNetChangeMapped(
    state: *const organic.State,
    soil_layer_capacity: usize,
    top_layer_by_cell: []const usize,
    signed_transfer_to_suspension: []const f64,
    output: []f64,
) !void {
    const cells = if (soil_layer_capacity == 0) 0 else state.layer_count / soil_layer_capacity;
    const components = try componentCount(state);
    if (cells == 0 or state.layer_count != try std.math.mul(usize, cells, soil_layer_capacity) or
        signed_transfer_to_suspension.len != try std.math.mul(usize, cells, components) or
        output.len != state.layer_count)
        return error.OrganicErosionDimensionMismatch;
    if (top_layer_by_cell.len != 0 and top_layer_by_cell.len != cells)
        return error.OrganicErosionDimensionMismatch;
    for (signed_transfer_to_suspension) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteOrganicErosionCarbonChange;
    @memset(output, 0);
    for (0..cells) |cell| {
        var cursor = cell * components;
        var change: f64 = 0;
        inline for (.{ state.microbial, state.residue, state.adsorbed }) |pools| {
            const per_layer = pools.len / state.layer_count;
            for (0..per_layer) |_| {
                change -= signed_transfer_to_suspension[cursor];
                cursor += 3;
            }
        }
        const acetate_per_layer = state.adsorbed_acetate_carbon_g_c.len / state.layer_count;
        for (0..acetate_per_layer) |_| {
            change -= signed_transfer_to_suspension[cursor];
            cursor += 1;
        }
        const structural_per_layer = state.structural.len / state.layer_count;
        for (0..structural_per_layer) |_| {
            change -= signed_transfer_to_suspension[cursor];
            cursor += 3;
        }
        cursor += state.colonized_structural_carbon_g_c.len / state.layer_count;
        if (cursor != (cell + 1) * components or !std.math.isFinite(change))
            return error.OrganicErosionDimensionMismatch;
        const local = if (top_layer_by_cell.len == 0) 0 else top_layer_by_cell[cell];
        if (local >= soil_layer_capacity) return error.OrganicErosionDimensionMismatch;
        output[cell * soil_layer_capacity + local] = change;
    }
}

/// Adds accepted suspension-to-topsoil organic carbon to the same DORGE
/// cancellation owner used by local erosion. Settling is positive topsoil C;
/// colonized structural carbon remains an annotation.
pub fn accumulateSettledCarbonNetChangeMapped(
    state: *const organic.State,
    soil_layer_capacity: usize,
    top_layer_by_cell: []const usize,
    settled_transfer_to_topsoil: []const f64,
    output: []f64,
) !void {
    const cells = if (soil_layer_capacity == 0) 0 else state.layer_count / soil_layer_capacity;
    const components = try componentCount(state);
    if (cells == 0 or state.layer_count != try std.math.mul(usize, cells, soil_layer_capacity) or
        top_layer_by_cell.len != cells or settled_transfer_to_topsoil.len != try std.math.mul(usize, cells, components) or
        output.len != state.layer_count)
        return error.OrganicErosionDimensionMismatch;
    for (settled_transfer_to_topsoil) |value|
        if (!std.math.isFinite(value) or value < 0) return error.NonFiniteOrganicErosionCarbonChange;
    for (0..cells) |cell| {
        var cursor = cell * components;
        var change: f64 = 0;
        inline for (.{ state.microbial, state.residue, state.adsorbed }) |pools| {
            const per_layer = pools.len / state.layer_count;
            for (0..per_layer) |_| {
                change += settled_transfer_to_topsoil[cursor];
                cursor += 3;
            }
        }
        const acetate_per_layer = state.adsorbed_acetate_carbon_g_c.len / state.layer_count;
        for (0..acetate_per_layer) |_| {
            change += settled_transfer_to_topsoil[cursor];
            cursor += 1;
        }
        const structural_per_layer = state.structural.len / state.layer_count;
        for (0..structural_per_layer) |_| {
            change += settled_transfer_to_topsoil[cursor];
            cursor += 3;
        }
        cursor += state.colonized_structural_carbon_g_c.len / state.layer_count;
        const local = top_layer_by_cell[cell];
        if (cursor != (cell + 1) * components or local >= soil_layer_capacity or !std.math.isFinite(change))
            return error.OrganicErosionDimensionMismatch;
        const index = cell * soil_layer_capacity + local;
        const next = output[index] + change;
        if (!std.math.isFinite(next)) return error.NonFiniteOrganicErosionCarbonChange;
        output[index] = next;
    }
}

/// REDIST `ORGR` (`redist.f` 7900--7970 accumulating `DC`, assigned at 6869):
/// non-humus organic carbon, i.e. every complex `K.NE.4`, and excluding the
/// charcoal structural fraction `OSC(5,...)` which accumulates into `DCC`.
/// In this state that is substrates `0..3` minus structural fraction 4.
/// HOUR1 needs it as `CORRM` (`hour1.f:2935`) to split the plant-residue term
/// out of total SOM for D50, cohesion and rainfall detachability.
pub fn surfaceResidueCarbonG(state: *const organic.State, soil_layer_capacity: usize, cell: usize) !f64 {
    if (soil_layer_capacity == 0) return error.OrganicErosionDimensionMismatch;
    const layer = try std.math.mul(usize, cell, soil_layer_capacity);
    if (layer >= state.layer_count) return error.OrganicErosionDimensionMismatch;
    var total: f64 = 0;
    for (0..organic.substrate_count - 1) |substrate| {
        total += try state.substrateCarbon_g_c(layer, substrate);
        const charcoal_index = (layer * organic.substrate_count + substrate) *
            organic.structural_fraction_count + (organic.structural_fraction_count - 1);
        total -= state.structural[charcoal_index].carbon_g_c;
    }
    if (!std.math.isFinite(total) or total < 0) return error.InvalidOrganicErosionState;
    return total;
}

/// REDIST `COE/ZOE/POE` external sediment loss. Colonized structural carbon
/// remains an annotation of its structural pool and is not counted twice.
pub noinline fn exportedElements(
    state: *const organic.State,
    workspace: *const constituents.PackedWorkspace,
) !ExportedElementsG {
    const components = try componentCount(state);
    if (workspace.component_count != components or
        workspace.exported.len !=
            try std.math.mul(usize, workspace.cell_count, components))
        return error.OrganicErosionDimensionMismatch;
    var result: ExportedElementsG = .{};
    for (0..workspace.cell_count) |cell| {
        var cursor = cell * components;
        try sumElementExports(
            state.microbial.len / state.layer_count,
            workspace.exported,
            &cursor,
            &result,
        );
        try sumElementExports(
            state.residue.len / state.layer_count,
            workspace.exported,
            &cursor,
            &result,
        );
        try sumElementExports(
            state.adsorbed.len / state.layer_count,
            workspace.exported,
            &cursor,
            &result,
        );
        const acetate_count =
            state.adsorbed_acetate_carbon_g_c.len / state.layer_count;
        for (0..acetate_count) |_| {
            result.carbon_g_c = try addExport(
                result.carbon_g_c,
                workspace.exported[cursor],
            );
            cursor += 1;
        }
        try sumElementExports(
            state.structural.len / state.layer_count,
            workspace.exported,
            &cursor,
            &result,
        );
        cursor += state.colonized_structural_carbon_g_c.len / state.layer_count;
        if (cursor != (cell + 1) * components)
            return error.OrganicErosionDimensionMismatch;
    }
    return result;
}

fn sumElementExports(
    pool_count: usize,
    values: []const f64,
    cursor: *usize,
    result: *ExportedElementsG,
) !void {
    for (0..pool_count) |_| {
        result.carbon_g_c = try addExport(result.carbon_g_c, values[cursor.*]);
        cursor.* += 1;
        result.nitrogen_g_n = try addExport(result.nitrogen_g_n, values[cursor.*]);
        cursor.* += 1;
        result.phosphorus_g_p = try addExport(result.phosphorus_g_p, values[cursor.*]);
        cursor.* += 1;
    }
}

fn addExport(total: f64, value: f64) !f64 {
    if (!std.math.isFinite(value) or value < 0)
        return error.InvalidOrganicErosionExport;
    const next = total + value;
    if (!std.math.isFinite(next)) return error.OrganicErosionExportOverflow;
    return next;
}

pub fn packSurface(state: *const organic.State, cells: usize, soil_layer_capacity: usize, component_count: usize, output: []f64) !void {
    return packSurfaceMapped(state, cells, soil_layer_capacity, component_count, &.{}, output);
}

pub fn packSurfaceMapped(state: *const organic.State, cells: usize, soil_layer_capacity: usize, component_count: usize, top_layer_by_cell: []const usize, output: []f64) !void {
    if (top_layer_by_cell.len != 0 and top_layer_by_cell.len != cells) return error.OrganicErosionDimensionMismatch;
    for (0..cells) |cell| {
        const local = if (top_layer_by_cell.len == 0) 0 else top_layer_by_cell[cell];
        if (local >= soil_layer_capacity) return error.OrganicErosionDimensionMismatch;
        const layer = cell * soil_layer_capacity + local;
        var cursor = cell * component_count;
        try packElementLayer(state.microbial, state.layer_count, layer, output, &cursor);
        try packElementLayer(state.residue, state.layer_count, layer, output, &cursor);
        try packElementLayer(state.adsorbed, state.layer_count, layer, output, &cursor);
        try packScalarLayer(state.adsorbed_acetate_carbon_g_c, state.layer_count, layer, output, &cursor);
        try packElementLayer(state.structural, state.layer_count, layer, output, &cursor);
        try packScalarLayer(state.colonized_structural_carbon_g_c, state.layer_count, layer, output, &cursor);
        if (cursor != (cell + 1) * component_count) return error.OrganicErosionDimensionMismatch;
    }
}

pub fn unpackSurface(state: *organic.State, cells: usize, soil_layer_capacity: usize, component_count: usize, input: []const f64) !void {
    return unpackSurfaceMapped(state, cells, soil_layer_capacity, component_count, &.{}, input);
}

pub fn unpackSurfaceMapped(state: *organic.State, cells: usize, soil_layer_capacity: usize, component_count: usize, top_layer_by_cell: []const usize, input: []const f64) !void {
    if (top_layer_by_cell.len != 0 and top_layer_by_cell.len != cells) return error.OrganicErosionDimensionMismatch;
    for (input) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicErosionCandidate;
    for (0..cells) |cell| {
        const local = if (top_layer_by_cell.len == 0) 0 else top_layer_by_cell[cell];
        if (local >= soil_layer_capacity) return error.OrganicErosionDimensionMismatch;
        const layer = cell * soil_layer_capacity + local;
        var cursor = cell * component_count;
        try unpackElementLayer(state.microbial, state.layer_count, layer, input, &cursor);
        try unpackElementLayer(state.residue, state.layer_count, layer, input, &cursor);
        try unpackElementLayer(state.adsorbed, state.layer_count, layer, input, &cursor);
        try unpackScalarLayer(state.adsorbed_acetate_carbon_g_c, state.layer_count, layer, input, &cursor);
        try unpackElementLayer(state.structural, state.layer_count, layer, input, &cursor);
        try unpackScalarLayer(state.colonized_structural_carbon_g_c, state.layer_count, layer, input, &cursor);
    }
}

fn packElementLayer(values: []const organic.ElementPool, layer_count: usize, layer: usize, output: []f64, cursor: *usize) !void {
    const per_layer = values.len / layer_count;
    for (values[layer * per_layer ..][0..per_layer]) |pool| inline for (@typeInfo(organic.ElementPool).@"struct".fields) |field| {
        const value = @field(pool, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicErosionState;
        output[cursor.*] = value;
        cursor.* += 1;
    };
}

fn unpackElementLayer(values: []organic.ElementPool, layer_count: usize, layer: usize, input: []const f64, cursor: *usize) !void {
    const per_layer = values.len / layer_count;
    for (values[layer * per_layer ..][0..per_layer]) |*pool| inline for (@typeInfo(organic.ElementPool).@"struct".fields) |field| {
        @field(pool, field.name) = input[cursor.*];
        cursor.* += 1;
    };
}

fn packScalarLayer(values: []const f64, layer_count: usize, layer: usize, output: []f64, cursor: *usize) !void {
    const per_layer = values.len / layer_count;
    for (values[layer * per_layer ..][0..per_layer]) |value| {
        if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicErosionState;
        output[cursor.*] = value;
        cursor.* += 1;
    }
}

fn unpackScalarLayer(values: []f64, layer_count: usize, layer: usize, input: []const f64, cursor: *usize) !void {
    const per_layer = values.len / layer_count;
    for (values[layer * per_layer ..][0..per_layer]) |*value| {
        value.* = input[cursor.*];
        cursor.* += 1;
    }
}

test "all solid organic families follow sediment conservatively" {
    var state = try organic.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.microbial[0].carbon_g_c = 10;
    state.residue[0].nitrogen_g_n = 20;
    state.adsorbed[0].phosphorus_g_p = 30;
    state.adsorbed_acetate_carbon_g_c[0] = 40;
    state.structural[0].carbon_g_c = 50;
    state.colonized_structural_carbon_g_c[0] = 60;
    const count = try componentCount(&state);
    var workspace = try constituents.PackedWorkspace.init(std.testing.allocator, 2, count);
    defer workspace.deinit();
    var erosion_carbon_change = [_]f64{ 0, 0 };
    try route(2, 1, 1, &.{ 10, 10 }, &state, .{ .east_megagrams = &.{ 1, 0 }, .west_megagrams = &.{ 0, 0 }, .south_megagrams = &.{ 0, 0 }, .north_megagrams = &.{ 0, 0 } }, &workspace, &erosion_carbon_change);
    try std.testing.expectApproxEqAbs(@as(f64, 9), state.microbial[0].carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1), state.microbial[state.microbial.len / 2].carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 54), state.colonized_structural_carbon_g_c[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 6), state.colonized_structural_carbon_g_c[state.colonized_structural_carbon_g_c.len / 2], 1e-14);
    var total_organic_carbon_g_per_megagram = [_]f64{ 0, 0 };
    try refreshSurfaceOrganicCarbonGPerMg(&state, 1, &.{ 10, 10 }, &total_organic_carbon_g_per_megagram);
    try std.testing.expectApproxEqAbs(@as(f64, 9), total_organic_carbon_g_per_megagram[0], 1e-14);
    // DORGE excludes colonized annotation: 10 microbial + 40 acetate + 50
    // structural, of which ten percent moved east.
    try std.testing.expectApproxEqAbs(@as(f64, -10), erosion_carbon_change[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 10), erosion_carbon_change[1], 1e-14);
}

test "ORGR excludes the humus complex and charcoal" {
    var state = try organic.State.init(std.testing.allocator, 1);
    defer state.deinit();
    // One unit into every substrate's non-charcoal structural fraction 0, plus
    // one unit into every substrate's charcoal fraction 4.
    for (0..organic.substrate_count) |substrate| {
        const base = (0 * organic.substrate_count + substrate) * organic.structural_fraction_count;
        state.structural[base + 0].carbon_g_c = 1;
        state.structural[base + organic.structural_fraction_count - 1].carbon_g_c = 1;
    }
    // Total carbon sees all 10 units; ORGR sees only the 4 non-humus,
    // non-charcoal ones (`redist.f` 7900: `K.NE.4`; `M.LE.4` excludes charcoal).
    try std.testing.expectApproxEqAbs(@as(f64, 10), try state.totalCarbon_g_c(0), 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 4), try surfaceResidueCarbonG(&state, 1, 0), 1e-14);
}

test "ORGR splitting changes the erosion properties it feeds" {
    // Falsifiability companion: proves the residue split is not a no-op, and
    // that its direction matches `hour1.f:2955--2956` and `2988`. CORGM is held
    // fixed at 0.10 and only the residue share of it varies.
    const parameters: erosion.SurfacePropertyParameters = .{
        .reference_water_viscosity_megagrams_per_m_s = 1.0e-3,
        .viscosity_temperature_intercept = 0.533,
        .viscosity_temperature_coefficient_per_c = 0.0267,
    };
    const base: erosion.SurfacePropertyInputs = .{ .sand_mass_fraction = 0.6, .silt_mass_fraction = 0.25, .clay_mass_fraction = 0.15, .humus_mass_fraction = 0.10, .residue_mass_fraction = 0, .root_length_density_m_per_m3 = 0, .surface_temperature_c = 20 };
    var split = base;
    split.humus_mass_fraction = 0.06;
    split.residue_mass_fraction = 0.04;
    const a = try erosion.deriveSurfaceProperties(base, parameters);
    const b = try erosion.deriveSurfaceProperties(split, parameters);
    // D50 gains 90*CORRM when the residue share is named (10 um -> 100 um).
    try std.testing.expectApproxEqAbs(90 * 0.04, b.mean_particle_diameter_um - a.mean_particle_diameter_um, 1e-12);
    // DETS loses 2.5e-6*CORRM.
    try std.testing.expectApproxEqAbs(-2.5e-6 * 0.04, b.rainfall_detachability_g_per_j - a.rainfall_detachability_g_per_j, 1e-18);
    // Cohesion and particle density depend only on the sum, so they must not move.
    try std.testing.expectEqual(a.runoff_detachability, b.runoff_detachability);
    try std.testing.expectEqual(a.particle_density_megagrams_per_m3, b.particle_density_megagrams_per_m3);
}

test "external organic sediment export counts C N P without colonized double count" {
    var state = try organic.State.init(std.testing.allocator, 1);
    defer state.deinit();
    const count = try componentCount(&state);
    var workspace = try constituents.PackedWorkspace.init(
        std.testing.allocator,
        1,
        count,
    );
    defer workspace.deinit();
    state.microbial[0] = .{
        .carbon_g_c = 10,
        .nitrogen_g_n = 20,
        .phosphorus_g_p = 30,
    };
    state.adsorbed_acetate_carbon_g_c[0] = 40;
    state.structural[0] = .{
        .carbon_g_c = 50,
        .nitrogen_g_n = 60,
        .phosphorus_g_p = 70,
    };
    state.colonized_structural_carbon_g_c[0] = 80;
    var erosion_carbon_change = [_]f64{0};
    try route(1, 1, 1, &.{10}, &state, .{
        .east_megagrams = &.{1},
        .west_megagrams = &.{0},
        .south_megagrams = &.{0},
        .north_megagrams = &.{0},
    }, &workspace, &erosion_carbon_change);
    const exported = try exportedElements(&state, &workspace);
    try std.testing.expectApproxEqAbs(@as(f64, 10), exported.carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 8), exported.nitrogen_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 10), exported.phosphorus_g_p, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -10), erosion_carbon_change[0], 1e-12);
}
