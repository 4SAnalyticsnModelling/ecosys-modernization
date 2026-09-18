const std = @import("std");
const SoilProfile = @import("../../state/soil_profile.zig").SoilProfile;
const profile_derivation = @import("derivation.zig");

pub const SoilMaterial = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    bulk_density_megagrams_per_m3: []f64,
    micropore_fraction: []f64,
    clay_mass_fraction: []f64,
    sand_mass_fraction: []f64,
    silt_mass_fraction: []f64,
    vertical_hydraulic_conductivity_m2_per_mpa_h: []f64,
    lateral_hydraulic_conductivity_m2_per_mpa_h: []f64,
    total_organic_carbon_g_per_megagram: []f64,
    particulate_organic_carbon_g_per_megagram: []f64,
    organic_nitrogen_g_per_megagram: []f64,
    organic_phosphorus_g_per_megagram: []f64,
    initial_ammonium_g_per_megagram: []f64,
    initial_calcium_g_per_megagram: []f64,
    cation_exchange_capacity_mol_per_megagram: []f64,
    anion_exchange_capacity_mol_per_megagram: []f64,
    dry_solid_heat_capacity_megajoules_per_m3_k: []f64,
    solid_thermal_conductivity_numerator_m_megajoules_per_h_k: []f64,
    solid_thermal_conductivity_denominator: []f64,

    pub fn init(allocator: std.mem.Allocator, profile: SoilProfile, derivation_parameters: profile_derivation.Parameters) !SoilMaterial {
        const layer_count = profile.total_layer_count;
        var result: SoilMaterial = undefined;
        result.allocator = allocator;
        result.layer_count = layer_count;
        var allocated: usize = 0;
        errdefer freeAllocated(&result, allocated);
        inline for (@typeInfo(SoilMaterial).@"struct".fields) |field| {
            if (field.type == []f64) {
                @field(result, field.name) = try allocator.alloc(f64, layer_count);
                allocated += 1;
            }
        }

        const organic_carbon_input = profile.property(.total_organic_carbon_kg_per_megagram);
        const particulate_carbon_input = profile.property(.particulate_organic_carbon_kg_per_megagram);
        const organic_nitrogen_input = profile.property(.organic_nitrogen_g_per_megagram);
        const organic_phosphorus_input = profile.property(.organic_phosphorus_g_per_megagram);
        for (0..layer_count) |layer| {
            const bulk_density = profile.initial_bulk_density_megagrams_per_m3[layer];
            const macropore_fraction = if (bulk_density <= 0.0) 0.0 else profile.macropore_fraction[layer];
            const rock_fraction = profile.rock_fraction[layer];
            const micropore_fraction = (1.0 - rock_fraction) * (1.0 - macropore_fraction);
            if (!std.math.isFinite(micropore_fraction) or micropore_fraction < 0.0 or micropore_fraction > 1.0) return error.InvalidMicroporeFraction;

            const organic_carbon_g_per_megagram = organic_carbon_input[layer] * 1000.0;
            const mineral_fraction = @max(0.0, 1.0 - organic_carbon_g_per_megagram / 550_000.0);
            const sand_kg_per_megagram = profile.sand_kg_per_megagram[layer];
            const silt_kg_per_megagram = profile.silt_kg_per_megagram[layer];
            const clay_kg_per_megagram = @max(0.0, 1000.0 - sand_kg_per_megagram - silt_kg_per_megagram);
            const sand_fraction = sand_kg_per_megagram * 0.001 * mineral_fraction;
            const silt_fraction = silt_kg_per_megagram * 0.001 * mineral_fraction;
            const clay_fraction = clay_kg_per_megagram * 0.001 * mineral_fraction;
            const derived = try profile_derivation.resolve(derivation_parameters, organic_carbon_g_per_megagram, particulate_carbon_input[layer] * 1000.0, organic_nitrogen_input[layer], organic_phosphorus_input[layer], profile.cation_exchange_capacity_cmol_kg[layer], profile.property(.ammonium_g_per_megagram)[layer], profile.property(.calcium_g_per_megagram)[layer], sand_fraction, silt_fraction, clay_fraction);

            result.bulk_density_megagrams_per_m3[layer] = bulk_density;
            result.micropore_fraction[layer] = micropore_fraction;
            result.vertical_hydraulic_conductivity_m2_per_mpa_h[layer] = 0.098 * profile.vertical_saturated_conductivity_mm_h[layer] * micropore_fraction;
            result.lateral_hydraulic_conductivity_m2_per_mpa_h[layer] = 0.098 * profile.lateral_saturated_conductivity_mm_h[layer] * micropore_fraction;
            result.sand_mass_fraction[layer] = sand_fraction;
            result.silt_mass_fraction[layer] = silt_fraction;
            result.clay_mass_fraction[layer] = clay_fraction;
            result.total_organic_carbon_g_per_megagram[layer] = organic_carbon_g_per_megagram;
            result.particulate_organic_carbon_g_per_megagram[layer] = derived.particulate_organic_carbon_g_per_megagram;
            result.organic_nitrogen_g_per_megagram[layer] = derived.organic_nitrogen_g_per_megagram;
            result.organic_phosphorus_g_per_megagram[layer] = derived.organic_phosphorus_g_per_megagram;
            result.initial_ammonium_g_per_megagram[layer] = derived.ammonium_g_per_megagram;
            result.initial_calcium_g_per_megagram[layer] = derived.calcium_g_per_megagram;
            result.cation_exchange_capacity_mol_per_megagram[layer] = derived.cation_exchange_capacity_mol_per_megagram;
            result.anion_exchange_capacity_mol_per_megagram[layer] = profile.anion_exchange_capacity_cmol_kg[layer] * 10.0;

            // STARTS/HOUR1 solid-phase thermal formulation. Input texture
            // fractions are normalized after converting SOC to organic matter.
            const solid = solidThermalTerms(.{
                .organic_carbon_g_per_megagram = organic_carbon_g_per_megagram,
                .bulk_density_megagrams_per_m3 = bulk_density,
                .silt_mass_fraction = result.silt_mass_fraction[layer],
                .clay_mass_fraction = result.clay_mass_fraction[layer],
                .sand_mass_fraction = result.sand_mass_fraction[layer],
                .micropore_fraction = micropore_fraction,
                .rock_fraction = rock_fraction,
            });
            result.dry_solid_heat_capacity_megajoules_per_m3_k[layer] = solid.dry_solid_heat_capacity_megajoules_per_m3_k;
            result.solid_thermal_conductivity_numerator_m_megajoules_per_h_k[layer] = solid.thermal_conductivity_numerator_m_megajoules_per_h_k;
            result.solid_thermal_conductivity_denominator[layer] = solid.thermal_conductivity_denominator;
        }
        try result.validateFinite();
        return result;
    }

    pub fn deinit(self: *SoilMaterial) void {
        inline for (@typeInfo(SoilMaterial).@"struct".fields) |field| {
            if (field.type == []f64) self.allocator.free(@field(self, field.name));
        }
        self.* = undefined;
    }

    pub fn validateFinite(self: SoilMaterial) !void {
        inline for (@typeInfo(SoilMaterial).@"struct".fields) |field| {
            if (field.type == []f64) {
                for (@field(self, field.name), 0..) |value, layer| {
                    if (!std.math.isFinite(value)) {
                        std.log.err("non-finite initialized soil property: field={s} layer={d}", .{ field.name, layer });
                        return error.NonFiniteInitializedSoilProperty;
                    }
                }
            }
        }
    }
};

fn freeAllocated(material: *SoilMaterial, count: usize) void {
    var visited: usize = 0;
    inline for (@typeInfo(SoilMaterial).@"struct".fields) |field| {
        if (field.type == []f64) {
            if (visited < count) material.allocator.free(@field(material, field.name));
            visited += 1;
        }
    }
}

test "initialize soil material in model units from self-contained profile" {
    const source = try @import("../../core/test_fixtures.zig").soilProfileSource(std.testing.allocator, @typeInfo(@import("../../state/soil_profile.zig").LayerProperty).@"enum".fields.len);
    defer std.testing.allocator.free(source);
    var profile = try @import("../../state/soil_profile.zig").parsePhysicalProfile(std.testing.allocator, source);
    defer profile.deinit();
    var material = try SoilMaterial.init(std.testing.allocator, profile, profile_derivation.compatibilityParameters());
    defer material.deinit();
    try std.testing.expectEqual(@as(usize, 1), material.layer_count);
    try std.testing.expectApproxEqAbs(@as(f64, 14_850.0), material.total_organic_carbon_g_per_megagram[0], 1.0e-10);
    const expected_micropore_fraction = (1.0 - profile.rock_fraction[0]) * (1.0 - profile.macropore_fraction[0]);
    try std.testing.expectApproxEqAbs(expected_micropore_fraction, material.micropore_fraction[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(0.098 * profile.vertical_saturated_conductivity_mm_h[0] * expected_micropore_fraction, material.vertical_hydraulic_conductivity_m2_per_mpa_h[0], 1.0e-12);
    try std.testing.expect(material.dry_solid_heat_capacity_megajoules_per_m3_k[0] > 0);
    try std.testing.expect(material.solid_thermal_conductivity_numerator_m_megajoules_per_h_k[0] > 0);
    try std.testing.expect(material.solid_thermal_conductivity_denominator[0] > 0);
}

test "negative READI organic and CEC sentinels resolve before catalog state_update" {
    const allocator = std.testing.allocator;
    const source = try @import("../../core/test_fixtures.zig").soilProfileSource(allocator, @typeInfo(@import("../../state/soil_profile.zig").LayerProperty).@"enum".fields.len);
    defer allocator.free(source);
    var profile = try @import("../../state/soil_profile.zig").parsePhysicalProfile(allocator, source);
    defer profile.deinit();
    profile.layer_properties[@intFromEnum(@import("../../state/soil_profile.zig").LayerProperty.particulate_organic_carbon_kg_per_megagram) * profile.total_layer_count] = -1;
    profile.layer_properties[@intFromEnum(@import("../../state/soil_profile.zig").LayerProperty.organic_nitrogen_g_per_megagram) * profile.total_layer_count] = -1;
    profile.layer_properties[@intFromEnum(@import("../../state/soil_profile.zig").LayerProperty.organic_phosphorus_g_per_megagram) * profile.total_layer_count] = -1;
    profile.cation_exchange_capacity_cmol_kg[0] = -1;
    var material = try SoilMaterial.init(allocator, profile, profile_derivation.compatibilityParameters());
    defer material.deinit();
    try std.testing.expectApproxEqAbs(0.067 * material.total_organic_carbon_g_per_megagram[0], material.particulate_organic_carbon_g_per_megagram[0], 1e-12);
    try std.testing.expect(material.organic_nitrogen_g_per_megagram[0] > 0);
    try std.testing.expect(material.organic_phosphorus_g_per_megagram[0] > 0);
    try std.testing.expect(material.cation_exchange_capacity_mol_per_megagram[0] > 0);
    try std.testing.expect(material.initial_ammonium_g_per_megagram[0] >= 1);
    try std.testing.expect(material.initial_calcium_g_per_megagram[0] >= 1);
}

/// STARTS/HOUR1 solid-phase thermal formulation, `hour1.f` 3688--3705.
///
/// Extracted from `SoilMaterial.init` so that the production owner of this
/// arithmetic is a nameable function. The unbound duplicate owner
/// `soil/heat/solid_thermal_porosity.zig` is pinned to it by an equivalence
/// guard in that file; see
/// `docs/traceability/a8a_solid_thermal_porosity_duplicate_owner.md`.
pub const SolidThermalInputs = struct {
    organic_carbon_g_per_megagram: f64,
    bulk_density_megagrams_per_m3: f64,
    silt_mass_fraction: f64,
    clay_mass_fraction: f64,
    sand_mass_fraction: f64,
    micropore_fraction: f64,
    rock_fraction: f64,
};

pub const SolidThermalTerms = struct {
    organic_matter_mass_fraction: f64,
    particle_density_megagrams_per_m3: f64,
    organic_volume_fraction: f64,
    nonsand_mineral_volume_fraction: f64,
    sand_volume_fraction: f64,
    dry_solid_heat_capacity_megajoules_per_m3_k: f64,
    thermal_conductivity_numerator_m_megajoules_per_h_k: f64,
    thermal_conductivity_denominator: f64,
};

pub fn solidThermalTerms(inputs: SolidThermalInputs) SolidThermalTerms {
    const organic_matter_mass_fraction = std.math.clamp(1.82e-6 * inputs.organic_carbon_g_per_megagram, 0.0, 1.0);
    const particle_density_megagrams_per_m3 = 1.30 * organic_matter_mass_fraction + 2.66 * (1.0 - organic_matter_mass_fraction);
    const bulk_to_particle_ratio = if (particle_density_megagrams_per_m3 > 0) inputs.bulk_density_megagrams_per_m3 / particle_density_megagrams_per_m3 else 0;
    const component_sum = organic_matter_mass_fraction + inputs.silt_mass_fraction + inputs.clay_mass_fraction + inputs.sand_mass_fraction;
    const normalization = if (component_sum > 0) @min(1.0, 1.0 / component_sum) else 0;
    const organic_volume_fraction = organic_matter_mass_fraction * normalization * bulk_to_particle_ratio;
    const nonsand_mineral_volume_fraction = (inputs.silt_mass_fraction + inputs.clay_mass_fraction) * normalization * bulk_to_particle_ratio;
    const sand_volume_fraction = inputs.sand_mass_fraction * normalization * bulk_to_particle_ratio;
    const matrix_fraction = inputs.micropore_fraction;
    return .{
        .organic_matter_mass_fraction = organic_matter_mass_fraction,
        .particle_density_megagrams_per_m3 = particle_density_megagrams_per_m3,
        .organic_volume_fraction = organic_volume_fraction,
        .nonsand_mineral_volume_fraction = nonsand_mineral_volume_fraction,
        .sand_volume_fraction = sand_volume_fraction,
        .dry_solid_heat_capacity_megajoules_per_m3_k = (2.496 * organic_volume_fraction + 2.385 * nonsand_mineral_volume_fraction + 2.128 * sand_volume_fraction) * matrix_fraction +
            2.128 * inputs.rock_fraction,
        .thermal_conductivity_numerator_m_megajoules_per_h_k = (1.253 * organic_volume_fraction * 9.050e-4 + 0.514 * nonsand_mineral_volume_fraction * 1.056e-2 + 0.386 * sand_volume_fraction * 2.112e-2) * matrix_fraction +
            0.514 * inputs.rock_fraction * 1.056e-2,
        .thermal_conductivity_denominator = (1.253 * organic_volume_fraction + 0.514 * nonsand_mineral_volume_fraction + 0.386 * sand_volume_fraction) * matrix_fraction +
            0.514 * inputs.rock_fraction,
    };
}
