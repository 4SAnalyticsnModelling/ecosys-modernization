const std = @import("std");
const builtin = @import("builtin");
const Grid = @import("../../state/grid.zig").GridState;
const Geometry = @import("layer_geometry.zig").State;
const SoilOrganic = @import("../organic/initialization.zig").State;
const SoilPropertiesModule = @import("../water/solver_properties.zig");
const SoilProperties = SoilPropertiesModule.State;
const SoilThermal = @import("../heat/thermal.zig").State;
const initialization = @import("initialization.zig");
const charcoal_adjustment = @import("../../management/charcoal_soil_property_adjustment.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    grid: *Grid,
    geometry: *const Geometry,
    soil_organic: *const SoilOrganic,
    properties: *SoilProperties,
    thermal: *SoilThermal,
    parameters: SoilPropertiesModule.RuntimeParameters,
    /// User/scene hard ceiling. Runtime fitting uses the lesser of this and
    /// the soil-profile fit ceiling and still stops as soon as it converges.
    maximum_iterations: u16,
    ice_density_megagrams_per_m3: f64 = 0.917,
    cation_exchange_capacity_delta_mol_by_cell: ?[]f64 = null,
    anion_exchange_capacity_delta_mol_by_cell: ?[]f64 = null,
    /// Exact layer-resolved HOUR1 DORGCC exchange-site changes. These are the
    /// authoritative local-scope producer values; the cell arrays above are
    /// their horizontal reduction for the existing per-cell gate.
    cation_exchange_capacity_delta_mol_by_layer: ?[]f64 = null,
    anion_exchange_capacity_delta_mol_by_layer: ?[]f64 = null,
};

const Candidate = struct {
    index: usize,
    bulk_density_megagrams_per_m3: f64,
    sand_mass_fraction: f64,
    silt_mass_fraction: f64,
    clay_mass_fraction: f64,
    organic_carbon_g_per_megagram: f64,
    porosity_fraction: f64,
    matrix_pore_capacity_m3: f64,
    matrix_air_volume_m3: f64,
    macropore_air_volume_m3: f64,
    total_air_volume_m3: f64,
    thermal_porosity_fraction: f64,
    solid_thermal_conductivity_numerator_m_megajoules_per_h_k: f64,
    solid_thermal_conductivity_denominator: f64,
    hydraulic: SoilPropertiesModule.DynamicLayerResolution,
    charcoal_carbon_g_c: f64,
    charcoal_retention_increment_fraction: f64,
    cation_exchange_capacity_mol_per_megagram: f64,
    anion_exchange_capacity_mol_per_megagram: f64,
    cation_exchange_capacity_mol: f64,
    anion_exchange_capacity_mol: f64,
    cation_exchange_capacity_delta_mol: f64,
    anion_exchange_capacity_delta_mol: f64,
};

/// Source-shaped HOUR1 3656--3715 material refresh. Every candidate is built
/// and validated before the first owner write, so a failure leaves all
/// properties, pore/air geometry and thermal caches byte-for-byte unchanged.
pub fn refreshAcceptedHour(context: *const Context) !usize {
    try validateDimensions(context);
    if (context.maximum_iterations == 0)
        return error.NoRuntimeMaterialRefreshIterations;
    var staged = try context.allocator.alloc(Candidate, context.properties.layer_count);
    defer context.allocator.free(staged);
    var count: usize = 0;
    if (context.cation_exchange_capacity_delta_mol_by_cell) |values| @memset(values, 0);
    if (context.anion_exchange_capacity_delta_mol_by_cell) |values| @memset(values, 0);
    if (context.cation_exchange_capacity_delta_mol_by_layer) |values| @memset(values, 0);
    if (context.anion_exchange_capacity_delta_mol_by_layer) |values| @memset(values, 0);

    for (0..context.geometry.cell_count) |cell| {
        const first = context.geometry.first_active_layer[cell];
        const active = context.geometry.active_layer_count[cell];
        if (active == 0 or first > context.geometry.layer_capacity or
            active > context.geometry.layer_capacity - first)
            return error.InvalidRuntimeMaterialActiveLayers;
        const base = cell * context.geometry.layer_capacity;
        for (0..active) |offset| {
            const index = base + first + offset;
            const matrix_volume = context.properties.matrix_bulk_volume_m3[index];
            const sand_mass = context.properties.sand_mass_megagrams[index];
            const silt_mass = context.properties.silt_mass_megagrams[index];
            const clay_mass = context.properties.clay_mass_megagrams[index];
            inline for (.{ matrix_volume, sand_mass, silt_mass, clay_mass }) |value|
                if (!std.math.isFinite(value) or value < 0) {
                    if (!builtin.is_test) std.log.err(
                        "invalid runtime soil carrier: cell={d} layer={d} index={d} matrix_volume_m3={e} sand_mass_megagrams={e} silt_mass_megagrams={e} clay_mass_megagrams={e}",
                        .{ cell, first + offset, index, matrix_volume, sand_mass, silt_mass, clay_mass },
                    );
                    return error.InvalidRuntimeSoilMaterial;
                };
            const bulk_density = context.properties.bulk_density_megagrams_per_m3[index];
            if (!std.math.isFinite(bulk_density) or bulk_density < 0 or
                matrix_volume <= 0)
            {
                if (!builtin.is_test) std.log.err(
                    "invalid runtime soil bulk geometry: cell={d} layer={d} index={d} matrix_volume_m3={e} bulk_density_megagrams_per_m3={e}",
                    .{ cell, first + offset, index, matrix_volume, bulk_density },
                );
                return error.InvalidRuntimeSoilMaterial;
            }
            // BKDS == 0 is the source's open-water layer. It has no mineral
            // carrier on which to rebuild texture, CEC/AEC, porosity or soil
            // hydraulics. Preserve every initialized open-water owner exactly;
            // settling and aqueous science still use the active slot.
            if (bulk_density == 0) continue;
            // HOUR1's authoritative carrier is BKVL=BKDS*VOLX. Mineral
            // inventories need not sum to BKVL because organic matter is a
            // separate constituent; BKDS remains the live physical owner.
            const soil_mass = bulk_density * matrix_volume;
            if (!std.math.isFinite(soil_mass) or soil_mass <= 0) {
                if (!builtin.is_test) std.log.err(
                    "invalid runtime soil mass: cell={d} layer={d} index={d} matrix_volume_m3={e} bulk_density_megagrams_per_m3={e} soil_mass_megagrams={e}",
                    .{ cell, first + offset, index, matrix_volume, bulk_density, soil_mass },
                );
                return error.InvalidRuntimeSoilMaterial;
            }
            const organic_carbon_g_c = try context.soil_organic.totalCarbon_g_c(index);
            if (!std.math.isFinite(organic_carbon_g_c) or organic_carbon_g_c < 0) {
                if (!builtin.is_test) std.log.err(
                    "invalid runtime soil organic carbon: cell={d} layer={d} index={d} organic_carbon_g_c={e}",
                    .{ cell, first + offset, index, organic_carbon_g_c },
                );
                return error.InvalidRuntimeSoilMaterial;
            }
            // CORGC is capped exactly as HOUR1 to keep the organic particle-
            // density mixture inside its source domain.
            const organic_concentration = @min(0.55e6, organic_carbon_g_c / soil_mass);
            const sand_fraction = sand_mass / soil_mass;
            const silt_fraction = silt_mass / soil_mass;
            const clay_fraction = clay_mass / soil_mass;
            const mineral_fraction = sand_fraction + silt_fraction + clay_fraction;
            if (!std.math.isFinite(mineral_fraction) or mineral_fraction <= 0) {
                if (!builtin.is_test) std.log.err(
                    "invalid runtime soil mineral fraction: cell={d} layer={d} index={d} soil_mass_megagrams={e} sand_fraction={e} silt_fraction={e} clay_fraction={e} mineral_fraction={e}",
                    .{ cell, first + offset, index, soil_mass, sand_fraction, silt_fraction, clay_fraction, mineral_fraction },
                );
                return error.InvalidRuntimeSoilMaterial;
            }
            const solid = initialization.solidThermalTerms(.{
                .organic_carbon_g_per_megagram = organic_concentration,
                .bulk_density_megagrams_per_m3 = bulk_density,
                .silt_mass_fraction = silt_fraction,
                .clay_mass_fraction = clay_fraction,
                .sand_mass_fraction = sand_fraction,
                .micropore_fraction = context.properties.micropore_fraction[index],
                .rock_fraction = context.properties.rock_fraction[index],
            });
            var porosity = 1.0 - bulk_density / solid.particle_density_megagrams_per_m3;
            if (offset == 0) {
                // Surface incorporation publishes structural pore capacity and
                // matrix geometry before the following HOUR1 constitutive
                // refresh. Read that authoritative accepted geometry directly;
                // `properties.porosity_fraction` is intentionally still the
                // coherent prior-hour retention/Mualem mirror at this boundary.
                const structural_porosity = context.grid.matrix_pore_capacity_m3[index] / matrix_volume;
                if (!std.math.isFinite(structural_porosity) or
                    structural_porosity < 0 or structural_porosity > 1)
                    return error.InvalidRuntimeSoilPorosity;
                porosity = @max(structural_porosity, porosity);
            }
            if (!std.math.isFinite(porosity) or porosity <= 0 or porosity > 1)
                return error.InvalidRuntimeSoilPorosity;
            const charcoal_carbon_g_c = try context.soil_organic.charcoalCarbon_g_c(index);
            const previous_charcoal_g_c = context.properties.previous_charcoal_carbon_g_c[index];
            if (!std.math.isFinite(previous_charcoal_g_c) or previous_charcoal_g_c < 0) {
                if (!builtin.is_test) std.log.err(
                    "invalid runtime soil charcoal snapshot: cell={d} layer={d} index={d} previous_charcoal_g_c={e}",
                    .{ cell, first + offset, index, previous_charcoal_g_c },
                );
                return error.InvalidRuntimeSoilMaterial;
            }
            const signed_charcoal_delta_g_c = charcoal_carbon_g_c - previous_charcoal_g_c;
            const signed_property_delta = try charcoal_adjustment.signedDeltas(
                signed_charcoal_delta_g_c,
                matrix_volume,
                0,
            );
            const signed_retention_delta = signed_property_delta.retention_fraction;
            const supplied_retention = context.properties.supplied_field_capacity_fraction[index] >= 0 and
                context.properties.supplied_wilting_point_fraction[index] >= 0;
            const charcoal_retention_increment = if (supplied_retention)
                context.properties.charcoal_retention_increment_fraction[index] + signed_retention_delta
            else
                signed_retention_delta;
            const hydraulic = try SoilPropertiesModule.resolveDynamicLayerWithCharcoalIncrement(
                context.properties,
                index,
                context.parameters,
                context.maximum_iterations,
                porosity,
                organic_concentration,
                bulk_density,
                sand_fraction,
                silt_fraction,
                clay_fraction,
                charcoal_retention_increment,
            );
            const cec_per_megagram = context.properties.cation_exchange_capacity_mol_per_megagram[index] +
                signed_property_delta.exchange_capacity_mol_per_megagram;
            const aec_per_megagram = context.properties.anion_exchange_capacity_mol_per_megagram[index] +
                signed_property_delta.exchange_capacity_mol_per_megagram;
            const cec_mol = cec_per_megagram * soil_mass;
            const aec_mol = aec_per_megagram * soil_mass;
            const cec_delta_mol = cec_mol - context.properties.cation_exchange_capacity_mol[index];
            const aec_delta_mol = aec_mol - context.properties.anion_exchange_capacity_mol[index];
            inline for (.{ charcoal_carbon_g_c, signed_charcoal_delta_g_c, charcoal_retention_increment, cec_per_megagram, aec_per_megagram, cec_mol, aec_mol, cec_delta_mol, aec_delta_mol }) |value|
                if (!std.math.isFinite(value)) {
                    if (!builtin.is_test) std.log.err(
                        "nonfinite runtime soil charcoal/exchange state: cell={d} layer={d} index={d} charcoal_carbon_g_c={e} signed_charcoal_delta_g_c={e} charcoal_retention_increment_fraction={e} cec_mol_per_megagram={e} aec_mol_per_megagram={e} cec_mol={e} aec_mol={e} cec_delta_mol={e} aec_delta_mol={e}",
                        .{ cell, first + offset, index, charcoal_carbon_g_c, signed_charcoal_delta_g_c, charcoal_retention_increment, cec_per_megagram, aec_per_megagram, cec_mol, aec_mol, cec_delta_mol, aec_delta_mol },
                    );
                    return error.InvalidRuntimeSoilMaterial;
                };
            if (charcoal_carbon_g_c < 0 or cec_per_megagram < 0 or aec_per_megagram < 0 or cec_mol < 0 or aec_mol < 0) {
                if (!builtin.is_test) std.log.err(
                    "negative runtime soil charcoal/exchange state: cell={d} layer={d} index={d} charcoal_carbon_g_c={e} cec_mol_per_megagram={e} aec_mol_per_megagram={e} cec_mol={e} aec_mol={e}",
                    .{ cell, first + offset, index, charcoal_carbon_g_c, cec_per_megagram, aec_per_megagram, cec_mol, aec_mol },
                );
                return error.InvalidRuntimeSoilMaterial;
            }
            const matrix_capacity = porosity * matrix_volume;
            const matrix_occupied = context.grid.matrix_liquid_water_m3[index] +
                context.grid.matrix_ice_water_m3[index] / context.ice_density_megagrams_per_m3;
            const previous_matrix_capacity = context.grid.matrix_pore_capacity_m3[index];
            const macro_capacity = context.grid.macropore_pore_capacity_m3[index];
            const macro_occupied = context.grid.macropore_liquid_water_m3[index] +
                context.grid.macropore_ice_water_m3[index] / context.ice_density_megagrams_per_m3;
            inline for (.{ matrix_capacity, matrix_occupied, previous_matrix_capacity, macro_capacity, macro_occupied }) |value|
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidRuntimeSoilPoreState;
            const matrix_entry_scale = @max(1, @max(previous_matrix_capacity, matrix_occupied));
            const macro_entry_scale = @max(1, @max(macro_capacity, macro_occupied));
            const matrix_entry_roundoff = 128 * std.math.floatEps(f64) * matrix_entry_scale;
            const macro_entry_roundoff = 128 * std.math.floatEps(f64) * macro_entry_scale;
            // The accepted entry state must fit the capacity owned by the
            // preceding hour. A smaller capacity derived immediately above is
            // different: HOUR1 3604--3606 clamps only the derived air carrier,
            // then 3704--3715 publishes the smaller VOLA without deleting or
            // relocating water. The following WATSUB vertical displacement
            // path owns that conservative transfer.
            if (matrix_occupied > previous_matrix_capacity + matrix_entry_roundoff or
                macro_occupied > macro_capacity + macro_entry_roundoff)
            {
                if (!builtin.is_test) std.log.err(
                    "runtime soil entry pore capacity exceeded: cell={d} layer={d} index={d} previous_matrix_capacity_m3={e} refreshed_matrix_capacity_m3={e} matrix_occupied_m3={e} previous_matrix_excess_m3={e} macropore_capacity_m3={e} macropore_occupied_m3={e} macropore_excess_m3={e}",
                    .{
                        cell,
                        first + offset,
                        index,
                        previous_matrix_capacity,
                        matrix_capacity,
                        matrix_occupied,
                        matrix_occupied - previous_matrix_capacity,
                        macro_capacity,
                        macro_occupied,
                        macro_occupied - macro_capacity,
                    },
                );
                return error.RuntimeSoilPoreCapacityExceeded;
            }
            const matrix_air = @max(0, matrix_capacity - matrix_occupied);
            const macro_air = @max(0, macro_capacity - macro_occupied);
            const thermal_volume = context.thermal.layer_volume_m3[index];
            const thermal_porosity = (matrix_capacity + macro_capacity) / thermal_volume;
            if (!std.math.isFinite(thermal_volume) or thermal_volume <= 0 or
                !std.math.isFinite(thermal_porosity) or thermal_porosity < 0 or
                thermal_porosity > 1 or
                !std.math.isFinite(solid.thermal_conductivity_numerator_m_megajoules_per_h_k) or
                solid.thermal_conductivity_numerator_m_megajoules_per_h_k < 0 or
                !std.math.isFinite(solid.thermal_conductivity_denominator) or
                solid.thermal_conductivity_denominator < 0)
                return error.InvalidRuntimeSoilThermalMaterial;
            staged[count] = .{
                .index = index,
                .bulk_density_megagrams_per_m3 = bulk_density,
                .sand_mass_fraction = sand_fraction,
                .silt_mass_fraction = silt_fraction,
                .clay_mass_fraction = clay_fraction,
                .organic_carbon_g_per_megagram = organic_concentration,
                .porosity_fraction = porosity,
                .matrix_pore_capacity_m3 = matrix_capacity,
                .matrix_air_volume_m3 = matrix_air,
                .macropore_air_volume_m3 = macro_air,
                .total_air_volume_m3 = matrix_air + macro_air,
                .thermal_porosity_fraction = thermal_porosity,
                .solid_thermal_conductivity_numerator_m_megajoules_per_h_k = solid.thermal_conductivity_numerator_m_megajoules_per_h_k,
                .solid_thermal_conductivity_denominator = solid.thermal_conductivity_denominator,
                .hydraulic = hydraulic,
                .charcoal_carbon_g_c = charcoal_carbon_g_c,
                .charcoal_retention_increment_fraction = charcoal_retention_increment,
                .cation_exchange_capacity_mol_per_megagram = cec_per_megagram,
                .anion_exchange_capacity_mol_per_megagram = aec_per_megagram,
                .cation_exchange_capacity_mol = cec_mol,
                .anion_exchange_capacity_mol = aec_mol,
                .cation_exchange_capacity_delta_mol = cec_delta_mol,
                .anion_exchange_capacity_delta_mol = aec_delta_mol,
            };
            count += 1;
        }
    }

    // Non-failing commit after complete validation.
    for (staged[0..count]) |candidate| {
        const index = candidate.index;
        context.properties.bulk_density_megagrams_per_m3[index] = candidate.bulk_density_megagrams_per_m3;
        context.properties.sand_mass_fraction[index] = candidate.sand_mass_fraction;
        context.properties.silt_mass_fraction[index] = candidate.silt_mass_fraction;
        context.properties.clay_mass_fraction[index] = candidate.clay_mass_fraction;
        context.properties.total_organic_carbon_g_per_megagram[index] = candidate.organic_carbon_g_per_megagram;
        context.properties.porosity_fraction[index] = candidate.porosity_fraction;
        context.properties.retention_curve[index] = candidate.hydraulic.retention_curve;
        context.properties.field_capacity_fraction[index] = candidate.hydraulic.retention_curve.curve.field_capacity_fraction;
        context.properties.wilting_point_fraction[index] = candidate.hydraulic.retention_curve.curve.wilting_point_fraction;
        context.properties.saturation_water_potential_megapascal[index] = candidate.hydraulic.retention_curve.curve.saturation_water_potential_megapascal;
        context.properties.mualem_van_genuchten_parameters[index] = candidate.hydraulic.mualem_van_genuchten_parameters;
        context.properties.lateral_saturated_hydraulic_conductivity_m_per_h[index] = candidate.hydraulic.lateral_saturated_hydraulic_conductivity_m_per_h;
        context.properties.saturated_lateral_conductivity_m2_per_h_megapascal[index] = candidate.hydraulic.saturated_lateral_conductivity_m2_per_h_megapascal;
        context.properties.previous_charcoal_carbon_g_c[index] = candidate.charcoal_carbon_g_c;
        context.properties.charcoal_retention_increment_fraction[index] = candidate.charcoal_retention_increment_fraction;
        context.properties.cation_exchange_capacity_mol_per_megagram[index] = candidate.cation_exchange_capacity_mol_per_megagram;
        context.properties.anion_exchange_capacity_mol_per_megagram[index] = candidate.anion_exchange_capacity_mol_per_megagram;
        context.properties.cation_exchange_capacity_mol[index] = candidate.cation_exchange_capacity_mol;
        context.properties.anion_exchange_capacity_mol[index] = candidate.anion_exchange_capacity_mol;
        const cell = index / context.geometry.layer_capacity;
        if (context.cation_exchange_capacity_delta_mol_by_cell) |values|
            values[cell] += candidate.cation_exchange_capacity_delta_mol;
        if (context.anion_exchange_capacity_delta_mol_by_cell) |values|
            values[cell] += candidate.anion_exchange_capacity_delta_mol;
        if (context.cation_exchange_capacity_delta_mol_by_layer) |values|
            values[index] = candidate.cation_exchange_capacity_delta_mol;
        if (context.anion_exchange_capacity_delta_mol_by_layer) |values|
            values[index] = candidate.anion_exchange_capacity_delta_mol;
        context.grid.matrix_pore_capacity_m3[index] = candidate.matrix_pore_capacity_m3;
        context.grid.matrix_air_volume_m3[index] = candidate.matrix_air_volume_m3;
        context.grid.macropore_air_volume_m3[index] = candidate.macropore_air_volume_m3;
        context.grid.air_volume_m3[index] = candidate.total_air_volume_m3;
        context.thermal.porosity_fraction[index] = candidate.thermal_porosity_fraction;
        context.thermal.solid_thermal_conductivity_numerator_m_megajoules_per_h_k[index] = candidate.solid_thermal_conductivity_numerator_m_megajoules_per_h_k;
        context.thermal.solid_thermal_conductivity_denominator[index] = candidate.solid_thermal_conductivity_denominator;
        // HOUR1's VHCM assignment is commented out in the active material
        // refresh branch. Deliberately preserve dry_solid_heat_capacity here.
    }
    return count;
}

fn validateDimensions(context: *const Context) !void {
    if (!std.math.isFinite(context.ice_density_megagrams_per_m3) or context.ice_density_megagrams_per_m3 <= 0 or context.ice_density_megagrams_per_m3 > 1) return error.InvalidRuntimeSoilPoreState;
    const layers = context.properties.layer_count;
    if (layers == 0 or context.grid.layer_count != layers or
        context.soil_organic.layer_count != layers or
        context.geometry.cell_count != context.grid.cell_count or
        context.geometry.layer_capacity != context.grid.soil_layer_capacity or
        context.thermal.cell_count != context.grid.cell_count or
        context.thermal.soil_layer_capacity != context.grid.soil_layer_capacity)
        return error.RuntimeMaterialRefreshDimensionMismatch;
    if ((context.cation_exchange_capacity_delta_mol_by_cell == null) != (context.anion_exchange_capacity_delta_mol_by_cell == null))
        return error.RuntimeMaterialRefreshDimensionMismatch;
    if (context.cation_exchange_capacity_delta_mol_by_cell) |values|
        if (values.len != context.grid.cell_count or context.anion_exchange_capacity_delta_mol_by_cell.?.len != context.grid.cell_count)
            return error.RuntimeMaterialRefreshDimensionMismatch;
    if ((context.cation_exchange_capacity_delta_mol_by_layer == null) != (context.anion_exchange_capacity_delta_mol_by_layer == null))
        return error.RuntimeMaterialRefreshDimensionMismatch;
    if (context.cation_exchange_capacity_delta_mol_by_layer) |values|
        if (values.len != layers or context.anion_exchange_capacity_delta_mol_by_layer.?.len != layers)
            return error.RuntimeMaterialRefreshDimensionMismatch;
    inline for (@typeInfo(SoilProperties).@"struct".fields) |field| {
        if (field.type == []f64 or
            field.type == []@import("../water/retention.zig").ResolvedCurve or
            field.type == []@import("../water/retention.zig").MualemVanGenuchtenParameters)
            if (@field(context.properties, field.name).len != layers)
                return error.RuntimeMaterialRefreshDimensionMismatch;
    }
}

test "accepted material refresh is atomic and updates retention and solid thermal owners" {
    const allocator = std.testing.allocator;
    const test_fixtures = @import("../../core/test_fixtures.zig");
    const soil_profile = @import("../../state/soil_profile.zig");
    const catalog_module = @import("catalog.zig");
    const config_module = @import("../../core/config.zig");
    const model_initialization = @import("../../driver/model_initialization.zig");

    const one_layer_source = try test_fixtures.soilProfileSource(
        allocator,
        @typeInfo(soil_profile.LayerProperty).@"enum".fields.len,
    );
    defer allocator.free(one_layer_source);
    var two_layer_source: std.ArrayList(u8) = .empty;
    defer two_layer_source.deinit(allocator);
    var lines = std.mem.splitScalar(u8, one_layer_source, '\n');
    _ = lines.next().?;
    try two_layer_source.appendSlice(allocator, "-0.01,-1.5,0.2,6,11,1.1,0.11,22,2.2,0.22,33,3.3,0.33,8,2,1,1,1,0,0\n");
    var record_index: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (record_index == 0) {
            try two_layer_source.appendSlice(allocator, "0.1 0.2\n");
        } else if (std.mem.startsWith(u8, line, "van_genuchten_inflection_pressure_head_m")) {
            try two_layer_source.appendSlice(allocator, "van_genuchten_inflection_pressure_head_m 0 0\n");
        } else {
            try two_layer_source.appendSlice(allocator, line);
            try two_layer_source.append(allocator, ' ');
            try two_layer_source.appendSlice(allocator, line);
            try two_layer_source.append(allocator, '\n');
        }
        record_index += 1;
    }
    var catalog = catalog_module.Catalog.init(allocator);
    defer catalog.deinit();
    const solver_parameters = SoilPropertiesModule.compatibilityParameters();
    _ = try catalog.appendFromSource(
        "soil",
        two_layer_source.items,
        solver_parameters.retention,
        solver_parameters.profile_derivation,
    );
    const layer_capacity = catalog.entries.items[0].profile.total_layer_count;
    try std.testing.expect(layer_capacity >= 2);
    const cfg = try config_module.SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = layer_capacity, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 80 },
    );
    var grid = try Grid.init(allocator, cfg);
    defer grid.deinit();
    try model_initialization.initializeCellHydrology(
        &grid,
        0,
        catalog.entries.items[0].hydrology_per_m2,
    );
    var properties = try SoilProperties.initMapped(
        allocator,
        &grid,
        catalog.entries.items,
        &.{0},
        &.{1},
        &.{1},
        solver_parameters,
    );
    defer properties.deinit();
    var thermal = try SoilThermal.initMapped(
        allocator,
        grid,
        catalog.entries.items,
        &.{0},
        &.{1},
        &.{1},
    );
    defer thermal.deinit();
    var geometry = try Geometry.init(allocator, 1, layer_capacity);
    defer geometry.deinit();
    try @import("layer_geometry.zig").initializeCell(
        &geometry,
        0,
        0,
        properties.layer_thickness_m,
        0,
        1e-9,
    );
    var soil_organic = try SoilOrganic.init(allocator, layer_capacity);
    defer soil_organic.deinit();

    // BKVL includes organic matter: minerals deliberately sum to 0.80*BKVL,
    // so a wrong sand+silt+clay carrier changes BKDS and all fractions.
    for (0..2) |index| {
        const soil_mass = properties.bulk_density_megagrams_per_m3[index] *
            properties.matrix_bulk_volume_m3[index];
        const mineral_mass = 0.80 * soil_mass;
        properties.sand_mass_megagrams[index] = mineral_mass * @as(f64, if (index == 0) 0.25 else 0.70);
        properties.silt_mass_megagrams[index] = mineral_mass * 0.20;
        properties.clay_mass_megagrams[index] = mineral_mass -
            properties.sand_mass_megagrams[index] -
            properties.silt_mass_megagrams[index];
        const structural = index * @import("../organic/initialization.zig").substrate_count *
            @import("../organic/initialization.zig").structural_fraction_count;
        soil_organic.structural[structural].carbon_g_c = soil_mass * (20_000.0 + 5_000.0 * @as(f64, @floatFromInt(index)));
        properties.van_genuchten_inflection_pressure_head_m[index] = 0;
    }
    properties.supplied_field_capacity_fraction[0] = 0.24;
    properties.supplied_wilting_point_fraction[0] = 0.10;
    properties.supplied_field_capacity_fraction[1] = -1;
    properties.supplied_wilting_point_fraction[1] = -1;
    const top_prior_porosity = properties.porosity_fraction[0];
    const deep_prior_porosity = properties.porosity_fraction[1];
    const accepted_top_structural_porosity = @min(0.95, top_prior_porosity + 0.05);
    grid.matrix_pore_capacity_m3[0] = accepted_top_structural_porosity *
        properties.matrix_bulk_volume_m3[0];
    const top_prior_bulk_density = properties.bulk_density_megagrams_per_m3[0];
    const deep_prior_bulk_density = properties.bulk_density_megagrams_per_m3[1];
    const old_solid_numerator = thermal.solid_thermal_conductivity_numerator_m_megajoules_per_h_k[0];
    const old_dry_heat = thermal.dry_solid_heat_capacity_megajoules_per_m3_k[0];
    var context: Context = .{
        .allocator = allocator,
        .grid = &grid,
        .geometry = &geometry,
        .soil_organic = &soil_organic,
        .properties = &properties,
        .thermal = &thermal,
        .parameters = solver_parameters,
        .maximum_iterations = 80,
    };
    try std.testing.expectEqual(layer_capacity, try refreshAcceptedHour(&context));
    try std.testing.expectEqual(accepted_top_structural_porosity, properties.porosity_fraction[0]);
    try std.testing.expect(properties.porosity_fraction[1] != deep_prior_porosity);
    try std.testing.expectEqual(top_prior_bulk_density, properties.bulk_density_megagrams_per_m3[0]);
    try std.testing.expectEqual(deep_prior_bulk_density, properties.bulk_density_megagrams_per_m3[1]);
    try std.testing.expectEqual(@as(f64, 0.24), properties.field_capacity_fraction[0]);
    try std.testing.expectEqual(@as(f64, 0.10), properties.wilting_point_fraction[0]);
    try std.testing.expect(thermal.solid_thermal_conductivity_numerator_m_megajoules_per_h_k[0] != old_solid_numerator);
    try std.testing.expectEqual(old_dry_heat, thermal.dry_solid_heat_capacity_megajoules_per_m3_k[0]);
    try std.testing.expectEqual(
        properties.porosity_fraction[0] * properties.matrix_bulk_volume_m3[0],
        grid.matrix_pore_capacity_m3[0],
    );

    // A tillage-style accepted extensive capacity remains the material base
    // on the next HOUR1 refresh when its per-Mg mirror uses exact BKVL.
    var accepted_cec: [2]f64 = undefined;
    var accepted_aec: [2]f64 = undefined;
    const pre_mix_cec = properties.cation_exchange_capacity_mol[0] +
        properties.cation_exchange_capacity_mol[1];
    const pre_mix_aec = properties.anion_exchange_capacity_mol[0] +
        properties.anion_exchange_capacity_mol[1];
    for (0..2) |index| {
        const soil_mass = properties.bulk_density_megagrams_per_m3[index] *
            properties.matrix_bulk_volume_m3[index];
        accepted_cec[index] = pre_mix_cec *
            @as(f64, if (index == 0) 0.4 else 0.6);
        accepted_aec[index] = pre_mix_aec *
            @as(f64, if (index == 0) 0.65 else 0.35);
        properties.cation_exchange_capacity_mol[index] = accepted_cec[index];
        properties.anion_exchange_capacity_mol[index] = accepted_aec[index];
        properties.cation_exchange_capacity_mol_per_megagram[index] =
            accepted_cec[index] / soil_mass;
        properties.anion_exchange_capacity_mol_per_megagram[index] =
            accepted_aec[index] / soil_mass;
    }
    var cec_delta_by_cell = [_]f64{0};
    var aec_delta_by_cell = [_]f64{0};
    var cec_delta_by_layer = [_]f64{ 0, 0 };
    var aec_delta_by_layer = [_]f64{ 0, 0 };
    context.cation_exchange_capacity_delta_mol_by_cell = &cec_delta_by_cell;
    context.anion_exchange_capacity_delta_mol_by_cell = &aec_delta_by_cell;
    context.cation_exchange_capacity_delta_mol_by_layer = &cec_delta_by_layer;
    context.anion_exchange_capacity_delta_mol_by_layer = &aec_delta_by_layer;
    try std.testing.expectEqual(layer_capacity, try refreshAcceptedHour(&context));
    for (0..2) |index| {
        try std.testing.expectApproxEqAbs(
            accepted_cec[index],
            properties.cation_exchange_capacity_mol[index],
            8 * std.math.floatEps(f64) * accepted_cec[index],
        );
        try std.testing.expectApproxEqAbs(
            accepted_aec[index],
            properties.anion_exchange_capacity_mol[index],
            8 * std.math.floatEps(f64) * accepted_aec[index],
        );
    }
    try std.testing.expectApproxEqAbs(@as(f64, 0), cec_delta_by_cell[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), aec_delta_by_cell[0], 1e-12);

    // Add authoritative OSC charcoal before the next accepted-hour refresh.
    // A derived layer receives only this hour's signed DORGCC on top of its
    // newly derived base; unchanged charcoal contributes zero next hour.
    const deep = 1;
    const organic_module = @import("../organic/initialization.zig");
    const charcoal_deep = (deep * organic_module.substrate_count + 3) *
        organic_module.structural_fraction_count +
        (organic_module.structural_fraction_count - 1);
    const added_charcoal_g_c = 0.01e6 * properties.matrix_bulk_volume_m3[deep];
    soil_organic.structural[charcoal_deep].carbon_g_c += added_charcoal_g_c;
    try std.testing.expectEqual(layer_capacity, try refreshAcceptedHour(&context));
    const derived_without_charcoal = try SoilPropertiesModule.resolveDynamicLayerWithCharcoalIncrement(
        &properties,
        deep,
        solver_parameters,
        80,
        properties.porosity_fraction[deep],
        properties.total_organic_carbon_g_per_megagram[deep],
        properties.bulk_density_megagrams_per_m3[deep],
        properties.sand_mass_fraction[deep],
        properties.silt_mass_fraction[deep],
        properties.clay_mass_fraction[deep],
        0,
    );
    try std.testing.expectApproxEqAbs(
        derived_without_charcoal.retention_curve.curve.field_capacity_fraction + 0.01,
        properties.field_capacity_fraction[deep],
        64 * std.math.floatEps(f64),
    );
    try std.testing.expectEqual(@as(f64, -1), properties.supplied_field_capacity_fraction[deep]);
    try std.testing.expect(cec_delta_by_cell[0] > 0);
    try std.testing.expect(aec_delta_by_cell[0] > 0);
    try std.testing.expectEqual(@as(f64, 0), cec_delta_by_layer[0]);
    try std.testing.expectEqual(@as(f64, 0), aec_delta_by_layer[0]);
    try std.testing.expectEqual(cec_delta_by_cell[0], cec_delta_by_layer[0] + cec_delta_by_layer[1]);
    try std.testing.expectEqual(aec_delta_by_cell[0], aec_delta_by_layer[0] + aec_delta_by_layer[1]);

    try std.testing.expectEqual(layer_capacity, try refreshAcceptedHour(&context));
    const derived_without_new_delta = try SoilPropertiesModule.resolveDynamicLayerWithCharcoalIncrement(
        &properties,
        deep,
        solver_parameters,
        80,
        properties.porosity_fraction[deep],
        properties.total_organic_carbon_g_per_megagram[deep],
        properties.bulk_density_megagrams_per_m3[deep],
        properties.sand_mass_fraction[deep],
        properties.silt_mass_fraction[deep],
        properties.clay_mass_fraction[deep],
        0,
    );
    try std.testing.expectApproxEqAbs(
        derived_without_new_delta.retention_curve.curve.field_capacity_fraction,
        properties.field_capacity_fraction[deep],
        64 * std.math.floatEps(f64),
    );
    try std.testing.expectEqual(@as(f64, 0), cec_delta_by_cell[0]);
    try std.testing.expectEqual(@as(f64, 0), aec_delta_by_cell[0]);
    try std.testing.expectEqual(@as(f64, 0), cec_delta_by_layer[0]);
    try std.testing.expectEqual(@as(f64, 0), cec_delta_by_layer[1]);
    try std.testing.expectEqual(@as(f64, 0), aec_delta_by_layer[0]);
    try std.testing.expectEqual(@as(f64, 0), aec_delta_by_layer[1]);

    // A later charcoal loss is the same signed HOUR1 path in reverse.
    soil_organic.structural[charcoal_deep].carbon_g_c -= 0.5 * added_charcoal_g_c;
    try std.testing.expectEqual(layer_capacity, try refreshAcceptedHour(&context));
    try std.testing.expect(cec_delta_by_cell[0] < 0);
    try std.testing.expect(aec_delta_by_cell[0] < 0);
    try std.testing.expectEqual(cec_delta_by_cell[0], cec_delta_by_layer[0] + cec_delta_by_layer[1]);
    try std.testing.expectEqual(aec_delta_by_cell[0], aec_delta_by_layer[0] + aec_delta_by_layer[1]);

    // Supplied FC/WP retain their accepted cumulative charcoal effect, but a
    // single event is applied exactly once and a later loss reverses it.
    const top = 0;
    const charcoal_top = (top * organic_module.substrate_count + 3) *
        organic_module.structural_fraction_count +
        (organic_module.structural_fraction_count - 1);
    const top_charcoal_g_c = 0.005e6 * properties.matrix_bulk_volume_m3[top];
    soil_organic.structural[charcoal_top].carbon_g_c += top_charcoal_g_c;
    try std.testing.expectEqual(layer_capacity, try refreshAcceptedHour(&context));
    try std.testing.expectApproxEqAbs(@as(f64, 0.245), properties.field_capacity_fraction[top], 64 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(@as(f64, 0.105), properties.wilting_point_fraction[top], 64 * std.math.floatEps(f64));
    try std.testing.expectEqual(layer_capacity, try refreshAcceptedHour(&context));
    try std.testing.expectApproxEqAbs(@as(f64, 0.245), properties.field_capacity_fraction[top], 64 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(@as(f64, 0.105), properties.wilting_point_fraction[top], 64 * std.math.floatEps(f64));
    try std.testing.expectEqual(@as(f64, 0), cec_delta_by_cell[0]);
    try std.testing.expectEqual(@as(f64, 0), aec_delta_by_cell[0]);
    soil_organic.structural[charcoal_top].carbon_g_c -= top_charcoal_g_c;
    try std.testing.expectEqual(layer_capacity, try refreshAcceptedHour(&context));
    try std.testing.expectApproxEqAbs(@as(f64, 0.24), properties.field_capacity_fraction[top], 64 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(@as(f64, 0.10), properties.wilting_point_fraction[top], 64 * std.math.floatEps(f64));
    try std.testing.expect(cec_delta_by_cell[0] < 0);
    try std.testing.expect(aec_delta_by_cell[0] < 0);

    // HOUR1 publishes a newly contracted deep VOLA even when the preceding
    // accepted liquid inventory filled the old pore volume. It preserves the
    // conserved carrier and exposes zero derived air; WATSUB owns the ensuing
    // upward displacement. The surface-layer max-old-porosity exception is
    // already checked above.
    const deep_structural = deep * organic_module.substrate_count *
        organic_module.structural_fraction_count;
    const deep_structural_carbon = soil_organic.structural[deep_structural].carbon_g_c;
    const deep_old_capacity = grid.matrix_pore_capacity_m3[deep];
    grid.matrix_liquid_water_m3[deep] = deep_old_capacity;
    soil_organic.structural[deep_structural].carbon_g_c = 4 * deep_structural_carbon;
    try std.testing.expectEqual(layer_capacity, try refreshAcceptedHour(&context));
    try std.testing.expect(grid.matrix_pore_capacity_m3[deep] < deep_old_capacity);
    try std.testing.expectEqual(deep_old_capacity, grid.matrix_liquid_water_m3[deep]);
    try std.testing.expectEqual(@as(f64, 0), grid.matrix_air_volume_m3[deep]);
    soil_organic.structural[deep_structural].carbon_g_c = deep_structural_carbon;
    grid.matrix_liquid_water_m3[deep] = 0;
    try std.testing.expectEqual(layer_capacity, try refreshAcceptedHour(&context));

    // An invalid late capacity leaves every already-staged owner unchanged.
    const before_porosity = try allocator.dupe(f64, properties.porosity_fraction);
    defer allocator.free(before_porosity);
    const before_stc = try allocator.dupe(f64, thermal.solid_thermal_conductivity_numerator_m_megajoules_per_h_k);
    defer allocator.free(before_stc);
    const before_capacity = try allocator.dupe(f64, grid.matrix_pore_capacity_m3);
    defer allocator.free(before_capacity);
    grid.matrix_liquid_water_m3[1] = properties.matrix_bulk_volume_m3[1] * 2;
    try std.testing.expectError(error.RuntimeSoilPoreCapacityExceeded, refreshAcceptedHour(&context));
    try std.testing.expectEqualSlices(f64, before_porosity, properties.porosity_fraction);
    try std.testing.expectEqualSlices(f64, before_stc, thermal.solid_thermal_conductivity_numerator_m_megajoules_per_h_k);
    try std.testing.expectEqualSlices(f64, before_capacity, grid.matrix_pore_capacity_m3);

    // A user ceiling of one is passed through to the fit and may not silently
    // consume the initialization compatibility budget of 80.
    grid.matrix_liquid_water_m3[1] = 0;
    const expected_mualem: @import("../water/retention.zig").MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0.078,
        .saturated_water_content_m3_per_m3 = 0.43,
        .alpha_per_m = 3.6,
        .n = 1.56,
        .saturated_hydraulic_conductivity_m_per_h = 0.0104,
    };
    const field_head_m = -0.33;
    const wilting_head_m = -15.0;
    properties.supplied_field_capacity_fraction[1] = try expected_mualem.waterContentAtPressureHead(field_head_m);
    properties.supplied_wilting_point_fraction[1] = try expected_mualem.waterContentAtPressureHead(wilting_head_m);
    properties.field_capacity_water_potential_megapascal[1] = field_head_m * 0.00980665;
    properties.wilting_point_water_potential_megapascal[1] = wilting_head_m * 0.00980665;
    properties.van_genuchten_inflection_pressure_head_m[1] = try expected_mualem.inflectionPressureHeadM();
    try std.testing.expectError(error.MualemVanGenuchtenFitDidNotConverge, SoilPropertiesModule.resolveDynamicLayerWithCharcoalIncrement(
        &properties,
        1,
        solver_parameters,
        1,
        0.43,
        properties.total_organic_carbon_g_per_megagram[1],
        properties.bulk_density_megagrams_per_m3[1],
        properties.sand_mass_fraction[1],
        properties.silt_mass_fraction[1],
        properties.clay_mass_fraction[1],
        0,
    ));

    // A failed scientific attempt may leave the destination numerically
    // invalid. Rollback validates only its layout, overwrites it from the
    // validated snapshot, and the following hour remains executable.
    const RuntimeCheckpoint = @import("../../io/checkpoint/soil_runtime_checkpoint.zig");
    const ReactionParameters = @import("../solute/chemistry_state.zig").ReactionParameters;
    const runtime_reaction_parameters = try allocator.alloc(
        ReactionParameters,
        properties.layer_count,
    );
    defer allocator.free(runtime_reaction_parameters);
    for (runtime_reaction_parameters) |*parameters| {
        parameters.cation_exchange_capacity_mol_charge_per_megagram = 1;
        parameters.cation_exchange_parameters.selectivity = .{
            .calcium_ammonium = 1,
            .calcium_hydrogen = 1,
            .calcium_aluminum_and_iron = 1,
            .calcium_magnesium = 1,
            .calcium_sodium = 1,
            .calcium_potassium = 1,
        };
    }
    var runtime_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer runtime_bytes.deinit();
    try RuntimeCheckpoint.write(&runtime_bytes.writer, .{
        .soil_properties = &properties,
        .soil_thermal = &thermal,
        .soil_chemistry_layer_parameters = runtime_reaction_parameters,
    });
    var runtime_reader = std.Io.Reader.fixed(runtime_bytes.written());
    var runtime_snapshot = try RuntimeCheckpoint.read(allocator, &runtime_reader, properties.layer_count);
    defer runtime_snapshot.deinit();
    properties.porosity_fraction[0] = std.math.nan(f64);
    thermal.total_heat_capacity_megajoules_per_m3_k[0] = -1;
    try std.testing.expectError(
        error.NonFiniteSoilRuntimeCheckpoint,
        RuntimeCheckpoint.validateView(.{
            .soil_properties = &properties,
            .soil_thermal = &thermal,
            .soil_chemistry_layer_parameters = runtime_reaction_parameters,
        }),
    );
    try RuntimeCheckpoint.validateTargetLayout(.{
        .soil_properties = &properties,
        .soil_thermal = &thermal,
        .soil_chemistry_layer_parameters = runtime_reaction_parameters,
    });
    try runtime_snapshot.restoreInto(
        &properties,
        &thermal,
        runtime_reaction_parameters,
    );
    try RuntimeCheckpoint.validateView(.{
        .soil_properties = &properties,
        .soil_thermal = &thermal,
        .soil_chemistry_layer_parameters = runtime_reaction_parameters,
    });
    _ = try refreshAcceptedHour(&context);

    // A valid active open-water slot has no mineral carrier and must remain
    // byte-for-byte outside the material-refresh candidate set.
    properties.bulk_density_megagrams_per_m3[0] = 0;
    const water_porosity = properties.porosity_fraction[0];
    const water_sand = properties.sand_mass_fraction[0];
    const water_cec = properties.cation_exchange_capacity_mol[0];
    const water_charcoal_snapshot = properties.previous_charcoal_carbon_g_c[0];
    try std.testing.expectEqual(layer_capacity - 1, try refreshAcceptedHour(&context));
    try std.testing.expectEqual(@as(f64, 0), properties.bulk_density_megagrams_per_m3[0]);
    try std.testing.expectEqual(water_porosity, properties.porosity_fraction[0]);
    try std.testing.expectEqual(water_sand, properties.sand_mass_fraction[0]);
    try std.testing.expectEqual(water_cec, properties.cation_exchange_capacity_mol[0]);
    try std.testing.expectEqual(water_charcoal_snapshot, properties.previous_charcoal_carbon_g_c[0]);
}

test "production binds accepted material refresh before hourly heat science" {
    const allocator = std.testing.allocator;
    const driver_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/ecosys_ng.zig",
        allocator,
        .limited(8 * 1024 * 1024),
    );
    defer allocator.free(driver_source);
    const heat_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/soil/water/heat_step.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(heat_source);

    const prepare_start = std.mem.indexOf(
        u8,
        driver_source,
        "noinline fn prepareHourlyScience(",
    ) orelse return error.MissingPrepareHourlySciencePhase;
    const advance_start = std.mem.indexOfPos(
        u8,
        driver_source,
        prepare_start,
        "noinline fn advanceHour(",
    ) orelse return error.MissingAdvanceHourPhase;
    const timeline_start = std.mem.indexOfPos(
        u8,
        driver_source,
        advance_start,
        "noinline fn runTimeline(",
    ) orelse return error.MissingTimelinePhase;
    const prepare_phase = driver_source[prepare_start..advance_start];
    const advance_phase = driver_source[advance_start..timeline_start];
    const refresh = std.mem.indexOf(
        u8,
        prepare_phase,
        "ecosys.soil_runtime_material_refresh.refreshAcceptedHour(&.{",
    ) orelse return error.MissingProductionRuntimeMaterialRefresh;
    const census = std.mem.indexOfPos(
        u8,
        prepare_phase,
        refresh,
        "diagnostics.reconstructLayerMassBalanceScopes(",
    ) orelse return error.MissingStorageCensusAfterMaterialRefresh;
    const prepare_call = std.mem.indexOf(
        u8,
        advance_phase,
        "try prepareHourlyScience(driver_context,",
    ) orelse return error.MissingHourlyPreparationCall;
    const science = std.mem.indexOfPos(
        u8,
        advance_phase,
        prepare_call,
        "executeHourlyScience(",
    ) orelse return error.MissingHourlyScienceAfterMaterialRefresh;
    try std.testing.expect(refresh < census);
    try std.testing.expect(prepare_call < science);
    const binding = prepare_phase[refresh..census];
    inline for (.{
        ".soil_organic = &driver_context.soil_organic_state.*",
        ".properties = &driver_context.soil_solver_property_state.*",
        ".thermal = &driver_context.soil_thermal_state.*",
        ".maximum_iterations = advance_context.active_iteration_limits.*.hard_max_iterations",
        ".ice_density_megagrams_per_m3 = driver_context.runscript.*.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3",
    }) |required| try std.testing.expect(std.mem.indexOf(u8, binding, required) != null);
    inline for (.{
        ".solid_conductivity_numerator_m_megajoules_per_h_k = thermal.solid_thermal_conductivity_numerator_m_megajoules_per_h_k",
        ".solid_conductivity_denominator = thermal.solid_thermal_conductivity_denominator",
    }) |required| try std.testing.expect(std.mem.indexOf(u8, heat_source, required) != null);
}

test "pond defers constitutive porosity publication to HOUR1 refresh" {
    const pond_source = @embedFile("../../surface/pond_domain_transaction.zig");

    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(
            u8,
            pond_source,
            "soil_properties.porosity_fraction[destination] =",
        ),
    );
}
