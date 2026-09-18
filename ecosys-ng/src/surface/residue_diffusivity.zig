// **A8a DISPOSITION: RECONCILED; RETAINED ORACLE, PRODUCTION SPLIT-BOUND.**
// `hour1.f:4627--4649` does not have one runtime owner. Its gaseous values are
// bound through `litter_gas_transport_step.zig`, TFND(0) through
// `microbial_environment.zig`, and its aqueous codebook through the bound
// `soil/solute/litter_soil_interface.zig` production transaction.
//
// The former species-map deferral is settled by `hour1.f:73--87` and
// `trnsfr.f:2022--2060,2091--2102`: the fourteen salt classes are distinct
// from DOC/DON/DOP/acetate and NH4/NH3/NO3/NO2/HPO4/H2PO4. The mineral vector
// retains ZNSG=4e-6, ZOSG=6e-6 and POSG=3e-6 in that exact order. Binding this
// combined oracle directly would still duplicate the gas writer.
// RESIDUE-HOUR1 group of docs/traceability/a8a_surface_dispositions.md
//! Historical translation retained as a cross-owner oracle; production is
//! split-bound as recorded above.
//!
//! Translates `hour1.f` 4627--4649, the "GASEOUS AND AQUEOUS DIFFUSIVITY IN
//! LITTER" block, which scales nineteen reference diffusivities at `L=0` by
//! `TFACG=(TKS/298.15)**1.75` (gases) or `TFACL=(TKS/298.15)**6` (solutes) and
//! also publishes `TFND(0)=TFACL`.
//!
//! The block does not map onto one production owner. Its nineteen outputs
//! divide across gas, microbial-environment, and litter/soil interface owners:
//!
//!   - The seven gaseous diffusivities (CGSGL, CHSGL, OGSGL, ZGSGL, Z2SGL,
//!     ZHSGL, HGSGL) are ALREADY OWNED. Bound
//!     `surface/litter_gas_transport_step.zig` carries exactly the same seven
//!     reference values in `free_air_diffusivity_m2_per_h` and applies
//!     `temperature_exponent = 1.75` about `reference_temperature_k = 298.15`
//!     at its line 121. `TFND(0)` is likewise already owned, by bound
//!     `surface/microbial_environment.zig:44`, which exposes the same
//!     sixth-power ratio as `aqueous_diffusion_temperature_response`; and the
//!     aqueous O2 case is owned a third time by bound
//!     `surface/microbial_oxygen.zig:10`. Binding this module would install a
//!     second writer for all of those.
//!
//!   - The aqueous codebook is now bound through
//!     `soil/solute/litter_soil_interface.zig`. Its production caller scales
//!     all reference values by the sixth-power TFACL and the accepted internal
//!     timestep exactly once. The salt, organic, and mineral-N/P families are
//!     separate vectors; focused tests pin their exact source ordering.
//!
//! This combined module remains uncalled because calling it in addition to the
//! split owners would duplicate its gaseous writes.

const std = @import("std");

pub const ReferenceDiffusivities = struct {
    carbon_dioxide_gas_m2_h: f64,
    methane_gas_m2_h: f64,
    oxygen_gas_m2_h: f64,
    nitrogen_gas_m2_h: f64,
    nitrous_oxide_gas_m2_h: f64,
    ammonia_gas_m2_h: f64,
    hydrogen_gas_m2_h: f64,
    methane_aqueous_m2_h: f64,
    oxygen_aqueous_m2_h: f64,
    nitrogen_aqueous_m2_h: f64,
    ammonia_aqueous_m2_h: f64,
    hydrogen_aqueous_m2_h: f64,
    nitrate_aqueous_m2_h: f64,
    nitrous_oxide_aqueous_m2_h: f64,
    dihydrogen_phosphate_aqueous_m2_h: f64,
    dissolved_organic_carbon_m2_h: f64,
    dissolved_organic_nitrogen_m2_h: f64,
    dissolved_organic_phosphorus_m2_h: f64,
    acetate_aqueous_m2_h: f64,
};

pub const AdjustedDiffusivities = ReferenceDiffusivities;

pub const Result = struct {
    gaseous_temperature_factor: f64,
    aqueous_temperature_factor: f64,
    nitrogen_diffusion_temperature_factor: f64,
    diffusivities: AdjustedDiffusivities,
};

pub const CalculationError = error{
    NonFiniteInput,
    NonPositiveTemperature,
    NegativeReferenceDiffusivity,
    NonFiniteResult,
};

/// Translates `hour1.f` lines 4628--4649 for one surface-residue layer.
pub fn calculate(
    residue_temperature_k: f64,
    reference: ReferenceDiffusivities,
) CalculationError!Result {
    if (!std.math.isFinite(residue_temperature_k)) return error.NonFiniteInput;
    if (residue_temperature_k <= 0.0) return error.NonPositiveTemperature;
    inline for (std.meta.fields(ReferenceDiffusivities)) |field| {
        const value = @field(reference, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteInput;
        if (value < 0.0) return error.NegativeReferenceDiffusivity;
    }

    const relative_temperature = residue_temperature_k / 298.15;
    const gaseous_temperature_factor = std.math.pow(f64, relative_temperature, 1.75);
    const aqueous_temperature_factor = std.math.pow(f64, relative_temperature, 6.0);

    // Preserve the assignment order in HOUR1: nitrogen diffusion receives
    // the aqueous factor before individual gas and solute diffusivities.
    const nitrogen_diffusion_temperature_factor = aqueous_temperature_factor;
    const diffusivities = AdjustedDiffusivities{
        .carbon_dioxide_gas_m2_h = reference.carbon_dioxide_gas_m2_h *
            gaseous_temperature_factor,
        .methane_gas_m2_h = reference.methane_gas_m2_h * gaseous_temperature_factor,
        .oxygen_gas_m2_h = reference.oxygen_gas_m2_h * gaseous_temperature_factor,
        .nitrogen_gas_m2_h = reference.nitrogen_gas_m2_h * gaseous_temperature_factor,
        .nitrous_oxide_gas_m2_h = reference.nitrous_oxide_gas_m2_h *
            gaseous_temperature_factor,
        .ammonia_gas_m2_h = reference.ammonia_gas_m2_h * gaseous_temperature_factor,
        .hydrogen_gas_m2_h = reference.hydrogen_gas_m2_h * gaseous_temperature_factor,
        .methane_aqueous_m2_h = reference.methane_aqueous_m2_h *
            aqueous_temperature_factor,
        .oxygen_aqueous_m2_h = reference.oxygen_aqueous_m2_h *
            aqueous_temperature_factor,
        .nitrogen_aqueous_m2_h = reference.nitrogen_aqueous_m2_h *
            aqueous_temperature_factor,
        .ammonia_aqueous_m2_h = reference.ammonia_aqueous_m2_h *
            aqueous_temperature_factor,
        .hydrogen_aqueous_m2_h = reference.hydrogen_aqueous_m2_h *
            aqueous_temperature_factor,
        .nitrate_aqueous_m2_h = reference.nitrate_aqueous_m2_h *
            aqueous_temperature_factor,
        .nitrous_oxide_aqueous_m2_h = reference.nitrous_oxide_aqueous_m2_h *
            aqueous_temperature_factor,
        .dihydrogen_phosphate_aqueous_m2_h = reference.dihydrogen_phosphate_aqueous_m2_h *
            aqueous_temperature_factor,
        .dissolved_organic_carbon_m2_h = reference.dissolved_organic_carbon_m2_h *
            aqueous_temperature_factor,
        .dissolved_organic_nitrogen_m2_h = reference.dissolved_organic_nitrogen_m2_h *
            aqueous_temperature_factor,
        .dissolved_organic_phosphorus_m2_h = reference.dissolved_organic_phosphorus_m2_h *
            aqueous_temperature_factor,
        .acetate_aqueous_m2_h = reference.acetate_aqueous_m2_h *
            aqueous_temperature_factor,
    };

    if (!std.math.isFinite(gaseous_temperature_factor) or
        !std.math.isFinite(aqueous_temperature_factor))
    {
        return error.NonFiniteResult;
    }
    inline for (std.meta.fields(AdjustedDiffusivities)) |field| {
        if (!std.math.isFinite(@field(diffusivities, field.name))) {
            return error.NonFiniteResult;
        }
    }
    return .{
        .gaseous_temperature_factor = gaseous_temperature_factor,
        .aqueous_temperature_factor = aqueous_temperature_factor,
        .nitrogen_diffusion_temperature_factor = nitrogen_diffusion_temperature_factor,
        .diffusivities = diffusivities,
    };
}

fn testReferenceDiffusivities() ReferenceDiffusivities {
    return .{
        .carbon_dioxide_gas_m2_h = 4.68e-2,
        .methane_gas_m2_h = 7.80e-2,
        .oxygen_gas_m2_h = 6.43e-2,
        .nitrogen_gas_m2_h = 5.57e-2,
        .nitrous_oxide_gas_m2_h = 5.57e-2,
        .ammonia_gas_m2_h = 6.67e-2,
        .hydrogen_gas_m2_h = 5.57e-2,
        .methane_aqueous_m2_h = 7.08e-6,
        .oxygen_aqueous_m2_h = 8.57e-6,
        .nitrogen_aqueous_m2_h = 7.34e-6,
        .ammonia_aqueous_m2_h = 4.00e-6,
        .hydrogen_aqueous_m2_h = 7.34e-6,
        .nitrate_aqueous_m2_h = 6.00e-6,
        .nitrous_oxide_aqueous_m2_h = 5.72e-6,
        .dihydrogen_phosphate_aqueous_m2_h = 3.00e-6,
        .dissolved_organic_carbon_m2_h = 1.00e-8,
        .dissolved_organic_nitrogen_m2_h = 1.00e-8,
        .dissolved_organic_phosphorus_m2_h = 1.00e-8,
        .acetate_aqueous_m2_h = 3.64e-6,
    };
}

test "reference temperature preserves every residue diffusivity" {
    const reference = testReferenceDiffusivities();
    const result = try calculate(298.15, reference);

    try std.testing.expectEqual(@as(f64, 1.0), result.gaseous_temperature_factor);
    try std.testing.expectEqual(@as(f64, 1.0), result.aqueous_temperature_factor);
    try std.testing.expectEqual(reference, result.diffusivities);
}

test "gas and aqueous diffusivities use their distinct temperature exponents" {
    const reference = testReferenceDiffusivities();
    const temperature_k = 280.0;
    const result = try calculate(temperature_k, reference);
    const expected_gas_factor = std.math.pow(f64, temperature_k / 298.15, 1.75);
    const expected_aqueous_factor = std.math.pow(f64, temperature_k / 298.15, 6.0);

    try std.testing.expectApproxEqRel(
        reference.oxygen_gas_m2_h * expected_gas_factor,
        result.diffusivities.oxygen_gas_m2_h,
        1.0e-14,
    );
    try std.testing.expectApproxEqRel(
        reference.nitrate_aqueous_m2_h * expected_aqueous_factor,
        result.diffusivities.nitrate_aqueous_m2_h,
        1.0e-14,
    );
    try std.testing.expectEqual(
        result.aqueous_temperature_factor,
        result.nitrogen_diffusion_temperature_factor,
    );
}

test "gaseous half agrees with the bound litter gas transport owner" {
    // Cross-module pin, not a self-check: if either the bound owner or this
    // module drifts from the shared `*SG` codebook, the duplicate-ownership
    // finding recorded in the header stops being true and this fails.
    const bound = @import("litter_gas_transport_step.zig").RuntimeParameters{};
    try std.testing.expectEqual(@as(f64, 1.75), bound.temperature_exponent);
    try std.testing.expectEqual(@as(f64, 298.15), bound.reference_temperature_k);

    const reference = testReferenceDiffusivities();
    const temperature_k = 288.0;
    const result = try calculate(temperature_k, reference);
    const factor = std.math.pow(f64, temperature_k / bound.reference_temperature_k, bound.temperature_exponent);
    // hour1.f gas order: CGSG, CHSG, OGSG, ZGSG, Z2SG, ZHSG, HGSG. The bound
    // owner's species order is CO2, CH4, O2, N2, N2O, NH3, H2.
    const mine = [_]f64{
        result.diffusivities.carbon_dioxide_gas_m2_h,
        result.diffusivities.methane_gas_m2_h,
        result.diffusivities.oxygen_gas_m2_h,
        result.diffusivities.nitrogen_gas_m2_h,
        result.diffusivities.nitrous_oxide_gas_m2_h,
        result.diffusivities.ammonia_gas_m2_h,
        result.diffusivities.hydrogen_gas_m2_h,
    };
    for (bound.free_air_diffusivity_m2_per_h, mine) |free_air, scaled|
        try std.testing.expectApproxEqRel(free_air * factor, scaled, 1.0e-14);

    // Falsifiability companion: the aqueous exponent must NOT be 1.75, or the
    // two-halves split the header asserts would be vacuous.
    try std.testing.expect(result.aqueous_temperature_factor != result.gaseous_temperature_factor);
}

test "aqueous half agrees with the sixth-power owners of TFACL" {
    const litter_temperature_k = 288.0;
    const environment_factor = std.math.pow(f64, litter_temperature_k / 298.15, 6);
    const result = try calculate(litter_temperature_k, testReferenceDiffusivities());
    // Not bit-exact: the bound owner writes `pow(.., 6)` and this module writes
    // `pow(.., 6.0)`, and Zig lowers the comptime_int exponent differently.
    // That 1-ulp gap is itself worth recording, because it means the two owners
    // are not substitutable under an exact-equality legacy comparison.
    try std.testing.expectApproxEqRel(environment_factor, result.aqueous_temperature_factor, 1.0e-15);
    try std.testing.expectEqual(result.aqueous_temperature_factor, result.nitrogen_diffusion_temperature_factor);

    // hour1.f 4636 applies TFACL to OLSG; surface/microbial_oxygen.zig owns the
    // same product for the aerobic-uptake path.
    const oxygen = @import("microbial_oxygen.zig");
    try std.testing.expectApproxEqRel(
        try oxygen.aqueousOxygenDiffusivity_m2_per_step(8.57e-6, litter_temperature_k, 1),
        result.diffusivities.oxygen_aqueous_m2_h,
        1.0e-14,
    );
}
