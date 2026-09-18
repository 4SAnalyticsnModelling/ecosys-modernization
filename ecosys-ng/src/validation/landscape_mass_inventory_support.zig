//! `landscape_mass_inventory` declarations: support.
//!
//! Split out of `landscape_mass_inventory.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const ice_units = @import("../core/ice_units.zig");
const surface_aqueous = @import("../surface/aqueous_runoff_transport.zig");
const snow = @import("../soil/solute/snow_solute_transport.zig");
const grid_module = @import("../state/grid.zig");
const gas = @import("../soil/gas/transport.zig");
const organic = @import("../soil/organic/initialization.zig");
const organic_transport = @import("../soil/organic/transport.zig");
const litter_chemistry = @import("../surface/litter_chemistry.zig");
const litter_fertilizer = @import("../surface/litter_fertilizer.zig");
const audit = @import("mass_balance_audit.zig");
const surface_precipitation = @import("../surface/precipitation.zig");
const canopy_retention = @import("../canopy/energy/precipitation_retention.zig");
const mineral_nitrogen = @import("../soil/biogeochemistry/mineral_nitrogen_transport.zig");
const nitrogen_fertilizer = @import("../management/fertilizer_nitrogen_inventory.zig");
const mineral_fertilizer = @import("../management/mineral_fertilizer_inventory.zig");
const soil_chemistry = @import("../soil/solute/chemistry_state.zig");
const solute_transport = @import("../soil/solute/transport.zig");
const solute_species = @import("../soil/solute/transport_species.zig");
const zone_classification = @import("../soil/solute/charge_classification.zig");
const plant_roots = @import("../plant/root/plant_root_system.zig");
const group_misc = @import("landscape_mass_inventory_misc.zig");
const group_snow = @import("landscape_mass_inventory_snow.zig");
const group_surface = @import("landscape_mass_inventory_surface.zig");

/// Authoritative storage side of the all-storage conservation equations.
/// Boundary additions/removals remain in their process-owned cumulative
/// ledgers and are combined by `mass_balance_audit`.
pub const Storage = struct {
    water_m3: f64 = 0,
    heat_megajoules: f64 = 0,
    // Failure-forensics partitions of `heat_megajoules`. They are populated
    // by the same range aggregators as the authoritative total, so the hourly
    // gate can identify a leaking storage owner without rerunning science.
    diagnostic_snow_heat_megajoules: f64 = 0,
    diagnostic_soil_heat_megajoules: f64 = 0,
    diagnostic_surface_heat_megajoules: f64 = 0,
    diagnostic_canopy_heat_megajoules: f64 = 0,
    diagnostic_surface_organic_carbon_g: f64 = 0,
    diagnostic_soil_gas_carbon_g: f64 = 0,
    diagnostic_surface_gas_carbon_g: f64 = 0,
    oxygen_g: f64 = 0,
    hydrogen_g: f64 = 0,
    residue_carbon_g: f64 = 0,
    organic_carbon_g: f64 = 0,
    carbon_dioxide_carbon_g: f64 = 0,
    /// Living/standing plant owners are kept separate from soil organic
    /// matter so the hourly cell gate can distinguish true plant storage
    /// from cumulative accounting diagnostics.
    plant_carbon_g: f64 = 0,
    plant_nitrogen_g: f64 = 0,
    plant_phosphorus_g: f64 = 0,
    residue_nitrogen_g: f64 = 0,
    organic_nitrogen_g: f64 = 0,
    dinitrogen_nitrogen_g: f64 = 0,
    ammonium_nitrogen_g: f64 = 0,
    nitrate_nitrogen_g: f64 = 0,
    residue_phosphorus_g: f64 = 0,
    organic_phosphorus_g: f64 = 0,
    phosphate_phosphorus_g: f64 = 0,
    /// Element-resolved ion/mineral inventory. These are chemical-element
    /// moles, not charge equivalents and not aggregate "ion atoms". Keeping
    /// them separate prevents a loss of one element from being hidden by a
    /// gain of another in `ion_inventory_mol`.
    aluminum_mol: f64 = 0,
    iron_mol: f64 = 0,
    calcium_mol: f64 = 0,
    magnesium_mol: f64 = 0,
    sodium_mol: f64 = 0,
    potassium_mol: f64 = 0,
    sulfur_mol: f64 = 0,
    chloride_mol: f64 = 0,
    silicon_mol: f64 = 0,
    /// Legacy aggregate diagnostic only. It is deliberately excluded from
    /// hourly conservation acceptance because unlike elements it is not
    /// invariant under association/dissociation.
    ion_inventory_mol: f64 = 0,
    sand_megagrams: f64 = 0,
    silt_megagrams: f64 = 0,
    clay_megagrams: f64 = 0,
    /// Sum of active-layer ROCK values. The translated REDIST equation moves
    /// this quantity additively, so this is intentionally not mass-weighted.
    rock_additive: f64 = 0,
    /// Extensive source HOUR1 exchange-site capacities. These are conserved
    /// material owners (except explicit charcoal creation), not ion species.
    cation_exchange_capacity_mol: f64 = 0,
    anion_exchange_capacity_mol: f64 = 0,

    pub fn add(self: *Storage, contribution: Storage) !void {
        inline for (std.meta.fields(Storage)) |field| {
            const value = @field(self, field.name) + @field(contribution, field.name);
            if (!std.math.isFinite(value)) return error.NonFiniteLandscapeInventory;
            @field(self, field.name) = value;
        }
    }

    pub fn validate(self: Storage) !void {
        inline for (std.meta.fields(Storage)) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value)) return error.NonFiniteLandscapeInventory;
            // `heat_megajoules` is an enthalpy measured against liquid water at
            // 0 K (HEAT-001 resolution A), so a sufficiently frozen carrier may
            // legitimately be negative. Every other field is a mass or volume
            // and must remain nonnegative.
            if (comptime !std.mem.eql(u8, field.name, "heat_megajoules") and
                !std.mem.endsWith(u8, field.name, "_heat_megajoules"))
                if (value < 0) return error.NegativeLandscapeInventory;
        }
    }
};

pub const ElementMoles = struct {
    aluminum: f64 = 0,
    iron: f64 = 0,
    calcium: f64 = 0,
    magnesium: f64 = 0,
    sodium: f64 = 0,
    potassium: f64 = 0,
    sulfur: f64 = 0,
    chloride: f64 = 0,
    silicon: f64 = 0,

    pub fn scaled(self: ElementMoles, amount_mol: f64) ElementMoles {
        var result = self;
        inline for (std.meta.fields(ElementMoles)) |field|
            @field(result, field.name) *= amount_mol;
        return result;
    }
};

/// Neumaier reduction for the nonnegative element inventories assembled from
/// many chemically distinct owners.  The accumulator changes only census
/// arithmetic: every scientific owner and stoichiometric coefficient is still
/// supplied by its existing caller.  Keeping the correction until the final
/// store prevents a small mobile-pool change from being repeatedly rounded
/// away while it is added to a much larger mineral stock.
pub const ElementMolesAccumulator = struct {
    sum: ElementMoles = .{},
    correction: ElementMoles = .{},

    pub fn add(self: *ElementMolesAccumulator, elements: ElementMoles) !void {
        inline for (std.meta.fields(ElementMoles)) |field| {
            const value = @field(elements, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidElementInventory;
            const previous = @field(self.sum, field.name);
            const next = previous + value;
            if (!std.math.isFinite(next)) return error.NonFiniteLandscapeInventory;
            const recovered = if (@abs(previous) >= @abs(value))
                (previous - next) + value
            else
                (value - next) + previous;
            const corrected = @field(self.correction, field.name) + recovered;
            if (!std.math.isFinite(corrected)) return error.NonFiniteLandscapeInventory;
            @field(self.sum, field.name) = next;
            @field(self.correction, field.name) = corrected;
        }
    }

    pub fn finish(self: ElementMolesAccumulator) !ElementMoles {
        var result: ElementMoles = .{};
        inline for (std.meta.fields(ElementMoles)) |field| {
            const value = @field(self.sum, field.name) +
                @field(self.correction, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidElementInventory;
            @field(result, field.name) = value;
        }
        return result;
    }
};

pub fn addElementMoles(storage: *Storage, elements: ElementMoles) !void {
    inline for (std.meta.fields(ElementMoles)) |field| {
        const value = @field(elements, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidElementInventory;
        const storage_name = field.name ++ "_mol";
        const next = @field(storage, storage_name) + value;
        if (!std.math.isFinite(next)) return error.NonFiniteLandscapeInventory;
        @field(storage, storage_name) = next;
    }
}

test "element inventory accumulator retains small contributions beside mineral stocks" {
    var accumulator: ElementMolesAccumulator = .{};
    try accumulator.add(.{ .magnesium = 32 });
    try accumulator.add(.{ .magnesium = 2.0e-15 });
    try accumulator.add(.{ .magnesium = 2.0e-15 });
    const result = try accumulator.finish();
    try std.testing.expectEqual(@as(f64, 32.00000000000001), result.magnesium);
}

/// Chemical-element stoichiometry of one mole of an aqueous transport
/// species. The formula owner is shared with boundary runoff so the storage
/// census and external-flux ledger cannot silently drift to different
/// coefficients. C, N, P, O, and H remain in their dedicated balances.
pub fn aqueousSpeciesElements(species: solute_species.AqueousSpecies) ElementMoles {
    const components = surface_aqueous.formula(species);
    return .{
        .aluminum = components.aluminum_mol,
        .iron = components.iron_mol,
        .calcium = components.calcium_mol,
        .magnesium = components.magnesium_mol,
        .sodium = components.sodium_mol,
        .potassium = components.potassium_mol,
        .sulfur = components.sulfur_mol,
        .chloride = components.chloride_mol,
        .silicon = components.silicon_mol,
    };
}

pub fn publishStorage(
    totals: *audit.Totals,
    storage: Storage,
) !void {
    try storage.validate();
    std.log.debug("heat latent census: snow_swe_m3={e} snow_ice_we_m3={e} soil_matrix_ice_m3={e} soil_macropore_ice_m3={e} surface_ice_m3={e} soil_vapor_we_m3={e} surface_vapor_we_m3={e} soil_dry_solid_extensive_heat_capacity={e}", .{
        group_snow.diagnostic_snow_solid_water_equivalent_m3,
        group_snow.diagnostic_snow_ice_volume_water_equivalent_m3,
        group_misc.diagnostic_soil_matrix_ice_water_equivalent_m3,
        group_misc.diagnostic_soil_macropore_ice_water_equivalent_m3,
        group_surface.diagnostic_surface_ice_water_equivalent_m3,
        group_misc.diagnostic_soil_vapor_water_equivalent_m3,
        group_surface.diagnostic_surface_vapor_water_equivalent_m3,
        group_misc.diagnostic_soil_dry_solid_extensive_heat_capacity,
    });
    totals.water_storage_m3 = storage.water_m3;
    totals.heat_storage_megajoules = storage.heat_megajoules;
    totals.oxygen_storage_g = storage.oxygen_g;
    totals.hydrogen_storage_g = storage.hydrogen_g;
    totals.residue_carbon_g = storage.residue_carbon_g;
    totals.organic_carbon_g = storage.organic_carbon_g;
    totals.carbon_dioxide_carbon_g = storage.carbon_dioxide_carbon_g;
    totals.plant_carbon_g = storage.plant_carbon_g;
    totals.residue_nitrogen_g = storage.residue_nitrogen_g;
    totals.organic_nitrogen_g = storage.organic_nitrogen_g;
    totals.dinitrogen_nitrogen_g = storage.dinitrogen_nitrogen_g;
    totals.ammonium_nitrogen_g = storage.ammonium_nitrogen_g;
    totals.nitrate_nitrogen_g = storage.nitrate_nitrogen_g;
    totals.plant_nitrogen_g = storage.plant_nitrogen_g;
    totals.residue_phosphorus_g = storage.residue_phosphorus_g;
    totals.organic_phosphorus_g = storage.organic_phosphorus_g;
    totals.phosphate_phosphorus_g = storage.phosphate_phosphorus_g;
    totals.plant_phosphorus_g = storage.plant_phosphorus_g;
    inline for (std.meta.fields(ElementMoles)) |element|
        @field(totals, element.name ++ "_storage_mol") =
            @field(storage, element.name ++ "_mol");
    totals.ion_inventory_mol = storage.ion_inventory_mol;
    totals.sand_storage_megagrams = storage.sand_megagrams;
    totals.silt_storage_megagrams = storage.silt_megagrams;
    totals.clay_storage_megagrams = storage.clay_megagrams;
    totals.rock_storage_additive = storage.rock_additive;
    totals.cation_exchange_capacity_storage_mol = storage.cation_exchange_capacity_mol;
    totals.anion_exchange_capacity_storage_mol = storage.anion_exchange_capacity_mol;
}

/// REDIST snowpack inventory:
/// WS = VOLSSL + VOLWSL + VOLVSL + VOLISL*DENSI
/// ENGYW = VHCPW*TKW, with gas and nutrient carriers summed in their tracked
/// element units. The modern snow owner retains only the eight transported
/// ion carriers, so their authoritative mole inventory is reconstructed from
/// the explicitly tracked element mass rather than inventing absent species.
///
/// HEAT-001 resolution A. The audited heat quantity is an *enthalpy*, not a
/// sensible heat, so every frozen carrier also contributes its latent heat of
/// fusion. The reference state is liquid water at 0 K: liquid and vapor carry
/// only `C*T`, and frozen water carries `C*T - L*V_water_equivalent`. Freeze
/// and thaw are then internal conversions that cancel exactly in the census,
/// and no boundary booking of latent heat of fusion is required or permitted.
/// Reference value retained for fixtures only. Production APIs require an
/// explicit runscript-owned value.
pub const default_latent_heat_of_fusion_megajoules_per_m3: f64 = 333;

/// Pure-water melting temperature separating frozen-carrier and liquid-water
/// enthalpy branches. A frozen carrier with sensible slope `C_f` stores
/// `C_l*Tm - L + C_f*(T-Tm)` per m3 water equivalent. Snow solid uses `C_s`;
/// refrozen physical ice and soil/surface WE ice use `C_i_phys/rho_i`.
///
/// Reference value retained for fixtures only. Production APIs require an
/// explicit runscript-owned value.
pub const default_pure_water_melting_temperature_k: f64 = 273.15;

/// Enthalpy of one m3 water equivalent on a caller-selected frozen-carrier
/// branch, relative to liquid water at 0 K. The boundary and census share this
/// definition; callers must pass `C_s` for solid snow and `C_i_phys/rho_i` for
/// physical-ice water equivalent.
pub fn frozenWaterEnthalpyPerM3(
    temperature_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    frozen_carrier_heat_capacity_per_water_equivalent_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
) !f64 {
    return ice_units.frozenWaterEquivalentEnthalpyPerM3(
        temperature_k,
        liquid_water_heat_capacity_megajoules_per_m3_k,
        frozen_carrier_heat_capacity_per_water_equivalent_m3_k,
        latent_heat_of_fusion_megajoules_per_m3,
        pure_water_melting_temperature_k,
    );
}

pub fn validateFiniteNonnegativeStruct(value: anytype) !void {
    inline for (std.meta.fields(@TypeOf(value))) |field| {
        const number = @field(value, field.name);
        if (!std.math.isFinite(number) or number < 0)
            return error.InvalidProfileMineralNitrogenState;
    }
}

pub fn validateNumericStruct(value: anytype) !void {
    const T = @TypeOf(value);
    inline for (std.meta.fields(T)) |field| switch (@typeInfo(field.type)) {
        .float => {
            const number = @field(value, field.name);
            if (!std.math.isFinite(number))
                return error.NonFiniteSurfaceChemistryInventory;
            if (number < 0) return error.NegativeSurfaceChemistryInventory;
        },
        .@"struct" => try validateNumericStruct(@field(value, field.name)),
        else => @compileError("surface chemistry inventory must be numeric"),
    };
}

pub fn validateOrganicDimensions(state: *const organic.State, failure: anyerror) !void {
    const expected_microbial = try product(&.{
        state.layer_count,
        organic.microbial_substrate_count,
        organic.microbial_population_count,
        organic.kinetic_fraction_count,
    });
    const expected_residue = try product(&.{
        state.layer_count,
        organic.substrate_count,
        organic.residue_fraction_count,
    });
    const expected_mobile = try product(&.{
        state.layer_count,
        organic.substrate_count,
    });
    const expected_structural = try product(&.{
        state.layer_count,
        organic.substrate_count,
        organic.structural_fraction_count,
    });
    if (state.microbial.len != expected_microbial or
        state.residue.len != expected_residue or
        state.dissolved.len != expected_mobile or
        state.adsorbed.len != expected_mobile or
        state.dissolved_acetate_carbon_g_c.len != expected_mobile or
        state.adsorbed_acetate_carbon_g_c.len != expected_mobile or
        state.structural.len != expected_structural or
        state.colonized_structural_carbon_g_c.len != expected_structural)
        return failure;
}

pub fn addResiduePool(
    result: *Storage,
    pool: organic.ElementPool,
) !void {
    inline for (.{
        pool.carbon_g_c,
        pool.nitrogen_g_n,
        pool.phosphorus_g_p,
    }) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteSurfaceOrganicInventory;
        // MICROBIAL-POOL-CARBON-OVERDRAW-HOUR-2678-001. These are DOMAIN checks on
        // an input to a sum, not conservation checks. `nitro.f` writes microbial
        // carbon pools unclamped (`:3824`, `:3832`) and reads each through
        // `AMAX1(0.0, ...)` (`:431`, `:454`, `:2094`, `:2532`), so a small negative
        // pool is part of the model's legal state space -- and an inventory that
        // cannot represent a legal state cannot describe the model.
        //
        // This is not an audit bypass: the conservation guarantee comes from the
        // hourly cell and layer gates, which compare summed storage against booked
        // flux and are untouched. They are what caught
        // PHOSPHORUS-SOIL-SURFACE-BIOGEOCHEMISTRY-HALVES-001. Summing a negative is
        // well defined and still reaches those gates. Non-finite stays fatal.

    }
    result.residue_carbon_g += pool.carbon_g_c;
    result.residue_nitrogen_g += pool.nitrogen_g_n;
    result.residue_phosphorus_g += pool.phosphorus_g_p;
}

pub fn addOrganicPool(result: *Storage, pool: organic.ElementPool) !void {
    inline for (.{
        pool.carbon_g_c,
        pool.nitrogen_g_n,
        pool.phosphorus_g_p,
    }) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteSoilOrganicInventory;

    }
    result.organic_carbon_g += pool.carbon_g_c;
    result.organic_nitrogen_g += pool.nitrogen_g_n;
    result.organic_phosphorus_g += pool.phosphorus_g_p;
}

pub fn addResidueCarbon(result: *Storage, carbon_g_c: f64) !void {
    if (!std.math.isFinite(carbon_g_c))
        return error.NonFiniteSurfaceOrganicInventory;

    result.residue_carbon_g += carbon_g_c;
}

pub fn addOrganicCarbon(result: *Storage, carbon_g_c: f64) !void {
    if (!std.math.isFinite(carbon_g_c))
        return error.NonFiniteSoilOrganicInventory;

    result.organic_carbon_g += carbon_g_c;
}

pub fn product(values: []const usize) !usize {
    var result: usize = 1;
    for (values) |value| result = try std.math.mul(usize, result, value);
    return result;
}

pub fn fourPhaseGas(
    gaseous: []const f64,
    dissolved: []const f64,
    macropore: []const f64,
    band: []const f64,
    species: gas.Species,
) f64 {
    const index = @intFromEnum(species);
    return gaseous[index] + dissolved[index] + macropore[index] + band[index];
}

pub fn speciesAmount(amounts: []const f64, species: snow.Species) f64 {
    return amounts[@intFromEnum(species)];
}
