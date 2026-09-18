const std = @import("std");

pub const Parameters = struct {
    carboxyl_capacity_mol_per_megagram_carbon: f64,
    carboxyl_dissociation_mol_per_m3: f64,
    negligible_site_concentration_mol_per_megagram: f64,
};

pub const Inputs = struct {
    cation_exchange_capacity_mol_charge: f64,
    effective_soil_mass_megagrams: f64,
    soil_organic_carbon_g_c: f64,
    hydrogen_mol_per_m3: f64,
};

pub const Result = struct {
    cation_exchange_capacity_mol_charge_per_megagram: f64,
    total_carboxyl_sites_mol_per_megagram: f64,
    protonated_carboxyl_sites_mol_per_megagram: f64,
};

/// Direct translation of `starte.f` lines 400--403. The `1.0e-6` source factor
/// converts organic carbon from g C to Mg C before applying mol sites/Mg C.
pub fn calculate(inputs: Inputs, parameters: Parameters) !Result {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteCarboxylExchangeInput;
    }
    inline for (@typeInfo(Parameters).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(parameters, field.name)))
            return error.NonFiniteCarboxylExchangeParameter;
    }
    if (inputs.cation_exchange_capacity_mol_charge < 0 or
        inputs.effective_soil_mass_megagrams <= 0 or
        inputs.soil_organic_carbon_g_c < 0 or
        inputs.hydrogen_mol_per_m3 < 0 or
        parameters.carboxyl_capacity_mol_per_megagram_carbon < 0 or
        parameters.carboxyl_dissociation_mol_per_m3 <= 0 or
        parameters.negligible_site_concentration_mol_per_megagram < 0)
        return error.InvalidCarboxylExchangeInput;

    const total_carboxyl_sites_mol_per_megagram = @max(
        parameters.negligible_site_concentration_mol_per_megagram,
        parameters.carboxyl_capacity_mol_per_megagram_carbon *
            1.0e-6 *
            inputs.soil_organic_carbon_g_c /
            inputs.effective_soil_mass_megagrams,
    );
    const result: Result = .{
        .cation_exchange_capacity_mol_charge_per_megagram = inputs.cation_exchange_capacity_mol_charge /
            inputs.effective_soil_mass_megagrams,
        .total_carboxyl_sites_mol_per_megagram = total_carboxyl_sites_mol_per_megagram,
        .protonated_carboxyl_sites_mol_per_megagram = try protonatedSites(
            total_carboxyl_sites_mol_per_megagram,
            inputs.hydrogen_mol_per_m3,
            parameters.carboxyl_dissociation_mol_per_m3,
        ),
    };
    inline for (@typeInfo(Result).@"struct".fields) |field| {
        const value = @field(result, field.name);
        if (!std.math.isFinite(value))
            return error.NonFiniteCarboxylExchangeResult;
    }
    return result;
}

/// Sole owner of STARTE line 403, `XHC1=XCOOH*AMIN1(1.0,CHY1/DPCOH)`: the
/// hydrogen-occupied share of the carboxyl exchange sites at the initial
/// per-layer proton concentration, in mol Mg-1.
///
/// This is factored out of `calculate` because the initial per-layer SOLUTE
/// equilibrium needs the occupancy on its own. `total_carboxyl_sites` there is
/// already a mol Mg-1 concentration, so the soil mass and organic carbon that
/// `Inputs` carries are neither available nor needed at that call site, and
/// duplicating the source expression would create a second owner of it.
///
/// A zero result is only correct when there are no sites. An occupancy of zero
/// against positive sites is an absorbing state for the SOLUTE carboxyl
/// reaction, because `solute_carboxyl_exchange.calculateChangeMolPerMg`
/// derives its substrate limit `FIONX/BKVLW*XHC1` from the occupied pool, so a
/// zero pool clamps every subsequent exchange extent to exactly zero and the
/// organic proton buffer can never re-enter the balance. That is why the source
/// establishes this occupancy before its reaction loop rather than solving for
/// it.
pub fn protonatedSites(
    total_carboxyl_sites_mol_per_megagram: f64,
    hydrogen_mol_per_m3: f64,
    carboxyl_dissociation_mol_per_m3: f64,
) !f64 {
    inline for (.{
        total_carboxyl_sites_mol_per_megagram,
        hydrogen_mol_per_m3,
        carboxyl_dissociation_mol_per_m3,
    }) |value| {
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidCarboxylExchangeInput;
    }
    if (carboxyl_dissociation_mol_per_m3 <= 0)
        return error.InvalidCarboxylExchangeInput;
    const occupied = total_carboxyl_sites_mol_per_megagram * @min(
        1.0,
        hydrogen_mol_per_m3 / carboxyl_dissociation_mol_per_m3,
    );
    if (!std.math.isFinite(occupied))
        return error.NonFiniteCarboxylExchangeResult;
    return occupied;
}

fn sourceParameters() Parameters {
    return .{
        .carboxyl_capacity_mol_per_megagram_carbon = 250,
        .carboxyl_dissociation_mol_per_m3 = 1.0e-2,
        .negligible_site_concentration_mol_per_megagram = 1.0e-48,
    };
}

test "STARTE soil carboxyl sites preserve source mass and occupancy order" {
    const result = try calculate(.{
        .cation_exchange_capacity_mol_charge = 60,
        .effective_soil_mass_megagrams = 2,
        .soil_organic_carbon_g_c = 40_000,
        .hydrogen_mol_per_m3 = 2.5e-3,
    }, sourceParameters());
    try std.testing.expectEqual(
        @as(f64, 30),
        result.cation_exchange_capacity_mol_charge_per_megagram,
    );
    try std.testing.expectEqual(
        @as(f64, 5),
        result.total_carboxyl_sites_mol_per_megagram,
    );
    try std.testing.expectEqual(
        @as(f64, 1.25),
        result.protonated_carboxyl_sites_mol_per_megagram,
    );
}

test "STARTE soil carboxyl protonation is capped at all sites" {
    const result = try calculate(.{
        .cation_exchange_capacity_mol_charge = 1,
        .effective_soil_mass_megagrams = 1,
        .soil_organic_carbon_g_c = 4000,
        .hydrogen_mol_per_m3 = 1,
    }, sourceParameters());
    try std.testing.expectEqual(
        result.total_carboxyl_sites_mol_per_megagram,
        result.protonated_carboxyl_sites_mol_per_megagram,
    );
}

test "STARTE soil carboxyl sites reject invalid mass" {
    const inputs: Inputs = .{
        .cation_exchange_capacity_mol_charge = 1,
        .effective_soil_mass_megagrams = 0,
        .soil_organic_carbon_g_c = 1,
        .hydrogen_mol_per_m3 = 1,
    };
    try std.testing.expectError(
        error.InvalidCarboxylExchangeInput,
        calculate(inputs, sourceParameters()),
    );
}
