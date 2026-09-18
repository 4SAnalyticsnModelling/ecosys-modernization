const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("ecosys_ng", .{
        .root_source_file = b.path("src/module_index.zig"),
        .target = target,
        .optimize = optimize,
    });

    const executable = b.addExecutable(.{
        .name = "ecosys_ng",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ecosys_ng.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ecosys_ng", .module = module }},
        }),
    });
    const install_executable = b.addInstallArtifact(executable, .{
        .dest_dir = .{ .override = .{ .custom = "../ecosys-ng-bin" } },
    });
    b.getInstallStep().dependOn(&install_executable.step);

    const run_cmd = b.addRunArtifact(executable);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run ecosys-ng").dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");

    const tests = b.addTest(.{ .root_module = module });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // src/ecosys_ng.zig is a second module root, not reachable from
    // src/module_index.zig, so its tests need their own test artifact.
    const executable_tests = b.addTest(.{ .root_module = executable.root_module });
    test_step.dependOn(&b.addRunArtifact(executable_tests).step);
}
