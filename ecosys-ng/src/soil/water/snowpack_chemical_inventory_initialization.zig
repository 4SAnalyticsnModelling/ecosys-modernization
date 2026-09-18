// **A8a DISPOSITION: SUPERSEDED BY THE BOUND STARTE SNOW-CHEMISTRY OWNER;
// GAP CLOSED.** `soil/chemistry/snow_initialization.zig:equilibrate` constructs
// the first weather-header equilibrium, including STARTE's gas-solubility
// activity divisor, and
// `soil/solute/snow_solute_transport.zig:initializeChemicalState` initializes
// every accepted runtime snow layer using STARTS' exact area-scaled `VHCPWX`
// gate. `ecosys_ng.zig` binds both before the initial mass-balance baseline,
// drives the salt branch from site `ISALTG`, and marks checkpoint-restored
// chemistry as already owned so resume cannot double-seed it. The versioned
// transport checkpoint serializes both `amount_g` and the 41-species dynamic
// salt inventory. First-hour melt continues through the same conservative
// snow transport owner.
//
// Historical audit detail follows. The translation of `starte.f:2072--2200` is faithful:
// `VOLWW = VOLWSL + VOLSSL + VOLISL*DENSI` at `:2085` is
// `equivalentWaterVolume:112--119`; the ten primary carriers at `:2086--2095`
// are seeded as `VOLWW * C*R`, with the `14.0` on the three nitrogen species and
// the `31.0` on the two phosphorus species carried as the runtime
// `nitrogen_molar_mass_g_per_mol` and `phosphorus_molar_mass_g_per_mol`; the
// `IF(VHCPW.GT.VHCPWX)` active gate at `:2073` is the heat-capacity threshold
// test at `:155--157`; and the `IF(ISALTG.NE.0)` branch at `:2099` correctly
// leaves ion inventories at their caller-supplied values in static mode rather
// than zeroing them, which is what Fortran's absent `ELSE` does.
//
// The original audit found no owner. `snow_solute_transport.State.init:61--65` allocates
// `amount_g` and `@memset`s it to zero, and `initializePhysicalState:88--111`
// seeds the twelve physical fields but touches no chemistry. A repository-wide
// search for writes of `amount_g` outside that module finds only
// `driver/transport_step.zig:360` and `:376` (a save/restore pair for rollback)
// and `io/checkpoint/transport_state_checkpoint.zig` (serialization). So
// production starts every snow layer chemically empty, where legacy starts it at
// precipitation composition scaled by the layer's water equivalent.
//
// At that time the gap was **vacuous in the configured case, for a reason that had
// nothing to do with chemistry**: Ottawa's site record 1 gives the initial
// snowpack depth as `0.00` (field 6 of
// `runottawa_input_files/landscape/f25si98`, parsed at `state/site.zig:84` and
// carried to `surface/ground_radiation.zig:38--41`). With zero initial depth,
// `initializePhysicalState:93--96` sets every layer's thickness and hence
// `active` to false, and legacy's own `VHCPW > VHCPWX` gate at `:2073` fails for
// the same layers, so both sides seed nothing. The first snowfall then enters
// through `snow_solute_transport.state_updateAtmosphericWater` with solute supplied by
// `stages/hourly_science_driver.zig:214--248`, which builds the per-species
// input from the weather header's precipitation pH, ammonium, nitrate and
// phosphate via `precipitation_nutrient_speciation`. So the *ongoing* seeding of
// snow chemistry from precipitation is owned and bound; what is missing is only
// the day-zero inventory of a snowpack that already exists at spin-up.
//
// This explained why it was filed rather than bound. Binding required a caller that
// knows the precipitation concentrations at initialization time, and the
// initialization-time analogue of the hourly speciation call above does not
// exist; inventing one is a science decision about what composition a
// pre-existing snowpack should be assumed to have, not a transcription. The
// module is also one of the overlapping-range group recorded in the cited
// binding request, so whoever takes it must first confirm it is not competing
// with a sibling decomposition of the same `starte.f` block.
//
// One further caution applied to that binding. The static/dynamic mode this module
// switches on is legacy `ISALTG`, which Ottawa's site record sets to 1, i.e.
// dynamic. Production formerly drove salt gates from
// `runscript.dynamic_plant_salts` instead, which Ottawa set false, so the two
// flags disagreed for that configured case (SITE-SALT-001/002,
// `state/site.zig:239--300`,
// `docs/traceability/isaltg_is_driven_by_the_wrong_flag.md`). Passing
// `.static` here because production is configured static would reproduce that
// pre-existing conflation in a new place; the mode argument must come from
// site `ISALTG`, as the bound owner now does.
//
// snowpack initialization group of docs/binding_requests/A4_solute_backlog_batch2.md

const std = @import("std");

pub const SaltEquilibriumMode = enum {
    static,
    dynamic,
};

pub const ion_species_count = @typeInfo(IonSpecies).@"enum".fields.len;

pub const IonSpecies = enum(u8) {
    aluminum,
    iron,
    hydrogen,
    calcium,
    magnesium,
    sodium,
    potassium,
    hydroxide,
    sulfate,
    chloride,
    carbonate,
    bicarbonate,
    aluminum_monohydroxide,
    aluminum_dihydroxide,
    aluminum_trihydroxide,
    aluminum_tetrahydroxide,
    aluminum_sulfate,
    iron_monohydroxide,
    iron_dihydroxide,
    iron_trihydroxide,
    iron_tetrahydroxide,
    iron_sulfate,
    calcium_hydroxide,
    calcium_carbonate,
    calcium_bicarbonate,
    calcium_sulfate,
    magnesium_hydroxide,
    magnesium_carbonate,
    magnesium_bicarbonate,
    magnesium_sulfate,
    sodium_carbonate,
    sodium_sulfate,
    potassium_sulfate,
    phosphate,
    phosphoric_acid,
    iron_monophosphate,
    iron_diphosphate,
    calcium_phosphate,
    calcium_hydrogen_phosphate,
    calcium_dihydrogen_phosphate,
    magnesium_hydrogen_phosphate,
};

pub const PrecipitationConcentrations = struct {
    carbon_dioxide_mol_per_m3: f64,
    methane_mol_per_m3: f64,
    oxygen_mol_per_m3: f64,
    nitrous_oxide_mol_n_per_m3: f64,
    dinitrogen_mol_n_per_m3: f64,
    ammonium_mol_n_per_m3: f64,
    ammonia_mol_n_per_m3: f64,
    nitrate_mol_n_per_m3: f64,
    hydrogen_phosphate_mol_p_per_m3: f64,
    organic_phosphorus_mol_p_per_m3: f64,
    ions_mol_per_m3: [ion_species_count]f64,
};

pub const Parameters = struct {
    ice_density_megagrams_per_m3: f64,
    nitrogen_molar_mass_g_per_mol: f64,
    phosphorus_molar_mass_g_per_mol: f64,
};

pub const LayerPhysicalState = struct {
    heat_capacity_megajoules_per_k: f64,
    active_heat_capacity_threshold_megajoules_per_k: f64,
    liquid_water_m3: f64,
    solid_snow_water_equivalent_m3: f64,
    ice_m3: f64,
};

pub const PrimaryInventories = struct {
    carbon_dioxide_mol: f64,
    methane_mol: f64,
    oxygen_mol: f64,
    nitrous_oxide_mol_n: f64,
    dinitrogen_mol_n: f64,
    ammonium_g_n: f64,
    ammonia_g_n: f64,
    nitrate_g_n: f64,
    hydrogen_phosphate_g_p: f64,
    organic_phosphorus_g_p: f64,
};

pub const LayerState = struct {
    primary: PrimaryInventories,
    ions_mol: [ion_species_count]f64,
};

fn validatePrecipitation(concentrations: PrecipitationConcentrations) !void {
    inline for (std.meta.fields(PrecipitationConcentrations)) |field| {
        if (comptime std.mem.eql(u8, field.name, "ions_mol_per_m3")) continue;
        const value = @field(concentrations, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSnowpackPrecipitationConcentration;
    }
    for (concentrations.ions_mol_per_m3) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSnowpackPrecipitationConcentration;
}

fn equivalentWaterVolume(
    physical: LayerPhysicalState,
    ice_density_megagrams_per_m3: f64,
) f64 {
    return physical.liquid_water_m3 +
        physical.solid_snow_water_equivalent_m3 +
        physical.ice_m3 * ice_density_megagrams_per_m3;
}

/// Direct translation of `starte.f` lines 2072--2200 over a runtime snow-layer
/// slice. Active layers inherit precipitation chemistry in their total
/// water-equivalent volume; inactive layers receive zero primary inventory.
/// STARTE touches ion inventories only when dynamic salt chemistry is enabled,
/// so static mode deliberately retains their caller-initialized values.
pub fn initialize(
    layers: []LayerState,
    physical_layers: []const LayerPhysicalState,
    concentrations: PrecipitationConcentrations,
    mode: SaltEquilibriumMode,
    parameters: Parameters,
) !void {
    if (layers.len == 0 or layers.len != physical_layers.len)
        return error.SnowpackChemicalDimensionMismatch;
    inline for (.{
        parameters.ice_density_megagrams_per_m3,
        parameters.nitrogen_molar_mass_g_per_mol,
        parameters.phosphorus_molar_mass_g_per_mol,
    }) |value| if (!std.math.isFinite(value) or value <= 0)
        return error.InvalidSnowpackChemicalParameter;
    try validatePrecipitation(concentrations);

    for (physical_layers) |physical| {
        inline for (std.meta.fields(LayerPhysicalState)) |field| {
            const value = @field(physical, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidSnowpackPhysicalState;
        }
        const volume_m3 = equivalentWaterVolume(
            physical,
            parameters.ice_density_megagrams_per_m3,
        );
        if (!std.math.isFinite(volume_m3))
            return error.NonFiniteSnowpackEquivalentWaterVolume;
        if (physical.heat_capacity_megajoules_per_k >
            physical.active_heat_capacity_threshold_megajoules_per_k)
        {
            const checks = [_]f64{
                volume_m3 * concentrations.carbon_dioxide_mol_per_m3,
                volume_m3 * concentrations.methane_mol_per_m3,
                volume_m3 * concentrations.oxygen_mol_per_m3,
                volume_m3 * concentrations.nitrous_oxide_mol_n_per_m3,
                volume_m3 * concentrations.dinitrogen_mol_n_per_m3,
                volume_m3 * concentrations.ammonium_mol_n_per_m3 *
                    parameters.nitrogen_molar_mass_g_per_mol,
                volume_m3 * concentrations.ammonia_mol_n_per_m3 *
                    parameters.nitrogen_molar_mass_g_per_mol,
                volume_m3 * concentrations.nitrate_mol_n_per_m3 *
                    parameters.nitrogen_molar_mass_g_per_mol,
                volume_m3 * concentrations.hydrogen_phosphate_mol_p_per_m3 *
                    parameters.phosphorus_molar_mass_g_per_mol,
                volume_m3 * concentrations.organic_phosphorus_mol_p_per_m3 *
                    parameters.phosphorus_molar_mass_g_per_mol,
            };
            for (checks) |value| if (!std.math.isFinite(value))
                return error.NonFiniteSnowpackChemicalInventory;
            if (mode == .dynamic) {
                for (concentrations.ions_mol_per_m3) |value|
                    if (!std.math.isFinite(volume_m3 * value))
                        return error.NonFiniteSnowpackChemicalInventory;
            }
        }
    }

    for (layers, physical_layers) |*layer, physical| {
        const active = physical.heat_capacity_megajoules_per_k >
            physical.active_heat_capacity_threshold_megajoules_per_k;
        if (!active) {
            layer.primary = std.mem.zeroes(PrimaryInventories);
            if (mode == .dynamic) layer.ions_mol = [_]f64{0} ** ion_species_count;
            continue;
        }
        const volume_m3 = equivalentWaterVolume(
            physical,
            parameters.ice_density_megagrams_per_m3,
        );
        layer.primary = .{
            .carbon_dioxide_mol = volume_m3 * concentrations.carbon_dioxide_mol_per_m3,
            .methane_mol = volume_m3 * concentrations.methane_mol_per_m3,
            .oxygen_mol = volume_m3 * concentrations.oxygen_mol_per_m3,
            .nitrous_oxide_mol_n = volume_m3 * concentrations.nitrous_oxide_mol_n_per_m3,
            .dinitrogen_mol_n = volume_m3 * concentrations.dinitrogen_mol_n_per_m3,
            .ammonium_g_n = volume_m3 * concentrations.ammonium_mol_n_per_m3 *
                parameters.nitrogen_molar_mass_g_per_mol,
            .ammonia_g_n = volume_m3 * concentrations.ammonia_mol_n_per_m3 *
                parameters.nitrogen_molar_mass_g_per_mol,
            .nitrate_g_n = volume_m3 * concentrations.nitrate_mol_n_per_m3 *
                parameters.nitrogen_molar_mass_g_per_mol,
            .hydrogen_phosphate_g_p = volume_m3 * concentrations.hydrogen_phosphate_mol_p_per_m3 *
                parameters.phosphorus_molar_mass_g_per_mol,
            .organic_phosphorus_g_p = volume_m3 * concentrations.organic_phosphorus_mol_p_per_m3 *
                parameters.phosphorus_molar_mass_g_per_mol,
        };
        if (mode == .dynamic) {
            for (
                concentrations.ions_mol_per_m3,
                &layer.ions_mol,
            ) |concentration, *inventory| inventory.* = volume_m3 * concentration;
        }
    }
}

fn testConcentrations() PrecipitationConcentrations {
    return .{
        .carbon_dioxide_mol_per_m3 = 1,
        .methane_mol_per_m3 = 2,
        .oxygen_mol_per_m3 = 3,
        .nitrous_oxide_mol_n_per_m3 = 4,
        .dinitrogen_mol_n_per_m3 = 5,
        .ammonium_mol_n_per_m3 = 6,
        .ammonia_mol_n_per_m3 = 7,
        .nitrate_mol_n_per_m3 = 8,
        .hydrogen_phosphate_mol_p_per_m3 = 9,
        .organic_phosphorus_mol_p_per_m3 = 10,
        .ions_mol_per_m3 = [_]f64{2} ** ion_species_count,
    };
}

const test_parameters: Parameters = .{
    .ice_density_megagrams_per_m3 = 0.9,
    .nitrogen_molar_mass_g_per_mol = 14,
    .phosphorus_molar_mass_g_per_mol = 31,
};

test "STARTE active snow layer uses total water-equivalent volume" {
    var layers = [_]LayerState{undefined};
    try initialize(&layers, &.{.{
        .heat_capacity_megajoules_per_k = 2,
        .active_heat_capacity_threshold_megajoules_per_k = 1,
        .liquid_water_m3 = 1,
        .solid_snow_water_equivalent_m3 = 2,
        .ice_m3 = 10,
    }}, testConcentrations(), .dynamic, test_parameters);
    const volume_m3: f64 = 12;
    try std.testing.expectEqual(volume_m3, layers[0].primary.carbon_dioxide_mol);
    try std.testing.expectEqual(volume_m3 * 6 * 14, layers[0].primary.ammonium_g_n);
    try std.testing.expectEqual(volume_m3 * 9 * 31, layers[0].primary.hydrogen_phosphate_g_p);
    try std.testing.expectEqual(volume_m3 * 2, layers[0].ions_mol[@intFromEnum(IonSpecies.potassium_sulfate)]);
}

test "STARTE inactive layer zeros tracked chemistry in dynamic mode" {
    var layers = [_]LayerState{undefined};
    try initialize(&layers, &.{.{
        .heat_capacity_megajoules_per_k = 1,
        .active_heat_capacity_threshold_megajoules_per_k = 1,
        .liquid_water_m3 = 4,
        .solid_snow_water_equivalent_m3 = 5,
        .ice_m3 = 6,
    }}, testConcentrations(), .dynamic, test_parameters);
    try std.testing.expectEqual(@as(f64, 0), layers[0].primary.nitrate_g_n);
    try std.testing.expectEqual(@as(f64, 0), layers[0].ions_mol[0]);
}

test "STARTE static salt mode retains caller ion inventories" {
    var layers = [_]LayerState{.{
        .primary = undefined,
        .ions_mol = [_]f64{7} ** ion_species_count,
    }};
    try initialize(&layers, &.{.{
        .heat_capacity_megajoules_per_k = 0,
        .active_heat_capacity_threshold_megajoules_per_k = 1,
        .liquid_water_m3 = 0,
        .solid_snow_water_equivalent_m3 = 0,
        .ice_m3 = 0,
    }}, testConcentrations(), .static, test_parameters);
    try std.testing.expectEqual(@as(f64, 0), layers[0].primary.oxygen_mol);
    try std.testing.expectEqual(@as(f64, 7), layers[0].ions_mol[0]);
}
