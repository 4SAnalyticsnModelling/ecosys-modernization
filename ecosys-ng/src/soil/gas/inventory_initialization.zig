//! STARTE soil-layer gas inventory initialization, `starte.f:1409--1433`.
//!
//! DISPOSITION (section 8a): DUPLICATE OWNER, not bound. The bound owner is
//! `soil/gas/transport.zig` `initializeSoilLayerCell`, reached from
//! `src/ecosys_ng.zig:1788` inside the per-layer-cell initialization loop. This
//! module is the unreachable twin and is retained only as the literal reading of
//! the Fortran, which is what makes the two discrepancies below legible.
//!
//! This is the soil-layer sibling of the surface-litter block closed as
//! STARTE-008 (`surface/litter_gas_inventory_initialization.zig`,
//! `starte.f:1919--1946`). Same structure, same `DATA(20).EQ.'NO'.AND.IGO.EQ.0`
//! gate, and the two modules agree with the bound owner on the six
//! `exp(a - b*T)` solubility pairs (0.843/0.0281 CO2, 0.597/0.0199 CH4,
//! 0.516/0.0172 O2, 0.456/0.0152 N2, 0.897/0.0299 N2O, H2 reusing methane's
//! pair, which is correct: `starte.f:32--33` gives `SH2GX = SCH4X = 3.156E-02`).
//! Gaseous mass is concentration times `VOLP`, and aqueous oxygen is zeroed at
//! or below the water table (`CDPTH(L-1) < DTBLZ`), all three agreeing.
//!
//! The bound owner wins on every axis that matters. It is reachable; it owns the
//! `State` arrays the gas pipeline reads; it applies the ionic-strength divisor
//! (see below) that the surface block correctly lacks and this layer block needs;
//! and it is passed a real water volume.
//!
//! Two naming defects in *this* module, which are the reason not to promote it:
//!
//! 1. `LayerEnvironment.temperature_reference_transform` is `CSTR1`, and `CSTR1`
//!    is not a temperature quantity at all. `starte.f:426` defines it as
//!    `0.5E-03*(9.0*(CC3+CA3)+4.0*(CC2+CA2)+CC1+CA1)`, the charge-weighted ionic
//!    strength of the soil solution. `exp(A*CSTR1)` is a Debye-Huckel-style
//!    activity divisor, exactly 1 in non-saline soil. The bound owner names this
//!    correctly (`ionic_strength`, `activity_coefficient`) and `ecosys_ng.zig:1786`
//!    supplies it from `initial_chemistry_state.activityCoefficients`. Binding
//!    this module instead would carry a name asserting the opposite of the physics.
//!
//! 2. `LayerEnvironment.aqueous_volume_m3` is `FC`, and `FC` is not a volume.
//!    `readi.f:329--332` reads it as "field capacity ... (m3 m-3)", a
//!    dimensionless water-content fraction. See STARTE-010.
//!
//! STARTE-010, filed in `docs/discrepancy_register.md`: the legacy soil-layer
//! aqueous seeds at `starte.f:1419--1433` all end in `*FC(L,NY,NX)`, a
//! dimensionless fraction, while the gaseous seeds on the preceding lines use the
//! air volume `VOLP(L)` in m3. The block's own comment header says
//! `VOLP,VOLW=soil air,water content (m3)`, naming `VOLW` as the intended
//! partner, and `VOLW` is available: `starts.f:1178` sets it and STARTS runs at
//! `soil.f:41`, before `CALL STARTE` at `soil.f:108`. Downstream confirms the
//! intent, since `hour1.f:3780` recovers a concentration as
//! `OXYS(L)/VOLW(L)`, which is only dimensionally sound if `OXYS` is a mass.
//! Production passes `state.matrix_liquid_water_m3` and is dimensionally right
//! where the source is not.
//!
//! This differs from STARTE-008 in one important way. There the surface `FC(0)`
//! is never written before STARTE runs, so the legacy surface aqueous seed is
//! zero on a fresh run. Here `readi.f:332` does read `FC` for `L=NU..NM`, so the
//! layer seed is a live nonzero number that is simply off by the ratio
//! `FC/VOLW`. Both are intentional replacements: a later legacy comparison of
//! day-zero dissolved gas will differ by construction and must not be
//! "reconciled" toward the source.
//!
//! Not verified: the magnitude of `FC/VOLW` in the shipped Ottawa profile, which
//! needs the run's `THETW` and `VOLX`. I did not build or run the Fortran. Noted
//! and dismissed: the soil block seeds CO2 from `CCO2EI` (`starts.f:495`, the
//! initial atmospheric CO2) rather than `CCO2E`; `readi.f:230` sets
//! `CO2E = CO2EI`, so the two agree until `wthr.f:482` scales `CO2E`, which is
//! after initialization. No discrepancy.
//!
const std = @import("std");

pub const GasStateSource = enum {
    atmospheric_equilibrium,
    supplied_profile,
};

pub const Control = struct {
    gas_state_source: GasStateSource,
    gas_initialization_index: usize, // IGO
};

/// Atmospheric gas concentrations are `g m-3`.
pub const AtmosphericConcentrations = struct {
    carbon_dioxide_g_per_m3: f64,
    methane_g_per_m3: f64,
    oxygen_g_per_m3: f64,
    dinitrogen_g_per_m3: f64,
    nitrous_oxide_g_per_m3: f64,
    ammonia_g_per_m3: f64,
    hydrogen_g_per_m3: f64,
};

/// Solubility reference factors and exponential coefficients retain the
/// dimensions used by STARTE.F's temperature correction.
pub const SolubilityParameters = struct {
    oxygen_reference: f64, // SOXYX
    oxygen_exponential_coefficient: f64, // AOXYX
    carbon_dioxide_reference: f64, // SCO2X
    carbon_dioxide_exponential_coefficient: f64, // ACO2X
    methane_reference: f64, // SCH4X
    methane_exponential_coefficient: f64, // ACH4X
    dinitrogen_reference: f64, // SN2GX
    dinitrogen_exponential_coefficient: f64, // AN2GX
    nitrous_oxide_reference: f64, // SN2OX
    nitrous_oxide_exponential_coefficient: f64, // AN2OX
    hydrogen_reference: f64, // SH2GX
    hydrogen_exponential_coefficient: f64, // AH2GX
};

pub const LayerEnvironment = struct {
    air_volume_m3: f64, // VOLP
    aqueous_volume_m3: f64, // FC
    overlying_depth_m: f64, // CDPTH(L-1)
    water_table_depth_m: f64, // DTBLZ
    air_temperature_c: f64, // ATCA
    temperature_reference_transform: f64, // CSTR1
};

/// Gas inventories are grams in the gaseous and aqueous phases.
pub const GasInventories = struct {
    gaseous_carbon_dioxide_g: f64, // CO2G
    gaseous_methane_g: f64, // CH4G
    gaseous_oxygen_g: f64, // OXYG
    gaseous_dinitrogen_g: f64, // Z2GG
    gaseous_nitrous_oxide_g: f64, // Z2OG
    gaseous_ammonia_g: f64, // ZNH3G
    gaseous_hydrogen_g: f64, // H2GG
    aqueous_oxygen_g: f64, // OXYS
    aqueous_carbon_dioxide_g: f64, // CO2S
    aqueous_methane_g: f64, // CH4S
    aqueous_dinitrogen_g: f64, // Z2GS
    aqueous_nitrous_oxide_g: f64, // Z2OS
    aqueous_hydrogen_g: f64, // H2GS
};

fn correctedDissolvedInventory(
    atmospheric_g_per_m3: f64,
    reference_solubility: f64,
    exponential_coefficient: f64,
    temperature_reference_transform: f64,
    temperature_factor: f64,
    air_temperature_c: f64,
    aqueous_volume_m3: f64,
) f64 {
    return atmospheric_g_per_m3 * reference_solubility /
        @exp(exponential_coefficient * temperature_reference_transform) *
        @exp(temperature_factor - air_temperature_c) * aqueous_volume_m3;
}

/// Direct translation of `starte.f` lines 1410--1433. The caller supplies the
/// current soil layer; `overlying_depth_m` represents source index `L-1`.
pub fn initialize(
    control: Control,
    atmosphere: AtmosphericConcentrations,
    solubility: SolubilityParameters,
    environment: LayerEnvironment,
) !?GasInventories {
    if (control.gas_state_source != .atmospheric_equilibrium or
        control.gas_initialization_index != 0) return null;
    inline for (@typeInfo(AtmosphericConcentrations).@"struct".fields) |field| {
        const value = @field(atmosphere, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidAtmosphericGasConcentration;
    }
    inline for (@typeInfo(SolubilityParameters).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(solubility, field.name))) return error.InvalidGasSolubilityParameter;
    }
    if (!std.math.isFinite(environment.air_volume_m3) or environment.air_volume_m3 < 0 or
        !std.math.isFinite(environment.aqueous_volume_m3) or environment.aqueous_volume_m3 < 0 or
        !std.math.isFinite(environment.overlying_depth_m) or
        !std.math.isFinite(environment.water_table_depth_m) or
        !std.math.isFinite(environment.air_temperature_c) or
        !std.math.isFinite(environment.temperature_reference_transform))
        return error.InvalidSoilGasEnvironment;

    const oxygen_aqueous_g = if (environment.overlying_depth_m < environment.water_table_depth_m)
        atmosphere.oxygen_g_per_m3 * solubility.oxygen_reference /
            @exp(solubility.oxygen_exponential_coefficient * environment.temperature_reference_transform) *
            @exp(0.516 - 0.0172 * environment.air_temperature_c) * environment.aqueous_volume_m3
    else
        0.0;
    const result: GasInventories = .{
        .gaseous_carbon_dioxide_g = atmosphere.carbon_dioxide_g_per_m3 * environment.air_volume_m3,
        .gaseous_methane_g = atmosphere.methane_g_per_m3 * environment.air_volume_m3,
        .gaseous_oxygen_g = atmosphere.oxygen_g_per_m3 * environment.air_volume_m3,
        .gaseous_dinitrogen_g = atmosphere.dinitrogen_g_per_m3 * environment.air_volume_m3,
        .gaseous_nitrous_oxide_g = atmosphere.nitrous_oxide_g_per_m3 * environment.air_volume_m3,
        .gaseous_ammonia_g = atmosphere.ammonia_g_per_m3 * environment.air_volume_m3,
        .gaseous_hydrogen_g = atmosphere.hydrogen_g_per_m3 * environment.air_volume_m3,
        .aqueous_oxygen_g = oxygen_aqueous_g,
        .aqueous_carbon_dioxide_g = correctedDissolvedInventory(atmosphere.carbon_dioxide_g_per_m3, solubility.carbon_dioxide_reference, solubility.carbon_dioxide_exponential_coefficient, environment.temperature_reference_transform, 0.843, 0.0281 * environment.air_temperature_c, environment.aqueous_volume_m3),
        .aqueous_methane_g = correctedDissolvedInventory(atmosphere.methane_g_per_m3, solubility.methane_reference, solubility.methane_exponential_coefficient, environment.temperature_reference_transform, 0.597, 0.0199 * environment.air_temperature_c, environment.aqueous_volume_m3),
        .aqueous_dinitrogen_g = correctedDissolvedInventory(atmosphere.dinitrogen_g_per_m3, solubility.dinitrogen_reference, solubility.dinitrogen_exponential_coefficient, environment.temperature_reference_transform, 0.456, 0.0152 * environment.air_temperature_c, environment.aqueous_volume_m3),
        .aqueous_nitrous_oxide_g = correctedDissolvedInventory(atmosphere.nitrous_oxide_g_per_m3, solubility.nitrous_oxide_reference, solubility.nitrous_oxide_exponential_coefficient, environment.temperature_reference_transform, 0.897, 0.0299 * environment.air_temperature_c, environment.aqueous_volume_m3),
        .aqueous_hydrogen_g = correctedDissolvedInventory(atmosphere.hydrogen_g_per_m3, solubility.hydrogen_reference, solubility.hydrogen_exponential_coefficient, environment.temperature_reference_transform, 0.597, 0.0199 * environment.air_temperature_c, environment.aqueous_volume_m3),
    };
    inline for (@typeInfo(GasInventories).@"struct".fields) |field| {
        const value = @field(result, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidInitialSoilGasInventory;
    }
    return result;
}

fn filledAtmosphere(value: f64) AtmosphericConcentrations {
    var result: AtmosphericConcentrations = undefined;
    inline for (@typeInfo(AtmosphericConcentrations).@"struct".fields) |field| @field(result, field.name) = value;
    return result;
}

fn filledSolubility(reference: f64, coefficient: f64) SolubilityParameters {
    var result: SolubilityParameters = undefined;
    inline for (@typeInfo(SolubilityParameters).@"struct".fields) |field|
        @field(result, field.name) = if (std.mem.endsWith(u8, field.name, "reference")) reference else coefficient;
    return result;
}

test "STARTE soil gas initialization preserves gas and temperature calculation order" {
    const result = (try initialize(.{ .gas_state_source = .atmospheric_equilibrium, .gas_initialization_index = 0 }, filledAtmosphere(2), filledSolubility(3, 0.2), .{
        .air_volume_m3 = 4,
        .aqueous_volume_m3 = 5,
        .overlying_depth_m = 1,
        .water_table_depth_m = 2,
        .air_temperature_c = 10,
        .temperature_reference_transform = 0.5,
    })).?;
    try std.testing.expectEqual(@as(f64, 8), result.gaseous_carbon_dioxide_g);
    const expected_co2 = 2.0 * 3.0 / @exp(0.2 * 0.5) * @exp(0.843 - 0.0281 * 10.0) * 5.0;
    try std.testing.expectApproxEqRel(expected_co2, result.aqueous_carbon_dioxide_g, 1e-14);
    try std.testing.expect(result.aqueous_oxygen_g > 0);
}

test "STARTE submerged soil layer initializes aqueous oxygen to exact zero" {
    const result = (try initialize(.{ .gas_state_source = .atmospheric_equilibrium, .gas_initialization_index = 0 }, filledAtmosphere(1), filledSolubility(1, 0), .{
        .air_volume_m3 = 1,
        .aqueous_volume_m3 = 1,
        .overlying_depth_m = 2,
        .water_table_depth_m = 2,
        .air_temperature_c = 0,
        .temperature_reference_transform = 0,
    })).?;
    try std.testing.expectEqual(@as(f64, 0), result.aqueous_oxygen_g);
}

test "STARTE inactive soil gas initialization does not inspect dormant invalid inputs" {
    try std.testing.expectEqual(@as(?GasInventories, null), try initialize(.{ .gas_state_source = .supplied_profile, .gas_initialization_index = 0 }, filledAtmosphere(std.math.nan(f64)), filledSolubility(std.math.nan(f64), std.math.nan(f64)), .{
        .air_volume_m3 = std.math.nan(f64),
        .aqueous_volume_m3 = std.math.nan(f64),
        .overlying_depth_m = std.math.nan(f64),
        .water_table_depth_m = std.math.nan(f64),
        .air_temperature_c = std.math.nan(f64),
        .temperature_reference_transform = std.math.nan(f64),
    }));
}

test "STARTE-010 guard: this twin agrees with the bound owner on the gaseous and oxygen legs" {
    // Equivalence guard for the DUPLICATE OWNER verdict. Both translate
    // starte.f:1410--1433. If they diverge on the legs that do NOT involve the
    // FC-versus-VOLW substitution, the verdict is stale and must be re-argued.
    const transport = @import("transport.zig");

    const air_volume_m3: f64 = 0.15;
    const water_volume_m3: f64 = 0.25;
    const temperature_c: f64 = 6.5;
    const atmosphere = filledAtmosphere(0.6);
    const solubility = filledSolubility(0.02925, 0.31);

    var state = try transport.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var guard_solubility: transport.SurfaceSolubilityParameters = undefined;
    for (0..transport.species_count) |i| {
        guard_solubility.reference_water_to_air[i] = 0.02925;
        guard_solubility.log_intercept[i] = 0.516;
        guard_solubility.temperature_coefficient_per_c[i] = 0.0172;
    }
    var concentrations: [transport.species_count]f64 = undefined;
    for (&concentrations) |*value| value.* = 0.6;

    // Non-saline soil: CSTR1 = 0, so exp(A*CSTR1) = 1 and the activity divisor
    // drops out of both owners. Above the water table (0.1 < 1.5).
    try transport.initializeSoilLayerCell(
        &state,
        0,
        air_volume_m3,
        water_volume_m3,
        0.1,
        1.5,
        temperature_c + 273.15,
        concentrations,
        guard_solubility,
        0,
        transport.starte_activity_coefficient,
    );

    const twin = (try initialize(
        .{ .gas_state_source = .atmospheric_equilibrium, .gas_initialization_index = 0 },
        atmosphere,
        solubility,
        .{
            .air_volume_m3 = air_volume_m3,
            .aqueous_volume_m3 = water_volume_m3,
            .overlying_depth_m = 0.1,
            .water_table_depth_m = 1.5,
            .air_temperature_c = temperature_c,
            .temperature_reference_transform = 0,
        },
    )).?;

    // Gaseous mass is concentration * VOLP in both.
    const oxygen = @intFromEnum(transport.Species.oxygen);
    try std.testing.expectApproxEqRel(
        state.gaseous_mass_g[oxygen],
        twin.gaseous_oxygen_g,
        1e-12,
    );
    // Aqueous oxygen: same 0.516/0.0172 pair, same SOXYX/AOXYX, so identical.
    try std.testing.expectApproxEqRel(
        state.dissolved_mass_g[oxygen],
        twin.aqueous_oxygen_g,
        1e-12,
    );

    // And the bound owner suppresses aqueous oxygen at or below the water table,
    // matching starte.f:1417--1421, which this twin also does.
    const submerged = (try initialize(
        .{ .gas_state_source = .atmospheric_equilibrium, .gas_initialization_index = 0 },
        atmosphere,
        solubility,
        .{
            .air_volume_m3 = air_volume_m3,
            .aqueous_volume_m3 = water_volume_m3,
            .overlying_depth_m = 2.0,
            .water_table_depth_m = 1.5,
            .air_temperature_c = temperature_c,
            .temperature_reference_transform = 0,
        },
    )).?;
    try std.testing.expectEqual(@as(f64, 0), submerged.aqueous_oxygen_g);
    // Gaseous oxygen is untouched by the water table.
    try std.testing.expectApproxEqRel(twin.gaseous_oxygen_g, submerged.gaseous_oxygen_g, 1e-15);
}

test "STARTE-010 guard: CSTR1 is an ionic strength, so the divisor must respond to salt and not to temperature" {
    // Falsifiability guard. It fails if anyone reinterprets
    // `temperature_reference_transform` as an actual temperature term, which is
    // the mistake this module's field name invites and the reason it is not the
    // owner. The divisor is exp(A*CSTR1) with CSTR1 the charge-weighted ionic
    // strength of starte.f:426, exactly 1 in non-saline soil.
    const atmosphere = filledAtmosphere(0.6);
    const coefficient: f64 = 0.31;
    const solubility = filledSolubility(0.02925, coefficient);

    var environment: LayerEnvironment = .{
        .air_volume_m3 = 0.15,
        .aqueous_volume_m3 = 0.25,
        .overlying_depth_m = 0.1,
        .water_table_depth_m = 1.5,
        .air_temperature_c = 6.5,
        .temperature_reference_transform = 0,
    };
    const fresh = (try initialize(.{ .gas_state_source = .atmospheric_equilibrium, .gas_initialization_index = 0 }, atmosphere, solubility, environment)).?;

    const ionic_strength: f64 = 2.0;
    environment.temperature_reference_transform = ionic_strength;
    const saline = (try initialize(.{ .gas_state_source = .atmospheric_equilibrium, .gas_initialization_index = 0 }, atmosphere, solubility, environment)).?;

    // Salt suppresses dissolved gas by exactly exp(A*I), never by anything
    // temperature-shaped, and leaves the gaseous phase alone.
    try std.testing.expectApproxEqRel(
        @exp(coefficient * ionic_strength),
        fresh.aqueous_oxygen_g / saline.aqueous_oxygen_g,
        1e-12,
    );
    try std.testing.expectApproxEqRel(fresh.gaseous_oxygen_g, saline.gaseous_oxygen_g, 1e-15);

    // The aqueous seed is linear in the volume-like argument, which is what makes
    // the legacy `*FC(L)` substitution a dimensional error rather than a scaling
    // choice: doubling real water must double dissolved mass.
    environment.temperature_reference_transform = 0;
    environment.aqueous_volume_m3 = 0.50;
    const doubled = (try initialize(.{ .gas_state_source = .atmospheric_equilibrium, .gas_initialization_index = 0 }, atmosphere, solubility, environment)).?;
    try std.testing.expectApproxEqRel(@as(f64, 2), doubled.aqueous_oxygen_g / fresh.aqueous_oxygen_g, 1e-12);
    // A bone-dry layer holds no dissolved gas but still holds gas.
    environment.aqueous_volume_m3 = 0;
    const dry = (try initialize(.{ .gas_state_source = .atmospheric_equilibrium, .gas_initialization_index = 0 }, atmosphere, solubility, environment)).?;
    try std.testing.expectEqual(@as(f64, 0), dry.aqueous_oxygen_g);
    try std.testing.expect(dry.gaseous_oxygen_g > 0);
}
