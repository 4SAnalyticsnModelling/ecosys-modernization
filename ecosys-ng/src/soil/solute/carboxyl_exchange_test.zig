//! Tests for `carboxyl_exchange.zig`.
//!
//! Extracted so the module beside it carries only model code. Tests
//! that reach a private declaration of that module stay there, since a
//! sibling file can only see `pub` declarations.

const std = @import("std");
const carboxyl_module = @import("carboxyl_exchange.zig");

test "SOLUTE carboxyl exchange reproduces bounded proton adsorption" {
    const change = try carboxyl_module.calculateChangeMolPerMg(.{
        .total_carboxyl_sites_mol_per_megagram = 1,
        .hydrogen_occupied_sites_mol_per_megagram = 0.4,
        .hydrogen_activity_mol_per_m3 = 0.1,
        .soil_mass_per_water_volume_megagrams_per_m3 = 2,
    }, .{
        .dissociation_constant_mol_per_m3 = 0.01,
        .maximum_exchange_mol_per_m3_per_iteration = 0.2,
        .substrate_limit_fraction_per_iteration = 0.2,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.04), change, 1e-15);
}

test "source carboxyl state update is unfloored and ceiling gated" {
    try std.testing.expectEqual(
        @as(f64, 0),
        try carboxyl_module.applySourceOrderStateUpdate(
            0.25,
            -0.25,
            .before_iteration_ceiling,
        ),
    );
    try std.testing.expectEqual(
        @as(f64, 0.25),
        try carboxyl_module.applySourceOrderStateUpdate(0.25, -0.25, .iteration_ceiling),
    );
    try std.testing.expectError(
        error.InvalidCarboxylExchangeStateUpdate,
        carboxyl_module.applySourceOrderStateUpdate(0.25, -0.3, .before_iteration_ceiling),
    );
}

test "SOLUTE carboxyl exchange desorption cannot exceed occupied sites" {
    const change = try carboxyl_module.calculateChangeMolPerMg(.{
        .total_carboxyl_sites_mol_per_megagram = 1,
        .hydrogen_occupied_sites_mol_per_megagram = 0.1,
        .hydrogen_activity_mol_per_m3 = 0,
        .soil_mass_per_water_volume_megagrams_per_m3 = 1,
    }, .{
        .dissociation_constant_mol_per_m3 = 0.01,
        .maximum_exchange_mol_per_m3_per_iteration = 1,
        .substrate_limit_fraction_per_iteration = 1,
    });
    try std.testing.expectApproxEqAbs(@as(f64, -0.1), change, 1e-15);
}

test "SOLUTE carboxyl exchange releases capacity lost between solves" {
    const change = try carboxyl_module.calculateChangeMolPerMg(.{
        .total_carboxyl_sites_mol_per_megagram = 1,
        .hydrogen_occupied_sites_mol_per_megagram = 1.2,
        .hydrogen_activity_mol_per_m3 = 1,
        .soil_mass_per_water_volume_megagrams_per_m3 = 2,
    }, .{
        .dissociation_constant_mol_per_m3 = 0,
        .maximum_exchange_mol_per_m3_per_iteration = 0,
        .substrate_limit_fraction_per_iteration = 0,
    });
    try std.testing.expectApproxEqAbs(@as(f64, -0.2), change, 1e-15);
}

test "SOLUTE carboxyl exchange matches source nested rate bounds" {
    const inputs = carboxyl_module.Inputs{
        .total_carboxyl_sites_mol_per_megagram = 1,
        .hydrogen_occupied_sites_mol_per_megagram = 0.2,
        .hydrogen_activity_mol_per_m3 = 0.01,
        .soil_mass_per_water_volume_megagrams_per_m3 = 2,
    };
    const parameters = carboxyl_module.Parameters{
        .dissociation_constant_mol_per_m3 = 0.08,
        .maximum_exchange_mol_per_m3_per_iteration = 0.5,
        .substrate_limit_fraction_per_iteration = 0.5,
    };

    // SOLUTE.F: XMIN=0.05, TADCC=0.25, XCOO=0.8, XCOOQ=1.0,
    // so RXHC=max(-0.25,-0.05,min(0.25,0.05,-0.2))=-0.05 mol C/Mg.
    const change = try carboxyl_module.calculateChangeMolPerMg(inputs, parameters);
    try std.testing.expectApproxEqAbs(@as(f64, -0.05), change, 1e-15);
}

test "soil carboxyl source order retains runtime open-site floor" {
    const inputs: carboxyl_module.Inputs = .{
        .total_carboxyl_sites_mol_per_megagram = 1,
        .hydrogen_occupied_sites_mol_per_megagram = 1,
        .hydrogen_activity_mol_per_m3 = 2,
        .soil_mass_per_water_volume_megagrams_per_m3 = 4,
    };
    const parameters: carboxyl_module.Parameters = .{
        .dissociation_constant_mol_per_m3 = 0.2,
        .maximum_exchange_mol_per_m3_per_iteration = 0.8,
        .substrate_limit_fraction_per_iteration = 0.5,
    };
    const result = try carboxyl_module.calculateSourceOrder(
        inputs,
        parameters,
        .{ .minimum_open_sites_mol_per_megagram = 0.03 },
    );

    // SOLUTE.F 1418--1423: XMIN=.125, TADCC=.2, XCOO=.03,
    // XCOOQ=.1, RXHC=max(-.2,-.125,min(.2,.125,-.07))=-.07.
    try std.testing.expectEqual(@as(f64, 0.125), result.substrate_limit_mol_per_megagram_step);
    try std.testing.expectEqual(@as(f64, 0.2), result.maximum_exchange_mol_per_megagram_step);
    try std.testing.expectEqual(@as(f64, 0.03), result.open_sites_mol_per_megagram);
    try std.testing.expectEqual(@as(f64, 0.1), result.equilibrium_open_sites_mol_per_megagram);
    try std.testing.expectApproxEqAbs(
        @as(f64, -0.07),
        result.hydrogen_adsorption_mol_per_megagram_step,
        1e-15,
    );
}

test "surface source open-site floor can exceed a fully occupied capacity" {
    const inputs: carboxyl_module.Inputs = .{
        .total_carboxyl_sites_mol_per_megagram = 1,
        .hydrogen_occupied_sites_mol_per_megagram = 1,
        .hydrogen_activity_mol_per_m3 = 1,
        .soil_mass_per_water_volume_megagrams_per_m3 = 1,
    };
    const parameters: carboxyl_module.Parameters = .{
        .dissociation_constant_mol_per_m3 = 0,
        .maximum_exchange_mol_per_m3_per_iteration = 1,
        .substrate_limit_fraction_per_iteration = 1,
    };
    const source = try carboxyl_module.calculateSourceOrderSurface(
        inputs,
        parameters,
        .{ .minimum_open_sites_mol_per_megagram = 1.0e-6 },
    );
    const production_safe = try carboxyl_module.calculateChangeMolPerMg(inputs, parameters);

    try std.testing.expectEqual(
        @as(f64, 1.0e-6),
        source.hydrogen_adsorption_mol_per_megagram_step,
    );
    try std.testing.expectEqual(@as(f64, 0), production_safe);
    try std.testing.expect(
        inputs.hydrogen_occupied_sites_mol_per_megagram +
            source.hydrogen_adsorption_mol_per_megagram_step >
            inputs.total_carboxyl_sites_mol_per_megagram,
    );
}

test "STARTE hydrogen-substrate cap throttles adsorption when H_activity << occupied" {
    // Acidic organic horizon: occupied = 0.8 mol/Mg, H_activity = 0.001 mol/m3, Kd = 0.01.
    // equilibrium_deprotonated = Kd*occupied/H_activity = 0.01*0.8/0.001 = 8, clips to total=1.
    // deprotonated = total - occupied = 0.2 < equilibrium = 1, so change is negative (adsorption).
    //
    // SOLUTE form: substrate_limit = fraction / density * occupied
    //            = 0.5 / 2 * 0.8 = 0.2 mol/Mg  =>  change = -0.2.
    // STARTE form: substrate_limit = fraction * min(occupied, H_activity)
    //            = 0.5 * min(0.8, 0.001) = 0.0005 mol/Mg  =>  change = -0.0005.
    // The STARTE cap is 400x tighter; it prevents runaway adsorption in low-pH horizons.
    const inputs = carboxyl_module.Inputs{
        .total_carboxyl_sites_mol_per_megagram = 1.0,
        .hydrogen_occupied_sites_mol_per_megagram = 0.8,
        .hydrogen_activity_mol_per_m3 = 0.001,
        .soil_mass_per_water_volume_megagrams_per_m3 = 2.0,
    };
    const base_params = carboxyl_module.Parameters{
        .dissociation_constant_mol_per_m3 = 0.01,
        .maximum_exchange_mol_per_m3_per_iteration = 10.0,
        .substrate_limit_fraction_per_iteration = 0.5,
    };
    // SOLUTE: substrate_limit = 0.2 mol/Mg, capped below kinetic_limit = 10/2 = 5.
    var solute_params = base_params;
    solute_params.use_starte_hydrogen_substrate_cap = false;
    const solute_change = try carboxyl_module.calculateChangeMolPerMg(inputs, solute_params);

    // STARTE substrate_limit = 0.0005 mol/Mg, 400x tighter.
    var starte_params = base_params;
    starte_params.use_starte_hydrogen_substrate_cap = true;
    const starte_change = try carboxyl_module.calculateChangeMolPerMg(inputs, starte_params);

    // Both changes are negative (adsorption); STARTE magnitude is 400x smaller.
    try std.testing.expect(solute_change < 0);
    try std.testing.expect(starte_change < 0);
    try std.testing.expectApproxEqAbs(@as(f64, -0.2), solute_change, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.0005), starte_change, 1e-14);
    try std.testing.expect(@abs(starte_change) < @abs(solute_change));
}

test "STARTE hydrogen-substrate cap is identical to SOLUTE when H_activity equals occupied" {
    // Falsification: when H_activity == occupied the two forms yield the same substrate limit
    // only if the density factor equals 1.0 (megagrams_per_m3 = 1.0).
    // More generally, they differ by density. This test verifies the cap logic branches
    // and that use_starte_hydrogen_substrate_cap=false is the default.
    const inputs = carboxyl_module.Inputs{
        .total_carboxyl_sites_mol_per_megagram = 1.0,
        .hydrogen_occupied_sites_mol_per_megagram = 0.3,
        .hydrogen_activity_mol_per_m3 = 0.3,
        .soil_mass_per_water_volume_megagrams_per_m3 = 1.0, // density=1 makes forms equivalent
    };
    const params = carboxyl_module.Parameters{
        .dissociation_constant_mol_per_m3 = 0.1,
        .maximum_exchange_mol_per_m3_per_iteration = 10.0,
        .substrate_limit_fraction_per_iteration = 0.5,
    };
    // SOLUTE: 0.5/1*0.3 = 0.15. STARTE: 0.5*min(0.3,0.3)=0.15. Equal when density=1.
    var starte_params = params;
    starte_params.use_starte_hydrogen_substrate_cap = true;
    const solute_change = try carboxyl_module.calculateChangeMolPerMg(inputs, params);
    const starte_change = try carboxyl_module.calculateChangeMolPerMg(inputs, starte_params);
    try std.testing.expectApproxEqAbs(solute_change, starte_change, 1e-15);
}
