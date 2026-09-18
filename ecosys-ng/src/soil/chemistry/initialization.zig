const std = @import("std");
const ChemistryState = @import("../solute/chemistry_state.zig").State;
const phosphate_exchange = @import("../solute/phosphate_exchange.zig");
const cation_exchange = @import("../solute/cation_exchange.zig");
const charge_classification = @import("../solute/charge_classification.zig");
const surface_litter = @import("../../surface/litter_chemistry.zig");
const carboxyl_exchange_initialization = @import("carboxyl_exchange_initialization.zig");
const carboxyl_proton_exchange = @import("carboxyl_proton_exchange.zig");

const starte_surface_carboxyl_minimum_sites_mol_per_megagram: f64 = 1.0e-48;
const starte_surface_carboxyl_maximum_exchange_mol_per_megagram_iteration: f64 = 1.0e-2;

/// STARTE surface CEC: COOH (mol/Mg C) times litter carbon converted from g C
/// to Mg C, divided by litter dry mass. The result is mol charge/Mg litter.
pub fn surfaceLitterCationExchangeCapacity_mol_charge_per_megagram_litter(
    litter_carbon_g_c: f64,
    litter_dry_mass_megagrams: f64,
    carboxyl_sites_mol_per_megagram_c: f64,
) !f64 {
    inline for (.{ litter_carbon_g_c, litter_dry_mass_megagrams, carboxyl_sites_mol_per_megagram_c }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceLitterChemistryInitialization;
    if (litter_dry_mass_megagrams == 0) return if (litter_carbon_g_c == 0) 0 else error.InvalidSurfaceLitterChemistryInitialization;
    const capacity = carboxyl_sites_mol_per_megagram_c * 1.0e-6 * litter_carbon_g_c / litter_dry_mass_megagrams;
    if (!std.math.isFinite(capacity)) return error.NonFiniteSurfaceLitterChemistryInitialization;
    // STARTE 1730 applies ZEROC whenever litter mass exists. If litter mass is
    // absent the branch above corresponds to STARTE 1732 and returns zero.
    return @max(starte_surface_carboxyl_minimum_sites_mol_per_megagram, capacity);
}

/// STARTE 1726--1907 initializes and equilibrates surface carboxyl-bound H as
/// startup state, before hourly conservation baselines exist. Fixed-pH
/// (`ISALTG=0`) litter has no dynamic carboxyl inventory (STARTE 1907--1909).
pub fn initializeSurfaceLitterCarboxylHydrogen(
    state: *surface_litter.State,
    surface_cell: usize,
    litter_carbon_g_c: f64,
    litter_dry_mass_megagrams: f64,
    carboxyl_sites_mol_per_megagram_c: f64,
    carboxyl_dissociation_mol_per_m3: f64,
    dynamic_salts: bool,
    max_iterations: u16,
) !void {
    if (surface_cell >= state.cells.len) return error.ChemistryCellIndexOutOfBounds;
    if (!std.math.isFinite(carboxyl_dissociation_mol_per_m3) or
        carboxyl_dissociation_mol_per_m3 <= 0)
        return error.InvalidSurfaceLitterChemistryInitialization;
    if (max_iterations == 0)
        return error.InvalidSurfaceLitterChemistryInitialization;
    if (!dynamic_salts) {
        state.cells[surface_cell].carboxyl_hydrogen_mol_per_megagram = 0;
        return;
    }
    const capacity = try surfaceLitterCationExchangeCapacity_mol_charge_per_megagram_litter(
        litter_carbon_g_c,
        litter_dry_mass_megagrams,
        carboxyl_sites_mol_per_megagram_c,
    );
    // STARTE 1729--1733 sets XCOOH=0 when BKVL is absent and ultimately
    // publishes XHC=XHC1*BKVL=0 at line 1907. Its intervening intensive
    // ZEROC recurrence has no physical carrier in that branch; running it here
    // would instead construct an out-of-capacity intensive state. Preserve the
    // exact authoritative extensive result and leave the carrier-free Zig
    // concentration at zero.
    if (capacity == 0) {
        state.cells[surface_cell].carboxyl_hydrogen_mol_per_megagram = 0;
        return;
    }
    const hydrogen = state.cells[surface_cell].hydrogen_mol_per_m3;
    if (!std.math.isFinite(hydrogen) or hydrogen < 0)
        return error.InvalidSurfaceLitterChemistryInitialization;
    var carboxyl_state = carboxyl_proton_exchange.State{
        .total_carboxyl_sites_mol_per_megagram = capacity,
        .protonated_carboxyl_sites_mol_per_megagram = try carboxyl_exchange_initialization.protonatedSites(
            capacity,
            hydrogen,
            carboxyl_dissociation_mol_per_m3,
        ),
    };
    var iteration: u16 = 0;
    var two_steps_ago: ?f64 = null;
    while (iteration < max_iterations) : (iteration += 1) {
        const before = carboxyl_state.protonated_carboxyl_sites_mol_per_megagram;
        const result = try carboxyl_proton_exchange.surfaceStep(
            hydrogen,
            .{
                .minimum_unprotonated_sites_mol_per_megagram = starte_surface_carboxyl_minimum_sites_mol_per_megagram,
                .carboxyl_dissociation_mol_per_m3 = carboxyl_dissociation_mol_per_m3,
                .maximum_exchange_mol_per_megagram_iteration = starte_surface_carboxyl_maximum_exchange_mol_per_megagram_iteration,
            },
            &carboxyl_state,
        );
        // An exact zero is a fixed point, so the remaining source iterations
        // are state-identical. No tolerance or approximate convergence rule is
        // introduced into startup initialization.
        if (result.protonation_rate_mol_per_megagram_iteration == 0) break;
        const after = carboxyl_state.protonated_carboxyl_sites_mol_per_megagram;
        if (after == before) break;
        // The source's bounded recurrence can enter an exact two-state cycle.
        // Fast-forward its parity rather than spending the remaining budget:
        // this stops work at oscillation while preserving the exact state the
        // user-clamped MRXN schedule would publish.
        if (two_steps_ago) |prior| if (after == prior) {
            const completed_iterations = iteration + 1;
            const remaining_iterations = max_iterations - completed_iterations;
            if (remaining_iterations % 2 != 0)
                carboxyl_state.protonated_carboxyl_sites_mol_per_megagram = before;
            break;
        };
        two_steps_ago = before;
    }
    state.cells[surface_cell].carboxyl_hydrogen_mol_per_megagram =
        carboxyl_state.protonated_carboxyl_sites_mol_per_megagram;
}

/// STARTE L=0 copies equilibrated top-soil solutes into litter water while
/// retaining the independently supplied surface-litter pH.
pub fn seedSurfaceLitterFromTopsoil(
    state: *surface_litter.State,
    surface_cell: usize,
    topsoil: *const ChemistryState,
    topsoil_cell: usize,
    surface_litter_ph: f64,
    water_activity_product_mol2_per_m6: f64,
    dynamic_salts: bool,
) !void {
    if (surface_cell >= state.cells.len or topsoil_cell >= topsoil.cell_count) return error.ChemistryCellIndexOutOfBounds;
    if (!std.math.isFinite(water_activity_product_mol2_per_m6) or water_activity_product_mol2_per_m6 <= 0) return error.InvalidSurfaceLitterChemistryInitialization;
    const hydrogen = try hydrogenFromPh_mol_per_m3(surface_litter_ph);
    const hydroxide = water_activity_product_mol2_per_m6 / hydrogen;
    if (!std.math.isFinite(hydroxide) or hydroxide < 0) return error.NonFiniteSurfaceLitterChemistryInitialization;
    const aqueous = topsoil.aqueous[topsoil_cell];
    const phosphate = topsoil.non_band_phosphate[topsoil_cell];
    const solids = topsoil.geochemistry_solids[topsoil_cell];
    var cell = std.mem.zeroes(surface_litter.Cell);
    cell.ammonium_mol_per_m3 = aqueous.ammonium_non_band;
    cell.ammonia_mol_per_m3 = aqueous.ammonia_non_band;
    cell.nitrate_mol_per_m3 = aqueous.nitrate_non_band;
    cell.hpo4_mol_p_per_m3 = phosphate.dissolved_hpo4_mol_p_per_m3;
    cell.h2po4_mol_p_per_m3 = phosphate.dissolved_h2po4_mol_p_per_m3;
    cell.phosphate_surface = .{
        .deprotonated_site_mol_per_megagram = phosphate.deprotonated_site_mol_per_megagram,
        .hydroxyl_site_mol_per_megagram = phosphate.hydroxyl_site_mol_per_megagram,
        .protonated_site_mol_per_megagram = phosphate.protonated_site_mol_per_megagram,
        .adsorbed_hpo4_mol_p_per_megagram = phosphate.adsorbed_hpo4_mol_p_per_megagram,
        .adsorbed_h2po4_mol_p_per_megagram = phosphate.adsorbed_h2po4_mol_p_per_megagram,
    };
    cell.hydrogen_mol_per_m3 = hydrogen;
    cell.hydroxide_mol_per_m3 = hydroxide;
    cell.aluminum_mol_per_m3 = aqueous.aluminum;
    cell.iron_mol_per_m3 = aqueous.iron;
    cell.calcium_mol_per_m3 = aqueous.calcium;
    cell.magnesium_mol_per_m3 = aqueous.magnesium;
    cell.sodium_mol_per_m3 = aqueous.sodium;
    cell.potassium_mol_per_m3 = aqueous.potassium;
    cell.phosphate_minerals = .{
        .aluminum_phosphate_mol_per_m3 = phosphate.aluminum_phosphate_solid_mol_per_m3,
        .iron_phosphate_mol_per_m3 = phosphate.iron_phosphate_solid_mol_per_m3,
        .dicalcium_phosphate_mol_per_m3 = phosphate.dicalcium_phosphate_solid_mol_per_m3,
        .hydroxyapatite_mol_per_m3 = phosphate.hydroxyapatite_solid_mol_per_m3,
        .monocalcium_phosphate_mol_per_m3 = phosphate.monocalcium_phosphate_solid_mol_per_m3,
    };
    if (dynamic_salts) {
        cell.carbonate_mol_per_m3 = aqueous.carbonate;
        cell.bicarbonate_mol_per_m3 = aqueous.bicarbonate;
        cell.carbon_dioxide_mol_per_m3 = aqueous.carbon_dioxide;
        cell.sulfate_mol_per_m3 = aqueous.sulfate;
        cell.chloride_mol_per_m3 = aqueous.chloride;
        cell.water_mol_per_m3 = topsoil.water_mol_per_m3[topsoil_cell];
        cell.salt_minerals = .{
            .gibbsite_mol_per_m3 = solids.gibbsite_solid_mol_per_m3,
            .iron_hydroxide_mol_per_m3 = solids.iron_hydroxide_solid_mol_per_m3,
            .calcite_mol_per_m3 = solids.calcite_solid_mol_per_m3,
            .gypsum_mol_per_m3 = solids.gypsum_solid_mol_per_m3,
        };
    }
    state.cells[surface_cell] = cell;
    state.ph[surface_cell] = surface_litter_ph;
}

test "STARTE surface litter carboxyl sites convert carbon and litter mass units" {
    const capacity = try surfaceLitterCationExchangeCapacity_mol_charge_per_megagram_litter(400_000, 2, 250);
    try std.testing.expectApproxEqAbs(@as(f64, 50), capacity, 1e-14);
    try std.testing.expectEqual(@as(f64, 0), try surfaceLitterCationExchangeCapacity_mol_charge_per_megagram_litter(0, 0, 250));
    try std.testing.expectEqual(
        starte_surface_carboxyl_minimum_sites_mol_per_megagram,
        try surfaceLitterCationExchangeCapacity_mol_charge_per_megagram_litter(0, 2, 250),
    );
    try std.testing.expectError(error.InvalidSurfaceLitterChemistryInitialization, surfaceLitterCationExchangeCapacity_mol_charge_per_megagram_litter(1, 0, 250));
}

test "STARTE surface carboxyl hydrogen is initialized before hourly accounting" {
    var litter = try surface_litter.State.init(std.testing.allocator, 1);
    defer litter.deinit();
    litter.cells[0].hydrogen_mol_per_m3 = 0.01;
    try initializeSurfaceLitterCarboxylHydrogen(
        &litter,
        0,
        400_000,
        2,
        250,
        0.1,
        true,
        1000,
    );
    var source_replay = carboxyl_proton_exchange.State{
        .total_carboxyl_sites_mol_per_megagram = 50,
        .protonated_carboxyl_sites_mol_per_megagram = 5,
    };
    for (0..1000) |_| _ = try carboxyl_proton_exchange.surfaceStep(
        0.01,
        .{
            .minimum_unprotonated_sites_mol_per_megagram = starte_surface_carboxyl_minimum_sites_mol_per_megagram,
            .carboxyl_dissociation_mol_per_m3 = 0.1,
            .maximum_exchange_mol_per_megagram_iteration = starte_surface_carboxyl_maximum_exchange_mol_per_megagram_iteration,
        },
        &source_replay,
    );
    try std.testing.expectEqual(
        source_replay.protonated_carboxyl_sites_mol_per_megagram,
        litter.cells[0].carboxyl_hydrogen_mol_per_megagram,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 4.54),
        litter.cells[0].carboxyl_hydrogen_mol_per_megagram,
        2e-14,
    );
    try initializeSurfaceLitterCarboxylHydrogen(
        &litter,
        0,
        400_000,
        2,
        250,
        0.1,
        false,
        1000,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        litter.cells[0].carboxyl_hydrogen_mol_per_megagram,
    );
}

test "STARTE surface carboxyl initialization honors the hard iteration ceiling" {
    var litter = try surface_litter.State.init(std.testing.allocator, 1);
    defer litter.deinit();
    litter.cells[0].hydrogen_mol_per_m3 = 0.01;
    try initializeSurfaceLitterCarboxylHydrogen(
        &litter,
        0,
        400_000,
        2,
        250,
        0.1,
        true,
        2,
    );
    // The source seed is 5 mol/Mg; each of the first two TADC-bounded
    // iterations removes exactly 0.01 mol/Mg.
    try std.testing.expectEqual(
        @as(f64, 4.98),
        litter.cells[0].carboxyl_hydrogen_mol_per_megagram,
    );
}

test "STARTE surface carboxyl two-cycle fast-forward is literal for odd and even ceilings" {
    const Literal = struct {
        fn replay(max_iterations: u16) !f64 {
            var source = carboxyl_proton_exchange.State{
                .total_carboxyl_sites_mol_per_megagram = 50,
                .protonated_carboxyl_sites_mol_per_megagram = 5,
            };
            for (0..max_iterations) |_| _ = try carboxyl_proton_exchange.surfaceStep(
                0.01,
                .{
                    .minimum_unprotonated_sites_mol_per_megagram = starte_surface_carboxyl_minimum_sites_mol_per_megagram,
                    .carboxyl_dissociation_mol_per_m3 = 0.1,
                    .maximum_exchange_mol_per_megagram_iteration = starte_surface_carboxyl_maximum_exchange_mol_per_megagram_iteration,
                },
                &source,
            );
            return source.protonated_carboxyl_sites_mol_per_megagram;
        }
    };

    var litter = try surface_litter.State.init(std.testing.allocator, 1);
    defer litter.deinit();
    litter.cells[0].hydrogen_mol_per_m3 = 0.01;
    for ([_]u16{ 1, 2, 47, 48, 997, 998, 999, 1000 }) |ceiling| {
        try initializeSurfaceLitterCarboxylHydrogen(
            &litter,
            0,
            400_000,
            2,
            250,
            0.1,
            true,
            ceiling,
        );
        try std.testing.expectEqual(
            try Literal.replay(ceiling),
            litter.cells[0].carboxyl_hydrogen_mol_per_megagram,
        );
    }
}

test "STARTE surface carboxyl zero-mass branch publishes zero extensive inventory" {
    var litter = try surface_litter.State.init(std.testing.allocator, 1);
    defer litter.deinit();
    litter.cells[0].hydrogen_mol_per_m3 = 0.01;
    litter.cells[0].carboxyl_hydrogen_mol_per_megagram = 7;
    try initializeSurfaceLitterCarboxylHydrogen(
        &litter,
        0,
        0,
        0,
        250,
        0.01,
        true,
        1000,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        litter.cells[0].carboxyl_hydrogen_mol_per_megagram,
    );
}

test "STARTE surface litter inherits topsoil ions but retains surface pH" {
    var topsoil = try ChemistryState.init(std.testing.allocator, 1);
    defer topsoil.deinit();
    topsoil.aqueous[0].ammonium_non_band = 2;
    topsoil.aqueous[0].calcium = 3;
    topsoil.aqueous[0].sulfate = 4;
    topsoil.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 5;
    topsoil.geochemistry_solids[0].gypsum_solid_mol_per_m3 = 6;
    var litter = try surface_litter.State.init(std.testing.allocator, 1);
    defer litter.deinit();
    try seedSurfaceLitterFromTopsoil(&litter, 0, &topsoil, 0, 6, 1e-8, true);
    try std.testing.expectEqual(@as(f64, 2), litter.cells[0].ammonium_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 3), litter.cells[0].calcium_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 4), litter.cells[0].sulfate_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 5), litter.cells[0].h2po4_mol_p_per_m3);
    try std.testing.expectEqual(@as(f64, 6), litter.cells[0].salt_minerals.gypsum_mol_per_m3);
    try std.testing.expectApproxEqAbs(@as(f64, 1e-3), litter.cells[0].hydrogen_mol_per_m3, 1e-15);
    try std.testing.expectEqual(@as(f64, 6), litter.ph[0]);
    try seedSurfaceLitterFromTopsoil(&litter, 0, &topsoil, 0, 6, 1e-8, false);
    try std.testing.expectEqual(@as(f64, 0), litter.cells[0].sulfate_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0), litter.cells[0].salt_minerals.gypsum_mol_per_m3);
}

pub const PhosphateDissociationConstants = struct {
    h3po4_to_h2po4_mol_per_m3: f64,
    h2po4_to_hpo4_mol_per_m3: f64,
    hpo4_to_po4_mol_per_m3: f64,
};

pub const PhosphateSpecies = struct {
    po4_mol_p_per_m3: f64,
    hpo4_mol_p_per_m3: f64,
    h2po4_mol_p_per_m3: f64,
    h3po4_mol_p_per_m3: f64,
};

pub const ProfileSolubleParameters = struct {
    saturated_paste_phosphate_multiplier: f64,
    water_activity_product_mol2_per_m6: f64,
    gibbsite_solubility_product_mol4_per_m12: f64,
    ferric_hydroxide_solubility_product_mol4_per_m12: f64,
    phosphate_dissociation: PhosphateDissociationConstants,
};

/// STARTE constants used when a legacy runscript has no tagged runtime
/// chemistry record. They remain ordinary runtime data and may be replaced by
/// the user's `chemistry_initialization` record.
pub fn sourceParameters() ProfileSolubleParameters {
    return .{
        .saturated_paste_phosphate_multiplier = 0.01,
        .water_activity_product_mol2_per_m6 = 1.0e-8,
        .gibbsite_solubility_product_mol4_per_m12 = 1.9e-21,
        .ferric_hydroxide_solubility_product_mol4_per_m12 = 6.3e-26,
        .phosphate_dissociation = .{
            .h3po4_to_h2po4_mol_per_m3 = 7.5,
            .h2po4_to_hpo4_mol_per_m3 = 6.2e-5,
            .hpo4_to_po4_mol_per_m3 = 4.8e-10,
        },
    };
}

pub const ProfilePrimaryInputs = struct {
    soil_ph: f64,
    ammonium_g_n_per_megagram: f64,
    nitrate_g_n_per_megagram: f64,
    phosphate_g_p_per_megagram: f64,
    aluminum_g_per_megagram: f64,
    iron_g_per_megagram: f64,
    calcium_g_per_megagram: f64,
    magnesium_g_per_megagram: f64,
    sodium_g_per_megagram: f64,
    potassium_g_per_megagram: f64,
    sulfate_sulfur_g_s_per_megagram: f64,
    chloride_g_per_megagram: f64,
    aluminum_phosphate_g_p_per_megagram: f64,
    iron_phosphate_g_p_per_megagram: f64,
    dicalcium_phosphate_g_p_per_megagram: f64,
    apatite_g_p_per_megagram: f64,
    aluminum_hydroxide_g_al_per_megagram: f64,
    iron_hydroxide_g_fe_per_megagram: f64,
    calcium_carbonate_g_ca_per_megagram: f64,
    calcium_sulfate_g_ca_per_megagram: f64,
};

pub const ElementMolarMassesGPerMol = struct {
    nitrogen: f64,
    phosphorus: f64,
    aluminum: f64,
    iron: f64,
    calcium: f64,
    magnesium: f64,
    sodium: f64,
    potassium: f64,
    sulfur: f64,
    chloride: f64,
};

pub const PrimaryInitializationParameters = struct {
    soluble: ProfileSolubleParameters,
    molar_mass_g_per_mol: ElementMolarMassesGPerMol,
    minimum_ammonium_g_n_per_megagram: f64,
    minimum_calcium_g_per_megagram: f64,
    soil_ammonium_extract_multiplier: f64,
    extract_mol_per_megagram_to_mol_per_m3: f64,
};

/// STARTE converts pH (mol L-1 convention) to mol m-3 before every aqueous
/// equilibrium calculation.
pub fn hydrogenFromPh_mol_per_m3(ph: f64) !f64 {
    if (!std.math.isFinite(ph)) return error.NonFiniteSoilPh;
    const hydrogen = std.math.pow(f64, 10.0, -(ph - 3.0));
    if (!std.math.isFinite(hydrogen) or hydrogen <= 0) return error.InvalidSoilPh;
    return hydrogen;
}

test "source chemistry parameters reproduce STARTE constants" {
    const parameters = sourceParameters();
    try std.testing.expectEqual(@as(f64, 0.01), parameters.saturated_paste_phosphate_multiplier);
    try std.testing.expectEqual(@as(f64, 1.0e-8), parameters.water_activity_product_mol2_per_m6);
    try std.testing.expectEqual(@as(f64, 1.9e-21), parameters.gibbsite_solubility_product_mol4_per_m12);
    try std.testing.expectEqual(@as(f64, 6.3e-26), parameters.ferric_hydroxide_solubility_product_mol4_per_m12);
    try std.testing.expectEqual(@as(f64, 7.5), parameters.phosphate_dissociation.h3po4_to_h2po4_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 6.2e-5), parameters.phosphate_dissociation.h2po4_to_hpo4_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 4.8e-10), parameters.phosphate_dissociation.hpo4_to_po4_mol_per_m3);
}

/// Resolves the documented negative Al and Fe profile sentinels before state
/// construction. `starte.f` lines 265--273 initializes those ions at hydroxide-mineral
/// equilibrium; the returned values use the profile's g Mg-1 units.
pub fn resolveProfileEquilibriumSentinels(inputs: ProfilePrimaryInputs, parameters: PrimaryInitializationParameters) !ProfilePrimaryInputs {
    var resolved = inputs;
    if (!std.math.isFinite(inputs.soil_ph)) return error.InvalidProfileChemistryInitialization;
    const hydrogen = try hydrogenFromPh_mol_per_m3(inputs.soil_ph);
    const hydroxide = parameters.soluble.water_activity_product_mol2_per_m6 / hydrogen;
    if (!std.math.isFinite(hydroxide) or hydroxide <= 0) return error.InvalidProfileChemistryInitialization;
    const hydroxide_cubed = hydroxide * hydroxide * hydroxide;
    if (!std.math.isFinite(hydroxide_cubed) or hydroxide_cubed <= 0) return error.InvalidProfileChemistryInitialization;
    if (inputs.aluminum_g_per_megagram < 0) {
        resolved.aluminum_g_per_megagram = parameters.soluble.gibbsite_solubility_product_mol4_per_m12 /
            hydroxide_cubed * parameters.molar_mass_g_per_mol.aluminum /
            parameters.extract_mol_per_megagram_to_mol_per_m3;
    }
    if (inputs.iron_g_per_megagram < 0) {
        resolved.iron_g_per_megagram = parameters.soluble.ferric_hydroxide_solubility_product_mol4_per_m12 /
            hydroxide_cubed * parameters.molar_mass_g_per_mol.iron /
            parameters.extract_mol_per_megagram_to_mol_per_m3;
    }
    inline for (.{ resolved.aluminum_g_per_megagram, resolved.iron_g_per_megagram }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidProfileChemistryInitialization;
    return resolved;
}

/// `starte.f` lines 323--335 initial phosphate protonation. A normalized log-domain
/// evaluation preserves the source equilibrium while avoiding overflow for
/// extreme but finite user pH values.
pub fn initialPhosphateSpecies(total_phosphate_mol_p_per_m3: f64, hydrogen_mol_per_m3: f64, constants: PhosphateDissociationConstants) !PhosphateSpecies {
    inline for (.{ total_phosphate_mol_p_per_m3, hydrogen_mol_per_m3, constants.h3po4_to_h2po4_mol_per_m3, constants.h2po4_to_hpo4_mol_per_m3, constants.hpo4_to_po4_mol_per_m3 }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidInitialPhosphateSpeciation;
    if (hydrogen_mol_per_m3 <= 0 or constants.h3po4_to_h2po4_mol_per_m3 <= 0 or constants.h2po4_to_hpo4_mol_per_m3 <= 0 or constants.hpo4_to_po4_mol_per_m3 <= 0) return error.InvalidInitialPhosphateSpeciation;
    if (total_phosphate_mol_p_per_m3 == 0) return .{ .po4_mol_p_per_m3 = 0, .hpo4_mol_p_per_m3 = 0, .h2po4_mol_p_per_m3 = 0, .h3po4_mol_p_per_m3 = 0 };
    const log_hydrogen = @log(hydrogen_mol_per_m3);
    const log_h3: f64 = 0;
    const log_h2 = @log(constants.h3po4_to_h2po4_mol_per_m3) - log_hydrogen;
    const log_h1 = log_h2 + @log(constants.h2po4_to_hpo4_mol_per_m3) - log_hydrogen;
    const log_h0 = log_h1 + @log(constants.hpo4_to_po4_mol_per_m3) - log_hydrogen;
    const maximum_log = @max(@max(log_h3, log_h2), @max(log_h1, log_h0));
    const weight_h3 = @exp(log_h3 - maximum_log);
    const weight_h2 = @exp(log_h2 - maximum_log);
    const weight_h1 = @exp(log_h1 - maximum_log);
    const weight_h0 = @exp(log_h0 - maximum_log);
    const weight_sum = weight_h3 + weight_h2 + weight_h1 + weight_h0;
    if (!std.math.isFinite(weight_sum) or weight_sum <= 0) return error.NonFiniteInitialPhosphateSpeciation;
    const result: PhosphateSpecies = .{
        .po4_mol_p_per_m3 = total_phosphate_mol_p_per_m3 * weight_h0 / weight_sum,
        .hpo4_mol_p_per_m3 = total_phosphate_mol_p_per_m3 * weight_h1 / weight_sum,
        .h2po4_mol_p_per_m3 = total_phosphate_mol_p_per_m3 * weight_h2 / weight_sum,
        .h3po4_mol_p_per_m3 = total_phosphate_mol_p_per_m3 * weight_h3 / weight_sum,
    };
    inline for (@typeInfo(PhosphateSpecies).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.NonFiniteInitialPhosphateSpeciation;
    return result;
}

/// Seeds the soil (K=3) branch before STARTE's coupled 1000-iteration solve.
/// The profile phosphate input is g P Mg-1; READI converts it to mol P Mg-1,
/// and STARTE applies its runtime saturated-paste multiplier as mol P m-3.
pub fn seedProfilePhosphate(state: *ChemistryState, layer: usize, soil_ph: f64, phosphate_g_p_per_megagram: f64, parameters: ProfileSolubleParameters) !void {
    if (layer >= state.cell_count) return error.ChemistryCellIndexOutOfBounds;
    inline for (.{ phosphate_g_p_per_megagram, parameters.saturated_paste_phosphate_multiplier, parameters.water_activity_product_mol2_per_m6 }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidProfileChemistryInitialization;
    if (parameters.saturated_paste_phosphate_multiplier > 1 or parameters.water_activity_product_mol2_per_m6 <= 0) return error.InvalidProfileChemistryInitialization;
    const hydrogen = try hydrogenFromPh_mol_per_m3(soil_ph);
    const hydroxide = parameters.water_activity_product_mol2_per_m6 / hydrogen;
    if (!std.math.isFinite(hydroxide) or hydroxide < 0) return error.NonFiniteProfileChemistryInitialization;
    const soluble_phosphate_mol_p_per_m3 = parameters.saturated_paste_phosphate_multiplier * phosphate_g_p_per_megagram / 31.0;
    const species = try initialPhosphateSpecies(soluble_phosphate_mol_p_per_m3, hydrogen, parameters.phosphate_dissociation);
    var aqueous = state.aqueous[layer];
    var non_band = state.non_band_phosphate[layer];
    var band = state.band_phosphate[layer];
    aqueous.hydrogen = hydrogen;
    aqueous.hydroxide = hydroxide;
    inline for (.{ &non_band, &band }) |zone| {
        zone.dissolved_po4_mol_p_per_m3 = species.po4_mol_p_per_m3;
        zone.dissolved_hpo4_mol_p_per_m3 = species.hpo4_mol_p_per_m3;
        zone.dissolved_h2po4_mol_p_per_m3 = species.h2po4_mol_p_per_m3;
        zone.dissolved_h3po4_mol_p_per_m3 = species.h3po4_mol_p_per_m3;
    }
    state.aqueous[layer] = aqueous;
    state.non_band_phosphate[layer] = non_band;
    state.band_phosphate[layer] = band;
}

/// Seeds STARTE primary free ions and input mineral inventories. Ion pairing,
/// adsorption, exchange, precipitation, and weathering follow in the coupled
/// hybrid solve rather than a full-model sub-hour cycle.
pub fn seedProfilePrimaryState(state: *ChemistryState, layer: usize, inputs: ProfilePrimaryInputs, soil_mass_megagrams: f64, soil_water_volume_m3: f64, parameters: PrimaryInitializationParameters) !void {
    if (layer >= state.cell_count) return error.ChemistryCellIndexOutOfBounds;
    inline for (@typeInfo(ProfilePrimaryInputs).@"struct".fields) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value)) return error.InvalidProfileChemistryInitialization;
        if (comptime !std.mem.eql(u8, field.name, "soil_ph")) if (value < 0) {
            std.log.err("negative unresolved soil chemistry input: field={s} value={e} layer={d}", .{ field.name, value, layer });
            return error.InvalidProfileChemistryInitialization;
        };
    }
    inline for (@typeInfo(ElementMolarMassesGPerMol).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters.molar_mass_g_per_mol, field.name)) or @field(parameters.molar_mass_g_per_mol, field.name) <= 0) return error.InvalidProfileChemistryInitialization;
    inline for (.{ soil_mass_megagrams, soil_water_volume_m3, parameters.minimum_ammonium_g_n_per_megagram, parameters.minimum_calcium_g_per_megagram, parameters.soil_ammonium_extract_multiplier, parameters.extract_mol_per_megagram_to_mol_per_m3 }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidProfileChemistryInitialization;
    if (soil_water_volume_m3 <= 0 or parameters.soil_ammonium_extract_multiplier > 1 or parameters.extract_mol_per_megagram_to_mol_per_m3 <= 0) return error.InvalidProfileChemistryInitialization;
    var staged = try ChemistryState.init(state.allocator, 1);
    defer staged.deinit();
    staged.aqueous[0] = state.aqueous[layer];
    staged.non_band_phosphate[0] = state.non_band_phosphate[layer];
    staged.band_phosphate[0] = state.band_phosphate[layer];
    staged.water_mol_per_m3[0] = state.water_mol_per_m3[layer];
    staged.cation_exchange_mol_per_megagram[0] = state.cation_exchange_mol_per_megagram[layer];
    staged.geochemistry_solids[0] = state.geochemistry_solids[layer];
    try seedProfilePhosphate(&staged, 0, inputs.soil_ph, inputs.phosphate_g_p_per_megagram, parameters.soluble);
    const masses = parameters.molar_mass_g_per_mol;
    const extract_scale = parameters.extract_mol_per_megagram_to_mol_per_m3;
    const aqueous = &staged.aqueous[0];
    const ammonium = parameters.soil_ammonium_extract_multiplier * @max(parameters.minimum_ammonium_g_n_per_megagram, inputs.ammonium_g_n_per_megagram) / masses.nitrogen * extract_scale;
    aqueous.ammonium_non_band = ammonium;
    aqueous.ammonium_band = ammonium;
    aqueous.nitrate_non_band = inputs.nitrate_g_n_per_megagram / masses.nitrogen * extract_scale;
    aqueous.nitrate_band = aqueous.nitrate_non_band;
    aqueous.aluminum = inputs.aluminum_g_per_megagram / masses.aluminum * extract_scale;
    aqueous.iron = inputs.iron_g_per_megagram / masses.iron * extract_scale;
    aqueous.calcium = @max(parameters.minimum_calcium_g_per_megagram, inputs.calcium_g_per_megagram) / masses.calcium * extract_scale;
    aqueous.magnesium = inputs.magnesium_g_per_megagram / masses.magnesium * extract_scale;
    aqueous.sodium = inputs.sodium_g_per_megagram / masses.sodium * extract_scale;
    aqueous.potassium = inputs.potassium_g_per_megagram / masses.potassium * extract_scale;
    aqueous.sulfate = inputs.sulfate_sulfur_g_s_per_megagram / masses.sulfur * extract_scale;
    aqueous.chloride = inputs.chloride_g_per_megagram / masses.chloride * extract_scale;
    const solid_concentration_scale = soil_mass_megagrams / soil_water_volume_m3;
    inline for (.{ &staged.non_band_phosphate[0], &staged.band_phosphate[0] }) |phosphate| {
        phosphate.aluminum_phosphate_solid_mol_per_m3 = inputs.aluminum_phosphate_g_p_per_megagram / masses.phosphorus * solid_concentration_scale;
        phosphate.iron_phosphate_solid_mol_per_m3 = inputs.iron_phosphate_g_p_per_megagram / masses.phosphorus * solid_concentration_scale;
        phosphate.dicalcium_phosphate_solid_mol_per_m3 = inputs.dicalcium_phosphate_g_p_per_megagram / masses.phosphorus * solid_concentration_scale;
        phosphate.hydroxyapatite_solid_mol_per_m3 = inputs.apatite_g_p_per_megagram / (3 * masses.phosphorus) * solid_concentration_scale;
    }
    staged.geochemistry_solids[0].gibbsite_solid_mol_per_m3 = inputs.aluminum_hydroxide_g_al_per_megagram / masses.aluminum * solid_concentration_scale;
    staged.geochemistry_solids[0].iron_hydroxide_solid_mol_per_m3 = inputs.iron_hydroxide_g_fe_per_megagram / masses.iron * solid_concentration_scale;
    staged.geochemistry_solids[0].calcite_solid_mol_per_m3 = inputs.calcium_carbonate_g_ca_per_megagram / masses.calcium * solid_concentration_scale;
    staged.geochemistry_solids[0].gypsum_solid_mol_per_m3 = inputs.calcium_sulfate_g_ca_per_megagram / masses.calcium * solid_concentration_scale;
    const state_vector = try state.allocator.alloc(f64, ChemistryState.packedComponentCount());
    defer state.allocator.free(state_vector);
    try staged.packCell(0, state_vector);
    try state.unpackCell(layer, state_vector);
}

/// `starte.f` lines 332--360 initializes the complete anion-exchange inventory before
/// iterative reactions. Capacities are concentrations per Mg of soil; no grid
/// extent is embedded in this scientific state.
pub fn seedProfilePhosphateSurfaceSites(
    state: *ChemistryState,
    layer: usize,
    total_profile_phosphate_mol_p_per_megagram: f64,
    anion_exchange_capacity_mol_charge_per_megagram: f64,
    surface: phosphate_exchange.Parameters,
    h2po4_dissociation_constant_mol_per_m3: f64,
) !void {
    if (layer >= state.cell_count) return error.ChemistryCellIndexOutOfBounds;
    inline for (.{ total_profile_phosphate_mol_p_per_megagram, anion_exchange_capacity_mol_charge_per_megagram, h2po4_dissociation_constant_mol_per_m3 }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidProfileChemistryInitialization;
    if (h2po4_dissociation_constant_mol_per_m3 <= 0 or surface.protonated_site_equilibrium_constant <= 0 or surface.hydroxyl_site_equilibrium_constant <= 0 or surface.h2po4_exchange_equilibrium_constant <= 0 or surface.hpo4_exchange_equilibrium_constant <= 0) return error.InvalidProfileChemistryInitialization;
    const hydrogen = state.aqueous[layer].hydrogen;
    if (!std.math.isFinite(hydrogen) or hydrogen <= 0) return error.InvalidProfileChemistryInitialization;

    // Source names SXOH2/SXOH1 describe successive site deprotonation.
    const protonated_weight: f64 = 1;
    const hydroxyl_weight = surface.protonated_site_equilibrium_constant / hydrogen;
    const deprotonated_weight = hydroxyl_weight * surface.hydroxyl_site_equilibrium_constant / hydrogen;
    const site_weight_sum = protonated_weight + hydroxyl_weight + deprotonated_weight;
    const adsorbed_total = @min(anion_exchange_capacity_mol_charge_per_megagram, total_profile_phosphate_mol_p_per_megagram);
    const unoccupied_total = anion_exchange_capacity_mol_charge_per_megagram - adsorbed_total;
    const hpo4_to_h2po4_ratio = surface.h2po4_exchange_equilibrium_constant * h2po4_dissociation_constant_mol_per_m3 /
        (surface.hpo4_exchange_equilibrium_constant * hydrogen);
    const adsorbed_h2po4 = adsorbed_total / (1 + hpo4_to_h2po4_ratio);
    const adsorbed_hpo4 = adsorbed_total - adsorbed_h2po4;
    inline for (.{ &state.non_band_phosphate[layer], &state.band_phosphate[layer] }) |zone| {
        zone.protonated_site_mol_per_megagram = unoccupied_total * protonated_weight / site_weight_sum;
        zone.hydroxyl_site_mol_per_megagram = unoccupied_total * hydroxyl_weight / site_weight_sum;
        zone.deprotonated_site_mol_per_megagram = unoccupied_total * deprotonated_weight / site_weight_sum;
        zone.adsorbed_h2po4_mol_p_per_megagram = adsorbed_h2po4;
        zone.adsorbed_hpo4_mol_p_per_megagram = adsorbed_hpo4;
    }
}

/// `starte.f` lines 715--763 performs an exact first-iteration Gapon partition. Seeding
/// it explicitly avoids spending hybrid iterations reconstructing an algebraic
/// equilibrium and retains the source charge-equivalent normalization.
pub fn seedProfileCationExchange(
    state: *ChemistryState,
    layer: usize,
    capacity_mol_charge_per_megagram: f64,
    selectivity: cation_exchange.Selectivity,
    fractions: charge_classification.ZoneFractions,
) !void {
    if (layer >= state.cell_count) return error.ChemistryCellIndexOutOfBounds;
    if (!std.math.isFinite(capacity_mol_charge_per_megagram) or capacity_mol_charge_per_megagram < 0) return error.InvalidProfileChemistryInitialization;
    inline for (@typeInfo(cation_exchange.Selectivity).@"struct".fields) |field| if (!std.math.isFinite(@field(selectivity, field.name)) or @field(selectivity, field.name) < 0) return error.InvalidProfileChemistryInitialization;
    if (capacity_mol_charge_per_megagram == 0) {
        state.cation_exchange_mol_per_megagram[layer] = std.mem.zeroes(cation_exchange.Cations);
        return;
    }
    const coefficients = try state.activityCoefficients(layer, fractions);
    const aqueous = state.aqueous[layer];
    const calcium_root = @sqrt(aqueous.calcium * coefficients.divalent_activity_coefficient);
    if (!std.math.isFinite(calcium_root) or calcium_root <= 0) return error.CationExchangeRequiresPositiveCalciumActivity;
    const aluminum_root = std.math.pow(f64, aqueous.aluminum * coefficients.trivalent_activity_coefficient, 1.0 / 3.0);
    const iron_root = std.math.pow(f64, aqueous.iron * coefficients.trivalent_activity_coefficient, 1.0 / 3.0);
    const magnesium_root = @sqrt(aqueous.magnesium * coefficients.divalent_activity_coefficient);
    const monovalent = coefficients.monovalent_activity_coefficient;
    const s = selectivity;
    const denominator = 1 +
        s.calcium_ammonium * aqueous.ammonium_non_band * monovalent / calcium_root * fractions.ammonium_non_band +
        s.calcium_ammonium * aqueous.ammonium_band * monovalent / calcium_root * fractions.ammonium_band +
        s.calcium_hydrogen * aqueous.hydrogen * monovalent / calcium_root +
        3 * s.calcium_aluminum_and_iron * (aluminum_root + iron_root) / calcium_root +
        2 * s.calcium_magnesium * magnesium_root / calcium_root +
        s.calcium_sodium * aqueous.sodium * monovalent / calcium_root +
        s.calcium_potassium * aqueous.potassium * monovalent / calcium_root;
    if (!std.math.isFinite(denominator) or denominator <= 0) return error.InvalidCationExchangeEquilibrium;
    const calcium_basis = capacity_mol_charge_per_megagram / denominator;
    state.cation_exchange_mol_per_megagram[layer] = .{
        .ammonium_non_band = calcium_basis * s.calcium_ammonium * aqueous.ammonium_non_band * monovalent / calcium_root,
        .ammonium_band = calcium_basis * s.calcium_ammonium * aqueous.ammonium_band * monovalent / calcium_root,
        .hydrogen = calcium_basis * s.calcium_hydrogen * aqueous.hydrogen * monovalent / calcium_root,
        .aluminum = calcium_basis * s.calcium_aluminum_and_iron * aluminum_root / calcium_root,
        .iron = calcium_basis * s.calcium_aluminum_and_iron * iron_root / calcium_root,
        .calcium = calcium_basis,
        .magnesium = calcium_basis * s.calcium_magnesium * magnesium_root / calcium_root,
        .sodium = calcium_basis * s.calcium_sodium * aqueous.sodium * monovalent / calcium_root,
        .potassium = calcium_basis * s.calcium_potassium * aqueous.potassium * monovalent / calcium_root,
    };
    const exchange = &state.cation_exchange_mol_per_megagram[layer];
    var charge = exchange.ammonium_non_band * fractions.ammonium_non_band + exchange.ammonium_band * fractions.ammonium_band + exchange.hydrogen + 3 * (exchange.aluminum + exchange.iron) + 2 * (exchange.calcium + exchange.magnesium) + exchange.sodium + exchange.potassium;
    if (!std.math.isFinite(charge) or charge <= 0) return error.InvalidCationExchangeEquilibrium;
    const source_normalization = capacity_mol_charge_per_megagram / charge;
    inline for (@typeInfo(cation_exchange.Cations).@"struct".fields) |field| @field(exchange.*, field.name) *= source_normalization;
    charge = exchange.ammonium_non_band * fractions.ammonium_non_band + exchange.ammonium_band * fractions.ammonium_band + exchange.hydrogen + 3 * (exchange.aluminum + exchange.iron) + 2 * (exchange.calcium + exchange.magnesium) + exchange.sodium + exchange.potassium;
    if (!std.math.isFinite(charge) or @abs(charge - capacity_mol_charge_per_megagram) > 1e-10 * @max(1.0, capacity_mol_charge_per_megagram)) return error.NonConservativeCationExchangeInitialization;
}

/// STARTE line 403, `XHC1=XCOOH*AMIN1(1.0,CHY1/DPCOH)`. Establishes the
/// hydrogen-occupied carboxyl pool for one runtime soil layer before the
/// initial per-layer equilibrium solve, exactly as the source does before its
/// `DO 1000 M=1,MRXN` reaction loop.
///
/// This seed is not an optimization. `State.init` zeroes
/// `carboxyl_bound_hydrogen_mol_per_megagram`, and zero occupancy is an
/// absorbing state for the SOLUTE carboxyl reaction: its substrate limit
/// `FIONX/BKVLW*XHC1` is proportional to the occupied pool, so with a zero pool
/// every carboxyl exchange extent clamps to exactly zero for every iteration
/// and the organic proton buffer contributes identically nothing to the proton
/// balance. Without this seed the buffer is structurally dead on the
/// initialization path regardless of soil organic carbon or pH.
///
/// The formula itself is owned by
/// `soil_carboxyl_exchange_initialization.protonatedSites`; this function only
/// state_updates it to the runtime layer, so there is one owner of the science.
pub fn seedProfileCarboxylOccupancy(
    state: *ChemistryState,
    layer: usize,
    total_carboxyl_sites_mol_per_megagram: f64,
    carboxyl_dissociation_constant_mol_per_m3: f64,
) !void {
    if (layer >= state.cell_count) return error.ChemistryCellIndexOutOfBounds;
    const hydrogen = state.aqueous[layer].hydrogen;
    if (!std.math.isFinite(hydrogen) or hydrogen < 0)
        return error.InvalidProfileChemistryInitialization;
    const occupied = try carboxyl_exchange_initialization.protonatedSites(
        total_carboxyl_sites_mol_per_megagram,
        hydrogen,
        carboxyl_dissociation_constant_mol_per_m3,
    );
    if (occupied > total_carboxyl_sites_mol_per_megagram)
        return error.InvalidProfileChemistryInitialization;
    state.carboxyl_bound_hydrogen_mol_per_megagram[layer] = occupied;
}

test "STARTE phosphate protonation is conservative and source equivalent" {
    const constants: PhosphateDissociationConstants = .{
        .h3po4_to_h2po4_mol_per_m3 = 7.5,
        .h2po4_to_hpo4_mol_per_m3 = 6.2e-5,
        .hpo4_to_po4_mol_per_m3 = 4.8e-10,
    };
    const hydrogen = try hydrogenFromPh_mol_per_m3(6.5);
    const species = try initialPhosphateSpecies(2.5, hydrogen, constants);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), species.po4_mol_p_per_m3 + species.hpo4_mol_p_per_m3 + species.h2po4_mol_p_per_m3 + species.h3po4_mol_p_per_m3, 1.0e-14);
    const source_denominator = 1.0 + constants.h3po4_to_h2po4_mol_per_m3 / hydrogen + constants.h3po4_to_h2po4_mol_per_m3 * constants.h2po4_to_hpo4_mol_per_m3 / (hydrogen * hydrogen) + constants.h3po4_to_h2po4_mol_per_m3 * constants.h2po4_to_hpo4_mol_per_m3 * constants.hpo4_to_po4_mol_per_m3 / (hydrogen * hydrogen * hydrogen);
    try std.testing.expectApproxEqAbs(2.5 / source_denominator, species.h3po4_mol_p_per_m3, 1.0e-14);
}

test "log-domain phosphate initialization remains finite at extreme pH" {
    const constants: PhosphateDissociationConstants = .{ .h3po4_to_h2po4_mol_per_m3 = 7.5, .h2po4_to_hpo4_mol_per_m3 = 6.2e-5, .hpo4_to_po4_mol_per_m3 = 4.8e-10 };
    const species = try initialPhosphateSpecies(1, try hydrogenFromPh_mol_per_m3(40), constants);
    try std.testing.expectApproxEqAbs(@as(f64, 1), species.po4_mol_p_per_m3 + species.hpo4_mol_p_per_m3 + species.h2po4_mol_p_per_m3 + species.h3po4_mol_p_per_m3, 1.0e-14);
    try std.testing.expect(species.po4_mol_p_per_m3 > 0.999999);
}

test "STARTE soil branch seeds H OH and both runtime phosphate zones atomically" {
    var state = try ChemistryState.init(std.testing.allocator, 2);
    defer state.deinit();
    try seedProfilePhosphate(&state, 1, 6.5, 31, .{
        .saturated_paste_phosphate_multiplier = 0.01,
        .water_activity_product_mol2_per_m6 = 1.0e-8,
        .gibbsite_solubility_product_mol4_per_m12 = 1.9e-21,
        .ferric_hydroxide_solubility_product_mol4_per_m12 = 6.3e-26,
        .phosphate_dissociation = .{ .h3po4_to_h2po4_mol_per_m3 = 7.5, .h2po4_to_hpo4_mol_per_m3 = 6.2e-5, .hpo4_to_po4_mol_per_m3 = 4.8e-10 },
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), state.non_band_phosphate[1].dissolved_po4_mol_p_per_m3 + state.non_band_phosphate[1].dissolved_hpo4_mol_p_per_m3 + state.non_band_phosphate[1].dissolved_h2po4_mol_p_per_m3 + state.non_band_phosphate[1].dissolved_h3po4_mol_p_per_m3, 1.0e-14);
    try std.testing.expectEqual(state.non_band_phosphate[1].dissolved_h2po4_mol_p_per_m3, state.band_phosphate[1].dissolved_h2po4_mol_p_per_m3);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0e-8), state.aqueous[1].hydrogen * state.aqueous[1].hydroxide, 1.0e-20);
}

test "STARTE primary profile ions and solids use explicit runtime conversions" {
    var state = try ChemistryState.init(std.testing.allocator, 1);
    defer state.deinit();
    try seedProfilePrimaryState(&state, 0, .{
        .soil_ph = 6.5,
        .ammonium_g_n_per_megagram = 14,
        .nitrate_g_n_per_megagram = 28,
        .phosphate_g_p_per_megagram = 31,
        .aluminum_g_per_megagram = 27,
        .iron_g_per_megagram = 56,
        .calcium_g_per_megagram = 40,
        .magnesium_g_per_megagram = 24.3,
        .sodium_g_per_megagram = 23,
        .potassium_g_per_megagram = 39.1,
        .sulfate_sulfur_g_s_per_megagram = 32,
        .chloride_g_per_megagram = 35.5,
        .aluminum_phosphate_g_p_per_megagram = 31,
        .iron_phosphate_g_p_per_megagram = 31,
        .dicalcium_phosphate_g_p_per_megagram = 31,
        .apatite_g_p_per_megagram = 93,
        .aluminum_hydroxide_g_al_per_megagram = 27,
        .iron_hydroxide_g_fe_per_megagram = 56,
        .calcium_carbonate_g_ca_per_megagram = 40,
        .calcium_sulfate_g_ca_per_megagram = 40,
    }, 2, 0.5, .{
        .soluble = .{ .saturated_paste_phosphate_multiplier = 0.01, .water_activity_product_mol2_per_m6 = 1e-8, .gibbsite_solubility_product_mol4_per_m12 = 1.9e-21, .ferric_hydroxide_solubility_product_mol4_per_m12 = 6.3e-26, .phosphate_dissociation = .{ .h3po4_to_h2po4_mol_per_m3 = 7.5, .h2po4_to_hpo4_mol_per_m3 = 6.2e-5, .hpo4_to_po4_mol_per_m3 = 4.8e-10 } },
        .molar_mass_g_per_mol = .{ .nitrogen = 14, .phosphorus = 31, .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 },
        .minimum_ammonium_g_n_per_megagram = 1,
        .minimum_calcium_g_per_megagram = 1,
        .soil_ammonium_extract_multiplier = 0.01,
        .extract_mol_per_megagram_to_mol_per_m3 = 1,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), state.aqueous[0].ammonium_non_band, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2), state.aqueous[0].nitrate_non_band, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 4), state.non_band_phosphate[0].aluminum_phosphate_solid_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 4), state.geochemistry_solids[0].gibbsite_solid_mol_per_m3, 1e-15);
}

test "negative profile aluminum and iron request hydroxide mineral equilibrium" {
    const parameters: PrimaryInitializationParameters = .{
        .soluble = .{
            .saturated_paste_phosphate_multiplier = 0.01,
            .water_activity_product_mol2_per_m6 = 1.0e-8,
            .gibbsite_solubility_product_mol4_per_m12 = 1.9e-21,
            .ferric_hydroxide_solubility_product_mol4_per_m12 = 6.3e-26,
            .phosphate_dissociation = .{ .h3po4_to_h2po4_mol_per_m3 = 7.5, .h2po4_to_hpo4_mol_per_m3 = 6.2e-5, .hpo4_to_po4_mol_per_m3 = 4.8e-10 },
        },
        .molar_mass_g_per_mol = .{ .nitrogen = 14, .phosphorus = 31, .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 },
        .minimum_ammonium_g_n_per_megagram = 1,
        .minimum_calcium_g_per_megagram = 1,
        .soil_ammonium_extract_multiplier = 0.01,
        .extract_mol_per_megagram_to_mol_per_m3 = 1,
    };
    const inputs: ProfilePrimaryInputs = .{
        .soil_ph = 6.42,
        .ammonium_g_n_per_megagram = 0,
        .nitrate_g_n_per_megagram = 0,
        .phosphate_g_p_per_megagram = 0,
        .aluminum_g_per_megagram = -1,
        .iron_g_per_megagram = -1,
        .calcium_g_per_megagram = 0,
        .magnesium_g_per_megagram = 0,
        .sodium_g_per_megagram = 0,
        .potassium_g_per_megagram = 0,
        .sulfate_sulfur_g_s_per_megagram = 0,
        .chloride_g_per_megagram = 0,
        .aluminum_phosphate_g_p_per_megagram = 0,
        .iron_phosphate_g_p_per_megagram = 0,
        .dicalcium_phosphate_g_p_per_megagram = 0,
        .apatite_g_p_per_megagram = 0,
        .aluminum_hydroxide_g_al_per_megagram = 0,
        .iron_hydroxide_g_fe_per_megagram = 0,
        .calcium_carbonate_g_ca_per_megagram = 0,
        .calcium_sulfate_g_ca_per_megagram = 0,
    };
    const resolved = try resolveProfileEquilibriumSentinels(inputs, parameters);
    const hydrogen = try hydrogenFromPh_mol_per_m3(inputs.soil_ph);
    const hydroxide = parameters.soluble.water_activity_product_mol2_per_m6 / hydrogen;
    try std.testing.expectApproxEqRel(parameters.soluble.gibbsite_solubility_product_mol4_per_m12 / std.math.pow(f64, hydroxide, 3) * 27, resolved.aluminum_g_per_megagram, 1.0e-14);
    try std.testing.expectApproxEqRel(parameters.soluble.ferric_hydroxide_solubility_product_mol4_per_m12 / std.math.pow(f64, hydroxide, 3) * 56, resolved.iron_g_per_megagram, 1.0e-14);

    var explicit = inputs;
    explicit.aluminum_g_per_megagram = 12;
    explicit.iron_g_per_megagram = 34;
    const preserved = try resolveProfileEquilibriumSentinels(explicit, parameters);
    try std.testing.expectEqual(@as(f64, 12), preserved.aluminum_g_per_megagram);
    try std.testing.expectEqual(@as(f64, 34), preserved.iron_g_per_megagram);
}

test "STARTE surface sites and Gapon exchange seed exact conserved capacities" {
    var state = try ChemistryState.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0].hydrogen = 0.01;
    state.aqueous[0].hydroxide = 1e-6;
    state.aqueous[0].ammonium_non_band = 0.2;
    state.aqueous[0].ammonium_band = 0.2;
    state.aqueous[0].aluminum = 0.01;
    state.aqueous[0].iron = 0.01;
    state.aqueous[0].calcium = 2;
    state.aqueous[0].magnesium = 1;
    state.aqueous[0].sodium = 0.5;
    state.aqueous[0].potassium = 0.1;
    const surface = phosphate_exchange.Parameters{ .protonated_site_equilibrium_constant = 0.45, .hydroxyl_site_equilibrium_constant = 8.1e-4, .h2po4_exchange_equilibrium_constant = 5e5, .hpo4_exchange_equilibrium_constant = 5e3, .water_activity_product_mol2_per_m6 = 1e-8, .h2po4_dissociation_constant = 6.2e-5, .maximum_exchange_mol_per_megagram_step = 0.1, .substrate_limit_fraction = 0.2 };
    try seedProfilePhosphateSurfaceSites(&state, 0, 3, 2, surface, 6.2e-5);
    const zone = state.non_band_phosphate[0];
    const sites = zone.protonated_site_mol_per_megagram + zone.hydroxyl_site_mol_per_megagram + zone.deprotonated_site_mol_per_megagram + zone.adsorbed_h2po4_mol_p_per_megagram + zone.adsorbed_hpo4_mol_p_per_megagram;
    try std.testing.expectApproxEqAbs(@as(f64, 2), sites, 1e-12);
    const fractions = charge_classification.ZoneFractions{ .ammonium_non_band = 0.75, .ammonium_band = 0.25, .nitrate_non_band = 0.6, .nitrate_band = 0.4, .phosphate_non_band = 0.8, .phosphate_band = 0.2 };
    try seedProfileCationExchange(&state, 0, 100, .{ .calcium_ammonium = 1, .calcium_hydrogen = 1, .calcium_aluminum_and_iron = 1, .calcium_magnesium = 1, .calcium_sodium = 1, .calcium_potassium = 1 }, fractions);
    const exchange = state.cation_exchange_mol_per_megagram[0];
    const charge = exchange.ammonium_non_band * fractions.ammonium_non_band + exchange.ammonium_band * fractions.ammonium_band + exchange.hydrogen + 3 * (exchange.aluminum + exchange.iron) + 2 * (exchange.calcium + exchange.magnesium) + exchange.sodium + exchange.potassium;
    try std.testing.expectApproxEqAbs(@as(f64, 100), charge, 1e-10);
}

test "STARTE carboxyl occupancy seed reproduces source line 403" {
    var state = try ChemistryState.init(std.testing.allocator, 2);
    defer state.deinit();
    state.aqueous[1].hydrogen = 2.5e-3;
    try seedProfileCarboxylOccupancy(&state, 1, 5, 1.0e-2);
    // XHC1 = XCOOH * AMIN1(1, CHY1/DPCOH) = 5 * 0.25.
    try std.testing.expectEqual(
        @as(f64, 1.25),
        state.carboxyl_bound_hydrogen_mol_per_megagram[1],
    );
    // Unseeded layers are untouched, so the seed owns exactly one layer.
    try std.testing.expectEqual(
        @as(f64, 0),
        state.carboxyl_bound_hydrogen_mol_per_megagram[0],
    );
}

test "STARTE carboxyl occupancy saturates at all sites and never exceeds them" {
    var state = try ChemistryState.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0].hydrogen = 1;
    try seedProfileCarboxylOccupancy(&state, 0, 4, 1.0e-2);
    try std.testing.expectEqual(
        @as(f64, 4),
        state.carboxyl_bound_hydrogen_mol_per_megagram[0],
    );
}

test "zero carboxyl occupancy is an absorbing state that the seed escapes" {
    const carboxyl = @import("../solute/carboxyl_exchange.zig");
    const parameters: carboxyl.Parameters = .{
        .dissociation_constant_mol_per_m3 = 1.0e-2,
        .maximum_exchange_mol_per_m3_per_iteration = 1.0e-2,
        .substrate_limit_fraction_per_iteration = 0.2,
    };
    // An acidic organic horizon: many sites, low pH, so the buffer must be
    // active. With the occupied pool left at the `State.init` zero, the
    // substrate limit `FIONX/BKVLW*XHC1` is zero and the reaction extent is
    // clamped to exactly zero no matter how many iterations are spent. That is
    // the `carboxyl=0e0` signature reported for four wave-1 examples.
    const unseeded = try carboxyl.calculateChangeMolPerMg(.{
        .total_carboxyl_sites_mol_per_megagram = 5,
        .hydrogen_occupied_sites_mol_per_megagram = 0,
        .hydrogen_activity_mol_per_m3 = 1.0e-2,
        .soil_mass_per_water_volume_megagrams_per_m3 = 2,
    }, parameters);
    try std.testing.expectEqual(@as(f64, 0), unseeded);

    var state = try ChemistryState.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0].hydrogen = 1.0e-2;
    try seedProfileCarboxylOccupancy(&state, 0, 5, 1.0e-2);
    const seeded_occupancy = state.carboxyl_bound_hydrogen_mol_per_megagram[0];
    try std.testing.expect(seeded_occupancy > 0);
    const seeded = try carboxyl.calculateChangeMolPerMg(.{
        .total_carboxyl_sites_mol_per_megagram = 5,
        .hydrogen_occupied_sites_mol_per_megagram = seeded_occupancy,
        .hydrogen_activity_mol_per_m3 = 1.0e-2,
        .soil_mass_per_water_volume_megagrams_per_m3 = 2,
    }, parameters);
    // A nonzero extent is a descent direction for the proton balance, which the
    // zero-occupancy state provably cannot supply.
    try std.testing.expect(@abs(seeded) > 0);
}

test "carboxyl occupancy seed rejects invalid inputs" {
    var state = try ChemistryState.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0].hydrogen = 1.0e-2;
    try std.testing.expectError(
        error.InvalidCarboxylExchangeInput,
        seedProfileCarboxylOccupancy(&state, 0, 5, 0),
    );
    try std.testing.expectError(
        error.ChemistryCellIndexOutOfBounds,
        seedProfileCarboxylOccupancy(&state, 7, 5, 1.0e-2),
    );
}

test "SOLUTE-036: STARTE and SOLUTE carboxyl substrate limits differ by orders of magnitude in an acidic organic horizon" {
    const starte = @import("carboxyl_proton_exchange.zig");

    // Conditions representative of the Cool Temperate Oak MA forest floor, the
    // regime where four wave-1 examples fail: surface pH 5, so
    // AHY1 ~ 1e-2 mol m-3, a thick organic horizon giving many carboxyl sites,
    // and the runtime `cation_kinetics,0.2,0.0025` limits from that example's
    // `soil_chemistry_reaction_parameters.txt`.
    const hydrogen_activity_mol_per_m3: f64 = 1.0e-2;
    const total_sites_mol_per_megagram: f64 = 5;
    const occupied_mol_per_megagram: f64 = 5; // saturated at this pH: min(1, AHY1/DPCOH)=1
    const soil_mass_per_water_volume_megagrams_per_m3: f64 = 2;
    const substrate_fraction: f64 = 0.2;

    // `solute.f:1418`  XMIN = FIONX/BKVLW*XHC1        -- ignores H+ activity.
    const solute_substrate_limit = substrate_fraction /
        soil_mass_per_water_volume_megagrams_per_m3 * occupied_mol_per_megagram;

    // `starte.f:813`   XMIN = FION*AMIN1(XHC1,AHY1)   -- throttled by H+ activity.
    const starte_substrate_limit = substrate_fraction *
        @min(occupied_mol_per_megagram, hydrogen_activity_mol_per_m3);

    // The STARTE limit is far smaller here, because AMIN1 selects AHY1 when the
    // horizon is acidic and site-rich. This is the quantitative basis of
    // SOLUTE-042: production ran the SOLUTE form on the initialization path, so
    // it permitted a carboxyl step 250x larger (0.5 / 2.0e-3, not the ~50x this
    // comment previously claimed) than the source's own initial equilibrium
    // allows, in exactly the regime where the blocked examples fail.
    //
    // The ID in this test's NAME is stale and is deliberately left alone: it is
    // cited by commit subjects 1c97ba0, 692b3ce and 8cf3018, which cannot be
    // rewritten. Register SOLUTE-036 is an unrelated bicarbonate defect from the
    // baseline snapshot; this defect is SOLUTE-042. Both entries carry the
    // mapping.
    try std.testing.expectEqual(@as(f64, 0.5), solute_substrate_limit);
    try std.testing.expectEqual(@as(f64, 2.0e-3), starte_substrate_limit);
    try std.testing.expect(solute_substrate_limit > 100 * starte_substrate_limit);

    // The STARTE kernel is an exact translation and is reachable, so the
    // formulation is available; only the call site is missing.
    var state: starte.State = .{
        .total_carboxyl_sites_mol_per_megagram = total_sites_mol_per_megagram,
        .protonated_carboxyl_sites_mol_per_megagram = occupied_mol_per_megagram,
    };
    const result = try starte.step(.soil, hydrogen_activity_mol_per_m3, .{
        .substrate_limit_fraction = substrate_fraction,
        .minimum_unprotonated_sites_mol_per_megagram = 1.0e-48,
        .carboxyl_dissociation_mol_per_m3 = 1.0e-2,
        .maximum_exchange_mol_per_megagram_iteration = 2.5e-3,
    }, &state);
    try std.testing.expectEqual(
        starte_substrate_limit,
        result.diagnostics.?.substrate_limit_mol_per_megagram_iteration,
    );
}
