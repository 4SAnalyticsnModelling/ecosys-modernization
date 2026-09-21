const std = @import("std");
const builtin = @import("builtin");
const surface_module = @import("litter_chemistry.zig");
const carrier_rebase = @import("litter_chemistry_carrier_rebase.zig");
const soil_module = @import("../soil/solute/chemistry_state.zig");
const conservation_sidecar = @import("pond_conservation_sidecar.zig");
const legacy_water_negligible_floor = @import("../core/legacy_water_negligible_floor.zig");

pub const CarrierVolumes = struct {
    surface_water_before_m3: f64,
    soil_shared_water_before_m3: f64,
    soil_phosphate_non_band_water_before_m3: f64,
    surface_water_after_m3: f64,
    soil_shared_water_after_m3: f64,
    soil_phosphate_non_band_water_after_m3: f64,
    surface_dry_mass_before_megagrams: f64,
    soil_dry_mass_before_megagrams: f64,
    surface_dry_mass_after_megagrams: f64,
    soil_dry_mass_after_megagrams: f64,
    /// Non-band reaction concentrations occupy only these shares of matrix
    /// water. Surface pond nitrogen is incorporated into the non-band zone.
    ammonium_non_band_water_fraction: f64 = 1,
    nitrate_non_band_water_fraction: f64 = 1,
    // Fraction of dissolved (water-borne) chemistry to transfer. This may be
    // less than the dry-material fraction when water transfer is capped by
    // available pore capacity. Set equal to fraction when unconstrained.
    dissolved_chemistry_fraction: f64,
    /// Cell horizontal footprint (`DH*DV`, `starts.f:270`), used to derive
    /// this cell's `ZEROS2`-equivalent water-carrier noise floor via
    /// `legacyNegligibleWaterVolumeM3`. issue-069 Finding A: without this,
    /// `calculate`/`acceptedSurfaceTransfer` compared `surface_water_*_m3`
    /// against exact zero only, the same mistranslated-`ZEROS2` shape already
    /// fixed at issue-060/061/063/064/065/066's other call sites.
    cell_area_m2: f64,
};

/// Native extensive carriers for the REDIST L=0 particulate-settling subset.
/// Unlike a pond-domain collapse, settling moves no liquid water and no
/// dissolved chemistry.  The source-order block moves only adsorbed ammonium,
/// the five phosphate surface-site pools, and the five phosphate precipitates.
pub const ParticulateCarriers = struct {
    surface_dry_mass_megagrams: f64,
    soil_dry_mass_megagrams: f64,
    soil_exchange_non_band_fraction: f64,
    soil_phosphate_non_band_fraction: f64,
    surface_mineral_reference_water_m3: f64,
    soil_phosphate_non_band_water_m3: f64,
};

/// Exact native extensive chemistry moved by the particulate equations below.
/// It is computed from the same source concentrations, carriers and fraction
/// that `calculateParticulate` commits, before either owner is mutated.
pub fn acceptedParticulateTransfer(
    surface: *const surface_module.State,
    soil: *const soil_module.State,
    cell: usize,
    destination: usize,
    carriers: ParticulateCarriers,
    fraction: f64,
) !conservation_sidecar.Transfer {
    _ = try calculateParticulate(surface, soil, cell, destination, carriers, fraction);
    const source = surface.cells[cell];
    const dry_scale = fraction * carriers.surface_dry_mass_megagrams;
    const mineral_scale = fraction * carriers.surface_mineral_reference_water_m3;
    var result: conservation_sidecar.Transfer = .{};
    result.nitrogen_mol = dry_scale * source.exchange.ammonium_mol_per_megagram;
    result.phosphorus_mol = dry_scale *
        (source.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram +
            source.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram);

    const minerals = source.phosphate_minerals;
    const aluminum_phosphate = mineral_scale * minerals.aluminum_phosphate_mol_per_m3;
    const iron_phosphate = mineral_scale * minerals.iron_phosphate_mol_per_m3;
    const dicalcium_phosphate = mineral_scale * minerals.dicalcium_phosphate_mol_per_m3;
    const hydroxyapatite = mineral_scale * minerals.hydroxyapatite_mol_per_m3;
    const monocalcium_phosphate = mineral_scale * minerals.monocalcium_phosphate_mol_per_m3;
    result.aluminum_mol += aluminum_phosphate;
    result.iron_mol += iron_phosphate;
    result.calcium_mol += dicalcium_phosphate + 5 * hydroxyapatite + monocalcium_phosphate;
    result.phosphorus_mol += aluminum_phosphate + iron_phosphate +
        dicalcium_phosphate + 3 * hydroxyapatite + 2 * monocalcium_phosphate;
    try result.validate();
    return result;
}

const ParticulateCandidate = struct {
    surface: surface_module.Cell,
    soil_phosphate: @import("../soil/solute/phosphate_network.zig").State,
    soil_pending_phosphate_mol: @import("../soil/solute/phosphate_network.zig").State,
    soil_cations: @import("../soil/solute/cation_exchange.zig").Cations,
    soil_pending_cations_mol: @import("../soil/solute/cation_exchange.zig").Cations,
};

/// REDIST 440--526 for a separated surface (legacy L=0).  Concentration
/// owners are converted to amounts on their native dry-mass or retained-water
/// reference carrier.  The carrier itself does not move in this operation;
/// therefore the retained source concentration falls by `fraction`.
pub fn transferParticulateFractionToSoil(
    surface: *surface_module.State,
    soil: *soil_module.State,
    cell: usize,
    destination: usize,
    carriers: ParticulateCarriers,
    fraction: f64,
) !void {
    const next = try calculateParticulate(surface, soil, cell, destination, carriers, fraction);
    surface.cells[cell] = next.surface;
    soil.non_band_phosphate[destination] = next.soil_phosphate;
    soil.pending_non_band_phosphate_mol[destination] = next.soil_pending_phosphate_mol;
    soil.cation_exchange_mol_per_megagram[destination] = next.soil_cations;
    soil.pending_cation_exchange_mol[destination] = next.soil_pending_cations_mol;
}

pub fn validateParticulateFractionToSoil(
    surface: *const surface_module.State,
    soil: *const soil_module.State,
    cell: usize,
    destination: usize,
    carriers: ParticulateCarriers,
    fraction: f64,
) !void {
    _ = try calculateParticulate(surface, soil, cell, destination, carriers, fraction);
}

fn calculateParticulate(
    surface: *const surface_module.State,
    soil: *const soil_module.State,
    cell: usize,
    destination: usize,
    carriers: ParticulateCarriers,
    fraction: f64,
) !ParticulateCandidate {
    if (cell >= surface.cells.len or destination >= soil.cell_count)
        return error.SurfacePondChemistryIndexOutOfBounds;
    inline for (@typeInfo(ParticulateCarriers).@"struct".fields) |field|
        if (!std.math.isFinite(@field(carriers, field.name)))
            return error.InvalidSurfacePondChemistryCarrier;
    if (carriers.surface_dry_mass_megagrams < 0 or
        carriers.soil_exchange_non_band_fraction <= 0 or
        carriers.soil_exchange_non_band_fraction > 1 or
        carriers.soil_phosphate_non_band_fraction <= 0 or
        carriers.soil_phosphate_non_band_fraction > 1 or
        carriers.surface_mineral_reference_water_m3 < 0 or
        carriers.soil_dry_mass_megagrams < 0 or
        carriers.soil_phosphate_non_band_water_m3 < 0)
        return error.InvalidSurfacePondChemistryCarrier;
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
        return error.InvalidSurfacePondChemistryCarrier;

    var result: ParticulateCandidate = .{
        .surface = surface.cells[cell],
        .soil_phosphate = soil.non_band_phosphate[destination],
        .soil_pending_phosphate_mol = soil.pending_non_band_phosphate_mol[destination],
        .soil_cations = soil.cation_exchange_mol_per_megagram[destination],
        .soil_pending_cations_mol = soil.pending_cation_exchange_mol[destination],
    };
    try transferFixedCarrierConcentrationToOwnedDestination(
        &result.surface.exchange.ammonium_mol_per_megagram,
        &result.soil_cations.ammonium_non_band,
        &result.soil_pending_cations_mol.ammonium_non_band,
        carriers.surface_dry_mass_megagrams,
        carriers.soil_dry_mass_megagrams * carriers.soil_exchange_non_band_fraction,
        fraction,
    );
    inline for (.{
        .{ "deprotonated_site_mol_per_megagram", "deprotonated_site_mol_per_megagram" },
        .{ "hydroxyl_site_mol_per_megagram", "hydroxyl_site_mol_per_megagram" },
        .{ "protonated_site_mol_per_megagram", "protonated_site_mol_per_megagram" },
        .{ "adsorbed_hpo4_mol_p_per_megagram", "adsorbed_hpo4_mol_p_per_megagram" },
        .{ "adsorbed_h2po4_mol_p_per_megagram", "adsorbed_h2po4_mol_p_per_megagram" },
    }) |names| try transferFixedCarrierConcentrationToOwnedDestination(
        &@field(result.surface.phosphate_surface, names[0]),
        &@field(result.soil_phosphate, names[1]),
        &@field(result.soil_pending_phosphate_mol, names[1]),
        carriers.surface_dry_mass_megagrams,
        carriers.soil_dry_mass_megagrams * carriers.soil_phosphate_non_band_fraction,
        fraction,
    );
    inline for (.{
        .{ "aluminum_phosphate_mol_per_m3", "aluminum_phosphate_solid_mol_per_m3" },
        .{ "iron_phosphate_mol_per_m3", "iron_phosphate_solid_mol_per_m3" },
        .{ "dicalcium_phosphate_mol_per_m3", "dicalcium_phosphate_solid_mol_per_m3" },
        .{ "hydroxyapatite_mol_per_m3", "hydroxyapatite_solid_mol_per_m3" },
        .{ "monocalcium_phosphate_mol_per_m3", "monocalcium_phosphate_solid_mol_per_m3" },
    }) |names| try transferFixedCarrierConcentrationToOwnedDestination(
        &@field(result.surface.phosphate_minerals, names[0]),
        &@field(result.soil_phosphate, names[1]),
        &@field(result.soil_pending_phosphate_mol, names[1]),
        carriers.surface_mineral_reference_water_m3,
        carriers.soil_phosphate_non_band_water_m3,
        fraction,
    );
    return result;
}

fn transferFixedCarrierConcentrationToOwnedDestination(
    source: *f64,
    destination: *f64,
    destination_pending_mol: *f64,
    source_base: f64,
    destination_base: f64,
    fraction: f64,
) !void {
    inline for (.{ source.*, destination.*, destination_pending_mol.*, source_base, destination_base, fraction }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSurfacePondChemistry;
    if (source.* < 0 or destination.* < 0 or destination_pending_mol.* < 0 or
        source_base < 0 or destination_base < 0 or fraction < 0 or fraction > 1 or
        (source_base == 0 and source.* != 0))
        return error.InvalidSurfacePondChemistry;
    const moved = fraction * source.* * source_base;
    const next_source = if (source_base > 0) source.* - moved / source_base else 0;
    const destination_amount = destination.* * destination_base + destination_pending_mol.* + moved;
    const next_destination = if (destination_base > 0) destination_amount / destination_base else 0;
    const next_pending = if (destination_base > 0) 0 else destination_amount;
    if (!std.math.isFinite(next_source) or next_source < 0 or
        !std.math.isFinite(next_destination) or next_destination < 0 or
        !std.math.isFinite(next_pending) or next_pending < 0)
        return error.InvalidSurfacePondChemistry;
    source.* = next_source;
    destination.* = next_destination;
    destination_pending_mol.* = next_pending;
}

const Candidate = struct {
    surface: surface_module.Cell,
    surface_mineral_reference_water_m3: f64,
    surface_dry_reference_water_m3: f64,
    soil_aqueous: @import("../soil/solute/aqueous_network.zig").State,
    soil_phosphate: @import("../soil/solute/phosphate_network.zig").State,
    soil_band_phosphate: @import("../soil/solute/phosphate_network.zig").State,
    soil_cations: @import("../soil/solute/cation_exchange.zig").Cations,
    soil_carboxyl_hydrogen_mol_per_megagram: f64,
    soil_solids: @import("../soil/solute/geochemistry_network.zig").SolidState,
};

/// REDIST layer-zero chemistry transfer. Surface concentrations are converted
/// to extensive amounts on their native water or litter-mass carriers and
/// mixed into the destination soil non-band owners.
pub fn transferSurfaceFractionToSoil(
    surface: *surface_module.State,
    soil: *soil_module.State,
    cell: usize,
    destination: usize,
    carriers: CarrierVolumes,
    dynamic_salts: bool,
    fraction: f64,
) !void {
    const next = try calculate(surface, soil, cell, destination, carriers, dynamic_salts, fraction);
    surface.cells[cell] = next.surface;
    surface.mineral_reference_water_m3[cell] = next.surface_mineral_reference_water_m3;
    surface.dry_reference_water_m3[cell] = next.surface_dry_reference_water_m3;
    soil.aqueous[destination] = next.soil_aqueous;
    soil.non_band_phosphate[destination] = next.soil_phosphate;
    soil.band_phosphate[destination] = next.soil_band_phosphate;
    soil.cation_exchange_mol_per_megagram[destination] = next.soil_cations;
    soil.carboxyl_bound_hydrogen_mol_per_megagram[destination] = next.soil_carboxyl_hydrogen_mol_per_megagram;
    soil.geochemistry_solids[destination] = next.soil_solids;
}

pub fn validateSurfaceFractionToSoil(
    surface: *const surface_module.State,
    soil: *const soil_module.State,
    cell: usize,
    destination: usize,
    carriers: CarrierVolumes,
    dynamic_salts: bool,
    fraction: f64,
) !void {
    _ = try calculate(surface, soil, cell, destination, carriers, dynamic_salts, fraction);
}

/// Exact element-resolved chemistry accepted by a pond-domain collapse. The
/// three carrier scales below are the literal operands of
/// `transferMappedConcentration`: capped liquid chemistry can differ from the
/// dry-material fraction, while solid minerals retain their own reference.
pub fn acceptedSurfaceTransfer(
    surface: *const surface_module.State,
    soil: *const soil_module.State,
    cell: usize,
    destination: usize,
    carriers: CarrierVolumes,
    dynamic_salts: bool,
    fraction: f64,
) !conservation_sidecar.Transfer {
    _ = try calculate(surface, soil, cell, destination, carriers, dynamic_salts, fraction);
    const source = surface.cells[cell];
    // issue-069 Finding A: widened from an exact-zero-only guard to the
    // shared `ZEROS2`-equivalent floor, matching `calculate`'s own
    // `surface_aqueous_before_m3` derivation exactly so this conservation
    // ledger never disagrees with the production mutator it accounts for.
    const negligible_water_volume_m3 = legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(carriers.cell_area_m2);
    const aqueous_reference = pondSurfaceWaterCarrierM3(
        carriers.surface_water_before_m3,
        surface.dry_reference_water_m3[cell],
        negligible_water_volume_m3,
    );
    const aqueous_scale = carriers.dissolved_chemistry_fraction * aqueous_reference;
    const dry_scale = fraction * carriers.surface_dry_mass_before_megagrams;
    const mineral_scale = fraction * surface.mineral_reference_water_m3[cell];
    var result: conservation_sidecar.Transfer = .{};

    result.nitrogen_mol += aqueous_scale *
        (source.ammonium_mol_per_m3 + source.ammonia_mol_per_m3 + source.nitrate_mol_per_m3);
    result.phosphorus_mol += aqueous_scale *
        (source.hpo4_mol_p_per_m3 + source.h2po4_mol_p_per_m3);
    result.carbon_mol += aqueous_scale *
        (source.carbonate_mol_per_m3 + source.bicarbonate_mol_per_m3);
    result.aluminum_mol += aqueous_scale * source.aluminum_mol_per_m3;
    result.iron_mol += aqueous_scale * source.iron_mol_per_m3;
    result.calcium_mol += aqueous_scale * source.calcium_mol_per_m3;
    result.magnesium_mol += aqueous_scale * source.magnesium_mol_per_m3;
    result.sodium_mol += aqueous_scale * source.sodium_mol_per_m3;
    result.potassium_mol += aqueous_scale * source.potassium_mol_per_m3;
    if (dynamic_salts) {
        result.sulfur_mol += aqueous_scale * source.sulfate_mol_per_m3;
        result.chloride_mol += aqueous_scale * source.chloride_mol_per_m3;
    }

    result.nitrogen_mol += dry_scale * source.exchange.ammonium_mol_per_megagram;
    result.aluminum_mol += dry_scale * source.exchange.aluminum_mol_per_megagram;
    result.iron_mol += dry_scale * source.exchange.iron_mol_per_megagram;
    result.calcium_mol += dry_scale * source.exchange.calcium_mol_per_megagram;
    result.magnesium_mol += dry_scale * source.exchange.magnesium_mol_per_megagram;
    result.sodium_mol += dry_scale * source.exchange.sodium_mol_per_megagram;
    result.potassium_mol += dry_scale * source.exchange.potassium_mol_per_megagram;
    result.phosphorus_mol += dry_scale *
        (source.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram +
            source.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram);

    const p = source.phosphate_minerals;
    const aluminum_phosphate = mineral_scale * p.aluminum_phosphate_mol_per_m3;
    const iron_phosphate = mineral_scale * p.iron_phosphate_mol_per_m3;
    const dicalcium_phosphate = mineral_scale * p.dicalcium_phosphate_mol_per_m3;
    const hydroxyapatite = mineral_scale * p.hydroxyapatite_mol_per_m3;
    const monocalcium_phosphate = mineral_scale * p.monocalcium_phosphate_mol_per_m3;
    result.aluminum_mol += aluminum_phosphate;
    result.iron_mol += iron_phosphate;
    result.calcium_mol += dicalcium_phosphate + 5 * hydroxyapatite + monocalcium_phosphate;
    result.phosphorus_mol += aluminum_phosphate + iron_phosphate + dicalcium_phosphate +
        3 * hydroxyapatite + 2 * monocalcium_phosphate;

    if (dynamic_salts) {
        const salts = source.salt_minerals;
        const gibbsite = mineral_scale * salts.gibbsite_mol_per_m3;
        const iron_hydroxide = mineral_scale * salts.iron_hydroxide_mol_per_m3;
        const calcite = mineral_scale * salts.calcite_mol_per_m3;
        const gypsum = mineral_scale * salts.gypsum_mol_per_m3;
        result.aluminum_mol += gibbsite;
        result.iron_mol += iron_hydroxide;
        result.calcium_mol += calcite + gypsum;
        result.carbon_mol += calcite;
        result.sulfur_mol += gypsum;
    }
    try result.validate();
    return result;
}

/// Exact non-band solid chemistry moved by REDIST pond-water settling from a
/// soil source layer. Explicit pending owners are included because a zero
/// carrier must not make accepted activity disappear.
pub fn acceptedSoilParticulateTransfer(
    soil: *const soil_module.State,
    source: usize,
    source_soil_mass_megagrams: f64,
    source_water_m3: f64,
    source_zone: @import("../soil/solute/charge_classification.zig").ZoneFractions,
    fraction: f64,
) !conservation_sidecar.Transfer {
    @setEvalBranchQuota(20_000);
    if (source >= soil.cell_count or !std.math.isFinite(source_soil_mass_megagrams) or
        !std.math.isFinite(source_water_m3) or !std.math.isFinite(fraction) or
        source_soil_mass_megagrams < 0 or source_water_m3 < 0 or fraction < 0 or fraction > 1)
        return error.InvalidSurfacePondChemistryCarrier;
    var result: conservation_sidecar.Transfer = .{};
    const cations = soil.cation_exchange_mol_per_megagram[source];
    const pending_cations = soil.pending_cation_exchange_mol[source];
    inline for (@typeInfo(@TypeOf(cations)).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "ammonium_band")) continue;
        const carrier = if (comptime std.mem.eql(u8, field.name, "ammonium_non_band"))
            source_soil_mass_megagrams * source_zone.ammonium_non_band
        else
            source_soil_mass_megagrams;
        const moved = fraction * (@field(cations, field.name) * carrier + @field(pending_cations, field.name));
        if (comptime std.mem.eql(u8, field.name, "ammonium_non_band")) result.nitrogen_mol += moved;
        if (comptime std.mem.eql(u8, field.name, "aluminum")) result.aluminum_mol += moved;
        if (comptime std.mem.eql(u8, field.name, "iron")) result.iron_mol += moved;
        if (comptime std.mem.eql(u8, field.name, "calcium")) result.calcium_mol += moved;
        if (comptime std.mem.eql(u8, field.name, "magnesium")) result.magnesium_mol += moved;
        if (comptime std.mem.eql(u8, field.name, "sodium")) result.sodium_mol += moved;
        if (comptime std.mem.eql(u8, field.name, "potassium")) result.potassium_mol += moved;
    }

    const phosphate = soil.non_band_phosphate[source];
    const pending_phosphate = soil.pending_non_band_phosphate_mol[source];
    inline for (@typeInfo(@TypeOf(phosphate)).@"struct".fields) |field| {
        const per_mass = comptime std.mem.endsWith(u8, field.name, "_per_megagram");
        const solid = comptime std.mem.indexOf(u8, field.name, "_solid_mol_per_m3") != null;
        if (!per_mass and !solid) continue;
        const carrier = (if (per_mass) source_soil_mass_megagrams else source_water_m3) *
            source_zone.phosphate_non_band;
        const moved = fraction * (@field(phosphate, field.name) * carrier + @field(pending_phosphate, field.name));
        if (comptime std.mem.indexOf(u8, field.name, "adsorbed_") != null) result.phosphorus_mol += moved;
        if (comptime std.mem.indexOf(u8, field.name, "aluminum_phosphate") != null) {
            result.aluminum_mol += moved;
            result.phosphorus_mol += moved;
        }
        if (comptime std.mem.indexOf(u8, field.name, "iron_phosphate") != null) {
            result.iron_mol += moved;
            result.phosphorus_mol += moved;
        }
        if (comptime std.mem.indexOf(u8, field.name, "dicalcium_phosphate") != null) {
            result.calcium_mol += moved;
            result.phosphorus_mol += moved;
        }
        if (comptime std.mem.indexOf(u8, field.name, "hydroxyapatite") != null) {
            result.calcium_mol += 5 * moved;
            result.phosphorus_mol += 3 * moved;
        }
        if (comptime std.mem.indexOf(u8, field.name, "monocalcium_phosphate") != null) {
            result.calcium_mol += moved;
            result.phosphorus_mol += 2 * moved;
        }
    }

    const solids = soil.geochemistry_solids[source];
    const pending_solids = soil.pending_geochemistry_solids_mol[source];
    inline for (@typeInfo(@TypeOf(solids)).@"struct".fields) |field| {
        const moved = fraction * (@field(solids, field.name) * source_water_m3 + @field(pending_solids, field.name));
        if (comptime std.mem.eql(u8, field.name, "gibbsite_solid_mol_per_m3")) result.aluminum_mol += moved else if (comptime std.mem.eql(u8, field.name, "iron_hydroxide_solid_mol_per_m3")) result.iron_mol += moved else if (comptime std.mem.eql(u8, field.name, "calcite_solid_mol_per_m3")) {
            result.calcium_mol += moved;
            result.carbon_mol += moved;
        } else if (comptime std.mem.eql(u8, field.name, "gypsum_solid_mol_per_m3")) {
            result.calcium_mol += moved;
            result.sulfur_mol += moved;
        } else {
            const silicon: f64 = if (comptime (std.mem.startsWith(u8, field.name, "aluminum_") or std.mem.startsWith(u8, field.name, "iron_"))) 0.75 else if (comptime (std.mem.startsWith(u8, field.name, "calcium_") or std.mem.startsWith(u8, field.name, "magnesium_"))) 0.5 else 0.25;
            result.silicon_mol += silicon * moved;
            if (comptime std.mem.startsWith(u8, field.name, "aluminum_")) result.aluminum_mol += moved;
            if (comptime std.mem.startsWith(u8, field.name, "iron_")) result.iron_mol += moved;
            if (comptime std.mem.startsWith(u8, field.name, "calcium_")) result.calcium_mol += moved;
            if (comptime std.mem.startsWith(u8, field.name, "magnesium_")) result.magnesium_mol += moved;
            if (comptime std.mem.startsWith(u8, field.name, "sodium_")) result.sodium_mol += moved;
            if (comptime std.mem.startsWith(u8, field.name, "potassium_")) result.potassium_mol += moved;
        }
    }
    try result.validate();
    return result;
}

/// `ZEROS2(NY,NX) = ZERO2*DH(NY,NX)*DV(NY,NX)` (`starts.f:270`). issue-069
/// Finding A: shared carrier-selection helper for this file's surface pond
/// water-carrier guards, mirroring `runtime_adapter.zig`'s
/// `tillageWaterCarrierM3` and `erosion_chemistry_bridge.zig`'s
/// `erosionWaterCarrierM3` exactly. A bare `> 0` guard treats any
/// nonzero-but-negligible live water carrier as "real", while a sibling
/// carrier (or the whole-hour census) may already substitute the remembered
/// dry/mineral reference for the same field at the same floor -- that basis
/// mismatch is the exact defect class already fixed at issue-060/061/063/
/// 064/065/066's other instances. `>`, not `>=`, matches legacy's own strict
/// comparison (`solute.f:610`).
fn pondSurfaceWaterCarrierM3(live_water_m3: f64, dry_reference_water_m3: f64, negligible_water_volume_m3: f64) f64 {
    return if (live_water_m3 > negligible_water_volume_m3) live_water_m3 else dry_reference_water_m3;
}

fn calculate(
    surface: *const surface_module.State,
    soil: *const soil_module.State,
    cell: usize,
    destination: usize,
    carriers: CarrierVolumes,
    dynamic_salts: bool,
    fraction: f64,
) !Candidate {
    if (cell >= surface.cells.len or destination >= soil.cell_count) return error.SurfacePondChemistryIndexOutOfBounds;
    if (surface.mineral_reference_water_m3.len != surface.cells.len or
        surface.dry_reference_water_m3.len != surface.cells.len)
        return error.SurfacePondChemistryDimensionMismatch;
    inline for (@typeInfo(CarrierVolumes).@"struct".fields) |field| {
        const value = @field(carriers, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfacePondChemistryCarrier;
    }
    // A dry surface carrier (`surface_water_before_m3 == 0`) is legitimate.
    // Its aqueous concentrations remain extensive on `dry_reference_water_m3`;
    // solid minerals use their independent mineral reference. Substituting the
    // zero live-water carrier here would silently erase retained dry solute.
    if (carriers.soil_shared_water_before_m3 < 0 or carriers.soil_phosphate_non_band_water_before_m3 < 0 or carriers.soil_shared_water_after_m3 <= 0 or carriers.soil_phosphate_non_band_water_after_m3 <= 0 or carriers.soil_dry_mass_before_megagrams <= 0 or carriers.soil_dry_mass_after_megagrams <= 0 or !std.math.isFinite(fraction) or fraction < 0 or fraction > 1 or carriers.dissolved_chemistry_fraction > 1) {
        if (!builtin.is_test) std.log.err(
            "invalid surface pond chemistry carriers: surface_water_before_m3={e} soil_shared_water_before_m3={e} soil_phosphate_water_before_m3={e} surface_water_after_m3={e} soil_shared_water_after_m3={e} soil_phosphate_water_after_m3={e} surface_dry_mass_before_megagrams={e} soil_dry_mass_before_megagrams={e} surface_dry_mass_after_megagrams={e} soil_dry_mass_after_megagrams={e} fraction={e}",
            .{
                carriers.surface_water_before_m3,
                carriers.soil_shared_water_before_m3,
                carriers.soil_phosphate_non_band_water_before_m3,
                carriers.surface_water_after_m3,
                carriers.soil_shared_water_after_m3,
                carriers.soil_phosphate_non_band_water_after_m3,
                carriers.surface_dry_mass_before_megagrams,
                carriers.soil_dry_mass_before_megagrams,
                carriers.surface_dry_mass_after_megagrams,
                carriers.soil_dry_mass_after_megagrams,
                fraction,
            },
        );
        return error.InvalidSurfacePondChemistryCarrier;
    }

    const dry_reference_before = surface.dry_reference_water_m3[cell];
    const mineral_reference_before = surface.mineral_reference_water_m3[cell];
    inline for (.{ dry_reference_before, mineral_reference_before }) |reference|
        if (!std.math.isFinite(reference) or reference < 0)
            return error.InvalidSurfacePondChemistryCarrier;
    // issue-069 Finding A: the three carrier selections below used to gate on
    // `carriers.surface_water_*_m3 > 0` (exact zero only), the same
    // mistranslated-`ZEROS2` shape already fixed at issue-060/061/063/064/
    // 065/066's other call sites (`starts.f:270`,
    // `legacyNegligibleWaterVolumeM3`). A near-zero-but-nonzero raw carrier
    // was accepted as "real" and multiplied directly into aqueous
    // concentrations, manufacturing a fake mass swing relative to the
    // correct dry-reference basis. Widened to the shared floor via
    // `pondSurfaceWaterCarrierM3`; `carriers.surface_water_before_m3 == 0`
    // is likewise widened to `<= negligible_water_volume_m3` so the dry
    // reference is rebuilt consistently on both sides of the same floor.
    const negligible_water_volume_m3 = legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(carriers.cell_area_m2);
    const surface_aqueous_before_m3 = pondSurfaceWaterCarrierM3(carriers.surface_water_before_m3, dry_reference_before, negligible_water_volume_m3);
    const surface_dry_reference_after_m3 = if (carriers.surface_water_after_m3 > negligible_water_volume_m3)
        0
    else if (carriers.surface_water_before_m3 <= negligible_water_volume_m3)
        dry_reference_before
    else
        carriers.surface_water_before_m3 * (1 - carriers.dissolved_chemistry_fraction);
    const surface_aqueous_after_m3 = pondSurfaceWaterCarrierM3(carriers.surface_water_after_m3, surface_dry_reference_after_m3, negligible_water_volume_m3);
    const surface_mineral_reference_after_m3 = pondSurfaceWaterCarrierM3(carriers.surface_water_after_m3, mineral_reference_before, negligible_water_volume_m3);

    var result: Candidate = .{
        .surface = surface.cells[cell],
        .surface_mineral_reference_water_m3 = surface_mineral_reference_after_m3,
        .surface_dry_reference_water_m3 = surface_dry_reference_after_m3,
        .soil_aqueous = soil.aqueous[destination],
        .soil_phosphate = soil.non_band_phosphate[destination],
        .soil_band_phosphate = soil.band_phosphate[destination],
        .soil_cations = soil.cation_exchange_mol_per_megagram[destination],
        .soil_carboxyl_hydrogen_mol_per_megagram = soil.carboxyl_bound_hydrogen_mol_per_megagram[destination],
        .soil_solids = soil.geochemistry_solids[destination],
    };
    const phosphate_non_band_fraction = if (carriers.soil_shared_water_before_m3 > 0)
        carriers.soil_phosphate_non_band_water_before_m3 / carriers.soil_shared_water_before_m3
    else
        carriers.soil_phosphate_non_band_water_after_m3 / carriers.soil_shared_water_after_m3;
    const phosphate_non_band_fraction_after =
        carriers.soil_phosphate_non_band_water_after_m3 / carriers.soil_shared_water_after_m3;
    if (!std.math.isFinite(phosphate_non_band_fraction) or
        !std.math.isFinite(phosphate_non_band_fraction_after) or
        phosphate_non_band_fraction <= 0 or phosphate_non_band_fraction > 1 or
        @abs(phosphate_non_band_fraction - phosphate_non_band_fraction_after) >
            64 * std.math.floatEps(f64) * @max(1.0, phosphate_non_band_fraction))
        return error.InvalidSurfacePondChemistryCarrier;

    inline for (.{
        .{ "hydrogen_mol_per_m3", "hydrogen" },
        .{ "hydroxide_mol_per_m3", "hydroxide" },
        .{ "aluminum_mol_per_m3", "aluminum" },
        .{ "iron_mol_per_m3", "iron" },
        .{ "calcium_mol_per_m3", "calcium" },
        .{ "magnesium_mol_per_m3", "magnesium" },
        .{ "sodium_mol_per_m3", "sodium" },
        .{ "potassium_mol_per_m3", "potassium" },
    }) |names| transferMappedConcentration(&@field(result.surface, names[0]), &@field(result.soil_aqueous, names[1]), surface_aqueous_before_m3, carriers.soil_shared_water_before_m3, surface_aqueous_after_m3, carriers.soil_shared_water_after_m3, carriers.dissolved_chemistry_fraction) catch return error.InvalidSurfacePondChemistryState;

    inline for (.{
        .{ "ammonium_mol_per_m3", "ammonium_non_band" },
        .{ "ammonia_mol_per_m3", "ammonia_non_band" },
    }) |names| transferMappedConcentration(&@field(result.surface, names[0]), &@field(result.soil_aqueous, names[1]), surface_aqueous_before_m3, carriers.soil_shared_water_before_m3 * carriers.ammonium_non_band_water_fraction, surface_aqueous_after_m3, carriers.soil_shared_water_after_m3 * carriers.ammonium_non_band_water_fraction, carriers.dissolved_chemistry_fraction) catch return error.InvalidSurfacePondChemistryState;
    transferMappedConcentration(&result.surface.nitrate_mol_per_m3, &result.soil_aqueous.nitrate_non_band, surface_aqueous_before_m3, carriers.soil_shared_water_before_m3 * carriers.nitrate_non_band_water_fraction, surface_aqueous_after_m3, carriers.soil_shared_water_after_m3 * carriers.nitrate_non_band_water_fraction, carriers.dissolved_chemistry_fraction) catch return error.InvalidSurfacePondChemistryState;

    // Pond material enters the non-band zone. Existing band concentrations
    // receive no solute, but their shared water carrier grows; dilute them so
    // the extensive band inventory remains unchanged.
    inline for (.{ "ammonium_band", "ammonia_band", "nitrate_band" }) |field_name|
        try rescaleUnchangedConcentration(
            &@field(result.soil_aqueous, field_name),
            carriers.soil_shared_water_before_m3,
            carriers.soil_shared_water_after_m3,
        );

    if (dynamic_salts) inline for (.{
        .{ "chloride_mol_per_m3", "chloride" },
        .{ "sulfate_mol_per_m3", "sulfate" },
        .{ "carbon_dioxide_mol_per_m3", "carbon_dioxide" },
    }) |names| transferMappedConcentration(&@field(result.surface, names[0]), &@field(result.soil_aqueous, names[1]), surface_aqueous_before_m3, carriers.soil_shared_water_before_m3, surface_aqueous_after_m3, carriers.soil_shared_water_after_m3, carriers.dissolved_chemistry_fraction) catch return error.InvalidSurfacePondChemistryState;

    // Carbonate alkalinity follows liquid water even when optional salt
    // reactions are disabled. The feature flag controls salt chemistry, not
    // ownership of conserved carbon carriers.
    inline for (.{
        .{ "carbonate_mol_per_m3", "carbonate" },
        .{ "bicarbonate_mol_per_m3", "bicarbonate" },
    }) |names| transferMappedConcentration(&@field(result.surface, names[0]), &@field(result.soil_aqueous, names[1]), surface_aqueous_before_m3, carriers.soil_shared_water_before_m3, surface_aqueous_after_m3, carriers.soil_shared_water_after_m3, carriers.dissolved_chemistry_fraction) catch return error.InvalidSurfacePondChemistryState;

    inline for (.{
        .{ "hpo4_mol_p_per_m3", "dissolved_hpo4_mol_p_per_m3" },
        .{ "h2po4_mol_p_per_m3", "dissolved_h2po4_mol_p_per_m3" },
    }) |names| transferMappedConcentration(&@field(result.surface, names[0]), &@field(result.soil_phosphate, names[1]), surface_aqueous_before_m3, carriers.soil_phosphate_non_band_water_before_m3, surface_aqueous_after_m3, carriers.soil_phosphate_non_band_water_after_m3, carriers.dissolved_chemistry_fraction) catch return error.InvalidSurfacePondChemistryState;

    transferMappedConcentration(
        &result.surface.exchange.ammonium_mol_per_megagram,
        &result.soil_cations.ammonium_non_band,
        carriers.surface_dry_mass_before_megagrams,
        carriers.soil_dry_mass_before_megagrams * carriers.ammonium_non_band_water_fraction,
        carriers.surface_dry_mass_after_megagrams,
        carriers.soil_dry_mass_after_megagrams * carriers.ammonium_non_band_water_fraction,
        fraction,
    ) catch return error.InvalidSurfacePondChemistryState;

    inline for (.{
        .{ "hydrogen_mol_per_megagram", "hydrogen" },
        .{ "aluminum_mol_per_megagram", "aluminum" },
        .{ "iron_mol_per_megagram", "iron" },
        .{ "calcium_mol_per_megagram", "calcium" },
        .{ "magnesium_mol_per_megagram", "magnesium" },
        .{ "sodium_mol_per_megagram", "sodium" },
        .{ "potassium_mol_per_megagram", "potassium" },
    }) |names| transferMappedConcentration(&@field(result.surface.exchange, names[0]), &@field(result.soil_cations, names[1]), carriers.surface_dry_mass_before_megagrams, carriers.soil_dry_mass_before_megagrams, carriers.surface_dry_mass_after_megagrams, carriers.soil_dry_mass_after_megagrams, fraction) catch return error.InvalidSurfacePondChemistryState;

    // As above, only non-band exchange receives surface material. Preserve
    // the pre-existing band ammonium amount on the enlarged dry-mass carrier.
    try rescaleUnchangedConcentration(
        &result.soil_cations.ammonium_band,
        carriers.soil_dry_mass_before_megagrams,
        carriers.soil_dry_mass_after_megagrams,
    );

    transferMappedConcentration(&result.surface.carboxyl_hydrogen_mol_per_megagram, &result.soil_carboxyl_hydrogen_mol_per_megagram, carriers.surface_dry_mass_before_megagrams, carriers.soil_dry_mass_before_megagrams, carriers.surface_dry_mass_after_megagrams, carriers.soil_dry_mass_after_megagrams, fraction) catch return error.InvalidSurfacePondChemistryState;

    inline for (.{
        .{ "deprotonated_site_mol_per_megagram", "deprotonated_site_mol_per_megagram" },
        .{ "hydroxyl_site_mol_per_megagram", "hydroxyl_site_mol_per_megagram" },
        .{ "protonated_site_mol_per_megagram", "protonated_site_mol_per_megagram" },
        .{ "adsorbed_hpo4_mol_p_per_megagram", "adsorbed_hpo4_mol_p_per_megagram" },
        .{ "adsorbed_h2po4_mol_p_per_megagram", "adsorbed_h2po4_mol_p_per_megagram" },
    }) |names| transferMappedConcentration(&@field(result.surface.phosphate_surface, names[0]), &@field(result.soil_phosphate, names[1]), carriers.surface_dry_mass_before_megagrams, carriers.soil_dry_mass_before_megagrams * phosphate_non_band_fraction, carriers.surface_dry_mass_after_megagrams, carriers.soil_dry_mass_after_megagrams * phosphate_non_band_fraction, fraction) catch return error.InvalidSurfacePondChemistryState;
    inline for (.{
        "deprotonated_site_mol_per_megagram",
        "hydroxyl_site_mol_per_megagram",
        "protonated_site_mol_per_megagram",
        "adsorbed_hpo4_mol_p_per_megagram",
        "adsorbed_h2po4_mol_p_per_megagram",
    }) |name| try rescaleUnchangedConcentration(
        &@field(result.soil_band_phosphate, name),
        carriers.soil_dry_mass_before_megagrams,
        carriers.soil_dry_mass_after_megagrams,
    );

    inline for (.{
        .{ "aluminum_phosphate_mol_per_m3", "aluminum_phosphate_solid_mol_per_m3" },
        .{ "iron_phosphate_mol_per_m3", "iron_phosphate_solid_mol_per_m3" },
        .{ "dicalcium_phosphate_mol_per_m3", "dicalcium_phosphate_solid_mol_per_m3" },
        .{ "hydroxyapatite_mol_per_m3", "hydroxyapatite_solid_mol_per_m3" },
        .{ "monocalcium_phosphate_mol_per_m3", "monocalcium_phosphate_solid_mol_per_m3" },
    }) |names| transferMappedConcentration(&@field(result.surface.phosphate_minerals, names[0]), &@field(result.soil_phosphate, names[1]), mineral_reference_before, carriers.soil_phosphate_non_band_water_before_m3, surface_mineral_reference_after_m3, carriers.soil_phosphate_non_band_water_after_m3, fraction) catch return error.InvalidSurfacePondChemistryState;
    inline for (.{
        "aluminum_phosphate_solid_mol_per_m3",
        "iron_phosphate_solid_mol_per_m3",
        "dicalcium_phosphate_solid_mol_per_m3",
        "hydroxyapatite_solid_mol_per_m3",
        "monocalcium_phosphate_solid_mol_per_m3",
    }) |name| try rescaleUnchangedConcentration(
        &@field(result.soil_band_phosphate, name),
        carriers.soil_shared_water_before_m3,
        carriers.soil_shared_water_after_m3,
    );

    inline for (.{
        .{ "gibbsite_mol_per_m3", "gibbsite_solid_mol_per_m3" },
        .{ "iron_hydroxide_mol_per_m3", "iron_hydroxide_solid_mol_per_m3" },
        .{ "calcite_mol_per_m3", "calcite_solid_mol_per_m3" },
        .{ "gypsum_mol_per_m3", "gypsum_solid_mol_per_m3" },
    }) |names| transferMappedConcentration(
        &@field(result.surface.salt_minerals, names[0]),
        &@field(result.soil_solids, names[1]),
        mineral_reference_before,
        carriers.soil_shared_water_before_m3,
        surface_mineral_reference_after_m3,
        carriers.soil_shared_water_after_m3,
        if (dynamic_salts) fraction else 0,
    ) catch return error.InvalidSurfacePondChemistryState;

    inline for (.{
        "aluminum_natural_silicate_mol_per_m3",
        "aluminum_ground_silicate_mol_per_m3",
        "iron_natural_silicate_mol_per_m3",
        "iron_ground_silicate_mol_per_m3",
        "calcium_natural_silicate_mol_per_m3",
        "calcium_ground_silicate_mol_per_m3",
        "magnesium_natural_silicate_mol_per_m3",
        "magnesium_ground_silicate_mol_per_m3",
        "sodium_natural_silicate_mol_per_m3",
        "sodium_ground_silicate_mol_per_m3",
        "potassium_natural_silicate_mol_per_m3",
        "potassium_ground_silicate_mol_per_m3",
    }) |name| try rescaleUnchangedConcentration(
        &@field(result.soil_solids, name),
        carriers.soil_shared_water_before_m3,
        carriers.soil_shared_water_after_m3,
    );

    return result;
}

fn transferMappedConcentration(source: *f64, destination: *f64, source_base_before: f64, destination_base_before: f64, source_base_after: f64, destination_base_after: f64, fraction: f64) !void {
    inline for (.{ source.*, destination.*, source_base_before, destination_base_before, source_base_after, destination_base_after, fraction }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfacePondChemistry;
    if (source.* < 0 or destination.* < 0 or source_base_before < 0 or destination_base_before < 0 or source_base_after < 0 or destination_base_after <= 0 or fraction < 0 or fraction > 1 or (source_base_before == 0 and source.* != 0)) return error.InvalidSurfacePondChemistry;
    const source_amount = source.* * source_base_before;
    const moved = fraction * source_amount;
    const destination_amount = destination.* * destination_base_before + moved;
    source.* = if (source_base_after > 0) (source_amount - moved) / source_base_after else 0;
    destination.* = destination_amount / destination_base_after;
    if (!std.math.isFinite(source.*) or source.* < 0 or !std.math.isFinite(destination.*) or destination.* < 0) return error.InvalidSurfacePondChemistry;
}

fn rescaleUnchangedConcentration(value: *f64, carrier_before: f64, carrier_after: f64) !void {
    inline for (.{ value.*, carrier_before, carrier_after }) |candidate|
        if (!std.math.isFinite(candidate)) return error.NonFiniteSurfacePondChemistry;
    if (value.* < 0 or carrier_before < 0 or carrier_after <= 0)
        return error.InvalidSurfacePondChemistry;
    value.* *= carrier_before / carrier_after;
    if (!std.math.isFinite(value.*) or value.* < 0)
        return error.InvalidSurfacePondChemistry;
}

test "L0 settling transfers only source-order particulate chemistry and conserves native amounts" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    surface.cells[0].exchange.ammonium_mol_per_megagram = 10;
    surface.cells[0].exchange.calcium_mol_per_megagram = 20;
    surface.cells[0].phosphate_surface.adsorbed_h2po4_mol_p_per_megagram = 6;
    surface.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3 = 12;
    surface.cells[0].salt_minerals.calcite_mol_per_m3 = 14;
    surface.cells[0].nitrate_mol_per_m3 = 16;
    soil.cation_exchange_mol_per_megagram[0].ammonium_non_band = 2;
    soil.non_band_phosphate[0].adsorbed_h2po4_mol_p_per_megagram = 3;
    soil.non_band_phosphate[0].aluminum_phosphate_solid_mol_per_m3 = 4;
    const carriers: ParticulateCarriers = .{
        .surface_dry_mass_megagrams = 2,
        .soil_dry_mass_megagrams = 5,
        .soil_exchange_non_band_fraction = 0.4,
        .soil_phosphate_non_band_fraction = 0.4,
        .surface_mineral_reference_water_m3 = 4,
        .soil_phosphate_non_band_water_m3 = 8,
    };

    try transferParticulateFractionToSoil(&surface, &soil, 0, 0, carriers, 0.25);

    try std.testing.expectApproxEqAbs(@as(f64, 7.5), surface.cells[0].exchange.ammonium_mol_per_megagram, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), soil.cation_exchange_mol_per_megagram[0].ammonium_non_band, 1e-14);
    try std.testing.expectApproxEqAbs(
        @as(f64, 24),
        surface.cells[0].exchange.ammonium_mol_per_megagram * carriers.surface_dry_mass_megagrams +
            soil.cation_exchange_mol_per_megagram[0].ammonium_non_band * carriers.soil_dry_mass_megagrams * carriers.soil_exchange_non_band_fraction,
        1e-14,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), surface.cells[0].phosphate_surface.adsorbed_h2po4_mol_p_per_megagram, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), soil.non_band_phosphate[0].adsorbed_h2po4_mol_p_per_megagram, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 9), surface.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 5.5), soil.non_band_phosphate[0].aluminum_phosphate_solid_mol_per_m3, 1e-14);
    // REDIST guards the other cations and salt precipitates with L.GT.0; the
    // separated litter source is L=0. Dissolved chemistry never settles.
    try std.testing.expectEqual(@as(f64, 20), surface.cells[0].exchange.calcium_mol_per_megagram);
    try std.testing.expectEqual(@as(f64, 14), surface.cells[0].salt_minerals.calcite_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 16), surface.cells[0].nitrate_mol_per_m3);
}

test "pond chemistry sidecars exclude mirrored carbon and material capacity" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    surface.cells[0].carbon_dioxide_mol_per_m3 = 7;
    surface.cells[0].carbonate_mol_per_m3 = 2;
    surface.cells[0].bicarbonate_mol_per_m3 = 3;
    surface.cells[0].phosphate_surface.deprotonated_site_mol_per_megagram = 11;
    surface.cells[0].phosphate_surface.hydroxyl_site_mol_per_megagram = 13;
    surface.cells[0].phosphate_surface.protonated_site_mol_per_megagram = 17;
    const carriers: CarrierVolumes = .{
        .surface_water_before_m3 = 4,
        .soil_shared_water_before_m3 = 3,
        .soil_phosphate_non_band_water_before_m3 = 3,
        .surface_water_after_m3 = 2,
        .soil_shared_water_after_m3 = 5,
        .soil_phosphate_non_band_water_after_m3 = 5,
        .surface_dry_mass_before_megagrams = 2,
        .soil_dry_mass_before_megagrams = 5,
        .surface_dry_mass_after_megagrams = 1,
        .soil_dry_mass_after_megagrams = 6,
        .dissolved_chemistry_fraction = 0.5,
        .cell_area_m2 = 1,
    };
    const accepted = try acceptedSurfaceTransfer(
        &surface,
        &soil,
        0,
        0,
        carriers,
        true,
        0.5,
    );
    try std.testing.expectEqual(@as(f64, 10), accepted.carbon_mol);
    try std.testing.expectEqual(@as(f64, 0), accepted.anion_exchange_capacity_mol);

    const particulate = try acceptedParticulateTransfer(
        &surface,
        &soil,
        0,
        0,
        .{
            .surface_dry_mass_megagrams = 2,
            .soil_dry_mass_megagrams = 5,
            .soil_exchange_non_band_fraction = 1,
            .soil_phosphate_non_band_fraction = 1,
            .surface_mineral_reference_water_m3 = 4,
            .soil_phosphate_non_band_water_m3 = 3,
        },
        0.5,
    );
    try std.testing.expectEqual(@as(f64, 0), particulate.anion_exchange_capacity_mol);

    soil.non_band_phosphate[0].deprotonated_site_mol_per_megagram = 19;
    soil.pending_non_band_phosphate_mol[0].hydroxyl_site_mol_per_megagram = 23;
    const soil_particulate = try acceptedSoilParticulateTransfer(
        &soil,
        0,
        5,
        3,
        .{
            .ammonium_non_band = 1,
            .ammonium_band = 0,
            .nitrate_non_band = 1,
            .nitrate_band = 0,
            .phosphate_non_band = 1,
            .phosphate_band = 0,
        },
        0.5,
    );
    try std.testing.expectEqual(@as(f64, 0), soil_particulate.anion_exchange_capacity_mol);
}

test "particulate chemistry uses pending extensive ownership in zero-density open water" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    surface.cells[0].exchange.ammonium_mol_per_megagram = 4;
    surface.cells[0].phosphate_surface.adsorbed_h2po4_mol_p_per_megagram = 6;
    surface.mineral_reference_water_m3[0] = 2;
    surface.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3 = 8;

    const carriers: ParticulateCarriers = .{
        .surface_dry_mass_megagrams = 3,
        .soil_dry_mass_megagrams = 0,
        .soil_exchange_non_band_fraction = 0.75,
        .soil_phosphate_non_band_fraction = 0.8,
        .surface_mineral_reference_water_m3 = 2,
        .soil_phosphate_non_band_water_m3 = 5,
    };
    try transferParticulateFractionToSoil(&surface, &soil, 0, 0, carriers, 0.25);

    try std.testing.expectApproxEqAbs(@as(f64, 3), surface.cells[0].exchange.ammonium_mol_per_megagram, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), soil.pending_cation_exchange_mol[0].ammonium_non_band, 1e-15);
    try std.testing.expectEqual(@as(f64, 0), soil.cation_exchange_mol_per_megagram[0].ammonium_non_band);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), surface.cells[0].phosphate_surface.adsorbed_h2po4_mol_p_per_megagram, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), soil.pending_non_band_phosphate_mol[0].adsorbed_h2po4_mol_p_per_megagram, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 6), surface.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), soil.non_band_phosphate[0].aluminum_phosphate_solid_mol_per_m3, 1e-15);
}

test "late invalid L0 particulate chemistry leaves both owners unchanged" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    surface.cells[0].exchange.ammonium_mol_per_megagram = 10;
    surface.cells[0].phosphate_minerals.monocalcium_phosphate_mol_per_m3 = 2;
    soil.non_band_phosphate[0].monocalcium_phosphate_solid_mol_per_m3 = std.math.inf(f64);
    const before_surface = surface.cells[0];
    const before_soil_phosphate = soil.non_band_phosphate[0];
    const before_soil_cations = soil.cation_exchange_mol_per_megagram[0];
    try std.testing.expectError(
        error.NonFiniteSurfacePondChemistry,
        transferParticulateFractionToSoil(&surface, &soil, 0, 0, .{
            .surface_dry_mass_megagrams = 2,
            .soil_dry_mass_megagrams = 5,
            .soil_exchange_non_band_fraction = 1,
            .soil_phosphate_non_band_fraction = 1,
            .surface_mineral_reference_water_m3 = 4,
            .soil_phosphate_non_band_water_m3 = 8,
        }, 0.25),
    );
    try std.testing.expectEqualDeep(before_surface, surface.cells[0]);
    try std.testing.expectEqualDeep(before_soil_phosphate, soil.non_band_phosphate[0]);
    try std.testing.expectEqualDeep(before_soil_cations, soil.cation_exchange_mol_per_megagram[0]);
}

test "surface chemistry mixes into soil non-band owners on native carriers" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    surface.cells[0].ammonium_mol_per_m3 = 4;
    surface.cells[0].h2po4_mol_p_per_m3 = 2;
    surface.cells[0].exchange.calcium_mol_per_megagram = 3;
    soil.aqueous[0].ammonium_non_band = 1;
    const carriers: CarrierVolumes = .{ .surface_water_before_m3 = 2, .soil_shared_water_before_m3 = 2, .soil_phosphate_non_band_water_before_m3 = 2, .surface_water_after_m3 = 1, .soil_shared_water_after_m3 = 3, .soil_phosphate_non_band_water_after_m3 = 3, .surface_dry_mass_before_megagrams = 2, .soil_dry_mass_before_megagrams = 2, .surface_dry_mass_after_megagrams = 1, .soil_dry_mass_after_megagrams = 3, .dissolved_chemistry_fraction = 0.5, .cell_area_m2 = 1 };
    try transferSurfaceFractionToSoil(&surface, &soil, 0, 0, carriers, false, 0.5);
    try std.testing.expectEqual(@as(f64, 4), surface.cells[0].ammonium_mol_per_m3);
    try std.testing.expectApproxEqAbs(@as(f64, 2), soil.aqueous[0].ammonium_non_band, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), soil.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1), soil.cation_exchange_mol_per_megagram[0].calcium, 1e-14);
}

test "pond mineral nitrogen conserves amount on non-band zone water" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    surface.cells[0].ammonium_mol_per_m3 = 4;
    surface.cells[0].nitrate_mol_per_m3 = 2;
    soil.aqueous[0].ammonium_non_band = 1;
    soil.aqueous[0].nitrate_non_band = 3;
    soil.aqueous[0].ammonium_band = 7;
    soil.aqueous[0].nitrate_band = 11;
    soil.cation_exchange_mol_per_megagram[0].ammonium_band = 13;
    const carriers: CarrierVolumes = .{
        .surface_water_before_m3 = 2,
        .soil_shared_water_before_m3 = 5,
        .soil_phosphate_non_band_water_before_m3 = 5,
        .surface_water_after_m3 = 1,
        .soil_shared_water_after_m3 = 6,
        .soil_phosphate_non_band_water_after_m3 = 6,
        .surface_dry_mass_before_megagrams = 2,
        .soil_dry_mass_before_megagrams = 5,
        .surface_dry_mass_after_megagrams = 1,
        .soil_dry_mass_after_megagrams = 6,
        .ammonium_non_band_water_fraction = 0.8,
        .nitrate_non_band_water_fraction = 0.6,
        .dissolved_chemistry_fraction = 0.5,
        .cell_area_m2 = 1,
    };
    const ammonium_before = 4.0 * 2.0 + 1.0 * 5.0 * 0.8;
    const nitrate_before = 2.0 * 2.0 + 3.0 * 5.0 * 0.6;
    try transferSurfaceFractionToSoil(&surface, &soil, 0, 0, carriers, false, 0.5);
    const ammonium_after = surface.cells[0].ammonium_mol_per_m3 * 1.0 + soil.aqueous[0].ammonium_non_band * 6.0 * 0.8;
    const nitrate_after = surface.cells[0].nitrate_mol_per_m3 * 1.0 + soil.aqueous[0].nitrate_non_band * 6.0 * 0.6;
    try std.testing.expectApproxEqAbs(ammonium_before, ammonium_after, 1e-14);
    try std.testing.expectApproxEqAbs(nitrate_before, nitrate_after, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 7 * 5), soil.aqueous[0].ammonium_band * 6, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 11 * 5), soil.aqueous[0].nitrate_band * 6, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 13 * 5), soil.cation_exchange_mol_per_megagram[0].ammonium_band * 6, 1e-14);
}

test "pond dry transfer conserves fraction-weighted exchanger and phosphate sites" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    surface.cells[0].exchange.ammonium_mol_per_megagram = 10;
    surface.cells[0].phosphate_surface.deprotonated_site_mol_per_megagram = 6;
    soil.cation_exchange_mol_per_megagram[0].ammonium_non_band = 2;
    soil.cation_exchange_mol_per_megagram[0].ammonium_band = 3;
    soil.non_band_phosphate[0].deprotonated_site_mol_per_megagram = 4;
    soil.band_phosphate[0].deprotonated_site_mol_per_megagram = 5;
    const carriers: CarrierVolumes = .{
        .surface_water_before_m3 = 2,
        .soil_shared_water_before_m3 = 5,
        .soil_phosphate_non_band_water_before_m3 = 2,
        .surface_water_after_m3 = 1,
        .soil_shared_water_after_m3 = 6,
        .soil_phosphate_non_band_water_after_m3 = 2.4,
        .surface_dry_mass_before_megagrams = 2,
        .soil_dry_mass_before_megagrams = 5,
        .surface_dry_mass_after_megagrams = 1,
        .soil_dry_mass_after_megagrams = 6,
        .ammonium_non_band_water_fraction = 0.4,
        .dissolved_chemistry_fraction = 0.5,
        .cell_area_m2 = 1,
    };
    const exchange_before = 10.0 * 2.0 + 5.0 * (0.4 * 2.0 + 0.6 * 3.0);
    const phosphate_sites_before = 6.0 * 2.0 + 5.0 * (0.4 * 4.0 + 0.6 * 5.0);
    try transferSurfaceFractionToSoil(&surface, &soil, 0, 0, carriers, false, 0.5);
    const exchange_after = surface.cells[0].exchange.ammonium_mol_per_megagram +
        6.0 * (0.4 * soil.cation_exchange_mol_per_megagram[0].ammonium_non_band +
            0.6 * soil.cation_exchange_mol_per_megagram[0].ammonium_band);
    const phosphate_sites_after = surface.cells[0].phosphate_surface.deprotonated_site_mol_per_megagram +
        6.0 * (0.4 * soil.non_band_phosphate[0].deprotonated_site_mol_per_megagram +
            0.6 * soil.band_phosphate[0].deprotonated_site_mol_per_megagram);
    try std.testing.expectApproxEqAbs(exchange_before, exchange_after, 1e-14);
    try std.testing.expectApproxEqAbs(phosphate_sites_before, phosphate_sites_after, 1e-14);
}

test "fixed salt mode preserves optional salt amounts while water carrier changes" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    surface.cells[0].sulfate_mol_per_m3 = 5;
    surface.cells[0].bicarbonate_mol_per_m3 = 4;
    const carriers: CarrierVolumes = .{ .surface_water_before_m3 = 1, .soil_shared_water_before_m3 = 1, .soil_phosphate_non_band_water_before_m3 = 1, .surface_water_after_m3 = 0.5, .soil_shared_water_after_m3 = 1.5, .soil_phosphate_non_band_water_after_m3 = 1.5, .surface_dry_mass_before_megagrams = 1, .soil_dry_mass_before_megagrams = 1, .surface_dry_mass_after_megagrams = 0.5, .soil_dry_mass_after_megagrams = 1.5, .dissolved_chemistry_fraction = 0.5, .cell_area_m2 = 1 };
    try transferSurfaceFractionToSoil(&surface, &soil, 0, 0, carriers, false, 0.5);
    try std.testing.expectEqual(@as(f64, 5), surface.cells[0].sulfate_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0), soil.aqueous[0].sulfate);
    try std.testing.expectEqual(@as(f64, 4), surface.cells[0].bicarbonate_mol_per_m3);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0 / 3.0), soil.aqueous[0].bicarbonate, 1e-15);
    surface.mineral_reference_water_m3[0] = carriers.surface_water_before_m3;
    surface.cells[0].salt_minerals.calcite_mol_per_m3 = 4;
    soil.geochemistry_solids[0].calcite_solid_mol_per_m3 = 2;
    try transferSurfaceFractionToSoil(&surface, &soil, 0, 0, carriers, false, 0.5);
    try std.testing.expectEqual(@as(f64, 8), surface.cells[0].salt_minerals.calcite_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 4.0 / 3.0), soil.geochemistry_solids[0].calcite_solid_mol_per_m3);
    const calcite_after_mol =
        surface.cells[0].salt_minerals.calcite_mol_per_m3 * carriers.surface_water_after_m3 +
        soil.geochemistry_solids[0].calcite_solid_mol_per_m3 * carriers.soil_shared_water_after_m3;
    try std.testing.expectEqual(@as(f64, 6), calcite_after_mol);
}

test "pond carrier growth preserves unmoved soil silicate amounts" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    inline for (.{
        "aluminum_natural_silicate_mol_per_m3",
        "aluminum_ground_silicate_mol_per_m3",
        "iron_natural_silicate_mol_per_m3",
        "iron_ground_silicate_mol_per_m3",
        "calcium_natural_silicate_mol_per_m3",
        "calcium_ground_silicate_mol_per_m3",
        "magnesium_natural_silicate_mol_per_m3",
        "magnesium_ground_silicate_mol_per_m3",
        "sodium_natural_silicate_mol_per_m3",
        "sodium_ground_silicate_mol_per_m3",
        "potassium_natural_silicate_mol_per_m3",
        "potassium_ground_silicate_mol_per_m3",
    }) |name| @field(soil.geochemistry_solids[0], name) = 7;
    const carriers: CarrierVolumes = .{
        .surface_water_before_m3 = 3,
        .soil_shared_water_before_m3 = 2,
        .soil_phosphate_non_band_water_before_m3 = 2,
        .surface_water_after_m3 = 0,
        .soil_shared_water_after_m3 = 5,
        .soil_phosphate_non_band_water_after_m3 = 5,
        .surface_dry_mass_before_megagrams = 0,
        .soil_dry_mass_before_megagrams = 2,
        .surface_dry_mass_after_megagrams = 0,
        .soil_dry_mass_after_megagrams = 2,
        .dissolved_chemistry_fraction = 1,
        .cell_area_m2 = 1,
    };
    try transferSurfaceFractionToSoil(&surface, &soil, 0, 0, carriers, false, 0);
    inline for (.{
        "aluminum_natural_silicate_mol_per_m3",
        "aluminum_ground_silicate_mol_per_m3",
        "iron_natural_silicate_mol_per_m3",
        "iron_ground_silicate_mol_per_m3",
        "calcium_natural_silicate_mol_per_m3",
        "calcium_ground_silicate_mol_per_m3",
        "magnesium_natural_silicate_mol_per_m3",
        "magnesium_ground_silicate_mol_per_m3",
        "sodium_natural_silicate_mol_per_m3",
        "sodium_ground_silicate_mol_per_m3",
        "potassium_natural_silicate_mol_per_m3",
        "potassium_ground_silicate_mol_per_m3",
    }) |name| try std.testing.expectApproxEqAbs(
        @as(f64, 14),
        @field(soil.geochemistry_solids[0], name) * carriers.soil_shared_water_after_m3,
        1e-14,
    );
}

test "dissolved chemistry fraction zero leaves soil aqueous state unchanged while dry chemistry still transfers" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    surface.cells[0].ammonium_mol_per_m3 = 1_000_000;
    surface.cells[0].exchange.ammonium_mol_per_megagram = 100;
    soil.aqueous[0].ammonium_non_band = 5;
    soil.cation_exchange_mol_per_megagram[0].ammonium_non_band = 0;
    // Water transfer blocked (pore full): dissolved_chemistry_fraction = 0.
    // Dry mass transfers at the full fraction = 0.5.
    const carriers: CarrierVolumes = .{
        .surface_water_before_m3 = 10,
        .soil_shared_water_before_m3 = 2,
        .soil_phosphate_non_band_water_before_m3 = 2,
        .surface_water_after_m3 = 10,
        .soil_shared_water_after_m3 = 2,
        .soil_phosphate_non_band_water_after_m3 = 2,
        .surface_dry_mass_before_megagrams = 2,
        .soil_dry_mass_before_megagrams = 2,
        .surface_dry_mass_after_megagrams = 1,
        .soil_dry_mass_after_megagrams = 3,
        .dissolved_chemistry_fraction = 0,
        .cell_area_m2 = 1,
    };
    try transferSurfaceFractionToSoil(&surface, &soil, 0, 0, carriers, false, 0.5);
    // Dissolved: no transfer, soil stays at 5
    try std.testing.expectEqual(@as(f64, 5), soil.aqueous[0].ammonium_non_band);
    // Dissolved: source concentration unchanged (no water moved)
    try std.testing.expectEqual(@as(f64, 1_000_000), surface.cells[0].ammonium_mol_per_m3);
    // Adsorbed: half of surface (0.5 * 100 * 2 / 3 Mg) moves to soil
    try std.testing.expectApproxEqAbs(@as(f64, 100.0 / 3.0), soil.cation_exchange_mol_per_megagram[0].ammonium_non_band, 1e-12);
}

test "pond precipitates follow solid fraction rather than capped water fraction" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    surface.mineral_reference_water_m3[0] = 10;
    surface.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3 = 4;
    surface.cells[0].salt_minerals.calcite_mol_per_m3 = 6;
    surface.cells[0].nitrate_mol_per_m3 = 2;
    const carriers: CarrierVolumes = .{
        .surface_water_before_m3 = 10,
        .soil_shared_water_before_m3 = 2,
        .soil_phosphate_non_band_water_before_m3 = 2,
        .surface_water_after_m3 = 9,
        .soil_shared_water_after_m3 = 3,
        .soil_phosphate_non_band_water_after_m3 = 3,
        .surface_dry_mass_before_megagrams = 4,
        .soil_dry_mass_before_megagrams = 5,
        .surface_dry_mass_after_megagrams = 2,
        .soil_dry_mass_after_megagrams = 7,
        .dissolved_chemistry_fraction = 0.1,
        .cell_area_m2 = 1,
    };
    try transferSurfaceFractionToSoil(&surface, &soil, 0, 0, carriers, true, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0 / 9.0), surface.cells[0].phosphate_minerals.aluminum_phosphate_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0 / 3.0), soil.non_band_phosphate[0].aluminum_phosphate_solid_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 30.0 / 9.0), surface.cells[0].salt_minerals.calcite_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 30.0 / 3.0), soil.geochemistry_solids[0].calcite_solid_mol_per_m3, 1e-14);
    // Dissolved nitrate still follows the smaller water fraction.
    try std.testing.expectApproxEqAbs(@as(f64, 2), surface.cells[0].nitrate_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), soil.aqueous[0].nitrate_non_band, 1e-14);
}

test "dry pond-domain transfer conserves retained aqueous and mineral native inventories" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    surface.dry_reference_water_m3[0] = 3;
    surface.mineral_reference_water_m3[0] = 4;
    surface.cells[0].nitrate_mol_per_m3 = 2;
    surface.cells[0].salt_minerals.calcite_mol_per_m3 = 5;
    soil.aqueous[0].nitrate_non_band = 1;
    soil.geochemistry_solids[0].calcite_solid_mol_per_m3 = 1;
    const carriers: CarrierVolumes = .{
        .surface_water_before_m3 = 0,
        .soil_shared_water_before_m3 = 2,
        .soil_phosphate_non_band_water_before_m3 = 2,
        .surface_water_after_m3 = 0,
        .soil_shared_water_after_m3 = 2,
        .soil_phosphate_non_band_water_after_m3 = 2,
        .surface_dry_mass_before_megagrams = 2,
        .soil_dry_mass_before_megagrams = 2,
        .surface_dry_mass_after_megagrams = 1,
        .soil_dry_mass_after_megagrams = 3,
        .dissolved_chemistry_fraction = 0.5,
        .cell_area_m2 = 1,
    };
    const nitrate_before_mol = surface.cells[0].nitrate_mol_per_m3 * surface.dry_reference_water_m3[0] +
        soil.aqueous[0].nitrate_non_band * carriers.soil_shared_water_before_m3;
    const calcite_before_mol = surface.cells[0].salt_minerals.calcite_mol_per_m3 * surface.mineral_reference_water_m3[0] +
        soil.geochemistry_solids[0].calcite_solid_mol_per_m3 * carriers.soil_shared_water_before_m3;

    try transferSurfaceFractionToSoil(&surface, &soil, 0, 0, carriers, true, 0.5);

    try std.testing.expectEqual(@as(f64, 3), surface.dry_reference_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 4), surface.mineral_reference_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 1), surface.cells[0].nitrate_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 2.5), surface.cells[0].salt_minerals.calcite_mol_per_m3);
    const nitrate_after_mol = surface.cells[0].nitrate_mol_per_m3 * surface.dry_reference_water_m3[0] +
        soil.aqueous[0].nitrate_non_band * carriers.soil_shared_water_after_m3;
    const calcite_after_mol = surface.cells[0].salt_minerals.calcite_mol_per_m3 * surface.mineral_reference_water_m3[0] +
        soil.geochemistry_solids[0].calcite_solid_mol_per_m3 * carriers.soil_shared_water_after_m3;
    try std.testing.expectApproxEqAbs(nitrate_before_mol, nitrate_after_mol, 1e-14);
    try std.testing.expectApproxEqAbs(calcite_before_mol, calcite_after_mol, 1e-14);

    try carrier_rebase.rebaseFromAcceptedLiquidWaterChange(&surface, &.{6}, &.{6});
    try std.testing.expectEqual(@as(f64, 0), surface.dry_reference_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 0.5), surface.cells[0].nitrate_mol_per_m3);
    try std.testing.expectApproxEqAbs(@as(f64, 3), surface.cells[0].nitrate_mol_per_m3 * 6, 1e-14);
}

test "wet pond-domain transfer to dryness preserves residual solute through rewetting" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    surface.cells[0].nitrate_mol_per_m3 = 2;
    soil.aqueous[0].nitrate_non_band = 1;
    const carriers: CarrierVolumes = .{
        .surface_water_before_m3 = 4,
        .soil_shared_water_before_m3 = 2,
        .soil_phosphate_non_band_water_before_m3 = 2,
        .surface_water_after_m3 = 0,
        .soil_shared_water_after_m3 = 2,
        .soil_phosphate_non_band_water_after_m3 = 2,
        .surface_dry_mass_before_megagrams = 2,
        .soil_dry_mass_before_megagrams = 2,
        .surface_dry_mass_after_megagrams = 1,
        .soil_dry_mass_after_megagrams = 3,
        .dissolved_chemistry_fraction = 0.25,
        .cell_area_m2 = 1,
    };
    const before_mol = surface.cells[0].nitrate_mol_per_m3 * 4 +
        soil.aqueous[0].nitrate_non_band * 2;
    try transferSurfaceFractionToSoil(&surface, &soil, 0, 0, carriers, false, 0.5);
    try std.testing.expectEqual(@as(f64, 3), surface.dry_reference_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 2), surface.cells[0].nitrate_mol_per_m3);
    try std.testing.expectApproxEqAbs(before_mol, surface.cells[0].nitrate_mol_per_m3 * 3 + soil.aqueous[0].nitrate_non_band * 2, 1e-14);

    try carrier_rebase.rebaseFromAcceptedLiquidWaterChange(&surface, &.{6}, &.{6});
    try std.testing.expectEqual(@as(f64, 0), surface.dry_reference_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 1), surface.cells[0].nitrate_mol_per_m3);
    try std.testing.expectApproxEqAbs(before_mol, surface.cells[0].nitrate_mol_per_m3 * 6 + soil.aqueous[0].nitrate_non_band * 2, 1e-14);
}

test "dry pond-domain unbound aqueous inventory fails atomically" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    surface.cells[0].nitrate_mol_per_m3 = 2;
    const surface_before = surface.cells[0];
    const soil_before = soil.aqueous[0];
    try std.testing.expectError(error.InvalidSurfacePondChemistryState, transferSurfaceFractionToSoil(
        &surface,
        &soil,
        0,
        0,
        .{
            .surface_water_before_m3 = 0,
            .soil_shared_water_before_m3 = 1,
            .soil_phosphate_non_band_water_before_m3 = 1,
            .surface_water_after_m3 = 0,
            .soil_shared_water_after_m3 = 1,
            .soil_phosphate_non_band_water_after_m3 = 1,
            .surface_dry_mass_before_megagrams = 1,
            .soil_dry_mass_before_megagrams = 1,
            .surface_dry_mass_after_megagrams = 0.5,
            .soil_dry_mass_after_megagrams = 1.5,
            .dissolved_chemistry_fraction = 0.5,
            .cell_area_m2 = 1,
        },
        false,
        0.5,
    ));
    try std.testing.expectEqualDeep(surface_before, surface.cells[0]);
    try std.testing.expectEqualDeep(soil_before, soil.aqueous[0]);
    try std.testing.expectEqual(@as(f64, 0), surface.dry_reference_water_m3[0]);
}

test "water-only pond chemistry transfers with zero dry carrier" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    surface.cells[0].nitrate_mol_per_m3 = 2;
    soil.aqueous[0].nitrate_non_band = 1;
    const carriers: CarrierVolumes = .{
        .surface_water_before_m3 = 3,
        .soil_shared_water_before_m3 = 1,
        .soil_phosphate_non_band_water_before_m3 = 1,
        .surface_water_after_m3 = 0,
        .soil_shared_water_after_m3 = 4,
        .soil_phosphate_non_band_water_after_m3 = 4,
        .surface_dry_mass_before_megagrams = 0,
        .soil_dry_mass_before_megagrams = 2,
        .surface_dry_mass_after_megagrams = 0,
        .soil_dry_mass_after_megagrams = 2,
        .dissolved_chemistry_fraction = 1,
        .cell_area_m2 = 1,
    };
    try transferSurfaceFractionToSoil(
        &surface,
        &soil,
        0,
        0,
        carriers,
        false,
        1,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        surface.cells[0].nitrate_mol_per_m3,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.75),
        soil.aqueous[0].nitrate_non_band,
        1e-14,
    );
}

test "issue-069 Finding A: pondSurfaceWaterCarrierM3 substitutes the dry reference at and below the ZEROS2 floor instead of only at exact zero" {
    const negligible = legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(1.0);
    try std.testing.expectEqual(@as(f64, 1.0e-6), negligible);

    // A near-zero-but-nonzero raw carrier -- the exact shape this defect
    // class manufactures fake mass from at issue-060/061/063/064/065/066's
    // other sites.
    const near_zero_raw_carrier: f64 = 1.0e-9;
    try std.testing.expect(near_zero_raw_carrier > 0);
    const dry_reference_m3: f64 = 0.5;
    const concentration_mol_per_m3: f64 = 20.0;

    // OLD guard (bare `> 0`, this file's behavior before this fix): the
    // near-zero raw carrier is accepted as "real", manufacturing a fake mass
    // more than eight orders of magnitude below the physically correct
    // value.
    const old_carrier = if (near_zero_raw_carrier > 0) near_zero_raw_carrier else dry_reference_m3;
    const old_mass_mol = concentration_mol_per_m3 * old_carrier;
    try std.testing.expectEqual(@as(f64, 1.0e-9), old_carrier);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0e-8), old_mass_mol, 1e-22);

    // NEW guard (this fix): the same near-zero raw carrier is at/below the
    // ZEROS2-equivalent floor, so the remembered dry reference is
    // substituted instead, producing a stable, physically sensible mass.
    const new_carrier = pondSurfaceWaterCarrierM3(near_zero_raw_carrier, dry_reference_m3, negligible);
    const new_mass_mol = concentration_mol_per_m3 * new_carrier;
    try std.testing.expectEqual(dry_reference_m3, new_carrier);
    try std.testing.expectEqual(@as(f64, 10.0), new_mass_mol);
    try std.testing.expect(new_mass_mol / old_mass_mol > 1.0e8);

    // Strictly above the floor: both guards agree and keep the live carrier.
    const just_above = std.math.nextAfter(f64, negligible, std.math.inf(f64));
    try std.testing.expectEqual(just_above, pondSurfaceWaterCarrierM3(just_above, dry_reference_m3, negligible));
    // At exactly the floor: OLD guard (`> 0`) would still have kept the live
    // carrier since `negligible > 0`, but NEW guard substitutes the dry
    // reference -- this is the boundary the fix actually widens.
    try std.testing.expect(negligible > 0);
    try std.testing.expectEqual(dry_reference_m3, pondSurfaceWaterCarrierM3(negligible, dry_reference_m3, negligible));
}

test "issue-069 Finding A: near-zero-but-nonzero surface water carrier no longer manufactures a fake mass swing in transferSurfaceFractionToSoil" {
    var surface = try surface_module.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try soil_module.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    surface.cells[0].ammonium_mol_per_m3 = 20;
    surface.dry_reference_water_m3[0] = 0.5;
    soil.aqueous[0].ammonium_non_band = 3;

    const near_zero_raw_carrier: f64 = 1.0e-9;
    const carriers: CarrierVolumes = .{
        .surface_water_before_m3 = near_zero_raw_carrier,
        .soil_shared_water_before_m3 = 2,
        .soil_phosphate_non_band_water_before_m3 = 2,
        .surface_water_after_m3 = 0,
        .soil_shared_water_after_m3 = 2,
        .soil_phosphate_non_band_water_after_m3 = 2,
        .surface_dry_mass_before_megagrams = 1,
        .soil_dry_mass_before_megagrams = 1,
        .surface_dry_mass_after_megagrams = 0.5,
        .soil_dry_mass_after_megagrams = 1.5,
        .dissolved_chemistry_fraction = 1,
        .cell_area_m2 = 1,
    };

    // Physically correct pre-transfer ammonium mass, on the dry-reference
    // basis a near-zero-but-nonzero live carrier must fall back to
    // (issue-060's own established basis).
    const true_before_mol = surface.cells[0].ammonium_mol_per_m3 * surface.dry_reference_water_m3[0] +
        soil.aqueous[0].ammonium_non_band * carriers.soil_shared_water_before_m3;

    // Manually replicate the OLD (pre-fix) exact-zero-only guard's basis to
    // prove it manufactures a fake mass swing: the pre-fix `calculate` used
    // the raw near-zero carrier directly (since it is `> 0`) instead of
    // substituting the dry reference.
    const old_source_amount_mol = surface.cells[0].ammonium_mol_per_m3 * near_zero_raw_carrier;
    try std.testing.expect(old_source_amount_mol / true_before_mol < 1.0e-6);

    try transferSurfaceFractionToSoil(&surface, &soil, 0, 0, carriers, false, 1);

    // NEW (fixed) behavior: total ammonium mass is conserved to roundoff
    // across the transfer, because the widened guard substitutes the dry
    // reference for the near-zero raw carrier instead of manufacturing a
    // near-total fake mass loss.
    const after_mol = surface.cells[0].ammonium_mol_per_m3 * surface.dry_reference_water_m3[0] +
        soil.aqueous[0].ammonium_non_band * carriers.soil_shared_water_after_m3;
    try std.testing.expectApproxEqAbs(true_before_mol, after_mol, 1e-12);
    try std.testing.expectEqual(@as(f64, 0), surface.cells[0].ammonium_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 8), soil.aqueous[0].ammonium_non_band);
}
