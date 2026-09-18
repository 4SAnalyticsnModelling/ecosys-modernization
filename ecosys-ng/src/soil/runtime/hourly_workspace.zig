const std = @import("std");
const grid_module = @import("../../state/grid.zig");
const property_module = @import("../water/solver_properties.zig");
const thermal_module = @import("../heat/thermal.zig");
const terrain_module = @import("../../state/terrain_hydrology.zig");
const surface_temperature_module = @import("../../surface/temperature_solver.zig");
const retention_module = @import("../water/retention.zig");
const chemistry_state_module = @import("../solute/chemistry_state.zig");
const charge_classification_module = @import("../solute/charge_classification.zig");
const ice_units = @import("../../core/ice_units.zig");
const heat_flux = @import("../heat/flux.zig");

pub const RuntimeParameters = struct {
    gravitational_water_potential_mpa_per_m: f64,
    reference_water_vapor_diffusivity_m2_per_h: f64,
    vapor_diffusivity_reference_temperature_k: f64,
    vapor_diffusivity_temperature_exponent: f64,
    vapor_pore_tortuosity: f64,
    osmotic_reflection_coefficient: f64,
    macropore_radius_m: f64,
    macropore_residual_saturation: f64,
    macropore_van_genuchten_alpha_per_m: f64,
    macropore_van_genuchten_n: f64,
    macropore_pore_connectivity: f64,
    dual_domain_geometry_factor: f64,
    dual_domain_scaling_coefficient: f64,
    frozen_hydraulic_impedance_exponent: f64,
    surface_residue_residual_water_content_m3_per_m3: f64,
    surface_residue_van_genuchten_alpha_per_m: f64,
    surface_residue_van_genuchten_n: f64,
    reference_water_viscosity_megagrams_per_m_s: f64,
    water_viscosity_temperature_intercept: f64,
    water_viscosity_temperature_coefficient_per_c: f64,
};

pub fn compatibilityParameters() RuntimeParameters {
    return .{ .gravitational_water_potential_mpa_per_m = 0.0098, .reference_water_vapor_diffusivity_m2_per_h = 8.96e-2, .vapor_diffusivity_reference_temperature_k = 298.15, .vapor_diffusivity_temperature_exponent = 1.75, .vapor_pore_tortuosity = 0.66, .osmotic_reflection_coefficient = 0.03, .macropore_radius_m = 0.5e-3, .macropore_residual_saturation = 0, .macropore_van_genuchten_alpha_per_m = 15, .macropore_van_genuchten_n = 2.68, .macropore_pore_connectivity = 0.5, .dual_domain_geometry_factor = 3, .dual_domain_scaling_coefficient = 0.4, .frozen_hydraulic_impedance_exponent = 7, .surface_residue_residual_water_content_m3_per_m3 = 0, .surface_residue_van_genuchten_alpha_per_m = 400, .surface_residue_van_genuchten_n = 2.5, .reference_water_viscosity_megagrams_per_m_s = 1e-6, .water_viscosity_temperature_intercept = 0.533, .water_viscosity_temperature_coefficient_per_c = 0.0267 };
}

pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    dual_domain_geometry_factor: f64,
    dual_domain_scaling_coefficient: f64,
    gravitational_water_potential_mpa_per_m: f64,
    frozen_hydraulic_impedance_exponent: f64,
    gravitational_potential_megapascal: []f64,
    osmotic_potential_megapascal: []f64,
    matric_plus_osmotic_potential_megapascal: []f64,
    landscape_total_water_potential_megapascal: []f64,
    root_referenced_total_water_potential_megapascal: []f64,
    vapor_diffusivity_m2_per_h: []f64,
    air_fraction: []f64,
    liquid_water_fraction: []f64,
    ice_fraction: []f64,
    fraction_of_pore_volume_air_filled: []f64,
    heat_capacity_megajoules_per_k: []f64,
    minimum_heat_capacity_megajoules_per_k: []f64,
    top_snow_heat_capacity_megajoules_per_k: []f64,
    maximum_negligible_snow_heat_capacity_megajoules_per_k: []f64,
    snow_storage_heat_flux_megajoules: []f64,
    cell_heat_source_megajoules: []f64,
    /// HEAT-001. The surface-to-soil conductive transfer exactly as
    /// `bindSurfaceHeatFlux` published it, before production adds the three
    /// later, legitimate top-cell heat sources
    /// (`surface_precipitation.bindSoilHeatIngress`,
    /// `subsurface_irrigation_heat.addToLayerHeatSources`, and the delayed
    /// subsurface combustion heat).
    ///
    /// The `surface soil conduction pairing` instrument used to read
    /// `cell_heat_source_megajoules[top]` *after* those additions and so
    /// reported a mismatch where none exists; the conduction transaction
    /// itself is bit-exact. This is the slot the instrument must read
    /// instead. Indexed by layer for dimensional uniformity; only top-of-cell
    /// entries are ever nonzero.
    published_surface_conduction_heat_megajoules: []f64,
    macropore_radius_m: []f64,
    macropore_spacing_m: []f64,
    macropore_hydraulic_conductivity_m2_per_h_megapascal: []f64,
    macropore_mualem_van_genuchten_parameters: []retention_module.MualemVanGenuchtenParameters,
    saturated_lateral_matrix_conductivity_m2_per_h_megapascal: []f64,
    plan_area_m2: []f64,
    is_top_soil_layer: []bool,
    macropore_exchange_enabled: []bool,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize) !State {
        if (layer_count == 0) return error.ZeroSoilHourlyWorkspaceSize;
        var result: State = undefined;
        result.allocator = allocator;
        result.layer_count = layer_count;
        result.dual_domain_geometry_factor = 0;
        result.dual_domain_scaling_coefficient = 0;
        result.gravitational_water_potential_mpa_per_m = 0;
        result.frozen_hydraulic_impedance_exponent = 0;
        var allocated: usize = 0;
        errdefer result.freeAllocated(allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) {
                @field(result, field.name) = try allocator.alloc(f64, layer_count);
                @memset(@field(result, field.name), 0);
                allocated += 1;
            } else if (field.type == []bool) {
                @field(result, field.name) = try allocator.alloc(bool, layer_count);
                @memset(@field(result, field.name), false);
                allocated += 1;
            } else if (field.type == []retention_module.MualemVanGenuchtenParameters) {
                @field(result, field.name) =
                    try allocator.alloc(retention_module.MualemVanGenuchtenParameters, layer_count);
                allocated += 1;
            }
        }
        @memset(result.heat_capacity_megajoules_per_k, 1);
        return result;
    }

    /// Refreshes HOUR1 quantities that depend on current water, ice,
    /// temperature, layer geometry, or terrain elevation.
    pub fn refresh(self: *State, grid: *const grid_module.GridState, properties: *const property_module.State, thermal: *const thermal_module.State, terrain: *const terrain_module.State, parameters: RuntimeParameters, ice_density_megagrams_per_m3: f64, chemistry: *const chemistry_state_module.State, fractions_source: anytype) !void {
        try validateRuntimeParameters(parameters);
        _ = try ice_units.physicalVolumeM3FromWaterEquivalent(0, ice_density_megagrams_per_m3);
        if (grid.layer_count != self.layer_count or properties.layer_count != self.layer_count or thermal.total_heat_capacity_megajoules_per_m3_k.len != self.layer_count or terrain.columns * terrain.rows != grid.cell_count or chemistry.cell_count != self.layer_count) return error.SoilHourlyWorkspaceDimensionMismatch;
        @memset(self.is_top_soil_layer, false);
        @memset(self.macropore_exchange_enabled, false);
        self.dual_domain_geometry_factor = parameters.dual_domain_geometry_factor;
        self.dual_domain_scaling_coefficient = parameters.dual_domain_scaling_coefficient;
        self.gravitational_water_potential_mpa_per_m =
            parameters.gravitational_water_potential_mpa_per_m;
        self.frozen_hydraulic_impedance_exponent =
            parameters.frozen_hydraulic_impedance_exponent;
        for (0..grid.cell_count) |cell| {
            var depth_to_top_m: f64 = 0;
            for (0..grid.active_soil_layer_count[cell]) |layer| {
                const index = cell * grid.soil_layer_capacity + layer;
                const thickness_m = properties.layer_thickness_m[index];
                const midpoint_depth_m = depth_to_top_m + 0.5 * thickness_m;
                depth_to_top_m += thickness_m;
                const matrix_volume_m3 = properties.matrix_bulk_volume_m3[index];
                const layer_volume_m3 = properties.layer_volume_m3[index];
                const matrix_pore_m3 = grid.matrix_pore_capacity_m3[index];
                if (matrix_volume_m3 <= 0 or layer_volume_m3 <= 0 or matrix_pore_m3 < 0 or grid.soil_temperature_k[index] <= 0) return error.InvalidSoilHourlyState;
                const total_air_m3 = grid.air_volume_m3[index];
                const matrix_air_m3 = grid.matrix_air_volume_m3[index];
                const matrix_liquid_m3 = grid.matrix_liquid_water_m3[index];
                const matrix_ice_m3 = grid.matrix_ice_water_m3[index];
                if (!std.math.isFinite(total_air_m3) or total_air_m3 < 0 or
                    !std.math.isFinite(matrix_air_m3) or matrix_air_m3 < 0 or
                    !std.math.isFinite(matrix_liquid_m3) or matrix_liquid_m3 < 0 or
                    !std.math.isFinite(matrix_ice_m3) or matrix_ice_m3 < 0 or
                    matrix_air_m3 > matrix_pore_m3)
                    return error.InvalidSoilHourlyPhaseVolume;
                self.gravitational_potential_megapascal[index] = parameters.gravitational_water_potential_mpa_per_m * (terrain.relative_surface_elevation_m[cell] - midpoint_depth_m);
                // SOIL-PSISO-001: PSISO = -8.3143e-6*TKS*CION (hour1.f:4181).
                // CION is the per-layer total ion activity already assembled
                // by the bound SOLUTE chemistry state; reuses the same
                // producer and formula surface/litter_water_environment.zig
                // already applies for the litter layer. The gravitational
                // term is intentionally not re-derived here to avoid
                // double-counting the one at `:138` above.
                const zone_fractions = try workspaceFractionsAt(fractions_source, index);
                const ion_activity_mol_per_m3 = (try chemistry.activityCoefficients(index, zone_fractions)).total_ion_activity_mol_per_m3;
                self.osmotic_potential_megapascal[index] = -8.3143e-6 * grid.soil_temperature_k[index] * ion_activity_mol_per_m3;
                self.matric_plus_osmotic_potential_megapascal[index] = grid.matric_potential_megapascal[index] + self.osmotic_potential_megapascal[index];
                self.landscape_total_water_potential_megapascal[index] =
                    self.matric_plus_osmotic_potential_megapascal[index] +
                    self.gravitational_potential_megapascal[index];
                // UPTAKE PSIST1 = PSIST - 0.0098*ALT. Because PSIST
                // already contains PSISH=0.0098*(ALT-depth), the absolute
                // landscape elevation cancels and the root-referenced
                // potential retains matric, osmotic, and layer-depth heads.
                self.root_referenced_total_water_potential_megapascal[index] =
                    self.matric_plus_osmotic_potential_megapascal[index] -
                    parameters.gravitational_water_potential_mpa_per_m *
                        midpoint_depth_m;
                self.vapor_diffusivity_m2_per_h[index] = parameters.reference_water_vapor_diffusivity_m2_per_h * std.math.pow(f64, grid.soil_temperature_k[index] / parameters.vapor_diffusivity_reference_temperature_k, parameters.vapor_diffusivity_temperature_exponent);
                self.air_fraction[index] = total_air_m3 / matrix_volume_m3;
                self.liquid_water_fraction[index] = matrix_liquid_m3 / matrix_volume_m3;
                self.ice_fraction[index] = (try ice_units.physicalVolumeM3FromWaterEquivalent(matrix_ice_m3, ice_density_megagrams_per_m3)) / matrix_volume_m3;
                self.fraction_of_pore_volume_air_filled[index] = if (matrix_pore_m3 > 0)
                    matrix_air_m3 / matrix_pore_m3
                else if (matrix_air_m3 == 0)
                    0
                else
                    return error.InvalidSoilHourlyPhaseVolume;
                self.heat_capacity_megajoules_per_k[index] = thermal.total_heat_capacity_megajoules_per_m3_k[index] * layer_volume_m3;
                self.macropore_radius_m[index] = parameters.macropore_radius_m;
                const macropore_count_per_m2: usize = @intFromFloat(@floor(grid.macropore_pore_capacity_m3[index] / (3.1416 * parameters.macropore_radius_m * parameters.macropore_radius_m * layer_volume_m3)));
                self.macropore_spacing_m[index] = if (macropore_count_per_m2 > 0) 1.0 / @sqrt(3.1416 * @as(f64, @floatFromInt(macropore_count_per_m2))) else 1.0;
                const temperature_c = grid.soil_temperature_k[index] - 273.15;
                const viscosity = parameters.reference_water_viscosity_megagrams_per_m_s * @exp(parameters.water_viscosity_temperature_intercept - parameters.water_viscosity_temperature_coefficient_per_c * temperature_c);
                self.macropore_hydraulic_conductivity_m2_per_h_megapascal[index] = 3.6e3 * 3.1416 * @as(f64, @floatFromInt(macropore_count_per_m2)) * std.math.pow(f64, parameters.macropore_radius_m, 4) / (8.0 * viscosity);
                self.macropore_mualem_van_genuchten_parameters[index] = .{
                    .residual_water_content_m3_per_m3 = parameters.macropore_residual_saturation,
                    .saturated_water_content_m3_per_m3 = 1,
                    .alpha_per_m = parameters.macropore_van_genuchten_alpha_per_m,
                    .n = parameters.macropore_van_genuchten_n,
                    .pore_connectivity = parameters.macropore_pore_connectivity,
                    .saturated_hydraulic_conductivity_m_per_h = self.macropore_hydraulic_conductivity_m2_per_h_megapascal[index] *
                        parameters.gravitational_water_potential_mpa_per_m,
                };
                try self.macropore_mualem_van_genuchten_parameters[index].validate();
                self.saturated_lateral_matrix_conductivity_m2_per_h_megapascal[index] = properties.saturated_lateral_conductivity_m2_per_h_megapascal[index];
                // `GRID-INV-003`. This is the *plan* (planform) area `Wx*Wy`,
                // valid only for genuinely vertical transfers: surface
                // conduction and the geothermal lower face. A lateral face
                // needs the vertical cross-section `t * W_transverse`, which
                // `solver_residual.zig` derives as layer volume over the
                // directional width. The former name,
                // `horizontal_face_area_m2`, read as "area of the horizontal
                // face" and invited exactly that substitution, which would
                // overstate lateral discharge by `W/t`: 250x for a 0.1 m layer
                // in a 25 m cell, and drifting as layers subside.
                self.plan_area_m2[index] = layer_volume_m3 / thickness_m;
                // STARTS 655 `VHCPRX = 8.380E-05*AREA(3,NU,NY,NX)`, against the
                // layer's plan area just derived above. This array is consumed
                // by `flux.zig:90/97` and `solver_residual.zig` as the oracle's
                // minimum layer heat capacity, but nothing in the tree ever
                // wrote it: `init` zeroes every f64 field at `:99` and no other
                // production site assigns it, so every test against it read
                // zero and became `capacity > 0`. That is a positivity test
                // standing in for a minimum-magnitude test -- the ZEROS/ZEROS2
                // translation gap -- and it let the soil heat solver divide an
                // enthalpy defect by a capacity 1.66x below the oracle's floor,
                // producing `residual_k = 3.0534e5` and
                // `SoilHeatSolverStagnated` at hour 2,726.
                self.minimum_heat_capacity_megajoules_per_k[index] =
                    heat_flux.minimum_layer_heat_capacity_megajoules_per_m2_k *
                    self.plan_area_m2[index];
                self.is_top_soil_layer[index] = layer == 0;
                self.macropore_exchange_enabled[index] = grid.macropore_pore_capacity_m3[index] > 0 and self.macropore_spacing_m[index] > self.macropore_radius_m[index];
            }
        }
        try self.validateFinite();
    }

    /// Binds the converged surface energy flux as an extensive top-cell heat
    /// source. Surface flux is positive upward, hence the sign reversal. The
    /// accepted flux must be state_updateted without clipping: any alteration here
    /// would destroy the equal-and-opposite surface/soil energy transaction.
    /// The implicit soil heat solve owns stability and reports non-convergence.
    pub fn bindSurfaceHeatFlux(self: *State, grid: *const grid_module.GridState, surface: *const surface_temperature_module.State, cell_area_m2: []const f64) !void {
        if (surface.cell_count != grid.cell_count or self.layer_count != grid.layer_count or cell_area_m2.len != grid.cell_count) return error.SoilHourlyWorkspaceDimensionMismatch;
        @memset(self.cell_heat_source_megajoules, 0);
        @memset(self.published_surface_conduction_heat_megajoules, 0);
        for (0..grid.cell_count) |cell| {
            if (grid.active_soil_layer_count[cell] == 0) return error.InvalidActiveSoilLayerCount;
            const top = cell * grid.soil_layer_capacity;
            // HEAT-001: the surface solver's conductive flux is per m2 of the
            // *ground surface*, so it must be extended by the cell's planform
            // area. `plan_area_m2[top]` is `layer_volume_m3 /
            // thickness_m`, which the surface pond transaction inflates above
            // the planform area once litter volume is folded into the top
            // layer. Using it made the soil receive ~1.3% more heat than the
            // surface gave, a smooth unbooked leak in the landscape heat
            // balance.
            if (!std.math.isFinite(cell_area_m2[cell]) or cell_area_m2[cell] <= 0) return error.InvalidSurfaceHeatFluxCellArea;
            const requested_surface_to_soil_megajoules = -surface.conductive_heat_flux_megajoules_per_m2[cell] * cell_area_m2[cell];
            self.cell_heat_source_megajoules[top] = requested_surface_to_soil_megajoules;
            self.published_surface_conduction_heat_megajoules[top] = requested_surface_to_soil_megajoules;
            if (!std.math.isFinite(self.cell_heat_source_megajoules[top])) return error.NonFiniteSoilSurfaceHeatFlux;
        }
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64 or field.type == []bool or field.type == []retention_module.MualemVanGenuchtenParameters) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    pub fn validateFinite(self: *const State) !void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) for (@field(self, field.name)) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilHourlyWorkspace;
        for (self.heat_capacity_megajoules_per_k) |capacity| if (capacity <= 0) return error.InvalidSoilHourlyHeatCapacity;
    }

    fn freeAllocated(self: *State, count: usize) void {
        var visited: usize = 0;
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64 or field.type == []bool or field.type == []retention_module.MualemVanGenuchtenParameters) {
            if (visited < count) self.allocator.free(@field(self, field.name));
            visited += 1;
        };
    }
};

fn workspaceFractionsAt(source: anytype, index: usize) !charge_classification_module.ZoneFractions {
    const Source = @TypeOf(source);
    if (comptime Source == charge_classification_module.ZoneFractions) return source;
    if (comptime Source == []const charge_classification_module.ZoneFractions or Source == []charge_classification_module.ZoneFractions) {
        if (index >= source.len) return error.SoilHourlyWorkspaceDimensionMismatch;
        return source[index];
    }
    return source.scienceZoneFractionsForFlatIndex(index);
}

pub fn validateRuntimeParameters(parameters: RuntimeParameters) !void {
    inline for (@typeInfo(RuntimeParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters, field.name))) return error.NonFiniteSoilHourlyParameters;
    if (parameters.gravitational_water_potential_mpa_per_m <= 0 or parameters.reference_water_vapor_diffusivity_m2_per_h < 0 or parameters.vapor_diffusivity_reference_temperature_k <= 0 or parameters.vapor_diffusivity_temperature_exponent < 0 or parameters.vapor_pore_tortuosity < 0 or parameters.osmotic_reflection_coefficient < 0 or parameters.osmotic_reflection_coefficient > 1 or parameters.macropore_radius_m <= 0 or parameters.macropore_residual_saturation < 0 or parameters.macropore_residual_saturation >= 1 or parameters.macropore_van_genuchten_alpha_per_m <= 0 or parameters.macropore_van_genuchten_n <= 1 or parameters.dual_domain_geometry_factor <= 0 or parameters.dual_domain_scaling_coefficient <= 0 or parameters.frozen_hydraulic_impedance_exponent < 0 or parameters.surface_residue_residual_water_content_m3_per_m3 < 0 or parameters.surface_residue_residual_water_content_m3_per_m3 >= 1 or parameters.surface_residue_van_genuchten_alpha_per_m <= 0 or parameters.surface_residue_van_genuchten_n <= 1 or parameters.reference_water_viscosity_megagrams_per_m_s <= 0 or parameters.water_viscosity_temperature_coefficient_per_c < 0) return error.InvalidSoilHourlyParameters;
}

test "hourly workspace refreshes gravity vapor fractions and extensive heat capacity" {
    const allocator = std.testing.allocator;
    const fixture = try @import("../../core/test_fixtures.zig").soilProfileSource(allocator, @typeInfo(@import("../../state/soil_profile.zig").LayerProperty).@"enum".fields.len);
    defer allocator.free(fixture);
    var catalog = @import("../profile/catalog.zig").Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("soil", fixture, @import("../water/retention.zig").compatibilityParameters(), @import("../profile/derivation.zig").compatibilityParameters());
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(allocator, cfg);
    defer grid.deinit();
    try @import("../../driver/model_initialization.zig").initializeCellHydrology(&grid, 0, catalog.entries.items[0].hydrology_per_m2);
    grid.soil_temperature_k[0] = 298.15;
    var properties = try property_module.State.initMapped(allocator, &grid, catalog.entries.items, &.{0}, &.{1}, &.{1}, property_module.compatibilityParameters());
    defer properties.deinit();
    var thermal = try thermal_module.State.initMapped(allocator, grid, catalog.entries.items, &.{0}, &.{1}, &.{1});
    defer thermal.deinit();
    var thermal_context: thermal_module.UpdateContext = .{ .thermal = &thermal, .grid = &grid, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .ice_density_megagrams_per_m3 = 0.917 };
    try thermal_module.updateTile(&thermal_context, .{ .first = 0, .end = 1 });
    var topography = try @import("../../state/topography.zig").fromUnits(allocator, &.{.{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1 }});
    defer topography.deinit();
    var terrain = try terrain_module.State.initMapped(allocator, topography, &.{0}, &.{1}, &.{1}, 1, 1);
    defer terrain.deinit();
    var workspace = try State.init(allocator, 1);
    defer workspace.deinit();
    var chemistry = try chemistry_state_module.State.init(allocator, 1);
    defer chemistry.deinit();
    chemistry.aqueous[0].ammonium_non_band = 5.0;
    chemistry.water_mol_per_m3[0] = 1;
    const zone_fractions = charge_classification_module.ZoneFractions{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 };
    try workspace.refresh(&grid, &properties, &thermal, &terrain, compatibilityParameters(), 0.917, &chemistry, zone_fractions);
    try std.testing.expectApproxEqAbs(@as(f64, 8.96e-2), workspace.vapor_diffusivity_m2_per_h[0], 1e-14);
    try std.testing.expect(workspace.gravitational_potential_megapascal[0] < 0);
    // SOIL-PSISO-001: with a nonzero ammonium concentration, PSISO must be
    // strictly negative -- proves the osmotic term now has a real producer
    // rather than silently staying at its allocation-time zero.
    try std.testing.expect(workspace.osmotic_potential_megapascal[0] < 0);
    try std.testing.expectApproxEqAbs(
        grid.matric_potential_megapascal[0] + workspace.osmotic_potential_megapascal[0] -
            compatibilityParameters().gravitational_water_potential_mpa_per_m *
                0.5 * properties.layer_thickness_m[0],
        workspace.root_referenced_total_water_potential_megapascal[0],
        1e-14,
    );
    try std.testing.expectApproxEqAbs(thermal.total_heat_capacity_megajoules_per_m3_k[0] * properties.layer_volume_m3[0], workspace.heat_capacity_megajoules_per_k[0], 1e-12);
    try std.testing.expect(workspace.is_top_soil_layer[0]);
    const parameters = compatibilityParameters();
    const count: usize = @intFromFloat(@floor(grid.macropore_pore_capacity_m3[0] / (3.1416 * parameters.macropore_radius_m * parameters.macropore_radius_m * properties.layer_volume_m3[0])));
    const viscosity = parameters.reference_water_viscosity_megagrams_per_m_s * @exp(parameters.water_viscosity_temperature_intercept - parameters.water_viscosity_temperature_coefficient_per_c * 25.0);
    const expected_conductivity = 3.6e3 * 3.1416 * @as(f64, @floatFromInt(count)) * std.math.pow(f64, parameters.macropore_radius_m, 4) / (8.0 * viscosity);
    try std.testing.expectApproxEqAbs(expected_conductivity, workspace.macropore_hydraulic_conductivity_m2_per_h_megapascal[0], 1e-14);
    try std.testing.expectApproxEqAbs(
        expected_conductivity * parameters.gravitational_water_potential_mpa_per_m,
        workspace.macropore_mualem_van_genuchten_parameters[0].saturated_hydraulic_conductivity_m_per_h,
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        parameters.macropore_van_genuchten_alpha_per_m,
        workspace.macropore_mualem_van_genuchten_parameters[0].alpha_per_m,
        1e-14,
    );
    try std.testing.expect(workspace.macropore_spacing_m[0] >= workspace.macropore_radius_m[0]);
}

test "hourly workspace rejects negative or over-capacity phase state instead of clipping" {
    const allocator = std.testing.allocator;
    const fixture = try @import("../../core/test_fixtures.zig").soilProfileSource(allocator, @typeInfo(@import("../../state/soil_profile.zig").LayerProperty).@"enum".fields.len);
    defer allocator.free(fixture);
    var catalog = @import("../profile/catalog.zig").Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("soil", fixture, @import("../water/retention.zig").compatibilityParameters(), @import("../profile/derivation.zig").compatibilityParameters());
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(allocator, cfg);
    defer grid.deinit();
    try @import("../../driver/model_initialization.zig").initializeCellHydrology(&grid, 0, catalog.entries.items[0].hydrology_per_m2);
    var properties = try property_module.State.initMapped(allocator, &grid, catalog.entries.items, &.{0}, &.{1}, &.{1}, property_module.compatibilityParameters());
    defer properties.deinit();
    var thermal = try thermal_module.State.initMapped(allocator, grid, catalog.entries.items, &.{0}, &.{1}, &.{1});
    defer thermal.deinit();
    var topography = try @import("../../state/topography.zig").fromUnits(allocator, &.{.{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1 }});
    defer topography.deinit();
    var terrain = try terrain_module.State.initMapped(allocator, topography, &.{0}, &.{1}, &.{1}, 1, 1);
    defer terrain.deinit();
    var workspace = try State.init(allocator, 1);
    defer workspace.deinit();
    var chemistry = try chemistry_state_module.State.init(allocator, 1);
    defer chemistry.deinit();
    chemistry.water_mol_per_m3[0] = 1;
    const zone_fractions = charge_classification_module.ZoneFractions{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 };

    grid.matrix_liquid_water_m3[0] = -std.math.floatEps(f64);
    try std.testing.expectError(error.InvalidSoilHourlyPhaseVolume, workspace.refresh(&grid, &properties, &thermal, &terrain, compatibilityParameters(), 0.917, &chemistry, zone_fractions));
    grid.matrix_liquid_water_m3[0] = 0;
    grid.matrix_air_volume_m3[0] = grid.matrix_pore_capacity_m3[0] + 1;
    try std.testing.expectError(error.InvalidSoilHourlyPhaseVolume, workspace.refresh(&grid, &properties, &thermal, &terrain, compatibilityParameters(), 0.917, &chemistry, zone_fractions));
}
