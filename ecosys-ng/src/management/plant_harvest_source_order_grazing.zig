//! `plant_harvest_source_order` declarations: grazing.
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
const group_harvest = @import("plant_harvest_source_order_harvest.zig");

pub const SourceOrderGrazingLitterLedgerState = struct {
    hourly_litter: canopy.ElementalMass,
    cumulative_litter: canopy.ElementalMass,
    cumulative_aboveground_litter: canopy.ElementalMass,
    surface_litter_carbon_g_c: f64,
    accumulated_application: canopy.ElementalMass,
};

pub const SourceOrderGrazingLitterResult = struct {
    returned_mass: canopy.ElementalMass,
    state: SourceOrderGrazingLitterLedgerState,
    manure: grazing_manure.Products,
};

/// Exact GROSUB 10847-10906 grazing litter ledgers and manure deposition.
pub fn sourceOrderGrazingLitterLedgers(
    harvest_code: i8,
    residue_by_component: [group_harvest.harvest_product_component_count]canopy.ElementalMass,
    direct_litter_by_component: [group_harvest.harvest_product_component_count]canopy.ElementalMass,
    current: SourceOrderGrazingLitterLedgerState,
) !SourceOrderGrazingLitterResult {
    const kind: management.HarvestKind = switch (harvest_code) {
        4 => .animal_grazing,
        6 => .insect_grazing,
        else => return error.InvalidGrazingLitterCode,
    };
    const residue = try group_harvest.sumHarvestProductComponents(residue_by_component);
    const direct = try group_harvest.sumHarvestProductComponents(direct_litter_by_component);
    inline for (@typeInfo(SourceOrderGrazingLitterLedgerState).@"struct".fields) |field| {
        if (field.type == canopy.ElementalMass) {
            const mass = @field(current, field.name);
            inline for (.{ mass.carbon_g, mass.nitrogen_g, mass.phosphorus_g }) |value|
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidGrazingLitterLedger;
        } else {
            const value = @field(current, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidGrazingLitterLedger;
        }
    }
    const returned: canopy.ElementalMass = .{
        .carbon_g = residue.carbon_g + direct.carbon_g,
        .nitrogen_g = residue.nitrogen_g + direct.nitrogen_g,
        .phosphorus_g = residue.phosphorus_g + direct.phosphorus_g,
    };
    var next = current;
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
        @field(next.hourly_litter, field.name) += @field(returned, field.name);
        @field(next.cumulative_litter, field.name) += @field(returned, field.name);
        @field(next.accumulated_application, field.name) += @field(returned, field.name);
    }
    next.cumulative_aboveground_litter.carbon_g += returned.carbon_g;
    // Preserve source lines 10854-10855: N/P use the just-updated total
    // cumulative ledger rather than their prior above-ground ledger.
    next.cumulative_aboveground_litter.nitrogen_g =
        next.cumulative_litter.nitrogen_g + returned.nitrogen_g;
    next.cumulative_aboveground_litter.phosphorus_g =
        next.cumulative_litter.phosphorus_g + returned.phosphorus_g;
    next.surface_litter_carbon_g_c += returned.carbon_g;
    inline for (@typeInfo(SourceOrderGrazingLitterLedgerState).@"struct".fields) |field| {
        if (field.type == canopy.ElementalMass) {
            const mass = @field(next, field.name);
            inline for (.{ mass.carbon_g, mass.nitrogen_g, mass.phosphorus_g }) |value|
                if (!std.math.isFinite(value) or value < 0)
                    return error.NonFiniteGrazingLitterLedger;
        } else if (!std.math.isFinite(@field(next, field.name)) or @field(next, field.name) < 0)
            return error.NonFiniteGrazingLitterLedger;
    }
    return .{
        .returned_mass = returned,
        .state = next,
        .manure = try grazing_manure.partition(kind, returned),
    };
}
