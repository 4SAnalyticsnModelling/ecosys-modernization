const std = @import("std");
const builtin = @import("builtin");
const plant_output = @import("../../io/output/plant_daily_output.zig");
const scoped_conservation = @import("../../validation/scoped_conservation.zig");
const tolerance_config = @import("../../core/conservation_tolerance.zig");

/// Complete living/dead plant inventory used by the independent accepted-hour
/// C/N/P gate. These are sums of the same authoritative shoot, root, symbiont,
/// seed-storage, and standing-dead pools used by GROSUB's BALC/BALN/BALP
/// identities. `charcoal` supplies source WTSTDG(5), which Zig stores apart
/// from the four ordinary standing-dead kinetics. Cumulative flux ledgers are
/// deliberately excluded.
pub const ElementalInventory = struct {
    carbon_g: f64 = 0,
    nitrogen_g: f64 = 0,
    phosphorus_g: f64 = 0,

    pub fn fromBalanceInputs(
        carbon: plant_output.CarbonBalanceInputs,
        nitrogen: plant_output.NutrientBalanceInputs,
        phosphorus: plant_output.NutrientBalanceInputs,
        charcoal: ElementalInventory,
    ) !ElementalInventory {
        const result: ElementalInventory = .{
            .carbon_g = carbon.shoot_carbon_g + carbon.root_carbon_g +
                carbon.nodule_carbon_g + carbon.storage_carbon_g +
                carbon.standing_dead_carbon_g + charcoal.carbon_g,
            .nitrogen_g = nitrogen.shoot_g + nitrogen.root_g +
                nitrogen.nodule_g + nitrogen.storage_g +
                nitrogen.standing_dead_g + charcoal.nitrogen_g,
            .phosphorus_g = phosphorus.shoot_g + phosphorus.root_g +
                phosphorus.nodule_g + phosphorus.storage_g +
                phosphorus.standing_dead_g + charcoal.phosphorus_g,
        };
        inline for (std.meta.fields(ElementalInventory)) |field| {
            const value = @field(result, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidPlantElementalInventory;
        }
        return result;
    }
};

/// Snapshot of only the cumulative owners that cross the plant inventory
/// boundary. Gross fixation plus signed respiration is the source CARBN +
/// TCO2T identity. Internal allocation, remobilization, and root/shoot
/// transfers never enter this structure.
pub const ConservationLedgerSnapshot = struct {
    gross_canopy_fixation_g_c: f64 = 0,
    signed_total_respiration_g_c: f64 = 0,
    root_soil_carbon_exchange_g_c: f64 = 0,
    carbon_litter_sink_g_c: f64 = 0,
    carbon_oxidation_g_c: f64 = 0,
    harvested_carbon_g_c: f64 = 0,
    root_soil_nitrogen_exchange_g_n: f64 = 0,
    canopy_ammonia_exchange_g_n: f64 = 0,
    symbiotic_nitrogen_fixation_g_n: f64 = 0,
    nitrogen_litter_sink_g_n: f64 = 0,
    nitrogen_oxidation_g_n: f64 = 0,
    harvested_nitrogen_g_n: f64 = 0,
    root_soil_phosphorus_exchange_g_p: f64 = 0,
    phosphorus_litter_sink_g_p: f64 = 0,
    phosphorus_oxidation_g_p: f64 = 0,
    harvested_phosphorus_g_p: f64 = 0,

    pub fn capture(ledger: *const State, plant: usize) !ConservationLedgerSnapshot {
        if (plant >= ledger.plant_count)
            return error.PlantDailyFluxLedgerIndexOutOfBounds;
        const result: ConservationLedgerSnapshot = .{
            // The historical Zig field name predates its provenance audit.
            // Production now binds it to source CARBN/CO2F, not HCNET.
            .gross_canopy_fixation_g_c = ledger.net_carbon_change_g[plant],
            .signed_total_respiration_g_c = ledger.signed_total_respiration_carbon_g[plant],
            .root_soil_carbon_exchange_g_c = ledger.root_soil_carbon_exchange_g[plant],
            .carbon_litter_sink_g_c = ledger.carbon_sink_g[plant],
            .carbon_oxidation_g_c = ledger.carbon_oxidation_g[plant],
            .harvested_carbon_g_c = ledger.harvested_carbon_g[plant],
            .root_soil_nitrogen_exchange_g_n = ledger.root_soil_nitrogen_exchange_g[plant],
            .canopy_ammonia_exchange_g_n = ledger.ammonia_exchange_g_n[plant],
            .symbiotic_nitrogen_fixation_g_n = ledger.symbiotic_nitrogen_fixation_g[plant],
            .nitrogen_litter_sink_g_n = ledger.nitrogen_sink_g[plant],
            .nitrogen_oxidation_g_n = ledger.nitrogen_oxidation_g[plant],
            .harvested_nitrogen_g_n = ledger.harvested_nitrogen_g[plant],
            .root_soil_phosphorus_exchange_g_p = ledger.root_soil_phosphorus_exchange_g[plant],
            .phosphorus_litter_sink_g_p = ledger.phosphorus_sink_g[plant],
            .phosphorus_oxidation_g_p = ledger.phosphorus_oxidation_g[plant],
            .harvested_phosphorus_g_p = ledger.harvested_phosphorus_g[plant],
        };
        inline for (std.meta.fields(ConservationLedgerSnapshot)) |field|
            if (!std.math.isFinite(@field(result, field.name)))
                return error.NonFinitePlantConservationLedger;
        return result;
    }
};

pub const AcceptedHourSnapshot = struct {
    inventory: ElementalInventory,
    ledger: ConservationLedgerSnapshot,

    pub fn capture(
        ledger: *const State,
        plant: usize,
        inventory: ElementalInventory,
    ) !AcceptedHourSnapshot {
        inline for (std.meta.fields(ElementalInventory)) |field| {
            const value = @field(inventory, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidPlantElementalInventory;
        }
        return .{
            .inventory = inventory,
            .ledger = try ConservationLedgerSnapshot.capture(ledger, plant),
        };
    }
};

pub const ConservationTolerances = struct {
    absolute_per_area: tolerance_config.AbsolutePerArea,
    relative: f64,

    pub fn validate(self: ConservationTolerances) !void {
        try self.absolute_per_area.validate();
        if (!std.math.isFinite(self.relative) or self.relative <= 0)
            return error.InvalidPlantConservationTolerance;
    }
};

pub const AcceptedHourReport = struct {
    carbon: scoped_conservation.Closure,
    nitrogen: scoped_conservation.Closure,
    phosphorus: scoped_conservation.Closure,

    pub fn accepted(self: AcceptedHourReport) bool {
        return self.carbon.accepted and self.nitrogen.accepted and
            self.phosphorus.accepted;
    }
};

const DirectionalActivity = struct {
    input_g: f64 = 0,
    output_g: f64 = 0,

    fn addSigned(self: *DirectionalActivity, value: f64) !void {
        if (!std.math.isFinite(value))
            return error.NonFinitePlantConservationActivity;
        if (value >= 0)
            self.input_g += value
        else
            self.output_g -= value;
        if (!std.math.isFinite(self.input_g) or !std.math.isFinite(self.output_g))
            return error.PlantConservationActivityOverflow;
    }

    fn addOutput(self: *DirectionalActivity, value: f64) !void {
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidPlantConservationDirectionalActivity;
        self.output_g += value;
        if (!std.math.isFinite(self.output_g))
            return error.PlantConservationActivityOverflow;
    }
};

fn monotonicDelta(after: f64, before: f64) !f64 {
    if (!std.math.isFinite(after) or !std.math.isFinite(before))
        return error.NonFinitePlantConservationLedger;
    const delta = after - before;
    if (!std.math.isFinite(delta) or delta < 0)
        return error.InvalidPlantConservationMonotonicLedger;
    return delta;
}

fn signedDelta(after: f64, before: f64) !f64 {
    if (!std.math.isFinite(after) or !std.math.isFinite(before))
        return error.NonFinitePlantConservationLedger;
    const delta = after - before;
    if (!std.math.isFinite(delta))
        return error.NonFinitePlantConservationLedger;
    return delta;
}

fn representationMagnitude(values: anytype) !f64 {
    var result: f64 = 0;
    inline for (values) |value| {
        if (!std.math.isFinite(value))
            return error.NonFinitePlantConservationTerm;
        result += @abs(value);
        if (!std.math.isFinite(result))
            return error.PlantConservationActivityOverflow;
    }
    return result;
}

fn representationFloor(magnitude: f64) f64 {
    // Subtracting cumulative annual owners incurs a floor proportional to the
    // represented operands. This is strictly an IEEE-754 roundoff allowance,
    // not a stock-scaled scientific relative tolerance.
    return 32.0 * std.math.floatEps(f64) * magnitude;
}

/// Independently evaluates one cell×species inventory. Manure is an existing
/// per-plant hourly product ledger: it is external to this plant, although it
/// remains internal to the ecosystem. Harvest litter is already in the litter
/// sink delta and must not be supplied again.
pub fn evaluateAcceptedHour(
    before: AcceptedHourSnapshot,
    inventory_after: ElementalInventory,
    ledger_after: ConservationLedgerSnapshot,
    manure_output: ElementalInventory,
    cell_area_m2: f64,
    tolerances: ConservationTolerances,
) !AcceptedHourReport {
    try tolerances.validate();
    if (!std.math.isFinite(cell_area_m2) or cell_area_m2 <= 0)
        return error.InvalidPlantConservationArea;
    inline for (std.meta.fields(ElementalInventory)) |field| inline for (.{
        @field(before.inventory, field.name),
        @field(inventory_after, field.name),
        @field(manure_output, field.name),
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidPlantElementalInventory;

    var carbon: DirectionalActivity = .{};
    try carbon.addSigned(try signedDelta(ledger_after.gross_canopy_fixation_g_c, before.ledger.gross_canopy_fixation_g_c));
    try carbon.addSigned(try signedDelta(ledger_after.signed_total_respiration_g_c, before.ledger.signed_total_respiration_g_c));
    try carbon.addSigned(try signedDelta(ledger_after.root_soil_carbon_exchange_g_c, before.ledger.root_soil_carbon_exchange_g_c));
    try carbon.addOutput(try monotonicDelta(ledger_after.carbon_litter_sink_g_c, before.ledger.carbon_litter_sink_g_c));
    try carbon.addSigned(try signedDelta(ledger_after.carbon_oxidation_g_c, before.ledger.carbon_oxidation_g_c));
    try carbon.addOutput(try monotonicDelta(ledger_after.harvested_carbon_g_c, before.ledger.harvested_carbon_g_c));
    try carbon.addOutput(manure_output.carbon_g);

    var nitrogen: DirectionalActivity = .{};
    try nitrogen.addSigned(try signedDelta(ledger_after.root_soil_nitrogen_exchange_g_n, before.ledger.root_soil_nitrogen_exchange_g_n));
    try nitrogen.addSigned(try signedDelta(ledger_after.canopy_ammonia_exchange_g_n, before.ledger.canopy_ammonia_exchange_g_n));
    try nitrogen.addOutput(try monotonicDelta(ledger_after.nitrogen_litter_sink_g_n, before.ledger.nitrogen_litter_sink_g_n));
    try nitrogen.addSigned(try signedDelta(ledger_after.nitrogen_oxidation_g_n, before.ledger.nitrogen_oxidation_g_n));
    try nitrogen.addSigned(try monotonicDelta(ledger_after.symbiotic_nitrogen_fixation_g_n, before.ledger.symbiotic_nitrogen_fixation_g_n));
    try nitrogen.addOutput(try monotonicDelta(ledger_after.harvested_nitrogen_g_n, before.ledger.harvested_nitrogen_g_n));
    try nitrogen.addOutput(manure_output.nitrogen_g);

    var phosphorus: DirectionalActivity = .{};
    try phosphorus.addSigned(try signedDelta(ledger_after.root_soil_phosphorus_exchange_g_p, before.ledger.root_soil_phosphorus_exchange_g_p));
    try phosphorus.addOutput(try monotonicDelta(ledger_after.phosphorus_litter_sink_g_p, before.ledger.phosphorus_litter_sink_g_p));
    try phosphorus.addSigned(try signedDelta(ledger_after.phosphorus_oxidation_g_p, before.ledger.phosphorus_oxidation_g_p));
    try phosphorus.addOutput(try monotonicDelta(ledger_after.harvested_phosphorus_g_p, before.ledger.harvested_phosphorus_g_p));
    try phosphorus.addOutput(manure_output.phosphorus_g);

    const carbon_magnitude = try representationMagnitude(.{
        before.inventory.carbon_g,
        inventory_after.carbon_g,
        before.ledger.gross_canopy_fixation_g_c,
        ledger_after.gross_canopy_fixation_g_c,
        before.ledger.signed_total_respiration_g_c,
        ledger_after.signed_total_respiration_g_c,
        before.ledger.root_soil_carbon_exchange_g_c,
        ledger_after.root_soil_carbon_exchange_g_c,
        before.ledger.carbon_litter_sink_g_c,
        ledger_after.carbon_litter_sink_g_c,
        before.ledger.carbon_oxidation_g_c,
        ledger_after.carbon_oxidation_g_c,
        before.ledger.harvested_carbon_g_c,
        ledger_after.harvested_carbon_g_c,
        manure_output.carbon_g,
    });
    const nitrogen_magnitude = try representationMagnitude(.{
        before.inventory.nitrogen_g,
        inventory_after.nitrogen_g,
        before.ledger.root_soil_nitrogen_exchange_g_n,
        ledger_after.root_soil_nitrogen_exchange_g_n,
        before.ledger.canopy_ammonia_exchange_g_n,
        ledger_after.canopy_ammonia_exchange_g_n,
        before.ledger.symbiotic_nitrogen_fixation_g_n,
        ledger_after.symbiotic_nitrogen_fixation_g_n,
        before.ledger.nitrogen_litter_sink_g_n,
        ledger_after.nitrogen_litter_sink_g_n,
        before.ledger.nitrogen_oxidation_g_n,
        ledger_after.nitrogen_oxidation_g_n,
        before.ledger.harvested_nitrogen_g_n,
        ledger_after.harvested_nitrogen_g_n,
        manure_output.nitrogen_g,
    });
    const phosphorus_magnitude = try representationMagnitude(.{
        before.inventory.phosphorus_g,
        inventory_after.phosphorus_g,
        before.ledger.root_soil_phosphorus_exchange_g_p,
        ledger_after.root_soil_phosphorus_exchange_g_p,
        before.ledger.phosphorus_litter_sink_g_p,
        ledger_after.phosphorus_litter_sink_g_p,
        before.ledger.phosphorus_oxidation_g_p,
        ledger_after.phosphorus_oxidation_g_p,
        before.ledger.harvested_phosphorus_g_p,
        ledger_after.harvested_phosphorus_g_p,
        manure_output.phosphorus_g,
    });

    return .{
        .carbon = try scoped_conservation.evaluate(.{
            .storage_before = before.inventory.carbon_g,
            .storage_after = inventory_after.carbon_g,
            .external_inputs = carbon.input_g,
            .external_outputs = carbon.output_g,
        }, .{
            .absolute = tolerances.absolute_per_area.carbon_g_m2 * cell_area_m2 +
                representationFloor(carbon_magnitude),
            .relative = tolerances.relative,
        }),
        .nitrogen = try scoped_conservation.evaluate(.{
            .storage_before = before.inventory.nitrogen_g,
            .storage_after = inventory_after.nitrogen_g,
            .external_inputs = nitrogen.input_g,
            .external_outputs = nitrogen.output_g,
        }, .{
            .absolute = tolerances.absolute_per_area.nitrogen_g_m2 * cell_area_m2 +
                representationFloor(nitrogen_magnitude),
            .relative = tolerances.relative,
        }),
        .phosphorus = try scoped_conservation.evaluate(.{
            .storage_before = before.inventory.phosphorus_g,
            .storage_after = inventory_after.phosphorus_g,
            .external_inputs = phosphorus.input_g,
            .external_outputs = phosphorus.output_g,
        }, .{
            .absolute = tolerances.absolute_per_area.phosphorus_g_m2 * cell_area_m2 +
                representationFloor(phosphorus_magnitude),
            .relative = tolerances.relative,
        }),
    };
}

/// Checks the scheduled planting/reconstruction boundary independently for
/// each plant. Initial startup inventories are already part of the landscape
/// initial condition and therefore pass with zero input. Later seed masses
/// are explicit external inputs; standing-dead/charcoal are retained internal
/// inventories. Any untransferred shoot/root pool cleared by reconstruction
/// remains a failure.
pub fn evaluateLifecycleBoundary(
    inventory_before: ElementalInventory,
    inventory_after: ElementalInventory,
    external_input: ElementalInventory,
    cell_area_m2: f64,
    tolerances: ConservationTolerances,
) !AcceptedHourReport {
    try tolerances.validate();
    if (!std.math.isFinite(cell_area_m2) or cell_area_m2 <= 0)
        return error.InvalidPlantConservationArea;
    inline for (std.meta.fields(ElementalInventory)) |field| inline for (.{
        @field(inventory_before, field.name),
        @field(inventory_after, field.name),
        @field(external_input, field.name),
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidPlantElementalInventory;

    const carbon_magnitude = try representationMagnitude(.{
        inventory_before.carbon_g,
        inventory_after.carbon_g,
        external_input.carbon_g,
    });
    const nitrogen_magnitude = try representationMagnitude(.{
        inventory_before.nitrogen_g,
        inventory_after.nitrogen_g,
        external_input.nitrogen_g,
    });
    const phosphorus_magnitude = try representationMagnitude(.{
        inventory_before.phosphorus_g,
        inventory_after.phosphorus_g,
        external_input.phosphorus_g,
    });
    return .{
        .carbon = try scoped_conservation.evaluate(.{
            .storage_before = inventory_before.carbon_g,
            .storage_after = inventory_after.carbon_g,
            .external_inputs = external_input.carbon_g,
        }, .{
            .absolute = tolerances.absolute_per_area.carbon_g_m2 * cell_area_m2 +
                representationFloor(carbon_magnitude),
            .relative = tolerances.relative,
        }),
        .nitrogen = try scoped_conservation.evaluate(.{
            .storage_before = inventory_before.nitrogen_g,
            .storage_after = inventory_after.nitrogen_g,
            .external_inputs = external_input.nitrogen_g,
        }, .{
            .absolute = tolerances.absolute_per_area.nitrogen_g_m2 * cell_area_m2 +
                representationFloor(nitrogen_magnitude),
            .relative = tolerances.relative,
        }),
        .phosphorus = try scoped_conservation.evaluate(.{
            .storage_before = inventory_before.phosphorus_g,
            .storage_after = inventory_after.phosphorus_g,
            .external_inputs = external_input.phosphorus_g,
        }, .{
            .absolute = tolerances.absolute_per_area.phosphorus_g_m2 * cell_area_m2 +
                representationFloor(phosphorus_magnitude),
            .relative = tolerances.relative,
        }),
    };
}

pub fn requireLifecycleAccepted(report: AcceptedHourReport, plant: usize) !void {
    if (report.accepted()) return;
    if (!builtin.is_test) std.log.err(
        "plant lifecycle C/N/P conservation failure: plant={d} carbon_residual={e} nitrogen_residual={e} phosphorus_residual={e}",
        .{ plant, report.carbon.residual, report.nitrogen.residual, report.phosphorus.residual },
    );
    return error.PlantLifecycleConservationFailure;
}

/// Local failures remain authoritative; equal and opposite plant residuals
/// never reduce into a passing cell/domain total.
pub fn requireAccepted(reports: []const AcceptedHourReport) !void {
    for (reports, 0..) |report, plant| {
        if (report.accepted()) continue;
        if (!builtin.is_test) std.log.err(
            "hourly plant C/N/P conservation failure: plant={d} carbon_residual={e} nitrogen_residual={e} phosphorus_residual={e}",
            .{ plant, report.carbon.residual, report.nitrogen.residual, report.phosphorus.residual },
        );
        return error.HourlyPlantConservationFailure;
    }
}

/// DAY 183--192: ALHVC..CLHVC are annual harvested-salt accumulators. They
/// are reset after the annual output only when dynamic salts are enabled.
pub fn closeYearHarvestSaltAfterOutput(
    cumulative_harvest_salt_mol_by_plant: []f64,
    dynamic_salts_enabled: bool,
) !void {
    for (cumulative_harvest_salt_mol_by_plant) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteAnnualPlantHarvestSalt;
    if (dynamic_salts_enabled)
        @memset(cumulative_harvest_salt_mol_by_plant, 0);
}

/// Runtime-sized equivalent of the per-plant daily fields carried in BLK14
/// and reset by DAY after the preceding day's OUTPD record has been written.
pub const State = struct {
    allocator: std.mem.Allocator,
    plant_count: usize,

    net_carbon_change_g: []f64,
    gross_primary_productivity_g: []f64,
    root_soil_carbon_exchange_g: []f64,
    carbon_sink_g: []f64,
    initial_carbon_sink_g: []f64,
    signed_total_respiration_carbon_g: []f64,
    signed_aboveground_respiration_carbon_g: []f64,
    ammonia_exchange_g_n: []f64,
    root_soil_nitrogen_exchange_g: []f64,
    symbiotic_nitrogen_fixation_g: []f64,
    nitrogen_sink_g: []f64,
    initial_nitrogen_sink_g: []f64,
    root_soil_phosphorus_exchange_g: []f64,
    phosphorus_sink_g: []f64,
    initial_phosphorus_sink_g: []f64,
    carbon_oxidation_g: []f64,
    nitrogen_oxidation_g: []f64,
    phosphorus_oxidation_g: []f64,
    harvested_carbon_g: []f64,
    harvested_nitrogen_g: []f64,
    harvested_phosphorus_g: []f64,

    cumulative_carbon_balance_g: []f64,
    cumulative_nitrogen_balance_g: []f64,
    cumulative_phosphorus_balance_g: []f64,
    cumulative_harvested_carbon_g: []f64,
    cumulative_harvested_nitrogen_g: []f64,
    cumulative_harvested_phosphorus_g: []f64,

    /// Releases the successfully allocated `[]f64` prefix from `init` in
    /// field order. Keeping this reflected loop out of line prevents Zig from
    /// expanding it at every allocation failure edge in the initializer.
    noinline fn deinitAllocatedPrefix(self: *State, allocated_count: usize) void {
        var remaining = allocated_count;
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) {
                if (remaining == 0) return;
                self.allocator.free(@field(self, field.name));
                remaining -= 1;
            }
        }
    }

    pub fn init(allocator: std.mem.Allocator, plant_count: usize) !State {
        if (plant_count == 0) return error.InvalidPlantDailyFluxLedgerDimensions;
        var result: State = undefined;
        result.allocator = allocator;
        result.plant_count = plant_count;
        var allocated: usize = 0;
        errdefer result.deinitAllocatedPrefix(allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) {
                @field(result, field.name) = try allocator.alloc(f64, plant_count);
                @memset(@field(result, field.name), 0);
                allocated += 1;
            }
        }
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field|
            if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    pub const HourlyExchange = struct {
        net_canopy_carbon_g: f64,
        gross_primary_productivity_g: f64,
        signed_total_respiration_carbon_g: f64,
        signed_aboveground_respiration_carbon_g: f64,
    };

    /// EXTRACT accumulates these carbon quantities into annual DAY owners.
    /// Branch-ordered canopy ammonia has a separate exact publisher below;
    /// legacy CTRAN has its own owner in plant/state_update/water.zig.
    pub fn accumulateHourlyExchange(self: *State, plant: usize, exchange: HourlyExchange) !void {
        if (plant >= self.plant_count) return error.PlantDailyFluxLedgerIndexOutOfBounds;
        inline for (std.meta.fields(HourlyExchange)) |field| {
            if (!std.math.isFinite(@field(exchange, field.name))) return error.NonFinitePlantDailyFluxLedgerInput;
        }
        self.net_carbon_change_g[plant] += exchange.net_canopy_carbon_g;
        self.gross_primary_productivity_g[plant] += exchange.gross_primary_productivity_g;
        self.signed_total_respiration_carbon_g[plant] += exchange.signed_total_respiration_carbon_g;
        self.signed_aboveground_respiration_carbon_g[plant] += exchange.signed_aboveground_respiration_carbon_g;
        inline for (.{
            self.net_carbon_change_g[plant],
            self.gross_primary_productivity_g[plant],
            self.signed_total_respiration_carbon_g[plant],
            self.signed_aboveground_respiration_carbon_g[plant],
        }) |value| if (!std.math.isFinite(value)) return error.NonFinitePlantDailyFluxLedger;
    }

    /// EXTRACT 965--969 advances TNH3C branch by branch. The canopy ammonia
    /// state-update computes that source-ordered cumulative image; publish it
    /// exactly once instead of re-summing a plant total in a different order.
    pub fn publishCanopyAmmoniaCumulative(self: *State, plant: usize, cumulative_g_n: f64) !void {
        if (plant >= self.plant_count) return error.PlantDailyFluxLedgerIndexOutOfBounds;
        if (!std.math.isFinite(cumulative_g_n)) return error.NonFinitePlantDailyFluxLedgerInput;
        self.ammonia_exchange_g_n[plant] = cumulative_g_n;
    }

    pub fn accumulateHourlyRootSoilExchange(
        self: *State,
        plant: usize,
        carbon_g: f64,
        nitrogen_g: f64,
        phosphorus_g: f64,
        symbiotic_nitrogen_fixation_g: f64,
    ) !void {
        if (plant >= self.plant_count) return error.PlantDailyFluxLedgerIndexOutOfBounds;
        inline for (.{ carbon_g, nitrogen_g, phosphorus_g, symbiotic_nitrogen_fixation_g }) |value|
            if (!std.math.isFinite(value)) return error.NonFinitePlantDailyFluxLedgerInput;
        self.root_soil_carbon_exchange_g[plant] += carbon_g;
        self.root_soil_nitrogen_exchange_g[plant] += nitrogen_g;
        self.root_soil_phosphorus_exchange_g[plant] += phosphorus_g;
        self.symbiotic_nitrogen_fixation_g[plant] += symbiotic_nitrogen_fixation_g;
        inline for (.{
            self.root_soil_carbon_exchange_g[plant],
            self.root_soil_nitrogen_exchange_g[plant],
            self.root_soil_phosphorus_exchange_g[plant],
            self.symbiotic_nitrogen_fixation_g[plant],
        }) |value| if (!std.math.isFinite(value)) return error.NonFinitePlantDailyFluxLedger;
    }

    pub fn accumulateHarvest(self: *State, plant: usize, carbon_g: f64, nitrogen_g: f64, phosphorus_g: f64) !void {
        if (plant >= self.plant_count) return error.PlantDailyFluxLedgerIndexOutOfBounds;
        inline for (.{ carbon_g, nitrogen_g, phosphorus_g }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantDailyHarvest;
        self.harvested_carbon_g[plant] += carbon_g;
        self.harvested_nitrogen_g[plant] += nitrogen_g;
        self.harvested_phosphorus_g[plant] += phosphorus_g;
        inline for (.{ self.harvested_carbon_g[plant], self.harvested_nitrogen_g[plant], self.harvested_phosphorus_g[plant] }) |value|
            if (!std.math.isFinite(value)) return error.NonFinitePlantDailyFluxLedger;
    }

    pub fn accumulateLitterSink(self: *State, plant: usize, carbon_g: f64, nitrogen_g: f64, phosphorus_g: f64) !void {
        if (plant >= self.plant_count) return error.PlantDailyFluxLedgerIndexOutOfBounds;
        inline for (.{ carbon_g, nitrogen_g, phosphorus_g }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantDailyLitterSink;
        self.carbon_sink_g[plant] += carbon_g;
        self.nitrogen_sink_g[plant] += nitrogen_g;
        self.phosphorus_sink_g[plant] += phosphorus_g;
        inline for (.{ self.carbon_sink_g[plant], self.nitrogen_sink_g[plant], self.phosphorus_sink_g[plant] }) |value|
            if (!std.math.isFinite(value)) return error.NonFinitePlantDailyFluxLedger;
    }

    /// Above-ground GROSUB litter contributes to both total TCSNC/TZSNC/TPSNC
    /// and the surface-only TCSN0/TZSN0/TPSN0 ledgers.
    pub fn accumulateAbovegroundLitterSink(self: *State, plant: usize, carbon_g: f64, nitrogen_g: f64, phosphorus_g: f64) !void {
        if (plant >= self.plant_count) return error.PlantDailyFluxLedgerIndexOutOfBounds;
        inline for (.{ carbon_g, nitrogen_g, phosphorus_g }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidPlantDailyLitterSink;
        const next_total_carbon = self.carbon_sink_g[plant] + carbon_g;
        const next_total_nitrogen = self.nitrogen_sink_g[plant] + nitrogen_g;
        const next_total_phosphorus = self.phosphorus_sink_g[plant] + phosphorus_g;
        const next_initial_carbon = self.initial_carbon_sink_g[plant] + carbon_g;
        const next_initial_nitrogen = self.initial_nitrogen_sink_g[plant] + nitrogen_g;
        const next_initial_phosphorus = self.initial_phosphorus_sink_g[plant] + phosphorus_g;
        inline for (.{ next_total_carbon, next_total_nitrogen, next_total_phosphorus, next_initial_carbon, next_initial_nitrogen, next_initial_phosphorus }) |value|
            if (!std.math.isFinite(value)) return error.NonFinitePlantDailyFluxLedger;
        self.carbon_sink_g[plant] = next_total_carbon;
        self.nitrogen_sink_g[plant] = next_total_nitrogen;
        self.phosphorus_sink_g[plant] = next_total_phosphorus;
        self.initial_carbon_sink_g[plant] = next_initial_carbon;
        self.initial_nitrogen_sink_g[plant] = next_initial_nitrogen;
        self.initial_phosphorus_sink_g[plant] = next_initial_phosphorus;
    }

    /// StateUpdates the complete EXTRACT plant litter state_update atomically:
    /// aboveground material contributes to total and surface-only ledgers,
    /// while belowground material contributes only to total litter.
    pub fn accumulateLitterStateUpdate(
        self: *State,
        plant: usize,
        aboveground_carbon_g_c: f64,
        aboveground_nitrogen_g_n: f64,
        aboveground_phosphorus_g_p: f64,
        belowground_carbon_g_c: f64,
        belowground_nitrogen_g_n: f64,
        belowground_phosphorus_g_p: f64,
    ) !void {
        if (plant >= self.plant_count)
            return error.PlantDailyFluxLedgerIndexOutOfBounds;
        inline for (.{
            aboveground_carbon_g_c,
            aboveground_nitrogen_g_n,
            aboveground_phosphorus_g_p,
            belowground_carbon_g_c,
            belowground_nitrogen_g_n,
            belowground_phosphorus_g_p,
        }) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidPlantDailyLitterSink;
        const next_total = .{
            self.carbon_sink_g[plant] + aboveground_carbon_g_c + belowground_carbon_g_c,
            self.nitrogen_sink_g[plant] + aboveground_nitrogen_g_n + belowground_nitrogen_g_n,
            self.phosphorus_sink_g[plant] + aboveground_phosphorus_g_p + belowground_phosphorus_g_p,
        };
        const next_surface = .{
            self.initial_carbon_sink_g[plant] + aboveground_carbon_g_c,
            self.initial_nitrogen_sink_g[plant] + aboveground_nitrogen_g_n,
            self.initial_phosphorus_sink_g[plant] + aboveground_phosphorus_g_p,
        };
        inline for (.{
            next_total[0],
            next_total[1],
            next_total[2],
            next_surface[0],
            next_surface[1],
            next_surface[2],
        }) |value|
            if (!std.math.isFinite(value))
                return error.NonFinitePlantDailyFluxLedger;
        self.carbon_sink_g[plant] = next_total[0];
        self.nitrogen_sink_g[plant] = next_total[1];
        self.phosphorus_sink_g[plant] = next_total[2];
        self.initial_carbon_sink_g[plant] = next_surface[0];
        self.initial_nitrogen_sink_g[plant] = next_surface[1];
        self.initial_phosphorus_sink_g[plant] = next_surface[2];
    }

    /// GROSUB/EXTRACT VCOXF/VNOXF/VPOXF retain signed plant-pool removals.
    /// Carbon includes the positive COR charcoal return supplied by the caller.
    pub fn accumulateOxidation(self: *State, plant: usize, carbon_g: f64, nitrogen_g: f64, phosphorus_g: f64) !void {
        if (plant >= self.plant_count) return error.PlantDailyFluxLedgerIndexOutOfBounds;
        inline for (.{ carbon_g, nitrogen_g, phosphorus_g }) |value|
            if (!std.math.isFinite(value)) return error.NonFinitePlantDailyFluxLedgerInput;
        const next_carbon = self.carbon_oxidation_g[plant] + carbon_g;
        const next_nitrogen = self.nitrogen_oxidation_g[plant] + nitrogen_g;
        const next_phosphorus = self.phosphorus_oxidation_g[plant] + phosphorus_g;
        inline for (.{ next_carbon, next_nitrogen, next_phosphorus }) |value|
            if (!std.math.isFinite(value)) return error.NonFinitePlantDailyFluxLedger;
        self.carbon_oxidation_g[plant] = next_carbon;
        self.nitrogen_oxidation_g[plant] = next_nitrogen;
        self.phosphorus_oxidation_g[plant] = next_phosphorus;
    }

    /// Applies the exact DAY carry equations, then clears the ledger fields
    /// legacy zeroes at `day.f:159-182`.
    ///
    /// PLANT-CADENCE-001 (fixed): legacy guards this entire carry-and-reset
    /// block on `I.EQ.1` (`day.f:84-85,197`) -- it runs once per simulated
    /// year, on the day the annual cycle turns over, not once per day. Every
    /// field this function zeroes is on legacy's annual list; none is
    /// genuinely daily. The caller MUST gate calls to this function on the
    /// same boundary legacy uses (the completed day being the last day of
    /// its year); it must not be called after every day's OUTPD-equivalent
    /// write. Named `closeYearAfterOutput` (not `closeDayAfterOutput`, its
    /// former name, which the unconditional-daily call site made literally
    /// true and scientifically wrong) to make the required cadence obvious
    /// at every call site.
    pub fn closeYearAfterOutput(self: *State) !void {
        try self.validateFinite();
        for (0..self.plant_count) |plant| {
            self.cumulative_carbon_balance_g[plant] +=
                self.net_carbon_change_g[plant] +
                self.root_soil_carbon_exchange_g[plant] -
                self.carbon_sink_g[plant] +
                self.signed_total_respiration_carbon_g[plant] +
                self.carbon_oxidation_g[plant];
            self.cumulative_nitrogen_balance_g[plant] +=
                self.root_soil_nitrogen_exchange_g[plant] +
                self.ammonia_exchange_g_n[plant] -
                self.nitrogen_sink_g[plant] +
                self.nitrogen_oxidation_g[plant] +
                self.symbiotic_nitrogen_fixation_g[plant];
            self.cumulative_phosphorus_balance_g[plant] +=
                self.root_soil_phosphorus_exchange_g[plant] -
                self.phosphorus_sink_g[plant] +
                self.phosphorus_oxidation_g[plant];
            self.cumulative_harvested_carbon_g[plant] += self.harvested_carbon_g[plant];
            self.cumulative_harvested_nitrogen_g[plant] += self.harvested_nitrogen_g[plant];
            self.cumulative_harvested_phosphorus_g[plant] += self.harvested_phosphorus_g[plant];
        }
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64 and !std.mem.startsWith(u8, field.name, "cumulative_"))
                @memset(@field(self, field.name), 0);
        }
        try self.validateFinite();
    }

    pub fn validateFinite(self: State) !void {
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) for (@field(self, field.name), 0..) |value, plant| {
                if (!std.math.isFinite(value)) {
                    if (!builtin.is_test) std.log.err("non-finite daily plant ledger: field={s} plant={d} value={e}", .{ field.name, plant, value });
                    return error.NonFinitePlantDailyFluxLedger;
                }
            };
        }
    }
};

test "daily plant flux state releases every partial allocation prefix" {
    const allocation_count = comptime count: {
        var count: usize = 0;
        for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) count += 1;
        }
        break :count count;
    };

    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            State.init(failing.allocator(), 2),
        );
    }
}

test "DAY carry equations execute at the year boundary and reset annual fields" {
    var state = try State.init(std.testing.allocator, 7);
    defer state.deinit();
    const plant = 6;
    state.net_carbon_change_g[plant] = 10;
    state.root_soil_carbon_exchange_g[plant] = 2;
    state.carbon_sink_g[plant] = 3;
    state.signed_total_respiration_carbon_g[plant] = -4;
    state.carbon_oxidation_g[plant] = 1;
    state.root_soil_nitrogen_exchange_g[plant] = 5;
    state.ammonia_exchange_g_n[plant] = -1;
    state.nitrogen_sink_g[plant] = 2;
    state.nitrogen_oxidation_g[plant] = 0.5;
    state.symbiotic_nitrogen_fixation_g[plant] = 1.5;
    state.root_soil_phosphorus_exchange_g[plant] = 3;
    state.phosphorus_sink_g[plant] = 1;
    state.phosphorus_oxidation_g[plant] = 0.25;
    state.harvested_carbon_g[plant] = 8;
    state.harvested_nitrogen_g[plant] = 0.8;
    state.harvested_phosphorus_g[plant] = 0.08;

    // Values remain available to OUTPD until the close operation.
    try std.testing.expectEqual(@as(f64, 10), state.net_carbon_change_g[plant]);
    try state.closeYearAfterOutput();
    try std.testing.expectEqual(@as(f64, 6), state.cumulative_carbon_balance_g[plant]);
    try std.testing.expectEqual(@as(f64, 4), state.cumulative_nitrogen_balance_g[plant]);
    try std.testing.expectEqual(@as(f64, 2.25), state.cumulative_phosphorus_balance_g[plant]);
    try std.testing.expectEqual(@as(f64, 8), state.cumulative_harvested_carbon_g[plant]);
    try std.testing.expectEqual(@as(f64, 0), state.net_carbon_change_g[plant]);
}

test "DAY annual harvested salt reset follows the dynamic salt guard atomically" {
    var enabled = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try closeYearHarvestSaltAfterOutput(&enabled, true);
    for (enabled) |value| try std.testing.expectEqual(@as(f64, 0), value);

    var disabled = [_]f64{ 1, 2 };
    try closeYearHarvestSaltAfterOutput(&disabled, false);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, &disabled);

    var invalid = [_]f64{ 1, std.math.nan(f64) };
    const before = invalid;
    try std.testing.expectError(
        error.NonFiniteAnnualPlantHarvestSalt,
        closeYearHarvestSaltAfterOutput(&invalid, true),
    );
    try std.testing.expectEqual(before[0], invalid[0]);
    try std.testing.expect(std.math.isNan(before[1]) and std.math.isNan(invalid[1]));
}

test "production annual CNP and salt owners share the DAY year guard" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/ecosys_ng.zig",
        allocator,
        .limited(12 * 1024 * 1024),
    );
    defer allocator.free(source);
    const guard = std.mem.indexOf(u8, source, "if (completed_day_of_year == ecosys.climate_change.daysInYear(accepted_context.current_year.*))") orelse return error.MissingAnnualRolloverGuard;
    const annual_body = source[guard..];
    const cnp = std.mem.indexOf(u8, annual_body, "driver_context.plant_daily_flux_ledger.*.closeYearAfterOutput();") orelse return error.MissingAnnualCnpRollover;
    const salt = std.mem.indexOf(u8, annual_body, "closeYearHarvestSaltAfterOutput(") orelse return error.MissingAnnualSaltRollover;
    const daily_reset = std.mem.indexOf(u8, annual_body, "driver_context.daily_soil_gas_flux.*.reset();") orelse return error.MissingFollowingDailyReset;
    try std.testing.expect(cnp < salt);
    try std.testing.expect(salt < daily_reset);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "driver_context.plant_daily_flux_ledger.*.closeYearAfterOutput();"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "closeYearHarvestSaltAfterOutput("));
}

test "daily plant ledger fails immediately on non-finite accumulation" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.net_carbon_change_g[0] = std.math.nan(f64);
    try std.testing.expectError(error.NonFinitePlantDailyFluxLedger, state.closeYearAfterOutput());
}

test "EXTRACT hourly exchange retains source signs and arbitrary plant index" {
    var state = try State.init(std.testing.allocator, 12);
    defer state.deinit();
    try state.accumulateHourlyExchange(11, .{
        .net_canopy_carbon_g = 2.5,
        .gross_primary_productivity_g = 3,
        .signed_total_respiration_carbon_g = -0.4,
        .signed_aboveground_respiration_carbon_g = -0.3,
    });
    try state.accumulateHourlyExchange(11, .{
        .net_canopy_carbon_g = -0.5,
        .gross_primary_productivity_g = 1,
        .signed_total_respiration_carbon_g = -0.2,
        .signed_aboveground_respiration_carbon_g = -0.1,
    });
    try state.publishCanopyAmmoniaCumulative(11, -0.03);
    try std.testing.expectApproxEqAbs(@as(f64, 2), state.net_carbon_change_g[11], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.6), state.signed_total_respiration_carbon_g[11], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.4), state.signed_aboveground_respiration_carbon_g[11], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.03), state.ammonia_exchange_g_n[11], 1e-15);
}

test "GROSUB root-soil C N P exchange and fixation accumulate with source signs" {
    var state = try State.init(std.testing.allocator, 9);
    defer state.deinit();
    try state.accumulateHourlyRootSoilExchange(8, -0.2, 0.03, -0.004, 0.01);
    try state.accumulateHourlyRootSoilExchange(8, 0.1, 0.02, 0.001, 0.02);
    try std.testing.expectApproxEqAbs(@as(f64, -0.1), state.root_soil_carbon_exchange_g[8], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), state.root_soil_nitrogen_exchange_g[8], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.003), state.root_soil_phosphorus_exchange_g[8], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.03), state.symbiotic_nitrogen_fixation_g[8], 1e-15);
}

test "management exports accumulate in daily HVST elemental ledgers" {
    var state = try State.init(std.testing.allocator, 6);
    defer state.deinit();
    try state.accumulateHarvest(5, 3, 0.3, 0.03);
    try state.accumulateHarvest(5, 2, 0.2, 0.02);
    try std.testing.expectEqual(@as(f64, 5), state.harvested_carbon_g[5]);
    try std.testing.expectEqual(@as(f64, 0.5), state.harvested_nitrogen_g[5]);
    try std.testing.expectEqual(@as(f64, 0.05), state.harvested_phosphorus_g[5]);
}

test "senesced litter accumulates TCSNC TZSNC TPSNC without recycled pools" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    try state.accumulateLitterSink(1, 4, 0.4, 0.04);
    try state.accumulateLitterSink(1, 1, 0.1, 0.01);
    try std.testing.expectEqual(@as(f64, 5), state.carbon_sink_g[1]);
    try std.testing.expectEqual(@as(f64, 0.5), state.nitrogen_sink_g[1]);
    try std.testing.expectEqual(@as(f64, 0.05), state.phosphorus_sink_g[1]);
}

test "aboveground litter also accumulates source TCSN0 TZSN0 TPSN0" {
    var state = try State.init(std.testing.allocator, 8);
    defer state.deinit();
    try state.accumulateAbovegroundLitterSink(7, 2, 0.2, 0.02);
    try state.accumulateLitterSink(7, 3, 0.3, 0.03);
    try std.testing.expectEqual(@as(f64, 5), state.carbon_sink_g[7]);
    try std.testing.expectEqual(@as(f64, 2), state.initial_carbon_sink_g[7]);
    try std.testing.expectEqual(@as(f64, 0.2), state.initial_nitrogen_sink_g[7]);
    try std.testing.expectEqual(@as(f64, 0.02), state.initial_phosphorus_sink_g[7]);
}

test "complete EXTRACT litter state_update is atomic across surface and root totals" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.carbon_sink_g[0] = 4;
    state.initial_carbon_sink_g[0] = 2;
    state.phosphorus_sink_g[0] = std.math.floatMax(f64);
    try std.testing.expectError(
        error.NonFinitePlantDailyFluxLedger,
        state.accumulateLitterStateUpdate(0, 3, 0.3, 1, 5, 0.5, std.math.floatMax(f64)),
    );
    try std.testing.expectEqual(@as(f64, 4), state.carbon_sink_g[0]);
    try std.testing.expectEqual(@as(f64, 2), state.initial_carbon_sink_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.initial_phosphorus_sink_g[0]);
}

test "disturbance oxidation retains source signs and carbon charcoal return" {
    var state = try State.init(std.testing.allocator, 3);
    defer state.deinit();
    try state.accumulateOxidation(2, -5.5 + 1.25, -0.4, -0.06);
    try std.testing.expectEqual(@as(f64, -4.25), state.carbon_oxidation_g[2]);
    try std.testing.expectEqual(@as(f64, -0.4), state.nitrogen_oxidation_g[2]);
    try std.testing.expectEqual(@as(f64, -0.06), state.phosphorus_oxidation_g[2]);
}

test "accepted-hour inventory includes split source WTSTDG charcoal" {
    var carbon: plant_output.CarbonBalanceInputs = std.mem.zeroes(plant_output.CarbonBalanceInputs);
    var nitrogen: plant_output.NutrientBalanceInputs = std.mem.zeroes(plant_output.NutrientBalanceInputs);
    var phosphorus: plant_output.NutrientBalanceInputs = std.mem.zeroes(plant_output.NutrientBalanceInputs);
    carbon.standing_dead_carbon_g = 10;
    nitrogen.standing_dead_g = 2;
    phosphorus.standing_dead_g = 0.5;
    try std.testing.expectEqual(
        ElementalInventory{ .carbon_g = 11, .nitrogen_g = 2.2, .phosphorus_g = 0.55 },
        try ElementalInventory.fromBalanceInputs(
            carbon,
            nitrogen,
            phosphorus,
            .{ .carbon_g = 1, .nitrogen_g = 0.2, .phosphorus_g = 0.05 },
        ),
    );
}

test "accepted-hour plant inventory closes gross fixation respiration exchanges litter harvest fire and manure exactly once" {
    const before: AcceptedHourSnapshot = .{
        .inventory = .{ .carbon_g = 100, .nitrogen_g = 20, .phosphorus_g = 5 },
        .ledger = .{
            .gross_canopy_fixation_g_c = 1000,
            .signed_total_respiration_g_c = -200,
            .root_soil_carbon_exchange_g_c = 40,
            .carbon_litter_sink_g_c = 50,
            .carbon_oxidation_g_c = -10,
            .harvested_carbon_g_c = 30,
            .root_soil_nitrogen_exchange_g_n = 10,
            .canopy_ammonia_exchange_g_n = -2,
            .symbiotic_nitrogen_fixation_g_n = 3,
            .nitrogen_litter_sink_g_n = 4,
            .nitrogen_oxidation_g_n = -1,
            .harvested_nitrogen_g_n = 2,
            .root_soil_phosphorus_exchange_g_p = 1,
            .phosphorus_litter_sink_g_p = 2,
            .phosphorus_oxidation_g_p = -0.5,
            .harvested_phosphorus_g_p = 0.4,
        },
    };
    const after_ledger: ConservationLedgerSnapshot = .{
        .gross_canopy_fixation_g_c = 1010,
        .signed_total_respiration_g_c = -203,
        .root_soil_carbon_exchange_g_c = 38,
        .carbon_litter_sink_g_c = 54,
        .carbon_oxidation_g_c = -11,
        .harvested_carbon_g_c = 35,
        .root_soil_nitrogen_exchange_g_n = 12,
        .canopy_ammonia_exchange_g_n = -2.5,
        .symbiotic_nitrogen_fixation_g_n = 4,
        .nitrogen_litter_sink_g_n = 4.5,
        .nitrogen_oxidation_g_n = -1.1,
        .harvested_nitrogen_g_n = 2.2,
        .root_soil_phosphorus_exchange_g_p = 1.4,
        .phosphorus_litter_sink_g_p = 2.1,
        .phosphorus_oxidation_g_p = -0.52,
        .harvested_phosphorus_g_p = 0.43,
    };
    const report = try evaluateAcceptedHour(
        before,
        .{ .carbon_g = 94, .nitrogen_g = 21.4, .phosphorus_g = 5.2 },
        after_ledger,
        .{ .carbon_g = 1, .nitrogen_g = 0.3, .phosphorus_g = 0.05 },
        2,
        .{
            .absolute_per_area = .{
                .carbon_g_m2 = 1e-12,
                .nitrogen_g_m2 = 1e-12,
                .phosphorus_g_m2 = 1e-12,
            },
            .relative = 1e-12,
        },
    );
    try std.testing.expect(report.accepted());
    try std.testing.expectApproxEqAbs(@as(f64, 0), report.carbon.residual, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), report.nitrogen.residual, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), report.phosphorus.residual, 1e-12);
    // Cancellation-resistant normalization sees individual directions, not
    // only their net: C input=10 and output=16.
    try std.testing.expectEqual(@as(f64, 26), report.carbon.normalization_scale);
}

test "equal opposite per-plant leaks cannot cancel into acceptance" {
    const zero_ledger: ConservationLedgerSnapshot = .{};
    const reports = [_]AcceptedHourReport{
        try evaluateAcceptedHour(
            .{ .inventory = .{}, .ledger = zero_ledger },
            .{ .carbon_g = 1 },
            zero_ledger,
            .{},
            1,
            .{ .absolute_per_area = .{ .carbon_g_m2 = 1e-12 }, .relative = 1e-12 },
        ),
        try evaluateAcceptedHour(
            .{ .inventory = .{ .carbon_g = 1 }, .ledger = zero_ledger },
            .{},
            zero_ledger,
            .{},
            1,
            .{ .absolute_per_area = .{ .carbon_g_m2 = 1e-12 }, .relative = 1e-12 },
        ),
    };
    try std.testing.expectEqual(@as(f64, 0), reports[0].carbon.residual + reports[1].carbon.residual);
    try std.testing.expect(!reports[0].carbon.accepted);
    try std.testing.expect(!reports[1].carbon.accepted);
    try std.testing.expectError(error.HourlyPlantConservationFailure, requireAccepted(&reports));
}

test "plant absolute tolerance scales by cell area independently from relative closure" {
    const before: AcceptedHourSnapshot = .{ .inventory = .{}, .ledger = .{} };
    const accepted = try evaluateAcceptedHour(
        before,
        .{ .carbon_g = 1e-6 },
        .{},
        .{},
        2,
        .{ .absolute_per_area = .{ .carbon_g_m2 = 6e-7 }, .relative = 1e-15 },
    );
    const rejected = try evaluateAcceptedHour(
        before,
        .{ .carbon_g = 1e-6 },
        .{},
        .{},
        1,
        .{ .absolute_per_area = .{ .carbon_g_m2 = 6e-7 }, .relative = 1e-15 },
    );
    try std.testing.expect(accepted.carbon.accepted);
    try std.testing.expect(!rejected.carbon.accepted);
}

test "failed plant gate is read only for rollback" {
    const before: AcceptedHourSnapshot = .{
        .inventory = .{ .carbon_g = 4, .nitrogen_g = 1, .phosphorus_g = 0.2 },
        .ledger = .{ .harvested_carbon_g_c = 2 },
    };
    const after_inventory = before.inventory;
    const invalid_after: ConservationLedgerSnapshot = .{ .harvested_carbon_g_c = 1 };
    const before_copy = before;
    const inventory_copy = after_inventory;
    const ledger_copy = invalid_after;
    try std.testing.expectError(
        error.InvalidPlantConservationMonotonicLedger,
        evaluateAcceptedHour(
            before,
            after_inventory,
            invalid_after,
            .{},
            1,
            .{ .absolute_per_area = .{}, .relative = 1e-9 },
        ),
    );
    try std.testing.expectEqualDeep(before_copy, before);
    try std.testing.expectEqualDeep(inventory_copy, after_inventory);
    try std.testing.expectEqualDeep(ledger_copy, invalid_after);
}

test "plant lifecycle boundary distinguishes initial condition from later planting input" {
    const tolerances: ConservationTolerances = .{
        .absolute_per_area = .{
            .carbon_g_m2 = 1e-12,
            .nitrogen_g_m2 = 1e-12,
            .phosphorus_g_m2 = 1e-12,
        },
        .relative = 1e-12,
    };
    const initial: ElementalInventory = .{
        .carbon_g = 10,
        .nitrogen_g = 1,
        .phosphorus_g = 0.2,
    };
    try std.testing.expect((try evaluateLifecycleBoundary(
        initial,
        initial,
        .{},
        1,
        tolerances,
    )).accepted());
    try std.testing.expect((try evaluateLifecycleBoundary(
        .{},
        initial,
        initial,
        1,
        tolerances,
    )).accepted());
}

test "plant lifecycle boundary rejects discarded pools and opposing plant cancellation" {
    const tolerances: ConservationTolerances = .{
        .absolute_per_area = .{
            .carbon_g_m2 = 1e-12,
            .nitrogen_g_m2 = 1e-12,
            .phosphorus_g_m2 = 1e-12,
        },
        .relative = 1e-12,
    };
    const lost = try evaluateLifecycleBoundary(
        .{ .carbon_g = 2 },
        .{},
        .{},
        1,
        tolerances,
    );
    const invented = try evaluateLifecycleBoundary(
        .{},
        .{ .carbon_g = 2 },
        .{},
        1,
        tolerances,
    );
    try std.testing.expectEqual(@as(f64, 0), lost.carbon.residual + invented.carbon.residual);
    try std.testing.expectError(
        error.PlantLifecycleConservationFailure,
        requireLifecycleAccepted(lost, 0),
    );
    try std.testing.expectError(
        error.PlantLifecycleConservationFailure,
        requireLifecycleAccepted(invented, 1),
    );
}

test "production binds source CARBN and orders per-plant acceptance inside rollback" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/ecosys_ng.zig",
        std.testing.allocator,
        .limited(12 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            source,
            ".net_canopy_carbon_g = canopy.plant_gross_primary_productivity_g_c_per_h[plant]",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, source, ".net_canopy_carbon_g = carbon_flux.net_co2_g_c_per_h"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "driver_context.plant_daily_flux_ledger.*.publishCanopyAmmoniaCumulative("),
    );
    // WTSTDG is a STARTQ-only initial condition. Runtime reconstruction must
    // restore its live owner instead of applying the trait value again.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "initializeStandingDeadStorage(&detailed_canopy_state.?, plant, standing_dead)"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "restorePersistentReseedInventories(&driver_context.detailed_canopy_state.*.?, plant"),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, source, ".carbon_g = canopy.plant_charcoal_carbon_g[plant]"),
    );
    const post_start = std.mem.indexOf(u8, source, "noinline fn postScienceAccounting(") orelse return error.MissingPostSciencePhase;
    const management_start = std.mem.indexOfPos(u8, source, post_start, "noinline fn postScienceManagementAndGasAccounting(") orelse return error.MissingManagementAccountingPhase;
    const canopy_wrapper_start = std.mem.indexOfPos(u8, source, management_start, "noinline fn postScienceCanopyFireAndCloseout(") orelse return error.MissingCanopyFireWrapper;
    const canopy_start = std.mem.indexOfPos(u8, source, canopy_wrapper_start, "noinline fn postScienceCanopyAndEnergy(") orelse return error.MissingCanopyEnergyPhase;
    const fire_start = std.mem.indexOfPos(u8, source, canopy_start, "noinline fn postScienceFireAndCloseout(") orelse return error.MissingFireCloseoutPhase;
    const accept_start = std.mem.indexOfPos(u8, source, fire_start, "noinline fn acceptHourAndPublish(") orelse return error.MissingAcceptHourPhase;
    const prepare_start = std.mem.indexOfPos(u8, source, accept_start, "noinline fn prepareHourlyScience(") orelse return error.MissingPrepareHourlySciencePhase;
    const advance_start = std.mem.indexOfPos(u8, source, prepare_start, "noinline fn advanceHour(") orelse return error.MissingAdvanceHourPhase;
    const timeline_start = std.mem.indexOfPos(u8, source, advance_start, "noinline fn runTimeline(") orelse return error.MissingTimelinePhase;
    const post_phase = source[post_start..management_start];
    const canopy_wrapper = source[canopy_wrapper_start..canopy_start];
    const canopy_phase = source[canopy_start..fire_start];
    const fire_phase = source[fire_start..accept_start];
    const accept_phase = source[accept_start..prepare_start];
    const prepare_phase = source[prepare_start..advance_start];
    const advance_phase = source[advance_start..timeline_start];
    const transaction_begin = std.mem.indexOf(u8, advance_phase, "driver_context.outer_hour_transaction_workspace.*.begin(") orelse return error.MissingOuterHourTransaction;
    const stable_capture = std.mem.indexOfPos(u8, advance_phase, transaction_begin, "captureStable(&driver_context.hourly_science_context.*") orelse return error.MissingHourlyScienceRollbackCapture;
    const prepare_call = std.mem.indexOfPos(u8, advance_phase, stable_capture, "try prepareHourlyScience(driver_context,") orelse return error.MissingHourlyPreparationCall;
    const hourly_science = std.mem.indexOfPos(u8, advance_phase, prepare_call, "executeHourlyScience(") orelse return error.MissingHourlyScience;
    const post_call = std.mem.indexOfPos(u8, advance_phase, hourly_science, "try postScienceAccounting(driver_context,") orelse return error.MissingPostScienceCall;
    const accept_call = std.mem.indexOfPos(u8, advance_phase, post_call, "try acceptHourAndPublish(driver_context,") orelse return error.MissingAcceptHourCall;
    _ = std.mem.indexOf(u8, prepare_phase, "driver_context.plant_conservation_hour_start.*[plant] =") orelse return error.MissingPlantConservationStartSnapshot;
    const management_call = std.mem.indexOf(u8, post_phase, "try postScienceManagementAndGasAccounting(") orelse return error.MissingManagementAccountingCall;
    const canopy_wrapper_call = std.mem.indexOfPos(u8, post_phase, management_call, "try postScienceCanopyFireAndCloseout(") orelse return error.MissingCanopyFireWrapperCall;
    const canopy_call = std.mem.indexOf(u8, canopy_wrapper, "try postScienceCanopyAndEnergy(") orelse return error.MissingCanopyEnergyCall;
    const fire_call = std.mem.indexOfPos(u8, canopy_wrapper, canopy_call, "try postScienceFireAndCloseout(") orelse return error.MissingFireCloseoutCall;
    const plant_exchange_call = std.mem.indexOf(u8, canopy_phase, "try postScienceManureAndPlantExchange(") orelse return error.MissingCanopyPlantExchangeCall;
    const energy_water_call = std.mem.indexOfPos(u8, canopy_phase, plant_exchange_call, "try postScienceCanopyEnergyAndWater(") orelse return error.MissingCanopyEnergyWaterCall;
    const structure_heat_call = std.mem.indexOfPos(u8, canopy_phase, energy_water_call, "try postScienceCanopyStructureAndHeat(") orelse return error.MissingCanopyStructureHeatCall;
    const root_ledgers_call = std.mem.indexOfPos(u8, canopy_phase, structure_heat_call, "try postScienceRootLedgers(") orelse return error.MissingRootLedgersCall;
    _ = std.mem.indexOf(u8, canopy_phase, ".signed_total_respiration_carbon_g = signed_total_respiration_carbon_g") orelse return error.MissingSignedPlantRespirationLedger;
    const manure = std.mem.indexOf(u8, fire_phase, ".organic_by_biochemical_fraction") orelse return error.MissingPlantManureBoundaryLedger;
    const evaluation = std.mem.indexOfPos(u8, fire_phase, manure, "ecosys.plant_daily_flux_ledger.evaluateAcceptedHour(") orelse return error.MissingPlantConservationEvaluation;
    const acceptance = std.mem.indexOfPos(u8, fire_phase, evaluation, "ecosys.plant_daily_flux_ledger.requireAccepted(") orelse return error.MissingPlantConservationAcceptance;
    const cell_acceptance = std.mem.indexOf(u8, accept_phase, "hourly_cell_conservation.requireAccepted(") orelse return error.MissingHourlyCellAcceptance;
    const counter = std.mem.indexOfPos(u8, accept_phase, cell_acceptance, "advance_context.previous_weather_timestamp.* = accept_context.timestamp.*") orelse return error.MissingAcceptedHourCounter;
    const commit = std.mem.indexOfPos(u8, accept_phase, counter, "outer_hour_transaction.*.commit()") orelse return error.MissingOuterHourCommit;
    try std.testing.expect(transaction_begin < stable_capture);
    try std.testing.expect(stable_capture < prepare_call);
    try std.testing.expect(prepare_call < hourly_science);
    try std.testing.expect(hourly_science < post_call);
    try std.testing.expect(post_call < accept_call);
    try std.testing.expect(management_call < canopy_wrapper_call);
    try std.testing.expect(canopy_call < fire_call);
    try std.testing.expect(plant_exchange_call < energy_water_call);
    try std.testing.expect(energy_water_call < structure_heat_call);
    try std.testing.expect(structure_heat_call < root_ledgers_call);
    try std.testing.expect(manure < evaluation);
    try std.testing.expect(evaluation < acceptance);
    try std.testing.expect(cell_acceptance < counter);
    try std.testing.expect(counter < commit);
}
