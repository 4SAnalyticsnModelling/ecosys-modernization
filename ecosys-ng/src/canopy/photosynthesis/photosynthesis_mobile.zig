//! `photosynthesis` declarations: mobile.
//!
//! Split out of `photosynthesis.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const c4_mesophyll_bundle_exchange = @import("c4_mesophyll_bundle_exchange.zig");
const branch_organ_growth_state_update = @import("../../plant/growth/branch_organ_growth_state_update.zig");
const leaf_node_growth_state_update = @import("../leaf/node_growth_state_update.zig");
const shoot_recycling_fraction = @import("../../plant/growth/shoot_recycling_fraction.zig");
const reserve_maintenance_respiration = @import("../../plant/growth/reserve_maintenance_respiration.zig");
const shoot_total_senescence_setup = @import("../../plant/growth/shoot_total_senescence_setup.zig");
const node_senescence_remobilization_request = @import("../../plant/growth/node_senescence_remobilization_request.zig");
const c4_leaf_nonstructural_carbon_senescence = @import("../leaf/c4_nonstructural_carbon_senescence.zig");
const node_senescence_cascade_progress = @import("../../plant/growth/node_senescence_cascade_progress.zig");
const perennial_stalk_senescence_setup = @import("../../plant/growth/perennial_stalk_senescence_setup.zig");
const internode_senescence_state_update = @import("../sheath/internode_senescence_state_update.zig");
const residual_stalk_senescence_request = @import("../../plant/growth/residual_stalk_senescence_request.zig");
const residual_stalk_senescence_state_update = @import("../../plant/growth/residual_stalk_senescence_state_update.zig");
const group_state = @import("photosynthesis_state.zig");

pub const BranchMobilePoolFluxes = struct {
    fixed_carbon_g: f64,
    maintenance_respiration_demand_g_c: f64,
    available_respirable_carbon_g_c: f64,
    growth_and_respiration_g_c: f64,
    nitrogen_assimilation_respiration_g_c: f64,
    assimilated_nitrogen_g: f64,
    canopy_ammonia_exchange_g_n: f64,
    assimilated_phosphorus_g: f64,
};

pub const BranchMobilePools = struct { carbon_g_c: f64, nitrogen_g_n: f64, phosphorus_g_p: f64 };

pub fn previewBranchMobilePools(state: *const group_state.State, branch: usize, fluxes: BranchMobilePoolFluxes) !BranchMobilePools {
    if (branch >= state.branch_mobile_carbon_g.len) return error.CanopyBranchIndexOutOfBounds;
    inline for (@typeInfo(BranchMobilePoolFluxes).@"struct".fields) |field| if (!std.math.isFinite(@field(fluxes, field.name))) return error.NonFiniteBranchPoolFlux;
    inline for (.{ state.branch_mobile_carbon_g[branch], state.branch_mobile_nitrogen_g[branch], state.branch_mobile_phosphorus_g[branch] }) |pool|
        if (!std.math.isFinite(pool) or pool < 0) return error.InvalidBranchMobilePoolState;
    const carbon = state.branch_mobile_carbon_g[branch] + fluxes.fixed_carbon_g - @min(fluxes.maintenance_respiration_demand_g_c, fluxes.available_respirable_carbon_g_c) - fluxes.growth_and_respiration_g_c - fluxes.nitrogen_assimilation_respiration_g_c;
    const nitrogen = state.branch_mobile_nitrogen_g[branch] - fluxes.assimilated_nitrogen_g + fluxes.canopy_ammonia_exchange_g_n;
    const phosphorus = state.branch_mobile_phosphorus_g[branch] - fluxes.assimilated_phosphorus_g;
    if (!std.math.isFinite(carbon) or !std.math.isFinite(nitrogen) or !std.math.isFinite(phosphorus)) {
        std.log.err("non-finite branch mobile-pool result: branch={d} carbon_g_c={e} nitrogen_g_n={e} phosphorus_g_p={e}", .{ branch, carbon, nitrogen, phosphorus });
        return error.NonFiniteBranchMobilePoolResult;
    }
    if (carbon < 0 or nitrogen < 0 or phosphorus < 0) {
        return error.BranchMobilePoolExhausted;
    }
    // These are conserved extensive pools.  A negative candidate is rejected
    // above; zeroing even a tiny candidate here would destroy the matching
    // source/sink amount recorded by the contributing process.
    return .{ .carbon_g_c = carbon, .nitrogen_g_n = nitrogen, .phosphorus_g_p = phosphorus };
}

pub fn updateBranchMobilePools(state: *group_state.State, branch: usize, fluxes: BranchMobilePoolFluxes) !void {
    const pools = try previewBranchMobilePools(state, branch, fluxes);
    state.branch_mobile_carbon_g[branch] = pools.carbon_g_c;
    state.branch_mobile_nitrogen_g[branch] = pools.nitrogen_g_n;
    state.branch_mobile_phosphorus_g[branch] = pools.phosphorus_g_p;
}

pub const ReserveFallbackPolicy = enum { source_compatible, consume_available };

/// GROSUB IFLGZ=0 reserve oxidation before leaf/stalk senescence. When shoot
/// remobilization is already enabled (IFLGZ=1), the later senescence cascade
/// owns the reserve transaction instead.
pub fn consumeReserveForRespiration(state: *group_state.State, branch: usize, shoot_remobilization_enabled: bool, remaining_respiration_demand_g_c: f64, maximum_nonstructural_carbon_oxidation_per_h: f64, canopy_growth_temperature_factor: f64, timestep_h: f64) !f64 {
    if (branch >= state.branch_reserve_carbon_g.len) return error.CanopyBranchIndexOutOfBounds;
    var demand = [1]f64{remaining_respiration_demand_g_c};
    _ = try reserve_maintenance_respiration.apply(.{
        .reserve_carbon_g_c = state.branch_reserve_carbon_g[branch .. branch + 1],
        .excess_maintenance_respiration_g_c_per_timestep = &demand,
    }, .{
        .branch = 0,
        .shoot_remobilization_status = if (shoot_remobilization_enabled) .active else .not_started,
        .maximum_nonstructural_carbon_oxidation_per_h = maximum_nonstructural_carbon_oxidation_per_h,
        .canopy_growth_temperature_response = canopy_growth_temperature_factor,
        .timestep_h = timestep_h,
    });
    return demand[0];
}

pub const ReserveExchange = struct { carbon_g: f64, nitrogen_g: f64, phosphorus_g: f64 };

pub const SourceOrderMobileRemoval = struct {
    remaining: group_state.ElementalMass,
    unclamped_carbon_retention_fraction: f64,
};

/// Exact GROSUB 9221-9238 proportional host/symbiont mobile removal. The
/// unclamped fraction is exposed because source applies it to symbiont
/// structural pools even when requested C exceeds mobile C.
pub fn sourceOrderProportionalMobileRemoval(
    initial: group_state.ElementalMass,
    requested_carbon_g_c: f64,
    plant_presence_threshold_g_c: f64,
) !SourceOrderMobileRemoval {
    inline for (.{ initial.carbon_g, initial.nitrogen_g, initial.phosphorus_g, requested_carbon_g_c, plant_presence_threshold_g_c }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidHarvestMass;
    if (initial.carbon_g <= plant_presence_threshold_g_c) return .{
        .remaining = .{},
        .unclamped_carbon_retention_fraction = 0,
    };
    const ratio = 1 - requested_carbon_g_c / initial.carbon_g;
    return .{
        .remaining = .{
            .carbon_g = @max(0, initial.carbon_g - requested_carbon_g_c),
            .nitrogen_g = @max(0, initial.nitrogen_g - requested_carbon_g_c * initial.nitrogen_g / initial.carbon_g),
            .phosphorus_g = @max(0, initial.phosphorus_g - requested_carbon_g_c * initial.phosphorus_g / initial.carbon_g),
        },
        .unclamped_carbon_retention_fraction = ratio,
    };
}

/// Conservative pairwise branch-reserve equilibration from the GROSUB main-
/// branch loop. Signed flux is positive from main_branch to other_branch.
pub fn equilibrateBranchReserves(state: *group_state.State, main_branch: usize, other_branch: usize, carbon_exchange_per_h: f64, nutrient_exchange_per_h: f64, timestep_h: f64, presence_threshold_g_c: f64) !ReserveExchange {
    inline for (.{ carbon_exchange_per_h, nutrient_exchange_per_h, timestep_h, presence_threshold_g_c }) |value| if (!std.math.isFinite(value)) return error.NonFiniteBranchReserveExchangeInput;
    if (main_branch >= state.branch_reserve_carbon_g.len or other_branch >= state.branch_reserve_carbon_g.len or main_branch == other_branch) return error.CanopyBranchIndexOutOfBounds;
    if (carbon_exchange_per_h < 0 or nutrient_exchange_per_h < 0 or timestep_h <= 0 or presence_threshold_g_c < 0) return error.InvalidBranchReserveExchangeInput;
    inline for (.{
        state.branch_reserve_carbon_g[main_branch],     state.branch_reserve_carbon_g[other_branch],
        state.branch_reserve_nitrogen_g[main_branch],   state.branch_reserve_nitrogen_g[other_branch],
        state.branch_reserve_phosphorus_g[main_branch], state.branch_reserve_phosphorus_g[other_branch],
        state.branch_sapwood_carbon_g[main_branch],     state.branch_sapwood_carbon_g[other_branch],
    }) |pool| if (!std.math.isFinite(pool) or pool < 0) return error.InvalidBranchReserveExchangeState;
    const other_sapwood = state.branch_sapwood_carbon_g[other_branch];
    if (other_sapwood <= presence_threshold_g_c) return .{ .carbon_g = 0, .nitrogen_g = 0, .phosphorus_g = 0 };
    const main_sapwood = state.branch_sapwood_carbon_g[main_branch];
    const total_sapwood = main_sapwood + other_sapwood;
    if (total_sapwood <= 0) return error.InvalidBranchSapwoodPool;
    const initial_total_reserve_c = state.branch_reserve_carbon_g[main_branch] + state.branch_reserve_carbon_g[other_branch];
    const carbon_difference = (state.branch_reserve_carbon_g[main_branch] * other_sapwood - state.branch_reserve_carbon_g[other_branch] * main_sapwood) / total_sapwood;
    const carbon_flux = carbon_exchange_per_h * carbon_difference * timestep_h;
    const main_c = state.branch_reserve_carbon_g[main_branch] - carbon_flux;
    const other_c = state.branch_reserve_carbon_g[other_branch] + carbon_flux;
    if (main_c < 0 or other_c < 0) return error.BranchReserveExchangeExhaustedCarbon;
    var nitrogen_flux: f64 = 0;
    var phosphorus_flux: f64 = 0;
    if (initial_total_reserve_c > presence_threshold_g_c) {
        const nitrogen_difference = (state.branch_reserve_nitrogen_g[main_branch] * other_c - state.branch_reserve_nitrogen_g[other_branch] * main_c) / initial_total_reserve_c;
        const phosphorus_difference = (state.branch_reserve_phosphorus_g[main_branch] * other_c - state.branch_reserve_phosphorus_g[other_branch] * main_c) / initial_total_reserve_c;
        nitrogen_flux = nutrient_exchange_per_h * nitrogen_difference * timestep_h;
        phosphorus_flux = nutrient_exchange_per_h * phosphorus_difference * timestep_h;
    }
    const main_n = state.branch_reserve_nitrogen_g[main_branch] - nitrogen_flux;
    const other_n = state.branch_reserve_nitrogen_g[other_branch] + nitrogen_flux;
    const main_p = state.branch_reserve_phosphorus_g[main_branch] - phosphorus_flux;
    const other_p = state.branch_reserve_phosphorus_g[other_branch] + phosphorus_flux;
    if (main_n < 0 or other_n < 0 or main_p < 0 or other_p < 0) return error.BranchReserveExchangeExhaustedNutrient;
    state.branch_reserve_carbon_g[main_branch] = main_c;
    state.branch_reserve_carbon_g[other_branch] = other_c;
    state.branch_reserve_nitrogen_g[main_branch] = main_n;
    state.branch_reserve_nitrogen_g[other_branch] = other_n;
    state.branch_reserve_phosphorus_g[main_branch] = main_p;
    state.branch_reserve_phosphorus_g[other_branch] = other_p;
    return .{ .carbon_g = carbon_flux, .nitrogen_g = nitrogen_flux, .phosphorus_g = phosphorus_flux };
}
