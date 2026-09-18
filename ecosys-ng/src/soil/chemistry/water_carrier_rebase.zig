const std = @import("std");
const chemistry = @import("../solute/chemistry_state.zig");

/// Source-local binary64 provenance for every authoritative landscape-inventory
/// lane changed by a pure-water carrier rebase. Final C/P census products are
/// certified in grams at their authoritative expression boundary rather than
/// inferred by scaling a molar discrepancy afterward. Contributions are
/// nonnegative and accumulated without cancellation.
pub const RoundoffAllowance = struct {
    /// Final-unit grouped census lanes. Endpoint molar-mass products are not
    /// bounded by multiplying a molar endpoint delta after the fact.
    carbon_g: f64 = 0,
    nitrogen_g: f64 = 0,
    phosphorus_g: f64 = 0,
    carbon_mol: f64 = 0,
    nitrogen_mol: f64 = 0,
    phosphorus_mol: f64 = 0,
    aluminum_mol: f64 = 0,
    iron_mol: f64 = 0,
    calcium_mol: f64 = 0,
    magnesium_mol: f64 = 0,
    sodium_mol: f64 = 0,
    potassium_mol: f64 = 0,
    sulfur_mol: f64 = 0,
    chloride_mol: f64 = 0,
    silicon_mol: f64 = 0,

    pub noinline fn add(self: *RoundoffAllowance, contribution: RoundoffAllowance) !void {
        inline for (std.meta.fields(RoundoffAllowance)) |field| {
            const value = @field(contribution, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidSoilChemistryWaterCarrierRoundoff;
            if (value != 0) {
                @field(self, field.name) = try addRoundUp(
                    @field(self, field.name),
                    value,
                );
            }
        }
    }

    pub noinline fn validate(self: RoundoffAllowance) !void {
        inline for (std.meta.fields(RoundoffAllowance)) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidSoilChemistryWaterCarrierRoundoff;
        }
    }
};

/// Shared source-local certification for a concentration-owned extensive
/// inventory with the census shape `concentration * carrier`.  Surface litter
/// and soil chemistry deliberately use this one implementation so both prove
/// their carrier rebases with the same FMA/TwoDiff reconstruction, outward
/// rounding, and Higham operation-count bound.
pub noinline fn accumulateCertifiedFullCarrierField(
    result: *RoundoffAllowance,
    before_concentration: f64,
    after_concentration: f64,
    old_carrier: f64,
    new_carrier: f64,
    coefficients: RoundoffAllowance,
) !void {
    return accumulateCertifiedFullWaterField(
        result,
        before_concentration,
        after_concentration,
        old_carrier,
        new_carrier,
        coefficients,
    );
}

/// Error-free endpoint-difference envelope for a source-owned grouped census
/// expression. Callers combine this with the independent per-field rebase
/// proof using `max`, so aggregation roundoff is covered without widening a
/// physical tolerance or double-counting the same arithmetic path.
pub noinline fn certifyGroupedEndpoint(before: f64, after: f64) !f64 {
    if (!std.math.isFinite(before) or !std.math.isFinite(after) or
        before < 0 or after < 0)
        return error.InvalidSoilChemistryWaterCarrierRoundoff;
    const difference = after - before;
    if (!std.math.isFinite(difference))
        return error.InvalidSoilChemistryWaterCarrierRoundoff;
    const error_term = twoDiffError(after, before, difference);
    return addRoundUp(@abs(difference), @abs(error_term));
}

pub noinline fn addCertifiedBounds(left: f64, right: f64) !f64 {
    return addRoundUp(left, right);
}

pub noinline fn scaleCertifiedBound(bound: f64, scale: f64) !f64 {
    return multiplyRoundUp(bound, scale);
}

/// Independent Higham envelope for the difference of two nonnegative grouped
/// endpoint evaluations. `operation_count` is the audited upper bound across
/// both endpoint expression paths; `member_bound` comes only from the
/// independently certified member mutations.
pub noinline fn groupedIndependentBound(
    member_bound: f64,
    before: f64,
    after: f64,
    operation_count: u8,
) !f64 {
    if (operation_count == 0)
        return error.InvalidSoilChemistryWaterCarrierRoundoff;
    const endpoint_magnitude = try addRoundUp(before, after);
    const evaluation_bound = try multiplyRoundUp(
        roundingGamma(std.math.floatEps(f64) / 2, operation_count),
        endpoint_magnitude,
    );
    return addRoundUp(
        try addRoundUp(member_bound, evaluation_bound),
        @as(f64, @floatFromInt(operation_count)) * std.math.floatTrueMin(f64),
    );
}

pub noinline fn requireCertifiedGroupedObserved(
    observed_bound: f64,
    independent_bound: f64,
) !f64 {
    if (!std.math.isFinite(observed_bound) or observed_bound < 0 or
        !std.math.isFinite(independent_bound) or independent_bound < 0)
        return error.InvalidSoilChemistryWaterCarrierRoundoff;
    if (observed_bound > independent_bound)
        return error.SoilChemistryWaterCarrierRoundoffExceeded;
    return observed_bound;
}

pub noinline fn certifyGroupedEndpointWithin(
    before: f64,
    after: f64,
    independent_bound: f64,
) !f64 {
    return requireCertifiedGroupedObserved(
        try certifyGroupedEndpoint(before, after),
        independent_bound,
    );
}

/// Phosphate-zone volume fractions used by the production landscape inventory.
pub const InventoryFractions = struct {
    phosphate_non_band: f64,
    phosphate_band: f64,

    pub fn validate(self: InventoryFractions) !void {
        inline for (std.meta.fields(InventoryFractions)) |field| {
            const fraction = @field(self, field.name);
            if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
                return error.InvalidSoilChemistryInventoryFraction;
        }
        // This is the production chemistry-zone partition contract used by
        // landscape_mass_inventory_phosphorus_ions.validatePhosphateFractions.
        const production_pair_tolerance = 1.0e-12;
        if (@abs(self.phosphate_non_band + self.phosphate_band - 1) >
            production_pair_tolerance)
            return error.InvalidSoilChemistryInventoryFraction;
    }
};

fn validateInventoryMolarMasses(
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !void {
    inline for (.{ carbon_g_per_mol, phosphorus_g_per_mol }) |molar_mass|
        if (!std.math.isFinite(molar_mass) or molar_mass <= 0)
            return error.InvalidSoilChemistryInventoryMolarMass;
}

/// Preserves every extensive amount represented by a water-normalized soil
/// chemistry coordinate after an accepted pure-water change. SOLUTE stores its
/// mineral pools as extensive mol (`solute.f:774--793`) and divides by `VOLW`
/// when entering the reaction solve. Zig retains those solve coordinates, so
/// geochemistry solids require the same carrier translation as aqueous and
/// phosphate coordinates.
pub fn rebaseLayer(
    state: *chemistry.State,
    layer: usize,
    old_water_m3: f64,
    new_water_m3: f64,
) !void {
    try validateLayerRebase(state, layer, old_water_m3, new_water_m3);
    if (new_water_m3 == 0) {
        rememberDryCarrier(state, layer, old_water_m3);
        return;
    }
    const preview = try prepareScaledLayer(
        state,
        layer,
        sourceWaterM3(state, layer, old_water_m3),
        new_water_m3,
    );
    commitScaledLayer(state, layer, preview);
    state.dry_reference_water_m3[layer] = 0;
}

const AqueousState = @typeInfo(@TypeOf(@as(chemistry.State, undefined).aqueous)).pointer.child;
const PhosphateState = @typeInfo(@TypeOf(@as(chemistry.State, undefined).non_band_phosphate)).pointer.child;
const GeochemistrySolidState = @typeInfo(@TypeOf(@as(chemistry.State, undefined).geochemistry_solids)).pointer.child;

const ScaledLayer = struct {
    aqueous_after: AqueousState,
    non_band_after: PhosphateState,
    band_after: PhosphateState,
    geochemistry_solids_after: GeochemistrySolidState,
};

const LayerRebasePreview = struct {
    scaled: ScaledLayer,
    allowance: RoundoffAllowance,
};

/// Applies the exact `rebaseLayer` arithmetic after privately certifying the
/// rebase-owned change in the production immobile-phosphate inventory.
pub fn rebaseLayerWithRoundoff(
    state: *chemistry.State,
    layer: usize,
    old_water_m3: f64,
    new_water_m3: f64,
    fractions: InventoryFractions,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !RoundoffAllowance {
    try validateInventoryMolarMasses(carbon_g_per_mol, phosphorus_g_per_mol);
    try validateLayerRebase(state, layer, old_water_m3, new_water_m3);
    try fractions.validate();
    if (new_water_m3 == 0) {
        rememberDryCarrier(state, layer, old_water_m3);
        return .{};
    }
    const source_water_m3 = sourceWaterM3(state, layer, old_water_m3);
    if (source_water_m3 == new_water_m3) {
        state.dry_reference_water_m3[layer] = 0;
        return .{};
    }
    const preview = try prepareLayerRebase(
        state,
        layer,
        source_water_m3,
        new_water_m3,
        fractions,
        carbon_g_per_mol,
        phosphorus_g_per_mol,
    );
    commitScaledLayer(state, layer, preview.scaled);
    state.dry_reference_water_m3[layer] = 0;
    return preview.allowance;
}

/// Computes and certifies a layer rebase without mutating scientific state.
/// Multi-layer owners can preflight every layer before any transaction commit.
pub noinline fn previewLayerRoundoff(
    state: *const chemistry.State,
    layer: usize,
    old_water_m3: f64,
    new_water_m3: f64,
    fractions: InventoryFractions,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !RoundoffAllowance {
    try validateInventoryMolarMasses(carbon_g_per_mol, phosphorus_g_per_mol);
    try validateLayerRebase(state, layer, old_water_m3, new_water_m3);
    try fractions.validate();
    if (new_water_m3 == 0) return .{};
    const source_water_m3 = sourceWaterM3(state, layer, old_water_m3);
    if (source_water_m3 == new_water_m3) return .{};
    return (try prepareLayerRebase(
        state,
        layer,
        source_water_m3,
        new_water_m3,
        fractions,
        carbon_g_per_mol,
        phosphorus_g_per_mol,
    )).allowance;
}

fn prepareLayerRebase(
    state: *const chemistry.State,
    layer: usize,
    old_water_m3: f64,
    new_water_m3: f64,
    fractions: InventoryFractions,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !LayerRebasePreview {
    // Validate the index before taking any layer snapshot. `prepareScaledLayer`
    // repeats the state validation immediately before its private arithmetic;
    // keeping this guard here preserves the public out-of-bounds error contract.
    try validateLayerRebase(state, layer, old_water_m3, new_water_m3);
    try fractions.validate();
    try validateInventoryMolarMasses(carbon_g_per_mol, phosphorus_g_per_mol);
    const non_band_before = state.non_band_phosphate[layer];
    const band_before = state.band_phosphate[layer];
    const geochemistry_solids_before = state.geochemistry_solids[layer];
    var result: LayerRebasePreview = .{
        .scaled = try prepareScaledLayer(
            state,
            layer,
            old_water_m3,
            new_water_m3,
        ),
        .allowance = .{},
    };

    var phosphate_allowance = try phosphateImmobileRoundoff(
        non_band_before,
        result.scaled.non_band_after,
        old_water_m3,
        new_water_m3,
        fractions.phosphate_non_band,
    );
    try phosphate_allowance.add(try phosphateImmobileRoundoff(
        band_before,
        result.scaled.band_after,
        old_water_m3,
        new_water_m3,
        fractions.phosphate_band,
    ));
    phosphate_allowance = try certifyGroupedPhosphateInventory(
        phosphate_allowance,
        non_band_before,
        band_before,
        result.scaled.non_band_after,
        result.scaled.band_after,
        old_water_m3,
        new_water_m3,
        fractions,
        phosphorus_g_per_mol,
    );
    try result.allowance.add(phosphate_allowance);

    var geochemistry_allowance = try geochemistrySolidRoundoff(
        geochemistry_solids_before,
        result.scaled.geochemistry_solids_after,
        old_water_m3,
        new_water_m3,
    );
    geochemistry_allowance = try certifyGroupedGeochemistryInventory(
        geochemistry_allowance,
        geochemistry_solids_before,
        result.scaled.geochemistry_solids_after,
        old_water_m3,
        new_water_m3,
        carbon_g_per_mol,
    );
    try result.allowance.add(geochemistry_allowance);
    try result.allowance.validate();
    return result;
}

fn sourceWaterM3(state: *const chemistry.State, layer: usize, old_water_m3: f64) f64 {
    return if (old_water_m3 > 0) old_water_m3 else state.dry_reference_water_m3[layer];
}

fn rememberDryCarrier(state: *chemistry.State, layer: usize, old_water_m3: f64) void {
    if (state.dry_reference_water_m3[layer] == 0)
        state.dry_reference_water_m3[layer] = sourceWaterM3(state, layer, old_water_m3);
}

/// Mutation-free validation shared with multi-layer transaction preflight.
/// `solute.f:610` admits a vanishing carrier (`VOLW ≤ ZEROS2`) and keeps the
/// extensive `Z*` pools. Concentrations are validated against the water they
/// currently represent: live water while wet, the remembered dry reference
/// while dry.
pub fn validateLayerRebase(
    state: *const chemistry.State,
    layer: usize,
    old_water_m3: f64,
    new_water_m3: f64,
) !void {
    if (layer >= state.cell_count) return error.SoilChemistryLayerOutOfBounds;
    if (!std.math.isFinite(old_water_m3) or !std.math.isFinite(new_water_m3) or
        old_water_m3 < 0 or new_water_m3 < 0)
        return error.InvalidSoilChemistryWaterCarrier;
    if (state.dry_reference_water_m3.len != state.cell_count)
        return error.SoilChemistryLayerOutOfBounds;
    const current_water_m3 = sourceWaterM3(state, layer, old_water_m3);
    if (!std.math.isFinite(current_water_m3) or current_water_m3 < 0)
        return error.InvalidSoilChemistryWaterCarrier;
    try validateScalable(state.aqueous[layer], current_water_m3, current_water_m3);
    try validateScalable(state.non_band_phosphate[layer], current_water_m3, current_water_m3);
    try validateScalable(state.band_phosphate[layer], current_water_m3, current_water_m3);
    try validateScalable(state.geochemistry_solids[layer], current_water_m3, current_water_m3);
}

/// Stages all four structures with one shared old/new scale. Each scalable
/// field receives exactly one multiplication, and no scientific state is
/// published until every staged result has passed finite/nonnegative checks.
fn prepareScaledLayer(
    state: *const chemistry.State,
    layer: usize,
    old_water_m3: f64,
    new_water_m3: f64,
) !ScaledLayer {
    try validateLayerRebase(state, layer, old_water_m3, new_water_m3);
    const scale = if (old_water_m3 == 0) 0 else old_water_m3 / new_water_m3;
    if (!std.math.isFinite(scale) or scale < 0)
        return error.InvalidSoilChemistryWaterCarrier;

    var result: ScaledLayer = .{
        .aqueous_after = state.aqueous[layer],
        .non_band_after = state.non_band_phosphate[layer],
        .band_after = state.band_phosphate[layer],
        .geochemistry_solids_after = state.geochemistry_solids[layer],
    };
    scaleScalable(&result.aqueous_after, scale);
    scaleScalable(&result.non_band_after, scale);
    scaleScalable(&result.band_after, scale);
    scaleScalable(&result.geochemistry_solids_after, scale);

    try validateScalable(result.aqueous_after, new_water_m3, new_water_m3);
    try validateScalable(result.non_band_after, new_water_m3, new_water_m3);
    try validateScalable(result.band_after, new_water_m3, new_water_m3);
    try validateScalable(result.geochemistry_solids_after, new_water_m3, new_water_m3);
    return result;
}

fn commitScaledLayer(
    state: *chemistry.State,
    layer: usize,
    scaled: ScaledLayer,
) void {
    state.aqueous[layer] = scaled.aqueous_after;
    state.non_band_phosphate[layer] = scaled.non_band_after;
    state.band_phosphate[layer] = scaled.band_after;
    state.geochemistry_solids[layer] = scaled.geochemistry_solids_after;
}

fn validateScalable(value: anytype, old_water_m3: f64, new_water_m3: f64) !void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| if (comptime scalable(field.name)) {
        const concentration = @field(value, field.name);
        if (!std.math.isFinite(concentration) or concentration < 0)
            return error.InvalidSoilChemistryWaterNormalizedPool;
        if (concentration > 0 and (old_water_m3 == 0 or new_water_m3 == 0))
            return error.SoilChemistryMassWithoutWaterCarrier;
    };
}

fn scaleScalable(value: anytype, scale: f64) void {
    inline for (@typeInfo(@TypeOf(value.*)).@"struct".fields) |field| {
        if (comptime scalable(field.name)) @field(value, field.name) *= scale;
    }
}

fn phosphateImmobileRoundoff(
    before: PhosphateState,
    after: PhosphateState,
    old_water_m3: f64,
    new_water_m3: f64,
    zone_fraction: f64,
) !RoundoffAllowance {
    // An absent zone contributes exactly zero to the authoritative inventory,
    // regardless of its dormant concentration coordinates.
    if (zone_fraction == 0) return .{};
    var result: RoundoffAllowance = .{};
    try accumulateCertifiedFractionWeightedField(
        &result,
        before.aluminum_phosphate_solid_mol_per_m3,
        after.aluminum_phosphate_solid_mol_per_m3,
        old_water_m3,
        new_water_m3,
        zone_fraction,
        .{ .phosphorus_mol = 1, .aluminum_mol = 1 },
    );
    try accumulateCertifiedFractionWeightedField(
        &result,
        before.iron_phosphate_solid_mol_per_m3,
        after.iron_phosphate_solid_mol_per_m3,
        old_water_m3,
        new_water_m3,
        zone_fraction,
        .{ .phosphorus_mol = 1, .iron_mol = 1 },
    );
    try accumulateCertifiedFractionWeightedField(
        &result,
        before.dicalcium_phosphate_solid_mol_per_m3,
        after.dicalcium_phosphate_solid_mol_per_m3,
        old_water_m3,
        new_water_m3,
        zone_fraction,
        .{ .phosphorus_mol = 1, .calcium_mol = 1 },
    );
    try accumulateCertifiedFractionWeightedField(
        &result,
        before.hydroxyapatite_solid_mol_per_m3,
        after.hydroxyapatite_solid_mol_per_m3,
        old_water_m3,
        new_water_m3,
        zone_fraction,
        .{ .phosphorus_mol = 3, .calcium_mol = 5 },
    );
    try accumulateCertifiedFractionWeightedField(
        &result,
        before.monocalcium_phosphate_solid_mol_per_m3,
        after.monocalcium_phosphate_solid_mol_per_m3,
        old_water_m3,
        new_water_m3,
        zone_fraction,
        .{ .phosphorus_mol = 2, .calcium_mol = 1 },
    );
    return result;
}

/// Mirrors `landscape_mass_inventory_phosphorus_ions.geochemistrySolidElements`
/// field-for-field. Geochemistry occupies the full layer-water carrier rather
/// than either phosphate-zone fraction. Aqueous coordinates are absent here:
/// the authoritative landscape census owns their extensive mol in transport.
fn geochemistrySolidRoundoff(
    before: GeochemistrySolidState,
    after: GeochemistrySolidState,
    old_water_m3: f64,
    new_water_m3: f64,
) !RoundoffAllowance {
    var result: RoundoffAllowance = .{};
    try accumulateCertifiedFullWaterField(
        &result,
        before.gibbsite_solid_mol_per_m3,
        after.gibbsite_solid_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .aluminum_mol = 1 },
    );
    try accumulateCertifiedFullWaterField(
        &result,
        before.iron_hydroxide_solid_mol_per_m3,
        after.iron_hydroxide_solid_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .iron_mol = 1 },
    );
    try accumulateCertifiedFullWaterField(
        &result,
        before.calcite_solid_mol_per_m3,
        after.calcite_solid_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .carbon_mol = 1, .calcium_mol = 1 },
    );
    try accumulateCertifiedFullWaterField(
        &result,
        before.gypsum_solid_mol_per_m3,
        after.gypsum_solid_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .calcium_mol = 1, .sulfur_mol = 1 },
    );
    try accumulateCertifiedFullWaterField(
        &result,
        before.aluminum_natural_silicate_mol_per_m3,
        after.aluminum_natural_silicate_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .aluminum_mol = 1, .silicon_mol = 0.75 },
    );
    try accumulateCertifiedFullWaterField(
        &result,
        before.aluminum_ground_silicate_mol_per_m3,
        after.aluminum_ground_silicate_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .aluminum_mol = 1, .silicon_mol = 0.75 },
    );
    try accumulateCertifiedFullWaterField(
        &result,
        before.iron_natural_silicate_mol_per_m3,
        after.iron_natural_silicate_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .iron_mol = 1, .silicon_mol = 0.75 },
    );
    try accumulateCertifiedFullWaterField(
        &result,
        before.iron_ground_silicate_mol_per_m3,
        after.iron_ground_silicate_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .iron_mol = 1, .silicon_mol = 0.75 },
    );
    try accumulateCertifiedFullWaterField(
        &result,
        before.calcium_natural_silicate_mol_per_m3,
        after.calcium_natural_silicate_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .calcium_mol = 1, .silicon_mol = 0.5 },
    );
    try accumulateCertifiedFullWaterField(
        &result,
        before.calcium_ground_silicate_mol_per_m3,
        after.calcium_ground_silicate_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .calcium_mol = 1, .silicon_mol = 0.5 },
    );
    try accumulateCertifiedFullWaterField(
        &result,
        before.magnesium_natural_silicate_mol_per_m3,
        after.magnesium_natural_silicate_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .magnesium_mol = 1, .silicon_mol = 0.5 },
    );
    try accumulateCertifiedFullWaterField(
        &result,
        before.magnesium_ground_silicate_mol_per_m3,
        after.magnesium_ground_silicate_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .magnesium_mol = 1, .silicon_mol = 0.5 },
    );
    try accumulateCertifiedFullWaterField(
        &result,
        before.sodium_natural_silicate_mol_per_m3,
        after.sodium_natural_silicate_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .sodium_mol = 1, .silicon_mol = 0.25 },
    );
    try accumulateCertifiedFullWaterField(
        &result,
        before.sodium_ground_silicate_mol_per_m3,
        after.sodium_ground_silicate_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .sodium_mol = 1, .silicon_mol = 0.25 },
    );
    try accumulateCertifiedFullWaterField(
        &result,
        before.potassium_natural_silicate_mol_per_m3,
        after.potassium_natural_silicate_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .potassium_mol = 1, .silicon_mol = 0.25 },
    );
    try accumulateCertifiedFullWaterField(
        &result,
        before.potassium_ground_silicate_mol_per_m3,
        after.potassium_ground_silicate_mol_per_m3,
        old_water_m3,
        new_water_m3,
        .{ .potassium_mol = 1, .silicon_mol = 0.25 },
    );
    return result;
}

noinline fn accumulateCertifiedFractionWeightedField(
    result: *RoundoffAllowance,
    before_concentration: f64,
    after_concentration: f64,
    old_water_m3: f64,
    new_water_m3: f64,
    zone_fraction: f64,
    coefficients: RoundoffAllowance,
) !void {
    const discrepancy = try certifiedFractionWeightedInventoryFieldDiscrepancy(
        before_concentration,
        after_concentration,
        old_water_m3,
        new_water_m3,
        zone_fraction,
    );
    try accumulateCertifiedDiscrepancy(result, discrepancy, coefficients);
}

noinline fn accumulateCertifiedFullWaterField(
    result: *RoundoffAllowance,
    before_concentration: f64,
    after_concentration: f64,
    old_water_m3: f64,
    new_water_m3: f64,
    coefficients: RoundoffAllowance,
) !void {
    const discrepancy = try certifiedFullWaterInventoryFieldDiscrepancy(
        before_concentration,
        after_concentration,
        old_water_m3,
        new_water_m3,
    );
    try accumulateCertifiedDiscrepancy(result, discrepancy, coefficients);
}

noinline fn accumulateCertifiedDiscrepancy(
    result: *RoundoffAllowance,
    discrepancy: f64,
    coefficients: RoundoffAllowance,
) !void {
    // These are exact identity cases. Avoid expanding one sparse source term
    // into every balance lane: most authoritative stoichiometric vectors have
    // only one or two nonzero coefficients, and an exactly preserved endpoint
    // has no contribution at all.
    if (discrepancy == 0) return;
    inline for (std.meta.fields(RoundoffAllowance)) |field| {
        const coefficient = @field(coefficients, field.name);
        if (coefficient != 0) {
            const contribution = try multiplyRoundUp(
                discrepancy,
                coefficient,
            );
            @field(result, field.name) = try addRoundUp(
                @field(result, field.name),
                contribution,
            );
        }
    }
}

/// Certifies the phosphate census shape
/// `concentration * fl(water * zone_fraction)`. The rebase exit has four
/// rounded operations from the exact entry extent; the entry census has two.
noinline fn certifiedFractionWeightedInventoryFieldDiscrepancy(
    before_concentration: f64,
    after_concentration: f64,
    old_water_m3: f64,
    new_water_m3: f64,
    zone_fraction: f64,
) !f64 {
    if (zone_fraction == 0) return 0;
    const old_carrier = old_water_m3 * zone_fraction;
    const new_carrier = new_water_m3 * zone_fraction;
    if (!std.math.isFinite(old_carrier) or old_carrier < 0 or
        !std.math.isFinite(new_carrier) or new_carrier < 0)
        return error.InvalidSoilChemistryWaterCarrierRoundoff;

    var exact_entry_extent_upper = try multiplyRoundUp(
        before_concentration,
        old_water_m3,
    );
    exact_entry_extent_upper = try multiplyRoundUp(
        exact_entry_extent_upper,
        zone_fraction,
    );
    return certifiedEndpointInventoryFieldDiscrepancy(
        before_concentration,
        after_concentration,
        old_carrier,
        new_carrier,
        exact_entry_extent_upper,
        2,
        4,
    );
}

/// Certifies the geochemistry census shape `concentration * water` exactly as
/// `extensiveGeochemistrySolids` constructs it. The rebase exit has three
/// rounded operations from the exact entry extent; the entry census has one.
noinline fn certifiedFullWaterInventoryFieldDiscrepancy(
    before_concentration: f64,
    after_concentration: f64,
    old_water_m3: f64,
    new_water_m3: f64,
) !f64 {
    const exact_entry_extent_upper = try multiplyRoundUp(
        before_concentration,
        old_water_m3,
    );
    return certifiedEndpointInventoryFieldDiscrepancy(
        before_concentration,
        after_concentration,
        old_water_m3,
        new_water_m3,
        exact_entry_extent_upper,
        1,
        3,
    );
}

/// FMA product residuals and an error-free TwoDiff bound both represented
/// endpoint products and their rounded census values. An independent Higham
/// source bound covers the complete exit and entry operation paths.
noinline fn certifiedEndpointInventoryFieldDiscrepancy(
    before_concentration: f64,
    after_concentration: f64,
    old_carrier: f64,
    new_carrier: f64,
    exact_entry_extent_upper: f64,
    entry_operation_count: u8,
    exit_operation_count: u8,
) !f64 {
    inline for (.{ before_concentration, after_concentration, old_carrier, new_carrier }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSoilChemistryWaterCarrierRoundoff;

    const before_product = before_concentration * old_carrier;
    const after_product = after_concentration * new_carrier;
    if (!std.math.isFinite(before_product) or
        !std.math.isFinite(after_product))
        return error.InvalidSoilChemistryWaterCarrierRoundoff;
    const before_product_error = @mulAdd(
        f64,
        before_concentration,
        old_carrier,
        -before_product,
    );
    const after_product_error = @mulAdd(
        f64,
        after_concentration,
        new_carrier,
        -after_product,
    );
    if (before_product == after_product and
        before_product_error == after_product_error)
        return 0;

    const product_difference = after_product - before_product;
    const difference_error = twoDiffError(
        after_product,
        before_product,
        product_difference,
    );
    const low_first = difference_error + after_product_error;
    const low = low_first - before_product_error;
    const total = product_difference + low;
    inline for (.{
        before_product_error,
        after_product_error,
        difference_error,
        low_first,
        low,
        total,
    }) |value| if (!std.math.isFinite(value))
        return error.InvalidSoilChemistryWaterCarrierRoundoff;

    const unit_roundoff = std.math.floatEps(f64) / 2;
    const gamma_one = std.math.nextAfter(
        f64,
        unit_roundoff / (1 - unit_roundoff),
        std.math.inf(f64),
    );
    const gamma_two = roundingGamma(unit_roundoff, 2);
    var low_magnitude = try addRoundUp(
        @abs(difference_error),
        @abs(after_product_error),
    );
    low_magnitude = try addRoundUp(low_magnitude, @abs(before_product_error));
    const low_error_bound = try addRoundUp(
        try multiplyRoundUp(gamma_two, low_magnitude),
        4 * std.math.floatTrueMin(f64),
    );
    var total_rounding_bound = try addRoundUp(
        @abs(product_difference),
        @abs(low),
    );
    total_rounding_bound = try multiplyRoundUp(
        gamma_one,
        total_rounding_bound,
    );
    var represented_upper = try addRoundUp(@abs(total), low_error_bound);
    represented_upper = try addRoundUp(
        represented_upper,
        total_rounding_bound,
    );
    const census_upper = try addRoundUp(
        @abs(product_difference),
        @abs(difference_error),
    );
    const observed_upper = @max(represented_upper, census_upper);

    const path_coefficient = try addRoundUp(
        roundingGamma(unit_roundoff, exit_operation_count),
        roundingGamma(unit_roundoff, entry_operation_count),
    );
    const higham_bound = try addRoundUp(
        try multiplyRoundUp(path_coefficient, exact_entry_extent_upper),
        8 * std.math.floatTrueMin(f64),
    );
    if (observed_upper > higham_bound)
        return error.SoilChemistryWaterCarrierRoundoffExceeded;
    return observed_upper;
}

fn roundingGamma(unit_roundoff: f64, operation_count: u8) f64 {
    const count: f64 = @floatFromInt(operation_count);
    return std.math.nextAfter(
        f64,
        (count * unit_roundoff) / (1 - count * unit_roundoff),
        std.math.inf(f64),
    );
}

fn addRoundUp(left: f64, right: f64) !f64 {
    if (!std.math.isFinite(left) or left < 0 or
        !std.math.isFinite(right) or right < 0)
        return error.InvalidSoilChemistryWaterCarrierRoundoff;
    if (left == 0) return right;
    if (right == 0) return left;
    const sum = left + right;
    if (!std.math.isFinite(sum))
        return error.InvalidSoilChemistryWaterCarrierRoundoff;
    return std.math.nextAfter(f64, sum, std.math.inf(f64));
}

fn multiplyRoundUp(left: f64, right: f64) !f64 {
    if (!std.math.isFinite(left) or left < 0 or
        !std.math.isFinite(right) or right < 0)
        return error.InvalidSoilChemistryWaterCarrierRoundoff;
    if (left == 0 or right == 0) return 0;
    const product = left * right;
    if (!std.math.isFinite(product))
        return error.InvalidSoilChemistryWaterCarrierRoundoff;
    return std.math.nextAfter(f64, product, std.math.inf(f64));
}

fn twoDiffError(left: f64, right: f64, difference: f64) f64 {
    const right_virtual = left - difference;
    const left_virtual = difference + right_virtual;
    const right_roundoff = right_virtual - right;
    const left_roundoff = left - left_virtual;
    return left_roundoff + right_roundoff;
}

fn scalable(comptime name: []const u8) bool {
    return !std.mem.eql(u8, name, "water_mol_per_m3") and
        !std.mem.endsWith(u8, name, "_per_megagram");
}

fn seedImmobilePhosphate(state: *chemistry.State) void {
    const amount = 31.596673933440005;
    inline for (.{ &state.non_band_phosphate[0], &state.band_phosphate[0] }) |zone| {
        zone.aluminum_phosphate_solid_mol_per_m3 = amount;
        zone.iron_phosphate_solid_mol_per_m3 = amount;
        zone.dicalcium_phosphate_solid_mol_per_m3 = amount;
        zone.hydroxyapatite_solid_mol_per_m3 = amount;
        zone.monocalcium_phosphate_solid_mol_per_m3 = amount;
    }
}

fn seedGeochemistrySolids(state: *chemistry.State) void {
    const amount = 31.596673933440005;
    inline for (@typeInfo(GeochemistrySolidState).@"struct".fields) |field|
        @field(state.geochemistry_solids[0], field.name) = amount;
}

/// Water-owned subset of
/// `landscape_mass_inventory_phosphorus_ions.phosphateImmobileInventory`.
/// The two adsorbed terms use the independent dry-soil carrier and therefore
/// cannot change in this transaction. All mineral grouping and stoichiometry
/// below are kept in the authoritative source order.
noinline fn phosphateInventoryShape(
    state: PhosphateState,
    water_m3: f64,
    zone_fraction: f64,
) RoundoffAllowance {
    const carrier = water_m3 * zone_fraction;
    const aluminum = state.aluminum_phosphate_solid_mol_per_m3 * carrier;
    const iron = state.iron_phosphate_solid_mol_per_m3 * carrier;
    const dicalcium = state.dicalcium_phosphate_solid_mol_per_m3 * carrier;
    const hydroxyapatite = state.hydroxyapatite_solid_mol_per_m3 * carrier;
    const monocalcium = state.monocalcium_phosphate_solid_mol_per_m3 * carrier;
    return .{
        .phosphorus_mol = aluminum + iron + dicalcium +
            3 * hydroxyapatite + 2 * monocalcium,
        .aluminum_mol = aluminum,
        .iron_mol = iron,
        .calcium_mol = dicalcium + 5 * hydroxyapatite + monocalcium,
    };
}

/// Mirrors `extensiveGeochemistrySolids` followed by
/// `geochemistrySolidElements`, including its grouped silicate arithmetic.
noinline fn geochemistryInventoryShape(
    state: GeochemistrySolidState,
    water_m3: f64,
) RoundoffAllowance {
    var extensive = state;
    inline for (@typeInfo(GeochemistrySolidState).@"struct".fields) |field|
        @field(extensive, field.name) *= water_m3;
    const aluminum_silicate = extensive.aluminum_natural_silicate_mol_per_m3 +
        extensive.aluminum_ground_silicate_mol_per_m3;
    const iron_silicate = extensive.iron_natural_silicate_mol_per_m3 +
        extensive.iron_ground_silicate_mol_per_m3;
    const calcium_silicate = extensive.calcium_natural_silicate_mol_per_m3 +
        extensive.calcium_ground_silicate_mol_per_m3;
    const magnesium_silicate = extensive.magnesium_natural_silicate_mol_per_m3 +
        extensive.magnesium_ground_silicate_mol_per_m3;
    const sodium_silicate = extensive.sodium_natural_silicate_mol_per_m3 +
        extensive.sodium_ground_silicate_mol_per_m3;
    const potassium_silicate = extensive.potassium_natural_silicate_mol_per_m3 +
        extensive.potassium_ground_silicate_mol_per_m3;
    return .{
        .carbon_mol = extensive.calcite_solid_mol_per_m3,
        .aluminum_mol = extensive.gibbsite_solid_mol_per_m3 +
            aluminum_silicate,
        .iron_mol = extensive.iron_hydroxide_solid_mol_per_m3 +
            iron_silicate,
        .calcium_mol = extensive.calcite_solid_mol_per_m3 +
            extensive.gypsum_solid_mol_per_m3 + calcium_silicate,
        .magnesium_mol = magnesium_silicate,
        .sodium_mol = sodium_silicate,
        .potassium_mol = potassium_silicate,
        .sulfur_mol = extensive.gypsum_solid_mol_per_m3,
        .silicon_mol = 0.75 * (aluminum_silicate + iron_silicate) +
            0.5 * (calcium_silicate + magnesium_silicate) +
            0.25 * (sodium_silicate + potassium_silicate),
    };
}

/// Mirrors the production immobile-phosphate publication boundary: each zone
/// is evaluated independently, zone phosphorus is added, and only then is the
/// authoritative final-unit molar-mass product formed.
noinline fn groupedPhosphateInventoryShape(
    non_band: PhosphateState,
    band: PhosphateState,
    water_m3: f64,
    fractions: InventoryFractions,
    phosphorus_g_per_mol: f64,
) !RoundoffAllowance {
    try fractions.validate();
    try validateInventoryMolarMasses(1, phosphorus_g_per_mol);
    const non_band_inventory = phosphateInventoryShape(
        non_band,
        water_m3,
        fractions.phosphate_non_band,
    );
    const band_inventory = phosphateInventoryShape(
        band,
        water_m3,
        fractions.phosphate_band,
    );
    const result: RoundoffAllowance = .{
        .phosphorus_g = phosphorus_g_per_mol *
            (non_band_inventory.phosphorus_mol + band_inventory.phosphorus_mol),
        .phosphorus_mol = non_band_inventory.phosphorus_mol +
            band_inventory.phosphorus_mol,
        .aluminum_mol = non_band_inventory.aluminum_mol +
            band_inventory.aluminum_mol,
        .iron_mol = non_band_inventory.iron_mol +
            band_inventory.iron_mol,
        .calcium_mol = non_band_inventory.calcium_mol +
            band_inventory.calcium_mol,
    };
    try result.validate();
    return result;
}

/// Adds exact grouped-endpoint coverage without replacing the independently
/// accumulated per-field proof. `max` is intentional: the two bounds certify
/// the same phosphate source path, while summing them would double-count it.
noinline fn certifyGroupedPhosphateInventory(
    member_allowance: RoundoffAllowance,
    non_band_before: PhosphateState,
    band_before: PhosphateState,
    non_band_after: PhosphateState,
    band_after: PhosphateState,
    old_water_m3: f64,
    new_water_m3: f64,
    fractions: InventoryFractions,
    phosphorus_g_per_mol: f64,
) !RoundoffAllowance {
    var result = member_allowance;
    const source_phosphorus_bound = member_allowance.phosphorus_mol;
    const before = try groupedPhosphateInventoryShape(
        non_band_before,
        band_before,
        old_water_m3,
        fractions,
        phosphorus_g_per_mol,
    );
    const after = try groupedPhosphateInventoryShape(
        non_band_after,
        band_after,
        new_water_m3,
        fractions,
        phosphorus_g_per_mol,
    );

    // Across both endpoint paths: two carrier products, ten mineral products,
    // ten stoichiometric/group additions, and the two zone joins. Sixty-four
    // is a conservative audited cap for every individual molar lane.
    const grouped_operation_count: u8 = 64;
    inline for (.{ "phosphorus_mol", "aluminum_mol", "iron_mol", "calcium_mol" }) |name| {
        const independent = try groupedIndependentBound(
            @field(member_allowance, name),
            @field(before, name),
            @field(after, name),
            grouped_operation_count,
        );
        const observed = try certifyGroupedEndpointWithin(
            @field(before, name),
            @field(after, name),
            independent,
        );
        @field(result, name) = @max(@field(result, name), observed);
    }

    const phosphorus_independent = try groupedIndependentBound(
        try scaleCertifiedBound(source_phosphorus_bound, phosphorus_g_per_mol),
        before.phosphorus_g,
        after.phosphorus_g,
        grouped_operation_count,
    );
    result.phosphorus_g = @max(
        result.phosphorus_g,
        try certifyGroupedEndpointWithin(
            before.phosphorus_g,
            after.phosphorus_g,
            phosphorus_independent,
        ),
    );
    try result.validate();
    return result;
}

/// Adds the exact production geochemistry grouping and final calcite-C gram
/// product to the independent field-by-field source proof.
noinline fn certifyGroupedGeochemistryInventory(
    member_allowance: RoundoffAllowance,
    before_state: GeochemistrySolidState,
    after_state: GeochemistrySolidState,
    old_water_m3: f64,
    new_water_m3: f64,
    carbon_g_per_mol: f64,
) !RoundoffAllowance {
    try validateInventoryMolarMasses(carbon_g_per_mol, 1);
    var result = member_allowance;
    const source_carbon_bound = member_allowance.carbon_mol;
    var before = geochemistryInventoryShape(before_state, old_water_m3);
    var after = geochemistryInventoryShape(after_state, new_water_m3);
    before.carbon_g = before.carbon_mol * carbon_g_per_mol;
    after.carbon_g = after.carbon_mol * carbon_g_per_mol;
    try before.validate();
    try after.validate();

    // Both endpoint paths contain sixteen extensive products plus the exact
    // silicate-pair and element stoichiometry grouping. Seventy-two covers all
    // operations influencing any one published lane, including final calcite C.
    const grouped_operation_count: u8 = 72;
    inline for (.{
        "carbon_mol",
        "aluminum_mol",
        "iron_mol",
        "calcium_mol",
        "magnesium_mol",
        "sodium_mol",
        "potassium_mol",
        "sulfur_mol",
        "silicon_mol",
    }) |name| {
        const independent = try groupedIndependentBound(
            @field(member_allowance, name),
            @field(before, name),
            @field(after, name),
            grouped_operation_count,
        );
        const observed = try certifyGroupedEndpointWithin(
            @field(before, name),
            @field(after, name),
            independent,
        );
        @field(result, name) = @max(@field(result, name), observed);
    }

    const carbon_independent = try groupedIndependentBound(
        try scaleCertifiedBound(source_carbon_bound, carbon_g_per_mol),
        before.carbon_g,
        after.carbon_g,
        grouped_operation_count,
    );
    result.carbon_g = @max(
        result.carbon_g,
        try certifyGroupedEndpointWithin(
            before.carbon_g,
            after.carbon_g,
            carbon_independent,
        ),
    );
    try result.validate();
    return result;
}

test "SOLUTE extensive mineral pools require the water-carrier translation" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0].calcium = 2;
    state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 3;
    state.non_band_phosphate[0].adsorbed_h2po4_mol_p_per_megagram = 5;
    inline for (@typeInfo(GeochemistrySolidState).@"struct".fields) |field|
        @field(state.geochemistry_solids[0], field.name) = 7;
    try rebaseLayer(&state, 0, 4, 2);
    try std.testing.expectEqual(@as(f64, 4), state.aqueous[0].calcium);
    try std.testing.expectEqual(@as(f64, 6), state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3);
    try std.testing.expectEqual(@as(f64, 5), state.non_band_phosphate[0].adsorbed_h2po4_mol_p_per_megagram);
    // `solute.f:774--793` names all four precipitates and twelve silicate
    // pools as extensive mol, then divides each by VOLW for its solve state.
    // Every corresponding Zig concentration must therefore retain its old
    // extensive amount across the carrier-only change.
    inline for (@typeInfo(GeochemistrySolidState).@"struct".fields) |field| {
        const concentration = @field(state.geochemistry_solids[0], field.name);
        try std.testing.expectEqual(@as(f64, 14), concentration);
        try std.testing.expectEqual(@as(f64, 28), concentration * 2);
    }
}

test "SOIL-CHEM-DRY-CARRIER-001 evaporating the carrier to dryness holds concentrations and remembers the live water" {
    // Hour-2705 Ottawa capture: layer 0 old_water_m3=6.42297794652246e-3,
    // new_water_m3=0, with positive aqueous and mineral concentrations.
    // `solute.f:610` skips the reaction block when VOLW ≤ ZEROS2 and keeps Z*.
    // The parent rejected this with SoilChemistryMassWithoutWaterCarrier.
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0].nitrate_non_band = 4;
    state.aqueous[0].calcium = 2;
    state.geochemistry_solids[0].calcite_solid_mol_per_m3 = 7;
    const old_water_m3 = 6.42297794652246e-3;
    try rebaseLayer(&state, 0, old_water_m3, 0);
    try std.testing.expectEqual(@as(f64, 4), state.aqueous[0].nitrate_non_band);
    try std.testing.expectEqual(@as(f64, 2), state.aqueous[0].calcium);
    try std.testing.expectEqual(@as(f64, 7), state.geochemistry_solids[0].calcite_solid_mol_per_m3);
    try std.testing.expectEqual(old_water_m3, state.dry_reference_water_m3[0]);
}

test "SOIL-CHEM-DRY-CARRIER-001 a second dry rebase keeps the first remembered carrier" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0].nitrate_non_band = 4;
    try rebaseLayer(&state, 0, 2, 0);
    _ = try rebaseLayerWithRoundoff(
        &state,
        0,
        0,
        0,
        .{ .phosphate_non_band = 1, .phosphate_band = 0 },
        12,
        31,
    );
    try std.testing.expectEqual(@as(f64, 2), state.dry_reference_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 4), state.aqueous[0].nitrate_non_band);
}

test "SOIL-CHEM-DRY-CARRIER-001 rewetting a dry layer recovers the retained extensive mass" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0].nitrate_non_band = 4;
    try rebaseLayer(&state, 0, 2, 0);
    const amount_before = state.aqueous[0].nitrate_non_band * state.dry_reference_water_m3[0];
    try rebaseLayer(&state, 0, 0, 8);
    try std.testing.expectEqual(@as(f64, 0), state.dry_reference_water_m3[0]);
    try std.testing.expectApproxEqRel(amount_before, state.aqueous[0].nitrate_non_band * 8, 1e-15);
}

test "roundoff provenance exposes exactly the authoritative element lanes" {
    const expected_names = [_][]const u8{
        "carbon_g",
        "nitrogen_g",
        "phosphorus_g",
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
        "silicon_mol",
    };
    const fields = std.meta.fields(RoundoffAllowance);
    try std.testing.expectEqual(expected_names.len, fields.len);
    inline for (expected_names, fields) |expected, field|
        try std.testing.expectEqualStrings(expected, field.name);
}

test "audited rebase is bitwise literal arithmetic and preview is mutation-free" {
    var audited = try chemistry.State.init(std.testing.allocator, 1);
    defer audited.deinit();
    var expected = try chemistry.State.init(std.testing.allocator, 1);
    defer expected.deinit();
    seedImmobilePhosphate(&audited);
    seedImmobilePhosphate(&expected);
    seedGeochemistrySolids(&audited);
    seedGeochemistrySolids(&expected);
    audited.aqueous[0].magnesium = 17;
    expected.aqueous[0].magnesium = 17;
    audited.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 19;
    expected.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 19;
    audited.geochemistry_solids[0].magnesium_natural_silicate_mol_per_m3 = 23;
    expected.geochemistry_solids[0].magnesium_natural_silicate_mol_per_m3 = 23;
    const fractions: InventoryFractions = .{
        .phosphate_non_band = 0.8,
        .phosphate_band = 0.2,
    };

    const aqueous_before = audited.aqueous[0];
    const non_band_before = audited.non_band_phosphate[0];
    const band_before = audited.band_phosphate[0];
    const geochemistry_before = audited.geochemistry_solids[0];
    const preview = try previewLayerRoundoff(&audited, 0, 4, 4.5, fractions, 12, 31);
    try std.testing.expectEqualDeep(aqueous_before, audited.aqueous[0]);
    try std.testing.expectEqualDeep(non_band_before, audited.non_band_phosphate[0]);
    try std.testing.expectEqualDeep(band_before, audited.band_phosphate[0]);
    try std.testing.expectEqualDeep(geochemistry_before, audited.geochemistry_solids[0]);

    const allowance = try rebaseLayerWithRoundoff(
        &audited,
        0,
        4,
        4.5,
        fractions,
        12,
        31,
    );
    try std.testing.expectEqualDeep(preview, allowance);
    try rebaseLayer(&expected, 0, 4, 4.5);
    try std.testing.expectEqualDeep(expected.aqueous[0], audited.aqueous[0]);
    try std.testing.expectEqualDeep(expected.non_band_phosphate[0], audited.non_band_phosphate[0]);
    try std.testing.expectEqualDeep(expected.band_phosphate[0], audited.band_phosphate[0]);
    try std.testing.expectEqualDeep(expected.geochemistry_solids[0], audited.geochemistry_solids[0]);
    inline for (std.meta.fields(RoundoffAllowance)) |field| {
        if (comptime std.mem.eql(u8, field.name, "nitrogen_g") or
            std.mem.eql(u8, field.name, "nitrogen_mol") or
            std.mem.eql(u8, field.name, "chloride_mol"))
        {
            try std.testing.expectEqual(@as(f64, 0), @field(allowance, field.name));
        } else {
            try std.testing.expect(@field(allowance, field.name) > 0);
        }
    }
}

test "allowance bounds authoritative fraction-weighted phosphate inventory" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    seedImmobilePhosphate(&state);
    const fractions: InventoryFractions = .{
        .phosphate_non_band = 0.73,
        .phosphate_band = 0.27,
    };
    const before_non_band = phosphateInventoryShape(
        state.non_band_phosphate[0],
        4,
        fractions.phosphate_non_band,
    );
    const before_band = phosphateInventoryShape(
        state.band_phosphate[0],
        4,
        fractions.phosphate_band,
    );
    const before_grouped = try groupedPhosphateInventoryShape(
        state.non_band_phosphate[0],
        state.band_phosphate[0],
        4,
        fractions,
        31,
    );
    const allowance = try rebaseLayerWithRoundoff(
        &state,
        0,
        4,
        4.5,
        fractions,
        12,
        31,
    );
    const after_non_band = phosphateInventoryShape(
        state.non_band_phosphate[0],
        4.5,
        fractions.phosphate_non_band,
    );
    const after_band = phosphateInventoryShape(
        state.band_phosphate[0],
        4.5,
        fractions.phosphate_band,
    );
    const after_grouped = try groupedPhosphateInventoryShape(
        state.non_band_phosphate[0],
        state.band_phosphate[0],
        4.5,
        fractions,
        31,
    );
    try std.testing.expect(allowance.phosphorus_g >=
        @abs(after_grouped.phosphorus_g - before_grouped.phosphorus_g));
    inline for (std.meta.fields(RoundoffAllowance)) |field| {
        const before = @field(before_non_band, field.name) +
            @field(before_band, field.name);
        const after = @field(after_non_band, field.name) +
            @field(after_band, field.name);
        try std.testing.expect(@field(allowance, field.name) >=
            @abs(after - before));
    }
}

test "allowance bounds exact landscape geochemistry inventory stoichiometry" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    const cases = .{
        .{ "gibbsite_solid_mol_per_m3", RoundoffAllowance{ .aluminum_mol = 1 } },
        .{ "iron_hydroxide_solid_mol_per_m3", RoundoffAllowance{ .iron_mol = 1 } },
        .{ "calcite_solid_mol_per_m3", RoundoffAllowance{ .carbon_g = 1, .carbon_mol = 1, .calcium_mol = 1 } },
        .{ "gypsum_solid_mol_per_m3", RoundoffAllowance{ .calcium_mol = 1, .sulfur_mol = 1 } },
        .{ "aluminum_natural_silicate_mol_per_m3", RoundoffAllowance{ .aluminum_mol = 1, .silicon_mol = 0.75 } },
        .{ "aluminum_ground_silicate_mol_per_m3", RoundoffAllowance{ .aluminum_mol = 1, .silicon_mol = 0.75 } },
        .{ "iron_natural_silicate_mol_per_m3", RoundoffAllowance{ .iron_mol = 1, .silicon_mol = 0.75 } },
        .{ "iron_ground_silicate_mol_per_m3", RoundoffAllowance{ .iron_mol = 1, .silicon_mol = 0.75 } },
        .{ "calcium_natural_silicate_mol_per_m3", RoundoffAllowance{ .calcium_mol = 1, .silicon_mol = 0.5 } },
        .{ "calcium_ground_silicate_mol_per_m3", RoundoffAllowance{ .calcium_mol = 1, .silicon_mol = 0.5 } },
        .{ "magnesium_natural_silicate_mol_per_m3", RoundoffAllowance{ .magnesium_mol = 1, .silicon_mol = 0.5 } },
        .{ "magnesium_ground_silicate_mol_per_m3", RoundoffAllowance{ .magnesium_mol = 1, .silicon_mol = 0.5 } },
        .{ "sodium_natural_silicate_mol_per_m3", RoundoffAllowance{ .sodium_mol = 1, .silicon_mol = 0.25 } },
        .{ "sodium_ground_silicate_mol_per_m3", RoundoffAllowance{ .sodium_mol = 1, .silicon_mol = 0.25 } },
        .{ "potassium_natural_silicate_mol_per_m3", RoundoffAllowance{ .potassium_mol = 1, .silicon_mol = 0.25 } },
        .{ "potassium_ground_silicate_mol_per_m3", RoundoffAllowance{ .potassium_mol = 1, .silicon_mol = 0.25 } },
    };
    // This restates `landscape_mass_inventory_phosphorus_ions.zig:566--594`:
    // calcite owns C+Ca, gypsum owns Ca+S, hydroxides own their metal, and
    // metal-normalized silicates own Si at 3/4, 1/2, or 1/4.
    inline for (cases) |case| {
        state.geochemistry_solids[0] = std.mem.zeroes(GeochemistrySolidState);
        @field(state.geochemistry_solids[0], case[0]) = 31.596673933440005;
        const allowance = try rebaseLayerWithRoundoff(
            &state,
            0,
            4,
            4.5,
            .{ .phosphate_non_band = 1, .phosphate_band = 0 },
            12,
            31,
        );
        inline for (std.meta.fields(RoundoffAllowance)) |field| {
            const coefficient = @field(case[1], field.name);
            if (coefficient == 0)
                try std.testing.expectEqual(@as(f64, 0), @field(allowance, field.name))
            else
                try std.testing.expect(@field(allowance, field.name) > 0);
        }
    }

    seedGeochemistrySolids(&state);
    const inventory = geochemistryInventoryShape(state.geochemistry_solids[0], 1);
    try std.testing.expectEqual(@as(f64, 31.596673933440005), inventory.carbon_mol);
    try std.testing.expectEqual(inventory.carbon_mol, inventory.sulfur_mol);
    try std.testing.expectEqual(3 * inventory.carbon_mol, inventory.aluminum_mol);
    try std.testing.expectEqual(inventory.aluminum_mol, inventory.iron_mol);
    try std.testing.expectEqual(4 * inventory.carbon_mol, inventory.calcium_mol);
    try std.testing.expectEqual(2 * inventory.carbon_mol, inventory.magnesium_mol);
    try std.testing.expectEqual(inventory.magnesium_mol, inventory.sodium_mol);
    try std.testing.expectEqual(inventory.sodium_mol, inventory.potassium_mol);
    try std.testing.expectEqual(6 * inventory.carbon_mol, inventory.silicon_mol);
    try std.testing.expectEqual(@as(f64, 0), inventory.phosphorus_mol);
}

test "grouped certification retains independent member anti-masking bounds" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    seedImmobilePhosphate(&state);
    seedGeochemistrySolids(&state);
    const fractions: InventoryFractions = .{
        .phosphate_non_band = 0.73,
        .phosphate_band = 0.27,
    };
    const scaled = try prepareScaledLayer(&state, 0, 4, 4.5);
    var phosphate_members = try phosphateImmobileRoundoff(
        state.non_band_phosphate[0],
        scaled.non_band_after,
        4,
        4.5,
        fractions.phosphate_non_band,
    );
    try phosphate_members.add(try phosphateImmobileRoundoff(
        state.band_phosphate[0],
        scaled.band_after,
        4,
        4.5,
        fractions.phosphate_band,
    ));
    const geochemistry_members = try geochemistrySolidRoundoff(
        state.geochemistry_solids[0],
        scaled.geochemistry_solids_after,
        4,
        4.5,
    );
    const allowance = try previewLayerRoundoff(
        &state,
        0,
        4,
        4.5,
        fractions,
        12,
        31,
    );
    inline for (std.meta.fields(RoundoffAllowance)) |field| {
        const member_sum = try addCertifiedBounds(
            @field(phosphate_members, field.name),
            @field(geochemistry_members, field.name),
        );
        try std.testing.expect(@field(allowance, field.name) >= member_sum);
    }
}

test "zero phosphate fraction is silent while full-water geochemistry certifies" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    const amount = 31.596673933440005;
    state.band_phosphate[0].hydroxyapatite_solid_mol_per_m3 = amount;
    state.geochemistry_solids[0].calcite_solid_mol_per_m3 = amount;
    const carbon_before = geochemistryInventoryShape(state.geochemistry_solids[0], 4).carbon_mol * 12;
    const allowance = try rebaseLayerWithRoundoff(
        &state,
        0,
        4,
        4.5,
        .{ .phosphate_non_band = 1, .phosphate_band = 0 },
        12,
        31,
    );
    const carbon_after = geochemistryInventoryShape(state.geochemistry_solids[0], 4.5).carbon_mol * 12;
    try std.testing.expectEqual(@as(f64, 0), allowance.phosphorus_mol);
    try std.testing.expect(allowance.carbon_mol > 0);
    try std.testing.expect(allowance.carbon_g >= @abs(carbon_after - carbon_before));
    try std.testing.expect(allowance.calcium_mol > 0);
    try std.testing.expectEqual(allowance.carbon_mol, allowance.calcium_mol);
    try std.testing.expectEqual(
        amount * (4.0 / 4.5),
        state.band_phosphate[0].hydroxyapatite_solid_mol_per_m3,
    );
    try std.testing.expectEqual(
        amount * (4.0 / 4.5),
        state.geochemistry_solids[0].calcite_solid_mol_per_m3,
    );
}

test "allowance contracts with a vanishing nonzero inventory fraction" {
    var full_state = try chemistry.State.init(std.testing.allocator, 1);
    defer full_state.deinit();
    var small_state = try chemistry.State.init(std.testing.allocator, 1);
    defer small_state.deinit();
    const amount = 31.596673933440005;
    full_state.non_band_phosphate[0].dicalcium_phosphate_solid_mol_per_m3 = amount;
    small_state.non_band_phosphate[0].dicalcium_phosphate_solid_mol_per_m3 = amount;
    const full = try previewLayerRoundoff(
        &full_state,
        0,
        4,
        4.5,
        .{ .phosphate_non_band = 1, .phosphate_band = 0 },
        12,
        31,
    );
    const small_fraction = 1.0e-9;
    const small = try previewLayerRoundoff(
        &small_state,
        0,
        4,
        4.5,
        .{
            .phosphate_non_band = small_fraction,
            .phosphate_band = 1 - small_fraction,
        },
        12,
        31,
    );
    try std.testing.expect(full.phosphorus_mol > 0);
    try std.testing.expect(small.phosphorus_mol > 0);
    try std.testing.expect(small.phosphorus_mol <
        full.phosphorus_mol * 1.0e-6);
    try std.testing.expectEqual(small.phosphorus_mol, small.calcium_mol);
}

test "repeated fraction-weighted carrier chains retain certificate" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    seedImmobilePhosphate(&state);
    const fractions: InventoryFractions = .{
        .phosphate_non_band = 0.8,
        .phosphate_band = 0.2,
    };
    const initial_non_band = phosphateInventoryShape(
        state.non_band_phosphate[0],
        4,
        fractions.phosphate_non_band,
    );
    const initial_band = phosphateInventoryShape(
        state.band_phosphate[0],
        4,
        fractions.phosphate_band,
    );
    const carriers = [_]f64{ 4.5, 5, 4.75, 4 };
    var old_water_m3: f64 = 4;
    var cumulative: RoundoffAllowance = .{};
    for (0..64) |step| {
        const new_water_m3 = carriers[step % carriers.len];
        try cumulative.add(try rebaseLayerWithRoundoff(
            &state,
            0,
            old_water_m3,
            new_water_m3,
            fractions,
            12,
            31,
        ));
        old_water_m3 = new_water_m3;
    }
    const final_non_band = phosphateInventoryShape(
        state.non_band_phosphate[0],
        old_water_m3,
        fractions.phosphate_non_band,
    );
    const final_band = phosphateInventoryShape(
        state.band_phosphate[0],
        old_water_m3,
        fractions.phosphate_band,
    );
    inline for (std.meta.fields(RoundoffAllowance)) |field| {
        const initial = @field(initial_non_band, field.name) +
            @field(initial_band, field.name);
        const final = @field(final_non_band, field.name) +
            @field(final_band, field.name);
        try std.testing.expect(@field(cumulative, field.name) >=
            @abs(final - initial));
    }
}

test "invalid fractions and uncertified mutation reject atomically" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.non_band_phosphate[0].dicalcium_phosphate_solid_mol_per_m3 = 1;
    state.geochemistry_solids[0].calcite_solid_mol_per_m3 = 2;
    const aqueous_before = state.aqueous[0];
    const non_band_before = state.non_band_phosphate[0];
    const band_before = state.band_phosphate[0];
    const geochemistry_before = state.geochemistry_solids[0];
    try std.testing.expectError(
        error.InvalidSoilChemistryInventoryFraction,
        previewLayerRoundoff(
            &state,
            0,
            4,
            4.5,
            .{ .phosphate_non_band = 0.8, .phosphate_band = 0.3 },
            12,
            31,
        ),
    );
    try std.testing.expectError(
        error.InvalidSoilChemistryInventoryFraction,
        previewLayerRoundoff(
            &state,
            0,
            4,
            4.5,
            .{ .phosphate_non_band = std.math.nan(f64), .phosphate_band = 0 },
            12,
            31,
        ),
    );
    try std.testing.expectEqualDeep(non_band_before, state.non_band_phosphate[0]);

    try std.testing.expectError(
        error.InvalidSoilChemistryInventoryMolarMass,
        previewLayerRoundoff(
            &state,
            0,
            4,
            4.5,
            .{ .phosphate_non_band = 1, .phosphate_band = 0 },
            0,
            31,
        ),
    );
    try std.testing.expectError(
        error.InvalidSoilChemistryInventoryMolarMass,
        previewLayerRoundoff(
            &state,
            0,
            4,
            4.5,
            .{ .phosphate_non_band = 1, .phosphate_band = 0 },
            12,
            std.math.nan(f64),
        ),
    );
    try std.testing.expectEqualDeep(non_band_before, state.non_band_phosphate[0]);

    try std.testing.expectError(
        error.SoilChemistryWaterCarrierRoundoffExceeded,
        rebaseLayerWithRoundoff(
            &state,
            0,
            std.math.floatMin(f64),
            std.math.floatMax(f64),
            .{ .phosphate_non_band = 1, .phosphate_band = 0 },
            12,
            31,
        ),
    );
    try std.testing.expectEqualDeep(aqueous_before, state.aqueous[0]);
    try std.testing.expectEqualDeep(non_band_before, state.non_band_phosphate[0]);
    try std.testing.expectEqualDeep(band_before, state.band_phosphate[0]);
    try std.testing.expectEqualDeep(geochemistry_before, state.geochemistry_solids[0]);

    var impossible = non_band_before;
    impossible.dicalcium_phosphate_solid_mol_per_m3 = 0.5;
    try std.testing.expectError(
        error.SoilChemistryWaterCarrierRoundoffExceeded,
        phosphateImmobileRoundoff(non_band_before, impossible, 1, 1, 1),
    );
    try std.testing.expectEqualDeep(non_band_before, state.non_band_phosphate[0]);

    try std.testing.expectError(
        error.InvalidSoilChemistryWaterCarrier,
        rebaseLayer(&state, 0, std.math.floatMax(f64), std.math.floatMin(f64)),
    );
    try std.testing.expectEqualDeep(aqueous_before, state.aqueous[0]);
    try std.testing.expectEqualDeep(non_band_before, state.non_band_phosphate[0]);
    try std.testing.expectEqualDeep(band_before, state.band_phosphate[0]);
    try std.testing.expectEqualDeep(geochemistry_before, state.geochemistry_solids[0]);
}
