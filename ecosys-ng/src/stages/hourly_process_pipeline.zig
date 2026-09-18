//! The hourly science step and the atomic state-generation state_updates.
//!
//! Extracted verbatim from `ecosys_ng.zig` so the entry point holds only
//! `main`. Declaration bodies are unchanged.
//!
//! The declarations live in the `_<group>.zig` files beside this one and
//! are re-exported here, so `module.name` still resolves for every caller
//! and the grouping is a file layout choice rather than an API change.

const group_timestep_finalize = @import("hourly_timestep_finalize.zig");
const group_driver = @import("hourly_process_driver.zig");
const group_gas_surface_water = @import("hourly_gas_surface_water.zig");
const group_heat_water_solute = @import("hourly_heat_water_solute.zig");
const group_sediment = @import("hourly_sediment.zig");
const group_snow_energy = @import("hourly_snow_energy.zig");
const group_support = @import("hourly_process_support.zig");
const group_vegetation = @import("hourly_vegetation.zig");

// state_updates

// driver
pub const executeHourlyScience = group_driver.executeHourlyScience;

// gas surface water

// heat water solute

// sediment

// snow energy

// support

// vegetation

// `@import` alone does not pull a file's tests into `zig build test`
// analysis (TEST-DISCOVERY-GAP-STAGES-001) -- without an explicit
// reference here, every sibling group's `test` blocks silently never run
// despite `zig build check` staying clean.
test {
    _ = group_timestep_finalize;
    _ = group_driver;
    _ = group_gas_surface_water;
    _ = group_heat_water_solute;
    _ = group_sediment;
    _ = group_snow_energy;
    _ = group_support;
    _ = group_vegetation;
}
