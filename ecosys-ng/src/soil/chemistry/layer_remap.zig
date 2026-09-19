const std = @import("std");
const chemistry_module = @import("../solute/chemistry_state.zig");
const phosphate = @import("../solute/phosphate_network.zig");
const cation = @import("../solute/cation_exchange.zig");
const geochemistry = @import("../solute/geochemistry_network.zig");
const aqueous = @import("../solute/aqueous_network.zig");
const ZoneFractions = @import("../solute/charge_classification.zig").ZoneFractions;

pub const ZoneWaterVolumes = struct {
    shared_m3: f64,
    ammonium_non_band_m3: f64,
    ammonium_band_m3: f64,
    nitrate_non_band_m3: f64,
    nitrate_band_m3: f64,
    phosphate_non_band_m3: f64,
    phosphate_band_m3: f64,
};

pub const ZoneFractionTransition = struct {
    source_before: ZoneFractions,
    destination_before: ZoneFractions,
    source_after: ZoneFractions,
    destination_after: ZoneFractions,
};

const equal_zone_fractions: ZoneFractions = .{
    .ammonium_non_band = 0.5,
    .ammonium_band = 0.5,
    .nitrate_non_band = 0.5,
    .nitrate_band = 0.5,
    .phosphate_non_band = 0.5,
    .phosphate_band = 0.5,
};
const equal_zone_transition: ZoneFractionTransition = .{
    .source_before = equal_zone_fractions,
    .destination_before = equal_zone_fractions,
    .source_after = equal_zone_fractions,
    .destination_after = equal_zone_fractions,
};

/// REDIST ponding for soluble N/P and the complete optional dynamic-salt
/// network. Band pools retain the source gate: no destination band carrier
/// means neither destination addition nor source removal.
pub fn transferAqueousLayerFraction(
    chemistry: *chemistry_module.State,
    source: usize,
    destination: usize,
    source_water: ZoneWaterVolumes,
    destination_water: ZoneWaterVolumes,
    source_water_after: ZoneWaterVolumes,
    destination_water_after: ZoneWaterVolumes,
    dynamic_salts: bool,
    fraction: f64,
) !void {
    if (source >= chemistry.cell_count or destination >= chemistry.cell_count or source == destination) return error.ChemistryLayerRemapIndexOutOfBounds;
    try validateZoneWater(source_water);
    try validateZoneWater(destination_water);
    try validateZoneWater(source_water_after);
    try validateZoneWater(destination_water_after);
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidChemistryLayerRemapInput;
    var next_source_aqueous = chemistry.aqueous[source];
    var next_destination_aqueous = chemistry.aqueous[destination];
    inline for (@typeInfo(aqueous.State).@"struct".fields) |field| {
        if ((comptime isBasePondedAqueousField(field.name)) or dynamic_salts) {
            const source_scale = aqueousFieldVolume(field.name, source_water);
            const destination_scale = aqueousFieldVolume(field.name, destination_water);
            const source_scale_after = aqueousFieldVolume(field.name, source_water_after);
            const destination_scale_after = aqueousFieldVolume(field.name, destination_water_after);
            const is_band = comptime std.mem.endsWith(u8, field.name, "_band");
            const moved_fraction = if (!is_band or destination_scale_after > 0)
                fraction
            else
                0;
            const next = try transferConcentration(@field(next_source_aqueous, field.name), @field(next_destination_aqueous, field.name), source_scale, destination_scale, source_scale_after, destination_scale_after, moved_fraction);
            @field(next_source_aqueous, field.name) = next.source;
            @field(next_destination_aqueous, field.name) = next.destination;
        }
    }
    const next_reaction_water = try transferConcentration(
        chemistry.water_mol_per_m3[source],
        chemistry.water_mol_per_m3[destination],
        source_water.shared_m3,
        destination_water.shared_m3,
        source_water_after.shared_m3,
        destination_water_after.shared_m3,
        fraction,
    );
    var next_source_non_band = chemistry.non_band_phosphate[source];
    var next_destination_non_band = chemistry.non_band_phosphate[destination];
    var next_source_band = chemistry.band_phosphate[source];
    var next_destination_band = chemistry.band_phosphate[destination];
    inline for (@typeInfo(phosphate.State).@"struct".fields) |field| if ((comptime isBaseAqueousPhosphateField(field.name)) or (dynamic_salts and (comptime isAqueousPhosphateField(field.name)))) {
        const non_band = try transferConcentration(@field(next_source_non_band, field.name), @field(next_destination_non_band, field.name), source_water.phosphate_non_band_m3, destination_water.phosphate_non_band_m3, source_water_after.phosphate_non_band_m3, destination_water_after.phosphate_non_band_m3, fraction);
        @field(next_source_non_band, field.name) = non_band.source;
        @field(next_destination_non_band, field.name) = non_band.destination;
        const band_fraction = if (destination_water_after.phosphate_band_m3 > 0)
            fraction
        else
            0;
        const band = try transferConcentration(@field(next_source_band, field.name), @field(next_destination_band, field.name), source_water.phosphate_band_m3, destination_water.phosphate_band_m3, source_water_after.phosphate_band_m3, destination_water_after.phosphate_band_m3, band_fraction);
        @field(next_source_band, field.name) = band.source;
        @field(next_destination_band, field.name) = band.destination;
    };
    chemistry.aqueous[source] = next_source_aqueous;
    chemistry.aqueous[destination] = next_destination_aqueous;
    chemistry.water_mol_per_m3[source] = next_reaction_water.source;
    chemistry.water_mol_per_m3[destination] = next_reaction_water.destination;
    chemistry.non_band_phosphate[source] = next_source_non_band;
    chemistry.non_band_phosphate[destination] = next_destination_non_band;
    chemistry.band_phosphate[source] = next_source_band;
    chemistry.band_phosphate[destination] = next_destination_band;
}

pub fn validateAqueousLayerFraction(
    chemistry: *const chemistry_module.State,
    source: usize,
    destination: usize,
    source_water: ZoneWaterVolumes,
    destination_water: ZoneWaterVolumes,
    source_water_after: ZoneWaterVolumes,
    destination_water_after: ZoneWaterVolumes,
    dynamic_salts: bool,
    fraction: f64,
) !void {
    if (source >= chemistry.cell_count or destination >= chemistry.cell_count) return error.ChemistryLayerRemapIndexOutOfBounds;
    var view = twoCellView(chemistry, source, destination);
    var state = view.bindState();
    try transferAqueousLayerFraction(&state, 0, 1, source_water, destination_water, source_water_after, destination_water_after, dynamic_salts, fraction);
}

/// REDIST ponding of adsorbed cations, carboxyl H, phosphate surfaces and
/// precipitates, and geochemical solids. Native concentration units are
/// converted to extensive amounts on their exact soil-mass or water-volume
/// basis before the conservative transfer.
pub fn transferSolidLayerFraction(
    chemistry: *chemistry_module.State,
    source: usize,
    destination: usize,
    source_soil_mass_megagrams: f64,
    destination_soil_mass_megagrams: f64,
    source_water_m3: f64,
    destination_water_m3: f64,
    zone_fractions: ZoneFractionTransition,
    source_soil_mass_after_megagrams: f64,
    destination_soil_mass_after_megagrams: f64,
    source_water_after_m3: f64,
    destination_water_after_m3: f64,
    fraction: f64,
) !void {
    if (source >= chemistry.cell_count or destination >= chemistry.cell_count or source == destination) return error.ChemistryLayerRemapIndexOutOfBounds;
    inline for (.{ source_soil_mass_megagrams, destination_soil_mass_megagrams, source_water_m3, destination_water_m3, source_soil_mass_after_megagrams, destination_soil_mass_after_megagrams, source_water_after_m3, destination_water_after_m3, fraction }) |value|
        if (!std.math.isFinite(value)) return error.InvalidChemistryLayerRemapInput;
    if (source_soil_mass_megagrams < 0 or destination_soil_mass_megagrams < 0 or source_water_m3 < 0 or destination_water_m3 < 0 or source_soil_mass_after_megagrams < 0 or destination_soil_mass_after_megagrams < 0 or source_water_after_m3 < 0 or destination_water_after_m3 < 0 or fraction < 0 or fraction > 1) return error.InvalidChemistryLayerRemapInput;
    try validateZoneFractionTransition(zone_fractions);

    var next_source_cations = chemistry.cation_exchange_mol_per_megagram[source];
    var next_destination_cations = chemistry.cation_exchange_mol_per_megagram[destination];
    var next_source_pending_cations = chemistry.pending_cation_exchange_mol[source];
    var next_destination_pending_cations = chemistry.pending_cation_exchange_mol[destination];
    inline for (@typeInfo(cation.Cations).@"struct".fields) |field| {
        const next = try transferOwnedAmount(
            @field(next_source_cations, field.name),
            @field(next_destination_cations, field.name),
            @field(next_source_pending_cations, field.name),
            @field(next_destination_pending_cations, field.name),
            cationSoilMass(field.name, source_soil_mass_megagrams, zone_fractions.source_before),
            cationSoilMass(field.name, destination_soil_mass_megagrams, zone_fractions.destination_before),
            cationSoilMass(field.name, source_soil_mass_after_megagrams, zone_fractions.source_after),
            cationSoilMass(field.name, destination_soil_mass_after_megagrams, zone_fractions.destination_after),
            fraction,
        );
        @field(next_source_cations, field.name) = next.source_concentration;
        @field(next_destination_cations, field.name) = next.destination_concentration;
        @field(next_source_pending_cations, field.name) = next.source_pending_mol;
        @field(next_destination_pending_cations, field.name) = next.destination_pending_mol;
    }
    const next_carboxyl = try transferOwnedAmount(chemistry.carboxyl_bound_hydrogen_mol_per_megagram[source], chemistry.carboxyl_bound_hydrogen_mol_per_megagram[destination], chemistry.pending_carboxyl_bound_hydrogen_mol[source], chemistry.pending_carboxyl_bound_hydrogen_mol[destination], source_soil_mass_megagrams, destination_soil_mass_megagrams, source_soil_mass_after_megagrams, destination_soil_mass_after_megagrams, fraction);

    var next_source_non_band = chemistry.non_band_phosphate[source];
    var next_destination_non_band = chemistry.non_band_phosphate[destination];
    var next_source_band = chemistry.band_phosphate[source];
    var next_destination_band = chemistry.band_phosphate[destination];
    var next_source_pending_non_band = chemistry.pending_non_band_phosphate_mol[source];
    var next_destination_pending_non_band = chemistry.pending_non_band_phosphate_mol[destination];
    var next_source_pending_band = chemistry.pending_band_phosphate_mol[source];
    var next_destination_pending_band = chemistry.pending_band_phosphate_mol[destination];
    inline for (.{
        .{
            &next_source_non_band,
            &next_destination_non_band,
            &next_source_pending_non_band,
            &next_destination_pending_non_band,
            zone_fractions.source_before.phosphate_non_band,
            zone_fractions.destination_before.phosphate_non_band,
            zone_fractions.source_after.phosphate_non_band,
            zone_fractions.destination_after.phosphate_non_band,
        },
        .{
            &next_source_band,
            &next_destination_band,
            &next_source_pending_band,
            &next_destination_pending_band,
            zone_fractions.source_before.phosphate_band,
            zone_fractions.destination_before.phosphate_band,
            zone_fractions.source_after.phosphate_band,
            zone_fractions.destination_after.phosphate_band,
        },
    }) |zones| inline for (@typeInfo(phosphate.State).@"struct".fields) |field| {
        if (comptime isPondedPhosphateField(field.name)) {
            const per_mass = comptime std.mem.endsWith(u8, field.name, "_per_megagram");
            const source_scale = (if (per_mass) source_soil_mass_megagrams else source_water_m3) * zones[4];
            const destination_scale = (if (per_mass) destination_soil_mass_megagrams else destination_water_m3) * zones[5];
            const source_scale_after = (if (per_mass) source_soil_mass_after_megagrams else source_water_after_m3) * zones[6];
            const destination_scale_after = (if (per_mass) destination_soil_mass_after_megagrams else destination_water_after_m3) * zones[7];
            // REDIST 9962--9976 and 10044--10058 transfer band adsorption and
            // precipitates unconditionally. A missing destination band carrier
            // is represented by the explicit pending extensive owner.
            const next = try transferOwnedAmount(@field(zones[0].*, field.name), @field(zones[1].*, field.name), @field(zones[2].*, field.name), @field(zones[3].*, field.name), source_scale, destination_scale, source_scale_after, destination_scale_after, fraction);
            @field(zones[0].*, field.name) = next.source_concentration;
            @field(zones[1].*, field.name) = next.destination_concentration;
            @field(zones[2].*, field.name) = next.source_pending_mol;
            @field(zones[3].*, field.name) = next.destination_pending_mol;
        }
    };

    var next_source_solids = chemistry.geochemistry_solids[source];
    var next_destination_solids = chemistry.geochemistry_solids[destination];
    var next_source_pending_solids = chemistry.pending_geochemistry_solids_mol[source];
    var next_destination_pending_solids = chemistry.pending_geochemistry_solids_mol[destination];
    inline for (@typeInfo(geochemistry.SolidState).@"struct".fields) |field| {
        const next = try transferOwnedAmount(@field(next_source_solids, field.name), @field(next_destination_solids, field.name), @field(next_source_pending_solids, field.name), @field(next_destination_pending_solids, field.name), source_water_m3, destination_water_m3, source_water_after_m3, destination_water_after_m3, fraction);
        @field(next_source_solids, field.name) = next.source_concentration;
        @field(next_destination_solids, field.name) = next.destination_concentration;
        @field(next_source_pending_solids, field.name) = next.source_pending_mol;
        @field(next_destination_pending_solids, field.name) = next.destination_pending_mol;
    }

    chemistry.cation_exchange_mol_per_megagram[source] = next_source_cations;
    chemistry.cation_exchange_mol_per_megagram[destination] = next_destination_cations;
    chemistry.pending_cation_exchange_mol[source] = next_source_pending_cations;
    chemistry.pending_cation_exchange_mol[destination] = next_destination_pending_cations;
    chemistry.carboxyl_bound_hydrogen_mol_per_megagram[source] = next_carboxyl.source_concentration;
    chemistry.carboxyl_bound_hydrogen_mol_per_megagram[destination] = next_carboxyl.destination_concentration;
    chemistry.pending_carboxyl_bound_hydrogen_mol[source] = next_carboxyl.source_pending_mol;
    chemistry.pending_carboxyl_bound_hydrogen_mol[destination] = next_carboxyl.destination_pending_mol;
    chemistry.non_band_phosphate[source] = next_source_non_band;
    chemistry.non_band_phosphate[destination] = next_destination_non_band;
    chemistry.band_phosphate[source] = next_source_band;
    chemistry.band_phosphate[destination] = next_destination_band;
    chemistry.pending_non_band_phosphate_mol[source] = next_source_pending_non_band;
    chemistry.pending_non_band_phosphate_mol[destination] = next_destination_pending_non_band;
    chemistry.pending_band_phosphate_mol[source] = next_source_pending_band;
    chemistry.pending_band_phosphate_mol[destination] = next_destination_pending_band;
    chemistry.geochemistry_solids[source] = next_source_solids;
    chemistry.geochemistry_solids[destination] = next_destination_solids;
    chemistry.pending_geochemistry_solids_mol[source] = next_source_pending_solids;
    chemistry.pending_geochemistry_solids_mol[destination] = next_destination_pending_solids;
}

/// Re-expresses immobile per-soil-mass chemistry after HOUR1 rebuilds VOLX
/// from accepted layer geometry. REDIST state is extensive in the reference;
/// this translation keeps that amount exact while changing only its native
/// concentration carrier. Water-carried precipitates are deliberately left
/// untouched here.
pub fn rebaseSolidSoilMassCarrier(
    chemistry: *chemistry_module.State,
    layer: usize,
    soil_mass_before_megagrams: f64,
    soil_mass_after_megagrams: f64,
    fractions: ZoneFractions,
) !void {
    if (layer >= chemistry.cell_count) return error.ChemistryLayerRemapIndexOutOfBounds;
    inline for (.{ soil_mass_before_megagrams, soil_mass_after_megagrams }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidChemistryLayerRemapInput;
    try validateZoneFractionTransition(.{
        .source_before = fractions,
        .destination_before = fractions,
        .source_after = fractions,
        .destination_after = fractions,
    });

    var next_cations = chemistry.cation_exchange_mol_per_megagram[layer];
    var next_pending_cations = chemistry.pending_cation_exchange_mol[layer];
    inline for (@typeInfo(cation.Cations).@"struct".fields) |field| {
        const next = try rebaseOwnedAmount(
            @field(next_cations, field.name),
            @field(next_pending_cations, field.name),
            cationSoilMass(field.name, soil_mass_before_megagrams, fractions),
            cationSoilMass(field.name, soil_mass_after_megagrams, fractions),
        );
        @field(next_cations, field.name) = next.concentration;
        @field(next_pending_cations, field.name) = next.pending_mol;
    }
    const next_carboxyl = try rebaseOwnedAmount(
        chemistry.carboxyl_bound_hydrogen_mol_per_megagram[layer],
        chemistry.pending_carboxyl_bound_hydrogen_mol[layer],
        soil_mass_before_megagrams,
        soil_mass_after_megagrams,
    );

    var next_non_band = chemistry.non_band_phosphate[layer];
    var next_band = chemistry.band_phosphate[layer];
    var next_pending_non_band = chemistry.pending_non_band_phosphate_mol[layer];
    var next_pending_band = chemistry.pending_band_phosphate_mol[layer];
    inline for (.{
        .{ &next_non_band, &next_pending_non_band, fractions.phosphate_non_band },
        .{ &next_band, &next_pending_band, fractions.phosphate_band },
    }) |zone| inline for (@typeInfo(phosphate.State).@"struct".fields) |field| {
        if (comptime std.mem.endsWith(u8, field.name, "_per_megagram")) {
            const next = try rebaseOwnedAmount(
                @field(zone[0].*, field.name),
                @field(zone[1].*, field.name),
                soil_mass_before_megagrams * zone[2],
                soil_mass_after_megagrams * zone[2],
            );
            @field(zone[0].*, field.name) = next.concentration;
            @field(zone[1].*, field.name) = next.pending_mol;
        }
    };

    chemistry.cation_exchange_mol_per_megagram[layer] = next_cations;
    chemistry.pending_cation_exchange_mol[layer] = next_pending_cations;
    chemistry.carboxyl_bound_hydrogen_mol_per_megagram[layer] = next_carboxyl.concentration;
    chemistry.pending_carboxyl_bound_hydrogen_mol[layer] = next_carboxyl.pending_mol;
    chemistry.non_band_phosphate[layer] = next_non_band;
    chemistry.band_phosphate[layer] = next_band;
    chemistry.pending_non_band_phosphate_mol[layer] = next_pending_non_band;
    chemistry.pending_band_phosphate_mol[layer] = next_pending_band;
}

const RebasedOwnedAmount = struct {
    concentration: f64,
    pending_mol: f64,
};

fn rebaseOwnedAmount(concentration_value: f64, pending_mol: f64, carrier_before: f64, carrier_after: f64) !RebasedOwnedAmount {
    inline for (.{ concentration_value, pending_mol, carrier_before, carrier_after }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidChemistryLayerRemapInput;
    const amount = concentration_value * carrier_before + pending_mol;
    if (!std.math.isFinite(amount)) return error.InvalidChemistryLayerRemapResult;
    if (carrier_after == 0) return .{ .concentration = 0, .pending_mol = amount };
    const next = amount / carrier_after;
    if (!std.math.isFinite(next) or next < 0) return error.InvalidChemistryLayerRemapResult;
    return .{ .concentration = next, .pending_mol = 0 };
}

pub fn validateSolidLayerFraction(
    chemistry: *const chemistry_module.State,
    source: usize,
    destination: usize,
    source_soil_mass_megagrams: f64,
    destination_soil_mass_megagrams: f64,
    source_water_m3: f64,
    destination_water_m3: f64,
    zone_fractions: ZoneFractionTransition,
    source_soil_mass_after_megagrams: f64,
    destination_soil_mass_after_megagrams: f64,
    source_water_after_m3: f64,
    destination_water_after_m3: f64,
    fraction: f64,
) !void {
    if (source >= chemistry.cell_count or destination >= chemistry.cell_count) return error.ChemistryLayerRemapIndexOutOfBounds;
    var view = twoCellView(chemistry, source, destination);
    var state = view.bindState();
    try transferSolidLayerFraction(&state, 0, 1, source_soil_mass_megagrams, destination_soil_mass_megagrams, source_water_m3, destination_water_m3, zone_fractions, source_soil_mass_after_megagrams, destination_soil_mass_after_megagrams, source_water_after_m3, destination_water_after_m3, fraction);
}

/// Exact REDIST pond-water particulate chemistry mask (`redist.f:380--527`):
/// non-band XN4, general exchanger cations, carboxyl sites, non-band phosphate
/// surfaces/precipitates, and geochemical solids. Band NH4/P pools do not
/// appear in this settling block and are preserved byte-for-byte.
pub fn transferPondParticulateLayerFraction(
    chemistry: *chemistry_module.State,
    source: usize,
    destination: usize,
    source_soil_mass_megagrams: f64,
    destination_soil_mass_megagrams: f64,
    source_water_m3: f64,
    destination_water_m3: f64,
    zone_fractions: ZoneFractionTransition,
    source_soil_mass_after_megagrams: f64,
    destination_soil_mass_after_megagrams: f64,
    fraction: f64,
) !void {
    if (source >= chemistry.cell_count or destination >= chemistry.cell_count or source == destination)
        return error.ChemistryLayerRemapIndexOutOfBounds;
    const source_band_ammonium = chemistry.cation_exchange_mol_per_megagram[source].ammonium_band;
    const destination_band_ammonium = chemistry.cation_exchange_mol_per_megagram[destination].ammonium_band;
    const source_pending_band_ammonium = chemistry.pending_cation_exchange_mol[source].ammonium_band;
    const destination_pending_band_ammonium = chemistry.pending_cation_exchange_mol[destination].ammonium_band;
    const source_band_phosphate = chemistry.band_phosphate[source];
    const destination_band_phosphate = chemistry.band_phosphate[destination];
    const source_pending_band_phosphate = chemistry.pending_band_phosphate_mol[source];
    const destination_pending_band_phosphate = chemistry.pending_band_phosphate_mol[destination];

    chemistry.cation_exchange_mol_per_megagram[source].ammonium_band = 0;
    chemistry.cation_exchange_mol_per_megagram[destination].ammonium_band = 0;
    chemistry.pending_cation_exchange_mol[source].ammonium_band = 0;
    chemistry.pending_cation_exchange_mol[destination].ammonium_band = 0;
    chemistry.band_phosphate[source] = std.mem.zeroes(phosphate.State);
    chemistry.band_phosphate[destination] = std.mem.zeroes(phosphate.State);
    chemistry.pending_band_phosphate_mol[source] = std.mem.zeroes(phosphate.State);
    chemistry.pending_band_phosphate_mol[destination] = std.mem.zeroes(phosphate.State);
    defer {
        chemistry.cation_exchange_mol_per_megagram[source].ammonium_band = source_band_ammonium;
        chemistry.cation_exchange_mol_per_megagram[destination].ammonium_band = destination_band_ammonium;
        chemistry.pending_cation_exchange_mol[source].ammonium_band = source_pending_band_ammonium;
        chemistry.pending_cation_exchange_mol[destination].ammonium_band = destination_pending_band_ammonium;
        chemistry.band_phosphate[source] = source_band_phosphate;
        chemistry.band_phosphate[destination] = destination_band_phosphate;
        chemistry.pending_band_phosphate_mol[source] = source_pending_band_phosphate;
        chemistry.pending_band_phosphate_mol[destination] = destination_pending_band_phosphate;
    }
    try transferSolidLayerFraction(
        chemistry,
        source,
        destination,
        source_soil_mass_megagrams,
        destination_soil_mass_megagrams,
        source_water_m3,
        destination_water_m3,
        zone_fractions,
        source_soil_mass_after_megagrams,
        destination_soil_mass_after_megagrams,
        source_water_m3,
        destination_water_m3,
        fraction,
    );
}

pub fn validatePondParticulateLayerFraction(
    chemistry: *const chemistry_module.State,
    source: usize,
    destination: usize,
    source_soil_mass_megagrams: f64,
    destination_soil_mass_megagrams: f64,
    source_water_m3: f64,
    destination_water_m3: f64,
    zone_fractions: ZoneFractionTransition,
    source_soil_mass_after_megagrams: f64,
    destination_soil_mass_after_megagrams: f64,
    fraction: f64,
) !void {
    if (source >= chemistry.cell_count or destination >= chemistry.cell_count or source == destination)
        return error.ChemistryLayerRemapIndexOutOfBounds;
    var view = twoCellView(chemistry, source, destination);
    var state = view.bindState();
    try transferPondParticulateLayerFraction(
        &state,
        0,
        1,
        source_soil_mass_megagrams,
        destination_soil_mass_megagrams,
        source_water_m3,
        destination_water_m3,
        zone_fractions,
        source_soil_mass_after_megagrams,
        destination_soil_mass_after_megagrams,
        fraction,
    );
}

fn cationSoilMass(comptime field_name: []const u8, soil_mass: f64, fractions: ZoneFractions) f64 {
    if (comptime std.mem.eql(u8, field_name, "ammonium_non_band"))
        return soil_mass * fractions.ammonium_non_band;
    if (comptime std.mem.eql(u8, field_name, "ammonium_band"))
        return soil_mass * fractions.ammonium_band;
    return soil_mass;
}

fn validateZoneFractionTransition(transition: ZoneFractionTransition) !void {
    inline for (.{
        transition.source_before,
        transition.destination_before,
        transition.source_after,
        transition.destination_after,
    }) |fractions| {
        inline for (@typeInfo(ZoneFractions).@"struct".fields) |field| {
            const value = @field(fractions, field.name);
            if (!std.math.isFinite(value) or value < 0 or value > 1)
                return error.InvalidChemistryLayerRemapInput;
        }
        inline for (.{
            .{ fractions.ammonium_non_band, fractions.ammonium_band },
            .{ fractions.nitrate_non_band, fractions.nitrate_band },
            .{ fractions.phosphate_non_band, fractions.phosphate_band },
        }) |pair|
            if (@abs(pair[0] + pair[1] - 1) > 64 * std.math.floatEps(f64))
                return error.InvalidChemistryLayerRemapInput;
    }
}

const TwoCellView = struct {
    aqueous_values: [2]aqueous.State,
    non_band_values: [2]phosphate.State,
    band_values: [2]phosphate.State,
    water_values: [2]f64,
    water_balance_values: [2]f64 = .{ 0, 0 },
    cation_values: [2]cation.Cations,
    carboxyl_values: [2]f64,
    solid_values: [2]geochemistry.SolidState,
    dry_reference_values: [2]f64 = .{ 0, 0 },
    pending_cation_values: [2]cation.Cations,
    pending_carboxyl_values: [2]f64,
    pending_non_band_values: [2]phosphate.State,
    pending_band_values: [2]phosphate.State,
    pending_solid_values: [2]geochemistry.SolidState,

    fn bindState(self: *TwoCellView) chemistry_module.State {
        return .{
            .allocator = undefined,
            .cell_count = 2,
            .aqueous = &self.aqueous_values,
            .non_band_phosphate = &self.non_band_values,
            .band_phosphate = &self.band_values,
            .water_mol_per_m3 = &self.water_values,
            .water_equilibrium_balance_mol = &self.water_balance_values,
            .cation_exchange_mol_per_megagram = &self.cation_values,
            .carboxyl_bound_hydrogen_mol_per_megagram = &self.carboxyl_values,
            .geochemistry_solids = &self.solid_values,
            .dry_reference_water_m3 = &self.dry_reference_values,
            .pending_cation_exchange_mol = &self.pending_cation_values,
            .pending_carboxyl_bound_hydrogen_mol = &self.pending_carboxyl_values,
            .pending_non_band_phosphate_mol = &self.pending_non_band_values,
            .pending_band_phosphate_mol = &self.pending_band_values,
            .pending_geochemistry_solids_mol = &self.pending_solid_values,
        };
    }
};

fn twoCellView(chemistry: *const chemistry_module.State, source: usize, destination: usize) TwoCellView {
    var result: TwoCellView = undefined;
    result.aqueous_values = .{ chemistry.aqueous[source], chemistry.aqueous[destination] };
    result.non_band_values = .{ chemistry.non_band_phosphate[source], chemistry.non_band_phosphate[destination] };
    result.band_values = .{ chemistry.band_phosphate[source], chemistry.band_phosphate[destination] };
    result.water_values = .{ chemistry.water_mol_per_m3[source], chemistry.water_mol_per_m3[destination] };
    result.cation_values = .{ chemistry.cation_exchange_mol_per_megagram[source], chemistry.cation_exchange_mol_per_megagram[destination] };
    result.carboxyl_values = .{ chemistry.carboxyl_bound_hydrogen_mol_per_megagram[source], chemistry.carboxyl_bound_hydrogen_mol_per_megagram[destination] };
    result.solid_values = .{ chemistry.geochemistry_solids[source], chemistry.geochemistry_solids[destination] };
    result.dry_reference_values = .{ chemistry.dry_reference_water_m3[source], chemistry.dry_reference_water_m3[destination] };
    result.pending_cation_values = .{ chemistry.pending_cation_exchange_mol[source], chemistry.pending_cation_exchange_mol[destination] };
    result.pending_carboxyl_values = .{ chemistry.pending_carboxyl_bound_hydrogen_mol[source], chemistry.pending_carboxyl_bound_hydrogen_mol[destination] };
    result.pending_non_band_values = .{ chemistry.pending_non_band_phosphate_mol[source], chemistry.pending_non_band_phosphate_mol[destination] };
    result.pending_band_values = .{ chemistry.pending_band_phosphate_mol[source], chemistry.pending_band_phosphate_mol[destination] };
    result.pending_solid_values = .{ chemistry.pending_geochemistry_solids_mol[source], chemistry.pending_geochemistry_solids_mol[destination] };
    return result;
}

const ConcentrationPair = struct { source: f64, destination: f64 };

fn transferConcentration(source: f64, destination: f64, source_scale: f64, destination_scale: f64, source_scale_after: f64, destination_scale_after: f64, fraction: f64) !ConcentrationPair {
    inline for (.{ source, destination, source_scale, destination_scale, source_scale_after, destination_scale_after }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidChemistryLayerRemapState;
    const source_amount = source * source_scale;
    const destination_amount = destination * destination_scale;
    const moved = fraction * source_amount;
    const next_source_amount = source_amount - moved;
    const next_destination_amount = destination_amount + moved;
    inline for (.{ source_amount, destination_amount, moved, next_source_amount, next_destination_amount }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidChemistryLayerRemapState;
    return .{
        .source = try concentration(next_source_amount, source_scale_after),
        .destination = try concentration(next_destination_amount, destination_scale_after),
    };
}

const OwnedAmountPair = struct {
    source_concentration: f64,
    destination_concentration: f64,
    source_pending_mol: f64,
    destination_pending_mol: f64,
};

fn transferOwnedAmount(source: f64, destination: f64, source_pending_mol: f64, destination_pending_mol: f64, source_scale: f64, destination_scale: f64, source_scale_after: f64, destination_scale_after: f64, fraction: f64) !OwnedAmountPair {
    inline for (.{ source, destination, source_pending_mol, destination_pending_mol, source_scale, destination_scale, source_scale_after, destination_scale_after, fraction }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidChemistryLayerRemapState;
    if (fraction > 1) return error.InvalidChemistryLayerRemapState;
    const source_amount = source * source_scale + source_pending_mol;
    const destination_amount = destination * destination_scale + destination_pending_mol;
    const moved = fraction * source_amount;
    const next_source_amount = source_amount - moved;
    const next_destination_amount = destination_amount + moved;
    inline for (.{ source_amount, destination_amount, moved, next_source_amount, next_destination_amount }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidChemistryLayerRemapState;
    const source_concentration = if (source_scale_after > 0) next_source_amount / source_scale_after else 0;
    const destination_concentration = if (destination_scale_after > 0) next_destination_amount / destination_scale_after else 0;
    if (!std.math.isFinite(source_concentration) or !std.math.isFinite(destination_concentration))
        return error.InvalidChemistryLayerRemapState;
    return .{
        .source_concentration = source_concentration,
        .destination_concentration = destination_concentration,
        .source_pending_mol = if (source_scale_after > 0) 0 else next_source_amount,
        .destination_pending_mol = if (destination_scale_after > 0) 0 else next_destination_amount,
    };
}

fn concentration(amount: f64, carrier: f64) !f64 {
    if (carrier > 0) return amount / carrier;
    if (amount == 0) return 0;
    // A concentration scalar cannot also safely encode an untagged extensive
    // amount. Fail the transaction so the hourly rollback/substep recovery can
    // retry before any carrier reaches zero with retained inventory.
    return error.ChemistryLayerRemapRequiresNonzeroCarrier;
}

fn isPondedPhosphateField(comptime name: []const u8) bool {
    @setEvalBranchQuota(10_000);
    return std.mem.endsWith(u8, name, "_per_megagram") or std.mem.indexOf(u8, name, "_solid_mol_per_m3") != null;
}

fn isAqueousPhosphateField(comptime name: []const u8) bool {
    @setEvalBranchQuota(10_000);
    return std.mem.startsWith(u8, name, "dissolved_") or std.mem.indexOf(u8, name, "_pair_") != null;
}

fn isBaseAqueousPhosphateField(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "dissolved_hpo4_mol_p_per_m3") or std.mem.eql(u8, name, "dissolved_h2po4_mol_p_per_m3");
}

fn isBasePondedAqueousField(comptime name: []const u8) bool {
    @setEvalBranchQuota(10_000);
    if (std.mem.startsWith(u8, name, "ammonium_") or std.mem.startsWith(u8, name, "ammonia_") or std.mem.startsWith(u8, name, "nitrate_")) return true;
    if (std.mem.eql(u8, name, "hydrogen") or std.mem.eql(u8, name, "hydroxide") or std.mem.eql(u8, name, "aluminum") or std.mem.eql(u8, name, "iron") or std.mem.eql(u8, name, "calcium") or std.mem.eql(u8, name, "magnesium") or std.mem.eql(u8, name, "sodium") or std.mem.eql(u8, name, "potassium")) return true;
    return false;
}

test "REDIST pond chemistry conserves zero-carrier pending owners and excludes bands" {
    var state = try chemistry_module.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.pending_cation_exchange_mol[0].ammonium_non_band = 8;
    state.pending_cation_exchange_mol[0].ammonium_band = 16;
    state.pending_cation_exchange_mol[0].hydrogen = 4;
    state.pending_non_band_phosphate_mol[0].adsorbed_hpo4_mol_p_per_megagram = 12;
    state.pending_band_phosphate_mol[0].adsorbed_hpo4_mol_p_per_megagram = 20;
    state.pending_geochemistry_solids_mol[0].calcite_solid_mol_per_m3 = 10;
    const zones: ZoneFractions = .{
        .ammonium_non_band = 0.5,
        .ammonium_band = 0.5,
        .nitrate_non_band = 0.5,
        .nitrate_band = 0.5,
        .phosphate_non_band = 0.5,
        .phosphate_band = 0.5,
    };
    try transferPondParticulateLayerFraction(&state, 0, 1, 0, 0, 0, 0, .{
        .source_before = zones,
        .destination_before = zones,
        .source_after = zones,
        .destination_after = zones,
    }, 0, 0, 0.25);
    try std.testing.expectEqual(@as(f64, 6), state.pending_cation_exchange_mol[0].ammonium_non_band);
    try std.testing.expectEqual(@as(f64, 2), state.pending_cation_exchange_mol[1].ammonium_non_band);
    try std.testing.expectEqual(@as(f64, 3), state.pending_cation_exchange_mol[0].hydrogen);
    try std.testing.expectEqual(@as(f64, 1), state.pending_cation_exchange_mol[1].hydrogen);
    try std.testing.expectEqual(@as(f64, 9), state.pending_non_band_phosphate_mol[0].adsorbed_hpo4_mol_p_per_megagram);
    try std.testing.expectEqual(@as(f64, 3), state.pending_non_band_phosphate_mol[1].adsorbed_hpo4_mol_p_per_megagram);
    try std.testing.expectEqual(@as(f64, 7.5), state.pending_geochemistry_solids_mol[0].calcite_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 2.5), state.pending_geochemistry_solids_mol[1].calcite_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 16), state.pending_cation_exchange_mol[0].ammonium_band);
    try std.testing.expectEqual(@as(f64, 0), state.pending_cation_exchange_mol[1].ammonium_band);
    try std.testing.expectEqual(@as(f64, 20), state.pending_band_phosphate_mol[0].adsorbed_hpo4_mol_p_per_megagram);
    try std.testing.expectEqual(@as(f64, 0), state.pending_band_phosphate_mol[1].adsorbed_hpo4_mol_p_per_megagram);
}

fn aqueousFieldVolume(comptime name: []const u8, volumes: ZoneWaterVolumes) f64 {
    if (std.mem.startsWith(u8, name, "ammonium_non_band") or std.mem.startsWith(u8, name, "ammonia_non_band")) return volumes.ammonium_non_band_m3;
    if (std.mem.startsWith(u8, name, "ammonium_band") or std.mem.startsWith(u8, name, "ammonia_band")) return volumes.ammonium_band_m3;
    if (std.mem.startsWith(u8, name, "nitrate_non_band")) return volumes.nitrate_non_band_m3;
    if (std.mem.startsWith(u8, name, "nitrate_band")) return volumes.nitrate_band_m3;
    return volumes.shared_m3;
}

fn validateZoneWater(volumes: ZoneWaterVolumes) !void {
    inline for (@typeInfo(ZoneWaterVolumes).@"struct".fields) |field| {
        const value = @field(volumes, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidChemistryLayerRemapInput;
    }
}

test "REDIST solid chemistry remap conserves native amounts across unequal layer bases" {
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 2);
    defer chemistry.deinit();
    chemistry.cation_exchange_mol_per_megagram[0].calcium = 2;
    chemistry.carboxyl_bound_hydrogen_mol_per_megagram[0] = 3;
    chemistry.non_band_phosphate[0].adsorbed_hpo4_mol_p_per_megagram = 4;
    chemistry.band_phosphate[0].aluminum_phosphate_solid_mol_per_m3 = 5;
    chemistry.geochemistry_solids[0].potassium_ground_silicate_mol_per_m3 = 6;
    try transferSolidLayerFraction(&chemistry, 0, 1, 10, 20, 2, 4, equal_zone_transition, 10, 20, 2, 4, 0.25);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), chemistry.cation_exchange_mol_per_megagram[0].calcium, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), chemistry.cation_exchange_mol_per_megagram[1].calcium, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), chemistry.non_band_phosphate[1].adsorbed_hpo4_mol_p_per_megagram, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.625), chemistry.band_phosphate[1].aluminum_phosphate_solid_mol_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), chemistry.geochemistry_solids[1].potassium_ground_silicate_mol_per_m3, 1e-14);
}

test "REDIST solid chemistry conserves zoned inventory while creating recipient bands" {
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 2);
    defer chemistry.deinit();
    chemistry.cation_exchange_mol_per_megagram[0].ammonium_non_band = 8;
    chemistry.cation_exchange_mol_per_megagram[0].ammonium_band = 4;
    chemistry.cation_exchange_mol_per_megagram[1].ammonium_non_band = 2;
    chemistry.non_band_phosphate[0].adsorbed_hpo4_mol_p_per_megagram = 5;
    chemistry.non_band_phosphate[1].adsorbed_hpo4_mol_p_per_megagram = 1;
    chemistry.band_phosphate[0].aluminum_phosphate_solid_mol_per_m3 = 6;
    const source_before: ZoneFractions = .{ .ammonium_non_band = 0.8, .ammonium_band = 0.2, .nitrate_non_band = 0.8, .nitrate_band = 0.2, .phosphate_non_band = 0.8, .phosphate_band = 0.2 };
    const destination_before: ZoneFractions = .{ .ammonium_non_band = 1, .ammonium_band = 0, .nitrate_non_band = 1, .nitrate_band = 0, .phosphate_non_band = 1, .phosphate_band = 0 };
    const source_after: ZoneFractions = .{ .ammonium_non_band = 0.6, .ammonium_band = 0.4, .nitrate_non_band = 0.6, .nitrate_band = 0.4, .phosphate_non_band = 0.6, .phosphate_band = 0.4 };
    const destination_after: ZoneFractions = .{ .ammonium_non_band = 0.7, .ammonium_band = 0.3, .nitrate_non_band = 0.7, .nitrate_band = 0.3, .phosphate_non_band = 0.7, .phosphate_band = 0.3 };
    const nitrogen_before = 10 * (0.8 * 8 + 0.2 * 4) + 20 * 2;
    const phosphorus_before = 10 * 0.8 * 5 + 20 * 1 + 2 * 0.2 * 6;

    try transferSolidLayerFraction(
        &chemistry,
        0,
        1,
        10,
        20,
        2,
        4,
        .{
            .source_before = source_before,
            .destination_before = destination_before,
            .source_after = source_after,
            .destination_after = destination_after,
        },
        7.5,
        22.5,
        1.5,
        4.5,
        0.25,
    );
    const source_exchange = chemistry.cation_exchange_mol_per_megagram[0];
    const destination_exchange = chemistry.cation_exchange_mol_per_megagram[1];
    const nitrogen_after = 7.5 * (0.6 * source_exchange.ammonium_non_band + 0.4 * source_exchange.ammonium_band) +
        22.5 * (0.7 * destination_exchange.ammonium_non_band + 0.3 * destination_exchange.ammonium_band);
    const phosphorus_after =
        7.5 * 0.6 * chemistry.non_band_phosphate[0].adsorbed_hpo4_mol_p_per_megagram +
        22.5 * 0.7 * chemistry.non_band_phosphate[1].adsorbed_hpo4_mol_p_per_megagram +
        1.5 * 0.4 * chemistry.band_phosphate[0].aluminum_phosphate_solid_mol_per_m3 +
        4.5 * 0.3 * chemistry.band_phosphate[1].aluminum_phosphate_solid_mol_per_m3;
    try std.testing.expectApproxEqAbs(nitrogen_before, nitrogen_after, 1e-12);
    try std.testing.expectApproxEqAbs(phosphorus_before, phosphorus_after, 1e-12);
    try std.testing.expect(chemistry.cation_exchange_mol_per_megagram[1].ammonium_band > 0);
    try std.testing.expect(chemistry.band_phosphate[1].aluminum_phosphate_solid_mol_per_m3 > 0);
}

test "REDIST solid chemistry retains water-based amounts for a dry recipient" {
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 2);
    defer chemistry.deinit();
    chemistry.cation_exchange_mol_per_megagram[0].calcium = 2;
    chemistry.geochemistry_solids[0].calcite_solid_mol_per_m3 = 3;
    try transferSolidLayerFraction(&chemistry, 0, 1, 10, 10, 1, 0, equal_zone_transition, 10, 10, 1, 0, 0.5);
    try std.testing.expectEqual(@as(f64, 1), chemistry.cation_exchange_mol_per_megagram[0].calcium);
    try std.testing.expectEqual(@as(f64, 1), chemistry.cation_exchange_mol_per_megagram[1].calcium);
    try std.testing.expectEqual(@as(f64, 1.5), chemistry.geochemistry_solids[0].calcite_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0), chemistry.geochemistry_solids[1].calcite_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 1.5), chemistry.pending_geochemistry_solids_mol[1].calcite_solid_mol_per_m3);
}

test "REDIST solid chemistry refills a zero-mass recipient" {
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 2);
    defer chemistry.deinit();
    chemistry.cation_exchange_mol_per_megagram[0].calcium = 2;
    try transferSolidLayerFraction(&chemistry, 0, 1, 10, 0, 1, 0, equal_zone_transition, 7.5, 2.5, 0.75, 0.25, 0.25);
    try std.testing.expectApproxEqAbs(@as(f64, 2), chemistry.cation_exchange_mol_per_megagram[0].calcium, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2), chemistry.cation_exchange_mol_per_megagram[1].calcium, 1e-14);
}

test "REDIST full downward retained solids survive carrier loss and rematerialize" {
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 2);
    defer chemistry.deinit();
    chemistry.cation_exchange_mol_per_megagram[0].calcium = 2;
    chemistry.non_band_phosphate[0].adsorbed_hpo4_mol_p_per_megagram = 4;
    chemistry.band_phosphate[0].aluminum_phosphate_solid_mol_per_m3 = 3;
    chemistry.geochemistry_solids[0].calcite_solid_mol_per_m3 = 5;

    try transferSolidLayerFraction(&chemistry, 0, 1, 10, 20, 2, 4, equal_zone_transition, 0, 30, 0, 6, 0);
    try std.testing.expectEqual(@as(f64, 0), chemistry.cation_exchange_mol_per_megagram[0].calcium);
    try std.testing.expectEqual(@as(f64, 20), chemistry.pending_cation_exchange_mol[0].calcium);
    try std.testing.expectEqual(@as(f64, 20), chemistry.pending_non_band_phosphate_mol[0].adsorbed_hpo4_mol_p_per_megagram);
    try std.testing.expectEqual(@as(f64, 3), chemistry.pending_band_phosphate_mol[0].aluminum_phosphate_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 10), chemistry.pending_geochemistry_solids_mol[0].calcite_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0), chemistry.cation_exchange_mol_per_megagram[1].calcium);
    try std.testing.expectEqual(@as(f64, 0), chemistry.geochemistry_solids[1].calcite_solid_mol_per_m3);

    try chemistry.materializePendingSolids(0, 10, 2, equal_zone_fractions);
    try std.testing.expectEqual(@as(f64, 2), chemistry.cation_exchange_mol_per_megagram[0].calcium);
    try std.testing.expectEqual(@as(f64, 4), chemistry.non_band_phosphate[0].adsorbed_hpo4_mol_p_per_megagram);
    try std.testing.expectEqual(@as(f64, 3), chemistry.band_phosphate[0].aluminum_phosphate_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 5), chemistry.geochemistry_solids[0].calcite_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0), chemistry.pending_cation_exchange_mol[0].calcium);
    try std.testing.expectEqual(@as(f64, 0), chemistry.pending_geochemistry_solids_mol[0].calcite_solid_mol_per_m3);
}

test "REDIST aqueous chemistry respects independent runtime band carriers" {
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 2);
    defer chemistry.deinit();
    chemistry.aqueous[0].calcium = 4;
    chemistry.aqueous[0].ammonium_band = 8;
    chemistry.aqueous[0].nitrate_band = 10;
    chemistry.water_mol_per_m3[0] = 16;
    chemistry.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 12;
    chemistry.band_phosphate[0].dissolved_hpo4_mol_p_per_m3 = 14;
    const source: ZoneWaterVolumes = .{ .shared_m3 = 2, .ammonium_non_band_m3 = 2, .ammonium_band_m3 = 1, .nitrate_non_band_m3 = 2, .nitrate_band_m3 = 1, .phosphate_non_band_m3 = 2, .phosphate_band_m3 = 1 };
    const destination: ZoneWaterVolumes = .{ .shared_m3 = 4, .ammonium_non_band_m3 = 4, .ammonium_band_m3 = 2, .nitrate_non_band_m3 = 4, .nitrate_band_m3 = 0, .phosphate_non_band_m3 = 4, .phosphate_band_m3 = 2 };
    try transferAqueousLayerFraction(&chemistry, 0, 1, source, destination, source, destination, true, 0.25);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), chemistry.aqueous[1].calcium, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1), chemistry.aqueous[1].ammonium_band, 1e-14);
    try std.testing.expectEqual(@as(f64, 10), chemistry.aqueous[0].nitrate_band);
    try std.testing.expectEqual(@as(f64, 0), chemistry.aqueous[1].nitrate_band);
    try std.testing.expectApproxEqAbs(
        @as(f64, 12),
        chemistry.water_mol_per_m3[0],
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 2),
        chemistry.water_mol_per_m3[1],
        1e-14,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), chemistry.non_band_phosphate[1].dissolved_h2po4_mol_p_per_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.75), chemistry.band_phosphate[1].dissolved_hpo4_mol_p_per_m3, 1e-14);
}

test "REDIST aqueous chemistry transfers into a newly created recipient band" {
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 2);
    defer chemistry.deinit();
    chemistry.aqueous[0].ammonium_band = 8;
    const source_before: ZoneWaterVolumes = .{ .shared_m3 = 2, .ammonium_non_band_m3 = 1, .ammonium_band_m3 = 1, .nitrate_non_band_m3 = 2, .nitrate_band_m3 = 0, .phosphate_non_band_m3 = 2, .phosphate_band_m3 = 0 };
    const destination_before: ZoneWaterVolumes = .{ .shared_m3 = 4, .ammonium_non_band_m3 = 4, .ammonium_band_m3 = 0, .nitrate_non_band_m3 = 4, .nitrate_band_m3 = 0, .phosphate_non_band_m3 = 4, .phosphate_band_m3 = 0 };
    const source_after: ZoneWaterVolumes = .{ .shared_m3 = 1.5, .ammonium_non_band_m3 = 0.9, .ammonium_band_m3 = 0.6, .nitrate_non_band_m3 = 1.5, .nitrate_band_m3 = 0, .phosphate_non_band_m3 = 1.5, .phosphate_band_m3 = 0 };
    const destination_after: ZoneWaterVolumes = .{ .shared_m3 = 4.5, .ammonium_non_band_m3 = 3.375, .ammonium_band_m3 = 1.125, .nitrate_non_band_m3 = 4.5, .nitrate_band_m3 = 0, .phosphate_non_band_m3 = 4.5, .phosphate_band_m3 = 0 };
    try transferAqueousLayerFraction(&chemistry, 0, 1, source_before, destination_before, source_after, destination_after, false, 0.25);
    const amount_after = chemistry.aqueous[0].ammonium_band * source_after.ammonium_band_m3 +
        chemistry.aqueous[1].ammonium_band * destination_after.ammonium_band_m3;
    try std.testing.expectApproxEqAbs(@as(f64, 8), amount_after, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 1.125), chemistry.aqueous[1].ammonium_band, 1e-14);
}

test "REDIST aqueous concentration uses pre-transfer amount and post-transfer carrier" {
    var chemistry = try chemistry_module.State.init(std.testing.allocator, 2);
    defer chemistry.deinit();
    chemistry.aqueous[0].calcium = 4;
    const source: ZoneWaterVolumes = .{ .shared_m3 = 2, .ammonium_non_band_m3 = 2, .ammonium_band_m3 = 0, .nitrate_non_band_m3 = 2, .nitrate_band_m3 = 0, .phosphate_non_band_m3 = 2, .phosphate_band_m3 = 0 };
    const destination: ZoneWaterVolumes = .{ .shared_m3 = 4, .ammonium_non_band_m3 = 4, .ammonium_band_m3 = 0, .nitrate_non_band_m3 = 4, .nitrate_band_m3 = 0, .phosphate_non_band_m3 = 4, .phosphate_band_m3 = 0 };
    const source_after: ZoneWaterVolumes = .{ .shared_m3 = 1.5, .ammonium_non_band_m3 = 1.5, .ammonium_band_m3 = 0, .nitrate_non_band_m3 = 1.5, .nitrate_band_m3 = 0, .phosphate_non_band_m3 = 1.5, .phosphate_band_m3 = 0 };
    const destination_after: ZoneWaterVolumes = .{ .shared_m3 = 4.5, .ammonium_non_band_m3 = 4.5, .ammonium_band_m3 = 0, .nitrate_non_band_m3 = 4.5, .nitrate_band_m3 = 0, .phosphate_non_band_m3 = 4.5, .phosphate_band_m3 = 0 };
    try transferAqueousLayerFraction(&chemistry, 0, 1, source, destination, source_after, destination_after, false, 0.25);
    try std.testing.expectApproxEqAbs(@as(f64, 4), chemistry.aqueous[0].calcium, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 4.5), chemistry.aqueous[1].calcium, 1e-14);
}

test "issue-063: transferSolidLayerFraction manufactures fake mass with a raw near-zero carrier but conserves mass when the caller floors it first" {
    // Reproduces the hour-2,894 mechanism
    // (`audit/issues/issue-063-relayering-activity-carbon-dioxide-carbon-mismatch-hour-2894.md`):
    // `relayering.zig` previously passed this call's water-carrier arguments
    // RAW (guarded only by `transferOwnedAmount`'s bare `scale_after > 0`
    // check), while `landscape_mass_inventory_phosphorus_ions.zig`'s census
    // always reads the resulting concentration back through the FLOORED
    // `aqueousCarrierM3`/`legacyNegligibleWaterVolumeM3` substitution. A
    // degenerate recipient carrier (at or below `ZEROS2`, nonzero) therefore
    // inflates the stored concentration, and the census re-multiplies that
    // inflated value by the much larger substituted reference volume --
    // manufacturing mass with no physical process or bookkeeping error in
    // either endpoint alone. `relayering.zig`'s fix floors all four carrier
    // arguments the same way before calling this function; this test proves
    // the underlying arithmetic is sound either way -- the caller's carrier
    // choice is what determines whether the result is legacy-consistent.
    const dry_reference_water_m3: f64 = 0.5;
    const negligible_water_volume_m3 = 1.0e-6; // ZEROS2 for a 1 m^2 cell.
    const raw_recipient_water_m3: f64 = 1.0e-9; // below the floor, nonzero.

    // Census-style reader: always uses the floored carrier, exactly like
    // `landscape_mass_inventory_phosphorus_ions.zig`'s private `aqueousCarrierM3`.
    const censusCarrier = struct {
        fn call(live_water_m3: f64) f64 {
            return if (live_water_m3 > negligible_water_volume_m3) live_water_m3 else dry_reference_water_m3;
        }
    }.call;

    // --- OLD (pre-fix relayering.zig) caller behavior: raw, unfloored carrier passed straight through. ---
    {
        var chemistry = try chemistry_module.State.init(std.testing.allocator, 2);
        defer chemistry.deinit();
        chemistry.geochemistry_solids[0].calcite_solid_mol_per_m3 = 100;
        chemistry.geochemistry_solids[1].calcite_solid_mol_per_m3 = 0.2;

        const recipient_census_before = chemistry.geochemistry_solids[1].calcite_solid_mol_per_m3 *
            censusCarrier(raw_recipient_water_m3);

        try transferSolidLayerFraction(
            &chemistry,
            0,
            1,
            10,
            10,
            5.0,
            raw_recipient_water_m3,
            equal_zone_transition,
            10,
            10,
            5.0,
            raw_recipient_water_m3,
            0.001,
        );

        const recipient_census_after = chemistry.geochemistry_solids[1].calcite_solid_mol_per_m3 *
            censusCarrier(raw_recipient_water_m3);
        const manufactured = recipient_census_after - recipient_census_before;
        // The real transferred amount is 0.001 * (100 * 5.0) = 0.5 mol. The
        // unfloored write manufactures roughly (dry_reference/raw) times
        // that -- many orders of magnitude of fake mass, matching hour
        // 2,894's shape (recipient gain far exceeding the donor's loss).
        try std.testing.expect(manufactured > 1000 * 0.5);
    }

    // --- NEW (fixed relayering.zig) caller behavior: floors the carrier the same way the census does. ---
    {
        var chemistry = try chemistry_module.State.init(std.testing.allocator, 2);
        defer chemistry.deinit();
        chemistry.geochemistry_solids[0].calcite_solid_mol_per_m3 = 100;
        chemistry.geochemistry_solids[1].calcite_solid_mol_per_m3 = 0.2;

        const floored_recipient_water_m3 = censusCarrier(raw_recipient_water_m3);
        const recipient_census_before = chemistry.geochemistry_solids[1].calcite_solid_mol_per_m3 *
            censusCarrier(raw_recipient_water_m3);

        try transferSolidLayerFraction(
            &chemistry,
            0,
            1,
            10,
            10,
            5.0,
            floored_recipient_water_m3,
            equal_zone_transition,
            10,
            10,
            5.0,
            floored_recipient_water_m3,
            0.001,
        );

        const recipient_census_after = chemistry.geochemistry_solids[1].calcite_solid_mol_per_m3 *
            censusCarrier(raw_recipient_water_m3);
        const conserved = recipient_census_after - recipient_census_before;
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), conserved, 1e-9);
    }
}
