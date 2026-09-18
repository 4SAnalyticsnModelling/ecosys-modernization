// **A8a DISPOSITION: superseded.** `snow_solute_transport.State.initializePhysicalState`
// (`soil/solute/snow_solute_transport.zig:76--112`, called once from
// `ecosys_ng.zig:2635`) is production's owner of `starts.f:602--641`, and it
// carries the whole layer loop.
//
// Line for line: `DENS0=0.05` at `:603` is `runscript.initial_snow_density_megagrams_per_m3`,
// passed as the fifth argument and stored per layer at `:107`; the
// `AMIN1(DLYRSI, AMAX1(0, DPTHS-CDPTHSI(L-1)))` thickness of `:613--617`, which
// fills each nominal layer in turn and leaves the rest empty, is `:91--93`
// (`@min(nominal, @max(0, depth - top))`, with `top` taken from the previous
// nominal bottom exactly as `CDPTHSI(L-1)`); `VOLSSL = DLYRS*DENS0*DH*DV` at
// `:619--620` is `:94`; the three zeroed phases at `:621--623` are `:98--100`;
// `DENSS(L)=DENS0` at `:632` is `:107`; `VOLSL = VOLSSL/DENSS + VOLWSL + VOLISL`
// at `:633--634` is `:95` and `:101`, which reduces to `solid/density` because
// the other two are the zeros just assigned; `VOLSI = DLYRSI*DH*DV` at `:635` is
// `target_layer_volume_m3` at `:102`; `CDPTHS(L)=CDPTHS(L-1)+DLYRS(L)` at `:636`
// with the `CDPTHS(0)=0` seed of `:602` is the running `cumulative` at
// `:104--105`; `TKW=AMIN1(273.15, ATKA)` at `:637` is `:108`, fed
// `site.mean_annual_air_temperature_c + 273.15` at `ecosys_ng.zig:2632--2634`;
// and `VHCPW = 2.095*VOLSSL + 4.19*VOLWSL + 1.9274*VOLISL` at `:639--640` is
// `:109`, written as `2.095 * solid` because the other two terms multiply the
// zeros. Production additionally sets `active` from `thickness > 0`, which is the
// runtime encoding of legacy's "layers past `DPTHS` get zero volume".
//
// The four quantities this module publishes that the owner does not are each
// owned elsewhere or are dead in source:
//
//   - `TCW` at `:638` is not stored. Production keeps only `temperature_k` and
//     reconstructs Celsius where it is needed, e.g. `snow_compaction.zig:54`.
//   - `VOLSS/VOLWS/VOLIS/VOLS` at `:604--607` are the column totals, and
//     production accumulates them at consumption rather than storing them:
//     `hourly_science_snow_energy.zig:125--128` sums the per-layer solid water
//     equivalent into `surface_precipitation.solid_snow_water_equivalent_m3` and
//     `:124` republishes `snow_depth_m` from the deepest cumulative depth. This
//     is the same distribution-by-consumer already recorded for
//     `snowpack_geometry_temperature_update`.
//   - `DPTHA=9999.0` at `:608` is the active-layer depth sentinel, and its owner
//     is `soil/profile/boundary_topology.zig:143`, which assigns the identical
//     `9999` and then overwrites it at `:161` from the ice fraction. It is a soil
//     permafrost quantity that happens to be seeded in the snow block, so the
//     split is by subject, not by cadence.
//   - `midpoint_water_equivalent_m3` translates `VOLSWI` (`:609`, `:625--630`).
//     **In `starts.f` that accumulator is dead**: it is zeroed, accumulated
//     across the loop, and never read again in the file. It is live in
//     `redist.f`, where the same accumulation at `:3965`/`:4000`/`:4013` feeds
//     the compaction overburden at `:4044`, and production's owner of *that* is
//     `snow_compaction.zig:45--46`, which rebuilds the half-layer sum locally
//     each step instead of carrying it in state. So initializing it would seed a
//     field with no reader.
//
// Binding this module would therefore make a second writer of every layer field
// the owner already establishes, at the same point in startup, with the further
// hazard that its `Parameters` accept the three heat-capacity coefficients as
// arguments while the owner hard-codes `2.095`, `4.19`, `1.9274` to match source:
// a caller could silently pass different ones. There is no gap to file here.
//
// snowpack initialization group of docs/traceability/a1b_snowpack_minimum_heat_capacity_unbound.md

const std = @import("std");

pub const Inputs = struct {
    snow_depth_m: []const f64,
    horizontal_cell_width_m: []const f64,
    vertical_cell_width_m: []const f64,
    mean_annual_air_temperature_k: []const f64,
    mean_annual_air_temperature_c: []const f64,
    nominal_layer_bottom_depth_m: []const f64,
};

pub const Parameters = struct {
    initial_snow_density_megagrams_per_m3: f64,
    ice_density_megagrams_per_m3: f64,
    solid_snow_heat_capacity_megajoules_per_m3_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    freezing_temperature_k: f64,
    freezing_temperature_c: f64,
    inactive_layer_depth_m: f64,
};

pub const CellState = struct {
    surface_boundary_depth_m: []f64,
    initial_snow_density_megagrams_per_m3: []f64,
    solid_snow_water_equivalent_m3: []f64,
    liquid_water_m3: []f64,
    ice_m3: []f64,
    total_snowpack_volume_m3: []f64,
    active_layer_depth_m: []f64,
    midpoint_water_equivalent_m3: []f64,
};

pub const LayerState = struct {
    layer_thickness_m: []f64,
    solid_snow_water_equivalent_m3: []f64,
    liquid_water_m3: []f64,
    vapor_water_equivalent_m3: []f64,
    ice_m3: []f64,
    snow_density_megagrams_per_m3: []f64,
    total_layer_volume_m3: []f64,
    target_layer_volume_m3: []f64,
    cumulative_depth_m: []f64,
    temperature_k: []f64,
    temperature_c: []f64,
    heat_capacity_megajoules_per_k: []f64,
};

pub const State = struct {
    cells: CellState,
    layers: LayerState,
};

fn validateSlices(value: anytype, expected: usize) bool {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
        if (@field(value, field.name).len != expected) return false;
    }
    return true;
}

/// Exact source-order translation of legacy `STARTS` lines 602--641.
pub fn initialize(
    state: State,
    inputs: Inputs,
    parameters: Parameters,
) !void {
    const cell_count = inputs.snow_depth_m.len;
    const layer_count = inputs.nominal_layer_bottom_depth_m.len;
    if (cell_count == 0 or layer_count == 0)
        return error.InvalidSnowpackInitialDimensions;
    if (inputs.horizontal_cell_width_m.len != cell_count or
        inputs.vertical_cell_width_m.len != cell_count or
        inputs.mean_annual_air_temperature_k.len != cell_count or
        inputs.mean_annual_air_temperature_c.len != cell_count or
        !validateSlices(state.cells, cell_count))
        return error.SnowpackInitialDimensionMismatch;
    const layer_cell_count = std.math.mul(
        usize,
        cell_count,
        layer_count,
    ) catch return error.DimensionOverflow;
    if (!validateSlices(state.layers, layer_cell_count))
        return error.SnowpackInitialDimensionMismatch;
    inline for (@typeInfo(Parameters).@"struct".fields) |field| {
        const value = @field(parameters, field.name);
        if (!std.math.isFinite(value))
            return error.NonFiniteSnowpackInitialParameter;
    }
    if (parameters.initial_snow_density_megagrams_per_m3 <= 0 or
        parameters.ice_density_megagrams_per_m3 <= 0 or
        parameters.solid_snow_heat_capacity_megajoules_per_m3_k <= 0 or
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or
        parameters.ice_heat_capacity_megajoules_per_m3_k <= 0 or
        parameters.freezing_temperature_k <= 0 or
        parameters.inactive_layer_depth_m <= 0)
        return error.InvalidSnowpackInitialParameter;
    var previous_bottom_m: f64 = 0.0;
    for (inputs.nominal_layer_bottom_depth_m) |bottom_m| {
        if (!std.math.isFinite(bottom_m))
            return error.NonFiniteSnowpackInitialInput;
        if (bottom_m <= previous_bottom_m)
            return error.InvalidSnowLayerBoundary;
        previous_bottom_m = bottom_m;
    }

    for (0..cell_count) |cell| {
        inline for (.{
            inputs.snow_depth_m[cell],
            inputs.horizontal_cell_width_m[cell],
            inputs.vertical_cell_width_m[cell],
            inputs.mean_annual_air_temperature_k[cell],
            inputs.mean_annual_air_temperature_c[cell],
        }) |value| if (!std.math.isFinite(value))
            return error.NonFiniteSnowpackInitialInput;
        if (inputs.snow_depth_m[cell] < 0 or
            inputs.horizontal_cell_width_m[cell] <= 0 or
            inputs.vertical_cell_width_m[cell] <= 0 or
            inputs.mean_annual_air_temperature_k[cell] <= 0)
            return error.InvalidSnowpackInitialInput;
        const area_m2 = inputs.horizontal_cell_width_m[cell] *
            inputs.vertical_cell_width_m[cell];
        const cell_solid_m3 = inputs.snow_depth_m[cell] *
            parameters.initial_snow_density_megagrams_per_m3 * area_m2;
        inline for (.{ area_m2, cell_solid_m3, cell_solid_m3 /
            parameters.initial_snow_density_megagrams_per_m3 }) |candidate|
            if (!std.math.isFinite(candidate))
                return error.SnowpackInitialOverflow;
        var previous_nominal_bottom_m: f64 = 0.0;
        for (0..layer_count) |layer| {
            const nominal_bottom_m =
                inputs.nominal_layer_bottom_depth_m[layer];
            const nominal_thickness_m =
                nominal_bottom_m - previous_nominal_bottom_m;
            const thickness_m = @min(
                nominal_thickness_m,
                @max(0.0, inputs.snow_depth_m[cell] -
                    previous_nominal_bottom_m),
            );
            const solid_m3 = thickness_m *
                parameters.initial_snow_density_megagrams_per_m3 * area_m2;
            inline for (.{
                nominal_thickness_m,
                thickness_m,
                solid_m3,
                solid_m3 / parameters.initial_snow_density_megagrams_per_m3,
                nominal_thickness_m * area_m2,
                parameters.solid_snow_heat_capacity_megajoules_per_m3_k * solid_m3,
            }) |candidate| if (!std.math.isFinite(candidate))
                return error.SnowpackInitialOverflow;
            previous_nominal_bottom_m = nominal_bottom_m;
        }
    }

    for (0..cell_count) |cell| {
        const area_m2 = inputs.horizontal_cell_width_m[cell] *
            inputs.vertical_cell_width_m[cell];
        state.cells.surface_boundary_depth_m[cell] = 0.0;
        state.cells.initial_snow_density_megagrams_per_m3[cell] =
            parameters.initial_snow_density_megagrams_per_m3;
        state.cells.solid_snow_water_equivalent_m3[cell] =
            inputs.snow_depth_m[cell] *
            parameters.initial_snow_density_megagrams_per_m3 * area_m2;
        state.cells.liquid_water_m3[cell] = 0.0;
        state.cells.ice_m3[cell] = 0.0;
        state.cells.total_snowpack_volume_m3[cell] =
            state.cells.solid_snow_water_equivalent_m3[cell] /
            parameters.initial_snow_density_megagrams_per_m3 +
            state.cells.liquid_water_m3[cell] + state.cells.ice_m3[cell];
        state.cells.active_layer_depth_m[cell] =
            parameters.inactive_layer_depth_m;
        state.cells.midpoint_water_equivalent_m3[cell] = 0.0;

        var previous_nominal_bottom_m: f64 = 0.0;
        for (0..layer_count) |layer| {
            const index = cell * layer_count + layer;
            const nominal_bottom_m =
                inputs.nominal_layer_bottom_depth_m[layer];
            const nominal_thickness_m =
                nominal_bottom_m - previous_nominal_bottom_m;
            state.layers.layer_thickness_m[index] = @min(
                nominal_thickness_m,
                @max(0.0, inputs.snow_depth_m[cell] -
                    previous_nominal_bottom_m),
            );
            state.layers.solid_snow_water_equivalent_m3[index] =
                state.layers.layer_thickness_m[index] *
                parameters.initial_snow_density_megagrams_per_m3 * area_m2;
            state.layers.liquid_water_m3[index] = 0.0;
            state.layers.vapor_water_equivalent_m3[index] = 0.0;
            state.layers.ice_m3[index] = 0.0;
            const current_equivalent =
                state.layers.solid_snow_water_equivalent_m3[index] +
                state.layers.liquid_water_m3[index] +
                state.layers.ice_m3[index] *
                    parameters.ice_density_megagrams_per_m3;
            if (layer == 0) {
                state.cells.midpoint_water_equivalent_m3[cell] +=
                    0.5 * current_equivalent;
            } else {
                const previous = index - 1;
                state.cells.midpoint_water_equivalent_m3[cell] += 0.5 *
                    (state.layers.solid_snow_water_equivalent_m3[previous] +
                        state.layers.liquid_water_m3[previous] +
                        state.layers.ice_m3[previous] *
                            parameters.ice_density_megagrams_per_m3 +
                        current_equivalent);
            }
            state.layers.snow_density_megagrams_per_m3[index] =
                parameters.initial_snow_density_megagrams_per_m3;
            state.layers.total_layer_volume_m3[index] =
                state.layers.solid_snow_water_equivalent_m3[index] /
                state.layers.snow_density_megagrams_per_m3[index] +
                state.layers.liquid_water_m3[index] +
                state.layers.ice_m3[index];
            state.layers.target_layer_volume_m3[index] =
                nominal_thickness_m * area_m2;
            state.layers.cumulative_depth_m[index] =
                (if (layer == 0)
                    0.0
                else
                    state.layers.cumulative_depth_m[index - 1]) +
                state.layers.layer_thickness_m[index];
            state.layers.temperature_k[index] = @min(
                parameters.freezing_temperature_k,
                inputs.mean_annual_air_temperature_k[cell],
            );
            state.layers.temperature_c[index] = @min(
                parameters.freezing_temperature_c,
                inputs.mean_annual_air_temperature_c[cell],
            );
            state.layers.heat_capacity_megajoules_per_k[index] =
                parameters.solid_snow_heat_capacity_megajoules_per_m3_k *
                state.layers.solid_snow_water_equivalent_m3[index] +
                parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
                    state.layers.liquid_water_m3[index] +
                parameters.ice_heat_capacity_megajoules_per_m3_k *
                    state.layers.ice_m3[index];
            previous_nominal_bottom_m = nominal_bottom_m;
        }
    }
}

fn allocSlices(comptime T: type, allocator: std.mem.Allocator, count: usize) !T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        @field(result, field.name) = try allocator.alloc(f64, count);
        @memset(@field(result, field.name), 7);
    }
    return result;
}

fn freeSlices(value: anytype, allocator: std.mem.Allocator) void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field|
        allocator.free(@field(value, field.name));
}

test "STARTS snowpack initializes totals layers midpoint water and heat" {
    const allocator = std.testing.allocator;
    const cells = try allocSlices(CellState, allocator, 1);
    defer freeSlices(cells, allocator);
    const layers = try allocSlices(LayerState, allocator, 3);
    defer freeSlices(layers, allocator);
    try initialize(.{ .cells = cells, .layers = layers }, .{
        .snow_depth_m = &.{0.2},
        .horizontal_cell_width_m = &.{10},
        .vertical_cell_width_m = &.{20},
        .mean_annual_air_temperature_k = &.{268.15},
        .mean_annual_air_temperature_c = &.{-5},
        .nominal_layer_bottom_depth_m = &.{ 0.05, 0.125, 0.25 },
    }, .{
        .initial_snow_density_megagrams_per_m3 = 0.05,
        .ice_density_megagrams_per_m3 = 0.92,
        .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
        .freezing_temperature_k = 273.15,
        .freezing_temperature_c = 0,
        .inactive_layer_depth_m = 9999,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 2), cells.solid_snow_water_equivalent_m3[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), layers.layer_thickness_m[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.075), layers.layer_thickness_m[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.075), layers.layer_thickness_m[2], 1e-15);
    try std.testing.expectEqual(@as(f64, 268.15), layers.temperature_k[0]);
    try std.testing.expectEqual(@as(f64, -5), layers.temperature_c[0]);
    try std.testing.expect(layers.heat_capacity_megajoules_per_k[0] > 0);
    try std.testing.expect(cells.midpoint_water_equivalent_m3[0] > 0);
}

test "runtime snow layer count is not fixed to five" {
    const allocator = std.testing.allocator;
    const cells = try allocSlices(CellState, allocator, 1);
    defer freeSlices(cells, allocator);
    const layers = try allocSlices(LayerState, allocator, 2);
    defer freeSlices(layers, allocator);
    try initialize(.{ .cells = cells, .layers = layers }, .{
        .snow_depth_m = &.{0},
        .horizontal_cell_width_m = &.{1},
        .vertical_cell_width_m = &.{1},
        .mean_annual_air_temperature_k = &.{280},
        .mean_annual_air_temperature_c = &.{7},
        .nominal_layer_bottom_depth_m = &.{ 0.1, 0.3 },
    }, .{
        .initial_snow_density_megagrams_per_m3 = 0.1,
        .ice_density_megagrams_per_m3 = 0.92,
        .solid_snow_heat_capacity_megajoules_per_m3_k = 2,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4,
        .ice_heat_capacity_megajoules_per_m3_k = 2,
        .freezing_temperature_k = 273.15,
        .freezing_temperature_c = 0,
        .inactive_layer_depth_m = 9999,
    });
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, layers.layer_thickness_m);
    for (layers.target_layer_volume_m3, [_]f64{ 0.1, 0.2 }) |
        actual,
        expected,
    | try std.testing.expectApproxEqAbs(expected, actual, 1e-15);
}
