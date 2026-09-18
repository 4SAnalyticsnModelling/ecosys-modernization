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
