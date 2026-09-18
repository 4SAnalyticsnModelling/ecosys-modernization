const std = @import("std");

pub const Parameters = struct {
    dissociation_constant_mol_per_m3: f64,
    maximum_exchange_mol_per_m3_per_iteration: f64,
    substrate_limit_fraction_per_iteration: f64,
    /// When true, the substrate limit is computed as
    /// `fraction * min(occupied_mol_per_Mg, hydrogen_activity_mol_per_m3)`
    /// exactly as `starte.f:813` does (`FION * AMIN1(XHC1,AHY1)`), instead
    /// of the hourly SOLUTE.F form `fraction / density * occupied`. Set this
    /// on the `ReactionParameters` passed to the STARTE initial-equilibrium
    /// solver only; the hourly path must keep `false` (default).
    use_starte_hydrogen_substrate_cap: bool = false,
};

pub const Inputs = struct {
    total_carboxyl_sites_mol_per_megagram: f64,
    hydrogen_occupied_sites_mol_per_megagram: f64,
    hydrogen_activity_mol_per_m3: f64,
    soil_mass_per_water_volume_megagrams_per_m3: f64,
};

pub const SurfaceControls = struct {
    /// Runtime replacement for source `ZEROC` in `XCOO`.
    minimum_open_sites_mol_per_megagram: f64,
};

pub const SurfaceSourceOrderResult = struct {
    substrate_limit_mol_per_megagram_step: f64,
    maximum_exchange_mol_per_megagram_step: f64,
    total_carboxyl_sites_mol_per_megagram: f64,
    open_sites_mol_per_megagram: f64,
    equilibrium_open_sites_mol_per_megagram: f64,
    hydrogen_adsorption_mol_per_megagram_step: f64,
    open_site_floor_was_applied: bool,
};

pub const SourceOrderControls = SurfaceControls;
pub const SourceOrderResult = SurfaceSourceOrderResult;

pub const SourceIterationStage = enum {
    before_iteration_ceiling,
    iteration_ceiling,
};

/// Directly translates SOLUTE.F lines 1407--1423 (`RXHC`). A positive result
/// protonates a carboxyl site and consumes the same amount of aqueous hydrogen
/// after conversion from mol/Mg to mol/m3 with the soil-mass:water ratio.
pub fn calculateChangeMolPerMg(inputs: Inputs, parameters: Parameters) !f64 {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidCarboxylExchangeInput;
    }
    inline for (@typeInfo(Parameters).@"struct".fields) |field| {
        const value = @field(parameters, field.name);
        if (field.type == bool) continue;
        if (!std.math.isFinite(value) or value < 0) return error.InvalidCarboxylExchangeParameter;
    }
    if (inputs.soil_mass_per_water_volume_megagrams_per_m3 == 0) return error.ZeroCarboxylExchangeSoilWaterRatio;
    // Organic-carbon turnover can lower the current site's capacity between
    // chemistry solves.  Evaluate equilibrium from the remaining physical
    // sites, but retain the excess as a mandatory desorption term so it is
    // returned to aqueous H+ by the ordinary conservative transaction.
    const stored_occupied = inputs.hydrogen_occupied_sites_mol_per_megagram;
    const occupied = @min(
        stored_occupied,
        inputs.total_carboxyl_sites_mol_per_megagram,
    );
    const capacity_rebase = occupied - stored_occupied;
    const deprotonated = @max(0.0, inputs.total_carboxyl_sites_mol_per_megagram - occupied);
    const equilibrium_deprotonated = if (inputs.hydrogen_activity_mol_per_m3 > 0)
        @min(inputs.total_carboxyl_sites_mol_per_megagram, parameters.dissociation_constant_mol_per_m3 * occupied / inputs.hydrogen_activity_mol_per_m3)
    else
        inputs.total_carboxyl_sites_mol_per_megagram;
    // SOLUTE.F 1418: `XMIN = FIONX/BKVLW*XHC1` -- substrate is only occupied
    // sites, scaled by density.
    // STARTE.F 813: `XMIN = FION*AMIN1(XHC1,AHY1)` -- substrate is the
    // minimum of occupied sites and hydrogen activity (no density scaling).
    // The STARTE form is used for the initial-equilibrium solver only; it
    // throttles carboxyl exchange in acidic organic horizons where AHY1 << XHC1.
    const substrate_limit = if (parameters.use_starte_hydrogen_substrate_cap)
        parameters.substrate_limit_fraction_per_iteration *
            @min(occupied, inputs.hydrogen_activity_mol_per_m3)
    else
        parameters.substrate_limit_fraction_per_iteration /
            inputs.soil_mass_per_water_volume_megagrams_per_m3 * occupied;
    const kinetic_limit = parameters.maximum_exchange_mol_per_m3_per_iteration / inputs.soil_mass_per_water_volume_megagrams_per_m3;
    const equilibrium_change = @max(-kinetic_limit, @max(-substrate_limit, @min(kinetic_limit, @min(substrate_limit, deprotonated - equilibrium_deprotonated))));
    const change = capacity_rebase + equilibrium_change;
    if (!std.math.isFinite(change)) return error.NonFiniteCarboxylExchangeChange;
    return change;
}

/// Direct state update for SOLUTE.F 2401. No source floor is applied, and the
/// occupied carboxyl pool is unchanged at `M == MRXN`.
pub fn applySourceOrderStateUpdate(
    current_hydrogen_occupied_sites_mol_per_megagram: f64,
    change_mol_per_megagram: f64,
    stage: SourceIterationStage,
) !f64 {
    if (!std.math.isFinite(current_hydrogen_occupied_sites_mol_per_megagram) or
        current_hydrogen_occupied_sites_mol_per_megagram < 0 or
        !std.math.isFinite(change_mol_per_megagram))
        return error.InvalidCarboxylExchangeStateUpdate;
    if (stage == .iteration_ceiling)
        return current_hydrogen_occupied_sites_mol_per_megagram;
    const next = current_hydrogen_occupied_sites_mol_per_megagram + change_mol_per_megagram;
    if (!std.math.isFinite(next) or next < 0)
        return error.InvalidCarboxylExchangeStateUpdate;
    return next;
}

/// Direct source-order translation of the soil carboxyl dissociation block,
/// SOLUTE.F 1407--1423. State is read only; the returned positive extent
/// protonates COO- and is in mol Mg-1 per reaction iteration.
pub fn calculateSourceOrder(
    inputs: Inputs,
    parameters: Parameters,
    controls: SourceOrderControls,
) !SourceOrderResult {
    return calculateSourceOrderSurface(inputs, parameters, controls);
}

/// Direct source-order translation of SOLUTE.F lines 4483--4498.
///
/// A positive result protonates a surface-litter carboxyl site. The pure
/// scalar kernel owns no grid dimensions and mutates no state.
pub fn calculateSourceOrderSurface(
    inputs: Inputs,
    parameters: Parameters,
    controls: SurfaceControls,
) !SurfaceSourceOrderResult {
    try validateSurfaceInputs(inputs, parameters, controls);
    const occupied = inputs.hydrogen_occupied_sites_mol_per_megagram;
    const density = inputs.soil_mass_per_water_volume_megagrams_per_m3;

    // SOLUTE.F 4492--4498. Preserve division, floor, and nested-bound order.
    const substrate_limit =
        parameters.substrate_limit_fraction_per_iteration / density * occupied;
    const maximum_exchange =
        parameters.maximum_exchange_mol_per_m3_per_iteration / density;
    const total = inputs.total_carboxyl_sites_mol_per_megagram;
    const unconstrained_open = total - occupied;
    const open = @max(
        controls.minimum_open_sites_mol_per_megagram,
        unconstrained_open,
    );
    const equilibrium_open = @min(
        total,
        parameters.dissociation_constant_mol_per_m3 * occupied /
            inputs.hydrogen_activity_mol_per_m3,
    );
    const change = @max(
        -maximum_exchange,
        -substrate_limit,
        @min(
            maximum_exchange,
            substrate_limit,
            open - equilibrium_open,
        ),
    );
    const result: SurfaceSourceOrderResult = .{
        .substrate_limit_mol_per_megagram_step = substrate_limit,
        .maximum_exchange_mol_per_megagram_step = maximum_exchange,
        .total_carboxyl_sites_mol_per_megagram = total,
        .open_sites_mol_per_megagram = open,
        .equilibrium_open_sites_mol_per_megagram = equilibrium_open,
        .hydrogen_adsorption_mol_per_megagram_step = change,
        .open_site_floor_was_applied = unconstrained_open < controls.minimum_open_sites_mol_per_megagram,
    };
    inline for (@typeInfo(SurfaceSourceOrderResult).@"struct".fields) |field| {
        if (@typeInfo(field.type) == .bool) continue;
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteSurfaceCarboxylExchangeResult;
    }
    return result;
}

fn validateSurfaceInputs(
    inputs: Inputs,
    parameters: Parameters,
    controls: SurfaceControls,
) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSurfaceCarboxylExchangeInput;
    }
    inline for (@typeInfo(Parameters).@"struct".fields) |field| {
        const value = @field(parameters, field.name);
        if (field.type == bool) continue;
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSurfaceCarboxylExchangeParameter;
    }
    if (!std.math.isFinite(controls.minimum_open_sites_mol_per_megagram) or
        controls.minimum_open_sites_mol_per_megagram <= 0 or
        inputs.hydrogen_activity_mol_per_m3 <= 0 or
        inputs.soil_mass_per_water_volume_megagrams_per_m3 <= 0 or
        inputs.hydrogen_occupied_sites_mol_per_megagram >
            inputs.total_carboxyl_sites_mol_per_megagram or
        parameters.substrate_limit_fraction_per_iteration > 1)
    {
        return error.InvalidSurfaceCarboxylExchangeInput;
    }
}

fn surfaceTestInputs() Inputs {
    return .{
        .total_carboxyl_sites_mol_per_megagram = 1,
        .hydrogen_occupied_sites_mol_per_megagram = 0.2,
        .hydrogen_activity_mol_per_m3 = 0.01,
        .soil_mass_per_water_volume_megagrams_per_m3 = 2,
    };
}

fn surfaceTestParameters() Parameters {
    return .{
        .dissociation_constant_mol_per_m3 = 0.08,
        .maximum_exchange_mol_per_m3_per_iteration = 0.5,
        .substrate_limit_fraction_per_iteration = 0.5,
    };
}

test "SOLUTE surface carboxyl exchange preserves every source expression" {
    const inputs = surfaceTestInputs();
    const parameters = surfaceTestParameters();
    const controls: SurfaceControls = .{
        .minimum_open_sites_mol_per_megagram = 1.0e-32,
    };
    const result =
        try calculateSourceOrderSurface(inputs, parameters, controls);
    const expected_substrate =
        parameters.substrate_limit_fraction_per_iteration /
        inputs.soil_mass_per_water_volume_megagrams_per_m3 *
        inputs.hydrogen_occupied_sites_mol_per_megagram;
    const expected_maximum =
        parameters.maximum_exchange_mol_per_m3_per_iteration /
        inputs.soil_mass_per_water_volume_megagrams_per_m3;
    const expected_open = @max(
        controls.minimum_open_sites_mol_per_megagram,
        inputs.total_carboxyl_sites_mol_per_megagram -
            inputs.hydrogen_occupied_sites_mol_per_megagram,
    );
    const expected_equilibrium = @min(
        inputs.total_carboxyl_sites_mol_per_megagram,
        parameters.dissociation_constant_mol_per_m3 *
            inputs.hydrogen_occupied_sites_mol_per_megagram /
            inputs.hydrogen_activity_mol_per_m3,
    );
    const expected_change = @max(
        -expected_maximum,
        -expected_substrate,
        @min(
            expected_maximum,
            expected_substrate,
            expected_open - expected_equilibrium,
        ),
    );

    try std.testing.expectEqual(
        expected_substrate,
        result.substrate_limit_mol_per_megagram_step,
    );
    try std.testing.expectEqual(
        expected_maximum,
        result.maximum_exchange_mol_per_megagram_step,
    );
    try std.testing.expectEqual(
        inputs.total_carboxyl_sites_mol_per_megagram,
        result.total_carboxyl_sites_mol_per_megagram,
    );
    try std.testing.expectEqual(expected_open, result.open_sites_mol_per_megagram);
    try std.testing.expectEqual(
        expected_equilibrium,
        result.equilibrium_open_sites_mol_per_megagram,
    );
    try std.testing.expectEqual(
        expected_change,
        result.hydrogen_adsorption_mol_per_megagram_step,
    );
}

test "surface carboxyl source floor is explicit" {
    var inputs = surfaceTestInputs();
    inputs.hydrogen_occupied_sites_mol_per_megagram =
        inputs.total_carboxyl_sites_mol_per_megagram;
    const controls: SurfaceControls = .{
        .minimum_open_sites_mol_per_megagram = 1.0e-12,
    };
    const result =
        try calculateSourceOrderSurface(inputs, surfaceTestParameters(), controls);
    try std.testing.expect(result.open_site_floor_was_applied);
    try std.testing.expectEqual(
        controls.minimum_open_sites_mol_per_megagram,
        result.open_sites_mol_per_megagram,
    );
}

test "surface carboxyl rate cannot overdraw occupied or open sites" {
    var inputs = surfaceTestInputs();
    var parameters = surfaceTestParameters();
    parameters.maximum_exchange_mol_per_m3_per_iteration = 100;
    parameters.substrate_limit_fraction_per_iteration = 1;
    inputs.hydrogen_activity_mol_per_m3 = 1.0e-12;
    const desorption = try calculateSourceOrderSurface(
        inputs,
        parameters,
        .{ .minimum_open_sites_mol_per_megagram = 1.0e-32 },
    );
    try std.testing.expect(
        -desorption.hydrogen_adsorption_mol_per_megagram_step <=
            inputs.hydrogen_occupied_sites_mol_per_megagram /
                inputs.soil_mass_per_water_volume_megagrams_per_m3,
    );

    inputs.hydrogen_activity_mol_per_m3 = 1.0e12;
    const adsorption = try calculateSourceOrderSurface(
        inputs,
        parameters,
        .{ .minimum_open_sites_mol_per_megagram = 1.0e-32 },
    );
    try std.testing.expect(
        adsorption.hydrogen_adsorption_mol_per_megagram_step <=
            inputs.total_carboxyl_sites_mol_per_megagram -
                inputs.hydrogen_occupied_sites_mol_per_megagram,
    );
}

test "surface carboxyl exchange rejects invalid input and overflow" {
    var inputs = surfaceTestInputs();
    inputs.hydrogen_activity_mol_per_m3 = 0;
    try std.testing.expectError(
        error.InvalidSurfaceCarboxylExchangeInput,
        calculateSourceOrderSurface(
            inputs,
            surfaceTestParameters(),
            .{ .minimum_open_sites_mol_per_megagram = 1.0e-32 },
        ),
    );

    inputs = surfaceTestInputs();
    inputs.hydrogen_occupied_sites_mol_per_megagram = 2;
    try std.testing.expectError(
        error.InvalidSurfaceCarboxylExchangeInput,
        calculateSourceOrderSurface(
            inputs,
            surfaceTestParameters(),
            .{ .minimum_open_sites_mol_per_megagram = 1.0e-32 },
        ),
    );

    inputs = surfaceTestInputs();
    inputs.soil_mass_per_water_volume_megagrams_per_m3 =
        std.math.floatMin(f64);
    var parameters = surfaceTestParameters();
    parameters.maximum_exchange_mol_per_m3_per_iteration =
        std.math.floatMax(f64);
    try std.testing.expectError(
        error.NonFiniteSurfaceCarboxylExchangeResult,
        calculateSourceOrderSurface(
            inputs,
            parameters,
            .{ .minimum_open_sites_mol_per_megagram = 1.0e-32 },
        ),
    );
}

test {
    _ = @import("carboxyl_exchange_test.zig");
}
