const std = @import("std");
const audit = @import("mass_balance_audit.zig");
const gas = @import("../soil/gas/transport.zig");
const soil_daily_gas = @import("../soil/diagnostics/daily_gas_flux.zig");
const canopy_daily_gas = @import("../canopy/gas/daily_exchange.zig");
const atmospheric_solutes = @import("../atmosphere/atmospheric_solute_inputs.zig");
const snow = @import("../soil/solute/snow_solute_transport.zig");
const snow_discharge = @import("../soil/water/snow_surface_discharge.zig");
const surface_aqueous = @import("../surface/aqueous_runoff_transport.zig");
const solute_species = @import("../soil/solute/transport_species.zig");
const hourly_cell_conservation = @import("hourly_cell_conservation.zig");
const symbiosis = @import("../canopy/symbiosis/plant_symbiotic_fixation.zig");
/// HEAT-001 third layer. Imported for `frozenWaterEnthalpyPerM3` only, so the
/// boundary credit for snowfall and the census's stored snow enthalpy share
/// one definition rather than two agreeing expressions.
const inventory = @import("landscape_mass_inventory.zig");

/// Direction-separated whole-landscape boundary fluxes for one accepted
/// model interval. Every value is nonnegative; the EXEC sign convention is
/// applied only by `mass_balance_audit.balance`.
pub const Fluxes = struct {
    rain_m3: f64 = 0,
    boundary_water_inflow_m3: f64 = 0,
    runoff_m3: f64 = 0,
    evaporation_m3: f64 = 0,
    water_outflow_m3: f64 = 0,
    heat_input_megajoules: f64 = 0,
    heat_output_megajoules: f64 = 0,
    oxygen_input_g: f64 = 0,
    oxygen_output_g: f64 = 0,
    redist_carbon_surface_input_g_c: f64 = 0,
    redist_carbon_subsurface_output_g_c: f64 = 0,
    redist_oxygen_surface_input_g_o: f64 = 0,
    redist_oxygen_subsurface_output_g_o: f64 = 0,
    redist_hydrogen_surface_input_g_h: f64 = 0,
    redist_hydrogen_subsurface_output_g_h: f64 = 0,
    carbon_dioxide_input_g_c: f64 = 0,
    carbon_output_g_c: f64 = 0,
    organic_fertilizer_carbon_g_c: f64 = 0,
    carbon_sink_g_c: f64 = 0,
    dinitrogen_input_g_n: f64 = 0,
    nitrogen_input_g_n: f64 = 0,
    nitrogen_output_g_n: f64 = 0,
    organic_fertilizer_nitrogen_g_n: f64 = 0,
    nitrogen_sink_g_n: f64 = 0,
    phosphorus_input_g_p: f64 = 0,
    phosphorus_output_g_p: f64 = 0,
    organic_fertilizer_phosphorus_g_p: f64 = 0,
    phosphorus_sink_g_p: f64 = 0,
    ion_input_mol: f64 = 0,
    ion_output_mol: f64 = 0,
    plant_root_organic_uptake_g_c: f64 = 0,
    plant_root_organic_exudate_g_c: f64 = 0,
    plant_root_organic_uptake_g_n: f64 = 0,
    plant_root_organic_exudate_g_n: f64 = 0,
    plant_root_organic_uptake_g_p: f64 = 0,
    plant_root_organic_exudate_g_p: f64 = 0,
    // Appended to preserve the serialized order of every pre-v1.0 field.
    hydrogen_input_g: f64 = 0,
    hydrogen_output_g: f64 = 0,
    // Element-resolved accepted-hour activity. These are the conservative
    // quantities; legacy ion_input/output above remain a REDIST SSB
    // diagnostic and must never decide production acceptance.
    aluminum_input_mol: f64 = 0,
    aluminum_output_mol: f64 = 0,
    iron_input_mol: f64 = 0,
    iron_output_mol: f64 = 0,
    calcium_input_mol: f64 = 0,
    calcium_output_mol: f64 = 0,
    magnesium_input_mol: f64 = 0,
    magnesium_output_mol: f64 = 0,
    sodium_input_mol: f64 = 0,
    sodium_output_mol: f64 = 0,
    potassium_input_mol: f64 = 0,
    potassium_output_mol: f64 = 0,
    sulfur_input_mol: f64 = 0,
    sulfur_output_mol: f64 = 0,
    chloride_input_mol: f64 = 0,
    chloride_output_mol: f64 = 0,
    silicon_input_mol: f64 = 0,
    silicon_output_mol: f64 = 0,
    sand_input_megagrams: f64 = 0,
    sand_output_megagrams: f64 = 0,
    silt_input_megagrams: f64 = 0,
    silt_output_megagrams: f64 = 0,
    clay_input_megagrams: f64 = 0,
    clay_output_megagrams: f64 = 0,
    // GROSUB WTNDI is an external biological inoculum, distinct from
    // atmospheric CO2/N2, fertilizer, and internal host/symbiont transfers.
    // Appended to preserve the serialized order of every earlier field.
    symbiotic_inoculum_carbon_input_g_c: f64 = 0,
    symbiotic_inoculum_nitrogen_input_g_n: f64 = 0,
    symbiotic_inoculum_phosphorus_input_g_p: f64 = 0,
    cation_exchange_capacity_input_mol: f64 = 0,
    cation_exchange_capacity_output_mol: f64 = 0,
    anion_exchange_capacity_input_mol: f64 = 0,
    anion_exchange_capacity_output_mol: f64 = 0,
    // CaCO3 amendment carbon is neither atmospheric CO2 nor organic matter.
    // Appended for explicit checkpointed boundary provenance.
    mineral_fertilizer_carbon_g_c: f64 = 0,
};

/// Accepted transformations that create or consume an audited species
/// without crossing the landscape boundary. H2 is audited as a gas pool, not
/// as total elemental hydrogen in water/organic matter, so fermentation and
/// hydrogenotrophic methanogenesis must appear explicitly in its identity.
pub const InternalProcesses = struct {
    heat_production_megajoules: f64 = 0,
    heat_consumption_megajoules: f64 = 0,
    oxygen_production_g_o: f64 = 0,
    oxygen_consumption_g_o: f64 = 0,
    hydrogen_production_g_h: f64 = 0,
    hydrogen_consumption_g_h: f64 = 0,
    cation_exchange_capacity_production_mol: f64 = 0,
    cation_exchange_capacity_consumption_mol: f64 = 0,
    anion_exchange_capacity_production_mol: f64 = 0,
    anion_exchange_capacity_consumption_mol: f64 = 0,
};

// WTNDI inoculum is not biological N2 fixation: it creates initial bacterial
// C/N/P and is recorded explicitly above. Subsequent GROSUB symbiotic fixed N
// reaches `nitrogen_input_g_n` through the accepted atmospheric-gas owner.
// NITRO nonsymbiotic fixation remains an internal transfer: accepted soil and
// surface updates remove the fixed mass from dissolved N2 while adding it to
// microbial organic N, so an extra boundary input would double-count it.

/// Authoritative thermodynamic controls for precipitation enthalpy. No field
/// has a default: the runscript owner must supply the same values used by the
/// snow and soil phase/storage calculations.
pub const PrecipitationHeatParameters = struct {
    snow_latent_heat_of_fusion_megajoules_per_m3: f64,
    solid_snow_heat_capacity_megajoules_per_m3_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    pure_water_melting_temperature_k: f64,

    fn validate(self: PrecipitationHeatParameters) !void {
        inline for (std.meta.fields(PrecipitationHeatParameters)) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value <= 0)
                return error.InvalidPrecipitationHeatParameter;
        }
    }
};

pub const State = struct {
    cumulative: Fluxes = .{},
    cumulative_internal: InternalProcesses = .{},

    /// Validates the complete persisted ledger using the same invariants as
    /// live publication. The six REDIST compatibility diagnostics retain the
    /// source model's signed convention; every physical direction-separated
    /// boundary and internal-process field remains nonnegative.
    pub fn validateCheckpointState(self: State) !void {
        try validate(self.cumulative);
        try validateInternal(self.cumulative_internal);
    }

    pub fn accumulateAccepted(self: *State, fluxes: Fluxes) !void {
        try validate(fluxes);
        var next = self.cumulative;
        inline for (std.meta.fields(Fluxes)) |field| {
            const value = @field(next, field.name) + @field(fluxes, field.name);
            if (!std.math.isFinite(value))
                return error.LandscapeBoundaryLedgerOverflow;
            @field(next, field.name) = value;
        }
        self.cumulative = next;
    }

    pub fn reset(self: *State) void {
        self.cumulative = .{};
        self.cumulative_internal = .{};
    }

    /// Atomically consumes one fixed-hour WTNDI activity per horizontal cell.
    /// The cell ledger gates local closure; the explicit landscape fields
    /// preserve accumulated/domain provenance. Successful publication clears
    /// the source buffer, making accidental repeated calls a no-op rather
    /// than a double count. The enclosing outer-hour transaction restores all
    /// three owners on any later failure.
    pub fn accumulateAcceptedSymbioticInoculum(
        self: *State,
        hourly_ledger: *hourly_cell_conservation.BoundaryLedger,
        input_by_cell: []symbiosis.Pool,
    ) !void {
        if (input_by_cell.len == 0 or input_by_cell.len != hourly_ledger.cells.len)
            return error.LandscapeBoundaryGridDimensionMismatch;
        var total: symbiosis.Pool = .{
            .carbon_g_c = 0,
            .nitrogen_g_n = 0,
            .phosphorus_g_p = 0,
        };
        for (input_by_cell, 0..) |input, cell| {
            try symbiosis.accumulateExternalInput(&total, input);
            try hourly_ledger.preflight(cell, .{
                .carbon_input_g = input.carbon_g_c,
                .nitrogen_input_g = input.nitrogen_g_n,
                .phosphorus_input_g = input.phosphorus_g_p,
            });
        }
        var landscape_candidate = self.*;
        try landscape_candidate.accumulateAccepted(.{
            .symbiotic_inoculum_carbon_input_g_c = total.carbon_g_c,
            .symbiotic_inoculum_nitrogen_input_g_n = total.nitrogen_g_n,
            .symbiotic_inoculum_phosphorus_input_g_p = total.phosphorus_g_p,
        });
        // Preflight above used these exact current ledgers and values. No
        // fallible action remains after the first live publication.
        for (input_by_cell, 0..) |input, cell|
            hourly_ledger.accumulate(cell, .{
                .carbon_input_g = input.carbon_g_c,
                .nitrogen_input_g = input.nitrogen_g_n,
                .phosphorus_input_g = input.phosphorus_g_p,
            }) catch unreachable;
        self.* = landscape_candidate;
        @memset(input_by_cell, .{
            .carbon_g_c = 0,
            .nitrogen_g_n = 0,
            .phosphorus_g_p = 0,
        });
    }

    /// Reduces the already-accepted hourly cell ledger into the accumulated
    /// domain element ledger. Internal intercell transfers publish equal
    /// donor outputs and recipient inputs, so they cancel in the domain
    /// identity while remaining visible to the authoritative cell gate.
    /// Reduction and cumulative publication are both staged: an invalid cell
    /// or overflow leaves the complete domain ledger unchanged.
    pub fn accumulateAcceptedHourlyCellElements(
        self: *State,
        activities: []const hourly_cell_conservation.BoundaryActivity,
    ) !void {
        if (activities.len == 0) return error.EmptyLandscapeBoundaryGrid;
        var fluxes: Fluxes = .{};
        var capacity_internal: InternalProcesses = .{};
        for (activities) |activity| {
            inline for (std.meta.fields(inventory.ElementMoles)) |element| {
                inline for (.{ "input", "output" }) |direction| {
                    const field_name = element.name ++ "_" ++ direction ++ "_mol";
                    const amount = @field(activity, field_name);
                    if (!std.math.isFinite(amount) or amount < 0)
                        return error.InvalidHourlyElementBoundaryActivity;
                    @field(fluxes, field_name) = try addFinite(
                        @field(fluxes, field_name),
                        amount,
                    );
                }
            }
            inline for (.{ "sand", "silt", "clay" }) |mineral| {
                inline for (.{ "input", "output" }) |direction| {
                    const field_name = mineral ++ "_" ++ direction ++ "_megagrams";
                    const amount = @field(activity, field_name);
                    if (!std.math.isFinite(amount) or amount < 0)
                        return error.InvalidHourlyElementBoundaryActivity;
                    @field(fluxes, field_name) = try addFinite(@field(fluxes, field_name), amount);
                }
            }
            inline for (.{ "cation_exchange_capacity", "anion_exchange_capacity" }) |capacity| {
                inline for (.{ "input", "output" }) |direction| {
                    const field_name = capacity ++ "_" ++ direction ++ "_mol";
                    const amount = @field(activity, field_name);
                    if (!std.math.isFinite(amount) or amount < 0)
                        return error.InvalidHourlyElementBoundaryActivity;
                    @field(fluxes, field_name) = try addFinite(@field(fluxes, field_name), amount);
                }
                inline for (.{ "production", "consumption" }) |direction| {
                    const cell_field = capacity ++ "_internal_" ++ direction ++ "_mol";
                    const domain_field = capacity ++ "_" ++ direction ++ "_mol";
                    const amount = @field(activity, cell_field);
                    if (!std.math.isFinite(amount) or amount < 0)
                        return error.InvalidHourlyElementBoundaryActivity;
                    @field(capacity_internal, domain_field) = try addFinite(
                        @field(capacity_internal, domain_field),
                        amount,
                    );
                }
            }
        }
        var candidate = self.*;
        try candidate.accumulateAccepted(fluxes);
        inline for (.{ "cation_exchange_capacity", "anion_exchange_capacity" }) |capacity| {
            inline for (.{ "production", "consumption" }) |direction| {
                const field_name = capacity ++ "_" ++ direction ++ "_mol";
                @field(candidate.cumulative_internal, field_name) = try addFinite(
                    @field(candidate.cumulative_internal, field_name),
                    @field(capacity_internal, field_name),
                );
            }
        }
        self.* = candidate;
    }

    /// NITRO `RH2GO=RH2GZ-TRGOH` split into its physical directions.
    /// Soil and surface fermentation publish H2-H; hydrogenotrophic
    /// methanogenesis consumes H2-H. The update is staged so invalid input or
    /// cumulative overflow leaves both cumulative fields unchanged.
    pub fn accumulateAcceptedHydrogenTransformations(
        self: *State,
        soil_fermentation_production_g_h: []const f64,
        soil_methanogenesis_consumption_g_h: []const f64,
        surface_fermentation_production_g_h: []const f64,
    ) !void {
        // The production owner is process-unit indexed, whereas the methane
        // sink is layer indexed.  Requiring equal lengths would reject every
        // real runtime layout; only each owner's presence is required here.
        if (soil_fermentation_production_g_h.len == 0 or
            soil_methanogenesis_consumption_g_h.len == 0 or
            surface_fermentation_production_g_h.len == 0)
            return error.HydrogenTransformationDimensionMismatch;
        const production = try addFinite(
            try sumNonnegative(soil_fermentation_production_g_h),
            try sumNonnegative(surface_fermentation_production_g_h),
        );
        const consumption = try sumNonnegative(soil_methanogenesis_consumption_g_h);
        try self.accumulateAcceptedHydrogenTransformationTotals(production, consumption);
    }

    /// Scalar entry point for callers that must exclude inactive-capacity
    /// slots before reduction. Both directions are preflighted before either
    /// cumulative owner changes.
    pub fn accumulateAcceptedHydrogenTransformationTotals(
        self: *State,
        production_g_h: f64,
        consumption_g_h: f64,
    ) !void {
        inline for (.{ production_g_h, consumption_g_h }) |value| {
            if (!std.math.isFinite(value)) return error.NonFiniteLandscapeBoundaryFlux;
            if (value < 0) return error.NegativeLandscapeBoundaryFlux;
        }
        var next = self.cumulative_internal;
        next.hydrogen_production_g_h = try addFinite(next.hydrogen_production_g_h, production_g_h);
        next.hydrogen_consumption_g_h = try addFinite(next.hydrogen_consumption_g_h, consumption_g_h);
        self.cumulative_internal = next;
    }

    /// Irreversible biochemical and combustion consumption of inventoried O2
    /// is an internal process, not a landscape-boundary export. This scalar
    /// entry point stages the cumulative update so overflow cannot partially
    /// publish provenance.
    pub fn accumulateAcceptedOxygenConsumptionTotal(
        self: *State,
        consumption_g_o: f64,
    ) !void {
        try self.accumulateAcceptedOxygenTransformationTotals(0, consumption_g_o);
    }

    /// Scalar gross O2 reaction entry point. Both directions are staged so a
    /// failure can never publish photosynthetic production without its paired
    /// respiratory/combustion consumption (or vice versa).
    pub fn accumulateAcceptedOxygenTransformationTotals(
        self: *State,
        production_g_o: f64,
        consumption_g_o: f64,
    ) !void {
        inline for (.{ production_g_o, consumption_g_o }) |value| {
            if (!std.math.isFinite(value)) return error.NonFiniteLandscapeBoundaryFlux;
            if (value < 0) return error.NegativeLandscapeBoundaryFlux;
        }
        var next = self.cumulative_internal;
        next.oxygen_production_g_o = try addFinite(
            next.oxygen_production_g_o,
            production_g_o,
        );
        next.oxygen_consumption_g_o = try addFinite(
            next.oxygen_consumption_g_o,
            consumption_g_o,
        );
        self.cumulative_internal = next;
    }

    /// Subsurface microbial O2 consumption (legacy `OXYGOU` via `RUPOXO`
    /// in `redist.f:627`). The oxygen solver removes this mass from the
    /// gaseous/aqueous soil pools, which the landscape inventory counts as
    /// storage. It is therefore explicit internal consumption in the audited
    /// O2-species identity, not an external landscape output.
    pub fn accumulateAcceptedSoilMicrobialOxygenUptake(
        self: *State,
        oxygen_uptake_g_o: []const f64,
    ) !void {
        const term = try sumNonnegative(oxygen_uptake_g_o);
        std.log.debug("oxygen internal term: microbial_uptake_consumption_g_o={e}", .{term});
        try self.accumulateAcceptedOxygenConsumptionTotal(term);
    }

    /// Root metabolic O2 consumption from the two authoritative sources used
    /// by UPTAKE: soil dissolved O2 (`TUPOXS`) and root aqueous O2 (`TUPOXP`).
    /// Both sources are counted by the landscape inventory and both are
    /// irreversibly consumed. REDIST combines them into `OXYGOU`
    /// (`redist.f:6580--6582`), but the modern provenance ledger separates
    /// this internal reaction from true boundary export. The two arrays are accepted current-hour,
    /// cell-layer aggregates; validate both completely before publication.
    pub fn accumulateAcceptedRootOxygenUptake(
        self: *State,
        soil_oxygen_uptake_g_o: []const f64,
        root_pool_oxygen_uptake_g_o: []const f64,
    ) !void {
        try requireSameNonzeroLength(.{
            soil_oxygen_uptake_g_o,
            root_pool_oxygen_uptake_g_o,
        });
        const term = try addFinite(
            try sumNonnegative(soil_oxygen_uptake_g_o),
            try sumNonnegative(root_pool_oxygen_uptake_g_o),
        );
        std.log.debug("oxygen internal term: root_uptake_consumption_g_o={e}", .{term});
        try self.accumulateAcceptedOxygenConsumptionTotal(term);
    }

    /// Accepted internal O2 sinks from the litter microbial/fire producers
    /// and the active subsurface fire layers. These are the reaction-only
    /// pieces of legacy `OXYGOU` (`redist.f:4498--4500,6580--6582`); physical
    /// REDIST gas and irrigation terms are owned by separate boundary ledgers
    /// and must not be folded into this booking. Inactive layer capacity is not
    /// scientific storage and is deliberately excluded.
    pub fn accumulateAcceptedSurfaceMicrobialAndFireOxygenUptake(
        self: *State,
        active_soil_layer_count: []const usize,
        soil_layer_capacity: usize,
        surface_microbial_units_per_cell: usize,
        surface_microbial_oxygen_uptake_g_o: []const f64,
        surface_fire_oxygen_consumption_g_o: []const f64,
        subsurface_fire_oxygen_consumption_g_o: []const f64,
    ) !void {
        const cell_count = active_soil_layer_count.len;
        if (cell_count == 0) return error.EmptyLandscapeBoundaryGrid;
        if (soil_layer_capacity == 0 or surface_microbial_units_per_cell == 0)
            return error.LandscapeBoundaryGridDimensionMismatch;
        const expected_surface_units = try std.math.mul(
            usize,
            cell_count,
            surface_microbial_units_per_cell,
        );
        const expected_soil_layers = try std.math.mul(
            usize,
            cell_count,
            soil_layer_capacity,
        );
        if (surface_microbial_oxygen_uptake_g_o.len != expected_surface_units or
            surface_fire_oxygen_consumption_g_o.len != cell_count or
            subsurface_fire_oxygen_consumption_g_o.len != expected_soil_layers)
            return error.LandscapeBoundaryGridDimensionMismatch;

        var term = try addFinite(
            try sumNonnegative(surface_microbial_oxygen_uptake_g_o),
            try sumNonnegative(surface_fire_oxygen_consumption_g_o),
        );
        for (active_soil_layer_count, 0..) |active_layers, cell| {
            if (active_layers > soil_layer_capacity)
                return error.LandscapeBoundaryGridDimensionMismatch;
            const first = cell * soil_layer_capacity;
            term = try addFinite(
                term,
                try sumNonnegative(
                    subsurface_fire_oxygen_consumption_g_o[first..][0..active_layers],
                ),
            );
        }
        std.log.debug("oxygen internal term: surface_microbial_and_fire_consumption_g_o={e}", .{term});
        try self.accumulateAcceptedOxygenConsumptionTotal(term);
    }

    /// Dissolved O2 carried off the landscape by surface runoff (legacy
    /// `OXS=XN*XOXQSS` then `OXYGOU=OXYGOU-OXS`, `redist.f:1095`). The surface
    /// dissolved-gas runoff carrier removes this mass from litter storage, so
    /// it must be booked as a boundary output or the audit sees a storage loss.
    pub fn accumulateAcceptedSurfaceDissolvedOxygenRunoff(
        self: *State,
        oxygen_export_g_o: []const f64,
    ) !void {
        const term = try sumNonnegative(oxygen_export_g_o);
        std.log.debug("oxygen boundary term: surface_runoff_output_g_o={e}", .{term});
        try self.accumulateAccepted(.{
            .oxygen_output_g = term,
        });
    }

    /// Accepted N2/N2O and H2 leaving in surface runoff. The mineral/DON
    /// daily export ledger excludes these gas pools; O2 and inorganic C have
    /// their own existing runoff owners. Only external exports belong here,
    /// not the paired intercell transfers consumed by the local gates.
    pub fn accumulateAcceptedSurfaceDissolvedNitrogenHydrogenRunoff(
        self: *State,
        nitrogen_export_g_n: []const f64,
        hydrogen_export_g_h: []const f64,
    ) !void {
        try requireSameNonzeroLength(.{ nitrogen_export_g_n, hydrogen_export_g_h });
        const nitrogen = try sumNonnegative(nitrogen_export_g_n);
        const hydrogen = try sumNonnegative(hydrogen_export_g_h);
        try self.accumulateAccepted(.{
            .nitrogen_output_g_n = nitrogen,
            .hydrogen_output_g = hydrogen,
        });
    }

    /// Accepted dissolved O2/H2 carried across external soil-water faces.
    /// These fluxes are distinct from dry-gas atmospheric/subsurface faces
    /// and from surface runoff.  The hourly cell gate consumes this same
    /// layer/species array in `accumulateDissolvedGasTransport`; reducing it
    /// here keeps the whole-landscape gas-species identity on the identical
    /// accepted producer.  Carbon and nitrogen remain owned by their existing
    /// drainage ledgers and are deliberately not booked a second time.
    pub fn accumulateAcceptedDissolvedGasExternalBoundaries(
        self: *State,
        active_by_layer: []const bool,
        boundary_net_flux_g: []const f64,
    ) !void {
        const expected_flux_count = std.math.mul(
            usize,
            active_by_layer.len,
            gas.species_count,
        ) catch return error.LandscapeBoundaryGridDimensionMismatch;
        if (active_by_layer.len == 0 or
            boundary_net_flux_g.len != expected_flux_count)
            return error.LandscapeBoundaryGridDimensionMismatch;

        var oxygen_input_g: f64 = 0;
        var oxygen_output_g: f64 = 0;
        var hydrogen_input_g: f64 = 0;
        var hydrogen_output_g: f64 = 0;
        for (active_by_layer, 0..) |active, layer| {
            if (!active) continue;
            const first = layer * gas.species_count;
            try splitSignedAtmosphereFlux(
                &oxygen_input_g,
                &oxygen_output_g,
                boundary_net_flux_g[first + @intFromEnum(gas.Species.oxygen)],
            );
            try splitSignedAtmosphereFlux(
                &hydrogen_input_g,
                &hydrogen_output_g,
                boundary_net_flux_g[first + @intFromEnum(gas.Species.hydrogen)],
            );
        }
        try self.accumulateAccepted(.{
            .oxygen_input_g = oxygen_input_g,
            .oxygen_output_g = oxygen_output_g,
            .hydrogen_input_g = hydrogen_input_g,
            .hydrogen_output_g = hydrogen_output_g,
        });
    }

    pub fn accumulateAcceptedWater(
        self: *State,
        rainfall_m3: []const f64,
        boundary_water_inflow_m3: []const f64,
        runoff_m3: []const f64,
        evaporation_m3: []const f64,
        water_outflow_m3: []const f64,
        artificial_drainage_outflow_m3: []const f64,
    ) !void {
        try requireSameNonzeroLength(.{
            rainfall_m3,
            boundary_water_inflow_m3,
            runoff_m3,
            evaporation_m3,
            water_outflow_m3,
            artificial_drainage_outflow_m3,
        });
        try self.accumulateAccepted(.{
            .rain_m3 = try sumNonnegative(rainfall_m3),
            .boundary_water_inflow_m3 = try sumNonnegative(boundary_water_inflow_m3),
            .runoff_m3 = try sumNonnegative(runoff_m3),
            .evaporation_m3 = try sumNonnegative(evaporation_m3),
            // The accepted Richards external boundary residual already
            // contains artificial drainage. Keep its process diagnostic in
            // the daily ledger, but do not count it a second time here.
            .water_outflow_m3 = try sumNonnegative(water_outflow_m3),
        });
        _ = try sumNonnegative(artificial_drainage_outflow_m3);
    }

    /// Atmospheric sensible heat carried into the landscape by liquid
    /// precipitation (including irrigation already merged with rain) and
    /// snowfall water equivalent. This is evaluated before canopy/snow/
    /// litter/soil routing so intercepted water is included exactly once.
    ///
    /// Snowfall crosses the boundary as solid SWE, so it carries the same
    /// `C_l*Tm - L + C_s*(T-Tm)` branch stored by the snow census. This is an
    /// external mass-carrier enthalpy, not an internal phase-change booking.
    ///
    /// The credited value is the same solid-snow branch the census stores:
    /// `C_l*Tm - L + C_s*(T-Tm)` per m3 SWE. It calls the census's own exported
    /// definition so the two sides cannot drift.
    pub fn accumulateAcceptedPrecipitationHeat(
        self: *State,
        liquid_water_depth_m: []const f64,
        snowfall_water_equivalent_depth_m: []const f64,
        cell_area_m2: []const f64,
        atmospheric_temperature_k: []const f64,
        parameters: PrecipitationHeatParameters,
        heat_megajoules_by_cell: []f64,
    ) !void {
        try parameters.validate();
        try requireSameNonzeroLength(.{
            liquid_water_depth_m,
            snowfall_water_equivalent_depth_m,
            cell_area_m2,
            atmospheric_temperature_k,
            heat_megajoules_by_cell,
        });
        var heat_input_megajoules: f64 = 0;
        var diagnostic_snowfall_water_equivalent_m3: f64 = 0;
        var diagnostic_rainfall_m3: f64 = 0;
        // First pass validates and stages the scalar without touching either
        // the caller's per-cell output or the cumulative ledger.
        for (
            liquid_water_depth_m,
            snowfall_water_equivalent_depth_m,
            cell_area_m2,
            atmospheric_temperature_k,
        ) |liquid_depth_m, snow_depth_m, area_m2, temperature_k| {
            inline for (.{ liquid_depth_m, snow_depth_m, area_m2, temperature_k }) |value|
                if (!std.math.isFinite(value))
                    return error.NonFiniteLandscapeBoundaryFlux;
            if (liquid_depth_m < 0 or snow_depth_m < 0 or area_m2 <= 0 or temperature_k <= 0)
                return error.InvalidPrecipitationHeatBoundaryInput;
            // Liquid precipitation is pure sensible `C_l*T` on this reference
            // state, unchanged, and it is what the liquid carriers store.
            const cell_liquid_heat_megajoules = temperature_k * area_m2 *
                parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
                liquid_depth_m;
            // Snowfall arrives in the solid-snow carrier, so it is credited
            // the same `C_s` frozen enthalpy the snow census will store.
            const snowfall_enthalpy_megajoules_per_m3 = try inventory.frozenWaterEnthalpyPerM3(
                temperature_k,
                parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                parameters.solid_snow_heat_capacity_megajoules_per_m3_k,
                parameters.snow_latent_heat_of_fusion_megajoules_per_m3,
                parameters.pure_water_melting_temperature_k,
            );
            const cell_snowfall_heat_megajoules =
                snowfall_enthalpy_megajoules_per_m3 * snow_depth_m * area_m2;
            const cell_heat_megajoules =
                cell_liquid_heat_megajoules + cell_snowfall_heat_megajoules;
            if (!std.math.isFinite(cell_heat_megajoules))
                return error.LandscapeBoundaryLedgerOverflow;
            heat_input_megajoules = try addFinite(
                heat_input_megajoules,
                cell_heat_megajoules,
            );
            diagnostic_snowfall_water_equivalent_m3 += snow_depth_m * area_m2;
            diagnostic_rainfall_m3 += liquid_depth_m * area_m2;
        }
        std.log.debug("heat latent instrument: precipitation snowfall_swe_m3={e} rain_m3={e} cumulative_snow_swe_m3={e}", .{ diagnostic_snowfall_water_equivalent_m3, diagnostic_rainfall_m3, diagnostic_snowfall_water_equivalent_m3 });
        try self.accumulateAcceptedSignedHeat(heat_input_megajoules);
        // The ledger commit above is the only fallible action after the
        // preflight. Recompute the exact cell expression only after it has
        // accepted, so failed calls leave both owners unchanged.
        for (
            liquid_water_depth_m,
            snowfall_water_equivalent_depth_m,
            cell_area_m2,
            atmospheric_temperature_k,
            heat_megajoules_by_cell,
        ) |liquid_depth_m, snow_depth_m, area_m2, temperature_k, *cell_heat| {
            const frozen_enthalpy = try inventory.frozenWaterEnthalpyPerM3(
                temperature_k,
                parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                parameters.solid_snow_heat_capacity_megajoules_per_m3_k,
                parameters.snow_latent_heat_of_fusion_megajoules_per_m3,
                parameters.pure_water_melting_temperature_k,
            );
            cell_heat.* = area_m2 *
                (parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
                    temperature_k * liquid_depth_m + frozen_enthalpy * snow_depth_m);
        }
    }

    /// Source HEATH plus THFLXC boundary accounting. Ground flux components
    /// are positive into the surface and expressed per horizontal area.
    /// Canopy water-energy changes are already extensive signed MJ and retain
    /// EXTRACT's exact current-minus-previous-minus-retained-rain equation.
    pub fn accumulateAcceptedSurfaceAndCanopyHeat(
        self: *State,
        ground_net_radiation_megajoules_per_m2: []const f64,
        ground_sensible_heat_megajoules_per_m2: []const f64,
        ground_latent_heat_megajoules_per_m2: []const f64,
        ground_vapor_sensible_heat_megajoules_per_m2: []const f64,
        cell_area_m2: []const f64,
        canopy_water_energy_change_megajoules: []const f64,
    ) !void {
        try requireSameNonzeroLength(.{
            ground_net_radiation_megajoules_per_m2,
            ground_sensible_heat_megajoules_per_m2,
            ground_latent_heat_megajoules_per_m2,
            ground_vapor_sensible_heat_megajoules_per_m2,
            cell_area_m2,
        });
        var signed_heat_into_landscape_megajoules: f64 = 0;
        for (
            ground_net_radiation_megajoules_per_m2,
            ground_sensible_heat_megajoules_per_m2,
            ground_latent_heat_megajoules_per_m2,
            ground_vapor_sensible_heat_megajoules_per_m2,
            cell_area_m2,
        ) |net_radiation, sensible, latent, vapor_sensible, area_m2| {
            inline for (.{ net_radiation, sensible, latent, vapor_sensible, area_m2 }) |value|
                if (!std.math.isFinite(value))
                    return error.NonFiniteLandscapeBoundaryFlux;
            if (area_m2 <= 0) return error.InvalidSurfaceHeatBoundaryArea;
            signed_heat_into_landscape_megajoules = try addFinite(
                signed_heat_into_landscape_megajoules,
                (net_radiation + sensible + latent + vapor_sensible) * area_m2,
            );
        }
        for (canopy_water_energy_change_megajoules) |change_megajoules| {
            if (!std.math.isFinite(change_megajoules))
                return error.NonFiniteLandscapeBoundaryFlux;
            signed_heat_into_landscape_megajoules =
                try addFinite(signed_heat_into_landscape_megajoules, change_megajoules);
        }
        try self.accumulateAccepted(.{
            .heat_input_megajoules = @max(0, signed_heat_into_landscape_megajoules),
            .heat_output_megajoules = @max(0, -signed_heat_into_landscape_megajoules),
        });
    }

    pub fn accumulateAcceptedSignedHeat(
        self: *State,
        signed_heat_into_landscape_megajoules: f64,
    ) !void {
        if (!std.math.isFinite(signed_heat_into_landscape_megajoules))
            return error.NonFiniteLandscapeBoundaryFlux;
        try self.accumulateAccepted(.{
            .heat_input_megajoules = @max(0, signed_heat_into_landscape_megajoules),
            .heat_output_megajoules = @max(0, -signed_heat_into_landscape_megajoules),
        });
    }

    /// Accepted heat created/consumed within the ecosystem control volume.
    /// Positive is internal production; negative is internal consumption.
    pub fn accumulateAcceptedSignedInternalHeat(
        self: *State,
        signed_heat_megajoules: f64,
    ) !void {
        if (!std.math.isFinite(signed_heat_megajoules))
            return error.NonFiniteLandscapeBoundaryFlux;
        try self.accumulateAcceptedHeatTransformationTotals(
            @max(0, signed_heat_megajoules),
            @max(0, -signed_heat_megajoules),
        );
    }

    pub fn accumulateAcceptedHeatTransformationTotals(
        self: *State,
        production_megajoules: f64,
        consumption_megajoules: f64,
    ) !void {
        inline for (.{ production_megajoules, consumption_megajoules }) |value| {
            if (!std.math.isFinite(value)) return error.NonFiniteLandscapeBoundaryFlux;
            if (value < 0) return error.NegativeLandscapeBoundaryFlux;
        }
        var next = self.cumulative_internal;
        next.heat_production_megajoules = try addFinite(next.heat_production_megajoules, production_megajoules);
        next.heat_consumption_megajoules = try addFinite(next.heat_consumption_megajoules, consumption_megajoules);
        self.cumulative_internal = next;
    }

    /// Accepted litter/surface combustion heat is an internal energy
    /// production term whose chemical-energy source is outside the audited
    /// thermal-storage census. The surface temperature residual consumes this
    /// exact delayed owner as an extensive MJ source; publish it once, without
    /// attempting to recover it from the mixed residual or heat-source arrays.
    pub fn accumulateAcceptedSurfaceCombustionHeat(
        self: *State,
        combustion_heat_megajoules_by_cell: []const f64,
    ) !void {
        if (combustion_heat_megajoules_by_cell.len == 0)
            return error.EmptyLandscapeBoundaryGrid;
        try self.accumulateAcceptedHeatTransformationTotals(
            try sumNonnegative(combustion_heat_megajoules_by_cell),
            0,
        );
    }

    /// Accepted active-layer soil combustion heat plus the signed convective
    /// heat carried by root water uptake. Combustion is consumed by WATSUB's
    /// heat-source owner; current root heat is published with TUPWTR after
    /// UPTAKE, while restored legacy checkpoint heat may still be consumed by
    /// WATSUB. Neither is part of the solver's external-face diagnostic.
    /// REDIST books `HCBFX` and signed `TUPHT` into `HEATIN`; positive root
    /// heat is therefore input and negative root heat is output. Inactive
    /// layer capacity is not scientific storage and is deliberately ignored.
    pub fn accumulateAcceptedSubsurfaceCombustionAndRootHeat(
        self: *State,
        active_soil_layer_count: []const usize,
        soil_layer_capacity: usize,
        combustion_heat_megajoules_by_layer: []const f64,
        root_uptake_heat_megajoules_by_layer: []const f64,
    ) !void {
        const cell_count = active_soil_layer_count.len;
        if (cell_count == 0) return error.EmptyLandscapeBoundaryGrid;
        if (soil_layer_capacity == 0 or
            combustion_heat_megajoules_by_layer.len != try std.math.mul(usize, cell_count, soil_layer_capacity) or
            root_uptake_heat_megajoules_by_layer.len != combustion_heat_megajoules_by_layer.len)
            return error.LandscapeBoundaryGridDimensionMismatch;

        var production_megajoules: f64 = 0;
        var consumption_megajoules: f64 = 0;
        for (active_soil_layer_count, 0..) |active_layers, cell| {
            if (active_layers > soil_layer_capacity)
                return error.LandscapeBoundaryGridDimensionMismatch;
            const first = cell * soil_layer_capacity;
            for (0..active_layers) |local_layer| {
                const layer = first + local_layer;
                const combustion = combustion_heat_megajoules_by_layer[layer];
                const root = root_uptake_heat_megajoules_by_layer[layer];
                if (!std.math.isFinite(combustion) or !std.math.isFinite(root))
                    return error.NonFiniteLandscapeBoundaryFlux;
                if (combustion < 0) return error.NegativeLandscapeBoundaryFlux;
                production_megajoules = try addFinite(production_megajoules, combustion);
                if (root >= 0)
                    production_megajoules = try addFinite(production_megajoules, root)
                else
                    consumption_megajoules = try addFinite(consumption_megajoules, -root);
            }
        }
        try self.accumulateAcceptedHeatTransformationTotals(
            production_megajoules,
            consumption_megajoules,
        );
    }

    /// Whole-landscape counterpart of the cell/surface endpoint-reference
    /// ledger. The surface residual already carries fusion latent heat; only
    /// the fixed liquid/ice reference and represented internal-vapor latent
    /// terms remain internal production/consumption.
    pub fn accumulateAcceptedSurfaceEndpointReferenceHeat(
        self: *State,
        ice_water_equivalent_change_m3: []const f64,
        internal_vapor_water_change_m3: []const f64,
        liquid_heat_capacity_megajoules_per_m3_k: f64,
        ice_heat_capacity_per_water_equivalent_m3_k: f64,
        pure_water_melting_temperature_k: f64,
        latent_heat_of_vaporization_megajoules_per_m3: f64,
    ) !void {
        try requireSameNonzeroLength(.{
            ice_water_equivalent_change_m3,
            internal_vapor_water_change_m3,
        });
        var signed_reference_heat_megajoules: f64 = 0;
        for (
            ice_water_equivalent_change_m3,
            internal_vapor_water_change_m3,
        ) |ice_change_m3, internal_vapor_change_m3| {
            signed_reference_heat_megajoules = try addFinite(
                signed_reference_heat_megajoules,
                hourly_cell_conservation.surfaceEndpointReferenceHeatMegajoules(
                    ice_change_m3,
                    internal_vapor_change_m3,
                    liquid_heat_capacity_megajoules_per_m3_k,
                    ice_heat_capacity_per_water_equivalent_m3_k,
                    pure_water_melting_temperature_k,
                    latent_heat_of_vaporization_megajoules_per_m3,
                ) catch return error.InvalidSurfaceEndpointReferenceHeat,
            );
        }
        try self.accumulateAcceptedSignedInternalHeat(signed_reference_heat_megajoules);
    }

    pub fn accumulateAcceptedFertilizer(
        self: *State,
        mineral_nitrogen_g_n: []const f64,
        organic_nitrogen_g_n: []const f64,
        mineral_phosphorus_g_p: []const f64,
        organic_phosphorus_g_p: []const f64,
        organic_carbon_g_c: []const f64,
    ) !void {
        try requireSameNonzeroLength(.{
            mineral_nitrogen_g_n,
            organic_nitrogen_g_n,
            mineral_phosphorus_g_p,
            organic_phosphorus_g_p,
            organic_carbon_g_c,
        });
        try self.accumulateAccepted(.{
            .nitrogen_input_g_n = try sumNonnegative(mineral_nitrogen_g_n),
            .organic_fertilizer_nitrogen_g_n = try sumNonnegative(organic_nitrogen_g_n),
            .phosphorus_input_g_p = try sumNonnegative(mineral_phosphorus_g_p),
            .organic_fertilizer_phosphorus_g_p = try sumNonnegative(organic_phosphorus_g_p),
            // The biome/NBP diagnostic describes a subset of this same
            // amendment. It is not an additional physical boundary input.
            .organic_fertilizer_carbon_g_c = try sumNonnegative(organic_carbon_g_c),
        });
    }

    pub fn accumulateAcceptedExports(
        self: *State,
        carbon_exports_g_c: [4][]const f64,
        nitrogen_exports_g_n: [4][]const f64,
        phosphorus_exports_g_p: [4][]const f64,
        ion_outflow_mol: []const f64,
    ) !void {
        const cell_count = ion_outflow_mol.len;
        if (cell_count == 0) return error.EmptyLandscapeBoundaryGrid;
        inline for (carbon_exports_g_c ++ nitrogen_exports_g_n ++
            phosphorus_exports_g_p) |values|
            if (values.len != cell_count)
                return error.LandscapeBoundaryGridDimensionMismatch;

        var carbon_output_g_c: f64 = 0;
        var nitrogen_output_g_n: f64 = 0;
        var phosphorus_output_g_p: f64 = 0;
        inline for (carbon_exports_g_c) |values|
            carbon_output_g_c = try addFinite(
                carbon_output_g_c,
                try sumNonnegative(values),
            );
        inline for (nitrogen_exports_g_n) |values|
            nitrogen_output_g_n = try addFinite(
                nitrogen_output_g_n,
                try sumNonnegative(values),
            );
        inline for (phosphorus_exports_g_p) |values|
            phosphorus_output_g_p = try addFinite(
                phosphorus_output_g_p,
                try sumNonnegative(values),
            );
        try self.accumulateAccepted(.{
            .carbon_output_g_c = carbon_output_g_c,
            .nitrogen_output_g_n = nitrogen_output_g_n,
            .phosphorus_output_g_p = phosphorus_output_g_p,
            .ion_output_mol = try sumNonnegative(ion_outflow_mol),
        });
    }

    /// Positive source-signed aqueous recharge through external soil faces.
    /// Atmospheric and irrigation inputs have separate authoritative owners.
    pub fn accumulateAcceptedIonTransportInputs(
        self: *State,
        ion_inflow_mol: []const f64,
    ) !void {
        if (ion_inflow_mol.len == 0) return error.EmptyLandscapeBoundaryGrid;
        try self.accumulateAccepted(.{
            .ion_input_mol = try sumNonnegative(ion_inflow_mol),
        });
    }

    /// Legacy REDIST `TION` excludes living plant salts from storage. Salt
    /// entering inventoried soil/litter through `ALSNT..CLSNT` or shoot/root
    /// combustion is therefore a pseudo-ion input even though it is an
    /// internal transfer in the stricter all-storage element balances.
    pub fn accumulateAcceptedLegacyPlantSaltInput(
        self: *State,
        salt_input_mol: []const f64,
    ) !void {
        if (salt_input_mol.len == 0) return error.EmptyLandscapeBoundaryGrid;
        try self.accumulateAccepted(.{
            .ion_input_mol = try sumNonnegative(salt_input_mol),
        });
    }

    /// Exact REDIST `TUPZAL..TUPZCL` direction. Positive root exchange removes
    /// salt from legacy TION storage; a negative exchange returns it. Validate
    /// and split the complete accepted carrier before publishing either side.
    pub fn accumulateAcceptedLegacyRootSaltUptake(
        self: *State,
        signed_uptake_mol: []const f64,
    ) !void {
        if (signed_uptake_mol.len == 0) return error.EmptyLandscapeBoundaryGrid;
        var input_mol: f64 = 0;
        var output_mol: f64 = 0;
        for (signed_uptake_mol) |value| {
            if (!std.math.isFinite(value))
                return error.NonFiniteLandscapeBoundaryFlux;
            if (value >= 0)
                output_mol = try addFinite(output_mol, value)
            else
                input_mol = try addFinite(input_mol, -value);
        }
        try self.accumulateAccepted(.{
            .ion_input_mol = input_mol,
            .ion_output_mol = output_mol,
        });
    }

    /// Positive source-signed organic and gas recharge through external
    /// subsurface boundaries. Precipitation and irrigation chemistry retain
    /// separate authoritative input ledgers so recharge is not counted twice.
    pub fn accumulateAcceptedCarbonTransportInputs(
        self: *State,
        organic_carbon_input_g_c: []const f64,
        inorganic_carbon_input_g_c: []const f64,
    ) !void {
        if (organic_carbon_input_g_c.len == 0 or organic_carbon_input_g_c.len != inorganic_carbon_input_g_c.len)
            return error.LandscapeBoundaryGridDimensionMismatch;
        try self.accumulateAccepted(.{
            .carbon_dioxide_input_g_c = try addFinite(
                try sumNonnegative(organic_carbon_input_g_c),
                try sumNonnegative(inorganic_carbon_input_g_c),
            ),
        });
    }

    pub fn accumulateAcceptedNitrogenTransportInputs(
        self: *State,
        dissolved_organic_nitrogen_g_n: []const f64,
        dissolved_inorganic_nitrogen_g_n: []const f64,
    ) !void {
        try self.accumulateAccepted(.{
            .nitrogen_input_g_n = try addFinite(
                try sumNonnegative(dissolved_organic_nitrogen_g_n),
                try sumNonnegative(dissolved_inorganic_nitrogen_g_n),
            ),
        });
    }

    pub fn accumulateAcceptedPhosphorusTransportInputs(
        self: *State,
        dissolved_organic_phosphorus_g_p: []const f64,
        dissolved_inorganic_phosphorus_g_p: []const f64,
    ) !void {
        try self.accumulateAccepted(.{
            .phosphorus_input_g_p = try addFinite(
                try sumNonnegative(dissolved_organic_phosphorus_g_p),
                try sumNonnegative(dissolved_inorganic_phosphorus_g_p),
            ),
        });
    }

    /// EXEC XCSN/XZSN/XPSN diagnostic for plant litter transferred into the
    /// reconstructed residue stores. The all-storage acceptance equation
    /// excludes these legacy soil-only sinks because both donor and recipient
    /// are inventoried.
    pub fn accumulateAcceptedPlantLitter(
        self: *State,
        carbon_litter_g_c: []const f64,
        nitrogen_litter_g_n: []const f64,
        phosphorus_litter_g_p: []const f64,
    ) !void {
        try requireSameNonzeroLength(.{
            carbon_litter_g_c,
            nitrogen_litter_g_n,
            phosphorus_litter_g_p,
        });
        try self.accumulateAccepted(.{
            .carbon_sink_g_c = try sumNonnegative(carbon_litter_g_c),
            .nitrogen_sink_g_n = try sumNonnegative(nitrogen_litter_g_n),
            .phosphorus_sink_g_p = try sumNonnegative(phosphorus_litter_g_p),
        });
    }

    /// Root-soil dissolved organic exchange diagnostic via
    /// RDFOMC/RDFOMN/RDFOMP. Positive per-plant values indicate root uptake;
    /// negative values indicate root exudation. Directions remain available
    /// for process diagnostics but are excluded from all-storage acceptance
    /// because both plant and soil owners are inventoried.
    pub fn accumulateAcceptedRootSoilOrganicExchange(
        self: *State,
        carbon_g_c: []const f64,
        nitrogen_g_n: []const f64,
        phosphorus_g_p: []const f64,
    ) !void {
        try requireSameNonzeroLength(.{ carbon_g_c, nitrogen_g_n, phosphorus_g_p });
        var uptake_c: f64 = 0;
        var exudate_c: f64 = 0;
        var uptake_n: f64 = 0;
        var exudate_n: f64 = 0;
        var uptake_p: f64 = 0;
        var exudate_p: f64 = 0;
        for (carbon_g_c, nitrogen_g_n, phosphorus_g_p) |c, n, p| {
            inline for (.{ c, n, p }) |v|
                if (!std.math.isFinite(v)) return error.NonFiniteLandscapeBoundaryFlux;
            if (c > 0) uptake_c = try addFinite(uptake_c, c) else if (c < 0) exudate_c = try addFinite(exudate_c, -c);
            if (n > 0) uptake_n = try addFinite(uptake_n, n) else if (n < 0) exudate_n = try addFinite(exudate_n, -n);
            if (p > 0) uptake_p = try addFinite(uptake_p, p) else if (p < 0) exudate_p = try addFinite(exudate_p, -p);
        }
        try self.accumulateAccepted(.{
            .plant_root_organic_uptake_g_c = uptake_c,
            .plant_root_organic_exudate_g_c = exudate_c,
            .plant_root_organic_uptake_g_n = uptake_n,
            .plant_root_organic_exudate_g_n = exudate_n,
            .plant_root_organic_uptake_g_p = uptake_p,
            .plant_root_organic_exudate_g_p = exudate_p,
        });
    }

    /// Atmospheric gas terms for the all-storage ecosystem balance. Soil,
    /// litter, and canopy values are positive atmosphere -> ecosystem. Canopy
    /// net fields contain fire, but the parallel fire diagnostics let this
    /// boundary retain gross fixation/respiration and combustion directions;
    /// reconstruct and split those producers before any cancellation. Canopy
    /// NH3 and symbiotic fixation are plant-indexed accepted daily owners.
    pub fn accumulateAcceptedAtmosphericGas(
        self: *State,
        soil: *const soil_daily_gas.State,
        canopy: *const canopy_daily_gas.State,
        canopy_ammonia_net_input_g_n: []const f64,
        symbiotic_fixation_input_g_n: []const f64,
    ) !void {
        if (soil.cell_count == 0 or
            soil.tracked_element_mass_g_by_cell_and_species.len !=
                soil.cell_count * gas.species_count or
            canopy.net_carbon_dioxide_uptake_g_c.len != soil.cell_count or
            canopy.net_methane_uptake_g_c.len != soil.cell_count or
            canopy.net_oxygen_uptake_g_o.len != soil.cell_count or
            canopy.fire_carbon_dioxide_emission_g_c.len != soil.cell_count or
            canopy.fire_methane_emission_g_c.len != soil.cell_count or
            canopy.fire_oxygen_consumption_g_o.len != soil.cell_count or
            canopy_ammonia_net_input_g_n.len == 0 or
            symbiotic_fixation_input_g_n.len != canopy_ammonia_net_input_g_n.len)
            return error.LandscapeGasBoundaryDimensionMismatch;

        var carbon_input_g_c: f64 = 0;
        var carbon_output_g_c: f64 = 0;
        var oxygen_input_g: f64 = 0;
        var oxygen_output_g: f64 = 0;
        var gaseous_nitrogen_input_g_n: f64 = 0;
        var gaseous_nitrogen_output_g_n: f64 = 0;
        var hydrogen_input_g_h: f64 = 0;
        var hydrogen_output_g_h: f64 = 0;
        for (0..soil.cell_count) |cell| {
            const fire_co2 = canopy.fire_carbon_dioxide_emission_g_c[cell];
            const fire_ch4 = canopy.fire_methane_emission_g_c[cell];
            const fire_o2 = canopy.fire_oxygen_consumption_g_o[cell];
            inline for (.{ fire_co2, fire_ch4, fire_o2 }) |value|
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidLandscapeGasBoundaryFlux;
            try splitSignedAtmosphereFlux(
                &carbon_input_g_c,
                &carbon_output_g_c,
                try addFinite(canopy.net_carbon_dioxide_uptake_g_c[cell], fire_co2),
            );
            try splitSignedAtmosphereFlux(
                &carbon_input_g_c,
                &carbon_output_g_c,
                try addFinite(canopy.net_methane_uptake_g_c[cell], fire_ch4),
            );
            try splitSignedAtmosphereFlux(
                &oxygen_input_g,
                &oxygen_output_g,
                try addFinite(canopy.net_oxygen_uptake_g_o[cell], -fire_o2),
            );
            carbon_output_g_c = try addFinite(carbon_output_g_c, fire_co2);
            carbon_output_g_c = try addFinite(carbon_output_g_c, fire_ch4);
            oxygen_input_g = try addFinite(oxygen_input_g, fire_o2);
            try splitSignedAtmosphereFlux(
                &carbon_input_g_c,
                &carbon_output_g_c,
                try soil.get(cell, .carbon_dioxide),
            );
            try splitSignedAtmosphereFlux(
                &carbon_input_g_c,
                &carbon_output_g_c,
                try soil.get(cell, .methane),
            );
            try splitSignedAtmosphereFlux(
                &oxygen_input_g,
                &oxygen_output_g,
                try soil.get(cell, .oxygen),
            );
            inline for (.{
                gas.Species.nitrogen,
                gas.Species.nitrous_oxide,
                gas.Species.ammonia,
            }) |species|
                try splitSignedAtmosphereFlux(
                    &gaseous_nitrogen_input_g_n,
                    &gaseous_nitrogen_output_g_n,
                    try soil.get(cell, species),
                );
            try splitSignedAtmosphereFlux(
                &hydrogen_input_g_h,
                &hydrogen_output_g_h,
                try soil.get(cell, .hydrogen),
            );
        }
        for (canopy_ammonia_net_input_g_n) |value|
            try splitSignedAtmosphereFlux(
                &gaseous_nitrogen_input_g_n,
                &gaseous_nitrogen_output_g_n,
                value,
            );
        gaseous_nitrogen_input_g_n = try addFinite(
            gaseous_nitrogen_input_g_n,
            try sumNonnegative(symbiotic_fixation_input_g_n),
        );
        std.log.debug("oxygen boundary term: atmospheric_gas_input_g_o={e} atmospheric_gas_output_g_o={e}", .{ oxygen_input_g, oxygen_output_g });
        try self.accumulateAccepted(.{
            .carbon_dioxide_input_g_c = carbon_input_g_c,
            .carbon_output_g_c = carbon_output_g_c,
            .oxygen_input_g = oxygen_input_g,
            .oxygen_output_g = oxygen_output_g,
            .dinitrogen_input_g_n = gaseous_nitrogen_input_g_n,
            .nitrogen_output_g_n = gaseous_nitrogen_output_g_n,
            .hydrogen_input_g = hydrogen_input_g_h,
            .hydrogen_output_g = hydrogen_output_g_h,
        });
    }

    /// Harvest is the only plant C/N/P transfer here that crosses the modeled
    /// ecosystem boundary. Litterfall and root-soil exchange are internal now
    /// that both living plants and soil/litter recipients are inventoried.
    pub fn accumulateAcceptedPlantHarvest(
        self: *State,
        carbon_g_c: []const f64,
        nitrogen_g_n: []const f64,
        phosphorus_g_p: []const f64,
    ) !void {
        try requireSameNonzeroLength(.{ carbon_g_c, nitrogen_g_n, phosphorus_g_p });
        try self.accumulateAccepted(.{
            .carbon_output_g_c = try sumNonnegative(carbon_g_c),
            .nitrogen_output_g_n = try sumNonnegative(nitrogen_g_n),
            .phosphorus_output_g_p = try sumNonnegative(phosphorus_g_p),
        });
    }

    /// REDIST precipitation/irrigation chemistry after snow/direct routing
    /// has been recombined. Nutrients retain tracked-element grams; the eight
    /// salt carriers are converted to mol using runtime chemistry constants.
    pub fn accumulateAcceptedAtmosphericSolutes(
        self: *State,
        inputs: *const atmospheric_solutes.State,
        ion_molar_mass_g_per_mol: snow_discharge.IonMolarMassesGPerMol,
    ) !void {
        if (inputs.cell_count == 0 or inputs.daily_input_g.len !=
            inputs.cell_count * snow.species_count or
            inputs.daily_salt_input_mol.len != inputs.cell_count * snow.salt_species_count)
            return error.AtmosphericSoluteInputDimensionMismatch;
        inline for (std.meta.fields(snow_discharge.IonMolarMassesGPerMol)) |field| {
            const value = @field(ion_molar_mass_g_per_mol, field.name);
            if (!std.math.isFinite(value) or value <= 0)
                return error.InvalidIonMolarMass;
        }

        var carbon_input_g_c: f64 = 0;
        var oxygen_input_g: f64 = 0;
        var gaseous_nitrogen_input_g_n: f64 = 0;
        var aqueous_nitrogen_input_g_n: f64 = 0;
        var phosphorus_input_g_p: f64 = 0;
        var ion_input_mol: f64 = 0;
        for (0..inputs.cell_count) |cell| {
            const first = cell * snow.species_count;
            const amounts = inputs.daily_input_g[first .. first + snow.species_count];
            for (amounts) |amount|
                if (!std.math.isFinite(amount) or amount < 0)
                    return error.InvalidAtmosphericSoluteInput;
            carbon_input_g_c = try addFinite(
                carbon_input_g_c,
                amounts[@intFromEnum(snow.Species.carbon_dioxide_carbon)] +
                    amounts[@intFromEnum(snow.Species.methane_carbon)],
            );
            oxygen_input_g = try addFinite(
                oxygen_input_g,
                amounts[@intFromEnum(snow.Species.oxygen)],
            );
            gaseous_nitrogen_input_g_n = try addFinite(
                gaseous_nitrogen_input_g_n,
                amounts[@intFromEnum(snow.Species.dinitrogen_nitrogen)] +
                    amounts[
                        @intFromEnum(
                            snow.Species.nitrous_oxide_nitrogen,
                        )
                    ],
            );
            aqueous_nitrogen_input_g_n = try addFinite(
                aqueous_nitrogen_input_g_n,
                amounts[@intFromEnum(snow.Species.ammonium_nitrogen)] +
                    amounts[@intFromEnum(snow.Species.ammonia_nitrogen)] +
                    amounts[@intFromEnum(snow.Species.nitrate_nitrogen)],
            );
            const hpo4_g_p = amounts[
                @intFromEnum(snow.Species.hydrogen_phosphate_phosphorus)
            ];
            const h2po4_g_p = amounts[
                @intFromEnum(snow.Species.dihydrogen_phosphate_phosphorus)
            ];
            phosphorus_input_g_p = try addFinite(
                phosphorus_input_g_p,
                hpo4_g_p + h2po4_g_p,
            );
            ion_input_mol = try addFinite(
                ion_input_mol,
                2 * hpo4_g_p / snow.phosphorus_g_per_mol +
                    3 * h2po4_g_p / snow.phosphorus_g_per_mol +
                    amounts[@intFromEnum(snow.Species.aluminum)] /
                        ion_molar_mass_g_per_mol.aluminum +
                    amounts[@intFromEnum(snow.Species.iron)] /
                        ion_molar_mass_g_per_mol.iron +
                    amounts[@intFromEnum(snow.Species.calcium)] /
                        ion_molar_mass_g_per_mol.calcium +
                    amounts[@intFromEnum(snow.Species.magnesium)] /
                        ion_molar_mass_g_per_mol.magnesium +
                    amounts[@intFromEnum(snow.Species.sodium)] /
                        ion_molar_mass_g_per_mol.sodium +
                    amounts[@intFromEnum(snow.Species.potassium)] /
                        ion_molar_mass_g_per_mol.potassium +
                    amounts[@intFromEnum(snow.Species.sulfate_sulfur)] /
                        ion_molar_mass_g_per_mol.sulfur +
                    amounts[@intFromEnum(snow.Species.chloride)] /
                        ion_molar_mass_g_per_mol.chloride,
            );
            const salt_first = cell * snow.salt_species_count;
            for (inputs.daily_salt_input_mol[salt_first .. salt_first + snow.salt_species_count], 0..) |amount_mol, snow_species_index| {
                if (!std.math.isFinite(amount_mol) or amount_mol < 0)
                    return error.InvalidAtmosphericSoluteInput;
                const aqueous_species = snow.aqueousSpeciesForSalt(@enumFromInt(snow_species_index));
                const formula = surface_aqueous.formula(aqueous_species);
                carbon_input_g_c = try addFinite(carbon_input_g_c, amount_mol * formula.carbon_mol * 12);
                phosphorus_input_g_p = try addFinite(phosphorus_input_g_p, amount_mol * formula.phosphorus_mol * snow.phosphorus_g_per_mol);
                ion_input_mol = try addFinite(
                    ion_input_mol,
                    amount_mol * solute_species.legacyIonCount(aqueous_species),
                );
            }
        }
        std.log.debug("oxygen boundary term: atmospheric_solutes_input_g_o={e}", .{oxygen_input_g});
        try self.accumulateAccepted(.{
            .carbon_dioxide_input_g_c = carbon_input_g_c,
            .oxygen_input_g = oxygen_input_g,
            .dinitrogen_input_g_n = gaseous_nitrogen_input_g_n,
            .nitrogen_input_g_n = aqueous_nitrogen_input_g_n,
            .phosphorus_input_g_p = phosphorus_input_g_p,
            .ion_input_mol = ion_input_mol,
        });
    }

    pub fn accumulateAcceptedRedistSurfaceGas(
        self: *State,
        redist: soil_daily_gas.RedistSurfaceGasIncrements,
    ) !void {
        inline for (std.meta.fields(soil_daily_gas.RedistSurfaceGasIncrements)) |field| {
            if (!std.math.isFinite(@field(redist, field.name)))
                return error.NonFiniteLandscapeBoundaryFlux;
        }
        var next = self.cumulative;
        next.redist_carbon_surface_input_g_c = try addFinite(
            next.redist_carbon_surface_input_g_c,
            redist.carbon_surface_input_g_c,
        );
        next.redist_carbon_subsurface_output_g_c = try addFinite(
            next.redist_carbon_subsurface_output_g_c,
            redist.carbon_subsurface_output_g_c,
        );
        next.redist_oxygen_surface_input_g_o = try addFinite(
            next.redist_oxygen_surface_input_g_o,
            redist.oxygen_surface_input_g_o,
        );
        next.redist_oxygen_subsurface_output_g_o = try addFinite(
            next.redist_oxygen_subsurface_output_g_o,
            redist.oxygen_subsurface_output_g_o,
        );
        next.redist_hydrogen_surface_input_g_h = try addFinite(
            next.redist_hydrogen_surface_input_g_h,
            redist.hydrogen_surface_input_g_h,
        );
        next.redist_hydrogen_subsurface_output_g_h = try addFinite(
            next.redist_hydrogen_subsurface_output_g_h,
            redist.hydrogen_subsurface_output_g_h,
        );
        self.cumulative = next;
    }

    /// Gross shoot-fire gaseous N/P reduced from the accepted hourly plant
    /// cell sidecars. Soil and root combustion have a separate daily owner;
    /// canopy NH3 is also excluded because atmospheric-gas publication owns it.
    pub fn accumulateAcceptedPlantFireNutrientEmissionTotals(
        self: *State,
        nitrogen_output_g_n: f64,
        phosphorus_output_g_p: f64,
    ) !void {
        inline for (.{ nitrogen_output_g_n, phosphorus_output_g_p }) |value| {
            if (!std.math.isFinite(value))
                return error.NonFiniteLandscapeBoundaryFlux;
            if (value < 0)
                return error.NegativeLandscapeBoundaryFlux;
        }
        try self.accumulateAccepted(.{
            .nitrogen_output_g_n = nitrogen_output_g_n,
            .phosphorus_output_g_p = phosphorus_output_g_p,
        });
    }

    /// FIRE-NOX-BOUNDARY-001. REDIST closes the fire nutrient balance at
    /// `redist.f:10919--10920` by debiting the cumulative surface exchange
    /// inventories, `ZN2GIN=ZN2GIN-ZOX` and `TPIN=TPIN-POX`, whenever soil
    /// combustion emits gaseous nitrogen and phosphorus oxides. Production
    /// computes the same complement of the retained mineral ammonium and
    /// phosphate return -- the soil share in
    /// `organic_matter_fire_exchange.zig:finalizeLayer`, the EXTRACT root
    /// share in `plant/root/combustion_boundary_state_update.zig:publish` --
    /// but until this function existed neither reached a boundary ledger, so
    /// the exported mass silently vanished from the landscape balance. Both
    /// per-cell arrays retain the source's negative (export-only) sign
    /// convention documented at their `ecosys_ng.zig` call site; the EXEC
    /// sign is applied only once, by `mass_balance_audit.balance`.
    pub fn accumulateAcceptedFireNutrientEmission(
        self: *State,
        soil_nitrogen_emission_g_n: []const f64,
        root_nitrogen_emission_g_n: []const f64,
        soil_phosphorus_emission_g_p: []const f64,
        root_phosphorus_emission_g_p: []const f64,
    ) !void {
        try requireSameNonzeroLength(.{
            soil_nitrogen_emission_g_n,
            root_nitrogen_emission_g_n,
            soil_phosphorus_emission_g_p,
            root_phosphorus_emission_g_p,
        });
        var nitrogen_output_g_n: f64 = 0;
        for (soil_nitrogen_emission_g_n, root_nitrogen_emission_g_n) |soil, root| {
            inline for (.{ soil, root }) |value| {
                if (!std.math.isFinite(value))
                    return error.NonFiniteLandscapeBoundaryFlux;
                if (value > 0)
                    return error.PositiveFireNutrientEmissionFlux;
            }
            nitrogen_output_g_n = try addFinite(nitrogen_output_g_n, -(soil + root));
        }
        var phosphorus_output_g_p: f64 = 0;
        for (soil_phosphorus_emission_g_p, root_phosphorus_emission_g_p) |soil, root| {
            inline for (.{ soil, root }) |value| {
                if (!std.math.isFinite(value))
                    return error.NonFiniteLandscapeBoundaryFlux;
                if (value > 0)
                    return error.PositiveFireNutrientEmissionFlux;
            }
            phosphorus_output_g_p = try addFinite(phosphorus_output_g_p, -(soil + root));
        }
        try self.accumulateAccepted(.{
            .nitrogen_output_g_n = nitrogen_output_g_n,
            .phosphorus_output_g_p = phosphorus_output_g_p,
        });
    }

    /// Publishes boundary fields only. Area and reconstructed storage remain
    /// owned by the runtime landscape inventory.
    pub fn publish(self: State, totals: *audit.Totals) !void {
        try validate(self.cumulative);
        try validateInternal(self.cumulative_internal);
        const f = self.cumulative;
        totals.cumulative_rain_m3 = try addFinite(f.rain_m3, f.boundary_water_inflow_m3);
        totals.cumulative_runoff_m3 = f.runoff_m3;
        totals.cumulative_evaporation_m3 = f.evaporation_m3;
        totals.cumulative_water_outflow_m3 = f.water_outflow_m3;
        totals.cumulative_heat_input_megajoules = f.heat_input_megajoules;
        totals.cumulative_heat_output_megajoules = f.heat_output_megajoules;
        totals.cumulative_internal_heat_production_megajoules = self.cumulative_internal.heat_production_megajoules;
        totals.cumulative_internal_heat_consumption_megajoules = self.cumulative_internal.heat_consumption_megajoules;
        totals.cumulative_oxygen_input_g = f.oxygen_input_g;
        totals.cumulative_oxygen_output_g = f.oxygen_output_g;
        totals.cumulative_internal_oxygen_production_g = self.cumulative_internal.oxygen_production_g_o;
        totals.cumulative_internal_oxygen_consumption_g = self.cumulative_internal.oxygen_consumption_g_o;
        totals.cumulative_hydrogen_input_g = f.hydrogen_input_g;
        totals.cumulative_hydrogen_output_g = f.hydrogen_output_g;
        totals.cumulative_internal_hydrogen_production_g = self.cumulative_internal.hydrogen_production_g_h;
        totals.cumulative_internal_hydrogen_consumption_g = self.cumulative_internal.hydrogen_consumption_g_h;
        totals.cumulative_redist_carbon_surface_input_g_c = f.redist_carbon_surface_input_g_c;
        totals.cumulative_redist_carbon_subsurface_output_g_c = f.redist_carbon_subsurface_output_g_c;
        totals.cumulative_redist_oxygen_surface_input_g_o = f.redist_oxygen_surface_input_g_o;
        totals.cumulative_redist_oxygen_subsurface_output_g_o = f.redist_oxygen_subsurface_output_g_o;
        totals.cumulative_redist_hydrogen_surface_input_g_h = f.redist_hydrogen_surface_input_g_h;
        totals.cumulative_redist_hydrogen_subsurface_output_g_h = f.redist_hydrogen_subsurface_output_g_h;
        totals.cumulative_carbon_dioxide_input_g =
            f.carbon_dioxide_input_g_c;
        totals.cumulative_carbon_output_g = f.carbon_output_g_c;
        totals.cumulative_organic_fertilizer_carbon_g =
            f.organic_fertilizer_carbon_g_c;
        totals.cumulative_carbon_sink_g = f.carbon_sink_g_c;
        totals.cumulative_dinitrogen_input_g = f.dinitrogen_input_g_n;
        totals.cumulative_nitrogen_input_g = f.nitrogen_input_g_n;
        totals.cumulative_nitrogen_output_g = f.nitrogen_output_g_n;
        totals.cumulative_organic_fertilizer_nitrogen_g =
            f.organic_fertilizer_nitrogen_g_n;
        totals.cumulative_nitrogen_sink_g = f.nitrogen_sink_g_n;
        totals.cumulative_phosphorus_input_g = f.phosphorus_input_g_p;
        totals.cumulative_phosphorus_output_g = f.phosphorus_output_g_p;
        totals.cumulative_organic_fertilizer_phosphorus_g =
            f.organic_fertilizer_phosphorus_g_p;
        totals.cumulative_phosphorus_sink_g = f.phosphorus_sink_g_p;
        totals.cumulative_ion_input_mol = f.ion_input_mol;
        totals.cumulative_ion_output_mol = f.ion_output_mol;
        inline for (std.meta.fields(inventory.ElementMoles)) |element| {
            inline for (.{ "input", "output" }) |direction| {
                @field(totals, "cumulative_" ++ element.name ++ "_" ++ direction ++ "_mol") =
                    @field(f, element.name ++ "_" ++ direction ++ "_mol");
            }
        }
        inline for (.{ "sand", "silt", "clay" }) |mineral| inline for (.{ "input", "output" }) |direction| {
            @field(totals, "cumulative_" ++ mineral ++ "_" ++ direction ++ "_megagrams") =
                @field(f, mineral ++ "_" ++ direction ++ "_megagrams");
        };
        totals.cumulative_plant_root_organic_carbon_uptake_g = f.plant_root_organic_uptake_g_c;
        totals.cumulative_plant_root_organic_carbon_exudate_g = f.plant_root_organic_exudate_g_c;
        totals.cumulative_plant_root_organic_nitrogen_uptake_g = f.plant_root_organic_uptake_g_n;
        totals.cumulative_plant_root_organic_nitrogen_exudate_g = f.plant_root_organic_exudate_g_n;
        totals.cumulative_plant_root_organic_phosphorus_uptake_g = f.plant_root_organic_uptake_g_p;
        totals.cumulative_plant_root_organic_phosphorus_exudate_g = f.plant_root_organic_exudate_g_p;
        totals.cumulative_symbiotic_inoculum_carbon_input_g = f.symbiotic_inoculum_carbon_input_g_c;
        totals.cumulative_mineral_fertilizer_carbon_g = f.mineral_fertilizer_carbon_g_c;
        totals.cumulative_symbiotic_inoculum_nitrogen_input_g = f.symbiotic_inoculum_nitrogen_input_g_n;
        totals.cumulative_symbiotic_inoculum_phosphorus_input_g = f.symbiotic_inoculum_phosphorus_input_g_p;
        totals.cumulative_cation_exchange_capacity_input_mol = f.cation_exchange_capacity_input_mol;
        totals.cumulative_cation_exchange_capacity_output_mol = f.cation_exchange_capacity_output_mol;
        totals.cumulative_anion_exchange_capacity_input_mol = f.anion_exchange_capacity_input_mol;
        totals.cumulative_anion_exchange_capacity_output_mol = f.anion_exchange_capacity_output_mol;
        totals.cumulative_internal_cation_exchange_capacity_production_mol = self.cumulative_internal.cation_exchange_capacity_production_mol;
        totals.cumulative_internal_cation_exchange_capacity_consumption_mol = self.cumulative_internal.cation_exchange_capacity_consumption_mol;
        totals.cumulative_internal_anion_exchange_capacity_production_mol = self.cumulative_internal.anion_exchange_capacity_production_mol;
        totals.cumulative_internal_anion_exchange_capacity_consumption_mol = self.cumulative_internal.anion_exchange_capacity_consumption_mol;
    }
};

fn validateInternal(processes: InternalProcesses) !void {
    inline for (std.meta.fields(InternalProcesses)) |field| {
        const value = @field(processes, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteLandscapeInternalProcess;
        if (value < 0) return error.NegativeLandscapeInternalProcess;
    }
}

fn validate(fluxes: Fluxes) !void {
    inline for (std.meta.fields(Fluxes)) |field| {
        const value = @field(fluxes, field.name);
        if (!std.math.isFinite(value))
            return error.NonFiniteLandscapeBoundaryFlux;
        const is_redist_term = std.mem.eql(
            u8,
            field.name,
            "redist_carbon_surface_input_g_c",
        ) or std.mem.eql(u8, field.name, "redist_carbon_subsurface_output_g_c") or
            std.mem.eql(u8, field.name, "redist_oxygen_surface_input_g_o") or
            std.mem.eql(u8, field.name, "redist_oxygen_subsurface_output_g_o") or
            std.mem.eql(u8, field.name, "redist_hydrogen_surface_input_g_h") or
            std.mem.eql(u8, field.name, "redist_hydrogen_subsurface_output_g_h");
        if (!is_redist_term and value < 0) return error.NegativeLandscapeBoundaryFlux;
    }
}

fn requireSameNonzeroLength(slices: anytype) !void {
    const length = slices[0].len;
    if (length == 0) return error.EmptyLandscapeBoundaryGrid;
    inline for (slices) |values|
        if (values.len != length)
            return error.LandscapeBoundaryGridDimensionMismatch;
}

fn sumNonnegative(values: []const f64) !f64 {
    var result: f64 = 0;
    for (values) |value| {
        if (!std.math.isFinite(value))
            return error.NonFiniteLandscapeBoundaryFlux;
        if (value < 0) return error.NegativeLandscapeBoundaryFlux;
        result = try addFinite(result, value);
    }
    return result;
}

fn addFinite(first: f64, second: f64) !f64 {
    const result = first + second;
    if (!std.math.isFinite(result))
        return error.LandscapeBoundaryLedgerOverflow;
    return result;
}

fn splitSignedAtmosphereFlux(
    input: *f64,
    output: *f64,
    atmosphere_to_ecosystem_g: f64,
) !void {
    if (!std.math.isFinite(atmosphere_to_ecosystem_g))
        return error.NonFiniteLandscapeBoundaryFlux;
    if (atmosphere_to_ecosystem_g >= 0)
        input.* = try addFinite(input.*, atmosphere_to_ecosystem_g)
    else
        output.* = try addFinite(output.*, -atmosphere_to_ecosystem_g);
}

test "REDIST plant salt pseudo-ion directions preserve TUPZ SNT and fire signs" {
    var state: State = .{};
    try state.accumulateAcceptedLegacyPlantSaltInput(&.{ 1, 2, 3 });
    try state.accumulateAcceptedLegacyRootSaltUptake(&.{ 4, -5, 6 });
    try state.accumulateAcceptedLegacyPlantSaltInput(&.{7});
    try std.testing.expectEqual(@as(f64, 18), state.cumulative.ion_input_mol);
    try std.testing.expectEqual(@as(f64, 10), state.cumulative.ion_output_mol);

    const before = state;
    try std.testing.expectError(
        error.NonFiniteLandscapeBoundaryFlux,
        state.accumulateAcceptedLegacyRootSaltUptake(
            &.{ 1, std.math.nan(f64), 3 },
        ),
    );
    try std.testing.expectEqualDeep(before, state);
}

test "accepted hourly cell elements reduce transactionally to domain history" {
    var state: State = .{};
    try state.accumulateAcceptedHourlyCellElements(&.{
        .{ .aluminum_input_mol = 2, .sulfur_output_mol = 3, .sand_output_megagrams = 1.5, .cation_exchange_capacity_output_mol = 11, .cation_exchange_capacity_internal_production_mol = 5 },
        .{ .aluminum_output_mol = 1, .sulfur_input_mol = 3, .silicon_output_mol = 4, .silt_output_megagrams = 2.5, .clay_output_megagrams = 3.5, .anion_exchange_capacity_output_mol = 13, .cation_exchange_capacity_internal_consumption_mol = 2, .anion_exchange_capacity_internal_production_mol = 7 },
    });
    try std.testing.expectEqual(@as(f64, 2), state.cumulative.aluminum_input_mol);
    try std.testing.expectEqual(@as(f64, 1), state.cumulative.aluminum_output_mol);
    try std.testing.expectEqual(@as(f64, 3), state.cumulative.sulfur_input_mol);
    try std.testing.expectEqual(@as(f64, 3), state.cumulative.sulfur_output_mol);
    try std.testing.expectEqual(@as(f64, 4), state.cumulative.silicon_output_mol);
    try std.testing.expectEqual(@as(f64, 1.5), state.cumulative.sand_output_megagrams);
    try std.testing.expectEqual(@as(f64, 2.5), state.cumulative.silt_output_megagrams);
    try std.testing.expectEqual(@as(f64, 3.5), state.cumulative.clay_output_megagrams);
    try std.testing.expectEqual(@as(f64, 11), state.cumulative.cation_exchange_capacity_output_mol);
    try std.testing.expectEqual(@as(f64, 13), state.cumulative.anion_exchange_capacity_output_mol);
    try std.testing.expectEqual(@as(f64, 5), state.cumulative_internal.cation_exchange_capacity_production_mol);
    try std.testing.expectEqual(@as(f64, 2), state.cumulative_internal.cation_exchange_capacity_consumption_mol);
    try std.testing.expectEqual(@as(f64, 7), state.cumulative_internal.anion_exchange_capacity_production_mol);

    const before = state;
    try std.testing.expectError(
        error.InvalidHourlyElementBoundaryActivity,
        state.accumulateAcceptedHourlyCellElements(&.{.{
            .calcium_input_mol = std.math.nan(f64),
        }}),
    );
    try std.testing.expectEqualDeep(before, state);
}

test {
    _ = @import("landscape_boundary_balance_test.zig");
}
