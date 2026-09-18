const std = @import("std");
const CellRange = @import("../../core/compute.zig").CellRange;
const Assignments = @import("../../state/plant_assignment.zig").Assignments;
const Catalog = @import("../../state/plant_catalog.zig").Catalog;
const RadiationState = @import("radiation.zig").State;

pub const WoodyOpticsParameters = struct {
    stalk_shortwave_albedo: f64,
    stalk_par_albedo: f64,
    standing_dead_shortwave_albedo: f64,
    standing_dead_par_albedo: f64,

    pub fn validate(self: WoodyOpticsParameters) !void {
        inline for (.{ self.stalk_shortwave_albedo, self.stalk_par_albedo, self.standing_dead_shortwave_albedo, self.standing_dead_par_albedo }) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidWoodyOptics;
    }
};

pub fn compatibilityWoodyOpticsParameters() WoodyOpticsParameters {
    return .{ .stalk_shortwave_albedo = 0.1, .stalk_par_albedo = 0.1, .standing_dead_shortwave_albedo = 0.1, .standing_dead_par_albedo = 0.1 };
}

/// Optical coefficients and incident absorbed beam intensities use a
/// cell-major, species-minor layout. Species capacity is entirely runtime.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    species_is_active: []bool,
    leaf_shortwave_absorptivity: []f64,
    leaf_par_absorptivity: []f64,
    leaf_shortwave_albedo: []f64,
    leaf_par_albedo: []f64,
    leaf_shortwave_transmission: []f64,
    leaf_par_transmission: []f64,
    direct_leaf_shortwave_megajoules_per_m2: []f64,
    diffuse_leaf_shortwave_megajoules_per_m2: []f64,
    direct_leaf_par_micromol_per_m2_per_s: []f64,
    diffuse_leaf_par_micromol_per_m2_per_s: []f64,

    pub fn initMapped(allocator: std.mem.Allocator, cell_count: usize, species_count: usize, assignments: Assignments, unit_by_cell: []const usize, catalog: Catalog) !State {
        if (cell_count == 0 or species_count == 0 or unit_by_cell.len != cell_count) return error.InvalidCanopyOpticsDimensions;
        const count = try std.math.mul(usize, cell_count, species_count);
        var result: State = .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .species_is_active = try allocator.alloc(bool, count),
            .leaf_shortwave_absorptivity = undefined,
            .leaf_par_absorptivity = undefined,
            .leaf_shortwave_albedo = undefined,
            .leaf_par_albedo = undefined,
            .leaf_shortwave_transmission = undefined,
            .leaf_par_transmission = undefined,
            .direct_leaf_shortwave_megajoules_per_m2 = undefined,
            .diffuse_leaf_shortwave_megajoules_per_m2 = undefined,
            .direct_leaf_par_micromol_per_m2_per_s = undefined,
            .diffuse_leaf_par_micromol_per_m2_per_s = undefined,
        };
        errdefer allocator.free(result.species_is_active);
        result.leaf_shortwave_absorptivity = try allocator.alloc(f64, count);
        errdefer allocator.free(result.leaf_shortwave_absorptivity);
        result.leaf_par_absorptivity = try allocator.alloc(f64, count);
        errdefer allocator.free(result.leaf_par_absorptivity);
        result.leaf_shortwave_albedo = try allocator.alloc(f64, count);
        errdefer allocator.free(result.leaf_shortwave_albedo);
        result.leaf_par_albedo = try allocator.alloc(f64, count);
        errdefer allocator.free(result.leaf_par_albedo);
        result.leaf_shortwave_transmission = try allocator.alloc(f64, count);
        errdefer allocator.free(result.leaf_shortwave_transmission);
        result.leaf_par_transmission = try allocator.alloc(f64, count);
        errdefer allocator.free(result.leaf_par_transmission);
        result.direct_leaf_shortwave_megajoules_per_m2 = try allocator.alloc(f64, count);
        errdefer allocator.free(result.direct_leaf_shortwave_megajoules_per_m2);
        result.diffuse_leaf_shortwave_megajoules_per_m2 = try allocator.alloc(f64, count);
        errdefer allocator.free(result.diffuse_leaf_shortwave_megajoules_per_m2);
        result.direct_leaf_par_micromol_per_m2_per_s = try allocator.alloc(f64, count);
        errdefer allocator.free(result.direct_leaf_par_micromol_per_m2_per_s);
        result.diffuse_leaf_par_micromol_per_m2_per_s = try allocator.alloc(f64, count);
        inline for (@typeInfo(State).@"struct".fields) |field| switch (field.type) {
            []f64 => @memset(@field(result, field.name), 0),
            []bool => @memset(@field(result, field.name), false),
            else => {},
        };

        for (unit_by_cell, 0..) |unit_index, cell| {
            if (unit_index >= assignments.units.len) return error.PlantAssignmentUnitOutOfBounds;
            const assigned_species = assignments.units[unit_index].species;
            if (assigned_species.len > species_count) return error.PlantSpeciesCapacityExceeded;
            for (assigned_species, 0..) |assignment, species| {
                const catalog_index = catalog.find(assignment.species_file) orelse return error.MissingPlantTraitProfile;
                const optics = catalog.entries.items[catalog_index].traits.optics;
                try validateOptics(optics);
                const index = cell * species_count + species;
                result.species_is_active[index] = true;
                result.leaf_shortwave_absorptivity[index] = optics.shortwave_absorptivity;
                result.leaf_par_absorptivity[index] = optics.par_absorptivity;
                result.leaf_shortwave_albedo[index] = optics.shortwave_albedo;
                result.leaf_par_albedo[index] = optics.par_albedo;
                result.leaf_shortwave_transmission[index] = optics.shortwave_transmission;
                result.leaf_par_transmission[index] = optics.par_transmission;
            }
        }
        return result;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.diffuse_leaf_par_micromol_per_m2_per_s);
        self.allocator.free(self.direct_leaf_par_micromol_per_m2_per_s);
        self.allocator.free(self.diffuse_leaf_shortwave_megajoules_per_m2);
        self.allocator.free(self.direct_leaf_shortwave_megajoules_per_m2);
        self.allocator.free(self.leaf_par_absorptivity);
        self.allocator.free(self.leaf_shortwave_absorptivity);
        self.allocator.free(self.leaf_par_transmission);
        self.allocator.free(self.leaf_shortwave_transmission);
        self.allocator.free(self.leaf_par_albedo);
        self.allocator.free(self.leaf_shortwave_albedo);
        self.allocator.free(self.species_is_active);
        self.* = undefined;
    }

    pub fn validateFinite(self: State) !void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) for (@field(self, field.name), 0..) |value, index| {
            if (!std.math.isFinite(value)) {
                std.log.err("non-finite canopy optics: field={s} index={d} value={e}", .{ field.name, index, value });
                return error.NonFiniteCanopyOptics;
            }
        };
    }
};

pub const ApplyContext = struct { state: *State, radiation: *const RadiationState };

/// Ports the HOUR1 RADSA/RAPSA leaf beam preparation. Incidence-angle and
/// surface-area integration remain separate kernels so this pass vectorizes.
pub fn applyLeafAbsorptionTile(context: *ApplyContext, range: CellRange) !void {
    if (range.end > context.state.cell_count or context.radiation.cellCount() != context.state.cell_count) return error.CanopyOpticsTileOutOfBounds;
    for (range.first..range.end) |cell| {
        for (0..context.state.species_count) |species| {
            const index = cell * context.state.species_count + species;
            if (!context.state.species_is_active[index]) continue;
            const shortwave_absorptivity = context.state.leaf_shortwave_absorptivity[index];
            const par_absorptivity = context.state.leaf_par_absorptivity[index];
            context.state.direct_leaf_shortwave_megajoules_per_m2[index] = context.radiation.direct_shortwave_megajoules_per_m2[cell] * shortwave_absorptivity;
            context.state.diffuse_leaf_shortwave_megajoules_per_m2[index] = context.radiation.diffuse_shortwave_megajoules_per_m2[cell] * shortwave_absorptivity;
            context.state.direct_leaf_par_micromol_per_m2_per_s[index] = context.radiation.direct_par_micromol_per_m2_per_s[cell] * par_absorptivity;
            context.state.diffuse_leaf_par_micromol_per_m2_per_s[index] = context.radiation.diffuse_par_micromol_per_m2_per_s[cell] * par_absorptivity;
        }
    }
}

fn validateOptics(optics: @import("../../state/plant_traits.zig").Optics) !void {
    inline for (.{ optics.shortwave_absorptivity, optics.par_absorptivity, optics.shortwave_albedo, optics.par_albedo, optics.shortwave_transmission, optics.par_transmission }) |value| if (!std.math.isFinite(value)) return error.NonFiniteLeafOptics;
    if (optics.shortwave_absorptivity <= 0 or optics.par_absorptivity <= 0 or optics.shortwave_albedo < 0 or optics.par_albedo < 0 or optics.shortwave_transmission < 0 or optics.par_transmission < 0 or optics.shortwave_absorptivity + optics.shortwave_albedo + optics.shortwave_transmission > 1.0 + 1.0e-9 or optics.par_absorptivity + optics.par_albedo + optics.par_transmission > 1.0 + 1.0e-9) return error.InvalidLeafOptics;
}

test "absorption kernel supports inactive slots beyond assigned species" {
    // Mapping behavior is covered by example-driven catalog tests; exercise
    // the hot kernel directly with a runtime capacity greater than five.
    const allocator = std.testing.allocator;
    const count: usize = 11;
    var radiation = try RadiationState.init(allocator, 1);
    defer radiation.deinit();
    radiation.direct_shortwave_megajoules_per_m2[0] = 2;
    radiation.diffuse_shortwave_megajoules_per_m2[0] = 0.5;
    radiation.direct_par_micromol_per_m2_per_s[0] = 1000;
    radiation.diffuse_par_micromol_per_m2_per_s[0] = 200;
    var state: State = .{
        .allocator = allocator,
        .cell_count = 1,
        .species_count = count,
        .species_is_active = try allocator.alloc(bool, count),
        .leaf_shortwave_absorptivity = try allocator.alloc(f64, count),
        .leaf_par_absorptivity = try allocator.alloc(f64, count),
        .leaf_shortwave_albedo = try allocator.alloc(f64, count),
        .leaf_par_albedo = try allocator.alloc(f64, count),
        .leaf_shortwave_transmission = try allocator.alloc(f64, count),
        .leaf_par_transmission = try allocator.alloc(f64, count),
        .direct_leaf_shortwave_megajoules_per_m2 = try allocator.alloc(f64, count),
        .diffuse_leaf_shortwave_megajoules_per_m2 = try allocator.alloc(f64, count),
        .direct_leaf_par_micromol_per_m2_per_s = try allocator.alloc(f64, count),
        .diffuse_leaf_par_micromol_per_m2_per_s = try allocator.alloc(f64, count),
    };
    defer state.deinit();
    @memset(state.species_is_active, false);
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) @memset(@field(state, field.name), 0);
    state.species_is_active[10] = true;
    state.leaf_shortwave_absorptivity[10] = 0.6;
    state.leaf_par_absorptivity[10] = 0.85;
    var context: ApplyContext = .{ .state = &state, .radiation = &radiation };
    try applyLeafAbsorptionTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), state.direct_leaf_shortwave_megajoules_per_m2[10], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 850), state.direct_leaf_par_micromol_per_m2_per_s[10], 1.0e-12);
    try std.testing.expectEqual(@as(f64, 0), state.direct_leaf_shortwave_megajoules_per_m2[0]);
}

test "READQ optical budgets retain albedo transmission and absorption" {
    try validateOptics(.{
        .shortwave_albedo = 0.18,
        .par_albedo = 0.08,
        .shortwave_transmission = 0.12,
        .par_transmission = 0.04,
        .shortwave_absorptivity = 0.70,
        .par_absorptivity = 0.88,
    });
    try std.testing.expectError(error.InvalidLeafOptics, validateOptics(.{
        .shortwave_albedo = 0.3,
        .par_albedo = 0.08,
        .shortwave_transmission = 0.2,
        .par_transmission = 0.04,
        .shortwave_absorptivity = 0.6,
        .par_absorptivity = 0.88,
    }));
}

test "HOUR1 woody optical parameters preserve source budgets" {
    const parameters = compatibilityWoodyOpticsParameters();
    try parameters.validate();
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), 1.0 - parameters.stalk_shortwave_albedo, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), 1.0 - parameters.standing_dead_par_albedo, 1.0e-15);
}
