const std = @import("std");
const grid_module = @import("../../state/grid.zig");
const hydrology_module = @import("../../transport/hydrology.zig");
const geometry_module = @import("../water/face_geometry.zig");
const organic = @import("initialization.zig");

pub const components_per_substrate: usize = 4;
pub const component_count: usize = organic.substrate_count * components_per_substrate;

pub const Component = enum(u2) {
    dissolved_organic_carbon,
    dissolved_organic_nitrogen,
    dissolved_organic_phosphorus,
    dissolved_acetate_carbon,
};

pub const RuntimeParameters = struct {
    reference_temperature_k: f64 = 298.15,
    temperature_exponent: f64 = 6,
    doc_diffusivity_m2_per_h: f64 = 1.0e-8,
    don_diffusivity_m2_per_h: f64 = 1.0e-8,
    dop_diffusivity_m2_per_h: f64 = 1.0e-8,
    acetate_diffusivity_m2_per_h: f64 = 3.64e-6,
    micropore_tortuosity_coefficient: f64 = 0.7,
    macropore_tortuosity_coefficient: f64 = 2.8,
    dispersivity_coefficient: f64 = 0.20,
    dispersivity_distance_exponent: f64 = 1.07,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    micropore_conductance_m3_per_step: []f64,
    macropore_conductance_m3_per_step: []f64,

    pub fn init(allocator: std.mem.Allocator, face_count: usize) !State {
        const count = try std.math.mul(usize, face_count, component_count);
        const micropore = try allocator.alloc(f64, count);
        errdefer allocator.free(micropore);
        const macropore = try allocator.alloc(f64, count);
        @memset(micropore, 0);
        @memset(macropore, 0);
        return .{ .allocator = allocator, .micropore_conductance_m3_per_step = micropore, .macropore_conductance_m3_per_step = macropore };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.macropore_conductance_m3_per_step);
        self.allocator.free(self.micropore_conductance_m3_per_step);
        self.* = undefined;
    }

    /// Reconstructs HOUR1 `OCSGL/ONSGL/OPSGL/OASGL` and the TRNSFR
    /// micropore/macropore face conductances for one converged physical step.
    pub fn refresh(
        self: *State,
        model_grid: *const grid_module.GridState,
        faces: *const hydrology_module.SoilFaces,
        geometry: *const geometry_module.State,
        matrix_bulk_volume_m3: []const f64,
        bulk_density_megagrams_per_m3: []const f64,
        step_h: f64,
        parameters: RuntimeParameters,
    ) !void {
        try validate(model_grid, faces, geometry, matrix_bulk_volume_m3, bulk_density_megagrams_per_m3, step_h, parameters, self.micropore_conductance_m3_per_step.len);
        for (faces.micropore_faces, 0..) |face, face_index| {
            if (!faces.active_by_face[face_index]) {
                const first = face_index * component_count;
                @memset(self.micropore_conductance_m3_per_step[first..][0..component_count], 0);
                @memset(self.macropore_conductance_m3_per_step[first..][0..component_count], 0);
                continue;
            }
            const source = face.first_cell;
            const destination = face.second_cell;
            const path_sum_m = geometry.source_path_length_m[face_index] + geometry.destination_path_length_m[face_index];
            const mean_distance_m = 0.5 * path_sum_m;
            const area_m2 = geometry.face_area_m2[face_index];
            const source_macro_fraction = macroporeFraction(model_grid, source);
            const destination_macro_fraction = macroporeFraction(model_grid, destination);
            const source_matrix_theta = if (matrix_bulk_volume_m3[source] > 0) std.math.clamp(model_grid.matrix_liquid_water_m3[source] / matrix_bulk_volume_m3[source], 0, 1) else 0;
            const destination_matrix_theta = if (matrix_bulk_volume_m3[destination] > 0) std.math.clamp(model_grid.matrix_liquid_water_m3[destination] / matrix_bulk_volume_m3[destination], 0, 1) else 0;
            // WATSUB computes one TORT carrier for every aqueous constituent.
            // Its BKDS>0 AND VOLY>0 predicate falls back to the flat 0.7
            // coefficient when either operand is zero (watsub.f:1122-1128).
            const source_micro_tortuosity = if (matrix_bulk_volume_m3[source] > 0 and bulk_density_megagrams_per_m3[source] > 0)
                parameters.micropore_tortuosity_coefficient * source_matrix_theta * source_matrix_theta * (1 - source_macro_fraction)
            else
                parameters.micropore_tortuosity_coefficient;
            const destination_micro_tortuosity = if (matrix_bulk_volume_m3[destination] > 0 and bulk_density_megagrams_per_m3[destination] > 0)
                parameters.micropore_tortuosity_coefficient * destination_matrix_theta * destination_matrix_theta * (1 - destination_macro_fraction)
            else
                parameters.micropore_tortuosity_coefficient;
            const source_macro_theta = if (model_grid.macropore_pore_capacity_m3[source] > 0) std.math.clamp(model_grid.macropore_liquid_water_m3[source] / model_grid.macropore_pore_capacity_m3[source], 0, 1) else 0;
            const destination_macro_theta = if (model_grid.macropore_pore_capacity_m3[destination] > 0) std.math.clamp(model_grid.macropore_liquid_water_m3[destination] / model_grid.macropore_pore_capacity_m3[destination], 0, 1) else 0;
            const source_macro_tortuosity = @min(1.0, parameters.macropore_tortuosity_coefficient * source_macro_theta * source_macro_theta * source_macro_theta) * source_macro_fraction;
            const destination_macro_tortuosity = @min(1.0, parameters.macropore_tortuosity_coefficient * destination_macro_theta * destination_macro_theta * destination_macro_theta) * destination_macro_fraction;
            const micro_tortuosity_per_m = (source_micro_tortuosity + destination_micro_tortuosity) / path_sum_m;
            const macro_tortuosity_per_m = (source_macro_tortuosity + destination_macro_tortuosity) / path_sum_m;
            const water_velocity_m_per_step = @abs(faces.micropore_water_flux_m3_per_step[face_index]) / area_m2;
            const dispersion_m2_per_step = parameters.dispersivity_coefficient * std.math.pow(f64, mean_distance_m, parameters.dispersivity_distance_exponent) * step_h * @min(step_h, water_velocity_m_per_step);
            const temperature_factor = std.math.pow(f64, model_grid.soil_temperature_k[destination] / parameters.reference_temperature_k, parameters.temperature_exponent);
            for (0..organic.substrate_count) |substrate| inline for (@typeInfo(Component).@"enum".fields) |field| {
                const component: Component = @enumFromInt(field.value);
                const index = face_index * component_count + substrate * components_per_substrate + field.value;
                const diffusivity_m2_per_step = referenceDiffusivity(component, parameters) * temperature_factor * step_h;
                self.micropore_conductance_m3_per_step[index] = (diffusivity_m2_per_step * micro_tortuosity_per_m + dispersion_m2_per_step) * area_m2;
                self.macropore_conductance_m3_per_step[index] = diffusivity_m2_per_step * macro_tortuosity_per_m * area_m2;
            };
        }
    }
};

fn referenceDiffusivity(component: Component, parameters: RuntimeParameters) f64 {
    return switch (component) {
        .dissolved_organic_carbon => parameters.doc_diffusivity_m2_per_h,
        .dissolved_organic_nitrogen => parameters.don_diffusivity_m2_per_h,
        .dissolved_organic_phosphorus => parameters.dop_diffusivity_m2_per_h,
        .dissolved_acetate_carbon => parameters.acetate_diffusivity_m2_per_h,
    };
}

fn macroporeFraction(model_grid: *const grid_module.GridState, layer: usize) f64 {
    const total = model_grid.matrix_pore_capacity_m3[layer] + model_grid.macropore_pore_capacity_m3[layer];
    return if (total > 0) std.math.clamp(model_grid.macropore_pore_capacity_m3[layer] / total, 0, 1) else 0;
}

fn validate(model_grid: *const grid_module.GridState, faces: *const hydrology_module.SoilFaces, geometry: *const geometry_module.State, bulk: []const f64, bulk_density: []const f64, step_h: f64, p: RuntimeParameters, output_len: usize) !void {
    if (bulk.len != model_grid.layer_count or bulk_density.len != model_grid.layer_count or faces.active_by_layer.len != model_grid.layer_count or faces.micropore_faces.len != geometry.face_area_m2.len or faces.active_by_face.len != faces.micropore_faces.len or output_len != faces.micropore_faces.len * component_count) return error.SoilOrganicFaceDimensionMismatch;
    inline for (.{ step_h, p.reference_temperature_k, p.doc_diffusivity_m2_per_h, p.don_diffusivity_m2_per_h, p.dop_diffusivity_m2_per_h, p.acetate_diffusivity_m2_per_h, p.micropore_tortuosity_coefficient, p.macropore_tortuosity_coefficient, p.dispersivity_coefficient, p.dispersivity_distance_exponent }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilOrganicTransportParameter;
    if (step_h == 0 or p.reference_temperature_k == 0) return error.InvalidSoilOrganicTransportParameter;
    for (bulk, model_grid.soil_temperature_k, faces.active_by_layer) |volume, temperature, active| {
        if (!std.math.isFinite(volume) or volume < 0 or !std.math.isFinite(temperature)) return error.InvalidSoilOrganicLayerState;
        if (active and temperature <= 0) return error.InvalidSoilOrganicLayerState;
    }
    for (bulk_density) |density| if (!std.math.isFinite(density) or density < 0) return error.InvalidSoilOrganicLayerState;
}

test "HOUR1 organic diffusivities distinguish acetate from DOC DON and DOP" {
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    @memset(model_grid.active_soil_layer_count, 1);
    @memset(model_grid.matrix_liquid_water_m3, 0.5);
    @memset(model_grid.matrix_pore_capacity_m3, 0.5);
    @memset(model_grid.macropore_liquid_water_m3, 0.1);
    @memset(model_grid.macropore_pore_capacity_m3, 0.1);
    @memset(model_grid.soil_temperature_k, 298.15);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &model_grid);
    defer faces.deinit();
    var geometry = try geometry_module.State.initMapped(std.testing.allocator, &model_grid, &faces, &.{ 1, 1 }, &.{ 1, 1 }, &.{ 1, 1 });
    defer geometry.deinit();
    var state = try State.init(std.testing.allocator, faces.micropore_faces.len);
    defer state.deinit();
    try state.refresh(&model_grid, &faces, &geometry, &.{ 1, 1 }, &.{ 1, 1 }, 1, .{});
    const doc = @intFromEnum(Component.dissolved_organic_carbon);
    const acetate = @intFromEnum(Component.dissolved_acetate_carbon);
    try std.testing.expect(state.micropore_conductance_m3_per_step[acetate] > state.micropore_conductance_m3_per_step[doc]);
    try std.testing.expect(state.macropore_conductance_m3_per_step[acetate] > state.macropore_conductance_m3_per_step[doc]);
    @memset(state.micropore_conductance_m3_per_step, 7);
    @memset(state.macropore_conductance_m3_per_step, 7);
    faces.active_by_face[0] = false;
    try state.refresh(&model_grid, &faces, &geometry, &.{ 1, 1 }, &.{ 1, 1 }, 1, .{});
    for (state.micropore_conductance_m3_per_step) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (state.macropore_conductance_m3_per_step) |value| try std.testing.expectEqual(@as(f64, 0), value);
}

test "active zero bulk volume uses flat WATSUB tortuosity for organic solutes" {
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

    try state.refresh(&grid, &faces, &geometry, &.{ 0, 1 }, &.{ 1, 1 }, 1, .{});
    const doc = @intFromEnum(Component.dissolved_organic_carbon);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5e-8), state.micropore_conductance_m3_per_step[doc], 1e-15);
    try std.testing.expectEqual(@as(f64, 0), state.macropore_conductance_m3_per_step[doc]);
    try state.refresh(&grid, &faces, &geometry, &.{ 1, 1 }, &.{ 0, 1 }, 1, .{});
    try std.testing.expectApproxEqAbs(@as(f64, 3.5e-8), state.micropore_conductance_m3_per_step[doc], 1e-15);
}
