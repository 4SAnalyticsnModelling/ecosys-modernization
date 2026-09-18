//! **A5 DISPOSITION: never production bound.**
//!
//! Legacy source: `ecosys_f77/hour1.f` lines 3760--3791. This module is an exact,
//! tested, source-order translation of that range and is imported only by
//! `src/module_index.zig`, so it is reachable by `zig build test` and unreachable
//! from `executeHourlyScience`. That is intentional and must stay that way.
//!
//! Classification: architecturally superseded. Production stores the same physics in a
//! different representation, deliberately, with the deviation recorded in
//! `docs/model_changes.md`. Binding this kernel would reintroduce the
//! formulation the project chose to leave behind, as a second writer.
//!
//! Superseded by: `gas_transport`, which uses an extensive-mass representation.
//!
//! It stores mass and divides by air-filled volume at the point of use, so
//! a stored concentration field would be a second, staleable copy: the air
//! volume changes every time water or ice moves, and a concentration recorded
//! before that move is wrong afterwards. This is the same representation
//! question EXEC-004 settled for litter solutes (`work_state.md` 971--982).
//!
//! Do not bind this module, and do not delete it: the tests are a source-order
//! comparison oracle for the range above. Full argument and the census behind
//! it: `docs/traceability/hour1_2039_5200_binding_survey.md`.
const std = @import("std");

pub const GaseousMasses = struct {
    carbon_dioxide_g: f64,
    methane_g: f64,
    oxygen_g: f64,
    nitrogen_g: f64,
    nitrous_oxide_g: f64,
    ammonia_g: f64,
    hydrogen_g: f64,
};

pub const AqueousMasses = struct {
    carbon_dioxide_g: f64,
    methane_g: f64,
    oxygen_g: f64,
    nitrogen_g: f64,
    nitrous_oxide_g: f64,
    hydrogen_g: f64,
};

pub const GaseousConcentrations = struct {
    carbon_dioxide_g_m3: f64,
    methane_g_m3: f64,
    oxygen_g_m3: f64,
    nitrogen_g_m3: f64,
    nitrous_oxide_g_m3: f64,
    ammonia_g_m3: f64,
    hydrogen_g_m3: f64,
};

pub const AqueousConcentrations = struct {
    carbon_dioxide_g_m3: f64,
    methane_g_m3: f64,
    oxygen_g_m3: f64,
    nitrogen_g_m3: f64,
    nitrous_oxide_g_m3: f64,
    hydrogen_g_m3: f64,
};

pub const Result = struct {
    gaseous: GaseousConcentrations,
    aqueous: AqueousConcentrations,
};

pub const ConcentrationError = error{
    NonFiniteInput,
    NegativeVolume,
    NonFiniteResult,
};

/// Translates `hour1.f` lines 3760--3791 in source order. Negative legacy gas
/// masses are clamped to zero concentration after division.
pub fn calculate(
    gaseous_masses: GaseousMasses,
    aqueous_masses: AqueousMasses,
    air_filled_volume_m3: f64,
    water_volume_m3: f64,
    air_volume_threshold_m3: f64,
    water_volume_threshold_m3: f64,
) ConcentrationError!Result {
    inline for (std.meta.fields(GaseousMasses)) |field| {
        if (!std.math.isFinite(@field(gaseous_masses, field.name))) {
            return error.NonFiniteInput;
        }
    }
    inline for (std.meta.fields(AqueousMasses)) |field| {
        if (!std.math.isFinite(@field(aqueous_masses, field.name))) {
            return error.NonFiniteInput;
        }
    }
    const volumes = [_]f64{
        air_filled_volume_m3,
        water_volume_m3,
        air_volume_threshold_m3,
        water_volume_threshold_m3,
    };
    for (volumes) |volume| {
        if (!std.math.isFinite(volume)) return error.NonFiniteInput;
        if (volume < 0.0) return error.NegativeVolume;
    }

    const gaseous = if (air_filled_volume_m3 > air_volume_threshold_m3)
        GaseousConcentrations{
            .carbon_dioxide_g_m3 = @max(
                0.0,
                gaseous_masses.carbon_dioxide_g / air_filled_volume_m3,
            ),
            .methane_g_m3 = @max(0.0, gaseous_masses.methane_g / air_filled_volume_m3),
            .oxygen_g_m3 = @max(0.0, gaseous_masses.oxygen_g / air_filled_volume_m3),
            .nitrogen_g_m3 = @max(0.0, gaseous_masses.nitrogen_g / air_filled_volume_m3),
            .nitrous_oxide_g_m3 = @max(
                0.0,
                gaseous_masses.nitrous_oxide_g / air_filled_volume_m3,
            ),
            .ammonia_g_m3 = @max(0.0, gaseous_masses.ammonia_g / air_filled_volume_m3),
            .hydrogen_g_m3 = @max(0.0, gaseous_masses.hydrogen_g / air_filled_volume_m3),
        }
    else
        std.mem.zeroes(GaseousConcentrations);

    const aqueous = if (water_volume_m3 > water_volume_threshold_m3)
        AqueousConcentrations{
            .carbon_dioxide_g_m3 = @max(0.0, aqueous_masses.carbon_dioxide_g / water_volume_m3),
            .methane_g_m3 = @max(0.0, aqueous_masses.methane_g / water_volume_m3),
            .oxygen_g_m3 = @max(0.0, aqueous_masses.oxygen_g / water_volume_m3),
            .nitrogen_g_m3 = @max(0.0, aqueous_masses.nitrogen_g / water_volume_m3),
            .nitrous_oxide_g_m3 = @max(0.0, aqueous_masses.nitrous_oxide_g / water_volume_m3),
            .hydrogen_g_m3 = @max(0.0, aqueous_masses.hydrogen_g / water_volume_m3),
        }
    else
        std.mem.zeroes(AqueousConcentrations);

    inline for (std.meta.fields(GaseousConcentrations)) |field| {
        if (!std.math.isFinite(@field(gaseous, field.name))) return error.NonFiniteResult;
    }
    inline for (std.meta.fields(AqueousConcentrations)) |field| {
        if (!std.math.isFinite(@field(aqueous, field.name))) return error.NonFiniteResult;
    }
    return .{ .gaseous = gaseous, .aqueous = aqueous };
}

test "gas masses divide by their pore-domain volumes" {
    const result = try calculate(
        .{
            .carbon_dioxide_g = 4.0,
            .methane_g = 2.0,
            .oxygen_g = 8.0,
            .nitrogen_g = 10.0,
            .nitrous_oxide_g = 1.0,
            .ammonia_g = -1.0,
            .hydrogen_g = 0.5,
        },
        .{
            .carbon_dioxide_g = 3.0,
            .methane_g = 1.5,
            .oxygen_g = 6.0,
            .nitrogen_g = 9.0,
            .nitrous_oxide_g = 0.3,
            .hydrogen_g = 0.6,
        },
        2.0,
        3.0,
        1.0e-12,
        1.0e-12,
    );
    try std.testing.expectEqual(@as(f64, 2.0), result.gaseous.carbon_dioxide_g_m3);
    try std.testing.expectEqual(@as(f64, 0.0), result.gaseous.ammonia_g_m3);
    try std.testing.expectEqual(@as(f64, 1.0), result.aqueous.carbon_dioxide_g_m3);
}

test "volumes at thresholds produce zero concentrations" {
    const gaseous = std.mem.zeroes(GaseousMasses);
    const aqueous = std.mem.zeroes(AqueousMasses);
    const result = try calculate(gaseous, aqueous, 0.0, 0.0, 0.0, 0.0);
    try std.testing.expectEqual(
        std.mem.zeroes(GaseousConcentrations),
        result.gaseous,
    );
    try std.testing.expectEqual(
        std.mem.zeroes(AqueousConcentrations),
        result.aqueous,
    );
}
