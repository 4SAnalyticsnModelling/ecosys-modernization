const std = @import("std");
const CellRange = @import("../../core/compute.zig").CellRange;
const Geometry = @import("../morphology/geometry.zig").Geometry;
const StructureState = @import("../morphology/structure.zig").State;
const OpticsState = @import("../radiation/optics.zig").State;
const LayerState = @import("../radiation/layer_distribution.zig").State;
const RadiationState = @import("../radiation/radiation.zig").State;
const WoodyOpticsParameters = @import("../radiation/optics.zig").WoodyOpticsParameters;
const ScatteringDirection = @import("../morphology/geometry.zig").ScatteringDirection;

/// Leaf-only interception for the current combined canopy layer. Stalk,
/// standing-dead, vertical-layer scattering and ground reflection are added by
/// subsequent kernels without changing this runtime-sized boundary.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    layer_count: usize,
    absorbed_shortwave_megajoules_per_m2: []f64,
    absorbed_par_micromol_per_m2_per_s: []f64,
    direct_transmission_fraction: []f64,
    diffuse_transmission_fraction: []f64,
    direct_boundary_transmission_fraction: []f64,
    diffuse_boundary_transmission_fraction: []f64,
    leaf_absorbed_shortwave_by_layer_megajoules_per_m2: []f64,
    stalk_absorbed_shortwave_by_layer_megajoules_per_m2: []f64,
    standing_dead_absorbed_shortwave_by_layer_megajoules_per_m2: []f64,
    leaf_absorbed_par_by_layer_micromol_per_m2_per_s: []f64,
    stalk_absorbed_par_by_layer_micromol_per_m2_per_s: []f64,
    standing_dead_absorbed_par_by_layer_micromol_per_m2_per_s: []f64,
    downward_scattered_shortwave_by_boundary_megajoules_per_m2: []f64,
    upward_scattered_shortwave_by_boundary_megajoules_per_m2: []f64,
    downward_scattered_par_by_boundary_micromol_per_m2_per_s: []f64,
    upward_scattered_par_by_boundary_micromol_per_m2_per_s: []f64,
    upward_escape_shortwave_megajoules_per_m2: []f64,
    upward_escape_par_micromol_per_m2_per_s: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, species_count: usize, layer_count: usize) !State {
        @setEvalBranchQuota(10_000);
        if (cell_count == 0 or species_count == 0 or layer_count == 0) return error.InvalidCanopyInterceptionDimensions;
        const species_slots = try std.math.mul(usize, cell_count, species_count);
        const boundary_slots = try std.math.mul(usize, cell_count, try std.math.add(usize, layer_count, 1));
        const layer_slots = try std.math.mul(usize, species_slots, layer_count);
        var result: State = .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .layer_count = layer_count,
            .absorbed_shortwave_megajoules_per_m2 = try allocator.alloc(f64, species_slots),
            .absorbed_par_micromol_per_m2_per_s = undefined,
            .direct_transmission_fraction = undefined,
            .diffuse_transmission_fraction = undefined,
            .direct_boundary_transmission_fraction = undefined,
            .diffuse_boundary_transmission_fraction = undefined,
            .leaf_absorbed_shortwave_by_layer_megajoules_per_m2 = undefined,
            .stalk_absorbed_shortwave_by_layer_megajoules_per_m2 = undefined,
            .standing_dead_absorbed_shortwave_by_layer_megajoules_per_m2 = undefined,
            .leaf_absorbed_par_by_layer_micromol_per_m2_per_s = undefined,
            .stalk_absorbed_par_by_layer_micromol_per_m2_per_s = undefined,
            .standing_dead_absorbed_par_by_layer_micromol_per_m2_per_s = undefined,
            .downward_scattered_shortwave_by_boundary_megajoules_per_m2 = undefined,
            .upward_scattered_shortwave_by_boundary_megajoules_per_m2 = undefined,
            .downward_scattered_par_by_boundary_micromol_per_m2_per_s = undefined,
            .upward_scattered_par_by_boundary_micromol_per_m2_per_s = undefined,
            .upward_escape_shortwave_megajoules_per_m2 = undefined,
            .upward_escape_par_micromol_per_m2_per_s = undefined,
        };
        errdefer allocator.free(result.absorbed_shortwave_megajoules_per_m2);
        result.absorbed_par_micromol_per_m2_per_s = try allocator.alloc(f64, species_slots);
        errdefer allocator.free(result.absorbed_par_micromol_per_m2_per_s);
        result.direct_transmission_fraction = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.direct_transmission_fraction);
        result.diffuse_transmission_fraction = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.diffuse_transmission_fraction);
        result.direct_boundary_transmission_fraction = try allocator.alloc(f64, boundary_slots);
        errdefer allocator.free(result.direct_boundary_transmission_fraction);
        result.diffuse_boundary_transmission_fraction = try allocator.alloc(f64, boundary_slots);
        errdefer allocator.free(result.diffuse_boundary_transmission_fraction);
        result.leaf_absorbed_shortwave_by_layer_megajoules_per_m2 = try allocator.alloc(f64, layer_slots);
        errdefer allocator.free(result.leaf_absorbed_shortwave_by_layer_megajoules_per_m2);
        result.stalk_absorbed_shortwave_by_layer_megajoules_per_m2 = try allocator.alloc(f64, layer_slots);
        errdefer allocator.free(result.stalk_absorbed_shortwave_by_layer_megajoules_per_m2);
        result.standing_dead_absorbed_shortwave_by_layer_megajoules_per_m2 = try allocator.alloc(f64, layer_slots);
        errdefer allocator.free(result.standing_dead_absorbed_shortwave_by_layer_megajoules_per_m2);
        result.leaf_absorbed_par_by_layer_micromol_per_m2_per_s = try allocator.alloc(f64, layer_slots);
        errdefer allocator.free(result.leaf_absorbed_par_by_layer_micromol_per_m2_per_s);
        result.stalk_absorbed_par_by_layer_micromol_per_m2_per_s = try allocator.alloc(f64, layer_slots);
        errdefer allocator.free(result.stalk_absorbed_par_by_layer_micromol_per_m2_per_s);
        result.standing_dead_absorbed_par_by_layer_micromol_per_m2_per_s = try allocator.alloc(f64, layer_slots);
        errdefer allocator.free(result.standing_dead_absorbed_par_by_layer_micromol_per_m2_per_s);
        result.downward_scattered_shortwave_by_boundary_megajoules_per_m2 = try allocator.alloc(f64, boundary_slots);
        errdefer allocator.free(result.downward_scattered_shortwave_by_boundary_megajoules_per_m2);
        result.upward_scattered_shortwave_by_boundary_megajoules_per_m2 = try allocator.alloc(f64, boundary_slots);
        errdefer allocator.free(result.upward_scattered_shortwave_by_boundary_megajoules_per_m2);
        result.downward_scattered_par_by_boundary_micromol_per_m2_per_s = try allocator.alloc(f64, boundary_slots);
        errdefer allocator.free(result.downward_scattered_par_by_boundary_micromol_per_m2_per_s);
        result.upward_scattered_par_by_boundary_micromol_per_m2_per_s = try allocator.alloc(f64, boundary_slots);
        errdefer allocator.free(result.upward_scattered_par_by_boundary_micromol_per_m2_per_s);
        result.upward_escape_shortwave_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.upward_escape_shortwave_megajoules_per_m2);
        result.upward_escape_par_micromol_per_m2_per_s = try allocator.alloc(f64, cell_count);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) @memset(@field(result, field.name), if (comptime std.mem.indexOf(u8, field.name, "transmission") != null) 1 else 0);
        return result;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.upward_escape_par_micromol_per_m2_per_s);
        self.allocator.free(self.upward_escape_shortwave_megajoules_per_m2);
        self.allocator.free(self.upward_scattered_par_by_boundary_micromol_per_m2_per_s);
        self.allocator.free(self.downward_scattered_par_by_boundary_micromol_per_m2_per_s);
        self.allocator.free(self.upward_scattered_shortwave_by_boundary_megajoules_per_m2);
        self.allocator.free(self.downward_scattered_shortwave_by_boundary_megajoules_per_m2);
        self.allocator.free(self.standing_dead_absorbed_par_by_layer_micromol_per_m2_per_s);
        self.allocator.free(self.stalk_absorbed_par_by_layer_micromol_per_m2_per_s);
        self.allocator.free(self.leaf_absorbed_par_by_layer_micromol_per_m2_per_s);
        self.allocator.free(self.standing_dead_absorbed_shortwave_by_layer_megajoules_per_m2);
        self.allocator.free(self.stalk_absorbed_shortwave_by_layer_megajoules_per_m2);
        self.allocator.free(self.leaf_absorbed_shortwave_by_layer_megajoules_per_m2);
        self.allocator.free(self.diffuse_boundary_transmission_fraction);
        self.allocator.free(self.direct_boundary_transmission_fraction);
        self.allocator.free(self.diffuse_transmission_fraction);
        self.allocator.free(self.direct_transmission_fraction);
        self.allocator.free(self.absorbed_par_micromol_per_m2_per_s);
        self.allocator.free(self.absorbed_shortwave_megajoules_per_m2);
        self.* = undefined;
    }

    pub fn validateFinite(self: State) !void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) for (@field(self, field.name), 0..) |value, index| {
            if (!std.math.isFinite(value)) {
                std.log.err("non-finite canopy interception: field={s} index={d} value={e}", .{ field.name, index, value });
                return error.NonFiniteCanopyInterception;
            }
        };
    }
};

pub const ApplyContext = struct {
    result: *State,
    structure: *const StructureState,
    optics: *const OpticsState,
    geometry: *const Geometry,
    direct_incidence_fraction: []const f64,
    direct_incidence_per_horizontal_area: []const f64,
};

/// HOUR1 DPTHS/DPTH0 burial inputs. DPTH0 is the depth of surface water and
/// ice above litter retention and half the bare-soil roughness height.
pub const BurialInputs = struct {
    snow_depth_m: []const f64,
    surface_liquid_water_m3: []const f64,
    surface_ice_m3: []const f64,
    surface_water_retention_capacity_m3: []const f64,
    cell_area_m2: []const f64,
    soil_roughness_height_m: f64,
    absolute_depth_tolerance_m: f64,
    relative_depth_tolerance: f64,
    ice_density_megagrams_per_m3: f64 = 0.917,

    pub fn validate(self: BurialInputs, cell_count: usize) !void {
        inline for (.{
            self.snow_depth_m,
            self.surface_liquid_water_m3,
            self.surface_ice_m3,
            self.surface_water_retention_capacity_m3,
            self.cell_area_m2,
        }) |values| if (values.len != cell_count) return error.CanopyBurialDimensionMismatch;
        if (!std.math.isFinite(self.soil_roughness_height_m) or self.soil_roughness_height_m < 0 or
            !std.math.isFinite(self.absolute_depth_tolerance_m) or self.absolute_depth_tolerance_m <= 0 or
            !std.math.isFinite(self.relative_depth_tolerance) or self.relative_depth_tolerance <= 0)
            return error.InvalidCanopyBurialInput;
        if (!std.math.isFinite(self.ice_density_megagrams_per_m3) or self.ice_density_megagrams_per_m3 <= 0 or self.ice_density_megagrams_per_m3 > 1) return error.InvalidCanopyBurialInput;
        for (0..cell_count) |cell| {
            inline for (.{
                self.snow_depth_m[cell],
                self.surface_liquid_water_m3[cell],
                self.surface_ice_m3[cell],
                self.surface_water_retention_capacity_m3[cell],
                self.cell_area_m2[cell],
            }) |value| if (!std.math.isFinite(value)) return error.InvalidCanopyBurialInput;
            if (self.snow_depth_m[cell] < 0 or self.surface_liquid_water_m3[cell] < 0 or
                self.surface_ice_m3[cell] < 0 or self.surface_water_retention_capacity_m3[cell] < 0 or
                self.cell_area_m2[cell] <= 0)
                return error.InvalidCanopyBurialInput;
        }
    }

    pub fn surfaceWaterIceDepthM(self: BurialInputs, cell: usize) f64 {
        const excess_depth_m = @max(0.0, self.surface_liquid_water_m3[cell] +
            self.surface_ice_m3[cell] / self.ice_density_megagrams_per_m3 - self.surface_water_retention_capacity_m3[cell]) /
            self.cell_area_m2[cell];
        return @max(0.0, excess_depth_m - 0.5 * self.soil_roughness_height_m);
    }

    pub fn layerIsExposed(self: BurialInputs, layers: *const LayerState, cell: usize, layer: usize) !bool {
        const bottom_height_m = layers.boundary_height_m[cell * (layers.layer_count + 1) + layer];
        if (!std.math.isFinite(bottom_height_m)) return error.InvalidCanopyLayerBoundary;
        const surface_depth_m = self.surfaceWaterIceDepthM(cell);
        const scale_m = @max(@abs(bottom_height_m), @max(self.snow_depth_m[cell], surface_depth_m));
        const tolerance_m = self.absolute_depth_tolerance_m + self.relative_depth_tolerance * scale_m;
        return bottom_height_m >= self.snow_depth_m[cell] - tolerance_m and
            bottom_height_m >= surface_depth_m - tolerance_m;
    }
};

pub fn applySingleLayerTile(context: *ApplyContext, range: CellRange) !void {
    const structure = context.structure;
    const result = context.result;
    const inclination_count = structure.inclination_class_count;
    const azimuth_count = context.geometry.leaf_azimuth_radians.len;
    const sky_count = context.geometry.sky_azimuth_radians.len;
    const direct_table_count = try std.math.mul(usize, inclination_count, azimuth_count);
    if (range.end > result.cell_count or structure.cell_count != result.cell_count or context.optics.cell_count != result.cell_count or structure.species_count != result.species_count or context.optics.species_count != result.species_count) return error.CanopyInterceptionDimensionMismatch;
    if (context.direct_incidence_fraction.len != result.cell_count * direct_table_count or context.direct_incidence_per_horizontal_area.len != result.cell_count * direct_table_count) return error.IncorrectSolarGeometryBufferSize;
    const azimuth_weight = 1.0 / @as(f64, @floatFromInt(azimuth_count));

    for (range.first..range.end) |cell| {
        var direct_intercepted_area: f64 = 0;
        var diffuse_intercepted_area: f64 = 0;
        for (0..result.species_count) |species| {
            const species_index = cell * result.species_count + species;
            result.absorbed_shortwave_megajoules_per_m2[species_index] = 0;
            result.absorbed_par_micromol_per_m2_per_s[species_index] = 0;
            if (!structure.species_is_active[species_index]) continue;
            const clumping = structure.effective_clumping_factor[species_index];
            for (0..inclination_count) |inclination| {
                const angle_index = species_index * inclination_count + inclination;
                const effective_leaf_area = structure.leaf_area_index_by_inclination_m2_m2[angle_index] * clumping;
                for (0..azimuth_count) |azimuth| {
                    const direct_index =
                        cell * direct_table_count +
                        inclination * azimuth_count + azimuth;
                    direct_intercepted_area += effective_leaf_area * azimuth_weight * context.direct_incidence_per_horizontal_area[direct_index];
                    for (0..sky_count) |sky| {
                        const diffuse_index = context.geometry.index(sky, inclination, azimuth);
                        diffuse_intercepted_area += effective_leaf_area * azimuth_weight * context.geometry.diffuse_incidence_per_horizontal_area[diffuse_index];
                    }
                }
            }
        }
        const direct_scale = saturationScale(direct_intercepted_area);
        const diffuse_scale = saturationScale(diffuse_intercepted_area);
        // A one-layer state retains the historical compact path. Runtime
        // multilayer states publish TAUS(1)/TAUY(1) via refreshLayerTransmission.
        if (result.layer_count == 1) {
            result.direct_transmission_fraction[cell] = 1.0 - @min(1.0, direct_intercepted_area);
            result.diffuse_transmission_fraction[cell] = 1.0 - @min(1.0, diffuse_intercepted_area);
        }

        for (0..result.species_count) |species| {
            const species_index = cell * result.species_count + species;
            if (!structure.species_is_active[species_index]) continue;
            var absorbed_shortwave: f64 = 0;
            var absorbed_par: f64 = 0;
            const clumping = structure.effective_clumping_factor[species_index];
            for (0..inclination_count) |inclination| {
                const angle_index = species_index * inclination_count + inclination;
                const effective_leaf_area = structure.leaf_area_index_by_inclination_m2_m2[angle_index] * clumping;
                for (0..azimuth_count) |azimuth| {
                    const direct_index =
                        cell * direct_table_count +
                        inclination * azimuth_count + azimuth;
                    const direct_surface = effective_leaf_area * azimuth_weight * context.direct_incidence_fraction[direct_index] * direct_scale;
                    absorbed_shortwave += direct_surface * context.optics.direct_leaf_shortwave_megajoules_per_m2[species_index];
                    absorbed_par += direct_surface * context.optics.direct_leaf_par_micromol_per_m2_per_s[species_index];
                    for (0..sky_count) |sky| {
                        const diffuse_index = context.geometry.index(sky, inclination, azimuth);
                        const diffuse_surface = effective_leaf_area * azimuth_weight * context.geometry.diffuse_incidence_fraction[diffuse_index] * diffuse_scale;
                        absorbed_shortwave += diffuse_surface * context.optics.diffuse_leaf_shortwave_megajoules_per_m2[species_index];
                        absorbed_par += diffuse_surface * context.optics.diffuse_leaf_par_micromol_per_m2_per_s[species_index];
                    }
                }
            }
            if (!std.math.isFinite(absorbed_shortwave) or !std.math.isFinite(absorbed_par) or absorbed_shortwave < 0 or absorbed_par < 0) return error.InvalidCanopyAbsorption;
            result.absorbed_shortwave_megajoules_per_m2[species_index] = absorbed_shortwave;
            result.absorbed_par_micromol_per_m2_per_s[species_index] = absorbed_par;
        }
    }
}

pub fn refreshLayerTransmission(result: *State, layers: *const LayerState, structure: *const StructureState, geometry: *const Geometry, direct_incidence_per_horizontal_area: []const f64, cell_area_m2: []const f64) !void {
    return refreshLayerTransmissionInternal(result, layers, structure, geometry, direct_incidence_per_horizontal_area, cell_area_m2, null);
}

pub fn refreshLayerTransmissionWithBurial(result: *State, layers: *const LayerState, structure: *const StructureState, geometry: *const Geometry, direct_incidence_per_horizontal_area: []const f64, cell_area_m2: []const f64, burial: BurialInputs) !void {
    try burial.validate(layers.cell_count);
    return refreshLayerTransmissionInternal(result, layers, structure, geometry, direct_incidence_per_horizontal_area, cell_area_m2, burial);
}

fn refreshLayerTransmissionInternal(result: *State, layers: *const LayerState, structure: *const StructureState, geometry: *const Geometry, direct_incidence_per_horizontal_area: []const f64, cell_area_m2: []const f64, burial: ?BurialInputs) !void {
    if (result.cell_count != layers.cell_count or result.species_count != layers.species_count or result.layer_count != layers.layer_count) return error.LayerInterceptionDimensionMismatch;
    try calculateLayerTransmissionInternal(layers, structure, geometry, direct_incidence_per_horizontal_area, cell_area_m2, result.direct_boundary_transmission_fraction, result.diffuse_boundary_transmission_fraction, burial);
    const boundary_count = result.layer_count + 1;
    for (0..result.cell_count) |cell| {
        result.direct_transmission_fraction[cell] = result.direct_boundary_transmission_fraction[cell * boundary_count];
        result.diffuse_transmission_fraction[cell] = result.diffuse_boundary_transmission_fraction[cell * boundary_count];
    }
}

pub fn refreshAtmosphericLayerAbsorption(result: *State, layers: *const LayerState, structure: *const StructureState, optics: *const OpticsState, geometry: *const Geometry, radiation: *const RadiationState, direct_incidence_fraction: []const f64, direct_incidence_per_horizontal_area: []const f64, direct_scattering_direction: []const ScatteringDirection, cell_area_m2: []const f64, woody: WoodyOpticsParameters) !void {
    return refreshAtmosphericLayerAbsorptionInternal(result, layers, structure, optics, geometry, radiation, direct_incidence_fraction, direct_incidence_per_horizontal_area, direct_scattering_direction, cell_area_m2, woody, null);
}

pub fn refreshAtmosphericLayerAbsorptionWithBurial(result: *State, layers: *const LayerState, structure: *const StructureState, optics: *const OpticsState, geometry: *const Geometry, radiation: *const RadiationState, direct_incidence_fraction: []const f64, direct_incidence_per_horizontal_area: []const f64, direct_scattering_direction: []const ScatteringDirection, cell_area_m2: []const f64, woody: WoodyOpticsParameters, burial: BurialInputs) !void {
    try burial.validate(layers.cell_count);
    return refreshAtmosphericLayerAbsorptionInternal(result, layers, structure, optics, geometry, radiation, direct_incidence_fraction, direct_incidence_per_horizontal_area, direct_scattering_direction, cell_area_m2, woody, burial);
}

fn refreshAtmosphericLayerAbsorptionInternal(result: *State, layers: *const LayerState, structure: *const StructureState, optics: *const OpticsState, geometry: *const Geometry, radiation: *const RadiationState, direct_incidence_fraction: []const f64, direct_incidence_per_horizontal_area: []const f64, direct_scattering_direction: []const ScatteringDirection, cell_area_m2: []const f64, woody: WoodyOpticsParameters, burial: ?BurialInputs) !void {
    try woody.validate();
    const inclination_count = layers.inclination_count;
    const azimuth_count = layers.azimuth_count;
    const sky_count = geometry.sky_azimuth_radians.len;
    const boundary_count = layers.layer_count + 1;
    const direct_table_count = inclination_count * azimuth_count;
    if (result.cell_count != layers.cell_count or result.species_count != layers.species_count or result.layer_count != layers.layer_count or structure.cell_count != layers.cell_count or structure.species_count != layers.species_count or optics.cell_count != layers.cell_count or optics.species_count != layers.species_count or radiation.cellCount() != layers.cell_count or geometry.leaf_inclination_sine.len != inclination_count or geometry.leaf_azimuth_radians.len != azimuth_count or direct_incidence_fraction.len != layers.cell_count * direct_table_count or direct_incidence_per_horizontal_area.len != layers.cell_count * direct_table_count or direct_scattering_direction.len != layers.cell_count * direct_table_count or cell_area_m2.len != layers.cell_count) return error.LayerAbsorptionDimensionMismatch;
    inline for (.{ result.leaf_absorbed_shortwave_by_layer_megajoules_per_m2, result.stalk_absorbed_shortwave_by_layer_megajoules_per_m2, result.standing_dead_absorbed_shortwave_by_layer_megajoules_per_m2, result.leaf_absorbed_par_by_layer_micromol_per_m2_per_s, result.stalk_absorbed_par_by_layer_micromol_per_m2_per_s, result.standing_dead_absorbed_par_by_layer_micromol_per_m2_per_s, result.absorbed_shortwave_megajoules_per_m2, result.absorbed_par_micromol_per_m2_per_s, result.downward_scattered_shortwave_by_boundary_megajoules_per_m2, result.upward_scattered_shortwave_by_boundary_megajoules_per_m2, result.downward_scattered_par_by_boundary_micromol_per_m2_per_s, result.upward_scattered_par_by_boundary_micromol_per_m2_per_s }) |values| @memset(values, 0);

    for (0..layers.cell_count) |cell| {
        if (!std.math.isFinite(cell_area_m2[cell]) or cell_area_m2[cell] <= 0) return error.InvalidCanopyCellArea;
        const inverse_cell_area = 1.0 / cell_area_m2[cell];
        for (0..layers.layer_count) |layer| {
            if (burial) |inputs| if (!(try inputs.layerIsExposed(layers, cell, layer))) continue;
            const above_boundary = cell * boundary_count + layer + 1;
            const below_boundary = cell * boundary_count + layer;
            const direct_above = result.direct_boundary_transmission_fraction[above_boundary];
            const diffuse_above = result.diffuse_boundary_transmission_fraction[above_boundary];
            var raw_direct_horizontal_fraction: f64 = 0;
            var raw_diffuse_horizontal_fraction: f64 = 0;
            for (0..layers.species_count) |species| {
                const plant = cell * layers.species_count + species;
                if (!structure.species_is_active[plant]) continue;
                for (0..inclination_count) |inclination| {
                    const surface = ((plant * layers.layer_count + layer) * inclination_count) + inclination;
                    const projected_m2 = layers.plant_leaf_projected_surface_m2[surface] * structure.effective_clumping_factor[plant] + layers.plant_stalk_projected_surface_m2[surface] + layers.plant_standing_dead_projected_surface_m2[surface];
                    for (0..azimuth_count) |azimuth| {
                        raw_direct_horizontal_fraction += projected_m2 * direct_incidence_per_horizontal_area[cell * direct_table_count + inclination * azimuth_count + azimuth] * inverse_cell_area;
                        for (0..sky_count) |sky| raw_diffuse_horizontal_fraction += projected_m2 * geometry.diffuse_incidence_per_horizontal_area[geometry.index(sky, inclination, azimuth)] * inverse_cell_area;
                    }
                }
            }
            const direct_raw_decrement = direct_above * raw_direct_horizontal_fraction;
            const diffuse_raw_decrement = diffuse_above * raw_diffuse_horizontal_fraction;
            const direct_scale = if (direct_raw_decrement > 0) (direct_above - result.direct_boundary_transmission_fraction[below_boundary]) / direct_raw_decrement else 0;
            const diffuse_scale = if (diffuse_raw_decrement > 0) (diffuse_above - result.diffuse_boundary_transmission_fraction[below_boundary]) / diffuse_raw_decrement else 0;
            if (!std.math.isFinite(direct_scale) or !std.math.isFinite(diffuse_scale) or direct_scale < -1.0e-12 or direct_scale > 1.0 + 1.0e-12 or diffuse_scale < -1.0e-12 or diffuse_scale > 1.0 + 1.0e-12) return error.InvalidLayerAbsorptionScale;

            for (0..layers.species_count) |species| {
                const plant = cell * layers.species_count + species;
                if (!structure.species_is_active[plant]) continue;
                const output = plant * layers.layer_count + layer;
                const scattering_boundary = cell * boundary_count + layer;
                const leaf_sw_absorptivity = optics.leaf_shortwave_absorptivity[plant];
                const leaf_par_absorptivity = optics.leaf_par_absorptivity[plant];
                for (0..inclination_count) |inclination| {
                    const surface = ((plant * layers.layer_count + layer) * inclination_count) + inclination;
                    const leaf_m2 = layers.plant_leaf_projected_surface_m2[surface] * structure.effective_clumping_factor[plant];
                    const stalk_m2 = layers.plant_stalk_projected_surface_m2[surface];
                    const dead_m2 = layers.plant_standing_dead_projected_surface_m2[surface];
                    for (0..azimuth_count) |azimuth| {
                        const direct_index =
                            cell * direct_table_count +
                            inclination * azimuth_count + azimuth;
                        const direct_incidence = direct_incidence_fraction[direct_index];
                        const direct_sw = radiation.direct_shortwave_megajoules_per_m2[cell] * direct_incidence * direct_above * direct_scale * inverse_cell_area;
                        const direct_par = radiation.direct_par_micromol_per_m2_per_s[cell] * direct_incidence * direct_above * direct_scale * inverse_cell_area;
                        const leaf_direct_sw = leaf_m2 * direct_sw * leaf_sw_absorptivity;
                        const stalk_direct_sw = stalk_m2 * direct_sw * (1.0 - woody.stalk_shortwave_albedo);
                        const dead_direct_sw = dead_m2 * direct_sw * (1.0 - woody.standing_dead_shortwave_albedo);
                        const leaf_direct_par = leaf_m2 * direct_par * leaf_par_absorptivity;
                        const stalk_direct_par = stalk_m2 * direct_par * (1.0 - woody.stalk_par_albedo);
                        const dead_direct_par = dead_m2 * direct_par * (1.0 - woody.standing_dead_par_albedo);
                        result.leaf_absorbed_shortwave_by_layer_megajoules_per_m2[output] += leaf_direct_sw;
                        result.stalk_absorbed_shortwave_by_layer_megajoules_per_m2[output] += stalk_direct_sw;
                        result.standing_dead_absorbed_shortwave_by_layer_megajoules_per_m2[output] += dead_direct_sw;
                        result.leaf_absorbed_par_by_layer_micromol_per_m2_per_s[output] += leaf_direct_par;
                        result.stalk_absorbed_par_by_layer_micromol_per_m2_per_s[output] += stalk_direct_par;
                        result.standing_dead_absorbed_par_by_layer_micromol_per_m2_per_s[output] += dead_direct_par;
                        result.downward_scattered_shortwave_by_boundary_megajoules_per_m2[scattering_boundary] += leaf_direct_sw * optics.leaf_shortwave_transmission[plant];
                        result.downward_scattered_par_by_boundary_micromol_per_m2_per_s[scattering_boundary] += leaf_direct_par * optics.leaf_par_transmission[plant];
                        const direct_is_forward = direct_scattering_direction[direct_index] == .forward;
                        const reflected_direct_sw = leaf_direct_sw * optics.leaf_shortwave_albedo[plant] + stalk_direct_sw * woody.stalk_shortwave_albedo + dead_direct_sw * woody.standing_dead_shortwave_albedo;
                        const reflected_direct_par = leaf_direct_par * optics.leaf_par_albedo[plant] + stalk_direct_par * woody.stalk_par_albedo + dead_direct_par * woody.standing_dead_par_albedo;
                        if (direct_is_forward) {
                            result.downward_scattered_shortwave_by_boundary_megajoules_per_m2[scattering_boundary] += reflected_direct_sw;
                            result.downward_scattered_par_by_boundary_micromol_per_m2_per_s[scattering_boundary] += reflected_direct_par;
                        } else {
                            result.upward_scattered_shortwave_by_boundary_megajoules_per_m2[scattering_boundary] += reflected_direct_sw;
                            result.upward_scattered_par_by_boundary_micromol_per_m2_per_s[scattering_boundary] += reflected_direct_par;
                        }
                        for (0..sky_count) |sky| {
                            const diffuse_incidence = geometry.diffuse_incidence_fraction[geometry.index(sky, inclination, azimuth)];
                            const diffuse_sw = radiation.diffuse_shortwave_megajoules_per_m2[cell] * diffuse_incidence * diffuse_above * diffuse_scale * inverse_cell_area;
                            const diffuse_par = radiation.diffuse_par_micromol_per_m2_per_s[cell] * diffuse_incidence * diffuse_above * diffuse_scale * inverse_cell_area;
                            const leaf_diffuse_sw = leaf_m2 * diffuse_sw * leaf_sw_absorptivity;
                            const stalk_diffuse_sw = stalk_m2 * diffuse_sw * (1.0 - woody.stalk_shortwave_albedo);
                            const dead_diffuse_sw = dead_m2 * diffuse_sw * (1.0 - woody.standing_dead_shortwave_albedo);
                            const leaf_diffuse_par = leaf_m2 * diffuse_par * leaf_par_absorptivity;
                            const stalk_diffuse_par = stalk_m2 * diffuse_par * (1.0 - woody.stalk_par_albedo);
                            const dead_diffuse_par = dead_m2 * diffuse_par * (1.0 - woody.standing_dead_par_albedo);
                            result.leaf_absorbed_shortwave_by_layer_megajoules_per_m2[output] += leaf_diffuse_sw;
                            result.stalk_absorbed_shortwave_by_layer_megajoules_per_m2[output] += stalk_diffuse_sw;
                            result.standing_dead_absorbed_shortwave_by_layer_megajoules_per_m2[output] += dead_diffuse_sw;
                            result.leaf_absorbed_par_by_layer_micromol_per_m2_per_s[output] += leaf_diffuse_par;
                            result.stalk_absorbed_par_by_layer_micromol_per_m2_per_s[output] += stalk_diffuse_par;
                            result.standing_dead_absorbed_par_by_layer_micromol_per_m2_per_s[output] += dead_diffuse_par;
                            result.downward_scattered_shortwave_by_boundary_megajoules_per_m2[scattering_boundary] += leaf_diffuse_sw * optics.leaf_shortwave_transmission[plant];
                            result.downward_scattered_par_by_boundary_micromol_per_m2_per_s[scattering_boundary] += leaf_diffuse_par * optics.leaf_par_transmission[plant];
                            const diffuse_index = geometry.index(sky, inclination, azimuth);
                            const reflected_diffuse_sw = leaf_diffuse_sw * optics.leaf_shortwave_albedo[plant] + stalk_diffuse_sw * woody.stalk_shortwave_albedo + dead_diffuse_sw * woody.standing_dead_shortwave_albedo;
                            const reflected_diffuse_par = leaf_diffuse_par * optics.leaf_par_albedo[plant] + stalk_diffuse_par * woody.stalk_par_albedo + dead_diffuse_par * woody.standing_dead_par_albedo;
                            if (geometry.diffuse_scattering_direction[diffuse_index] == .forward) {
                                result.downward_scattered_shortwave_by_boundary_megajoules_per_m2[scattering_boundary] += reflected_diffuse_sw;
                                result.downward_scattered_par_by_boundary_micromol_per_m2_per_s[scattering_boundary] += reflected_diffuse_par;
                            } else {
                                result.upward_scattered_shortwave_by_boundary_megajoules_per_m2[scattering_boundary] += reflected_diffuse_sw;
                                result.upward_scattered_par_by_boundary_micromol_per_m2_per_s[scattering_boundary] += reflected_diffuse_par;
                            }
                        }
                    }
                }
                result.absorbed_shortwave_megajoules_per_m2[plant] += result.leaf_absorbed_shortwave_by_layer_megajoules_per_m2[output] + result.stalk_absorbed_shortwave_by_layer_megajoules_per_m2[output];
                result.absorbed_par_micromol_per_m2_per_s[plant] += result.leaf_absorbed_par_by_layer_micromol_per_m2_per_s[output] + result.stalk_absorbed_par_by_layer_micromol_per_m2_per_s[output];
            }
        }
        if (burial) |inputs| {
            var layer = layers.layer_count;
            while (layer > 0) {
                layer -= 1;
                if (try inputs.layerIsExposed(layers, cell, layer)) continue;
                const below = cell * boundary_count + layer;
                const above = below + 1;
                result.downward_scattered_shortwave_by_boundary_megajoules_per_m2[below] = result.downward_scattered_shortwave_by_boundary_megajoules_per_m2[above];
                result.downward_scattered_par_by_boundary_micromol_per_m2_per_s[below] = result.downward_scattered_par_by_boundary_micromol_per_m2_per_s[above];
            }
        }
    }
}

/// HOUR1 lower-to-upper diffuse pass beginning with ground reflection and
/// atmospheric RAB at boundary zero. Angular surface weights allocate the
/// layer interception; leaf TAUR/TAUP terms propagate transmitted energy.
pub fn applyGroundReflectedUpwardSweep(result: *State, layers: *const LayerState, structure: *const StructureState, optics: *const OpticsState, geometry: *const Geometry, ground_reflected_shortwave_megajoules_per_m2: []const f64, ground_reflected_par_micromol_per_m2_per_s: []const f64, woody: WoodyOpticsParameters) !void {
    return applyGroundReflectedUpwardSweepInternal(result, layers, structure, optics, geometry, ground_reflected_shortwave_megajoules_per_m2, ground_reflected_par_micromol_per_m2_per_s, woody, null);
}

pub fn applyGroundReflectedUpwardSweepWithBurial(result: *State, layers: *const LayerState, structure: *const StructureState, optics: *const OpticsState, geometry: *const Geometry, ground_reflected_shortwave_megajoules_per_m2: []const f64, ground_reflected_par_micromol_per_m2_per_s: []const f64, woody: WoodyOpticsParameters, burial: BurialInputs) !void {
    try burial.validate(layers.cell_count);
    return applyGroundReflectedUpwardSweepInternal(result, layers, structure, optics, geometry, ground_reflected_shortwave_megajoules_per_m2, ground_reflected_par_micromol_per_m2_per_s, woody, burial);
}

fn applyGroundReflectedUpwardSweepInternal(result: *State, layers: *const LayerState, structure: *const StructureState, optics: *const OpticsState, geometry: *const Geometry, ground_reflected_shortwave_megajoules_per_m2: []const f64, ground_reflected_par_micromol_per_m2_per_s: []const f64, woody: WoodyOpticsParameters, burial: ?BurialInputs) !void {
    try woody.validate();
    if (result.cell_count != layers.cell_count or result.species_count != layers.species_count or result.layer_count != layers.layer_count or structure.cell_count != layers.cell_count or optics.cell_count != layers.cell_count or ground_reflected_shortwave_megajoules_per_m2.len != layers.cell_count or ground_reflected_par_micromol_per_m2_per_s.len != layers.cell_count) return error.UpwardCanopySweepDimensionMismatch;
    @memset(result.upward_escape_shortwave_megajoules_per_m2, 0);
    @memset(result.upward_escape_par_micromol_per_m2_per_s, 0);
    const boundary_count = layers.layer_count + 1;
    for (0..layers.cell_count) |cell| {
        var incoming_sw = ground_reflected_shortwave_megajoules_per_m2[cell] + result.upward_scattered_shortwave_by_boundary_megajoules_per_m2[cell * boundary_count];
        var incoming_par = ground_reflected_par_micromol_per_m2_per_s[cell] + result.upward_scattered_par_by_boundary_micromol_per_m2_per_s[cell * boundary_count];
        if (!std.math.isFinite(incoming_sw) or !std.math.isFinite(incoming_par) or incoming_sw < 0 or incoming_par < 0) return error.InvalidGroundReflectedRadiation;
        for (0..layers.layer_count) |layer| {
            if (burial) |inputs| if (!(try inputs.layerIsExposed(layers, cell, layer))) continue;
            const below = cell * boundary_count + layer;
            const above = below + 1;
            const below_transmission = result.diffuse_boundary_transmission_fraction[below];
            const above_transmission = result.diffuse_boundary_transmission_fraction[above];
            const layer_transmission = if (above_transmission > 0) std.math.clamp(below_transmission / above_transmission, 0, 1) else 0;
            var total_geometric_weight: f64 = 0;
            for (0..layers.species_count) |species| {
                const plant = cell * layers.species_count + species;
                if (!structure.species_is_active[plant]) continue;
                for (0..layers.inclination_count) |inclination| {
                    const surface = ((plant * layers.layer_count + layer) * layers.inclination_count) + inclination;
                    const area = layers.plant_leaf_projected_surface_m2[surface] * structure.effective_clumping_factor[plant] + layers.plant_stalk_projected_surface_m2[surface] + layers.plant_standing_dead_projected_surface_m2[surface];
                    for (0..layers.azimuth_count) |azimuth| {
                        for (0..geometry.sky_azimuth_radians.len) |sky| {
                            total_geometric_weight += area * geometry.diffuse_incidence_fraction[geometry.index(sky, inclination, azimuth)];
                        }
                    }
                }
            }
            const intercepted_sw = incoming_sw * (1.0 - layer_transmission);
            const intercepted_par = incoming_par * (1.0 - layer_transmission);
            var leaf_transmitted_sw: f64 = 0;
            var leaf_transmitted_par: f64 = 0;
            if (total_geometric_weight > 0) for (0..layers.species_count) |species| {
                const plant = cell * layers.species_count + species;
                if (!structure.species_is_active[plant]) continue;
                const output = plant * layers.layer_count + layer;
                var leaf_weight: f64 = 0;
                var stalk_weight: f64 = 0;
                var dead_weight: f64 = 0;
                for (0..layers.inclination_count) |inclination| {
                    const surface = ((plant * layers.layer_count + layer) * layers.inclination_count) + inclination;
                    var angular_weight: f64 = 0;
                    for (0..layers.azimuth_count) |azimuth| {
                        for (0..geometry.sky_azimuth_radians.len) |sky| {
                            angular_weight += geometry.diffuse_incidence_fraction[geometry.index(sky, inclination, azimuth)];
                        }
                    }
                    leaf_weight += layers.plant_leaf_projected_surface_m2[surface] * structure.effective_clumping_factor[plant] * angular_weight;
                    stalk_weight += layers.plant_stalk_projected_surface_m2[surface] * angular_weight;
                    dead_weight += layers.plant_standing_dead_projected_surface_m2[surface] * angular_weight;
                }
                const leaf_sw = intercepted_sw * leaf_weight / total_geometric_weight * optics.leaf_shortwave_absorptivity[plant];
                const stalk_sw = intercepted_sw * stalk_weight / total_geometric_weight * (1.0 - woody.stalk_shortwave_albedo);
                const dead_sw = intercepted_sw * dead_weight / total_geometric_weight * (1.0 - woody.standing_dead_shortwave_albedo);
                const leaf_par = intercepted_par * leaf_weight / total_geometric_weight * optics.leaf_par_absorptivity[plant];
                const stalk_par = intercepted_par * stalk_weight / total_geometric_weight * (1.0 - woody.stalk_par_albedo);
                const dead_par = intercepted_par * dead_weight / total_geometric_weight * (1.0 - woody.standing_dead_par_albedo);
                result.leaf_absorbed_shortwave_by_layer_megajoules_per_m2[output] += leaf_sw;
                result.stalk_absorbed_shortwave_by_layer_megajoules_per_m2[output] += stalk_sw;
                result.standing_dead_absorbed_shortwave_by_layer_megajoules_per_m2[output] += dead_sw;
                result.leaf_absorbed_par_by_layer_micromol_per_m2_per_s[output] += leaf_par;
                result.stalk_absorbed_par_by_layer_micromol_per_m2_per_s[output] += stalk_par;
                result.standing_dead_absorbed_par_by_layer_micromol_per_m2_per_s[output] += dead_par;
                result.absorbed_shortwave_megajoules_per_m2[plant] += leaf_sw + stalk_sw;
                result.absorbed_par_micromol_per_m2_per_s[plant] += leaf_par + stalk_par;
                leaf_transmitted_sw += leaf_sw * optics.leaf_shortwave_transmission[plant];
                leaf_transmitted_par += leaf_par * optics.leaf_par_transmission[plant];
            };
            incoming_sw = incoming_sw * layer_transmission + leaf_transmitted_sw + result.upward_scattered_shortwave_by_boundary_megajoules_per_m2[above];
            incoming_par = incoming_par * layer_transmission + leaf_transmitted_par + result.upward_scattered_par_by_boundary_micromol_per_m2_per_s[above];
            if (!std.math.isFinite(incoming_sw) or !std.math.isFinite(incoming_par) or incoming_sw < 0 or incoming_par < 0) return error.InvalidUpwardCanopyRadiation;
        }
        result.upward_escape_shortwave_megajoules_per_m2[cell] = incoming_sw;
        result.upward_escape_par_micromol_per_m2_per_s[cell] = incoming_par;
    }
}

fn saturationScale(intercepted_area: f64) f64 {
    if (intercepted_area <= 1.0) return 1.0;
    return 1.0 / intercepted_area;
}

/// HOUR1 TAUS/TAUY top-down interception sweep over runtime canopy layers.
/// Projected surfaces already contain GROSUB's uniform-azimuth 0.25 factor.
pub fn calculateLayerTransmission(
    layers: *const LayerState,
    structure: *const StructureState,
    geometry: *const Geometry,
    direct_incidence_per_horizontal_area: []const f64,
    cell_area_m2: []const f64,
    direct_boundary_transmission: []f64,
    diffuse_boundary_transmission: []f64,
) !void {
    return calculateLayerTransmissionInternal(layers, structure, geometry, direct_incidence_per_horizontal_area, cell_area_m2, direct_boundary_transmission, diffuse_boundary_transmission, null);
}

fn calculateLayerTransmissionInternal(
    layers: *const LayerState,
    structure: *const StructureState,
    geometry: *const Geometry,
    direct_incidence_per_horizontal_area: []const f64,
    cell_area_m2: []const f64,
    direct_boundary_transmission: []f64,
    diffuse_boundary_transmission: []f64,
    burial: ?BurialInputs,
) !void {
    const inclination_count = layers.inclination_count;
    const azimuth_count = geometry.leaf_azimuth_radians.len;
    const sky_count = geometry.sky_azimuth_radians.len;
    const boundary_count = try std.math.add(usize, layers.layer_count, 1);
    const direct_table_count = inclination_count * azimuth_count;
    if (structure.cell_count != layers.cell_count or structure.species_count != layers.species_count or structure.inclination_class_count != inclination_count or geometry.leaf_inclination_sine.len != inclination_count or layers.azimuth_count != azimuth_count or cell_area_m2.len != layers.cell_count or direct_incidence_per_horizontal_area.len != layers.cell_count * direct_table_count or direct_boundary_transmission.len != layers.cell_count * boundary_count or diffuse_boundary_transmission.len != layers.cell_count * boundary_count) return error.LayerInterceptionDimensionMismatch;
    for (cell_area_m2) |area| if (!std.math.isFinite(area) or area <= 0) return error.InvalidCanopyCellArea;
    for (direct_incidence_per_horizontal_area) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidDirectIncidence;

    @memset(direct_boundary_transmission, 1);
    @memset(diffuse_boundary_transmission, 1);
    for (0..layers.cell_count) |cell| {
        var direct_transmission: f64 = 1;
        var diffuse_transmission: f64 = 1;
        var layer = layers.layer_count;
        while (layer > 0) {
            layer -= 1;
            const boundary_index = cell * boundary_count + layer;
            if (burial) |inputs| if (!(try inputs.layerIsExposed(layers, cell, layer))) {
                direct_boundary_transmission[boundary_index] = direct_transmission;
                diffuse_boundary_transmission[boundary_index] = diffuse_transmission;
                continue;
            };
            var direct_horizontal_area_m2: f64 = 0;
            var diffuse_horizontal_area_m2: f64 = 0;
            for (0..layers.species_count) |species| {
                const plant = cell * layers.species_count + species;
                if (!structure.species_is_active[plant]) continue;
                const clumping = structure.effective_clumping_factor[plant];
                if (!std.math.isFinite(clumping) or clumping < 0) return error.InvalidCanopyClumpingFactor;
                for (0..inclination_count) |inclination| {
                    const surface_index = ((plant * layers.layer_count + layer) * inclination_count) + inclination;
                    const leaf_surface_m2 = layers.plant_leaf_projected_surface_m2[surface_index] * clumping;
                    const woody_surface_m2 = layers.plant_stalk_projected_surface_m2[surface_index] + layers.plant_standing_dead_projected_surface_m2[surface_index];
                    if (!std.math.isFinite(leaf_surface_m2) or !std.math.isFinite(woody_surface_m2) or leaf_surface_m2 < 0 or woody_surface_m2 < 0) return error.InvalidProjectedCanopySurface;
                    const projected_surface_m2 = leaf_surface_m2 + woody_surface_m2;
                    for (0..azimuth_count) |azimuth| {
                        direct_horizontal_area_m2 += projected_surface_m2 * direct_incidence_per_horizontal_area[cell * direct_table_count + inclination * azimuth_count + azimuth];
                        for (0..sky_count) |sky| diffuse_horizontal_area_m2 += projected_surface_m2 * geometry.diffuse_incidence_per_horizontal_area[geometry.index(sky, inclination, azimuth)];
                    }
                }
            }
            const inverse_cell_area = 1.0 / cell_area_m2[cell];
            const direct_increment = @min(direct_transmission, direct_transmission * direct_horizontal_area_m2 * inverse_cell_area);
            const diffuse_increment = @min(diffuse_transmission, diffuse_transmission * diffuse_horizontal_area_m2 * inverse_cell_area);
            direct_transmission -= direct_increment;
            diffuse_transmission -= diffuse_increment;
            if (!std.math.isFinite(direct_transmission) or !std.math.isFinite(diffuse_transmission) or direct_transmission < 0 or diffuse_transmission < 0) return error.InvalidLayerTransmission;
            direct_boundary_transmission[boundary_index] = direct_transmission;
            diffuse_boundary_transmission[boundary_index] = diffuse_transmission;
        }
    }
}

test "saturation scaling preserves the Fortran full-interception cap" {
    try std.testing.expectEqual(@as(f64, 1), saturationScale(0.4));
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), saturationScale(4), 1.0e-15);
}

test "HOUR1 runtime layer transmission is bounded and monotone" {
    const allocator = std.testing.allocator;
    var canopy = try @import("../photosynthesis/photosynthesis.zig").State.init(allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    var layers = try LayerState.init(allocator, 1, 1, 6, 7, 5, &canopy);
    defer layers.deinit();
    @memset(layers.plant_leaf_projected_surface_m2, 0.03);
    var structure: StructureState = .{ .allocator = allocator, .cell_count = 1, .species_count = 1, .inclination_class_count = 7, .species_is_active = try allocator.alloc(bool, 1), .initial_clumping_factor = try allocator.alloc(f64, 1), .effective_clumping_factor = try allocator.alloc(f64, 1), .leaf_inclination_fraction = try allocator.alloc(f64, 7), .leaf_area_index_by_inclination_m2_m2 = try allocator.alloc(f64, 7) };
    defer structure.deinit();
    structure.species_is_active[0] = true;
    structure.effective_clumping_factor[0] = 0.8;
    var geometry = try Geometry.init(allocator, .{ .leaf_inclination_class_count = 7, .leaf_azimuth_class_count = 5, .diffuse_sky_sector_count = 3 });
    defer geometry.deinit();
    const direct_count = geometry.leaf_inclination_sine.len * geometry.leaf_azimuth_radians.len;
    const direct = try allocator.alloc(f64, direct_count);
    defer allocator.free(direct);
    const incidence = try allocator.alloc(f64, direct_count);
    defer allocator.free(incidence);
    const direction = try allocator.alloc(@import("../morphology/geometry.zig").ScatteringDirection, direct_count);
    defer allocator.free(direction);
    try geometry.directSolarIncidence(0.6, direct, incidence, direction);
    var direct_transmission: [7]f64 = undefined;
    var diffuse_transmission: [7]f64 = undefined;
    try calculateLayerTransmission(&layers, &structure, &geometry, incidence, &.{10}, &direct_transmission, &diffuse_transmission);
    try std.testing.expectEqual(@as(f64, 1), direct_transmission[6]);
    try std.testing.expectEqual(@as(f64, 1), diffuse_transmission[6]);
    for (0..6) |layer| {
        try std.testing.expect(direct_transmission[layer] >= 0 and direct_transmission[layer] <= direct_transmission[layer + 1]);
        try std.testing.expect(diffuse_transmission[layer] >= 0 and diffuse_transmission[layer] <= diffuse_transmission[layer + 1]);
    }
}

test "HOUR1 layered atmospheric absorption conserves incident shortwave" {
    const allocator = std.testing.allocator;
    var canopy = try @import("../photosynthesis/photosynthesis.zig").State.init(allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    var layers = try LayerState.init(allocator, 1, 1, 2, 1, 1, &canopy);
    defer layers.deinit();
    @memset(layers.plant_leaf_projected_surface_m2, 0.2);
    @memset(layers.plant_stalk_projected_surface_m2, 0.1);
    @memset(layers.plant_standing_dead_projected_surface_m2, 0.1);
    var structure: StructureState = .{ .allocator = allocator, .cell_count = 1, .species_count = 1, .inclination_class_count = 1, .species_is_active = try allocator.alloc(bool, 1), .initial_clumping_factor = try allocator.alloc(f64, 1), .effective_clumping_factor = try allocator.alloc(f64, 1), .leaf_inclination_fraction = try allocator.alloc(f64, 1), .leaf_area_index_by_inclination_m2_m2 = try allocator.alloc(f64, 1) };
    defer structure.deinit();
    structure.species_is_active[0] = true;
    structure.effective_clumping_factor[0] = 1;
    var geometry = try Geometry.init(allocator, .{ .leaf_inclination_class_count = 1, .leaf_azimuth_class_count = 1, .diffuse_sky_sector_count = 1 });
    defer geometry.deinit();
    var optics: OpticsState = .{ .allocator = allocator, .cell_count = 1, .species_count = 1, .species_is_active = try allocator.alloc(bool, 1), .leaf_shortwave_absorptivity = try allocator.alloc(f64, 1), .leaf_par_absorptivity = try allocator.alloc(f64, 1), .leaf_shortwave_albedo = try allocator.alloc(f64, 1), .leaf_par_albedo = try allocator.alloc(f64, 1), .leaf_shortwave_transmission = try allocator.alloc(f64, 1), .leaf_par_transmission = try allocator.alloc(f64, 1), .direct_leaf_shortwave_megajoules_per_m2 = try allocator.alloc(f64, 1), .diffuse_leaf_shortwave_megajoules_per_m2 = try allocator.alloc(f64, 1), .direct_leaf_par_micromol_per_m2_per_s = try allocator.alloc(f64, 1), .diffuse_leaf_par_micromol_per_m2_per_s = try allocator.alloc(f64, 1) };
    defer optics.deinit();
    optics.leaf_shortwave_absorptivity[0] = 0.7;
    optics.leaf_par_absorptivity[0] = 0.85;
    optics.leaf_shortwave_albedo[0] = 0.2;
    optics.leaf_par_albedo[0] = 0.1;
    optics.leaf_shortwave_transmission[0] = 0.1;
    optics.leaf_par_transmission[0] = 0.05;
    var radiation = try RadiationState.init(allocator, 1);
    defer radiation.deinit();
    radiation.direct_shortwave_megajoules_per_m2[0] = 1;
    radiation.diffuse_shortwave_megajoules_per_m2[0] = 0.5;
    radiation.direct_par_micromol_per_m2_per_s[0] = 500;
    radiation.diffuse_par_micromol_per_m2_per_s[0] = 200;
    const direct_fraction = try allocator.alloc(f64, 1);
    defer allocator.free(direct_fraction);
    const direct_horizontal = try allocator.alloc(f64, 1);
    defer allocator.free(direct_horizontal);
    const direction = try allocator.alloc(@import("../morphology/geometry.zig").ScatteringDirection, 1);
    defer allocator.free(direction);
    try geometry.directSolarIncidence(0.6, direct_fraction, direct_horizontal, direction);
    var result = try State.init(allocator, 1, 1, 2);
    defer result.deinit();
    try refreshLayerTransmission(&result, &layers, &structure, &geometry, direct_horizontal, &.{1});
    try refreshAtmosphericLayerAbsorption(&result, &layers, &structure, &optics, &geometry, &radiation, direct_fraction, direct_horizontal, direction, &.{1}, @import("../radiation/optics.zig").compatibilityWoodyOpticsParameters());
    var dead_absorbed: f64 = 0;
    for (result.standing_dead_absorbed_shortwave_by_layer_megajoules_per_m2) |value| dead_absorbed += value;
    var scattered_shortwave: f64 = 0;
    for (result.downward_scattered_shortwave_by_boundary_megajoules_per_m2) |value| scattered_shortwave += value;
    for (result.upward_scattered_shortwave_by_boundary_megajoules_per_m2) |value| scattered_shortwave += value;
    const incident_horizontal = radiation.direct_shortwave_megajoules_per_m2[0] * 0.6 + radiation.diffuse_shortwave_megajoules_per_m2[0] * geometry.diffuse_sky_horizontal_projection;
    const total_absorbed = result.absorbed_shortwave_megajoules_per_m2[0] + dead_absorbed;
    try std.testing.expect(total_absorbed > 0);
    try std.testing.expect(total_absorbed <= incident_horizontal + 1.0e-12);
    try std.testing.expect(scattered_shortwave > 0);
    try std.testing.expect(total_absorbed + scattered_shortwave <= incident_horizontal + 1.0e-12);
    const living_absorbed_before_upward = result.absorbed_shortwave_megajoules_per_m2[0];
    try applyGroundReflectedUpwardSweep(&result, &layers, &structure, &optics, &geometry, &.{0.1}, &.{20}, @import("../radiation/optics.zig").compatibilityWoodyOpticsParameters());
    try std.testing.expect(result.absorbed_shortwave_megajoules_per_m2[0] >= living_absorbed_before_upward);
    try std.testing.expect(result.upward_escape_shortwave_megajoules_per_m2[0] >= 0 and std.math.isFinite(result.upward_escape_shortwave_megajoules_per_m2[0]));
}

test "HOUR1 burial bypasses submerged layers in both radiation sweeps" {
    const allocator = std.testing.allocator;
    var canopy = try @import("../photosynthesis/photosynthesis.zig").State.init(allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    var layers = try LayerState.init(allocator, 1, 1, 2, 1, 1, &canopy);
    defer layers.deinit();
    layers.boundary_height_m[0] = 0;
    layers.boundary_height_m[1] = 0.3;
    layers.boundary_height_m[2] = 0.6;
    @memset(layers.plant_leaf_projected_surface_m2, 0.2);
    @memset(layers.plant_stalk_projected_surface_m2, 0.1);
    @memset(layers.plant_standing_dead_projected_surface_m2, 0.1);
    var structure: StructureState = .{ .allocator = allocator, .cell_count = 1, .species_count = 1, .inclination_class_count = 1, .species_is_active = try allocator.alloc(bool, 1), .initial_clumping_factor = try allocator.alloc(f64, 1), .effective_clumping_factor = try allocator.alloc(f64, 1), .leaf_inclination_fraction = try allocator.alloc(f64, 1), .leaf_area_index_by_inclination_m2_m2 = try allocator.alloc(f64, 1) };
    defer structure.deinit();
    structure.species_is_active[0] = true;
    structure.effective_clumping_factor[0] = 1;
    var geometry = try Geometry.init(allocator, .{ .leaf_inclination_class_count = 1, .leaf_azimuth_class_count = 1, .diffuse_sky_sector_count = 1 });
    defer geometry.deinit();
    var optics: OpticsState = .{ .allocator = allocator, .cell_count = 1, .species_count = 1, .species_is_active = try allocator.alloc(bool, 1), .leaf_shortwave_absorptivity = try allocator.alloc(f64, 1), .leaf_par_absorptivity = try allocator.alloc(f64, 1), .leaf_shortwave_albedo = try allocator.alloc(f64, 1), .leaf_par_albedo = try allocator.alloc(f64, 1), .leaf_shortwave_transmission = try allocator.alloc(f64, 1), .leaf_par_transmission = try allocator.alloc(f64, 1), .direct_leaf_shortwave_megajoules_per_m2 = try allocator.alloc(f64, 1), .diffuse_leaf_shortwave_megajoules_per_m2 = try allocator.alloc(f64, 1), .direct_leaf_par_micromol_per_m2_per_s = try allocator.alloc(f64, 1), .diffuse_leaf_par_micromol_per_m2_per_s = try allocator.alloc(f64, 1) };
    defer optics.deinit();
    optics.leaf_shortwave_absorptivity[0] = 0.7;
    optics.leaf_par_absorptivity[0] = 0.85;
    optics.leaf_shortwave_albedo[0] = 0.2;
    optics.leaf_par_albedo[0] = 0.1;
    optics.leaf_shortwave_transmission[0] = 0.1;
    optics.leaf_par_transmission[0] = 0.05;
    var radiation = try RadiationState.init(allocator, 1);
    defer radiation.deinit();
    radiation.direct_shortwave_megajoules_per_m2[0] = 1;
    radiation.diffuse_shortwave_megajoules_per_m2[0] = 0.5;
    radiation.direct_par_micromol_per_m2_per_s[0] = 500;
    radiation.diffuse_par_micromol_per_m2_per_s[0] = 200;
    var direct_fraction: [1]f64 = undefined;
    var direct_horizontal: [1]f64 = undefined;
    var direction: [1]ScatteringDirection = undefined;
    try geometry.directSolarIncidence(0.6, &direct_fraction, &direct_horizontal, &direction);
    var result = try State.init(allocator, 1, 1, 2);
    defer result.deinit();
    const burial: BurialInputs = .{
        .snow_depth_m = &.{0.7},
        .surface_liquid_water_m3 = &.{0.4},
        .surface_ice_m3 = &.{0.2},
        .surface_water_retention_capacity_m3 = &.{0.1},
        .cell_area_m2 = &.{1},
        .ice_density_megagrams_per_m3 = 0.917,
        .soil_roughness_height_m = 0.025,
        .absolute_depth_tolerance_m = 1e-12,
        .relative_depth_tolerance = 1e-12,
    };
    const expected_surface_depth_m = 0.4 + 0.2 / 0.917 - 0.1 - 0.5 * 0.025;
    try std.testing.expectApproxEqAbs(expected_surface_depth_m, burial.surfaceWaterIceDepthM(0), 1e-15);
    try refreshLayerTransmissionWithBurial(&result, &layers, &structure, &geometry, &direct_horizontal, &.{1}, burial);
    for (result.direct_boundary_transmission_fraction) |value| try std.testing.expectEqual(@as(f64, 1), value);
    for (result.diffuse_boundary_transmission_fraction) |value| try std.testing.expectEqual(@as(f64, 1), value);
    try refreshAtmosphericLayerAbsorptionWithBurial(&result, &layers, &structure, &optics, &geometry, &radiation, &direct_fraction, &direct_horizontal, &direction, &.{1}, @import("../radiation/optics.zig").compatibilityWoodyOpticsParameters(), burial);
    for (result.absorbed_shortwave_megajoules_per_m2) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (result.standing_dead_absorbed_shortwave_by_layer_megajoules_per_m2) |value| try std.testing.expectEqual(@as(f64, 0), value);
    try applyGroundReflectedUpwardSweepWithBurial(&result, &layers, &structure, &optics, &geometry, &.{0.1}, &.{20}, @import("../radiation/optics.zig").compatibilityWoodyOpticsParameters(), burial);
    try std.testing.expectEqual(@as(f64, 0.1), result.upward_escape_shortwave_megajoules_per_m2[0]);
    try std.testing.expectEqual(@as(f64, 20), result.upward_escape_par_micromol_per_m2_per_s[0]);
}
