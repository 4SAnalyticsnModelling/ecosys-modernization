// **A8a DISPOSITION: BOUND.** `armWarmThinPack` and `consume` split the WATSUB
// 6655--6670 producer from the REDIST 4259--4300 consumer against production's
// authoritative snow and litter owners. `hourly_heat_water_solute` reserves the
// source layer before accepted snow drift and publishes it afterward, so drift
// arrivals cannot alter the gate or be consumed as part of the old pack. The
// transaction moves every source-layer phase, sensible/latent enthalpy,
// non-salt species and dynamic salt coordinate, then refreshes snow geometry. It is an
// internal, cell-local storage transfer: it is not a landscape boundary, but
// `accepted_transfer_by_cell` retains the exact donor image for paired
// snow-layer -> surface local-conservation publication.
//
// The scalar `transfer` kernel below remains as a line-for-line REDIST oracle.
// Production uses the live transaction because its surface ice owner is water
// equivalent, vapor is molar gas storage, chemistry is an accepted litter
// discharge, and all runtime snow layers must publish atomically.

const std = @import("std");
const snow_transport = @import("../solute/snow_solute_transport.zig");
const ice_units = @import("../../core/ice_units.zig");

pub const LiveDestinations = struct {
    litter_liquid_water_m3: []f64,
    litter_water_vapor_mol: []f64,
    litter_ice_water_equivalent_m3: []f64,
    litter_temperature_k: []f64,
    litter_heat_capacity_megajoules_per_k: []f64,
    accepted_litter_discharge: []snow_transport.SurfaceDischarge,
};

pub const LiveConservationTolerances = struct {
    water_depth_m: f64,
    heat_megajoules_per_m2: f64,
    amount_g_per_m2: [snow_transport.species_count]f64,
    salt_mol_per_m2: [snow_transport.salt_species_count]f64,
    relative: f64,
};

pub const LiveParameters = struct {
    thermodynamics: snow_transport.ThermodynamicParameters,
    ice_density_megagrams_per_m3: f64,
    reset_snow_density_megagrams_per_m3: f64,
    water_molar_mass_g_per_mol: f64,
    water_density_g_per_m3: f64,
    /// Snow and surface are independently parameterized in the runscript.
    /// Their frozen-water reference offsets must therefore be reconciled when
    /// ownership changes, even though the physical ice amount is unchanged.
    ///
    /// That reconciliation was half-done: the latent heats were split and the
    /// ICE DENSITIES were not, so the recipient's frozen reference was computed
    /// from the donor's density. `SURFACE-HEAT-PONDED-LITTER-BOOKING-001` is
    /// exactly that gap, and it was bit-exact:
    /// `(239.370533084879 - 239.24925) * 3.635275033610843e-4` minus the booked
    /// internal production reproduced the surface closure residual
    /// `4.3868628948784405e-5` MJ to 1e-15.
    ///
    /// `ice_density_megagrams_per_m3` above stays the DONOR's, because it
    /// converts the snowpack's physical ice volume to a water-equivalent mass.
    /// The field below is the RECIPIENT's, and it is what every litter-side
    /// capacity and enthalpy must use: once snow ice is transferred into the
    /// litter it IS litter ice, and the surface inventory values it with
    /// `soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3`.
    surface_ice_density_megagrams_per_m3: f64,
    snow_latent_heat_of_fusion_megajoules_per_m3: f64,
    surface_latent_heat_of_fusion_megajoules_per_m3: f64,
    /// STARTS 654: VHCPWX = 8.380E-04 * AREA.
    snow_activation_heat_capacity_megajoules_per_m2_k: f64 = 8.380e-4,
    heat_capacity_absolute_tolerance_megajoules_per_k: f64,
    physical_relative_tolerance: f64,
    conservation: LiveConservationTolerances,
};

pub const LiveReport = struct {
    triggered_cells: usize = 0,
    solid_snow_water_equivalent_m3: f64 = 0,
    liquid_water_m3: f64 = 0,
    vapor_water_equivalent_m3: f64 = 0,
    ice_volume_m3: f64 = 0,
    frozen_water_equivalent_m3: f64 = 0,
    sensible_heat_megajoules: f64 = 0,
    snow_frozen_latent_heat_megajoules: f64 = 0,
    surface_frozen_latent_heat_megajoules: f64 = 0,
    enthalpy_reference_adjustment_megajoules: f64 = 0,
    amount_g: [snow_transport.species_count]f64 = @splat(0),
    salt_amount_mol: [snow_transport.salt_species_count]f64 = @splat(0),
};

/// Exact accepted top-snow -> litter transfer retained by cell.  The stage
/// conservation owner consumes this sidecar after `consume`; reconstructing it
/// from the post-drift snow state would lose the reserved donor identity.
pub const LiveAcceptedTransfer = struct {
    triggered: bool = false,
    water_equivalent_m3: f64 = 0,
    canonical_heat_megajoules: f64 = 0,
    amount_g: [snow_transport.species_count]f64 = @splat(0),
    salt_amount_mol: [snow_transport.salt_species_count]f64 = @splat(0),
};

/// Pre-drift WATSUB producer image held outside the live snow owner until the
/// post-drift REDIST consumer publishes it to litter. Arming reserves (removes)
/// exactly layer 1 after every donor and recipient candidate is validated; this
/// is the only unambiguous way for the unified modern owner to retain incoming
/// drift while the original kept producer and REDIST state images separately.
pub const ArmedLiveDisappearance = struct {
    allocator: std.mem.Allocator,
    destinations: LiveDestinations,
    litter_liquid_candidate: []f64,
    litter_vapor_candidate: []f64,
    litter_ice_candidate: []f64,
    litter_temperature_candidate: []f64,
    litter_capacity_candidate: []f64,
    discharge_candidate: []snow_transport.SurfaceDischarge,
    accepted_transfer_by_cell: []LiveAcceptedTransfer,
    report: LiveReport,
    consumed: bool = false,

    pub fn deinit(self: *ArmedLiveDisappearance) void {
        self.allocator.free(self.litter_liquid_candidate);
        self.allocator.free(self.litter_vapor_candidate);
        self.allocator.free(self.litter_ice_candidate);
        self.allocator.free(self.litter_temperature_candidate);
        self.allocator.free(self.litter_capacity_candidate);
        self.allocator.free(self.discharge_candidate);
        self.allocator.free(self.accepted_transfer_by_cell);
        self.* = undefined;
    }

    /// REDIST consumer publication. No snow owner is touched here: the exact
    /// pre-drift donor was reserved while arming, so any live top-layer storage
    /// now present is incoming drift and must remain snow.
    pub fn consume(self: *ArmedLiveDisappearance) !LiveReport {
        if (self.consumed) return error.SnowpackDisappearanceAlreadyConsumed;
        if (self.report.triggered_cells != 0) {
            @memcpy(self.destinations.litter_liquid_water_m3, self.litter_liquid_candidate);
            @memcpy(self.destinations.litter_water_vapor_mol, self.litter_vapor_candidate);
            @memcpy(self.destinations.litter_ice_water_equivalent_m3, self.litter_ice_candidate);
            @memcpy(self.destinations.litter_temperature_k, self.litter_temperature_candidate);
            @memcpy(self.destinations.litter_heat_capacity_megajoules_per_k, self.litter_capacity_candidate);
            @memcpy(self.destinations.accepted_litter_discharge, self.discharge_candidate);
        }
        self.consumed = true;
        return self.report;
    }
};

/// WATSUB 6655--6670 producer against live runtime owners.
///
/// The source gate is evaluated from the top snow layer and ground-surface air:
/// non-empty source layer 1 is reserved only when
/// `VHCPW(1) <= 8.380E-04*AREA` and the air is warmer than the pure-water
/// melting point. Lower layers are not part of the source flux and remain live.
/// Solid snow and physical snow ice are converted to the modern surface
/// ice water-equivalent carrier; vapor is converted to the litter gas owner's
/// molar carrier. Non-salt and salt inventories enter the already accepted
/// snow-surface discharge as litter-only internal transfers.
///
/// Every candidate and every cell-local donor/recipient closure is checked
/// before any owner changes. Callers may therefore retry or roll back a failed
/// nonlinear substep without observing a partial disappearance.
pub fn armWarmThinPack(
    allocator: std.mem.Allocator,
    state: *snow_transport.State,
    cell_area_m2: []const f64,
    ground_surface_air_temperature_k: []const f64,
    entry_top_heat_capacity_megajoules_per_k: []const f64,
    destinations: LiveDestinations,
    parameters: LiveParameters,
) !ArmedLiveDisappearance {
    try validateLiveDimensions(
        state,
        cell_area_m2,
        ground_surface_air_temperature_k,
        entry_top_heat_capacity_megajoules_per_k,
        destinations,
    );
    try validateLiveParameters(parameters);
    // The DONOR's, for the snow-side reference only.
    const ice_heat_capacity_per_water_equivalent_m3_k =
        try ice_units.heatCapacityPerWaterEquivalentM3K(
            parameters.thermodynamics.ice_heat_capacity_megajoules_per_m3_k,
            parameters.ice_density_megagrams_per_m3,
        );
    // The RECIPIENT's, for every litter-side capacity and enthalpy. See the
    // `surface_ice_density_megagrams_per_m3` doc comment: using the donor's
    // here is `SURFACE-HEAT-PONDED-LITTER-BOOKING-001`.
    const surface_ice_heat_capacity_per_water_equivalent_m3_k =
        try ice_units.heatCapacityPerWaterEquivalentM3K(
            parameters.thermodynamics.ice_heat_capacity_megajoules_per_m3_k,
            parameters.surface_ice_density_megagrams_per_m3,
        );
    try validateLiveState(state, cell_area_m2, ground_surface_air_temperature_k, destinations);
    for (entry_top_heat_capacity_megajoules_per_k) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSnowpackDisappearanceEntryHeatCapacity;
    for (0..state.active.len) |layer|
        _ = try liveSnowHeatCapacity(state, layer, parameters);

    const triggered = try allocator.alloc(bool, state.cell_count);
    defer allocator.free(triggered);
    @memset(triggered, false);
    const liquid_candidate = try allocator.dupe(f64, destinations.litter_liquid_water_m3);
    errdefer allocator.free(liquid_candidate);
    const vapor_candidate = try allocator.dupe(f64, destinations.litter_water_vapor_mol);
    errdefer allocator.free(vapor_candidate);
    const ice_candidate = try allocator.dupe(f64, destinations.litter_ice_water_equivalent_m3);
    errdefer allocator.free(ice_candidate);
    const temperature_candidate = try allocator.dupe(f64, destinations.litter_temperature_k);
    errdefer allocator.free(temperature_candidate);
    const capacity_candidate = try allocator.dupe(f64, destinations.litter_heat_capacity_megajoules_per_k);
    errdefer allocator.free(capacity_candidate);
    const discharge_candidate = try allocator.dupe(
        snow_transport.SurfaceDischarge,
        destinations.accepted_litter_discharge,
    );
    errdefer allocator.free(discharge_candidate);
    const accepted_transfer_by_cell = try allocator.alloc(LiveAcceptedTransfer, state.cell_count);
    errdefer allocator.free(accepted_transfer_by_cell);
    @memset(accepted_transfer_by_cell, .{});

    var report: LiveReport = .{};
    for (0..state.cell_count) |cell| {
        const first = cell * state.layer_capacity;
        const area_m2 = cell_area_m2[cell];
        const ground_temperature_k = ground_surface_air_temperature_k[cell];
        const has_source_phase = state.solid_snow_water_equivalent_m3[first] > 0 or
            state.liquid_water_volume_m3[first] > 0 or
            state.vapor_water_equivalent_m3[first] > 0 or
            state.ice_volume_m3[first] > 0;
        const snow_threshold = parameters.snow_activation_heat_capacity_megajoules_per_m2_k * area_m2;
        if (!has_source_phase or
            entry_top_heat_capacity_megajoules_per_k[cell] > snow_threshold or
            ground_temperature_k <= parameters.thermodynamics.pure_water_melting_temperature_k)
            continue;
        triggered[cell] = true;

        var solid_m3: f64 = 0;
        var liquid_m3: f64 = 0;
        var vapor_m3: f64 = 0;
        var ice_volume_m3: f64 = 0;
        var sensible_heat_megajoules: f64 = 0;
        var amount_g: [snow_transport.species_count]f64 = @splat(0);
        var salt_mol: [snow_transport.salt_species_count]f64 = @splat(0);
        solid_m3 = state.solid_snow_water_equivalent_m3[first];
        liquid_m3 = state.liquid_water_volume_m3[first];
        vapor_m3 = state.vapor_water_equivalent_m3[first];
        ice_volume_m3 = state.ice_volume_m3[first];
        const expected_capacity = try liveSnowHeatCapacity(state, first, parameters);
        sensible_heat_megajoules = expected_capacity * state.temperature_k[first];
        if (!std.math.isFinite(sensible_heat_megajoules) or sensible_heat_megajoules <= 0)
            return error.InvalidSnowpackDisappearanceSourceHeat;
        const amounts = state.amount_g[first * snow_transport.species_count ..][0..snow_transport.species_count];
        for (&amount_g, amounts) |*sum, value| sum.* = value;
        const salts = state.salt_amount_mol[first * snow_transport.salt_species_count ..][0..snow_transport.salt_species_count];
        for (&salt_mol, salts) |*sum, value| sum.* = value;

        const old_vapor_water_equivalent_m3 = destinations.litter_water_vapor_mol[cell] *
            parameters.water_molar_mass_g_per_mol / parameters.water_density_g_per_m3;
        const old_wet_capacity = parameters.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k *
            (destinations.litter_liquid_water_m3[cell] + old_vapor_water_equivalent_m3) +
            surface_ice_heat_capacity_per_water_equivalent_m3_k *
                destinations.litter_ice_water_equivalent_m3[cell];
        const dry_capacity = destinations.litter_heat_capacity_megajoules_per_k[cell] - old_wet_capacity;
        if (!std.math.isFinite(dry_capacity) or dry_capacity < 0)
            return error.InvalidSnowpackDisappearanceLitterHeatCapacity;

        const vapor_increment_mol = vapor_m3 * parameters.water_density_g_per_m3 /
            parameters.water_molar_mass_g_per_mol;
        const frozen_increment_m3 = solid_m3 +
            ice_volume_m3 * parameters.ice_density_megagrams_per_m3;
        const snow_water_equivalent_m3 = solid_m3 + liquid_m3 + vapor_m3 +
            ice_volume_m3 * parameters.ice_density_megagrams_per_m3;
        const snow_solid_reference_offset_megajoules_per_m3 =
            try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
                parameters.thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k,
                parameters.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
                parameters.snow_latent_heat_of_fusion_megajoules_per_m3,
                parameters.thermodynamics.pure_water_melting_temperature_k,
            );
        const snow_ice_reference_offset_megajoules_per_m3 =
            try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
                ice_heat_capacity_per_water_equivalent_m3_k,
                parameters.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
                parameters.snow_latent_heat_of_fusion_megajoules_per_m3,
                parameters.thermodynamics.pure_water_melting_temperature_k,
            );
        const surface_frozen_reference_offset_megajoules_per_m3 =
            try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
                surface_ice_heat_capacity_per_water_equivalent_m3_k,
                parameters.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
                parameters.surface_latent_heat_of_fusion_megajoules_per_m3,
                parameters.thermodynamics.pure_water_melting_temperature_k,
            );
        const enthalpy_reference_adjustment_megajoules =
            (snow_solid_reference_offset_megajoules_per_m3 -
                surface_frozen_reference_offset_megajoules_per_m3) * solid_m3 +
            (snow_ice_reference_offset_megajoules_per_m3 -
                surface_frozen_reference_offset_megajoules_per_m3) *
                (ice_volume_m3 * parameters.ice_density_megagrams_per_m3);
        liquid_candidate[cell] = try checkedLiveAdd(liquid_candidate[cell], liquid_m3);
        vapor_candidate[cell] = try checkedLiveAdd(vapor_candidate[cell], vapor_increment_mol);
        ice_candidate[cell] = try checkedLiveAdd(ice_candidate[cell], frozen_increment_m3);
        const new_vapor_water_equivalent_m3 = vapor_candidate[cell] *
            parameters.water_molar_mass_g_per_mol / parameters.water_density_g_per_m3;
        capacity_candidate[cell] = dry_capacity +
            parameters.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k *
                (liquid_candidate[cell] + new_vapor_water_equivalent_m3) +
            surface_ice_heat_capacity_per_water_equivalent_m3_k *
                ice_candidate[cell];
        const old_litter_energy_megajoules = destinations.litter_heat_capacity_megajoules_per_k[cell] *
            destinations.litter_temperature_k[cell];
        const new_litter_energy_megajoules = try checkedLiveAdd(
            try checkedLiveAdd(old_litter_energy_megajoules, sensible_heat_megajoules),
            enthalpy_reference_adjustment_megajoules,
        );
        // The legacy fallback applies only to a zero-capacity recipient. A
        // positive modern carrier retains the transferred energy instead of
        // introducing an unowned reference-temperature heat source.
        temperature_candidate[cell] = if (capacity_candidate[cell] > 0)
            new_litter_energy_megajoules / capacity_candidate[cell]
        else
            ground_temperature_k;
        inline for (.{
            liquid_candidate[cell],
            vapor_candidate[cell],
            ice_candidate[cell],
            capacity_candidate[cell],
            temperature_candidate[cell],
        }) |value| if (!std.math.isFinite(value) or value < 0)
            return error.NonFiniteSnowpackDisappearanceCandidate;
        if (temperature_candidate[cell] <= 0)
            return error.InvalidSnowpackDisappearanceTemperature;

        var needs_dry_aqueous_reference = false;
        for (amount_g[5..]) |value|
            needs_dry_aqueous_reference = needs_dry_aqueous_reference or value > 0;
        for (salt_mol[0..12]) |value|
            needs_dry_aqueous_reference = needs_dry_aqueous_reference or value > 0;
        if (needs_dry_aqueous_reference) {
            const old_dry_reference_carrier_m3 =
                destinations.accepted_litter_discharge[cell].litter_dry_reference_carrier_m3;
            discharge_candidate[cell].litter_dry_reference_carrier_m3 = try checkedLiveAdd(
                discharge_candidate[cell].litter_dry_reference_carrier_m3,
                snow_water_equivalent_m3,
            );
            try requireLiveTransferClosure(
                snow_water_equivalent_m3,
                discharge_candidate[cell].litter_dry_reference_carrier_m3 -
                    old_dry_reference_carrier_m3,
                parameters.conservation.water_depth_m * area_m2,
                parameters.conservation.relative,
                @max(
                    @abs(old_dry_reference_carrier_m3),
                    @abs(discharge_candidate[cell].litter_dry_reference_carrier_m3),
                ),
            );
        }
        for (&discharge_candidate[cell].litter_g, amount_g, 0..) |*destination, value, species| {
            const before = destinations.accepted_litter_discharge[cell].litter_g[species];
            destination.* = try checkedLiveAdd(destination.*, value);
            try requireLiveTransferClosure(
                value,
                destination.* - before,
                parameters.conservation.amount_g_per_m2[species] * area_m2,
                parameters.conservation.relative,
                @max(@abs(before), @abs(destination.*)),
            );
        }
        for (&discharge_candidate[cell].litter_salt_mol, salt_mol, 0..) |*destination, value, species| {
            const before = destinations.accepted_litter_discharge[cell].litter_salt_mol[species];
            destination.* = try checkedLiveAdd(destination.*, value);
            try requireLiveTransferClosure(
                value,
                destination.* - before,
                parameters.conservation.salt_mol_per_m2[species] * area_m2,
                parameters.conservation.relative,
                @max(@abs(before), @abs(destination.*)),
            );
        }

        const litter_water_increment_m3 =
            (liquid_candidate[cell] - destinations.litter_liquid_water_m3[cell]) +
            (new_vapor_water_equivalent_m3 - old_vapor_water_equivalent_m3) +
            (ice_candidate[cell] - destinations.litter_ice_water_equivalent_m3[cell]);
        try requireLiveTransferClosure(
            snow_water_equivalent_m3,
            litter_water_increment_m3,
            parameters.conservation.water_depth_m * area_m2,
            parameters.conservation.relative,
            @max(snow_water_equivalent_m3, @abs(litter_water_increment_m3)),
        );
        const donor_enthalpy_megajoules = sensible_heat_megajoules +
            snow_solid_reference_offset_megajoules_per_m3 * solid_m3 +
            snow_ice_reference_offset_megajoules_per_m3 *
                (ice_volume_m3 * parameters.ice_density_megagrams_per_m3);
        const recipient_enthalpy_increment_megajoules =
            capacity_candidate[cell] * temperature_candidate[cell] - old_litter_energy_megajoules +
            surface_frozen_reference_offset_megajoules_per_m3 * frozen_increment_m3;
        try requireLiveTransferClosure(
            donor_enthalpy_megajoules,
            recipient_enthalpy_increment_megajoules,
            parameters.conservation.heat_megajoules_per_m2 * area_m2,
            parameters.conservation.relative,
            @max(
                @abs(old_litter_energy_megajoules +
                    surface_frozen_reference_offset_megajoules_per_m3 *
                        destinations.litter_ice_water_equivalent_m3[cell]),
                @abs(new_litter_energy_megajoules +
                    surface_frozen_reference_offset_megajoules_per_m3 * ice_candidate[cell]),
            ),
        );
        // SURFACE-HEAT-PONDED-LITTER-BOOKING-001, the last unmeasured
        // subtraction. `canonical_heat_megajoules` is what the ledger books as
        // the surface's heat input for this event; the two enthalpy figures
        // just above are what the transfer believes it moved, in its own
        // convention; and the four terms the inventory measures are printed
        // per hour by `ecosys_ng.zig`. Six hypotheses have been refuted with
        // every link verified individually, so the gap has to be between what
        // is REPORTED and what the writes below actually do to those terms.
        //
        // This fires once per disappearance event -- once per simulated year on
        // this deck -- so unlike the two traces reverted for 6x and 2.3x
        // runtime it costs nothing measurable.
        std.log.info(
            "snowpack disappearance enthalpy: cell={d} donor_enthalpy_megajoules={e} recipient_enthalpy_increment_megajoules={e} reported_canonical_heat_megajoules={e} donor_minus_recipient_megajoules={e} sensible_heat_megajoules={e} enthalpy_reference_adjustment_megajoules={e} old_litter_energy_megajoules={e} new_litter_energy_megajoules={e} capacity_candidate_megajoules_per_k={e} temperature_candidate_k={e} dry_capacity_megajoules_per_k={e} solid_m3={e} liquid_m3={e} vapor_m3={e} ice_volume_m3={e} frozen_increment_m3={e} surface_frozen_reference_offset_megajoules_per_m3={e}",
            .{
                cell,
                donor_enthalpy_megajoules,
                recipient_enthalpy_increment_megajoules,
                donor_enthalpy_megajoules,
                donor_enthalpy_megajoules - recipient_enthalpy_increment_megajoules,
                sensible_heat_megajoules,
                enthalpy_reference_adjustment_megajoules,
                old_litter_energy_megajoules,
                new_litter_energy_megajoules,
                capacity_candidate[cell],
                temperature_candidate[cell],
                dry_capacity,
                solid_m3,
                liquid_m3,
                vapor_m3,
                ice_volume_m3,
                frozen_increment_m3,
                surface_frozen_reference_offset_megajoules_per_m3,
            },
        );
        accepted_transfer_by_cell[cell] = .{
            .triggered = true,
            .water_equivalent_m3 = snow_water_equivalent_m3,
            .canonical_heat_megajoules = donor_enthalpy_megajoules,
            .amount_g = amount_g,
            .salt_amount_mol = salt_mol,
        };

        report.triggered_cells += 1;
        report.solid_snow_water_equivalent_m3 = try checkedLiveAdd(report.solid_snow_water_equivalent_m3, solid_m3);
        report.liquid_water_m3 = try checkedLiveAdd(report.liquid_water_m3, liquid_m3);
        report.vapor_water_equivalent_m3 = try checkedLiveAdd(report.vapor_water_equivalent_m3, vapor_m3);
        report.ice_volume_m3 = try checkedLiveAdd(report.ice_volume_m3, ice_volume_m3);
        report.frozen_water_equivalent_m3 = try checkedLiveAdd(report.frozen_water_equivalent_m3, frozen_increment_m3);
        report.sensible_heat_megajoules = try checkedLiveAdd(report.sensible_heat_megajoules, sensible_heat_megajoules);
        report.snow_frozen_latent_heat_megajoules = try checkedLiveAdd(
            report.snow_frozen_latent_heat_megajoules,
            parameters.snow_latent_heat_of_fusion_megajoules_per_m3 * frozen_increment_m3,
        );
        report.surface_frozen_latent_heat_megajoules = try checkedLiveAdd(
            report.surface_frozen_latent_heat_megajoules,
            parameters.surface_latent_heat_of_fusion_megajoules_per_m3 * frozen_increment_m3,
        );
        report.enthalpy_reference_adjustment_megajoules = try checkedLiveAdd(
            report.enthalpy_reference_adjustment_megajoules,
            enthalpy_reference_adjustment_megajoules,
        );
        for (&report.amount_g, amount_g) |*sum, value| sum.* = try checkedLiveAdd(sum.*, value);
        for (&report.salt_amount_mol, salt_mol) |*sum, value| sum.* = try checkedLiveAdd(sum.*, value);
    }

    // No operation below this point can fail. Reserve exactly the validated
    // pre-drift source layer; the consumer later publishes the staged litter
    // candidates without touching any drift arrival that occupies this layer.
    for (0..state.cell_count) |cell| if (triggered[cell]) {
        const first = cell * state.layer_capacity;
        state.active[first] = false;
        state.solid_snow_water_equivalent_m3[first] = 0;
        state.liquid_water_volume_m3[first] = 0;
        state.vapor_water_equivalent_m3[first] = 0;
        state.ice_volume_m3[first] = 0;
        state.heat_capacity_megajoules_per_k[first] = 0;
        state.temperature_k[first] = ground_surface_air_temperature_k[cell];
        state.snow_density_megagrams_per_m3[first] = parameters.reset_snow_density_megagrams_per_m3;
        @memset(state.amount_g[first * snow_transport.species_count ..][0..snow_transport.species_count], 0);
        @memset(state.salt_amount_mol[first * snow_transport.salt_species_count ..][0..snow_transport.salt_species_count], 0);
    };
    state.refreshAllGeometry();
    return .{
        .allocator = allocator,
        .destinations = destinations,
        .litter_liquid_candidate = liquid_candidate,
        .litter_vapor_candidate = vapor_candidate,
        .litter_ice_candidate = ice_candidate,
        .litter_temperature_candidate = temperature_candidate,
        .litter_capacity_candidate = capacity_candidate,
        .discharge_candidate = discharge_candidate,
        .accepted_transfer_by_cell = accepted_transfer_by_cell,
        .report = report,
    };
}

/// Convenience transaction used by focused kernel tests and non-staged callers.
/// Production splits arming and consumption around snow drift.
pub fn disappearWarmThinPack(
    allocator: std.mem.Allocator,
    state: *snow_transport.State,
    cell_area_m2: []const f64,
    ground_surface_air_temperature_k: []const f64,
    destinations: LiveDestinations,
    parameters: LiveParameters,
) !LiveReport {
    const entry_top_heat_capacity = try allocator.alloc(f64, state.cell_count);
    defer allocator.free(entry_top_heat_capacity);
    for (entry_top_heat_capacity, 0..) |*capacity, cell|
        capacity.* = state.heat_capacity_megajoules_per_k[cell * state.layer_capacity];
    var armed = try armWarmThinPack(
        allocator,
        state,
        cell_area_m2,
        ground_surface_air_temperature_k,
        entry_top_heat_capacity,
        destinations,
        parameters,
    );
    defer armed.deinit();
    return armed.consume();
}

fn validateLiveDimensions(
    state: *const snow_transport.State,
    cell_area_m2: []const f64,
    ground_surface_air_temperature_k: []const f64,
    entry_top_heat_capacity_megajoules_per_k: []const f64,
    destinations: LiveDestinations,
) !void {
    const layers = std.math.mul(usize, state.cell_count, state.layer_capacity) catch
        return error.SnowpackDisappearanceDimensionMismatch;
    const amount_count = std.math.mul(usize, layers, snow_transport.species_count) catch
        return error.SnowpackDisappearanceDimensionMismatch;
    const salt_count = std.math.mul(usize, layers, snow_transport.salt_species_count) catch
        return error.SnowpackDisappearanceDimensionMismatch;
    if (state.cell_count == 0 or state.layer_capacity == 0 or
        cell_area_m2.len != state.cell_count or
        ground_surface_air_temperature_k.len != state.cell_count or
        entry_top_heat_capacity_megajoules_per_k.len != state.cell_count or
        destinations.litter_liquid_water_m3.len != state.cell_count or
        destinations.litter_water_vapor_mol.len != state.cell_count or
        destinations.litter_ice_water_equivalent_m3.len != state.cell_count or
        destinations.litter_temperature_k.len != state.cell_count or
        destinations.litter_heat_capacity_megajoules_per_k.len != state.cell_count or
        destinations.accepted_litter_discharge.len != state.cell_count or
        state.active.len != layers or
        state.solid_snow_water_equivalent_m3.len != layers or
        state.liquid_water_volume_m3.len != layers or
        state.vapor_water_equivalent_m3.len != layers or
        state.ice_volume_m3.len != layers or
        state.air_filled_volume_m3.len != layers or
        state.total_layer_volume_m3.len != layers or
        state.target_layer_volume_m3.len != layers or
        state.layer_thickness_m.len != layers or
        state.cumulative_depth_m.len != layers or
        state.snow_density_megagrams_per_m3.len != layers or
        state.temperature_k.len != layers or
        state.heat_capacity_megajoules_per_k.len != layers or
        state.horizontal_area_m2.len != layers or
        state.amount_g.len != amount_count or
        state.salt_amount_mol.len != salt_count or
        state.dynamic_salts_by_cell.len != state.cell_count)
        return error.SnowpackDisappearanceDimensionMismatch;
}

fn validateLiveParameters(parameters: LiveParameters) !void {
    inline for (@typeInfo(snow_transport.ThermodynamicParameters).@"struct".fields) |field| {
        const value = @field(parameters.thermodynamics, field.name);
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidSnowpackDisappearanceParameter;
    }
    inline for (.{
        parameters.ice_density_megagrams_per_m3,
        parameters.reset_snow_density_megagrams_per_m3,
        parameters.water_molar_mass_g_per_mol,
        parameters.water_density_g_per_m3,
        parameters.snow_latent_heat_of_fusion_megajoules_per_m3,
        parameters.surface_latent_heat_of_fusion_megajoules_per_m3,
        parameters.snow_activation_heat_capacity_megajoules_per_m2_k,
        parameters.heat_capacity_absolute_tolerance_megajoules_per_k,
        parameters.physical_relative_tolerance,
    }) |value| if (!std.math.isFinite(value) or value <= 0)
        return error.InvalidSnowpackDisappearanceParameter;
    if (parameters.ice_density_megagrams_per_m3 > 1 or
        parameters.conservation.relative <= 0 or
        !std.math.isFinite(parameters.conservation.relative))
        return error.InvalidSnowpackDisappearanceParameter;
    inline for (.{
        parameters.conservation.water_depth_m,
        parameters.conservation.heat_megajoules_per_m2,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidSnowpackDisappearanceParameter;
    for (parameters.conservation.amount_g_per_m2) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSnowpackDisappearanceParameter;
    for (parameters.conservation.salt_mol_per_m2) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSnowpackDisappearanceParameter;
}

fn validateLiveState(
    state: *const snow_transport.State,
    cell_area_m2: []const f64,
    ground_surface_air_temperature_k: []const f64,
    destinations: LiveDestinations,
) !void {
    inline for (.{
        state.solid_snow_water_equivalent_m3,
        state.liquid_water_volume_m3,
        state.vapor_water_equivalent_m3,
        state.ice_volume_m3,
        state.air_filled_volume_m3,
        state.total_layer_volume_m3,
        state.target_layer_volume_m3,
        state.layer_thickness_m,
        state.cumulative_depth_m,
        state.snow_density_megagrams_per_m3,
        state.temperature_k,
        state.heat_capacity_megajoules_per_k,
        state.horizontal_area_m2,
        state.amount_g,
        state.salt_amount_mol,
        cell_area_m2,
        ground_surface_air_temperature_k,
        destinations.litter_liquid_water_m3,
        destinations.litter_water_vapor_mol,
        destinations.litter_ice_water_equivalent_m3,
        destinations.litter_temperature_k,
        destinations.litter_heat_capacity_megajoules_per_k,
    }) |values| for (values) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidSnowpackDisappearanceState;
    for (state.temperature_k) |value| if (value <= 0)
        return error.InvalidSnowpackDisappearanceState;
    for (state.snow_density_megagrams_per_m3) |value| if (value <= 0)
        return error.InvalidSnowpackDisappearanceState;
    for (cell_area_m2) |value| if (value <= 0)
        return error.InvalidSnowpackDisappearanceState;
    for (ground_surface_air_temperature_k) |value| if (value <= 0)
        return error.InvalidSnowpackDisappearanceState;
    for (destinations.litter_temperature_k) |value| if (value <= 0)
        return error.InvalidSnowpackDisappearanceState;
    for (destinations.litter_heat_capacity_megajoules_per_k) |value| if (value <= 0)
        return error.InvalidSnowpackDisappearanceState;
    for (destinations.accepted_litter_discharge) |discharge| {
        if (!std.math.isFinite(discharge.litter_dry_reference_carrier_m3) or
            discharge.litter_dry_reference_carrier_m3 < 0)
            return error.InvalidSnowpackDisappearanceState;
        inline for (.{
            discharge.litter_g[0..],
            discharge.soil_nonband_g[0..],
            discharge.soil_band_g[0..],
            discharge.litter_salt_mol[0..],
            discharge.soil_nonband_salt_mol[0..],
            discharge.soil_band_salt_mol[0..],
        }) |values| for (values) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSnowpackDisappearanceState;
    }
}

fn liveSnowHeatCapacity(state: *const snow_transport.State, layer: usize, parameters: LiveParameters) !f64 {
    const expected = parameters.thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k *
        state.solid_snow_water_equivalent_m3[layer] +
        parameters.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k *
            (state.liquid_water_volume_m3[layer] + state.vapor_water_equivalent_m3[layer]) +
        parameters.thermodynamics.ice_heat_capacity_megajoules_per_m3_k *
            state.ice_volume_m3[layer];
    const stored = state.heat_capacity_megajoules_per_k[layer];
    const tolerance = parameters.heat_capacity_absolute_tolerance_megajoules_per_k +
        parameters.physical_relative_tolerance * @max(@abs(expected), @abs(stored));
    if (!std.math.isFinite(expected) or expected < 0 or @abs(expected - stored) > tolerance)
        return error.InconsistentSnowpackDisappearanceHeatCapacity;
    return expected;
}

fn checkedLiveAdd(left: f64, right: f64) !f64 {
    const result = left + right;
    if (!std.math.isFinite(left) or !std.math.isFinite(right) or !std.math.isFinite(result))
        return error.NonFiniteSnowpackDisappearanceCandidate;
    return result;
}

fn requireLiveTransferClosure(
    donor_loss: f64,
    recipient_gain: f64,
    absolute_tolerance: f64,
    relative_tolerance: f64,
    representation_scale: f64,
) !void {
    const activity_scale = @max(@abs(donor_loss), @abs(recipient_gain));
    const tolerance = absolute_tolerance + relative_tolerance * activity_scale +
        64 * std.math.floatEps(f64) * @abs(representation_scale);
    if (!std.math.isFinite(donor_loss) or !std.math.isFinite(recipient_gain) or
        !std.math.isFinite(tolerance) or @abs(donor_loss - recipient_gain) > tolerance)
        return error.SnowpackDisappearanceConservationFailure;
}

fn liveTestParameters() LiveParameters {
    return .{
        .thermodynamics = snow_transport.test_thermodynamics,
        // Deliberately keep `Ci_phys/rho` distinct from `Cs`: a 0.92 test
        // density makes 1.9274 / 0.92 exactly 2.095 and would let a grouped
        // solid/physical-ice carrier bug pass unnoticed.
        .ice_density_megagrams_per_m3 = ice_units.reference_ice_density_megagrams_per_m3,
        // Deliberately equal to the donor's here so every existing expectation
        // in these fixtures is unchanged by the split. The case that exercises
        // a genuine difference is its own test below.
        .surface_ice_density_megagrams_per_m3 = ice_units.reference_ice_density_megagrams_per_m3,
        .reset_snow_density_megagrams_per_m3 = 0.05,
        .water_molar_mass_g_per_mol = 18,
        .water_density_g_per_m3 = 1.0e6,
        .snow_latent_heat_of_fusion_megajoules_per_m3 = 333,
        .surface_latent_heat_of_fusion_megajoules_per_m3 = 341,
        .heat_capacity_absolute_tolerance_megajoules_per_k = 1.0e-12,
        .physical_relative_tolerance = 1.0e-12,
        .conservation = .{
            .water_depth_m = 0,
            .heat_megajoules_per_m2 = 0,
            .amount_g_per_m2 = @splat(0),
            .salt_mol_per_m2 = @splat(0),
            .relative = 1.0e-12,
        },
    };
}

test "warm thin live snowpack disappearance conserves phases energy and every chemistry coordinate" {
    var state = try snow_transport.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    const area_m2: f64 = 100;
    for (0..1) |layer| {
        const scale = @as(f64, @floatFromInt(layer + 1));
        state.active[layer] = true;
        state.solid_snow_water_equivalent_m3[layer] = 0.001 * scale;
        state.liquid_water_volume_m3[layer] = 0.002 * scale;
        state.vapor_water_equivalent_m3[layer] = 0.0005 * scale;
        state.ice_volume_m3[layer] = 0.0015 * scale;
        state.snow_density_megagrams_per_m3[layer] = 0.1;
        state.temperature_k[layer] = 269 + scale;
        state.horizontal_area_m2[layer] = area_m2;
        state.target_layer_volume_m3[layer] = 5 * scale;
        state.heat_capacity_megajoules_per_k[layer] =
            snow_transport.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * state.solid_snow_water_equivalent_m3[layer] +
            snow_transport.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k *
                (state.liquid_water_volume_m3[layer] + state.vapor_water_equivalent_m3[layer]) +
            snow_transport.test_thermodynamics.ice_heat_capacity_megajoules_per_m3_k * state.ice_volume_m3[layer];
        for (try state.amounts(0, layer), 0..) |*value, species|
            value.* = scale * @as(f64, @floatFromInt(species + 1));
        for (try state.saltAmounts(0, layer), 0..) |*value, species|
            value.* = 0.1 * scale * @as(f64, @floatFromInt(species + 1));
    }
    state.dynamic_salts_by_cell[0] = true;
    state.refreshAllGeometry();

    var litter_liquid = [_]f64{0.2};
    const old_vapor_water_equivalent_m3: f64 = 0.05;
    var litter_vapor_mol = [_]f64{old_vapor_water_equivalent_m3 * 1.0e6 / 18};
    var litter_ice = [_]f64{0.1};
    var litter_temperature = [_]f64{280};
    const dry_litter_capacity: f64 = 0.5;
    const test_ice_heat_capacity_per_water_equivalent_m3_k =
        try ice_units.heatCapacityPerWaterEquivalentM3K(
            snow_transport.test_thermodynamics.ice_heat_capacity_megajoules_per_m3_k,
            liveTestParameters().ice_density_megagrams_per_m3,
        );
    var litter_capacity = [_]f64{dry_litter_capacity +
        snow_transport.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k *
            (litter_liquid[0] + old_vapor_water_equivalent_m3) +
        test_ice_heat_capacity_per_water_equivalent_m3_k * litter_ice[0]};
    var discharge = [_]snow_transport.SurfaceDischarge{.{}};
    const old_litter_energy = litter_capacity[0] * litter_temperature[0];
    var snow_energy: f64 = 0;
    for (state.heat_capacity_megajoules_per_k, state.temperature_k) |capacity, temperature|
        snow_energy += capacity * temperature;
    const snow_solid_before = state.solid_snow_water_equivalent_m3[0];
    const snow_ice_physical_before = state.ice_volume_m3[0];
    const parameters = liveTestParameters();

    const report = try disappearWarmThinPack(
        std.testing.allocator,
        &state,
        &.{area_m2},
        &.{274},
        .{
            .litter_liquid_water_m3 = &litter_liquid,
            .litter_water_vapor_mol = &litter_vapor_mol,
            .litter_ice_water_equivalent_m3 = &litter_ice,
            .litter_temperature_k = &litter_temperature,
            .litter_heat_capacity_megajoules_per_k = &litter_capacity,
            .accepted_litter_discharge = &discharge,
        },
        parameters,
    );

    try std.testing.expectEqual(@as(usize, 1), report.triggered_cells);
    try std.testing.expectApproxEqAbs(@as(f64, 0.202), litter_liquid[0], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0505), litter_vapor_mol[0] * 18 / 1.0e6, 1.0e-15);
    const expected_frozen_increment = 0.001 +
        0.0015 * parameters.ice_density_megagrams_per_m3;
    const expected_water_transfer = 0.001 + 0.002 + 0.0005 +
        0.0015 * parameters.ice_density_megagrams_per_m3;
    try std.testing.expectApproxEqAbs(0.1 + expected_frozen_increment, litter_ice[0], 1.0e-15);
    try std.testing.expectApproxEqAbs(
        expected_water_transfer,
        discharge[0].litter_dry_reference_carrier_m3,
        1.0e-15,
    );
    const snow_solid_offset = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        parameters.thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k,
        parameters.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
        parameters.snow_latent_heat_of_fusion_megajoules_per_m3,
        parameters.thermodynamics.pure_water_melting_temperature_k,
    );
    const snow_ice_offset = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        test_ice_heat_capacity_per_water_equivalent_m3_k,
        parameters.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
        parameters.snow_latent_heat_of_fusion_megajoules_per_m3,
        parameters.thermodynamics.pure_water_melting_temperature_k,
    );
    const surface_frozen_offset = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        test_ice_heat_capacity_per_water_equivalent_m3_k,
        parameters.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
        parameters.surface_latent_heat_of_fusion_megajoules_per_m3,
        parameters.thermodynamics.pure_water_melting_temperature_k,
    );
    const old_total_enthalpy = old_litter_energy + surface_frozen_offset * 0.1 +
        snow_energy + snow_solid_offset * snow_solid_before +
        snow_ice_offset * snow_ice_physical_before * parameters.ice_density_megagrams_per_m3;
    const new_total_enthalpy = litter_capacity[0] * litter_temperature[0] +
        surface_frozen_offset * litter_ice[0];
    try std.testing.expectApproxEqAbs(
        old_total_enthalpy,
        new_total_enthalpy,
        64 * std.math.floatEps(f64) * @abs(old_total_enthalpy),
    );
    try std.testing.expectApproxEqAbs(
        parameters.snow_latent_heat_of_fusion_megajoules_per_m3 * expected_frozen_increment,
        report.snow_frozen_latent_heat_megajoules,
        1.0e-15,
    );
    try std.testing.expectApproxEqAbs(
        parameters.surface_latent_heat_of_fusion_megajoules_per_m3 * expected_frozen_increment,
        report.surface_frozen_latent_heat_megajoules,
        1.0e-15,
    );
    const latent_reference_difference =
        parameters.surface_latent_heat_of_fusion_megajoules_per_m3 -
        parameters.snow_latent_heat_of_fusion_megajoules_per_m3;
    const solid_carrier_reference_difference =
        (test_ice_heat_capacity_per_water_equivalent_m3_k -
            parameters.thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k) *
        parameters.thermodynamics.pure_water_melting_temperature_k +
        latent_reference_difference;
    const expected_reference_adjustment =
        solid_carrier_reference_difference * snow_solid_before +
        latent_reference_difference *
            snow_ice_physical_before * parameters.ice_density_megagrams_per_m3;
    try std.testing.expectApproxEqAbs(
        expected_reference_adjustment,
        report.enthalpy_reference_adjustment_megajoules,
        1.0e-15,
    );
    for (state.active) |active| try std.testing.expect(!active);
    inline for (.{
        state.solid_snow_water_equivalent_m3,
        state.liquid_water_volume_m3,
        state.vapor_water_equivalent_m3,
        state.ice_volume_m3,
        state.total_layer_volume_m3,
        state.air_filled_volume_m3,
        state.layer_thickness_m,
        state.cumulative_depth_m,
        state.heat_capacity_megajoules_per_k,
        state.amount_g,
        state.salt_amount_mol,
    }) |values| for (values) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (state.snow_density_megagrams_per_m3) |density|
        try std.testing.expectEqual(@as(f64, 0.05), density);
    for (state.temperature_k) |temperature|
        try std.testing.expectEqual(@as(f64, 274), temperature);
    try std.testing.expectEqualSlices(f64, &.{5}, state.target_layer_volume_m3);
    for (0..snow_transport.species_count) |species| {
        const expected = @as(f64, @floatFromInt(species + 1));
        try std.testing.expectApproxEqAbs(expected, discharge[0].litter_g[species], 1.0e-13);
        try std.testing.expectApproxEqAbs(expected, report.amount_g[species], 1.0e-13);
        try std.testing.expectEqual(@as(f64, 0), discharge[0].soil_nonband_g[species]);
        try std.testing.expectEqual(@as(f64, 0), discharge[0].soil_band_g[species]);
    }
    for (0..snow_transport.salt_species_count) |species| {
        const expected = 0.1 * @as(f64, @floatFromInt(species + 1));
        try std.testing.expectApproxEqAbs(expected, discharge[0].litter_salt_mol[species], 1.0e-13);
        try std.testing.expectApproxEqAbs(expected, report.salt_amount_mol[species], 1.0e-13);
        try std.testing.expectEqual(@as(f64, 0), discharge[0].soil_nonband_salt_mol[species]);
        try std.testing.expectEqual(@as(f64, 0), discharge[0].soil_band_salt_mol[species]);
    }
}

test "empty source layer does not delete an active lower snow layer" {
    var state = try snow_transport.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    state.active[1] = true;
    state.solid_snow_water_equivalent_m3[1] = 0.25;
    state.snow_density_megagrams_per_m3[0] = 0.1;
    state.snow_density_megagrams_per_m3[1] = 0.1;
    state.temperature_k[0] = 270;
    state.temperature_k[1] = 268;
    state.horizontal_area_m2[0] = 1;
    state.horizontal_area_m2[1] = 1;
    state.target_layer_volume_m3[0] = 0.1;
    state.target_layer_volume_m3[1] = 3;
    state.heat_capacity_megajoules_per_k[1] =
        snow_transport.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * 0.25;
    state.refreshAllGeometry();

    var liquid = [_]f64{0.1};
    var vapor = [_]f64{0};
    var ice = [_]f64{0};
    var temperature = [_]f64{280};
    var capacity = [_]f64{1};
    var discharge = [_]snow_transport.SurfaceDischarge{.{}};
    const report = try disappearWarmThinPack(
        std.testing.allocator,
        &state,
        &.{1},
        &.{274},
        .{
            .litter_liquid_water_m3 = &liquid,
            .litter_water_vapor_mol = &vapor,
            .litter_ice_water_equivalent_m3 = &ice,
            .litter_temperature_k = &temperature,
            .litter_heat_capacity_megajoules_per_k = &capacity,
            .accepted_litter_discharge = &discharge,
        },
        liveTestParameters(),
    );
    try std.testing.expectEqual(@as(usize, 0), report.triggered_cells);
    try std.testing.expect(state.active[1]);
    try std.testing.expectEqual(@as(f64, 0.25), state.solid_snow_water_equivalent_m3[1]);
    try std.testing.expect(state.cumulative_depth_m[1] > 0);
    try std.testing.expectEqual(@as(f64, 0.1), liquid[0]);
}

test "pre-drift disappearance reservation leaves later top-layer drift arrival in snow" {
    var state = try snow_transport.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    state.active[0] = true;
    state.solid_snow_water_equivalent_m3[0] = 0.0001;
    state.snow_density_megagrams_per_m3[0] = 0.1;
    state.temperature_k[0] = 270;
    state.horizontal_area_m2[0] = 1;
    state.target_layer_volume_m3[0] = 0.1;
    state.heat_capacity_megajoules_per_k[0] =
        snow_transport.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * 0.0001;
    state.refreshAllGeometry();

    var liquid = [_]f64{0.1};
    var vapor = [_]f64{0};
    var ice = [_]f64{0};
    var temperature = [_]f64{280};
    var capacity = [_]f64{1};
    var discharge = [_]snow_transport.SurfaceDischarge{.{}};
    var armed = try armWarmThinPack(
        std.testing.allocator,
        &state,
        &.{1},
        &.{274},
        &.{state.heat_capacity_megajoules_per_k[0]},
        .{
            .litter_liquid_water_m3 = &liquid,
            .litter_water_vapor_mol = &vapor,
            .litter_ice_water_equivalent_m3 = &ice,
            .litter_temperature_k = &temperature,
            .litter_heat_capacity_megajoules_per_k = &capacity,
            .accepted_litter_discharge = &discharge,
        },
        liveTestParameters(),
    );
    defer armed.deinit();
    try std.testing.expectEqual(@as(f64, 0), state.solid_snow_water_equivalent_m3[0]);
    try std.testing.expect(armed.accepted_transfer_by_cell[0].triggered);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.0001),
        armed.accepted_transfer_by_cell[0].water_equivalent_m3,
        16 * std.math.floatEps(f64),
    );
    try std.testing.expect(std.math.isFinite(armed.accepted_transfer_by_cell[0].canonical_heat_megajoules));
    try std.testing.expect(armed.accepted_transfer_by_cell[0].canonical_heat_megajoules > 0);

    // Stand in for an accepted REDIST arrival between producer and consumer.
    state.active[0] = true;
    state.solid_snow_water_equivalent_m3[0] = 0.002;
    state.snow_density_megagrams_per_m3[0] = 0.1;
    state.temperature_k[0] = 269;
    state.heat_capacity_megajoules_per_k[0] =
        snow_transport.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * 0.002;
    state.refreshAllGeometry();

    const report = try armed.consume();
    try std.testing.expectEqual(@as(usize, 1), report.triggered_cells);
    try std.testing.expectEqual(@as(f64, 0.002), state.solid_snow_water_equivalent_m3[0]);
    try std.testing.expect(state.active[0]);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.0001),
        ice[0],
        16 * std.math.floatEps(f64),
    );
}

test "entry heat capacity controls disappearance while post-process layer is captured" {
    var state = try snow_transport.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    const solid = [_]f64{ 0.01, 0.0001 };
    for (0..2) |cell| {
        state.active[cell] = true;
        state.solid_snow_water_equivalent_m3[cell] = solid[cell];
        state.snow_density_megagrams_per_m3[cell] = 0.1;
        state.temperature_k[cell] = 270;
        state.horizontal_area_m2[cell] = 1;
        state.target_layer_volume_m3[cell] = 0.2;
        state.heat_capacity_megajoules_per_k[cell] =
            snow_transport.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * solid[cell];
    }
    state.refreshAllGeometry();
    var liquid = [_]f64{ 0.1, 0.1 };
    var vapor = [_]f64{ 0, 0 };
    var ice = [_]f64{ 0, 0 };
    var temperature = [_]f64{ 280, 280 };
    var capacity = [_]f64{ 1, 1 };
    var discharge = [_]snow_transport.SurfaceDischarge{ .{}, .{} };
    var armed = try armWarmThinPack(
        std.testing.allocator,
        &state,
        &.{ 1, 1 },
        &.{ 274, 274 },
        // Cell 0 entered thin then accumulated; cell 1 entered thick then melted.
        &.{ 0.0001, 0.02 },
        .{
            .litter_liquid_water_m3 = &liquid,
            .litter_water_vapor_mol = &vapor,
            .litter_ice_water_equivalent_m3 = &ice,
            .litter_temperature_k = &temperature,
            .litter_heat_capacity_megajoules_per_k = &capacity,
            .accepted_litter_discharge = &discharge,
        },
        liveTestParameters(),
    );
    defer armed.deinit();
    try std.testing.expectEqual(@as(usize, 1), armed.report.triggered_cells);
    try std.testing.expectEqual(@as(f64, 0), state.solid_snow_water_equivalent_m3[0]);
    try std.testing.expectEqual(@as(f64, 0.0001), state.solid_snow_water_equivalent_m3[1]);
    _ = try armed.consume();
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), ice[0], 1.0e-15);
    try std.testing.expectEqual(@as(f64, 0), ice[1]);
}

test "live snowpack disappearance requires both thin and warm gates" {
    var state = try snow_transport.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    for (0..2) |cell| {
        state.active[cell] = true;
        state.solid_snow_water_equivalent_m3[cell] = if (cell == 0) 0.001 else 0.0001;
        state.snow_density_megagrams_per_m3[cell] = 0.1;
        state.temperature_k[cell] = 270;
        state.horizontal_area_m2[cell] = 1;
        state.target_layer_volume_m3[cell] = 0.1;
        state.heat_capacity_megajoules_per_k[cell] =
            snow_transport.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k *
            state.solid_snow_water_equivalent_m3[cell];
    }
    state.refreshAllGeometry();
    const solid_before = state.solid_snow_water_equivalent_m3[0..2].*;
    var liquid = [_]f64{ 0.1, 0.1 };
    var vapor = [_]f64{ 0, 0 };
    var ice = [_]f64{ 0, 0 };
    var temperature = [_]f64{ 280, 280 };
    var capacity = [_]f64{ 1, 1 };
    var discharge = [_]snow_transport.SurfaceDischarge{ .{}, .{} };
    const report = try disappearWarmThinPack(
        std.testing.allocator,
        &state,
        &.{ 1, 1 },
        // Cell 0 is warm but too thick; cell 1 is thin but not above melting.
        &.{ 274, snow_transport.test_thermodynamics.pure_water_melting_temperature_k },
        .{
            .litter_liquid_water_m3 = &liquid,
            .litter_water_vapor_mol = &vapor,
            .litter_ice_water_equivalent_m3 = &ice,
            .litter_temperature_k = &temperature,
            .litter_heat_capacity_megajoules_per_k = &capacity,
            .accepted_litter_discharge = &discharge,
        },
        liveTestParameters(),
    );
    try std.testing.expectEqual(@as(usize, 0), report.triggered_cells);
    try std.testing.expectEqualSlices(f64, &solid_before, state.solid_snow_water_equivalent_m3);
    try std.testing.expectEqualSlices(f64, &.{ 0.1, 0.1 }, &liquid);
    try std.testing.expectEqualSlices(f64, &.{ 1, 1 }, &capacity);
}

test "invalid late live snowpack disappearance candidate rolls back every owner" {
    var state = try snow_transport.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    for (0..2) |cell| {
        state.active[cell] = true;
        state.solid_snow_water_equivalent_m3[cell] = 0.0001;
        state.snow_density_megagrams_per_m3[cell] = 0.1;
        state.temperature_k[cell] = 270;
        state.horizontal_area_m2[cell] = 100;
        state.target_layer_volume_m3[cell] = 1;
        state.heat_capacity_megajoules_per_k[cell] =
            snow_transport.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * 0.0001;
        state.amount_g[cell * snow_transport.species_count] = if (cell == 0) 2 else std.math.floatMax(f64);
    }
    state.refreshAllGeometry();
    var liquid = [_]f64{ 0.1, 0.1 };
    var vapor = [_]f64{ 0, 0 };
    var ice = [_]f64{ 0, 0 };
    var temperature = [_]f64{ 280, 280 };
    var capacity = [_]f64{ 1, 1 };
    var discharge = [_]snow_transport.SurfaceDischarge{ .{}, .{} };
    discharge[1].litter_g[0] = std.math.floatMax(f64);
    const solid_before = state.solid_snow_water_equivalent_m3[0..2].*;
    const active_before = state.active[0..2].*;
    const amount_before = try std.testing.allocator.dupe(f64, state.amount_g);
    defer std.testing.allocator.free(amount_before);
    const discharge_before = discharge;

    try std.testing.expectError(
        error.NonFiniteSnowpackDisappearanceCandidate,
        disappearWarmThinPack(
            std.testing.allocator,
            &state,
            &.{ 100, 100 },
            &.{ 274, 274 },
            .{
                .litter_liquid_water_m3 = &liquid,
                .litter_water_vapor_mol = &vapor,
                .litter_ice_water_equivalent_m3 = &ice,
                .litter_temperature_k = &temperature,
                .litter_heat_capacity_megajoules_per_k = &capacity,
                .accepted_litter_discharge = &discharge,
            },
            liveTestParameters(),
        ),
    );
    try std.testing.expectEqualSlices(f64, &solid_before, state.solid_snow_water_equivalent_m3);
    try std.testing.expectEqualSlices(bool, &active_before, state.active);
    try std.testing.expectEqualSlices(f64, amount_before, state.amount_g);
    try std.testing.expectEqualSlices(f64, &.{ 0.1, 0.1 }, &liquid);
    try std.testing.expectEqualSlices(f64, &.{ 1, 1 }, &capacity);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&discharge_before),
        std.mem.asBytes(&discharge),
    );
}

pub const SnowLayer = struct {
    /// VOLSSL(1). Solid snow volume (m3).
    solid_m3: f64,
    /// VOLWSL(1). Liquid water volume (m3).
    liquid_m3: f64,
    /// VOLVSL(1). Vapor volume (m3).
    vapor_m3: f64,
    /// VOLISL(1). Ice volume (m3).
    ice_m3: f64,
    /// TKW(1). Temperature (K).
    temperature_k: f64,
    /// VHCPW(1). Volumetric heat capacity (MJ K-1).
    heat_capacity_megajoules_per_k: f64,
};

pub const SurfaceLitter = struct {
    /// VOLW(0). Liquid water volume (m3).
    liquid_m3: f64,
    /// VOLV(0). Vapor volume (m3).
    vapor_m3: f64,
    /// VOLI(0). Ice volume (m3).
    ice_m3: f64,
    /// TKS(0). Temperature (K).
    temperature_k: f64,
    /// VHCP(0). Volumetric heat capacity (MJ K-1).
    heat_capacity_megajoules_per_k: f64,
};

pub const Fluxes = struct {
    /// XFLWSX. Solid snow flux from watsub.f to litter (m3 step-1).
    solid_m3: f64,
    /// XFLWWX. Liquid water flux (m3 step-1).
    liquid_m3: f64,
    /// XFLWVX. Vapor flux (m3 step-1).
    vapor_m3: f64,
    /// XFLWIX. Ice flux (m3 step-1).
    ice_m3: f64,
    /// XHFLWX. Heat flux from watsub.f to litter (MJ step-1). Must be > 0.
    heat_megajoules: f64,
};

pub const Parameters = struct {
    /// DENSI. Ice density (Mg m-3); converts solid snow volume to ice volume.
    ice_density_megagrams_per_m3: f64,
    /// DENS0. Initial snow density applied to all layers after full melt
    /// (Mg m-3). Also used to compute VOLS from VOLSSL.
    reset_snow_density_megagrams_per_m3: f64,
    /// VHCPWX. Minimum snow layer heat capacity for temperature update (MJ K-1).
    min_snow_heat_capacity_megajoules_per_k: f64,
    /// TKQ. Ambient temperature fallback for snow layer when heat capacity
    /// falls below threshold (K).
    ambient_temperature_k: f64,
    /// VHCPRX. Minimum litter heat capacity for temperature update (MJ K-1).
    min_litter_heat_capacity_megajoules_per_k: f64,
    /// TKS(NUM). Mineral layer temperature fallback for litter when litter
    /// heat capacity falls below threshold (K).
    mineral_layer_temperature_k: f64,
};

pub const LitterOrganic = struct {
    /// ORGC(0). Surface litter organic carbon (g C).
    organic_carbon_g: f64,
    /// ORGCC(0). Surface litter charcoal carbon (g C).
    charcoal_g: f64,
};

pub const Inputs = struct {
    snow_layer: SnowLayer,
    litter: SurfaceLitter,
    litter_organic: LitterOrganic,
    fluxes: Fluxes,
    parameters: Parameters,
};

pub const UpdatedSnowLayer = struct {
    solid_m3: f64,
    liquid_m3: f64,
    vapor_m3: f64,
    ice_m3: f64,
    heat_capacity_megajoules_per_k: f64,
    temperature_k: f64,
};

pub const UpdatedLitter = struct {
    liquid_m3: f64,
    vapor_m3: f64,
    ice_m3: f64,
    heat_capacity_megajoules_per_k: f64,
    temperature_k: f64,
};

pub const SnowpackTotals = struct {
    /// VOLSS. Total solid snow volume (m3).
    solid_m3: f64,
    /// VOLWS. Total liquid water (m3).
    liquid_m3: f64,
    /// VOLIS. Total ice (m3).
    ice_m3: f64,
    /// VOLS. Total snowpack volume (m3).
    total_m3: f64,
    /// DPTHS. Set to 0 after complete melt-to-litter transfer.
    depth_m: f64,
    /// DENSS value assigned to all snow layers (= DENS0).
    layer_density_megagrams_per_m3: f64,
};

pub const Result = struct {
    snow_layer: UpdatedSnowLayer,
    litter: UpdatedLitter,
    snowpack: SnowpackTotals,
};

// Heat capacity coefficients (MJ m-3 K-1 or MJ g-1 K-1).
const solid_snow_heat_capacity: f64 = 2.095;
const liquid_water_heat_capacity: f64 = 4.19;
const ice_heat_capacity: f64 = 1.9274;
const organic_carbon_heat_capacity: f64 = 2.496e-6; // MJ g-1 K-1

test "SURFACE-HEAT-PONDED-LITTER-BOOKING-001 the recipient frozen reference uses the SURFACE ice density, not the donor's" {
    // The two offsets must be computed from different ice densities. Sharing
    // one coefficient is the defect: it made the snowpack transfer book the
    // litter's ice latent enthalpy at the snow's reference while the surface
    // inventory valued the same mass at the surface's, and the gap was bit-exact
    // against the observed closure residual --
    // `(239.370533084879 - 239.24925) * 3.635275033610843e-4` minus the booked
    // internal production reproduced `4.3868628948784405e-5` MJ to 1e-15.
    const liquid_capacity: f64 = 4.19;
    const physical_ice_capacity: f64 = 1.9274;
    const melting_k: f64 = 273.15;
    const latent: f64 = 333;
    const snow_density: f64 = 0.92;
    const surface_density: f64 = 0.917;

    const snow_carrier = try ice_units.heatCapacityPerWaterEquivalentM3K(physical_ice_capacity, snow_density);
    const surface_carrier = try ice_units.heatCapacityPerWaterEquivalentM3K(physical_ice_capacity, surface_density);
    try std.testing.expect(snow_carrier != surface_carrier);

    const snow_offset = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        snow_carrier,
        liquid_capacity,
        latent,
        melting_k,
    );
    const surface_offset = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        surface_carrier,
        liquid_capacity,
        latent,
        melting_k,
    );

    // The whole point: two densities give two offsets, and the difference is
    // exactly `(C_ice/d_snow - C_ice/d_surface) * Tm`.
    try std.testing.expect(snow_offset != surface_offset);
    try std.testing.expectApproxEqRel(
        (snow_carrier - surface_carrier) * melting_k,
        surface_offset - snow_offset,
        1e-12,
    );

    // And the sign matters: the surface density is the smaller one here, so its
    // carrier capacity is larger and its offset is lower. A fix that used the
    // donor's density for the recipient would collapse the difference to zero,
    // which is what this asserts against.
    try std.testing.expect(surface_carrier > snow_carrier);
    try std.testing.expect(surface_offset < snow_offset);
}

/// Direct translation of redist.f lines 4259--4300 (body of the
/// `IF(XHFLWX > ZEROS)` gate).
///
/// Transfers snow phase volumes from the bottom snow layer (layer 1) to
/// the surface litter (layer 0), updates both heat capacities from the new
/// volumes using source-default phase coefficients, and updates temperatures
/// via energy conservation. Falls back to ambient/mineral temperatures when
/// heat capacity drops below the respective minimum thresholds.
/// Resets all snow layer densities to DENS0 and zeroes DPTHS.
pub fn transfer(inputs: Inputs) !Result {
    try validateInputs(inputs);
    const fluxes = inputs.fluxes;
    const p = inputs.parameters;

    const snow = inputs.snow_layer;
    const litter = inputs.litter;
    const org = inputs.litter_organic;

    // Lines 4260--4263: remove fluxes from snow layer 1.
    const snow_solid = snow.solid_m3 - fluxes.solid_m3;
    const snow_liquid = snow.liquid_m3 - fluxes.liquid_m3;
    const snow_vapor = snow.vapor_m3 - fluxes.vapor_m3;
    const snow_ice = snow.ice_m3 - fluxes.ice_m3;
    inline for (.{ snow_solid, snow_liquid, snow_vapor, snow_ice }) |volume_m3| {
        if (!std.math.isFinite(volume_m3))
            return error.NonFiniteSnowpackLitterTransferResult;
        if (volume_m3 < 0)
            return error.SnowpackLitterFluxExceedsInventory;
    }

    // Lines 4264--4266: add fluxes to surface litter.
    const litter_liquid = litter.liquid_m3 + fluxes.liquid_m3;
    const litter_vapor = litter.vapor_m3 + fluxes.vapor_m3;
    const litter_ice = litter.ice_m3 + fluxes.ice_m3 + fluxes.solid_m3 / p.ice_density_megagrams_per_m3;

    // Lines 4267--4275: snow layer heat capacity and temperature.
    const snow_energy = snow.temperature_k * snow.heat_capacity_megajoules_per_k;
    const snow_vhcp = solid_snow_heat_capacity * snow_solid +
        liquid_water_heat_capacity * (snow_liquid + snow_vapor) +
        ice_heat_capacity * snow_ice;
    const snow_temperature = if (snow_vhcp > p.min_snow_heat_capacity_megajoules_per_k)
        (snow_energy - fluxes.heat_megajoules) / snow_vhcp
    else
        p.ambient_temperature_k;

    // Lines 4276--4284: litter heat capacity and temperature.
    const litter_energy = litter.temperature_k * litter.heat_capacity_megajoules_per_k;
    const litter_vhcp = organic_carbon_heat_capacity * (org.organic_carbon_g + org.charcoal_g) +
        liquid_water_heat_capacity * (litter_liquid + litter_vapor) +
        ice_heat_capacity * litter_ice;
    const litter_temperature = if (litter_vhcp > p.min_litter_heat_capacity_megajoules_per_k)
        (litter_energy + fluxes.heat_megajoules) / litter_vhcp
    else
        p.mineral_layer_temperature_k;

    // Lines 4285--4293: snowpack totals. DENSS(L) = DENS0 for all L;
    // VOLS uses DENSS(1) = DENS0. DPTHS = 0.
    const total_snow_m3 = snow_solid / p.reset_snow_density_megagrams_per_m3 +
        snow_liquid + snow_ice;

    const result = Result{
        .snow_layer = .{
            .solid_m3 = snow_solid,
            .liquid_m3 = snow_liquid,
            .vapor_m3 = snow_vapor,
            .ice_m3 = snow_ice,
            .heat_capacity_megajoules_per_k = snow_vhcp,
            .temperature_k = snow_temperature,
        },
        .litter = .{
            .liquid_m3 = litter_liquid,
            .vapor_m3 = litter_vapor,
            .ice_m3 = litter_ice,
            .heat_capacity_megajoules_per_k = litter_vhcp,
            .temperature_k = litter_temperature,
        },
        .snowpack = .{
            .solid_m3 = snow_solid,
            .liquid_m3 = snow_liquid,
            .ice_m3 = snow_ice,
            .total_m3 = total_snow_m3,
            .depth_m = 0.0,
            .layer_density_megagrams_per_m3 = p.reset_snow_density_megagrams_per_m3,
        },
    };
    inline for (@typeInfo(UpdatedSnowLayer).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result.snow_layer, field.name)))
            return error.NonFiniteSnowpackLitterTransferResult;
    inline for (@typeInfo(UpdatedLitter).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result.litter, field.name)))
            return error.NonFiniteSnowpackLitterTransferResult;
    inline for (@typeInfo(SnowpackTotals).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result.snowpack, field.name)))
            return error.NonFiniteSnowpackLitterTransferResult;
    if (result.snow_layer.heat_capacity_megajoules_per_k < 0 or
        result.snow_layer.temperature_k <= 0 or
        result.litter.liquid_m3 < 0 or
        result.litter.vapor_m3 < 0 or
        result.litter.ice_m3 < 0 or
        result.litter.heat_capacity_megajoules_per_k < 0 or
        result.litter.temperature_k <= 0 or
        result.snowpack.total_m3 < 0)
    {
        return error.InvalidSnowpackLitterTransferResult;
    }
    return result;
}

fn validateInputs(inputs: Inputs) !void {
    inline for (@typeInfo(SnowLayer).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(inputs.snow_layer, field.name)))
            return error.NonFiniteSnowpackLitterTransferInput;
    }
    inline for (@typeInfo(SurfaceLitter).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(inputs.litter, field.name)))
            return error.NonFiniteSnowpackLitterTransferInput;
    }
    inline for (@typeInfo(LitterOrganic).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(inputs.litter_organic, field.name)))
            return error.NonFiniteSnowpackLitterTransferInput;
    }
    inline for (@typeInfo(Fluxes).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(inputs.fluxes, field.name)))
            return error.NonFiniteSnowpackLitterTransferInput;
    }
    inline for (@typeInfo(Parameters).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(inputs.parameters, field.name)))
            return error.NonFiniteSnowpackLitterTransferInput;
    }

    const snow = inputs.snow_layer;
    const litter = inputs.litter;
    const organic = inputs.litter_organic;
    const fluxes = inputs.fluxes;
    const p = inputs.parameters;
    if (snow.solid_m3 < 0 or snow.liquid_m3 < 0 or snow.vapor_m3 < 0 or
        snow.ice_m3 < 0 or snow.heat_capacity_megajoules_per_k < 0 or
        snow.temperature_k <= 0 or litter.liquid_m3 < 0 or
        litter.vapor_m3 < 0 or litter.ice_m3 < 0 or
        litter.heat_capacity_megajoules_per_k < 0 or litter.temperature_k <= 0 or
        organic.organic_carbon_g < 0 or organic.charcoal_g < 0)
    {
        return error.InvalidSnowpackLitterTransferState;
    }
    if (fluxes.heat_megajoules <= 0)
        return error.InvalidSnowpackLitterHeatFlux;
    if (fluxes.solid_m3 < 0 or fluxes.liquid_m3 < 0 or
        fluxes.vapor_m3 < 0 or fluxes.ice_m3 < 0)
    {
        return error.InvalidSnowpackLitterFlux;
    }
    if (p.ice_density_megagrams_per_m3 <= 0 or
        p.reset_snow_density_megagrams_per_m3 <= 0 or
        p.min_snow_heat_capacity_megajoules_per_k < 0 or
        p.ambient_temperature_k <= 0 or
        p.min_litter_heat_capacity_megajoules_per_k < 0 or
        p.mineral_layer_temperature_k <= 0)
    {
        return error.InvalidSnowpackLitterTransferParameter;
    }
}

fn defaultInputs() Inputs {
    return .{
        .snow_layer = .{
            .solid_m3 = 0.10,
            .liquid_m3 = 0.05,
            .vapor_m3 = 0.01,
            .ice_m3 = 0.02,
            .temperature_k = 273.0,
            .heat_capacity_megajoules_per_k = 2.095 * 0.10 + 4.19 * (0.05 + 0.01) + 1.9274 * 0.02,
        },
        .litter = .{
            .liquid_m3 = 0.005,
            .vapor_m3 = 0.001,
            .ice_m3 = 0.0,
            .temperature_k = 275.0,
            .heat_capacity_megajoules_per_k = 0.01,
        },
        .litter_organic = .{
            .organic_carbon_g = 500.0,
            .charcoal_g = 10.0,
        },
        .fluxes = .{
            .solid_m3 = 0.05,
            .liquid_m3 = 0.02,
            .vapor_m3 = 0.005,
            .ice_m3 = 0.01,
            .heat_megajoules = 0.1,
        },
        .parameters = .{
            .ice_density_megagrams_per_m3 = 0.917,
            .reset_snow_density_megagrams_per_m3 = 0.10,
            .min_snow_heat_capacity_megajoules_per_k = 1.0e-5,
            .ambient_temperature_k = 273.15,
            .min_litter_heat_capacity_megajoules_per_k = 1.0e-5,
            .mineral_layer_temperature_k = 278.0,
        },
    };
}

test "REDIST snowpack-litter transfer preserves source-order volume balance" {
    const inp = defaultInputs();
    const result = try transfer(inp);

    // Snow layer volumes decrease by fluxes.
    try std.testing.expectApproxEqRel(
        inp.snow_layer.solid_m3 - inp.fluxes.solid_m3,
        result.snow_layer.solid_m3,
        1.0e-15,
    );
    try std.testing.expectApproxEqRel(
        inp.snow_layer.liquid_m3 - inp.fluxes.liquid_m3,
        result.snow_layer.liquid_m3,
        1.0e-15,
    );

    // Litter liquid and vapor increase by fluxes.
    try std.testing.expectApproxEqRel(
        inp.litter.liquid_m3 + inp.fluxes.liquid_m3,
        result.litter.liquid_m3,
        1.0e-15,
    );

    // Litter ice includes solid snow converted by ice density.
    const expected_litter_ice =
        inp.litter.ice_m3 + inp.fluxes.ice_m3 +
        inp.fluxes.solid_m3 / inp.parameters.ice_density_megagrams_per_m3;
    try std.testing.expectApproxEqRel(
        expected_litter_ice,
        result.litter.ice_m3,
        1.0e-15,
    );
}

test "REDIST snowpack-litter transfer applies energy conservation when heat capacity sufficient" {
    const inp = defaultInputs();
    const result = try transfer(inp);

    // Snow temperature: (old energy - heat flux) / new heat capacity.
    const snow_energy = inp.snow_layer.temperature_k * inp.snow_layer.heat_capacity_megajoules_per_k;
    const snow_solid_new = inp.snow_layer.solid_m3 - inp.fluxes.solid_m3;
    const snow_liquid_new = inp.snow_layer.liquid_m3 - inp.fluxes.liquid_m3;
    const snow_vapor_new = inp.snow_layer.vapor_m3 - inp.fluxes.vapor_m3;
    const snow_ice_new = inp.snow_layer.ice_m3 - inp.fluxes.ice_m3;
    const snow_vhcp_new = solid_snow_heat_capacity * snow_solid_new +
        liquid_water_heat_capacity * (snow_liquid_new + snow_vapor_new) +
        ice_heat_capacity * snow_ice_new;
    const expected_snow_temp = (snow_energy - inp.fluxes.heat_megajoules) / snow_vhcp_new;
    try std.testing.expectApproxEqRel(
        expected_snow_temp,
        result.snow_layer.temperature_k,
        1.0e-14,
    );
}

test "REDIST snowpack-litter transfer falls back to ambient when snow heat capacity below threshold" {
    var inp = defaultInputs();
    // Force heat capacity below threshold by making snow layer near-empty.
    inp.snow_layer.solid_m3 = 1.0e-10;
    inp.snow_layer.liquid_m3 = 1.0e-10;
    inp.snow_layer.vapor_m3 = 1.0e-10;
    inp.snow_layer.ice_m3 = 1.0e-10;
    inp.snow_layer.heat_capacity_megajoules_per_k = 1.0e-10;
    inp.fluxes.solid_m3 = 1.0e-11;
    inp.fluxes.liquid_m3 = 1.0e-11;
    inp.fluxes.vapor_m3 = 1.0e-11;
    inp.fluxes.ice_m3 = 1.0e-11;
    // VHCPWX set high so new snow VHCP < threshold.
    inp.parameters.min_snow_heat_capacity_megajoules_per_k = 1.0;
    const result = try transfer(inp);
    try std.testing.expectEqual(
        inp.parameters.ambient_temperature_k,
        result.snow_layer.temperature_k,
    );
}

test "REDIST snowpack-litter transfer rejects non-positive heat flux" {
    var inp = defaultInputs();
    inp.fluxes.heat_megajoules = 0.0;
    try std.testing.expectError(
        error.InvalidSnowpackLitterHeatFlux,
        transfer(inp),
    );
    inp.fluxes.heat_megajoules = -1.0;
    try std.testing.expectError(
        error.InvalidSnowpackLitterHeatFlux,
        transfer(inp),
    );
}

test "REDIST snowpack-litter transfer rejects a phase flux larger than its inventory" {
    var inp = defaultInputs();
    inp.fluxes.vapor_m3 = inp.snow_layer.vapor_m3 + 1.0e-6;
    try std.testing.expectError(
        error.SnowpackLitterFluxExceedsInventory,
        transfer(inp),
    );
}

test "REDIST snowpack-litter transfer rejects non-finite state before mutation" {
    var inp = defaultInputs();
    inp.litter.temperature_k = std.math.nan(f64);
    try std.testing.expectError(
        error.NonFiniteSnowpackLitterTransferInput,
        transfer(inp),
    );
}
