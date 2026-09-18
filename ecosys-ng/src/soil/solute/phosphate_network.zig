const std = @import("std");
const exchange = @import("phosphate_exchange.zig");
const diagnostic_control = @import("reaction_diagnostic_control.zig");

pub const MineralFluxes = struct {
    aluminum_phosphate_mol_per_m3: f64,
    iron_phosphate_mol_per_m3: f64,
    dicalcium_phosphate_mol_per_m3: f64,
    hydroxyapatite_mol_per_m3: f64,
    monocalcium_phosphate_mol_per_m3: f64,
};

pub const DissociationAndPairingFluxes = struct {
    po4_hydrogen_association_mol_p_per_m3: f64,
    hpo4_hydrogen_association_mol_p_per_m3: f64,
    h2po4_hydrogen_association_mol_p_per_m3: f64,
    iron_hpo4_pairing_mol_p_per_m3: f64,
    iron_h2po4_pairing_mol_p_per_m3: f64,
    calcium_po4_pairing_mol_p_per_m3: f64,
    calcium_hpo4_pairing_mol_p_per_m3: f64,
    calcium_h2po4_pairing_mol_p_per_m3: f64,
    magnesium_hpo4_pairing_mol_p_per_m3: f64,
};

pub const Fluxes = struct {
    minerals: MineralFluxes,
    surface: exchange.Flux,
    aqueous: DissociationAndPairingFluxes,
    soil_mass_per_water_volume_megagrams_per_m3: f64,
};

pub const Transformations = struct {
    dissolved_po4_mol_p_per_m3: f64,
    dissolved_hpo4_mol_p_per_m3: f64,
    dissolved_h2po4_mol_p_per_m3: f64,
    dissolved_h3po4_mol_p_per_m3: f64,
    deprotonated_site_mol_per_megagram: f64,
    hydroxyl_site_mol_per_megagram: f64,
    protonated_site_mol_per_megagram: f64,
    adsorbed_hpo4_mol_p_per_megagram: f64,
    adsorbed_h2po4_mol_p_per_megagram: f64,
    dissolved_aluminum_mol_per_m3: f64,
    dissolved_iron_mol_per_m3: f64,
    dissolved_calcium_mol_per_m3: f64,
    dissolved_magnesium_mol_per_m3: f64,
    dissolved_hydrogen_mol_per_m3: f64,
    dissolved_hydroxide_mol_per_m3: f64,
    water_mol_per_m3: f64,
    aluminum_phosphate_solid_mol_per_m3: f64,
    iron_phosphate_solid_mol_per_m3: f64,
    dicalcium_phosphate_solid_mol_per_m3: f64,
    hydroxyapatite_solid_mol_per_m3: f64,
    monocalcium_phosphate_solid_mol_per_m3: f64,
    iron_hpo4_pair_mol_per_m3: f64,
    iron_h2po4_pair_mol_per_m3: f64,
    calcium_po4_pair_mol_per_m3: f64,
    calcium_hpo4_pair_mol_per_m3: f64,
    calcium_h2po4_pair_mol_per_m3: f64,
    magnesium_hpo4_pair_mol_per_m3: f64,
};

pub const State = struct {
    dissolved_po4_mol_p_per_m3: f64,
    dissolved_hpo4_mol_p_per_m3: f64,
    dissolved_h2po4_mol_p_per_m3: f64,
    dissolved_h3po4_mol_p_per_m3: f64,
    deprotonated_site_mol_per_megagram: f64,
    hydroxyl_site_mol_per_megagram: f64,
    protonated_site_mol_per_megagram: f64,
    adsorbed_hpo4_mol_p_per_megagram: f64,
    adsorbed_h2po4_mol_p_per_megagram: f64,
    aluminum_phosphate_solid_mol_per_m3: f64,
    iron_phosphate_solid_mol_per_m3: f64,
    dicalcium_phosphate_solid_mol_per_m3: f64,
    hydroxyapatite_solid_mol_per_m3: f64,
    monocalcium_phosphate_solid_mol_per_m3: f64,
    iron_hpo4_pair_mol_per_m3: f64,
    iron_h2po4_pair_mol_per_m3: f64,
    calcium_po4_pair_mol_per_m3: f64,
    calcium_hpo4_pair_mol_per_m3: f64,
    calcium_h2po4_pair_mol_per_m3: f64,
    magnesium_hpo4_pair_mol_per_m3: f64,
};

pub const SourceIterationStage = enum {
    before_iteration_ceiling,
    iteration_ceiling,
};

/// Applies every phosphate-network destination atomically. This is the state
/// transaction used by a chemistry iterate; failed validation changes nothing.
pub fn state_update(state: *State, transformations: Transformations) !void {
    try validateState(state.*);
    var next = state.*;
    inline for (@typeInfo(State).@"struct".fields) |field| {
        const change = @field(transformations, field.name);
        if (!std.math.isFinite(change)) return error.NonFinitePhosphateNetworkTransformation;
        @field(next, field.name) += change;
    }
    try validateState(next);
    state.* = next;
}

/// Applies one phosphate-zone transaction using the changes that were
/// actually representable in every stored pool.  The returned transformation
/// is the realized transaction for coupling to the shared aqueous metals.
/// This keeps independently rounded donor/recipient additions from leaking P,
/// exchange sites, or a paired metal at accepted-state publication.
pub fn state_updateRealized(
    state: *State,
    transformations: Transformations,
    soil_mass_per_water_volume_megagrams_per_m3: f64,
) !Transformations {
    if (!std.math.isFinite(soil_mass_per_water_volume_megagrams_per_m3) or
        soil_mass_per_water_volume_megagrams_per_m3 < 0)
        return error.InvalidPhosphateNetworkDensity;
    if (soil_mass_per_water_volume_megagrams_per_m3 == 0) {
        inline for (@typeInfo(State).@"struct".fields) |field| {
            const change = @field(transformations, field.name);
            if (!std.math.isFinite(change))
                return error.NonFinitePhosphateNetworkTransformation;
            if (change != 0) return error.InvalidPhosphateNetworkDensity;
        }
        return transformations;
    }
    const before = state.*;
    var next = before;
    try state_update(&next, transformations);

    try reconcileSiteInventory(&next, before, transformations);
    try reconcilePhosphorusInventory(
        &next,
        before,
        transformations,
        soil_mass_per_water_volume_megagrams_per_m3,
    );

    var realized = transformations;
    inline for (@typeInfo(State).@"struct".fields) |field| {
        const change = @field(next, field.name) - @field(before, field.name);
        if (!std.math.isFinite(change))
            return error.NonFinitePhosphateNetworkTransformation;
        @field(realized, field.name) = change;
    }
    // Shared metals are the other half of the mineral/pair transaction.  Use
    // actual stored deltas, not ideal extents that may have rounded away.
    realized.dissolved_aluminum_mol_per_m3 =
        -realized.aluminum_phosphate_solid_mol_per_m3;
    realized.dissolved_iron_mol_per_m3 =
        -(realized.iron_phosphate_solid_mol_per_m3 +
            realized.iron_hpo4_pair_mol_per_m3 +
            realized.iron_h2po4_pair_mol_per_m3);
    realized.dissolved_calcium_mol_per_m3 =
        -(realized.dicalcium_phosphate_solid_mol_per_m3 +
            5 * realized.hydroxyapatite_solid_mol_per_m3 +
            realized.monocalcium_phosphate_solid_mol_per_m3 +
            realized.calcium_po4_pair_mol_per_m3 +
            realized.calcium_hpo4_pair_mol_per_m3 +
            realized.calcium_h2po4_pair_mol_per_m3);
    realized.dissolved_magnesium_mol_per_m3 =
        -realized.magnesium_hpo4_pair_mol_per_m3;
    // Mineral storage can round independently of its shared aqueous half.
    // Retain the non-mineral H/OH terms from the assembled transformation,
    // but replace every ideal mineral extent by the extent actually stored.
    // This is the proton/hydroxide counterpart of the exact metal coupling
    // above and is required even when reconciliation changes only one ULP.
    realized.dissolved_hydrogen_mol_per_m3 =
        transformations.dissolved_hydrogen_mol_per_m3 +
        2 * (realized.aluminum_phosphate_solid_mol_per_m3 -
            transformations.aluminum_phosphate_solid_mol_per_m3) +
        2 * (realized.iron_phosphate_solid_mol_per_m3 -
            transformations.iron_phosphate_solid_mol_per_m3) +
        (realized.dicalcium_phosphate_solid_mol_per_m3 -
            transformations.dicalcium_phosphate_solid_mol_per_m3) +
        6 * (realized.hydroxyapatite_solid_mol_per_m3 -
            transformations.hydroxyapatite_solid_mol_per_m3);
    realized.dissolved_hydroxide_mol_per_m3 =
        transformations.dissolved_hydroxide_mol_per_m3 -
        (realized.hydroxyapatite_solid_mol_per_m3 -
            transformations.hydroxyapatite_solid_mol_per_m3);
    state.* = next;
    return realized;
}

pub fn phosphorusInventory(
    state: State,
    soil_mass_per_water_volume_megagrams_per_m3: f64,
) !f64 {
    try validateState(state);
    if (!std.math.isFinite(soil_mass_per_water_volume_megagrams_per_m3) or
        soil_mass_per_water_volume_megagrams_per_m3 < 0)
        return error.InvalidPhosphateNetworkDensity;
    const result = state.dissolved_po4_mol_p_per_m3 +
        state.dissolved_hpo4_mol_p_per_m3 +
        state.dissolved_h2po4_mol_p_per_m3 +
        state.dissolved_h3po4_mol_p_per_m3 +
        soil_mass_per_water_volume_megagrams_per_m3 *
            (state.adsorbed_hpo4_mol_p_per_megagram +
                state.adsorbed_h2po4_mol_p_per_megagram) +
        state.aluminum_phosphate_solid_mol_per_m3 +
        state.iron_phosphate_solid_mol_per_m3 +
        state.dicalcium_phosphate_solid_mol_per_m3 +
        3 * state.hydroxyapatite_solid_mol_per_m3 +
        2 * state.monocalcium_phosphate_solid_mol_per_m3 +
        state.iron_hpo4_pair_mol_per_m3 +
        state.iron_h2po4_pair_mol_per_m3 +
        state.calcium_po4_pair_mol_per_m3 +
        state.calcium_hpo4_pair_mol_per_m3 +
        state.calcium_h2po4_pair_mol_per_m3 +
        state.magnesium_hpo4_pair_mol_per_m3;
    if (!std.math.isFinite(result) or result < 0)
        return error.InvalidPhosphateNetworkInventory;
    return result;
}

pub fn siteInventory(state: State) !f64 {
    try validateState(state);
    const result = state.deprotonated_site_mol_per_megagram +
        state.hydroxyl_site_mol_per_megagram +
        state.protonated_site_mol_per_megagram +
        state.adsorbed_hpo4_mol_p_per_megagram +
        state.adsorbed_h2po4_mol_p_per_megagram;
    if (!std.math.isFinite(result) or result < 0)
        return error.InvalidPhosphateNetworkInventory;
    return result;
}

fn reconcileSiteInventory(
    next: *State,
    before: State,
    transformations: Transformations,
) !void {
    const ideal_residual = siteTransformation(transformations);
    const ideal_scale = siteTransformationMagnitude(transformations);
    // A relative-only envelope becomes zero when every reaction extent is
    // subnormal, even though correctly rounded assembly can retain one least
    // subnormal ULP after the algebraic donor/recipient cancellation.  The
    // absolute term is an operation-count bound, not a physical tolerance;
    // accepted endpoints are still reconciled against the original inventory.
    const ideal_envelope = @max(
        32 * std.math.floatEps(f64) * ideal_scale,
        32 * std.math.floatTrueMin(f64),
    );
    if (@abs(ideal_residual) > ideal_envelope) {
        if (diagnostic_control.isEnabled()) std.log.warn(
            "phosphate site reconciliation rejected nonconservative transformation: residual={e} magnitude={e} envelope={e}",
            .{ ideal_residual, ideal_scale, ideal_envelope },
        );
        return error.NonConservativePhosphateSiteUpdate;
    }
    const target = try siteInventory(before);
    const proposed = next.*;
    const proposed_inventory = try siteInventory(proposed);
    const roundoff_envelope = @max(
        64 * std.math.floatEps(f64) * @max(target, proposed_inventory),
        64 * std.math.floatTrueMin(f64),
    );
    if (@abs(proposed_inventory - target) > roundoff_envelope) {
        if (diagnostic_control.isEnabled()) std.log.warn(
            "phosphate site reconciliation rejected stored endpoint: before={e} proposed={e} delta={e} envelope={e}",
            .{ target, proposed_inventory, proposed_inventory - target, roundoff_envelope },
        );
        return error.NonConservativePhosphateSiteUpdate;
    }

    const primary_owner = largestMutableSiteOwner(next);
    var roundoff_candidate: ?State = null;
    if (try reconcileSiteOwnerExact(
        next,
        before,
        primary_owner,
        siteOwnerBeforeValue(next, before, primary_owner),
    )) return;
    if (@abs((try siteInventory(next.*)) - target) <= roundoff_envelope and
        siteRealizedTransferClosed(before, next.*))
        roundoff_candidate = next.*;
    const Candidate = struct { owner: *f64, before_value: f64 };
    const candidates = [_]Candidate{
        .{ .owner = &next.deprotonated_site_mol_per_megagram, .before_value = before.deprotonated_site_mol_per_megagram },
        .{ .owner = &next.hydroxyl_site_mol_per_megagram, .before_value = before.hydroxyl_site_mol_per_megagram },
        .{ .owner = &next.protonated_site_mol_per_megagram, .before_value = before.protonated_site_mol_per_megagram },
    };
    for (candidates) |candidate| {
        if (candidate.owner == primary_owner) continue;
        next.* = proposed;
        if (try reconcileSiteOwnerExact(
            next,
            before,
            candidate.owner,
            candidate.before_value,
        )) return;
        if (roundoff_candidate == null and
            @abs((try siteInventory(next.*)) - target) <= roundoff_envelope and
            siteRealizedTransferClosed(before, next.*))
            roundoff_candidate = next.*;
    }
    if (roundoff_candidate) |candidate| {
        next.* = candidate;
        return;
    }
    if (diagnostic_control.isEnabled()) {
        const realized = realizedStateChange(before, proposed);
        std.log.warn(
            "phosphate site reconciliation could not represent exact closure: before={e} proposed={e} endpoint_delta={e} envelope={e} realized_residual={e} before_sites=[{e},{e},{e},{e},{e}] proposed_sites=[{e},{e},{e},{e},{e}] requested_changes=[{e},{e},{e},{e},{e}]",
            .{
                target,
                proposed_inventory,
                proposed_inventory - target,
                roundoff_envelope,
                siteTransformation(realized),
                before.deprotonated_site_mol_per_megagram,
                before.hydroxyl_site_mol_per_megagram,
                before.protonated_site_mol_per_megagram,
                before.adsorbed_hpo4_mol_p_per_megagram,
                before.adsorbed_h2po4_mol_p_per_megagram,
                proposed.deprotonated_site_mol_per_megagram,
                proposed.hydroxyl_site_mol_per_megagram,
                proposed.protonated_site_mol_per_megagram,
                proposed.adsorbed_hpo4_mol_p_per_megagram,
                proposed.adsorbed_h2po4_mol_p_per_megagram,
                transformations.deprotonated_site_mol_per_megagram,
                transformations.hydroxyl_site_mol_per_megagram,
                transformations.protonated_site_mol_per_megagram,
                transformations.adsorbed_hpo4_mol_p_per_megagram,
                transformations.adsorbed_h2po4_mol_p_per_megagram,
            },
        );
    }
    next.* = proposed;
    return error.NonConservativePhosphateSiteUpdate;
}

fn reconcileSiteOwnerExact(
    next: *State,
    before: State,
    owner: *f64,
    before_owner: f64,
) !bool {
    // Reconstruct the chosen stored delta from all other realized deltas. This
    // proves donor loss equals recipient gain locally; endpoint sums alone can
    // hide a missing small recipient behind a much larger unrelated pool.
    owner.* = before_owner;
    const other_residual = siteTransformation(
        realizedStateChange(before, next.*),
    );
    const reconstructed = before_owner - other_residual;
    if (!std.math.isFinite(reconstructed) or reconstructed < 0) return false;
    owner.* = reconstructed;
    var residual = siteTransformation(realizedStateChange(before, next.*));
    if (residual == 0) return true;
    const direction = if (residual < 0)
        std.math.inf(f64)
    else
        -std.math.inf(f64);
    var adjacent_attempt: u8 = 0;
    while (adjacent_attempt < 8) : (adjacent_attempt += 1) {
        const adjacent = std.math.nextAfter(f64, owner.*, direction);
        if (!std.math.isFinite(adjacent) or adjacent < 0 or adjacent == owner.*)
            return false;
        owner.* = adjacent;
        const adjacent_residual = siteTransformation(
            realizedStateChange(before, next.*),
        );
        if (adjacent_residual == 0) return true;
        if ((residual < 0 and adjacent_residual > 0) or
            (residual > 0 and adjacent_residual < 0))
            return false;
        residual = adjacent_residual;
    }
    return false;
}

fn siteOwnerBeforeValue(
    next: *State,
    before: State,
    owner: *f64,
) f64 {
    if (owner == &next.deprotonated_site_mol_per_megagram)
        return before.deprotonated_site_mol_per_megagram;
    if (owner == &next.hydroxyl_site_mol_per_megagram)
        return before.hydroxyl_site_mol_per_megagram;
    return before.protonated_site_mol_per_megagram;
}

fn reconcilePhosphorusInventory(
    next: *State,
    before: State,
    transformations: Transformations,
    density: f64,
) !void {
    const ideal_residual = phosphorusTransformation(transformations, density);
    const ideal_scale = phosphorusTransformationMagnitude(
        transformations,
        density,
    );
    const ideal_envelope = @max(
        128 * std.math.floatEps(f64) * ideal_scale,
        128 * std.math.floatTrueMin(f64),
    );
    if (@abs(ideal_residual) > ideal_envelope)
        return error.NonConservativePhosphateInventoryUpdate;
    const target = try phosphorusInventory(before, density);
    const proposed = next.*;
    const proposed_inventory = try phosphorusInventory(proposed, density);
    // Reconciliation is only a representation-level repair. The inventory is
    // a sum of nonnegative f64 terms after component-wise state additions; 128
    // eps covers those additions, density products, and both inventory sums
    // with ample operation-count margin. A larger discrepancy is a physical
    // transformation defect and must never be rewritten into another pool.
    const roundoff_envelope = @max(
        128 * std.math.floatEps(f64) * @max(target, proposed_inventory),
        128 * std.math.floatTrueMin(f64),
    );
    if (@abs(proposed_inventory - target) > roundoff_envelope)
        return error.NonConservativePhosphateInventoryUpdate;
    const primary_owner = largestDissolvedPhosphorusOwner(next);
    var roundoff_candidate: ?State = null;
    if (try reconcilePhosphorusOwnerExact(
        next,
        before,
        density,
        target,
        primary_owner,
        1,
    )) return;
    if (try phosphorusInventory(next.*, density) == target and
        phosphorusRealizedTransferClosed(before, next.*, density))
        roundoff_candidate = next.*;

    // The preferred largest dissolved pool minimizes relative perturbation and
    // remains bit-identical for every transaction it can close. A fully
    // depleted dissolved family can nevertheless leave an independently
    // rounded recipient endpoint one ULP above the conserved target, making a
    // nonnegative dissolved reconstruction impossible. Try the other non-site
    // phosphorus owners before rejecting that otherwise valid transaction.
    // Adsorbed owners are deliberately excluded because changing either would
    // reopen the separately exact exchange-site inventory. A metal-bearing
    // owner may only repair a reaction which is already active in the requested
    // transformation. Otherwise a phosphorus-only roundoff correction would
    // manufacture an Al/Fe/Ca/Mg transfer that has no scientific reaction.
    // Active mineral/pair corrections are reflected into their shared-metal
    // counterparts when the realized transformation is assembled by the
    // caller.
    const Candidate = struct {
        owner: *f64,
        phosphorus_weight: f64,
        enabled: bool = true,
    };
    const candidates = [_]Candidate{
        .{ .owner = &next.dissolved_po4_mol_p_per_m3, .phosphorus_weight = 1 },
        .{ .owner = &next.dissolved_hpo4_mol_p_per_m3, .phosphorus_weight = 1 },
        .{ .owner = &next.dissolved_h2po4_mol_p_per_m3, .phosphorus_weight = 1 },
        .{ .owner = &next.dissolved_h3po4_mol_p_per_m3, .phosphorus_weight = 1 },
        .{ .owner = &next.aluminum_phosphate_solid_mol_per_m3, .phosphorus_weight = 1, .enabled = transformations.aluminum_phosphate_solid_mol_per_m3 != 0 },
        .{ .owner = &next.iron_phosphate_solid_mol_per_m3, .phosphorus_weight = 1, .enabled = transformations.iron_phosphate_solid_mol_per_m3 != 0 },
        .{ .owner = &next.dicalcium_phosphate_solid_mol_per_m3, .phosphorus_weight = 1, .enabled = transformations.dicalcium_phosphate_solid_mol_per_m3 != 0 },
        .{ .owner = &next.hydroxyapatite_solid_mol_per_m3, .phosphorus_weight = 3, .enabled = transformations.hydroxyapatite_solid_mol_per_m3 != 0 },
        .{ .owner = &next.monocalcium_phosphate_solid_mol_per_m3, .phosphorus_weight = 2, .enabled = transformations.monocalcium_phosphate_solid_mol_per_m3 != 0 },
        .{ .owner = &next.iron_hpo4_pair_mol_per_m3, .phosphorus_weight = 1, .enabled = transformations.iron_hpo4_pair_mol_per_m3 != 0 },
        .{ .owner = &next.iron_h2po4_pair_mol_per_m3, .phosphorus_weight = 1, .enabled = transformations.iron_h2po4_pair_mol_per_m3 != 0 },
        .{ .owner = &next.calcium_po4_pair_mol_per_m3, .phosphorus_weight = 1, .enabled = transformations.calcium_po4_pair_mol_per_m3 != 0 },
        .{ .owner = &next.calcium_hpo4_pair_mol_per_m3, .phosphorus_weight = 1, .enabled = transformations.calcium_hpo4_pair_mol_per_m3 != 0 },
        .{ .owner = &next.calcium_h2po4_pair_mol_per_m3, .phosphorus_weight = 1, .enabled = transformations.calcium_h2po4_pair_mol_per_m3 != 0 },
        .{ .owner = &next.magnesium_hpo4_pair_mol_per_m3, .phosphorus_weight = 1, .enabled = transformations.magnesium_hpo4_pair_mol_per_m3 != 0 },
    };
    for (candidates) |candidate| {
        if (!candidate.enabled or candidate.owner == primary_owner) continue;
        next.* = proposed;
        if (try reconcilePhosphorusOwnerExact(
            next,
            before,
            density,
            target,
            candidate.owner,
            candidate.phosphorus_weight,
        )) return;
        if (roundoff_candidate == null and
            try phosphorusInventory(next.*, density) == target and
            phosphorusRealizedTransferClosed(before, next.*, density))
            roundoff_candidate = next.*;
    }
    if (roundoff_candidate) |candidate| {
        next.* = candidate;
        return;
    }

    // Every scientifically permissible single-owner reconstruction above has
    // now proved that exact endpoint equality is not representable.  Preserve
    // the independently rounded endpoint only if its realized donor/recipient
    // transaction closes on the process activity itself.  This tighter local
    // gate prevents a large background inventory from hiding a missing small
    // reaction while admitting the unavoidable one-ULP endpoint residual
    // already bounded by `roundoff_envelope`.
    if (preserveProcessClosedUnrepresentableEndpoint(
        next,
        before,
        proposed,
        density,
    )) return;
    next.* = proposed;
    return error.NonConservativePhosphateInventoryUpdate;
}

fn preserveProcessClosedUnrepresentableEndpoint(
    next: *State,
    before: State,
    proposed: State,
    density: f64,
) bool {
    if (!phosphorusTransferClosed(
        realizedStateChange(before, proposed),
        density,
    )) return false;
    next.* = proposed;
    return true;
}

fn reconcilePhosphorusOwnerExact(
    next: *State,
    before: State,
    density: f64,
    target: f64,
    owner: *f64,
    phosphorus_weight: f64,
) !bool {
    std.debug.assert(phosphorus_weight > 0);
    // First preserve every locally representable donor/recipient correction.
    // This prevents a very large unrelated endpoint pool from hiding a smaller
    // process-scale transfer in the rounded whole-inventory sum. Stop when the
    // remaining correction cannot change its f64 owner; the endpoint
    // reconstruction below handles that adjacent-representation case.
    var local_pass: u8 = 0;
    while (local_pass < 8) : (local_pass += 1) {
        const local_residual = phosphorusTransformation(
            realizedStateChange(before, next.*),
            density,
        );
        if (local_residual == 0) break;
        const corrected = owner.* - local_residual / phosphorus_weight;
        if (!std.math.isFinite(corrected) or corrected < 0)
            return false;
        if (corrected == owner.*) break;
        owner.* = corrected;
    }
    if (try phosphorusInventory(next.*, density) == target and
        phosphorusTransformation(
            realizedStateChange(before, next.*),
            density,
        ) == 0)
        return true;

    // Reconstruct one nonnegative owner from the conserved endpoint
    // inventory.  Incrementing it by a delta-space residual can be a no-op
    // when that residual is smaller than the owner's ULP; endpoint
    // reconstruction preserves the actual stored inventory instead.
    owner.* = 0;
    const inventory_without_owner = try phosphorusInventory(next.*, density);
    const reconstructed = (target - inventory_without_owner) /
        phosphorus_weight;
    if (!std.math.isFinite(reconstructed) or reconstructed < 0)
        return false;
    owner.* = reconstructed;

    var inventory = try phosphorusInventory(next.*, density);
    if (inventory == target and
        phosphorusTransformation(
            realizedStateChange(before, next.*),
            density,
        ) == 0)
        return true;

    // The subtraction above is correctly rounded and can land beside the
    // representable owner whose full endpoint sum equals `target`. Search only
    // adjacent representations, require exact endpoint equality, and reject if
    // the monotone inventory crosses the target without hitting it.
    const realized_residual = phosphorusTransformation(
        realizedStateChange(before, next.*),
        density,
    );
    const direction = if (inventory < target or
        (inventory == target and realized_residual < 0))
        std.math.inf(f64)
    else
        -std.math.inf(f64);
    var adjacent_attempt: u8 = 0;
    while (adjacent_attempt < 8) : (adjacent_attempt += 1) {
        const adjacent = std.math.nextAfter(f64, owner.*, direction);
        if (!std.math.isFinite(adjacent) or adjacent < 0 or adjacent == owner.*)
            return false;
        owner.* = adjacent;
        const adjacent_inventory = try phosphorusInventory(next.*, density);
        if (adjacent_inventory == target and
            phosphorusTransformation(
                realizedStateChange(before, next.*),
                density,
            ) == 0)
            return true;
        if ((inventory < target and adjacent_inventory > target) or
            (inventory > target and adjacent_inventory < target))
            return false;
        inventory = adjacent_inventory;
    }
    return false;
}

fn realizedStateChange(before: State, after: State) Transformations {
    var result = std.mem.zeroes(Transformations);
    inline for (@typeInfo(State).@"struct".fields) |field|
        @field(result, field.name) =
            @field(after, field.name) - @field(before, field.name);
    return result;
}

fn phosphorusTransformation(change: Transformations, density: f64) f64 {
    return change.dissolved_po4_mol_p_per_m3 +
        change.dissolved_hpo4_mol_p_per_m3 +
        change.dissolved_h2po4_mol_p_per_m3 +
        change.dissolved_h3po4_mol_p_per_m3 +
        density * (change.adsorbed_hpo4_mol_p_per_megagram +
            change.adsorbed_h2po4_mol_p_per_megagram) +
        change.aluminum_phosphate_solid_mol_per_m3 +
        change.iron_phosphate_solid_mol_per_m3 +
        change.dicalcium_phosphate_solid_mol_per_m3 +
        3 * change.hydroxyapatite_solid_mol_per_m3 +
        2 * change.monocalcium_phosphate_solid_mol_per_m3 +
        change.iron_hpo4_pair_mol_per_m3 +
        change.iron_h2po4_pair_mol_per_m3 +
        change.calcium_po4_pair_mol_per_m3 +
        change.calcium_hpo4_pair_mol_per_m3 +
        change.calcium_h2po4_pair_mol_per_m3 +
        change.magnesium_hpo4_pair_mol_per_m3;
}

fn phosphorusTransformationMagnitude(
    change: Transformations,
    density: f64,
) f64 {
    return @abs(change.dissolved_po4_mol_p_per_m3) +
        @abs(change.dissolved_hpo4_mol_p_per_m3) +
        @abs(change.dissolved_h2po4_mol_p_per_m3) +
        @abs(change.dissolved_h3po4_mol_p_per_m3) +
        density * (@abs(change.adsorbed_hpo4_mol_p_per_megagram) +
            @abs(change.adsorbed_h2po4_mol_p_per_megagram)) +
        @abs(change.aluminum_phosphate_solid_mol_per_m3) +
        @abs(change.iron_phosphate_solid_mol_per_m3) +
        @abs(change.dicalcium_phosphate_solid_mol_per_m3) +
        3 * @abs(change.hydroxyapatite_solid_mol_per_m3) +
        2 * @abs(change.monocalcium_phosphate_solid_mol_per_m3) +
        @abs(change.iron_hpo4_pair_mol_per_m3) +
        @abs(change.iron_h2po4_pair_mol_per_m3) +
        @abs(change.calcium_po4_pair_mol_per_m3) +
        @abs(change.calcium_hpo4_pair_mol_per_m3) +
        @abs(change.calcium_h2po4_pair_mol_per_m3) +
        @abs(change.magnesium_hpo4_pair_mol_per_m3);
}

/// Local donor/recipient arithmetic after density conversion. Exact endpoint
/// inventory is enforced separately; this bound covers only the finite chain
/// of f64 additions and density products used to form the realized delta.
fn phosphorusTransferClosed(change: Transformations, density: f64) bool {
    return @abs(phosphorusTransformation(change, density)) <=
        128 * std.math.floatEps(f64) *
            phosphorusTransformationMagnitude(change, density);
}

fn phosphorusRealizedTransferClosed(
    before: State,
    after: State,
    density: f64,
) bool {
    const realized = realizedStateChange(before, after);
    const storage_scale = phosphorusStateMagnitude(before, density) +
        phosphorusStateMagnitude(after, density);
    return @abs(phosphorusTransformation(realized, density)) <=
        128 * std.math.floatEps(f64) * storage_scale;
}

fn phosphorusStateMagnitude(state: State, density: f64) f64 {
    return state.dissolved_po4_mol_p_per_m3 +
        state.dissolved_hpo4_mol_p_per_m3 +
        state.dissolved_h2po4_mol_p_per_m3 +
        state.dissolved_h3po4_mol_p_per_m3 +
        density * (state.adsorbed_hpo4_mol_p_per_megagram +
            state.adsorbed_h2po4_mol_p_per_megagram) +
        state.aluminum_phosphate_solid_mol_per_m3 +
        state.iron_phosphate_solid_mol_per_m3 +
        state.dicalcium_phosphate_solid_mol_per_m3 +
        3 * state.hydroxyapatite_solid_mol_per_m3 +
        2 * state.monocalcium_phosphate_solid_mol_per_m3 +
        state.iron_hpo4_pair_mol_per_m3 +
        state.iron_h2po4_pair_mol_per_m3 +
        state.calcium_po4_pair_mol_per_m3 +
        state.calcium_hpo4_pair_mol_per_m3 +
        state.calcium_h2po4_pair_mol_per_m3 +
        state.magnesium_hpo4_pair_mol_per_m3;
}

fn siteTransformation(change: Transformations) f64 {
    return change.deprotonated_site_mol_per_megagram +
        change.hydroxyl_site_mol_per_megagram +
        change.protonated_site_mol_per_megagram +
        change.adsorbed_hpo4_mol_p_per_megagram +
        change.adsorbed_h2po4_mol_p_per_megagram;
}

fn siteTransformationMagnitude(change: Transformations) f64 {
    return @abs(change.deprotonated_site_mol_per_megagram) +
        @abs(change.hydroxyl_site_mol_per_megagram) +
        @abs(change.protonated_site_mol_per_megagram) +
        @abs(change.adsorbed_hpo4_mol_p_per_megagram) +
        @abs(change.adsorbed_h2po4_mol_p_per_megagram);
}

fn siteRealizedTransferClosed(before: State, after: State) bool {
    const realized = realizedStateChange(before, after);
    const storage_scale = siteStateMagnitude(before) +
        siteStateMagnitude(after);
    return @abs(siteTransformation(realized)) <=
        64 * std.math.floatEps(f64) * storage_scale;
}

fn siteStateMagnitude(state: State) f64 {
    return state.deprotonated_site_mol_per_megagram +
        state.hydroxyl_site_mol_per_megagram +
        state.protonated_site_mol_per_megagram +
        state.adsorbed_hpo4_mol_p_per_megagram +
        state.adsorbed_h2po4_mol_p_per_megagram;
}

fn largestMutableSiteOwner(state: *State) *f64 {
    var result = &state.deprotonated_site_mol_per_megagram;
    inline for (.{
        &state.hydroxyl_site_mol_per_megagram,
        &state.protonated_site_mol_per_megagram,
    }) |candidate| if (candidate.* > result.*) {
        result = candidate;
    };
    return result;
}

fn largestDissolvedPhosphorusOwner(state: *State) *f64 {
    var result = &state.dissolved_po4_mol_p_per_m3;
    inline for (.{
        &state.dissolved_hpo4_mol_p_per_m3,
        &state.dissolved_h2po4_mol_p_per_m3,
        &state.dissolved_h3po4_mol_p_per_m3,
    }) |candidate| if (candidate.* > result.*) {
        result = candidate;
    };
    return result;
}

/// Direct update for one zone in SOLUTE.F 2368--2387. The caller invokes it
/// for non-band then band state, preserving source order. Every listed pool is
/// floor-clamped and the entire block is skipped at `M == MRXN`.
pub fn applySourceOrderAqueousUpdate(
    current: State,
    transformations: Transformations,
    minimum_concentration_mol_per_m3: f64,
    stage: SourceIterationStage,
) !State {
    try validateState(current);
    if (!std.math.isFinite(minimum_concentration_mol_per_m3) or
        minimum_concentration_mol_per_m3 <= 0)
        return error.InvalidPhosphateConcentrationFloor;
    inline for (@typeInfo(Transformations).@"struct".fields) |field|
        if (!std.math.isFinite(@field(transformations, field.name)))
            return error.NonFinitePhosphateNetworkTransformation;
    if (stage == .iteration_ceiling) return current;

    var next = current;
    inline for (.{
        "dissolved_po4_mol_p_per_m3",
        "dissolved_hpo4_mol_p_per_m3",
        "dissolved_h2po4_mol_p_per_m3",
        "dissolved_h3po4_mol_p_per_m3",
        "iron_hpo4_pair_mol_per_m3",
        "iron_h2po4_pair_mol_per_m3",
        "calcium_po4_pair_mol_per_m3",
        "calcium_hpo4_pair_mol_per_m3",
        "calcium_h2po4_pair_mol_per_m3",
        "magnesium_hpo4_pair_mol_per_m3",
    }) |name| {
        @field(next, name) = @max(
            minimum_concentration_mol_per_m3,
            @field(current, name) + @field(transformations, name),
        );
    }
    return next;
}

/// Direct surface-site update for one zone in SOLUTE.F 2402--2411. Invoke for
/// non-band then band state. These five pools are not floor-clamped and the
/// block is skipped at the iteration ceiling.
pub fn applySourceOrderSurfaceUpdate(
    current: State,
    transformations: Transformations,
    stage: SourceIterationStage,
) !State {
    try validateState(current);
    inline for (@typeInfo(Transformations).@"struct".fields) |field|
        if (!std.math.isFinite(@field(transformations, field.name)))
            return error.NonFinitePhosphateNetworkTransformation;
    if (stage == .iteration_ceiling) return current;

    var next = current;
    inline for (.{
        "deprotonated_site_mol_per_megagram",
        "hydroxyl_site_mol_per_megagram",
        "protonated_site_mol_per_megagram",
        "adsorbed_hpo4_mol_p_per_megagram",
        "adsorbed_h2po4_mol_p_per_megagram",
    }) |name| {
        @field(next, name) = @field(current, name) +
            @field(transformations, name);
        if (!std.math.isFinite(@field(next, name)) or @field(next, name) < 0)
            return error.InvalidPhosphateSurfaceStateUpdate;
    }
    return next;
}

/// Direct precipitate update for one phosphate zone in SOLUTE.F 2442--2451.
/// Invoke for non-band then band state. No floor is applied and the whole
/// block is skipped at the iteration ceiling.
pub fn applySourceOrderMineralUpdate(
    current: State,
    transformations: Transformations,
    stage: SourceIterationStage,
) !State {
    try validateState(current);
    inline for (@typeInfo(Transformations).@"struct".fields) |field|
        if (!std.math.isFinite(@field(transformations, field.name)))
            return error.NonFinitePhosphateNetworkTransformation;
    if (stage == .iteration_ceiling) return current;

    var next = current;
    inline for (.{
        "aluminum_phosphate_solid_mol_per_m3",
        "iron_phosphate_solid_mol_per_m3",
        "dicalcium_phosphate_solid_mol_per_m3",
        "hydroxyapatite_solid_mol_per_m3",
        "monocalcium_phosphate_solid_mol_per_m3",
    }) |name| {
        @field(next, name) = @field(current, name) +
            @field(transformations, name);
        if (!std.math.isFinite(@field(next, name)) or @field(next, name) < 0)
            return error.InvalidPhosphateMineralStateUpdate;
    }
    return next;
}

/// Dimensionally corrected phosphate portion of SOLUTE.F lines 2143--2226.
/// Flux signs follow the reaction kernels: positive means association,
/// adsorption, or precipitation; negative means the reverse reaction. Surface
/// extents are mol/Mg and are explicitly converted to mol/m3; the source
/// transformation block omits that required conversion.
pub fn assemble(fluxes: Fluxes) !Transformations {
    try validate(fluxes);
    return assembleWithSiteFactor(
        fluxes,
        fluxes.soil_mass_per_water_volume_megagrams_per_m3,
    );
}

/// Exact phosphate-zone portion of SOLUTE.F 2205--2226. The source adds
/// mol Mg-1 surface extents directly to mol m-3 aqueous transformations;
/// factor 1 intentionally retains that dimensional defect for comparison.
pub fn assembleSourceOrder(fluxes: Fluxes) !Transformations {
    try validate(fluxes);
    return assembleWithSiteFactor(fluxes, 1);
}

fn assembleWithSiteFactor(
    fluxes: Fluxes,
    site_to_water: f64,
) Transformations {
    const m = fluxes.minerals;
    const s = fluxes.surface;
    const a = fluxes.aqueous;
    const protonated_site_change = s.protonated_to_hydroxyl_site_mol_per_megagram - s.h2po4_with_protonated_site_mol_p_per_megagram;
    const adsorbed_h2po4_change = s.h2po4_with_protonated_site_mol_p_per_megagram + s.h2po4_with_hydroxyl_site_mol_p_per_megagram;
    return .{
        .dissolved_po4_mol_p_per_m3 = -a.po4_hydrogen_association_mol_p_per_m3 - a.calcium_po4_pairing_mol_p_per_m3,
        .dissolved_hpo4_mol_p_per_m3 = -s.hpo4_with_hydroxyl_site_mol_p_per_megagram * site_to_water + a.po4_hydrogen_association_mol_p_per_m3 - a.hpo4_hydrogen_association_mol_p_per_m3 - a.iron_hpo4_pairing_mol_p_per_m3 - a.calcium_hpo4_pairing_mol_p_per_m3 - a.magnesium_hpo4_pairing_mol_p_per_m3,
        .dissolved_h2po4_mol_p_per_m3 = -m.aluminum_phosphate_mol_per_m3 - m.iron_phosphate_mol_per_m3 - m.dicalcium_phosphate_mol_per_m3 - 3 * m.hydroxyapatite_mol_per_m3 - 2 * m.monocalcium_phosphate_mol_per_m3 - (s.h2po4_with_protonated_site_mol_p_per_megagram + s.h2po4_with_hydroxyl_site_mol_p_per_megagram) * site_to_water + a.hpo4_hydrogen_association_mol_p_per_m3 - a.h2po4_hydrogen_association_mol_p_per_m3 - a.iron_h2po4_pairing_mol_p_per_m3 - a.calcium_h2po4_pairing_mol_p_per_m3,
        .dissolved_h3po4_mol_p_per_m3 = a.h2po4_hydrogen_association_mol_p_per_m3,
        .deprotonated_site_mol_per_megagram = -s.hydroxyl_to_deprotonated_site_mol_per_megagram,
        // Assemble the dependent neutral site from the other net site changes.
        // Cancelling a large source circulation first preserves small transfers
        // and keeps the ideal site ledger conservative at its own net scale.
        .hydroxyl_site_mol_per_megagram = s.hydroxyl_to_deprotonated_site_mol_per_megagram - protonated_site_change - adsorbed_h2po4_change - s.hpo4_with_hydroxyl_site_mol_p_per_megagram,
        .protonated_site_mol_per_megagram = protonated_site_change,
        .adsorbed_hpo4_mol_p_per_megagram = s.hpo4_with_hydroxyl_site_mol_p_per_megagram,
        .adsorbed_h2po4_mol_p_per_megagram = adsorbed_h2po4_change,
        .dissolved_aluminum_mol_per_m3 = -m.aluminum_phosphate_mol_per_m3,
        .dissolved_iron_mol_per_m3 = -m.iron_phosphate_mol_per_m3 - a.iron_hpo4_pairing_mol_p_per_m3 - a.iron_h2po4_pairing_mol_p_per_m3,
        .dissolved_calcium_mol_per_m3 = -m.dicalcium_phosphate_mol_per_m3 - m.monocalcium_phosphate_mol_per_m3 - 5 * m.hydroxyapatite_mol_per_m3 - a.calcium_po4_pairing_mol_p_per_m3 - a.calcium_hpo4_pairing_mol_p_per_m3 - a.calcium_h2po4_pairing_mol_p_per_m3,
        .dissolved_magnesium_mol_per_m3 = -a.magnesium_hpo4_pairing_mol_p_per_m3,
        .dissolved_hydrogen_mol_per_m3 = 2 * (m.aluminum_phosphate_mol_per_m3 + m.iron_phosphate_mol_per_m3) + 6 * m.hydroxyapatite_mol_per_m3 + m.dicalcium_phosphate_mol_per_m3 - (s.protonated_to_hydroxyl_site_mol_per_megagram + s.hydroxyl_to_deprotonated_site_mol_per_megagram) * site_to_water - a.po4_hydrogen_association_mol_p_per_m3 - a.hpo4_hydrogen_association_mol_p_per_m3 - a.h2po4_hydrogen_association_mol_p_per_m3,
        .dissolved_hydroxide_mol_per_m3 = -m.hydroxyapatite_mol_per_m3 + (s.h2po4_with_hydroxyl_site_mol_p_per_megagram + s.hpo4_with_hydroxyl_site_mol_p_per_megagram) * site_to_water,
        .water_mol_per_m3 = s.h2po4_with_protonated_site_mol_p_per_megagram * site_to_water,
        .aluminum_phosphate_solid_mol_per_m3 = m.aluminum_phosphate_mol_per_m3,
        .iron_phosphate_solid_mol_per_m3 = m.iron_phosphate_mol_per_m3,
        .dicalcium_phosphate_solid_mol_per_m3 = m.dicalcium_phosphate_mol_per_m3,
        .hydroxyapatite_solid_mol_per_m3 = m.hydroxyapatite_mol_per_m3,
        .monocalcium_phosphate_solid_mol_per_m3 = m.monocalcium_phosphate_mol_per_m3,
        .iron_hpo4_pair_mol_per_m3 = a.iron_hpo4_pairing_mol_p_per_m3,
        .iron_h2po4_pair_mol_per_m3 = a.iron_h2po4_pairing_mol_p_per_m3,
        .calcium_po4_pair_mol_per_m3 = a.calcium_po4_pairing_mol_p_per_m3,
        .calcium_hpo4_pair_mol_per_m3 = a.calcium_hpo4_pairing_mol_p_per_m3,
        .calcium_h2po4_pair_mol_per_m3 = a.calcium_h2po4_pairing_mol_p_per_m3,
        .magnesium_hpo4_pair_mol_per_m3 = a.magnesium_hpo4_pairing_mol_p_per_m3,
    };
}

fn validate(fluxes: Fluxes) !void {
    inline for (@typeInfo(MineralFluxes).@"struct".fields) |field| if (!std.math.isFinite(@field(fluxes.minerals, field.name))) return error.NonFinitePhosphateNetworkFlux;
    inline for (@typeInfo(exchange.Flux).@"struct".fields) |field| if (!std.math.isFinite(@field(fluxes.surface, field.name))) return error.NonFinitePhosphateNetworkFlux;
    inline for (@typeInfo(DissociationAndPairingFluxes).@"struct".fields) |field| if (!std.math.isFinite(@field(fluxes.aqueous, field.name))) return error.NonFinitePhosphateNetworkFlux;
    if (!std.math.isFinite(fluxes.soil_mass_per_water_volume_megagrams_per_m3) or fluxes.soil_mass_per_water_volume_megagrams_per_m3 <= 0) return error.InvalidPhosphateNetworkDensity;
}

fn validateState(state: State) !void {
    inline for (@typeInfo(State).@"struct".fields) |field| {
        const value = @field(state, field.name);
        if (!std.math.isFinite(value)) return error.NonFinitePhosphateNetworkState;
        if (value < 0) return error.NegativePhosphateNetworkState;
    }
}

fn filledState(value: f64) State {
    var state: State = undefined;
    inline for (@typeInfo(State).@"struct".fields) |field| @field(state, field.name) = value;
    return state;
}

fn filledTransformations(value: f64) Transformations {
    var transformations: Transformations = undefined;
    inline for (@typeInfo(Transformations).@"struct".fields) |field| @field(transformations, field.name) = value;
    return transformations;
}

test "assembled phosphate network conserves phosphorus and exchange sites" {
    const density = 1.7;
    const result = try assemble(.{
        .soil_mass_per_water_volume_megagrams_per_m3 = density,
        .minerals = .{ .aluminum_phosphate_mol_per_m3 = 0.001, .iron_phosphate_mol_per_m3 = -0.002, .dicalcium_phosphate_mol_per_m3 = 0.003, .hydroxyapatite_mol_per_m3 = 0.004, .monocalcium_phosphate_mol_per_m3 = -0.001 },
        .surface = .{ .protonated_to_hydroxyl_site_mol_per_megagram = 0.002, .hydroxyl_to_deprotonated_site_mol_per_megagram = -0.001, .h2po4_with_protonated_site_mol_p_per_megagram = 0.003, .h2po4_with_hydroxyl_site_mol_p_per_megagram = -0.002, .hpo4_with_hydroxyl_site_mol_p_per_megagram = 0.001 },
        .aqueous = .{ .po4_hydrogen_association_mol_p_per_m3 = 0.003, .hpo4_hydrogen_association_mol_p_per_m3 = -0.002, .h2po4_hydrogen_association_mol_p_per_m3 = 0.001, .iron_hpo4_pairing_mol_p_per_m3 = 0.002, .iron_h2po4_pairing_mol_p_per_m3 = -0.001, .calcium_po4_pairing_mol_p_per_m3 = 0.002, .calcium_hpo4_pairing_mol_p_per_m3 = -0.003, .calcium_h2po4_pairing_mol_p_per_m3 = 0.001, .magnesium_hpo4_pairing_mol_p_per_m3 = 0.002 },
    });
    const dissolved_p = result.dissolved_po4_mol_p_per_m3 + result.dissolved_hpo4_mol_p_per_m3 + result.dissolved_h2po4_mol_p_per_m3 + result.dissolved_h3po4_mol_p_per_m3;
    const adsorbed_p = density * (result.adsorbed_hpo4_mol_p_per_megagram + result.adsorbed_h2po4_mol_p_per_megagram);
    const solid_p = result.aluminum_phosphate_solid_mol_per_m3 + result.iron_phosphate_solid_mol_per_m3 + result.dicalcium_phosphate_solid_mol_per_m3 + 3 * result.hydroxyapatite_solid_mol_per_m3 + 2 * result.monocalcium_phosphate_solid_mol_per_m3;
    const paired_p = result.iron_hpo4_pair_mol_per_m3 + result.iron_h2po4_pair_mol_per_m3 + result.calcium_po4_pair_mol_per_m3 + result.calcium_hpo4_pair_mol_per_m3 + result.calcium_h2po4_pair_mol_per_m3 + result.magnesium_hpo4_pair_mol_per_m3;
    try std.testing.expectApproxEqAbs(@as(f64, 0), dissolved_p + adsorbed_p + solid_p + paired_p, 1e-14);
    const sites = result.deprotonated_site_mol_per_megagram + result.hydroxyl_site_mol_per_megagram + result.protonated_site_mol_per_megagram + result.adsorbed_hpo4_mol_p_per_megagram + result.adsorbed_h2po4_mol_p_per_megagram;
    try std.testing.expectApproxEqAbs(@as(f64, 0), sites, 1e-14);
}

test "source-order phosphate assembly omits exchange density conversion" {
    const fluxes = Fluxes{
        .soil_mass_per_water_volume_megagrams_per_m3 = 3,
        .minerals = .{
            .aluminum_phosphate_mol_per_m3 = 0,
            .iron_phosphate_mol_per_m3 = 0,
            .dicalcium_phosphate_mol_per_m3 = 0,
            .hydroxyapatite_mol_per_m3 = 0,
            .monocalcium_phosphate_mol_per_m3 = 0,
        },
        .surface = .{
            .protonated_to_hydroxyl_site_mol_per_megagram = 0.2,
            .hydroxyl_to_deprotonated_site_mol_per_megagram = 0.1,
            .h2po4_with_protonated_site_mol_p_per_megagram = 0.4,
            .h2po4_with_hydroxyl_site_mol_p_per_megagram = 0.3,
            .hpo4_with_hydroxyl_site_mol_p_per_megagram = 0.5,
        },
        .aqueous = .{
            .po4_hydrogen_association_mol_p_per_m3 = 0,
            .hpo4_hydrogen_association_mol_p_per_m3 = 0,
            .h2po4_hydrogen_association_mol_p_per_m3 = 0,
            .iron_hpo4_pairing_mol_p_per_m3 = 0,
            .iron_h2po4_pairing_mol_p_per_m3 = 0,
            .calcium_po4_pairing_mol_p_per_m3 = 0,
            .calcium_hpo4_pairing_mol_p_per_m3 = 0,
            .calcium_h2po4_pairing_mol_p_per_m3 = 0,
            .magnesium_hpo4_pairing_mol_p_per_m3 = 0,
        },
    };
    const source = try assembleSourceOrder(fluxes);
    const corrected = try assemble(fluxes);

    try std.testing.expectEqual(@as(f64, -0.5), source.dissolved_hpo4_mol_p_per_m3);
    try std.testing.expectEqual(@as(f64, -0.7), source.dissolved_h2po4_mol_p_per_m3);
    try std.testing.expectApproxEqAbs(@as(f64, -0.3), source.dissolved_hydrogen_mol_per_m3, 1e-15);
    try std.testing.expectEqual(@as(f64, 0.8), source.dissolved_hydroxide_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0.4), source.water_mol_per_m3);
    try std.testing.expectEqual(3 * source.dissolved_hpo4_mol_p_per_m3, corrected.dissolved_hpo4_mol_p_per_m3);
    try std.testing.expectEqual(3 * source.dissolved_h2po4_mol_p_per_m3, corrected.dissolved_h2po4_mol_p_per_m3);
}

test "phosphate network state state_update is atomic" {
    var state = filledState(1);
    const before = state;
    var changes = filledTransformations(0);
    changes.dissolved_h2po4_mol_p_per_m3 = -2;
    changes.iron_phosphate_solid_mol_per_m3 = 0.2;
    try std.testing.expectError(error.NegativePhosphateNetworkState, state_update(&state, changes));
    try std.testing.expectEqualDeep(before, state);

    changes.dissolved_h2po4_mol_p_per_m3 = -0.2;
    try state_update(&state, changes);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), state.dissolved_h2po4_mol_p_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), state.iron_phosphate_solid_mol_per_m3, 1e-15);
}

test "state_updateRealized is a true zero-in-zero-out identity for a nonzero density" {
    // PERF-REACTION-SPAN-CLOSED-FORM-001: a closed-form (affine, non-
    // bisection) replacement for the reaction-span extent search assumes
    // that a reaction not touching the phosphate network passes an
    // all-zero `Transformations` here and gets back the state completely
    // unchanged, bit-for-bit -- not merely "unchanged within tolerance".
    // This proves that identity directly, for a state with large,
    // unevenly-scaled pools where any nonzero perturbation would show up.
    const density = 1.0e-8;
    var before = filledState(1);
    before.adsorbed_hpo4_mol_p_per_megagram = 0x1p50;
    before.aluminum_phosphate_solid_mol_per_m3 = 0x1p50;
    before.dicalcium_phosphate_solid_mol_per_m3 = 0x1p-40;
    const zero_transformations = filledTransformations(0);

    var state = before;
    const realized = try state_updateRealized(&state, zero_transformations, density);

    try std.testing.expectEqualDeep(before, state);
    try std.testing.expectEqualDeep(zero_transformations, realized);
}

test "site reconciliation admits only operation-bounded subnormal cancellation" {
    const before = filledState(1);
    const least = std.math.floatTrueMin(f64);
    var transformations = std.mem.zeroes(Transformations);
    transformations.deprotonated_site_mol_per_megagram = least;
    transformations.hydroxyl_site_mol_per_megagram = least;
    transformations.protonated_site_mol_per_megagram = least;
    transformations.adsorbed_hpo4_mol_p_per_megagram = least;
    transformations.adsorbed_h2po4_mol_p_per_megagram = -3 * least;
    try std.testing.expectEqual(least, siteTransformation(transformations));

    var next = before;
    try state_update(&next, transformations);
    try reconcileSiteInventory(&next, before, transformations);
    try std.testing.expectEqualDeep(before, next);

    var imbalanced = std.mem.zeroes(Transformations);
    imbalanced.deprotonated_site_mol_per_megagram = 1.0e-8;
    next = before;
    try state_update(&next, imbalanced);
    var diagnostic_guard = diagnostic_control.suppress();
    defer diagnostic_guard.restore();
    try std.testing.expectError(
        error.NonConservativePhosphateSiteUpdate,
        reconcileSiteInventory(&next, before, imbalanced),
    );
}

test "realized phosphate update closes mixed-scale donors and recipients exactly" {
    const density = 1.0e-8;
    var before = filledState(1);
    before.adsorbed_hpo4_mol_p_per_megagram = 0x1p50;
    before.aluminum_phosphate_solid_mol_per_m3 = 0x1p50;
    const transformations = try assemble(.{
        .soil_mass_per_water_volume_megagrams_per_m3 = density,
        .minerals = .{
            .aluminum_phosphate_mol_per_m3 = 0.01,
            .iron_phosphate_mol_per_m3 = 0,
            .dicalcium_phosphate_mol_per_m3 = 0,
            .hydroxyapatite_mol_per_m3 = 0,
            .monocalcium_phosphate_mol_per_m3 = 0,
        },
        .surface = .{
            .protonated_to_hydroxyl_site_mol_per_megagram = 0,
            .hydroxyl_to_deprotonated_site_mol_per_megagram = 0,
            .h2po4_with_protonated_site_mol_p_per_megagram = 0,
            .h2po4_with_hydroxyl_site_mol_p_per_megagram = 0,
            .hpo4_with_hydroxyl_site_mol_p_per_megagram = 0.01,
        },
        .aqueous = std.mem.zeroes(DissociationAndPairingFluxes),
    });
    const phosphorus_before = try phosphorusInventory(before, density);
    const sites_before = try siteInventory(before);

    var independently_rounded = before;
    try state_update(&independently_rounded, transformations);
    const independently_realized = realizedStateChange(
        before,
        independently_rounded,
    );
    try std.testing.expect(
        phosphorusTransformation(independently_realized, density) != 0 or
            siteTransformation(independently_realized) != 0,
    );

    var state = before;
    const realized = try state_updateRealized(
        &state,
        transformations,
        density,
    );
    try std.testing.expectEqual(
        phosphorus_before,
        try phosphorusInventory(state, density),
    );
    try std.testing.expectEqual(sites_before, try siteInventory(state));
    try std.testing.expect(phosphorusTransferClosed(realized, density));
    try std.testing.expectEqual(@as(f64, 0), siteTransformation(realized));
    try std.testing.expectEqual(
        @as(f64, 0),
        realized.aluminum_phosphate_solid_mol_per_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        realized.dissolved_aluminum_mol_per_m3,
    );
}

test "endpoint phosphate reconciliation survives a sub-ULP delta residual" {
    const density = 1.2;
    const before = filledState(10);
    const transformations = try assemble(.{
        .soil_mass_per_water_volume_megagrams_per_m3 = density,
        .minerals = std.mem.zeroes(MineralFluxes),
        .surface = .{
            .protonated_to_hydroxyl_site_mol_per_megagram = 0,
            .hydroxyl_to_deprotonated_site_mol_per_megagram = 0,
            .h2po4_with_protonated_site_mol_p_per_megagram = 1e-4,
            .h2po4_with_hydroxyl_site_mol_p_per_megagram = 0,
            .hpo4_with_hydroxyl_site_mol_p_per_megagram = 0,
        },
        .aqueous = std.mem.zeroes(DissociationAndPairingFluxes),
    });
    var independently_rounded = before;
    try state_update(&independently_rounded, transformations);
    try std.testing.expect(
        phosphorusTransformation(
            realizedStateChange(before, independently_rounded),
            density,
        ) != 0,
    );

    var state = before;
    const realized = try state_updateRealized(&state, transformations, density);
    try std.testing.expectEqual(
        try phosphorusInventory(before, density),
        try phosphorusInventory(state, density),
    );
    _ = realized;
    try std.testing.expect(phosphorusRealizedTransferClosed(
        before,
        state,
        density,
    ));
}

test "phosphate unrepresentable-endpoint fallback preserves only a positive process-closed state" {
    const density = 1.0;
    var before = std.mem.zeroes(State);
    // At this scale the background inventory has a 0.25 ULP. Two positive
    // mineral owners are accumulated after it, while their dissolved
    // recipient is accumulated before it. The same conservative 0.2 transfer
    // therefore gives adjacent endpoint inventory representations.
    before.adsorbed_hpo4_mol_p_per_megagram = 0x1p50;
    before.aluminum_phosphate_solid_mol_per_m3 = 1.1;
    before.iron_phosphate_solid_mol_per_m3 = 1.1;

    var transformations = std.mem.zeroes(Transformations);
    transformations.dissolved_po4_mol_p_per_m3 = 0.2;
    transformations.aluminum_phosphate_solid_mol_per_m3 = -0.1;
    transformations.iron_phosphate_solid_mol_per_m3 = -0.1;
    try std.testing.expectEqual(
        @as(f64, 0),
        phosphorusTransformation(transformations, density),
    );

    var proposed = before;
    try state_update(&proposed, transformations);
    const target_inventory = try phosphorusInventory(before, density);
    const proposed_inventory = try phosphorusInventory(proposed, density);
    try std.testing.expect(proposed_inventory != target_inventory);
    try std.testing.expect(phosphorusTransferClosed(
        realizedStateChange(before, proposed),
        density,
    ));
    try std.testing.expect(proposed.dissolved_po4_mol_p_per_m3 > 0);
    try std.testing.expect(proposed.aluminum_phosphate_solid_mol_per_m3 > 0);
    try std.testing.expect(proposed.iron_phosphate_solid_mol_per_m3 > 0);

    var reconciled = before;
    try std.testing.expect(preserveProcessClosedUnrepresentableEndpoint(
        &reconciled,
        before,
        proposed,
        density,
    ));
    try std.testing.expectEqualDeep(proposed, reconciled);

    // The same rounded endpoint without its dissolved recipient is not a
    // conservative process transfer, even though the huge background storage
    // could make an inventory-relative residual look small.
    var missing_recipient = proposed;
    missing_recipient.dissolved_po4_mol_p_per_m3 = 0;
    var untouched = before;
    try std.testing.expect(!preserveProcessClosedUnrepresentableEndpoint(
        &untouched,
        before,
        missing_recipient,
        density,
    ));
    try std.testing.expectEqualDeep(before, untouched);
}

test "phosphorus roundoff repair cannot manufacture a metal reaction" {
    const density = 1.0;
    var before = std.mem.zeroes(State);
    before.dissolved_po4_mol_p_per_m3 = 0x1p50;
    before.dissolved_hpo4_mol_p_per_m3 = 0x1p50;
    before.dissolved_h2po4_mol_p_per_m3 = 0x1p50;
    before.dissolved_h3po4_mol_p_per_m3 = 0x1p50;
    before.deprotonated_site_mol_per_megagram = 1;
    before.hydroxyl_site_mol_per_megagram = 1;
    before.protonated_site_mol_per_megagram = 1;
    before.adsorbed_hpo4_mol_p_per_megagram = 1;
    const transformations = try assemble(.{
        .soil_mass_per_water_volume_megagrams_per_m3 = density,
        .minerals = std.mem.zeroes(MineralFluxes),
        .surface = .{
            .protonated_to_hydroxyl_site_mol_per_megagram = 0,
            .hydroxyl_to_deprotonated_site_mol_per_megagram = 0,
            .h2po4_with_protonated_site_mol_p_per_megagram = 0,
            .h2po4_with_hydroxyl_site_mol_p_per_megagram = 0,
            .hpo4_with_hydroxyl_site_mol_p_per_megagram = -1.0e-4,
        },
        .aqueous = std.mem.zeroes(DissociationAndPairingFluxes),
    });
    var state = before;
    try std.testing.expectError(
        error.NonConservativePhosphateInventoryUpdate,
        state_updateRealized(&state, transformations, density),
    );
    try std.testing.expectEqualDeep(before, state);
}

test "endpoint phosphate reconciliation preserves all shared mineral coupling" {
    const density = 1.0;
    var before = std.mem.zeroes(State);
    before.dissolved_po4_mol_p_per_m3 = 0.1;
    before.aluminum_phosphate_solid_mol_per_m3 = 0.9;
    var transformations = std.mem.zeroes(Transformations);
    transformations.dissolved_po4_mol_p_per_m3 = -0.1;
    transformations.aluminum_phosphate_solid_mol_per_m3 = 0.1;
    transformations.iron_phosphate_solid_mol_per_m3 = std.math.floatEps(f64);
    transformations.dissolved_hydrogen_mol_per_m3 =
        2 * (transformations.aluminum_phosphate_solid_mol_per_m3 +
            transformations.iron_phosphate_solid_mol_per_m3);
    transformations.dissolved_aluminum_mol_per_m3 =
        -transformations.aluminum_phosphate_solid_mol_per_m3;
    transformations.dissolved_iron_mol_per_m3 =
        -transformations.iron_phosphate_solid_mol_per_m3;
    const target = try phosphorusInventory(before, density);
    var state = before;
    const realized = try state_updateRealized(
        &state,
        transformations,
        density,
    );
    try std.testing.expectEqual(
        target,
        try phosphorusInventory(state, density),
    );
    try std.testing.expectEqual(
        try siteInventory(before),
        try siteInventory(state),
    );
    try std.testing.expectEqual(
        -realized.aluminum_phosphate_solid_mol_per_m3,
        realized.dissolved_aluminum_mol_per_m3,
    );
    try std.testing.expectEqual(
        -realized.iron_phosphate_solid_mol_per_m3,
        realized.dissolved_iron_mol_per_m3,
    );
    try std.testing.expectEqual(
        2 * (realized.aluminum_phosphate_solid_mol_per_m3 +
            realized.iron_phosphate_solid_mol_per_m3),
        realized.dissolved_hydrogen_mol_per_m3,
    );
}

test "endpoint phosphate reconciliation rejects material imbalance atomically" {
    const density = 1.0;
    const before = filledState(1);
    var transformations = std.mem.zeroes(Transformations);
    transformations.dissolved_po4_mol_p_per_m3 = 1.0e-8;
    var state = before;
    try std.testing.expectError(
        error.NonConservativePhosphateInventoryUpdate,
        state_updateRealized(&state, transformations, density),
    );
    try std.testing.expectEqualDeep(before, state);
}

test "source phosphate aqueous update floors before ceiling only" {
    const current = filledState(1);
    var changes = filledTransformations(0);
    changes.dissolved_po4_mol_p_per_m3 = -2;
    changes.dissolved_hpo4_mol_p_per_m3 = 0.25;
    changes.magnesium_hpo4_pair_mol_per_m3 = -0.5;

    const terminal = try applySourceOrderAqueousUpdate(
        current,
        changes,
        0.01,
        .iteration_ceiling,
    );
    try std.testing.expectEqualDeep(current, terminal);

    const continuing = try applySourceOrderAqueousUpdate(
        current,
        changes,
        0.01,
        .before_iteration_ceiling,
    );
    try std.testing.expectEqual(
        @as(f64, 0.01),
        continuing.dissolved_po4_mol_p_per_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 1.25),
        continuing.dissolved_hpo4_mol_p_per_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 0.5),
        continuing.magnesium_hpo4_pair_mol_per_m3,
    );
}

test "source phosphate surface update is unfloored and ceiling gated" {
    const current = filledState(1);
    var changes = filledTransformations(0);
    changes.deprotonated_site_mol_per_megagram = -1;
    changes.hydroxyl_site_mol_per_megagram = 0.25;
    changes.adsorbed_h2po4_mol_p_per_megagram = -0.5;

    const terminal = try applySourceOrderSurfaceUpdate(
        current,
        changes,
        .iteration_ceiling,
    );
    try std.testing.expectEqualDeep(current, terminal);

    const continuing = try applySourceOrderSurfaceUpdate(
        current,
        changes,
        .before_iteration_ceiling,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        continuing.deprotonated_site_mol_per_megagram,
    );
    try std.testing.expectEqual(
        @as(f64, 1.25),
        continuing.hydroxyl_site_mol_per_megagram,
    );
    try std.testing.expectEqual(
        @as(f64, 0.5),
        continuing.adsorbed_h2po4_mol_p_per_megagram,
    );
}

test "source phosphate mineral update is unfloored and ceiling gated" {
    const current = filledState(1);
    var changes = filledTransformations(0);
    changes.aluminum_phosphate_solid_mol_per_m3 = -1;
    changes.hydroxyapatite_solid_mol_per_m3 = 0.25;
    changes.monocalcium_phosphate_solid_mol_per_m3 = -0.5;

    const terminal = try applySourceOrderMineralUpdate(
        current,
        changes,
        .iteration_ceiling,
    );
    try std.testing.expectEqualDeep(current, terminal);

    const continuing = try applySourceOrderMineralUpdate(
        current,
        changes,
        .before_iteration_ceiling,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        continuing.aluminum_phosphate_solid_mol_per_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 1.25),
        continuing.hydroxyapatite_solid_mol_per_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 0.5),
        continuing.monocalcium_phosphate_solid_mol_per_m3,
    );
}

test "surface extents use runtime soil mass per water volume" {
    const density = 2.0;
    const result = try assemble(.{
        .soil_mass_per_water_volume_megagrams_per_m3 = density,
        .minerals = std.mem.zeroes(MineralFluxes),
        .surface = .{
            .protonated_to_hydroxyl_site_mol_per_megagram = 0.2,
            .hydroxyl_to_deprotonated_site_mol_per_megagram = 0.1,
            .h2po4_with_protonated_site_mol_p_per_megagram = 0.3,
            .h2po4_with_hydroxyl_site_mol_p_per_megagram = 0,
            .hpo4_with_hydroxyl_site_mol_p_per_megagram = 0,
        },
        .aqueous = std.mem.zeroes(DissociationAndPairingFluxes),
    });
    try std.testing.expectApproxEqAbs(
        @as(f64, -0.6),
        result.dissolved_hydrogen_mol_per_m3,
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.6),
        result.water_mol_per_m3,
        1e-15,
    );
}
