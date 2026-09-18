//! Local coupled surface/mineral candidate with conserved element totals.
const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const local = @import("reaction_surface_charge.zig");
const phosphate = @import("phosphate_network.zig");
const numerics = @import("../../core/numerics.zig");
const span = @import("conservative_reaction_span.zig");
const ledger = @import("reaction_solve.zig");
const charge_ledger = @import("reaction_charge.zig");
const exchange = @import("cation_exchange.zig");
const dimension = 26; // Surface, metals, solids, exchange partners, carbonate and sulfate.
/// Private iteration coordinates, never an accepted native chemistry state.
/// The caller owns their lifetime within one outer equilibrium solve.
pub const CandidateSeed = [dimension]f64;
/// Permit one ordinary continuation opportunity per outer equilibrium solve.
/// A successful or failed later attempt cannot rearm that opportunity. The
/// separately bounded alternate-merit recovery keeps its existing call policy.
pub fn prepareOrdinarySeed(seed: *?CandidateSeed, consumed: *bool) void {
    if (seed.* == null) return;
    if (consumed.*) seed.* = null else consumed.* = true;
}
const partners = .{ "ammonium_non_band", "ammonium_band", "magnesium", "sodium", "potassium" };
// Product, metal, ligand, reactant valences, product charge, native axis, inventory.
const complexes = .{
    .{ "aluminum_sulfate", "aluminum", "sulfate", 3, 2, 1, 8, 0 },
    .{ "iron_sulfate", "iron", "sulfate", 3, 2, 1, 13, 1 },
    .{ "calcium_hydroxide", "calcium", "hydroxide", 2, 1, 1, 14, 2 },
    .{ "calcium_carbonate", "calcium", "carbonate", 2, 2, 0, 15, 2 },
    .{ "calcium_bicarbonate", "calcium", "bicarbonate", 2, 1, 1, 16, 2 },
    .{ "calcium_sulfate", "calcium", "sulfate", 2, 2, 0, 17, 2 },
    .{ "magnesium_hydroxide", "magnesium", "hydroxide", 2, 1, 1, 18, 3 },
    .{ "magnesium_carbonate", "magnesium", "carbonate", 2, 2, 0, 19, 3 },
    .{ "magnesium_bicarbonate", "magnesium", "bicarbonate", 2, 1, 1, 20, 3 },
    .{ "magnesium_sulfate", "magnesium", "sulfate", 2, 2, 0, 21, 3 },
    .{ "sodium_carbonate", "sodium", "carbonate", 1, 2, -1, 22, 4 },
    .{ "sodium_sulfate", "sodium", "sulfate", 1, 2, -1, 23, 4 },
    .{ "potassium_sulfate", "potassium", "sulfate", 1, 2, -1, 24, 5 },
};
const fields = .{ "aluminum_phosphate_solid_mol_per_m3", "iron_phosphate_solid_mol_per_m3", "dicalcium_phosphate_solid_mol_per_m3", "hydroxyapatite_solid_mol_per_m3", "monocalcium_phosphate_solid_mol_per_m3" };
const metal_index = [_]usize{ 0, 1, 2, 2, 2 };
const metal_n = [_]f64{ 1, 1, 1, 5, 1 };
const phosphorus_n = [_]f64{ 1, 1, 1, 3, 2 };
const charge_n = [_]f64{ 3, 3, 2 };
const hydroxide_fields = .{
    .{ "aluminum_hydroxide_1", "aluminum_hydroxide_2", "aluminum_hydroxide_3", "aluminum_hydroxide_4" },
    .{ "iron_hydroxide_1", "iron_hydroxide_2", "iron_hydroxide_3", "iron_hydroxide_4" },
};
fn pairP(z: phosphate.State) f64 {
    return z.iron_hpo4_pair_mol_per_m3 + z.iron_h2po4_pair_mol_per_m3 + z.calcium_hpo4_pair_mol_per_m3 + z.calcium_h2po4_pair_mol_per_m3 + z.magnesium_hpo4_pair_mol_per_m3;
}
fn pairCharge(z: phosphate.State) f64 {
    return z.iron_hpo4_pair_mol_per_m3 + 2 * z.iron_h2po4_pair_mol_per_m3 + z.calcium_h2po4_pair_mol_per_m3;
}
fn restoreTrace(value: *f64, expected: f64, inventory: f64) !void {
    if (!std.math.isFinite(expected) or expected < 0 or @abs(value.* - expected) > 128 * std.math.floatEps(f64) * inventory)
        return error.InvalidSurfaceMineralReconstruction;
    value.* = expected;
}
const Evaluation = struct {
    surface: local.Evaluation,
    aqueous: @import("aqueous_network.zig").State,
    exchange: exchange.Cations,
    residual: [dimension]f64,
    solids: [10]f64,
    norm: f64,
    converged: bool,
};

/// Retained pieces of one complete `Context.evaluate` that a single mineral
/// solid coordinate `x[9..19]` provably cannot change.
///
/// A mineral coordinate enters the residual through exactly three additive
/// accumulations -- `counted_metals[metal_index]`, `counted_phosphorus[zone]`
/// and its own `result.solids[phase]` -- plus its own complementarity row.
/// It never touches `base.invariant`, `base.aqueous`, the Gapon exchange
/// solve, the hydroxide chains, the ion-pair complexes, the carbonate/sulfate
/// speciation, `result.surface` (which is a function of `x[0..6]` and the
/// already-adjusted invariant only), the ionic-strength row, or any partner
/// row. The finite-difference Jacobian therefore does not need to repeat that
/// work 20 times per local Newton iteration.
///
/// Every retained term is stored per contributing phase/zone so the perturbed
/// accumulation can be replayed in the ORIGINAL summation order. That makes
/// the shortcut bit-for-bit identical to the full evaluation, not merely
/// close: binary64 addition is not associative, so replaying a different
/// order would perturb the Jacobian and thus the iterate sequence.
///
/// This is a strictly larger transformation than the inactive-mineral
/// Jacobian-column trial that was rejected on 2026-09-09 (combined median
/// runtime ratio 0.99035, within noise): that one skipped only the columns
/// whose mineral phase is DISABLED, of which this deck has few. This one
/// short-circuits all ten mineral columns whether enabled or not.
const MineralColumnCache = struct {
    residual: [dimension]f64 = @splat(0),
    /// `counted_metals` after free metals, exchange, hydroxide chains and
    /// complexes, i.e. immediately before the mineral loop.
    metals_before_minerals: [3]f64 = @splat(0),
    mineral_metal_term: [10]f64 = @splat(0),
    /// Ion-pair contributions added to `counted_metals` after the minerals.
    metal_pair_term: [2][3]f64 = @splat(@splat(0)),
    mineral_phosphorus_term: [10]f64 = @splat(0),
    phosphorus_pair_term: [2]f64 = @splat(0),
    phosphorus_free_term: [2]f64 = @splat(0),
    pair_zone_active: [2]bool = @splat(false),
    phosphorus_row_active: [2]bool = @splat(false),
    affinity: [10]f64 = @splat(0),
};

/// Set to `true` only for an equivalence-verification build: every mineral
/// Jacobian column is then computed BOTH ways and any bit difference panics.
const verify_mineral_column_shortcut = false;
const Context = struct {
    euclidean_merit: bool = false,
    base: local.Context,
    total_metals: [3]f64,
    initial_metals: [3]f64,
    initial_solids: [10]f64,
    scales: [10]f64,
    enabled: [10]bool,
    products: [5]f64,
    total_magnesium: f64,
    initial_exchange: exchange.Cations,
    exchange_total_charge: f64,
    partner_totals: [5]f64 = @splat(0),
    partner_densities: [5]f64,
    partner_fractions: [5]f64,
    carbon_total: f64 = 0,
    sulfur_total: f64 = 0,

    fn evaluate(self: Context, x: [dimension]f64) !Evaluation {
        return self.evaluateCaching(x, null);
    }

    fn evaluateCaching(self: Context, x: [dimension]f64, cache: ?*MineralColumnCache) !Evaluation {
        var profile_scope = @import("reaction_diagnostic_control.zig").beginPhase(.local_mineral_target);
        defer profile_scope.end();
        if (cache) |retained| retained.* = .{};
        var result: Evaluation = .{ .surface = undefined, .aqueous = undefined, .exchange = undefined, .residual = @splat(0), .solids = self.initial_solids, .norm = 0, .converged = true };
        var free_metals: [3]f64 = undefined;
        var counted_metals: [3]f64 = undefined;
        var counted_phosphorus: [2]f64 = @splat(0);
        var partner_complexes: [5]f64 = @splat(0);
        var base = self.base;
        for (0..3) |m| {
            free_metals[m] = if (self.total_metals[m] > 0) self.total_metals[m] * @exp(x[6 + m]) else 0;
            if (!std.math.isFinite(free_metals[m])) return error.InvalidSurfaceMineralTrial;
            counted_metals[m] = free_metals[m];
            base.invariant -= charge_n[m] * (free_metals[m] - self.initial_metals[m]);
        }
        base.aqueous.aluminum = free_metals[0];
        base.aqueous.iron = free_metals[1];
        base.aqueous.calcium = free_metals[2];
        const coefficients = try local.coefficients(x[5]);
        const g1 = coefficients.monovalent_activity_coefficient;
        const g2 = coefficients.divalent_activity_coefficient;
        const g3 = coefficients.trivalent_activity_coefficient;
        const h = @exp(x[0]);
        base.aqueous.hydrogen = h;
        base.aqueous.hydroxide = base.parameters.water_activity_product_mol2_per_m6 / h / (g1 * g1);
        base.aqueous.carbonate = if (self.carbon_total > 0) self.carbon_total * @exp(x[24]) else 0;
        base.aqueous.bicarbonate = base.aqueous.carbonate * g2 * h / base.parameters.aqueous_constants.bicarbonate;
        base.aqueous.carbon_dioxide = base.aqueous.bicarbonate * h * g1 * g1 / base.parameters.aqueous_constants.carbon_dioxide;
        base.aqueous.sulfate = if (self.sulfur_total > 0) self.sulfur_total * @exp(x[25]) else 0;
        base.invariant += 2 * (base.aqueous.carbonate - self.base.aqueous.carbonate) + base.aqueous.bicarbonate - self.base.aqueous.bicarbonate + 2 * (base.aqueous.sulfate - self.base.aqueous.sulfate);
        inline for (partners, 0..) |field, i| {
            if (self.partner_fractions[i] > 0) @field(base.aqueous, field) = if (self.partner_totals[i] > 0) self.partner_totals[i] * @exp(x[19 + i]) else 0;
        }
        inline for (.{ "ammonia_non_band", "ammonia_band" }, 0..) |field, i| {
            if (self.partner_fractions[i] > 0) @field(base.aqueous, field) = @field(base.aqueous, partners[i]) * base.parameters.aqueous_constants.ammonium / h;
        }
        var exchange_aqueous: exchange.Cations = undefined;
        var exchange_activities: exchange.Cations = undefined;
        inline for (std.meta.fields(exchange.Cations)) |field| {
            @field(exchange_aqueous, field.name) = @field(base.aqueous, field.name);
            const valence: f64 = if (comptime std.mem.eql(u8, field.name, "aluminum") or std.mem.eql(u8, field.name, "iron")) 3 else if (comptime std.mem.eql(u8, field.name, "calcium") or std.mem.eql(u8, field.name, "magnesium")) 2 else 1;
            @field(exchange_activities, field.name) = @field(exchange_aqueous, field.name) * (if (valence == 3) g3 else if (valence == 2) g2 else g1);
        }
        result.exchange = if (base.parameters.cation_exchange_capacity_mol_charge_per_megagram == 0)
            self.initial_exchange
        else
            try exchange.sourceOrderEquilibriumIonConcentration(.{
                .cation_exchange_capacity_mol_charge_per_megagram = base.parameters.cation_exchange_capacity_mol_charge_per_megagram,
                .aqueous_concentration_mol_per_m3 = exchange_aqueous,
                .aqueous_activity_mol_per_m3 = exchange_activities,
                .exchange_concentration_mol_per_megagram = self.initial_exchange,
                .ammonium_non_band_fraction = self.partner_fractions[0],
                .ammonium_band_fraction = self.partner_fractions[1],
                .soil_mass_per_water_volume_megagrams_per_m3 = base.parameters.cation_exchange_water_ratios.shared_megagrams_per_m3,
            }, base.parameters.cation_exchange_parameters.selectivity, .{ .minimum_activity_mol_per_m3 = base.parameters.negligible_water_ion_concentration_mol_per_m3 });
        // Source activity floors do not supply an absent element. Such a
        // coordinate has zero donor cap.
        inline for (.{ "aluminum", "iron", "calcium" }, 0..) |field, m| {
            if (self.total_metals[m] == 0) {
                @field(result.exchange, field) = 0;
            }
        }
        inline for (partners, 0..) |field, i| {
            if (self.partner_fractions[i] > 0 and self.partner_totals[i] == 0) {
                @field(result.exchange, field) = 0;
            }
        }
        // The projected source preserves stored exchange charge, which may
        // differ from configured CEC after carrier/geometry changes. Normalize
        // to that entry invariant; the remaining same-sign raw changes cancel
        // in the source charge projection even when the configured CEC differs.
        if (base.parameters.cation_exchange_capacity_mol_charge_per_megagram > 0) {
            const e = result.exchange;
            const charge = e.ammonium_non_band * self.partner_fractions[0] + e.ammonium_band * self.partner_fractions[1] + e.hydrogen + 3 * (e.aluminum + e.iron) + 2 * (e.calcium + e.magnesium) + e.sodium + e.potassium;
            if (charge <= 0) return error.InvalidSurfaceMineralTrial;
            const fraction = self.exchange_total_charge / charge;
            inline for (std.meta.fields(exchange.Cations)) |field| @field(result.exchange, field.name) *= fraction;
        }
        inline for (partners, 0..) |field, i| {
            if (self.partner_fractions[i] == 0) @field(result.exchange, field) = @field(self.initial_exchange, field);
            if (i != 2) base.invariant -= self.partner_fractions[i] * (@field(base.aqueous, field) - @field(self.base.aqueous, field));
        }
        inline for (std.meta.fields(exchange.Cations)) |field| {
            const valence: f64 = if (comptime std.mem.eql(u8, field.name, "aluminum") or std.mem.eql(u8, field.name, "iron")) 3 else if (comptime std.mem.eql(u8, field.name, "calcium") or std.mem.eql(u8, field.name, "magnesium")) 2 else 1;
            const density = if (comptime std.mem.eql(u8, field.name, "ammonium_non_band")) self.partner_fractions[0] * self.partner_densities[0] else if (comptime std.mem.eql(u8, field.name, "ammonium_band")) self.partner_fractions[1] * self.partner_densities[1] else base.parameters.cation_exchange_water_ratios.shared_megagrams_per_m3;
            base.invariant -= valence * density * (@field(result.exchange, field.name) - @field(self.initial_exchange, field.name));
        }
        inline for (.{ "aluminum", "iron", "calcium" }, 0..) |field, m| counted_metals[m] += base.parameters.cation_exchange_water_ratios.shared_megagrams_per_m3 * @field(result.exchange, field);
        const oh_activity = base.parameters.water_activity_product_mol2_per_m6 / @exp(x[0]) / g1;
        const chain_coefficients = [_]f64{ g3, g2, g1, 1, g1 };
        inline for (hydroxide_fields, 0..) |chain, m| {
            var previous = free_metals[m];
            inline for (chain, 0..) |field, i| {
                const concentration = previous * chain_coefficients[i] * oh_activity / (@field(base.parameters.aqueous_constants, field) * chain_coefficients[i + 1]);
                @field(base.aqueous, field) = concentration;
                counted_metals[m] += concentration;
                base.invariant -= (2 - @as(f64, @floatFromInt(i))) * (concentration - @field(self.base.aqueous, field));
                previous = concentration;
            }
        }
        const gamma = [_]f64{ 1, g1, g2, g3 };
        var carbon = base.aqueous.carbonate + base.aqueous.bicarbonate + base.aqueous.carbon_dioxide;
        var sulfur = base.aqueous.sulfate;
        inline for (complexes) |c| {
            const amount = @field(base.aqueous, c[1]) * @field(base.aqueous, c[2]) * gamma[c[3]] * gamma[c[4]] / (gamma[@abs(c[5])] * @field(base.parameters.aqueous_constants, c[0]));
            @field(base.aqueous, c[0]) = amount;
            base.invariant -= c[5] * (amount - @field(self.base.aqueous, c[0]));
            if (c[7] < 3) counted_metals[c[7]] += amount else partner_complexes[c[7] - 1] += amount;
            if (comptime std.mem.eql(u8, c[2], "sulfate")) sulfur += amount;
            if (comptime std.mem.eql(u8, c[2], "carbonate") or std.mem.eql(u8, c[2], "bicarbonate")) carbon += amount;
        }
        result.residual[24] = if (self.carbon_total > 0) @log(carbon / self.carbon_total) else x[24];
        result.residual[25] = if (self.sulfur_total > 0) @log(sulfur / self.sulfur_total) else x[25];
        if (cache) |retained| retained.metals_before_minerals = counted_metals;
        for (0..10) |phase| {
            if (!self.enabled[phase]) continue;
            if (x[9 + phase] < 0) return error.InvalidSurfaceMineralTrial;
            const zone = phase / 5;
            const mineral = phase % 5;
            result.solids[phase] = x[9 + phase] * self.scales[phase];
            const metal_term = result.solids[phase] * metal_n[mineral] * base.fractions[zone];
            const phosphorus_term = result.solids[phase] * phosphorus_n[mineral];
            counted_metals[metal_index[mineral]] += metal_term;
            counted_phosphorus[zone] += phosphorus_term;
            if (cache) |retained| {
                retained.mineral_metal_term[phase] = metal_term;
                retained.mineral_phosphorus_term[phase] = phosphorus_term;
            }
        }
        result.surface = try base.evaluateWithActivities(x[0..6].*, coefficients);
        @memcpy(result.residual[0..6], &result.surface.residual);
        const constants = base.parameters.phosphate_constants;
        var extra_charge = 2 * (base.aqueous.magnesium - self.base.aqueous.magnesium);
        for (&result.surface.zones, 0..) |*z, i| {
            if (base.fractions[i] == 0) continue;
            // Match the original pairing activity conventions, including
            // the source's Fe-pair coefficients. CaPO4 remains disabled.
            z.iron_hpo4_pair_mol_per_m3 = free_metals[1] * g3 * z.dissolved_hpo4_mol_p_per_m3 / constants.iron_hpo4;
            z.iron_h2po4_pair_mol_per_m3 = free_metals[1] * g3 * z.dissolved_h2po4_mol_p_per_m3 / constants.iron_h2po4;
            z.calcium_hpo4_pair_mol_per_m3 = free_metals[2] * g2 * g2 * z.dissolved_hpo4_mol_p_per_m3 / constants.calcium_hpo4;
            z.calcium_h2po4_pair_mol_per_m3 = free_metals[2] * g2 * z.dissolved_h2po4_mol_p_per_m3 / constants.calcium_h2po4;
            z.magnesium_hpo4_pair_mol_per_m3 = base.aqueous.magnesium * g2 * g2 * z.dissolved_hpo4_mol_p_per_m3 / constants.magnesium_hpo4;
            const iron_pair_term = base.fractions[i] * (z.iron_hpo4_pair_mol_per_m3 + z.iron_h2po4_pair_mol_per_m3);
            const calcium_pair_term = base.fractions[i] * (z.calcium_hpo4_pair_mol_per_m3 + z.calcium_h2po4_pair_mol_per_m3);
            const phosphorus_pair_term = pairP(z.*);
            counted_metals[1] += iron_pair_term;
            counted_metals[2] += calcium_pair_term;
            counted_phosphorus[i] += phosphorus_pair_term;
            if (cache) |retained| {
                retained.pair_zone_active[i] = true;
                retained.metal_pair_term[i][1] = iron_pair_term;
                retained.metal_pair_term[i][2] = calcium_pair_term;
                retained.phosphorus_pair_term[i] = phosphorus_pair_term;
            }
            extra_charge += base.fractions[i] * (pairCharge(z.*) - pairCharge(base.before[i]));
        }
        result.residual[0] += extra_charge / base.charge_scale;
        base.aqueous.hydrogen = @exp(x[0]);
        base.aqueous.hydroxide = base.parameters.water_activity_product_mol2_per_m6 / base.aqueous.hydrogen / (coefficients.monovalent_activity_coefficient * coefficients.monovalent_activity_coefficient);
        const actual = try @import("activity_coefficients.zig").calculate(try @import("charge_classification.zig").classify(base.aqueous, result.surface.zones[0], result.surface.zones[1], base.parameters.fractions), 1);
        result.residual[5] = @log(actual.ionic_strength_mol_per_l) - x[5];
        result.aqueous = base.aqueous;
        inline for (partners, 0..) |field, i| {
            var total = @field(base.aqueous, field) + self.partner_densities[i] * @field(result.exchange, field) + partner_complexes[i];
            if (i == 0) total += base.aqueous.ammonia_non_band;
            if (i == 1) total += base.aqueous.ammonia_band;
            if (i == 2) for (result.surface.zones, base.fractions) |z, f| {
                total += f * z.magnesium_hpo4_pair_mol_per_m3;
            };
            result.residual[19 + i] = if (self.partner_fractions[i] > 0 and self.partner_totals[i] > 0) @log(total / self.partner_totals[i]) else x[19 + i];
        }
        for (result.surface.zones, 0..) |zone, i| {
            if (base.fractions[i] == 0 or base.totals[i] == 0) continue;
            const free_term = local.freeP(zone) + base.densities[i] * (zone.adsorbed_hpo4_mol_p_per_megagram + zone.adsorbed_h2po4_mol_p_per_megagram);
            counted_phosphorus[i] += free_term;
            result.residual[1 + 2 * i] = @log(counted_phosphorus[i] / base.totals[i]);
            if (cache) |retained| {
                retained.phosphorus_row_active[i] = true;
                retained.phosphorus_free_term[i] = free_term;
            }
        }
        for (0..3) |m| result.residual[6 + m] = if (self.total_metals[m] > 0) @log(counted_metals[m] / self.total_metals[m]) else x[6 + m];
        const metal_activities = [_]f64{ free_metals[0] * coefficients.trivalent_activity_coefficient, free_metals[1] * coefficients.trivalent_activity_coefficient, free_metals[2] * coefficients.divalent_activity_coefficient };
        for (0..10) |phase| {
            if (!self.enabled[phase]) {
                result.residual[9 + phase] = x[9 + phase];
                continue;
            }
            const mineral = phase % 5;
            const z = result.surface.zones[phase / 5];
            const p_activity = switch (mineral) {
                0, 1, 3 => z.dissolved_po4_mol_p_per_m3 * coefficients.trivalent_activity_coefficient,
                2 => z.dissolved_hpo4_mol_p_per_m3 * coefficients.divalent_activity_coefficient,
                4 => z.dissolved_h2po4_mol_p_per_m3 * coefficients.monovalent_activity_coefficient,
                else => unreachable,
            };
            if (metal_activities[metal_index[mineral]] <= 0 or p_activity <= 0) return error.InvalidSurfaceMineralTrial;
            const log_metal = metal_n[mineral] * @log(metal_activities[metal_index[mineral]]);
            const log_p = phosphorus_n[mineral] * @log(p_activity);
            const log_oh = if (mineral == 3) @log(base.parameters.water_activity_product_mol2_per_m6) - x[0] - @log(coefficients.monovalent_activity_coefficient) else 0;
            const log_k = @log(self.products[mineral]);
            const affinity = log_metal + log_p + log_oh - log_k;
            if (cache) |retained| retained.affinity[phase] = affinity;
            const solid = x[9 + phase];
            const hypotenuse = std.math.hypot(affinity, solid);
            const r = if (affinity < 0) solid * (solid / (hypotenuse - affinity) - 1) else if (hypotenuse == 0) 0 else affinity * (1 + affinity / (hypotenuse + solid));
            result.residual[9 + phase] = r;
            const roundoff = 256 * std.math.floatEps(f64) * (1 + @abs(log_metal) + @abs(log_p) + @abs(log_oh) + @abs(log_k));
            if (@abs(r) > roundoff) result.converged = false;
        }
        for (result.residual, 0..) |r, i| {
            if (!std.math.isFinite(r)) return error.InvalidSurfaceMineralTrial;
            // The alternate merit is reserved for one terminal recovery.
            // Both searches retain the same componentwise closure gates.
            result.norm = if (self.euclidean_merit) std.math.hypot(result.norm, r) else @max(result.norm, @abs(r));
            if ((i < 9 or i >= 19) and @abs(r) > 16 * std.math.floatEps(f64)) result.converged = false;
        }
        if (cache) |retained| retained.residual = result.residual;
        return result;
    }

    /// Replays only the rows a single mineral solid coordinate can change,
    /// in the original accumulation order, from a retained complete
    /// evaluation of the unperturbed coordinate vector. Every guard the full
    /// evaluation applies to those rows is retained: a negative solid
    /// coordinate and a non-finite residual are still rejected, and the
    /// affinity/activity positivity checks were already decided by the
    /// retained evaluation because a mineral coordinate cannot alter them.
    fn mineralColumnResidual(
        self: Context,
        retained: *const MineralColumnCache,
        x: [dimension]f64,
        phase: usize,
        output: *[dimension]f64,
    ) !void {
        output.* = retained.residual;
        const coordinate = x[9 + phase];
        if (!std.math.isFinite(coordinate)) return error.InvalidSurfaceMineralTrial;
        if (!self.enabled[phase]) {
            output[9 + phase] = coordinate;
            return;
        }
        if (coordinate < 0) return error.InvalidSurfaceMineralTrial;
        const mineral = phase % 5;
        const zone = phase / 5;
        const solid = coordinate * self.scales[phase];
        var metal_terms = retained.mineral_metal_term;
        var phosphorus_terms = retained.mineral_phosphorus_term;
        metal_terms[phase] = solid * metal_n[mineral] * self.base.fractions[zone];
        phosphorus_terms[phase] = solid * phosphorus_n[mineral];

        const metal = metal_index[mineral];
        var counted_metal = retained.metals_before_minerals[metal];
        for (0..10) |other| {
            if (!self.enabled[other]) continue;
            if (metal_index[other % 5] != metal) continue;
            counted_metal += metal_terms[other];
        }
        if (metal == 1 or metal == 2) {
            for (0..2) |i| {
                if (!retained.pair_zone_active[i]) continue;
                counted_metal += retained.metal_pair_term[i][metal];
            }
        }
        if (self.total_metals[metal] > 0)
            output[6 + metal] = @log(counted_metal / self.total_metals[metal]);

        var counted_phosphorus: f64 = 0;
        for (0..10) |other| {
            if (!self.enabled[other]) continue;
            if (other / 5 != zone) continue;
            counted_phosphorus += phosphorus_terms[other];
        }
        if (retained.pair_zone_active[zone])
            counted_phosphorus += retained.phosphorus_pair_term[zone];
        if (retained.phosphorus_row_active[zone]) {
            counted_phosphorus += retained.phosphorus_free_term[zone];
            output[1 + 2 * zone] =
                @log(counted_phosphorus / self.base.totals[zone]);
        }

        const affinity = retained.affinity[phase];
        const hypotenuse = std.math.hypot(affinity, coordinate);
        output[9 + phase] = if (affinity < 0)
            coordinate * (coordinate / (hypotenuse - affinity) - 1)
        else if (hypotenuse == 0)
            0
        else
            affinity * (1 + affinity / (hypotenuse + coordinate));
        for (output.*) |value|
            if (!std.math.isFinite(value)) return error.InvalidSurfaceMineralTrial;
    }
};

pub fn candidate(scratch: *chemistry.State, current: []const f64, parameters: chemistry.ReactionParameters, maximum_iterations: u16, output: []f64) !u16 {
    return candidateWithMerit(scratch, current, parameters, maximum_iterations, output, false, null);
}

pub fn euclideanRecoveryCandidate(scratch: *chemistry.State, current: []const f64, parameters: chemistry.ReactionParameters, maximum_iterations: u16, output: []f64) !u16 {
    return candidateWithMerit(scratch, current, parameters, maximum_iterations, output, true, null);
}

pub fn candidateWithSeed(scratch: *chemistry.State, current: []const f64, parameters: chemistry.ReactionParameters, maximum_iterations: u16, output: []f64, seed: *?CandidateSeed) !u16 {
    return candidateWithMerit(scratch, current, parameters, maximum_iterations, output, false, seed);
}

pub fn euclideanRecoveryCandidateWithSeed(scratch: *chemistry.State, current: []const f64, parameters: chemistry.ReactionParameters, maximum_iterations: u16, output: []f64, seed: *?CandidateSeed) !u16 {
    return candidateWithMerit(scratch, current, parameters, maximum_iterations, output, true, seed);
}

fn candidateWithMerit(scratch: *chemistry.State, current: []const f64, parameters: chemistry.ReactionParameters, maximum_iterations: u16, output: []f64, euclidean_merit: bool, seed: ?*?CandidateSeed) !u16 {
    var profile_scope = @import("reaction_diagnostic_control.zig").beginPhase(.local_mineral_candidate);
    defer profile_scope.end();
    const capacity = parameters.cation_exchange_capacity_mol_charge_per_megagram;
    if (capacity < 0 or (capacity > 0 and (parameters.cation_exchange_parameters.substrate_limit_fraction <= 0 or parameters.cation_exchange_parameters.maximum_adsorption_mol_charge_per_m3_step <= 0)) or parameters.aqueous_kinetics.ammonium_substrate_limit_fraction <= 0 or parameters.aqueous_kinetics.maximum_fast_association_mol_per_m3_step <= 0) return error.UnsupportedSurfaceMineralInput;
    // Precipitation is the zero-carrier subspace of the same aqueous network.
    // Missing minerals disable every solid phase; they do not add a reservoir.
    const minerals = parameters.phosphate_minerals orelse std.mem.zeroes(@import("phosphate_reaction_rates.zig").MineralParameters);
    const constants = parameters.phosphate_constants;
    for ([_]f64{ constants.iron_hpo4, constants.iron_h2po4, constants.calcium_hpo4, constants.calcium_h2po4, constants.magnesium_hpo4 }) |k| if (k <= 0) return error.UnsupportedSurfaceMineralInput;
    var x: [dimension]f64 = @splat(0);
    const base = try local.initialize(scratch, current, parameters, x[0..6]);
    if (capacity == 0) {
        // Zero configured capacity is eligible only with exactly zero stored
        // exchange. Otherwise retaining it could hide a geometry inconsistency.
        inline for (std.meta.fields(exchange.Cations)) |field| {
            if (@field(scratch.cation_exchange_mol_per_megagram[0], field.name) != 0)
                return error.UnsupportedSurfaceMineralInput;
        }
    }
    // A kinetic step may consume H without resetting the water pair. Seed
    // speciation from the same charge-preserving reset used by evaluateAt;
    // raw near-zero H would imply an enormous artificial OH concentration.
    // Keep the original pools in `base` for native transfer reconstruction.
    const seed_water = try @import("water_equilibrium.zig").solve(.{
        .hydrogen_concentration_mol_per_m3 = base.aqueous.hydrogen,
        .hydroxide_concentration_mol_per_m3 = base.aqueous.hydroxide,
        .monovalent_activity_coefficient = (try local.coefficients(x[5])).monovalent_activity_coefficient,
        .water_activity_product_mol2_per_m6 = parameters.water_activity_product_mol2_per_m6,
        .negligible_concentration_mol_per_m3 = parameters.negligible_water_ion_concentration_mol_per_m3,
    });
    const seed_hydrogen = seed_water.hydrogen_concentration_mol_per_m3;
    x[0] = @log(seed_hydrogen);
    const entry_inventory = try ledger.acceptedStateInventory(scratch, 0, parameters);
    const entry_charge = try charge_ledger.inventory(scratch, 0, parameters);
    const initial_metals = [_]f64{ base.aqueous.aluminum, base.aqueous.iron, base.aqueous.calcium };
    const ratios = parameters.cation_exchange_water_ratios;
    var context: Context = .{ .base = base, .initial_metals = initial_metals, .total_metals = initial_metals, .total_magnesium = base.aqueous.magnesium, .initial_solids = undefined, .scales = @splat(1), .enabled = @splat(false), .products = .{ minerals.aluminum_phosphate_solubility_product, minerals.iron_phosphate_solubility_product, minerals.dicalcium_phosphate_solubility_product, minerals.hydroxyapatite_solubility_product, minerals.monocalcium_phosphate_solubility_product }, .initial_exchange = scratch.cation_exchange_mol_per_megagram[0], .exchange_total_charge = entry_inventory.cation_exchange_charge_mol_per_megagram, .partner_densities = .{ ratios.ammonium_non_band_megagrams_per_m3, ratios.ammonium_band_megagrams_per_m3, ratios.shared_megagrams_per_m3, ratios.shared_megagrams_per_m3, ratios.shared_megagrams_per_m3 }, .partner_fractions = .{ parameters.fractions.ammonium_non_band, parameters.fractions.ammonium_band, 1, 1, 1 } };
    inline for (.{ "aluminum", "iron", "calcium" }, 0..) |field, m| context.total_metals[m] += ratios.shared_megagrams_per_m3 * @field(context.initial_exchange, field);
    inline for (partners, 0..) |field, i| context.partner_totals[i] = @field(base.aqueous, field) + context.partner_densities[i] * @field(context.initial_exchange, field);
    context.partner_totals[0] += base.aqueous.ammonia_non_band;
    context.partner_totals[1] += base.aqueous.ammonia_band;
    context.carbon_total = base.aqueous.carbonate + base.aqueous.bicarbonate + base.aqueous.carbon_dioxide;
    context.sulfur_total = base.aqueous.sulfate;
    inline for (complexes) |c| {
        const amount = @field(base.aqueous, c[0]);
        if (c[7] < 3) context.total_metals[c[7]] += amount else context.partner_totals[c[7] - 1] += amount;
        if (comptime std.mem.eql(u8, c[2], "sulfate")) context.sulfur_total += amount;
        if (comptime std.mem.eql(u8, c[2], "carbonate") or std.mem.eql(u8, c[2], "bicarbonate")) context.carbon_total += amount;
    }
    context.base.charge_scale += 2 * (context.carbon_total + context.sulfur_total);
    context.base.charge_scale += ratios.shared_megagrams_per_m3 * parameters.cation_exchange_capacity_mol_charge_per_megagram;
    if (parameters.aqueous_kinetics.general_substrate_limit_fraction <= 0 or parameters.aqueous_kinetics.maximum_slow_association_mol_per_m3_step <= 0) return error.UnsupportedSurfaceMineralInput;
    inline for (hydroxide_fields, 0..) |chain, m| {
        inline for (chain) |field| {
            if (@field(parameters.aqueous_constants, field) <= 0) return error.UnsupportedSurfaceMineralInput;
            context.total_metals[m] += @field(base.aqueous, field);
        }
    }
    for (base.before, 0..) |zone, i| {
        if (base.fractions[i] > 0) {
            context.total_metals[1] += base.fractions[i] * (zone.iron_hpo4_pair_mol_per_m3 + zone.iron_h2po4_pair_mol_per_m3);
            context.total_metals[2] += base.fractions[i] * (zone.calcium_hpo4_pair_mol_per_m3 + zone.calcium_h2po4_pair_mol_per_m3);
            context.total_magnesium += base.fractions[i] * zone.magnesium_hpo4_pair_mol_per_m3;
            context.base.totals[i] += pairP(zone);
        }
        inline for (fields, 0..) |field, m| {
            const phase = i * 5 + m;
            const solid = @field(zone, field);
            context.initial_solids[phase] = solid;
            context.enabled[phase] = base.fractions[i] > 0 and context.products[m] > 0 and (if (m == 3) minerals.maximum_apatite_precipitation_mol_per_m3_step > 0 else minerals.maximum_phosphate_precipitation_mol_per_m3_step > 0) and (m != 4 or minerals.maximum_mineral_dissolution_mol_per_m3_step > 0);
            if (context.enabled[phase]) {
                context.total_metals[metal_index[m]] += base.fractions[i] * solid * metal_n[m];
                context.base.totals[i] += solid * phosphorus_n[m];
            }
        }
    }
    for (0..3) |m| {
        if (context.total_metals[m] > 0) x[6 + m] = @log(@max(0.001, initial_metals[m] / context.total_metals[m]));
        context.base.charge_scale += charge_n[m] * context.total_metals[m];
    }
    context.partner_totals[2] += context.total_magnesium - base.aqueous.magnesium;
    inline for (partners, 0..) |field, i| {
        if (context.partner_fractions[i] > 0 and context.partner_totals[i] > 0) {
            x[19 + i] = @log(@max(0.001, @field(base.aqueous, field) / context.partner_totals[i]));
            if (i < 2) x[19 + i] = @min(x[19 + i], @log(seed_hydrogen / (seed_hydrogen + parameters.aqueous_constants.ammonium)));
        }
    }
    const initial_coefficients = try local.coefficients(x[5]);
    if (context.carbon_total > 0) {
        const bicarbonate_weight = initial_coefficients.divalent_activity_coefficient * seed_hydrogen / parameters.aqueous_constants.bicarbonate;
        const dioxide_weight = bicarbonate_weight * seed_hydrogen * initial_coefficients.monovalent_activity_coefficient * initial_coefficients.monovalent_activity_coefficient / parameters.aqueous_constants.carbon_dioxide;
        x[24] = @min(@log(@max(0.001, base.aqueous.carbonate / context.carbon_total)), -@log(1 + bicarbonate_weight + dioxide_weight));
    }
    if (context.sulfur_total > 0) x[25] = @log(@max(0.001, base.aqueous.sulfate / context.sulfur_total));
    const initial_g = [_]f64{ initial_coefficients.trivalent_activity_coefficient, initial_coefficients.divalent_activity_coefficient, initial_coefficients.monovalent_activity_coefficient, 1, initial_coefficients.monovalent_activity_coefficient };
    const initial_oh = parameters.water_activity_product_mol2_per_m6 / @exp(x[0]) / initial_coefficients.monovalent_activity_coefficient;
    inline for (hydroxide_fields, 0..) |chain, m| {
        var weight: f64 = 1;
        var denominator: f64 = 1;
        inline for (chain, 0..) |field, i| {
            weight *= initial_g[i] * initial_oh / (@field(parameters.aqueous_constants, field) * initial_g[i + 1]);
            denominator += weight;
        }
        if (context.total_metals[m] > 0) x[6 + m] = @min(x[6 + m], -@log(denominator));
    }
    for (0..2) |i| {
        context.base.charge_scale += 3 * base.fractions[i] * (context.base.totals[i] - base.totals[i]);
        if (base.fractions[i] > 0 and context.base.totals[i] > 0) x[1 + 2 * i] = @log(@max(0.001, base.before[i].dissolved_h2po4_mol_p_per_m3 / context.base.totals[i]));
    }
    for (0..10) |phase| {
        if (!context.enabled[phase]) continue;
        const z = phase / 5;
        const m = phase % 5;
        context.scales[phase] = @min(context.base.totals[z] / phosphorus_n[m], context.total_metals[metal_index[m]] / (base.fractions[z] * metal_n[m]));
        if (context.scales[phase] == 0) {
            context.enabled[phase] = false;
            continue;
        }
        x[9 + phase] = context.initial_solids[phase] / context.scales[phase];
    }
    context.euclidean_merit = euclidean_merit;
    var retained_columns: MineralColumnCache = .{};
    var value = try context.evaluateCaching(x, &retained_columns);
    // Native inventories, activities and phase residuals are rebuilt for the
    // new target. A retained guess is useful only if it beats the cold start;
    // it never substitutes for convergence or native reconstruction.
    if (seed) |storage| {
        if (storage.*) |prior| {
            var seed_columns: MineralColumnCache = .{};
            if (context.evaluateCaching(prior, &seed_columns)) |seed_value| {
                if (seed_value.norm < value.norm) {
                    x = prior;
                    value = seed_value;
                    retained_columns = seed_columns;
                }
            } else |_| {}
        }
    }
    // Only failed attempts need continuation. A completed native candidate
    // clears the private seed instead of perturbing subsequent cold targets.
    // Errors still retain improved work without publishing native chemistry.
    if (seed) |storage| storage.* = null;
    errdefer if (seed) |storage| {
        storage.* = x;
    };
    var iteration: u16 = 0;
    while (!value.converged and iteration < maximum_iterations) : (iteration += 1) {
        var jacobian: [dimension * dimension]f64 = undefined;
        for (0..dimension) |column| {
            const probe = std.math.cbrt(std.math.floatEps(f64)) * @max(1, @abs(x[column]));
            var plus = x;
            var minus = x;
            plus[column] += probe;
            const backward = if (column >= 9 and column < 19) @min(probe, x[column]) else probe;
            minus[column] -= backward;
            // A mineral solid coordinate reaches the residual through three
            // additive accumulations and its own complementarity row, so its
            // two finite-difference probes are replayed from the retained
            // complete evaluation instead of repeating the coupled
            // speciation, Gapon exchange, surface and activity work 20 times
            // per local Newton iteration. See `MineralColumnCache`.
            if (column >= 9 and column < 19) {
                const phase = column - 9;
                var positive: [dimension]f64 = undefined;
                var negative: [dimension]f64 = undefined;
                try context.mineralColumnResidual(&retained_columns, plus, phase, &positive);
                try context.mineralColumnResidual(&retained_columns, minus, phase, &negative);
                if (verify_mineral_column_shortcut) {
                    const reference_positive = try context.evaluate(plus);
                    const reference_negative = try context.evaluate(minus);
                    for (0..dimension) |row| {
                        if (positive[row] != reference_positive.residual[row] or
                            negative[row] != reference_negative.residual[row])
                            @panic("mineral Jacobian column shortcut is not bit-identical");
                    }
                }
                for (0..dimension) |row| jacobian[row * dimension + column] = (positive[row] - negative[row]) / (probe + backward);
                continue;
            }
            const positive = try context.evaluate(plus);
            const negative = try context.evaluate(minus);
            for (0..dimension) |row| jacobian[row * dimension + column] = (positive.residual[row] - negative.residual[row]) / (probe + backward);
        }
        var step = value.residual;
        for (&step) |*r| r.* = -r.*;
        {
            var dense_scope = @import("reaction_diagnostic_control.zig").beginPhase(.local_mineral_dense_solve);
            defer dense_scope.end();
            if (!numerics.solveDenseLinearSystem(&jacobian, &step, dimension)) return error.SingularSurfaceMineralJacobian;
        }
        const previous_x = x;
        const previous_value = value;
        var fraction: f64 = 1;
        var improved = false;
        var trial_columns: MineralColumnCache = .{};
        for (0..16) |_| {
            var trial = x;
            for (&trial, step, 0..) |*coordinate, delta, i| coordinate.* = if (i >= 9 and i < 19) @max(0, coordinate.* + fraction * delta) else coordinate.* + fraction * delta;
            const next = context.evaluateCaching(trial, &trial_columns) catch {
                fraction *= 0.5;
                continue;
            };
            if (next.norm < value.norm or next.converged) {
                x = trial;
                value = next;
                retained_columns = trial_columns;
                improved = true;
                break;
            }
            fraction *= 0.5;
        }
        var accelerated: [dimension]f64 = undefined;
        if (numerics.andersonDepthOneCandidate(&previous_x, &previous_value.residual, &x, &value.residual, &accelerated)) {
            for (accelerated[9..19]) |*v| v.* = @max(0, v.*);
            var accelerated_columns: MineralColumnCache = .{};
            if (context.evaluateCaching(accelerated, &accelerated_columns)) |next| {
                if (next.norm < value.norm or next.converged) {
                    x = accelerated;
                    value = next;
                    retained_columns = accelerated_columns;
                    improved = true;
                }
            } else |_| {}
        }
        if (!improved) return error.SurfaceMineralStagnated;
    }
    if (!value.converged) return error.SurfaceMineralDidNotConverge;
    // `zeroTransformations` is a pure function of `parameters`; the original
    // reconstruction re-derived it once per reaction axis, zeroing a full
    // `CellTransformations` roughly fifty times per accepted candidate.
    const zero_transformations = span.zeroTransformations(parameters);
    var changes = try local.transformations(base, value.surface);
    try span.addReactionExtent(&changes, 0, base.aqueous.ammonia_non_band - value.aqueous.ammonia_non_band, zero_transformations, parameters);
    try span.addReactionExtent(&changes, 1, base.aqueous.ammonia_band - value.aqueous.ammonia_band, zero_transformations, parameters);
    var carbonate_association = base.aqueous.carbonate - value.aqueous.carbonate;
    inline for (complexes) |c| {
        const extent = @field(value.aqueous, c[0]) - @field(base.aqueous, c[0]);
        try span.addReactionExtent(&changes, c[6], extent, zero_transformations, parameters);
        if (comptime std.mem.eql(u8, c[2], "carbonate")) carbonate_association -= extent;
    }
    try span.addReactionExtent(&changes, 2, carbonate_association, zero_transformations, parameters);
    try span.addReactionExtent(&changes, 3, value.aqueous.carbon_dioxide - base.aqueous.carbon_dioxide, zero_transformations, parameters);
    inline for (std.meta.fields(exchange.Cations)) |field| @field(changes.cation_adsorption_mol_per_megagram, field.name) = @field(value.exchange, field.name) - @field(context.initial_exchange, field.name);
    inline for (hydroxide_fields, 0..) |chain, m| {
        var extent: f64 = 0;
        inline for (0..4) |reverse| {
            const i = 3 - reverse;
            extent += @field(value.aqueous, chain[i]) - @field(base.aqueous, chain[i]);
            try span.addReactionExtent(&changes, (if (m == 0) @as(usize, 4) else 9) + i, extent, zero_transformations, parameters);
        }
    }
    for (base.before, value.surface.zones, 0..) |before, after, z| {
        if (base.fractions[z] == 0) continue;
        const offset = if (z == 0) span.non_band_phosphate_aqueous_offset else span.band_phosphate_aqueous_offset;
        const pair_changes = [_]f64{ after.iron_hpo4_pair_mol_per_m3 - before.iron_hpo4_pair_mol_per_m3, after.iron_h2po4_pair_mol_per_m3 - before.iron_h2po4_pair_mol_per_m3, 0, after.calcium_hpo4_pair_mol_per_m3 - before.calcium_hpo4_pair_mol_per_m3, after.calcium_h2po4_pair_mol_per_m3 - before.calcium_h2po4_pair_mol_per_m3, after.magnesium_hpo4_pair_mol_per_m3 - before.magnesium_hpo4_pair_mol_per_m3 };
        try span.addReactionExtent(&changes, offset + 1, -pair_changes[0] - pair_changes[3] - pair_changes[5], zero_transformations, parameters);
        for (pair_changes, 0..) |extent, i| if (extent != 0) try span.addReactionExtent(&changes, offset + 3 + i, extent, zero_transformations, parameters);
    }
    for (0..10) |phase| {
        if (!context.enabled[phase]) continue;
        const offset = if (phase < 5) span.non_band_phosphate_mineral_offset else span.band_phosphate_mineral_offset;
        try span.addReactionExtent(&changes, offset + phase % 5, value.solids[phase] - context.initial_solids[phase], zero_transformations, parameters);
    }
    var native: [chemistry.State.packedComponentCount()]f64 = undefined;
    const final_coefficients = try local.coefficients(x[5]);
    try @import("reaction_solver_numerics.zig").transformedVector(scratch, current, changes, final_coefficients.monovalent_activity_coefficient, parameters.water_activity_product_mol2_per_m6, 1, &native);
    // Exact stored-P reconciliation may choose an ion pair as its rounding
    // owner. Undo that pair redistribution stoichiometrically before restoring
    // trace free metals; changing only the free metal would leak its inventory.
    for ([_]*phosphate.State{ &scratch.non_band_phosphate[0], &scratch.band_phosphate[0] }, value.surface.zones, 0..) |zone, target, z| {
        if (base.fractions[z] == 0) continue;
        inline for (.{
            .{ "iron_hpo4_pair_mol_per_m3", "iron", "dissolved_hpo4_mol_p_per_m3" },
            .{ "iron_h2po4_pair_mol_per_m3", "iron", "dissolved_h2po4_mol_p_per_m3" },
            .{ "calcium_hpo4_pair_mol_per_m3", "calcium", "dissolved_hpo4_mol_p_per_m3" },
            .{ "calcium_h2po4_pair_mol_per_m3", "calcium", "dissolved_h2po4_mol_p_per_m3" },
            .{ "magnesium_hpo4_pair_mol_per_m3", "magnesium", "dissolved_hpo4_mol_p_per_m3" },
        }) |pair| {
            const released = @field(zone.*, pair[0]) - @field(target, pair[0]);
            if (@abs(released) > 128 * std.math.floatEps(f64) * context.base.totals[z]) return error.InvalidSurfaceMineralReconstruction;
            @field(zone.*, pair[0]) = @field(target, pair[0]);
            @field(zone.*, pair[2]) += released;
            @field(scratch.aqueous[0], pair[1]) += base.fractions[z] * released;
        }
    }
    // Native precipitation subtracts large nearly equal pools. Recover only
    // roundoff-sized losses in the model's positive dissolved coordinates;
    // validate the original complete ledgers before returning any output.
    try restoreTrace(&scratch.aqueous[0].aluminum, context.total_metals[0] * @exp(x[6]), context.total_metals[0]);
    try restoreTrace(&scratch.aqueous[0].iron, context.total_metals[1] * @exp(x[7]), context.total_metals[1]);
    try restoreTrace(&scratch.aqueous[0].calcium, context.total_metals[2] * @exp(x[8]), context.total_metals[2]);
    inline for (partners, 0..) |field, i| try restoreTrace(&@field(scratch.aqueous[0], field), @field(value.aqueous, field), context.partner_totals[i]);
    try restoreTrace(&scratch.aqueous[0].ammonia_non_band, value.aqueous.ammonia_non_band, context.partner_totals[0]);
    try restoreTrace(&scratch.aqueous[0].ammonia_band, value.aqueous.ammonia_band, context.partner_totals[1]);
    inline for (complexes) |c| {
        const total = if (c[7] < 3) context.total_metals[c[7]] else context.partner_totals[c[7] - 1];
        try restoreTrace(&@field(scratch.aqueous[0], c[0]), @field(value.aqueous, c[0]), total);
    }
    inline for (.{ "carbonate", "bicarbonate", "carbon_dioxide" }) |field| try restoreTrace(&@field(scratch.aqueous[0], field), @field(value.aqueous, field), context.carbon_total);
    try restoreTrace(&scratch.aqueous[0].sulfate, value.aqueous.sulfate, context.sulfur_total);
    inline for (hydroxide_fields, 0..) |chain, m| {
        inline for (chain) |field| try restoreTrace(&@field(scratch.aqueous[0], field), @field(value.aqueous, field), context.total_metals[m]);
    }
    const h = @exp(x[0]);
    const oh = parameters.water_activity_product_mol2_per_m6 / h / (final_coefficients.monovalent_activity_coefficient * final_coefficients.monovalent_activity_coefficient);
    try restoreTrace(&scratch.aqueous[0].hydrogen, h, context.base.charge_scale);
    try restoreTrace(&scratch.aqueous[0].hydroxide, oh, context.base.charge_scale);
    try ledger.requireConservedInventories(entry_inventory, try ledger.acceptedStateInventory(scratch, 0, parameters));
    try charge_ledger.requireConserved(entry_charge, try charge_ledger.inventory(scratch, 0, parameters));
    try scratch.packCell(0, output);
    return iteration;
}
