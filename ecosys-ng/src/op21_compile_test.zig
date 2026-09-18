const removal = @import("surface/litter_removal.zig");

test "operation 21 module compiles from the repository module root" {
    _ = removal.RuntimeContext;
}
