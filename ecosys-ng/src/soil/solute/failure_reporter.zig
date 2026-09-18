const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const solver = @import("reaction_solver.zig");
const snapshot = @import("failure_snapshot.zig");

pub const Request = struct {
    io: std.Io,
    directory: std.Io.Dir,
    file_path: []const u8,
    context: snapshot.Context,
};

pub fn captureAndWrite(
    allocator: std.mem.Allocator,
    request: Request,
    state: *const chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
    options: solver.Options,
) !void {
    var replay_case = try snapshot.capture(
        allocator,
        state,
        cell_index,
        parameters,
        options,
        request.context,
    );
    defer replay_case.deinit();
    const buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(buffer);
    var atomic_file = try request.directory.createFileAtomic(
        request.io,
        request.file_path,
        .{ .replace = true },
    );
    defer atomic_file.deinit(request.io);
    var writer = atomic_file.file.writerStreaming(request.io, buffer);
    try snapshot.write(allocator, &writer.interface, &replay_case);
    try writer.interface.flush();
    try atomic_file.file.sync(request.io);
    try atomic_file.replace(request.io);
    std.log.info(
        "SOLUTE failure snapshot written: path={s}",
        .{request.file_path},
    );
}

pub fn reportPreservingSolverError(
    allocator: std.mem.Allocator,
    request: Request,
    state: *const chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
    options: solver.Options,
    solver_error: anyerror,
) anyerror {
    captureAndWrite(
        allocator,
        request,
        state,
        cell_index,
        parameters,
        options,
    ) catch |reporter_error| {
        std.log.warn(
            "SOLUTE failure snapshot write failed: path={s} reporter_error={s} preserved_solver_error={s}",
            .{
                request.file_path,
                @errorName(reporter_error),
                @errorName(solver_error),
            },
        );
    };
    return solver_error;
}

test "reporter atomically preserves a replayable failure before returning the solver error" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    const context: snapshot.Context = .{
        .execution_id = 1,
        .scenario_id = 2,
        .repeat_id = 3,
        .scene_id = 4,
        .scene_hour = 16,
        .year = 1998,
        .day_of_year = 1,
        .hour = 16,
        .global_cell_id = 5,
        .soil_layer_id = 6,
        .packed_cell_index = 0,
    };
    const preserved = reportPreservingSolverError(
        std.testing.allocator,
        .{
            .io = std.testing.io,
            .directory = temporary.dir,
            .file_path = "solute-failure.bin",
            .context = context,
        },
        &state,
        0,
        std.mem.zeroes(chemistry.ReactionParameters),
        .{},
        error.SoluteReactionSolverStagnated,
    );
    try std.testing.expectEqual(
        error.SoluteReactionSolverStagnated,
        preserved,
    );
    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "solute-failure.bin",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var replay = try snapshot.read(std.testing.allocator, &reader);
    defer replay.deinit();
    try std.testing.expect(std.meta.eql(context, replay.context));
    try std.testing.expectEqual(@as(usize, 1), replay.state.cell_count);
}

test "reporter failure publishes no partial file and preserves the solver error" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    const preserved = reportPreservingSolverError(
        std.testing.allocator,
        .{
            .io = std.testing.io,
            .directory = temporary.dir,
            .file_path = "solute-failure.bin",
            .context = .{},
        },
        &state,
        1,
        std.mem.zeroes(chemistry.ReactionParameters),
        .{},
        error.SoluteReactionSolverStagnated,
    );
    try std.testing.expectEqual(
        error.SoluteReactionSolverStagnated,
        preserved,
    );
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile(std.testing.io, "solute-failure.bin", .{}),
    );
}
