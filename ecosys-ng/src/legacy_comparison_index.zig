//! Aggregator for the legacy-comparison modules.
//!
//! Exists so `tools/compare_legacy.zig` (and lane A8's inventory front end) can
//! import the comparison machinery as one module without touching
//! `src/module_index.zig`, which lane A1 owns. Any front end should import this rather
//! than reaching at the individual files.

pub const comparison = @import("validation/legacy_comparison.zig");
pub const column_map = @import("validation/legacy_comparison_column_map.zig");
pub const report = @import("validation/legacy_comparison_report.zig");
pub const driver = @import("validation/legacy_comparison_driver.zig");
pub const attribution = @import("validation/legacy_comparison_attribution.zig");

test {
    // Zig 0.16 has no `refAllDeclsRecursive`, so reference each module
    // explicitly. This is better anyway: it names exactly what the harness test
    // step is expected to cover, so dropping a module is a visible edit.
    _ = comparison;
    _ = column_map;
    _ = report;
    _ = driver;
    _ = attribution;
}
