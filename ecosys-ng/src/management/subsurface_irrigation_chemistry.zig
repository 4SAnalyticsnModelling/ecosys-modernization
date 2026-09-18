const std = @import("std");
const routing = @import("irrigation_layer_routing.zig");
const aqueous_transport = @import("../soil/solute/transport.zig");
const aqueous_species = @import("../soil/solute/transport_species.zig");
const chemistry = @import("../soil/solute/chemistry_state.zig");
const mineral_nitrogen = @import("../soil/biogeochemistry/mineral_nitrogen_transport.zig");
const nutrient_speciation = @import("../chemistry/precipitation_nutrient_speciation.zig");
const aqueous_rates = @import("../soil/solute/aqueous_reaction_rates.zig");
const phosphate_rates = @import("../soil/solute/phosphate_reaction_rates.zig");
const ZoneFractions = @import("../soil/solute/charge_classification.zig").ZoneFractions;

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

pub const EquilibriumConstants = struct {
    aqueous: aqueous_rates.EquilibriumConstants,
    phosphate: phosphate_rates.EquilibriumConstants,
};

pub const Parameters = struct {
    molar_mass_g_per_mol: ElementMolarMassesGPerMol,
    equilibrium: ?EquilibriumConstants,
    ammonium_band_fraction: f64,
    nitrate_band_fraction: f64,
    phosphate_band_fraction: f64,
};

pub const BoundaryInput = struct {
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
    /// Compatibility aggregate for the landscape EXEC ledger. It includes
    /// free hydrogen plus all eight salt-system element amounts below.
    ion_mol: f64 = 0,
    aluminum_mol: f64 = 0,
    iron_mol: f64 = 0,
    calcium_mol: f64 = 0,
    magnesium_mol: f64 = 0,
    sodium_mol: f64 = 0,
    potassium_mol: f64 = 0,
    sulfur_mol: f64 = 0,
    chloride_mol: f64 = 0,
};

/// Adds free hydrogen and the eight irrigation salt carriers to the selected
/// runtime soil layers before the same-hour 50-species aqueous solve.
pub fn addTransportedIons(
    loads: *const routing.Loads,
    transport: *aqueous_transport.State,
    parameters: Parameters,
) !void {
    return addTransportedIonsFraction(loads, transport, parameters, 1);
}

pub fn addTransportedIonsFraction(
    loads: *const routing.Loads,
    transport: *aqueous_transport.State,
    parameters: Parameters,
    step_fraction: f64,
) !void {
    try validate(loads, transport.cell_count, parameters);
    try validateStepFraction(step_fraction);
    if (transport.species_count != aqueous_species.AqueousSpecies.count)
        return error.SubsurfaceIrrigationTransportDimensionMismatch;

    for (0..loads.subsurface_water_m3.len) |layer| {
        const first = layer * routing.dissolved_species_count;
        const mass = loads.subsurface_dissolved_mass_g[first..][0..routing.dissolved_species_count];
        const additions = ionAdditions(
            loads.subsurface_hydrogen_mol[layer],
            mass,
            parameters.molar_mass_g_per_mol,
        );
        inline for (transported_ion_species, additions) |species, addition| {
            const destination = layer * aqueous_species.AqueousSpecies.count +
                aqueous_species.index(species);
            const candidate = transport.amount_mol[destination] + addition * step_fraction;
            if (!std.math.isFinite(candidate) or candidate < 0)
                return error.InvalidSubsurfaceIrrigationChemistryTransaction;
        }
    }
    for (0..loads.subsurface_water_m3.len) |layer| {
        const first = layer * routing.dissolved_species_count;
        const additions = ionAdditions(
            loads.subsurface_hydrogen_mol[layer],
            loads.subsurface_dissolved_mass_g[first..][0..routing.dissolved_species_count],
            parameters.molar_mass_g_per_mol,
        );
        inline for (transported_ion_species, additions) |species, addition|
            transport.amount_mol[
                layer * aqueous_species.AqueousSpecies.count +
                    aqueous_species.index(species)
            ] += addition * step_fraction;
    }
}

/// HPO4 and H2PO4 occupy the four appended owners in the canonical 54-carrier
/// vector. The hourly caller synchronizes these concentration changes into
/// zone-extensive transport amounts immediately after this update.
pub fn addPhosphate(
    loads: *const routing.Loads,
    state: *chemistry.State,
    matrix_water_volume_m3: []const f64,
    parameters: Parameters,
) !void {
    return addPhosphateFraction(loads, state, matrix_water_volume_m3, parameters, 1);
}

pub fn addPhosphateFraction(
    loads: *const routing.Loads,
    state: *chemistry.State,
    matrix_water_volume_m3: []const f64,
    parameters: Parameters,
    step_fraction: f64,
) !void {
    return addPhosphateFractionWithZones(loads, state, matrix_water_volume_m3, parameters, parameterZoneFractions(parameters), step_fraction);
}

pub fn addPhosphateFractionWithZones(
    loads: *const routing.Loads,
    state: *chemistry.State,
    matrix_water_volume_m3: []const f64,
    parameters: Parameters,
    fractions_source: anytype,
    step_fraction: f64,
) !void {
    try validate(loads, state.cell_count, parameters);
    try validateStepFraction(step_fraction);
    if (matrix_water_volume_m3.len != state.cell_count)
        return error.SubsurfaceIrrigationChemistryDimensionMismatch;
    for (0..state.cell_count) |layer| {
        const fractions = try irrigationFractionsAt(fractions_source, layer);
        const species = try layerNutrients(loads, layer, parameters);
        const phosphorus_mol = (species[3] + species[4]) * step_fraction;
        const water_m3 = matrix_water_volume_m3[layer];
        if (!std.math.isFinite(water_m3) or water_m3 < 0 or
            (phosphorus_mol > 0 and water_m3 == 0))
            return error.InvalidSubsurfaceIrrigationChemistryWater;
        if (phosphorus_mol == 0) continue;
        inline for (.{
            state.non_band_phosphate[layer].dissolved_hpo4_mol_p_per_m3 +
                (if (fractions.phosphate_non_band > 0) species[3] * step_fraction / water_m3 else 0),
            state.non_band_phosphate[layer].dissolved_h2po4_mol_p_per_m3 +
                (if (fractions.phosphate_non_band > 0) species[4] * step_fraction / water_m3 else 0),
            state.band_phosphate[layer].dissolved_hpo4_mol_p_per_m3 +
                (if (fractions.phosphate_band > 0) species[3] * step_fraction / water_m3 else 0),
            state.band_phosphate[layer].dissolved_h2po4_mol_p_per_m3 +
                (if (fractions.phosphate_band > 0) species[4] * step_fraction / water_m3 else 0),
        }) |candidate| if (!std.math.isFinite(candidate) or candidate < 0)
            return error.InvalidSubsurfaceIrrigationChemistryTransaction;
    }
    for (0..state.cell_count) |layer| {
        const fractions = try irrigationFractionsAt(fractions_source, layer);
        const species = try layerNutrients(loads, layer, parameters);
        if ((species[3] + species[4]) * step_fraction == 0) continue;
        const water_m3 = matrix_water_volume_m3[layer];
        if (fractions.phosphate_non_band > 0) {
            state.non_band_phosphate[layer].dissolved_hpo4_mol_p_per_m3 += species[3] * step_fraction / water_m3;
            state.non_band_phosphate[layer].dissolved_h2po4_mol_p_per_m3 += species[4] * step_fraction / water_m3;
        }
        if (fractions.phosphate_band > 0) {
            state.band_phosphate[layer].dissolved_hpo4_mol_p_per_m3 += species[3] * step_fraction / water_m3;
            state.band_phosphate[layer].dissolved_h2po4_mol_p_per_m3 += species[4] * step_fraction / water_m3;
        }
    }
}

/// Adds NH4, NH3, and NO3 amounts after the reaction concentrations have been
/// imported into the mineral-N transport owner and before its same-hour solve.
pub fn addMineralNitrogen(
    loads: *const routing.Loads,
    state: *mineral_nitrogen.State,
    parameters: Parameters,
) !void {
    return addMineralNitrogenFraction(loads, state, parameters, 1);
}

pub fn addMineralNitrogenFraction(
    loads: *const routing.Loads,
    state: *mineral_nitrogen.State,
    parameters: Parameters,
    step_fraction: f64,
) !void {
    return addMineralNitrogenFractionWithZones(loads, state, parameters, parameterZoneFractions(parameters), step_fraction);
}

pub fn addMineralNitrogenFractionWithZones(
    loads: *const routing.Loads,
    state: *mineral_nitrogen.State,
    parameters: Parameters,
    fractions_source: anytype,
    step_fraction: f64,
) !void {
    try validate(loads, state.cell_count, parameters);
    try validateStepFraction(step_fraction);
    if (state.matrix.species_count != mineral_nitrogen.species_count)
        return error.SubsurfaceIrrigationMineralNitrogenDimensionMismatch;
    for (0..state.cell_count) |layer| {
        const fractions = try irrigationFractionsAt(fractions_source, layer);
        const species = try layerNutrients(loads, layer, parameters);
        const additions = nitrogenAdditions(species, fractions);
        for (additions, 0..) |addition, component| {
            const candidate = state.matrix.amount_mol[
                layer * mineral_nitrogen.species_count + component
            ] + addition * step_fraction;
            if (!std.math.isFinite(candidate) or candidate < 0)
                return error.InvalidSubsurfaceIrrigationChemistryTransaction;
        }
    }
    for (0..state.cell_count) |layer| {
        const fractions = try irrigationFractionsAt(fractions_source, layer);
        const additions = nitrogenAdditions(
            try layerNutrients(loads, layer, parameters),
            fractions,
        );
        for (additions, 0..) |addition, component|
            state.matrix.amount_mol[
                layer * mineral_nitrogen.species_count + component
            ] += addition * step_fraction;
    }
}

fn validateStepFraction(step_fraction: f64) !void {
    if (!std.math.isFinite(step_fraction) or step_fraction <= 0 or step_fraction > 1)
        return error.InvalidSubsurfaceIrrigationStepFraction;
}

/// Exact extensive boundary input corresponding to the state_updateted subsurface
/// irrigation carriers. REDIST keeps aqueous N and P in their own balances;
/// its `SBU` ion boundary contains free H and the salt-system carriers only.
pub fn boundaryInput(
    loads: *const routing.Loads,
    parameters: Parameters,
) !BoundaryInput {
    try validate(loads, loads.subsurface_water_m3.len, parameters);
    var result: BoundaryInput = .{};
    for (0..loads.cell_count) |cell|
        result = try addBoundaryInput(result, try boundaryInputForCell(loads, cell, parameters));
    return result;
}

/// Publishes exact cell-resolved chemistry inputs without allocating or
/// distributing a landscape scalar. The full destination is preflighted in a
/// first pass, so an invalid late cell leaves caller storage unchanged.
pub fn boundaryInputByCell(
    result_by_cell: []BoundaryInput,
    loads: *const routing.Loads,
    parameters: Parameters,
) !void {
    try validate(loads, loads.subsurface_water_m3.len, parameters);
    if (result_by_cell.len != loads.cell_count)
        return error.SubsurfaceIrrigationChemistryDimensionMismatch;
    for (0..loads.cell_count) |cell|
        _ = try boundaryInputForCell(loads, cell, parameters);
    for (result_by_cell, 0..) |*result, cell|
        result.* = try boundaryInputForCell(loads, cell, parameters);
}

fn boundaryInputForCell(
    loads: *const routing.Loads,
    cell: usize,
    parameters: Parameters,
) !BoundaryInput {
    if (cell >= loads.cell_count) return error.SubsurfaceIrrigationChemistryDimensionMismatch;
    var result: BoundaryInput = .{};
    const first_layer = cell * loads.soil_layer_capacity;
    for (0..loads.soil_layer_capacity) |local_layer| {
        const layer = first_layer + local_layer;
        const first = layer * routing.dissolved_species_count;
        const mass = loads.subsurface_dissolved_mass_g[first..][0..routing.dissolved_species_count];
        const ions = ionAdditions(
            loads.subsurface_hydrogen_mol[layer],
            mass,
            parameters.molar_mass_g_per_mol,
        );
        result = try addBoundaryInput(result, .{
            .nitrogen_g_n = mass[0] + mass[1],
            .phosphorus_g_p = mass[2],
            .ion_mol = sumFinite(ions) catch return error.InvalidSubsurfaceIrrigationChemistryTransaction,
            .aluminum_mol = ions[1],
            .iron_mol = ions[2],
            .calcium_mol = ions[3],
            .magnesium_mol = ions[4],
            .sodium_mol = ions[5],
            .potassium_mol = ions[6],
            .sulfur_mol = ions[7],
            .chloride_mol = ions[8],
        });
    }
    return result;
}

fn addBoundaryInput(left: BoundaryInput, right: BoundaryInput) !BoundaryInput {
    var result = left;
    inline for (std.meta.fields(BoundaryInput)) |field| {
        const value = @field(left, field.name) + @field(right, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSubsurfaceIrrigationChemistryTransaction;
        @field(result, field.name) = value;
    }
    return result;
}

fn sumFinite(values: anytype) !f64 {
    var result: f64 = 0;
    for (values) |value| {
        result += value;
        if (!std.math.isFinite(result) or result < 0)
            return error.InvalidSubsurfaceIrrigationChemistryTransaction;
    }
    return result;
}

const transported_ion_species = [_]aqueous_species.AqueousSpecies{
    .hydrogen, .aluminum,  .iron,    .calcium,  .magnesium,
    .sodium,   .potassium, .sulfate, .chloride,
};

fn ionAdditions(
    hydrogen_mol: f64,
    mass_g: []const f64,
    molar_mass: ElementMolarMassesGPerMol,
) [transported_ion_species.len]f64 {
    return .{
        hydrogen_mol,
        mass_g[3] / molar_mass.aluminum,
        mass_g[4] / molar_mass.iron,
        mass_g[5] / molar_mass.calcium,
        mass_g[6] / molar_mass.magnesium,
        mass_g[7] / molar_mass.sodium,
        mass_g[8] / molar_mass.potassium,
        mass_g[9] / molar_mass.sulfur,
        mass_g[10] / molar_mass.chloride,
    };
}

fn nitrogenAdditions(species: [5]f64, fractions: ZoneFractions) [mineral_nitrogen.species_count]f64 {
    return .{
        species[0] * fractions.ammonium_non_band,
        species[0] * fractions.ammonium_band,
        species[1] * fractions.ammonium_non_band,
        species[1] * fractions.ammonium_band,
        species[2] * fractions.nitrate_non_band,
        species[2] * fractions.nitrate_band,
        0,
        0,
    };
}

fn parameterZoneFractions(parameters: Parameters) ZoneFractions {
    return .{
        .ammonium_non_band = 1 - parameters.ammonium_band_fraction,
        .ammonium_band = parameters.ammonium_band_fraction,
        .nitrate_non_band = 1 - parameters.nitrate_band_fraction,
        .nitrate_band = parameters.nitrate_band_fraction,
        .phosphate_non_band = 1 - parameters.phosphate_band_fraction,
        .phosphate_band = parameters.phosphate_band_fraction,
    };
}

fn irrigationFractionsAt(source: anytype, layer: usize) !ZoneFractions {
    const fractions = if (comptime @TypeOf(source) == ZoneFractions) source else try source.scienceZoneFractionsForFlatIndex(layer);
    inline for (@typeInfo(ZoneFractions).@"struct".fields) |field| {
        const value = @field(fractions, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidSubsurfaceIrrigationBandFraction;
    }
    return fractions;
}

fn layerNutrients(
    loads: *const routing.Loads,
    layer: usize,
    parameters: Parameters,
) ![5]f64 {
    const first = layer * routing.dissolved_species_count;
    const mass = loads.subsurface_dissolved_mass_g[first..][0..routing.dissolved_species_count];
    const water_m3 = loads.subsurface_water_m3[layer];
    if (water_m3 == 0) return .{ 0, 0, 0, 0, 0 };
    const hydrogen_mol_per_m3 = loads.subsurface_hydrogen_mol[layer] / water_m3;
    const ph = -std.math.log10(@max(hydrogen_mol_per_m3 / 1000.0, 1.0e-14));
    if (parameters.equilibrium) |equilibrium|
        return nutrient_speciation.calculate(.{
            .ph = ph,
            .ammonium_g_n_per_m3 = mass[0] / water_m3,
            .nitrate_g_n_per_m3 = mass[1] / water_m3,
            .phosphate_g_p_per_m3 = mass[2] / water_m3,
            .nitrogen_g_per_mol = parameters.molar_mass_g_per_mol.nitrogen,
            .phosphorus_g_per_mol = parameters.molar_mass_g_per_mol.phosphorus,
        }, equilibrium.aqueous, equilibrium.phosphate);
    return .{
        mass[0] / parameters.molar_mass_g_per_mol.nitrogen,
        0,
        mass[1] / parameters.molar_mass_g_per_mol.nitrogen,
        0,
        mass[2] / parameters.molar_mass_g_per_mol.phosphorus,
    };
}

fn validate(
    loads: *const routing.Loads,
    expected_layer_count: usize,
    parameters: Parameters,
) !void {
    const layer_count = try std.math.mul(
        usize,
        loads.cell_count,
        loads.soil_layer_capacity,
    );
    if (layer_count != expected_layer_count or
        loads.subsurface_water_m3.len != layer_count or
        loads.subsurface_hydrogen_mol.len != layer_count or
        loads.subsurface_dissolved_mass_g.len !=
            try std.math.mul(usize, layer_count, routing.dissolved_species_count))
        return error.SubsurfaceIrrigationChemistryDimensionMismatch;
    inline for (std.meta.fields(ElementMolarMassesGPerMol)) |field| {
        const value = @field(parameters.molar_mass_g_per_mol, field.name);
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidSubsurfaceIrrigationMolarMass;
    }
    inline for (.{
        parameters.ammonium_band_fraction,
        parameters.nitrate_band_fraction,
        parameters.phosphate_band_fraction,
    }) |fraction| if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
        return error.InvalidSubsurfaceIrrigationBandFraction;
    for (loads.subsurface_water_m3, loads.subsurface_hydrogen_mol) |water, hydrogen|
        if (!std.math.isFinite(water) or water < 0 or
            !std.math.isFinite(hydrogen) or hydrogen < 0 or
            (water == 0 and hydrogen != 0))
            return error.InvalidSubsurfaceIrrigationChemistryLoad;
    for (loads.subsurface_dissolved_mass_g) |mass|
        if (!std.math.isFinite(mass) or mass < 0)
            return error.InvalidSubsurfaceIrrigationChemistryLoad;
}

fn testParameters() Parameters {
    return .{
        .molar_mass_g_per_mol = .{
            .nitrogen = 14,
            .phosphorus = 31,
            .aluminum = 27,
            .iron = 56,
            .calcium = 40,
            .magnesium = 24,
            .sodium = 23,
            .potassium = 39,
            .sulfur = 32,
            .chloride = 35.5,
        },
        .equilibrium = null,
        .ammonium_band_fraction = 0.25,
        .nitrate_band_fraction = 0.4,
        .phosphate_band_fraction = 0.2,
    };
}

test "runtime-depth subsurface carriers enter only selected layers and conserve mass" {
    var loads = try routing.Loads.init(std.testing.allocator, 2, 7);
    defer loads.deinit();
    // IRRIGATION-SUBSURFACE-DEAD-CODE-001: `Loads.accumulate` never
    // populates the subsurface carriers -- it always routes to the
    // surface, matching the Fortran oracle's permanently-disabled PRECUI
    // branch (wthr.f:308-315). This test still exercises the chemistry
    // consumers directly against a synthetic subsurface load (as if a
    // future, independently validated enhancement re-enabled routing),
    // equivalent to what `accumulate(1, 7, ..., 10, 0.02, 0.45, ...)` used
    // to produce before that fix.
    const selected: usize = 7 + 4;
    loads.subsurface_water_m3[selected] = 0.2;
    loads.subsurface_hydrogen_mol[selected] = 0.0002;
    const mass = [_]f64{ 2.8, 5.6, 6.2, 5.4, 11.2, 8.0, 4.8, 4.6, 7.8, 6.4, 7.1 };
    @memcpy(
        loads.subsurface_dissolved_mass_g[selected * routing.dissolved_species_count ..][0..routing.dissolved_species_count],
        &mass,
    );
    var transport = try aqueous_transport.State.init(
        std.testing.allocator,
        14,
        aqueous_species.AqueousSpecies.count,
    );
    defer transport.deinit();
    try addTransportedIons(&loads, &transport, testParameters());
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.2),
        transport.amount_mol[
            selected * aqueous_species.AqueousSpecies.count +
                aqueous_species.index(.aluminum)
        ],
        1e-12,
    );
    for (0..14) |layer| if (layer != selected)
        try std.testing.expectEqual(
            @as(f64, 0),
            transport.amount_mol[
                layer * aqueous_species.AqueousSpecies.count +
                    aqueous_species.index(.aluminum)
            ],
        );
    const boundary = try boundaryInput(&loads, testParameters());
    try std.testing.expectApproxEqAbs(@as(f64, 8.4), boundary.nitrogen_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 6.2), boundary.phosphorus_g_p, 1e-12);
    // 0.2 mol each of the eight supplied salt carriers plus pH-derived H.
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.6) + loads.subsurface_hydrogen_mol[selected],
        boundary.ion_mol,
        1e-12,
    );
}

test "subsurface irrigation boundary input remains exact and element resolved by cell" {
    var loads = try routing.Loads.init(std.testing.allocator, 2, 2);
    defer loads.deinit();
    loads.subsurface_water_m3[1] = 1;
    loads.subsurface_hydrogen_mol[1] = 0.01;
    loads.subsurface_water_m3[2] = 1;
    loads.subsurface_hydrogen_mol[2] = 0.02;
    const first_mass = [_]f64{ 14, 28, 31, 27, 56, 40, 24, 23, 39, 32, 35.5 };
    const second_mass = [_]f64{ 28, 14, 62, 54, 112, 80, 48, 46, 78, 64, 71 };
    @memcpy(loads.subsurface_dissolved_mass_g[routing.dissolved_species_count..][0..routing.dissolved_species_count], &first_mass);
    @memcpy(loads.subsurface_dissolved_mass_g[2 * routing.dissolved_species_count ..][0..routing.dissolved_species_count], &second_mass);
    var by_cell: [2]BoundaryInput = undefined;
    try boundaryInputByCell(&by_cell, &loads, testParameters());
    try std.testing.expectEqual(@as(f64, 42), by_cell[0].nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 31), by_cell[0].phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 1), by_cell[0].aluminum_mol);
    try std.testing.expectEqual(@as(f64, 1), by_cell[0].chloride_mol);
    try std.testing.expectEqual(@as(f64, 42), by_cell[1].nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 62), by_cell[1].phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 2), by_cell[1].aluminum_mol);
    try std.testing.expectEqual(@as(f64, 2), by_cell[1].chloride_mol);
    const total = try boundaryInput(&loads, testParameters());
    try std.testing.expectEqual(by_cell[0].nitrogen_g_n + by_cell[1].nitrogen_g_n, total.nitrogen_g_n);
    try std.testing.expectEqual(by_cell[0].aluminum_mol + by_cell[1].aluminum_mol, total.aluminum_mol);
}

test "late invalid load leaves transported ions unchanged" {
    var loads = try routing.Loads.init(std.testing.allocator, 1, 2);
    defer loads.deinit();
    loads.subsurface_water_m3[0] = 1;
    loads.subsurface_hydrogen_mol[0] = 0.001;
    loads.subsurface_dissolved_mass_g[3] = 27;
    loads.subsurface_dissolved_mass_g[2 * routing.dissolved_species_count - 1] = std.math.nan(f64);
    var transport = try aqueous_transport.State.init(
        std.testing.allocator,
        2,
        aqueous_species.AqueousSpecies.count,
    );
    defer transport.deinit();
    try std.testing.expectError(
        error.InvalidSubsurfaceIrrigationChemistryLoad,
        addTransportedIons(&loads, &transport, testParameters()),
    );
    for (transport.amount_mol) |amount| try std.testing.expectEqual(@as(f64, 0), amount);
}

test "subsurface nutrient binding preserves runtime band splits and selected layer" {
    var loads = try routing.Loads.init(std.testing.allocator, 1, 7);
    defer loads.deinit();
    // IRRIGATION-SUBSURFACE-DEAD-CODE-001: as above, `accumulate` no
    // longer routes to the subsurface carriers, so this test populates
    // the selected layer's synthetic load directly. This reproduces what
    // `accumulate(0, 7, ..., 1, 1, 0.61, ...)` used to produce before
    // that fix.
    const selected: usize = 6;
    loads.subsurface_water_m3[selected] = 1;
    loads.subsurface_hydrogen_mol[selected] = 0.0001;
    const mass = [_]f64{ 14, 28, 31, 0, 0, 0, 0, 0, 0, 0, 0 };
    @memcpy(
        loads.subsurface_dissolved_mass_g[selected * routing.dissolved_species_count ..][0..routing.dissolved_species_count],
        &mass,
    );
    var nitrogen = try mineral_nitrogen.State.init(std.testing.allocator, 7);
    defer nitrogen.deinit();
    try addMineralNitrogen(&loads, &nitrogen, testParameters());
    const first = selected * mineral_nitrogen.species_count;
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), nitrogen.matrix.amount_mol[first + @intFromEnum(mineral_nitrogen.Species.ammonium_non_band)], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), nitrogen.matrix.amount_mol[first + @intFromEnum(mineral_nitrogen.Species.ammonium_band)], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), nitrogen.matrix.amount_mol[first + @intFromEnum(mineral_nitrogen.Species.nitrate_non_band)], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), nitrogen.matrix.amount_mol[first + @intFromEnum(mineral_nitrogen.Species.nitrate_band)], 1e-12);

    var chemistry_state = try chemistry.State.init(std.testing.allocator, 7);
    defer chemistry_state.deinit();
    const water = [_]f64{1} ** 7;
    try addPhosphate(&loads, &chemistry_state, &water, testParameters());
    try std.testing.expectApproxEqAbs(
        @as(f64, 1),
        chemistry_state.non_band_phosphate[selected].dissolved_h2po4_mol_p_per_m3,
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 1),
        chemistry_state.band_phosphate[selected].dissolved_h2po4_mol_p_per_m3,
        1e-12,
    );
    const physical_phosphate_mol =
        0.8 * chemistry_state.non_band_phosphate[selected].dissolved_h2po4_mol_p_per_m3 +
        0.2 * chemistry_state.band_phosphate[selected].dissolved_h2po4_mol_p_per_m3;
    try std.testing.expectEqual(@as(f64, 1), physical_phosphate_mol);
    for (0..selected) |layer| {
        try std.testing.expectEqual(
            @as(f64, 0),
            chemistry_state.non_band_phosphate[layer].dissolved_h2po4_mol_p_per_m3,
        );
        try std.testing.expectEqual(
            @as(f64, 0),
            nitrogen.matrix.amount_mol[
                layer * mineral_nitrogen.species_count +
                    @intFromEnum(mineral_nitrogen.Species.ammonium_non_band)
            ],
        );
    }
}

test "phosphate zero-water failure is atomic across runtime layers" {
    var loads = try routing.Loads.init(std.testing.allocator, 1, 2);
    defer loads.deinit();
    loads.subsurface_water_m3[1] = 1;
    loads.subsurface_hydrogen_mol[1] = 0.0001;
    loads.subsurface_dissolved_mass_g[
        routing.dissolved_species_count + 2
    ] = 31;
    var state = try chemistry.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 3;
    try std.testing.expectError(
        error.InvalidSubsurfaceIrrigationChemistryWater,
        addPhosphate(&loads, &state, &.{ 1, 0 }, testParameters()),
    );
    try std.testing.expectEqual(
        @as(f64, 3),
        state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        state.non_band_phosphate[1].dissolved_h2po4_mol_p_per_m3,
    );
}

test "two half-step irrigation chemistry additions equal one hourly addition" {
    var loads = try routing.Loads.init(std.testing.allocator, 1, 1);
    defer loads.deinit();
    loads.subsurface_water_m3[0] = 1;
    loads.subsurface_hydrogen_mol[0] = 0.002;
    const mass = [_]f64{ 14, 28, 31, 27, 56, 40, 24, 23, 39, 32, 35.5 };
    @memcpy(loads.subsurface_dissolved_mass_g[0..routing.dissolved_species_count], &mass);

    var ions_hour = try aqueous_transport.State.init(std.testing.allocator, 1, aqueous_species.AqueousSpecies.count);
    defer ions_hour.deinit();
    var ions_halves = try aqueous_transport.State.init(std.testing.allocator, 1, aqueous_species.AqueousSpecies.count);
    defer ions_halves.deinit();
    try addTransportedIons(&loads, &ions_hour, testParameters());
    try addTransportedIonsFraction(&loads, &ions_halves, testParameters(), 0.5);
    try addTransportedIonsFraction(&loads, &ions_halves, testParameters(), 0.5);
    try std.testing.expectEqualSlices(f64, ions_hour.amount_mol, ions_halves.amount_mol);

    var nitrogen_hour = try mineral_nitrogen.State.init(std.testing.allocator, 1);
    defer nitrogen_hour.deinit();
    var nitrogen_halves = try mineral_nitrogen.State.init(std.testing.allocator, 1);
    defer nitrogen_halves.deinit();
    try addMineralNitrogen(&loads, &nitrogen_hour, testParameters());
    try addMineralNitrogenFraction(&loads, &nitrogen_halves, testParameters(), 0.5);
    try addMineralNitrogenFraction(&loads, &nitrogen_halves, testParameters(), 0.5);
    try std.testing.expectEqualSlices(f64, nitrogen_hour.matrix.amount_mol, nitrogen_halves.matrix.amount_mol);

    var phosphate_hour = try chemistry.State.init(std.testing.allocator, 1);
    defer phosphate_hour.deinit();
    var phosphate_halves = try chemistry.State.init(std.testing.allocator, 1);
    defer phosphate_halves.deinit();
    try addPhosphate(&loads, &phosphate_hour, &.{1}, testParameters());
    try addPhosphateFraction(&loads, &phosphate_halves, &.{1}, testParameters(), 0.5);
    try addPhosphateFraction(&loads, &phosphate_halves, &.{1}, testParameters(), 0.5);
    try std.testing.expectEqual(
        phosphate_hour.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3,
        phosphate_halves.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3,
    );
}
