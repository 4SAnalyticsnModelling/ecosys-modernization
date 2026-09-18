const dispatch = @import("management/disturbance_management_dispatch.zig");

test "production tillage disturbance binding compiles" {
    _ = dispatch.applyEvent;
}
