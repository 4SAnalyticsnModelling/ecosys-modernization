//! `plant_harvest_source_order` declarations: exchange.
//!
//! Split out of `plant_harvest_source_order.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const management = @import("plant_management.zig");
const canopy = @import("../canopy/photosynthesis/photosynthesis.zig");
const phenology = @import("../plant/lifecycle/phenology.zig");
const litter_partition = @import("../plant/partition/litter.zig");
const grazing_manure = @import("grazing_manure.zig");
const __parent = @import("plant_harvest_runtime.zig");

pub const SourceOrderSoilPlantExchangeInput = struct {
    organic_carbon_exchange_g_c_step: f64,
    organic_nitrogen_exchange_g_n_step: f64,
    ammonium_uptake_g_n_step: f64,
    nitrate_uptake_g_n_step: f64,
    root_fixation_g_n_step: f64,
    canopy_fixation_g_n_step: f64,
    organic_phosphorus_exchange_g_p_step: f64,
    dihydrogen_phosphate_uptake_g_p_step: f64,
    hydrogen_phosphate_uptake_g_p_step: f64,
    cumulative_soil_exchange: canopy.ElementalMass,
    cumulative_fixation_g_n: f64,
    cumulative_plant_carbon_g_c: f64,
    cumulative_respired_carbon_g_c: f64,
};

pub const SourceOrderSoilPlantExchangeResult = struct {
    hourly_net_exchange: canopy.ElementalMass,
    cumulative_soil_exchange: canopy.ElementalMass,
    cumulative_fixation_g_n: f64,
    cumulative_net_primary_productivity_g_c: f64,
};

/// Exact GROSUB 11663-11675 hourly and cumulative soil-plant accounting.
pub fn sourceOrderAccumulateSoilPlantExchange(
    input: SourceOrderSoilPlantExchangeInput,
) !SourceOrderSoilPlantExchangeResult {
    inline for (@typeInfo(SourceOrderSoilPlantExchangeInput).@"struct".fields) |field| {
        const value = @field(input, field.name);
        if (field.type == f64) {
            if (!std.math.isFinite(value))
                return error.InvalidSoilPlantExchange;
        } else inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |element|
            if (!std.math.isFinite(@field(value, element.name)))
                return error.InvalidSoilPlantExchange;
    }
    const result: SourceOrderSoilPlantExchangeResult = .{
        .hourly_net_exchange = .{
            .carbon_g = input.organic_carbon_exchange_g_c_step,
            .nitrogen_g = input.organic_nitrogen_exchange_g_n_step +
                input.ammonium_uptake_g_n_step +
                input.nitrate_uptake_g_n_step +
                input.root_fixation_g_n_step,
            .phosphorus_g = input.organic_phosphorus_exchange_g_p_step +
                input.dihydrogen_phosphate_uptake_g_p_step +
                input.hydrogen_phosphate_uptake_g_p_step,
        },
        .cumulative_soil_exchange = .{
            .carbon_g = input.cumulative_soil_exchange.carbon_g +
                input.organic_carbon_exchange_g_c_step,
            .nitrogen_g = input.cumulative_soil_exchange.nitrogen_g +
                input.organic_nitrogen_exchange_g_n_step +
                input.ammonium_uptake_g_n_step +
                input.nitrate_uptake_g_n_step,
            .phosphorus_g = input.cumulative_soil_exchange.phosphorus_g +
                input.organic_phosphorus_exchange_g_p_step +
                input.dihydrogen_phosphate_uptake_g_p_step +
                input.hydrogen_phosphate_uptake_g_p_step,
        },
        .cumulative_fixation_g_n = input.cumulative_fixation_g_n +
            input.root_fixation_g_n_step +
            input.canopy_fixation_g_n_step,
        .cumulative_net_primary_productivity_g_c = input.cumulative_plant_carbon_g_c +
            input.cumulative_respired_carbon_g_c,
    };
    inline for (@typeInfo(SourceOrderSoilPlantExchangeResult).@"struct".fields) |field| {
        const value = @field(result, field.name);
        if (field.type == f64) {
            if (!std.math.isFinite(value))
                return error.NonFiniteSoilPlantExchange;
        } else inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |element|
            if (!std.math.isFinite(@field(value, element.name)))
                return error.NonFiniteSoilPlantExchange;
    }
    return result;
}

pub const SourceOrderLitterfallAccumulationInput = struct {
    carbon_g_c_by_position_fraction_layer: []const f64,
    nitrogen_g_n_by_position_fraction_layer: []const f64,
    phosphorus_g_p_by_position_fraction_layer: []const f64,
    layer_count_including_surface: usize,
    preceding_cumulative_surface_litter: canopy.ElementalMass,
    preceding_hourly_litter: canopy.ElementalMass,
    preceding_cumulative_litter: canopy.ElementalMass,
    preceding_layer_carbon_g_c: []const f64,
};

pub const SourceOrderLitterfallAccumulationResult = struct {
    cumulative_surface_litter: canopy.ElementalMass,
    hourly_litter: canopy.ElementalMass,
    cumulative_litter: canopy.ElementalMass,
    layer_carbon_g_c: []f64,

    pub fn deinit(self: SourceOrderLitterfallAccumulationResult, allocator: std.mem.Allocator) void {
        allocator.free(self.layer_carbon_g_c);
    }
};

/// Exact GROSUB 12636-12653 position/fraction/layer litter accumulation.
pub fn sourceOrderAccumulateLitterfall(
    allocator: std.mem.Allocator,
    input: SourceOrderLitterfallAccumulationInput,
) !SourceOrderLitterfallAccumulationResult {
    if (input.layer_count_including_surface == 0 or
        input.preceding_layer_carbon_g_c.len != input.layer_count_including_surface)
        return error.InvalidLitterfallAccumulationDimensions;
    const values_per_element = std.math.mul(
        usize,
        2 * 5,
        input.layer_count_including_surface,
    ) catch return error.InvalidLitterfallAccumulationDimensions;
    inline for (.{
        input.carbon_g_c_by_position_fraction_layer,
        input.nitrogen_g_n_by_position_fraction_layer,
        input.phosphorus_g_p_by_position_fraction_layer,
    }) |values| {
        if (values.len != values_per_element)
            return error.InvalidLitterfallAccumulationDimensions;
        for (values) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLitterfallAccumulationInput;
    }
    inline for (.{
        input.preceding_cumulative_surface_litter,
        input.preceding_hourly_litter,
        input.preceding_cumulative_litter,
    }) |ledger| inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
        const value = @field(ledger, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLitterfallAccumulationInput;
    };
    for (input.preceding_layer_carbon_g_c) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLitterfallAccumulationInput;

    const layer_carbon = try allocator.dupe(f64, input.preceding_layer_carbon_g_c);
    errdefer allocator.free(layer_carbon);
    var surface = input.preceding_cumulative_surface_litter;
    var hourly = input.preceding_hourly_litter;
    var cumulative = input.preceding_cumulative_litter;
    for (0..2) |position| {
        for (0..5) |fraction| {
            const first = (position * 5 + fraction) *
                input.layer_count_including_surface;
            surface.carbon_g += input.carbon_g_c_by_position_fraction_layer[first];
            surface.nitrogen_g += input.nitrogen_g_n_by_position_fraction_layer[first];
            surface.phosphorus_g += input.phosphorus_g_p_by_position_fraction_layer[first];
            for (0..input.layer_count_including_surface) |layer| {
                const index = first + layer;
                const carbon = input.carbon_g_c_by_position_fraction_layer[index];
                const nitrogen = input.nitrogen_g_n_by_position_fraction_layer[index];
                const phosphorus = input.phosphorus_g_p_by_position_fraction_layer[index];
                hourly.carbon_g += carbon;
                hourly.nitrogen_g += nitrogen;
                hourly.phosphorus_g += phosphorus;
                cumulative.carbon_g += carbon;
                cumulative.nitrogen_g += nitrogen;
                cumulative.phosphorus_g += phosphorus;
                layer_carbon[layer] += carbon;
            }
        }
    }
    inline for (.{ surface, hourly, cumulative }) |ledger|
        inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
            if (!std.math.isFinite(@field(ledger, field.name)))
                return error.NonFiniteLitterfallAccumulation;
    for (layer_carbon) |value| if (!std.math.isFinite(value))
        return error.NonFiniteLitterfallAccumulation;
    return .{
        .cumulative_surface_litter = surface,
        .hourly_litter = hourly,
        .cumulative_litter = cumulative,
        .layer_carbon_g_c = layer_carbon,
    };
}
