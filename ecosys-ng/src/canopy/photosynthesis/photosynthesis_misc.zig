//! `photosynthesis` declarations: misc.
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

pub const C4CarbonFluxes = struct {
    mesophyll_to_bundle_sheath_g_c: f64,
    bundle_sheath_decarboxylation_g_c: f64,
    bundle_sheath_co2_leakage_g_c: f64,
};

pub const C4CarbonParameters = struct {
    bundle_sheath_water_g_per_g_c: f64,
    mesophyll_water_g_per_g_c: f64,
    co2_concentration_umol_per_l_per_g_c_per_g_leaf_c: f64,
    decarboxylation_fraction_per_h: f64,
    co2_decarboxylation_inhibition_umol_per_l: f64,
    decarboxylated_co2_fraction: f64,
    leakage_g_c_per_umol_per_l_g_leaf_c_h: f64,
    mesophyll_feedback_half_saturation_umol_per_l: f64,
    co2_compensation_umol_per_l: f64,
    electron_requirement_umol_e_per_umol_co2: f64,

    pub fn validate(self: C4CarbonParameters) !void {
        inline for (@typeInfo(C4CarbonParameters).@"struct".fields) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidC4CarbonParameter;
        }
        if (self.bundle_sheath_water_g_per_g_c <= 0 or self.mesophyll_water_g_per_g_c <= 0 or self.co2_concentration_umol_per_l_per_g_c_per_g_leaf_c <= 0 or self.co2_decarboxylation_inhibition_umol_per_l <= 0 or self.decarboxylated_co2_fraction > 1 or self.mesophyll_feedback_half_saturation_umol_per_l <= 0 or self.co2_compensation_umol_per_l < 0 or self.electron_requirement_umol_e_per_umol_co2 <= 0) return error.InvalidC4CarbonParameter;
    }
};

pub fn sourceC4CarbonParameters() C4CarbonParameters {
    return .{
        .bundle_sheath_water_g_per_g_c = 1.2,
        .mesophyll_water_g_per_g_c = 4.8,
        .co2_concentration_umol_per_l_per_g_c_per_g_leaf_c = 0.083e9,
        .decarboxylation_fraction_per_h = 0.025,
        .co2_decarboxylation_inhibition_umol_per_l = 1000,
        .decarboxylated_co2_fraction = 0.02,
        .leakage_g_c_per_umol_per_l_g_leaf_c_h = 5.0e-7,
        .mesophyll_feedback_half_saturation_umol_per_l = 5.0e6,
        .co2_compensation_umol_per_l = 0.5,
        .electron_requirement_umol_e_per_umol_co2 = 3,
    };
}

/// GROSUB C4 mesophyll↔bundle-sheath transaction for one runtime node.
pub fn advanceC4CarbonPools(state: *group_state.State, node: usize, mesophyll_fixation_g_c: f64, bundle_sheath_fixation_g_c: f64, intercellular_co2_umol_per_l: f64, parameters: C4CarbonParameters, timestep_h: f64) !C4CarbonFluxes {
    inline for (.{ mesophyll_fixation_g_c, bundle_sheath_fixation_g_c, intercellular_co2_umol_per_l, timestep_h }) |value| if (!std.math.isFinite(value)) return error.NonFiniteC4CarbonInput;
    try parameters.validate();
    if (node >= state.node_leaf_carbon_g.len) return error.CanopyNodeIndexOutOfBounds;
    if (mesophyll_fixation_g_c < 0 or bundle_sheath_fixation_g_c < 0 or intercellular_co2_umol_per_l < 0 or timestep_h <= 0) return error.InvalidC4CarbonInput;
    const leaf_carbon = state.node_leaf_carbon_g[node];
    if (leaf_carbon <= 0) return error.C4NodeHasNoLeafCarbon;
    const exchange = try c4_mesophyll_bundle_exchange.exchange(.{
        .bundle_sheath_nonstructural_carbon_g_c = state.node_c3_nonstructural_carbon_g[node],
        .mesophyll_nonstructural_carbon_g_c = state.node_c4_mesophyll_nonstructural_carbon_g[node],
        .bundle_sheath_fixation_g_c_per_timestep = bundle_sheath_fixation_g_c,
        .mesophyll_fixation_g_c_per_timestep = mesophyll_fixation_g_c,
        .leaf_carbon_g_c = leaf_carbon,
        .bundle_sheath_water_g_h2o_per_g_c = parameters.bundle_sheath_water_g_per_g_c,
        .mesophyll_water_g_h2o_per_g_c = parameters.mesophyll_water_g_per_g_c,
        .timestep_h = timestep_h,
    });
    var bundle_nonstructural = exchange.bundle_sheath_nonstructural_carbon_g_c;
    const mesophyll_nonstructural = exchange.mesophyll_nonstructural_carbon_g_c;
    const transfer = exchange.mesophyll_to_bundle_sheath_carbon_g_c;
    const bundle_co2_concentration = @max(0.0, parameters.co2_concentration_umol_per_l_per_g_c_per_g_leaf_c * state.node_bundle_sheath_co2_carbon_g[node] / (leaf_carbon * parameters.bundle_sheath_water_g_per_g_c));
    const decarboxylation = parameters.decarboxylation_fraction_per_h * bundle_nonstructural / (1.0 + bundle_co2_concentration / parameters.co2_decarboxylation_inhibition_umol_per_l) * timestep_h;
    bundle_nonstructural -= decarboxylation;
    const decarboxylated_bicarbonate_fraction = 1.0 - parameters.decarboxylated_co2_fraction;
    var co2_carbon = state.node_bundle_sheath_co2_carbon_g[node] + parameters.decarboxylated_co2_fraction * decarboxylation;
    var bicarbonate_carbon = state.node_bundle_sheath_bicarbonate_carbon_g[node] + decarboxylated_bicarbonate_fraction * decarboxylation;
    const leakage = parameters.leakage_g_c_per_umol_per_l_g_leaf_c_h * (bundle_co2_concentration - intercellular_co2_umol_per_l) * leaf_carbon * parameters.bundle_sheath_water_g_per_g_c * timestep_h;
    co2_carbon -= parameters.decarboxylated_co2_fraction * leakage;
    bicarbonate_carbon -= decarboxylated_bicarbonate_fraction * leakage;
    inline for (.{ bundle_nonstructural, mesophyll_nonstructural, co2_carbon, bicarbonate_carbon }) |value| if (value < 0 or !std.math.isFinite(value)) {
        std.log.err("C4 node carbon transaction failed: node={d} bundle_nonstructural_g={e} mesophyll_nonstructural_g={e} co2_carbon_g={e} bicarbonate_carbon_g={e}", .{ node, bundle_nonstructural, mesophyll_nonstructural, co2_carbon, bicarbonate_carbon });
        return error.C4CarbonPoolExhausted;
    };
    state.node_c3_nonstructural_carbon_g[node] = bundle_nonstructural;
    state.node_c4_mesophyll_nonstructural_carbon_g[node] = mesophyll_nonstructural;
    state.node_bundle_sheath_co2_carbon_g[node] = co2_carbon;
    state.node_bundle_sheath_bicarbonate_carbon_g[node] = bicarbonate_carbon;
    return .{ .mesophyll_to_bundle_sheath_g_c = transfer, .bundle_sheath_decarboxylation_g_c = decarboxylation, .bundle_sheath_co2_leakage_g_c = leakage };
}

pub const LeafNutrientRemobilization = struct { nitrogen_g: f64, phosphorus_g: f64 };

/// Exact GROSUB 9303-9315 C4-intermediate retention selector.
pub fn sourceOrderC4IntermediateRetention(
    is_c4: bool,
    initial_host_mobile_carbon_g_c: f64,
    remaining_host_mobile_carbon_g_c: f64,
    plant_presence_threshold_g_c: f64,
) !f64 {
    inline for (.{ initial_host_mobile_carbon_g_c, remaining_host_mobile_carbon_g_c, plant_presence_threshold_g_c }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidHarvestMass;
    if (remaining_host_mobile_carbon_g_c > initial_host_mobile_carbon_g_c)
        return error.InvalidHarvestMass;
    if (!is_c4 or initial_host_mobile_carbon_g_c <= plant_presence_threshold_g_c) return 1;
    return remaining_host_mobile_carbon_g_c / initial_host_mobile_carbon_g_c;
}
