const std = @import("std");
const CellRange = @import("../core/compute.zig").CellRange;
const Topography = @import("../state/topography.zig").Topography;
const SoilCatalog = @import("../soil/profile/catalog.zig").Catalog;
const canopy_radiation = @import("../canopy/radiation/radiation.zig");
const RadiationState = canopy_radiation.State;
const InterceptionState = @import("../canopy/energy/interception.zig").State;
const terrain_radiation = @import("../state/terrain_radiation.zig");
const TerrainState = terrain_radiation.State;
const Geometry = @import("../canopy/morphology/geometry.zig").Geometry;
const snow_cover_fraction = @import("../soil/water/snow_cover_fraction.zig");
const SnowTransportState = @import("../soil/solute/snow_solute_transport.zig").State;

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    soil_albedo: []f64,
    initial_snow_depth_m: []f64,
    surface_albedo: []f64,
    incident_shortwave_megajoules_per_m2: []f64,
    absorbed_shortwave_megajoules_per_m2: []f64,
    reflected_shortwave_megajoules_per_m2: []f64,
    incident_par_micromol_per_m2_per_s: []f64,
    absorbed_par_micromol_per_m2_per_s: []f64,
    reflected_par_micromol_per_m2_per_s: []f64,

    pub fn initMapped(allocator: std.mem.Allocator, topography: Topography, topography_unit_by_cell: []const usize, soil_catalog: SoilCatalog, soil_catalog_index_by_cell: []const usize, full_snow_cover_depth_m: f64) !State {
        if (topography_unit_by_cell.len == 0 or topography_unit_by_cell.len != soil_catalog_index_by_cell.len) return error.InvalidGroundRadiationDimensions;
        const cell_count = topography_unit_by_cell.len;
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        var allocated: usize = 0;
        errdefer freeAllocated(&result, allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            @field(result, field.name) = try allocator.alloc(f64, cell_count);
            @memset(@field(result, field.name), 0);
            allocated += 1;
        };
        for (topography_unit_by_cell, soil_catalog_index_by_cell, 0..) |topography_index, soil_index, cell| {
            if (topography_index >= topography.units.len or soil_index >= soil_catalog.entries.items.len) return error.GroundRadiationMappingOutOfBounds;
            const albedo = soil_catalog.entries.items[soil_index].profile.wet_soil_albedo;
            const snow_depth = topography.units[topography_index].initial_snowpack_depth_m;
            if (!std.math.isFinite(albedo) or albedo < 0 or albedo > 1 or !std.math.isFinite(snow_depth) or snow_depth < 0) return error.InvalidGroundSurfaceProperties;
            result.soil_albedo[cell] = albedo;
            result.initial_snow_depth_m[cell] = snow_depth;
            // Cold start: `initializePhysicalState`
            // (`soil/solute/snow_solute_transport.zig`) always seeds the
            // snowpack with liquid and ice volumes both zero, i.e. fresh dry
            // snow, so the composition weighting collapses to the pure
            // fresh-snow term (`fresh_dry_snow_albedo`) regardless of depth.
            result.surface_albedo[cell] = try snowBlendedAlbedo(albedo, snow_depth, full_snow_cover_depth_m, fresh_dry_snow_albedo);
        }
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    pub fn validateFinite(self: State) !void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) for (@field(self, field.name), 0..) |value, index| {
            if (!std.math.isFinite(value)) {
                std.log.err("non-finite ground radiation: field={s} index={d} value={e}", .{ field.name, index, value });
                return error.NonFiniteGroundRadiation;
            }
        };
    }
};

pub const ApplyContext = struct {
    result: *State,
    radiation: *const RadiationState,
    interception: ?*const InterceptionState,
    terrain: *const TerrainState,
    /// Live, hourly-evolving snow depth (not the static site-initial value
    /// baked into `State.initial_snow_depth_m`). Re-blending surface albedo
    /// against this every hour is what keeps accumulation/melt visible to
    /// the radiation balance instead of freezing albedo at its hour-0 value.
    snow_depth_m: []const f64,
    /// Runtime `DPTHSX` control (`snow_full_cover_depth_m`), never a
    /// compile-time constant, per `MIGRATION.md`.
    full_snow_cover_depth_m: f64,
    /// Live per-layer snow phase inventory (production-wired: the same
    /// state `snow_phase_change.zig`, `snow_vapor_equilibrium.zig` and
    /// `snow_melt_water_routing.zig` read and update every hour). Only the
    /// top layer (layer 0 of each cell, matching watsub.f's `L=1`) feeds the
    /// ALBW composition term; see `snowCompositionAlbedo`. This reflects the
    /// composition as of the end of the previous hour, the same timing this
    /// module already uses for `snow_depth_m` -- the current hour's
    /// transport/phase solvers run later in `hourly_process_driver.zig`.
    snow: *const SnowTransportState,
};

pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    const result = context.result;
    if (range.end > result.cell_count or context.radiation.cellCount() != result.cell_count or context.terrain.cell_count != result.cell_count or context.snow_depth_m.len != result.cell_count) return error.GroundRadiationDimensionMismatch;
    if (context.interception) |interception| if (interception.cell_count != result.cell_count) return error.GroundRadiationDimensionMismatch;
    if (context.snow.cell_count != result.cell_count or context.snow.layer_capacity == 0) return error.GroundRadiationDimensionMismatch;
    for (range.first..range.end) |cell| {
        if (!std.math.isFinite(context.snow_depth_m[cell]) or context.snow_depth_m[cell] < 0) return error.InvalidGroundSnowDepth;
        const top_layer = cell * context.snow.layer_capacity;
        const solid = context.snow.solid_snow_water_equivalent_m3[top_layer];
        const liquid = context.snow.liquid_water_volume_m3[top_layer];
        const ice = context.snow.ice_volume_m3[top_layer];
        if (!std.math.isFinite(solid) or solid < 0 or !std.math.isFinite(liquid) or liquid < 0 or !std.math.isFinite(ice) or ice < 0) return error.InvalidSnowCompositionState;
        const snow_albedo = snowCompositionAlbedo(solid, liquid, ice);
        result.surface_albedo[cell] = try snowBlendedAlbedo(result.soil_albedo[cell], context.snow_depth_m[cell], context.full_snow_cover_depth_m, snow_albedo);
        const direct_transmission = if (context.interception) |interception| interception.direct_transmission_fraction[cell] else 1.0;
        const diffuse_transmission = if (context.interception) |interception| interception.diffuse_transmission_fraction[cell] else 1.0;
        var diffuse_terrain_projection: f64 = 0;
        for (0..context.terrain.sky_sector_count) |sky| diffuse_terrain_projection += context.terrain.diffuse_sky_incidence_fraction[cell * context.terrain.sky_sector_count + sky];
        const direct_shortwave = context.radiation.direct_shortwave_megajoules_per_m2[cell] * direct_transmission * context.terrain.direct_solar_incidence_fraction[cell];
        var diffuse_shortwave = context.radiation.diffuse_shortwave_megajoules_per_m2[cell] * diffuse_transmission * diffuse_terrain_projection;
        const direct_par = context.radiation.direct_par_micromol_per_m2_per_s[cell] * direct_transmission * context.terrain.direct_solar_incidence_fraction[cell];
        var diffuse_par = context.radiation.diffuse_par_micromol_per_m2_per_s[cell] * diffuse_transmission * diffuse_terrain_projection;
        if (context.interception) |interception| {
            const bottom_boundary = cell * (interception.layer_count + 1);
            diffuse_shortwave += interception.downward_scattered_shortwave_by_boundary_megajoules_per_m2[bottom_boundary];
            diffuse_par += interception.downward_scattered_par_by_boundary_micromol_per_m2_per_s[bottom_boundary];
        }
        const shortwave = try partitionEnergy(direct_shortwave + diffuse_shortwave, result.surface_albedo[cell]);
        const par = try partitionEnergy(direct_par + diffuse_par, result.surface_albedo[cell]);
        result.incident_shortwave_megajoules_per_m2[cell] = shortwave.incident;
        result.absorbed_shortwave_megajoules_per_m2[cell] = shortwave.absorbed;
        result.reflected_shortwave_megajoules_per_m2[cell] = shortwave.reflected;
        result.incident_par_micromol_per_m2_per_s[cell] = par.incident;
        result.absorbed_par_micromol_per_m2_per_s[cell] = par.absorbed;
        result.reflected_par_micromol_per_m2_per_s[cell] = par.reflected;
    }
}

const EnergyPartition = struct { incident: f64, absorbed: f64, reflected: f64 };

fn partitionEnergy(incident: f64, albedo: f64) !EnergyPartition {
    if (!std.math.isFinite(incident) or !std.math.isFinite(albedo)) return error.NonFiniteGroundEnergy;
    if (incident < 0 or albedo < 0 or albedo > 1) return error.InvalidGroundEnergy;
    const reflected = incident * albedo;
    const absorbed = incident - reflected;
    if (@abs((absorbed + reflected) - incident) > 1.0e-12 * @max(1.0, incident)) return error.GroundEnergyImbalance;
    return .{ .incident = incident, .absorbed = absorbed, .reflected = reflected };
}

/// Fresh, dry-snow albedo weight from watsub.f:1238's `0.90*VOLS02` term.
const fresh_dry_snow_albedo: f64 = 0.90;
/// Refrozen-ice albedo weight from watsub.f:1238's `0.30*VOLI02` term.
const refrozen_ice_albedo: f64 = 0.30;
/// Liquid (wet, melting) snow albedo weight from watsub.f:1239's
/// `0.06*VOLW02` term.
const wet_snow_albedo: f64 = 0.06;

/// Blends dry-soil albedo against the snowpack albedo (ALBW) by the areal
/// snow-cover fraction implied by live snow depth, matching the cover
/// fraction convention used by `surface/energy.zig`'s emissivity blend.
///
/// The cover fraction itself is `watsub.f:386-392`'s FSNW/FSNX pair (a square
/// root of the depth ratio, with a floor-and-complement on the snow-free
/// side), delegated to the single authoritative owner in
/// `soil/water/snow_cover_fraction.zig` rather than re-derived here. See
/// `docs/traceability/watsub_snow_cover_fraction_exponent_defect.md`.
///
/// `snow_albedo` is ALBW itself, supplied by the caller: `applyTile` passes
/// `snowCompositionAlbedo`'s live phase-weighted value every hour, while
/// `State.initMapped`'s cold start passes `fresh_dry_snow_albedo` directly
/// (see the call site for why that is exact, not an approximation).
///
/// The snow-composition term (watsub.f:1237-1241) is implemented by
/// `snowCompositionAlbedo` below. Live soil/litter ALBG/ALBZ/ALBR are
/// recomputed at the start of every coupled nonlinear substep by
/// `surface/temperature_solver.zig`, before its net-radiation residual is
/// assembled; the hourly value here remains the pre-substep canopy-reflection
/// diagnostic.
fn snowBlendedAlbedo(soil_albedo: f64, snow_depth_m: f64, full_snow_cover_depth_m: f64, snow_albedo: f64) !f64 {
    const cover = try snow_cover_fraction.evaluate(snow_depth_m, full_snow_cover_depth_m);
    return cover.snow_fraction * snow_albedo + cover.snow_free_fraction * soil_albedo;
}

const wet_surface_albedo: f64 = 0.06;
const frozen_surface_albedo: f64 = 0.30;
const dry_regular_litter_albedo: f64 = 0.40;
const dry_charcoal_albedo: f64 = 0.00;

/// WATSUB ALBG/ALBR phase weighting (watsub.f:2736-2744, 2961-2963).
/// `ice_volume_m3` is physical ice volume, as in the oracle's VOLI arrays.
/// Soil callers may request the oracle's dry fallback when the phase inventory
/// is below its cell-scaled ZEROS2 equivalent; litter callers pass zero because
/// the litter energy branch itself guarantees a non-empty denominator.
pub fn phaseWeightedSurfaceAlbedo(
    dry_albedo: f64,
    dry_mass_megagrams: f64,
    liquid_water_m3: f64,
    ice_volume_m3: f64,
    negligible_phase_volume_m3: f64,
) !f64 {
    inline for (.{ dry_albedo, dry_mass_megagrams, liquid_water_m3, ice_volume_m3, negligible_phase_volume_m3 }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSurfaceAlbedoInput;
    if (dry_albedo < 0 or dry_albedo > 1 or dry_mass_megagrams < 0 or
        liquid_water_m3 < 0 or ice_volume_m3 < 0 or negligible_phase_volume_m3 < 0)
        return error.InvalidSurfaceAlbedoInput;
    if (liquid_water_m3 + ice_volume_m3 <= negligible_phase_volume_m3)
        return dry_albedo;
    const total = dry_mass_megagrams + liquid_water_m3 + ice_volume_m3;
    if (total <= 0) return error.EmptySurfaceAlbedoInventory;
    const albedo = (dry_albedo * dry_mass_megagrams +
        wet_surface_albedo * liquid_water_m3 +
        frozen_surface_albedo * ice_volume_m3) / total;
    if (!std.math.isFinite(albedo) or albedo < 0 or albedo > 1)
        return error.InvalidSurfaceAlbedoResult;
    return albedo;
}

/// WATSUB ALBZ (watsub.f:339-347). The regular-carbon gate is intentional:
/// when ORGC is negligible the oracle publishes 0.40 even if ORGCC is present.
pub fn dryLitterAlbedo(
    regular_carbon_g_c: f64,
    charcoal_carbon_g_c: f64,
    negligible_regular_carbon_g_c: f64,
) !f64 {
    inline for (.{ regular_carbon_g_c, charcoal_carbon_g_c, negligible_regular_carbon_g_c }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSurfaceAlbedoInput;
    if (regular_carbon_g_c < 0 or charcoal_carbon_g_c < 0 or negligible_regular_carbon_g_c < 0)
        return error.InvalidSurfaceAlbedoInput;
    if (regular_carbon_g_c <= negligible_regular_carbon_g_c)
        return dry_regular_litter_albedo;
    const total_carbon = regular_carbon_g_c + charcoal_carbon_g_c;
    if (total_carbon <= 0) return error.EmptySurfaceAlbedoInventory;
    return (dry_regular_litter_albedo * regular_carbon_g_c +
        dry_charcoal_albedo * charcoal_carbon_g_c) / total_carbon;
}

pub fn blendSoilLitterAlbedo(soil_albedo: f64, litter_albedo: f64, litter_cover_fraction: f64) !f64 {
    inline for (.{ soil_albedo, litter_albedo, litter_cover_fraction }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSurfaceAlbedoInput;
    if (soil_albedo < 0 or soil_albedo > 1 or litter_albedo < 0 or litter_albedo > 1 or
        litter_cover_fraction < 0 or litter_cover_fraction > 1)
        return error.InvalidSurfaceAlbedoInput;
    return litter_cover_fraction * litter_albedo +
        (1 - litter_cover_fraction) * soil_albedo;
}

/// WATSUB BARE/CVRD/BAREW/CVRDW (watsub.f:393-402). This is kept with
/// ALBG/ALBR because cover is part of the exact source partition of incoming
/// shortwave between soil and litter, including the excess-water override.
pub fn liveLitterCoverFraction(
    total_litter_carbon_g_c: f64,
    horizontal_area_m2: f64,
    litter_heat_capacity_megajoules_per_k: f64,
    minimum_litter_heat_capacity_megajoules_per_k: f64,
    excess_surface_water_and_ice_m3: f64,
    surface_ponding_capacity_m3: f64,
) !f64 {
    inline for (.{
        total_litter_carbon_g_c,
        horizontal_area_m2,
        litter_heat_capacity_megajoules_per_k,
        minimum_litter_heat_capacity_megajoules_per_k,
        excess_surface_water_and_ice_m3,
        surface_ponding_capacity_m3,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceAlbedoInput;
    if (total_litter_carbon_g_c < 0 or horizontal_area_m2 <= 0 or
        litter_heat_capacity_megajoules_per_k < 0 or
        minimum_litter_heat_capacity_megajoules_per_k < 0 or
        excess_surface_water_and_ice_m3 < 0 or surface_ponding_capacity_m3 < 0)
        return error.InvalidSurfaceAlbedoInput;
    const dry_bare_fraction = if (litter_heat_capacity_megajoules_per_k >
        minimum_litter_heat_capacity_megajoules_per_k)
        std.math.exp(-0.005 * total_litter_carbon_g_c / horizontal_area_m2)
    else
        1;
    const excess_water_cover_fraction: f64 = if (surface_ponding_capacity_m3 > 0)
        std.math.clamp(
            excess_surface_water_and_ice_m3 / surface_ponding_capacity_m3,
            0,
            1,
        )
    else if (excess_surface_water_and_ice_m3 > 0)
        1.0
    else
        0.0;
    const water_adjusted_bare_fraction = @max(0, dry_bare_fraction - excess_water_cover_fraction);
    return 1 - water_adjusted_bare_fraction;
}

/// ALBW: the snowpack albedo itself, computed every hour from the top snow
/// layer's live solid-snow, ice and liquid-water composition, exactly
/// matching watsub.f:1238-1240's
/// `ALBW=(0.90*VOLS02(1,..)+0.30*VOLI02(1,..)+0.06*VOLW02(1,..))
///       /(VOLS02+VOLI02+VOLW02)(1,..)`.
/// As fresh dry snow (weight 0.90) melts into liquid water (weight 0.06) or
/// refreezes into ice (weight 0.30), the phase-weighted average falls --
/// this is the oracle's entire mechanism for snow-albedo aging/decay with
/// melt state, distinct from the areal snow-cover-fraction blend in
/// `snowBlendedAlbedo`.
///
/// When the top layer carries no snow/ice/water volume at all (no snow
/// present, or present only in lower layers), the ratio is undefined; the
/// oracle's `DO 3000 MM=1,NPS` loop is gated on `VHCPWM2(1,..)>VHCPWX` for
/// exactly this reason, so this returns the fresh-dry-snow weight, matching
/// the value a just-arrived, all-solid top layer would produce.
fn snowCompositionAlbedo(solid_snow_water_equivalent_m3: f64, liquid_water_m3: f64, ice_volume_m3: f64) f64 {
    const total = solid_snow_water_equivalent_m3 + liquid_water_m3 + ice_volume_m3;
    if (total <= 0) return fresh_dry_snow_albedo;
    return (fresh_dry_snow_albedo * solid_snow_water_equivalent_m3 + refrozen_ice_albedo * ice_volume_m3 + wet_snow_albedo * liquid_water_m3) / total;
}

fn freeAllocated(state: *State, count: usize) void {
    var visited: usize = 0;
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        if (visited < count) state.allocator.free(@field(state, field.name));
        visited += 1;
    };
}

test "ground energy partition is conservative" {
    const result = try partitionEnergy(2.5, 0.2);
    try std.testing.expectApproxEqAbs(@as(f64, 2), result.absorbed, 1.0e-15);
    try std.testing.expectApproxEqAbs(result.incident, result.absorbed + result.reflected, 1.0e-15);
}

test "live soil and litter albedo preserve WATSUB dry wet frozen causality" {
    const dry = try phaseWeightedSurfaceAlbedo(0.40, 1, 0, 0, 1.0e-9);
    const wet = try phaseWeightedSurfaceAlbedo(0.40, 1, 0.5, 0, 1.0e-9);
    const frozen = try phaseWeightedSurfaceAlbedo(0.40, 1, 0, 0.5, 1.0e-9);
    try std.testing.expectEqual(@as(f64, 0.40), dry);
    try std.testing.expect(wet < frozen);
    try std.testing.expect(frozen < dry);
    try std.testing.expectApproxEqAbs(@as(f64, (0.40 + 0.03) / 1.5), wet, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, (0.40 + 0.15) / 1.5), frozen, 1.0e-15);

    const regular = try dryLitterAlbedo(3, 0, 1.0e-12);
    const charred = try dryLitterAlbedo(3, 1, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.40), regular, 16 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), charred, 1.0e-15);
    try std.testing.expectEqual(@as(f64, 0.40), try dryLitterAlbedo(0, 1, 1.0e-12));
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), try blendSoilLitterAlbedo(0.20, 0.40, 0.25), 1.0e-15);

    const no_litter = try liveLitterCoverFraction(100, 10, 0.01, 0.02, 0, 1);
    const litter = try liveLitterCoverFraction(100, 10, 0.03, 0.02, 0, 1);
    const flooded = try liveLitterCoverFraction(100, 10, 0.03, 0.02, 1, 1);
    const zero_capacity_dry = try liveLitterCoverFraction(100, 10, 0.03, 0.02, 0, 0);
    const zero_capacity_wet = try liveLitterCoverFraction(100, 10, 0.03, 0.02, 1, 0);
    try std.testing.expectEqual(@as(f64, 0), no_litter);
    try std.testing.expect(litter > no_litter and litter < flooded);
    try std.testing.expectEqual(@as(f64, 1), flooded);
    try std.testing.expectEqual(litter, zero_capacity_dry);
    try std.testing.expectEqual(@as(f64, 1), zero_capacity_wet);
}

test "snow-blended albedo follows the source square root of the depth fraction" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), try snowBlendedAlbedo(0.2, 0, 0.07, fresh_dry_snow_albedo), 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), try snowBlendedAlbedo(0.2, 0.07, 0.07, fresh_dry_snow_albedo), 1.0e-15);
    try std.testing.expect(try snowBlendedAlbedo(0.2, 0.035, 0.07, fresh_dry_snow_albedo) > 0.2);
    // sqrt(0.25) = 0.5 exactly at one fourth of the full-cover depth, so the
    // blend is exactly halfway between soil and snow albedo there. The
    // previous squared form would have produced a cover fraction of only
    // 0.0625, an 8x understatement, and a blend far closer to soil albedo.
    try std.testing.expectApproxEqAbs(@as(f64, 0.5) * 0.90 + @as(f64, 0.5) * 0.2, try snowBlendedAlbedo(0.2, 0.0175, 0.07, fresh_dry_snow_albedo), 1.0e-14);
}

test "snow composition albedo decays from fresh dry snow toward wet/icy snow, matching watsub.f's ALBW weights" {
    // Fresh dry snow only: exactly the 0.90 weight, matching watsub.f:1238's
    // 0.90*VOLS02 term with VOLI02=VOLW02=0.
    try std.testing.expectApproxEqAbs(@as(f64, 0.90), snowCompositionAlbedo(1, 0, 0), 1.0e-15);
    // Fully refrozen ice: the 0.30 weight.
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), snowCompositionAlbedo(0, 0, 1), 1.0e-15);
    // Fully melted (wet) liquid water: the 0.06 weight -- the oracle's
    // steepest albedo decay state.
    try std.testing.expectApproxEqAbs(@as(f64, 0.06), snowCompositionAlbedo(0, 1, 0), 1.0e-15);
    // Half solid, half liquid: exact phase-weighted average.
    try std.testing.expectApproxEqAbs(@as(f64, 0.5) * 0.90 + @as(f64, 0.5) * 0.06, snowCompositionAlbedo(1, 1, 0), 1.0e-15);
    // No snow/ice/water volume at all in the top layer: falls back to fresh
    // dry snow rather than dividing by zero.
    try std.testing.expectApproxEqAbs(@as(f64, 0.90), snowCompositionAlbedo(0, 0, 0), 1.0e-15);
}

test "applyTile re-blends surface albedo from live snow depth every hour, not just at init" {
    const allocator = std.testing.allocator;
    var result: State = undefined;
    result.allocator = allocator;
    result.cell_count = 1;
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        @field(result, field.name) = try allocator.alloc(f64, 1);
        @memset(@field(result, field.name), 0);
    };
    defer result.deinit();
    result.soil_albedo[0] = 0.2;

    var radiation = try RadiationState.init(allocator, 1);
    defer radiation.deinit();

    var terrain: TerrainState = undefined;
    terrain.allocator = allocator;
    terrain.cell_count = 1;
    terrain.sky_sector_count = 1;
    inline for (@typeInfo(TerrainState).@"struct".fields) |field| if (field.type == []f64) {
        @field(terrain, field.name) = try allocator.alloc(f64, 1);
        @memset(@field(terrain, field.name), 0);
    };
    defer terrain.deinit();

    var snow = try SnowTransportState.init(allocator, 1, 1);
    defer snow.deinit();
    snow.solid_snow_water_equivalent_m3[0] = 1;

    var snow_depth_m = [_]f64{0.07};
    var context: ApplyContext = .{ .result = &result, .radiation = &radiation, .interception = null, .terrain = &terrain, .snow_depth_m = &snow_depth_m, .full_snow_cover_depth_m = 0.07, .snow = &snow };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), result.surface_albedo[0], 1.0e-15);

    snow_depth_m[0] = 0;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), result.surface_albedo[0], 1.0e-15);
}

test "applyTile lowers snow-covered albedo as the top layer melts to wet/icy snow" {
    const allocator = std.testing.allocator;
    var result: State = undefined;
    result.allocator = allocator;
    result.cell_count = 1;
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        @field(result, field.name) = try allocator.alloc(f64, 1);
        @memset(@field(result, field.name), 0);
    };
    defer result.deinit();
    result.soil_albedo[0] = 0.2;

    var radiation = try RadiationState.init(allocator, 1);
    defer radiation.deinit();

    var terrain: TerrainState = undefined;
    terrain.allocator = allocator;
    terrain.cell_count = 1;
    terrain.sky_sector_count = 1;
    inline for (@typeInfo(TerrainState).@"struct".fields) |field| if (field.type == []f64) {
        @field(terrain, field.name) = try allocator.alloc(f64, 1);
        @memset(@field(terrain, field.name), 0);
    };
    defer terrain.deinit();

    var snow = try SnowTransportState.init(allocator, 1, 1);
    defer snow.deinit();
    snow.solid_snow_water_equivalent_m3[0] = 1;

    // Full cover depth so the areal snow-cover fraction is 1 and the entire
    // surface_albedo swing is attributable to ALBW alone.
    var snow_depth_m = [_]f64{0.07};
    var context: ApplyContext = .{ .result = &result, .radiation = &radiation, .interception = null, .terrain = &terrain, .snow_depth_m = &snow_depth_m, .full_snow_cover_depth_m = 0.07, .snow = &snow };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.90), result.surface_albedo[0], 1.0e-15);

    // Fresh snow melts entirely into liquid water: ALBW must fall to the wet
    // snow weight, not stay pinned at the fresh-snow constant.
    snow.solid_snow_water_equivalent_m3[0] = 0;
    snow.liquid_water_volume_m3[0] = 1;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.06), result.surface_albedo[0], 1.0e-15);

    // The same melt water refreezes into ice overnight: ALBW settles at the
    // refrozen-ice weight, between fresh snow and open water.
    snow.liquid_water_volume_m3[0] = 0;
    snow.ice_volume_m3[0] = 1;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), result.surface_albedo[0], 1.0e-15);
}

/// RADIATION-DIFFUSE-SECTOR-COUNT-001 regression: the ground-incident
/// shortwave on flat terrain must be invariant to the deck's configured
/// `diffuse_sky_sector_count`. Before the fix, `canopy_radiation.partition`
/// always divided by the frozen four-sector normalizer while
/// `ground_radiation.applyTile` summed the terrain incidence table over the
/// *actual* runtime sector count, so a deck configured with N=6 silently
/// inflated diffuse shortwave/PAR reaching the ground by 6/4 relative to the
/// N=4 case with identical physical inputs.
fn flatTerrainIncidentShortwave(allocator: std.mem.Allocator, sky_sector_count: usize) !f64 {
    var geometry = try Geometry.init(allocator, .{ .diffuse_sky_sector_count = sky_sector_count });
    defer geometry.deinit();

    const soil_name = try allocator.dupe(u8, "soil");
    var units = try allocator.alloc(@import("../state/topography.zig").LandscapeUnit, 1);
    units[0] = .{ .west_column = 1, .north_row = 1, .east_column = 1, .south_row = 1, .compass_aspect_degrees = 0, .geometric_aspect_degrees = 0, .slope_degrees = 0, .initial_snowpack_depth_m = 0, .soil_profile_file = soil_name };
    var topography: Topography = .{ .allocator = allocator, .units = units };
    defer topography.deinit();

    var terrain = try TerrainState.init(allocator, topography, &.{0}, geometry);
    defer terrain.deinit();
    var solar_context: terrain_radiation.DirectSolarContext = .{ .state = &terrain, .solar_angle_sine = 0.8, .solar_azimuth_radians = 0 };
    try terrain_radiation.applyDirectSolarTile(&solar_context, .{ .first = 0, .end = 1 });

    var radiation = try RadiationState.init(allocator, 1);
    defer radiation.deinit();
    var radiation_context: canopy_radiation.ApplyContext = .{
        .state = &radiation,
        .horizontal_shortwave_megajoules_per_m2 = 2.0,
        .extraterrestrial_horizontal_shortwave_megajoules_per_m2 = 4.0,
        .solar_angle_sine = 0.8,
        .diffuse_sky_horizontal_projection = geometry.diffuse_sky_horizontal_projection,
    };
    try canopy_radiation.applyUniformTile(&radiation_context, .{ .first = 0, .end = 1 });

    var result: State = undefined;
    result.allocator = allocator;
    result.cell_count = 1;
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        @field(result, field.name) = try allocator.alloc(f64, 1);
        @memset(@field(result, field.name), 0);
    };
    defer result.deinit();
    result.soil_albedo[0] = 0;

    var snow = try SnowTransportState.init(allocator, 1, 1);
    defer snow.deinit();

    var snow_depth_m = [_]f64{0};
    var context: ApplyContext = .{ .result = &result, .radiation = &radiation, .interception = null, .terrain = &terrain, .snow_depth_m = &snow_depth_m, .full_snow_cover_depth_m = 0.07, .snow = &snow };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    return result.incident_shortwave_megajoules_per_m2[0];
}

test "ground-incident shortwave on flat terrain is invariant to the configured sky-sector count" {
    const allocator = std.testing.allocator;
    const four_sector = try flatTerrainIncidentShortwave(allocator, 4);
    const six_sector = try flatTerrainIncidentShortwave(allocator, 6);
    try std.testing.expectApproxEqAbs(four_sector, six_sector, 1.0e-6);
    // Both should closely reconstruct the original horizontal input on
    // (near-)flat ground -- the 0.1 degree slope floor (aligned with the
    // chosen zero aspect/azimuth) is the only source of deviation from the
    // exact 2.0 input, worth ~1.3e-3 here.
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), four_sector, 2.0e-3);
}
