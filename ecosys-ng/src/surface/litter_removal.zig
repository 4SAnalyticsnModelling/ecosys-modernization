// REDIST operation 21 authoritative surface-litter removal transaction.
//
// REDIST operation 21, surface litter removal. `applyRuntimeCell` is the
// atomic owner adapter; the management dispatcher owns its date/solar-noon
// gate and calls it exactly once for each selected cell.
//
// Production binding: `disturbance_management_dispatch.applyEvent` selects
// `.surface_litter_removal` at each cell's solar noon and supplies the live
// owners plus hourly C/N/P and cumulative heat boundary ledgers. Missing
// binding is a hard error; operation 21 is no longer a counted no-op.
const std = @import("std");
const Organic = @import("../soil/organic/initialization.zig");
const Chemistry = @import("litter_chemistry.zig");
const Fertilizer = @import("litter_fertilizer.zig");
const Denitrification = @import("denitrification_step.zig");
const Geometry = @import("litter_geometry.zig");
const GeometryState = @import("litter_geometry_step.zig").State;
const legacy_water_negligible_floor = @import("../core/legacy_water_negligible_floor.zig");
const litter_substrate_count: usize = 3;

/// Runtime-sized authoritative surface pools bound from the REDIST operation
/// 21 owners. Colonized carbon is a diagnostic subset of structural carbon,
/// so it is scaled but deliberately excluded from independent C accounting.
pub const Pools = struct {
    organic_carbon_g_c: []f64,
    organic_nitrogen_g_n: []f64,
    organic_phosphorus_g_p: []f64,
    charcoal_carbon_g_c: []f64,
    charcoal_nitrogen_g_n: []f64,
    charcoal_phosphorus_g_p: []f64,
    colonized_structural_carbon_g_c: []f64,
    counted_mineral_nitrogen_g_n: []f64,
    counted_phosphate_phosphorus_g_p: []f64,
    other_scaled_nitrogen_g_n: []f64,
};

pub const Inputs = struct {
    removal_fraction: f64,
    surface_temperature_k: f64,
    /// ORGCX-equivalent dry organic C before this removal transaction.
    dry_organic_carbon_before_g_c: f64,
    dry_organic_heat_capacity_megajoules_per_g_c_k: f64 = 2.496e-6,
};

pub const Accounting = struct {
    carbon_output_g_c: f64,
    nitrogen_output_g_n: f64,
    phosphorus_output_g_p: f64,
    heat_output_megajoules: f64,
    remaining_organic_carbon_g_c: f64,
    remaining_organic_nitrogen_g_n: f64,
    remaining_organic_phosphorus_g_p: f64,
    remaining_charcoal_carbon_g_c: f64,
    remaining_charcoal_nitrogen_g_n: f64,
    remaining_charcoal_phosphorus_g_p: f64,
};

/// Atomically applies REDIST operation 21. Callers bind every named surface
/// owner into the appropriate runtime slice. Validation and all derived
/// accounting finish before the first pool is changed.
pub fn apply(pools: Pools, inputs: Inputs) !Accounting {
    try validateInputs(inputs);
    inline for (std.meta.fields(Pools)) |field|
        try validatePool(@field(pools, field.name));

    const organic_c_before = try sumFinite(pools.organic_carbon_g_c);
    const organic_n_before = try sumFinite(pools.organic_nitrogen_g_n);
    const organic_p_before = try sumFinite(pools.organic_phosphorus_g_p);
    const charcoal_c_before = try sumFinite(pools.charcoal_carbon_g_c);
    const charcoal_n_before = try sumFinite(pools.charcoal_nitrogen_g_n);
    const charcoal_p_before = try sumFinite(pools.charcoal_phosphorus_g_p);
    const mineral_n_before =
        try sumFinite(pools.counted_mineral_nitrogen_g_n);
    const mineral_p_before =
        try sumFinite(pools.counted_phosphate_phosphorus_g_p);

    const retained_fraction = 1 - inputs.removal_fraction;
    const accounting: Accounting = .{
        .carbon_output_g_c = try productFinite(
            inputs.removal_fraction,
            try addFinite(organic_c_before, charcoal_c_before),
        ),
        .nitrogen_output_g_n = try productFinite(
            inputs.removal_fraction,
            try addFinite(
                try addFinite(organic_n_before, charcoal_n_before),
                mineral_n_before,
            ),
        ),
        .phosphorus_output_g_p = try productFinite(
            inputs.removal_fraction,
            try addFinite(
                try addFinite(organic_p_before, charcoal_p_before),
                mineral_p_before,
            ),
        ),
        .remaining_organic_carbon_g_c = try productFinite(retained_fraction, organic_c_before),
        .remaining_organic_nitrogen_g_n = try productFinite(retained_fraction, organic_n_before),
        .remaining_organic_phosphorus_g_p = try productFinite(retained_fraction, organic_p_before),
        .remaining_charcoal_carbon_g_c = try productFinite(retained_fraction, charcoal_c_before),
        .remaining_charcoal_nitrogen_g_n = try productFinite(retained_fraction, charcoal_n_before),
        .remaining_charcoal_phosphorus_g_p = try productFinite(retained_fraction, charcoal_p_before),
        .heat_output_megajoules = undefined,
    };
    const remaining_dry_carbon_g_c = try addFinite(
        accounting.remaining_organic_carbon_g_c,
        accounting.remaining_charcoal_carbon_g_c,
    );
    const dry_carbon_loss_g_c =
        inputs.dry_organic_carbon_before_g_c - remaining_dry_carbon_g_c;
    if (!std.math.isFinite(dry_carbon_loss_g_c) or dry_carbon_loss_g_c < 0)
        return error.InconsistentSurfaceOrganicCarbon;
    var result = accounting;
    result.heat_output_megajoules = try productFinite(
        try productFinite(
            inputs.dry_organic_heat_capacity_megajoules_per_g_c_k,
            dry_carbon_loss_g_c,
        ),
        inputs.surface_temperature_k,
    );

    scale(pools.organic_carbon_g_c, retained_fraction);
    scale(pools.organic_nitrogen_g_n, retained_fraction);
    scale(pools.organic_phosphorus_g_p, retained_fraction);
    scale(pools.charcoal_carbon_g_c, retained_fraction);
    scale(pools.charcoal_nitrogen_g_n, retained_fraction);
    scale(pools.charcoal_phosphorus_g_p, retained_fraction);
    scale(pools.colonized_structural_carbon_g_c, retained_fraction);
    scale(pools.counted_mineral_nitrogen_g_n, retained_fraction);
    scale(pools.counted_phosphate_phosphorus_g_p, retained_fraction);
    scale(pools.other_scaled_nitrogen_g_n, retained_fraction);
    return result;
}

/// Every target receives the same accepted external transfer. Empty target
/// lists are legal for focused callers; production binds both cumulative and
/// per-cell/day ledgers here so no half-published closeout is observable.
pub const LedgerTargets = struct {
    carbon_output_g_c: []const *f64 = &.{},
    nitrogen_output_g_n: []const *f64 = &.{},
    phosphorus_output_g_p: []const *f64 = &.{},
    heat_output_megajoules: []const *f64 = &.{},
    dissolved_carbon_output_g_c: []const *f64 = &.{},
    dissolved_nitrogen_output_g_n: []const *f64 = &.{},
    dissolved_phosphorus_output_g_p: []const *f64 = &.{},
    net_biome_productivity_g_c: []const *f64 = &.{},
};

pub const RuntimeContext = struct {
    surface_organic: *Organic.State,
    surface_chemistry: *Chemistry.State,
    surface_fertilizer: *Fertilizer.State,
    surface_denitrification: *Denitrification.State,
    surface_geometry: *GeometryState,
    litter_water_m3: []const f64,
    litter_ice_m3: []const f64,
    /// `ZEROS2(NY,NX)=ZERO2*DH(NY,NX)*DV(NY,NX)` (`starts.f:270`) per-cell
    /// footprint. issue-064 sibling: floors `litter_water_m3` before it
    /// carries the litter aqueous N/P concentration below, mirroring the
    /// already-fixed `landscape_mass_inventory_surface.zig`/`metabolism_state_update.zig`
    /// siblings (issue-061) instead of substituting the dry reference only
    /// at exact zero.
    cell_area_m2: []const f64,
    surface_temperature_k: []const f64,
    geometry_parameters: Geometry.Parameters,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    dry_organic_heat_capacity_megajoules_per_g_c_k: f64 = 2.496e-6,
    ice_density_megagrams_per_m3: f64 = 0.917,
    ledgers: LedgerTargets = .{},
};

pub const RuntimeAccounting = struct {
    carbon_output_g_c: f64,
    nitrogen_output_g_n: f64,
    phosphorus_output_g_p: f64,
    heat_output_megajoules: f64,
    remaining_organic_carbon_g_c: f64,
    remaining_organic_nitrogen_g_n: f64,
    remaining_organic_phosphorus_g_p: f64,
    remaining_charcoal_carbon_g_c: f64,
    remaining_charcoal_nitrogen_g_n: f64,
    remaining_charcoal_phosphorus_g_p: f64,
};

const ElementTotals = struct {
    remaining_c: f64 = 0,
    remaining_n: f64 = 0,
    remaining_p: f64 = 0,
    removed_c: f64 = 0,
    removed_n: f64 = 0,
    removed_p: f64 = 0,
    charcoal_remaining_c: f64 = 0,
    charcoal_remaining_n: f64 = 0,
    charcoal_remaining_p: f64 = 0,
};

/// Applies operation 21 directly to the authoritative runtime owners. Organic
/// traversal follows REDIST 11121--11227: a complete microbial K sweep first,
/// then residue/mobile/structural K sweeps. The stale legacy destination `L`
/// is deliberately corrected to the selected surface cell. All donor losses,
/// including adsorbed acetate, exchangeable NH4 and undissolved fertilizer,
/// are derived from before/after inventories and reach the external ledger.
/// Legacy OQ*H are macropore DOM, not another chemistry sorption family. They
/// start at zero at the surface, and the current runtime has no surface
/// macropore-DOM producer; soil OQ*H are owned by organic transport instead.
pub fn applyRuntimeCell(context: *RuntimeContext, cell: usize, removal_fraction: f64) !RuntimeAccounting {
    try validateRuntimeContext(context, cell, removal_fraction);
    const retained = 1 - removal_fraction;
    var totals: ElementTotals = .{};

    // Source pass 1: OMC/OMN/OMP, K=0..2, N=0..6, M=1..3.
    for (0..litter_substrate_count) |substrate| for (0..Organic.microbial_population_count) |population| for (0..Organic.kinetic_fraction_count) |fraction| {
        const index = ((cell * Organic.microbial_substrate_count + substrate) * Organic.microbial_population_count + population) * Organic.kinetic_fraction_count + fraction;
        try accumulatePool(context.surface_organic.microbial[index], removal_fraction, false, &totals);
    };
    // Source pass 2: OR*, OQ*, OH*, then OS*, all K=0..2. Surface OQ*H
    // remain source-zero until a surface macropore-DOM producer is bound.
    for (0..litter_substrate_count) |substrate| {
        for (0..Organic.residue_fraction_count) |fraction| {
            const index = (cell * Organic.substrate_count + substrate) * Organic.residue_fraction_count + fraction;
            try accumulatePool(context.surface_organic.residue[index], removal_fraction, false, &totals);
        }
        const mobile = cell * Organic.substrate_count + substrate;
        try accumulatePool(context.surface_organic.dissolved[mobile], removal_fraction, false, &totals);
        try accumulateCarbon(context.surface_organic.dissolved_acetate_carbon_g_c[mobile], removal_fraction, false, &totals);
        try accumulatePool(context.surface_organic.adsorbed[mobile], removal_fraction, false, &totals);
        // REDIST omitted this donor loss from OC. Production books the actual
        // before/after loss so acetate cannot disappear from the C balance.
        try accumulateCarbon(context.surface_organic.adsorbed_acetate_carbon_g_c[mobile], removal_fraction, false, &totals);
        for (0..Organic.structural_fraction_count) |fraction| {
            const index = (cell * Organic.substrate_count + substrate) * Organic.structural_fraction_count + fraction;
            try accumulatePool(context.surface_organic.structural[index], removal_fraction, fraction == Organic.structural_fraction_count - 1, &totals);
            const colonized = context.surface_organic.colonized_structural_carbon_g_c[index];
            if (!std.math.isFinite(colonized) or colonized < 0 or !std.math.isFinite(colonized * retained)) return error.InvalidSurfaceLitterRemovalPool;
        }
    }

    var carbon_by_pool: [Geometry.source_pool_count]f64 = undefined;
    for (&carbon_by_pool, 0..) |*value, substrate| {
        const before = try context.surface_organic.substrateCarbon_g_c(cell, substrate);
        value.* = if (substrate < litter_substrate_count) before * retained else before;
    }
    var charcoal_after_g_c: f64 = 0;
    for (0..Organic.substrate_count) |substrate| {
        const index = (cell * Organic.substrate_count + substrate) * Organic.structural_fraction_count + Organic.structural_fraction_count - 1;
        const before = context.surface_organic.structural[index].carbon_g_c;
        charcoal_after_g_c += if (substrate < litter_substrate_count) before * retained else before;
    }
    var geometry_next = try Geometry.calculate(.{
        .carbon_by_pool_g_c = carbon_by_pool,
        .signed_charcoal_change_g_c = 0,
        .water_m3 = context.litter_water_m3[cell],
        .ice_m3 = context.litter_ice_m3[cell] / context.ice_density_megagrams_per_m3,
    }, context.geometry_parameters);
    // Operation 21 does not raise source IFLGS. FC/WP remain at the accepted
    // HOUR1 values while the next REDIST cycle still advances ORGCCX.
    geometry_next.field_capacity_m3_per_m3 = context.surface_geometry.field_capacity_m3_per_m3[cell];
    geometry_next.wilting_point_m3_per_m3 = context.surface_geometry.wilting_point_m3_per_m3[cell];

    const old_dry_mass = context.surface_geometry.dry_mass_megagrams[cell];
    const new_dry_mass = geometry_next.dry_mass_megagrams;
    var chemistry_next = context.surface_chemistry.cells[cell];
    var fertilizer_next = context.surface_fertilizer.cells[cell];
    // issue-064 sibling: floor at `ZEROS2`, not exact zero (see the field
    // doc comment on `RuntimeContext.cell_area_m2` above).
    const negligible_water_volume_m3 = legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(context.cell_area_m2[cell]);
    const aqueous_carrier = if (context.litter_water_m3[cell] > negligible_water_volume_m3) context.litter_water_m3[cell] else context.surface_chemistry.dry_reference_water_m3[cell];
    const aqueous_n_before_mol = aqueous_carrier * (chemistry_next.ammonium_mol_per_m3 + chemistry_next.ammonia_mol_per_m3 + chemistry_next.nitrate_mol_per_m3);
    const phosphate_before_mol = aqueous_carrier * (chemistry_next.hpo4_mol_p_per_m3 + chemistry_next.h2po4_mol_p_per_m3);
    const exchange_ammonium_before_mol = old_dry_mass * chemistry_next.exchange.ammonium_mol_per_megagram;
    const fertilizer_before_mol = fertilizer_next.ammonium_mol_n + fertilizer_next.ammonia_mol_n + fertilizer_next.urea_mol_n + fertilizer_next.nitrate_mol_n;
    const nitrite_before_g_n = context.surface_denitrification.nitrite_g_n[cell];

    chemistry_next.ammonium_mol_per_m3 *= retained;
    chemistry_next.ammonia_mol_per_m3 *= retained;
    chemistry_next.nitrate_mol_per_m3 *= retained;
    chemistry_next.hpo4_mol_p_per_m3 *= retained;
    chemistry_next.h2po4_mol_p_per_m3 *= retained;
    // Preserve every other dry-mass-normalized chemistry inventory across the
    // geometry change. XN4 alone is a reference removal pool and is overridden.
    if (old_dry_mass > 0 and new_dry_mass > 0) {
        const rebase = old_dry_mass / new_dry_mass;
        scaleNumericStruct(@TypeOf(chemistry_next.exchange), &chemistry_next.exchange, rebase);
        scaleNumericStruct(@TypeOf(chemistry_next.phosphate_surface), &chemistry_next.phosphate_surface, rebase);
        chemistry_next.carboxyl_hydrogen_mol_per_megagram *= rebase;
        chemistry_next.exchange.ammonium_mol_per_megagram = exchange_ammonium_before_mol * retained / new_dry_mass;
    } else if (exchange_ammonium_before_mol != 0) return error.SurfaceLitterRemovalMissingDryMassCarrier;
    fertilizer_next.ammonium_mol_n *= retained;
    fertilizer_next.ammonia_mol_n *= retained;
    fertilizer_next.urea_mol_n *= retained;
    fertilizer_next.nitrate_mol_n *= retained;

    const mineral_n_output = removal_fraction * (context.nitrogen_g_per_mol * (aqueous_n_before_mol + exchange_ammonium_before_mol + fertilizer_before_mol) + nitrite_before_g_n);
    const mineral_p_output = removal_fraction * context.phosphorus_g_per_mol * phosphate_before_mol;
    const carbon_output = totals.removed_c;
    const nitrogen_output = try addFinite(totals.removed_n, mineral_n_output);
    const phosphorus_output = try addFinite(totals.removed_p, mineral_p_output);
    const heat_output = try productFinite(
        context.dry_organic_heat_capacity_megajoules_per_g_c_k,
        try productFinite(carbon_output, context.surface_temperature_k[cell]),
    );
    const nitrite_next_g_n = nitrite_before_g_n * retained;
    if (!std.math.isFinite(nitrite_next_g_n) or nitrite_next_g_n < 0) return error.SurfaceLitterRemovalAccountingOverflow;
    try validateLedgerTargets(context.ledgers, carbon_output, nitrogen_output, phosphorus_output, heat_output);

    // Commit is intentionally non-fallible after all owners and targets pass.
    for (0..litter_substrate_count) |substrate| for (0..Organic.microbial_population_count) |population| for (0..Organic.kinetic_fraction_count) |fraction| {
        const index = ((cell * Organic.microbial_substrate_count + substrate) * Organic.microbial_population_count + population) * Organic.kinetic_fraction_count + fraction;
        scaleElementPool(&context.surface_organic.microbial[index], retained);
    };
    for (0..litter_substrate_count) |substrate| {
        for (0..Organic.residue_fraction_count) |fraction| {
            const index = (cell * Organic.substrate_count + substrate) * Organic.residue_fraction_count + fraction;
            scaleElementPool(&context.surface_organic.residue[index], retained);
        }
        const mobile = cell * Organic.substrate_count + substrate;
        scaleElementPool(&context.surface_organic.dissolved[mobile], retained);
        context.surface_organic.dissolved_acetate_carbon_g_c[mobile] *= retained;
        scaleElementPool(&context.surface_organic.adsorbed[mobile], retained);
        context.surface_organic.adsorbed_acetate_carbon_g_c[mobile] *= retained;
        for (0..Organic.structural_fraction_count) |fraction| {
            const index = (cell * Organic.substrate_count + substrate) * Organic.structural_fraction_count + fraction;
            scaleElementPool(&context.surface_organic.structural[index], retained);
            context.surface_organic.colonized_structural_carbon_g_c[index] *= retained;
        }
    }
    context.surface_chemistry.cells[cell] = chemistry_next;
    context.surface_fertilizer.cells[cell] = fertilizer_next;
    context.surface_denitrification.nitrite_g_n[cell] = nitrite_next_g_n;
    inline for (@typeInfo(Geometry.Result).@"struct".fields) |field|
        @field(context.surface_geometry, field.name)[cell] = @field(geometry_next, field.name);
    addToTargets(context.ledgers.carbon_output_g_c, carbon_output);
    addToTargets(context.ledgers.nitrogen_output_g_n, nitrogen_output);
    addToTargets(context.ledgers.phosphorus_output_g_p, phosphorus_output);
    addToTargets(context.ledgers.heat_output_megajoules, heat_output);
    addToTargets(context.ledgers.dissolved_carbon_output_g_c, carbon_output);
    addToTargets(context.ledgers.dissolved_nitrogen_output_g_n, nitrogen_output);
    addToTargets(context.ledgers.dissolved_phosphorus_output_g_p, phosphorus_output);
    subtractFromTargets(context.ledgers.net_biome_productivity_g_c, carbon_output);
    return .{
        .carbon_output_g_c = carbon_output,
        .nitrogen_output_g_n = nitrogen_output,
        .phosphorus_output_g_p = phosphorus_output,
        .heat_output_megajoules = heat_output,
        .remaining_organic_carbon_g_c = totals.remaining_c,
        .remaining_organic_nitrogen_g_n = totals.remaining_n,
        .remaining_organic_phosphorus_g_p = totals.remaining_p,
        .remaining_charcoal_carbon_g_c = totals.charcoal_remaining_c,
        .remaining_charcoal_nitrogen_g_n = totals.charcoal_remaining_n,
        .remaining_charcoal_phosphorus_g_p = totals.charcoal_remaining_p,
    };
}

fn validateRuntimeContext(context: *const RuntimeContext, cell: usize, removal_fraction: f64) !void {
    const cells = context.surface_organic.layer_count;
    const microbial_count = std.math.mul(usize, cells, Organic.microbial_substrate_count * Organic.microbial_population_count * Organic.kinetic_fraction_count) catch return error.SurfaceLitterRemovalDimensionMismatch;
    const residue_count = std.math.mul(usize, cells, Organic.substrate_count * Organic.residue_fraction_count) catch return error.SurfaceLitterRemovalDimensionMismatch;
    const mobile_count = std.math.mul(usize, cells, Organic.substrate_count) catch return error.SurfaceLitterRemovalDimensionMismatch;
    const structural_count = std.math.mul(usize, cells, Organic.substrate_count * Organic.structural_fraction_count) catch return error.SurfaceLitterRemovalDimensionMismatch;
    if (cells == 0 or cell >= cells or context.surface_chemistry.cells.len != cells or
        context.surface_chemistry.mineral_reference_water_m3.len != cells or
        context.surface_chemistry.dry_reference_water_m3.len != cells or
        context.surface_fertilizer.cells.len != cells or context.surface_fertilizer.formulation.len != cells or
        context.surface_denitrification.cell_count != cells or context.surface_denitrification.nitrite_g_n.len != cells or
        context.surface_geometry.cell_count != cells or context.litter_water_m3.len != cells or
        context.litter_ice_m3.len != cells or context.cell_area_m2.len != cells or context.surface_temperature_k.len != cells or
        context.surface_organic.microbial.len != microbial_count or context.surface_organic.residue.len != residue_count or
        context.surface_organic.dissolved.len != mobile_count or context.surface_organic.adsorbed.len != mobile_count or
        context.surface_organic.dissolved_acetate_carbon_g_c.len != mobile_count or
        context.surface_organic.adsorbed_acetate_carbon_g_c.len != mobile_count or
        context.surface_organic.structural.len != structural_count or
        context.surface_organic.colonized_structural_carbon_g_c.len != structural_count)
        return error.SurfaceLitterRemovalDimensionMismatch;
    inline for (@typeInfo(GeometryState).@"struct".fields) |field| if (field.type == []f64 and @field(context.surface_geometry.*, field.name).len != cells)
        return error.SurfaceLitterRemovalDimensionMismatch;
    inline for (.{ removal_fraction, context.nitrogen_g_per_mol, context.phosphorus_g_per_mol, context.dry_organic_heat_capacity_megajoules_per_g_c_k, context.litter_water_m3[cell], context.litter_ice_m3[cell], context.cell_area_m2[cell], context.surface_temperature_k[cell], context.surface_geometry.dry_mass_megagrams[cell], context.surface_chemistry.dry_reference_water_m3[cell] }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSurfaceLitterRemovalInput;
    if (removal_fraction < 0 or removal_fraction > 0.999 or context.nitrogen_g_per_mol <= 0 or
        context.phosphorus_g_per_mol <= 0 or context.dry_organic_heat_capacity_megajoules_per_g_c_k <= 0 or
        context.litter_water_m3[cell] < 0 or context.litter_ice_m3[cell] < 0 or context.cell_area_m2[cell] <= 0 or context.surface_temperature_k[cell] <= 0 or
        context.surface_geometry.dry_mass_megagrams[cell] < 0 or context.surface_chemistry.dry_reference_water_m3[cell] < 0)
        return error.InvalidSurfaceLitterRemovalInput;
    try validateNumericStruct(Chemistry.Cell, context.surface_chemistry.cells[cell]);
    try validateNumericStruct(Fertilizer.Inventory, context.surface_fertilizer.cells[cell]);
    if (!std.math.isFinite(context.surface_denitrification.nitrite_g_n[cell]) or context.surface_denitrification.nitrite_g_n[cell] < 0)
        return error.InvalidSurfaceLitterRemovalPool;
}

fn accumulatePool(pool: Organic.ElementPool, removal_fraction: f64, charcoal: bool, totals: *ElementTotals) !void {
    inline for (.{ pool.carbon_g_c, pool.nitrogen_g_n, pool.phosphorus_g_p }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceLitterRemovalPool;
    const remaining_c = try productFinite(1 - removal_fraction, pool.carbon_g_c);
    const remaining_n = try productFinite(1 - removal_fraction, pool.nitrogen_g_n);
    const remaining_p = try productFinite(1 - removal_fraction, pool.phosphorus_g_p);
    totals.removed_c = try addFinite(totals.removed_c, try productFinite(removal_fraction, pool.carbon_g_c));
    totals.removed_n = try addFinite(totals.removed_n, try productFinite(removal_fraction, pool.nitrogen_g_n));
    totals.removed_p = try addFinite(totals.removed_p, try productFinite(removal_fraction, pool.phosphorus_g_p));
    if (charcoal) {
        totals.charcoal_remaining_c = try addFinite(totals.charcoal_remaining_c, remaining_c);
        totals.charcoal_remaining_n = try addFinite(totals.charcoal_remaining_n, remaining_n);
        totals.charcoal_remaining_p = try addFinite(totals.charcoal_remaining_p, remaining_p);
    } else {
        totals.remaining_c = try addFinite(totals.remaining_c, remaining_c);
        totals.remaining_n = try addFinite(totals.remaining_n, remaining_n);
        totals.remaining_p = try addFinite(totals.remaining_p, remaining_p);
    }
}

fn accumulateCarbon(value: f64, removal_fraction: f64, charcoal: bool, totals: *ElementTotals) !void {
    if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceLitterRemovalPool;
    totals.removed_c = try addFinite(totals.removed_c, try productFinite(removal_fraction, value));
    const remaining = try productFinite(1 - removal_fraction, value);
    if (charcoal)
        totals.charcoal_remaining_c = try addFinite(totals.charcoal_remaining_c, remaining)
    else
        totals.remaining_c = try addFinite(totals.remaining_c, remaining);
}

fn scaleElementPool(pool: *Organic.ElementPool, retained: f64) void {
    inline for (std.meta.fields(Organic.ElementPool)) |field| @field(pool.*, field.name) *= retained;
}

fn scaleNumericStruct(comptime T: type, value: *T, scale_factor: f64) void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => @field(value, field.name) *= scale_factor,
        .@"struct" => scaleNumericStruct(field.type, &@field(value, field.name), scale_factor),
        else => @compileError("surface litter removal chemistry must be numeric"),
    };
}

fn validateNumericStruct(comptime T: type, value: T) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => {
            const number = @field(value, field.name);
            if (!std.math.isFinite(number) or number < 0) return error.InvalidSurfaceLitterRemovalPool;
        },
        .@"struct" => try validateNumericStruct(field.type, @field(value, field.name)),
        else => @compileError("surface litter removal chemistry must be numeric"),
    };
}

fn validateLedgerTargets(targets: LedgerTargets, carbon: f64, nitrogen: f64, phosphorus: f64, heat: f64) !void {
    const additions = .{
        .{ targets.carbon_output_g_c, carbon },
        .{ targets.nitrogen_output_g_n, nitrogen },
        .{ targets.phosphorus_output_g_p, phosphorus },
        .{ targets.heat_output_megajoules, heat },
        .{ targets.dissolved_carbon_output_g_c, carbon },
        .{ targets.dissolved_nitrogen_output_g_n, nitrogen },
        .{ targets.dissolved_phosphorus_output_g_p, phosphorus },
    };
    inline for (additions) |entry| for (entry[0]) |target| {
        if (!std.math.isFinite(target.*)) return error.SurfaceLitterRemovalAccountingOverflow;
        var next = target.*;
        inline for (additions) |other| for (other[0]) |other_target| {
            if (other_target == target) next += other[1];
        };
        for (targets.net_biome_productivity_g_c) |other_target| {
            if (other_target == target) next -= carbon;
        }
        if (!std.math.isFinite(next)) return error.SurfaceLitterRemovalAccountingOverflow;
    };
    for (targets.net_biome_productivity_g_c) |target| {
        if (!std.math.isFinite(target.*)) return error.SurfaceLitterRemovalAccountingOverflow;
        var next = target.*;
        inline for (additions) |other| for (other[0]) |other_target| {
            if (other_target == target) next += other[1];
        };
        for (targets.net_biome_productivity_g_c) |other_target| {
            if (other_target == target) next -= carbon;
        }
        if (!std.math.isFinite(next)) return error.SurfaceLitterRemovalAccountingOverflow;
    }
}

fn addToTargets(targets: []const *f64, delta: f64) void {
    for (targets) |target| target.* += delta;
}

fn subtractFromTargets(targets: []const *f64, delta: f64) void {
    for (targets) |target| target.* -= delta;
}

fn validateInputs(inputs: Inputs) !void {
    inline for (.{
        inputs.removal_fraction,
        inputs.surface_temperature_k,
        inputs.dry_organic_carbon_before_g_c,
        inputs.dry_organic_heat_capacity_megajoules_per_g_c_k,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteSurfaceLitterRemovalInput;
    if (inputs.removal_fraction < 0 or inputs.removal_fraction > 0.999)
        return error.InvalidSurfaceLitterRemovalFraction;
    if (inputs.surface_temperature_k <= 0 or
        inputs.dry_organic_carbon_before_g_c < 0 or
        inputs.dry_organic_heat_capacity_megajoules_per_g_c_k <= 0)
        return error.InvalidSurfaceLitterRemovalInput;
}

fn validatePool(pool: []const f64) !void {
    for (pool) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidSurfaceLitterRemovalPool;
}

fn sumFinite(values: []const f64) !f64 {
    var total: f64 = 0;
    for (values) |value| {
        total += value;
        if (!std.math.isFinite(total))
            return error.SurfaceLitterRemovalAccountingOverflow;
    }
    return total;
}

fn addFinite(a: f64, b: f64) !f64 {
    const result = a + b;
    if (!std.math.isFinite(result))
        return error.SurfaceLitterRemovalAccountingOverflow;
    return result;
}

fn productFinite(a: f64, b: f64) !f64 {
    const result = a * b;
    if (!std.math.isFinite(result))
        return error.SurfaceLitterRemovalAccountingOverflow;
    return result;
}

fn scale(values: []f64, retained_fraction: f64) void {
    for (values) |*value| value.* *= retained_fraction;
}

test "operation 21 scales arbitrary runtime pools and accounts C N P heat" {
    var organic_c = [_]f64{ 10, 20, 30, 40 };
    var organic_n = [_]f64{ 1, 2, 3 };
    var organic_p = [_]f64{ 0.5, 1.5 };
    var charcoal_c = [_]f64{50};
    var charcoal_n = [_]f64{5};
    var charcoal_p = [_]f64{2};
    var colonized_c = [_]f64{ 8, 12 };
    var mineral_n = [_]f64{ 4, 6, 8, 2 };
    var mineral_p = [_]f64{ 3, 7 };
    var other_n = [_]f64{ 9, 11, 13, 17, 19 };
    const result = try apply(.{
        .organic_carbon_g_c = &organic_c,
        .organic_nitrogen_g_n = &organic_n,
        .organic_phosphorus_g_p = &organic_p,
        .charcoal_carbon_g_c = &charcoal_c,
        .charcoal_nitrogen_g_n = &charcoal_n,
        .charcoal_phosphorus_g_p = &charcoal_p,
        .colonized_structural_carbon_g_c = &colonized_c,
        .counted_mineral_nitrogen_g_n = &mineral_n,
        .counted_phosphate_phosphorus_g_p = &mineral_p,
        .other_scaled_nitrogen_g_n = &other_n,
    }, .{
        .removal_fraction = 0.25,
        .surface_temperature_k = 300,
        .dry_organic_carbon_before_g_c = 150,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 37.5), result.carbon_output_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 7.75), result.nitrogen_output_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), result.phosphorus_output_g_p, 1e-12);
    try std.testing.expectApproxEqAbs(
        2.496e-6 * 37.5 * 300,
        result.heat_output_megajoules,
        1e-14,
    );
    try std.testing.expectEqual(@as(f64, 7.5), organic_c[0]);
    try std.testing.expectEqual(@as(f64, 37.5), charcoal_c[0]);
    try std.testing.expectEqual(@as(f64, 6), colonized_c[0]);
    try std.testing.expectEqual(@as(f64, 3), mineral_n[0]);
    try std.testing.expectEqual(@as(f64, 6.75), other_n[0]);
}

test "late invalid pool rolls back every operation 21 owner" {
    var organic_c = [_]f64{ 10, 20 };
    const organic_c_before = organic_c;
    var empty = [_]f64{};
    var other_n = [_]f64{ 1, std.math.nan(f64) };
    try std.testing.expectError(
        error.InvalidSurfaceLitterRemovalPool,
        apply(.{
            .organic_carbon_g_c = &organic_c,
            .organic_nitrogen_g_n = &empty,
            .organic_phosphorus_g_p = &empty,
            .charcoal_carbon_g_c = &empty,
            .charcoal_nitrogen_g_n = &empty,
            .charcoal_phosphorus_g_p = &empty,
            .colonized_structural_carbon_g_c = &empty,
            .counted_mineral_nitrogen_g_n = &empty,
            .counted_phosphate_phosphorus_g_p = &empty,
            .other_scaled_nitrogen_g_n = &other_n,
        }, .{
            .removal_fraction = 0.5,
            .surface_temperature_k = 290,
            .dry_organic_carbon_before_g_c = 30,
        }),
    );
    try std.testing.expectEqualSlices(f64, &organic_c_before, &organic_c);
    try std.testing.expectEqual(@as(f64, 1), other_n[0]);
    try std.testing.expect(std.math.isNan(other_n[1]));
}

test "inconsistent heat baseline fails before pool mutation" {
    var organic_c = [_]f64{100};
    var empty = [_]f64{};
    try std.testing.expectError(
        error.InconsistentSurfaceOrganicCarbon,
        apply(.{
            .organic_carbon_g_c = &organic_c,
            .organic_nitrogen_g_n = &empty,
            .organic_phosphorus_g_p = &empty,
            .charcoal_carbon_g_c = &empty,
            .charcoal_nitrogen_g_n = &empty,
            .charcoal_phosphorus_g_p = &empty,
            .colonized_structural_carbon_g_c = &empty,
            .counted_mineral_nitrogen_g_n = &empty,
            .counted_phosphate_phosphorus_g_p = &empty,
            .other_scaled_nitrogen_g_n = &empty,
        }, .{
            .removal_fraction = 0.1,
            .surface_temperature_k = 290,
            .dry_organic_carbon_before_g_c = 50,
        }),
    );
    try std.testing.expectEqual(@as(f64, 100), organic_c[0]);
}

fn testGeometryParameters() Geometry.Parameters {
    return .{
        .water_retention_m3_per_g_c = .{ 2e-6, 5e-6, 5e-6, 5e-6, 5e-6 },
        .dry_bulk_density_megagrams_per_m3 = .{ 0.1, 0.0125, 0.025, 0.025, 0.025 },
        .dry_mass_megagrams_per_g_c = 1.82e-6,
        .particle_density_megagrams_per_m3 = 1.3,
        .field_capacity_fraction_of_porosity = 0.5,
        .wilting_point_fraction_of_porosity = 0.25,
    };
}

fn refreshTestGeometry(state: *GeometryState, organic: *const Organic.State, water: f64, ice: f64) !void {
    var carbon: [Geometry.source_pool_count]f64 = undefined;
    for (&carbon, 0..) |*value, substrate| {
        value.* = try organic.substrateCarbon_g_c(0, substrate);
    }
    const current_charcoal = try organic.charcoalCarbon_g_c(0);
    const value = try Geometry.calculate(.{
        .carbon_by_pool_g_c = carbon,
        .signed_charcoal_change_g_c = 0,
        .water_m3 = water,
        .ice_m3 = ice,
    }, testGeometryParameters());
    inline for (@typeInfo(Geometry.Result).@"struct".fields) |field| @field(state, field.name)[0] = @field(value, field.name);
    state.previous_charcoal_carbon_g_c[0] = current_charcoal;
    state.retention_refresh_pending[0] = 0;
}

test "runtime operation 21 maps acetate fertilizer and ledgers conservatively" {
    var organic = try Organic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var chemistry = try Chemistry.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    var fertilizer = try Fertilizer.State.init(std.testing.allocator, 1);
    defer fertilizer.deinit();
    var denitrification = try Denitrification.State.init(std.testing.allocator, 1);
    defer denitrification.deinit();
    var geometry = try GeometryState.init(std.testing.allocator, 1);
    defer geometry.deinit();

    organic.microbial[0] = .{ .carbon_g_c = 8, .nitrogen_g_n = 4, .phosphorus_g_p = 2 };
    organic.dissolved[0] = .{ .carbon_g_c = 10, .nitrogen_g_n = 2, .phosphorus_g_p = 1 };
    organic.adsorbed_acetate_carbon_g_c[0] = 2;
    organic.structural[Organic.structural_fraction_count - 1] = .{ .carbon_g_c = 5, .nitrogen_g_n = 1, .phosphorus_g_p = 0.5 };
    organic.colonized_structural_carbon_g_c[Organic.structural_fraction_count - 1] = 1;
    try refreshTestGeometry(&geometry, &organic, 2, 0);

    chemistry.cells[0].ammonium_mol_per_m3 = 1;
    chemistry.cells[0].ammonia_mol_per_m3 = 0.5;
    chemistry.cells[0].nitrate_mol_per_m3 = 0.25;
    chemistry.cells[0].hpo4_mol_p_per_m3 = 0.2;
    chemistry.cells[0].h2po4_mol_p_per_m3 = 0.3;
    chemistry.cells[0].exchange.ammonium_mol_per_megagram = 2;
    chemistry.cells[0].exchange.calcium_mol_per_megagram = 3;
    fertilizer.cells[0].ammonium_mol_n = 1;
    fertilizer.cells[0].ammonia_mol_n = 2;
    fertilizer.cells[0].urea_mol_n = 3;
    fertilizer.cells[0].nitrate_mol_n = 4;
    denitrification.nitrite_g_n[0] = 14;
    const organic_before_c = try organic.totalCarbon_g_c(0);
    const old_dry_mass = geometry.dry_mass_megagrams[0];
    const exchange_before_mol = old_dry_mass * chemistry.cells[0].exchange.ammonium_mol_per_megagram;
    const calcium_before_mol = old_dry_mass * chemistry.cells[0].exchange.calcium_mol_per_megagram;

    var carbon_ledger: f64 = 0;
    var nitrogen_ledger: f64 = 0;
    var phosphorus_ledger: f64 = 0;
    var heat_ledger: f64 = 0;
    var doc_ledger: f64 = 0;
    var don_ledger: f64 = 0;
    var dop_ledger: f64 = 0;
    var nbp: f64 = 100;
    var context: RuntimeContext = .{
        .surface_organic = &organic,
        .surface_chemistry = &chemistry,
        .surface_fertilizer = &fertilizer,
        .surface_denitrification = &denitrification,
        .surface_geometry = &geometry,
        .litter_water_m3 = &.{2},
        .litter_ice_m3 = &.{0},
        .cell_area_m2 = &.{1},
        .surface_temperature_k = &.{300},
        .geometry_parameters = testGeometryParameters(),
        .nitrogen_g_per_mol = 14,
        .phosphorus_g_per_mol = 31,
        .ledgers = .{
            .carbon_output_g_c = &.{&carbon_ledger},
            .nitrogen_output_g_n = &.{&nitrogen_ledger},
            .phosphorus_output_g_p = &.{&phosphorus_ledger},
            .heat_output_megajoules = &.{&heat_ledger},
            .dissolved_carbon_output_g_c = &.{&doc_ledger},
            .dissolved_nitrogen_output_g_n = &.{&don_ledger},
            .dissolved_phosphorus_output_g_p = &.{&dop_ledger},
            .net_biome_productivity_g_c = &.{&nbp},
        },
    };
    const result = try applyRuntimeCell(&context, 0, 0.25);
    const organic_after_c = try organic.totalCarbon_g_c(0);
    try std.testing.expectApproxEqAbs(organic_before_c, organic_after_c + result.carbon_output_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 6.25), result.carbon_output_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), organic.adsorbed_acetate_carbon_g_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(exchange_before_mol * 0.75, geometry.dry_mass_megagrams[0] * chemistry.cells[0].exchange.ammonium_mol_per_megagram, 1e-15);
    try std.testing.expectApproxEqAbs(calcium_before_mol, geometry.dry_mass_megagrams[0] * chemistry.cells[0].exchange.calcium_mol_per_megagram, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), fertilizer.cells[0].ammonium_mol_n, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), denitrification.nitrite_g_n[0], 1e-15);
    try std.testing.expectEqual(result.carbon_output_g_c, carbon_ledger);
    try std.testing.expectEqual(result.carbon_output_g_c, doc_ledger);
    try std.testing.expectEqual(result.nitrogen_output_g_n, nitrogen_ledger);
    try std.testing.expectEqual(result.nitrogen_output_g_n, don_ledger);
    try std.testing.expectEqual(result.phosphorus_output_g_p, phosphorus_ledger);
    try std.testing.expectEqual(result.phosphorus_output_g_p, dop_ledger);
    try std.testing.expectEqual(result.heat_output_megajoules, heat_ledger);
    try std.testing.expectEqual(100 - result.carbon_output_g_c, nbp);
}

test "issue-064 sibling: surface litter removal floors the aqueous carrier at the ZEROS2 floor instead of exact zero" {
    // Sibling of the already-fixed `landscape_mass_inventory_surface.zig`/
    // `metabolism_state_update.zig` (issue-061) and `phosphate_inventory.zig`
    // (issue-064) litter-water-carrier guards: this REDIST operation 21
    // production commit path had its own, previously-unaudited exact-zero-
    // only guard on the same collapsible `litter_water_m3` array, feeding
    // the mineral N/P mass this transaction actually removes from the model
    // and books to the external ledger.
    var organic = try Organic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var chemistry = try Chemistry.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    var fertilizer = try Fertilizer.State.init(std.testing.allocator, 1);
    defer fertilizer.deinit();
    var denitrification = try Denitrification.State.init(std.testing.allocator, 1);
    defer denitrification.deinit();
    var geometry = try GeometryState.init(std.testing.allocator, 1);
    defer geometry.deinit();
    organic.dissolved[0].carbon_g_c = 100;
    try refreshTestGeometry(&geometry, &organic, 2, 0);
    chemistry.cells[0].hpo4_mol_p_per_m3 = 10;
    chemistry.dry_reference_water_m3[0] = 0.5;

    var carbon_ledger: f64 = 0;
    var nitrogen_ledger: f64 = 0;
    var phosphorus_ledger: f64 = 0;
    var heat_ledger: f64 = 0;
    var context: RuntimeContext = .{
        .surface_organic = &organic,
        .surface_chemistry = &chemistry,
        .surface_fertilizer = &fertilizer,
        .surface_denitrification = &denitrification,
        .surface_geometry = &geometry,
        // Below the ZEROS2 floor for a 1 m^2 cell (1e-6 m^3), nonzero.
        .litter_water_m3 = &.{1.0e-9},
        .litter_ice_m3 = &.{0},
        .cell_area_m2 = &.{1},
        .surface_temperature_k = &.{300},
        .geometry_parameters = testGeometryParameters(),
        .nitrogen_g_per_mol = 14,
        .phosphorus_g_per_mol = 31,
        .ledgers = .{
            .carbon_output_g_c = &.{&carbon_ledger},
            .nitrogen_output_g_n = &.{&nitrogen_ledger},
            .phosphorus_output_g_p = &.{&phosphorus_ledger},
            .heat_output_megajoules = &.{&heat_ledger},
        },
    };
    const removal_fraction = 0.25;
    const result = try applyRuntimeCell(&context, 0, removal_fraction);

    // Fixed: the floored carrier substitutes the remembered dry reference
    // (0.5 m^3), not the collapsed live value, so the removed mineral P mass
    // matches the dry-reference-basis calculation.
    const expected_mineral_p_output = removal_fraction * 31 * (0.5 * 10);
    try std.testing.expectApproxEqAbs(expected_mineral_p_output, result.phosphorus_output_g_p, 1e-9);
    try std.testing.expectApproxEqAbs(expected_mineral_p_output, phosphorus_ledger, 1e-9);
    // The old, pre-fix raw-carrier guard would have used the collapsed live
    // value directly, undercounting this removal's mineral P by ~8 orders of
    // magnitude.
    const old_raw_carrier_mineral_p_output = removal_fraction * 31 * (1.0e-9 * 10);
    try std.testing.expect(result.phosphorus_output_g_p > 1e6 * old_raw_carrier_mineral_p_output);
}

test "runtime operation 21 late ledger overflow rolls back every owner" {
    var organic = try Organic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var chemistry = try Chemistry.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    var fertilizer = try Fertilizer.State.init(std.testing.allocator, 1);
    defer fertilizer.deinit();
    var denitrification = try Denitrification.State.init(std.testing.allocator, 1);
    defer denitrification.deinit();
    var geometry = try GeometryState.init(std.testing.allocator, 1);
    defer geometry.deinit();
    organic.dissolved[0].carbon_g_c = std.math.floatMax(f64) / 2;
    try refreshTestGeometry(&geometry, &organic, 1, 0);
    const organic_before = organic.dissolved[0];
    const geometry_before = geometry.dry_mass_megagrams[0];
    var overflow = std.math.floatMax(f64);
    var context: RuntimeContext = .{
        .surface_organic = &organic,
        .surface_chemistry = &chemistry,
        .surface_fertilizer = &fertilizer,
        .surface_denitrification = &denitrification,
        .surface_geometry = &geometry,
        .litter_water_m3 = &.{1},
        .litter_ice_m3 = &.{0},
        .cell_area_m2 = &.{1},
        .surface_temperature_k = &.{300},
        .geometry_parameters = testGeometryParameters(),
        .nitrogen_g_per_mol = 14,
        .phosphorus_g_per_mol = 31,
        .ledgers = .{ .carbon_output_g_c = &.{&overflow} },
    };
    try std.testing.expectError(error.SurfaceLitterRemovalAccountingOverflow, applyRuntimeCell(&context, 0, 0.5));
    try std.testing.expectEqual(organic_before, organic.dissolved[0]);
    try std.testing.expectEqual(geometry_before, geometry.dry_mass_megagrams[0]);
    try std.testing.expectEqual(std.math.floatMax(f64), overflow);
}
