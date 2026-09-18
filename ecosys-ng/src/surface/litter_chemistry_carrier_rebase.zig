const std = @import("std");
const litter_chemistry = @import("litter_chemistry.zig");
const carrier_certification = @import("../soil/chemistry/water_carrier_rebase.zig");

pub const RoundoffAllowance = carrier_certification.RoundoffAllowance;

/// Fixed owners needed to reproduce the authoritative per-cell surface
/// chemistry census around a carrier-only mutation. They are inputs to the
/// proof, never mutation targets.
pub const InventoryInputs = struct {
    dry_mass_megagrams: f64,
    carbon_g_per_mol: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    fertilizer_ammonium_mol_n: f64 = 0,
    fertilizer_ammonia_mol_n: f64 = 0,
    fertilizer_urea_mol_n: f64 = 0,
    fertilizer_nitrate_mol_n: f64 = 0,
    denitrification_nitrite_g_n: f64 = 0,

    fn validate(self: InventoryInputs) !void {
        inline for (std.meta.fields(InventoryInputs)) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidLitterChemistryCarrier;
        }
        if (self.carbon_g_per_mol == 0 or self.nitrogen_g_per_mol == 0 or
            self.phosphorus_g_per_mol == 0)
            return error.InvalidLitterChemistryCarrier;
    }

    fn withDryMass(self: InventoryInputs, dry_mass_megagrams: f64) InventoryInputs {
        var result = self;
        result.dry_mass_megagrams = dry_mass_megagrams;
        return result;
    }
};

/// Diagnostic counter: how many times the dry-carrier branch has executed. Used to
/// check whether that branch is reachable at all in a given scenario, rather than
/// assuming it from the presence of a failure downstream. See EXEC-004.
///
/// Measured: `10` executions over the first day of the Ottawa example with surface
/// evaporation enabled, and `0` with it disabled as shipped. That is what
/// establishes the branch is genuinely exercised once evaporation is active, and
/// that the shipped configuration never reaches it.
pub var dry_branch_executions: u64 = 0;

/// Returns the carrier on which water-normalized litter chemistry is stored.
/// Live water owns wet concentrations; the remembered dry reference owns the
/// same extensive amount while no liquid water is present.
pub fn effectiveAqueousCarrierM3(
    live_water_m3: f64,
    dry_reference_water_m3: f64,
) !f64 {
    if (!std.math.isFinite(live_water_m3) or live_water_m3 < 0 or
        !std.math.isFinite(dry_reference_water_m3) or dry_reference_water_m3 < 0)
        return error.InvalidLitterChemistryCarrier;
    return if (live_water_m3 > 0) live_water_m3 else dry_reference_water_m3;
}

/// Stages the independent solid-mineral representation for a water change
/// performed outside `rebaseFromAcceptedLiquidWaterChange` (notably the
/// litter--soil interface).  Extensive solid amounts remain fixed; the last
/// positive reference is retained while dry.  Validation completes before
/// `cell` is changed.
pub noinline fn rebaseMineralCellForAcceptedWater(
    cell: *litter_chemistry.Cell,
    mineral_reference_before_m3: f64,
    new_live_water_m3: f64,
) !f64 {
    if (!std.math.isFinite(mineral_reference_before_m3) or mineral_reference_before_m3 < 0 or
        !std.math.isFinite(new_live_water_m3) or new_live_water_m3 < 0)
        return error.InvalidLitterChemistryCarrier;
    var candidate = cell.*;
    inline for (@typeInfo(litter_chemistry.Cell).@"struct".fields) |field| {
        if (comptime isMineralStruct(field.name)) {
            inline for (@typeInfo(field.type).@"struct".fields) |nested|
                try validatePool(@field(@field(candidate, field.name), nested.name), mineral_reference_before_m3);
        }
    }
    if (new_live_water_m3 == 0) return mineral_reference_before_m3;
    applyMineralScale(
        &candidate,
        if (mineral_reference_before_m3 == 0) 0 else mineral_reference_before_m3 / new_live_water_m3,
    );
    inline for (@typeInfo(litter_chemistry.Cell).@"struct".fields) |field| {
        if (comptime isMineralStruct(field.name)) {
            inline for (@typeInfo(field.type).@"struct".fields) |nested|
                try validatePool(@field(@field(candidate, field.name), nested.name), new_live_water_m3);
        }
    }
    cell.* = candidate;
    return new_live_water_m3;
}

/// Allocation-free carrier transaction after an accepted liquid-water change.
/// All `mol/m3` pools retain their extensive amount; dry-mass-normalized
/// exchange, carboxyl, and phosphate-surface pools remain unchanged.
///
/// **Dry carriers.** `hour1.f` 4494--4524 stores litter solutes as absolute mass
/// and derives concentration as `AMAX1(0.0, mass/VOLW(0))`, setting it to `0.0`
/// where the litter layer does not exist. Mass therefore survives the carrier
/// vanishing. Because ecosys-ng stores these pools water-normalized, a carrier of
/// exactly zero has no representable concentration, and this transaction used to
/// reject that outright with `LitterChemistryMassWithoutWaterCarrier`, which made
/// evaporation to dryness a hard error.
///
/// It no longer does. When the live carrier reaches zero the concentrations are
/// **held unchanged** rather than scaled to zero, and the carrier they refer to is
/// remembered in `dry_reference_water_m3` so that rewetting rescales from the
/// retained value instead of from zero. The extensive amount
/// `concentration * remembered_carrier` is therefore preserved exactly across an
/// arbitrary wet/dry/rewet sequence, matching the oracle's invariant (mass
/// conserved, concentration undefined while dry) within a water-normalized
/// representation.
///
/// Note `mineral_reference_water_m3` is deliberately *not* reused for this: it is
/// also written by `bindMineralReferenceWater` and `renormalizeMinerals`, so
/// borrowing it as the rescale source would couple two independent invariants.
///
/// **Dry-consumer invariant.** Active storage, metabolism, runoff/snow, ammonia
/// phase exchange, litter--soil transfer, removal, tillage, pond-domain
/// transfer, diagnostics/daily output, and restart paths reconstruct aqueous
/// amounts on the live carrier when wet and `dry_reference_water_m3` when dry.
/// Processes that physically require liquid water (reaction equilibrium and
/// aqueous biological uptake) deliberately use the live carrier and skip while
/// dry. Solid minerals remain independent on `mineral_reference_water_m3`;
/// wet/dry rebasing scales the two owner classes from their respective
/// references.
///
/// See EXEC-004. `surface_litter_solute_dry_carrier.zig` states the target
/// semantics independently and proves why a naive rescale cannot round-trip.
pub noinline fn rebaseFromAcceptedLiquidWaterChange(
    state: *litter_chemistry.State,
    new_litter_water_volume_m3: []const f64,
    liquid_water_change_m3: []const f64,
) !void {
    if (new_litter_water_volume_m3.len != state.cells.len or
        liquid_water_change_m3.len != state.cells.len)
        return error.LitterChemistryCarrierDimensionMismatch;

    for (state.cells, 0..) |cell, index| {
        const old = try oldCarrier(
            new_litter_water_volume_m3[index],
            liquid_water_change_m3[index],
        );
        const aqueous_source = try effectiveAqueousCarrierM3(old, state.dry_reference_water_m3[index]);
        try validateCell(cell, aqueous_source, state.mineral_reference_water_m3[index]);
    }
    for (state.cells, 0..) |*cell, index| {
        const new = new_litter_water_volume_m3[index];
        const old = new - liquid_water_change_m3[index];
        // The carrier the stored concentrations currently refer to: the live
        // `old`, unless a previous step went dry and remembered one.
        const source = try effectiveAqueousCarrierM3(old, state.dry_reference_water_m3[index]);
        const mineral_source = state.mineral_reference_water_m3[index];
        if (new == 0) {
            // Going dry: hold the concentrations and remember the carrier they
            // refer to, so no mass is lost and rewetting can recover it.
            dry_branch_executions += 1;
            if (state.dry_reference_water_m3[index] == 0)
                state.dry_reference_water_m3[index] = source;
            continue;
        }
        applyAqueousScale(cell, if (source == 0) 0 else source / new);
        applyMineralScale(cell, if (mineral_source == 0) 0 else mineral_source / new);
        state.mineral_reference_water_m3[index] = new;
        state.dry_reference_water_m3[index] = 0;
    }
}

/// Mutation-free preflight for one cell of a larger accepted water
/// transaction. Callers which publish several physical carriers atomically use
/// this before their first write, then call `rebaseCellForAcceptedWater` during
/// the infallible commit pass.
pub noinline fn validateCellForAcceptedWater(
    state: *const litter_chemistry.State,
    index: usize,
    old_live_water_m3: f64,
    new_live_water_m3: f64,
) !void {
    if (index >= state.cells.len or
        state.dry_reference_water_m3.len != state.cells.len or
        state.mineral_reference_water_m3.len != state.cells.len)
        return error.LitterChemistryCarrierDimensionMismatch;
    if (!std.math.isFinite(old_live_water_m3) or old_live_water_m3 < 0 or
        !std.math.isFinite(new_live_water_m3) or new_live_water_m3 < 0)
        return error.InvalidLitterChemistryCarrier;
    const aqueous_source = try effectiveAqueousCarrierM3(
        old_live_water_m3,
        state.dry_reference_water_m3[index],
    );
    try validateCell(
        state.cells[index],
        aqueous_source,
        state.mineral_reference_water_m3[index],
    );
}

/// Commits a cell whose carrier change has already passed
/// `validateCellForAcceptedWater`. Extensive aqueous and mineral amounts are
/// preserved; dry reference ownership follows the vector transaction above.
pub noinline fn rebaseCellForAcceptedWater(
    state: *litter_chemistry.State,
    index: usize,
    old_live_water_m3: f64,
    new_live_water_m3: f64,
) !void {
    try validateCellForAcceptedWater(state, index, old_live_water_m3, new_live_water_m3);
    const source = try effectiveAqueousCarrierM3(
        old_live_water_m3,
        state.dry_reference_water_m3[index],
    );
    const mineral_source = state.mineral_reference_water_m3[index];
    if (new_live_water_m3 == 0) {
        dry_branch_executions += 1;
        if (state.dry_reference_water_m3[index] == 0)
            state.dry_reference_water_m3[index] = source;
        return;
    }
    applyAqueousScale(
        &state.cells[index],
        if (source == 0) 0 else source / new_live_water_m3,
    );
    applyMineralScale(
        &state.cells[index],
        if (mineral_source == 0) 0 else mineral_source / new_live_water_m3,
    );
    state.mineral_reference_water_m3[index] = new_live_water_m3;
    state.dry_reference_water_m3[index] = 0;
}

/// Rebase every dry-mass-normalized pool after an accepted litter dry-mass
/// change. Extensive amounts are invariant; water-normalized pools are not
/// touched because this transaction changes only the solid carrier.
pub noinline fn rebaseFromAcceptedDryMassChange(
    state: *litter_chemistry.State,
    old_dry_mass_megagrams: []const f64,
    new_dry_mass_megagrams: []const f64,
) !void {
    if (old_dry_mass_megagrams.len != state.cells.len or
        new_dry_mass_megagrams.len != state.cells.len)
        return error.LitterChemistryCarrierDimensionMismatch;

    for (state.cells, old_dry_mass_megagrams, new_dry_mass_megagrams) |cell, old, new| {
        try validateDryCarrier(old, new);
        try validateDryNormalizedCell(cell, old, new);
    }
    for (state.cells, old_dry_mass_megagrams, new_dry_mass_megagrams) |*cell, old, new| {
        const scale = if (old == 0) 0 else old / new;
        applyDryScale(cell, scale);
    }
}

/// Mutation-free certification of the authoritative surface chemistry
/// inventory affected by one accepted liquid-water carrier change.  The
/// returned lanes are arithmetic provenance only; they are not material
/// sources or physical tolerances.
pub noinline fn previewCellWaterRoundoff(
    state: *const litter_chemistry.State,
    index: usize,
    old_live_water_m3: f64,
    new_live_water_m3: f64,
    inventory_inputs: InventoryInputs,
) !RoundoffAllowance {
    return previewCellWaterRoundoffFromScaleSource(
        state,
        index,
        old_live_water_m3,
        old_live_water_m3,
        new_live_water_m3,
        inventory_inputs,
    );
}

/// Certifies the literal vector-rebase arithmetic when its mutator reconstructs
/// the scale source as `new - accepted_change`. `inventory_before_live_water_m3`
/// is the exact pre-mutation physical carrier used by the storage census;
/// `scale_source_live_water_m3` is the binary64 value the mutator actually
/// divides by the new carrier. Keeping both values makes reconstruction drift
/// visible without changing the established scientific mutation arithmetic.
pub noinline fn previewCellWaterRoundoffFromScaleSource(
    state: *const litter_chemistry.State,
    index: usize,
    inventory_before_live_water_m3: f64,
    scale_source_live_water_m3: f64,
    new_live_water_m3: f64,
    inventory_inputs: InventoryInputs,
) !RoundoffAllowance {
    try inventory_inputs.validate();
    try validateCellForAcceptedWater(
        state,
        index,
        inventory_before_live_water_m3,
        new_live_water_m3,
    );
    // No carrier arithmetic is performed when the physical inventory source,
    // the mutator's literal scale source, and the accepted carrier are the
    // same binary64 value. Validation must still run so this fast path cannot
    // hide an invalid state or input.
    if (inventory_before_live_water_m3 == scale_source_live_water_m3 and
        scale_source_live_water_m3 == new_live_water_m3)
        return .{};
    try validateCellForAcceptedWater(
        state,
        index,
        scale_source_live_water_m3,
        new_live_water_m3,
    );
    const inventory_before_aqueous_carrier = try effectiveAqueousCarrierM3(
        inventory_before_live_water_m3,
        state.dry_reference_water_m3[index],
    );
    const aqueous_source = try effectiveAqueousCarrierM3(
        scale_source_live_water_m3,
        state.dry_reference_water_m3[index],
    );
    const mineral_source = state.mineral_reference_water_m3[index];

    const before = state.cells[index];
    var after = before;
    if (new_live_water_m3 == 0) {
        var dry_result: RoundoffAllowance = .{};
        try accumulateAqueousRoundoff(
            &dry_result,
            before,
            after,
            inventory_before_aqueous_carrier,
            aqueous_source,
        );
        try mergeAuthoritativeGroupDrift(
            &dry_result,
            try carrierOwnedInventory(
                before,
                inventory_before_aqueous_carrier,
                mineral_source,
                inventory_inputs,
            ),
            try carrierOwnedInventory(
                after,
                aqueous_source,
                mineral_source,
                inventory_inputs,
            ),
            inventory_inputs,
        );
        try dry_result.validate();
        return dry_result;
    }
    const aqueous_scale = if (aqueous_source == 0)
        0
    else
        aqueous_source / new_live_water_m3;
    const mineral_scale = if (mineral_source == 0)
        0
    else
        mineral_source / new_live_water_m3;
    if (!std.math.isFinite(aqueous_scale) or aqueous_scale < 0 or
        !std.math.isFinite(mineral_scale) or mineral_scale < 0)
        return error.InvalidLitterChemistryCarrier;
    applyAqueousScale(&after, aqueous_scale);
    applyMineralScale(&after, mineral_scale);
    try validateCell(after, new_live_water_m3, new_live_water_m3);

    var result: RoundoffAllowance = .{};
    try accumulateAqueousRoundoff(
        &result,
        before,
        after,
        inventory_before_aqueous_carrier,
        new_live_water_m3,
    );
    try accumulateMineralRoundoff(
        &result,
        before,
        after,
        mineral_source,
        new_live_water_m3,
    );
    try mergeAuthoritativeGroupDrift(
        &result,
        try carrierOwnedInventory(
            before,
            inventory_before_aqueous_carrier,
            mineral_source,
            inventory_inputs,
        ),
        try carrierOwnedInventory(
            after,
            new_live_water_m3,
            new_live_water_m3,
            inventory_inputs,
        ),
        inventory_inputs,
    );
    try result.validate();
    return result;
}

/// Mutation-free certification for the independent solid-mineral carrier
/// transaction performed by `rebaseMineralCellForAcceptedWater`.
pub noinline fn previewMineralCellRoundoff(
    cell: litter_chemistry.Cell,
    aqueous_carrier_m3: f64,
    inventory_inputs: InventoryInputs,
    old_reference_water_m3: f64,
    new_live_water_m3: f64,
) !RoundoffAllowance {
    try inventory_inputs.validate();
    if (!std.math.isFinite(old_reference_water_m3) or old_reference_water_m3 < 0 or
        !std.math.isFinite(new_live_water_m3) or new_live_water_m3 < 0)
        return error.InvalidLitterChemistryCarrier;
    try validateCell(cell, aqueous_carrier_m3, old_reference_water_m3);
    var after = cell;
    inline for (@typeInfo(litter_chemistry.Cell).@"struct".fields) |field| {
        if (comptime isMineralStruct(field.name)) {
            inline for (@typeInfo(field.type).@"struct".fields) |nested|
                try validatePool(@field(@field(cell, field.name), nested.name), old_reference_water_m3);
        }
    }
    if (new_live_water_m3 == 0) return .{};
    const scale = if (old_reference_water_m3 == 0)
        0
    else
        old_reference_water_m3 / new_live_water_m3;
    if (!std.math.isFinite(scale) or scale < 0)
        return error.InvalidLitterChemistryCarrier;
    applyMineralScale(&after, scale);
    try validateCell(after, aqueous_carrier_m3, new_live_water_m3);
    inline for (@typeInfo(litter_chemistry.Cell).@"struct".fields) |field| {
        if (comptime isMineralStruct(field.name)) {
            inline for (@typeInfo(field.type).@"struct".fields) |nested|
                try validatePool(@field(@field(after, field.name), nested.name), new_live_water_m3);
        }
    }
    var result: RoundoffAllowance = .{};
    try accumulateMineralRoundoff(
        &result,
        cell,
        after,
        old_reference_water_m3,
        new_live_water_m3,
    );
    try mergeAuthoritativeGroupDrift(
        &result,
        try carrierOwnedInventory(
            cell,
            aqueous_carrier_m3,
            old_reference_water_m3,
            inventory_inputs,
        ),
        try carrierOwnedInventory(
            after,
            aqueous_carrier_m3,
            new_live_water_m3,
            inventory_inputs,
        ),
        inventory_inputs,
    );
    try result.validate();
    return result;
}

/// Mutation-free certification for dry-mass-normalized exchange and adsorbed
/// phosphate owners.  Other dry-normalized coordinates are not accepted
/// C/N/P/ion storage and therefore cannot inflate these provenance lanes.
pub noinline fn previewCellDryMassRoundoff(
    cell: litter_chemistry.Cell,
    aqueous_carrier_m3: f64,
    mineral_reference_water_m3: f64,
    inventory_inputs: InventoryInputs,
    old_dry_mass_megagrams: f64,
    new_dry_mass_megagrams: f64,
) !RoundoffAllowance {
    try inventory_inputs.validate();
    try validateDryCarrier(old_dry_mass_megagrams, new_dry_mass_megagrams);
    try validateCell(cell, aqueous_carrier_m3, mineral_reference_water_m3);
    try validateDryNormalizedCell(
        cell,
        old_dry_mass_megagrams,
        new_dry_mass_megagrams,
    );
    const scale = if (old_dry_mass_megagrams == 0)
        0
    else
        old_dry_mass_megagrams / new_dry_mass_megagrams;
    if (!std.math.isFinite(scale) or scale < 0)
        return error.InvalidLitterChemistryCarrier;
    var after = cell;
    applyDryScale(&after, scale);
    try validateCell(after, aqueous_carrier_m3, mineral_reference_water_m3);
    try validateDryNormalizedCell(
        after,
        new_dry_mass_megagrams,
        new_dry_mass_megagrams,
    );
    var result: RoundoffAllowance = .{};
    try accumulateDryMassRoundoff(
        &result,
        cell,
        after,
        old_dry_mass_megagrams,
        new_dry_mass_megagrams,
    );
    try mergeAuthoritativeGroupDrift(
        &result,
        try carrierOwnedInventory(
            cell,
            aqueous_carrier_m3,
            mineral_reference_water_m3,
            inventory_inputs.withDryMass(old_dry_mass_megagrams),
        ),
        try carrierOwnedInventory(
            after,
            aqueous_carrier_m3,
            mineral_reference_water_m3,
            inventory_inputs.withDryMass(new_dry_mass_megagrams),
        ),
        inventory_inputs,
    );
    try result.validate();
    return result;
}

const CarrierOwnedInventory = struct {
    carbon_g: f64,
    ammonium_nitrogen_g: f64,
    nitrate_nitrogen_g: f64,
    phosphorus_g: f64,
    elements: RoundoffAllowance,
};

/// Carrier-owned projection of the authoritative surface chemistry census.
/// Its expression grouping, final-unit molar products, fixed fertilizer and
/// nitrite terms, and element stoichiometry mirror production exactly.
noinline fn carrierOwnedInventory(
    cell: litter_chemistry.Cell,
    aqueous_carrier_m3: f64,
    mineral_reference_water_m3: f64,
    inputs: InventoryInputs,
) !CarrierOwnedInventory {
    try inputs.validate();
    inline for (.{ aqueous_carrier_m3, mineral_reference_water_m3 }) |carrier|
        if (!std.math.isFinite(carrier) or carrier < 0)
            return error.InvalidLitterChemistryCarrier;

    const elements: RoundoffAllowance = .{
        .aluminum_mol = aqueous_carrier_m3 * cell.aluminum_mol_per_m3 +
            inputs.dry_mass_megagrams * cell.exchange.aluminum_mol_per_megagram +
            mineral_reference_water_m3 *
                (cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 +
                    cell.salt_minerals.gibbsite_mol_per_m3),
        .iron_mol = aqueous_carrier_m3 * cell.iron_mol_per_m3 +
            inputs.dry_mass_megagrams * cell.exchange.iron_mol_per_megagram +
            mineral_reference_water_m3 *
                (cell.phosphate_minerals.iron_phosphate_mol_per_m3 +
                    cell.salt_minerals.iron_hydroxide_mol_per_m3),
        .calcium_mol = aqueous_carrier_m3 * cell.calcium_mol_per_m3 +
            inputs.dry_mass_megagrams * cell.exchange.calcium_mol_per_megagram +
            mineral_reference_water_m3 *
                (cell.phosphate_minerals.dicalcium_phosphate_mol_per_m3 +
                    5 * cell.phosphate_minerals.hydroxyapatite_mol_per_m3 +
                    cell.phosphate_minerals.monocalcium_phosphate_mol_per_m3 +
                    cell.salt_minerals.calcite_mol_per_m3 +
                    cell.salt_minerals.gypsum_mol_per_m3),
        .magnesium_mol = aqueous_carrier_m3 * cell.magnesium_mol_per_m3 +
            inputs.dry_mass_megagrams * cell.exchange.magnesium_mol_per_megagram,
        .sodium_mol = aqueous_carrier_m3 * cell.sodium_mol_per_m3 +
            inputs.dry_mass_megagrams * cell.exchange.sodium_mol_per_megagram,
        .potassium_mol = aqueous_carrier_m3 * cell.potassium_mol_per_m3 +
            inputs.dry_mass_megagrams * cell.exchange.potassium_mol_per_megagram,
        .sulfur_mol = aqueous_carrier_m3 * cell.sulfate_mol_per_m3 +
            mineral_reference_water_m3 * cell.salt_minerals.gypsum_mol_per_m3,
        .chloride_mol = aqueous_carrier_m3 * cell.chloride_mol_per_m3,
    };
    try elements.validate();
    const result: CarrierOwnedInventory = .{
        .carbon_g = inputs.carbon_g_per_mol *
            (aqueous_carrier_m3 *
                (cell.carbonate_mol_per_m3 + cell.bicarbonate_mol_per_m3) +
                mineral_reference_water_m3 * cell.salt_minerals.calcite_mol_per_m3),
        .ammonium_nitrogen_g = inputs.nitrogen_g_per_mol *
            (aqueous_carrier_m3 *
                (cell.ammonium_mol_per_m3 + cell.ammonia_mol_per_m3) +
                inputs.dry_mass_megagrams * cell.exchange.ammonium_mol_per_megagram +
                inputs.fertilizer_ammonium_mol_n +
                inputs.fertilizer_ammonia_mol_n +
                inputs.fertilizer_urea_mol_n),
        .nitrate_nitrogen_g = inputs.nitrogen_g_per_mol *
            (aqueous_carrier_m3 * cell.nitrate_mol_per_m3 +
                inputs.fertilizer_nitrate_mol_n) +
            inputs.denitrification_nitrite_g_n,
        .phosphorus_g = inputs.phosphorus_g_per_mol *
            (aqueous_carrier_m3 *
                (cell.hpo4_mol_p_per_m3 + cell.h2po4_mol_p_per_m3) +
                mineral_reference_water_m3 *
                    (cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 +
                        cell.phosphate_minerals.iron_phosphate_mol_per_m3 +
                        cell.phosphate_minerals.dicalcium_phosphate_mol_per_m3 +
                        2 * cell.phosphate_minerals.monocalcium_phosphate_mol_per_m3 +
                        3 * cell.phosphate_minerals.hydroxyapatite_mol_per_m3) +
                inputs.dry_mass_megagrams *
                    (cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram +
                        cell.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram)),
        .elements = elements,
    };
    inline for (std.meta.fields(CarrierOwnedInventory)) |field| {
        if (comptime !std.mem.eql(u8, field.name, "elements")) {
            const value = @field(result, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidLitterChemistryCarrier;
        }
    }
    return result;
}

noinline fn mergeAuthoritativeGroupDrift(
    result: *RoundoffAllowance,
    before: CarrierOwnedInventory,
    after: CarrierOwnedInventory,
    inputs: InventoryInputs,
) !void {
    const grouped_operation_count: u8 = 32;
    const carbon_independent = try carrier_certification.groupedIndependentBound(
        try carrier_certification.scaleCertifiedBound(
            result.carbon_mol,
            inputs.carbon_g_per_mol,
        ),
        before.carbon_g,
        after.carbon_g,
        grouped_operation_count,
    );
    result.carbon_g = @max(
        result.carbon_g,
        try carrier_certification.certifyGroupedEndpointWithin(
            before.carbon_g,
            after.carbon_g,
            carbon_independent,
        ),
    );
    const ammonium_nitrogen_bound = try carrier_certification.certifyGroupedEndpoint(
        before.ammonium_nitrogen_g,
        after.ammonium_nitrogen_g,
    );
    const nitrate_nitrogen_bound = try carrier_certification.certifyGroupedEndpoint(
        before.nitrate_nitrogen_g,
        after.nitrate_nitrogen_g,
    );
    const nitrogen_observed = try carrier_certification.addCertifiedBounds(
        ammonium_nitrogen_bound,
        nitrate_nitrogen_bound,
    );
    const nitrogen_before = try carrier_certification.addCertifiedBounds(
        before.ammonium_nitrogen_g,
        before.nitrate_nitrogen_g,
    );
    const nitrogen_after = try carrier_certification.addCertifiedBounds(
        after.ammonium_nitrogen_g,
        after.nitrate_nitrogen_g,
    );
    const nitrogen_independent = try carrier_certification.groupedIndependentBound(
        try carrier_certification.scaleCertifiedBound(
            result.nitrogen_mol,
            inputs.nitrogen_g_per_mol,
        ),
        nitrogen_before,
        nitrogen_after,
        grouped_operation_count,
    );
    result.nitrogen_g = @max(
        result.nitrogen_g,
        try carrier_certification.requireCertifiedGroupedObserved(
            nitrogen_observed,
            nitrogen_independent,
        ),
    );
    const phosphorus_independent = try carrier_certification.groupedIndependentBound(
        try carrier_certification.scaleCertifiedBound(
            result.phosphorus_mol,
            inputs.phosphorus_g_per_mol,
        ),
        before.phosphorus_g,
        after.phosphorus_g,
        grouped_operation_count,
    );
    result.phosphorus_g = @max(
        result.phosphorus_g,
        try carrier_certification.certifyGroupedEndpointWithin(
            before.phosphorus_g,
            after.phosphorus_g,
            phosphorus_independent,
        ),
    );
    inline for (.{ "aluminum_mol", "iron_mol", "calcium_mol", "magnesium_mol", "sodium_mol", "potassium_mol", "sulfur_mol", "chloride_mol" }) |name| {
        const independent = try carrier_certification.groupedIndependentBound(
            @field(result, name),
            @field(before.elements, name),
            @field(after.elements, name),
            grouped_operation_count,
        );
        const drift = try carrier_certification.certifyGroupedEndpointWithin(
            @field(before.elements, name),
            @field(after.elements, name),
            independent,
        );
        @field(result, name) = @max(@field(result, name), drift);
    }
    try result.validate();
}

fn validateDryCarrier(old: f64, new: f64) !void {
    if (!std.math.isFinite(old) or !std.math.isFinite(new) or old < 0 or new < 0)
        return error.InvalidLitterChemistryCarrier;
}

noinline fn validateDryNormalizedCell(cell: litter_chemistry.Cell, old: f64, new: f64) !void {
    inline for (@typeInfo(litter_chemistry.Cell).@"struct".fields) |field| {
        const Field = field.type;
        if (comptime isDryNormalized(field.name, Field)) {
            try validateDryPool(@field(cell, field.name), old, new);
        } else if (comptime isDryNormalizedStruct(field.name)) {
            inline for (@typeInfo(Field).@"struct".fields) |nested|
                try validateDryPool(@field(@field(cell, field.name), nested.name), old, new);
        }
    }
}

fn validateDryPool(value: f64, old: f64, new: f64) !void {
    if (!std.math.isFinite(value) or value < 0)
        return error.InvalidDryNormalizedLitterChemistryPool;
    if (value > 0 and (old == 0 or new == 0))
        return error.LitterChemistryMassWithoutDryCarrier;
}

noinline fn applyDryScale(cell: *litter_chemistry.Cell, scale: f64) void {
    inline for (@typeInfo(litter_chemistry.Cell).@"struct".fields) |field| {
        const Field = field.type;
        if (comptime isDryNormalized(field.name, Field)) {
            @field(cell, field.name) *= scale;
        } else if (comptime isDryNormalizedStruct(field.name)) {
            inline for (@typeInfo(Field).@"struct".fields) |nested|
                @field(@field(cell, field.name), nested.name) *= scale;
        }
    }
}

fn isDryNormalized(comptime name: []const u8, comptime Field: type) bool {
    return @typeInfo(Field) == .float and std.mem.endsWith(u8, name, "_per_megagram");
}

fn isDryNormalizedStruct(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "exchange") or
        std.mem.eql(u8, name, "phosphate_surface");
}

fn oldCarrier(new: f64, change: f64) !f64 {
    if (!std.math.isFinite(new) or !std.math.isFinite(change))
        return error.InvalidLitterChemistryCarrier;
    const old = new - change;
    if (!std.math.isFinite(old) or old < 0 or new < 0)
        return error.InvalidLitterChemistryCarrier;
    return old;
}

noinline fn validateCell(cell: litter_chemistry.Cell, aqueous_reference: f64, mineral_reference: f64) !void {
    if (!std.math.isFinite(aqueous_reference) or aqueous_reference < 0 or
        !std.math.isFinite(mineral_reference) or mineral_reference < 0)
        return error.InvalidLitterChemistryCarrier;
    inline for (@typeInfo(litter_chemistry.Cell).@"struct".fields) |field| {
        const Field = field.type;
        if (comptime isSolventWater(field.name)) {
            // Intensive: no carrier owns it, so `validatePool`'s
            // mass-without-a-carrier rule does not apply. It must still be a
            // finite, non-negative molarity.
            const value = @field(cell, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidLitterSolventWaterConcentration;
        } else if (comptime isWaterNormalized(field.name, Field)) {
            try validatePool(@field(cell, field.name), aqueous_reference);
        } else if (comptime isMineralStruct(field.name)) {
            inline for (@typeInfo(Field).@"struct".fields) |nested| {
                try validatePool(@field(@field(cell, field.name), nested.name), mineral_reference);
            }
        } else if (comptime @typeInfo(Field) == .float) {
            const value = @field(cell, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidDryNormalizedLitterChemistryPool;
        } else {
            inline for (@typeInfo(Field).@"struct".fields) |nested| {
                const value = @field(@field(cell, field.name), nested.name);
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidDryNormalizedLitterChemistryPool;
            }
        }
    }
}

fn validatePool(value: f64, reference: f64) !void {
    if (!std.math.isFinite(value) or value < 0)
        return error.InvalidWaterNormalizedLitterChemistryPool;
    if (value > 0 and reference == 0)
        return error.LitterChemistryMassWithoutWaterCarrier;
}

noinline fn applyAqueousScale(cell: *litter_chemistry.Cell, scale: f64) void {
    inline for (@typeInfo(litter_chemistry.Cell).@"struct".fields) |field| {
        const Field = field.type;
        if (comptime isWaterNormalized(field.name, Field)) {
            @field(cell, field.name) *= scale;
        }
    }
}

noinline fn applyMineralScale(cell: *litter_chemistry.Cell, scale: f64) void {
    inline for (@typeInfo(litter_chemistry.Cell).@"struct".fields) |field| {
        const Field = field.type;
        if (comptime isMineralStruct(field.name)) {
            inline for (@typeInfo(Field).@"struct".fields) |nested|
                @field(@field(cell, field.name), nested.name) *= scale;
        }
    }
}

/// The solvent-water coordinate is an *intensive* property of liquid water --
/// its own molarity, `water_concentration_mol_per_m3` (55555.555... mol m-3 for
/// pure water) -- and not a dissolved inventory carried by that water.
///
/// A carrier change adds or removes litter water, which changes the water
/// volume and the number of water molecules in exact proportion, so the
/// solvent molarity is invariant under the transaction. Rescaling it by
/// `old / new` like a solute would instead conserve a fictitious extensive
/// "amount of solvent" pinned to whatever carrier happened to be live when the
/// litter first became wet, and drive the coordinate arbitrarily close to zero
/// across a net-wetting sequence.
///
/// `soil/chemistry/water_carrier_rebase.zig`'s `scalable` excludes the
/// identically-named soil field for exactly this reason; this predicate is the
/// surface-litter counterpart of that exclusion.
fn isSolventWater(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "water_mol_per_m3");
}

fn isWaterNormalized(comptime name: []const u8, comptime Field: type) bool {
    return @typeInfo(Field) == .float and
        !isSolventWater(name) and
        std.mem.indexOf(u8, name, "_mol") != null and
        std.mem.endsWith(u8, name, "_per_m3");
}

fn isMineralStruct(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "phosphate_minerals") or
        std.mem.eql(u8, name, "salt_minerals");
}

noinline fn certifyField(
    result: *RoundoffAllowance,
    before: f64,
    after: f64,
    old_carrier: f64,
    new_carrier: f64,
    coefficients: RoundoffAllowance,
) !void {
    try carrier_certification.accumulateCertifiedFullCarrierField(
        result,
        before,
        after,
        old_carrier,
        new_carrier,
        coefficients,
    );
}

noinline fn accumulateAqueousRoundoff(
    result: *RoundoffAllowance,
    before: litter_chemistry.Cell,
    after: litter_chemistry.Cell,
    old_carrier: f64,
    new_carrier: f64,
) !void {
    try certifyField(result, before.ammonium_mol_per_m3, after.ammonium_mol_per_m3, old_carrier, new_carrier, .{ .nitrogen_mol = 1 });
    try certifyField(result, before.ammonia_mol_per_m3, after.ammonia_mol_per_m3, old_carrier, new_carrier, .{ .nitrogen_mol = 1 });
    try certifyField(result, before.nitrate_mol_per_m3, after.nitrate_mol_per_m3, old_carrier, new_carrier, .{ .nitrogen_mol = 1 });
    try certifyField(result, before.hpo4_mol_p_per_m3, after.hpo4_mol_p_per_m3, old_carrier, new_carrier, .{ .phosphorus_mol = 1 });
    try certifyField(result, before.h2po4_mol_p_per_m3, after.h2po4_mol_p_per_m3, old_carrier, new_carrier, .{ .phosphorus_mol = 1 });
    try certifyField(result, before.aluminum_mol_per_m3, after.aluminum_mol_per_m3, old_carrier, new_carrier, .{ .aluminum_mol = 1 });
    try certifyField(result, before.iron_mol_per_m3, after.iron_mol_per_m3, old_carrier, new_carrier, .{ .iron_mol = 1 });
    try certifyField(result, before.calcium_mol_per_m3, after.calcium_mol_per_m3, old_carrier, new_carrier, .{ .calcium_mol = 1 });
    try certifyField(result, before.magnesium_mol_per_m3, after.magnesium_mol_per_m3, old_carrier, new_carrier, .{ .magnesium_mol = 1 });
    try certifyField(result, before.sodium_mol_per_m3, after.sodium_mol_per_m3, old_carrier, new_carrier, .{ .sodium_mol = 1 });
    try certifyField(result, before.potassium_mol_per_m3, after.potassium_mol_per_m3, old_carrier, new_carrier, .{ .potassium_mol = 1 });
    try certifyField(result, before.sulfate_mol_per_m3, after.sulfate_mol_per_m3, old_carrier, new_carrier, .{ .sulfur_mol = 1 });
    try certifyField(result, before.chloride_mol_per_m3, after.chloride_mol_per_m3, old_carrier, new_carrier, .{ .chloride_mol = 1 });
    try certifyField(result, before.carbonate_mol_per_m3, after.carbonate_mol_per_m3, old_carrier, new_carrier, .{ .carbon_mol = 1 });
    try certifyField(result, before.bicarbonate_mol_per_m3, after.bicarbonate_mol_per_m3, old_carrier, new_carrier, .{ .carbon_mol = 1 });
}

noinline fn accumulateMineralRoundoff(
    result: *RoundoffAllowance,
    before: litter_chemistry.Cell,
    after: litter_chemistry.Cell,
    old_carrier: f64,
    new_carrier: f64,
) !void {
    const bp = before.phosphate_minerals;
    const ap = after.phosphate_minerals;
    try certifyField(result, bp.aluminum_phosphate_mol_per_m3, ap.aluminum_phosphate_mol_per_m3, old_carrier, new_carrier, .{ .phosphorus_mol = 1, .aluminum_mol = 1 });
    try certifyField(result, bp.iron_phosphate_mol_per_m3, ap.iron_phosphate_mol_per_m3, old_carrier, new_carrier, .{ .phosphorus_mol = 1, .iron_mol = 1 });
    try certifyField(result, bp.dicalcium_phosphate_mol_per_m3, ap.dicalcium_phosphate_mol_per_m3, old_carrier, new_carrier, .{ .phosphorus_mol = 1, .calcium_mol = 1 });
    try certifyField(result, bp.hydroxyapatite_mol_per_m3, ap.hydroxyapatite_mol_per_m3, old_carrier, new_carrier, .{ .phosphorus_mol = 3, .calcium_mol = 5 });
    try certifyField(result, bp.monocalcium_phosphate_mol_per_m3, ap.monocalcium_phosphate_mol_per_m3, old_carrier, new_carrier, .{ .phosphorus_mol = 2, .calcium_mol = 1 });

    const before_salt = before.salt_minerals;
    const after_salt = after.salt_minerals;
    try certifyField(result, before_salt.gibbsite_mol_per_m3, after_salt.gibbsite_mol_per_m3, old_carrier, new_carrier, .{ .aluminum_mol = 1 });
    try certifyField(result, before_salt.iron_hydroxide_mol_per_m3, after_salt.iron_hydroxide_mol_per_m3, old_carrier, new_carrier, .{ .iron_mol = 1 });
    try certifyField(result, before_salt.calcite_mol_per_m3, after_salt.calcite_mol_per_m3, old_carrier, new_carrier, .{ .carbon_mol = 1, .calcium_mol = 1 });
    try certifyField(result, before_salt.gypsum_mol_per_m3, after_salt.gypsum_mol_per_m3, old_carrier, new_carrier, .{ .calcium_mol = 1, .sulfur_mol = 1 });
}

noinline fn accumulateDryMassRoundoff(
    result: *RoundoffAllowance,
    before: litter_chemistry.Cell,
    after: litter_chemistry.Cell,
    old_carrier: f64,
    new_carrier: f64,
) !void {
    const bx = before.exchange;
    const ax = after.exchange;
    try certifyField(result, bx.ammonium_mol_per_megagram, ax.ammonium_mol_per_megagram, old_carrier, new_carrier, .{ .nitrogen_mol = 1 });
    try certifyField(result, bx.aluminum_mol_per_megagram, ax.aluminum_mol_per_megagram, old_carrier, new_carrier, .{ .aluminum_mol = 1 });
    try certifyField(result, bx.iron_mol_per_megagram, ax.iron_mol_per_megagram, old_carrier, new_carrier, .{ .iron_mol = 1 });
    try certifyField(result, bx.calcium_mol_per_megagram, ax.calcium_mol_per_megagram, old_carrier, new_carrier, .{ .calcium_mol = 1 });
    try certifyField(result, bx.magnesium_mol_per_megagram, ax.magnesium_mol_per_megagram, old_carrier, new_carrier, .{ .magnesium_mol = 1 });
    try certifyField(result, bx.sodium_mol_per_megagram, ax.sodium_mol_per_megagram, old_carrier, new_carrier, .{ .sodium_mol = 1 });
    try certifyField(result, bx.potassium_mol_per_megagram, ax.potassium_mol_per_megagram, old_carrier, new_carrier, .{ .potassium_mol = 1 });

    const bp = before.phosphate_surface;
    const ap = after.phosphate_surface;
    try certifyField(result, bp.adsorbed_hpo4_mol_p_per_megagram, ap.adsorbed_hpo4_mol_p_per_megagram, old_carrier, new_carrier, .{ .phosphorus_mol = 1 });
    try certifyField(result, bp.adsorbed_h2po4_mol_p_per_megagram, ap.adsorbed_h2po4_mol_p_per_megagram, old_carrier, new_carrier, .{ .phosphorus_mol = 1 });
}

fn testInventoryInputs(dry_mass_megagrams: f64) InventoryInputs {
    return .{
        .dry_mass_megagrams = dry_mass_megagrams,
        .carbon_g_per_mol = 12,
        .nitrogen_g_per_mol = 14,
        .phosphorus_g_per_mol = 31,
    };
}

test "surface water carrier preview certifies every authoritative element lane without mutation" {
    var state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    const cell = &state.cells[0];
    cell.ammonium_mol_per_m3 = 1.23456789012345;
    cell.hpo4_mol_p_per_m3 = 2.34567890123456;
    cell.aluminum_mol_per_m3 = 3.45678901234567;
    cell.iron_mol_per_m3 = 4.56789012345678;
    cell.calcium_mol_per_m3 = 5.67890123456789;
    cell.magnesium_mol_per_m3 = 6.78901234567891;
    cell.sodium_mol_per_m3 = 7.89012345678912;
    cell.potassium_mol_per_m3 = 8.90123456789123;
    cell.sulfate_mol_per_m3 = 9.01234567891234;
    cell.chloride_mol_per_m3 = 1.13579135791357;
    cell.carbonate_mol_per_m3 = 2.24680246802468;
    cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 = 3.35791357913579;
    cell.salt_minerals.gibbsite_mol_per_m3 = 4.4680246802468;
    cell.salt_minerals.iron_hydroxide_mol_per_m3 = 5.57913579135791;
    cell.salt_minerals.calcite_mol_per_m3 = 6.68024680246802;
    cell.salt_minerals.gypsum_mol_per_m3 = 7.79135791357913;
    state.mineral_reference_water_m3[0] = 7.1;

    const before = state.cells[0];
    const mineral_reference_before = state.mineral_reference_water_m3[0];
    const dry_reference_before = state.dry_reference_water_m3[0];
    const allowance = try previewCellWaterRoundoff(&state, 0, 7.1, 3.7, testInventoryInputs(2.9));
    try std.testing.expectEqualDeep(before, state.cells[0]);
    try std.testing.expectEqual(mineral_reference_before, state.mineral_reference_water_m3[0]);
    try std.testing.expectEqual(dry_reference_before, state.dry_reference_water_m3[0]);
    inline for (.{
        "carbon_mol",
        "nitrogen_mol",
        "phosphorus_mol",
        "aluminum_mol",
        "iron_mol",
        "calcium_mol",
        "magnesium_mol",
        "sodium_mol",
        "potassium_mol",
        "sulfur_mol",
        "chloride_mol",
    }) |name| try std.testing.expect(@field(allowance, name) > 0);
    try std.testing.expectEqual(@as(f64, 0), allowance.silicon_mol);
}

test "vector carrier preview certifies reconstructed old carrier drift" {
    var state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].aluminum_mol_per_m3 = 1;
    state.cells[0].carbonate_mol_per_m3 = 1;
    state.cells[0].bicarbonate_mol_per_m3 = 0.3;
    state.cells[0].exchange.aluminum_mol_per_megagram = 0.7;
    state.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3 = 0.2;
    state.cells[0].salt_minerals.gibbsite_mol_per_m3 = 0.4;
    state.mineral_reference_water_m3[0] = 5.3;
    const inventory_before_live_water_m3: f64 = 7.1;
    const accepted_change_m3: f64 = 3.7;
    const new_live_water_m3: f64 = 10.8;
    const scale_source_live_water_m3 = new_live_water_m3 - accepted_change_m3;
    const dry_mass_megagrams: f64 = 2.9;
    try std.testing.expect(scale_source_live_water_m3 != inventory_before_live_water_m3);

    const before = state.cells[0];
    const before_inventory = try carrierOwnedInventory(
        before,
        inventory_before_live_water_m3,
        state.mineral_reference_water_m3[0],
        testInventoryInputs(dry_mass_megagrams),
    );
    const allowance = try previewCellWaterRoundoffFromScaleSource(
        &state,
        0,
        inventory_before_live_water_m3,
        scale_source_live_water_m3,
        new_live_water_m3,
        testInventoryInputs(dry_mass_megagrams),
    );
    try std.testing.expectEqualDeep(before, state.cells[0]);

    try rebaseFromAcceptedLiquidWaterChange(
        &state,
        &.{new_live_water_m3},
        &.{accepted_change_m3},
    );
    const drift = @abs(
        state.cells[0].aluminum_mol_per_m3 * new_live_water_m3 -
            before.aluminum_mol_per_m3 * inventory_before_live_water_m3,
    );
    try std.testing.expect(drift > 0);
    try std.testing.expect(allowance.aluminum_mol >= drift);
    const after_inventory = try carrierOwnedInventory(
        state.cells[0],
        new_live_water_m3,
        state.mineral_reference_water_m3[0],
        testInventoryInputs(dry_mass_megagrams),
    );
    try std.testing.expect(
        allowance.carbon_g >= @abs(after_inventory.carbon_g - before_inventory.carbon_g),
    );
    try std.testing.expect(
        allowance.aluminum_mol >= @abs(
            after_inventory.elements.aluminum_mol - before_inventory.elements.aluminum_mol,
        ),
    );
}

test "grouped carbon census drift is certified when individual products are unchanged" {
    var state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].carbonate_mol_per_m3 = 1;
    state.cells[0].bicarbonate_mol_per_m3 = 0.3;
    const old_water_m3: f64 = 7.1;
    const new_water_m3: f64 = 10.8;
    const inputs = testInventoryInputs(0);
    const before = state.cells[0];
    const before_inventory = try carrierOwnedInventory(before, old_water_m3, 0, inputs);
    const allowance = try previewCellWaterRoundoff(
        &state,
        0,
        old_water_m3,
        new_water_m3,
        inputs,
    );
    try rebaseCellForAcceptedWater(&state, 0, old_water_m3, new_water_m3);
    try std.testing.expectEqual(
        before.carbonate_mol_per_m3 * old_water_m3,
        state.cells[0].carbonate_mol_per_m3 * new_water_m3,
    );
    try std.testing.expectEqual(
        before.bicarbonate_mol_per_m3 * old_water_m3,
        state.cells[0].bicarbonate_mol_per_m3 * new_water_m3,
    );
    const after_inventory = try carrierOwnedInventory(
        state.cells[0],
        new_water_m3,
        new_water_m3,
        inputs,
    );
    const grouped_drift_g = @abs(after_inventory.carbon_g - before_inventory.carbon_g);
    try std.testing.expect(grouped_drift_g > 0);
    try std.testing.expect(allowance.carbon_g >= grouped_drift_g);
}

test "surface mineral carrier preview uses mineral stoichiometry and is mutation free" {
    var cell = std.mem.zeroes(litter_chemistry.Cell);
    cell.phosphate_minerals.aluminum_phosphate_mol_per_m3 = 1.23456789012345;
    cell.phosphate_minerals.iron_phosphate_mol_per_m3 = 2.34567890123456;
    cell.phosphate_minerals.dicalcium_phosphate_mol_per_m3 = 3.45678901234567;
    cell.salt_minerals.gibbsite_mol_per_m3 = 4.56789012345678;
    cell.salt_minerals.iron_hydroxide_mol_per_m3 = 5.67890123456789;
    cell.salt_minerals.calcite_mol_per_m3 = 6.78901234567891;
    cell.salt_minerals.gypsum_mol_per_m3 = 7.89012345678912;
    const before = cell;
    const allowance = try previewMineralCellRoundoff(cell, 4.7, testInventoryInputs(2.9), 8.3, 3.1);
    try std.testing.expectEqualDeep(before, cell);
    inline for (.{ "carbon_mol", "phosphorus_mol", "aluminum_mol", "iron_mol", "calcium_mol", "sulfur_mol" }) |name|
        try std.testing.expect(@field(allowance, name) > 0);
    inline for (.{ "nitrogen_mol", "magnesium_mol", "sodium_mol", "potassium_mol", "chloride_mol", "silicon_mol" }) |name|
        try std.testing.expectEqual(@as(f64, 0), @field(allowance, name));
}

test "surface dry mass preview certifies exchange and adsorbed phosphate lanes" {
    var cell = std.mem.zeroes(litter_chemistry.Cell);
    cell.exchange.ammonium_mol_per_megagram = 1.23456789012345;
    cell.exchange.aluminum_mol_per_megagram = 2.34567890123456;
    cell.exchange.iron_mol_per_megagram = 3.45678901234567;
    cell.exchange.calcium_mol_per_megagram = 4.56789012345678;
    cell.exchange.magnesium_mol_per_megagram = 5.67890123456789;
    cell.exchange.sodium_mol_per_megagram = 6.78901234567891;
    cell.exchange.potassium_mol_per_megagram = 7.89012345678912;
    cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram = 8.90123456789123;
    const before = cell;
    const allowance = try previewCellDryMassRoundoff(cell, 4.7, 8.3, testInventoryInputs(9.7), 9.7, 2.9);
    try std.testing.expectEqualDeep(before, cell);
    inline for (.{ "nitrogen_mol", "phosphorus_mol", "aluminum_mol", "iron_mol", "calcium_mol", "magnesium_mol", "sodium_mol", "potassium_mol" }) |name|
        try std.testing.expect(@field(allowance, name) > 0);
    inline for (.{ "carbon_mol", "sulfur_mol", "chloride_mol", "silicon_mol" }) |name|
        try std.testing.expectEqual(@as(f64, 0), @field(allowance, name));
}

test "surface carrier previews reject invalid inputs without mutation" {
    var state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].aluminum_mol_per_m3 = 1;
    const before = state.cells[0];
    try std.testing.expectEqualDeep(
        RoundoffAllowance{},
        try previewCellWaterRoundoff(&state, 0, 1, 1, testInventoryInputs(1)),
    );
    state.cells[0].carbonate_mol_per_m3 = -1;
    try std.testing.expectError(
        error.InvalidWaterNormalizedLitterChemistryPool,
        previewCellWaterRoundoff(&state, 0, 1, 1, testInventoryInputs(1)),
    );
    state.cells[0] = before;
    try std.testing.expectError(
        error.InvalidLitterChemistryCarrier,
        previewCellWaterRoundoff(&state, 0, 1, std.math.nan(f64), testInventoryInputs(1)),
    );
    try std.testing.expectEqualDeep(before, state.cells[0]);
    try std.testing.expectError(
        error.InvalidLitterChemistryCarrier,
        previewMineralCellRoundoff(before, 1, testInventoryInputs(1), 1, std.math.inf(f64)),
    );
    try std.testing.expectEqualDeep(before, state.cells[0]);

    var invalid_fixed = before;
    invalid_fixed.carbonate_mol_per_m3 = -1;
    try std.testing.expectError(
        error.InvalidWaterNormalizedLitterChemistryPool,
        previewMineralCellRoundoff(invalid_fixed, 1, testInventoryInputs(1), 1, 2),
    );
    try std.testing.expectError(
        error.InvalidWaterNormalizedLitterChemistryPool,
        previewCellDryMassRoundoff(invalid_fixed, 1, 1, testInventoryInputs(1), 1, 2),
    );
    try std.testing.expectEqualDeep(before, state.cells[0]);
}

test "surface litter carrier preserves inorganic carbon phosphorus and ions" {
    var state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var cell = &state.cells[0];
    cell.carbon_dioxide_mol_per_m3 = 2;
    cell.bicarbonate_mol_per_m3 = 3;
    cell.h2po4_mol_p_per_m3 = 5;
    cell.calcium_mol_per_m3 = 7;
    cell.phosphate_minerals.hydroxyapatite_mol_per_m3 = 11;
    cell.salt_minerals.calcite_mol_per_m3 = 13;
    state.mineral_reference_water_m3[0] = 2;

    try rebaseFromAcceptedLiquidWaterChange(&state, &.{0.5}, &.{-1.5});
    try std.testing.expectEqual(@as(f64, 8), cell.carbon_dioxide_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 12), cell.bicarbonate_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 20), cell.h2po4_mol_p_per_m3);
    try std.testing.expectEqual(@as(f64, 28), cell.calcium_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 44), cell.phosphate_minerals.hydroxyapatite_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 52), cell.salt_minerals.calcite_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 4), cell.carbon_dioxide_mol_per_m3 * 0.5);
    try std.testing.expectEqual(@as(f64, 10), cell.h2po4_mol_p_per_m3 * 0.5);
    try std.testing.expectEqual(@as(f64, 26), cell.salt_minerals.calcite_mol_per_m3 * 0.5);
}

test "rewetting scales aqueous and mineral pools from independent references" {
    var state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.dry_reference_water_m3[0] = 3;
    state.mineral_reference_water_m3[0] = 4;
    state.cells[0].nitrate_mol_per_m3 = 2;
    state.cells[0].salt_minerals.calcite_mol_per_m3 = 5;

    try rebaseFromAcceptedLiquidWaterChange(&state, &.{6}, &.{6});

    try std.testing.expectEqual(@as(f64, 1), state.cells[0].nitrate_mol_per_m3);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0), state.cells[0].salt_minerals.calcite_mol_per_m3, 1e-15);
    try std.testing.expectEqual(@as(f64, 6), state.cells[0].nitrate_mol_per_m3 * 6);
    try std.testing.expectEqual(@as(f64, 20), state.cells[0].salt_minerals.calcite_mol_per_m3 * 6);
    try std.testing.expectEqual(@as(f64, 0), state.dry_reference_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 6), state.mineral_reference_water_m3[0]);
}

test "external water transaction rebases solid minerals from their own reference" {
    var cell: litter_chemistry.Cell = std.mem.zeroes(litter_chemistry.Cell);
    cell.salt_minerals.calcite_mol_per_m3 = 5;
    cell.phosphate_minerals.hydroxyapatite_mol_per_m3 = 7;
    const reference_after = try rebaseMineralCellForAcceptedWater(&cell, 4, 2);
    try std.testing.expectEqual(@as(f64, 2), reference_after);
    try std.testing.expectEqual(@as(f64, 20), cell.salt_minerals.calcite_mol_per_m3 * reference_after);
    try std.testing.expectEqual(@as(f64, 28), cell.phosphate_minerals.hydroxyapatite_mol_per_m3 * reference_after);

    const before = cell;
    const dry_reference = try rebaseMineralCellForAcceptedWater(&cell, reference_after, 0);
    try std.testing.expectEqual(reference_after, dry_reference);
    try std.testing.expectEqualDeep(before, cell);

    var unbound: litter_chemistry.Cell = std.mem.zeroes(litter_chemistry.Cell);
    unbound.salt_minerals.gypsum_mol_per_m3 = 1;
    const unbound_before = unbound;
    try std.testing.expectError(
        error.LitterChemistryMassWithoutWaterCarrier,
        rebaseMineralCellForAcceptedWater(&unbound, 0, 3),
    );
    try std.testing.expectEqualDeep(unbound_before, unbound);
}

test "surface litter carrier leaves dry normalized pools untouched" {
    var state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].carboxyl_hydrogen_mol_per_megagram = 2;
    state.cells[0].exchange.calcium_mol_per_megagram = 3;
    state.cells[0].phosphate_surface.adsorbed_h2po4_mol_p_per_megagram = 4;
    try rebaseFromAcceptedLiquidWaterChange(&state, &.{2}, &.{1});
    try std.testing.expectEqual(@as(f64, 2), state.cells[0].carboxyl_hydrogen_mol_per_megagram);
    try std.testing.expectEqual(@as(f64, 3), state.cells[0].exchange.calcium_mol_per_megagram);
    try std.testing.expectEqual(@as(f64, 4), state.cells[0].phosphate_surface.adsorbed_h2po4_mol_p_per_megagram);
}

test "surface litter carrier validation is atomic and rejects invalid carriers" {
    var state = try litter_chemistry.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.cells[0].nitrate_mol_per_m3 = 2;
    state.cells[1].sulfate_mol_per_m3 = 3;
    // A carrier that would go negative is still rejected, and rejection leaves
    // every cell untouched rather than partially applied.
    try std.testing.expectError(
        error.InvalidLitterChemistryCarrier,
        rebaseFromAcceptedLiquidWaterChange(&state, &.{ 2, 1 }, &.{ 1, 2 }),
    );
    try std.testing.expectEqual(@as(f64, 2), state.cells[0].nitrate_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 3), state.cells[1].sulfate_mol_per_m3);
}

test "cell carrier preflight supports an all-cell atomic commit" {
    var state = try litter_chemistry.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.cells[0].nitrate_mol_per_m3 = 2;
    state.cells[0].salt_minerals.calcite_mol_per_m3 = 3;
    state.mineral_reference_water_m3[0] = 4;
    state.cells[1].sulfate_mol_per_m3 = std.math.nan(f64);
    const first_before = state.cells[0];

    try validateCellForAcceptedWater(&state, 0, 4, 2);
    try std.testing.expectError(
        error.InvalidWaterNormalizedLitterChemistryPool,
        validateCellForAcceptedWater(&state, 1, 4, 2),
    );
    // The caller has not entered its commit pass, so a later invalid cell
    // cannot leave the valid first cell partly diluted.
    try std.testing.expectEqualDeep(first_before, state.cells[0]);

    state.cells[1].sulfate_mol_per_m3 = 0;
    try validateCellForAcceptedWater(&state, 1, 4, 2);
    try rebaseCellForAcceptedWater(&state, 0, 4, 2);
    try rebaseCellForAcceptedWater(&state, 1, 4, 2);
    try std.testing.expectEqual(@as(f64, 8), state.cells[0].nitrate_mol_per_m3 * 2);
    try std.testing.expectEqual(@as(f64, 12), state.cells[0].salt_minerals.calcite_mol_per_m3 * 2);
}

test "evaporating the carrier to dryness conserves solute mass" {
    // EXEC-004: this used to fail with LitterChemistryMassWithoutWaterCarrier,
    // which forced the shipped runscript to disable surface evaporation.
    var state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    const cell = &state.cells[0];
    cell.nitrate_mol_per_m3 = 4;
    // Establish a wet carrier of 2 m3, so the extensive amount is 8 mol.
    try rebaseFromAcceptedLiquidWaterChange(&state, &.{2}, &.{0});
    try std.testing.expectEqual(@as(f64, 2), state.mineral_reference_water_m3[0]);
    const amount_before = cell.nitrate_mol_per_m3 * state.mineral_reference_water_m3[0];

    // Evaporate to exactly dry. This must not error.
    try rebaseFromAcceptedLiquidWaterChange(&state, &.{0}, &.{-2});
    // Concentration and reference are held together, so the amount is unchanged.
    const amount_dry = cell.nitrate_mol_per_m3 * state.mineral_reference_water_m3[0];
    try std.testing.expectApproxEqRel(amount_before, amount_dry, 1e-15);
}

test "rewetting a dry carrier recovers the retained solute mass" {
    var state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    const cell = &state.cells[0];
    cell.nitrate_mol_per_m3 = 4;
    try rebaseFromAcceptedLiquidWaterChange(&state, &.{2}, &.{0});
    const amount_before = cell.nitrate_mol_per_m3 * state.mineral_reference_water_m3[0];

    try rebaseFromAcceptedLiquidWaterChange(&state, &.{0}, &.{-2});
    // Rewet to 8 m3: four times the original carrier.
    try rebaseFromAcceptedLiquidWaterChange(&state, &.{8}, &.{8});
    try std.testing.expectEqual(@as(f64, 8), state.mineral_reference_water_m3[0]);
    const amount_after = cell.nitrate_mol_per_m3 * state.mineral_reference_water_m3[0];
    // The mass survived the round trip through dryness, which is exactly what a
    // naive rescale-from-zero cannot do.
    try std.testing.expectApproxEqRel(amount_before, amount_after, 1e-14);
    // Diluted into four times the water, so a quarter of the concentration.
    try std.testing.expectApproxEqRel(@as(f64, 1), cell.nitrate_mol_per_m3, 1e-14);
}

test "solute mass survives an arbitrary wet dry rewet sequence" {
    var state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    const cell = &state.cells[0];
    cell.nitrate_mol_per_m3 = 2.5;
    try rebaseFromAcceptedLiquidWaterChange(&state, &.{4}, &.{0});
    const amount_before = cell.nitrate_mol_per_m3 * state.mineral_reference_water_m3[0];

    var carrier: f64 = 4;
    for ([_]f64{ 2, 0.5, 0, 3, 0, 0, 7 }) |next| {
        try rebaseFromAcceptedLiquidWaterChange(&state, &.{next}, &.{next - carrier});
        carrier = next;
        // The invariant holds after every single step, including consecutive dry
        // steps, not merely at the end.
        const amount = cell.nitrate_mol_per_m3 * state.mineral_reference_water_m3[0];
        try std.testing.expectApproxEqRel(amount_before, amount, 1e-13);
    }
}

test "surface litter dry carrier preserves exchange and phosphate amounts" {
    var state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].carboxyl_hydrogen_mol_per_megagram = 2;
    state.cells[0].exchange.calcium_mol_per_megagram = 3;
    state.cells[0].phosphate_surface.adsorbed_h2po4_mol_p_per_megagram = 5;
    state.cells[0].h2po4_mol_p_per_m3 = 7;

    try rebaseFromAcceptedDryMassChange(&state, &.{2}, &.{0.5});
    try std.testing.expectEqual(@as(f64, 8), state.cells[0].carboxyl_hydrogen_mol_per_megagram);
    try std.testing.expectEqual(@as(f64, 12), state.cells[0].exchange.calcium_mol_per_megagram);
    try std.testing.expectEqual(@as(f64, 20), state.cells[0].phosphate_surface.adsorbed_h2po4_mol_p_per_megagram);
    try std.testing.expectEqual(@as(f64, 7), state.cells[0].h2po4_mol_p_per_m3);
}

test "surface litter dry carrier validation is atomic" {
    var state = try litter_chemistry.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.cells[0].exchange.calcium_mol_per_megagram = 2;
    state.cells[1].phosphate_surface.adsorbed_hpo4_mol_p_per_megagram = 3;
    try std.testing.expectError(
        error.LitterChemistryMassWithoutDryCarrier,
        rebaseFromAcceptedDryMassChange(&state, &.{ 1, 1 }, &.{ 2, 0 }),
    );
    try std.testing.expectEqual(@as(f64, 2), state.cells[0].exchange.calcium_mol_per_megagram);
    try std.testing.expectEqual(@as(f64, 3), state.cells[1].phosphate_surface.adsorbed_hpo4_mol_p_per_megagram);
}

/// Pure-water molarity from the production deck's `water_equilibrium` record
/// (`soil_chemistry_reaction_parameters.txt`), which seeds every litter cell's
/// solvent-water coordinate at `startq`/`starte`.
const solvent_water_mol_per_m3: f64 = 55555.555555555555;

test "litter carrier rebase leaves the solvent water molarity invariant" {
    var state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    const cell = &state.cells[0];
    cell.water_mol_per_m3 = solvent_water_mol_per_m3;
    // A genuine dissolved inventory on the same carrier, to prove the
    // exclusion is specific to the solvent and not a blanket opt-out.
    cell.calcium_mol_per_m3 = 7;
    state.mineral_reference_water_m3[0] = 2;

    // Wetting: the carrier quadruples. A solute's molarity must fall by 4x;
    // the solvent's must not move, because four times the water volume also
    // contains four times as many water molecules.
    try rebaseFromAcceptedLiquidWaterChange(&state, &.{8}, &.{6});
    try std.testing.expectEqual(solvent_water_mol_per_m3, cell.water_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 7.0 / 4.0), cell.calcium_mol_per_m3);

    // Drying back to the original carrier restores the solute exactly and
    // still leaves the solvent untouched.
    try rebaseFromAcceptedLiquidWaterChange(&state, &.{2}, &.{-6});
    try std.testing.expectEqual(solvent_water_mol_per_m3, cell.water_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 7), cell.calcium_mol_per_m3);

    // Single-cell commit path shares the predicate.
    try rebaseCellForAcceptedWater(&state, 0, 2, 5);
    try std.testing.expectEqual(solvent_water_mol_per_m3, cell.water_mol_per_m3);
}

test "repeated carrier transactions cannot ratchet the solvent water down" {
    // Regression for the `year1998-day88-hour24` production
    // `NegativeLitterChemistryState`. `isWaterNormalized` used to match
    // `water_mol_per_m3` (it contains `_mol` and ends in `_per_m3`), so
    // `applyAqueousScale` rescaled the solvent molarity by `old / new` on
    // every accepted litter-water change, as if it were a dissolved load.
    //
    // The production run's own `TEMP_CHEMISTRY_TRACE` shows this is a
    // per-hour ratchet, not one bad transaction. It measured:
    //
    //   hour 1   water_m3 = 8.012842196814723e-4  water = 55466.503973951585
    //   day 89   water_m3 = 2.7081754312875198e-3 water = 1.5749925066128579e-6
    //
    // The litter holds 3.4x MORE water at the failure yet reports a molarity
    // 3.5e10 times smaller, and `concentration * carrier` is not conserved
    // between the two samples either (44.4 vs 4.27e-9). Over the 2125 hours
    // between them that is a compounding ~1.09%/hour loss: several carrier
    // transactions run per hour and their reconstructed `old`/`new` pairs do
    // not compose back to unity over a closed wet/dry cycle.
    //
    // The fix does not depend on making those pairs consistent. An intensive
    // coordinate is simply never rescaled, so the ratchet has no purchase
    // regardless of how many transactions run or with what ratios.
    const hour1_carrier_m3: f64 = 8.012842196814723e-4;
    const failure_carrier_m3: f64 = 2.7081754312875198e-3;

    var state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    const cell = &state.cells[0];
    cell.water_mol_per_m3 = solvent_water_mol_per_m3;
    // A real dissolved load, to keep proving the exclusion is solvent-only.
    cell.calcium_mol_per_m3 = 0.004660766574984104;
    const dissolved_amount_mol = cell.calcium_mol_per_m3 * hour1_carrier_m3;
    state.mineral_reference_water_m3[0] = hour1_carrier_m3;

    // Drive the measured wetting/drying range repeatedly. Under the defect
    // each round trip lost ~1% of the solvent coordinate; it must now be
    // bit-for-bit unchanged after every one of them.
    var carrier = hour1_carrier_m3;
    var cycle: usize = 0;
    while (cycle < 64) : (cycle += 1) {
        for ([_]f64{ failure_carrier_m3, hour1_carrier_m3 }) |next| {
            try rebaseFromAcceptedLiquidWaterChange(
                &state,
                &.{next},
                &.{next - carrier},
            );
            carrier = next;
            try std.testing.expectEqual(
                solvent_water_mol_per_m3,
                cell.water_mol_per_m3,
            );
        }
    }
    // The dissolved load still round-trips its extensive amount, so the
    // rescale itself is intact for the pools that genuinely need it.
    try std.testing.expectApproxEqRel(
        dissolved_amount_mol,
        cell.calcium_mol_per_m3 * carrier,
        1e-12,
    );

    // Why the drained coordinate is fatal. At the logged H+/OH- pair the
    // starting-water RHHX projection (SOLUTE.F 4238--4265) is undersaturated
    // against Kw, so water must dissociate: the equal reaction extent is
    // negative and is subtracted from this coordinate in
    // `litter_reaction_rates.projectWaterEquilibriumOpaque`. Its magnitude is
    // set by sqrt(Kw), never by the carrier, so the drained value is overdrawn
    // by orders of magnitude and `litter_chemistry_solve.applyHourlyCell`'s
    // entry `validateCell` rejects the cell. The correct solvent molarity
    // absorbs the same extent without leaving the physical domain.
    const water_equilibrium = @import("../soil/solute/water_equilibrium.zig");
    const projected = try water_equilibrium.solve(.{
        .hydrogen_concentration_mol_per_m3 = 0.00004648920793575199,
        .hydroxide_concentration_mol_per_m3 = 0.0000002257936610147606,
        .monovalent_activity_coefficient = 1,
        .water_activity_product_mol2_per_m6 = 1.0e-8,
        .negligible_concentration_mol_per_m3 = 1.0e-32,
    });
    const extent = projected.equal_reaction_extent_mol_per_m3;
    const logged_drained_water: f64 = 0.0000015749925066128579;
    try std.testing.expect(extent < 0);
    try std.testing.expect(logged_drained_water + extent < 0);
    try std.testing.expect(cell.water_mol_per_m3 + extent > 0);
}

test "a negative solvent water molarity is rejected with its own field context" {
    var state = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.cells[0].water_mol_per_m3 = -1;
    try std.testing.expectError(
        error.InvalidLitterSolventWaterConcentration,
        rebaseCellForAcceptedWater(&state, 0, 1, 2),
    );
    // A dry carrier is not "mass without a carrier" for an intensive
    // coordinate: a positive solvent molarity must pass with no live water.
    state.cells[0].water_mol_per_m3 = solvent_water_mol_per_m3;
    try validateCellForAcceptedWater(&state, 0, 0, 0);
}
