// **A8a DISPOSITION: SUPERSEDED BY CORRECTED BOUND OWNER; SOIL-EHUM-001 is
// closed.** `soil/microbial/turnover_step.zig` now includes the parameterized
// `0.182e-6 * CORGC` term and receives the production organic-carbon carrier.
//
// **HISTORICAL A8a DISPOSITION: keep unbound. This module is *more correct* than the bound
// owner, and it is the evidence for register finding SOIL-EHUM-001.**
//
// The formula here is `hour1.f:2910--2911` verbatim, and the same three-term law
// appears at `hour1.f:3738--3739` for every mineral layer: `EHUM = 0.150 +
// 0.300*AMIN1(0.333,CCLAY) + 0.182E-06*CORGC`. The production owner of `EHUM` is
// `soil/microbial/turnover_step.zig:86`, which computes only the first two terms
// - `turnover.humification_intercept + turnover.humification_clay_coefficient *
// @min(turnover.humification_maximum_clay_fraction, clay_mass_fraction[layer])`,
// with the three constants parameterized at
// `soil/nutrients/nitrogen_parameters.zig:226--228` - and hands the result to
// `metabolism.decompose` as `humification_fraction`. There is no fourth
// parameter, and `ApplyContext` (`turnover_step.zig:41`) takes no organic-carbon
// slice, so the `CORGC` term is not merely unparameterized: it is absent. A
// repository-wide search for `0.182e-6` finds exactly one hit, line 33 of this
// file.
//
// So this is *not* a supersession. Binding it as written would still be wrong,
// because the coefficient belongs on the owner's parameter record next to the
// three that are already there, not in a standalone helper that the hourly
// microbial step does not call. And leaving it unbound is not "settled" either:
// the missing term is a real, one-signed, cumulative bias. `EHUM` is a split,
// not a scale factor - `nitro.f:2718--2721` and `2794--2797` route decomposition
// products to humus by this fraction, so carbon it does not capture is respired
// or recycled instead. In the configured Ottawa surface layer
// (`CORGC = 14 850` g Mg-1, `CCLAY = 0.2656`) legacy gives 0.23239 against
// production's 0.22969, a 1.18 percent under-allocation; at legacy's own `CORGC`
// ceiling of `0.55E+06` the dropped term is worth 0.1001, which slightly exceeds
// the entire clay term's maximum of 0.0999, so on an organic soil production
// would stabilize roughly a third less carbon than legacy.
//
// Two things to not infer. First, the surface-residue site cited above is not a
// separate law: `hour1.f:2910` evaluates the identical expression using the top
// mineral layer's `CCLAY(NU)` and `CORGC(NU)`, so a fix at the owner covers both
// once layer 0 reads the `NU` values. Second, `soil/heat/solid_thermal_porosity
// .zig:112` uses `1.82e-6` on the same `organic_carbon_concentration_g_per_mega
// gram` carrier; that is a different coefficient for a different purpose (the
// organic solid-fraction weight) and is not this term recovered elsewhere. It
// does, however, prove the carrier production needs already exists and only has
// to be routed.
//
// Retain this module as the reference implementation and the reproduction case
// for the fix. Do not banner it as bound or as deliberately superseded.
//
// SOIL-EHUM-001 of docs/discrepancy_register.md

const std = @import("std");

pub const AllocationError = error{
    NonFiniteInput,
    InvalidClayMassFraction,
    InvalidOrganicCarbonConcentration,
    InvalidAllocationFraction,
};

/// Translates `hour1.f` lines 2910--2911 (EHUM).
///
/// `surface_clay_megagrams_megagrams` is Mg clay per Mg soil,
/// `soil_organic_carbon_g_per_megagram` is g C per Mg soil, and the result is the
/// dimensionless fraction of microbial decomposition product sent to humus.
pub fn humusAllocationFraction(
    surface_clay_megagrams_megagrams: f64,
    soil_organic_carbon_g_per_megagram: f64,
) AllocationError!f64 {
    if (!std.math.isFinite(surface_clay_megagrams_megagrams) or
        !std.math.isFinite(soil_organic_carbon_g_per_megagram))
    {
        return error.NonFiniteInput;
    }
    if (surface_clay_megagrams_megagrams < 0.0 or surface_clay_megagrams_megagrams > 1.0) {
        return error.InvalidClayMassFraction;
    }
    if (soil_organic_carbon_g_per_megagram < 0.0) {
        return error.InvalidOrganicCarbonConcentration;
    }

    const allocation_fraction = 0.150 +
        0.300 * @min(0.333, surface_clay_megagrams_megagrams) +
        0.182e-6 * soil_organic_carbon_g_per_megagram;
    if (!std.math.isFinite(allocation_fraction) or
        allocation_fraction < 0.0 or allocation_fraction > 1.0)
    {
        return error.InvalidAllocationFraction;
    }
    return allocation_fraction;
}

test "humus allocation preserves legacy operation order below clay cap" {
    const fraction = try humusAllocationFraction(0.2, 100_000.0);
    const expected = 0.150 + 0.300 * 0.2 + 0.182e-6 * 100_000.0;
    try std.testing.expectEqual(expected, fraction);
}

test "clay contribution is capped at legacy mass fraction" {
    const at_cap = try humusAllocationFraction(0.333, 0.0);
    const above_cap = try humusAllocationFraction(0.8, 0.0);
    try std.testing.expectEqual(at_cap, above_cap);
}

test "allocation exceeding a physical fraction fails explicitly" {
    try std.testing.expectError(
        error.InvalidAllocationFraction,
        humusAllocationFraction(0.2, 5_000_000.0),
    );
}
