const std = @import("std");
const grid_module = @import("../../state/grid.zig");
const hydrology_module = @import("../../transport/hydrology.zig");
const geometry_module = @import("../water/face_geometry.zig");
const species_module = @import("transport_species.zig");

const Species = species_module.AqueousSpecies;

pub const RuntimeParameters = struct {
    reference_temperature_k: f64 = 298.15,
    temperature_exponent: f64 = 6,
    phosphate_diffusivity_m2_per_h: f64 = 3.0e-6,
    other_ion_diffusivity_m2_per_h: f64 = 5.0e-6,
    micropore_tortuosity_coefficient: f64 = 0.7,
    macropore_tortuosity_coefficient: f64 = 2.8,
    dispersivity_coefficient: f64 = 0.20,
    dispersivity_distance_exponent: f64 = 1.07,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    micropore_conductance_m3_per_step: []f64,
    macropore_conductance_m3_per_step: []f64,
    micropore_mobility_fraction: []f64,
    macropore_mobility_fraction: []f64,
    boundary_mobility_fraction: []f64,

    pub fn init(allocator: std.mem.Allocator, face_count: usize) !State {
        const count = try std.math.mul(usize, face_count, Species.count);
        const micro = try allocator.alloc(f64, count);
        errdefer allocator.free(micro);
        const macro = try allocator.alloc(f64, count);
        errdefer allocator.free(macro);
        const micro_mobile = try allocator.alloc(f64, count);
        errdefer allocator.free(micro_mobile);
        const macro_mobile = try allocator.alloc(f64, count);
        errdefer allocator.free(macro_mobile);
        const boundary_mobile = try allocator.alloc(f64, Species.count);
        errdefer allocator.free(boundary_mobile);
        @memset(micro, 0);
        @memset(macro, 0);
        @memset(micro_mobile, 1);
        @memset(macro_mobile, 1);
        @memset(boundary_mobile, 1);
        return .{ .allocator = allocator, .micropore_conductance_m3_per_step = micro, .macropore_conductance_m3_per_step = macro, .micropore_mobility_fraction = micro_mobile, .macropore_mobility_fraction = macro_mobile, .boundary_mobility_fraction = boundary_mobile };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.boundary_mobility_fraction);
        self.allocator.free(self.macropore_mobility_fraction);
        self.allocator.free(self.micropore_mobility_fraction);
        self.allocator.free(self.macropore_conductance_m3_per_step);
        self.allocator.free(self.micropore_conductance_m3_per_step);
        self.* = undefined;
    }

    /// Reconstructs HOUR1/WATSUB/STARTS/TRNSFRS face coefficients from the
    /// current runtime water state. `step_hours` is physical time, not a fixed
    /// sub-hour loop fraction; nonlinear iterations converge this one step.
    pub fn refresh(self: *State, grid: *const grid_module.GridState, faces: *const hydrology_module.SoilFaces, geometry: *const geometry_module.State, matrix_bulk_volume_m3: []const f64, bulk_density_megagrams_per_m3: []const f64, step_hours: f64, parameters: RuntimeParameters) !void {
        try validate(grid, faces, geometry, matrix_bulk_volume_m3, bulk_density_megagrams_per_m3, step_hours, parameters, self.micropore_conductance_m3_per_step.len);
        @memset(self.boundary_mobility_fraction, 1);
        for (faces.micropore_faces, 0..) |face, face_index| {
            if (!faces.active_by_face[face_index]) {
                const first = face_index * Species.count;
                @memset(self.micropore_conductance_m3_per_step[first..][0..Species.count], 0);
                @memset(self.macropore_conductance_m3_per_step[first..][0..Species.count], 0);
                @memset(self.micropore_mobility_fraction[first..][0..Species.count], 0);
                @memset(self.macropore_mobility_fraction[first..][0..Species.count], 0);
                continue;
            }
            const source = face.first_cell;
            const destination = face.second_cell;
            const path_sum_m = geometry.source_path_length_m[face_index] + geometry.destination_path_length_m[face_index];
            const mean_distance_m = 0.5 * path_sum_m;
            const area_m2 = geometry.face_area_m2[face_index];
            const source_macro_fraction = macroporeFraction(grid, source);
            const destination_macro_fraction = macroporeFraction(grid, destination);
            const source_matrix_theta = if (matrix_bulk_volume_m3[source] > 0) std.math.clamp(grid.matrix_liquid_water_m3[source] / matrix_bulk_volume_m3[source], 0, 1) else 0;
            const destination_matrix_theta = if (matrix_bulk_volume_m3[destination] > 0) std.math.clamp(grid.matrix_liquid_water_m3[destination] / matrix_bulk_volume_m3[destination], 0, 1) else 0;
            // watsub.f:1122-1128 (`IF(BKDS.GT.ZERO.AND.VOLY.GT.ZEROS) ... ELSE TORT=0.7`):
            // a zero matrix pore volume OR a zero bulk density (SOLUTE-TORT-BKDS-001:
            // the compound condition's other half) falls back to a flat,
            // theta-independent tortuosity of 0.7, not to zero. Only the numerator's
            // theta-squared term is undefined at zero volume/density; the flat legacy
            // constant must still apply so the micropore diffusive pathway stays open.
            const source_micro_matrix_active = matrix_bulk_volume_m3[source] > 0 and bulk_density_megagrams_per_m3[source] > 0;
            const destination_micro_matrix_active = matrix_bulk_volume_m3[destination] > 0 and bulk_density_megagrams_per_m3[destination] > 0;
            const source_micro_tortuosity = if (source_micro_matrix_active) parameters.micropore_tortuosity_coefficient * source_matrix_theta * source_matrix_theta * (1 - source_macro_fraction) else parameters.micropore_tortuosity_coefficient;
            const destination_micro_tortuosity = if (destination_micro_matrix_active) parameters.micropore_tortuosity_coefficient * destination_matrix_theta * destination_matrix_theta * (1 - destination_macro_fraction) else parameters.micropore_tortuosity_coefficient;
            const source_macro_theta = if (grid.macropore_pore_capacity_m3[source] > 0) std.math.clamp(grid.macropore_liquid_water_m3[source] / grid.macropore_pore_capacity_m3[source], 0, 1) else 0;
            const destination_macro_theta = if (grid.macropore_pore_capacity_m3[destination] > 0) std.math.clamp(grid.macropore_liquid_water_m3[destination] / grid.macropore_pore_capacity_m3[destination], 0, 1) else 0;
            const source_macro_tortuosity = @min(1.0, parameters.macropore_tortuosity_coefficient * source_macro_theta * source_macro_theta * source_macro_theta) * source_macro_fraction;
            const destination_macro_tortuosity = @min(1.0, parameters.macropore_tortuosity_coefficient * destination_macro_theta * destination_macro_theta * destination_macro_theta) * destination_macro_fraction;
            const micro_tortuosity_per_m = (source_micro_tortuosity + destination_micro_tortuosity) / path_sum_m;
            const macro_tortuosity_per_m = (source_macro_tortuosity + destination_macro_tortuosity) / path_sum_m;
            const water_velocity_m_per_step = @abs(faces.micropore_water_flux_m3_per_step[face_index]) / area_m2;
            const dispersivity_m2_per_step = parameters.dispersivity_coefficient * std.math.pow(f64, mean_distance_m, parameters.dispersivity_distance_exponent) * step_hours * @min(step_hours, water_velocity_m_per_step);
            const temperature_factor = std.math.pow(f64, grid.soil_temperature_k[destination] / parameters.reference_temperature_k, parameters.temperature_exponent);
            inline for (@typeInfo(Species).@"enum".fields) |field| {
                const species: Species = @enumFromInt(field.value);
                const component = face_index * Species.count + field.value;
                const reference_diffusivity = if (species_module.diffusivityClass(species) == .phosphate) parameters.phosphate_diffusivity_m2_per_h else parameters.other_ion_diffusivity_m2_per_h;
                const diffusivity_m2_per_step = reference_diffusivity * temperature_factor * step_hours;
                self.micropore_conductance_m3_per_step[component] = (diffusivity_m2_per_step * micro_tortuosity_per_m + dispersivity_m2_per_step) * area_m2;
                self.macropore_conductance_m3_per_step[component] = diffusivity_m2_per_step * macro_tortuosity_per_m * area_m2;
                self.micropore_mobility_fraction[component] = 1;
                self.macropore_mobility_fraction[component] = self.micropore_mobility_fraction[component];
            }
        }
    }
};

fn macroporeFraction(grid: *const grid_module.GridState, cell: usize) f64 {
    const total = grid.matrix_pore_capacity_m3[cell] + grid.macropore_pore_capacity_m3[cell];
    return if (total > 0) std.math.clamp(grid.macropore_pore_capacity_m3[cell] / total, 0, 1) else 0;
}

fn validate(grid: *const grid_module.GridState, faces: *const hydrology_module.SoilFaces, geometry: *const geometry_module.State, bulk: []const f64, bulk_density: []const f64, step: f64, p: RuntimeParameters, output_len: usize) !void {
    if (bulk.len != grid.layer_count or bulk_density.len != grid.layer_count or faces.micropore_faces.len != geometry.face_area_m2.len or faces.active_by_face.len != faces.micropore_faces.len or output_len != faces.micropore_faces.len * Species.count) return error.SoilSoluteFaceDimensionMismatch;
    inline for (.{ step, p.reference_temperature_k, p.phosphate_diffusivity_m2_per_h, p.other_ion_diffusivity_m2_per_h, p.micropore_tortuosity_coefficient, p.macropore_tortuosity_coefficient, p.dispersivity_coefficient, p.dispersivity_distance_exponent }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilSoluteRuntimeParameter;
    if (step == 0 or p.reference_temperature_k == 0) return error.InvalidSoilSoluteRuntimeParameter;
    // Zero bulk volume or zero bulk density is allowed: relayering can fully
    // drain a layer's matrix volume into an adjacent layer while the layer
    // remains geometrically active (the real, observed Arctic Fen relayering
    // trigger), and a deck may declare an `initial_bulk_density_megagrams_per_m3
    // == 0` layer (e.g. a purely organic/void horizon). This mirrors
    // watsub.f:1122-1128's `IF(BKDS.GT.ZERO.AND.VOLY.GT.ZEROS)...ELSE TORT=0.7`:
    // such layers fall back to the flat micropore tortuosity coefficient
    // (see `refresh`'s `source_micro_tortuosity`/`destination_micro_tortuosity`),
    // not to zero conductance. A non-finite or negative volume/density, or a
    // non-positive or non-finite temperature, remain hard errors.
    for (bulk, grid.soil_temperature_k) |volume, temperature| if (!std.math.isFinite(volume) or volume < 0 or !std.math.isFinite(temperature) or temperature <= 0) return error.InvalidSoilSoluteLayerState;
    for (bulk_density) |density| if (!std.math.isFinite(density) or density < 0) return error.InvalidSoilSoluteLayerState;
}

test "zero bulk volume layer falls back to the flat watsub.f TORT=0.7 tortuosity, not zero (Arctic Fen relayering)" {
    // relayering.zig can transfer fx=1.0 of a layer's matrix_bulk_volume_m3 into
    // an adjacent layer while the layer remains geometrically active. Validate
    // that face_parameters allows zero-bulk-volume entries (matching the Fortran
    // guard for VOLY<=0 at watsub.f:1122-1128) and reproduces the oracle's flat,
    // theta-independent TORT=0.7 fallback for the micropore term on that side,
    // rather than collapsing it to zero. This is distinct from -- and not to be
    // confused with -- the unrelated TRNSFRS DLYRM thin-layer flux-block gate
    // (`TRNSFRS-DLYRM-001`/`HOLD-1`), which this test does not exercise.
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 2);
    @memset(grid.matrix_liquid_water_m3, 0);
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.macropore_liquid_water_m3, 0);
    @memset(grid.macropore_pore_capacity_m3, 0);
    @memset(grid.soil_temperature_k, 298.15);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 2, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    // layer_thickness_m: 2 entries (grid.layer_count = cell_count * soil_layers = 1*2).
    // cell width arrays: 1 entry each (grid.cell_count = 1).
    var geometry = try geometry_module.State.initMapped(std.testing.allocator, &grid, &faces, &.{ 0.1, 0.1 }, &.{1}, &.{1});
    defer geometry.deinit();
    var state = try State.init(std.testing.allocator, faces.micropore_faces.len);
    defer state.deinit();
    // One cell, two layers: layer 0 has zero bulk volume (fully drained by relayering).
    const bulk = [_]f64{ 0, 1 };
    const bulk_density = [_]f64{ 1, 1 };
    try state.refresh(&grid, &faces, &geometry, &bulk, &bulk_density, 1, .{});
    const aluminum = species_module.index(.aluminum);
    // Layer 0 (bulk volume 0) contributes a flat 0.7; layer 1 (bulk volume 1,
    // matrix_liquid_water_m3=0, so theta=0) contributes 0.7*0^2*1=0. Averaged
    // over the shared +z path (0.1 m + 0.1 m) and multiplied by the aluminum
    // (other-ion) diffusivity of 5.0e-6 m2/h at the reference temperature over
    // a 1 m2 face and a 1-hour step: (5.0e-6 * (0.7/0.2)) * 1 = 1.75e-5.
    try std.testing.expectApproxEqAbs(@as(f64, 1.75e-5), state.micropore_conductance_m3_per_step[aluminum], 1e-12);
    // The macropore fallback is unaffected by this fix: watsub.f:1129-1133 sets
    // TORTH=0.0 when VOLAH1<=0, which is what zero macropore_pore_capacity_m3
    // already produces on both sides here.
    try std.testing.expectEqual(@as(f64, 0), state.macropore_conductance_m3_per_step[aluminum]);
}

test "negative bulk volume remains a hard error (SOLUTE-FEN-001 falsification)" {
    // Zero is allowed; negative is not. This falsification verifies the predicate
    // was tightened to < 0 (not removed entirely).
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 2);
    @memset(grid.matrix_liquid_water_m3, 0);
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.macropore_liquid_water_m3, 0);
    @memset(grid.macropore_pore_capacity_m3, 0);
    @memset(grid.soil_temperature_k, 298.15);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 2, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var geometry = try geometry_module.State.initMapped(std.testing.allocator, &grid, &faces, &.{ 0.1, 0.1 }, &.{1}, &.{1});
    defer geometry.deinit();
    var state = try State.init(std.testing.allocator, faces.micropore_faces.len);
    defer state.deinit();
    const bulk_negative = [_]f64{ -0.01, 1 };
    const bulk_density = [_]f64{ 1, 1 };
    try std.testing.expectError(error.InvalidSoilSoluteLayerState, state.refresh(&grid, &faces, &geometry, &bulk_negative, &bulk_density, 1, .{}));
}

test "zero bulk density layer falls back to the flat watsub.f TORT=0.7 tortuosity (SOLUTE-TORT-BKDS-001)" {
    // watsub.f:1122-1128's gate is a compound AND: BKDS(L,NY,NX).GT.ZERO
    // .AND. VOLY(L,NY,NX).GT.ZEROS(NY,NX). This exercises the BKDS half in
    // isolation: matrix_bulk_volume_m3 stays positive (a real pore volume)
    // while bulk_density_megagrams_per_m3 is exactly zero (an allowed deck
    // state for a purely organic/void horizon, see
    // state/soil_profile.zig's `value < 0` -- not `<= 0` -- validation).
    // The oracle still falls back to the flat TORT=0.7, not the theta^2
    // branch, because a matrix with no mass has no meaningful tortuosity.
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 2);
    @memset(grid.matrix_liquid_water_m3, 0);
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.macropore_liquid_water_m3, 0);
    @memset(grid.macropore_pore_capacity_m3, 0);
    @memset(grid.soil_temperature_k, 298.15);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 2, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var geometry = try geometry_module.State.initMapped(std.testing.allocator, &grid, &faces, &.{ 0.1, 0.1 }, &.{1}, &.{1});
    defer geometry.deinit();
    var state = try State.init(std.testing.allocator, faces.micropore_faces.len);
    defer state.deinit();
    // Layer 0: positive matrix_bulk_volume_m3 (real pore volume) but zero
    // bulk_density_megagrams_per_m3 (declared void/organic horizon). Layer 1:
    // fully populated matrix (bulk volume 1, bulk density 1, dry, theta=0).
    const bulk = [_]f64{ 1, 1 };
    const bulk_density = [_]f64{ 0, 1 };
    try state.refresh(&grid, &faces, &geometry, &bulk, &bulk_density, 1, .{});
    const aluminum = species_module.index(.aluminum);
    // Same expected magnitude as the zero-bulk-volume case: layer 0
    // contributes the flat 0.7 fallback (via the BKDS leg this time, not the
    // VOLY leg); layer 1 contributes 0.7*0^2*1=0. Averaged over the shared
    // +z path (0.1 m + 0.1 m) with the aluminum (other-ion) diffusivity of
    // 5.0e-6 m2/h at the reference temperature, 1 m2 face, 1-hour step:
    // (5.0e-6 * (0.7/0.2)) * 1 = 1.75e-5.
    try std.testing.expectApproxEqAbs(@as(f64, 1.75e-5), state.micropore_conductance_m3_per_step[aluminum], 1e-12);
}

test "negative bulk density remains a hard error (SOLUTE-TORT-BKDS-001 falsification)" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 2);
    @memset(grid.matrix_liquid_water_m3, 0);
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.macropore_liquid_water_m3, 0);
    @memset(grid.macropore_pore_capacity_m3, 0);
    @memset(grid.soil_temperature_k, 298.15);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 2, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var geometry = try geometry_module.State.initMapped(std.testing.allocator, &grid, &faces, &.{ 0.1, 0.1 }, &.{1}, &.{1});
    defer geometry.deinit();
    var state = try State.init(std.testing.allocator, faces.micropore_faces.len);
    defer state.deinit();
    const bulk = [_]f64{ 1, 1 };
    const bulk_density_negative = [_]f64{ -0.01, 1 };
    try std.testing.expectError(error.InvalidSoilSoluteLayerState, state.refresh(&grid, &faces, &geometry, &bulk, &bulk_density_negative, 1, .{}));
}

test "face assembler reproduces TRNSFRS micropore and macropore forms" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    @memset(grid.matrix_liquid_water_m3, 0.5);
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    @memset(grid.macropore_liquid_water_m3, 0.1);
    @memset(grid.macropore_pore_capacity_m3, 0.1);
    @memset(grid.soil_temperature_k, 298.15);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();
    hydrology.micropore_face_flux_m3_per_step[0] = 0.01;
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var geometry = try geometry_module.State.initMapped(std.testing.allocator, &grid, &faces, &.{ 1, 1 }, &.{ 1, 1 }, &.{ 1, 1 });
    defer geometry.deinit();
    var state = try State.init(std.testing.allocator, faces.micropore_faces.len);
    defer state.deinit();
    try state.refresh(&grid, &faces, &geometry, &.{ 1, 1 }, &.{ 1, 1 }, 1, .{});
    const aluminum = species_module.index(.aluminum);
    const phosphate = species_module.index(.non_band_phosphate);
    try std.testing.expect(state.micropore_conductance_m3_per_step[aluminum] > state.micropore_conductance_m3_per_step[phosphate]);
    try std.testing.expect(state.macropore_conductance_m3_per_step[aluminum] > 0);
    try std.testing.expectEqual(@as(f64, 1), state.micropore_mobility_fraction[phosphate]);
    @memset(state.micropore_conductance_m3_per_step, 7);
    @memset(state.macropore_conductance_m3_per_step, 7);
    @memset(state.micropore_mobility_fraction, 1);
    @memset(state.macropore_mobility_fraction, 1);
    faces.active_by_face[0] = false;
    try state.refresh(&grid, &faces, &geometry, &.{ 1, 1 }, &.{ 1, 1 }, 1, .{});
    for (state.micropore_conductance_m3_per_step) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (state.macropore_conductance_m3_per_step) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (state.micropore_mobility_fraction) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (state.macropore_mobility_fraction) |value| try std.testing.expectEqual(@as(f64, 0), value);
}
