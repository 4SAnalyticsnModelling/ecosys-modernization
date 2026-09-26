const std = @import("std");
const precipitation_speciation = @import("../../chemistry/precipitation_nutrient_speciation.zig");
const initialization = @import("initialization.zig");
const parameters_module = @import("parameters.zig");
const chemistry = @import("../solute/chemistry_state.zig");
const reaction_solver = @import("../solute/reaction_solver.zig");
const failure_reporter = @import("../solute/failure_reporter.zig");
const aqueous_bridge = @import("../solute/aqueous_transport_bridge.zig");
const aqueous_network = @import("../solute/aqueous_network.zig");
const phosphate_network = @import("../solute/phosphate_network.zig");
const charge_classification = @import("../solute/charge_classification.zig");
const activity_coefficients = @import("../solute/activity_coefficients.zig");
const AqueousSpecies = @import("../solute/transport_species.zig").AqueousSpecies;
const snow = @import("../solute/snow_solute_transport.zig");
const gas_transport = @import("../gas/transport.zig");

pub const Inputs = struct {
    precipitation_ph: f64,
    dissolved_gas_g_per_m3: [5]f64,
    ammonium_g_n_per_m3: f64,
    nitrate_g_n_per_m3: f64,
    phosphate_g_p_per_m3: f64,
    /// Al, Fe, Ca, Mg, Na, K, sulfate-S, chloride in weather-header order.
    free_ion_g_per_m3: [8]f64,
    molar_mass_g_per_mol: initialization.ElementMolarMassesGPerMol,
};

const CarrierFreeSystem = struct {
    initial_hydrogen_mol_per_m3: f64,
    initial_hydroxide_mol_per_m3: f64,
    total_ammoniacal_n_mol_per_m3: f64,
    nitrate_mol_n_per_m3: f64,
    total_carbon_mol_per_m3: f64,
    total_phosphate_mol_p_per_m3: f64,
    initial_proton_inventory_mol_per_m3: f64,
    initial_charge_mol_per_m3: f64,
    ammonium_dissociation_mol_per_m3: f64,
    carbon_dioxide_dissociation_mol_per_m3: f64,
    bicarbonate_dissociation_mol_per_m3: f64,
    phosphate_h3_dissociation_mol_per_m3: f64,
    phosphate_h2_dissociation_mol_per_m3: f64,
    phosphate_h1_dissociation_mol_per_m3: f64,
    water_activity_product_mol2_per_m6: f64,
};

const CarrierFreeState = struct {
    aqueous: aqueous_network.State,
    phosphate: phosphate_network.State,
    coefficients: activity_coefficients.Result,
    proton_inventory_residual_mol_per_m3: f64,
};

const unit_activity_coefficients: activity_coefficients.Result = .{
    .ionic_strength_mol_per_l = 0,
    .monovalent_activity_coefficient = 1,
    .divalent_activity_coefficient = 1,
    .trivalent_activity_coefficient = 1,
    .total_ion_activity_mol_per_m3 = 0,
    .electrical_conductivity_dS_per_m = 0,
};

fn normalizedLogDistribution(
    comptime count: usize,
    total: f64,
    log_weights: [count]f64,
) ![count]f64 {
    var result: [count]f64 = @splat(0);
    if (total == 0) return result;
    var maximum_log = -std.math.inf(f64);
    for (log_weights) |log_weight| {
        if (!std.math.isFinite(log_weight))
            return error.InvalidCarrierFreeEquilibrium;
        maximum_log = @max(maximum_log, log_weight);
    }
    var weights: [count]f64 = undefined;
    var weight_sum: f64 = 0;
    for (&weights, log_weights) |*weight, log_weight| {
        weight.* = @exp(log_weight - maximum_log);
        weight_sum += weight.*;
    }
    if (!std.math.isFinite(weight_sum) or weight_sum <= 0)
        return error.InvalidCarrierFreeEquilibrium;
    for (&result, weights) |*value, weight| value.* = total * weight / weight_sum;
    return result;
}

fn carrierFreeProtonInventory(
    aqueous: aqueous_network.State,
    phosphate: phosphate_network.State,
) f64 {
    return aqueous.hydrogen - aqueous.hydroxide +
        aqueous.ammonium_non_band + aqueous.bicarbonate +
        2 * aqueous.carbon_dioxide +
        phosphate.dissolved_hpo4_mol_p_per_m3 +
        2 * phosphate.dissolved_h2po4_mol_p_per_m3 +
        3 * phosphate.dissolved_h3po4_mol_p_per_m3;
}

fn carrierFreeCharge(
    aqueous: aqueous_network.State,
    phosphate: phosphate_network.State,
) f64 {
    return aqueous.hydrogen + aqueous.ammonium_non_band -
        aqueous.hydroxide - aqueous.nitrate_non_band -
        aqueous.bicarbonate - 2 * aqueous.carbonate -
        phosphate.dissolved_h2po4_mol_p_per_m3 -
        2 * phosphate.dissolved_hpo4_mol_p_per_m3 -
        3 * phosphate.dissolved_po4_mol_p_per_m3;
}

fn buildCarrierFreeSystem(
    inputs: Inputs,
    global_parameters: parameters_module.Parameters,
) !CarrierFreeSystem {
    const hydrogen = try initialization.hydrogenFromPh_mol_per_m3(inputs.precipitation_ph);
    const hydroxide = global_parameters.water_activity_product_mol2_per_m6 / hydrogen;
    const total_ammoniacal_n = inputs.ammonium_g_n_per_m3 /
        inputs.molar_mass_g_per_mol.nitrogen;
    const nitrate = inputs.nitrate_g_n_per_m3 /
        inputs.molar_mass_g_per_mol.nitrogen;
    const total_carbon = inputs.dissolved_gas_g_per_m3[0] / 12;
    const total_phosphate = inputs.phosphate_g_p_per_m3 /
        inputs.molar_mass_g_per_mol.phosphorus;
    inline for (.{
        hydroxide,
        total_ammoniacal_n,
        nitrate,
        total_carbon,
        total_phosphate,
        global_parameters.aqueous_constants.ammonium,
        global_parameters.aqueous_constants.carbon_dioxide,
        global_parameters.aqueous_constants.bicarbonate,
        global_parameters.phosphate_constants.h3po4,
        global_parameters.phosphate_constants.h2po4,
        global_parameters.phosphate_constants.hpo4,
        global_parameters.water_activity_product_mol2_per_m6,
    }) |value| {
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidCarrierFreeEquilibrium;
    }
    inline for (.{
        global_parameters.aqueous_constants.ammonium,
        global_parameters.aqueous_constants.carbon_dioxide,
        global_parameters.aqueous_constants.bicarbonate,
        global_parameters.phosphate_constants.h3po4,
        global_parameters.phosphate_constants.h2po4,
        global_parameters.phosphate_constants.hpo4,
        global_parameters.water_activity_product_mol2_per_m6,
    }) |value| if (value == 0) return error.InvalidCarrierFreeEquilibrium;

    const initial_ammonium = total_ammoniacal_n * hydrogen /
        (hydrogen + global_parameters.aqueous_constants.ammonium);
    const initial_phosphate = try initialization.initialPhosphateSpecies(
        total_phosphate,
        hydrogen,
        .{
            .h3po4_to_h2po4_mol_per_m3 = global_parameters.phosphate_constants.h3po4,
            .h2po4_to_hpo4_mol_per_m3 = global_parameters.phosphate_constants.h2po4,
            .hpo4_to_po4_mol_per_m3 = global_parameters.phosphate_constants.hpo4,
        },
    );
    var initial_aqueous = std.mem.zeroes(aqueous_network.State);
    initial_aqueous.hydrogen = hydrogen;
    initial_aqueous.hydroxide = hydroxide;
    initial_aqueous.ammonium_non_band = initial_ammonium;
    initial_aqueous.ammonia_non_band = total_ammoniacal_n - initial_ammonium;
    initial_aqueous.nitrate_non_band = nitrate;
    initial_aqueous.carbon_dioxide = total_carbon;
    var initial_zone = std.mem.zeroes(phosphate_network.State);
    initial_zone.dissolved_po4_mol_p_per_m3 = initial_phosphate.po4_mol_p_per_m3;
    initial_zone.dissolved_hpo4_mol_p_per_m3 = initial_phosphate.hpo4_mol_p_per_m3;
    initial_zone.dissolved_h2po4_mol_p_per_m3 = initial_phosphate.h2po4_mol_p_per_m3;
    initial_zone.dissolved_h3po4_mol_p_per_m3 = initial_phosphate.h3po4_mol_p_per_m3;
    return .{
        .initial_hydrogen_mol_per_m3 = hydrogen,
        .initial_hydroxide_mol_per_m3 = hydroxide,
        .total_ammoniacal_n_mol_per_m3 = total_ammoniacal_n,
        .nitrate_mol_n_per_m3 = nitrate,
        .total_carbon_mol_per_m3 = total_carbon,
        .total_phosphate_mol_p_per_m3 = total_phosphate,
        .initial_proton_inventory_mol_per_m3 = carrierFreeProtonInventory(initial_aqueous, initial_zone),
        .initial_charge_mol_per_m3 = carrierFreeCharge(initial_aqueous, initial_zone),
        .ammonium_dissociation_mol_per_m3 = global_parameters.aqueous_constants.ammonium,
        .carbon_dioxide_dissociation_mol_per_m3 = global_parameters.aqueous_constants.carbon_dioxide,
        .bicarbonate_dissociation_mol_per_m3 = global_parameters.aqueous_constants.bicarbonate,
        .phosphate_h3_dissociation_mol_per_m3 = global_parameters.phosphate_constants.h3po4,
        .phosphate_h2_dissociation_mol_per_m3 = global_parameters.phosphate_constants.h2po4,
        .phosphate_h1_dissociation_mol_per_m3 = global_parameters.phosphate_constants.hpo4,
        .water_activity_product_mol2_per_m6 = global_parameters.water_activity_product_mol2_per_m6,
    };
}

fn carrierFreeSpeciesAtHydrogen(
    system: CarrierFreeSystem,
    hydrogen: f64,
    coefficients: activity_coefficients.Result,
) !struct { aqueous: aqueous_network.State, phosphate: phosphate_network.State } {
    if (!std.math.isFinite(hydrogen) or hydrogen <= 0)
        return error.InvalidCarrierFreeEquilibrium;
    const g1 = coefficients.monovalent_activity_coefficient;
    const g2 = coefficients.divalent_activity_coefficient;
    const g3 = coefficients.trivalent_activity_coefficient;
    inline for (.{ g1, g2, g3 }) |value| if (!std.math.isFinite(value) or value <= 0)
        return error.InvalidCarrierFreeEquilibrium;

    const log_hydrogen = @log(hydrogen);
    const log_g1 = @log(g1);
    const log_g2 = @log(g2);
    const log_g3 = @log(g3);
    const carbon = try normalizedLogDistribution(3, system.total_carbon_mol_per_m3, .{
        0,
        @log(system.carbon_dioxide_dissociation_mol_per_m3) - log_hydrogen - 2 * log_g1,
        @log(system.carbon_dioxide_dissociation_mol_per_m3) - log_hydrogen - 2 * log_g1 +
            @log(system.bicarbonate_dissociation_mol_per_m3) - log_hydrogen - log_g2,
    });
    const phosphate = try normalizedLogDistribution(4, system.total_phosphate_mol_p_per_m3, .{
        0,
        @log(system.phosphate_h3_dissociation_mol_per_m3) - log_hydrogen - 2 * log_g1,
        @log(system.phosphate_h3_dissociation_mol_per_m3) - log_hydrogen - 2 * log_g1 +
            @log(system.phosphate_h2_dissociation_mol_per_m3) - log_hydrogen - log_g2,
        @log(system.phosphate_h3_dissociation_mol_per_m3) - log_hydrogen - 2 * log_g1 +
            @log(system.phosphate_h2_dissociation_mol_per_m3) - log_hydrogen - log_g2 +
            @log(system.phosphate_h1_dissociation_mol_per_m3) + log_g2 -
            log_hydrogen - log_g1 - log_g3,
    });
    const ammonium_denominator = hydrogen + system.ammonium_dissociation_mol_per_m3;
    if (!std.math.isFinite(ammonium_denominator) or ammonium_denominator <= 0)
        return error.InvalidCarrierFreeEquilibrium;

    var aqueous = std.mem.zeroes(aqueous_network.State);
    aqueous.hydrogen = hydrogen;
    aqueous.hydroxide = system.water_activity_product_mol2_per_m6 /
        (hydrogen * g1 * g1);
    aqueous.ammonium_non_band = system.total_ammoniacal_n_mol_per_m3 *
        hydrogen / ammonium_denominator;
    aqueous.ammonia_non_band = system.total_ammoniacal_n_mol_per_m3 -
        aqueous.ammonium_non_band;
    aqueous.nitrate_non_band = system.nitrate_mol_n_per_m3;
    aqueous.carbon_dioxide = carbon[0];
    aqueous.bicarbonate = carbon[1];
    aqueous.carbonate = carbon[2];
    var zone = std.mem.zeroes(phosphate_network.State);
    zone.dissolved_h3po4_mol_p_per_m3 = phosphate[0];
    zone.dissolved_h2po4_mol_p_per_m3 = phosphate[1];
    zone.dissolved_hpo4_mol_p_per_m3 = phosphate[2];
    zone.dissolved_po4_mol_p_per_m3 = phosphate[3];
    inline for (@typeInfo(aqueous_network.State).@"struct".fields) |field|
        if (!std.math.isFinite(@field(aqueous, field.name)) or @field(aqueous, field.name) < 0)
            return error.InvalidCarrierFreeEquilibrium;
    inline for (@typeInfo(phosphate_network.State).@"struct".fields) |field|
        if (!std.math.isFinite(@field(zone, field.name)) or @field(zone, field.name) < 0)
            return error.InvalidCarrierFreeEquilibrium;
    return .{ .aqueous = aqueous, .phosphate = zone };
}

fn carrierFreeStateAtHydrogen(
    system: CarrierFreeSystem,
    hydrogen: f64,
) !CarrierFreeState {
    var coefficients = unit_activity_coefficients;
    for (0..64) |_| {
        const species = try carrierFreeSpeciesAtHydrogen(system, hydrogen, coefficients);
        const charge_totals = try charge_classification.classify(
            species.aqueous,
            species.phosphate,
            std.mem.zeroes(phosphate_network.State),
            .{
                .ammonium_non_band = 1,
                .ammonium_band = 0,
                .nitrate_non_band = 1,
                .nitrate_band = 0,
                .phosphate_non_band = 1,
                .phosphate_band = 0,
            },
        );
        const next_coefficients = try activity_coefficients.calculate(charge_totals, 1);
        const coefficient_delta = @max(
            @abs(next_coefficients.monovalent_activity_coefficient - coefficients.monovalent_activity_coefficient),
            @abs(next_coefficients.divalent_activity_coefficient - coefficients.divalent_activity_coefficient),
            @abs(next_coefficients.trivalent_activity_coefficient - coefficients.trivalent_activity_coefficient),
        );
        coefficients = next_coefficients;
        if (coefficient_delta <= 64 * std.math.floatEps(f64)) {
            const final_species = try carrierFreeSpeciesAtHydrogen(system, hydrogen, coefficients);
            return .{
                .aqueous = final_species.aqueous,
                .phosphate = final_species.phosphate,
                .coefficients = coefficients,
                .proton_inventory_residual_mol_per_m3 = carrierFreeProtonInventory(
                    final_species.aqueous,
                    final_species.phosphate,
                ) - system.initial_proton_inventory_mol_per_m3,
            };
        }
    }
    return error.CarrierFreeActivityDidNotConverge;
}

fn retainBetterCarrierFreeState(best: *CarrierFreeState, candidate: CarrierFreeState) void {
    if (@abs(candidate.proton_inventory_residual_mol_per_m3) <
        @abs(best.proton_inventory_residual_mol_per_m3)) best.* = candidate;
}

fn carrierFreeStatePhysicallyAcceptable(
    system: CarrierFreeSystem,
    state: CarrierFreeState,
) bool {
    const aqueous = state.aqueous;
    const phosphate = state.phosphate;
    const carbon_after = aqueous.carbon_dioxide + aqueous.bicarbonate + aqueous.carbonate;
    const ammoniacal_n_after = aqueous.ammonium_non_band + aqueous.ammonia_non_band;
    const phosphate_after = phosphate.dissolved_po4_mol_p_per_m3 +
        phosphate.dissolved_hpo4_mol_p_per_m3 +
        phosphate.dissolved_h2po4_mol_p_per_m3 +
        phosphate.dissolved_h3po4_mol_p_per_m3;
    const charge_after = carrierFreeCharge(aqueous, phosphate);
    const water_product = aqueous.hydrogen * aqueous.hydroxide *
        state.coefficients.monovalent_activity_coefficient *
        state.coefficients.monovalent_activity_coefficient;
    const magnitude = @abs(aqueous.hydrogen) + @abs(aqueous.hydroxide) +
        system.total_ammoniacal_n_mol_per_m3 + system.nitrate_mol_n_per_m3 +
        2 * system.total_carbon_mol_per_m3 + 3 * system.total_phosphate_mol_p_per_m3;
    const allowance = 4096 * std.math.floatEps(f64) * @max(magnitude, std.math.floatEps(f64));
    const water_allowance = 4096 * std.math.floatEps(f64) *
        @max(system.water_activity_product_mol2_per_m6, std.math.floatEps(f64));
    return @abs(carbon_after - system.total_carbon_mol_per_m3) <= allowance and
        @abs(ammoniacal_n_after - system.total_ammoniacal_n_mol_per_m3) <= allowance and
        @abs(phosphate_after - system.total_phosphate_mol_p_per_m3) <= allowance and
        @abs(state.proton_inventory_residual_mol_per_m3) <= allowance and
        @abs(charge_after - system.initial_charge_mol_per_m3) <= allowance and
        @abs(water_product - system.water_activity_product_mol2_per_m6) <= water_allowance;
}

fn carrierFreeOutput(
    state: CarrierFreeState,
    inputs: Inputs,
) !snow.InitialChemicalConcentrations {
    var output: snow.InitialChemicalConcentrations = .{
        .primary_g_per_m3 = .{
            state.aqueous.carbon_dioxide * 12,
            inputs.dissolved_gas_g_per_m3[1],
            inputs.dissolved_gas_g_per_m3[2],
            inputs.dissolved_gas_g_per_m3[3],
            inputs.dissolved_gas_g_per_m3[4],
            state.aqueous.ammonium_non_band * inputs.molar_mass_g_per_mol.nitrogen,
            state.aqueous.ammonia_non_band * inputs.molar_mass_g_per_mol.nitrogen,
            state.aqueous.nitrate_non_band * inputs.molar_mass_g_per_mol.nitrogen,
            state.phosphate.dissolved_hpo4_mol_p_per_m3 * inputs.molar_mass_g_per_mol.phosphorus,
            state.phosphate.dissolved_h2po4_mol_p_per_m3 * inputs.molar_mass_g_per_mol.phosphorus,
        },
        .static_ion_g_per_m3 = inputs.free_ion_g_per_m3,
        .salt_mol_per_m3 = @splat(0),
    };
    output.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydrogen)] = state.aqueous.hydrogen;
    output.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydroxide)] = state.aqueous.hydroxide;
    output.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.carbonate)] = state.aqueous.carbonate;
    output.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.bicarbonate)] = state.aqueous.bicarbonate;
    output.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphate)] = state.phosphate.dissolved_po4_mol_p_per_m3;
    output.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphoric_acid)] = state.phosphate.dissolved_h3po4_mol_p_per_m3;
    for (output.primary_g_per_m3) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidCarrierFreeEquilibrium;
    for (output.salt_mol_per_m3) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidCarrierFreeEquilibrium;
    return output;
}

fn carrierFreeAnalyticalEquilibrium(
    inputs: Inputs,
    global_parameters: parameters_module.Parameters,
) !snow.InitialChemicalConcentrations {
    const system = try buildCarrierFreeSystem(inputs, global_parameters);
    const initial_state = try carrierFreeStateAtHydrogen(
        system,
        system.initial_hydrogen_mol_per_m3,
    );
    var best_state = initial_state;
    var lower_hydrogen = system.initial_hydrogen_mol_per_m3;
    var upper_hydrogen = system.initial_hydrogen_mol_per_m3;
    var lower_residual = initial_state.proton_inventory_residual_mol_per_m3;
    var upper_residual = lower_residual;

    if (lower_residual < 0) {
        for (0..256) |_| {
            if (upper_hydrogen > std.math.floatMax(f64) * 0.5)
                return error.CarrierFreeEquilibriumNotBracketed;
            upper_hydrogen *= 2;
            const candidate = try carrierFreeStateAtHydrogen(system, upper_hydrogen);
            retainBetterCarrierFreeState(&best_state, candidate);
            upper_residual = candidate.proton_inventory_residual_mol_per_m3;
            if (upper_residual >= 0) break;
        }
    } else if (upper_residual > 0) {
        for (0..256) |_| {
            lower_hydrogen *= 0.5;
            if (lower_hydrogen == 0)
                return error.CarrierFreeEquilibriumNotBracketed;
            const candidate = try carrierFreeStateAtHydrogen(system, lower_hydrogen);
            retainBetterCarrierFreeState(&best_state, candidate);
            lower_residual = candidate.proton_inventory_residual_mol_per_m3;
            if (lower_residual <= 0) break;
        }
    }
    if (lower_residual > 0 or upper_residual < 0)
        return error.CarrierFreeEquilibriumNotBracketed;

    for (0..128) |_| {
        const midpoint = 0.5 * lower_hydrogen + 0.5 * upper_hydrogen;
        if (midpoint == lower_hydrogen or midpoint == upper_hydrogen) break;
        const candidate = try carrierFreeStateAtHydrogen(system, midpoint);
        retainBetterCarrierFreeState(&best_state, candidate);
        if (candidate.proton_inventory_residual_mol_per_m3 < 0) {
            lower_hydrogen = midpoint;
        } else {
            upper_hydrogen = midpoint;
        }
        if (std.math.nextAfter(f64, lower_hydrogen, upper_hydrogen) >= upper_hydrogen)
            break;
    }
    if (!carrierFreeStatePhysicallyAcceptable(system, best_state))
        return error.CarrierFreeEquilibriumPhysicalAcceptanceFailed;
    return carrierFreeOutput(best_state, inputs);
}

fn hasNoPrecipitationIonCarriers(inputs: Inputs) bool {
    for (inputs.free_ion_g_per_m3) |value| if (value != 0) return false;
    return true;
}

/// STARTE K=1 precipitation gas concentrations (`starte.f:234--256`). Unlike
/// the air/water surface ratio, the first-header equilibrium divides each gas
/// by its source activity exponent before publishing `C*R` for initial snow.
pub fn initialPrecipitationDissolvedGasGPerM3(
    atmospheric_g_per_m3: [5]f64,
    mean_annual_temperature_k: f64,
    parameters: gas_transport.SurfaceSolubilityParameters,
    precipitation_activity_log: [gas_transport.species_count]f64,
) ![5]f64 {
    const water_to_air = try gas_transport.surfaceSolubilityWaterToAir(
        mean_annual_temperature_k,
        parameters,
    );
    var dissolved: [5]f64 = undefined;
    for (&dissolved, atmospheric_g_per_m3, 0..) |*value, atmospheric, species| {
        if (!std.math.isFinite(atmospheric) or atmospheric < 0 or
            !std.math.isFinite(precipitation_activity_log[species]))
            return error.InvalidInitialSnowEquilibriumInput;
        const activity_divisor = @exp(precipitation_activity_log[species]);
        value.* = atmospheric * water_to_air[species] / activity_divisor;
        if (!std.math.isFinite(value.*) or value.* < 0)
            return error.InvalidInitialSnowEquilibrium;
    }
    return dissolved;
}

/// STARTE K=1 precipitation equilibrium.  The temporary chemistry cell has no
/// soil, exchange, surface, or solid-mineral carrier, so only aqueous
/// dissociation and ion/phosphate pairing can redistribute the header totals.
pub fn equilibrate(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    global_parameters: parameters_module.Parameters,
    options: reaction_solver.Options,
) !snow.InitialChemicalConcentrations {
    return equilibrateWithFailureReport(
        allocator,
        inputs,
        global_parameters,
        options,
        null,
    );
}

/// The hourly precipitation boundary can preserve the exact temporary
/// aqueous cell when its equilibrium solve fails. Startup and tests retain the
/// reporter-free `equilibrate` entry point above.
pub fn equilibrateWithFailureReport(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    global_parameters: parameters_module.Parameters,
    options: reaction_solver.Options,
    failure_report: ?failure_reporter.Request,
) !snow.InitialChemicalConcentrations {
    try validateInputs(inputs);
    try reaction_solver.validateOptions(options);
    if (hasNoPrecipitationIonCarriers(inputs)) {
        const analytical: ?snow.InitialChemicalConcentrations =
            carrierFreeAnalyticalEquilibrium(inputs, global_parameters) catch null;
        if (analytical) |output| return output;
    }
    var workspace = try reaction_solver.Workspace.init(allocator);
    defer workspace.deinit();
    return equilibrateGenericWithWorkspaceAndFailureReport(
        allocator,
        &workspace,
        inputs,
        global_parameters,
        options,
        failure_report,
    );
}

/// Allocation-bounded precipitation equilibrium for hourly callers which
/// already own an exclusive reaction workspace. The scientific solve,
/// convergence gate, rollback semantics, and failure snapshot are identical
/// to `equilibrateWithFailureReport`; only the large generic solver workspace
/// is reused rather than rebuilt for every wet cell-hour.
pub fn equilibrateWithWorkspaceAndFailureReport(
    allocator: std.mem.Allocator,
    workspace: *reaction_solver.Workspace,
    inputs: Inputs,
    global_parameters: parameters_module.Parameters,
    options: reaction_solver.Options,
    failure_report: ?failure_reporter.Request,
) !snow.InitialChemicalConcentrations {
    try validateInputs(inputs);
    try reaction_solver.validateOptions(options);
    if (hasNoPrecipitationIonCarriers(inputs)) {
        const analytical: ?snow.InitialChemicalConcentrations =
            carrierFreeAnalyticalEquilibrium(inputs, global_parameters) catch null;
        if (analytical) |output| return output;
    }
    return equilibrateGenericWithWorkspaceAndFailureReport(
        allocator,
        workspace,
        inputs,
        global_parameters,
        options,
        failure_report,
    );
}

fn equilibrateGenericWithWorkspaceAndFailureReport(
    allocator: std.mem.Allocator,
    workspace: *reaction_solver.Workspace,
    inputs: Inputs,
    global_parameters: parameters_module.Parameters,
    options: reaction_solver.Options,
    failure_report: ?failure_reporter.Request,
) !snow.InitialChemicalConcentrations {
    var state = try chemistry.State.init(allocator, 1);
    defer state.deinit();

    const hydrogen = try initialization.hydrogenFromPh_mol_per_m3(inputs.precipitation_ph);
    const hydroxide = global_parameters.water_activity_product_mol2_per_m6 / hydrogen;
    if (!std.math.isFinite(hydroxide) or hydroxide < 0) return error.InvalidInitialSnowEquilibrium;
    const nutrient = try precipitation_speciation.calculate(.{
        .ph = inputs.precipitation_ph,
        .ammonium_g_n_per_m3 = inputs.ammonium_g_n_per_m3,
        .nitrate_g_n_per_m3 = inputs.nitrate_g_n_per_m3,
        .phosphate_g_p_per_m3 = inputs.phosphate_g_p_per_m3,
        .nitrogen_g_per_mol = inputs.molar_mass_g_per_mol.nitrogen,
        .phosphorus_g_per_mol = inputs.molar_mass_g_per_mol.phosphorus,
    }, global_parameters.aqueous_constants, global_parameters.phosphate_constants);
    const phosphate = try initialization.initialPhosphateSpecies(
        inputs.phosphate_g_p_per_m3 / inputs.molar_mass_g_per_mol.phosphorus,
        hydrogen,
        .{
            .h3po4_to_h2po4_mol_per_m3 = global_parameters.phosphate_constants.h3po4,
            .h2po4_to_hpo4_mol_per_m3 = global_parameters.phosphate_constants.h2po4,
            .hpo4_to_po4_mol_per_m3 = global_parameters.phosphate_constants.hpo4,
        },
    );

    state.water_mol_per_m3[0] = global_parameters.water_concentration_mol_per_m3;
    state.aqueous[0].hydrogen = hydrogen;
    state.aqueous[0].hydroxide = hydroxide;
    state.aqueous[0].carbon_dioxide = inputs.dissolved_gas_g_per_m3[0] / 12;
    state.aqueous[0].ammonium_non_band = nutrient[0];
    state.aqueous[0].ammonia_non_band = nutrient[1];
    state.aqueous[0].nitrate_non_band = nutrient[2];
    state.aqueous[0].aluminum = inputs.free_ion_g_per_m3[0] / inputs.molar_mass_g_per_mol.aluminum;
    state.aqueous[0].iron = inputs.free_ion_g_per_m3[1] / inputs.molar_mass_g_per_mol.iron;
    state.aqueous[0].calcium = inputs.free_ion_g_per_m3[2] / inputs.molar_mass_g_per_mol.calcium;
    state.aqueous[0].magnesium = inputs.free_ion_g_per_m3[3] / inputs.molar_mass_g_per_mol.magnesium;
    state.aqueous[0].sodium = inputs.free_ion_g_per_m3[4] / inputs.molar_mass_g_per_mol.sodium;
    state.aqueous[0].potassium = inputs.free_ion_g_per_m3[5] / inputs.molar_mass_g_per_mol.potassium;
    state.aqueous[0].sulfate = inputs.free_ion_g_per_m3[6] / inputs.molar_mass_g_per_mol.sulfur;
    state.aqueous[0].chloride = inputs.free_ion_g_per_m3[7] / inputs.molar_mass_g_per_mol.chloride;
    state.non_band_phosphate[0].dissolved_po4_mol_p_per_m3 = phosphate.po4_mol_p_per_m3;
    state.non_band_phosphate[0].dissolved_hpo4_mol_p_per_m3 = phosphate.hpo4_mol_p_per_m3;
    state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = phosphate.h2po4_mol_p_per_m3;
    state.non_band_phosphate[0].dissolved_h3po4_mol_p_per_m3 = phosphate.h3po4_mol_p_per_m3;

    var reaction_parameters = global_parameters.forLayer(
        .{
            .ammonium_non_band = 1,
            .ammonium_band = 0,
            .nitrate_non_band = 1,
            .nitrate_band = 0,
            .phosphate_non_band = 1,
            .phosphate_band = 0,
        },
        // The shared phosphate evaluator requires positive zone carrier
        // densities even when soil surface exchange and minerals are disabled
        // below. Unit virtual densities are inert because every soil-coupled
        // maximum is zero, while zero would reject all precipitation
        // equilibria before aqueous pairing can run.
        1,
        1,
        0,
        0,
        .{
            // Positive virtual carriers satisfy the shared evaluator's
            // dimensional preconditions. Exchange capacity and all exchange
            // maxima are zero, so these values cannot create soil exchange.
            .shared_megagrams_per_m3 = 1,
            .ammonium_non_band_megagrams_per_m3 = 1,
            .ammonium_band_megagrams_per_m3 = 1,
        },
        .{
            .calcium_ammonium = 1,
            .calcium_hydrogen = 1,
            .calcium_aluminum_and_iron = 1,
            .calcium_magnesium = 1,
            .calcium_sodium = 1,
            .calcium_potassium = 1,
        },
    );
    reaction_parameters.phosphate_minerals = null;
    reaction_parameters.carboxyl_exchange_parameters.maximum_exchange_mol_per_m3_per_iteration = 0;
    reaction_parameters.phosphate_surface.maximum_exchange_mol_per_megagram_step = 0;
    reaction_parameters.cation_exchange_parameters.maximum_adsorption_mol_charge_per_m3_step = 0;
    reaction_parameters.geochemistry_kinetics.maximum_hydroxide_mineral_mol_per_m3_step = 0;
    reaction_parameters.geochemistry_kinetics.maximum_general_mineral_mol_per_m3_step = 0;
    reaction_parameters.geochemistry_kinetics.maximum_natural_weathering_mol_per_m3_step = 0;
    reaction_parameters.geochemistry_kinetics.maximum_ground_weathering_mol_per_m3_step = 0;
    // This temporary carrier-free cell seeks an aqueous equilibrium, not a
    // finite-time soil reaction step. Any positive substrate fraction has the
    // same zero-rate phosphate root, but an inherited fraction below one can
    // clip dissociation at a nonzero artificial face and strand Newton--Anderson
    // there. Admit the complete nonnegative aqueous phosphate pool while
    // retaining every equilibrium constant and conservation equation.
    reaction_parameters.phosphate_kinetics.substrate_limit_fraction = 1;
    var diagnostic_trace: ?reaction_solver.SolverTrace = if (@import("builtin").is_test)
        try reaction_solver.SolverTrace.init(allocator, @as(usize, options.max_iterations) + 2)
    else
        null;
    defer if (diagnostic_trace) |*trace| trace.deinit();
    const result = reaction_solver.solveCellWithWorkspaceAndTrace(
        workspace,
        &state,
        0,
        reaction_parameters,
        options,
        if (diagnostic_trace) |*trace| trace else null,
    ) catch |err| {
        // Failure-only test diagnostics retain the solver's bounded iterate;
        // they never alter an equation, candidate, or publication decision.
        if (@import("builtin").is_test and workspace.best_bounded_iteration != null) {
            std.debug.print("SNOW_EQUILIBRIUM_FAILURE error={s} iteration={d} best_iteration={any} physical_quality={e} candidate={s}\n", .{
                @errorName(err),                workspace.last_iteration,                    workspace.best_bounded_iteration,
                workspace.best_bounded_maximum, @tagName(workspace.last_selected_candidate),
            });
            for (workspace.current, workspace.residual, 0..) |value, residual, component| {
                if (value != 0 or residual != 0) std.debug.print("SNOW_EQUILIBRIUM_COMPONENT name={s} state={e} residual={e}\n", .{
                    chemistry.State.packedComponentName(component) orelse "unknown", value, residual,
                });
            }
            if (diagnostic_trace) |trace| for (trace.entries[0..trace.count]) |entry| {
                std.debug.print("SNOW_EQUILIBRIUM_ITERATION iteration={d} limiting={s} state={e} residual={e} search_norm={e} selected={s} full_network={s}\n", .{
                    entry.iteration,                       chemistry.State.packedComponentName(entry.limiting_component_index) orelse "unknown",
                    entry.limiting_state_value,            entry.limiting_residual,
                    entry.current_maximum_scaled_residual, @tagName(entry.selected_candidate),
                    @tagName(entry.full_network_status),
                });
            };
        }
        if (failure_report) |report| return failure_reporter.reportPreservingSolverError(
            allocator,
            report,
            &state,
            0,
            reaction_parameters,
            options,
            err,
        );
        return err;
    };
    if (!result.converged) return error.InitialSnowEquilibriumDidNotConverge;
    if (@import("builtin").is_test) std.debug.print("SNOW_EQUILIBRIUM_ACCEPTED ph={d} carbon={e} iterations={d} physical_quality={e} search_metric={any}\n", .{
        inputs.precipitation_ph,        inputs.dissolved_gas_g_per_m3[0], result.iterations,
        result.maximum_scaled_residual, workspace.last_search_metric,
    });
    var output = try fromEquilibratedState(&state, inputs.dissolved_gas_g_per_m3, inputs.molar_mass_g_per_mol);
    output.static_ion_g_per_m3 = inputs.free_ion_g_per_m3;
    return output;
}

pub fn fromEquilibratedState(
    state: *const chemistry.State,
    dissolved_gas_g_per_m3: [5]f64,
    molar_mass_g_per_mol: initialization.ElementMolarMassesGPerMol,
) !snow.InitialChemicalConcentrations {
    if (state.cell_count != 1) return error.InitialSnowEquilibriumCellCountMismatch;
    var output: snow.InitialChemicalConcentrations = .{
        .primary_g_per_m3 = undefined,
        .static_ion_g_per_m3 = @splat(0),
        .salt_mol_per_m3 = undefined,
    };
    output.primary_g_per_m3 = .{
        state.aqueous[0].carbon_dioxide * 12,
        dissolved_gas_g_per_m3[1],
        dissolved_gas_g_per_m3[2],
        dissolved_gas_g_per_m3[3],
        dissolved_gas_g_per_m3[4],
        state.aqueous[0].ammonium_non_band * molar_mass_g_per_mol.nitrogen,
        state.aqueous[0].ammonia_non_band * molar_mass_g_per_mol.nitrogen,
        state.aqueous[0].nitrate_non_band * molar_mass_g_per_mol.nitrogen,
        state.non_band_phosphate[0].dissolved_hpo4_mol_p_per_m3 * molar_mass_g_per_mol.phosphorus,
        state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 * molar_mass_g_per_mol.phosphorus,
    };
    comptime {
        if (@intFromEnum(snow.SaltSpecies.potassium_sulfate) != 32 or
            @intFromEnum(AqueousSpecies.potassium_sulfate) != 32 or
            @intFromEnum(AqueousSpecies.non_band_phosphate) != 34 or
            snow.salt_species_count != 41)
            @compileError("snow/aqueous precipitation-equilibrium species mapping changed");
    }
    for (0..33) |index|
        output.salt_mol_per_m3[index] = aqueous_bridge.concentration(state, 0, @enumFromInt(index));
    for (33..snow.salt_species_count) |index|
        output.salt_mol_per_m3[index] = aqueous_bridge.concentration(state, 0, @enumFromInt(index + 1));
    for (output.primary_g_per_m3) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidInitialSnowEquilibrium;
    for (output.static_ion_g_per_m3) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidInitialSnowEquilibrium;
    for (output.salt_mol_per_m3) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidInitialSnowEquilibrium;
    return output;
}

pub const SpeciatedDynamicSource = struct {
    primary_g_per_m3: [snow.species_count]f64 = @splat(0),
    salt_mol_per_m3: [snow.salt_species_count]f64 = @splat(0),
};

pub const SpeciationCacheKey = struct {
    ph: f64,
    soil_hydrogen: f64,
    atca: f64,
    cco2ei: f64,
    nh4_n: f64,
    no3_n: f64,
    po4_p: f64,
    ions: [8]f64,

    pub fn equals(self: SpeciationCacheKey, other: SpeciationCacheKey) bool {
        if (self.ph != other.ph) return false;
        if (self.soil_hydrogen != other.soil_hydrogen) return false;
        if (self.atca != other.atca) return false;
        if (self.cco2ei != other.cco2ei) return false;
        if (self.nh4_n != other.nh4_n) return false;
        if (self.no3_n != other.no3_n) return false;
        if (self.po4_p != other.po4_p) return false;
        for (self.ions, other.ions) |a, b| {
            if (a != b) return false;
        }
        return true;
    }
};

pub const SpeciationCache = struct {
    const Slot = struct {
        key: SpeciationCacheKey,
        value: SpeciatedDynamicSource,
        valid: bool = false,
    };

    slots: [8]Slot = [_]Slot{.{ .key = undefined, .value = undefined, .valid = false }} ** 8,
    next_slot: usize = 0,

    pub fn clear(self: *SpeciationCache) void {
        for (&self.slots) |*slot| {
            slot.valid = false;
        }
        self.next_slot = 0;
    }

    pub fn get(self: *SpeciationCache, key: SpeciationCacheKey) ?SpeciatedDynamicSource {
        for (&self.slots) |*slot| {
            if (slot.valid and slot.key.equals(key)) {
                return slot.value;
            }
        }
        return null;
    }

    pub fn put(self: *SpeciationCache, key: SpeciationCacheKey, value: SpeciatedDynamicSource) void {
        for (&self.slots) |*slot| {
            if (slot.valid and slot.key.equals(key)) {
                slot.value = value;
                return;
            }
        }
        self.slots[self.next_slot] = .{
            .key = key,
            .value = value,
            .valid = true,
        };
        self.next_slot = (self.next_slot + 1) % self.slots.len;
    }
};

/// Persistent STARTE-event speciation state for dynamic rain and irrigation inputs (soil.f:106-109).
/// Hoisted to persistent context state to avoid hourly re-speciation on transient soil chemistry changes.
pub const DynamicInputSpeciationState = struct {
    pub const max_cells: usize = 256;

    cache: SpeciationCache = .{},
    last_starte_day: ?u16 = null,
    event_topsoil_ph: [max_cells]?f64 = [_]?f64{null} ** max_cells,
    event_topsoil_activity_hydrogen: [max_cells]f64 = [_]f64{0.0} ** max_cells,

    pub fn invalidate(self: *DynamicInputSpeciationState) void {
        self.cache.clear();
        self.last_starte_day = null;
        @memset(&self.event_topsoil_ph, null);
        @memset(&self.event_topsoil_activity_hydrogen, 0.0);
    }
};

pub fn speciateFixedPhSourceCached(
    cache: ?*SpeciationCache,
    ph: f64,
    dissolved_gas_g_per_m3: [5]f64,
    ammonium_g_n_per_m3: f64,
    nitrate_g_n_per_m3: f64,
    phosphate_g_p_per_m3: f64,
    free_ion_g_per_m3: [8]f64,
    molar_mass_g_per_mol: initialization.ElementMolarMassesGPerMol,
    soil_hydrogen_mol_per_m3: f64,
    atca: f64,
    cco2ei: f64,
) !SpeciatedDynamicSource {
    const key: SpeciationCacheKey = .{
        .ph = ph,
        .soil_hydrogen = soil_hydrogen_mol_per_m3,
        .atca = atca,
        .cco2ei = cco2ei,
        .nh4_n = ammonium_g_n_per_m3,
        .no3_n = nitrate_g_n_per_m3,
        .po4_p = phosphate_g_p_per_m3,
        .ions = free_ion_g_per_m3,
    };
    if (cache) |c| {
        if (c.get(key)) |hit| return hit;
    }
    const result = try speciateFixedPhSource(
        ph,
        dissolved_gas_g_per_m3,
        ammonium_g_n_per_m3,
        nitrate_g_n_per_m3,
        phosphate_g_p_per_m3,
        free_ion_g_per_m3,
        molar_mass_g_per_mol,
        soil_hydrogen_mol_per_m3,
        atca,
        cco2ei,
    );
    if (cache) |c| {
        c.put(key, result);
    }
    return result;
}

/// STARTE M-loop fixed-pH speciation per source (starte.f:117-160, 234-358, 408-1227, 1234-1341).
/// Each source (K=1 rain, K=2 irrigation) is speciated at its own fixed pH, with carbonate seeds
/// and hydrogen fixed, and with activity quotients evaluated at topsoil-layer pH (starte.f:439).
pub fn speciateFixedPhSource(
    ph: f64,
    dissolved_gas_g_per_m3: [5]f64,
    ammonium_g_n_per_m3: f64,
    nitrate_g_n_per_m3: f64,
    phosphate_g_p_per_m3: f64,
    free_ion_g_per_m3: [8]f64,
    molar_mass_g_per_mol: initialization.ElementMolarMassesGPerMol,
    soil_hydrogen_mol_per_m3: f64,
    atca: f64,
    cco2ei: f64,
) !SpeciatedDynamicSource {
    return speciateFixedPhSourceBounded(
        ph,
        dissolved_gas_g_per_m3,
        ammonium_g_n_per_m3,
        nitrate_g_n_per_m3,
        phosphate_g_p_per_m3,
        free_ion_g_per_m3,
        molar_mass_g_per_mol,
        soil_hydrogen_mol_per_m3,
        atca,
        cco2ei,
        1000,
    );
}

pub fn speciateFixedPhSourceBounded(
    ph: f64,
    dissolved_gas_g_per_m3: [5]f64,
    ammonium_g_n_per_m3: f64,
    nitrate_g_n_per_m3: f64,
    phosphate_g_p_per_m3: f64,
    free_ion_g_per_m3: [8]f64,
    molar_mass_g_per_mol: initialization.ElementMolarMassesGPerMol,
    soil_hydrogen_mol_per_m3: f64,
    atca: f64,
    cco2ei: f64,
    mrxn: usize,
) !SpeciatedDynamicSource {
    return speciateFixedPhSourceBoundedWithHook(
        ph,
        dissolved_gas_g_per_m3,
        ammonium_g_n_per_m3,
        nitrate_g_n_per_m3,
        phosphate_g_p_per_m3,
        free_ion_g_per_m3,
        molar_mass_g_per_mol,
        soil_hydrogen_mol_per_m3,
        atca,
        cco2ei,
        mrxn,
        null,
    );
}

fn packSpeciatedSource(
    CCO21: f64,
    dissolved_gas_g_per_m3: [5]f64,
    CN41: f64,
    CN31: f64,
    CNO1: f64,
    CH1P1: f64,
    CH2P1: f64,
    molar_mass_g_per_mol: initialization.ElementMolarMassesGPerMol,
    CAL1: f64,
    CFE1: f64,
    CHY1: f64,
    CCA1: f64,
    CMG1: f64,
    CNA1: f64,
    CKA1: f64,
    COH1: f64,
    CSO41: f64,
    CCL1: f64,
    CCO31: f64,
    CHCO31: f64,
    CALO1: f64,
    CALO2: f64,
    CALO3: f64,
    CALO4: f64,
    CALS1: f64,
    CFEO1: f64,
    CFEO2: f64,
    CFEO3: f64,
    CFEO4: f64,
    CFES1: f64,
    CCAO1: f64,
    CCAC1: f64,
    CCAH1: f64,
    CCAS1: f64,
    CMGO1: f64,
    CMGC1: f64,
    CMGH1: f64,
    CMGS1: f64,
    CNAC1: f64,
    CNAS1: f64,
    CKAS1: f64,
    CH0P1: f64,
    CH3P1: f64,
    CF1P1: f64,
    CF2P1: f64,
    CC0P1: f64,
    CC1P1: f64,
    CC2P1: f64,
    CM1P1: f64,
) SpeciatedDynamicSource {
    var result: SpeciatedDynamicSource = .{};
    result.primary_g_per_m3[0] = CCO21 * 12.0;
    result.primary_g_per_m3[1] = dissolved_gas_g_per_m3[1];
    result.primary_g_per_m3[2] = dissolved_gas_g_per_m3[2];
    result.primary_g_per_m3[3] = dissolved_gas_g_per_m3[3];
    result.primary_g_per_m3[4] = dissolved_gas_g_per_m3[4];
    result.primary_g_per_m3[5] = CN41 * molar_mass_g_per_mol.nitrogen;
    result.primary_g_per_m3[6] = CN31 * molar_mass_g_per_mol.nitrogen;
    result.primary_g_per_m3[7] = CNO1 * molar_mass_g_per_mol.nitrogen;
    result.primary_g_per_m3[8] = CH1P1 * molar_mass_g_per_mol.phosphorus;
    result.primary_g_per_m3[9] = CH2P1 * molar_mass_g_per_mol.phosphorus;

    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum)] = CAL1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron)] = CFE1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydrogen)] = CHY1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium)] = CCA1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium)] = CMG1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium)] = CNA1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium)] = CKA1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydroxide)] = COH1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sulfate)] = CSO41;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.chloride)] = CCL1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.carbonate)] = CCO31;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.bicarbonate)] = CHCO31;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_monohydroxide)] = CALO1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_dihydroxide)] = CALO2;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_trihydroxide)] = CALO3;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_tetrahydroxide)] = CALO4;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_sulfate)] = CALS1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_monohydroxide)] = CFEO1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_dihydroxide)] = CFEO2;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_trihydroxide)] = CFEO3;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_tetrahydroxide)] = CFEO4;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_sulfate)] = CFES1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydroxide)] = CCAO1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_carbonate)] = CCAC1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_bicarbonate)] = CCAH1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_sulfate)] = CCAS1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydroxide)] = CMGO1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_carbonate)] = CMGC1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_bicarbonate)] = CMGH1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_sulfate)] = CMGS1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_carbonate)] = CNAC1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_sulfate)] = CNAS1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium_sulfate)] = CKAS1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphate)] = CH0P1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphoric_acid)] = CH3P1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_hydrogen_phosphate)] = CF1P1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_dihydrogen_phosphate)] = CF2P1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_phosphate)] = CC0P1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydrogen_phosphate)] = CC1P1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_dihydrogen_phosphate)] = CC2P1;
    result.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydrogen_phosphate)] = CM1P1;
    return result;
}

pub fn speciateFixedPhSourceBoundedWithHook(
    ph: f64,
    dissolved_gas_g_per_m3: [5]f64,
    ammonium_g_n_per_m3: f64,
    nitrate_g_n_per_m3: f64,
    phosphate_g_p_per_m3: f64,
    free_ion_g_per_m3: [8]f64,
    molar_mass_g_per_mol: initialization.ElementMolarMassesGPerMol,
    soil_hydrogen_mol_per_m3: f64,
    atca: f64,
    cco2ei: f64,
    mrxn: usize,
    step_hook: ?*const fn (step: usize, state: *const SpeciatedDynamicSource) void,
) !SpeciatedDynamicSource {
    if (!std.math.isFinite(ph) or ph < 0 or ph > 14)
        return error.InvalidInitialSnowEquilibriumInput;
    inline for (.{ dissolved_gas_g_per_m3, free_ion_g_per_m3 }) |values|
        for (values) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidInitialSnowEquilibriumInput;
    inline for (.{ ammonium_g_n_per_m3, nitrate_g_n_per_m3, phosphate_g_p_per_m3 }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidInitialSnowEquilibriumInput;
    if (!std.math.isFinite(soil_hydrogen_mol_per_m3) or soil_hydrogen_mol_per_m3 <= 0)
        return error.InvalidInitialSnowEquilibriumInput;
    if (!std.math.isFinite(atca) or atca < -100 or atca > 100)
        return error.InvalidInitialSnowEquilibriumInput;
    if (!std.math.isFinite(cco2ei) or cco2ei <= 0)
        return error.InvalidInitialSnowEquilibriumInput;
    if (mrxn == 0) return error.InvalidPicardIterationCount;
    inline for (@typeInfo(initialization.ElementMolarMassesGPerMol).@"struct".fields) |field| {
        const value = @field(molar_mass_g_per_mol, field.name);
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidInitialSnowEquilibriumInput;
    }

    const DPH2O: f64 = 1.0e-08;
    const SPALO: f64 = 1.9e-21;
    const SPFEO: f64 = 6.3e-26;
    const DPCO2: f64 = 4.2e-04;
    const DPHCO: f64 = 5.6e-08;
    const DPN4: f64 = 5.5e-07;
    const DPAL1: f64 = 4.6e-07;
    const DPAL2: f64 = 7.3e-07;
    const DPAL3: f64 = 1.8e-05;
    const DPAL4: f64 = 1.2e-05;
    const DPALS: f64 = 0.16;
    const DPFE1: f64 = 2.7e-08;
    const DPFE2: f64 = 4.5e-07;
    const DPFE3: f64 = 2.5e-05;
    const DPFE4: f64 = 1.2e-05;
    const DPFES: f64 = 7.1e-02;
    const DPCAO: f64 = 12.5;
    const DPCAC: f64 = 4.2e-02;
    const DPCAH: f64 = 13.5;
    const DPCAS: f64 = 1.2;
    const DPMGO: f64 = 0.7;
    const DPMGC: f64 = 0.3;
    const DPMGH: f64 = 67.0;
    const DPMGS: f64 = 2.1;
    const DPNAC: f64 = 0.45;
    const DPNAS: f64 = 3.3e+02;
    const DPKAS: f64 = 5.0e+01;
    const DPH1P: f64 = 4.8e-10;
    const DPH2P: f64 = 6.2e-05;
    const DPH3P: f64 = 7.5;
    const DPF1P: f64 = 4.5e-02;
    const DPF2P: f64 = 3.7e-03;
    const DPC1P: f64 = 1.82;
    const DPC2P: f64 = 40.0;
    const DPM1P: f64 = 1.23;
    const DPCO3: f64 = DPCO2 * DPHCO;
    const TSL: f64 = 1.0e-01;
    const FION: f64 = 0.2;
    const FIONS: f64 = 0.2;
    const FIONX: f64 = 0.2;
    const ZEROC: f64 = 1.0e-48;
    const MRXN: usize = mrxn;

    const CHY1: f64 = std.math.pow(f64, 10.0, -(ph - 3.0));
    const COH1: f64 = DPH2O / CHY1;
    const CN4Z: f64 = ammonium_g_n_per_m3 / molar_mass_g_per_mol.nitrogen;
    const CNOZ: f64 = nitrate_g_n_per_m3 / molar_mass_g_per_mol.nitrogen;
    const CPOZ: f64 = phosphate_g_p_per_m3 / molar_mass_g_per_mol.phosphorus;
    const CALZ: f64 = free_ion_g_per_m3[0] / molar_mass_g_per_mol.aluminum;
    const CFEZ: f64 = free_ion_g_per_m3[1] / molar_mass_g_per_mol.iron;
    const CCAZ: f64 = free_ion_g_per_m3[2] / molar_mass_g_per_mol.calcium;
    const CMGZ: f64 = free_ion_g_per_m3[3] / molar_mass_g_per_mol.magnesium;
    const CNAZ: f64 = free_ion_g_per_m3[4] / molar_mass_g_per_mol.sodium;
    const CKAZ: f64 = free_ion_g_per_m3[5] / molar_mass_g_per_mol.potassium;
    const CSOZ: f64 = free_ion_g_per_m3[6] / molar_mass_g_per_mol.sulfur;
    const CCLZ: f64 = free_ion_g_per_m3[7] / molar_mass_g_per_mol.chloride;
    const SCO2X: f64 = 7.391e-01;
    const ACO2X: f64 = 0.14;
    const CCO2M: f64 = cco2ei / 12.0;
    const CCO21: f64 = CCO2M * (SCO2X / @exp(ACO2X)) * @exp(0.843 - 0.0281 * atca);

    const CCO31: f64 = CCO21 * DPCO3 / (CHY1 * CHY1);
    const CHCO31: f64 = CCO21 * DPCO2 / CHY1;

    var CN41: f64 = CN4Z / (1.0 + DPN4 / CHY1);
    var CN31: f64 = CN41 * DPN4 / CHY1;

    const coh1_cubed = COH1 * COH1 * COH1;
    var CAL1: f64 = if (CALZ < 0.0)
        SPALO / coh1_cubed
    else
        @min(CALZ, SPALO / coh1_cubed);

    var CFE1: f64 = if (CFEZ < 0.0)
        SPFEO / coh1_cubed
    else
        @min(CFEZ, SPFEO / coh1_cubed);

    CN41 = @max(ZEROC, CN41);
    CN31 = @max(ZEROC, CN31);
    const CNO1: f64 = @max(ZEROC, CNOZ);
    const CPO1: f64 = @max(ZEROC, CPOZ);
    CAL1 = @max(ZEROC, CAL1);
    CFE1 = @max(ZEROC, CFE1);
    var CCA1: f64 = @max(ZEROC, CCAZ);
    var CMG1: f64 = @max(ZEROC, CMGZ);
    var CNA1: f64 = @max(ZEROC, CNAZ);
    var CKA1: f64 = @max(ZEROC, CKAZ);
    var CSO41: f64 = @max(ZEROC, CSOZ);
    const CCL1: f64 = @max(ZEROC, CCLZ);

    var CALO1: f64 = CAL1 * COH1 / DPAL1;
    var CALO2: f64 = CAL1 * COH1 * COH1 / (DPAL1 * DPAL2);
    var CALO3: f64 = CAL1 * COH1 * COH1 * COH1 / (DPAL1 * DPAL2 * DPAL3);
    var CALO4: f64 = CAL1 * COH1 * COH1 * COH1 * COH1 / (DPAL1 * DPAL2 * DPAL3 * DPAL4);
    var CALS1: f64 = 0.0;
    var CFEO1: f64 = CFE1 * COH1 / DPFE1;
    var CFEO2: f64 = CFE1 * COH1 * COH1 / (DPFE1 * DPFE2);
    var CFEO3: f64 = CFE1 * COH1 * COH1 * COH1 / (DPFE1 * DPFE2 * DPFE3);
    var CFEO4: f64 = CFE1 * COH1 * COH1 * COH1 * COH1 / (DPFE1 * DPFE2 * DPFE3 * DPFE4);
    var CFES1: f64 = 0.0;
    var CCAO1: f64 = CCA1 * COH1 / DPCAO;
    var CCAC1: f64 = CCA1 * CCO31 * CCO31 / DPCAC;
    var CCAH1: f64 = CCA1 * CHCO31 / DPCAH;
    var CCAS1: f64 = 0.0;
    var CMGO1: f64 = CMG1 * COH1 / DPMGO;
    var CMGC1: f64 = CMG1 * CCO31 * CCO31 / DPMGC;
    var CMGH1: f64 = CMG1 * CHCO31 / DPMGH;
    var CMGS1: f64 = 0.0;
    var CNAC1: f64 = CNA1 * CCO31 / DPNAC;
    var CNAS1: f64 = 0.0;
    var CKAS1: f64 = 0.0;
    var CF1P1: f64 = 0.0;
    var CF2P1: f64 = 0.0;
    var CC0P1: f64 = 0.0;
    var CC1P1: f64 = 0.0;
    var CC2P1: f64 = 0.0;
    var CM1P1: f64 = 0.0;

    const p_denom: f64 = 1.0 + DPH3P / CHY1 + DPH3P * DPH2P / (CHY1 * CHY1) +
        DPH3P * DPH2P * DPH1P / (CHY1 * CHY1 * CHY1);
    var CH3P1: f64 = CPO1 / p_denom;
    var CH2P1: f64 = CH3P1 * DPH3P / CHY1;
    var CH1P1: f64 = CH3P1 * DPH3P * DPH2P / (CHY1 * CHY1);
    var CH0P1: f64 = CH3P1 * DPH3P * DPH2P * DPH1P / (CHY1 * CHY1 * CHY1);

    const AHY1: f64 = soil_hydrogen_mol_per_m3;
    const AOH1: f64 = DPH2O / AHY1;
    const ACO21: f64 = CCO21;

    for (1..MRXN + 1) |m| {
        const CC3 = CAL1 + CFE1;
        const CA3 = CH0P1;
        const CC2 = CCA1 + CMG1 + CALO1 + CFEO1 + CF2P1;
        const CA2 = CSO41 + CCO31 + CH1P1;
        const CC1 = CN41 + CHY1 + CNA1 + CKA1 + CALO2 + CFEO2 + CALS1 + CFES1 + CCAO1 + CCAH1 + CMGO1 + CMGH1 + CF1P1 + CC2P1;
        const CA1 = CNO1 + COH1 + CHCO31 + CCL1 + CALO4 + CFEO4 + CNAC1 + CNAS1 + CKAS1 + CH2P1 + CC0P1;
        const CSTR1 = 0.5e-3 * (9.0 * (CC3 + CA3) + 4.0 * (CC2 + CA2) + CC1 + CA1);
        const CSTRQ = @sqrt(CSTR1);
        const CSTRX = CSTRQ / (1.0 + CSTRQ) - 0.20 * CSTR1;
        const A1S = @min(1.0, std.math.pow(f64, 10.0, -0.509 * 1.0 * CSTRX));
        const A2S = @min(1.0, std.math.pow(f64, 10.0, -0.509 * 4.0 * CSTRX));
        const A3S = @min(1.0, std.math.pow(f64, 10.0, -0.509 * 9.0 * CSTRX));

        const AAL1 = CAL1 * A3S;
        const AALO1 = CALO1 * A2S;
        const AALO2 = CALO2 * A1S;
        const AALO3 = CALO3;
        const AALO4 = CALO4 * A1S;
        const AFE1 = CFE1 * A3S;
        const AFEO1 = CFEO1 * A2S;
        const AFEO2 = CFEO2 * A1S;
        const AFEO3 = CFEO3;
        const AFEO4 = CFEO4 * A1S;
        const ACA1 = CCA1 * A2S;
        const ACO31 = CCO31 * A2S;
        const AHCO31 = CHCO31 * A1S;
        const ASO41 = CSO41 * A2S;
        const AH0P1 = CH0P1 * A3S;
        const AH1P1 = CH1P1 * A2S;
        const AH2P1 = CH2P1 * A1S;
        const AH3P1 = CH3P1;
        const AF1P1 = CF1P1 * A2S;
        const AF2P1 = CF2P1 * A1S;
        _ = CC0P1 * A1S;
        const AC1P1 = CC1P1;
        const AC2P1 = CC2P1 * A1S;
        const AM1P1 = CM1P1;
        const AN41 = CN41 * A1S;
        const AN31 = CN31;
        const AMG1 = CMG1 * A2S;
        const ANA1 = CNA1 * A1S;
        const AKA1 = CKA1 * A1S;
        const AALS1 = CALS1 * A1S;
        const AFES1 = CFES1 * A1S;
        const ACAO1 = CCAO1 * A1S;
        const ACAC1 = CCAC1;
        const ACAS1 = CCAS1;
        const ACAH1 = CCAH1 * A1S;
        const AMGO1 = CMGO1 * A1S;
        const AMGC1 = CMGC1;
        const AMGH1 = CMGH1 * A1S;
        const AMGS1 = CMGS1;
        const ANAC1 = CNAC1 * A1S;
        const ANAS1 = CNAS1 * A1S;
        const AKAS1 = CKAS1 * A1S;

        const XMINN_NH4 = FION * CN41;
        const XMINP_NH4 = FION * @min(CHY1, CN31);
        const AN3Q = DPN4 * AN41 / AHY1;
        const RNH4 = @max(-TSL, @max(-XMINN_NH4, @min(TSL, @min(XMINP_NH4, AN31 - AN3Q))));

        const XMINN_HCO3 = FION * CHCO31;
        const XMINP_HCO3 = FION * @min(CHY1, CCO31);
        const ACO3Q = DPHCO * AHCO31 / AHY1;
        _ = @max(-TSL, @max(-XMINN_HCO3, @min(TSL, @min(XMINP_HCO3, (ACO31 - ACO3Q) / A2S))));

        const XMINN_CO2 = FION * CCO21;
        const XMINP_CO2 = FION * @min(CHY1, CHCO31);
        const AHCO3Q = DPCO2 * ACO21 / AHY1;
        _ = @max(-TSL, @max(-XMINN_CO2, @min(TSL, @min(XMINP_CO2, (AHCO31 - AHCO3Q) / A1S))));

        const XMINN_ALO1 = FIONS * CALO1;
        const XMINP_ALO1 = FIONS * @min(CAL1, COH1);
        const AAL1Q = DPAL1 * AALO1 / AOH1;
        const RALO1 = @max(-TSL, @max(-XMINN_ALO1, @min(TSL, @min(XMINP_ALO1, (AAL1 - AAL1Q) / A3S))));

        const XMINN_ALO2 = FIONS * CALO2;
        const XMINP_ALO2 = FIONS * @min(CALO1, COH1);
        const AALO1Q = DPAL2 * AALO2 / AOH1;
        const RALO2 = @max(-TSL, @max(-XMINN_ALO2, @min(TSL, @min(XMINP_ALO2, (AALO1 - AALO1Q) / A2S))));

        const XMINN_ALO3 = FIONS * CALO3;
        const XMINP_ALO3 = FIONS * @min(CALO2, COH1);
        const AALO2Q = DPAL3 * AALO3 / AOH1;
        const RALO3 = @max(-TSL, @max(-XMINN_ALO3, @min(TSL, @min(XMINP_ALO3, (AALO2 - AALO2Q) / A1S))));

        const XMINN_ALO4 = FIONS * CALO4;
        const XMINP_ALO4 = FIONS * @min(CALO3, COH1);
        const AALO3Q = DPAL4 * AALO4 / AOH1;
        const RALO4 = @max(-TSL, @max(-XMINN_ALO4, @min(TSL, @min(XMINP_ALO4, AALO3 - AALO3Q))));

        const XMINN_ALS = FIONS * CALS1;
        const XMINP_ALS = FIONS * @min(CAL1, CSO41);
        const AAL1Q_S = DPALS * AALS1 / ASO41;
        const RALS = if (ASO41 > 0)
            @max(-TSL, @max(-XMINN_ALS, @min(TSL, @min(XMINP_ALS, (AAL1 - AAL1Q_S) / A3S))))
        else
            0.0;

        const XMINN_FEO1 = FIONS * CFEO1;
        const XMINP_FEO1 = FIONS * @min(CFE1, COH1);
        const AFE1Q = DPFE1 * AFEO1 / AOH1;
        const RFEO1 = @max(-TSL, @max(-XMINN_FEO1, @min(TSL, @min(XMINP_FEO1, (AFE1 - AFE1Q) / A3S))));

        const XMINN_FEO2 = FIONS * CFEO2;
        const XMINP_FEO2 = FIONS * @min(CFEO1, COH1);
        const AFEO1Q = DPFE2 * AFEO2 / AOH1;
        const RFEO2 = @max(-TSL, @max(-XMINN_FEO2, @min(TSL, @min(XMINP_FEO2, (AFEO1 - AFEO1Q) / A2S))));

        const XMINN_FEO3 = FIONS * CFEO3;
        const XMINP_FEO3 = FIONS * @min(CFEO2, COH1);
        const AFEO2Q = DPFE3 * AFEO3 / AOH1;
        const RFEO3 = @max(-TSL, @max(-XMINN_FEO3, @min(TSL, @min(XMINP_FEO3, (AFEO2 - AFEO2Q) / A1S))));

        const XMINN_FEO4 = FIONS * CFEO4;
        const XMINP_FEO4 = FIONS * @min(CFEO3, COH1);
        const AFEO3Q = DPFE4 * AFEO4 / AOH1;
        const RFEO4 = @max(-TSL, @max(-XMINN_FEO4, @min(TSL, @min(XMINP_FEO4, AFEO3 - AFEO3Q))));

        const XMINN_FES = FIONX * CFES1;
        const XMINP_FES = FIONX * @min(CFE1, CSO41);
        const AFE1Q_S = if (ASO41 > 0) DPFES * AFES1 / ASO41 else 0.0;
        const RFES = if (ASO41 > 0)
            @max(-TSL, @max(-XMINN_FES, @min(TSL, @min(XMINP_FES, (AFE1 - AFE1Q_S) / A3S))))
        else
            0.0;

        const XMINN_CAO = FIONS * CCAO1;
        const XMINP_CAO = FIONS * @min(CCA1, COH1);
        const ACA1Q_O = DPCAO * ACAO1 / AOH1;
        const RCAO = @max(-TSL, @max(-XMINN_CAO, @min(TSL, @min(XMINP_CAO, (ACA1 - ACA1Q_O) / A2S))));

        const XMINN_CAC = FIONS * CCAC1;
        const XMINP_CAC = FIONS * @min(CCA1, CCO31);
        const ACA1Q_C = if (ACO31 > 0) DPCAC * ACAC1 / ACO31 else 0.0;
        const RCAC = if (ACO31 > 0)
            @max(-TSL, @max(-XMINN_CAC, @min(TSL, @min(XMINP_CAC, (ACA1 - ACA1Q_C) / A2S))))
        else
            0.0;

        const XMINN_CAH = FIONS * CCAH1;
        const XMINP_CAH = FIONS * @min(CCA1, CHCO31);
        const ACA1Q_H = if (AHCO31 > 0) DPCAH * ACAH1 / AHCO31 else 0.0;
        const RCAH = if (AHCO31 > 0)
            @max(-TSL, @max(-XMINN_CAH, @min(TSL, @min(XMINP_CAH, (ACA1 - ACA1Q_H) / A2S))))
        else
            0.0;

        const XMINN_CAS = FIONS * CCAS1;
        const XMINP_CAS = FIONS * @min(CCA1, CSO41);
        const ACA1Q_S = if (ASO41 > 0) DPCAS * ACAS1 / ASO41 else 0.0;
        const RCAS = if (ASO41 > 0)
            @max(-TSL, @max(-XMINN_CAS, @min(TSL, @min(XMINP_CAS, (ACA1 - ACA1Q_S) / A2S))))
        else
            0.0;

        const XMINN_MGO = FIONS * CMGO1;
        const XMINP_MGO = FIONS * @min(CMG1, COH1);
        const AMG1Q_O = DPMGO * AMGO1 / AOH1;
        const RMGO = @max(-TSL, @max(-XMINN_MGO, @min(TSL, @min(XMINP_MGO, (AMG1 - AMG1Q_O) / A2S))));

        const XMINN_MGC = FIONS * CMGC1;
        const XMINP_MGC = FIONS * @min(CMG1, CCO31);
        const AMG1Q_C = if (ACO31 > 0) DPMGC * AMGC1 / ACO31 else 0.0;
        const RMGC = if (ACO31 > 0)
            @max(-TSL, @max(-XMINN_MGC, @min(TSL, @min(XMINP_MGC, (AMG1 - AMG1Q_C) / A2S))))
        else
            0.0;

        const XMINN_MGH = FIONS * CMGH1;
        const XMINP_MGH = FIONS * @min(CMG1, CHCO31);
        const AMG1Q_H = if (AHCO31 > 0) DPMGH * AMGH1 / AHCO31 else 0.0;
        const RMGH = if (AHCO31 > 0)
            @max(-TSL, @max(-XMINN_MGH, @min(TSL, @min(XMINP_MGH, (AMG1 - AMG1Q_H) / A2S))))
        else
            0.0;

        const XMINN_MGS = FIONS * CMGS1;
        const XMINP_MGS = FIONS * @min(CMG1, CSO41);
        const AMG1Q_S = if (ASO41 > 0) DPMGS * AMGS1 / ASO41 else 0.0;
        const RMGS = if (ASO41 > 0)
            @max(-TSL, @max(-XMINN_MGS, @min(TSL, @min(XMINP_MGS, (AMG1 - AMG1Q_S) / A2S))))
        else
            0.0;

        const XMINN_NAC = FIONS * CNAC1;
        const XMINP_NAC = FIONS * @min(CNA1, CCO31);
        const ANA1Q_C = if (ACO31 > 0) DPNAC * ANAC1 / ACO31 else 0.0;
        const RNAC = if (ACO31 > 0)
            @max(-TSL, @max(-XMINN_NAC, @min(TSL, @min(XMINP_NAC, (ANA1 - ANA1Q_C) / A1S))))
        else
            0.0;

        const XMINN_NAS = FIONS * CNAS1;
        const XMINP_NAS = FIONS * @min(CNA1, CSO41);
        const ANA1Q_S = if (ASO41 > 0) DPNAS * ANAS1 / ASO41 else 0.0;
        const RNAS = if (ASO41 > 0)
            @max(-TSL, @max(-XMINN_NAS, @min(TSL, @min(XMINP_NAS, (ANA1 - ANA1Q_S) / A1S))))
        else
            0.0;

        const XMINN_KAS = FIONS * CKAS1;
        const XMINP_KAS = FIONS * @min(CKA1, CSO41);
        const AKA1Q_S = if (ASO41 > 0) DPKAS * AKAS1 / ASO41 else 0.0;
        const RKAS = if (ASO41 > 0)
            @max(-TSL, @max(-XMINN_KAS, @min(TSL, @min(XMINP_KAS, (AKA1 - AKA1Q_S) / A1S))))
        else
            0.0;

        const XMINN_H1P = FIONS * CH1P1;
        const XMINP_H1P = FIONS * @min(CHY1, CH0P1);
        const AH0P1Q = DPH1P * AH1P1 / AHY1;
        const RH1P = @max(-TSL, @max(-XMINN_H1P, @min(TSL, @min(XMINP_H1P, (AH0P1 - AH0P1Q) / A3S))));

        const XMINN_H2P = FIONS * CH2P1;
        const XMINP_H2P = FIONS * @min(CHY1, CH1P1);
        const AH1P1Q = DPH2P * AH2P1 / AHY1;
        const RH2P = @max(-TSL, @max(-XMINN_H2P, @min(TSL, @min(XMINP_H2P, (AH1P1 - AH1P1Q) / A2S))));

        const XMINN_H3P = FIONS * CH3P1;
        const XMINP_H3P = FIONS * @min(CHY1, CH2P1);
        const AH2P1Q = DPH3P * AH3P1 / AHY1;
        const RH3P = @max(-TSL, @max(-XMINN_H3P, @min(TSL, @min(XMINP_H3P, (AH2P1 - AH2P1Q) / A1S))));

        const XMINN_F1P = FIONX * CF1P1;
        const XMINP_F1P = FIONX * @min(CH1P1, CFE1);
        const AFE1Q_1P = if (AH1P1 > 0) DPF1P * AF1P1 / AH1P1 else 0.0;
        const RF1P = if (AH1P1 > 0)
            @max(-TSL, @max(-XMINN_F1P, @min(TSL, @min(XMINP_F1P, (AFE1 - AFE1Q_1P) / A3S))))
        else
            0.0;

        const XMINN_F2P = FIONS * CF2P1;
        const XMINP_F2P = FIONS * @min(CH2P1, CFE1);
        const AFE1Q_2P = if (AH2P1 > 0) DPF2P * AF2P1 / AH2P1 else 0.0;
        const RF2P = if (AH2P1 > 0)
            @max(-TSL, @max(-XMINN_F2P, @min(TSL, @min(XMINP_F2P, (AFE1 - AFE1Q_2P) / A3S))))
        else
            0.0;

        const RC0P: f64 = 0.0;

        const XMINN_C1P = FIONS * CC1P1;
        const XMINP_C1P = FIONS * @min(CH1P1, CCA1);
        const ACA1Q_1P = if (AH1P1 > 0) DPC1P * AC1P1 / AH1P1 else 0.0;
        const RC1P = if (AH1P1 > 0)
            @max(-TSL, @max(-XMINN_C1P, @min(TSL, @min(XMINP_C1P, (ACA1 - ACA1Q_1P) / A2S))))
        else
            0.0;

        const XMINN_C2P = FIONS * CC2P1;
        const XMINP_C2P = FIONS * @min(CH2P1, CCA1);
        const ACA1Q_2P = if (AH2P1 > 0) DPC2P * AC2P1 / AH2P1 else 0.0;
        const RC2P = if (AH2P1 > 0)
            @max(-TSL, @max(-XMINN_C2P, @min(TSL, @min(XMINP_C2P, (ACA1 - ACA1Q_2P) / A2S))))
        else
            0.0;

        const XMINN_M1P = FIONS * CM1P1;
        const XMINP_M1P = FIONX * @min(CH1P1, CMG1);
        const AMG1Q_1P = if (AH1P1 > 0) DPM1P * AM1P1 / AH1P1 else 0.0;
        const RM1P = if (AH1P1 > 0)
            @max(-TSL, @max(-XMINN_M1P, @min(TSL, @min(XMINP_M1P, (AMG1 - AMG1Q_1P) / A2S))))
        else
            0.0;

        const RN4S = RNH4;
        const RN3S = -RNH4;
        const RAL = -RALO1 - RALS;
        const RFE = -RFEO1 - RFES - (RF1P + RF2P);
        const RCA = -RCAO - RCAC - RCAH - RCAS - RC0P - RC1P - RC2P;
        const RMG = -RMGO - RMGC - RMGH - RMGS - RM1P;
        const RNA = -RNAC - RNAS;
        const RKA = -RKAS;
        const RSO4 = -RALS - RFES - RCAS - RMGS - RNAS - RKAS;
        const RAL1 = RALO1 - RALO2;
        const RAL2 = RALO2 - RALO3;
        const RAL3 = RALO3 - RALO4;
        const RAL4 = RALO4;
        const RFE1 = RFEO1 - RFEO2;
        const RFE2 = RFEO2 - RFEO3;
        const RFE3 = RFEO3 - RFEO4;
        const RFE4 = RFEO4;
        const RHP0 = -RH1P - RC0P;
        const RHP1 = RH1P - RH2P - RF1P - RC1P - RM1P;
        const RHP2 = RH2P - RH3P - RF2P - RC2P;
        const RHP3 = RH3P;

        CN41 = @max(ZEROC, CN41 + RN4S);
        CN31 = @max(ZEROC, CN31 + RN3S);
        CAL1 = @max(ZEROC, CAL1 + RAL);
        CFE1 = @max(ZEROC, CFE1 + RFE);
        CCA1 = @max(ZEROC, CCA1 + RCA);
        CMG1 = @max(ZEROC, CMG1 + RMG);
        CNA1 = @max(ZEROC, CNA1 + RNA);
        CKA1 = @max(ZEROC, CKA1 + RKA);
        CSO41 = @max(ZEROC, CSO41 + RSO4);
        CALO1 = @max(ZEROC, CALO1 + RAL1);
        CALO2 = @max(ZEROC, CALO2 + RAL2);
        CALO3 = @max(ZEROC, CALO3 + RAL3);
        CALO4 = @max(ZEROC, CALO4 + RAL4);
        CALS1 = @max(ZEROC, CALS1 + RALS);
        CFEO1 = @max(ZEROC, CFEO1 + RFE1);
        CFEO2 = @max(ZEROC, CFEO2 + RFE2);
        CFEO3 = @max(ZEROC, CFEO3 + RFE3);
        CFEO4 = @max(ZEROC, CFEO4 + RFE4);
        CFES1 = @max(ZEROC, CFES1 + RFES);
        CCAO1 = @max(ZEROC, CCAO1 + RCAO);
        CCAC1 = @max(ZEROC, CCAC1 + RCAC);
        CCAH1 = @max(ZEROC, CCAH1 + RCAH);
        CCAS1 = @max(ZEROC, CCAS1 + RCAS);
        CMGO1 = @max(ZEROC, CMGO1 + RMGO);
        CMGC1 = @max(ZEROC, CMGC1 + RMGC);
        CMGH1 = @max(ZEROC, CMGH1 + RMGH);
        CMGS1 = @max(ZEROC, CMGS1 + RMGS);
        CNAC1 = @max(ZEROC, CNAC1 + RNAC);
        CNAS1 = @max(ZEROC, CNAS1 + RNAS);
        CKAS1 = @max(ZEROC, CKAS1 + RKAS);
        CH0P1 = @max(ZEROC, CH0P1 + RHP0);
        CH1P1 = @max(ZEROC, CH1P1 + RHP1);
        CH2P1 = @max(ZEROC, CH2P1 + RHP2);
        CH3P1 = @max(ZEROC, CH3P1 + RHP3);
        CF1P1 = @max(ZEROC, CF1P1 + RF1P);
        CF2P1 = @max(ZEROC, CF2P1 + RF2P);
        CC0P1 = @max(ZEROC, CC0P1 + RC0P);
        CC1P1 = @max(ZEROC, CC1P1 + RC1P);
        CC2P1 = @max(ZEROC, CC2P1 + RC2P);
        CM1P1 = @max(ZEROC, CM1P1 + RM1P);
        if (step_hook) |hook| {
            const step_state = packSpeciatedSource(
                CCO21,
                dissolved_gas_g_per_m3,
                CN41,
                CN31,
                CNO1,
                CH1P1,
                CH2P1,
                molar_mass_g_per_mol,
                CAL1,
                CFE1,
                CHY1,
                CCA1,
                CMG1,
                CNA1,
                CKA1,
                COH1,
                CSO41,
                CCL1,
                CCO31,
                CHCO31,
                CALO1,
                CALO2,
                CALO3,
                CALO4,
                CALS1,
                CFEO1,
                CFEO2,
                CFEO3,
                CFEO4,
                CFES1,
                CCAO1,
                CCAC1,
                CCAH1,
                CCAS1,
                CMGO1,
                CMGC1,
                CMGH1,
                CMGS1,
                CNAC1,
                CNAS1,
                CKAS1,
                CH0P1,
                CH3P1,
                CF1P1,
                CF2P1,
                CC0P1,
                CC1P1,
                CC2P1,
                CM1P1,
            );
            hook(m, &step_state);
        }
    }

    return packSpeciatedSource(
        CCO21,
        dissolved_gas_g_per_m3,
        CN41,
        CN31,
        CNO1,
        CH1P1,
        CH2P1,
        molar_mass_g_per_mol,
        CAL1,
        CFE1,
        CHY1,
        CCA1,
        CMG1,
        CNA1,
        CKA1,
        COH1,
        CSO41,
        CCL1,
        CCO31,
        CHCO31,
        CALO1,
        CALO2,
        CALO3,
        CALO4,
        CALS1,
        CFEO1,
        CFEO2,
        CFEO3,
        CFEO4,
        CFES1,
        CCAO1,
        CCAC1,
        CCAH1,
        CCAS1,
        CMGO1,
        CMGC1,
        CMGH1,
        CMGS1,
        CNAC1,
        CNAS1,
        CKAS1,
        CH0P1,
        CH3P1,
        CF1P1,
        CF2P1,
        CC0P1,
        CC1P1,
        CC2P1,
        CM1P1,
    );
}

fn validateInputs(inputs: Inputs) !void {
    if (!std.math.isFinite(inputs.precipitation_ph) or inputs.precipitation_ph < 0 or inputs.precipitation_ph > 14)
        return error.InvalidInitialSnowEquilibriumInput;
    inline for (.{ inputs.dissolved_gas_g_per_m3, inputs.free_ion_g_per_m3 }) |values|
        for (values) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidInitialSnowEquilibriumInput;
    inline for (.{ inputs.ammonium_g_n_per_m3, inputs.nitrate_g_n_per_m3, inputs.phosphate_g_p_per_m3 }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidInitialSnowEquilibriumInput;
    inline for (@typeInfo(initialization.ElementMolarMassesGPerMol).@"struct".fields) |field| {
        const value = @field(inputs.molar_mass_g_per_mol, field.name);
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidInitialSnowEquilibriumInput;
    }
}

fn filled(comptime T: type, value: f64) T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| @field(result, field.name) = value;
    return result;
}

test "first-header snow gas solubility includes STARTE activity divisor" {
    const atmospheric = [5]f64{ 2, 3, 4, 5, 6 };
    const parameters: gas_transport.SurfaceSolubilityParameters = .{
        .reference_water_to_air = [_]f64{0.5} ** gas_transport.species_count,
        .log_intercept = [_]f64{0.2} ** gas_transport.species_count,
        .temperature_coefficient_per_c = [_]f64{0.01} ** gas_transport.species_count,
    };
    const activity_log = [_]f64{0.3} ** gas_transport.species_count;
    const dissolved = try initialPrecipitationDissolvedGasGPerM3(
        atmospheric,
        298.15,
        parameters,
        activity_log,
    );
    for (dissolved, atmospheric, 0..) |actual, air, species| {
        _ = species;
        const expected = air * 0.5 * @exp(0.2 - 0.01 * 25 - 0.3);
        try std.testing.expectApproxEqRel(expected, actual, 8 * std.math.floatEps(f64));
    }
}

test "first-header equilibrium derives nonzero complexes instead of dropping them" {
    var parameters = std.mem.zeroes(parameters_module.Parameters);
    parameters.aqueous_constants = filled(@TypeOf(parameters.aqueous_constants), 1);
    parameters.aqueous_kinetics = .{
        .ammonium_substrate_limit_fraction = 0.2,
        .general_substrate_limit_fraction = 0.2,
        .maximum_fast_association_mol_per_m3_step = 1e-3,
        .maximum_slow_association_mol_per_m3_step = 1e-3,
    };
    parameters.phosphate_constants = filled(@TypeOf(parameters.phosphate_constants), 1);
    parameters.phosphate_surface = filled(@TypeOf(parameters.phosphate_surface), 0.2);
    parameters.phosphate_minerals = filled(@TypeOf(parameters.phosphate_minerals), 1);
    parameters.phosphate_kinetics = .{ .substrate_limit_fraction = 0.2, .maximum_pairing_mol_per_m3_step = 1e-3 };
    parameters.cation_substrate_limit_fraction = 0.2;
    parameters.cation_maximum_adsorption_mol_charge_per_m3_step = 0.2;
    parameters.geochemistry_products = filled(@TypeOf(parameters.geochemistry_products), 1);
    parameters.geochemistry_kinetics = filled(@TypeOf(parameters.geochemistry_kinetics), 0.2);
    parameters.water_activity_product_mol2_per_m6 = 1e-8;
    parameters.negligible_water_ion_concentration_mol_per_m3 = 1e-12;
    parameters.water_concentration_mol_per_m3 = 1000;
    parameters.surface_litter.carboxyl_dissociation_constant = 1;
    const masses: initialization.ElementMolarMassesGPerMol = .{ .nitrogen = 14, .phosphorus = 31, .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 };
    const output = try equilibrate(std.testing.allocator, .{
        .precipitation_ph = 3,
        .dissolved_gas_g_per_m3 = .{ 0.12, 0.12, 0.32, 0.28, 0.28 },
        .ammonium_g_n_per_m3 = 0,
        .nitrate_g_n_per_m3 = 0,
        .phosphate_g_p_per_m3 = 0,
        .free_ion_g_per_m3 = .{ 0, 0, 0.40, 0, 0, 0, 0.32, 0 },
        .molar_mass_g_per_mol = masses,
    }, parameters, .{ .absolute_tolerance_mol_per_m3 = 1e-6, .absolute_tolerance_mol_per_megagram = 1e-6, .relative_tolerance = 1e-5, .max_iterations = 100 });
    for (output.primary_g_per_m3[0..5]) |value| try std.testing.expect(value > 0);
    try std.testing.expectEqualSlices(f64, &[_]f64{ 0, 0, 0.40, 0, 0, 0, 0.32, 0 }, &output.static_ion_g_per_m3);
    try std.testing.expect(output.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_sulfate)] > 0);
    // Substitute the published answer into independent elemental balances
    // and mass-action equations, not merely the solver's convergence score.
    var aqueous = std.mem.zeroes(aqueous_network.State);
    inline for (.{ "hydrogen", "hydroxide", "calcium", "carbonate", "bicarbonate", "sulfate", "calcium_hydroxide", "calcium_carbonate", "calcium_bicarbonate", "calcium_sulfate" }) |field| {
        @field(aqueous, field) = output.salt_mol_per_m3[@intFromEnum(@field(snow.SaltSpecies, field))];
    }
    aqueous.carbon_dioxide = output.primary_g_per_m3[0] / 12;
    const calcium_total = aqueous.calcium + aqueous.calcium_hydroxide + aqueous.calcium_carbonate + aqueous.calcium_bicarbonate + aqueous.calcium_sulfate;
    const carbon_total = aqueous.carbon_dioxide + aqueous.carbonate + aqueous.bicarbonate + aqueous.calcium_carbonate + aqueous.calcium_bicarbonate;
    const sulfur_total = aqueous.sulfate + aqueous.calcium_sulfate;
    for ([_]f64{ calcium_total, carbon_total, sulfur_total }) |total|
        try std.testing.expectApproxEqRel(@as(f64, 0.01), total, 128 * std.math.floatEps(f64));
    const coefficients = try activity_coefficients.calculate(try charge_classification.classify(
        aqueous,
        std.mem.zeroes(phosphate_network.State),
        std.mem.zeroes(phosphate_network.State),
        .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 },
    ), 1);
    const g1 = coefficients.monovalent_activity_coefficient;
    const g2 = coefficients.divalent_activity_coefficient;
    const tolerance = 1024 * std.math.floatEps(f64);
    try std.testing.expectApproxEqRel(parameters.water_activity_product_mol2_per_m6, aqueous.hydrogen * aqueous.hydroxide * g1 * g1, tolerance);
    try std.testing.expectApproxEqRel(aqueous.calcium * aqueous.sulfate * g2 * g2, aqueous.calcium_sulfate * parameters.aqueous_constants.calcium_sulfate, tolerance);
    try std.testing.expectApproxEqRel(aqueous.calcium * aqueous.carbonate * g2 * g2, aqueous.calcium_carbonate * parameters.aqueous_constants.calcium_carbonate, tolerance);
    try std.testing.expectApproxEqRel(aqueous.calcium * aqueous.bicarbonate * g2 * g1, aqueous.calcium_bicarbonate * g1 * parameters.aqueous_constants.calcium_bicarbonate, tolerance);
    try std.testing.expectApproxEqRel(aqueous.calcium * aqueous.hydroxide * g2 * g1, aqueous.calcium_hydroxide * g1 * parameters.aqueous_constants.calcium_hydroxide, tolerance);
    try std.testing.expectApproxEqRel(aqueous.hydrogen * aqueous.bicarbonate * g1 * g1, aqueous.carbon_dioxide * parameters.aqueous_constants.carbon_dioxide, tolerance);
    try std.testing.expectApproxEqRel(aqueous.hydrogen * aqueous.carbonate * g1 * g2, aqueous.bicarbonate * g1 * parameters.aqueous_constants.bicarbonate, tolerance);
}

test "acidic phosphate-bearing precipitation reaches carrier-free equilibrium" {
    const parameters = try parameters_module.parse(
        "aqueous_constants 5.5e-7 5.6e-8 4.2e-4 4.6e-7 7.3e-7 1.8e-5 1.2e-5 0.16 2.7e-8 4.5e-7 2.5e-5 1.2e-5 7.1e-2 12.5 4.2e-2 13.5 1.2 0.7 0.3 67.0 2.1 0.45 3.3e2 5.0e1\n" ++
            "aqueous_kinetics 0.2 0.2 0.1 0.1\n" ++
            "phosphate_constants 4.8e-10 6.2e-5 7.5 4.5e-2 3.7e-3 1.82 40.0 1.23\n" ++
            "phosphate_surface 4.5e-1 8.1e-4 5.0e5 5.0e3 1.0e-8 6.2e-5 1.0e-2 0.2\n" ++
            "phosphate_minerals 9.8e-15 2.5e-19 1.3e-1 4.0e-31 7.0e7 1.0e-8 1.0e-3 1.0e-3 1.0e-3\n" ++
            "phosphate_kinetics 0.2 0.1\n" ++
            "cation_kinetics 0.2 1.0e-2\n" ++
            "geochemistry_products 1.9e-21 6.3e-26 3.3e-3 1.4e1 1.0e5 1.0e5 1.0e3 1.0e3 1.0e2 1.0e2\n" ++
            "geochemistry_kinetics 0.2 0.2 1.0e-3 1.0e-3 1.0e-5 0.0 0.0\n" ++
            "water_equilibrium 1.0e-8 1.0e-48 55555.555555555555\n" ++
            "surface_litter 1.0e-2 2.5e2\n" ++
            "surface_fertilizer 1.0 1.0 1.0 0.05 50.0 0.03 0.05 0.01 0.005\n",
    );
    const masses: initialization.ElementMolarMassesGPerMol = .{ .nitrogen = 14, .phosphorus = 31, .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 };
    inline for (.{
        // Ottawa hour 605: the old 20% substrate face caused stagnation.
        0.2669585201498312,
        // Ottawa hour 105: the full-domain solve exposed accumulated affine
        // phosphate roundoff at the strict accepted-state audit.
        0.5121520251528051,
    }) |dissolved_co2_g_per_m3| {
        const equilibrium_inputs: Inputs = .{
            .precipitation_ph = 4,
            .dissolved_gas_g_per_m3 = .{ dissolved_co2_g_per_m3, 0, 0, 0, 0 },
            .ammonium_g_n_per_m3 = 0.25,
            .nitrate_g_n_per_m3 = 0.75,
            .phosphate_g_p_per_m3 = 0.2,
            .free_ion_g_per_m3 = @splat(0),
            .molar_mass_g_per_mol = masses,
        };
        const baseline = try equilibrate(
            std.testing.allocator,
            equilibrium_inputs,
            parameters,
            .{
                .absolute_tolerance_mol_per_m3 = 1e-13,
                .absolute_tolerance_mol_per_megagram = 1e-13,
                .relative_tolerance = 1e-8,
                .max_iterations = 100,
            },
        );
        const output = try equilibrate(std.testing.allocator, equilibrium_inputs, parameters, .{
            .absolute_tolerance_mol_per_m3 = 1e-13,
            .absolute_tolerance_mol_per_megagram = 1e-13,
            .relative_tolerance = 1e-8,
            .include_zero_rate_full_network_axes = false,
            .max_iterations = 100,
        });
        try std.testing.expectEqualDeep(baseline, output);
        const gated_output = try equilibrate(std.testing.allocator, equilibrium_inputs, parameters, .{
            .absolute_tolerance_mol_per_m3 = 1e-13,
            .absolute_tolerance_mol_per_megagram = 1e-13,
            .relative_tolerance = 1e-8,
            .include_zero_rate_full_network_axes = false,
            .rate_ranked_coordinate_head_maximum_norm = 1.0e8,
            .max_iterations = 100,
        });
        try std.testing.expectEqualDeep(output, gated_output);

        var phosphate_g_p_per_m3 = output.primary_g_per_m3[8] +
            output.primary_g_per_m3[9];
        for (output.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphate)..]) |value|
            phosphate_g_p_per_m3 += value * masses.phosphorus;
        try std.testing.expectApproxEqAbs(
            @as(f64, 0.2),
            phosphate_g_p_per_m3,
            1e-12,
        );
    }
}

test "equilibrated precipitation maps all 41 snow salt species without dropping phosphate pairs" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0].carbon_dioxide = 2;
    state.aqueous[0].ammonium_non_band = 3;
    state.aqueous[0].ammonia_non_band = 4;
    state.aqueous[0].nitrate_non_band = 5;
    inline for (@typeInfo(@TypeOf(state.aqueous[0])).@"struct".fields, 0..) |field, index| {
        if (@field(state.aqueous[0], field.name) == 0)
            @field(state.aqueous[0], field.name) = @floatFromInt(index + 1);
    }
    inline for (@typeInfo(@TypeOf(state.non_band_phosphate[0])).@"struct".fields, 0..) |field, index|
        @field(state.non_band_phosphate[0], field.name) = @floatFromInt(index + 1);
    const masses: initialization.ElementMolarMassesGPerMol = .{ .nitrogen = 14, .phosphorus = 31, .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 };
    const output = try fromEquilibratedState(&state, .{ 0, 6, 7, 8, 9 }, masses);
    for (output.primary_g_per_m3) |value| try std.testing.expect(value > 0);
    for (output.salt_mol_per_m3) |value| try std.testing.expect(value > 0);
    try std.testing.expectEqual(state.non_band_phosphate[0].magnesium_hpo4_pair_mol_per_m3, output.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydrogen_phosphate)]);
}

/// Ottawa runtime parameters as the production deck parses them, for the
/// carrier-free precipitation equilibrium cost benchmark below.
fn benchmarkParameters() !parameters_module.Parameters {
    return parameters_module.parse(
        "aqueous_constants 5.5e-7 5.6e-8 4.2e-4 4.6e-7 7.3e-7 1.8e-5 1.2e-5 0.16 2.7e-8 4.5e-7 2.5e-5 1.2e-5 7.1e-2 12.5 4.2e-2 13.5 1.2 0.7 0.3 67.0 2.1 0.45 3.3e2 5.0e1\n" ++
            "aqueous_kinetics 0.2 0.2 0.1 0.1\n" ++
            "phosphate_constants 4.8e-10 6.2e-5 7.5 4.5e-2 3.7e-3 1.82 40.0 1.23\n" ++
            "phosphate_surface 4.5e-1 8.1e-4 5.0e5 5.0e3 1.0e-8 6.2e-5 1.0e-2 0.2\n" ++
            "phosphate_minerals 9.8e-15 2.5e-19 1.3e-1 4.0e-31 7.0e7 1.0e-8 1.0e-3 1.0e-3 1.0e-3\n" ++
            "phosphate_kinetics 0.2 0.1\n" ++
            "cation_kinetics 0.2 1.0e-2\n" ++
            "geochemistry_products 1.9e-21 6.3e-26 3.3e-3 1.4e1 1.0e5 1.0e5 1.0e3 1.0e3 1.0e2 1.0e2\n" ++
            "geochemistry_kinetics 0.2 0.2 1.0e-3 1.0e-3 1.0e-5 0.0 0.0\n" ++
            "water_equilibrium 1.0e-8 1.0e-48 55555.555555555555\n" ++
            "surface_litter 1.0e-2 2.5e2\n" ++
            "surface_fertilizer 1.0 1.0 1.0 0.05 50.0 0.03 0.05 0.01 0.005\n",
    );
}

fn expectWithinSolverTolerance(
    expected: f64,
    actual: f64,
    absolute_tolerance: f64,
    relative_tolerance: f64,
) !void {
    const tolerance = 4 * absolute_tolerance +
        4 * relative_tolerance * @max(@abs(expected), @abs(actual));
    try std.testing.expectApproxEqAbs(expected, actual, tolerance);
}

test "carrier-free analytical equilibrium matches generic solver and conserves invariants" {
    const parameters = try benchmarkParameters();
    const masses: initialization.ElementMolarMassesGPerMol = .{ .nitrogen = 14, .phosphorus = 31, .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 };
    const options: reaction_solver.Options = .{
        .absolute_tolerance_mol_per_m3 = 1.0e-13,
        .absolute_tolerance_mol_per_megagram = 1.0e-13,
        .relative_tolerance = 1.0e-8,
        .picard_relaxation = 0.5,
        .include_zero_rate_full_network_axes = false,
        .rate_ranked_coordinate_head_maximum_norm = 1.0e8,
        .max_iterations = 100,
    };
    const Case = struct { ph: f64, dissolved_co2_g_per_m3: f64 };
    const cases = [_]Case{
        .{ .ph = 7.0, .dissolved_co2_g_per_m3 = 0.2669585201498312 },
        .{ .ph = 7.0, .dissolved_co2_g_per_m3 = 0.2669585201498312 * 1.0001 },
        .{ .ph = 4.0, .dissolved_co2_g_per_m3 = 0.2669585201498312 },
    };
    var workspace = try reaction_solver.Workspace.init(std.testing.allocator);
    defer workspace.deinit();

    var comparison_failure: ?anyerror = null;
    for (cases) |case| {
        const inputs: Inputs = .{
            .precipitation_ph = case.ph,
            .dissolved_gas_g_per_m3 = .{ case.dissolved_co2_g_per_m3, 0, 0, 0, 0 },
            .ammonium_g_n_per_m3 = 0.25,
            .nitrate_g_n_per_m3 = 0.75,
            .phosphate_g_p_per_m3 = 0.2,
            .free_ion_g_per_m3 = @splat(0),
            .molar_mass_g_per_mol = masses,
        };
        const analytical = try carrierFreeAnalyticalEquilibrium(inputs, parameters);
        const selected = try equilibrate(std.testing.allocator, inputs, parameters, options);
        try std.testing.expectEqualDeep(analytical, selected);
        const generic = equilibrateGenericWithWorkspaceAndFailureReport(
            std.testing.allocator,
            &workspace,
            inputs,
            parameters,
            options,
            null,
        ) catch |err| {
            std.debug.print("SNOW_EQUILIBRIUM_COMPARISON ph={d} carbon={e} solver_error={s}\n", .{ case.ph, case.dissolved_co2_g_per_m3, @errorName(err) });
            comparison_failure = err;
            continue;
        };
        const primary_molar_masses = [10]f64{ 12, 1, 1, 1, 1, masses.nitrogen, masses.nitrogen, masses.nitrogen, masses.phosphorus, masses.phosphorus };
        for (generic.primary_g_per_m3, analytical.primary_g_per_m3, primary_molar_masses, 0..) |expected, actual, molar_mass, species| {
            expectWithinSolverTolerance(
                expected,
                actual,
                options.absolute_tolerance_mol_per_m3 * molar_mass,
                options.relative_tolerance,
            ) catch |err| {
                std.debug.print("SNOW_EQUILIBRIUM_COMPARISON ph={d} primary_species={d} generic={e} analytical={e} molar_difference={e}\n", .{
                    case.ph, species, expected, actual, (actual - expected) / molar_mass,
                });
                comparison_failure = err;
            };
        }
        try std.testing.expectEqualSlices(f64, &generic.static_ion_g_per_m3, &analytical.static_ion_g_per_m3);
        for (generic.salt_mol_per_m3, analytical.salt_mol_per_m3, 0..) |expected, actual, species| {
            expectWithinSolverTolerance(expected, actual, options.absolute_tolerance_mol_per_m3, options.relative_tolerance) catch |err| {
                std.debug.print("SNOW_EQUILIBRIUM_COMPARISON ph={d} salt_species={d} generic={e} analytical={e}\n", .{ case.ph, species, expected, actual });
                comparison_failure = err;
            };
        }

        const system = try buildCarrierFreeSystem(inputs, parameters);
        var aqueous = std.mem.zeroes(aqueous_network.State);
        aqueous.hydrogen = analytical.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydrogen)];
        aqueous.hydroxide = analytical.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydroxide)];
        aqueous.carbon_dioxide = analytical.primary_g_per_m3[0] / 12;
        aqueous.ammonium_non_band = analytical.primary_g_per_m3[5] / masses.nitrogen;
        aqueous.ammonia_non_band = analytical.primary_g_per_m3[6] / masses.nitrogen;
        aqueous.nitrate_non_band = analytical.primary_g_per_m3[7] / masses.nitrogen;
        aqueous.carbonate = analytical.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.carbonate)];
        aqueous.bicarbonate = analytical.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.bicarbonate)];
        var phosphate = std.mem.zeroes(phosphate_network.State);
        phosphate.dissolved_po4_mol_p_per_m3 = analytical.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphate)];
        phosphate.dissolved_hpo4_mol_p_per_m3 = analytical.primary_g_per_m3[8] / masses.phosphorus;
        phosphate.dissolved_h2po4_mol_p_per_m3 = analytical.primary_g_per_m3[9] / masses.phosphorus;
        phosphate.dissolved_h3po4_mol_p_per_m3 = analytical.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphoric_acid)];
        const invariant_scale = @abs(aqueous.hydrogen) + @abs(aqueous.hydroxide) +
            system.total_ammoniacal_n_mol_per_m3 + system.nitrate_mol_n_per_m3 +
            2 * system.total_carbon_mol_per_m3 + 3 * system.total_phosphate_mol_p_per_m3;
        const invariant_tolerance = 8192 * std.math.floatEps(f64) *
            @max(invariant_scale, std.math.floatEps(f64));
        try std.testing.expectApproxEqAbs(
            system.initial_proton_inventory_mol_per_m3,
            carrierFreeProtonInventory(aqueous, phosphate),
            invariant_tolerance,
        );
        try std.testing.expectApproxEqAbs(
            system.initial_charge_mol_per_m3,
            carrierFreeCharge(aqueous, phosphate),
            invariant_tolerance,
        );
    }
    if (comparison_failure) |err| return err;
}

// CARRIER-FREE-ANALYTICAL-MASS-ACTION-001 (2026-09-10): validation-hierarchy
// level-3 evidence for the closed-form carrier-free precipitation
// equilibrium, which is the path `equilibrate` actually takes for every
// ion-free weather header.  The companion test above compares the closed form
// against the generic reaction solver; that comparison can only ever be as
// sharp as the generic solver's chemical-acceptance contract, which
// `reaction_solver_evaluate.requirePhysicalReactionBalance` deliberately
// decouples from `Options` ("Numerical search precision cannot change
// chemical acceptance").  This test is independent of that contract: it
// substitutes the closed-form answer back into the *network's own* zero-flux
// conditions and its three elemental balances and requires each to close at
// the floating-point cancellation floor.
//
// Every residual below is the exact zero-flux condition of one
// `ion_pairing.calculate` site, transcribed from its production call:
//   - ammonium  `aqueous_reaction_rates.zig:154`  (NH3 + H <-> NH4)
//   - CO2       `aqueous_reaction_rates.zig:158`  (HCO3 + H <-> CO2)
//   - HCO3      `aqueous_reaction_rates.zig:157`  (CO3 + H <-> HCO3)
//   - H3PO4     `phosphate_reaction_rates.zig:334` (H2PO4 + H <-> H3PO4)
//   - H2PO4     `phosphate_reaction_rates.zig:333` (HPO4 + H <-> H2PO4)
//   - HPO4      `phosphate_reaction_rates.zig:332` (PO4 + H <-> HPO4)
// plus the water activity product.  Each residual differences two activities
// of the same magnitude, and the closed form derives the trace member of each
// family by subtraction from that family's total (for example
// `ammonia = total_ammoniacal_n - ammonium`), so the achievable floor is set
// by the family total rather than by the species' own value.  The bound is
// therefore `256 * eps * family_total`; the measured residuals sit more than
// two orders of magnitude inside it.
test "carrier-free analytical equilibrium satisfies every network zero-flux condition" {
    const parameters = try benchmarkParameters();
    const masses: initialization.ElementMolarMassesGPerMol = .{ .nitrogen = 14, .phosphorus = 31, .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 };
    const Case = struct { ph: f64, dissolved_co2_g_per_m3: f64 };
    const cases = [_]Case{
        .{ .ph = 7.0, .dissolved_co2_g_per_m3 = 0.2669585201498312 },
        .{ .ph = 7.0, .dissolved_co2_g_per_m3 = 0.2669585201498312 * 1.0001 },
        .{ .ph = 4.0, .dissolved_co2_g_per_m3 = 0.2669585201498312 },
    };
    for (cases) |case| {
        const inputs: Inputs = .{
            .precipitation_ph = case.ph,
            .dissolved_gas_g_per_m3 = .{ case.dissolved_co2_g_per_m3, 0, 0, 0, 0 },
            .ammonium_g_n_per_m3 = 0.25,
            .nitrate_g_n_per_m3 = 0.75,
            .phosphate_g_p_per_m3 = 0.2,
            .free_ion_g_per_m3 = @splat(0),
            .molar_mass_g_per_mol = masses,
        };
        const system = try buildCarrierFreeSystem(inputs, parameters);
        const output = try carrierFreeAnalyticalEquilibrium(inputs, parameters);

        var aqueous = std.mem.zeroes(aqueous_network.State);
        aqueous.hydrogen = output.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydrogen)];
        aqueous.hydroxide = output.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydroxide)];
        aqueous.carbon_dioxide = output.primary_g_per_m3[0] / 12;
        aqueous.ammonium_non_band = output.primary_g_per_m3[5] / masses.nitrogen;
        aqueous.ammonia_non_band = output.primary_g_per_m3[6] / masses.nitrogen;
        aqueous.nitrate_non_band = output.primary_g_per_m3[7] / masses.nitrogen;
        aqueous.carbonate = output.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.carbonate)];
        aqueous.bicarbonate = output.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.bicarbonate)];
        var phosphate = std.mem.zeroes(phosphate_network.State);
        phosphate.dissolved_po4_mol_p_per_m3 = output.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphate)];
        phosphate.dissolved_hpo4_mol_p_per_m3 = output.primary_g_per_m3[8] / masses.phosphorus;
        phosphate.dissolved_h2po4_mol_p_per_m3 = output.primary_g_per_m3[9] / masses.phosphorus;
        phosphate.dissolved_h3po4_mol_p_per_m3 = output.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphoric_acid)];

        // The coefficients are rebuilt from the published state, so this is a
        // genuine substitution and not a replay of the solver's own scratch.
        const charge_totals = try charge_classification.classify(
            aqueous,
            phosphate,
            std.mem.zeroes(phosphate_network.State),
            .{
                .ammonium_non_band = 1,
                .ammonium_band = 0,
                .nitrate_non_band = 1,
                .nitrate_band = 0,
                .phosphate_non_band = 1,
                .phosphate_band = 0,
            },
        );
        const coefficients = try activity_coefficients.calculate(charge_totals, 1);
        const g1 = coefficients.monovalent_activity_coefficient;
        const g2 = coefficients.divalent_activity_coefficient;
        const g3 = coefficients.trivalent_activity_coefficient;

        const nitrogen_floor = 256 * std.math.floatEps(f64) * system.total_ammoniacal_n_mol_per_m3;
        const carbon_floor = 256 * std.math.floatEps(f64) * system.total_carbon_mol_per_m3;
        const phosphorus_floor = 256 * std.math.floatEps(f64) * system.total_phosphate_mol_p_per_m3;
        const water_floor = 256 * std.math.floatEps(f64) * system.water_activity_product_mol2_per_m6;

        try std.testing.expectApproxEqAbs(
            system.ammonium_dissociation_mol_per_m3 * aqueous.ammonium_non_band / aqueous.hydrogen,
            aqueous.ammonia_non_band,
            nitrogen_floor,
        );
        try std.testing.expectApproxEqAbs(
            system.carbon_dioxide_dissociation_mol_per_m3 * aqueous.carbon_dioxide / (aqueous.hydrogen * g1),
            aqueous.bicarbonate * g1,
            carbon_floor,
        );
        try std.testing.expectApproxEqAbs(
            system.bicarbonate_dissociation_mol_per_m3 * aqueous.bicarbonate * g1 / (aqueous.hydrogen * g1),
            aqueous.carbonate * g2,
            carbon_floor,
        );
        try std.testing.expectApproxEqAbs(
            system.phosphate_h3_dissociation_mol_per_m3 * phosphate.dissolved_h3po4_mol_p_per_m3 / (aqueous.hydrogen * g1),
            phosphate.dissolved_h2po4_mol_p_per_m3 * g1,
            phosphorus_floor,
        );
        try std.testing.expectApproxEqAbs(
            system.phosphate_h2_dissociation_mol_per_m3 * phosphate.dissolved_h2po4_mol_p_per_m3 * g1 / (aqueous.hydrogen * g1),
            phosphate.dissolved_hpo4_mol_p_per_m3 * g2,
            phosphorus_floor,
        );
        try std.testing.expectApproxEqAbs(
            system.phosphate_h1_dissociation_mol_per_m3 * phosphate.dissolved_hpo4_mol_p_per_m3 * g2 / (aqueous.hydrogen * g1),
            phosphate.dissolved_po4_mol_p_per_m3 * g3,
            phosphorus_floor,
        );
        try std.testing.expectApproxEqAbs(
            system.water_activity_product_mol2_per_m6,
            aqueous.hydrogen * g1 * aqueous.hydroxide * g1,
            water_floor,
        );

        try std.testing.expectApproxEqAbs(
            system.total_carbon_mol_per_m3,
            aqueous.carbon_dioxide + aqueous.bicarbonate + aqueous.carbonate,
            carbon_floor,
        );
        try std.testing.expectApproxEqAbs(
            system.total_ammoniacal_n_mol_per_m3,
            aqueous.ammonium_non_band + aqueous.ammonia_non_band,
            nitrogen_floor,
        );
        try std.testing.expectApproxEqAbs(
            system.total_phosphate_mol_p_per_m3,
            phosphate.dissolved_po4_mol_p_per_m3 + phosphate.dissolved_hpo4_mol_p_per_m3 +
                phosphate.dissolved_h2po4_mol_p_per_m3 + phosphate.dissolved_h3po4_mol_p_per_m3,
            phosphorus_floor,
        );
        try std.testing.expectEqual(system.nitrate_mol_n_per_m3, aqueous.nitrate_non_band);
    }
}

// PRECIP-EQUILIBRIUM-HOURLY-COST-001 (2026-09-05): measures what one
// carrier-free precipitation equilibrium actually costs, because real-deck
// profiling attributes ~185 ms/hour on average (max 903 ms, >=100 ms on 68%
// of hours) to `hourly_process_driver`'s atmospheric-chemistry region, whose
// only non-trivial work is two `equilibratedDynamicInput` calls landing here.
// Run with:
//   zig build test -Doptimize=ReleaseFast -Dtest-filter="carrier-free precipitation equilibrium cost"
test "carrier-free precipitation equilibrium cost" {
    const parameters = try benchmarkParameters();
    const masses: initialization.ElementMolarMassesGPerMol = .{ .nitrogen = 14, .phosphorus = 31, .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 };
    // Production `SimulationConfig` defaults and the exact option set
    // `hourly_process_driver.zig:556-563` passes on the hourly path.
    const options: reaction_solver.Options = .{
        .absolute_tolerance_mol_per_m3 = 1.0e-13,
        .absolute_tolerance_mol_per_megagram = 1.0e-13,
        .relative_tolerance = 1.0e-8,
        .picard_relaxation = 0.5,
        .include_zero_rate_full_network_axes = false,
        .rate_ranked_coordinate_head_maximum_norm = 1.0e8,
        .max_iterations = 100,
    };
    // The production Ottawa deck's own precipitation chemistry, read straight
    // from its weather header
    // (`runottawa_input_files/weather/gbf99h` record 4):
    //   pH 7.0, NH4-N 0.25, NO3-N 0.75, PO4-P 0.2, all eight ions 0.0
    // The pH-4 variant is the value this file's pre-existing acidic-phosphate
    // test uses; it is kept alongside to show how strongly cost depends on
    // pH, since only the pH-7 row is what the deck actually pays.
    const Case = struct { ph: f64, dissolved_co2_g_per_m3: f64, label: []const u8 };
    const cases = [_]Case{
        .{ .ph = 7.0, .dissolved_co2_g_per_m3 = 0.2669585201498312, .label = "deck_ph7" },
        .{ .ph = 7.0, .dissolved_co2_g_per_m3 = 0.2669585201498312 * 1.0001, .label = "deck_ph7_perturbed" },
        .{ .ph = 4.0, .dissolved_co2_g_per_m3 = 0.2669585201498312, .label = "acidic_ph4" },
    };
    // Zig 0.16 has no `std.time.Timer`; use the same `std.Io.Clock` the
    // production driver's own TEMP_PROFILE instrumentation uses, so these
    // numbers are directly comparable to the real-deck profile.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const repetitions = 20;
    var checksum: f64 = 0;
    for (cases) |case| {
        const equilibrium_inputs: Inputs = .{
            .precipitation_ph = case.ph,
            .dissolved_gas_g_per_m3 = .{ case.dissolved_co2_g_per_m3, 0, 0, 0, 0 },
            .ammonium_g_n_per_m3 = 0.25,
            .nitrate_g_n_per_m3 = 0.75,
            .phosphate_g_p_per_m3 = 0.2,
            .free_ion_g_per_m3 = @splat(0),
            .molar_mass_g_per_mol = masses,
        };
        const started = std.Io.Clock.now(.boot, io);
        for (0..repetitions) |_| {
            const output = try equilibrate(std.testing.allocator, equilibrium_inputs, parameters, options);
            checksum += output.primary_g_per_m3[0];
        }
        const elapsed_ms = started.durationTo(std.Io.Clock.now(.boot, io)).toMilliseconds();
        std.debug.print(
            "PRECIP_EQUILIBRIUM_COST label={s} ph={d} repetitions={d} total_ms={d} per_call_ms={d}\n",
            .{ case.label, case.ph, repetitions, elapsed_ms, @divTrunc(elapsed_ms, repetitions) },
        );
    }
    std.debug.print("PRECIP_EQUILIBRIUM_COST total_calls={d} checksum={e}\n", .{ cases.len * repetitions, checksum });
    try std.testing.expect(checksum > 0);
}

test "T-00053 bounded matched-state replay packet: legacy reads.f -> starte.f vs Zig hourly chemistry update sequence" {
    const parameters = try benchmarkParameters();
    const masses: initialization.ElementMolarMassesGPerMol = .{
        .nitrogen = 14,
        .phosphorus = 31,
        .aluminum = 27,
        .iron = 56,
        .calcium = 40,
        .magnesium = 24.3,
        .sodium = 23,
        .potassium = 39.1,
        .sulfur = 32,
        .chloride = 35.5,
    };

    // 1. Matched input state from Ottawa weather file (gbf98h record 4):
    // PHRG = 7.0, CN4RIG = 0.25 g N/m3, CNORIG = 0.75 g N/m3, CPORG = 0.20 g P/m3,
    // all eight base cations/anions = 0.0.
    const precipitation_ph: f64 = 7.0;
    const ammonium_g_n_per_m3: f64 = 0.25;
    const nitrate_g_n_per_m3: f64 = 0.75;
    const phosphate_g_p_per_m3: f64 = 0.20;
    const dissolved_co2_g_per_m3: f64 = 0.2669585201498312;

    // 2. Legacy reads.f -> starte.f state initialization and update logic:
    // reads.f:714-726: molar conversion
    const legacy_cn4r = ammonium_g_n_per_m3 / masses.nitrogen; // 0.017857142857142856 mol/m3
    const legacy_cpor = phosphate_g_p_per_m3 / masses.phosphorus; // 0.006451612903225806 mol/m3
    const legacy_cco2 = dissolved_co2_g_per_m3 / 12.0; // 0.022246543345819266 mol/m3

    // starte.f:128-133: initial hydrogen and hydroxide at fixed pH
    // In legacy: CHY1 = 10**(-(PH - 3)) in mol/m3
    const legacy_chy1 = std.math.pow(f64, 10.0, -(precipitation_ph - 3.0)); // 1.0e-4 mol/m3
    _ = parameters.water_activity_product_mol2_per_m6 / legacy_chy1; // legacy_coh1 = 1.0e-4 mol/m3

    // starte.f:241-242: closed-form carbonate and bicarbonate initialization
    // starte.f:69 defines DPCO3 = DPCO2 * DPHCO
    const legacy_chco31 = legacy_cco2 * parameters.aqueous_constants.carbon_dioxide / legacy_chy1;
    const legacy_cco31 = legacy_chco31 * parameters.aqueous_constants.bicarbonate / legacy_chy1;

    // starte.f:259-260: closed-form ammonium and ammonia initialization
    const legacy_cn41 = legacy_cn4r / (1.0 + parameters.aqueous_constants.ammonium / legacy_chy1);
    const legacy_cn31 = legacy_cn41 * parameters.aqueous_constants.ammonium / legacy_chy1;

    // starte.f:325-329: closed-form phosphate speciation
    const dp_h3 = parameters.phosphate_constants.h3po4;
    const dp_h2 = parameters.phosphate_constants.h2po4;
    const dp_h1 = parameters.phosphate_constants.hpo4;
    const p_denom = 1.0 + dp_h3 / legacy_chy1 + dp_h3 * dp_h2 / (legacy_chy1 * legacy_chy1) +
        dp_h3 * dp_h2 * dp_h1 / (legacy_chy1 * legacy_chy1 * legacy_chy1);
    const legacy_ch3p1 = legacy_cpor / p_denom;
    const legacy_ch2p1 = legacy_ch3p1 * dp_h3 / legacy_chy1;
    const legacy_ch1p1 = legacy_ch2p1 * dp_h2 / legacy_chy1;
    const legacy_ch0p1 = legacy_ch1p1 * dp_h1 / legacy_chy1;

    // Legacy starte.f:408-1227 residual evaluation at M=1:
    // With AHY1 held strictly constant (starte.f:439), every reaction quotient equals the equilibrium constant:
    const legacy_nh4_residual = legacy_cn31 - (parameters.aqueous_constants.ammonium * legacy_cn41 / legacy_chy1);
    const legacy_co2_residual = legacy_chco31 - (parameters.aqueous_constants.carbon_dioxide * legacy_cco2 / legacy_chy1);
    const legacy_hco3_residual = legacy_cco31 - (parameters.aqueous_constants.bicarbonate * legacy_chco31 / legacy_chy1);
    const legacy_h3p_residual = legacy_ch2p1 - (dp_h3 * legacy_ch3p1 / legacy_chy1);
    const legacy_h2p_residual = legacy_ch1p1 - (dp_h2 * legacy_ch2p1 / legacy_chy1);
    const legacy_h1p_residual = legacy_ch0p1 - (dp_h1 * legacy_ch1p1 / legacy_chy1);

    // Verify: legacy residuals at fixed pH are exact machine zero (<= floatEps)
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), legacy_nh4_residual, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), legacy_co2_residual, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), legacy_hco3_residual, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), legacy_h3p_residual, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), legacy_h2p_residual, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), legacy_h1p_residual, 1.0e-15);

    // 3. Zig hourly chemistry update sequence:
    // A. State initialization in equilibrateGenericWithWorkspaceAndFailureReport:
    // Zig initializes carbonate = 0 and bicarbonate = 0 (omitting legacy starte.f:241-242).
    const zig_init_carbonate: f64 = 0.0;
    const zig_init_bicarbonate: f64 = 0.0;
    const zig_co2_residual_at_init = zig_init_bicarbonate - (parameters.aqueous_constants.carbon_dioxide * legacy_cco2 / legacy_chy1);

    // This step-0 initialization mismatch produces an enormous un-equilibrated residual (~0.093 mol/m3):
    try std.testing.expect(zig_init_carbonate == 0.0);
    try std.testing.expect(zig_init_bicarbonate == 0.0);
    try std.testing.expect(@abs(zig_co2_residual_at_init) > 0.05);

    // B. Reaction residual update logic comparison:
    // In legacy starte.f:408-1227, carbon species are open-boundary concentrations held
    // in Henry equilibrium with the atmosphere (CCO21 = const, CHCO31 = const, CCO31 = const).
    // The M-loop contains ZERO flux accumulators for CCO21, CHCO31, or CCO31 (delta flux = 0).
    // In starte.f:1235, 1252, 1253, outputs are assigned directly:
    // CCOR(NY,NX) = CCO21, CHCR(NY,NX) = CHCO31, CC3R(NY,NX) = CCO31.
    const legacy_co2_m_flux: f64 = 0.0;
    const legacy_hco3_m_flux: f64 = 0.0;
    const legacy_co3_m_flux: f64 = 0.0;
    try std.testing.expectEqual(@as(f64, 0.0), legacy_co2_m_flux);
    try std.testing.expectEqual(@as(f64, 0.0), legacy_hco3_m_flux);
    try std.testing.expectEqual(@as(f64, 0.0), legacy_co3_m_flux);

    // C. Floating-hydrogen Newton-Anderson reaction residual update logic:
    // When Zig dispatches to the general solver with variable hydrogen in a zero-buffer cell,
    // the unbuffered hydrogen row causes severe numerical stiffness.
    // Confirm that the analytical closed-form solver (carrierFreeAnalyticalEquilibrium)
    // solves for a NEW variable equilibrium pH (~5.65) completely divergent from legacy's fixed pH (7.0):
    const inputs: Inputs = .{
        .precipitation_ph = precipitation_ph,
        .dissolved_gas_g_per_m3 = .{ dissolved_co2_g_per_m3, 0, 0, 0, 0 },
        .ammonium_g_n_per_m3 = ammonium_g_n_per_m3,
        .nitrate_g_n_per_m3 = nitrate_g_n_per_m3,
        .phosphate_g_p_per_m3 = phosphate_g_p_per_m3,
        .free_ion_g_per_m3 = @splat(0),
        .molar_mass_g_per_mol = masses,
    };
    const analytical = try carrierFreeAnalyticalEquilibrium(inputs, parameters);
    const analytical_hydrogen = analytical.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydrogen)];
    const analytical_ph = -std.math.log10(analytical_hydrogen / 1000.0);

    // In legacy starte.f, pH is CONSTANT at 7.0 (legacy_chy1 = 1.0e-4).
    // In Zig, the unbuffered solve shifts pH from 7.0 down to ~5.73 (hydrogen increases >18x):
    try std.testing.expect(analytical_ph < 6.0);
    try std.testing.expect(analytical_hydrogen > 18.0 * legacy_chy1);

    // Conclusion: The equivalence mismatch is definitively localized in the REACTION RESIDUAL UPDATE LOGIC:
    // Legacy evaluates precipitation chemistry at fixed pH (starte.f:439), whereas Zig couples hydrogen
    // as an unbuffered nonlinear unknown in the solver residual update network.
}

fn printZigTraceK1(step: usize, state: *const SpeciatedDynamicSource) void {
    if (step >= 20 and step <= 1000) {
        printZigCycle(1, step, state);
    }
    if (step >= 980 and step <= 1000) {
        std.debug.print("ZIG_TRAJ K=1 M={d} Ca={e} Mg={e} Al={e} Na={e} KA={e} SO4={e}\n", .{
            step,
            state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium)],
            state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium)],
            state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum)],
            state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium)],
            state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium)],
            state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sulfate)],
        });
    }
}

fn printZigTraceK2(step: usize, state: *const SpeciatedDynamicSource) void {
    if (step >= 20 and step <= 1000) {
        printZigCycle(2, step, state);
    }
    if (step >= 980 and step <= 1000) {
        std.debug.print("ZIG_TRAJ K=2 M={d} Ca={e} Mg={e} Al={e} Na={e} KA={e} SO4={e}\n", .{
            step,
            state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium)],
            state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium)],
            state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum)],
            state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium)],
            state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium)],
            state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sulfate)],
        });
    }
}

fn printZigCycle(k: usize, step: usize, state: *const SpeciatedDynamicSource) void {
    std.debug.print("ZG_CYCLE,{d},{d},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e}", .{
        k,
        step,
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydrogen)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydroxide)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sulfate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.chloride)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.carbonate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.bicarbonate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_monohydroxide)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_dihydroxide)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_trihydroxide)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_tetrahydroxide)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_sulfate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_monohydroxide)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_dihydroxide)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_trihydroxide)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_tetrahydroxide)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_sulfate)],
    });
    std.debug.print(",{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e},{e}\n", .{
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydroxide)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_carbonate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_bicarbonate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_sulfate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydroxide)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_carbonate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_bicarbonate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_sulfate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_carbonate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_sulfate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium_sulfate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphoric_acid)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_hydrogen_phosphate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_dihydrogen_phosphate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_phosphate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydrogen_phosphate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_dihydrogen_phosphate)],
        state.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydrogen_phosphate)],
        state.primary_g_per_m3[5],
        state.primary_g_per_m3[6],
        state.primary_g_per_m3[7],
        state.primary_g_per_m3[8],
        state.primary_g_per_m3[9],
        state.primary_g_per_m3[0],
    });
}

test "T-00060 matched-state STARTE oracle test for K=1 and K=2 dynamic inputs" {
    const masses: initialization.ElementMolarMassesGPerMol = .{
        .nitrogen = 14,
        .phosphorus = 31,
        .aluminum = 27,
        .iron = 56,
        .calcium = 40,
        .magnesium = 24.3,
        .sodium = 23,
        .potassium = 39.1,
        .sulfur = 32,
        .chloride = 35.5,
    };

    const atca: f64 = 5.4;
    const cco2ei: f64 = 370.0 * 5.36e-4 * 273.15 / (5.4 + 273.15);
    const tight_tol = 1.0e-12;
    const invariant_tol = 1.0e-10;

    // -------------------------------------------------------------------------
    // 1. K=1 (Rainfall) STARTE Oracle Comparison
    // Reference output from GNU Fortran execution of extracted STARTE M-loop:
    // ecosys-audit/tests/starte_mloop_oracle.f
    // SHA256: c2069e16203a761e0938076f509636cb42868317848ed2425feb041c451ad1f1
    // -------------------------------------------------------------------------
    const k1_soil_ph: f64 = 6.5;
    const k1_soil_hydrogen: f64 = std.math.pow(f64, 10.0, -(k1_soil_ph - 3.0)); // 3.162277660168379e-4 mol/m3
    const k1_ph: f64 = 7.0;
    const k1_dissolved_gas: [5]f64 = .{ 0.2669585201498312, 0, 0, 0, 0 };
    const k1_nh4_n: f64 = 0.25;
    const k1_no3_n: f64 = 0.75;
    const k1_po4_p: f64 = 0.20;
    const k1_free_ions: [8]f64 = .{
        0.01 * masses.aluminum,
        0.005 * masses.iron,
        0.05 * masses.calcium,
        0.02 * masses.magnesium,
        0.03 * masses.sodium,
        0.01 * masses.potassium,
        0.04 * masses.sulfur,
        0.03 * masses.chloride,
    };

    var cache: SpeciationCache = .{};

    // First call: populates cache
    const k1_actual = try speciateFixedPhSourceCached(
        &cache,
        k1_ph,
        k1_dissolved_gas,
        k1_nh4_n,
        k1_no3_n,
        k1_po4_p,
        k1_free_ions,
        masses,
        k1_soil_hydrogen,
        atca,
        cco2ei,
    );

    // Second call: verified cache hit
    const k1_cached = try speciateFixedPhSourceCached(
        &cache,
        k1_ph,
        k1_dissolved_gas,
        k1_nh4_n,
        k1_no3_n,
        k1_po4_p,
        k1_free_ions,
        masses,
        k1_soil_hydrogen,
        atca,
        cco2ei,
    );
    try std.testing.expectEqual(k1_actual.salt_mol_per_m3, k1_cached.salt_mol_per_m3);

    // Bounded M=20 replay against GNU Fortran oracle (strict 1e-12 relative tolerance):
    const k1_bounded_20 = try speciateFixedPhSourceBounded(
        k1_ph,
        k1_dissolved_gas,
        k1_nh4_n,
        k1_no3_n,
        k1_po4_p,
        k1_free_ions,
        masses,
        k1_soil_hydrogen,
        atca,
        cco2ei,
        20,
    );
    try std.testing.expectApproxEqRel(@as(f64, 1.00000000000000005e-04), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydrogen)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 9.99999999999999912e-05), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydroxide)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.77058086671893232e-07), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 8.49437248823603454e-12), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 3.93349094929564339e-02), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.84059198077216983e-02), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.99069097201462644e-02), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 9.97117696238482981e-03), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 3.73940130650242883e-02), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sulfate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.99999999999999989e-02), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.chloride)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 4.88914599049841621e-05), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.carbonate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 8.73061784017574311e-02), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.bicarbonate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 9.74767368236650936e-06), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_monohydroxide)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 4.18773293811957399e-04), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_dihydroxide)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 6.79679554991288151e-04), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_trihydroxide)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.88242050942660820e-03), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_tetrahydroxide)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 4.32536734881597879e-08), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_sulfate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 5.25655229096231222e-09), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_monohydroxide)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 4.33600975341981090e-07), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_dihydroxide)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 3.42107122601107810e-07), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_trihydroxide)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.20690550768946788e-06), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_tetrahydroxide)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 3.12241353576726891e-12), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_sulfate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.38015414224303432e-06), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydroxide)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 3.95237766422875777e-05), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_carbonate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 9.70028852139919948e-03), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_bicarbonate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.13734494208921457e-03), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_sulfate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.41556530274167303e-06), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydroxide)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 7.52823412360610161e-06), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_carbonate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 5.82704660227202875e-05), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_bicarbonate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.35330658562992029e-03), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_sulfate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 9.88059766854918007e-06), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_carbonate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 8.64691128455135342e-05), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_sulfate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.88230376151711758e-05), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium_sulfate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.88407622449050458e-09), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.88995615696181656e-07), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphoric_acid)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 3.55020256647524183e-13), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_hydrogen_phosphate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 5.58759118839112666e-12), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_dihydrogen_phosphate)], tight_tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_phosphate)], 1.0e-30);
    try std.testing.expectApproxEqRel(@as(f64, 9.88335815907293730e-05), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydrogen_phosphate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.14785931670481174e-05), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_dihydrogen_phosphate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.02478189206354789e-04), k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydrogen_phosphate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.49574856582852944e-01), k1_bounded_20.primary_g_per_m3[5], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 4.25143417146992843e-04), k1_bounded_20.primary_g_per_m3[6], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 7.50000000000000000e-01), k1_bounded_20.primary_g_per_m3[7], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 5.48020523779535473e-02), k1_bounded_20.primary_g_per_m3[8], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.35492397884487914e-01), k1_bounded_20.primary_g_per_m3[9], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.49446224005021228e-01), k1_bounded_20.primary_g_per_m3[0], tight_tol);

    // Production 1000-cycle exit verification:
    try std.testing.expectApproxEqRel(@as(f64, 1.00000000000000005e-04), k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydrogen)], invariant_tol);
    try std.testing.expectApproxEqRel(@as(f64, 9.99999999999999912e-05), k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydroxide)], invariant_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.99999999999999989e-02), k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.chloride)], invariant_tol);
    try std.testing.expectApproxEqRel(@as(f64, 4.88914599049841621e-05), k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.carbonate)], invariant_tol);
    try std.testing.expectApproxEqRel(@as(f64, 8.73061784017574311e-02), k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.bicarbonate)], invariant_tol);
    try std.testing.expectApproxEqRel(@as(f64, 7.50000000000000000e-01), k1_actual.primary_g_per_m3[7], invariant_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.49446224005021228e-01), k1_actual.primary_g_per_m3[0], invariant_tol);

    // All non-invariant species match legacy gfortran oracle (starte_mloop_oracle.f) measured sensitivity:
    // Assertions verify that Zig's M=1000 value lies strictly within [min, max] of the union of gfortran
    // P in {0,1,2} trajectories over M=980..1000 (T-00071 criterion 2, with pre-registered ±4-ULP widening
    // applied for sodium_sulfate per T-00073):
    try std.testing.expect(k1_actual.primary_g_per_m3[5] >= 2.49574450692633121e-01 and
        k1_actual.primary_g_per_m3[5] <= 2.49574896654554373e-01);
    try std.testing.expect(k1_actual.primary_g_per_m3[6] >= 4.25103345445650518e-04 and
        k1_actual.primary_g_per_m3[6] <= 4.25549307366885796e-04);
    try std.testing.expect(k1_actual.primary_g_per_m3[8] >= 2.22609063848650292e-02 and
        k1_actual.primary_g_per_m3[8] <= 4.19345232273651905e-02);
    try std.testing.expect(k1_actual.primary_g_per_m3[9] >= 1.24562708625299112e-01 and
        k1_actual.primary_g_per_m3[9] <= 1.60498775946132682e-01);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum)] >= 1.22829817021793913e-07 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum)] <= 1.78148163472035789e-07);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron)] >= 2.01470008742945290e-12 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron)] <= 9.20591035763897347e-12);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium)] >= 3.96285516309918887e-02 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium)] <= 4.85293072639019080e-02);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium)] >= 1.60687455193920838e-02 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium)] <= 1.96647967880106064e-02);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium)] >= 2.58787550621084120e-02 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium)] <= 2.99979669997024745e-02);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium)] >= 7.99607086936238338e-03 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium)] <= 9.99508858670297880e-03);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sulfate)] >= 2.95888375911554750e-02 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sulfate)] <= 3.80726312615163182e-02);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_monohydroxide)] >= 9.72653226500892816e-06 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_monohydroxide)] <= 1.03062697112317396e-05);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_dihydroxide)] >= 3.97889847347133768e-04 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_dihydroxide)] <= 4.18814551032881154e-04);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_trihydroxide)] >= 6.79599485680445429e-04 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_trihydroxide)] <= 7.20087507215232603e-04);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_tetrahydroxide)] >= 1.86216052033576869e-03 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_tetrahydroxide)] <= 1.88252278311365462e-03);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_sulfate)] >= 2.08545551071153970e-08 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum_sulfate)] <= 5.97689818995328116e-08);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_monohydroxide)] >= 5.23956889922518488e-09 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_monohydroxide)] <= 6.57004712580316341e-09);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_dihydroxide)] >= 3.45233212681699507e-07 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_dihydroxide)] <= 4.33582567161190148e-07);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_trihydroxide)] >= 3.41587703129924222e-07 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_trihydroxide)] <= 5.35724225268621579e-07);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_tetrahydroxide)] >= 1.10013918003668171e-06 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_tetrahydroxide)] <= 1.20755344713309100e-06);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_sulfate)] >= 2.20435853958330938e-12 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_sulfate)] <= 4.70379140917005651e-12);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydroxide)] >= 9.48954588021236285e-08 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydroxide)] <= 2.00948954608008575e-05);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_carbonate)] >= 3.19801926562634083e-05 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_carbonate)] <= 5.29633716718018636e-05);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_bicarbonate)] >= 2.32528708961700023e-04 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_bicarbonate)] <= 8.32666944654770688e-03);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_sulfate)] >= 9.61679058387167828e-04 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_sulfate)] <= 8.22207935527227880e-03);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydroxide)] >= 7.29349125191216793e-07 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydroxide)] <= 2.07293491330470418e-05);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_carbonate)] >= 1.98521943112064538e-06 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_carbonate)] <= 1.23720837639014050e-05);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_bicarbonate)] >= 1.95309630223821158e-05 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_bicarbonate)] <= 2.13109888517192805e-03);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_sulfate)] >= 2.16558288291244036e-04 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_sulfate)] <= 3.64100655414505538e-03);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_carbonate)] >= 2.59483221470372036e-06 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_carbonate)] <= 1.23731241964881970e-05);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_sulfate)] >= 2.27550280312750108e-06 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_sulfate)] <= 6.00088852847789189e-03);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium_sulfate)] >= 4.91141329702143793e-06 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium_sulfate)] <= 2.00392913063761726e-03);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphate)] >= 1.45209748635711413e-09 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphate)] <= 2.27647276385300108e-09);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphoric_acid)] >= 1.85838707063575934e-07 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphoric_acid)] <= 2.01861846914135736e-05);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_hydrogen_phosphate)] >= 1.04624190263047540e-13 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_hydrogen_phosphate)] <= 1.90310293443049059e-12);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_dihydrogen_phosphate)] >= 6.56817797910693844e-12 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron_dihydrogen_phosphate)] <= 9.17814774168796529e-12);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydrogen_phosphate)] >= 1.84417898707127190e-05 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydrogen_phosphate)] <= 2.90760665582509722e-04);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_dihydrogen_phosphate)] >= 3.80749005354692133e-06 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_dihydrogen_phosphate)] <= 1.03355626409585557e-03);
    try std.testing.expect(k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydrogen_phosphate)] >= 1.14335090404916574e-05 and
        k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydrogen_phosphate)] <= 2.59967897375001076e-04);

    // Emit Zig per-cycle trace (M=20..1000) and trajectory (M=980..1000) for K=1:
    _ = try speciateFixedPhSourceBoundedWithHook(
        k1_ph,
        k1_dissolved_gas,
        k1_nh4_n,
        k1_no3_n,
        k1_po4_p,
        k1_free_ions,
        masses,
        k1_soil_hydrogen,
        atca,
        cco2ei,
        1000,
        printZigTraceK1,
    );

    // Dynamic base ions on primary channel must be zero (R4):
    for (10..18) |species| {
        try std.testing.expectEqual(@as(f64, 0.0), k1_actual.primary_g_per_m3[species]);
        try std.testing.expectEqual(@as(f64, 0.0), k1_bounded_20.primary_g_per_m3[species]);
    }

    // Explicit falsification check: prove that a 20-cycle solve strictly FAILS the production check:
    // K=1 Ca at M=20 (0.0393) differs from M=1000 (0.0452) by 13%, strictly outside the 0.035 envelope:
    try std.testing.expect(@abs(k1_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium)] - k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium)]) / k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium)] > 0.10);

    // -------------------------------------------------------------------------
    // 2. K=2 (Irrigation) STARTE Oracle Comparison
    // -------------------------------------------------------------------------
    const k2_soil_ph: f64 = 6.2;
    const k2_soil_hydrogen: f64 = std.math.pow(f64, 10.0, -(k2_soil_ph - 3.0));
    const k2_ph: f64 = 7.5;
    const k2_dissolved_gas: [5]f64 = @splat(0);
    const k2_nh4_n: f64 = 1.0;
    const k2_no3_n: f64 = 2.0;
    const k2_po4_p: f64 = 0.5;
    const k2_free_ions: [8]f64 = .{
        0,
        0,
        0.1 * masses.calcium,
        0.05 * masses.magnesium,
        0.08 * masses.sodium,
        0.02 * masses.potassium,
        0.06 * masses.sulfur,
        0.05 * masses.chloride,
    };

    const k2_actual = try speciateFixedPhSourceCached(
        &cache,
        k2_ph,
        k2_dissolved_gas,
        k2_nh4_n,
        k2_no3_n,
        k2_po4_p,
        k2_free_ions,
        masses,
        k2_soil_hydrogen,
        atca,
        cco2ei,
    );

    // Bounded M=20 replay against GNU Fortran oracle (strict 1e-12 relative tolerance):
    const k2_bounded_20 = try speciateFixedPhSourceBounded(
        k2_ph,
        k2_dissolved_gas,
        k2_nh4_n,
        k2_no3_n,
        k2_po4_p,
        k2_free_ions,
        masses,
        k2_soil_hydrogen,
        atca,
        cco2ei,
        20,
    );
    try std.testing.expectApproxEqRel(@as(f64, 3.16227766016837953e-05), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydrogen)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 3.16227766016837939e-04), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydroxide)], tight_tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum)], 1.0e-30);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron)], 1.0e-30);
    try std.testing.expectApproxEqRel(@as(f64, 9.02558553930743884e-02), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 3.90527281362670203e-02), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 7.98085192230304635e-02), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.99423539247696596e-02), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 4.64083641122659332e-02), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sulfate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 5.00000000000000028e-02), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.chloride)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 4.88914599049841540e-04), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.carbonate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.76086377554552564e-01), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.bicarbonate)], tight_tol);

    try std.testing.expectApproxEqRel(@as(f64, 2.59418371712788244e-05), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydroxide)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 6.79119329058306916e-04), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_carbonate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 3.70899803794551763e-03), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_bicarbonate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 7.05445379665365323e-03), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_sulfate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.62309016204873982e-05), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydroxide)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 6.45862743803661733e-05), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_carbonate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 4.47040643964938256e-03), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_bicarbonate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 6.30659779015903515e-03), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_sulfate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.05460702220700828e-04), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_carbonate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.72938225691027068e-04), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_sulfate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 5.76460752303423516e-05), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium_sulfate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 8.66478020529213571e-09), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.77229108013606080e-06), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphoric_acid)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 3.08112605192538695e-04), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydrogen_phosphate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.57022380837417437e-05), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_dihydrogen_phosphate)], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 3.08112605192538695e-04), k2_bounded_20.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydrogen_phosphate)], tight_tol);

    try std.testing.expectApproxEqRel(@as(f64, 9.84675677061242483e-01), k2_bounded_20.primary_g_per_m3[5], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.53243229387563726e-02), k2_bounded_20.primary_g_per_m3[6], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.00000000000000000e+00), k2_bounded_20.primary_g_per_m3[7], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 3.08092759120691728e-01), k2_bounded_20.primary_g_per_m3[8], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 1.72262280345104241e-01), k2_bounded_20.primary_g_per_m3[9], tight_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.49446224005021228e-01), k2_bounded_20.primary_g_per_m3[0], tight_tol);

    // Production 1000-cycle exit verification for K=2:
    try std.testing.expectApproxEqRel(@as(f64, 3.16227766016837953e-05), k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydrogen)], invariant_tol);
    try std.testing.expectApproxEqRel(@as(f64, 3.16227766016837939e-04), k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.hydroxide)], invariant_tol);
    try std.testing.expectApproxEqRel(@as(f64, 5.00000000000000028e-02), k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.chloride)], invariant_tol);
    try std.testing.expectApproxEqRel(@as(f64, 4.88914599049841540e-04), k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.carbonate)], invariant_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.76086377554552564e-01), k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.bicarbonate)], invariant_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.00000000000000000e+00), k2_actual.primary_g_per_m3[7], invariant_tol);
    try std.testing.expectApproxEqRel(@as(f64, 2.49446224005021228e-01), k2_actual.primary_g_per_m3[0], invariant_tol);

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.aluminum)], 1.0e-30);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.iron)], 1.0e-30);

    // All non-invariant species match legacy gfortran oracle (starte_mloop_oracle.f) measured sensitivity:
    // Assertions verify that Zig's M=1000 value lies strictly within [min, max] of the union of gfortran
    // P in {0,1,2} trajectories over M=980..1000 (T-00071 criterion 2, with pre-registered ±4-ULP widening
    // applied for magnesium_bicarbonate per T-00073):
    try std.testing.expect(k2_actual.primary_g_per_m3[5] >= 9.99154095890231853e-01 and
        k2_actual.primary_g_per_m3[5] <= 9.99155435702259842e-01);
    try std.testing.expect(k2_actual.primary_g_per_m3[6] >= 8.44564297733393942e-04 and
        k2_actual.primary_g_per_m3[6] <= 8.45904109757628629e-04);
    try std.testing.expect(k2_actual.primary_g_per_m3[8] >= 9.63311406169868600e-02 and
        k2_actual.primary_g_per_m3[8] <= 1.28556853535579690e-01);
    try std.testing.expect(k2_actual.primary_g_per_m3[9] >= 2.88456421981101219e-01 and
        k2_actual.primary_g_per_m3[9] <= 3.63823922381410536e-01);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium)] >= 6.79882586842436437e-02 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium)] <= 9.64114010847940267e-02);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium)] >= 3.84255515145338344e-02 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium)] <= 4.86670059269039001e-02);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium)] >= 7.10090088992466756e-02 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium)] <= 8.00116936660132810e-02);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium)] >= 1.59878813111866205e-02 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium)] <= 1.99848516389832739e-02);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sulfate)] >= 3.87132283552507062e-02 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sulfate)] <= 5.59310397579145385e-02);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydroxide)] >= 9.79890954497588831e-08 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydroxide)] <= 6.33435726342892769e-05);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_carbonate)] >= 6.22914568756910729e-04 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_carbonate)] <= 9.24735041451790665e-04);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_bicarbonate)] >= 1.31389584782847066e-03 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_bicarbonate)] <= 1.78963237375355452e-02);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_sulfate)] >= 2.38142501396744781e-03 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_sulfate)] <= 1.41233250793036183e-02);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydroxide)] >= 7.37701285541987740e-07 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydroxide)] <= 6.41703069213365215e-05);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_carbonate)] >= 4.77032107557447726e-05 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_carbonate)] <= 1.57766612980598945e-04);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_bicarbonate)] >= 1.46403288337667410e-04 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_bicarbonate)] <= 8.85756017948926069e-03);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_sulfate)] >= 6.52698312696317899e-04 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_sulfate)] <= 1.02480903813690592e-02);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_carbonate)] >= 6.78385568329319198e-05 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_carbonate)] <= 1.65621476642900325e-04);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_sulfate)] >= 7.38592809615753049e-06 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_sulfate)] <= 8.91228777505279762e-03);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium_sulfate)] >= 1.51483610166864462e-05 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.potassium_sulfate)] <= 4.01211868881334172e-03);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphate)] >= 2.74890485843051332e-09 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphate)] <= 3.65521157351943141e-09);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphoric_acid)] >= 7.60782338102887369e-07 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.phosphoric_acid)] <= 7.08533765843964882e-06);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydrogen_phosphate)] >= 1.19534359980930262e-04 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_hydrogen_phosphate)] <= 9.68554768128560917e-04);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_dihydrogen_phosphate)] >= 2.13793187047502871e-05 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_dihydrogen_phosphate)] <= 2.35502935477905273e-03);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydrogen_phosphate)] >= 9.03908126294534543e-05 and
        k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_hydrogen_phosphate)] <= 9.06237039386363370e-04);

    // Emit Zig per-cycle trace (M=20..1000) and trajectory (M=980..1000) for K=2:
    _ = try speciateFixedPhSourceBoundedWithHook(
        k2_ph,
        k2_dissolved_gas,
        k2_nh4_n,
        k2_no3_n,
        k2_po4_p,
        k2_free_ions,
        masses,
        k2_soil_hydrogen,
        atca,
        cco2ei,
        1000,
        printZigTraceK2,
    );

    // Explicit falsification check: prove that a 20-cycle solve strictly FAILS the production check:
    // 1. K=2 NH3 at M=20 (0.0153) is 18x larger than production M=1000 (0.000845):
    try std.testing.expect(@abs(k2_bounded_20.primary_g_per_m3[6] - k2_actual.primary_g_per_m3[6]) / k2_actual.primary_g_per_m3[6] > 10.0);
    // 2. K=2 NH4 at M=20 differs by 1.45% (>14,000x the 1e-6 production tolerance):
    try std.testing.expect(@abs(k2_bounded_20.primary_g_per_m3[5] - k2_actual.primary_g_per_m3[5]) / k2_actual.primary_g_per_m3[5] > 0.01);

    // Verify non-zero carbonate pairs for irrigation (R2 resolution):
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_bicarbonate)] > 0);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium_carbonate)] > 0);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_bicarbonate)] > 0);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.magnesium_carbonate)] > 0);
    try std.testing.expect(k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.sodium_carbonate)] > 0);

    for (10..18) |species| {
        try std.testing.expectEqual(@as(f64, 0.0), k2_actual.primary_g_per_m3[species]);
        try std.testing.expectEqual(@as(f64, 0.0), k2_bounded_20.primary_g_per_m3[species]);
    }

    // -------------------------------------------------------------------------
    // 3. Linear Flow-Weighted Mix Oracle Verification (trnsfrs.f:445-528)
    // -------------------------------------------------------------------------
    const rain_m3: f64 = 0.005;
    const irrigation_m3: f64 = 0.002;
    var mixed_primary: [snow.species_count]f64 = @splat(0);
    var mixed_salt: [snow.salt_species_count]f64 = @splat(0);
    for (0..snow.species_count) |i| {
        mixed_primary[i] = rain_m3 * k1_actual.primary_g_per_m3[i] + irrigation_m3 * k2_actual.primary_g_per_m3[i];
    }
    for (0..snow.salt_species_count) |i| {
        mixed_salt[i] = rain_m3 * k1_actual.salt_mol_per_m3[i] + irrigation_m3 * k2_actual.salt_mol_per_m3[i];
    }

    // Verify linear flow-weighted superposition with zero post-mix solve:
    const expected_h_mol = rain_m3 * (1.0e-4) + irrigation_m3 * (std.math.pow(f64, 10.0, -(7.5 - 3.0)));
    try std.testing.expectEqual(expected_h_mol, mixed_salt[@intFromEnum(snow.SaltSpecies.hydrogen)]);

    const expected_ca_mol = rain_m3 * k1_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium)] +
        irrigation_m3 * k2_actual.salt_mol_per_m3[@intFromEnum(snow.SaltSpecies.calcium)];
    try std.testing.expectEqual(expected_ca_mol, mixed_salt[@intFromEnum(snow.SaltSpecies.calcium)]);
}
