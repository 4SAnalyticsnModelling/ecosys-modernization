const std = @import("std");
const grid_module = @import("../../state/grid.zig");
const catalog_module = @import("../profile/catalog.zig");
const retention = @import("retention.zig");
const profile_derivation = @import("../profile/derivation.zig");

pub const RuntimeParameters = struct {
    retention: retention.Parameters,
    mualem_van_genuchten_fit_max_iterations: u16,
    hydraulic_conductivity_class_count: usize,
    pore_interaction_exponent: f64,
    air_entry_fraction_of_vertical_saturated_conductivity: f64,
    mineral_saturated_conductivity_scale_m2_per_h_megapascal: f64,
    mineral_reference_water_potential_mpa_magnitude: f64,
    organic_saturated_conductivity_intercept_m2_per_h_megapascal: f64,
    organic_saturated_conductivity_scale_m2_per_h_megapascal: f64,
    organic_saturated_conductivity_bulk_density_base: f64,
    profile_derivation: profile_derivation.Parameters,
};

/// Values encoded by HOUR1 in the historical source. This constructs a runtime
/// value only for old runscripts that predate the explicit soil_solver record.
pub fn compatibilityParameters() RuntimeParameters {
    return .{
        .retention = retention.compatibilityParameters(),
        .mualem_van_genuchten_fit_max_iterations = 80,
        .hydraulic_conductivity_class_count = 100,
        .pore_interaction_exponent = 1.33,
        .air_entry_fraction_of_vertical_saturated_conductivity = 0.1,
        .mineral_saturated_conductivity_scale_m2_per_h_megapascal = 1.54,
        .mineral_reference_water_potential_mpa_magnitude = 0.033,
        .organic_saturated_conductivity_intercept_m2_per_h_megapascal = 0.10,
        .organic_saturated_conductivity_scale_m2_per_h_megapascal = 75,
        .organic_saturated_conductivity_bulk_density_base = 1.0e-15,
        .profile_derivation = profile_derivation.compatibilityParameters(),
    };
}

/// Heap-owned, cell-layer-resolved HOUR1 properties consumed by the coupled
/// soil solvers. Every scientific coefficient enters through RuntimeParameters
/// or a user soil profile; none of the extents or coefficients are comptime.
pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    retention_curve: []retention.ResolvedCurve,
    mualem_van_genuchten_parameters: []retention.MualemVanGenuchtenParameters = @constCast(&.{}),
    /// `SOIL-HCOND-AXIS-ISOTROPY-001`. Per-layer lateral (x=y) saturated
    /// hydraulic conductivity, `m h-1`, the `SCNH` analog of
    /// `mualem_van_genuchten_parameters[index].saturated_hydraulic_conductivity_m_per_h`
    /// (`SCNV`). Populated the same way as the vertical scalar: the deck's
    /// `lateral_saturated_conductivity_mm_h` when supplied, else the vertical
    /// scalar itself (isotropic fallback), mirroring `hour1.f:2210-2221`'s
    /// `ISOIL(4,...)` branch defaulting to the same formula used for `SCNV`
    /// when the soil file withholds a lateral value.
    lateral_saturated_hydraulic_conductivity_m_per_h: []f64 = @constCast(&.{}),
    matrix_bulk_volume_m3: []f64,
    layer_volume_m3: []f64,
    layer_thickness_m: []f64,
    /// REDIST DLYRI(3): immutable layer thickness read from the soil profile.
    /// Current thickness is allowed to move; this anchor is not.
    initial_layer_thickness_m: []f64 = @constCast(&.{}),
    layer_midpoint_depth_m: []f64,
    layer_bottom_depth_m: []f64,
    bulk_density_megagrams_per_m3: []f64,
    /// REDIST BKDSI: immutable bulk density read from the soil profile.
    reference_bulk_density_megagrams_per_m3: []f64 = @constCast(&.{}),
    sand_mass_fraction: []f64,
    silt_mass_fraction: []f64,
    clay_mass_fraction: []f64,
    /// STARTS/REDIST SAND, SILT, CLAY authoritative extensive inventories.
    sand_mass_megagrams: []f64,
    silt_mass_megagrams: []f64,
    clay_mass_megagrams: []f64,
    total_organic_carbon_g_per_megagram: []f64,
    cation_exchange_capacity_mol_per_megagram: []f64,
    anion_exchange_capacity_mol_per_megagram: []f64,
    cation_exchange_capacity_mol: []f64,
    anion_exchange_capacity_mol: []f64,
    porosity_fraction: []f64,
    /// Persistent source/profile controls required to rebuild material-derived
    /// properties after redistribution. Negative supplied values retain the
    /// HOUR1 "derive this property" sentinel semantics.
    micropore_fraction: []f64,
    macropore_fraction: []f64,
    rock_fraction: []f64,
    supplied_field_capacity_fraction: []f64,
    supplied_wilting_point_fraction: []f64,
    field_capacity_water_potential_megapascal: []f64,
    wilting_point_water_potential_megapascal: []f64,
    supplied_vertical_saturated_hydraulic_conductivity_m_per_h: []f64,
    supplied_lateral_saturated_hydraulic_conductivity_m_per_h: []f64,
    supplied_lateral_conductivity_m2_per_h_megapascal: []f64,
    van_genuchten_inflection_pressure_head_m: []f64,
    /// Exact cumulative HOUR1 charcoal DORGCC/VOLY increment. It is kept
    /// separate from the profile anchors so later texture/SOC rebuilds cannot
    /// erase an accepted fertilizer transaction.
    charcoal_retention_increment_fraction: []f64,
    /// Previous accepted per-layer charcoal C (ORGCCX, g C). The next HOUR1
    /// material refresh uses the signed current-minus-previous DORGCC once,
    /// then advances this snapshot atomically.
    previous_charcoal_carbon_g_c: []f64,
    field_capacity_fraction: []f64,
    wilting_point_fraction: []f64,
    saturation_water_potential_megapascal: []f64,
    /// Rainfall-impact reduction applied during lookup; the base table remains immutable.
    rainfall_conductivity_multiplier: []f64,
    /// `PR-COND-TABLE-001`. Saturated lateral (x=y) matrix conductivity per
    /// layer, as an intrinsic m2 MPa-1 h-1 property. This replaces the legacy
    /// HOUR1 `HCND` class table, whose only surviving production read was the
    /// wettest class of the lateral axis, i.e. this scalar.
    saturated_lateral_conductivity_m2_per_h_megapascal: []f64,

    pub fn initMapped(
        allocator: std.mem.Allocator,
        grid: *const grid_module.GridState,
        catalog_entries: []const catalog_module.Entry,
        catalog_index_by_cell: []const usize,
        horizontal_cell_width_m: []const f64,
        vertical_cell_width_m: []const f64,
        parameters: RuntimeParameters,
    ) !State {
        try parameters.retention.validate();
        try parameters.profile_derivation.validate();
        if (parameters.mualem_van_genuchten_fit_max_iterations == 0 or parameters.hydraulic_conductivity_class_count == 0 or !std.math.isFinite(parameters.pore_interaction_exponent) or parameters.pore_interaction_exponent <= 0 or !std.math.isFinite(parameters.air_entry_fraction_of_vertical_saturated_conductivity) or parameters.air_entry_fraction_of_vertical_saturated_conductivity < 0 or parameters.air_entry_fraction_of_vertical_saturated_conductivity > 1 or !std.math.isFinite(parameters.mineral_saturated_conductivity_scale_m2_per_h_megapascal) or parameters.mineral_saturated_conductivity_scale_m2_per_h_megapascal < 0 or !std.math.isFinite(parameters.mineral_reference_water_potential_mpa_magnitude) or parameters.mineral_reference_water_potential_mpa_magnitude <= 0 or !std.math.isFinite(parameters.organic_saturated_conductivity_intercept_m2_per_h_megapascal) or parameters.organic_saturated_conductivity_intercept_m2_per_h_megapascal < 0 or !std.math.isFinite(parameters.organic_saturated_conductivity_scale_m2_per_h_megapascal) or parameters.organic_saturated_conductivity_scale_m2_per_h_megapascal < 0 or !std.math.isFinite(parameters.organic_saturated_conductivity_bulk_density_base) or parameters.organic_saturated_conductivity_bulk_density_base <= 0) return error.InvalidSoilSolverRuntimeParameters;
        if (catalog_index_by_cell.len != grid.cell_count or
            horizontal_cell_width_m.len != grid.cell_count or
            vertical_cell_width_m.len != grid.cell_count)
            return error.SoilSolverPropertyDimensionMismatch;
        var result: State = undefined;
        result.allocator = allocator;
        result.layer_count = grid.layer_count;
        var allocated: usize = 0;
        errdefer result.freeAllocated(allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) {
                @field(result, field.name) = try allocator.alloc(f64, grid.layer_count);
                @memset(@field(result, field.name), 0);
                allocated += 1;
            } else if (field.type == []retention.ResolvedCurve) {
                @field(result, field.name) = try allocator.alloc(retention.ResolvedCurve, grid.layer_count);
                allocated += 1;
            } else if (field.type == []retention.MualemVanGenuchtenParameters) {
                @field(result, field.name) = try allocator.alloc(retention.MualemVanGenuchtenParameters, grid.layer_count);
                allocated += 1;
            }
        }
        const inactive_curve = try retention.resolve(parameters.retention, .{ .porosity_fraction = 0.5, .macropore_fraction = 0, .sand_fraction = 0.5, .clay_fraction = 0.25, .organic_carbon_g_per_megagram = 0, .bulk_density_megagrams_per_m3 = 1, .supplied_field_capacity_fraction = null, .supplied_wilting_point_fraction = null }, -0.01, -1.5);
        @memset(result.retention_curve, inactive_curve);
        const inactive_mualem_van_genuchten = try retention.carselParrishDefault(.loam, 0.5);
        @memset(result.mualem_van_genuchten_parameters, inactive_mualem_van_genuchten);
        @memset(result.lateral_saturated_hydraulic_conductivity_m_per_h, inactive_mualem_van_genuchten.saturated_hydraulic_conductivity_m_per_h);
        @memset(result.matrix_bulk_volume_m3, 1);
        @memset(result.layer_volume_m3, 1);
        @memset(result.layer_thickness_m, 1);
        @memset(result.initial_layer_thickness_m, 1);
        @memset(result.layer_midpoint_depth_m, 0.5);
        @memset(result.layer_bottom_depth_m, 1);
        @memset(result.bulk_density_megagrams_per_m3, 1);
        @memset(result.reference_bulk_density_megagrams_per_m3, 1);
        @memset(result.sand_mass_fraction, 0.5);
        @memset(result.silt_mass_fraction, 0.25);
        @memset(result.clay_mass_fraction, 0.25);
        @memset(result.sand_mass_megagrams, 0.5);
        @memset(result.silt_mass_megagrams, 0.25);
        @memset(result.clay_mass_megagrams, 0.25);
        @memset(result.total_organic_carbon_g_per_megagram, 0);
        @memset(result.cation_exchange_capacity_mol_per_megagram, 0);
        @memset(result.anion_exchange_capacity_mol_per_megagram, 0);
        @memset(result.cation_exchange_capacity_mol, 0);
        @memset(result.anion_exchange_capacity_mol, 0);
        @memset(result.porosity_fraction, 0.5);
        @memset(result.micropore_fraction, 1);
        @memset(result.macropore_fraction, 0);
        @memset(result.rock_fraction, 0);
        @memset(result.supplied_field_capacity_fraction, -1);
        @memset(result.supplied_wilting_point_fraction, -1);
        @memset(result.field_capacity_water_potential_megapascal, -0.01);
        @memset(result.wilting_point_water_potential_megapascal, -1.5);
        @memset(result.supplied_vertical_saturated_hydraulic_conductivity_m_per_h, -1);
        @memset(result.supplied_lateral_saturated_hydraulic_conductivity_m_per_h, -1);
        @memset(result.supplied_lateral_conductivity_m2_per_h_megapascal, -1);
        @memset(result.van_genuchten_inflection_pressure_head_m, 0);
        @memset(result.charcoal_retention_increment_fraction, 0);
        @memset(result.previous_charcoal_carbon_g_c, 0);
        @memset(result.field_capacity_fraction, inactive_curve.curve.field_capacity_fraction);
        @memset(result.wilting_point_fraction, inactive_curve.curve.wilting_point_fraction);
        @memset(result.saturation_water_potential_megapascal, inactive_curve.curve.saturation_water_potential_megapascal);
        @memset(result.rainfall_conductivity_multiplier, 1);

        for (catalog_index_by_cell, 0..) |catalog_index, cell| {
            if (catalog_index >= catalog_entries.len) return error.SoilCatalogMapOutOfBounds;
            const entry = &catalog_entries[catalog_index];
            if (entry.profile.total_layer_count != grid.active_soil_layer_count[cell]) return error.SoilLayerCountMismatch;
            const area_m2 = horizontal_cell_width_m[cell] * vertical_cell_width_m[cell];
            var layer_top_depth_m: f64 = 0;
            for (0..entry.profile.total_layer_count) |layer| {
                const index = cell * grid.soil_layer_capacity + layer;
                const curve = try retention.resolve(parameters.retention, .{
                    .porosity_fraction = entry.hydrology_per_m2.total_porosity_fraction[layer],
                    .macropore_fraction = entry.profile.macropore_fraction[layer],
                    .sand_fraction = entry.material.sand_mass_fraction[layer],
                    .clay_fraction = entry.material.clay_mass_fraction[layer],
                    .organic_carbon_g_per_megagram = entry.material.total_organic_carbon_g_per_megagram[layer],
                    .bulk_density_megagrams_per_m3 = entry.material.bulk_density_megagrams_per_m3[layer],
                    .supplied_field_capacity_fraction = supplied(entry.profile.field_capacity_m3_m3[layer]),
                    .supplied_wilting_point_fraction = supplied(entry.profile.wilting_point_m3_m3[layer]),
                }, entry.profile.field_capacity_potential_megapascal, entry.profile.wilting_point_potential_megapascal);
                const texture = try retention.classifyUsdaSoilTexture(
                    entry.material.sand_mass_fraction[layer],
                    entry.material.silt_mass_fraction[layer],
                    entry.material.clay_mass_fraction[layer],
                );
                var mualem_van_genuchten = try retention.carselParrishDefault(
                    texture,
                    curve.porosity_fraction,
                );
                if (entry.profile.vertical_saturated_conductivity_mm_h[layer] >= 0)
                    mualem_van_genuchten.saturated_hydraulic_conductivity_m_per_h =
                        entry.profile.vertical_saturated_conductivity_mm_h[layer] / 1000.0;
                const inflection_pressure_head_m =
                    entry.profile.van_genuchten_inflection_pressure_head_m[layer];
                if (inflection_pressure_head_m < 0) {
                    const fitted = try retention.fitOriginalMualemVanGenuchten(.{
                        .saturated_water_content_m3_per_m3 = curve.porosity_fraction,
                        .field_capacity_water_content_m3_per_m3 = curve.curve.field_capacity_fraction,
                        .field_capacity_pressure_head_m = try mpaToPressureHeadM(
                            entry.profile.field_capacity_potential_megapascal,
                        ),
                        .wilting_point_water_content_m3_per_m3 = curve.curve.wilting_point_fraction,
                        .wilting_point_pressure_head_m = try mpaToPressureHeadM(
                            entry.profile.wilting_point_potential_megapascal,
                        ),
                        .inflection_pressure_head_m = inflection_pressure_head_m,
                        .saturated_hydraulic_conductivity_m_per_h = mualem_van_genuchten.saturated_hydraulic_conductivity_m_per_h,
                    }, .{
                        .maximum_iterations = parameters.mualem_van_genuchten_fit_max_iterations,
                    });
                    mualem_van_genuchten = fitted.parameters;
                }
                // `SOIL-HCOND-AXIS-ISOTROPY-001`. Same unit and fallback
                // convention as the vertical scalar just above: an explicit
                // deck lateral conductivity in mm h-1 converted to m h-1, else
                // the (possibly fitted) vertical scalar, so a deck that never
                // specifies a lateral value keeps today's isotropic behaviour
                // exactly. This mirrors `hour1.f:2197-2221`'s `SCNV`/`SCNH`,
                // which share one fallback formula when either is unknown
                // from the soil file. Deliberately independent of the
                // `estimated_saturated_conductivity`/`lateral_saturated_conductivity`
                // pair immediately below: those remain the intrinsic-area
                // `m2 MPa-1 h-1` `saturated_lateral_conductivity_m2_per_h_megapascal`
                // carrier consumed only by macropore-matrix exchange
                // (`phase_change.zig`'s `macroporeMatrixExchange`), a
                // different physical process from this Richards-face scalar.
                const lateral_hydraulic_conductivity_m_per_h = if (entry.profile.lateral_saturated_conductivity_mm_h[layer] >= 0)
                    entry.profile.lateral_saturated_conductivity_mm_h[layer] / 1000.0
                else
                    mualem_van_genuchten.saturated_hydraulic_conductivity_m_per_h;
                // Conductivity remains an intrinsic m2 MPa-1 h-1 property.
                // Face area is applied exactly once by the flux kernel.
                const estimated_saturated_conductivity = try estimateSaturatedConductivity(parameters, curve, entry.material.total_organic_carbon_g_per_megagram[layer], entry.material.bulk_density_megagrams_per_m3[layer], entry.material.micropore_fraction[layer]);
                // `PR-COND-TABLE-001` note, NOT closed here. The vertical
                // counterpart of this fallback used to exist and fed only the
                // deleted class table, so when the profile withholds a vertical
                // saturated conductivity the estimate never reaches the
                // Mualem-van Genuchten `saturated_hydraulic_conductivity_m_per_h`
                // above: that keeps the Carsel and Parrish texture default. That
                // asymmetry predates this change and is left untouched rather
                // than silently repaired inside a carrier removal. Ottawa ships
                // explicit vertical conductivities, so the branch is not taken
                // on the acceptance deck.
                const lateral_saturated_conductivity = if (entry.profile.lateral_saturated_conductivity_mm_h[layer] < 0)
                    estimated_saturated_conductivity
                else
                    entry.material.lateral_hydraulic_conductivity_m2_per_mpa_h[layer];
                result.retention_curve[index] = curve;
                result.mualem_van_genuchten_parameters[index] =
                    mualem_van_genuchten;
                result.lateral_saturated_hydraulic_conductivity_m_per_h[index] =
                    lateral_hydraulic_conductivity_m_per_h;
                result.clay_mass_fraction[index] = entry.material.clay_mass_fraction[layer];
                result.silt_mass_fraction[index] = entry.material.silt_mass_fraction[layer];
                result.sand_mass_fraction[index] = entry.material.sand_mass_fraction[layer];
                // STARTS/HOUR1 BKVL = BKDS*VOLX and VOLX is the matrix
                // (rock/macropore-excluded) volume. This carrier is shared by
                // texture inventories and CEC/AEC extensive state.
                const matrix_bulk_volume_m3 = entry.hydrology_per_m2.matrix_volume_m3[layer] * area_m2;
                const bulk_soil_mass_megagrams = entry.material.bulk_density_megagrams_per_m3[layer] * matrix_bulk_volume_m3;
                result.sand_mass_megagrams[index] = entry.material.sand_mass_fraction[layer] * bulk_soil_mass_megagrams;
                result.silt_mass_megagrams[index] = entry.material.silt_mass_fraction[layer] * bulk_soil_mass_megagrams;
                result.clay_mass_megagrams[index] = entry.material.clay_mass_fraction[layer] * bulk_soil_mass_megagrams;
                result.total_organic_carbon_g_per_megagram[index] = entry.material.total_organic_carbon_g_per_megagram[layer];
                result.cation_exchange_capacity_mol_per_megagram[index] = entry.material.cation_exchange_capacity_mol_per_megagram[layer];
                result.anion_exchange_capacity_mol_per_megagram[index] = 10.0 * entry.profile.anion_exchange_capacity_cmol_kg[layer];
                result.cation_exchange_capacity_mol[index] = result.cation_exchange_capacity_mol_per_megagram[index] * bulk_soil_mass_megagrams;
                result.anion_exchange_capacity_mol[index] = result.anion_exchange_capacity_mol_per_megagram[index] * bulk_soil_mass_megagrams;
                result.matrix_bulk_volume_m3[index] = matrix_bulk_volume_m3;
                result.layer_volume_m3[index] = entry.hydrology_per_m2.total_layer_volume_m3[layer] * area_m2;
                result.layer_thickness_m[index] = entry.hydrology_per_m2.layer_thickness_m[layer];
                result.initial_layer_thickness_m[index] = entry.hydrology_per_m2.layer_thickness_m[layer];
                result.layer_midpoint_depth_m[index] = layer_top_depth_m + 0.5 * entry.hydrology_per_m2.layer_thickness_m[layer];
                layer_top_depth_m += entry.hydrology_per_m2.layer_thickness_m[layer];
                result.layer_bottom_depth_m[index] = layer_top_depth_m;
                result.bulk_density_megagrams_per_m3[index] = entry.material.bulk_density_megagrams_per_m3[layer];
                result.reference_bulk_density_megagrams_per_m3[index] = entry.material.bulk_density_megagrams_per_m3[layer];
                result.porosity_fraction[index] = curve.porosity_fraction;
                result.micropore_fraction[index] = entry.material.micropore_fraction[layer];
                result.macropore_fraction[index] = entry.profile.macropore_fraction[layer];
                result.rock_fraction[index] = entry.profile.rock_fraction[layer];
                result.supplied_field_capacity_fraction[index] = entry.profile.field_capacity_m3_m3[layer];
                result.supplied_wilting_point_fraction[index] = entry.profile.wilting_point_m3_m3[layer];
                result.field_capacity_water_potential_megapascal[index] = entry.profile.field_capacity_potential_megapascal;
                result.wilting_point_water_potential_megapascal[index] = entry.profile.wilting_point_potential_megapascal;
                result.supplied_vertical_saturated_hydraulic_conductivity_m_per_h[index] = if (entry.profile.vertical_saturated_conductivity_mm_h[layer] >= 0) entry.profile.vertical_saturated_conductivity_mm_h[layer] / 1000.0 else -1;
                result.supplied_lateral_saturated_hydraulic_conductivity_m_per_h[index] = if (entry.profile.lateral_saturated_conductivity_mm_h[layer] >= 0) entry.profile.lateral_saturated_conductivity_mm_h[layer] / 1000.0 else -1;
                result.supplied_lateral_conductivity_m2_per_h_megapascal[index] = if (entry.profile.lateral_saturated_conductivity_mm_h[layer] >= 0) entry.material.lateral_hydraulic_conductivity_m2_per_mpa_h[layer] else -1;
                result.van_genuchten_inflection_pressure_head_m[index] = entry.profile.van_genuchten_inflection_pressure_head_m[layer];
                result.field_capacity_fraction[index] = curve.curve.field_capacity_fraction;
                result.wilting_point_fraction[index] = curve.curve.wilting_point_fraction;
                result.saturation_water_potential_megapascal[index] = curve.curve.saturation_water_potential_megapascal;
                result.saturated_lateral_conductivity_m2_per_h_megapascal[index] = lateral_saturated_conductivity;
            }
        }
        try result.validateFinite();
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64 or field.type == []retention.ResolvedCurve or field.type == []retention.MualemVanGenuchtenParameters) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    pub fn validateFinite(self: *const State) !void {
        for (self.retention_curve) |curve| {
            if (!std.math.isFinite(curve.porosity_fraction) or curve.porosity_fraction <= 0) return error.NonFiniteSoilSolverProperty;
        }
        for (self.mualem_van_genuchten_parameters) |parameters|
            try parameters.validate();
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) for (@field(self, field.name)) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilSolverProperty;
    }

    fn freeAllocated(self: *State, count: usize) void {
        var visited: usize = 0;
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64 or field.type == []retention.ResolvedCurve or field.type == []retention.MualemVanGenuchtenParameters) {
            if (visited < count) self.allocator.free(@field(self, field.name));
            visited += 1;
        };
    }
};

pub const DynamicLayerResolution = struct {
    retention_curve: retention.ResolvedCurve,
    mualem_van_genuchten_parameters: retention.MualemVanGenuchtenParameters,
    lateral_saturated_hydraulic_conductivity_m_per_h: f64,
    saturated_lateral_conductivity_m2_per_h_megapascal: f64,
};

/// Rebuild the constitutive owners from accepted, redistributed material while
/// retaining the profile's supplied-vs-derived decisions. `maximum_iterations`
/// is the already-capped user ceiling, not a target.
pub fn resolveDynamicLayer(
    state: *const State,
    index: usize,
    parameters: RuntimeParameters,
    maximum_iterations: u16,
    porosity_fraction: f64,
    organic_carbon_g_per_megagram: f64,
    bulk_density_megagrams_per_m3: f64,
    sand_mass_fraction: f64,
    silt_mass_fraction: f64,
    clay_mass_fraction: f64,
) !DynamicLayerResolution {
    if (index >= state.layer_count)
        return error.InvalidDynamicSoilLayerResolution;
    return resolveDynamicLayerWithCharcoalIncrement(
        state,
        index,
        parameters,
        maximum_iterations,
        porosity_fraction,
        organic_carbon_g_per_megagram,
        bulk_density_megagrams_per_m3,
        sand_mass_fraction,
        silt_mass_fraction,
        clay_mass_fraction,
        state.charcoal_retention_increment_fraction[index],
    );
}

pub fn resolveDynamicLayerWithCharcoalIncrement(
    state: *const State,
    index: usize,
    parameters: RuntimeParameters,
    maximum_iterations: u16,
    porosity_fraction: f64,
    organic_carbon_g_per_megagram: f64,
    bulk_density_megagrams_per_m3: f64,
    sand_mass_fraction: f64,
    silt_mass_fraction: f64,
    clay_mass_fraction: f64,
    charcoal_increment: f64,
) !DynamicLayerResolution {
    if (index >= state.layer_count or maximum_iterations == 0)
        return error.InvalidDynamicSoilLayerResolution;
    inline for (.{
        porosity_fraction,
        organic_carbon_g_per_megagram,
        bulk_density_megagrams_per_m3,
        sand_mass_fraction,
        silt_mass_fraction,
        clay_mass_fraction,
    }) |value| if (!std.math.isFinite(value))
        return error.InvalidDynamicSoilLayerResolution;
    if (porosity_fraction <= 0 or porosity_fraction > 1 or
        organic_carbon_g_per_megagram < 0 or
        bulk_density_megagrams_per_m3 < 0 or
        sand_mass_fraction < 0 or silt_mass_fraction < 0 or
        clay_mass_fraction < 0)
        return error.InvalidDynamicSoilLayerResolution;

    var curve = try retention.resolve(parameters.retention, .{
        .porosity_fraction = porosity_fraction,
        .macropore_fraction = state.macropore_fraction[index],
        .sand_fraction = sand_mass_fraction,
        .clay_fraction = clay_mass_fraction,
        .organic_carbon_g_per_megagram = organic_carbon_g_per_megagram,
        .bulk_density_megagrams_per_m3 = bulk_density_megagrams_per_m3,
        .supplied_field_capacity_fraction = supplied(state.supplied_field_capacity_fraction[index]),
        .supplied_wilting_point_fraction = supplied(state.supplied_wilting_point_fraction[index]),
    }, state.field_capacity_water_potential_megapascal[index], state.wilting_point_water_potential_megapascal[index]);
    if (!std.math.isFinite(charcoal_increment))
        return error.InvalidDynamicSoilLayerResolution;
    curve.curve.field_capacity_fraction += charcoal_increment;
    curve.curve.wilting_point_fraction += charcoal_increment;
    if (curve.curve.wilting_point_fraction <= 0 or
        curve.curve.field_capacity_fraction <= curve.curve.wilting_point_fraction or
        curve.curve.field_capacity_fraction >= curve.porosity_fraction)
        return error.InvalidDynamicSoilRetentionCurve;

    const texture = try retention.classifyUsdaSoilTexture(
        sand_mass_fraction,
        silt_mass_fraction,
        clay_mass_fraction,
    );
    var mualem = try retention.carselParrishDefault(texture, porosity_fraction);
    if (state.supplied_vertical_saturated_hydraulic_conductivity_m_per_h[index] >= 0)
        mualem.saturated_hydraulic_conductivity_m_per_h =
            state.supplied_vertical_saturated_hydraulic_conductivity_m_per_h[index];
    const fit_budget = @min(
        parameters.mualem_van_genuchten_fit_max_iterations,
        maximum_iterations,
    );
    if (fit_budget == 0) return error.InvalidDynamicSoilLayerResolution;
    const inflection = state.van_genuchten_inflection_pressure_head_m[index];
    if (inflection < 0) {
        const fitted = try retention.fitOriginalMualemVanGenuchten(.{
            .saturated_water_content_m3_per_m3 = porosity_fraction,
            .field_capacity_water_content_m3_per_m3 = curve.curve.field_capacity_fraction,
            .field_capacity_pressure_head_m = try mpaToPressureHeadM(state.field_capacity_water_potential_megapascal[index]),
            .wilting_point_water_content_m3_per_m3 = curve.curve.wilting_point_fraction,
            .wilting_point_pressure_head_m = try mpaToPressureHeadM(state.wilting_point_water_potential_megapascal[index]),
            .inflection_pressure_head_m = inflection,
            .saturated_hydraulic_conductivity_m_per_h = mualem.saturated_hydraulic_conductivity_m_per_h,
        }, .{ .maximum_iterations = fit_budget });
        mualem = fitted.parameters;
    }
    const lateral_hydraulic = if (state.supplied_lateral_saturated_hydraulic_conductivity_m_per_h[index] >= 0)
        state.supplied_lateral_saturated_hydraulic_conductivity_m_per_h[index]
    else
        mualem.saturated_hydraulic_conductivity_m_per_h;
    const estimated_lateral = try estimateSaturatedConductivity(
        parameters,
        curve,
        organic_carbon_g_per_megagram,
        bulk_density_megagrams_per_m3,
        state.micropore_fraction[index],
    );
    const lateral_intrinsic = if (state.supplied_lateral_conductivity_m2_per_h_megapascal[index] >= 0)
        state.supplied_lateral_conductivity_m2_per_h_megapascal[index]
    else
        estimated_lateral;
    return .{
        .retention_curve = curve,
        .mualem_van_genuchten_parameters = mualem,
        .lateral_saturated_hydraulic_conductivity_m_per_h = lateral_hydraulic,
        .saturated_lateral_conductivity_m2_per_h_megapascal = lateral_intrinsic,
    };
}

pub fn estimateSaturatedConductivity(parameters: RuntimeParameters, curve: retention.ResolvedCurve, organic_carbon_g_per_megagram: f64, bulk_density_megagrams_per_m3: f64, micropore_fraction: f64) !f64 {
    inline for (.{ parameters.mineral_saturated_conductivity_scale_m2_per_h_megapascal, parameters.mineral_reference_water_potential_mpa_magnitude, parameters.organic_saturated_conductivity_intercept_m2_per_h_megapascal, parameters.organic_saturated_conductivity_scale_m2_per_h_megapascal, parameters.organic_saturated_conductivity_bulk_density_base, organic_carbon_g_per_megagram, bulk_density_megagrams_per_m3, micropore_fraction }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSaturatedConductivityInput;
    if (parameters.mineral_saturated_conductivity_scale_m2_per_h_megapascal < 0 or parameters.mineral_reference_water_potential_mpa_magnitude <= 0 or parameters.organic_saturated_conductivity_intercept_m2_per_h_megapascal < 0 or parameters.organic_saturated_conductivity_scale_m2_per_h_megapascal < 0 or parameters.organic_saturated_conductivity_bulk_density_base <= 0 or organic_carbon_g_per_megagram < 0 or bulk_density_megagrams_per_m3 < 0 or micropore_fraction < 0 or micropore_fraction > 1) return error.InvalidSaturatedConductivityInput;
    const value = if (organic_carbon_g_per_megagram < parameters.retention.organic_soil_threshold_g_per_megagram) mineral: {
        const porosity = curve.porosity_fraction;
        const field_capacity = curve.curve.field_capacity_fraction;
        const log_saturation_potential = @log(-curve.curve.saturation_water_potential_megapascal);
        const log_field_potential = @log(-curve.curve.field_capacity_water_potential_megapascal);
        const water_at_reference = @min(porosity, @exp(
            (log_saturation_potential - @log(parameters.mineral_reference_water_potential_mpa_magnitude)) *
                (@log(porosity) - @log(field_capacity)) /
                (log_field_potential - log_saturation_potential) +
                @log(porosity),
        ));
        break :mineral parameters.mineral_saturated_conductivity_scale_m2_per_h_megapascal * std.math.pow(f64, (porosity - water_at_reference) / water_at_reference, 2);
    } else (parameters.organic_saturated_conductivity_intercept_m2_per_h_megapascal +
        parameters.organic_saturated_conductivity_scale_m2_per_h_megapascal *
            std.math.pow(f64, parameters.organic_saturated_conductivity_bulk_density_base, bulk_density_megagrams_per_m3)) *
        micropore_fraction;
    if (!std.math.isFinite(value) or value < 0) return error.InvalidResolvedSaturatedConductivity;
    return value;
}

fn supplied(value: f64) ?f64 {
    return if (value >= 0) value else null;
}

pub fn mpaToPressureHeadM(water_potential_megapascal: f64) !f64 {
    if (!std.math.isFinite(water_potential_megapascal) or water_potential_megapascal >= 0)
        return error.InvalidSoilWaterPotential;
    const water_density_kg_per_m3 = 1000.0;
    const gravitational_acceleration_m_per_s2 = 9.80665;
    const pressure_head_m =
        water_potential_megapascal * 1_000_000.0 /
        (water_density_kg_per_m3 * gravitational_acceleration_m_per_s2);
    if (!std.math.isFinite(pressure_head_m) or pressure_head_m >= 0)
        return error.InvalidSoilWaterPotential;
    return pressure_head_m;
}

test "mapped solver properties use runtime dimensions classes and profile science" {
    const allocator = std.testing.allocator;
    const source = try @import("../../core/test_fixtures.zig").soilProfileSource(allocator, @typeInfo(@import("../../state/soil_profile.zig").LayerProperty).@"enum".fields.len);
    defer allocator.free(source);
    var catalog = catalog_module.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("soil", source, compatibilityParameters().retention, compatibilityParameters().profile_derivation);
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = catalog.entries.items[0].profile.total_layer_count, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(allocator, cfg);
    defer grid.deinit();
    try @import("../../driver/model_initialization.zig").initializeCellHydrology(&grid, 0, catalog.entries.items[0].hydrology_per_m2);
    var parameters = compatibilityParameters();
    parameters.hydraulic_conductivity_class_count = 37;
    catalog.entries.items[0].profile.vertical_saturated_conductivity_mm_h[0] = -1;
    catalog.entries.items[0].material.vertical_hydraulic_conductivity_m2_per_mpa_h[0] = -1;
    var state = try State.initMapped(allocator, &grid, catalog.entries.items, &.{0}, &.{1}, &.{1}, parameters);
    defer state.deinit();
    try std.testing.expectEqual(grid.layer_count, state.saturated_lateral_conductivity_m2_per_h_megapascal.len);
    try std.testing.expect(state.matrix_bulk_volume_m3[0] > 0);
    const entry = catalog.entries.items[0];
    const bulk_soil_mass_megagrams = entry.material.bulk_density_megagrams_per_m3[0] * entry.hydrology_per_m2.matrix_volume_m3[0];
    try std.testing.expectApproxEqAbs(entry.material.sand_mass_fraction[0] * bulk_soil_mass_megagrams, state.sand_mass_megagrams[0], 1e-14);
    try std.testing.expectApproxEqAbs(entry.material.silt_mass_fraction[0] * bulk_soil_mass_megagrams, state.silt_mass_megagrams[0], 1e-14);
    try std.testing.expectApproxEqAbs(entry.material.clay_mass_fraction[0] * bulk_soil_mass_megagrams, state.clay_mass_megagrams[0], 1e-14);
    try std.testing.expectApproxEqAbs(state.cation_exchange_capacity_mol_per_megagram[0] * bulk_soil_mass_megagrams, state.cation_exchange_capacity_mol[0], 1e-14);
    try std.testing.expectApproxEqAbs(state.anion_exchange_capacity_mol_per_megagram[0] * bulk_soil_mass_megagrams, state.anion_exchange_capacity_mol[0], 1e-14);
    try std.testing.expect(state.saturated_lateral_conductivity_m2_per_h_megapascal[0] > 0);
    // PR-COND-TABLE-001: the per-layer lateral saturated conductivity is the
    // profile value verbatim, with no class-table offset applied. The old path
    // reached the same number only because the Ottawa deck ships JK = 100.
    try std.testing.expectEqual(entry.material.lateral_hydraulic_conductivity_m2_per_mpa_h[0], state.saturated_lateral_conductivity_m2_per_h_megapascal[0]);
    try std.testing.expectApproxEqAbs(0.5 * state.layer_thickness_m[0], state.layer_midpoint_depth_m[0], 1e-15);
    for (1..grid.active_soil_layer_count[0]) |layer| {
        try std.testing.expectApproxEqAbs(state.layer_bottom_depth_m[layer - 1] + 0.5 * state.layer_thickness_m[layer], state.layer_midpoint_depth_m[layer], 1e-15);
        try std.testing.expectApproxEqAbs(state.layer_bottom_depth_m[layer - 1] + state.layer_thickness_m[layer], state.layer_bottom_depth_m[layer], 1e-15);
    }
}

test "SOIL-HCOND-AXIS-ISOTROPY-001: lateral Mualem saturated conductivity is independent of vertical, with isotropic fallback" {
    // Mirrors `ecosys_f77/hour1.f:2197-2221`'s `SCNV`/`SCNH` split: both are
    // parsed independently from the soil file, and each falls back
    // (`ISOIL(3|4,...)`) to the same estimate formula only when its own value
    // is unknown, not the other axis's.
    const allocator = std.testing.allocator;
    const source = try @import("../../core/test_fixtures.zig").soilProfileSource(allocator, @typeInfo(@import("../../state/soil_profile.zig").LayerProperty).@"enum".fields.len);
    defer allocator.free(source);
    var catalog = catalog_module.Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("soil", source, compatibilityParameters().retention, compatibilityParameters().profile_derivation);
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = catalog.entries.items[0].profile.total_layer_count, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(allocator, cfg);
    defer grid.deinit();
    try @import("../../driver/model_initialization.zig").initializeCellHydrology(&grid, 0, catalog.entries.items[0].hydrology_per_m2);
    const parameters = compatibilityParameters();
    catalog.entries.items[0].profile.vertical_saturated_conductivity_mm_h[0] = 10;
    catalog.entries.items[0].profile.lateral_saturated_conductivity_mm_h[0] = 40;
    var anisotropic_state = try State.initMapped(allocator, &grid, catalog.entries.items, &.{0}, &.{1}, &.{1}, parameters);
    defer anisotropic_state.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), anisotropic_state.mualem_van_genuchten_parameters[0].saturated_hydraulic_conductivity_m_per_h, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.04), anisotropic_state.lateral_saturated_hydraulic_conductivity_m_per_h[0], 1e-15);

    // Withholding the lateral value (the deck sentinel, `< 0`) keeps today's
    // pre-`SOIL-HCOND-AXIS-ISOTROPY-001` isotropic behaviour exactly: the
    // lateral scalar defaults to the vertical one.
    catalog.entries.items[0].profile.lateral_saturated_conductivity_mm_h[0] = -1;
    var isotropic_state = try State.initMapped(allocator, &grid, catalog.entries.items, &.{0}, &.{1}, &.{1}, parameters);
    defer isotropic_state.deinit();
    try std.testing.expectEqual(
        isotropic_state.mualem_van_genuchten_parameters[0].saturated_hydraulic_conductivity_m_per_h,
        isotropic_state.lateral_saturated_hydraulic_conductivity_m_per_h[0],
    );
}

test "HOUR1 missing saturated conductivity uses mineral and organic equations" {
    const parameters = compatibilityParameters();
    const mineral_curve = try retention.resolve(parameters.retention, .{
        .porosity_fraction = 0.5,
        .macropore_fraction = 0,
        .sand_fraction = 0.4,
        .clay_fraction = 0.2,
        .organic_carbon_g_per_megagram = 10_000,
        .bulk_density_megagrams_per_m3 = 1.3,
        .supplied_field_capacity_fraction = 0.25,
        .supplied_wilting_point_fraction = 0.1,
    }, -0.033, -1.5);
    const mineral = try estimateSaturatedConductivity(parameters, mineral_curve, 10_000, 1.3, 0.9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.54), mineral, 1.0e-12);

    const organic = try estimateSaturatedConductivity(parameters, mineral_curve, 300_000, 0.1, 0.8);
    const expected = (0.10 + 75.0 * std.math.pow(f64, 1.0e-15, 0.1)) * 0.8;
    try std.testing.expectApproxEqAbs(expected, organic, 1.0e-12);
}
