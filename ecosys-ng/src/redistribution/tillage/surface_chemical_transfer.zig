// **A8a DISPOSITION: BOUND THROUGH ATOMIC RUNTIME ADAPTER.**
// `redistribution/tillage/runtime_adapter.zig` invokes this kernel in source
// order from the scheduled disturbance dispatcher and publishes atomically.
//
// **HISTORICAL A8a DISPOSITION: GAP, translated and validated but unreached. Do not bind here.**
//
// REDIST 11717--11885 scales every layer-0 gas, mineral N, phosphate,
// exchange, and salt pool by XCORP0, rebuilds VHCP(0) at 11791--11793, and
// subtracts HFLXD from both HEATIN and HEATSO at 11750--11751. None of it
// happens in production, including the two heat-ledger corrections.
//
// The whole directory has one importer, `src/module_index.zig`.
// `disturbance_management_dispatch.applyEvent:95` handles `.tillage` for roots
// and plants only, and its `ApplyContext:41--61` carries no soil-column state,
// so the omission is structural. The gap is live: `f25til98` fires codes 10,
// 10, and 8 during 1998, and `day.f:347--349` gives XCORP = 0.0, 0.0, and 0.2,
// all passing the `redist.f:11277` gate.
//
// Binding requires a new soil-side disturbance path and an ordering decision
// against the existing root-side response, which is A1's call under the
// shared-state rule.
//
// surface incorporation group of
// docs/traceability/redistribution_tillage_unbound_family_disposition.md
//
const std = @import("std");
const ice_units = @import("../../core/ice_units.zig");

pub const core_family_count = 31;
pub const dynamic_salt_family_count = 42;
pub const TransferFamily = struct {
    surface_amount: []f64,
    incorporated_amount: []f64,
};
pub const OrganicTotals = struct {
    remaining_carbon_g_c: f64,
    remaining_nitrogen_g_n: f64,
    charcoal_remaining_carbon_g_c: f64,
    charcoal_remaining_nitrogen_g_n: f64,
};
pub const ThermodynamicParameters = struct {
    dry_organic_heat_capacity_megajoules_per_g_c_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    physical_ice_heat_capacity_megajoules_per_m3_k: f64,
    ice_density_megagrams_per_m3: f64,
};
pub const State = struct {
    /// REDIST 11717--11747 order: gases(6), mineral N(4), phosphate(2),
    /// exchange pools(14), fertilizer/fixation N(5).
    core_families: []const TransferFamily,
    /// REDIST 11801--11842 order; empty when ISALTG=0, exactly 42 otherwise.
    dynamic_salt_families: []const TransferFamily,
    surface_water_m3: []f64,
    surface_ice_m3: []f64,
    surface_vapor_m3: []f64,
    incorporated_water_m3: []f64,
    incorporated_energy_megajoules: []f64,
    organic_carbon_g_c: []f64,
    organic_nitrogen_g_n: []f64,
    charcoal_organic_carbon_g_c: []f64,
    charcoal_organic_nitrogen_g_n: []f64,
    residue_organic_carbon_g_c: []f64,
    surface_temperature_k: []const f64,
    surface_heat_capacity_megajoules_k: []f64,
    heat_input_megajoules: []f64,
    soil_heat_megajoules: []f64,
    residue_volume_m3: []f64,
    total_volume_m3: []f64,
    auxiliary_volume_m3: []f64,
    urea_surface_maximum: []f64,
    urea_incorporated_maximum: []f64,
    fixation_maximum: []f64,
    urea_surface_candidate: []const f64,
    urea_incorporated_candidate: []const f64,
    fixation_candidate: []const f64,
};

fn finiteSlice(v: []const f64) bool {
    for (v) |x| if (!std.math.isFinite(x)) return false;
    return true;
}
fn validateFamily(f: TransferFamily, cells: usize) !void {
    if (f.surface_amount.len != cells or f.incorporated_amount.len != cells) return error.TillageChemicalTransferDimensionMismatch;
    if (!finiteSlice(f.surface_amount) or !finiteSlice(f.incorporated_amount)) return error.InvalidTillageChemicalTransferInput;
    for (f.surface_amount) |x| if (x < 0) return error.InvalidTillageChemicalTransferInput;
}

/// Direct translation of REDIST 11717--11885 for one runtime-indexed cell.
pub fn transferCell(allocator: std.mem.Allocator, cell: usize, surface_remaining_fraction: f64, dynamic_salts: bool, totals: OrganicTotals, thermodynamics: ThermodynamicParameters, state: State) !void {
    const cells = state.surface_water_m3.len;
    const expected_salt_families: usize = if (dynamic_salts) dynamic_salt_family_count else 0;
    if (cells == 0 or cell >= cells or state.core_families.len != core_family_count or state.dynamic_salt_families.len != expected_salt_families) return error.TillageChemicalTransferDimensionMismatch;
    inline for (std.meta.fields(State)) |field| {
        if (comptime std.mem.eql(u8, field.name, "core_families") or std.mem.eql(u8, field.name, "dynamic_salt_families")) continue;
        if (@field(state, field.name).len != cells) return error.TillageChemicalTransferDimensionMismatch;
        if (!finiteSlice(@field(state, field.name))) return error.InvalidTillageChemicalTransferInput;
    }
    for (state.core_families) |family| try validateFamily(family, cells);
    for (state.dynamic_salt_families) |family| try validateFamily(family, cells);
    if (!std.math.isFinite(surface_remaining_fraction) or surface_remaining_fraction < 0 or surface_remaining_fraction > 1) return error.InvalidTillageChemicalTransferInput;
    inline for (std.meta.fields(OrganicTotals)) |field| if (!std.math.isFinite(@field(totals, field.name)) or @field(totals, field.name) < 0) return error.InvalidTillageChemicalTransferInput;
    if (!std.math.isFinite(thermodynamics.dry_organic_heat_capacity_megajoules_per_g_c_k) or thermodynamics.dry_organic_heat_capacity_megajoules_per_g_c_k <= 0 or !std.math.isFinite(thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k) or thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k <= 0) return error.InvalidTillageChemicalTransferInput;
    const ice_heat_capacity_per_water_equivalent_m3_k = ice_units.heatCapacityPerWaterEquivalentM3K(
        thermodynamics.physical_ice_heat_capacity_megajoules_per_m3_k,
        thermodynamics.ice_density_megagrams_per_m3,
    ) catch return error.InvalidTillageChemicalTransferInput;
    if (state.surface_temperature_k[cell] <= 0 or state.surface_water_m3[cell] < 0 or state.surface_ice_m3[cell] < 0 or state.surface_vapor_m3[cell] < 0) return error.InvalidTillageChemicalTransferInput;
    const incorporated_fraction = 1.0 - surface_remaining_fraction;
    const family_total = core_family_count + state.dynamic_salt_families.len;
    const staged_surface = try allocator.alloc(f64, family_total);
    defer allocator.free(staged_surface);
    const staged_incorporated = try allocator.alloc(f64, family_total);
    defer allocator.free(staged_incorporated);
    var family_index: usize = 0;
    for (state.core_families) |family| {
        staged_incorporated[family_index] = family.surface_amount[cell] * incorporated_fraction;
        staged_surface[family_index] = family.surface_amount[cell] * surface_remaining_fraction;
        family_index += 1;
    }
    for (state.dynamic_salt_families) |family| {
        staged_incorporated[family_index] = family.surface_amount[cell] * incorporated_fraction;
        staged_surface[family_index] = family.surface_amount[cell] * surface_remaining_fraction;
        family_index += 1;
    }
    const incorporated_water = state.surface_water_m3[cell] * incorporated_fraction;
    const heat_flux = thermodynamics.dry_organic_heat_capacity_megajoules_per_g_c_k * state.organic_carbon_g_c[cell] * incorporated_fraction * state.surface_temperature_k[cell];
    const next_heat_input = state.heat_input_megajoules[cell] - heat_flux;
    const next_soil_heat = state.soil_heat_megajoules[cell] - heat_flux;
    const incorporated_energy = thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * incorporated_water * state.surface_temperature_k[cell];
    const water = state.surface_water_m3[cell] * surface_remaining_fraction;
    const ice = state.surface_ice_m3[cell] * surface_remaining_fraction;
    const vapor = state.surface_vapor_m3[cell] * surface_remaining_fraction;
    const heat_capacity = thermodynamics.dry_organic_heat_capacity_megajoules_per_g_c_k * (totals.remaining_carbon_g_c + totals.charcoal_remaining_carbon_g_c) + thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * (water + vapor) + ice_heat_capacity_per_water_equivalent_m3_k * ice;
    const residue_volume = state.residue_volume_m3[cell] * surface_remaining_fraction;
    const total_volume = state.total_volume_m3[cell] * surface_remaining_fraction;
    const auxiliary_volume = state.auxiliary_volume_m3[cell] * surface_remaining_fraction;
    const urea_surface_max = @max(state.urea_surface_maximum[cell], state.urea_surface_candidate[cell]);
    const urea_incorporated_max = @max(state.urea_incorporated_maximum[cell], state.urea_incorporated_candidate[cell]);
    const fixation_max = @max(state.fixation_maximum[cell], state.fixation_candidate[cell]);
    inline for (.{ incorporated_water, heat_flux, next_heat_input, next_soil_heat, incorporated_energy, water, ice, vapor, heat_capacity, residue_volume, total_volume, auxiliary_volume, urea_surface_max, urea_incorporated_max, fixation_max }) |x| if (!std.math.isFinite(x)) return error.NonFiniteTillageChemicalTransferResult;
    for (staged_surface) |x| if (!std.math.isFinite(x)) return error.NonFiniteTillageChemicalTransferResult;
    for (staged_incorporated) |x| if (!std.math.isFinite(x)) return error.NonFiniteTillageChemicalTransferResult;

    family_index = 0;
    for (state.core_families) |family| {
        family.incorporated_amount[cell] = staged_incorporated[family_index];
        family.surface_amount[cell] = staged_surface[family_index];
        family_index += 1;
    }
    state.incorporated_water_m3[cell] = incorporated_water;
    state.incorporated_energy_megajoules[cell] = incorporated_energy;
    state.heat_input_megajoules[cell] = next_heat_input;
    state.soil_heat_megajoules[cell] = next_soil_heat;
    state.organic_carbon_g_c[cell] = totals.remaining_carbon_g_c;
    state.organic_nitrogen_g_n[cell] = totals.remaining_nitrogen_g_n;
    state.charcoal_organic_carbon_g_c[cell] = totals.charcoal_remaining_carbon_g_c;
    state.charcoal_organic_nitrogen_g_n[cell] = totals.charcoal_remaining_nitrogen_g_n;
    state.residue_organic_carbon_g_c[cell] = totals.remaining_carbon_g_c;
    state.surface_water_m3[cell] = water;
    state.surface_ice_m3[cell] = ice;
    state.surface_vapor_m3[cell] = vapor;
    state.surface_heat_capacity_megajoules_k[cell] = heat_capacity;
    state.residue_volume_m3[cell] = residue_volume;
    state.total_volume_m3[cell] = total_volume;
    state.auxiliary_volume_m3[cell] = auxiliary_volume;
    state.urea_surface_maximum[cell] = urea_surface_max;
    state.urea_incorporated_maximum[cell] = urea_incorporated_max;
    state.fixation_maximum[cell] = fixation_max;
    for (state.dynamic_salt_families) |family| {
        family.incorporated_amount[cell] = staged_incorporated[family_index];
        family.surface_amount[cell] = staged_surface[family_index];
        family_index += 1;
    }
}

fn stateFixture(core: []const TransferFamily, salts: []const TransferFamily, values: *[24][1]f64) State {
    return .{ .core_families = core, .dynamic_salt_families = salts, .surface_water_m3 = &values[0], .surface_ice_m3 = &values[1], .surface_vapor_m3 = &values[2], .incorporated_water_m3 = &values[3], .incorporated_energy_megajoules = &values[4], .organic_carbon_g_c = &values[5], .organic_nitrogen_g_n = &values[6], .charcoal_organic_carbon_g_c = &values[7], .charcoal_organic_nitrogen_g_n = &values[8], .residue_organic_carbon_g_c = &values[9], .surface_temperature_k = &values[10], .surface_heat_capacity_megajoules_k = &values[11], .heat_input_megajoules = &values[12], .soil_heat_megajoules = &values[13], .residue_volume_m3 = &values[14], .total_volume_m3 = &values[15], .auxiliary_volume_m3 = &values[16], .urea_surface_maximum = &values[17], .urea_incorporated_maximum = &values[18], .fixation_maximum = &values[19], .urea_surface_candidate = &values[20], .urea_incorporated_candidate = &values[21], .fixation_candidate = &values[22] };
}

test "REDIST surface chemical transfer preserves fractions heat ledgers and optional salts" {
    var core_surface: [core_family_count][1]f64 = @splat(@splat(4));
    var core_work: [core_family_count][1]f64 = @splat(@splat(0));
    var core: [core_family_count]TransferFamily = undefined;
    for (0..core_family_count) |i| core[i] = .{ .surface_amount = &core_surface[i], .incorporated_amount = &core_work[i] };
    var salt_surface: [dynamic_salt_family_count][1]f64 = @splat(@splat(8));
    var salt_work: [dynamic_salt_family_count][1]f64 = @splat(@splat(0));
    var salts: [dynamic_salt_family_count]TransferFamily = undefined;
    for (0..dynamic_salt_family_count) |i| salts[i] = .{ .surface_amount = &salt_surface[i], .incorporated_amount = &salt_work[i] };
    var values: [24][1]f64 = @splat(@splat(2));
    values[10][0] = 300;
    values[5][0] = 10;
    values[12][0] = 100;
    values[13][0] = 100;
    values[20][0] = 5;
    const state = stateFixture(&core, &salts, &values);
    const rho_ice = 0.917;
    try transferCell(std.testing.allocator, 0, 0.25, true, .{ .remaining_carbon_g_c = 6, .remaining_nitrogen_g_n = 3, .charcoal_remaining_carbon_g_c = 2, .charcoal_remaining_nitrogen_g_n = 1 }, .{ .dry_organic_heat_capacity_megajoules_per_g_c_k = 2.496e-6, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .physical_ice_heat_capacity_megajoules_per_m3_k = 1.9274, .ice_density_megagrams_per_m3 = rho_ice }, state);
    try std.testing.expectEqual(@as(f64, 1), core_surface[0][0]);
    try std.testing.expectEqual(@as(f64, 3), core_work[0][0]);
    try std.testing.expectEqual(@as(f64, 2), salt_surface[41][0]);
    try std.testing.expectEqual(@as(f64, 6), salt_work[41][0]);
    try std.testing.expectEqual(@as(f64, 1.5), values[3][0]);
    try std.testing.expectEqual(@as(f64, 6), values[5][0]);
    try std.testing.expectEqual(@as(f64, 5), values[17][0]);
    try std.testing.expectApproxEqAbs(2.496e-6 * 8 + 4.19 * 1 + 1.9274 / rho_ice * 0.5, values[11][0], 1e-12);
}

test "REDIST surface chemical late overflow is atomic" {
    var core_surface: [core_family_count][1]f64 = @splat(@splat(4));
    var core_work: [core_family_count][1]f64 = @splat(@splat(0));
    var core: [core_family_count]TransferFamily = undefined;
    for (0..core_family_count) |i| core[i] = .{ .surface_amount = &core_surface[i], .incorporated_amount = &core_work[i] };
    var values: [24][1]f64 = @splat(@splat(2));
    values[10][0] = std.math.floatMax(f64);
    values[5][0] = std.math.floatMax(f64);
    const state = stateFixture(&core, &.{}, &values);
    try std.testing.expectError(error.NonFiniteTillageChemicalTransferResult, transferCell(std.testing.allocator, 0, 0.5, false, .{ .remaining_carbon_g_c = 1, .remaining_nitrogen_g_n = 1, .charcoal_remaining_carbon_g_c = 1, .charcoal_remaining_nitrogen_g_n = 1 }, .{ .dry_organic_heat_capacity_megajoules_per_g_c_k = 2.496e-6, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .physical_ice_heat_capacity_megajoules_per_m3_k = 1.9274, .ice_density_megagrams_per_m3 = 0.917 }, state));
    try std.testing.expectEqual(@as(f64, 4), core_surface[0][0]);
    try std.testing.expectEqual(@as(f64, 0), core_work[0][0]);
    try std.testing.expectEqual(@as(f64, 2), values[0][0]);
}
