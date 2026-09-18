// **A8a DISPOSITION: SUPERSEDED BY THE BOUND DLYRM TOPOLOGY OWNER; HOLD-1
// IS CLOSED.** `transport/hydrology.SoilFaces.mappedDestination` reproduces
// the source's vertical `LL=N6..NL` scan by promoting a +z slot to the first
// deeper layer whose live thickness is strictly greater than DLYRM. Horizontal
// slots require both same-depth endpoints to pass the same strict gate.
//
// **HISTORICAL A8a DISPOSITION: HOLD-1, do not bind and do not mark superseded.**
// Source: `trnsfrs.f` 9036--9045. Named member of HOLD-1, the `DLYRM` thin-layer gate, in
// docs/traceability/a4e_trnsfrs_unbound_dispositions.md. Production has no
// thickness predicate: `transport_hydrology.buildSoilFacesMapped`
// (`hydrology.zig:228`) enumerates faces from `active_soil_layer_count` alone,
// and `face_parameters.zig:117` then rejects a zero-bulk-volume layer with
// `InvalidSoilSoluteLayerState`, the open Arctic Fen blocker. The condition this
// module implements is therefore genuinely absent from production. The likely fix
// is the face builder's predicate rather than binding this kernel, but that is
// undecided, so this is a HOLD and not a supersession.
// Group HOLD-1 of docs/traceability/transport_unbound_family_was_already_dispositioned_elsewhere.md
const std = @import("std");

pub const Direction = enum { east_west, north_south, vertical };

pub const Resolution = struct {
    apply_pore_flux: bool,
    neighbor_layer_fortran: usize,
};

pub const Inputs = struct {
    /// NCN at the current grid cell. The source skips nonvertical direction
    /// when this value is exactly three.
    cell_connection_code: i32,
    direction: Direction,
    initial_neighbor_layer_fortran: usize,
    /// Neighbor layer thicknesses, Zig index zero corresponding to Fortran 1.
    neighbor_layer_thickness_m: []const f64,
    minimum_layer_thickness_m: f64,
};

/// Compatibility translation of TRNSFRS.F lines 9036--9045.
/// For vertical flow, N6 becomes the first LL in the inclusive source range
/// `N6..NL` for which neighbor DLYR exceeds DLYRM. If none qualifies, the
/// incoming N6 is retained exactly as in the Fortran loop.
pub fn resolve(inputs: Inputs) !Resolution {
    if (inputs.cell_connection_code == 3 and inputs.direction != .vertical) {
        return .{
            .apply_pore_flux = false,
            .neighbor_layer_fortran = inputs.initial_neighbor_layer_fortran,
        };
    }
    if (inputs.direction != .vertical) {
        return .{
            .apply_pore_flux = true,
            .neighbor_layer_fortran = inputs.initial_neighbor_layer_fortran,
        };
    }

    try validate(inputs);
    const first_index = inputs.initial_neighbor_layer_fortran - 1;
    for (inputs.neighbor_layer_thickness_m[first_index..], first_index..) |thickness_m, layer_index| {
        if (thickness_m > inputs.minimum_layer_thickness_m) {
            return .{ .apply_pore_flux = true, .neighbor_layer_fortran = layer_index + 1 };
        }
    }
    return .{
        .apply_pore_flux = true,
        .neighbor_layer_fortran = inputs.initial_neighbor_layer_fortran,
    };
}

fn validate(inputs: Inputs) !void {
    if (inputs.neighbor_layer_thickness_m.len == 0 or
        inputs.initial_neighbor_layer_fortran == 0 or
        inputs.initial_neighbor_layer_fortran > inputs.neighbor_layer_thickness_m.len)
        return error.PoreFluxNeighborLayerDimensionMismatch;
    if (!std.math.isFinite(inputs.minimum_layer_thickness_m))
        return error.NonFinitePoreFluxNeighborLayerInput;
    for (inputs.neighbor_layer_thickness_m) |thickness_m|
        if (!std.math.isFinite(thickness_m)) return error.NonFinitePoreFluxNeighborLayerInput;
}

test "TRNSFRS vertical flow selects first sufficiently thick neighbor layer" {
    const thickness_m = [_]f64{ 0.01, 0.02, 0.2, 0.3 };
    const result = try resolve(.{
        .cell_connection_code = 3,
        .direction = .vertical,
        .initial_neighbor_layer_fortran = 2,
        .neighbor_layer_thickness_m = &thickness_m,
        .minimum_layer_thickness_m = 0.1,
    });
    try std.testing.expect(result.apply_pore_flux);
    try std.testing.expectEqual(@as(usize, 3), result.neighbor_layer_fortran);
}

test "vertical scan is strict and retains N6 when no layer exceeds threshold" {
    const thickness_m = [_]f64{ 0.2, 0.1, 0.05 };
    const result = try resolve(.{
        .cell_connection_code = 1,
        .direction = .vertical,
        .initial_neighbor_layer_fortran = 2,
        .neighbor_layer_thickness_m = &thickness_m,
        .minimum_layer_thickness_m = 0.1,
    });
    try std.testing.expect(result.apply_pore_flux);
    try std.testing.expectEqual(@as(usize, 2), result.neighbor_layer_fortran);
}

test "horizontal flow retains N6 without scanning" {
    const thickness_m = [_]f64{};
    const result = try resolve(.{
        .cell_connection_code = 2,
        .direction = .north_south,
        .initial_neighbor_layer_fortran = 7,
        .neighbor_layer_thickness_m = &thickness_m,
        .minimum_layer_thickness_m = 0.1,
    });
    try std.testing.expect(result.apply_pore_flux);
    try std.testing.expectEqual(@as(usize, 7), result.neighbor_layer_fortran);
}

test "connection code three skips nonvertical pore flux" {
    const thickness_m = [_]f64{};
    const result = try resolve(.{
        .cell_connection_code = 3,
        .direction = .east_west,
        .initial_neighbor_layer_fortran = 9,
        .neighbor_layer_thickness_m = &thickness_m,
        .minimum_layer_thickness_m = 0.1,
    });
    try std.testing.expect(!result.apply_pore_flux);
    try std.testing.expectEqual(@as(usize, 9), result.neighbor_layer_fortran);
}

test "invalid runtime layer and nonfinite thickness fail immediately" {
    const thickness_m = [_]f64{0.2};
    try std.testing.expectError(error.PoreFluxNeighborLayerDimensionMismatch, resolve(.{
        .cell_connection_code = 1,
        .direction = .vertical,
        .initial_neighbor_layer_fortran = 0,
        .neighbor_layer_thickness_m = &thickness_m,
        .minimum_layer_thickness_m = 0.1,
    }));
    const invalid_thickness_m = [_]f64{std.math.nan(f64)};
    try std.testing.expectError(error.NonFinitePoreFluxNeighborLayerInput, resolve(.{
        .cell_connection_code = 1,
        .direction = .vertical,
        .initial_neighbor_layer_fortran = 1,
        .neighbor_layer_thickness_m = &invalid_thickness_m,
        .minimum_layer_thickness_m = 0.1,
    }));
}
