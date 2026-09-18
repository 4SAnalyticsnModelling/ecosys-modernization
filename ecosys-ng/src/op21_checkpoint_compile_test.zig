const organic_checkpoint = @import("io/checkpoint/soil_organic_checkpoint.zig");
const geometry_checkpoint = @import("io/checkpoint/soil_geometry_checkpoint.zig");
const balance_checkpoint = @import("io/checkpoint/landscape_mass_balance_checkpoint.zig");

test "operation 21 checkpoint owners round trips compile from the repository module root" {
    _ = organic_checkpoint.View;
    _ = geometry_checkpoint.View;
    _ = balance_checkpoint.State;
}
