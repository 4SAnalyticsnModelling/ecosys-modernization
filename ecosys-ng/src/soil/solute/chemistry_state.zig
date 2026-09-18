const std = @import("std");
const aqueous_network = @import("aqueous_network.zig");
const phosphate_network = @import("phosphate_network.zig");
const cation_exchange = @import("cation_exchange.zig");
const geochemistry = @import("geochemistry_network.zig");
const charge_classification = @import("charge_classification.zig");
const activity_coefficients = @import("activity_coefficients.zig");
const aqueous_reaction_rates = @import("aqueous_reaction_rates.zig");
const phosphate_reaction_rates = @import("phosphate_reaction_rates.zig");
const phosphate_exchange = @import("phosphate_exchange.zig");
const geochemistry_reaction_rates = @import("geochemistry_reaction_rates.zig");
const carboxyl_exchange = @import("carboxyl_exchange.zig");
const water_equilibrium = @import("water_equilibrium.zig");

pub const PhosphateTransformations = struct {
    non_band: phosphate_network.Transformations,
    band: phosphate_network.Transformations,
};

pub const ReactionParameters = struct {
    fractions: charge_classification.ZoneFractions,
    non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3: f64,
    band_phosphate_soil_mass_per_water_volume_megagrams_per_m3: f64,
    cation_exchange_capacity_mol_charge_per_megagram: f64,
    cation_exchange_water_ratios: CationExchangeWaterRatios,
    total_carboxyl_sites_mol_per_megagram: f64,
    carboxyl_exchange_parameters: carboxyl_exchange.Parameters,
    aqueous_constants: aqueous_reaction_rates.EquilibriumConstants,
    aqueous_kinetics: aqueous_reaction_rates.Kinetics,
    phosphate_constants: phosphate_reaction_rates.EquilibriumConstants,
    phosphate_surface: phosphate_exchange.Parameters,
    phosphate_minerals: ?phosphate_reaction_rates.MineralParameters,
    phosphate_kinetics: phosphate_reaction_rates.Kinetics,
    cation_exchange_parameters: cation_exchange.Parameters,
    geochemistry_products: geochemistry_reaction_rates.SolubilityProducts,
    geochemistry_kinetics: geochemistry_reaction_rates.Kinetics,
    water_activity_product_mol2_per_m6: f64,
    negligible_water_ion_concentration_mol_per_m3: f64,
};

pub const CationExchangeWaterRatios = struct {
    shared_megagrams_per_m3: f64,
    ammonium_non_band_megagrams_per_m3: f64,
    ammonium_band_megagrams_per_m3: f64,
};

pub const CellTransformations = struct {
    aqueous: aqueous_network.Transformations,
    non_band_phosphate: phosphate_network.Transformations,
    band_phosphate: phosphate_network.Transformations,
    non_band_phosphate_water_fraction: f64,
    band_phosphate_water_fraction: f64,
    non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3: f64 = 1,
    band_phosphate_soil_mass_per_water_volume_megagrams_per_m3: f64 = 1,
    cation_adsorption_mol_per_megagram: cation_exchange.Cations,
    cation_exchange_water_ratios: CationExchangeWaterRatios,
    geochemistry: geochemistry.Transformations,
    carboxyl_hydrogen_change_mol_per_megagram: f64 = 0,
    carboxyl_soil_mass_per_water_volume_megagrams_per_m3: f64 = 0,
};

const StagedCellUpdate = struct {
    aqueous: aqueous_network.State,
    aqueous_changes: aqueous_network.Transformations,
    non_band_phosphate: phosphate_network.State,
    band_phosphate: phosphate_network.State,
    water_mol_per_m3: f64,
    cation_exchange_mol_per_megagram: cation_exchange.Cations,
    carboxyl_bound_hydrogen_mol_per_megagram: f64,
    geochemistry_solids: geochemistry.SolidState,
};

/// Exact non-mutating diagnostic for an aqueous inventory rejected by the
/// atomic projected-water update. `applied_change_mol_per_m3` includes every
/// realized phosphate, geochemistry, exchange, and direct-aqueous
/// contribution at the caller's trial fraction.
pub const ProjectedAqueousRejection = struct {
    component_index: usize,
    component_name: []const u8,
    current_value_mol_per_m3: f64,
    applied_change_mol_per_m3: f64,
    candidate_value_mol_per_m3: f64,
};

/// The source keeps RH2O solvent change and RHHX water-pair reset in
/// separate owners. A stationary circulating surface reaction can have
/// nonzero values in both owners, while their sum is zero. Neither owner
/// alone is a physical net-water equilibrium residual.
pub const ReactionWaterBalance = struct {
    source_solvent_change_mol_per_m3: f64,
    projected_water_pair_extent_mol_per_m3: f64,
    net_water_change_mol_per_m3: f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    aqueous: []aqueous_network.State,
    non_band_phosphate: []phosphate_network.State,
    band_phosphate: []phosphate_network.State,
    water_mol_per_m3: []f64,
    /// Hourly extensive SOLUTE `TBH2O`: the equal H+/OH- extent from the
    /// terminal accepted water-equilibrium projection, after multiplication
    /// by the layer's liquid-water volume. This is a balance ledger, not the
    /// solvent-water concentration above, and is deliberately excluded from
    /// nonlinear solver vectors.
    water_equilibrium_balance_mol: []f64,
    cation_exchange_mol_per_megagram: []cation_exchange.Cations,
    carboxyl_bound_hydrogen_mol_per_megagram: []f64,
    geochemistry_solids: []geochemistry.SolidState,
    /// Live-water volume last seen while aqueous and water-normalized mineral
    /// concentrations still represented extensive SOLUTE `Z*` mass. Zero while
    /// the layer is wet. `solute.f:610` skips the reaction block when
    /// `VOLW ≤ ZEROS2` and never destroys those extensive pools; Zig stores the
    /// solve coordinates as concentrations, so this remembered carrier is the
    /// dry-side owner, matching litter `dry_reference_water_m3`.
    dry_reference_water_m3: []f64,
    /// Extensive immobile inventories whose concentration carrier temporarily
    /// vanished during REDIST. These owners are never solver coordinates: they
    /// remain in mol until the exact mass/water carrier is positive again.
    pending_cation_exchange_mol: []cation_exchange.Cations,
    pending_carboxyl_bound_hydrogen_mol: []f64,
    pending_non_band_phosphate_mol: []phosphate_network.State,
    pending_band_phosphate_mol: []phosphate_network.State,
    pending_geochemistry_solids_mol: []geochemistry.SolidState,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroChemistryCellCount;
        const aqueous = try allocator.alloc(aqueous_network.State, cell_count);
        errdefer allocator.free(aqueous);
        const non_band = try allocator.alloc(phosphate_network.State, cell_count);
        errdefer allocator.free(non_band);
        const band = try allocator.alloc(phosphate_network.State, cell_count);
        errdefer allocator.free(band);
        const water = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(water);
        const water_equilibrium_balance = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(water_equilibrium_balance);
        const exchange_state = try allocator.alloc(cation_exchange.Cations, cell_count);
        errdefer allocator.free(exchange_state);
        const carboxyl_bound_hydrogen = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(carboxyl_bound_hydrogen);
        const geochemistry_solids = try allocator.alloc(geochemistry.SolidState, cell_count);
        errdefer allocator.free(geochemistry_solids);
        const dry_reference_water = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(dry_reference_water);
        const pending_exchange = try allocator.alloc(cation_exchange.Cations, cell_count);
        errdefer allocator.free(pending_exchange);
        const pending_carboxyl = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(pending_carboxyl);
        const pending_non_band = try allocator.alloc(phosphate_network.State, cell_count);
        errdefer allocator.free(pending_non_band);
        const pending_band = try allocator.alloc(phosphate_network.State, cell_count);
        errdefer allocator.free(pending_band);
        const pending_geochemistry = try allocator.alloc(geochemistry.SolidState, cell_count);
        errdefer allocator.free(pending_geochemistry);
        for (aqueous) |*cell| zeroStruct(aqueous_network.State, cell);
        for (non_band) |*cell| zeroStruct(phosphate_network.State, cell);
        for (band) |*cell| zeroStruct(phosphate_network.State, cell);
        @memset(water, 0);
        @memset(water_equilibrium_balance, 0);
        for (exchange_state) |*cell| zeroStruct(cation_exchange.Cations, cell);
        @memset(carboxyl_bound_hydrogen, 0);
        for (geochemistry_solids) |*cell| zeroStruct(geochemistry.SolidState, cell);
        @memset(dry_reference_water, 0);
        for (pending_exchange) |*cell| zeroStruct(cation_exchange.Cations, cell);
        @memset(pending_carboxyl, 0);
        for (pending_non_band) |*cell| zeroStruct(phosphate_network.State, cell);
        for (pending_band) |*cell| zeroStruct(phosphate_network.State, cell);
        for (pending_geochemistry) |*cell| zeroStruct(geochemistry.SolidState, cell);
        return .{ .allocator = allocator, .cell_count = cell_count, .aqueous = aqueous, .non_band_phosphate = non_band, .band_phosphate = band, .water_mol_per_m3 = water, .water_equilibrium_balance_mol = water_equilibrium_balance, .cation_exchange_mol_per_megagram = exchange_state, .carboxyl_bound_hydrogen_mol_per_megagram = carboxyl_bound_hydrogen, .geochemistry_solids = geochemistry_solids, .dry_reference_water_m3 = dry_reference_water, .pending_cation_exchange_mol = pending_exchange, .pending_carboxyl_bound_hydrogen_mol = pending_carboxyl, .pending_non_band_phosphate_mol = pending_non_band, .pending_band_phosphate_mol = pending_band, .pending_geochemistry_solids_mol = pending_geochemistry };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.pending_geochemistry_solids_mol);
        self.allocator.free(self.pending_band_phosphate_mol);
        self.allocator.free(self.pending_non_band_phosphate_mol);
        self.allocator.free(self.pending_carboxyl_bound_hydrogen_mol);
        self.allocator.free(self.pending_cation_exchange_mol);
        self.allocator.free(self.dry_reference_water_m3);
        self.allocator.free(self.geochemistry_solids);
        self.allocator.free(self.carboxyl_bound_hydrogen_mol_per_megagram);
        self.allocator.free(self.cation_exchange_mol_per_megagram);
        self.allocator.free(self.water_equilibrium_balance_mol);
        self.allocator.free(self.water_mol_per_m3);
        self.allocator.free(self.band_phosphate);
        self.allocator.free(self.non_band_phosphate);
        self.allocator.free(self.aqueous);
        self.* = undefined;
    }

    /// Converts pending extensive REDIST owners back to their native
    /// concentration units exactly once a positive carrier exists. Publishing
    /// is atomic across every immobile chemistry owner in the cell.
    pub fn materializePendingSolids(
        self: *State,
        cell_index: usize,
        soil_mass_megagrams: f64,
        water_m3: f64,
        fractions: charge_classification.ZoneFractions,
    ) !void {
        if (cell_index >= self.cell_count) return error.ChemistryCellIndexOutOfBounds;
        if (!std.math.isFinite(soil_mass_megagrams) or soil_mass_megagrams < 0 or
            !std.math.isFinite(water_m3) or water_m3 < 0)
            return error.InvalidPendingChemistryCarrier;
        inline for (@typeInfo(charge_classification.ZoneFractions).@"struct".fields) |field| {
            const value = @field(fractions, field.name);
            if (!std.math.isFinite(value) or value < 0 or value > 1)
                return error.InvalidPendingChemistryCarrier;
        }
        inline for (.{
            .{ fractions.ammonium_non_band, fractions.ammonium_band },
            .{ fractions.nitrate_non_band, fractions.nitrate_band },
            .{ fractions.phosphate_non_band, fractions.phosphate_band },
        }) |pair| if (@abs(pair[0] + pair[1] - 1) > 64 * std.math.floatEps(f64))
            return error.InvalidPendingChemistryCarrier;

        var exchange = self.cation_exchange_mol_per_megagram[cell_index];
        var pending_exchange = self.pending_cation_exchange_mol[cell_index];
        inline for (@typeInfo(cation_exchange.Cations).@"struct".fields) |field| {
            const carrier = if (comptime std.mem.eql(u8, field.name, "ammonium_non_band"))
                soil_mass_megagrams * fractions.ammonium_non_band
            else if (comptime std.mem.eql(u8, field.name, "ammonium_band"))
                soil_mass_megagrams * fractions.ammonium_band
            else
                soil_mass_megagrams;
            try materializeOne(&@field(exchange, field.name), &@field(pending_exchange, field.name), carrier);
        }
        var carboxyl = self.carboxyl_bound_hydrogen_mol_per_megagram[cell_index];
        var pending_carboxyl = self.pending_carboxyl_bound_hydrogen_mol[cell_index];
        try materializeOne(&carboxyl, &pending_carboxyl, soil_mass_megagrams);

        var non_band = self.non_band_phosphate[cell_index];
        var pending_non_band = self.pending_non_band_phosphate_mol[cell_index];
        var band = self.band_phosphate[cell_index];
        var pending_band = self.pending_band_phosphate_mol[cell_index];
        inline for (.{ .{ &non_band, &pending_non_band, fractions.phosphate_non_band }, .{ &band, &pending_band, fractions.phosphate_band } }) |zone| {
            inline for (@typeInfo(phosphate_network.State).@"struct".fields) |field| {
                if (comptime isImmobilePhosphateField(field.name)) {
                    const carrier = (if (comptime std.mem.endsWith(u8, field.name, "_per_megagram")) soil_mass_megagrams else water_m3) * zone[2];
                    try materializeOne(&@field(zone[0].*, field.name), &@field(zone[1].*, field.name), carrier);
                } else if (@field(zone[1].*, field.name) != 0) {
                    return error.InvalidPendingChemistryState;
                }
            }
        }

        var solids = self.geochemistry_solids[cell_index];
        var pending_solids = self.pending_geochemistry_solids_mol[cell_index];
        inline for (@typeInfo(geochemistry.SolidState).@"struct".fields) |field|
            try materializeOne(&@field(solids, field.name), &@field(pending_solids, field.name), water_m3);

        self.cation_exchange_mol_per_megagram[cell_index] = exchange;
        self.pending_cation_exchange_mol[cell_index] = pending_exchange;
        self.carboxyl_bound_hydrogen_mol_per_megagram[cell_index] = carboxyl;
        self.pending_carboxyl_bound_hydrogen_mol[cell_index] = pending_carboxyl;
        self.non_band_phosphate[cell_index] = non_band;
        self.pending_non_band_phosphate_mol[cell_index] = pending_non_band;
        self.band_phosphate[cell_index] = band;
        self.pending_band_phosphate_mol[cell_index] = pending_band;
        self.geochemistry_solids[cell_index] = solids;
        self.pending_geochemistry_solids_mol[cell_index] = pending_solids;
    }

    pub fn resetWaterEquilibriumBalanceHourly(self: *State) void {
        @memset(self.water_equilibrium_balance_mol, 0);
    }

    /// Publishes one terminal accepted `RHHX * VOLW` contribution. Candidate
    /// and residual evaluations never call this method.
    pub fn publishAcceptedWaterEquilibriumBalance(
        self: *State,
        cell_index: usize,
        extent_mol_per_m3: f64,
        liquid_water_m3: f64,
    ) !void {
        if (cell_index >= self.cell_count)
            return error.ChemistryCellIndexOutOfBounds;
        if (!std.math.isFinite(extent_mol_per_m3) or
            !std.math.isFinite(liquid_water_m3) or liquid_water_m3 < 0)
            return error.InvalidChemistryWaterEquilibriumBalance;
        const contribution = extent_mol_per_m3 * liquid_water_m3;
        const next = self.water_equilibrium_balance_mol[cell_index] + contribution;
        if (!std.math.isFinite(contribution) or !std.math.isFinite(next))
            return error.InvalidChemistryWaterEquilibriumBalance;
        self.water_equilibrium_balance_mol[cell_index] = next;
    }

    fn stageCellUpdate(
        self: *State,
        cell_index: usize,
        transformations: CellTransformations,
        staged: *StagedCellUpdate,
    ) !void {
        if (cell_index >= self.cell_count) return error.ChemistryCellIndexOutOfBounds;
        staged.aqueous = self.aqueous[cell_index];
        staged.non_band_phosphate = self.non_band_phosphate[cell_index];
        staged.band_phosphate = self.band_phosphate[cell_index];
        staged.cation_exchange_mol_per_megagram =
            self.cation_exchange_mol_per_megagram[cell_index];
        staged.carboxyl_bound_hydrogen_mol_per_megagram =
            self.carboxyl_bound_hydrogen_mol_per_megagram[cell_index] +
            transformations.carboxyl_hydrogen_change_mol_per_megagram;
        const original_geochemistry = self.geochemistry_solids[cell_index];
        staged.geochemistry_solids = original_geochemistry;
        if (!std.math.isFinite(staged.carboxyl_bound_hydrogen_mol_per_megagram))
            return error.NonFiniteCarboxylExchangeState;
        if (staged.carboxyl_bound_hydrogen_mol_per_megagram < 0)
            return error.NegativeCarboxylExchangeState;
        if (!std.math.isFinite(transformations.carboxyl_soil_mass_per_water_volume_megagrams_per_m3) or transformations.carboxyl_soil_mass_per_water_volume_megagrams_per_m3 < 0) return error.InvalidCarboxylExchangeSoilWaterRatio;
        if (!validFraction(transformations.non_band_phosphate_water_fraction) or !validFraction(transformations.band_phosphate_water_fraction)) return error.InvalidPhosphateWaterFraction;
        staged.aqueous_changes = transformations.aqueous;
        staged.aqueous_changes.hydrogen -= transformations.carboxyl_hydrogen_change_mol_per_megagram * transformations.carboxyl_soil_mass_per_water_volume_megagrams_per_m3;
        try addCationExchange(
            &staged.cation_exchange_mol_per_megagram,
            &staged.aqueous_changes,
            transformations.cation_adsorption_mol_per_megagram,
            transformations.cation_exchange_water_ratios,
        );
        try geochemistry.state_updateSolids(
            &staged.geochemistry_solids,
            transformations.geochemistry,
        );
        addGeochemistry(
            &staged.aqueous_changes,
            try geochemistry.transformationsForRealizedSolidUpdate(
                original_geochemistry,
                staged.geochemistry_solids,
            ),
        );
        const realized_non_band_phosphate = try phosphate_network.state_updateRealized(
            &staged.non_band_phosphate,
            transformations.non_band_phosphate,
            transformations.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
        );
        const realized_band_phosphate = try phosphate_network.state_updateRealized(
            &staged.band_phosphate,
            transformations.band_phosphate,
            transformations.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
        );
        addSharedPhosphate(&staged.aqueous_changes, realized_non_band_phosphate, transformations.non_band_phosphate_water_fraction);
        addSharedPhosphate(&staged.aqueous_changes, realized_band_phosphate, transformations.band_phosphate_water_fraction);
        // SOLUTE.F 2225--2226: RH2O includes aqueous CO2 hydration as well
        // as the two fraction-weighted phosphate-zone contributions. Keep
        // this in the atomic live-state update so rejected solver candidates
        // can never publish reaction water.
        staged.water_mol_per_m3 = self.water_mol_per_m3[cell_index] +
            try State.sourceOrderWaterChangeMolPerM3(transformations);
        if (!std.math.isFinite(staged.water_mol_per_m3))
            return error.NonFiniteChemistryWaterState;
        if (staged.water_mol_per_m3 < 0)
            return error.NegativeChemistryWaterState;
    }

    fn publishStagedCellUpdate(
        self: *State,
        cell_index: usize,
        staged: StagedCellUpdate,
    ) void {
        self.aqueous[cell_index] = staged.aqueous;
        self.non_band_phosphate[cell_index] = staged.non_band_phosphate;
        self.band_phosphate[cell_index] = staged.band_phosphate;
        self.water_mol_per_m3[cell_index] = staged.water_mol_per_m3;
        self.cation_exchange_mol_per_megagram[cell_index] =
            staged.cation_exchange_mol_per_megagram;
        self.carboxyl_bound_hydrogen_mol_per_megagram[cell_index] =
            staged.carboxyl_bound_hydrogen_mol_per_megagram;
        self.geochemistry_solids[cell_index] = staged.geochemistry_solids;
    }

    /// Dimensionally safe replacement for SOLUTE.F lines 2295--2452. A
    /// chemistry iterate is atomic across the shared aqueous system and both
    /// fertilizer zones; no partial state survives a failed invariant check.
    pub fn state_updateCell(self: *State, cell_index: usize, transformations: CellTransformations) !void {
        var staged: StagedCellUpdate = undefined;
        try self.stageCellUpdate(cell_index, transformations, &staged);
        try aqueous_network.state_update(&staged.aqueous, staged.aqueous_changes);
        self.publishStagedCellUpdate(cell_index, staged);
    }

    /// Non-publishing balance residual before line-search damping. A blocked
    /// donor must not multiply every independent reaction by a vanishing
    /// fraction and thereby manufacture apparent chemical equilibrium.
    /// Negative residuals are legitimate balance defects, not stored pools.
    /// Trial publication still uses the atomic positive-inventory transaction.
    pub fn undampedReactionBalance(
        self: *const State,
        cell_index: usize,
        transformations: CellTransformations,
        monovalent_activity_coefficient: f64,
        water_activity_product_mol2_per_m6: f64,
        output: []f64,
    ) !void {
        _ = try self.undampedReactionBalanceWithWater(
            cell_index,
            transformations,
            monovalent_activity_coefficient,
            water_activity_product_mol2_per_m6,
            output,
        );
    }

    /// Returns the dependent water-pair extent alongside the undamped
    /// source-vector defect, without publishing or accumulating trial ledgers.
    /// The last output coordinate remains RH2O for compatibility with the
    /// packed source solvent owner; use the returned sum to audit net water.
    /// This diagnostic is not a replacement production acceptance gate.
    pub fn undampedReactionBalanceWithWater(
        self: *const State,
        cell_index: usize,
        transformations: CellTransformations,
        monovalent_activity_coefficient: f64,
        water_activity_product_mol2_per_m6: f64,
        output: []f64,
    ) !ReactionWaterBalance {
        if (cell_index >= self.cell_count) return error.ChemistryCellIndexOutOfBounds;
        if (output.len != packedComponentCount()) return error.ChemistryVectorSizeMismatch;
        try self.packCell(cell_index, output);
        for (output) |value| {
            if (!std.math.isFinite(value)) return error.NonFiniteChemistryVector;
            if (value < 0) return error.NegativeChemistryVector;
        }
        try validateCationExchangeWaterRatios(transformations.cation_adsorption_mol_per_megagram, transformations.cation_exchange_water_ratios);
        if (!validFraction(transformations.non_band_phosphate_water_fraction) or !validFraction(transformations.band_phosphate_water_fraction)) return error.InvalidPhosphateWaterFraction;
        if (!std.math.isFinite(transformations.carboxyl_soil_mass_per_water_volume_megagrams_per_m3) or transformations.carboxyl_soil_mass_per_water_volume_megagrams_per_m3 < 0) return error.InvalidCarboxylExchangeSoilWaterRatio;
        var aqueous = transformations.aqueous;
        aqueous.hydrogen -= transformations.carboxyl_hydrogen_change_mol_per_megagram *
            transformations.carboxyl_soil_mass_per_water_volume_megagrams_per_m3;
        addCationExchangeAqueousChanges(&aqueous, transformations.cation_adsorption_mol_per_megagram, transformations.cation_exchange_water_ratios);
        addGeochemistry(&aqueous, transformations.geochemistry);
        addSharedPhosphate(&aqueous, transformations.non_band_phosphate, transformations.non_band_phosphate_water_fraction);
        addSharedPhosphate(&aqueous, transformations.band_phosphate, transformations.band_phosphate_water_fraction);
        const original_aqueous = self.aqueous[cell_index];
        const water = try water_equilibrium.projectProvisional(
            original_aqueous.hydrogen + aqueous.hydrogen,
            original_aqueous.hydroxide + aqueous.hydroxide,
            monovalent_activity_coefficient,
            water_activity_product_mol2_per_m6,
        );
        aqueous.hydrogen = water.hydrogen_concentration_mol_per_m3 - original_aqueous.hydrogen;
        aqueous.hydroxide = water.hydroxide_concentration_mol_per_m3 - original_aqueous.hydroxide;
        var cursor: usize = 0;
        packStruct(aqueous_network.Transformations, aqueous, output, &cursor);
        inline for (.{ transformations.non_band_phosphate, transformations.band_phosphate }) |phosphate| {
            inline for (std.meta.fields(phosphate_network.State)) |field| {
                output[cursor] = @field(phosphate, field.name);
                cursor += 1;
            }
        }
        packStruct(cation_exchange.Cations, transformations.cation_adsorption_mol_per_megagram, output, &cursor);
        output[cursor] = transformations.carboxyl_hydrogen_change_mol_per_megagram;
        cursor += 1;
        inline for (std.meta.fields(geochemistry.SolidState)) |field| {
            output[cursor] = @field(transformations.geochemistry, field.name);
            cursor += 1;
        }
        output[cursor] = try sourceOrderWaterChangeMolPerM3(transformations);
        for (output) |value| if (!std.math.isFinite(value)) return error.NonFiniteChemistryVector;
        const net_water = output[cursor] + water.equal_reaction_extent_mol_per_m3;
        if (!std.math.isFinite(net_water)) return error.NonFiniteChemistryVector;
        return .{
            .source_solvent_change_mol_per_m3 = output[cursor],
            .projected_water_pair_extent_mol_per_m3 = water.equal_reaction_extent_mol_per_m3,
            .net_water_change_mol_per_m3 = net_water,
        };
    }

    /// Candidate-only atomic transaction for the dependent H+/OH- pair.
    /// Every solid and phosphate endpoint is realized first, so the signed
    /// provisional pair contains the exact changes that will be published.
    /// Only conserved aqueous coordinates are checked before H+/OH- are
    /// projected onto Kw; no intermediate negative free-ion value is clipped.
    pub fn state_updateCellProjectedWater(
        self: *State,
        cell_index: usize,
        transformations: CellTransformations,
        monovalent_activity_coefficient: f64,
        water_activity_product_mol2_per_m6: f64,
    ) !water_equilibrium.Result {
        var staged: StagedCellUpdate = undefined;
        try self.stageCellUpdate(cell_index, transformations, &staged);
        const water = try water_equilibrium.projectProvisional(
            staged.aqueous.hydrogen + staged.aqueous_changes.hydrogen,
            staged.aqueous.hydroxide + staged.aqueous_changes.hydroxide,
            monovalent_activity_coefficient,
            water_activity_product_mol2_per_m6,
        );
        staged.aqueous_changes.hydrogen = 0;
        staged.aqueous_changes.hydroxide = 0;
        try aqueous_network.state_update(&staged.aqueous, staged.aqueous_changes);
        staged.aqueous.hydrogen = water.hydrogen_concentration_mol_per_m3;
        staged.aqueous.hydroxide = water.hydroxide_concentration_mol_per_m3;
        self.publishStagedCellUpdate(cell_index, staged);
        return water;
    }

    /// Replays only the staging portion of `state_updateCellProjectedWater`
    /// and reports its first negative conserved aqueous coordinate. It never
    /// publishes staged state and deliberately excludes H+/OH-, which the
    /// production update projects onto Kw before validating conserved ions.
    pub fn diagnoseFirstNegativeProjectedAqueous(
        self: *State,
        cell_index: usize,
        transformations: CellTransformations,
    ) !?ProjectedAqueousRejection {
        var staged: StagedCellUpdate = undefined;
        try self.stageCellUpdate(cell_index, transformations, &staged);
        staged.aqueous_changes.hydrogen = 0;
        staged.aqueous_changes.hydroxide = 0;
        inline for (
            @typeInfo(aqueous_network.State).@"struct".fields,
            0..,
        ) |field, index| {
            const current_value = @field(staged.aqueous, field.name);
            const applied_change = @field(staged.aqueous_changes, field.name);
            const candidate_value = current_value + applied_change;
            if (candidate_value < 0) return .{
                .component_index = index,
                .component_name = field.name,
                .current_value_mol_per_m3 = current_value,
                .applied_change_mol_per_m3 = applied_change,
                .candidate_value_mol_per_m3 = candidate_value,
            };
        }
        return null;
    }

    /// Returns the complete shared-aqueous change assembled from every
    /// reaction family before the atomic cell state_update.
    pub fn assembledAqueousChanges(
        transformations: CellTransformations,
        current_exchange: cation_exchange.Cations,
    ) !aqueous_network.Transformations {
        var aqueous_changes = transformations.aqueous;
        aqueous_changes.hydrogen -=
            transformations.carboxyl_hydrogen_change_mol_per_megagram *
            transformations.carboxyl_soil_mass_per_water_volume_megagrams_per_m3;
        var exchange = current_exchange;
        try addCationExchange(
            &exchange,
            &aqueous_changes,
            transformations.cation_adsorption_mol_per_megagram,
            transformations.cation_exchange_water_ratios,
        );
        addGeochemistry(&aqueous_changes, transformations.geochemistry);
        addSharedPhosphate(
            &aqueous_changes,
            transformations.non_band_phosphate,
            transformations.non_band_phosphate_water_fraction,
        );
        addSharedPhosphate(
            &aqueous_changes,
            transformations.band_phosphate,
            transformations.band_phosphate_water_fraction,
        );
        return aqueous_changes;
    }

    /// Direct source-order `RH2O` diagnostic for SOLUTE.F lines 2225--2226.
    /// Production state mutation remains unchanged until restart and protected
    /// coupled-solver comparisons include this additional water owner.
    pub fn sourceOrderWaterChangeMolPerM3(
        transformations: CellTransformations,
    ) !f64 {
        if (!validFraction(transformations.non_band_phosphate_water_fraction) or
            !validFraction(transformations.band_phosphate_water_fraction))
            return error.InvalidPhosphateWaterFraction;
        const change = transformations.aqueous.carbon_dioxide +
            transformations.non_band_phosphate.water_mol_per_m3 *
                transformations.non_band_phosphate_water_fraction +
            transformations.band_phosphate.water_mol_per_m3 *
                transformations.band_phosphate_water_fraction;
        if (!std.math.isFinite(change)) return error.InvalidChemistryWaterState;
        return change;
    }

    pub fn evaluateCarboxylHydrogenChange(
        self: *const State,
        cell_index: usize,
        total_carboxyl_sites_mol_per_megagram: f64,
        hydrogen_activity_mol_per_m3: f64,
        soil_mass_per_water_volume_megagrams_per_m3: f64,
        parameters: carboxyl_exchange.Parameters,
    ) !f64 {
        if (cell_index >= self.cell_count) return error.ChemistryCellIndexOutOfBounds;
        return carboxyl_exchange.calculateChangeMolPerMg(.{
            .total_carboxyl_sites_mol_per_megagram = total_carboxyl_sites_mol_per_megagram,
            .hydrogen_occupied_sites_mol_per_megagram = self.carboxyl_bound_hydrogen_mol_per_megagram[cell_index],
            .hydrogen_activity_mol_per_m3 = hydrogen_activity_mol_per_m3,
            .soil_mass_per_water_volume_megagrams_per_m3 = soil_mass_per_water_volume_megagrams_per_m3,
        }, parameters);
    }

    pub fn packedComponentCount() usize {
        return @typeInfo(aqueous_network.State).@"struct".fields.len +
            2 * @typeInfo(phosphate_network.State).@"struct".fields.len +
            @typeInfo(cation_exchange.Cations).@"struct".fields.len +
            @typeInfo(geochemistry.SolidState).@"struct".fields.len + 2;
    }

    pub fn packedComponentName(index: usize) ?[]const u8 {
        var cursor: usize = 0;
        inline for (@typeInfo(aqueous_network.State).@"struct".fields) |field| {
            if (index == cursor) return "aqueous." ++ field.name;
            cursor += 1;
        }
        inline for (@typeInfo(phosphate_network.State).@"struct".fields) |field| {
            if (index == cursor) return "phosphate_non_band." ++ field.name;
            cursor += 1;
        }
        inline for (@typeInfo(phosphate_network.State).@"struct".fields) |field| {
            if (index == cursor) return "phosphate_band." ++ field.name;
            cursor += 1;
        }
        inline for (@typeInfo(cation_exchange.Cations).@"struct".fields) |field| {
            if (index == cursor) return "cation_exchange." ++ field.name;
            cursor += 1;
        }
        if (index == cursor) return "carboxyl_bound_hydrogen_mol_per_megagram";
        cursor += 1;
        inline for (@typeInfo(geochemistry.SolidState).@"struct".fields) |field| {
            if (index == cursor) return "geochemistry_solids." ++ field.name;
            cursor += 1;
        }
        if (index == cursor) return "water_mol_per_m3";
        return null;
    }

    /// The packed nonlinear vector mixes aqueous/solid mol/m3 coordinates
    /// with exchange/site mol/Mg coordinates. Keep that unit boundary
    /// explicit anywhere a numerical absolute tolerance is selected.
    pub fn packedComponentIsMolPerMegagram(index: usize) bool {
        var cursor: usize = 0;
        inline for (@typeInfo(aqueous_network.State).@"struct".fields) |field| {
            if (index == cursor)
                return comptime std.mem.endsWith(u8, field.name, "_per_megagram");
            cursor += 1;
        }
        inline for (0..2) |_| {
            inline for (@typeInfo(phosphate_network.State).@"struct".fields) |field| {
                if (index == cursor)
                    return comptime std.mem.endsWith(u8, field.name, "_per_megagram");
                cursor += 1;
            }
        }
        inline for (@typeInfo(cation_exchange.Cations).@"struct".fields) |_| {
            if (index == cursor) return true;
            cursor += 1;
        }
        if (index == cursor) return true; // carboxyl-bound H is mol/Mg.
        cursor += 1;
        inline for (@typeInfo(geochemistry.SolidState).@"struct".fields) |field| {
            if (index == cursor)
                return comptime std.mem.endsWith(u8, field.name, "_per_megagram");
            cursor += 1;
        }
        // Terminal solvent water is mol/m3; an invalid index is not silently
        // promoted into the exchange unit class.
        return false;
    }

    /// Packs one runtime cell into the vector consumed by the coupled hybrid
    /// solver. The chemistry species list is scientific structure; grid size,
    /// layers, zones, and solver storage remain runtime allocated.
    pub fn packCell(self: *const State, cell_index: usize, output: []f64) !void {
        if (cell_index >= self.cell_count) return error.ChemistryCellIndexOutOfBounds;
        if (output.len != packedComponentCount()) return error.ChemistryVectorSizeMismatch;
        var cursor: usize = 0;
        packStruct(aqueous_network.State, self.aqueous[cell_index], output, &cursor);
        packStruct(phosphate_network.State, self.non_band_phosphate[cell_index], output, &cursor);
        packStruct(phosphate_network.State, self.band_phosphate[cell_index], output, &cursor);
        packStruct(cation_exchange.Cations, self.cation_exchange_mol_per_megagram[cell_index], output, &cursor);
        output[cursor] = self.carboxyl_bound_hydrogen_mol_per_megagram[cell_index];
        cursor += 1;
        packStruct(geochemistry.SolidState, self.geochemistry_solids[cell_index], output, &cursor);
        output[cursor] = self.water_mol_per_m3[cell_index];
    }

    pub fn unpackCell(self: *State, cell_index: usize, input: []const f64) !void {
        if (cell_index >= self.cell_count) return error.ChemistryCellIndexOutOfBounds;
        if (input.len != packedComponentCount()) return error.ChemistryVectorSizeMismatch;
        var cursor: usize = 0;
        const aqueous = try unpackStruct(aqueous_network.State, input, &cursor);
        const non_band = try unpackStruct(phosphate_network.State, input, &cursor);
        const band = try unpackStruct(phosphate_network.State, input, &cursor);
        const exchange_state = try unpackStruct(cation_exchange.Cations, input, &cursor);
        const carboxyl_bound_hydrogen = input[cursor];
        cursor += 1;
        if (!std.math.isFinite(carboxyl_bound_hydrogen))
            return error.NonFiniteCarboxylExchangeState;
        if (carboxyl_bound_hydrogen < 0)
            return error.NegativeCarboxylExchangeState;
        const geochemistry_solids = try unpackStruct(geochemistry.SolidState, input, &cursor);
        const water = input[cursor];
        if (!std.math.isFinite(water))
            return error.NonFiniteChemistryWaterState;
        if (water < 0)
            return error.NegativeChemistryWaterState;
        self.aqueous[cell_index] = aqueous;
        self.non_band_phosphate[cell_index] = non_band;
        self.band_phosphate[cell_index] = band;
        self.cation_exchange_mol_per_megagram[cell_index] = exchange_state;
        self.carboxyl_bound_hydrogen_mol_per_megagram[cell_index] = carboxyl_bound_hydrogen;
        self.geochemistry_solids[cell_index] = geochemistry_solids;
        self.water_mol_per_m3[cell_index] = water;
    }

    pub fn activityCoefficients(self: *const State, cell_index: usize, fractions: charge_classification.ZoneFractions) !activity_coefficients.Result {
        if (cell_index >= self.cell_count) return error.ChemistryCellIndexOutOfBounds;
        const totals_per_m3 = try charge_classification.classify(self.aqueous[cell_index], self.non_band_phosphate[cell_index], self.band_phosphate[cell_index], fractions);
        return activity_coefficients.calculate(totals_per_m3, 1);
    }

    pub fn evaluateAqueousTransformations(self: *const State, cell_index: usize, fractions: charge_classification.ZoneFractions, constants: aqueous_reaction_rates.EquilibriumConstants, kinetics: aqueous_reaction_rates.Kinetics) !aqueous_network.Transformations {
        const coefficients = try self.activityCoefficients(cell_index, fractions);
        return self.evaluateAqueousTransformationsWithCoefficients(cell_index, fractions, coefficients, constants, kinetics);
    }

    fn evaluateAqueousTransformationsWithCoefficients(self: *const State, cell_index: usize, fractions: charge_classification.ZoneFractions, coefficients: activity_coefficients.Result, constants: aqueous_reaction_rates.EquilibriumConstants, kinetics: aqueous_reaction_rates.Kinetics) !aqueous_network.Transformations {
        const fluxes = try aqueous_reaction_rates.calculateSourceOrder(
            self.aqueous[cell_index],
            coefficients,
            constants,
            kinetics,
            .{
                .non_band = if (fractions.ammonium_non_band > 0) .wet else .dry,
                .band = if (fractions.ammonium_band > 0) .wet else .dry,
            },
        );
        return aqueous_network.assemble(fluxes, .{ .non_band = fractions.ammonium_non_band, .band = fractions.ammonium_band });
    }

    pub fn evaluatePhosphateTransformations(self: *const State, cell_index: usize, fractions: charge_classification.ZoneFractions, non_band_soil_mass_per_water_volume_megagrams_per_m3: f64, band_soil_mass_per_water_volume_megagrams_per_m3: f64, constants: phosphate_reaction_rates.EquilibriumConstants, surface_parameters: phosphate_exchange.Parameters, mineral_parameters: ?phosphate_reaction_rates.MineralParameters, kinetics: phosphate_reaction_rates.Kinetics) !PhosphateTransformations {
        const coefficients = try self.activityCoefficients(cell_index, fractions);
        return self.evaluatePhosphateTransformationsWithCoefficients(cell_index, fractions, coefficients, non_band_soil_mass_per_water_volume_megagrams_per_m3, band_soil_mass_per_water_volume_megagrams_per_m3, constants, surface_parameters, mineral_parameters, kinetics);
    }

    fn evaluatePhosphateTransformationsWithCoefficients(self: *const State, cell_index: usize, fractions: charge_classification.ZoneFractions, coefficients: activity_coefficients.Result, non_band_soil_mass_per_water_volume_megagrams_per_m3: f64, band_soil_mass_per_water_volume_megagrams_per_m3: f64, constants: phosphate_reaction_rates.EquilibriumConstants, surface_parameters: phosphate_exchange.Parameters, mineral_parameters: ?phosphate_reaction_rates.MineralParameters, kinetics: phosphate_reaction_rates.Kinetics) !PhosphateTransformations {
        const non_band = if (fractions.phosphate_non_band > 0) blk: {
            const fluxes = try phosphate_reaction_rates.calculate(self.aqueous[cell_index], self.non_band_phosphate[cell_index], coefficients, non_band_soil_mass_per_water_volume_megagrams_per_m3, constants, surface_parameters, mineral_parameters, kinetics);
            break :blk try phosphate_network.assemble(fluxes);
        } else std.mem.zeroes(phosphate_network.Transformations);
        const band = if (fractions.phosphate_band > 0) blk: {
            const fluxes = try phosphate_reaction_rates.calculate(self.aqueous[cell_index], self.band_phosphate[cell_index], coefficients, band_soil_mass_per_water_volume_megagrams_per_m3, constants, surface_parameters, mineral_parameters, kinetics);
            break :blk try phosphate_network.assemble(fluxes);
        } else std.mem.zeroes(phosphate_network.Transformations);
        return .{ .non_band = non_band, .band = band };
    }

    pub fn evaluateGeochemistryTransformations(self: *const State, cell_index: usize, fractions: charge_classification.ZoneFractions, products: geochemistry_reaction_rates.SolubilityProducts, kinetics: geochemistry_reaction_rates.Kinetics) !geochemistry.Transformations {
        const coefficients = try self.activityCoefficients(cell_index, fractions);
        return self.evaluateGeochemistryTransformationsWithCoefficients(cell_index, coefficients, products, kinetics);
    }

    fn evaluateGeochemistryTransformationsWithCoefficients(self: *const State, cell_index: usize, coefficients: activity_coefficients.Result, products: geochemistry_reaction_rates.SolubilityProducts, kinetics: geochemistry_reaction_rates.Kinetics) !geochemistry.Transformations {
        return geochemistry_reaction_rates.calculate(self.aqueous[cell_index], self.geochemistry_solids[cell_index], coefficients, products, kinetics);
    }

    pub fn evaluateCell(self: *const State, cell_index: usize, parameters: ReactionParameters) !CellTransformations {
        const coefficients = try self.activityCoefficients(cell_index, parameters.fractions);
        const aqueous = try self.evaluateAqueousTransformationsWithCoefficients(cell_index, parameters.fractions, coefficients, parameters.aqueous_constants, parameters.aqueous_kinetics);
        const phosphate = try self.evaluatePhosphateTransformationsWithCoefficients(cell_index, parameters.fractions, coefficients, parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3, parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3, parameters.phosphate_constants, parameters.phosphate_surface, parameters.phosphate_minerals, parameters.phosphate_kinetics);
        const shared = self.aqueous[cell_index];
        const concentrations = cation_exchange.Cations{
            .ammonium_non_band = shared.ammonium_non_band,
            .ammonium_band = shared.ammonium_band,
            .hydrogen = shared.hydrogen,
            .aluminum = shared.aluminum,
            .iron = shared.iron,
            .calcium = shared.calcium,
            .magnesium = shared.magnesium,
            .sodium = shared.sodium,
            .potassium = shared.potassium,
        };
        const activities = cation_exchange.Cations{
            .ammonium_non_band = shared.ammonium_non_band * coefficients.monovalent_activity_coefficient,
            .ammonium_band = shared.ammonium_band * coefficients.monovalent_activity_coefficient,
            .hydrogen = shared.hydrogen * coefficients.monovalent_activity_coefficient,
            .aluminum = shared.aluminum * coefficients.trivalent_activity_coefficient,
            .iron = shared.iron * coefficients.trivalent_activity_coefficient,
            .calcium = shared.calcium * coefficients.divalent_activity_coefficient,
            .magnesium = shared.magnesium * coefficients.divalent_activity_coefficient,
            .sodium = shared.sodium * coefficients.monovalent_activity_coefficient,
            .potassium = shared.potassium * coefficients.monovalent_activity_coefficient,
        };
        const adsorption = try cation_exchange.calculateSourceOrder(.{
            .cation_exchange_capacity_mol_charge_per_megagram = parameters.cation_exchange_capacity_mol_charge_per_megagram,
            .aqueous_concentration_mol_per_m3 = concentrations,
            .aqueous_activity_mol_per_m3 = activities,
            .exchange_concentration_mol_per_megagram = self.cation_exchange_mol_per_megagram[cell_index],
            .ammonium_non_band_fraction = parameters.fractions.ammonium_non_band,
            .ammonium_band_fraction = parameters.fractions.ammonium_band,
            .soil_mass_per_water_volume_megagrams_per_m3 = parameters.cation_exchange_water_ratios.shared_megagrams_per_m3,
        }, parameters.cation_exchange_parameters, .{
            .minimum_activity_mol_per_m3 = parameters.negligible_water_ion_concentration_mol_per_m3,
        });
        const carboxyl_hydrogen_change = try self.evaluateCarboxylHydrogenChange(
            cell_index,
            parameters.total_carboxyl_sites_mol_per_megagram,
            activities.hydrogen,
            parameters.cation_exchange_water_ratios.shared_megagrams_per_m3,
            parameters.carboxyl_exchange_parameters,
        );
        return .{
            .aqueous = aqueous,
            .non_band_phosphate = phosphate.non_band,
            .band_phosphate = phosphate.band,
            .non_band_phosphate_water_fraction = parameters.fractions.phosphate_non_band,
            .band_phosphate_water_fraction = parameters.fractions.phosphate_band,
            .non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
            .band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
            .cation_adsorption_mol_per_megagram = adsorption,
            .cation_exchange_water_ratios = parameters.cation_exchange_water_ratios,
            .geochemistry = try self.evaluateGeochemistryTransformationsWithCoefficients(cell_index, coefficients, parameters.geochemistry_products, parameters.geochemistry_kinetics),
            .carboxyl_hydrogen_change_mol_per_megagram = carboxyl_hydrogen_change,
            .carboxyl_soil_mass_per_water_volume_megagrams_per_m3 = parameters.cation_exchange_water_ratios.shared_megagrams_per_m3,
        };
    }
};

test "packed chemistry tolerance units classify both phosphate zones exactly" {
    const aqueous_count = @typeInfo(aqueous_network.State).@"struct".fields.len;
    const phosphate_count = @typeInfo(phosphate_network.State).@"struct".fields.len;
    const exchange_count = @typeInfo(cation_exchange.Cations).@"struct".fields.len;
    const geochemistry_count = @typeInfo(geochemistry.SolidState).@"struct".fields.len;
    const dissolved_offset = std.meta.fieldIndex(
        phosphate_network.State,
        "dissolved_hpo4_mol_p_per_m3",
    ).?;
    const site_offset = std.meta.fieldIndex(
        phosphate_network.State,
        "deprotonated_site_mol_per_megagram",
    ).?;
    const adsorbed_offset = std.meta.fieldIndex(
        phosphate_network.State,
        "adsorbed_h2po4_mol_p_per_megagram",
    ).?;

    try std.testing.expect(!State.packedComponentIsMolPerMegagram(0));
    inline for (0..2) |zone| {
        const start = aqueous_count + zone * phosphate_count;
        try std.testing.expect(!State.packedComponentIsMolPerMegagram(start + dissolved_offset));
        try std.testing.expect(State.packedComponentIsMolPerMegagram(start + site_offset));
        try std.testing.expect(State.packedComponentIsMolPerMegagram(start + adsorbed_offset));
    }
    const exchange_start = aqueous_count + 2 * phosphate_count;
    try std.testing.expect(State.packedComponentIsMolPerMegagram(exchange_start));
    const carboxyl_index = exchange_start + exchange_count;
    try std.testing.expect(State.packedComponentIsMolPerMegagram(carboxyl_index));
    const geochemistry_start = carboxyl_index + 1;
    try std.testing.expect(!State.packedComponentIsMolPerMegagram(geochemistry_start));
    const water_index = geochemistry_start + geochemistry_count;
    try std.testing.expect(!State.packedComponentIsMolPerMegagram(water_index));
}

fn zeroStruct(comptime T: type, value: *T) void {
    inline for (@typeInfo(T).@"struct".fields) |field| @field(value.*, field.name) = 0;
}

fn filledStruct(comptime T: type, amount: f64) T {
    var value: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| @field(value, field.name) = amount;
    return value;
}

test "inactive ammonium zone accepts only zero exchange flux" {
    var exchange_state = filledStruct(cation_exchange.Cations, 0);
    var aqueous = filledStruct(aqueous_network.Transformations, 0);
    var adsorption = filledStruct(cation_exchange.Cations, 0);
    const ratios: CationExchangeWaterRatios = .{
        .shared_megagrams_per_m3 = 1.5,
        .ammonium_non_band_megagrams_per_m3 = 1.5,
        .ammonium_band_megagrams_per_m3 = 0,
    };
    try addCationExchange(
        &exchange_state,
        &aqueous,
        adsorption,
        ratios,
    );
    adsorption.ammonium_band = 1.0e-6;
    try std.testing.expectError(
        error.InactiveAmmoniumZoneHasExchangeFlux,
        addCationExchange(&exchange_state, &aqueous, adsorption, ratios),
    );
}

test "addCationExchange is a true zero-in-zero-out identity" {
    // PERF-REACTION-SPAN-CLOSED-FORM-001: a closed-form (affine)
    // replacement for the reaction-span extent search assumes a reaction
    // not touching cation exchange passes an all-zero `adsorption` here
    // and leaves both `exchange_state` and `aqueous` completely
    // unchanged, bit-for-bit. Prove it with large, unevenly-scaled
    // starting values so any nonzero perturbation would be visible.
    var exchange_state = filledStruct(cation_exchange.Cations, 0);
    exchange_state.calcium = 0x1p40;
    exchange_state.hydrogen = 0x1p-30;
    const before_exchange = exchange_state;
    var aqueous = filledStruct(aqueous_network.Transformations, 0);
    aqueous.calcium = 0x1p35;
    aqueous.ammonium_non_band = -0x1p-25;
    const before_aqueous = aqueous;
    const zero_adsorption = filledStruct(cation_exchange.Cations, 0);
    const ratios: CationExchangeWaterRatios = .{
        .shared_megagrams_per_m3 = 1.5,
        .ammonium_non_band_megagrams_per_m3 = 1.5,
        .ammonium_band_megagrams_per_m3 = 0.7,
    };
    try addCationExchange(&exchange_state, &aqueous, zero_adsorption, ratios);
    try std.testing.expectEqualDeep(before_exchange, exchange_state);
    try std.testing.expectEqualDeep(before_aqueous, aqueous);
}

fn packStruct(comptime T: type, value: T, output: []f64, cursor: *usize) void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        output[cursor.*] = @field(value, field.name);
        cursor.* += 1;
    }
}

fn unpackStruct(comptime T: type, input: []const f64, cursor: *usize) !T {
    var value: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const component = input[cursor.*];
        if (!std.math.isFinite(component)) return error.NonFiniteChemistryVector;
        if (component < 0) return error.NegativeChemistryVector;
        @field(value, field.name) = component;
        cursor.* += 1;
    }
    return value;
}

fn validFraction(value: f64) bool {
    return std.math.isFinite(value) and value >= 0 and value <= 1;
}

fn addSharedPhosphate(aqueous: *aqueous_network.Transformations, phosphate: phosphate_network.Transformations, water_fraction: f64) void {
    aqueous.aluminum += phosphate.dissolved_aluminum_mol_per_m3 * water_fraction;
    aqueous.iron += phosphate.dissolved_iron_mol_per_m3 * water_fraction;
    aqueous.calcium += phosphate.dissolved_calcium_mol_per_m3 * water_fraction;
    aqueous.magnesium += phosphate.dissolved_magnesium_mol_per_m3 * water_fraction;
    aqueous.hydrogen += phosphate.dissolved_hydrogen_mol_per_m3 * water_fraction;
    aqueous.hydroxide += phosphate.dissolved_hydroxide_mol_per_m3 * water_fraction;
}

fn addCationExchange(exchange_state: *cation_exchange.Cations, aqueous: *aqueous_network.Transformations, adsorption: cation_exchange.Cations, ratios: CationExchangeWaterRatios) !void {
    try validateCationExchangeWaterRatios(adsorption, ratios);
    inline for (@typeInfo(cation_exchange.Cations).@"struct".fields) |field| {
        const flux = @field(adsorption, field.name);
        if (!std.math.isFinite(flux)) return error.NonFiniteCationExchangeTransformation;
        @field(exchange_state.*, field.name) += flux;
        if (@field(exchange_state.*, field.name) < 0) return error.NegativeCationExchangeState;
    }
    addCationExchangeAqueousChanges(aqueous, adsorption, ratios);
}

fn validateCationExchangeWaterRatios(adsorption: cation_exchange.Cations, ratios: CationExchangeWaterRatios) !void {
    if (!std.math.isFinite(ratios.shared_megagrams_per_m3) or
        ratios.shared_megagrams_per_m3 <= 0 or
        !std.math.isFinite(ratios.ammonium_non_band_megagrams_per_m3) or
        ratios.ammonium_non_band_megagrams_per_m3 < 0 or
        !std.math.isFinite(ratios.ammonium_band_megagrams_per_m3) or
        ratios.ammonium_band_megagrams_per_m3 < 0)
        return error.InvalidCationExchangeWaterRatio;
    // SOLUTE sets BKVLWH/BKVLWB to zero for an inactive zero-water zone.
    // Such a zone must also contribute exactly zero adsorption; accepting a
    // nonzero flux here would silently discard or create aqueous ammonium.
    if ((ratios.ammonium_non_band_megagrams_per_m3 == 0 and
        adsorption.ammonium_non_band != 0) or
        (ratios.ammonium_band_megagrams_per_m3 == 0 and
            adsorption.ammonium_band != 0))
        return error.InactiveAmmoniumZoneHasExchangeFlux;
}

fn addCationExchangeAqueousChanges(aqueous: *aqueous_network.Transformations, adsorption: cation_exchange.Cations, ratios: CationExchangeWaterRatios) void {
    aqueous.ammonium_non_band -= adsorption.ammonium_non_band * ratios.ammonium_non_band_megagrams_per_m3;
    aqueous.ammonium_band -= adsorption.ammonium_band * ratios.ammonium_band_megagrams_per_m3;
    aqueous.hydrogen -= adsorption.hydrogen * ratios.shared_megagrams_per_m3;
    aqueous.aluminum -= adsorption.aluminum * ratios.shared_megagrams_per_m3;
    aqueous.iron -= adsorption.iron * ratios.shared_megagrams_per_m3;
    aqueous.calcium -= adsorption.calcium * ratios.shared_megagrams_per_m3;
    aqueous.magnesium -= adsorption.magnesium * ratios.shared_megagrams_per_m3;
    aqueous.sodium -= adsorption.sodium * ratios.shared_megagrams_per_m3;
    aqueous.potassium -= adsorption.potassium * ratios.shared_megagrams_per_m3;
}

fn addGeochemistry(aqueous: *aqueous_network.Transformations, transformations: geochemistry.Transformations) void {
    aqueous.aluminum += transformations.dissolved_aluminum_mol_per_m3;
    aqueous.iron += transformations.dissolved_iron_mol_per_m3;
    aqueous.calcium += transformations.dissolved_calcium_mol_per_m3;
    aqueous.magnesium += transformations.dissolved_magnesium_mol_per_m3;
    aqueous.sodium += transformations.dissolved_sodium_mol_per_m3;
    aqueous.potassium += transformations.dissolved_potassium_mol_per_m3;
    aqueous.hydrogen += transformations.dissolved_hydrogen_mol_per_m3;
    aqueous.hydroxide += transformations.dissolved_hydroxide_mol_per_m3;
    aqueous.carbonate += transformations.dissolved_carbonate_mol_per_m3;
    aqueous.sulfate += transformations.dissolved_sulfate_mol_per_m3;
    aqueous.hydrogen_silicate += transformations.dissolved_hydrogen_silicate_mol_per_m3;
}

fn materializeOne(concentration: *f64, pending_mol: *f64, carrier: f64) !void {
    inline for (.{ concentration.*, pending_mol.*, carrier }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidPendingChemistryState;
    if (carrier == 0 or pending_mol.* == 0) return;
    const next = concentration.* + pending_mol.* / carrier;
    if (!std.math.isFinite(next) or next < 0) return error.InvalidPendingChemistryState;
    concentration.* = next;
    pending_mol.* = 0;
}

fn isImmobilePhosphateField(comptime name: []const u8) bool {
    @setEvalBranchQuota(10_000);
    return std.mem.endsWith(u8, name, "_per_megagram") or
        std.mem.indexOf(u8, name, "_solid_mol_per_m3") != null;
}

test "chemistry state uses runtime cell allocation" {
    var state = try State.init(std.testing.allocator, 7);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 7), state.aqueous.len);
    try std.testing.expectEqual(@as(usize, 7), state.non_band_phosphate.len);
    try std.testing.expectEqual(@as(usize, 7), state.band_phosphate.len);
    try std.testing.expectEqual(@as(usize, 7), state.water_mol_per_m3.len);
    try std.testing.expectEqual(@as(usize, 7), state.cation_exchange_mol_per_megagram.len);
    try std.testing.expectEqual(@as(usize, 7), state.geochemistry_solids.len);
    try std.testing.expectEqual(@as(usize, 7), state.water_equilibrium_balance_mol.len);
    try std.testing.expectEqual(@as(usize, 7), state.dry_reference_water_m3.len);
    try std.testing.expectEqual(@as(usize, 7), state.pending_cation_exchange_mol.len);
    try std.testing.expectEqual(@as(usize, 7), state.pending_non_band_phosphate_mol.len);
    try std.testing.expectEqual(@as(usize, 7), state.pending_geochemistry_solids_mol.len);
}

test "accepted water equilibrium balance converts volume once and resets hourly" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    try state.publishAcceptedWaterEquilibriumBalance(1, 0.08, 0.25);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.02),
        state.water_equilibrium_balance_mol[1],
        1e-16,
    );
    state.resetWaterEquilibriumBalanceHourly();
    try std.testing.expectEqual(@as(f64, 0), state.water_equilibrium_balance_mol[1]);
    try std.testing.expectError(
        error.InvalidChemistryWaterEquilibriumBalance,
        state.publishAcceptedWaterEquilibriumBalance(0, std.math.nan(f64), 1),
    );
}

test "production resets accepted water equilibrium ledgers once per external hour" {
    const production = @embedFile("../../ecosys_ng.zig");
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            production,
            "driver_context.initial_chemistry_state.*.resetWaterEquilibriumBalanceHourly()",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            production,
            "driver_context.surface_litter_chemistry_state.*.resetWaterEquilibriumBalanceHourly()",
        ),
    );
    const soil_stage = @embedFile("../../stages/soil_chemistry_convergence.zig");
    const litter_stage = @embedFile("../../stages/surface_litter_convergence.zig");
    try std.testing.expect(std.mem.indexOf(
        u8,
        soil_stage,
        "resetWaterEquilibriumBalanceHourly",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        litter_stage,
        "resetWaterEquilibriumBalanceHourly",
    ) == null);
}

test "cell chemistry state_update is atomic across aqueous and both phosphate zones" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.aqueous[1] = filledStruct(aqueous_network.State, 1);
    state.non_band_phosphate[1] = filledStruct(phosphate_network.State, 1);
    state.band_phosphate[1] = filledStruct(phosphate_network.State, 1);
    const before_aqueous = state.aqueous[1];
    const before_non_band = state.non_band_phosphate[1];
    const before_band = state.band_phosphate[1];
    const before_water = state.water_mol_per_m3[1];
    const before_exchange = state.cation_exchange_mol_per_megagram[1];
    const before_carboxyl = state.carboxyl_bound_hydrogen_mol_per_megagram[1];
    const before_geochemistry = state.geochemistry_solids[1];
    const before_pending_exchange = state.pending_cation_exchange_mol[1];
    const before_pending_carboxyl = state.pending_carboxyl_bound_hydrogen_mol[1];
    const before_pending_non_band = state.pending_non_band_phosphate_mol[1];
    const before_pending_band = state.pending_band_phosphate_mol[1];
    const before_pending_geochemistry = state.pending_geochemistry_solids_mol[1];
    var aqueous_change = filledStruct(aqueous_network.Transformations, 0);
    var non_band_change = filledStruct(phosphate_network.Transformations, 0);
    var band_change = filledStruct(phosphate_network.Transformations, 0);
    aqueous_change.calcium = 0.1;
    non_band_change.dissolved_h2po4_mol_p_per_m3 = 0.1;
    non_band_change.dissolved_po4_mol_p_per_m3 = -0.1;
    band_change.dissolved_h2po4_mol_p_per_m3 = -2;
    try std.testing.expectError(error.NegativePhosphateNetworkState, state.state_updateCell(1, .{ .aqueous = aqueous_change, .non_band_phosphate = non_band_change, .band_phosphate = band_change, .non_band_phosphate_water_fraction = 0.8, .band_phosphate_water_fraction = 0.2, .cation_adsorption_mol_per_megagram = filledStruct(cation_exchange.Cations, 0), .cation_exchange_water_ratios = .{ .shared_megagrams_per_m3 = 1, .ammonium_non_band_megagrams_per_m3 = 1, .ammonium_band_megagrams_per_m3 = 1 }, .geochemistry = filledStruct(geochemistry.Transformations, 0) }));
    try std.testing.expectEqualDeep(before_aqueous, state.aqueous[1]);
    try std.testing.expectEqualDeep(before_non_band, state.non_band_phosphate[1]);
    try std.testing.expectEqualDeep(before_band, state.band_phosphate[1]);
    try std.testing.expectEqual(before_water, state.water_mol_per_m3[1]);
    try std.testing.expectEqualDeep(before_exchange, state.cation_exchange_mol_per_megagram[1]);
    try std.testing.expectEqual(before_carboxyl, state.carboxyl_bound_hydrogen_mol_per_megagram[1]);
    try std.testing.expectEqualDeep(before_geochemistry, state.geochemistry_solids[1]);
    try std.testing.expectEqualDeep(before_pending_exchange, state.pending_cation_exchange_mol[1]);
    try std.testing.expectEqual(before_pending_carboxyl, state.pending_carboxyl_bound_hydrogen_mol[1]);
    try std.testing.expectEqualDeep(before_pending_non_band, state.pending_non_band_phosphate_mol[1]);
    try std.testing.expectEqualDeep(before_pending_band, state.pending_band_phosphate_mol[1]);
    try std.testing.expectEqualDeep(before_pending_geochemistry, state.pending_geochemistry_solids_mol[1]);
}

test "projected cell update accepts signed provisional water ions atomically" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0].hydrogen = 1;
    state.aqueous[0].hydroxide = 1;
    state.aqueous[0].calcium = 1;
    var aqueous_change = filledStruct(aqueous_network.Transformations, 0);
    aqueous_change.hydroxide = -2;
    aqueous_change.calcium = -0.25;
    const zero_phosphate = filledStruct(phosphate_network.Transformations, 0);
    const transformations: CellTransformations = .{
        .aqueous = aqueous_change,
        .non_band_phosphate = zero_phosphate,
        .band_phosphate = zero_phosphate,
        .non_band_phosphate_water_fraction = 0.5,
        .band_phosphate_water_fraction = 0.5,
        .cation_adsorption_mol_per_megagram = filledStruct(cation_exchange.Cations, 0),
        .cation_exchange_water_ratios = .{
            .shared_megagrams_per_m3 = 1,
            .ammonium_non_band_megagrams_per_m3 = 1,
            .ammonium_band_megagrams_per_m3 = 1,
        },
        .geochemistry = filledStruct(geochemistry.Transformations, 0),
    };
    const water = try state.state_updateCellProjectedWater(
        0,
        transformations,
        1,
        1,
    );
    try std.testing.expect(state.aqueous[0].hydrogen > 0);
    try std.testing.expect(state.aqueous[0].hydroxide > 0);
    try std.testing.expectApproxEqAbs(
        @as(f64, 1),
        state.aqueous[0].hydrogen * state.aqueous[0].hydroxide,
        16 * std.math.floatEps(f64),
    );
    try std.testing.expectEqual(
        water.hydrogen_concentration_mol_per_m3,
        state.aqueous[0].hydrogen,
    );
    try std.testing.expectEqual(
        water.hydroxide_concentration_mol_per_m3,
        state.aqueous[0].hydroxide,
    );
    try std.testing.expectEqual(@as(f64, 0.75), state.aqueous[0].calcium);

    const before = state.aqueous[0];
    var invalid = transformations;
    invalid.aqueous.hydroxide = 0;
    invalid.aqueous.calcium = -1;
    const rejection = (try state.diagnoseFirstNegativeProjectedAqueous(
        0,
        invalid,
    )).?;
    try std.testing.expectEqual(
        std.meta.fieldIndex(aqueous_network.State, "calcium").?,
        rejection.component_index,
    );
    try std.testing.expectEqualStrings("calcium", rejection.component_name);
    try std.testing.expectEqual(@as(f64, 0.75), rejection.current_value_mol_per_m3);
    try std.testing.expectEqual(@as(f64, -1), rejection.applied_change_mol_per_m3);
    try std.testing.expectEqual(@as(f64, -0.25), rejection.candidate_value_mol_per_m3);
    try std.testing.expectError(
        error.NegativeAqueousState,
        state.state_updateCellProjectedWater(0, invalid, 1, 1),
    );
    try std.testing.expectEqualDeep(before, state.aqueous[0]);
}

test "runtime chemistry cell round trips through hybrid solver vector" {
    var state = try State.init(std.testing.allocator, 3);
    defer state.deinit();
    state.aqueous[2] = filledStruct(aqueous_network.State, 0.25);
    state.non_band_phosphate[2] = filledStruct(phosphate_network.State, 0.5);
    state.band_phosphate[2] = filledStruct(phosphate_network.State, 0.75);
    const vector = try std.testing.allocator.alloc(f64, State.packedComponentCount());
    defer std.testing.allocator.free(vector);
    try state.packCell(2, vector);
    state.aqueous[2] = filledStruct(aqueous_network.State, 0);
    state.non_band_phosphate[2] = filledStruct(phosphate_network.State, 0);
    state.band_phosphate[2] = filledStruct(phosphate_network.State, 0);
    try state.unpackCell(2, vector);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), state.aqueous[2].calcium, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), state.non_band_phosphate[2].dissolved_h2po4_mol_p_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), state.band_phosphate[2].hydroxyapatite_solid_mol_per_m3, 1e-15);
}

test "band and non-band phosphate reactions update one fraction-weighted shared state" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = filledStruct(aqueous_network.State, 10);
    state.water_mol_per_m3[0] = 10;
    state.non_band_phosphate[0].dissolved_hpo4_mol_p_per_m3 = 10;
    state.band_phosphate[0].dissolved_hpo4_mol_p_per_m3 = 10;
    const aqueous_change = filledStruct(aqueous_network.Transformations, 0);
    var non_band_change = filledStruct(phosphate_network.Transformations, 0);
    var band_change = filledStruct(phosphate_network.Transformations, 0);
    non_band_change.dissolved_hpo4_mol_p_per_m3 = -1;
    band_change.dissolved_hpo4_mol_p_per_m3 = -1;
    non_band_change.calcium_hpo4_pair_mol_per_m3 = 1;
    band_change.calcium_hpo4_pair_mol_per_m3 = 1;
    non_band_change.dissolved_calcium_mol_per_m3 = -1;
    band_change.dissolved_calcium_mol_per_m3 = -1;
    non_band_change.water_mol_per_m3 = 2;
    band_change.water_mol_per_m3 = 4;
    try state.state_updateCell(0, .{
        .aqueous = aqueous_change,
        .non_band_phosphate = non_band_change,
        .band_phosphate = band_change,
        .non_band_phosphate_water_fraction = 0.75,
        .band_phosphate_water_fraction = 0.25,
        .cation_adsorption_mol_per_megagram = filledStruct(cation_exchange.Cations, 0),
        .cation_exchange_water_ratios = .{ .shared_megagrams_per_m3 = 1, .ammonium_non_band_megagrams_per_m3 = 1, .ammonium_band_megagrams_per_m3 = 1 },
        .geochemistry = filledStruct(geochemistry.Transformations, 0),
    });
    try std.testing.expectApproxEqAbs(@as(f64, 9), state.aqueous[0].calcium, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), state.water_mol_per_m3[0], 1e-15);
}

test "cation adsorption uses distinct shared and ammonium water ratios" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = filledStruct(aqueous_network.State, 10);
    var adsorption = filledStruct(cation_exchange.Cations, 0);
    adsorption.ammonium_non_band = 0.1;
    adsorption.ammonium_band = 0.2;
    adsorption.calcium = 0.3;
    try state.state_updateCell(0, .{
        .aqueous = filledStruct(aqueous_network.Transformations, 0),
        .non_band_phosphate = filledStruct(phosphate_network.Transformations, 0),
        .band_phosphate = filledStruct(phosphate_network.Transformations, 0),
        .non_band_phosphate_water_fraction = 0.8,
        .band_phosphate_water_fraction = 0.2,
        .cation_adsorption_mol_per_megagram = adsorption,
        .cation_exchange_water_ratios = .{ .shared_megagrams_per_m3 = 2, .ammonium_non_band_megagrams_per_m3 = 3, .ammonium_band_megagrams_per_m3 = 4 },
        .geochemistry = filledStruct(geochemistry.Transformations, 0),
    });
    try std.testing.expectApproxEqAbs(@as(f64, 9.7), state.aqueous[0].ammonium_non_band, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 9.2), state.aqueous[0].ammonium_band, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 9.4), state.aqueous[0].calcium, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), state.cation_exchange_mol_per_megagram[0].calcium, 1e-15);
}

test "carboxyl protonation conserves hydrogen across solid and aqueous pools" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0].hydrogen = 1;
    const zero_aqueous = filledStruct(aqueous_network.Transformations, 0);
    const zero_phosphate = filledStruct(phosphate_network.Transformations, 0);
    try state.state_updateCell(0, .{
        .aqueous = zero_aqueous,
        .non_band_phosphate = zero_phosphate,
        .band_phosphate = zero_phosphate,
        .non_band_phosphate_water_fraction = 0.5,
        .band_phosphate_water_fraction = 0.5,
        .cation_adsorption_mol_per_megagram = filledStruct(cation_exchange.Cations, 0),
        .cation_exchange_water_ratios = .{ .shared_megagrams_per_m3 = 2, .ammonium_non_band_megagrams_per_m3 = 2, .ammonium_band_megagrams_per_m3 = 2 },
        .geochemistry = filledStruct(geochemistry.Transformations, 0),
        .carboxyl_hydrogen_change_mol_per_megagram = 0.2,
        .carboxyl_soil_mass_per_water_volume_megagrams_per_m3 = 2,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), state.carboxyl_bound_hydrogen_mol_per_megagram[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), state.aqueous[0].hydrogen, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), state.aqueous[0].hydrogen + 2 * state.carboxyl_bound_hydrogen_mol_per_megagram[0], 1e-15);
}

test "shared geochemistry updates aqueous and solid pools in one transaction" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = filledStruct(aqueous_network.State, 10);
    state.geochemistry_solids[0] = filledStruct(geochemistry.SolidState, 1);
    const changes = try geochemistry.assemble(
        .{ .gibbsite_precipitation_mol_per_m3 = 0.1, .iron_hydroxide_precipitation_mol_per_m3 = 0, .calcite_precipitation_mol_per_m3 = 0, .gypsum_precipitation_mol_per_m3 = 0 },
        .{ .aluminum_natural_mol_per_m3 = 0.02, .aluminum_ground_mol_per_m3 = 0, .iron_natural_mol_per_m3 = 0, .iron_ground_mol_per_m3 = 0, .calcium_natural_mol_per_m3 = 0, .calcium_ground_mol_per_m3 = 0, .magnesium_natural_mol_per_m3 = 0, .magnesium_ground_mol_per_m3 = 0, .sodium_natural_mol_per_m3 = 0, .sodium_ground_mol_per_m3 = 0, .potassium_natural_mol_per_m3 = 0, .potassium_ground_mol_per_m3 = 0 },
    );
    try state.state_updateCell(0, .{
        .aqueous = filledStruct(aqueous_network.Transformations, 0),
        .non_band_phosphate = filledStruct(phosphate_network.Transformations, 0),
        .band_phosphate = filledStruct(phosphate_network.Transformations, 0),
        .non_band_phosphate_water_fraction = 0.8,
        .band_phosphate_water_fraction = 0.2,
        .cation_adsorption_mol_per_megagram = filledStruct(cation_exchange.Cations, 0),
        .cation_exchange_water_ratios = .{ .shared_megagrams_per_m3 = 1, .ammonium_non_band_megagrams_per_m3 = 1, .ammonium_band_megagrams_per_m3 = 1 },
        .geochemistry = changes,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 9.92), state.aqueous[0].aluminum, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.1), state.geochemistry_solids[0].gibbsite_solid_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.98), state.geochemistry_solids[0].aluminum_natural_silicate_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 10.015), state.aqueous[0].hydrogen_silicate, 1e-15);
}

test "sub-ulp mineral and weathering extents cannot create aqueous inventory" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = filledStruct(aqueous_network.State, 1);

    // Each requested solid change is smaller than one ulp of its storage
    // owner. The pre-fix update left every solid unchanged but still
    // published the ideal Al/Fe/Ca/Mg/Na/K and HSi aqueous extents.
    state.geochemistry_solids[0] =
        filledStruct(geochemistry.SolidState, 0x1p50);
    const aqueous_before = state.aqueous[0];
    const solids_before = state.geochemistry_solids[0];
    const changes = try geochemistry.assemble(
        .{
            .gibbsite_precipitation_mol_per_m3 = 0.01,
            .iron_hydroxide_precipitation_mol_per_m3 = 0.02,
            .calcite_precipitation_mol_per_m3 = 0.03,
            .gypsum_precipitation_mol_per_m3 = 0.04,
        },
        .{
            .aluminum_natural_mol_per_m3 = 1.0e-8,
            .aluminum_ground_mol_per_m3 = 0,
            .iron_natural_mol_per_m3 = 1.0e-8,
            .iron_ground_mol_per_m3 = 0,
            .calcium_natural_mol_per_m3 = 1.0e-8,
            .calcium_ground_mol_per_m3 = 0,
            .magnesium_natural_mol_per_m3 = 1.0e-8,
            .magnesium_ground_mol_per_m3 = 0,
            .sodium_natural_mol_per_m3 = 1.0e-8,
            .sodium_ground_mol_per_m3 = 0,
            .potassium_natural_mol_per_m3 = 1.0e-8,
            .potassium_ground_mol_per_m3 = 0,
        },
    );
    try state.state_updateCell(0, .{
        .aqueous = filledStruct(aqueous_network.Transformations, 0),
        .non_band_phosphate = filledStruct(phosphate_network.Transformations, 0),
        .band_phosphate = filledStruct(phosphate_network.Transformations, 0),
        .non_band_phosphate_water_fraction = 0.5,
        .band_phosphate_water_fraction = 0.5,
        .cation_adsorption_mol_per_megagram = filledStruct(cation_exchange.Cations, 0),
        .cation_exchange_water_ratios = .{
            .shared_megagrams_per_m3 = 1,
            .ammonium_non_band_megagrams_per_m3 = 1,
            .ammonium_band_megagrams_per_m3 = 1,
        },
        .geochemistry = changes,
    });
    try std.testing.expectEqualDeep(solids_before, state.geochemistry_solids[0]);
    try std.testing.expectEqualDeep(aqueous_before, state.aqueous[0]);
}

test "runtime chemistry state feeds activity coefficients directly" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0].calcium = 10;
    state.aqueous[0].chloride = 20;
    const result = try state.activityCoefficients(0, .{ .ammonium_non_band = 0.8, .ammonium_band = 0.2, .nitrate_non_band = 0.6, .nitrate_band = 0.4, .phosphate_non_band = 0.7, .phosphate_band = 0.3 });
    try std.testing.expect(result.ionic_strength_mol_per_l > 0);
    try std.testing.expect(result.divalent_activity_coefficient < result.monovalent_activity_coefficient);
}

test "runtime state evaluates named aqueous reactions into conservative changes" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = filledStruct(aqueous_network.State, 1);
    state.aqueous[0].calcium = 2;
    const fractions: charge_classification.ZoneFractions = .{ .ammonium_non_band = 0.8, .ammonium_band = 0.2, .nitrate_non_band = 0.6, .nitrate_band = 0.4, .phosphate_non_band = 0.7, .phosphate_band = 0.3 };
    const constants = filledStruct(aqueous_reaction_rates.EquilibriumConstants, 1);
    const kinetics: aqueous_reaction_rates.Kinetics = .{ .ammonium_substrate_limit_fraction = 0.2, .general_substrate_limit_fraction = 0.2, .maximum_fast_association_mol_per_m3_step = 0.1, .maximum_slow_association_mol_per_m3_step = 0.1 };
    const transformations = try state.evaluateAqueousTransformations(0, fractions, constants, kinetics);
    const coefficients = try state.activityCoefficients(0, fractions);
    const injected = try state.evaluateAqueousTransformationsWithCoefficients(0, fractions, coefficients, constants, kinetics);
    try std.testing.expectEqualDeep(transformations, injected);
    try std.testing.expectApproxEqAbs(@as(f64, 0), transformations.calcium + transformations.calcium_hydroxide + transformations.calcium_carbonate + transformations.calcium_bicarbonate + transformations.calcium_sulfate, 1e-14);
}

test "runtime aqueous evaluation honors independent ammonium water zones" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = filledStruct(aqueous_network.State, 1);
    var constants = filledStruct(aqueous_reaction_rates.EquilibriumConstants, 1);
    constants.ammonium = 0.5;
    const transformations = try state.evaluateAqueousTransformations(
        0,
        .{
            .ammonium_non_band = 0,
            .ammonium_band = 1,
            .nitrate_non_band = 1,
            .nitrate_band = 0,
            .phosphate_non_band = 1,
            .phosphate_band = 0,
        },
        constants,
        .{
            .ammonium_substrate_limit_fraction = 0.2,
            .general_substrate_limit_fraction = 0.2,
            .maximum_fast_association_mol_per_m3_step = 0.1,
            .maximum_slow_association_mol_per_m3_step = 0.1,
        },
    );
    try std.testing.expectEqual(@as(f64, 0), transformations.ammonium_non_band);
    try std.testing.expect(transformations.ammonium_band > 0);
}

test "runtime state evaluates both phosphate zones with shared activities" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = filledStruct(aqueous_network.State, 1);
    state.non_band_phosphate[0] = filledStruct(phosphate_network.State, 1);
    state.band_phosphate[0] = filledStruct(phosphate_network.State, 1);
    const fractions: charge_classification.ZoneFractions = .{ .ammonium_non_band = 0.8, .ammonium_band = 0.2, .nitrate_non_band = 0.6, .nitrate_band = 0.4, .phosphate_non_band = 0.7, .phosphate_band = 0.3 };
    const constants = filledStruct(phosphate_reaction_rates.EquilibriumConstants, 1);
    const surface: phosphate_exchange.Parameters = .{ .protonated_site_equilibrium_constant = 1, .hydroxyl_site_equilibrium_constant = 1, .h2po4_exchange_equilibrium_constant = 1, .hpo4_exchange_equilibrium_constant = 1, .water_activity_product_mol2_per_m6 = 1, .h2po4_dissociation_constant = 1, .maximum_exchange_mol_per_megagram_step = 0.1, .substrate_limit_fraction = 0.2 };
    const kinetics: phosphate_reaction_rates.Kinetics = .{ .substrate_limit_fraction = 0.2, .maximum_pairing_mol_per_m3_step = 0.1 };
    const changes = try state.evaluatePhosphateTransformations(0, fractions, 1.2, 1.5, constants, surface, null, kinetics);
    const coefficients = try state.activityCoefficients(0, fractions);
    const injected = try state.evaluatePhosphateTransformationsWithCoefficients(0, fractions, coefficients, 1.2, 1.5, constants, surface, null, kinetics);
    try std.testing.expectEqualDeep(changes, injected);
    inline for (@typeInfo(phosphate_network.Transformations).@"struct".fields) |field| {
        try std.testing.expect(std.math.isFinite(@field(changes.non_band, field.name)));
        try std.testing.expect(std.math.isFinite(@field(changes.band, field.name)));
    }
}

test "runtime state evaluates shared mineral and weathering rates" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = filledStruct(aqueous_network.State, 1);
    state.geochemistry_solids[0] = filledStruct(geochemistry.SolidState, 1);
    const fractions: charge_classification.ZoneFractions = .{ .ammonium_non_band = 0.8, .ammonium_band = 0.2, .nitrate_non_band = 0.6, .nitrate_band = 0.4, .phosphate_non_band = 0.7, .phosphate_band = 0.3 };
    const products = filledStruct(geochemistry_reaction_rates.SolubilityProducts, 1);
    const kinetics: geochemistry_reaction_rates.Kinetics = .{ .general_substrate_limit_fraction = 0.2, .hydrogen_coupled_substrate_limit_fraction = 0.2, .maximum_hydroxide_mineral_mol_per_m3_step = 0.1, .maximum_general_mineral_mol_per_m3_step = 0.1, .calcite_hydroxide_inhibition_constant_mol_per_m3 = 1, .maximum_natural_weathering_mol_per_m3_step = 0.01, .maximum_ground_weathering_mol_per_m3_step = 0.02 };
    const changes = try state.evaluateGeochemistryTransformations(0, fractions, products, kinetics);
    const coefficients = try state.activityCoefficients(0, fractions);
    const injected = try state.evaluateGeochemistryTransformationsWithCoefficients(0, coefficients, products, kinetics);
    try std.testing.expectEqualDeep(changes, injected);
    try std.testing.expectApproxEqAbs(@as(f64, 0), changes.dissolved_calcium_mol_per_m3 + changes.calcite_solid_mol_per_m3 + changes.gypsum_solid_mol_per_m3 + changes.calcium_natural_silicate_mol_per_m3 + changes.calcium_ground_silicate_mol_per_m3, 1e-14);
}

test "single cell evaluation assembles every active SOLUTE reaction family" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = filledStruct(aqueous_network.State, 1);
    state.non_band_phosphate[0] = filledStruct(phosphate_network.State, 1);
    state.band_phosphate[0] = filledStruct(phosphate_network.State, 1);
    state.cation_exchange_mol_per_megagram[0] = filledStruct(cation_exchange.Cations, 1);
    state.geochemistry_solids[0] = filledStruct(geochemistry.SolidState, 1);
    const transformations = try state.evaluateCell(0, .{
        .fractions = .{ .ammonium_non_band = 0.8, .ammonium_band = 0.2, .nitrate_non_band = 0.6, .nitrate_band = 0.4, .phosphate_non_band = 0.7, .phosphate_band = 0.3 },
        .non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 1.2,
        .band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 1.5,
        .cation_exchange_capacity_mol_charge_per_megagram = 10,
        .cation_exchange_water_ratios = .{ .shared_megagrams_per_m3 = 1.4, .ammonium_non_band_megagrams_per_m3 = 1.1, .ammonium_band_megagrams_per_m3 = 1.8 },
        .total_carboxyl_sites_mol_per_megagram = 0,
        .carboxyl_exchange_parameters = .{ .dissociation_constant_mol_per_m3 = 0.01, .maximum_exchange_mol_per_m3_per_iteration = 0.01, .substrate_limit_fraction_per_iteration = 0.2 },
        .aqueous_constants = filledStruct(aqueous_reaction_rates.EquilibriumConstants, 1),
        .aqueous_kinetics = .{ .ammonium_substrate_limit_fraction = 0.2, .general_substrate_limit_fraction = 0.2, .maximum_fast_association_mol_per_m3_step = 0.01, .maximum_slow_association_mol_per_m3_step = 0.01 },
        .phosphate_constants = filledStruct(phosphate_reaction_rates.EquilibriumConstants, 1),
        .phosphate_surface = .{ .protonated_site_equilibrium_constant = 1, .hydroxyl_site_equilibrium_constant = 1, .h2po4_exchange_equilibrium_constant = 1, .hpo4_exchange_equilibrium_constant = 1, .water_activity_product_mol2_per_m6 = 1, .h2po4_dissociation_constant = 1, .maximum_exchange_mol_per_megagram_step = 0.01, .substrate_limit_fraction = 0.2 },
        .phosphate_minerals = null,
        .phosphate_kinetics = .{ .substrate_limit_fraction = 0.2, .maximum_pairing_mol_per_m3_step = 0.01 },
        .cation_exchange_parameters = .{ .selectivity = .{ .calcium_ammonium = 1, .calcium_hydrogen = 1, .calcium_aluminum_and_iron = 1, .calcium_magnesium = 1, .calcium_sodium = 1, .calcium_potassium = 1 }, .substrate_limit_fraction = 0.2, .maximum_adsorption_mol_charge_per_m3_step = 0.01 },
        .geochemistry_products = filledStruct(geochemistry_reaction_rates.SolubilityProducts, 1),
        .geochemistry_kinetics = .{ .general_substrate_limit_fraction = 0.2, .hydrogen_coupled_substrate_limit_fraction = 0.2, .maximum_hydroxide_mineral_mol_per_m3_step = 0.01, .maximum_general_mineral_mol_per_m3_step = 0.01, .calcite_hydroxide_inhibition_constant_mol_per_m3 = 1, .maximum_natural_weathering_mol_per_m3_step = 0.001, .maximum_ground_weathering_mol_per_m3_step = 0.002 },
        .water_activity_product_mol2_per_m6 = 1,
        .negligible_water_ion_concentration_mol_per_m3 = 1e-32,
    });
    inline for (@typeInfo(aqueous_network.Transformations).@"struct".fields) |field| try std.testing.expect(std.math.isFinite(@field(transformations.aqueous, field.name)));
    inline for (@typeInfo(cation_exchange.Cations).@"struct".fields) |field| try std.testing.expect(std.math.isFinite(@field(transformations.cation_adsorption_mol_per_megagram, field.name)));
}

test "source-order water change includes carbon dioxide hydration" {
    var transformations = std.mem.zeroes(CellTransformations);
    transformations.aqueous.carbon_dioxide = 0.2;
    transformations.non_band_phosphate.water_mol_per_m3 = 0.3;
    transformations.band_phosphate.water_mol_per_m3 = 0.4;
    transformations.non_band_phosphate_water_fraction = 0.75;
    transformations.band_phosphate_water_fraction = 0.25;
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.525),
        try State.sourceOrderWaterChangeMolPerM3(transformations),
        1e-15,
    );

    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.water_mol_per_m3[0] = 10;
    transformations.cation_exchange_water_ratios = .{
        .shared_megagrams_per_m3 = 1,
        .ammonium_non_band_megagrams_per_m3 = 1,
        .ammonium_band_megagrams_per_m3 = 1,
    };
    try state.state_updateCell(0, transformations);
    try std.testing.expectApproxEqAbs(
        @as(f64, 10.525),
        state.water_mol_per_m3[0],
        1e-15,
    );
}

test "source phosphate surface circulation closes net water after dependent projection" {
    // A positive capped-source stationary witness, not a fitted isotherm:
    // RXO2 = RXH2 = -RYH2, RXO1 = RXH1 = 0. Individual detailed
    // balance is impossible here with source SXOH2 = 0.45, but all five
    // site balances and the aqueous H-minus-OH balance vanish.
    for ([_]f64{ 1, 0.8 }) |g1| {
        const g2 = g1 * g1;
        const hydrogen_activity: f64 = 1e-3;
        const hydroxide_activity: f64 = 1e-5;
        const kw: f64 = 1e-8;
        const hydrogen = hydrogen_activity / g1;
        const hydroxyl_site = 1 / (1.5 * g1);
        const circulation = 0.5 * hydrogen;
        const parameters: phosphate_exchange.Parameters = .{
            .protonated_site_equilibrium_constant = 0.45,
            .hydroxyl_site_equilibrium_constant = 1e-3,
            .h2po4_exchange_equilibrium_constant = 5e5,
            .hpo4_exchange_equilibrium_constant = 5e5,
            .water_activity_product_mol2_per_m6 = kw,
            .h2po4_dissociation_constant = 1e-3,
            .maximum_exchange_mol_per_megagram_step = 1,
            .substrate_limit_fraction = 0.5,
        };
        const inputs: phosphate_exchange.Inputs = .{
            .hydrogen_concentration_mol_per_m3 = hydrogen,
            .hydrogen_activity_mol_per_m3 = hydrogen_activity,
            .hydroxide_activity_mol_per_m3 = hydroxide_activity,
            .h2po4_concentration_mol_p_per_m3 = 0.1,
            .h2po4_activity_mol_p_per_m3 = 0.1 * g1,
            .hpo4_concentration_mol_p_per_m3 = 0.2,
            .hpo4_activity_mol_p_per_m3 = 0.2 * g2,
            .deprotonated_site_mol_per_megagram = hydroxyl_site,
            .hydroxyl_site_mol_per_megagram = hydroxyl_site,
            .protonated_site_mol_per_megagram = hydrogen,
            .adsorbed_h2po4_mol_p_per_megagram = (0.1 + circulation) * g1 * hydroxyl_site / (5e5 * hydroxide_activity),
            .adsorbed_hpo4_mol_p_per_megagram = 0.2 * g2 * hydroxyl_site / (5e5 * kw / 1e-3),
            .monovalent_activity_coefficient = g1,
            .divalent_activity_coefficient = g2,
        };
        var state = try State.init(std.testing.allocator, 1);
        defer state.deinit();
        state.aqueous[0].hydrogen = hydrogen;
        state.aqueous[0].hydroxide = hydroxide_activity / g1;
        state.water_mol_per_m3[0] = 55500;
        state.water_equilibrium_balance_mol[0] = 7;
        var changes = std.mem.zeroes(CellTransformations);
        changes.non_band_phosphate_water_fraction = 0.3;
        changes.band_phosphate_water_fraction = 0.7;
        changes.cation_exchange_water_ratios = .{
            .shared_megagrams_per_m3 = 1,
            .ammonium_non_band_megagrams_per_m3 = 1,
            .ammonium_band_megagrams_per_m3 = 1,
        };
        for ([_]*phosphate_network.State{ &state.non_band_phosphate[0], &state.band_phosphate[0] }, 0..) |zone, index| {
            zone.dissolved_h2po4_mol_p_per_m3 = inputs.h2po4_concentration_mol_p_per_m3;
            zone.dissolved_hpo4_mol_p_per_m3 = inputs.hpo4_concentration_mol_p_per_m3;
            inline for (.{ "deprotonated_site_mol_per_megagram", "hydroxyl_site_mol_per_megagram", "protonated_site_mol_per_megagram", "adsorbed_h2po4_mol_p_per_megagram", "adsorbed_hpo4_mol_p_per_megagram" }) |field| {
                @field(zone.*, field) = @field(inputs, field);
            }
            const flux = if (index == 0) try phosphate_exchange.calculate(inputs, parameters) else try phosphate_exchange.calculateBandSourceOrder(inputs, parameters);
            try std.testing.expectApproxEqAbs(circulation, flux.protonated_to_hydroxyl_site_mol_per_megagram, 1e-16);
            try std.testing.expectApproxEqAbs(circulation, flux.h2po4_with_protonated_site_mol_p_per_megagram, 1e-16);
            try std.testing.expectApproxEqAbs(-circulation, flux.h2po4_with_hydroxyl_site_mol_p_per_megagram, 1e-16);
            const assembled = try phosphate_network.assemble(.{
                .surface = flux,
                .minerals = std.mem.zeroes(phosphate_network.MineralFluxes),
                .aqueous = std.mem.zeroes(phosphate_network.DissociationAndPairingFluxes),
                .soil_mass_per_water_volume_megagrams_per_m3 = 3,
            });
            if (index == 0) changes.non_band_phosphate = assembled else changes.band_phosphate = assembled;
        }
        var before: [State.packedComponentCount()]f64 = undefined;
        var after: [State.packedComponentCount()]f64 = undefined;
        var defect: [State.packedComponentCount()]f64 = undefined;
        try state.packCell(0, &before);
        const audit = try state.undampedReactionBalanceWithWater(0, changes, g1, kw, &defect);
        const roundoff = 32 * std.math.floatEps(f64);
        // Every species closes, including both site totals and dissolved P.
        // Only the separate source solvent owner has a nonzero increment.
        for (defect[0 .. defect.len - 1]) |value| try std.testing.expectApproxEqAbs(@as(f64, 0), value, roundoff);
        try std.testing.expectApproxEqAbs(3 * circulation, audit.source_solvent_change_mol_per_m3, roundoff);
        try std.testing.expectApproxEqAbs(-3 * circulation, audit.projected_water_pair_extent_mol_per_m3, roundoff);
        try std.testing.expectApproxEqAbs(@as(f64, 0), audit.net_water_change_mol_per_m3, roundoff);
        try std.testing.expectEqual(audit.source_solvent_change_mol_per_m3, defect[defect.len - 1]);
        try state.packCell(0, &after);
        try std.testing.expectEqualSlices(f64, &before, &after);
        try std.testing.expectEqual(@as(f64, 7), state.water_equilibrium_balance_mol[0]);
    }
}

test "undamped chemical balance retains active reactions beside a blocked donor" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0].ammonium_non_band = 2;
    state.aqueous[0].hydrogen = 1;
    state.aqueous[0].hydroxide = 1;
    state.water_mol_per_m3[0] = 10;
    var before: [State.packedComponentCount()]f64 = undefined;
    var after: [State.packedComponentCount()]f64 = undefined;
    var residual: [State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &before);
    var changes = std.mem.zeroes(CellTransformations);
    changes.aqueous.ammonium_non_band = -0.25;
    changes.aqueous.ammonia_non_band = 0.25;
    changes.aqueous.hydrogen = 0.25;
    changes.aqueous.calcium = -1;
    changes.cation_exchange_water_ratios = .{
        .shared_megagrams_per_m3 = 1,
        .ammonium_non_band_megagrams_per_m3 = 1,
        .ammonium_band_megagrams_per_m3 = 1,
    };
    try state.undampedReactionBalance(0, changes, 1, 1, &residual);
    try std.testing.expectEqual(@as(f64, -0.25), residual[0]);
    try std.testing.expectEqual(@as(f64, 0.25), residual[1]);
    try std.testing.expectEqual(@as(f64, -1), residual[std.meta.fieldIndex(aqueous_network.State, "calcium").?]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), residual[4] - residual[5], 1e-15);
    try state.packCell(0, &after);
    try std.testing.expectEqualSlices(f64, &before, &after);
    try std.testing.expectError(error.NegativeAqueousState, state.state_updateCellProjectedWater(0, changes, 1, 1));
    try state.packCell(0, &after);
    try std.testing.expectEqualSlices(f64, &before, &after);

    state.aqueous[0].calcium = 2;
    try state.packCell(0, &before);
    try state.undampedReactionBalance(0, changes, 1, 1, &residual);
    _ = try state.state_updateCellProjectedWater(0, changes, 1, 1);
    try state.packCell(0, &after);
    for (before, after, residual) |initial, final, defect|
        try std.testing.expectApproxEqAbs(defect, final - initial, 1e-15);
}
