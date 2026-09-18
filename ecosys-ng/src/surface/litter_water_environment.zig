const std = @import("std");
const compute = @import("../core/compute.zig");
const geometry = @import("litter_geometry_step.zig");
const retention = @import("../soil/water/retention.zig");
const chemistry = @import("litter_chemistry.zig");

pub const Parameters = struct {
    saturation_water_potential_megapascal: f64,
    minimum_water_potential_megapascal: f64,
    hygroscopic_water_potential_megapascal: f64,
    saturation_to_field_shape: f64,
    below_wilting_shape: f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    inactive_water_threshold_m3_per_m3: []f64,
    matric_water_potential_megapascal: []f64,
    osmotic_water_potential_megapascal: []f64,
    matric_plus_osmotic_water_potential_megapascal: []f64,
    water_film_thickness_m: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceLitterWaterEnvironmentCells;
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        var allocated: usize = 0;
        errdefer inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64 and allocated > 0) {
            allocated -= 1;
            allocator.free(@field(result, field.name));
        };
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            @field(result, field.name) = try allocator.alloc(f64, cell_count);
            @memset(@field(result, field.name), 0);
            allocated += 1;
        };
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }
};

pub const ApplyContext = struct {
    result: *State,
    litter_geometry: *const geometry.State,
    litter_chemistry: *const chemistry.State,
    litter_water_m3: []const f64,
    litter_temperature_k: []const f64,
    field_capacity_potential_megapascal: []const f64,
    wilting_point_potential_megapascal: []const f64,
    parameters: Parameters,
};

/// HOUR1 L=0 PSISM/PSISO. The retained water, rather than excess free water,
/// sets PSISM. Microbial OFFSET has its own authoritative per-cell state.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |cell| {
        const porosity = context.litter_geometry.porosity_m3_per_m3[cell];
        const field_capacity = context.litter_geometry.field_capacity_m3_per_m3[cell];
        const wilting_point = context.litter_geometry.wilting_point_m3_per_m3[cell];
        const inactive = try @import("litter_geometry.zig").waterFractionAtPotentialBelowWilting(field_capacity, wilting_point, context.field_capacity_potential_megapascal[cell], context.wilting_point_potential_megapascal[cell], context.parameters.hygroscopic_water_potential_megapascal);
        const retained_water_fraction = if (context.litter_geometry.dry_litter_volume_m3[cell] > 0)
            @min(context.litter_geometry.water_retention_capacity_m3[cell], context.litter_water_m3[cell]) / context.litter_geometry.dry_litter_volume_m3[cell]
        else
            porosity;
        const curve: retention.ResolvedCurve = .{ .porosity_fraction = porosity, .curve = .{
            .field_capacity_fraction = field_capacity,
            .wilting_point_fraction = wilting_point,
            .saturation_water_potential_megapascal = context.parameters.saturation_water_potential_megapascal,
            .field_capacity_water_potential_megapascal = context.field_capacity_potential_megapascal[cell],
            .wilting_point_water_potential_megapascal = context.wilting_point_potential_megapascal[cell],
            .minimum_water_potential_megapascal = context.parameters.minimum_water_potential_megapascal,
            .saturation_to_field_shape = context.parameters.saturation_to_field_shape,
            .below_wilting_shape = context.parameters.below_wilting_shape,
        } };
        const matric = if (retained_water_fraction > 0) try curve.waterPotentialMpa(retained_water_fraction) else context.parameters.minimum_water_potential_megapascal;
        const ion_activity = if (context.litter_water_m3[cell] > 0) (try chemistry.activityCoefficients(context.litter_chemistry.cells[cell], context.litter_water_m3[cell])).total_ion_activity_mol_per_m3 else 0;
        const osmotic = -8.3143e-6 * context.litter_temperature_k[cell] * ion_activity;
        // WATSUB FILM(M,0): a litter-free or water-free surface retains the
        // 1 um lower bound used by NITRO's radial O2 diffusion resistance.
        const film = if (context.litter_geometry.dry_litter_volume_m3[cell] > 0 and context.litter_water_m3[cell] > 0)
            @max(1e-6, 0.5 * @exp(-13.650 - 0.857 * @log(-matric)))
        else
            1e-6;
        inline for (.{ inactive, matric, osmotic, matric + osmotic, film }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceLitterWaterEnvironment;
        context.result.inactive_water_threshold_m3_per_m3[cell] = inactive;
        context.result.matric_water_potential_megapascal[cell] = matric;
        context.result.osmotic_water_potential_megapascal[cell] = osmotic;
        context.result.matric_plus_osmotic_water_potential_megapascal[cell] = matric + osmotic;
        context.result.water_film_thickness_m[cell] = film;
    }
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const cells = context.result.cell_count;
    if (range.first > range.end or range.end > cells or context.litter_geometry.cell_count != cells or context.litter_chemistry.cells.len != cells) return error.SurfaceLitterWaterEnvironmentDimensionMismatch;
    inline for (.{ context.litter_water_m3, context.litter_temperature_k, context.field_capacity_potential_megapascal, context.wilting_point_potential_megapascal }) |values| if (values.len != cells) return error.SurfaceLitterWaterEnvironmentDimensionMismatch;
    inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(context.parameters, field.name))) return error.NonFiniteSurfaceLitterWaterEnvironmentParameter;
    if (context.parameters.saturation_water_potential_megapascal >= 0 or context.parameters.minimum_water_potential_megapascal >= context.parameters.saturation_water_potential_megapascal or context.parameters.hygroscopic_water_potential_megapascal >= 0 or context.parameters.saturation_to_field_shape <= 0 or context.parameters.below_wilting_shape <= 0) return error.InvalidSurfaceLitterWaterEnvironmentParameter;
}

test "surface litter water environment reproduces HOUR1 potentials" {
    var litter_geometry = try geometry.State.init(std.testing.allocator, 1);
    defer litter_geometry.deinit();
    litter_geometry.dry_litter_volume_m3[0] = 1;
    litter_geometry.water_retention_capacity_m3[0] = 0.2;
    litter_geometry.porosity_m3_per_m3[0] = 0.6;
    litter_geometry.field_capacity_m3_per_m3[0] = 0.3;
    litter_geometry.wilting_point_m3_per_m3[0] = 0.1;
    var litter_chemistry = try chemistry.State.init(std.testing.allocator, 1);
    defer litter_chemistry.deinit();
    litter_chemistry.cells[0].sodium_mol_per_m3 = 2;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var context: ApplyContext = .{ .result = &state, .litter_geometry = &litter_geometry, .litter_chemistry = &litter_chemistry, .litter_water_m3 = &.{0.2}, .litter_temperature_k = &.{293.15}, .field_capacity_potential_megapascal = &.{-0.033}, .wilting_point_potential_megapascal = &.{-1.5}, .parameters = .{ .saturation_water_potential_megapascal = -0.0005, .minimum_water_potential_megapascal = -1.5e12, .hygroscopic_water_potential_megapascal = -1.5e4, .saturation_to_field_shape = 0.5, .below_wilting_shape = 0.5 } };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.matric_water_potential_megapascal[0] < -0.033);
    try std.testing.expect(state.osmotic_water_potential_megapascal[0] < 0);
    try std.testing.expect(state.water_film_thickness_m[0] >= 1e-6);
}
