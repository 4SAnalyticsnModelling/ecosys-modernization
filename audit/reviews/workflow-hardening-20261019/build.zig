const std = @import("std");
pub fn build(b: *std.Build) void {
 const m=b.createModule(.{.root_source_file=b.path("fixture.zig"),.target=b.standardTargetOptions(.{})});
 const tests=b.addTest(.{.root_module=m});
 b.step("test-module", "Synthetic root accounting").dependOn(&b.addRunArtifact(tests).step);
}
