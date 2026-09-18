//! **A5 DISPOSITION: never production bound.**
//!
//! Legacy source: `ecosys_f77/hour1.f` lines 3656--3671. This module is an exact,
//! tested, source-order translation of that range and is imported only by
//! `src/module_index.zig`, so it is reachable by `zig build test` and unreachable
//! from `executeHourlyScience`. That is intentional and must stay that way.
//!
//! Classification: architecturally superseded. Production stores the same physics in a
//! different representation, deliberately, with the deviation recorded in
//! `docs/model_changes.md`. Binding this kernel would reintroduce the
//! formulation the project chose to leave behind, as a second writer.
//!
//! Superseded by: `soil_solver_properties`, verified production bound at
//! `ecosys_ng.zig:7249` via `State.initMapped`. See the correction note in
//! `solid_thermal_porosity.zig`: `mineral_layer_phase_initialization` was
//! originally named here too and was removed because it is itself unbound.
//!
//! The legacy concentrations are derived from a single bulk soil mass;
//! production carries sand, silt, clay, and organic masses per domain and
//! derives concentrations at the point of use, so a stored concentration would
//! be a second, staleable copy.
//!
//! Do not bind this module, and do not delete it: the tests are a source-order
//! comparison oracle for the range above. Full argument and the census behind
//! it: `docs/traceability/hour1_2039_5200_binding_survey.md`.
const std = @import("std");

pub const SaltMode = enum { static_equilibrium, dynamic_transport };

pub const Inputs = struct {
    bulk_density_megagrams_m3: f64,
    rock_excluded_volume_m3: f64,
    organic_carbon_g: f64,
    sand_megagrams: f64,
    silt_megagrams: f64,
    clay_megagrams: f64,
    soil_mass_threshold_megagrams: f64,
};

pub const Result = struct {
    soil_mass_megagrams: f64,
    organic_carbon_concentration_g_per_megagram: f64,
    sand_mass_fraction_megagrams_megagrams: f64,
    silt_mass_fraction_megagrams_megagrams: f64,
    clay_mass_fraction_megagrams_megagrams: f64,
    dynamic_salt_surface_area_m2_m3: ?f64,
};

pub const CalculationError = error{
    NonFiniteInput,
    NegativeInput,
    InvalidTextureFraction,
    NonFiniteResult,
};

/// Translates `hour1.f` lines 3656--3671 in source operation order.
pub fn calculate(
    salt_mode: SaltMode,
    inputs: Inputs,
) CalculationError!Result {
    inline for (std.meta.fields(Inputs)) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteInput;
        if (value < 0.0) return error.NegativeInput;
    }

    const soil_mass_megagrams = inputs.bulk_density_megagrams_m3 * inputs.rock_excluded_volume_m3;
    var organic_carbon_concentration_g_per_megagram: f64 = 0.0;
    var sand_mass_fraction_megagrams_megagrams: f64 = 0.0;
    var silt_mass_fraction_megagrams_megagrams: f64 = 0.0;
    var clay_mass_fraction_megagrams_megagrams: f64 = 0.0;
    if (soil_mass_megagrams > inputs.soil_mass_threshold_megagrams) {
        organic_carbon_concentration_g_per_megagram =
            @min(0.55e6, inputs.organic_carbon_g / soil_mass_megagrams);
        sand_mass_fraction_megagrams_megagrams = inputs.sand_megagrams / soil_mass_megagrams;
        silt_mass_fraction_megagrams_megagrams = inputs.silt_megagrams / soil_mass_megagrams;
        clay_mass_fraction_megagrams_megagrams = inputs.clay_megagrams / soil_mass_megagrams;
        if (sand_mass_fraction_megagrams_megagrams > 1.0 or
            silt_mass_fraction_megagrams_megagrams > 1.0 or
            clay_mass_fraction_megagrams_megagrams > 1.0 or
            sand_mass_fraction_megagrams_megagrams +
                silt_mass_fraction_megagrams_megagrams +
                clay_mass_fraction_megagrams_megagrams > 1.0 + 1.0e-12)
        {
            return error.InvalidTextureFraction;
        }
    }

    const dynamic_salt_surface_area_m2_m3 = if (salt_mode == .dynamic_transport)
        (0.3 * sand_mass_fraction_megagrams_megagrams +
            2.2 * silt_mass_fraction_megagrams_megagrams +
            8.0 * clay_mass_fraction_megagrams_megagrams) * inputs.bulk_density_megagrams_m3
    else
        null;
    const result = Result{
        .soil_mass_megagrams = soil_mass_megagrams,
        .organic_carbon_concentration_g_per_megagram = organic_carbon_concentration_g_per_megagram,
        .sand_mass_fraction_megagrams_megagrams = sand_mass_fraction_megagrams_megagrams,
        .silt_mass_fraction_megagrams_megagrams = silt_mass_fraction_megagrams_megagrams,
        .clay_mass_fraction_megagrams_megagrams = clay_mass_fraction_megagrams_megagrams,
        .dynamic_salt_surface_area_m2_m3 = dynamic_salt_surface_area_m2_m3,
    };
    inline for (std.meta.fields(Result)) |field| {
        if (field.type == f64 and !std.math.isFinite(@field(result, field.name))) {
            return error.NonFiniteResult;
        }
    }
    if (dynamic_salt_surface_area_m2_m3) |surface_area| {
        if (!std.math.isFinite(surface_area)) return error.NonFiniteResult;
    }
    return result;
}

test "positive soil mass produces concentrations and dynamic surface area" {
    const result = try calculate(.dynamic_transport, .{
        .bulk_density_megagrams_m3 = 1.25,
        .rock_excluded_volume_m3 = 100.0,
        .organic_carbon_g = 1_000_000.0,
        .sand_megagrams = 50.0,
        .silt_megagrams = 40.0,
        .clay_megagrams = 30.0,
        .soil_mass_threshold_megagrams = 1.0e-12,
    });
    try std.testing.expectEqual(@as(f64, 125.0), result.soil_mass_megagrams);
    try std.testing.expectEqual(@as(f64, 0.4), result.sand_mass_fraction_megagrams_megagrams);
    try std.testing.expect(result.dynamic_salt_surface_area_m2_m3.? > 0.0);
}

test "negligible mass uses zero concentrations and static salt has no surface area update" {
    const result = try calculate(.static_equilibrium, .{
        .bulk_density_megagrams_m3 = 0.0,
        .rock_excluded_volume_m3 = 0.0,
        .organic_carbon_g = 0.0,
        .sand_megagrams = 0.0,
        .silt_megagrams = 0.0,
        .clay_megagrams = 0.0,
        .soil_mass_threshold_megagrams = 0.0,
    });
    try std.testing.expectEqual(@as(f64, 0.0), result.organic_carbon_concentration_g_per_megagram);
    try std.testing.expect(result.dynamic_salt_surface_area_m2_m3 == null);
}
