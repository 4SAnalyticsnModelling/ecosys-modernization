const std = @import("std");
const snow = @import("../solute/snow_solute_transport.zig");
const gas = @import("../gas/transport.zig");
const litter = @import("../../surface/litter_chemistry.zig");
const chemistry = @import("../solute/chemistry_state.zig");
const transport = @import("../solute/transport.zig");
const mineral_nitrogen = @import("../biogeochemistry/mineral_nitrogen_transport.zig");
const surface_routing = @import("../solute/surface_solute_routing.zig");
const transport_species = @import("../solute/transport_species.zig");
const charge_classification = @import("../solute/charge_classification.zig");
const fertilizer_band_state = @import("../../management/fertilizer_band_state.zig");

pub const Inputs = struct {
    discharge: []const snow.SurfaceDischarge,
    litter_water_volume_m3: []const f64,
    topsoil_water_volume_m3: []const f64,
    soil_layer_capacity: usize,
    nitrogen_molar_mass_g_per_mol: f64,
    phosphorus_molar_mass_g_per_mol: f64,
    ion_molar_mass_g_per_mol: IonMolarMassesGPerMol,
    surface_aqueous: *surface_routing.State,
    /// Amount-based soil owners that receive snowmelt solutes in production.
    /// The concentration-backed chemistry state remains their reaction mirror.
    /// Optional only for focused litter-only compatibility tests.
    soil_transport_owners: ?SoilTransportOwners = null,
    fertilizer_band: ?*const fertilizer_band_state.State = null,
    ammonium_non_band_fraction: f64 = 1,
    ammonium_band_fraction: f64 = 0,
    nitrate_non_band_fraction: f64 = 1,
    nitrate_band_fraction: f64 = 0,
    phosphate_non_band_fraction: f64 = 1,
    phosphate_band_fraction: f64 = 0,
};

pub const SoilTransportOwners = struct {
    aqueous: *transport.State,
    mineral_nitrogen: *mineral_nitrogen.State,
};

pub const IonMolarMassesGPerMol = struct {
    aluminum: f64,
    iron: f64,
    calcium: f64,
    magnesium: f64,
    sodium: f64,
    potassium: f64,
    sulfur: f64,
    chloride: f64,
};

/// Conservatively receives TRNSFR snow discharge into the authoritative
/// litter and topsoil gas/mineral pools. When disappearance leaves no liquid
/// carrier, its representation-only water-equivalent reference preserves the
/// exact extensive litter aqueous inventory across the frozen/dry interval.
/// All destinations publish together.
pub fn state_update(allocator: std.mem.Allocator, inputs: Inputs, litter_gas: *gas.State, soil_gas: *gas.State, litter_chemistry: *litter.State, soil_chemistry: *chemistry.State) !void {
    const cells = inputs.discharge.len;
    if (cells == 0 or inputs.litter_water_volume_m3.len != cells or inputs.soil_layer_capacity == 0 or litter_gas.cell_count != cells or litter_chemistry.cells.len != cells or litter_chemistry.dry_reference_water_m3.len != cells or soil_gas.cell_count != soil_chemistry.cell_count or soil_chemistry.cell_count != cells * inputs.soil_layer_capacity or inputs.topsoil_water_volume_m3.len != soil_chemistry.cell_count or inputs.surface_aqueous.columns * inputs.surface_aqueous.rows != cells or inputs.surface_aqueous.species_count != transport_species.AqueousSpecies.count) return error.SnowDischargeDimensionMismatch;
    if (inputs.soil_transport_owners) |owners| {
        if (owners.aqueous.cell_count != soil_chemistry.cell_count or
            owners.aqueous.species_count != transport_species.AqueousSpecies.count or
            owners.mineral_nitrogen.cell_count != soil_chemistry.cell_count or
            owners.mineral_nitrogen.matrix.cell_count != soil_chemistry.cell_count or
            owners.mineral_nitrogen.matrix.species_count != mineral_nitrogen.species_count)
            return error.SnowDischargeDimensionMismatch;
    }
    for (0..cells) |cell| _ = try zoneFractions(inputs, cell);
    const staged_litter_gas = try allocator.dupe(f64, litter_gas.dissolved_mass_g);
    defer allocator.free(staged_litter_gas);
    const staged_soil_gas = try allocator.dupe(f64, soil_gas.dissolved_mass_g);
    defer allocator.free(staged_soil_gas);
    const staged_litter = try allocator.dupe(litter.Cell, litter_chemistry.cells);
    defer allocator.free(staged_litter);
    const staged_dry_reference_water_m3 = try allocator.dupe(
        f64,
        litter_chemistry.dry_reference_water_m3,
    );
    defer allocator.free(staged_dry_reference_water_m3);
    const staged_aqueous = try allocator.dupe(@TypeOf(soil_chemistry.aqueous[0]), soil_chemistry.aqueous);
    defer allocator.free(staged_aqueous);
    const staged_non_band = try allocator.dupe(@TypeOf(soil_chemistry.non_band_phosphate[0]), soil_chemistry.non_band_phosphate);
    defer allocator.free(staged_non_band);
    const staged_band = try allocator.dupe(@TypeOf(soil_chemistry.band_phosphate[0]), soil_chemistry.band_phosphate);
    defer allocator.free(staged_band);
    const staged_surface_aqueous = try allocator.dupe(f64, inputs.surface_aqueous.amount_mol);
    defer allocator.free(staged_surface_aqueous);
    const staged_soil_aqueous = if (inputs.soil_transport_owners) |owners|
        try allocator.dupe(f64, owners.aqueous.amount_mol)
    else
        try allocator.alloc(f64, 0);
    defer allocator.free(staged_soil_aqueous);
    const staged_soil_mineral_nitrogen = if (inputs.soil_transport_owners) |owners|
        try allocator.dupe(f64, owners.mineral_nitrogen.matrix.amount_mol)
    else
        try allocator.alloc(f64, 0);
    defer allocator.free(staged_soil_mineral_nitrogen);

    for (0..cells) |cell| {
        const fractions = try zoneFractions(inputs, cell);
        const litter_water = inputs.litter_water_volume_m3[cell];
        const topsoil = cell * inputs.soil_layer_capacity;
        const soil_water = inputs.topsoil_water_volume_m3[topsoil];
        if (!std.math.isFinite(litter_water) or litter_water < 0 or !std.math.isFinite(soil_water) or soil_water < 0) return error.InvalidSnowDischargeWaterVolume;
        const dry_carrier_increment_m3 =
            inputs.discharge[cell].litter_dry_reference_carrier_m3;
        if (!std.math.isFinite(dry_carrier_increment_m3) or
            dry_carrier_increment_m3 < 0)
            return error.InvalidSnowDischargeDryReferenceCarrier;
        var needs_litter_aqueous_carrier = false;
        for (5..snow.species_count) |species|
            needs_litter_aqueous_carrier = needs_litter_aqueous_carrier or
                inputs.discharge[cell].litter_g[species] > 0;
        for (0..12) |species|
            needs_litter_aqueous_carrier = needs_litter_aqueous_carrier or
                inputs.discharge[cell].litter_salt_mol[species] > 0;
        var litter_aqueous_carrier_m3 = litter_water;
        if (litter_water == 0 and needs_litter_aqueous_carrier) {
            const old_reference_m3 = staged_dry_reference_water_m3[cell];
            const new_reference_m3 = old_reference_m3 + dry_carrier_increment_m3;
            if (!std.math.isFinite(old_reference_m3) or old_reference_m3 < 0 or
                !std.math.isFinite(new_reference_m3) or new_reference_m3 <= 0)
                return error.SnowDischargeRequiresWater;
            if (old_reference_m3 == 0 and hasLitterAqueousInventory(staged_litter[cell]))
                return error.UnboundDryLitterChemistryInventory;
            try rescaleLitterAqueous(
                &staged_litter[cell],
                old_reference_m3 / new_reference_m3,
            );
            staged_dry_reference_water_m3[cell] = new_reference_m3;
            litter_aqueous_carrier_m3 = new_reference_m3;
        }
        for (0..snow.species_count) |species| {
            const litter_g = inputs.discharge[cell].litter_g[species];
            const non_band_g = inputs.discharge[cell].soil_nonband_g[species];
            const band_g = inputs.discharge[cell].soil_band_g[species];
            inline for (.{ litter_g, non_band_g, band_g }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowSurfaceDischarge;
            if (species < 5) {
                staged_litter_gas[cell * gas.species_count + species] += litter_g;
                staged_soil_gas[topsoil * gas.species_count + species] += non_band_g + band_g;
                continue;
            }
            if (non_band_g + band_g > 0 and soil_water <= 0) return error.SnowDischargeRequiresWater;
            const molar_mass = molarMass(
                inputs.nitrogen_molar_mass_g_per_mol,
                inputs.phosphorus_molar_mass_g_per_mol,
                inputs.ion_molar_mass_g_per_mol,
                species,
            );
            if (!std.math.isFinite(molar_mass) or molar_mass <= 0) return error.InvalidSnowDischargeMolarMass;
            const litter_mol_per_m3 = if (litter_aqueous_carrier_m3 > 0)
                litter_g / molar_mass / litter_aqueous_carrier_m3
            else
                0;
            const carrier_fractions = speciesCarrierFractions(
                @enumFromInt(species),
                fractions,
            );
            const non_band_carrier_m3 = soil_water * carrier_fractions.non_band;
            const band_carrier_m3 = soil_water * carrier_fractions.band;
            if ((non_band_g > 0 and non_band_carrier_m3 == 0) or (band_g > 0 and band_carrier_m3 == 0))
                return error.SnowDischargeRequiresWater;
            const non_band_mol_per_m3 = if (non_band_carrier_m3 > 0) non_band_g / molar_mass / non_band_carrier_m3 else 0;
            const band_mol_per_m3 = if (band_carrier_m3 > 0) band_g / molar_mass / band_carrier_m3 else 0;
            switch (@as(snow.Species, @enumFromInt(species))) {
                .ammonium_nitrogen => {
                    staged_litter[cell].ammonium_mol_per_m3 += litter_mol_per_m3;
                    staged_aqueous[topsoil].ammonium_non_band += non_band_mol_per_m3;
                    staged_aqueous[topsoil].ammonium_band += band_mol_per_m3;
                    if (inputs.soil_transport_owners != null) {
                        staged_soil_mineral_nitrogen[topsoil * mineral_nitrogen.species_count + @intFromEnum(mineral_nitrogen.Species.ammonium_non_band)] += non_band_g / inputs.nitrogen_molar_mass_g_per_mol;
                        staged_soil_mineral_nitrogen[topsoil * mineral_nitrogen.species_count + @intFromEnum(mineral_nitrogen.Species.ammonium_band)] += band_g / inputs.nitrogen_molar_mass_g_per_mol;
                    }
                },
                .ammonia_nitrogen => {
                    staged_litter[cell].ammonia_mol_per_m3 += litter_mol_per_m3;
                    staged_aqueous[topsoil].ammonia_non_band += non_band_mol_per_m3;
                    staged_aqueous[topsoil].ammonia_band += band_mol_per_m3;
                    if (inputs.soil_transport_owners != null) {
                        staged_soil_mineral_nitrogen[topsoil * mineral_nitrogen.species_count + @intFromEnum(mineral_nitrogen.Species.ammonia_non_band)] += non_band_g / inputs.nitrogen_molar_mass_g_per_mol;
                        staged_soil_mineral_nitrogen[topsoil * mineral_nitrogen.species_count + @intFromEnum(mineral_nitrogen.Species.ammonia_band)] += band_g / inputs.nitrogen_molar_mass_g_per_mol;
                    }
                },
                .nitrate_nitrogen => {
                    staged_litter[cell].nitrate_mol_per_m3 += litter_mol_per_m3;
                    staged_aqueous[topsoil].nitrate_non_band += non_band_mol_per_m3;
                    staged_aqueous[topsoil].nitrate_band += band_mol_per_m3;
                    if (inputs.soil_transport_owners != null) {
                        staged_soil_mineral_nitrogen[topsoil * mineral_nitrogen.species_count + @intFromEnum(mineral_nitrogen.Species.nitrate_non_band)] += non_band_g / inputs.nitrogen_molar_mass_g_per_mol;
                        staged_soil_mineral_nitrogen[topsoil * mineral_nitrogen.species_count + @intFromEnum(mineral_nitrogen.Species.nitrate_band)] += band_g / inputs.nitrogen_molar_mass_g_per_mol;
                    }
                },
                .hydrogen_phosphate_phosphorus => {
                    staged_litter[cell].hpo4_mol_p_per_m3 += litter_mol_per_m3;
                    staged_non_band[topsoil].dissolved_hpo4_mol_p_per_m3 += non_band_mol_per_m3;
                    staged_band[topsoil].dissolved_hpo4_mol_p_per_m3 += band_mol_per_m3;
                    if (inputs.soil_transport_owners != null) {
                        staged_soil_aqueous[topsoil * transport_species.AqueousSpecies.count + @intFromEnum(transport_species.AqueousSpecies.non_band_hpo4)] += non_band_g / inputs.phosphorus_molar_mass_g_per_mol;
                        staged_soil_aqueous[topsoil * transport_species.AqueousSpecies.count + @intFromEnum(transport_species.AqueousSpecies.band_hpo4)] += band_g / inputs.phosphorus_molar_mass_g_per_mol;
                    }
                },
                .dihydrogen_phosphate_phosphorus => {
                    staged_litter[cell].h2po4_mol_p_per_m3 += litter_mol_per_m3;
                    staged_non_band[topsoil].dissolved_h2po4_mol_p_per_m3 += non_band_mol_per_m3;
                    staged_band[topsoil].dissolved_h2po4_mol_p_per_m3 += band_mol_per_m3;
                    if (inputs.soil_transport_owners != null) {
                        staged_soil_aqueous[topsoil * transport_species.AqueousSpecies.count + @intFromEnum(transport_species.AqueousSpecies.non_band_h2po4)] += non_band_g / inputs.phosphorus_molar_mass_g_per_mol;
                        staged_soil_aqueous[topsoil * transport_species.AqueousSpecies.count + @intFromEnum(transport_species.AqueousSpecies.band_h2po4)] += band_g / inputs.phosphorus_molar_mass_g_per_mol;
                    }
                },
                .aluminum => {
                    staged_litter[cell].aluminum_mol_per_m3 += litter_mol_per_m3;
                    staged_aqueous[topsoil].aluminum += non_band_mol_per_m3 + band_mol_per_m3;
                    if (inputs.soil_transport_owners != null) staged_soil_aqueous[topsoil * transport_species.AqueousSpecies.count + @intFromEnum(transport_species.AqueousSpecies.aluminum)] += (non_band_g + band_g) / molar_mass;
                },
                .iron => {
                    staged_litter[cell].iron_mol_per_m3 += litter_mol_per_m3;
                    staged_aqueous[topsoil].iron += non_band_mol_per_m3 + band_mol_per_m3;
                    if (inputs.soil_transport_owners != null) staged_soil_aqueous[topsoil * transport_species.AqueousSpecies.count + @intFromEnum(transport_species.AqueousSpecies.iron)] += (non_band_g + band_g) / molar_mass;
                },
                .calcium => {
                    staged_litter[cell].calcium_mol_per_m3 += litter_mol_per_m3;
                    staged_aqueous[topsoil].calcium += non_band_mol_per_m3 + band_mol_per_m3;
                    if (inputs.soil_transport_owners != null) staged_soil_aqueous[topsoil * transport_species.AqueousSpecies.count + @intFromEnum(transport_species.AqueousSpecies.calcium)] += (non_band_g + band_g) / molar_mass;
                },
                .magnesium => {
                    staged_litter[cell].magnesium_mol_per_m3 += litter_mol_per_m3;
                    staged_aqueous[topsoil].magnesium += non_band_mol_per_m3 + band_mol_per_m3;
                    if (inputs.soil_transport_owners != null) staged_soil_aqueous[topsoil * transport_species.AqueousSpecies.count + @intFromEnum(transport_species.AqueousSpecies.magnesium)] += (non_band_g + band_g) / molar_mass;
                },
                .sodium => {
                    staged_litter[cell].sodium_mol_per_m3 += litter_mol_per_m3;
                    staged_aqueous[topsoil].sodium += non_band_mol_per_m3 + band_mol_per_m3;
                    if (inputs.soil_transport_owners != null) staged_soil_aqueous[topsoil * transport_species.AqueousSpecies.count + @intFromEnum(transport_species.AqueousSpecies.sodium)] += (non_band_g + band_g) / molar_mass;
                },
                .potassium => {
                    staged_litter[cell].potassium_mol_per_m3 += litter_mol_per_m3;
                    staged_aqueous[topsoil].potassium += non_band_mol_per_m3 + band_mol_per_m3;
                    if (inputs.soil_transport_owners != null) staged_soil_aqueous[topsoil * transport_species.AqueousSpecies.count + @intFromEnum(transport_species.AqueousSpecies.potassium)] += (non_band_g + band_g) / molar_mass;
                },
                .sulfate_sulfur => {
                    staged_litter[cell].sulfate_mol_per_m3 += litter_mol_per_m3;
                    staged_aqueous[topsoil].sulfate += non_band_mol_per_m3 + band_mol_per_m3;
                    if (inputs.soil_transport_owners != null) staged_soil_aqueous[topsoil * transport_species.AqueousSpecies.count + @intFromEnum(transport_species.AqueousSpecies.sulfate)] += (non_band_g + band_g) / molar_mass;
                },
                .chloride => {
                    staged_litter[cell].chloride_mol_per_m3 += litter_mol_per_m3;
                    staged_aqueous[topsoil].chloride += non_band_mol_per_m3 + band_mol_per_m3;
                    if (inputs.soil_transport_owners != null) staged_soil_aqueous[topsoil * transport_species.AqueousSpecies.count + @intFromEnum(transport_species.AqueousSpecies.chloride)] += (non_band_g + band_g) / molar_mass;
                },
                else => unreachable,
            }
        }
        for (0..snow.salt_species_count) |species| {
            const litter_mol = inputs.discharge[cell].litter_salt_mol[species];
            const non_band_mol = inputs.discharge[cell].soil_nonband_salt_mol[species];
            const band_mol = inputs.discharge[cell].soil_band_salt_mol[species];
            inline for (.{ litter_mol, non_band_mol, band_mol }) |value|
                if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowSurfaceDischarge;
            if (non_band_mol + band_mol > 0 and soil_water <= 0)
                return error.SnowDischargeRequiresWater;
            const litter_concentration = if (litter_aqueous_carrier_m3 > 0)
                litter_mol / litter_aqueous_carrier_m3
            else
                0;
            const salt_species: snow.SaltSpecies = @enumFromInt(species);
            const phosphate = species >= @intFromEnum(snow.SaltSpecies.phosphate);
            const non_band_carrier_m3 = soil_water * (if (phosphate) fractions.phosphate_non_band else 1);
            const band_carrier_m3 = soil_water * (if (phosphate) fractions.phosphate_band else 1);
            if ((non_band_mol > 0 and non_band_carrier_m3 == 0) or (band_mol > 0 and band_carrier_m3 == 0))
                return error.SnowDischargeRequiresWater;
            const non_band_concentration = if (non_band_carrier_m3 > 0) non_band_mol / non_band_carrier_m3 else 0;
            const band_concentration = if (band_carrier_m3 > 0) band_mol / band_carrier_m3 else 0;
            if (species < 12) {
                addLitterFreeSalt(&staged_litter[cell], salt_species, litter_concentration);
            } else {
                const surface_species = if (species < 33) species else species + 1;
                staged_surface_aqueous[cell * inputs.surface_aqueous.species_count + surface_species] += litter_mol;
            }
            addSoilSalt(&staged_aqueous[topsoil], &staged_non_band[topsoil], &staged_band[topsoil], salt_species, non_band_concentration, band_concentration);
            if (inputs.soil_transport_owners != null) {
                const non_band_species = snow.aqueousSpeciesForSalt(salt_species);
                staged_soil_aqueous[topsoil * transport_species.AqueousSpecies.count + @intFromEnum(non_band_species)] += non_band_mol;
                if (phosphate) {
                    const band_species: transport_species.AqueousSpecies = @enumFromInt(@intFromEnum(non_band_species) + 8);
                    staged_soil_aqueous[topsoil * transport_species.AqueousSpecies.count + @intFromEnum(band_species)] += band_mol;
                } else {
                    staged_soil_aqueous[topsoil * transport_species.AqueousSpecies.count + @intFromEnum(non_band_species)] += band_mol;
                }
            }
        }
    }
    inline for (.{ staged_litter_gas, staged_soil_gas, staged_surface_aqueous, staged_soil_aqueous, staged_soil_mineral_nitrogen, staged_dry_reference_water_m3 }) |values| for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowDischargeCandidate;
    for (staged_litter) |candidate| try validateCandidate(candidate);
    for (staged_aqueous) |candidate| try validateCandidate(candidate);
    for (staged_non_band) |candidate| try validateCandidate(candidate);
    for (staged_band) |candidate| try validateCandidate(candidate);
    @memcpy(litter_gas.dissolved_mass_g, staged_litter_gas);
    @memcpy(soil_gas.dissolved_mass_g, staged_soil_gas);
    @memcpy(litter_chemistry.cells, staged_litter);
    @memcpy(litter_chemistry.dry_reference_water_m3, staged_dry_reference_water_m3);
    @memcpy(soil_chemistry.aqueous, staged_aqueous);
    @memcpy(soil_chemistry.non_band_phosphate, staged_non_band);
    @memcpy(soil_chemistry.band_phosphate, staged_band);
    @memcpy(inputs.surface_aqueous.amount_mol, staged_surface_aqueous);
    if (inputs.soil_transport_owners) |owners| {
        @memcpy(owners.aqueous.amount_mol, staged_soil_aqueous);
        @memcpy(owners.mineral_nitrogen.matrix.amount_mol, staged_soil_mineral_nitrogen);
    }
}

const ZonePair = struct { non_band: f64, band: f64 };

fn speciesCarrierFractions(
    species: snow.Species,
    fractions: charge_classification.ZoneFractions,
) ZonePair {
    return switch (species) {
        .ammonium_nitrogen, .ammonia_nitrogen => .{
            .non_band = fractions.ammonium_non_band,
            .band = fractions.ammonium_band,
        },
        .nitrate_nitrogen => .{
            .non_band = fractions.nitrate_non_band,
            .band = fractions.nitrate_band,
        },
        .hydrogen_phosphate_phosphorus, .dihydrogen_phosphate_phosphorus => .{
            .non_band = fractions.phosphate_non_band,
            .band = fractions.phosphate_band,
        },
        else => .{ .non_band = 1, .band = 1 },
    };
}

fn zoneFractions(inputs: Inputs, cell: usize) !charge_classification.ZoneFractions {
    const fractions = if (inputs.fertilizer_band) |state|
        try state.scienceZoneFractions(cell, 0)
    else
        charge_classification.ZoneFractions{
            .ammonium_non_band = inputs.ammonium_non_band_fraction,
            .ammonium_band = inputs.ammonium_band_fraction,
            .nitrate_non_band = inputs.nitrate_non_band_fraction,
            .nitrate_band = inputs.nitrate_band_fraction,
            .phosphate_non_band = inputs.phosphate_non_band_fraction,
            .phosphate_band = inputs.phosphate_band_fraction,
        };
    inline for (@typeInfo(charge_classification.ZoneFractions).@"struct".fields) |field| {
        const value = @field(fractions, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidSnowDischargeZoneFraction;
    }
    inline for (.{
        fractions.ammonium_non_band + fractions.ammonium_band,
        fractions.nitrate_non_band + fractions.nitrate_band,
        fractions.phosphate_non_band + fractions.phosphate_band,
    }) |sum| if (@abs(sum - 1) > 32 * std.math.floatEps(f64) * @max(1.0, @abs(sum)))
        return error.InvalidSnowDischargeZoneFraction;
    return fractions;
}

fn hasLitterAqueousInventory(cell: litter.Cell) bool {
    inline for (@typeInfo(litter.Cell).@"struct".fields) |field| {
        if (comptime isLitterAqueousField(field.name, field.type))
            if (@field(cell, field.name) != 0) return true;
    }
    return false;
}

fn rescaleLitterAqueous(cell: *litter.Cell, scale: f64) !void {
    if (!std.math.isFinite(scale) or scale < 0)
        return error.InvalidSnowDischargeDryReferenceCarrier;
    inline for (@typeInfo(litter.Cell).@"struct".fields) |field| {
        if (comptime isLitterAqueousField(field.name, field.type)) {
            const value = @field(cell, field.name) * scale;
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidSnowDischargeCandidate;
            @field(cell, field.name) = value;
        }
    }
}

fn isLitterAqueousField(comptime name: []const u8, comptime Field: type) bool {
    return @typeInfo(Field) == .float and
        std.mem.indexOf(u8, name, "_mol") != null and
        std.mem.endsWith(u8, name, "_per_m3");
}

fn validateCandidate(value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .float => if (!std.math.isFinite(value) or value < 0) return error.InvalidSnowDischargeCandidate,
        .array => for (value) |item| try validateCandidate(item),
        .@"struct" => inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field|
            try validateCandidate(@field(value, field.name)),
        else => {},
    }
}

fn addLitterFreeSalt(cell: anytype, species: snow.SaltSpecies, amount_mol_per_m3: f64) void {
    switch (species) {
        .aluminum => cell.aluminum_mol_per_m3 += amount_mol_per_m3,
        .iron => cell.iron_mol_per_m3 += amount_mol_per_m3,
        .hydrogen => cell.hydrogen_mol_per_m3 += amount_mol_per_m3,
        .calcium => cell.calcium_mol_per_m3 += amount_mol_per_m3,
        .magnesium => cell.magnesium_mol_per_m3 += amount_mol_per_m3,
        .sodium => cell.sodium_mol_per_m3 += amount_mol_per_m3,
        .potassium => cell.potassium_mol_per_m3 += amount_mol_per_m3,
        .hydroxide => cell.hydroxide_mol_per_m3 += amount_mol_per_m3,
        .sulfate => cell.sulfate_mol_per_m3 += amount_mol_per_m3,
        .chloride => cell.chloride_mol_per_m3 += amount_mol_per_m3,
        .carbonate => cell.carbonate_mol_per_m3 += amount_mol_per_m3,
        .bicarbonate => cell.bicarbonate_mol_per_m3 += amount_mol_per_m3,
        else => unreachable,
    }
}

fn addSoilSalt(aqueous: anytype, non_band: anytype, band: anytype, species: snow.SaltSpecies, non_band_mol_per_m3: f64, band_mol_per_m3: f64) void {
    const shared = non_band_mol_per_m3 + band_mol_per_m3;
    switch (species) {
        .aluminum => aqueous.aluminum += shared,
        .iron => aqueous.iron += shared,
        .hydrogen => aqueous.hydrogen += shared,
        .calcium => aqueous.calcium += shared,
        .magnesium => aqueous.magnesium += shared,
        .sodium => aqueous.sodium += shared,
        .potassium => aqueous.potassium += shared,
        .hydroxide => aqueous.hydroxide += shared,
        .sulfate => aqueous.sulfate += shared,
        .chloride => aqueous.chloride += shared,
        .carbonate => aqueous.carbonate += shared,
        .bicarbonate => aqueous.bicarbonate += shared,
        .aluminum_monohydroxide => aqueous.aluminum_hydroxide_1 += shared,
        .aluminum_dihydroxide => aqueous.aluminum_hydroxide_2 += shared,
        .aluminum_trihydroxide => aqueous.aluminum_hydroxide_3 += shared,
        .aluminum_tetrahydroxide => aqueous.aluminum_hydroxide_4 += shared,
        .aluminum_sulfate => aqueous.aluminum_sulfate += shared,
        .iron_monohydroxide => aqueous.iron_hydroxide_1 += shared,
        .iron_dihydroxide => aqueous.iron_hydroxide_2 += shared,
        .iron_trihydroxide => aqueous.iron_hydroxide_3 += shared,
        .iron_tetrahydroxide => aqueous.iron_hydroxide_4 += shared,
        .iron_sulfate => aqueous.iron_sulfate += shared,
        .calcium_hydroxide => aqueous.calcium_hydroxide += shared,
        .calcium_carbonate => aqueous.calcium_carbonate += shared,
        .calcium_bicarbonate => aqueous.calcium_bicarbonate += shared,
        .calcium_sulfate => aqueous.calcium_sulfate += shared,
        .magnesium_hydroxide => aqueous.magnesium_hydroxide += shared,
        .magnesium_carbonate => aqueous.magnesium_carbonate += shared,
        .magnesium_bicarbonate => aqueous.magnesium_bicarbonate += shared,
        .magnesium_sulfate => aqueous.magnesium_sulfate += shared,
        .sodium_carbonate => aqueous.sodium_carbonate += shared,
        .sodium_sulfate => aqueous.sodium_sulfate += shared,
        .potassium_sulfate => aqueous.potassium_sulfate += shared,
        .phosphate => {
            non_band.dissolved_po4_mol_p_per_m3 += non_band_mol_per_m3;
            band.dissolved_po4_mol_p_per_m3 += band_mol_per_m3;
        },
        .phosphoric_acid => {
            non_band.dissolved_h3po4_mol_p_per_m3 += non_band_mol_per_m3;
            band.dissolved_h3po4_mol_p_per_m3 += band_mol_per_m3;
        },
        .iron_hydrogen_phosphate => {
            non_band.iron_hpo4_pair_mol_per_m3 += non_band_mol_per_m3;
            band.iron_hpo4_pair_mol_per_m3 += band_mol_per_m3;
        },
        .iron_dihydrogen_phosphate => {
            non_band.iron_h2po4_pair_mol_per_m3 += non_band_mol_per_m3;
            band.iron_h2po4_pair_mol_per_m3 += band_mol_per_m3;
        },
        .calcium_phosphate => {
            non_band.calcium_po4_pair_mol_per_m3 += non_band_mol_per_m3;
            band.calcium_po4_pair_mol_per_m3 += band_mol_per_m3;
        },
        .calcium_hydrogen_phosphate => {
            non_band.calcium_hpo4_pair_mol_per_m3 += non_band_mol_per_m3;
            band.calcium_hpo4_pair_mol_per_m3 += band_mol_per_m3;
        },
        .calcium_dihydrogen_phosphate => {
            non_band.calcium_h2po4_pair_mol_per_m3 += non_band_mol_per_m3;
            band.calcium_h2po4_pair_mol_per_m3 += band_mol_per_m3;
        },
        .magnesium_hydrogen_phosphate => {
            non_band.magnesium_hpo4_pair_mol_per_m3 += non_band_mol_per_m3;
            band.magnesium_hpo4_pair_mol_per_m3 += band_mol_per_m3;
        },
    }
}

fn molarMass(nitrogen: f64, phosphorus: f64, ions: IonMolarMassesGPerMol, species: usize) f64 {
    return switch (@as(snow.Species, @enumFromInt(species))) {
        .ammonium_nitrogen, .ammonia_nitrogen, .nitrate_nitrogen => nitrogen,
        .hydrogen_phosphate_phosphorus, .dihydrogen_phosphate_phosphorus => phosphorus,
        .aluminum => ions.aluminum,
        .iron => ions.iron,
        .calcium => ions.calcium,
        .magnesium => ions.magnesium,
        .sodium => ions.sodium,
        .potassium => ions.potassium,
        .sulfate_sulfur => ions.sulfur,
        .chloride => ions.chloride,
        else => unreachable,
    };
}

test "snow discharge conserves tracked gas nitrogen and phosphorus into runtime recipients" {
    var litter_gas = try gas.State.init(std.testing.allocator, 1);
    defer litter_gas.deinit();
    var soil_gas = try gas.State.init(std.testing.allocator, 2);
    defer soil_gas.deinit();
    var litter_chemistry = try litter.State.init(std.testing.allocator, 1);
    defer litter_chemistry.deinit();
    var soil_chemistry = try chemistry.State.init(std.testing.allocator, 2);
    defer soil_chemistry.deinit();
    var surface_aqueous = try surface_routing.State.init(std.testing.allocator, 1, 1, transport_species.AqueousSpecies.count);
    defer surface_aqueous.deinit();
    var soil_aqueous = try transport.State.init(std.testing.allocator, 2, transport_species.AqueousSpecies.count);
    defer soil_aqueous.deinit();
    var soil_mineral_nitrogen = try mineral_nitrogen.State.init(std.testing.allocator, 2);
    defer soil_mineral_nitrogen.deinit();
    var discharge = [_]snow.SurfaceDischarge{.{}};
    discharge[0].litter_g[@intFromEnum(snow.Species.carbon_dioxide_carbon)] = 2;
    discharge[0].soil_nonband_g[@intFromEnum(snow.Species.ammonium_nitrogen)] = 14;
    discharge[0].litter_g[@intFromEnum(snow.Species.hydrogen_phosphate_phosphorus)] = 31;
    discharge[0].soil_band_g[@intFromEnum(snow.Species.hydrogen_phosphate_phosphorus)] = 31;
    discharge[0].litter_g[@intFromEnum(snow.Species.dihydrogen_phosphate_phosphorus)] = 62;
    discharge[0].soil_nonband_g[@intFromEnum(snow.Species.dihydrogen_phosphate_phosphorus)] = 93;
    discharge[0].soil_nonband_g[@intFromEnum(snow.Species.calcium)] = 40;
    discharge[0].litter_salt_mol[@intFromEnum(snow.SaltSpecies.calcium_carbonate)] = 0.25;
    discharge[0].soil_nonband_salt_mol[@intFromEnum(snow.SaltSpecies.aluminum_sulfate)] = 0.5;
    discharge[0].litter_salt_mol[@intFromEnum(snow.SaltSpecies.phosphate)] = 4;
    discharge[0].soil_nonband_salt_mol[@intFromEnum(snow.SaltSpecies.phosphate)] = 5;
    discharge[0].soil_band_salt_mol[@intFromEnum(snow.SaltSpecies.phosphate)] = 6;
    discharge[0].litter_salt_mol[@intFromEnum(snow.SaltSpecies.phosphoric_acid)] = 7;
    discharge[0].soil_nonband_salt_mol[@intFromEnum(snow.SaltSpecies.phosphoric_acid)] = 8;
    discharge[0].soil_band_salt_mol[@intFromEnum(snow.SaltSpecies.phosphoric_acid)] = 9;
    discharge[0].soil_band_salt_mol[@intFromEnum(snow.SaltSpecies.magnesium_hydrogen_phosphate)] = 0.75;
    try state_update(std.testing.allocator, .{ .discharge = &discharge, .litter_water_volume_m3 = &.{1}, .topsoil_water_volume_m3 = &.{ 2, 0 }, .soil_layer_capacity = 2, .nitrogen_molar_mass_g_per_mol = 14, .phosphorus_molar_mass_g_per_mol = 31, .ion_molar_mass_g_per_mol = .{ .aluminum = 27, .iron = 55.8, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 }, .surface_aqueous = &surface_aqueous, .soil_transport_owners = .{ .aqueous = &soil_aqueous, .mineral_nitrogen = &soil_mineral_nitrogen }, .ammonium_non_band_fraction = 0.25, .ammonium_band_fraction = 0.75, .phosphate_non_band_fraction = 0.25, .phosphate_band_fraction = 0.75 }, &litter_gas, &soil_gas, &litter_chemistry, &soil_chemistry);
    try std.testing.expectEqual(@as(f64, 2), litter_gas.dissolved_mass_g[0]);
    try std.testing.expectEqual(@as(f64, 2), soil_chemistry.aqueous[0].ammonium_non_band);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), soil_chemistry.band_phosphate[0].dissolved_hpo4_mol_p_per_m3, 1e-15);
    try std.testing.expectEqual(@as(f64, 0.5), soil_chemistry.aqueous[0].calcium);
    try std.testing.expectEqual(@as(f64, 0.25), surface_aqueous.amount_mol[@intFromEnum(snow.SaltSpecies.calcium_carbonate)]);
    try std.testing.expectEqual(@as(f64, 0.25), soil_chemistry.aqueous[0].aluminum_sulfate);
    try std.testing.expectEqual(@as(f64, 0.5), soil_chemistry.band_phosphate[0].magnesium_hpo4_pair_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 1), litter_chemistry.cells[0].hpo4_mol_p_per_m3);
    try std.testing.expectEqual(@as(f64, 2), litter_chemistry.cells[0].h2po4_mol_p_per_m3);
    try std.testing.expectEqual(@as(f64, 4), surface_aqueous.amount_mol[34]);
    try std.testing.expectEqual(@as(f64, 7), surface_aqueous.amount_mol[35]);
    const soil_amounts = try soil_aqueous.cellAmountsConst(0);
    try std.testing.expectEqual(@as(f64, 1), soil_amounts[@intFromEnum(transport_species.AqueousSpecies.calcium)]);
    try std.testing.expectEqual(@as(f64, 0.5), soil_amounts[@intFromEnum(transport_species.AqueousSpecies.aluminum_sulfate)]);
    try std.testing.expectEqual(@as(f64, 3), soil_amounts[@intFromEnum(transport_species.AqueousSpecies.non_band_h2po4)]);
    try std.testing.expectEqual(@as(f64, 1), soil_amounts[@intFromEnum(transport_species.AqueousSpecies.band_hpo4)]);
    try std.testing.expectEqual(@as(f64, 5), soil_amounts[@intFromEnum(transport_species.AqueousSpecies.non_band_phosphate)]);
    try std.testing.expectEqual(@as(f64, 6), soil_amounts[@intFromEnum(transport_species.AqueousSpecies.band_phosphate)]);
    try std.testing.expectEqual(@as(f64, 0.75), soil_amounts[@intFromEnum(transport_species.AqueousSpecies.band_magnesium_hpo4)]);
    const soil_nitrogen = try soil_mineral_nitrogen.matrix.cellAmountsConst(0);
    try std.testing.expectEqual(@as(f64, 1), soil_nitrogen[@intFromEnum(mineral_nitrogen.Species.ammonium_non_band)]);

    // Four distinct phosphate states cross snow -> litter/topsoil exactly
    // once: mineral HPO4/H2PO4 remain in explicit chemistry owners while
    // extensive coordinates 34/35 carry PO4/H3PO4. Expand molecular formulas
    // to prove P, H, and O closure rather than merely coordinate equality.
    const expected_p_mol: f64 = 46.75;
    const observed_p_mol =
        litter_chemistry.cells[0].hpo4_mol_p_per_m3 +
        litter_chemistry.cells[0].h2po4_mol_p_per_m3 +
        surface_aqueous.amount_mol[34] + surface_aqueous.amount_mol[35] +
        0.5 * (soil_chemistry.non_band_phosphate[0].dissolved_hpo4_mol_p_per_m3 + soil_chemistry.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 +
            soil_chemistry.non_band_phosphate[0].dissolved_po4_mol_p_per_m3 + soil_chemistry.non_band_phosphate[0].dissolved_h3po4_mol_p_per_m3 +
            soil_chemistry.non_band_phosphate[0].magnesium_hpo4_pair_mol_per_m3) +
        1.5 * (soil_chemistry.band_phosphate[0].dissolved_hpo4_mol_p_per_m3 + soil_chemistry.band_phosphate[0].dissolved_h2po4_mol_p_per_m3 +
            soil_chemistry.band_phosphate[0].dissolved_po4_mol_p_per_m3 + soil_chemistry.band_phosphate[0].dissolved_h3po4_mol_p_per_m3 +
            soil_chemistry.band_phosphate[0].magnesium_hpo4_pair_mol_per_m3);
    const observed_h_mol =
        litter_chemistry.cells[0].hpo4_mol_p_per_m3 + 2 * litter_chemistry.cells[0].h2po4_mol_p_per_m3 +
        3 * surface_aqueous.amount_mol[35] +
        0.5 * (soil_chemistry.non_band_phosphate[0].dissolved_hpo4_mol_p_per_m3 +
            2 * soil_chemistry.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 +
            3 * soil_chemistry.non_band_phosphate[0].dissolved_h3po4_mol_p_per_m3 +
            soil_chemistry.non_band_phosphate[0].magnesium_hpo4_pair_mol_per_m3) +
        1.5 * (soil_chemistry.band_phosphate[0].dissolved_hpo4_mol_p_per_m3 +
            2 * soil_chemistry.band_phosphate[0].dissolved_h2po4_mol_p_per_m3 +
            3 * soil_chemistry.band_phosphate[0].dissolved_h3po4_mol_p_per_m3 +
            soil_chemistry.band_phosphate[0].magnesium_hpo4_pair_mol_per_m3);
    try std.testing.expectApproxEqAbs(expected_p_mol, observed_p_mol, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 84.75), observed_h_mol, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 187), 4 * observed_p_mol, 1e-14);
}

test "dry disappearance carrier conserves existing and incoming litter aqueous chemistry" {
    var litter_gas = try gas.State.init(std.testing.allocator, 1);
    defer litter_gas.deinit();
    var soil_gas = try gas.State.init(std.testing.allocator, 1);
    defer soil_gas.deinit();
    var litter_chemistry = try litter.State.init(std.testing.allocator, 1);
    defer litter_chemistry.deinit();
    var soil_chemistry = try chemistry.State.init(std.testing.allocator, 1);
    defer soil_chemistry.deinit();
    var surface_aqueous = try surface_routing.State.init(
        std.testing.allocator,
        1,
        1,
        transport_species.AqueousSpecies.count,
    );
    defer surface_aqueous.deinit();
    litter_chemistry.dry_reference_water_m3[0] = 2;
    litter_chemistry.cells[0].ammonium_mol_per_m3 = 3;
    litter_chemistry.cells[0].calcium_mol_per_m3 = 4;

    var discharge = [_]snow.SurfaceDischarge{.{}};
    discharge[0].litter_dry_reference_carrier_m3 = 3;
    discharge[0].litter_g[@intFromEnum(snow.Species.carbon_dioxide_carbon)] = 2;
    discharge[0].litter_g[@intFromEnum(snow.Species.ammonium_nitrogen)] = 14;
    discharge[0].litter_g[@intFromEnum(snow.Species.hydrogen_phosphate_phosphorus)] = 31;
    discharge[0].litter_salt_mol[@intFromEnum(snow.SaltSpecies.calcium)] = 5;
    discharge[0].litter_salt_mol[@intFromEnum(snow.SaltSpecies.calcium_carbonate)] = 7;
    try state_update(std.testing.allocator, .{
        .discharge = &discharge,
        .litter_water_volume_m3 = &.{0},
        .topsoil_water_volume_m3 = &.{0},
        .soil_layer_capacity = 1,
        .nitrogen_molar_mass_g_per_mol = 14,
        .phosphorus_molar_mass_g_per_mol = 31,
        .ion_molar_mass_g_per_mol = .{ .aluminum = 27, .iron = 55.8, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 },
        .surface_aqueous = &surface_aqueous,
    }, &litter_gas, &soil_gas, &litter_chemistry, &soil_chemistry);

    try std.testing.expectEqual(@as(f64, 5), litter_chemistry.dry_reference_water_m3[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0 / 5.0), litter_chemistry.cells[0].ammonium_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 13.0 / 5.0), litter_chemistry.cells[0].calcium_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 5.0), litter_chemistry.cells[0].hpo4_mol_p_per_m3, 1e-15);
    try std.testing.expectEqual(@as(f64, 2), litter_gas.dissolved_mass_g[0]);
    try std.testing.expectEqual(@as(f64, 7), surface_aqueous.amount_mol[@intFromEnum(transport_species.AqueousSpecies.calcium_carbonate)]);
    // Existing 6 mol N and 8 mol Ca plus exactly 1 and 5 mol respectively.
    try std.testing.expectApproxEqAbs(@as(f64, 7), litter_chemistry.cells[0].ammonium_mol_per_m3 * 5, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 13), litter_chemistry.cells[0].calcium_mol_per_m3 * 5, 1e-14);
}

test "missing dry disappearance carrier rolls back every discharge recipient" {
    var litter_gas = try gas.State.init(std.testing.allocator, 1);
    defer litter_gas.deinit();
    var soil_gas = try gas.State.init(std.testing.allocator, 1);
    defer soil_gas.deinit();
    var litter_chemistry = try litter.State.init(std.testing.allocator, 1);
    defer litter_chemistry.deinit();
    var soil_chemistry = try chemistry.State.init(std.testing.allocator, 1);
    defer soil_chemistry.deinit();
    var surface_aqueous = try surface_routing.State.init(
        std.testing.allocator,
        1,
        1,
        transport_species.AqueousSpecies.count,
    );
    defer surface_aqueous.deinit();
    litter_gas.dissolved_mass_g[0] = 3;
    var discharge = [_]snow.SurfaceDischarge{.{}};
    discharge[0].litter_g[@intFromEnum(snow.Species.carbon_dioxide_carbon)] = 2;
    discharge[0].litter_g[@intFromEnum(snow.Species.ammonium_nitrogen)] = 14;

    try std.testing.expectError(error.SnowDischargeRequiresWater, state_update(std.testing.allocator, .{
        .discharge = &discharge,
        .litter_water_volume_m3 = &.{0},
        .topsoil_water_volume_m3 = &.{0},
        .soil_layer_capacity = 1,
        .nitrogen_molar_mass_g_per_mol = 14,
        .phosphorus_molar_mass_g_per_mol = 31,
        .ion_molar_mass_g_per_mol = .{ .aluminum = 27, .iron = 55.8, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 },
        .surface_aqueous = &surface_aqueous,
    }, &litter_gas, &soil_gas, &litter_chemistry, &soil_chemistry));
    try std.testing.expectEqual(@as(f64, 3), litter_gas.dissolved_mass_g[0]);
    try std.testing.expectEqual(@as(f64, 0), litter_chemistry.cells[0].ammonium_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0), litter_chemistry.dry_reference_water_m3[0]);
}

test "late complex overflow rolls back every snow discharge recipient atomically" {
    var litter_gas = try gas.State.init(std.testing.allocator, 2);
    defer litter_gas.deinit();
    var soil_gas = try gas.State.init(std.testing.allocator, 2);
    defer soil_gas.deinit();
    var litter_chemistry = try litter.State.init(std.testing.allocator, 2);
    defer litter_chemistry.deinit();
    var soil_chemistry = try chemistry.State.init(std.testing.allocator, 2);
    defer soil_chemistry.deinit();
    var surface_aqueous = try surface_routing.State.init(std.testing.allocator, 2, 1, transport_species.AqueousSpecies.count);
    defer surface_aqueous.deinit();
    litter_gas.dissolved_mass_g[0] = 3;
    litter_chemistry.cells[0].hpo4_mol_p_per_m3 = 5;
    soil_chemistry.aqueous[0].calcium = 7;
    const complex = @intFromEnum(snow.SaltSpecies.aluminum_monohydroxide);
    surface_aqueous.amount_mol[transport_species.AqueousSpecies.count + complex] = std.math.floatMax(f64);
    var discharge = [_]snow.SurfaceDischarge{ .{}, .{} };
    discharge[0].litter_g[@intFromEnum(snow.Species.carbon_dioxide_carbon)] = 1;
    discharge[1].litter_salt_mol[complex] = std.math.floatMax(f64);
    const litter_gas_before = try std.testing.allocator.dupe(f64, litter_gas.dissolved_mass_g);
    defer std.testing.allocator.free(litter_gas_before);
    const litter_before = try std.testing.allocator.dupe(litter.Cell, litter_chemistry.cells);
    defer std.testing.allocator.free(litter_before);
    const aqueous_before = try std.testing.allocator.dupe(@TypeOf(soil_chemistry.aqueous[0]), soil_chemistry.aqueous);
    defer std.testing.allocator.free(aqueous_before);
    const surface_before = try std.testing.allocator.dupe(f64, surface_aqueous.amount_mol);
    defer std.testing.allocator.free(surface_before);

    try std.testing.expectError(error.InvalidSnowDischargeCandidate, state_update(std.testing.allocator, .{
        .discharge = &discharge,
        .litter_water_volume_m3 = &.{ 1, 1 },
        .topsoil_water_volume_m3 = &.{ 1, 1 },
        .soil_layer_capacity = 1,
        .nitrogen_molar_mass_g_per_mol = 14,
        .phosphorus_molar_mass_g_per_mol = 31,
        .ion_molar_mass_g_per_mol = .{ .aluminum = 27, .iron = 55.8, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 },
        .surface_aqueous = &surface_aqueous,
    }, &litter_gas, &soil_gas, &litter_chemistry, &soil_chemistry));
    try std.testing.expectEqualSlices(f64, litter_gas_before, litter_gas.dissolved_mass_g);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(litter_before), std.mem.sliceAsBytes(litter_chemistry.cells));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(aqueous_before), std.mem.sliceAsBytes(soil_chemistry.aqueous));
    try std.testing.expectEqualSlices(f64, surface_before, surface_aqueous.amount_mol);
}
