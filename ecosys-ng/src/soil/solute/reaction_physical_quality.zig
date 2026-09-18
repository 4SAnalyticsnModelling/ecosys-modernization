//! Chemical endpoint quality, independent of numerical search tolerances.
//! Inventory conservation and positivity are separate publication guards.
const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const phosphate = @import("phosphate_network.zig");

pub const Criteria = struct {
    /// A hundredth of a pH unit is about 2.3% hydrogen-activity movement.
    maximum_pH_change: f64 = 0.01,
    /// One percent of an occupied species pool, plus a trace allowance of
    /// one ten-thousandth of its dissolved elemental family or site capacity.
    species_pool_fraction: f64 = 0.01,
    mobile_family_fraction: f64 = 0.0001,
    /// One part per million of solvent inventory in the net reaction preview.
    water_inventory_fraction: f64 = 0.000001,
};

pub const Quality = struct {
    maximum: f64 = 0,
    rms: f64 = 0,
    component: usize = 0,
    pH_change: f64 = 0,

    fn include(self: *Quality, value: f64, component: usize) void {
        if (value > self.maximum) {
            self.maximum = value;
            self.component = component;
        }
        self.rms = std.math.hypot(self.rms, value);
    }
};

fn relativeChange(change: f64, pool: f64, family: f64, criteria: Criteria) !f64 {
    if (!std.math.isFinite(change) or !std.math.isFinite(pool) or pool < 0 or
        !std.math.isFinite(family) or family < 0) return error.InvalidChemicalQualityState;
    const limit = criteria.species_pool_fraction * pool + criteria.mobile_family_fraction * family +
        128 * std.math.floatEps(f64) * @max(pool, family);
    // A newly supplied family is wholly out of balance, but its finite
    // source must still be allowed to generate a Newton correction.
    return if (change == 0) 0 else if (limit == 0) 1 / @max(criteria.mobile_family_fraction, criteria.species_pool_fraction) else @abs(change) / limit;
}

fn mobileReference(name: []const u8, mobile: anytype, own: f64) f64 {
    var reference = own;
    if (std.mem.startsWith(u8, name, "aluminum")) reference = mobile.aluminum_mol_per_m3;
    if (std.mem.startsWith(u8, name, "iron")) reference = mobile.iron_mol_per_m3;
    if (std.mem.startsWith(u8, name, "calcium")) reference = mobile.calcium_mol_per_m3;
    if (std.mem.startsWith(u8, name, "magnesium")) reference = mobile.magnesium_mol_per_m3;
    if (std.mem.startsWith(u8, name, "sodium")) reference = mobile.sodium_mol_per_m3;
    if (std.mem.startsWith(u8, name, "potassium")) reference = mobile.potassium_mol_per_m3;
    if (std.mem.indexOf(u8, name, "carbon") != null) reference = if (std.mem.startsWith(u8, name, "carbon") or std.mem.eql(u8, name, "bicarbonate")) mobile.carbon_mol_per_m3 else @min(reference, mobile.carbon_mol_per_m3);
    if (std.mem.indexOf(u8, name, "sulfate") != null) reference = if (std.mem.eql(u8, name, "sulfate")) mobile.sulfur_mol_per_m3 else @min(reference, mobile.sulfur_mol_per_m3);
    return reference;
}

fn mobilePhosphorus(zone: phosphate.State) f64 {
    @setEvalBranchQuota(20000);
    var total: f64 = 0;
    inline for (std.meta.fields(phosphate.State)) |field| {
        if (comptime std.mem.indexOf(u8, field.name, "solid") == null and !std.mem.endsWith(u8, field.name, "megagram")) total += @field(zone, field.name);
    }
    return total;
}

/// `residual` is the undamped source preview, including dependent water-pair
/// projection and net solvent change. No line-search damping enters quality.
pub fn measure(state: *const chemistry.State, parameters: chemistry.ReactionParameters, residual: []const f64, criteria: Criteria) !Quality {
    @setEvalBranchQuota(20000);
    var profile_scope = @import("reaction_diagnostic_control.zig").beginPhase(.physical_quality);
    defer profile_scope.end();
    if (state.cell_count != 1 or residual.len != chemistry.State.packedComponentCount()) return error.InvalidChemicalQualityState;
    for (residual) |value| if (!std.math.isFinite(value)) return error.InvalidChemicalQualityState;
    inline for (std.meta.fields(Criteria)) |field| {
        const value = @field(criteria, field.name);
        if (!std.math.isFinite(value) or value <= 0 or value > 1) return error.InvalidChemicalQualityCriteria;
    }
    const mobile = try @import("reaction_solve.zig").mobileStateInventory(state, 0, parameters);
    const aqueous = state.aqueous[0];
    var quality: Quality = .{};
    var cursor: usize = 0;
    inline for (std.meta.fields(@TypeOf(aqueous))) |field| {
        const own = @field(aqueous, field.name);
        if (comptime std.mem.eql(u8, field.name, "hydrogen") or std.mem.eql(u8, field.name, "hydroxide")) {
            const next = own + residual[cursor];
            const movement = if (own > 0 and next > 0 and std.math.isFinite(next)) @abs(@log(next) - @log(own)) / @log(@as(f64, 10)) else std.math.inf(f64);
            quality.pH_change = @max(quality.pH_change, movement);
            quality.include(movement / criteria.maximum_pH_change, cursor);
        } else {
            const reference = if (comptime std.mem.eql(u8, field.name, "ammonium_non_band") or std.mem.eql(u8, field.name, "ammonia_non_band")) aqueous.ammonium_non_band + aqueous.ammonia_non_band else if (comptime std.mem.eql(u8, field.name, "ammonium_band") or std.mem.eql(u8, field.name, "ammonia_band")) aqueous.ammonium_band + aqueous.ammonia_band else mobileReference(field.name, mobile, own);
            quality.include(try relativeChange(residual[cursor], own, reference, criteria), cursor);
        }
        cursor += 1;
    }
    for ([_]phosphate.State{ state.non_band_phosphate[0], state.band_phosphate[0] }, 0..) |zone, zone_index| {
        const phosphorus = mobilePhosphorus(zone);
        const capacity = try phosphate.siteInventory(zone);
        inline for (std.meta.fields(phosphate.State)) |field| {
            const own = @field(zone, field.name);
            var reference = if (comptime std.mem.endsWith(u8, field.name, "megagram")) capacity else phosphorus;
            if (comptime std.mem.indexOf(u8, field.name, "pair") != null) {
                const fraction = if (zone_index == 0) parameters.fractions.phosphate_non_band else parameters.fractions.phosphate_band;
                const metal = if (comptime std.mem.startsWith(u8, field.name, "iron")) mobile.iron_mol_per_m3 else if (comptime std.mem.startsWith(u8, field.name, "calcium")) mobile.calcium_mol_per_m3 else mobile.magnesium_mol_per_m3;
                if (fraction > 0) reference = @min(reference, metal / fraction);
            }
            quality.include(try relativeChange(residual[cursor], own, reference, criteria), cursor);
            cursor += 1;
        }
    }
    inline for (std.meta.fields(@TypeOf(state.cation_exchange_mol_per_megagram[0]))) |field| {
        quality.include(try relativeChange(residual[cursor], @field(state.cation_exchange_mol_per_megagram[0], field.name), parameters.cation_exchange_capacity_mol_charge_per_megagram, criteria), cursor);
        cursor += 1;
    }
    quality.include(try relativeChange(residual[cursor], state.carboxyl_bound_hydrogen_mol_per_megagram[0], parameters.total_carboxyl_sites_mol_per_megagram, criteria), cursor);
    cursor += 1;
    inline for (std.meta.fields(@TypeOf(state.geochemistry_solids[0]))) |field| {
        const own = @field(state.geochemistry_solids[0], field.name);
        quality.include(try relativeChange(residual[cursor], own, mobileReference(field.name, mobile, own), criteria), cursor);
        cursor += 1;
    }
    std.debug.assert(cursor + 1 == residual.len);
    var water_criteria = criteria;
    water_criteria.species_pool_fraction = criteria.water_inventory_fraction;
    water_criteria.mobile_family_fraction = 0;
    quality.include(try relativeChange(residual[cursor], state.water_mol_per_m3[0], 0, water_criteria), cursor);
    quality.rms /= @sqrt(@as(f64, @floatFromInt(residual.len)));
    return quality;
}
