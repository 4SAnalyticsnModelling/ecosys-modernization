//! `solver` declarations: validation.
//!
//! Split out of `solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const grid_module = @import("../../state/grid.zig");
const heat = @import("flux.zig");
const transport_hydrology = @import("../../transport/hydrology.zig");
const numerics = @import("../../core/numerics.zig");
const boundary_topology_module = @import("../profile/boundary_topology.zig");
const water_boundary = @import("../water/boundary.zig");
const enthalpy = @import("../water/enthalpy_balance.zig");
const retention = @import("../water/retention.zig");
const group_types = @import("solver_types.zig");

pub const minimum_physical_temperature_k: f64 = 173.15;
pub const maximum_physical_temperature_k: f64 = 373.15;

pub fn isPhysicalTemperatureK(temperature_k: f64) bool {
    return std.math.isFinite(temperature_k) and
        temperature_k >= minimum_physical_temperature_k and
        temperature_k <= maximum_physical_temperature_k;
}

pub fn validateSoilTemperaturePhysicalDomain(temperature_k: []const f64) !void {
    for (temperature_k) |value|
        if (!isPhysicalTemperatureK(value))
            return error.SoilHeatSolverTemperatureOutsidePhysicalDomain;
}

pub fn validateInputs(grid: *const grid_module.GridState, faces: []const group_types.Face, properties: group_types.Properties, water_fluxes: group_types.WaterHeatFluxes, heat_flux_megajoules: []const f64, options: group_types.Options) !void {
    const cells = grid.layer_count;
    try validateSoilTemperaturePhysicalDomain(grid.soil_temperature_k);
    inline for (@typeInfo(group_types.Properties).@"struct".fields) |field| {
        if (field.type == []const f64 and @field(properties, field.name).len != cells) return error.SoilHeatSolverDimensionMismatch;
        if (field.type == []const bool and @field(properties, field.name).len != 0 and @field(properties, field.name).len != cells) return error.SoilHeatSolverDimensionMismatch;
    }
    if (water_fluxes.liquid_water_m3.len != faces.len or water_fluxes.vapor_m3.len != faces.len or water_fluxes.macropore_water_m3.len != faces.len or heat_flux_megajoules.len != faces.len) return error.SoilHeatSolverDimensionMismatch;
    if (properties.geothermal_boundary) |geothermal| {
        if (geothermal.layer_bottom_depth_m.len != cells or geothermal.lower_face_area_m2.len != cells or geothermal.enabled_by_cell.len != geothermal.topology.water_table_mode.len or geothermal.mean_annual_temperature_k_by_cell.len != geothermal.topology.water_table_mode.len or !std.math.isFinite(geothermal.minimum_source_depth_m) or geothermal.minimum_source_depth_m <= 0 or !std.math.isFinite(geothermal.source_depth_below_profile_m) or geothermal.source_depth_below_profile_m <= 0 or !std.math.isFinite(geothermal.conductivity_m_megajoules_per_h_k) or geothermal.conductivity_m_megajoules_per_h_k <= 0 or !std.math.isFinite(geothermal.geothermal_flux_megajoules_per_m2_h)) return error.InvalidGeothermalBoundary;
        for (geothermal.mean_annual_temperature_k_by_cell) |temperature_k| if (!std.math.isFinite(temperature_k) or temperature_k <= 0) return error.InvalidGeothermalBoundary;
    }
    if (properties.dirichlet_thermal_boundaries) |boundaries| {
        const boundary_count = boundaries.cell_index.len;
        if (boundaries.temperature_k.len != boundary_count or
            boundaries.distance_from_cell_center_m.len != boundary_count or
            boundaries.face_area_m2.len != boundary_count)
            return error.SoilHeatBoundaryDimensionMismatch;
        for (boundaries.cell_index, boundaries.temperature_k, boundaries.distance_from_cell_center_m, boundaries.face_area_m2) |cell, temperature_k, distance_m, face_area_m2| {
            if (cell >= cells or
                !std.math.isFinite(temperature_k) or temperature_k <= 0 or
                !std.math.isFinite(distance_m) or distance_m <= 0 or
                !std.math.isFinite(face_area_m2) or face_area_m2 < 0)
                return error.InvalidDirichletSoilHeatBoundary;
        }
    }
    if (properties.enthalpy_coupling) |coupling| {
        inline for (.{
            coupling.matrix_liquid_water_m3,
            coupling.matrix_ice_water_equivalent_m3,
            coupling.porous_medium_volume_m3,
        }) |values| if (values.len != cells)
            return error.SoilHeatSolverDimensionMismatch;
        if (coupling.unfrozen_pressure_head_m.len != 0 and
            coupling.unfrozen_pressure_head_m.len != cells)
            return error.SoilHeatSolverDimensionMismatch;
        if (coupling.matrix_pore_capacity_m3.len != 0 and
            coupling.matrix_pore_capacity_m3.len != cells)
            return error.SoilHeatSolverDimensionMismatch;
        if (coupling.mualem_van_genuchten.len != cells)
            return error.SoilHeatSolverDimensionMismatch;
        if (coupling.conservation_cell_area_m2.len != 0 and
            coupling.conservation_cell_area_m2.len != cells)
            return error.SoilHeatSolverDimensionMismatch;
        if (!std.math.isFinite(coupling.conservation_absolute_tolerance_megajoules_per_m2) or
            coupling.conservation_absolute_tolerance_megajoules_per_m2 < 0 or
            !std.math.isFinite(coupling.conservation_relative_tolerance) or
            coupling.conservation_relative_tolerance < 0)
            return error.InvalidSoilHeatConservationTolerance;
        for (coupling.conservation_cell_area_m2) |area_m2|
            if (!std.math.isFinite(area_m2) or area_m2 < 0)
                return error.InvalidSoilHeatConservationCellArea;
        const macropore_enabled =
            coupling.macropore_mualem_van_genuchten.len != 0;
        if (macropore_enabled) {
            inline for (.{
                coupling.macropore_liquid_water_m3,
                coupling.macropore_ice_water_equivalent_m3,
                coupling.macropore_porous_medium_volume_m3,
            }) |values| if (values.len != cells)
                return error.SoilHeatSolverDimensionMismatch;
            if (coupling.macropore_mualem_van_genuchten.len != cells or
                (coupling.macropore_unfrozen_pressure_head_m.len != 0 and
                    coupling.macropore_unfrozen_pressure_head_m.len != cells))
                return error.SoilHeatSolverDimensionMismatch;
            for (coupling.macropore_mualem_van_genuchten) |parameters|
                try parameters.validate();
        } else if (coupling.macropore_liquid_water_m3.len != 0 or
            coupling.macropore_ice_water_equivalent_m3.len != 0 or
            coupling.macropore_porous_medium_volume_m3.len != 0 or
            coupling.macropore_unfrozen_pressure_head_m.len != 0)
            return error.IncompleteSoilHeatMacroporeEnthalpyCoupling;
        inline for (.{
            coupling.gravitational_water_potential_mpa_per_m,
            coupling.pure_water_melting_temperature_k,
            coupling.ice_water_equivalent_heat_capacity_megajoules_per_m3_k,
            coupling.latent_heat_of_fusion_megajoules_per_m3,
        }) |value| if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidSoilHeatEnthalpyCoupling;
        if (!std.math.isFinite(coupling.ice_density_megagrams_per_m3) or
            coupling.ice_density_megagrams_per_m3 <= 0 or
            coupling.ice_density_megagrams_per_m3 >= 1)
            return error.InvalidSoilHeatEnthalpyCoupling;
        for (coupling.mualem_van_genuchten) |parameters|
            try parameters.validate();
    }
    if (!std.math.isFinite(properties.liquid_water_heat_capacity_megajoules_per_m3_k) or properties.liquid_water_heat_capacity_megajoules_per_m3_k <= 0) return error.InvalidSoilHeatCapacity;
    if (!std.math.isFinite(properties.time_step_hours) or
        properties.time_step_hours <= 0 or properties.time_step_hours > 1)
        return error.InvalidSoilHeatTimeStep;
    if (!options.anderson_recovery or options.max_iterations == 0 or options.directional_newton_max_line_search_steps == 0 or options.topology_newton_max_line_search_steps == 0 or !std.math.isFinite(options.absolute_tolerance_k) or options.absolute_tolerance_k <= 0 or !std.math.isFinite(options.relative_tolerance) or options.relative_tolerance <= 0 or !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or !std.math.isFinite(options.directional_probe_fraction) or options.directional_probe_fraction <= 0 or !std.math.isFinite(options.minimum_newton_fraction) or options.minimum_newton_fraction <= 0 or !std.math.isFinite(options.maximum_newton_fraction) or options.maximum_newton_fraction < options.minimum_newton_fraction) return error.InvalidSoilHeatSolverOptions;
    for (0..cells) |cell| if (!std.math.isFinite(properties.heat_capacity_megajoules_per_k[cell]) or properties.heat_capacity_megajoules_per_k[cell] <= 0) return error.InvalidSoilHeatCapacity;
    for (faces) |face| if (face.source_cell >= cells or face.destination_cell >= cells or face.source_cell == face.destination_cell or !std.math.isFinite(face.source_path_length_m) or face.source_path_length_m <= 0 or !std.math.isFinite(face.destination_path_length_m) or face.destination_path_length_m <= 0 or !std.math.isFinite(face.face_area_m2) or face.face_area_m2 < 0) return error.InvalidSoilHeatFace;
}
