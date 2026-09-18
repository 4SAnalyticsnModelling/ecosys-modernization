//! Source `NITRO.F` product-energy feedback and the anaerobic growth
//! respiration requirement `ECHZ` that depends on it.
//!
//! Source statements owned here, in source order:
//!
//! | source | statement | owner |
//! |---|---|---|
//! | 556--557 | `GH2X=8.3143E-03*TKS*LOG((AMAX1(1.0E-03,CH2GS)/H2KI)**4)` | `hydrogenFeedbackEnergy_kilojoule_per_mol` |
//! | 918 | `GH2F=GH2X/72.0` | `FermenterFeedback.hydrogen_kilojoule_per_g_c` |
//! | 919--920 | `GOAX=8.3143E-03*TKS*LOG((AMAX1(ZERO,COQA)/OAKI)**2)` | `FermenterFeedback.acetate_kilojoule_per_mol` |
//! | 921 | `GOAF=GOAX/72.0` | `FermenterFeedback.acetate_kilojoule_per_g_c` |
//! | 922 | `GHAX=GH2F+GOAF` | `FermenterFeedback.combined_kilojoule_per_g_c` |
//! | 924--925 | `ECHZ=AMAX1(EO2X,AMIN1(1.0,1.0/(1.0+AMAX1(0.0,(GCHX-GHAX))/EOMF)))` | `fermenterRequirement` (N=4) |
//! | 927--928 | `ECHZ=AMAX1(ENFY,AMIN1(1.0,1.0/(1.0+AMAX1(0.0,(GCHX-GHAX))/EOMY)))` | `fermenterRequirement` (N=7) |
//! | 1000--1001 | `GOMX=8.3143E-03*TKS*LOG((AMAX1(ZERO,COQA)/OAKI))` | `acetotrophicFeedback` |
//! | 1002 | `GOMM=GOMX/24.0` | `acetotrophicFeedback` |
//! | 1003--1004 | `ECHZ=AMAX1(EO2X,AMIN1(1.0,1.0/(1.0+AMAX1(0.0,(GC4X+GOMM))/EOMH)))` | `acetotrophicRequirement` (N=5) |
//! | 1317 | `GH2H=GH2X/12.0` | `hydrogenotrophicCarbonBasisFeedback` |
//!
//! The `ECHZ` reciprocal algebra itself is not duplicated here. It is owned by
//! `soil_nitrogen_parameters.AnaerobicGrowthEnergyParameters`, whose two
//! methods this module composes. Everything in this module is the *feedback
//! energy* that those methods consume, which is the part production was
//! missing.
//!
//! Why this module exists: `docs/traceability/bind_nitro_001_double_mutation_analysis.md`
//! established that `soil_heterotrophic_respiration_step` is already the single
//! production owner of both anaerobic respiration branches, and that its defect
//! is a *constant* growth respiration requirement where the source has a
//! function of hourly product energy. The two isolated kernels
//! (`soil_fermenter_respiration`, `soil_acetotrophic_methanogenesis`) must not
//! be bound as second writers. This module therefore supplies the missing
//! physics to the existing owner and publishes nothing itself.
//!
//! Every entry point is allocation-free, returns by value, and validates its
//! full input domain before computing, so a rejected call cannot leave partial
//! state anywhere.

const std = @import("std");
const nitrogen_parameters = @import("../nutrients/nitrogen_parameters.zig");

/// Stoichiometric carbon basis for each source feedback conversion, in gram
/// carbon per mole of the reaction the feedback energy is expressed over.
/// These are the source divisors and carry no other meaning.
pub const CarbonBasis = struct {
    /// Source 918 and 921 divisor `72.0`, shared by the fermenter branch's
    /// hydrogen and acetate feedback.
    fermentation_g_c_per_mol: f64,
    /// Source 1002 divisor `24.0`, acetotrophic methanogenesis.
    acetotrophic_methanogenesis_g_c_per_mol: f64,
    /// Source 1317 divisor `12.0`, hydrogenotrophic methanogenesis.
    hydrogenotrophic_methanogenesis_g_c_per_mol: f64,

    pub fn validate(self: CarbonBasis) !void {
        inline for (@typeInfo(CarbonBasis).@"struct".fields) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value <= 0)
                return error.InvalidAnaerobicCarbonBasis;
        }
    }
};

/// Source divisors from `NITRO.F` 918, 921, 1002, and 1317.
pub const source_carbon_basis: CarbonBasis = .{
    .fermentation_g_c_per_mol = 72,
    .acetotrophic_methanogenesis_g_c_per_mol = 24,
    .hydrogenotrophic_methanogenesis_g_c_per_mol = 12,
};

/// Product-inhibition reference concentrations and the thermodynamic gas
/// constant, all source values from the `NITRO.F` 65--235 parameter block.
pub const FeedbackEnvironmentParameters = struct {
    /// `8.3143E-03`, kilojoule per mole per kelvin.
    gas_constant_kilojoule_per_mol_kelvin: f64,
    /// `H2KI`, hydrogen product inhibition reference (gram hydrogen per m3).
    hydrogen_product_inhibition_g_h_per_m3: f64,
    /// `OAKI`, acetate product inhibition reference (gram carbon per m3).
    acetate_product_inhibition_g_c_per_m3: f64,
    /// Source `AMAX1(1.0E-03, CH2GS)` floor at line 557.
    minimum_hydrogen_concentration_g_h_per_m3: f64,
    /// Source `AMAX1(ZERO, COQA)` floor at lines 920 and 1001.
    minimum_acetate_concentration_g_c_per_m3: f64,
    /// Source exponent `**4` at line 557.
    hydrogen_feedback_stoichiometric_exponent: f64,
    /// Source exponent `**2` at line 920. The acetotrophic branch at line
    /// 1001 has no exponent, which is exponent one and is not configurable.
    fermenter_acetate_feedback_stoichiometric_exponent: f64,

    pub fn validate(self: FeedbackEnvironmentParameters) !void {
        inline for (@typeInfo(FeedbackEnvironmentParameters).@"struct".fields) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value <= 0)
                return error.InvalidAnaerobicFeedbackParameter;
        }
    }
};

/// Source defaults: `NITRO.F` 95 (`H2KI=1.0`, `OAKI=12.0`), 556--557, 920.
pub const source_feedback_environment: FeedbackEnvironmentParameters = .{
    .gas_constant_kilojoule_per_mol_kelvin = 8.3143e-3,
    .hydrogen_product_inhibition_g_h_per_m3 = 1,
    .acetate_product_inhibition_g_c_per_m3 = 12,
    .minimum_hydrogen_concentration_g_h_per_m3 = 1e-3,
    .minimum_acetate_concentration_g_c_per_m3 = 1e-15,
    .hydrogen_feedback_stoichiometric_exponent = 4,
    .fermenter_acetate_feedback_stoichiometric_exponent = 2,
};

/// Evaluates the source's `LOG(numerator/reference)` without changing its
/// ordinary finite operation order. Only an overflowed or underflowed division
/// uses the algebraically identical difference of logarithms.
pub fn sourceOrderedLogPositiveRatio(
    numerator: f64,
    reference: f64,
) f64 {
    const ratio = numerator / reference;
    if (std.math.isFinite(ratio) and ratio > 0) return @log(ratio);
    return @log(numerator) - @log(reference);
}

/// Evaluates the source's `LOG((numerator/reference)**exponent)` while keeping
/// normal finite results bit-for-bit unchanged. The first fallback avoids a
/// power-range failure without introducing separate-log cancellation; only an
/// unrepresentable division needs `log(numerator) - log(reference)`.
pub fn sourceOrderedLogPositiveRatioPower(
    numerator: f64,
    reference: f64,
    exponent: f64,
) f64 {
    const ratio = numerator / reference;
    const powered_ratio = std.math.pow(f64, ratio, exponent);
    if (std.math.isFinite(powered_ratio) and powered_ratio > 0)
        return @log(powered_ratio);
    if (std.math.isFinite(ratio) and ratio > 0)
        return exponent * @log(ratio);
    return exponent * (@log(numerator) - @log(reference));
}

/// Exact source 556--557 `GH2X`, in kilojoule per mole. This is the single
/// hydrogen feedback energy the source computes once per layer and then
/// rescales per population.
pub fn hydrogenFeedbackEnergy_kilojoule_per_mol(
    soil_temperature_kelvin: f64,
    aqueous_hydrogen_concentration_g_h_per_m3: f64,
    parameters: FeedbackEnvironmentParameters,
) !f64 {
    try parameters.validate();
    if (!std.math.isFinite(soil_temperature_kelvin) or
        soil_temperature_kelvin <= 0 or
        !std.math.isFinite(aqueous_hydrogen_concentration_g_h_per_m3) or
        aqueous_hydrogen_concentration_g_h_per_m3 < 0)
        return error.InvalidAnaerobicFeedbackEnvironment;
    const bounded_concentration = @max(
        parameters.minimum_hydrogen_concentration_g_h_per_m3,
        aqueous_hydrogen_concentration_g_h_per_m3,
    );
    const energy = parameters.gas_constant_kilojoule_per_mol_kelvin *
        soil_temperature_kelvin *
        sourceOrderedLogPositiveRatioPower(
            bounded_concentration,
            parameters.hydrogen_product_inhibition_g_h_per_m3,
            parameters.hydrogen_feedback_stoichiometric_exponent,
        );
    if (!std.math.isFinite(energy))
        return error.NonFiniteAnaerobicFeedbackEnergy;
    return energy;
}

/// Exact source 1317 `GH2H`. The hydrogenotrophic branch rescales the same
/// `GH2X` onto a twelve gram carbon basis instead of the fermenter's
/// seventy-two.
pub fn hydrogenotrophicCarbonBasisFeedback_kilojoule_per_g_c(
    hydrogen_feedback_energy_kilojoule_per_mol: f64,
    basis: CarbonBasis,
) !f64 {
    try basis.validate();
    if (!std.math.isFinite(hydrogen_feedback_energy_kilojoule_per_mol))
        return error.InvalidAnaerobicFeedbackEnvironment;
    const result = hydrogen_feedback_energy_kilojoule_per_mol /
        basis.hydrogenotrophic_methanogenesis_g_c_per_mol;
    if (!std.math.isFinite(result))
        return error.NonFiniteAnaerobicFeedbackEnergy;
    return result;
}

/// Every intermediate of source 918--922, retained separately so a caller can
/// assert each source statement rather than only the composite.
pub const FermenterFeedback = struct {
    /// `GH2F`, source 918.
    hydrogen_kilojoule_per_g_c: f64,
    /// `GOAX`, source 919--920.
    acetate_kilojoule_per_mol: f64,
    /// `GOAF`, source 921.
    acetate_kilojoule_per_g_c: f64,
    /// `GHAX`, source 922.
    combined_kilojoule_per_g_c: f64,
};

/// Exact source 918--922. `hydrogen_feedback_energy_kilojoule_per_mol` is the
/// layer `GH2X` from `hydrogenFeedbackEnergy_kilojoule_per_mol`.
pub fn fermenterFeedback(
    soil_temperature_kelvin: f64,
    aqueous_acetate_concentration_g_c_per_m3: f64,
    hydrogen_feedback_energy_kilojoule_per_mol: f64,
    parameters: FeedbackEnvironmentParameters,
    basis: CarbonBasis,
) !FermenterFeedback {
    try parameters.validate();
    try basis.validate();
    if (!std.math.isFinite(soil_temperature_kelvin) or
        soil_temperature_kelvin <= 0 or
        !std.math.isFinite(aqueous_acetate_concentration_g_c_per_m3) or
        aqueous_acetate_concentration_g_c_per_m3 < 0 or
        !std.math.isFinite(hydrogen_feedback_energy_kilojoule_per_mol))
        return error.InvalidAnaerobicFeedbackEnvironment;
    const hydrogen = hydrogen_feedback_energy_kilojoule_per_mol /
        basis.fermentation_g_c_per_mol;
    const bounded_acetate = @max(
        parameters.minimum_acetate_concentration_g_c_per_m3,
        aqueous_acetate_concentration_g_c_per_m3,
    );
    const acetate_mol = parameters.gas_constant_kilojoule_per_mol_kelvin *
        soil_temperature_kelvin *
        sourceOrderedLogPositiveRatioPower(
            bounded_acetate,
            parameters.acetate_product_inhibition_g_c_per_m3,
            parameters.fermenter_acetate_feedback_stoichiometric_exponent,
        );
    const acetate = acetate_mol / basis.fermentation_g_c_per_mol;
    const result: FermenterFeedback = .{
        .hydrogen_kilojoule_per_g_c = hydrogen,
        .acetate_kilojoule_per_mol = acetate_mol,
        .acetate_kilojoule_per_g_c = acetate,
        .combined_kilojoule_per_g_c = hydrogen + acetate,
    };
    inline for (@typeInfo(FermenterFeedback).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteAnaerobicFeedbackEnergy;
    return result;
}

/// Exact source 1000--1002 `GOMX` then `GOMM`, in kilojoule per gram carbon.
/// Source line 1001 has no exponent on the acetate ratio, unlike the
/// fermenter's `**2` at line 920.
pub fn acetotrophicFeedback_kilojoule_per_g_c(
    soil_temperature_kelvin: f64,
    aqueous_acetate_concentration_g_c_per_m3: f64,
    parameters: FeedbackEnvironmentParameters,
    basis: CarbonBasis,
) !f64 {
    try parameters.validate();
    try basis.validate();
    if (!std.math.isFinite(soil_temperature_kelvin) or
        soil_temperature_kelvin <= 0 or
        !std.math.isFinite(aqueous_acetate_concentration_g_c_per_m3) or
        aqueous_acetate_concentration_g_c_per_m3 < 0)
        return error.InvalidAnaerobicFeedbackEnvironment;
    const bounded_acetate = @max(
        parameters.minimum_acetate_concentration_g_c_per_m3,
        aqueous_acetate_concentration_g_c_per_m3,
    );
    const energy_mol = parameters.gas_constant_kilojoule_per_mol_kelvin *
        soil_temperature_kelvin * sourceOrderedLogPositiveRatio(
        bounded_acetate,
        parameters.acetate_product_inhibition_g_c_per_m3,
    );
    const result = energy_mol /
        basis.acetotrophic_methanogenesis_g_c_per_mol;
    if (!std.math.isFinite(result))
        return error.NonFiniteAnaerobicFeedbackEnergy;
    return result;
}

/// Which source anaerobic branch a runtime population takes. The selector
/// itself stays with `soil_microbial_respiration_activity.sourceMetabolism`;
/// this only distinguishes the two fermenter sub-branches, which the source
/// separates by `IF(N.EQ.4)` at line 923.
pub const FermenterRole = enum { fermenter, anaerobic_diazotroph };

/// Exact source 924--928 composed onto the feedback above. Returns `ECHZ` in
/// gram carbon per gram carbon.
pub fn fermenterRequirement_g_c_per_g_c(
    energy: nitrogen_parameters.AnaerobicGrowthEnergyParameters,
    feedback: FermenterFeedback,
    role: FermenterRole,
) !f64 {
    return energy.fermenterGrowthRespirationRequirement(
        feedback.combined_kilojoule_per_g_c,
        role == .anaerobic_diazotroph,
    );
}

/// Exact source 1003--1004 composed onto `acetotrophicFeedback`. Returns
/// `ECHZ` in gram carbon per gram carbon.
pub fn acetotrophicRequirement_g_c_per_g_c(
    energy: nitrogen_parameters.AnaerobicGrowthEnergyParameters,
    acetate_feedback_kilojoule_per_g_c: f64,
) !f64 {
    return energy.acetotrophicGrowthRespirationRequirement(
        acetate_feedback_kilojoule_per_g_c,
    );
}

const testing = std.testing;

test "source hydrogen feedback reproduces NITRO 556-557 statement order" {
    const temperature: f64 = 293.15;
    const concentration: f64 = 0.25;
    const expected = 8.3143e-3 * temperature *
        @log(std.math.pow(f64, concentration / 1.0, 4));
    try testing.expectApproxEqRel(
        expected,
        try hydrogenFeedbackEnergy_kilojoule_per_mol(
            temperature,
            concentration,
            source_feedback_environment,
        ),
        1e-15,
    );
}

test "source hydrogen floor engages below one milligram per cubic metre" {
    const temperature: f64 = 300;
    const floored = try hydrogenFeedbackEnergy_kilojoule_per_mol(
        temperature,
        0,
        source_feedback_environment,
    );
    const at_floor = try hydrogenFeedbackEnergy_kilojoule_per_mol(
        temperature,
        1e-3,
        source_feedback_environment,
    );
    try testing.expectEqual(at_floor, floored);
    // Source AMAX1(1.0E-03, CH2GS)/H2KI = 1e-3 < 1, so the log is negative.
    try testing.expect(floored < 0);
}

test "source feedback remains finite when ratio or power exceeds binary64 range" {
    const temperature: f64 = 300;
    const hydrogen = try hydrogenFeedbackEnergy_kilojoule_per_mol(
        temperature,
        1e100,
        source_feedback_environment,
    );
    try testing.expect(std.math.isFinite(hydrogen));
    try testing.expectApproxEqRel(
        8.3143e-3 * temperature * 4 * @log(@as(f64, 1e100)),
        hydrogen,
        1e-15,
    );

    const fermenter = try fermenterFeedback(
        temperature,
        1e200,
        0,
        source_feedback_environment,
        source_carbon_basis,
    );
    try testing.expect(std.math.isFinite(fermenter.acetate_kilojoule_per_mol));

    var ratio_overflow = source_feedback_environment;
    ratio_overflow.acetate_product_inhibition_g_c_per_m3 = std.math.floatMin(f64);
    const acetotrophic = try acetotrophicFeedback_kilojoule_per_g_c(
        temperature,
        std.math.floatMax(f64),
        ratio_overflow,
        source_carbon_basis,
    );
    try testing.expect(std.math.isFinite(acetotrophic));
}

test "source fermenter feedback reproduces NITRO 918-922 statement order" {
    const temperature: f64 = 288;
    const acetate: f64 = 6;
    const hydrogen_mol = try hydrogenFeedbackEnergy_kilojoule_per_mol(
        temperature,
        0.5,
        source_feedback_environment,
    );
    const feedback = try fermenterFeedback(
        temperature,
        acetate,
        hydrogen_mol,
        source_feedback_environment,
        source_carbon_basis,
    );
    try testing.expectApproxEqRel(
        hydrogen_mol / 72,
        feedback.hydrogen_kilojoule_per_g_c,
        1e-15,
    );
    const expected_acetate_mol = 8.3143e-3 * temperature *
        @log(std.math.pow(f64, acetate / 12, 2));
    try testing.expectApproxEqRel(
        expected_acetate_mol,
        feedback.acetate_kilojoule_per_mol,
        1e-15,
    );
    try testing.expectApproxEqRel(
        expected_acetate_mol / 72,
        feedback.acetate_kilojoule_per_g_c,
        1e-15,
    );
    try testing.expectApproxEqRel(
        feedback.hydrogen_kilojoule_per_g_c +
            feedback.acetate_kilojoule_per_g_c,
        feedback.combined_kilojoule_per_g_c,
        1e-15,
    );
}

test "source acetotrophic feedback has no exponent unlike the fermenter" {
    const temperature: f64 = 295;
    const acetate: f64 = 48;
    const expected = 8.3143e-3 * temperature * @log(acetate / 12) / 24;
    try testing.expectApproxEqRel(
        expected,
        try acetotrophicFeedback_kilojoule_per_g_c(
            temperature,
            acetate,
            source_feedback_environment,
            source_carbon_basis,
        ),
        1e-15,
    );
    const fermenter = try fermenterFeedback(
        temperature,
        acetate,
        0,
        source_feedback_environment,
        source_carbon_basis,
    );
    // Source exponent 2 versus 1 on the same ratio: the fermenter acetate
    // energy per mole must be exactly twice the acetotrophic energy per mole.
    const acetotrophic_mol = 8.3143e-3 * temperature * @log(acetate / 12);
    try testing.expectApproxEqRel(
        2 * acetotrophic_mol,
        fermenter.acetate_kilojoule_per_mol,
        1e-15,
    );
}

test "hydrogenotrophic basis is the fermenter basis scaled by six" {
    const energy_mol: f64 = -3.5;
    const hydrogenotrophic =
        try hydrogenotrophicCarbonBasisFeedback_kilojoule_per_g_c(
            energy_mol,
            source_carbon_basis,
        );
    try testing.expectApproxEqRel(energy_mol / 12, hydrogenotrophic, 1e-15);
    const fermenter = energy_mol / source_carbon_basis.fermentation_g_c_per_mol;
    try testing.expectApproxEqRel(6 * fermenter, hydrogenotrophic, 1e-15);
}

fn sourceEnergy() !nitrogen_parameters.AnaerobicGrowthEnergyParameters {
    const parameters = try nitrogen_parameters.sourceParameters();
    return parameters.anaerobic_growth_energy;
}

test "unfed anaerobic requirements match source parameter derivations" {
    const energy = try sourceEnergy();
    const zero_feedback: FermenterFeedback = .{
        .hydrogen_kilojoule_per_g_c = 0,
        .acetate_kilojoule_per_mol = 0,
        .acetate_kilojoule_per_g_c = 0,
        .combined_kilojoule_per_g_c = 0,
    };
    // Source GCHX=3.0, EOMF=EOMY=37.5, GC4X=1.5, EOMH=37.5.
    try testing.expectApproxEqRel(
        1.0 / (1.0 + 3.0 / 37.5),
        try fermenterRequirement_g_c_per_g_c(energy, zero_feedback, .fermenter),
        1e-15,
    );
    try testing.expectApproxEqRel(
        1.0 / (1.0 + 3.0 / 37.5),
        try fermenterRequirement_g_c_per_g_c(
            energy,
            zero_feedback,
            .anaerobic_diazotroph,
        ),
        1e-15,
    );
    try testing.expectApproxEqRel(
        1.0 / (1.0 + 1.5 / 37.5),
        try acetotrophicRequirement_g_c_per_g_c(energy, 0),
        1e-15,
    );
}

test "product accumulation raises the requirement toward complete respiration" {
    const energy = try sourceEnergy();
    const temperature: f64 = 293.15;
    var previous: f64 = 0;
    // Rising acetate raises GOAF, shrinks GCHX-GHAX, and therefore raises
    // ECHZ. This is the self-limiting mechanism production had lost.
    for ([_]f64{ 0.5, 2, 6, 12, 48, 200 }) |acetate| {
        const feedback = try fermenterFeedback(
            temperature,
            acetate,
            try hydrogenFeedbackEnergy_kilojoule_per_mol(
                temperature,
                1e-3,
                source_feedback_environment,
            ),
            source_feedback_environment,
            source_carbon_basis,
        );
        const requirement = try fermenterRequirement_g_c_per_g_c(
            energy,
            feedback,
            .fermenter,
        );
        try testing.expect(requirement >= previous);
        previous = requirement;
    }
    try testing.expect(previous > 0.4);
}

test "source floors and ceilings bracket both anaerobic requirements" {
    const energy = try sourceEnergy();
    const temperature: f64 = 280;
    var floor_ever_binds = false;
    for ([_]f64{ 1e-9, 1e-3, 1, 12, 1e3, 1e6 }) |acetate| {
        for ([_]f64{ 0, 1e-3, 1, 1e3 }) |hydrogen| {
            const hydrogen_mol =
                try hydrogenFeedbackEnergy_kilojoule_per_mol(
                    temperature,
                    hydrogen,
                    source_feedback_environment,
                );
            const feedback = try fermenterFeedback(
                temperature,
                acetate,
                hydrogen_mol,
                source_feedback_environment,
                source_carbon_basis,
            );
            for ([_]FermenterRole{ .fermenter, .anaerobic_diazotroph }) |role| {
                const requirement =
                    try fermenterRequirement_g_c_per_g_c(
                        energy,
                        feedback,
                        role,
                    );
                const floor: f64 = switch (role) {
                    .fermenter => 0.4,
                    .anaerobic_diazotroph => 0.5,
                };
                try testing.expect(requirement >= floor);
                try testing.expect(requirement <= 1);
                if (requirement == floor) floor_ever_binds = true;
            }
            const acetotrophic =
                try acetotrophicRequirement_g_c_per_g_c(
                    energy,
                    try acetotrophicFeedback_kilojoule_per_g_c(
                        temperature,
                        acetate,
                        source_feedback_environment,
                        source_carbon_basis,
                    ),
                );
            try testing.expect(acetotrophic >= 0.4);
            try testing.expect(acetotrophic <= 1);
        }
    }
    // Measured finding: at the source defaults the floors `EO2X=0.4` and
    // `ENFY=0.5` are unreachable. The fermenter floor requires
    // `GCHX-GHAX >= EOMF*(1/0.4-1) = 56.25` kilojoule per gram carbon, and with
    // `GCHX=3` that needs a product feedback near `-53`, which at 280 K needs an
    // acetate ratio below `exp(-800)`. The floors exist in the source and are
    // preserved exactly, but production behaviour is set by the reciprocal.
    try testing.expect(!floor_ever_binds);
}

test "source floors are preserved and do select per branch when reachable" {
    // Isolate the floor logic from its physical reachability by shrinking the
    // growth energy requirements so the reciprocal collapses below each floor.
    const steep: nitrogen_parameters.AnaerobicGrowthEnergyParameters = .{
        .fermentation_energy_yield_kilojoule_per_g_c = 3.0,
        .acetotrophic_methanogenesis_energy_yield_kilojoule_per_g_c = 1.5,
        .fermenter_growth_energy_requirement_kilojoule_per_g_c = 0.1,
        .anaerobic_diazotroph_growth_energy_requirement_kilojoule_per_g_c = 0.1,
        .acetotrophic_methanogen_growth_energy_requirement_kilojoule_per_g_c = 0.1,
        .minimum_growth_respiration_requirement_g_c_per_g_c = 0.4,
        .anaerobic_diazotroph_minimum_growth_respiration_requirement_g_c_per_g_c = 0.5,
    };
    const depleted: FermenterFeedback = .{
        .hydrogen_kilojoule_per_g_c = -1,
        .acetate_kilojoule_per_mol = -72,
        .acetate_kilojoule_per_g_c = -1,
        .combined_kilojoule_per_g_c = -2,
    };
    try testing.expectApproxEqAbs(
        @as(f64, 0.4),
        try fermenterRequirement_g_c_per_g_c(steep, depleted, .fermenter),
        1e-15,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 0.5),
        try fermenterRequirement_g_c_per_g_c(steep, depleted, .anaerobic_diazotroph),
        1e-15,
    );
    // The acetotrophic branch ADDS its feedback, so its floor binds under
    // accumulated acetate, the opposite direction from the fermenter.
    try testing.expectApproxEqAbs(
        @as(f64, 0.4),
        try acetotrophicRequirement_g_c_per_g_c(steep, 2),
        1e-15,
    );
}

test "production constants sit inside but not at the source ranges" {
    const energy = try sourceEnergy();
    // docs/traceability/bind_nitro_001_double_mutation_analysis.md: the two
    // production constants are 0.5 and 0.42016806722689076. Neither is the
    // correct unfed value, which is what this lane replaces.
    const unfed_fermenter = try fermenterRequirement_g_c_per_g_c(
        energy,
        .{
            .hydrogen_kilojoule_per_g_c = 0,
            .acetate_kilojoule_per_mol = 0,
            .acetate_kilojoule_per_g_c = 0,
            .combined_kilojoule_per_g_c = 0,
        },
        .fermenter,
    );
    const unfed_acetotroph =
        try acetotrophicRequirement_g_c_per_g_c(energy, 0);
    try testing.expect(unfed_fermenter > 0.5);
    try testing.expect(unfed_acetotroph > 0.42016806722689076);
    // EO2A, the aerobic acetate requirement, is what production applied to an
    // anaerobic population. It is not any acetotrophic source value.
    try testing.expectApproxEqRel(
        @as(f64, 0.42016806722689076),
        1.0 / (1.0 + (37.5 - 3.0) / 25.0),
        1e-15,
    );
}

test "invalid feedback inputs are rejected without producing a value" {
    try testing.expectError(
        error.InvalidAnaerobicFeedbackEnvironment,
        hydrogenFeedbackEnergy_kilojoule_per_mol(
            0,
            1,
            source_feedback_environment,
        ),
    );
    try testing.expectError(
        error.InvalidAnaerobicFeedbackEnvironment,
        hydrogenFeedbackEnergy_kilojoule_per_mol(
            300,
            -1,
            source_feedback_environment,
        ),
    );
    try testing.expectError(
        error.InvalidAnaerobicFeedbackEnvironment,
        acetotrophicFeedback_kilojoule_per_g_c(
            300,
            std.math.nan(f64),
            source_feedback_environment,
            source_carbon_basis,
        ),
    );
    var broken = source_feedback_environment;
    broken.acetate_product_inhibition_g_c_per_m3 = 0;
    try testing.expectError(
        error.InvalidAnaerobicFeedbackParameter,
        acetotrophicFeedback_kilojoule_per_g_c(
            300,
            1,
            broken,
            source_carbon_basis,
        ),
    );
    var broken_basis = source_carbon_basis;
    broken_basis.fermentation_g_c_per_mol = -1;
    try testing.expectError(
        error.InvalidAnaerobicCarbonBasis,
        fermenterFeedback(
            300,
            1,
            0,
            source_feedback_environment,
            broken_basis,
        ),
    );
}

test "feedback is invariant to the order acetate and hydrogen are supplied" {
    const temperature: f64 = 291;
    var prng = std.Random.DefaultPrng.init(0x4e_49_54_52_4f_5f_41_33);
    const random = prng.random();
    for (0..256) |_| {
        const acetate = random.float(f64) * 100;
        const hydrogen = random.float(f64) * 10;
        const hydrogen_mol =
            try hydrogenFeedbackEnergy_kilojoule_per_mol(
                temperature,
                hydrogen,
                source_feedback_environment,
            );
        const feedback = try fermenterFeedback(
            temperature,
            acetate,
            hydrogen_mol,
            source_feedback_environment,
            source_carbon_basis,
        );
        const hydrogen_only = try fermenterFeedback(
            temperature,
            source_feedback_environment.acetate_product_inhibition_g_c_per_m3,
            hydrogen_mol,
            source_feedback_environment,
            source_carbon_basis,
        );
        const acetate_only = try fermenterFeedback(
            temperature,
            acetate,
            0,
            source_feedback_environment,
            source_carbon_basis,
        );
        // GHAX = GH2F + GOAF is additively separable, and the acetate term
        // vanishes exactly at COQA = OAKI because log(1) = 0.
        try testing.expectApproxEqAbs(
            hydrogen_only.combined_kilojoule_per_g_c +
                acetate_only.combined_kilojoule_per_g_c,
            feedback.combined_kilojoule_per_g_c,
            1e-14,
        );
    }
}
