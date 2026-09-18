// **CURRENT DISPOSITION: BOUND.** `carboxylation.zig` imports this module and
// calls `calculate` for every admitted illuminated beam before the leaf CO2
// solve. Register CANOPY-WFNB-RS-001 was closed by that production binding.
// The detailed text below is the pre-binding audit record; its descriptions
// of the former plant-level approximation are historical, not current status.
//
// Science: grosub.f:1026--1053, verified verbatim, and repeated at :1206--1234,
// :1412--1435, and :1546--1569 for the direct and diffuse beams of the C4 and
// C3 paths. The source computes, per illuminated leaf sample,
// RS=AMIN1(RCMX,AMAX1(RCMN,DCO2/VL)) at :1027, then
// RSL=RS+(RCMX-RS)*WFNSC at :1028, GSL=1.0/RSL*FMOL at :1029, and finally the
// water response at :1046--1053: WFNB=(RS/RSL)**0.667 with WFN4=WFNB when
// IGTYP.NE.0, else WFNB=WFNSG and WFN4=WFNB.
//
// The family argument, stated in full here rather than by cross-reference.
// The stomate.f/grosub.f canopy carboxylation chain was translated twice. One
// translation became this directory's fine-grained per-step modules; the other
// became the two production kernels canopy/photosynthesis/biochemistry.zig
// (the stomate.f capacity side) and canopy/photosynthesis/carboxylation.zig
// (the grosub.f leaf-CO2-balance side). Production kept the two kernels. Both
// are reachable: stages/hourly_science_vegetation.zig:275 runs
// ecosys.canopy_carboxylation.applyTile across the serial tiles, and
// canopy_biochemistry runs upstream of it in the same stage. Every module in
// this directory listed as unbound is referenced only from
// src/index/canopy_test_index.zig; that was checked per module by grepping the
// module_index alias and discarding the module_index line itself.
//
// Why this is a GAP and not a supersession. The nearest production code is
// canopy/photosynthesis/carboxylation.zig:88--98, and it is not a translation
// of the above. Two distinct policies are missing.
//
// First, the per-sample resistance. The source recomputes RS for every
// illuminated sample from that sample's own preliminary carboxylation rate VL,
// as DCO2/VL clamped into [RCMN, RCMX], so a shaded or nitrogen-poor leaf gets
// a larger stomatal resistance and a correspondingly weaker water response
// than a sunlit one on the same plant in the same hour. Production reads a
// single plant-level pair instead: current_resistance_h_per_m from the surface
// workspace and minimum_resistance_h_per_m from
// plant_minimum_water_vapor_resistance_h_per_m, bound at
// stages/hourly_science_vegetation.zig:264--265, and forms one
// water_stress_fraction per plant at :95--98 that every sample then shares.
// The production minimum is RSMN from stomate.f:656--662, which is a
// canopy-integrated quantity computed from the whole-canopy CH2O of the
// previous call (owner canopy/energy/minimum_stomatal_resistance.zig:18,
// reached via soil/biogeochemistry/uptake_coupled_transaction.zig:188 from
// ecosys_ng.zig:5098). RSMN and RS are different variables in the source and
// production has substituted one for the other. Grep confirms no production
// code forms DCO2/VL per sample: the only atmospheric_to_intercellular CO2
// gradient consumers are canopy/gas/aqueous_environment.zig:34 and the
// canopy-level canopy/energy/stomatal_resistance.zig:89.
//
// Second, the shallow-profile formula. On the IGTYP.EQ.0 arm the source sets
// WFNB=WFNSG, and WFNSG for that arm is EXP(0.05*PSILT) at grosub.f:538, an
// exponential in the canopy *water* potential. Production instead uses
// clamp(turgor_potential - minimum_turgor_potential, 0, 1) at
// carboxylation.zig:96, which is the source's WFNST at grosub.f:535, a
// different variable serving the turgor expansion and extension function. A
// linear clamp on turgor has been substituted for an exponential in water
// potential.
//
// Non-vacuity, honestly bounded. The second divergence is currently
// unreachable in the shipped Ottawa example: root_profile_type is the second
// functional-type token (parsed at state/plant_traits.zig:134) and the three
// plant files in examples-ng/Cool Temperate Maize-Soybean ON carry 2, 3, and 1,
// never 0, so no shipped plant takes the shallow arm. It is recorded because a
// bryophyte or moss parameterization would take it immediately and would then
// silently run the wrong function. The first divergence is live for every
// plant on every hour, and its magnitude grows with the spread of illumination
// across the canopy, which is exactly the spread the sample discretization
// exists to resolve.
//
// Why no guard catches it. Both forms are dimensionless multipliers in [0,1]
// applied to a carboxylation rate. Mass is conserved either way, so no
// conservation residual can move; the fields involved are all written every
// hour, so the unwritten-field guard is satisfied; and every value stays
// finite, so the finiteness checks pass. Only the magnitude of fixation
// changes.
//
// Reader warning, by name. Three modules look like they might already own this
// and none do. canopy/energy/minimum_stomatal_resistance.zig is bound but
// computes RSMN from stomate.f:656--662, a canopy quantity, not RS from
// grosub.f:1027. canopy/energy/stomatal_resistance.zig is bound and holds
// gasEnvironment and c3Capacity but has no WFNB. canopy/energy/surface_exchange
// .zig:180--181 forms the RSL-shaped sum minimum+(cuticular-minimum)*water_stress
// for the *water vapor* surface exchange, not for CO2, and feeds the workspace
// that carboxylation.zig then reads; mistaking it for the owner is the easiest
// error available here.
//
// Related and separate. CANOPY-TURGOR-001 records that
// plant_canopy_turgor_potential_megapascal is never updated after planting.
// That compounds this gap, since the substituted formula reads a frozen input,
// but it is a different defect and neither entry subsumes the other.
//
// STOMATE-CARBOX group of docs/traceability/stomate_grosub_canopy_carboxylation.md
const std = @import("std");

pub const RootProfile = enum {
    shallow,
    non_shallow,
};

pub const Inputs = struct {
    preliminary_carboxylation_umol_per_m2_s: f64,
    negligible_carboxylation_umol_per_m2_s: f64,
    atmospheric_to_intercellular_co2_umol_per_m3: f64,
    minimum_stomatal_resistance_s_per_m: f64,
    cuticular_resistance_s_per_m: f64,
    stomatal_turgor_response: f64,
    air_amount_mol_per_m3: f64,
    root_profile: RootProfile,
    shallow_root_growth_water_response: f64,
};

pub const Response = struct {
    admitted: bool,
    zero_water_stress_resistance_s_per_m: f64,
    current_resistance_s_per_m: f64,
    stomatal_conductance_mol_per_m2_s: f64,
    c3_water_response: f64,
    c4_water_response: f64,
};

/// Exact grosub.f lines 1026--1053, repeated at 1206--1234, 1412--1435, and
/// 1546--1569, for one illuminated leaf sample. The same operation applies to
/// direct and diffuse radiation and to both C4 mesophyll and C3 mesophyll
/// paths; C4 additionally copies the C3 response into WFN4.
pub fn calculate(inputs: Inputs) !Response {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (field.type == f64) {
            const value = @field(inputs, field.name);
            if (!std.math.isFinite(value))
                return error.NonFiniteCanopyCarboxylationWaterInput;
        }
    }
    if (inputs.preliminary_carboxylation_umol_per_m2_s < 0 or
        inputs.negligible_carboxylation_umol_per_m2_s < 0 or
        inputs.minimum_stomatal_resistance_s_per_m <= 0 or
        inputs.cuticular_resistance_s_per_m <
            inputs.minimum_stomatal_resistance_s_per_m or
        inputs.stomatal_turgor_response < 0 or
        inputs.air_amount_mol_per_m3 <= 0 or
        inputs.shallow_root_growth_water_response < 0)
        return error.InvalidCanopyCarboxylationWaterInput;
    if (inputs.preliminary_carboxylation_umol_per_m2_s <=
        inputs.negligible_carboxylation_umol_per_m2_s)
        return .{
            .admitted = false,
            .zero_water_stress_resistance_s_per_m = 0,
            .current_resistance_s_per_m = 0,
            .stomatal_conductance_mol_per_m2_s = 0,
            .c3_water_response = 0,
            .c4_water_response = 0,
        };

    const zero_water_stress_resistance_s_per_m = @min(
        inputs.cuticular_resistance_s_per_m,
        @max(
            inputs.minimum_stomatal_resistance_s_per_m,
            inputs.atmospheric_to_intercellular_co2_umol_per_m3 /
                inputs.preliminary_carboxylation_umol_per_m2_s,
        ),
    );
    const current_resistance_s_per_m =
        zero_water_stress_resistance_s_per_m +
        (inputs.cuticular_resistance_s_per_m -
            zero_water_stress_resistance_s_per_m) *
            inputs.stomatal_turgor_response;
    const stomatal_conductance_mol_per_m2_s =
        inputs.air_amount_mol_per_m3 / current_resistance_s_per_m;
    const water_response = switch (inputs.root_profile) {
        .non_shallow => std.math.pow(
            f64,
            zero_water_stress_resistance_s_per_m /
                current_resistance_s_per_m,
            0.667,
        ),
        .shallow => inputs.shallow_root_growth_water_response,
    };
    inline for (.{ current_resistance_s_per_m, stomatal_conductance_mol_per_m2_s, water_response }) |value|
        if (!std.math.isFinite(value))
            return error.NonFiniteCanopyCarboxylationWaterResponse;
    return .{
        .admitted = true,
        .zero_water_stress_resistance_s_per_m = zero_water_stress_resistance_s_per_m,
        .current_resistance_s_per_m = current_resistance_s_per_m,
        .stomatal_conductance_mol_per_m2_s = stomatal_conductance_mol_per_m2_s,
        .c3_water_response = water_response,
        .c4_water_response = water_response,
    };
}

fn sampleInputs() Inputs {
    return .{
        .preliminary_carboxylation_umol_per_m2_s = 20,
        .negligible_carboxylation_umol_per_m2_s = 1.0e-12,
        .atmospheric_to_intercellular_co2_umol_per_m3 = 2000,
        .minimum_stomatal_resistance_s_per_m = 50,
        .cuticular_resistance_s_per_m = 5000,
        .stomatal_turgor_response = 0.25,
        .air_amount_mol_per_m3 = 40,
        .root_profile = .non_shallow,
        .shallow_root_growth_water_response = 0.7,
    };
}

test "GROSUB deeper-root water response preserves source operation order" {
    const response = try calculate(sampleInputs());
    const source_resistance: f64 = 100;
    const current_resistance = source_resistance + (5000 - source_resistance) * 0.25;
    try std.testing.expect(response.admitted);
    try std.testing.expectEqual(source_resistance, response.zero_water_stress_resistance_s_per_m);
    try std.testing.expectEqual(current_resistance, response.current_resistance_s_per_m);
    try std.testing.expectEqual(40 / current_resistance, response.stomatal_conductance_mol_per_m2_s);
    try std.testing.expectEqual(
        std.math.pow(f64, source_resistance / current_resistance, 0.667),
        response.c4_water_response,
    );
    try std.testing.expectEqual(response.c3_water_response, response.c4_water_response);
}

test "GROSUB shallow roots use canopy growth water response" {
    var inputs = sampleInputs();
    inputs.root_profile = .shallow;
    const response = try calculate(inputs);
    try std.testing.expectEqual(@as(f64, 0.7), response.c3_water_response);
    try std.testing.expectEqual(@as(f64, 0.7), response.c4_water_response);
}

test "source permits responses above one and negative CO2 gradient before resistance bounding" {
    var inputs = sampleInputs();
    inputs.atmospheric_to_intercellular_co2_umol_per_m3 = -1;
    inputs.stomatal_turgor_response = 2;
    const non_shallow = try calculate(inputs);
    try std.testing.expectEqual(
        inputs.minimum_stomatal_resistance_s_per_m,
        non_shallow.zero_water_stress_resistance_s_per_m,
    );
    const expected_current = inputs.minimum_stomatal_resistance_s_per_m +
        (inputs.cuticular_resistance_s_per_m -
            inputs.minimum_stomatal_resistance_s_per_m) * 2;
    try std.testing.expectEqual(expected_current, non_shallow.current_resistance_s_per_m);

    inputs.root_profile = .shallow;
    inputs.shallow_root_growth_water_response = 1.2;
    const shallow = try calculate(inputs);
    try std.testing.expectEqual(@as(f64, 1.2), shallow.c3_water_response);
    try std.testing.expectEqual(@as(f64, 1.2), shallow.c4_water_response);
}

test "preliminary rate comparison remains strict at source threshold" {
    var inputs = sampleInputs();
    inputs.preliminary_carboxylation_umol_per_m2_s =
        inputs.negligible_carboxylation_umol_per_m2_s;
    const response = try calculate(inputs);
    try std.testing.expect(!response.admitted);
}

test "invalid canopy water-response input fails explicitly" {
    var inputs = sampleInputs();
    inputs.cuticular_resistance_s_per_m = 49;
    try std.testing.expectError(
        error.InvalidCanopyCarboxylationWaterInput,
        calculate(inputs),
    );
    inputs = sampleInputs();
    inputs.air_amount_mol_per_m3 = std.math.nan(f64);
    try std.testing.expectError(
        error.NonFiniteCanopyCarboxylationWaterInput,
        calculate(inputs),
    );
}
