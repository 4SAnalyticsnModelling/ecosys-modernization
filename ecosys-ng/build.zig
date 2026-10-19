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
    // Zig 0.17: `--` passthrough args are applied to the Run step by the build
    // runner itself; `std.Build.args` no longer exists, so no explicit b.args line.
    b.step("run", "Run ecosys-ng").dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const test_filters: []const []const u8 = if (b.option([]const u8, "test-filter", "Run matching tests in both module roots")) |filter|
        b.allocator.dupe([]const u8, &.{filter}) catch @panic("out of memory")
    else
        &.{};

    const tests = b.addTest(.{ .root_module = module, .filters = test_filters });
    const module_run = b.addRunArtifact(tests);
    test_step.dependOn(&module_run.step);
    b.step("test-module", "Run module_index tests with separate accounting").dependOn(&module_run.step);

    // src/ecosys_ng.zig is a second module root, not reachable from
    // src/module_index.zig, so its tests need their own test artifact.
    const executable_tests = b.addTest(.{ .root_module = executable.root_module, .filters = test_filters });
    const executable_run = b.addRunArtifact(executable_tests);
    test_step.dependOn(&executable_run.step);
    b.step("test-executable", "Run ecosys_ng tests with separate accounting").dependOn(&executable_run.step);
}
