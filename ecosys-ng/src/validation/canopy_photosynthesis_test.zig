//! Tests for `photosynthesis.zig`.
//!
//! Extracted verbatim so the module beside it contains only the model
//! code. Tests that use private declarations of that module stay there,
//! since a sibling file can only reach `pub` declarations.
//!
//! Split into parts only to keep each file reviewable. The parts
//! share the original header imports and are otherwise verbatim.

test {
    _ = @import("canopy_photosynthesis_test_part1.zig");
    _ = @import("canopy_photosynthesis_test_part2.zig");
    _ = @import("canopy_photosynthesis_test_part3.zig");
}
