const std = @import("std");

pub const source_pool_count: usize = 5;

pub const Parameters = struct {
    water_retention_m3_per_g_c: [source_pool_count]f64,
    dry_bulk_density_megagrams_per_m3: [source_pool_count]f64,
    dry_mass_megagrams_per_g_c: f64,
    particle_density_megagrams_per_m3: f64,
    field_capacity_fraction_of_porosity: f64,
    wilting_point_fraction_of_porosity: f64,
};

pub const Inputs = struct {
    carbon_by_pool_g_c: [source_pool_count]f64,
    /// REDIST/HOUR1 `DORGCC(0)`: signed charcoal change since the previous
    /// accepted disturbed-surface refresh, not the current charcoal stock.
    signed_charcoal_change_g_c: f64,
    water_m3: f64,
    ice_m3: f64,
};

pub const Result = struct {
    water_retention_capacity_m3: f64,
    dry_litter_volume_m3: f64,
    expanded_total_volume_m3: f64,
    dry_mass_megagrams: f64,
    pore_volume_m3: f64,
    air_volume_m3: f64,
    porosity_m3_per_m3: f64,
    field_capacity_m3_per_m3: f64,
    wilting_point_m3_per_m3: f64,
};

/// HOUR1 THETY/THETZ inverse of the log-log segment between field capacity
/// and wilting point. Used for hygroscopic and minimum-potential water limits.
pub fn waterFractionAtPotentialBelowWilting(field_capacity_fraction: f64, wilting_point_fraction: f64, field_capacity_potential_megapascal: f64, wilting_point_potential_megapascal: f64, target_potential_megapascal: f64) !f64 {
    inline for (.{ field_capacity_fraction, wilting_point_fraction, field_capacity_potential_megapascal, wilting_point_potential_megapascal, target_potential_megapascal }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceLitterRetentionInput;
    if (field_capacity_fraction <= wilting_point_fraction or wilting_point_fraction <= 0 or field_capacity_potential_megapascal >= 0 or wilting_point_potential_megapascal >= field_capacity_potential_megapascal or target_potential_megapascal >= wilting_point_potential_megapascal) return error.InvalidSurfaceLitterRetentionInput;
    const log_field_water = @log(field_capacity_fraction);
    const log_wilting_water = @log(wilting_point_fraction);
    const log_field_potential = @log(-field_capacity_potential_megapascal);
    const log_wilting_potential = @log(-wilting_point_potential_megapascal);
    const log_target_potential = @log(-target_potential_megapascal);
    const result = @exp((log_field_potential - log_target_potential) * (log_field_water - log_wilting_water) / (log_wilting_potential - log_field_potential) + log_field_water);
    if (!std.math.isFinite(result) or result < 0) return error.NonFiniteSurfaceLitterRetention;
    return result;
}

/// HOUR1 L=0 geometry. Pool 3 is intentionally excluded from VOLWRX/VOLR,
/// matching RC0 indices 0,1,2,4 in the source.
pub fn calculate(inputs: Inputs, parameters: Parameters) !Result {
    inline for (inputs.carbon_by_pool_g_c ++ parameters.water_retention_m3_per_g_c ++ parameters.dry_bulk_density_megagrams_per_m3) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceLitterGeometryInput;
    inline for (.{ inputs.signed_charcoal_change_g_c, inputs.water_m3, inputs.ice_m3, parameters.dry_mass_megagrams_per_g_c, parameters.particle_density_megagrams_per_m3, parameters.field_capacity_fraction_of_porosity, parameters.wilting_point_fraction_of_porosity }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceLitterGeometryInput;
    for (inputs.carbon_by_pool_g_c) |value| if (value < 0) return error.InvalidSurfaceLitterGeometryInput;
    for (parameters.water_retention_m3_per_g_c) |value| if (value < 0) return error.InvalidSurfaceLitterGeometryInput;
    for (parameters.dry_bulk_density_megagrams_per_m3) |value| if (value <= 0) return error.InvalidSurfaceLitterGeometryInput;
    if (inputs.water_m3 < 0 or inputs.ice_m3 < 0 or parameters.dry_mass_megagrams_per_g_c < 0 or parameters.particle_density_megagrams_per_m3 <= 0 or parameters.field_capacity_fraction_of_porosity < 0 or parameters.field_capacity_fraction_of_porosity > 1 or parameters.wilting_point_fraction_of_porosity < 0 or parameters.wilting_point_fraction_of_porosity > parameters.field_capacity_fraction_of_porosity) return error.InvalidSurfaceLitterGeometryInput;

    const included = [_]usize{ 0, 1, 2, 4 };
    var retention: f64 = 0;
    var dry_volume: f64 = 0;
    for (included) |pool| {
        retention += parameters.water_retention_m3_per_g_c[pool] * inputs.carbon_by_pool_g_c[pool];
        dry_volume += 1e-6 * inputs.carbon_by_pool_g_c[pool] / parameters.dry_bulk_density_megagrams_per_m3[pool];
    }
    const excess_water_and_ice = @max(0, inputs.water_m3 + inputs.ice_m3 - retention);
    const expanded_volume = dry_volume + excess_water_and_ice;
    // `carbon_by_pool_g_c` is gathered with `substrateCarbon_g_c`, which
    // already includes structural fraction 4 charcoal.  Adding the charcoal
    // stock again here double-counted it in BKVL/dry mass.
    var total_carbon: f64 = 0;
    for (inputs.carbon_by_pool_g_c) |value| total_carbon += value;
    const dry_mass = parameters.dry_mass_megagrams_per_g_c * total_carbon;
    const pore_volume = @max(0, dry_volume - dry_mass / parameters.particle_density_megagrams_per_m3);
    const air_volume = @max(0, pore_volume - inputs.water_m3 - inputs.ice_m3);
    const porosity = if (dry_volume > 0) pore_volume / dry_volume else parameters.water_retention_m3_per_g_c[1] / parameters.dry_bulk_density_megagrams_per_m3[1];
    const charcoal_volume_fraction = if (dry_volume > 0) 1e-6 * inputs.signed_charcoal_change_g_c / dry_volume else 0;
    const result: Result = .{
        .water_retention_capacity_m3 = retention,
        .dry_litter_volume_m3 = dry_volume,
        .expanded_total_volume_m3 = expanded_volume,
        .dry_mass_megagrams = dry_mass,
        .pore_volume_m3 = pore_volume,
        .air_volume_m3 = air_volume,
        .porosity_m3_per_m3 = porosity,
        .field_capacity_m3_per_m3 = parameters.field_capacity_fraction_of_porosity * porosity + charcoal_volume_fraction,
        .wilting_point_m3_per_m3 = parameters.wilting_point_fraction_of_porosity * porosity + charcoal_volume_fraction,
    };
    inline for (@typeInfo(Result).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.NonFiniteSurfaceLitterGeometry;
    return result;
}

/// HOUR1 `VOLA(0)` minus the ice it already holds: the liquid capacity left in
/// the surface litter layer's DRY pore volume.
///
/// `hour1.f:4366-4367` is the owner of this arithmetic --
/// `VOLP(0,NY,NX)=AMAX1(0.0,VOLA(0,NY,NX)-VOLW(0,NY,NX)-VOLI(0,NY,NX))`. When
/// liquid plus ice exceed the dry pore volume the oracle **clamps to zero**; it
/// does not reject the state. Three statements in that same block say the state
/// is expected rather than tolerated:
///
///   - `:4353` `TVOLG0=AMAX1(0.0,VOLW(0)+VOLI(0)-VOLWRX)` and `:4356`
///     `VOLT(0)=TVOLG0+VOLR` exist precisely to hold water and ice in excess of
///     retention: the excess **expands the layer**, it is not required to fit in
///     the dry pore volume.
///   - `:4372-4373` `THETI(0)=AMAX1(0.0,AMIN1(1.0,VOLI(0)/VOLR))` clamps ice
///     content at unity, i.e. the oracle anticipates ice reaching and exceeding
///     the entire dry residue volume -- a stronger overfill than this function
///     sees.
///   - The oracle places no upper bound at all on `VOLW(0)+VOLI(0)`. Surface
///     water ponds and then leaves through WATSUB's runoff path.
///
/// `soil/water/solver_flux.zig:117-121` states the same policy for the matrix
/// layers in this tree's own words: accepted entry overfill may persist
/// transiently. See `LITTER-ICE-PORE-DOMAIN-001` in the discrepancy register.
pub fn liquidCapacityAfterIceM3(dry_pore_volume_m3: f64, physical_ice_volume_m3: f64) !f64 {
    inline for (.{ dry_pore_volume_m3, physical_ice_volume_m3 }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceLitterPoreState;
    return @max(0, dry_pore_volume_m3 - physical_ice_volume_m3);
}

/// The surface litter's total heat capacity: dry organic plus the three water
/// carriers. One owner for a formula that existed in three places.
///
/// `SURFACE-HEAT-CAPACITY-STALE-WITHIN-HOUR-001`. It was written once per hour
/// at `stages/hourly_snow_energy.zig:432`, recomputed independently by the
/// inventory at `validation/landscape_mass_inventory_surface.zig:513-517`, and
/// consumed mid-hour by the snowpack-disappearance transfer at
/// `soil/water/snowpack_litter_heat_water_transfer.zig:232-238`, which derives
/// its DRY capacity by subtracting a freshly-recomputed wet capacity from the
/// stored total. A stored total that had gone stale therefore became fictitious
/// dry capacity. Measured stale by `2.492331186283031e-6` MJ/K at the hour
/// surface vapor and ice first became nonzero, against `4.623948795384747e-8`
/// on the hour before -- a 54x jump.
///
/// Ice is passed as a water equivalent and must be paired with the
/// per-water-equivalent capacity from `ice_units.heatCapacityPerWaterEquivalentM3K`,
/// never with the physical coefficient. Vapor is carried at the LIQUID capacity,
/// which is what every existing owner does and what the inventory's enthalpy
/// convention assumes.
pub fn heatCapacityMegajoulesPerK(
    dry_organic_heat_capacity_megajoules_per_g_c_k: f64,
    organic_carbon_g_c: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    liquid_water_m3: f64,
    vapor_water_equivalent_m3: f64,
    ice_heat_capacity_per_water_equivalent_m3_k: f64,
    ice_water_equivalent_m3: f64,
) !f64 {
    inline for (.{
        dry_organic_heat_capacity_megajoules_per_g_c_k,
        organic_carbon_g_c,
        liquid_water_heat_capacity_megajoules_per_m3_k,
        liquid_water_m3,
        vapor_water_equivalent_m3,
        ice_heat_capacity_per_water_equivalent_m3_k,
        ice_water_equivalent_m3,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidSurfaceLitterHeatCapacityInput;
    const capacity = dry_organic_heat_capacity_megajoules_per_g_c_k * organic_carbon_g_c +
        liquid_water_heat_capacity_megajoules_per_m3_k *
            (liquid_water_m3 + vapor_water_equivalent_m3) +
        ice_heat_capacity_per_water_equivalent_m3_k * ice_water_equivalent_m3;
    if (!std.math.isFinite(capacity) or capacity <= 0)
        return error.InvalidSurfaceLitterHeatCapacity;
    return capacity;
}

test "SURFACE-HEAT-CAPACITY-STALE-WITHIN-HOUR-001 the one owner reproduces the measured audit-time capacity" {
    // The recomputed capacity printed at the failing hour, from its own state.
    const capacity = try heatCapacityMegajoulesPerK(
        2.496e-6,
        9.512005948477522e-1,
        4.19,
        3.7242356749202033e-3,
        3.7582097462947e-5,
        1.9274 / 0.917,
        3.635275033610843e-4,
    );
    try std.testing.expectApproxEqRel(@as(f64, 1.6528472353240755e-2), capacity, 1e-9);
    // The hour before, with both new carriers still at zero.
    const before = try heatCapacityMegajoulesPerK(
        2.496e-6,
        9.508959245186365e-1,
        4.19,
        3.7342319002911383e-3,
        0,
        1.9274 / 0.917,
        0,
    );
    try std.testing.expectApproxEqRel(@as(f64, 1.564880509844747e-2), before, 1e-9);
    // Negative and non-finite inputs stay fatal, and so does a zero total.
    try std.testing.expectError(error.InvalidSurfaceLitterHeatCapacityInput, heatCapacityMegajoulesPerK(2.496e-6, -1, 4.19, 0, 0, 2.1, 0));
    try std.testing.expectError(error.InvalidSurfaceLitterHeatCapacityInput, heatCapacityMegajoulesPerK(2.496e-6, std.math.nan(f64), 4.19, 0, 0, 2.1, 0));
    try std.testing.expectError(error.InvalidSurfaceLitterHeatCapacity, heatCapacityMegajoulesPerK(0, 0, 4.19, 0, 0, 2.1, 0));
}

/// HOUR1 `THETWR`: the water content the litter retention curve is evaluated at.
///
/// `hour1.f:4385` is the owner:
///   `THETWR=AMIN1(VOLWRX(NY,NX),VOLW(0,NY,NX))/VOLR(NY,NX)`
/// bounded by the litter water HOLDING CAPACITY `VOLWRX` and divided by the DRY
/// residue volume `VOLR`. `:4386-4400` then selects the retention branch on it,
/// and `:4398-4399` returns the saturated potential `PSISE(0)` once `THETWR`
/// reaches `POROS(0)`. Note `:1933` defines `POROS0=VOLWRX/VOLR`, so a litter
/// layer holding at least its retention capacity sits at or above its own
/// porosity -- i.e. saturated, the OPPOSITE end of the curve from residual.
///
/// Two substitutions are deliberately NOT made here, because `hour1.f:4385`
/// makes neither: the bound is not `pore - ice` (there is no ice term in
/// `THETWR` at all; `:4383-4384` gates only on `VOLR>0 .AND. VOLW(0)>0`), and
/// the denominator is not the expanded volume `VOLT(0)`. Using `pore - ice`
/// drives a ponded, frozen litter layer to exactly zero, which the retention
/// curve then clamps up to residual water content and reads as bone dry while
/// several litres of liquid sit in it. See `LITTER-RETENTION-THETWR-001`.
pub fn retentionWaterFraction(
    water_retention_capacity_m3: f64,
    liquid_water_m3: f64,
    dry_litter_volume_m3: f64,
) !f64 {
    inline for (.{ water_retention_capacity_m3, liquid_water_m3, dry_litter_volume_m3 }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceLitterRetentionWaterState;
    if (dry_litter_volume_m3 == 0) return 0;
    const fraction = @min(water_retention_capacity_m3, liquid_water_m3) / dry_litter_volume_m3;
    if (!std.math.isFinite(fraction) or fraction < 0) return error.InvalidSurfaceLitterRetentionWaterState;
    return fraction;
}

test "surface litter geometry reproduces HOUR1 pool equations" {
    const carbon = [source_pool_count]f64{ 10, 20, 30, 40, 50 };
    const parameters: Parameters = .{ .water_retention_m3_per_g_c = .{ 2e-6, 5e-6, 5e-6, 5e-6, 5e-6 }, .dry_bulk_density_megagrams_per_m3 = .{ 0.1, 0.0125, 0.025, 0.025, 0.025 }, .dry_mass_megagrams_per_g_c = 1.82e-6, .particle_density_megagrams_per_m3 = 1.30, .field_capacity_fraction_of_porosity = 0.5, .wilting_point_fraction_of_porosity = 0.25 };
    const result = try calculate(.{ .carbon_by_pool_g_c = carbon, .signed_charcoal_change_g_c = 5, .water_m3 = 0.001, .ice_m3 = 0 }, parameters);
    const retention = 2e-6 * 10 + 5e-6 * (20 + 30 + 50);
    const volume: f64 = 1e-6 * (10.0 / 0.1 + 20.0 / 0.0125 + 30.0 / 0.025 + 50.0 / 0.025);
    try std.testing.expectApproxEqAbs(retention, result.water_retention_capacity_m3, 1e-18);
    try std.testing.expectApproxEqAbs(volume, result.dry_litter_volume_m3, 1e-18);
    try std.testing.expectApproxEqAbs(volume + @max(0, 0.001 - retention), result.expanded_total_volume_m3, 1e-18);
    try std.testing.expectApproxEqAbs(@max(0, result.pore_volume_m3 - 0.001), result.air_volume_m3, 1e-18);
}

test "surface litter dry mass counts charcoal exactly once" {
    const parameters: Parameters = .{ .water_retention_m3_per_g_c = .{ 2e-6, 5e-6, 5e-6, 5e-6, 5e-6 }, .dry_bulk_density_megagrams_per_m3 = .{ 0.1, 0.0125, 0.025, 0.025, 0.025 }, .dry_mass_megagrams_per_g_c = 1.82e-6, .particle_density_megagrams_per_m3 = 1.30, .field_capacity_fraction_of_porosity = 0.5, .wilting_point_fraction_of_porosity = 0.25 };
    const result = try calculate(.{ .carbon_by_pool_g_c = .{ 0, 0, 0, 0, 5 }, .signed_charcoal_change_g_c = 5, .water_m3 = 0, .ice_m3 = 0 }, parameters);
    try std.testing.expectApproxEqAbs(@as(f64, 5 * 1.82e-6), result.dry_mass_megagrams, 1e-18);
}

test "surface litter hygroscopic water reproduces HOUR1 THETY" {
    const value = try waterFractionAtPotentialBelowWilting(0.3, 0.1, -0.033, -1.5, -1.5e4);
    const expected = @exp((@log(0.033) - @log(1.5e4)) * (@log(0.3) - @log(0.1)) / (@log(1.5) - @log(0.033)) + @log(0.3));
    try std.testing.expectApproxEqAbs(expected, value, 1e-15);
}

test "LITTER-ICE-PORE-DOMAIN-001 ponded surface ice over the dry pore volume clamps, as HOUR1 VOLP does" {
    // The exact state that ended the best fresh Ottawa run in project history
    // at attempt 2,650 (1998 day 111 hour 10), captured by the
    // litter-interface-diagnostics observation build over a 1 m2 cell.
    const dry_pore_volume_m3: f64 = 6.937374214942075e-5;
    const ice_water_equivalent_m3: f64 = 3.4793980410975303e-4;
    const ice_density_megagrams_per_m3: f64 = 0.917;
    const liquid_m3: f64 = 4.708564418092413e-3;
    const physical_ice_m3 = ice_water_equivalent_m3 / ice_density_megagrams_per_m3;

    // The overfill is real and large in both phases: ice is 5.5x the dry pore
    // volume and liquid is 67.9x it. HOUR1 admits both.
    try std.testing.expect(physical_ice_m3 > 5 * dry_pore_volume_m3);
    try std.testing.expect(liquid_m3 > 60 * dry_pore_volume_m3);

    const capacity = try liquidCapacityAfterIceM3(dry_pore_volume_m3, physical_ice_m3);
    try std.testing.expectEqual(@as(f64, 0), capacity);

    // `hour1.f:4366` VOLP(0): air volume clamps to exactly zero rather than
    // going negative or rejecting.
    const air_m3 = @max(0, capacity - liquid_m3);
    try std.testing.expectEqual(@as(f64, 0), air_m3);
    try std.testing.expect(std.math.isFinite(air_m3));
}

test "LITTER-RETENTION-THETWR-001 a ponded frozen litter layer reads saturated, not residual" {
    // Same captured hour-2,650 state. `retention` and `dry_volume` are not
    // printed directly by the diagnostic build, but the geometry identity
    // `expanded = dry + max(0, water + ice - retention)` pins their difference
    // exactly, so the two are carried here as a consistent pair.
    const liquid_m3: f64 = 4.708564418092413e-3;
    const ice_water_equivalent_m3: f64 = 3.4793980410975303e-4;
    const expanded_m3: f64 = 5.1541934567952445e-3;
    const dry_pore_m3: f64 = 6.937374214942075e-5;
    const retention_m3: f64 = 1.0e-4;
    const dry_volume_m3 = expanded_m3 - @max(0, liquid_m3 + ice_water_equivalent_m3 - retention_m3);
    try std.testing.expect(dry_volume_m3 > 0);

    const fraction = try retentionWaterFraction(retention_m3, liquid_m3, dry_volume_m3);

    // HOUR1 bounds THETWR by the retention capacity, so a layer holding more
    // liquid than it can retain sits at exactly retention/VOLR -- and :1933
    // defines POROS0 as that same ratio, i.e. saturation.
    try std.testing.expectEqual(retention_m3 / dry_volume_m3, fraction);
    try std.testing.expect(fraction > 0.5);

    // The substituted expression this replaces collapsed to exactly zero, which
    // the van Genuchten clamp then reads as residual -- the driest point on the
    // curve -- for a layer holding 4.7 litres.
    const physical_ice_m3 = ice_water_equivalent_m3 / 0.917;
    const substituted = @min(liquid_m3, @max(0, dry_pore_m3 - physical_ice_m3)) / expanded_m3;
    try std.testing.expectEqual(@as(f64, 0), substituted);
    try std.testing.expect(fraction > substituted);
}

test "LITTER-RETENTION-THETWR-001 zero dry residue volume and invalid inputs stay closed" {
    try std.testing.expectEqual(@as(f64, 0), try retentionWaterFraction(1e-4, 1e-3, 0));
    try std.testing.expectError(error.InvalidSurfaceLitterRetentionWaterState, retentionWaterFraction(-1e-9, 1e-3, 1e-3));
    try std.testing.expectError(error.InvalidSurfaceLitterRetentionWaterState, retentionWaterFraction(1e-4, 1e-3, std.math.nan(f64)));
    // Below its retention capacity the layer reports its actual liquid content.
    const pore: f64 = 2e-3;
    const water: f64 = 5e-4;
    try std.testing.expectEqual(water / pore, try retentionWaterFraction(1e-3, water, pore));
}

test "LITTER-ICE-PORE-DOMAIN-001 the unfilled case still reports the exact remaining capacity" {
    // The clamp must not swallow the ordinary case: with ice below the dry pore
    // volume the capacity is the plain difference, to the last bit.
    // Both sides must be the same runtime f64 subtraction: Zig evaluates a
    // comptime float expression in arbitrary precision, so `1e-3 - 4e-4` folds
    // to exactly 6e-4 while the f64 difference is 6.000000000000001e-4.
    const pore: f64 = 1e-3;
    const ice: f64 = 4e-4;
    const capacity = try liquidCapacityAfterIceM3(pore, ice);
    try std.testing.expectEqual(pore - ice, capacity);
    // Negative and non-finite inputs remain fatal: this fix removes an invented
    // upper bound, not the domain checks.
    try std.testing.expectError(error.InvalidSurfaceLitterPoreState, liquidCapacityAfterIceM3(-1e-9, 0));
    try std.testing.expectError(error.InvalidSurfaceLitterPoreState, liquidCapacityAfterIceM3(1e-3, std.math.nan(f64)));
}
