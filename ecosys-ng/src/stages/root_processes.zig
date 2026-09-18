//! Root metabolism and root nutrient uptake for the hourly step.
//!
//! Extracted verbatim from `ecosys_ng.zig` so the entry point holds only
//! `main`. Declaration bodies are unchanged.
//!
//! The declarations live in the `_<group>.zig` files beside this one and
//! are re-exported here, so `module.name` still resolves for every caller
//! and the grouping is a file layout choice rather than an API change.

const group_metabolism = @import("root_processes_metabolism.zig");
const group_uptake = @import("root_processes_uptake.zig");

// metabolism
pub const applyRootMetabolism = group_metabolism.applyRootMetabolism;

// uptake
pub const applyRootNutrientUptake = group_uptake.applyRootNutrientUptake;
