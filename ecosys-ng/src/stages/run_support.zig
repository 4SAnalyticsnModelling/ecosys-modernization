//! Input-path resolution, output catalogs and calendar helpers.
//!
//! Extracted verbatim from `ecosys_ng.zig` so the entry point holds only
//! `main`. Declaration bodies are unchanged.

const std = @import("std");
const ecosys = @import("ecosys_ng");
/// Resolves the species input file name used to label a plant output file, so
/// output names carry a readable species instead of the source model's positional
/// digit.
///
/// The runscript declares a population capacity (five in the Ottawa example) while a
/// scene may assign fewer species, so indices beyond the assigned set are real and
/// expected. Those populations carry no species and would emit all-zero rows, so
/// this returns `null` for them and the caller skips the write entirely: an output
/// file is created only for `soil_or_eco` and for genuinely assigned species. The
/// same applies to a run with no plant assignments at all, which then writes no
/// plant files rather than a set of empty ones.
pub fn outputSpeciesLabel(
    assignments: ?ecosys.plant_assignment.Assignments,
    unit_by_cell: ?[]const usize,
    cell: usize,
    species: usize,
) ?[]const u8 {
    if (assignments) |resolved| if (unit_by_cell) |units| {
        if (cell < units.len) {
            const unit_index = units[cell];
            if (unit_index < resolved.units.len) {
                const assigned = resolved.units[unit_index].species;
                if (species < assigned.len) return assigned[species].species_file;
            }
        }
    };
    return null;
}

pub fn sameCalendarDay(left: ecosys.weather.Timestamp, right: ecosys.weather.Timestamp) bool {
    return left.year == right.year and left.day_of_year == right.day_of_year and left.month == right.month and left.day_of_month == right.day_of_month;
}

pub fn sameWeatherTimestamp(left: ecosys.weather.Timestamp, right: ecosys.weather.Timestamp) bool {
    return left.year == right.year and
        left.day_of_year == right.day_of_year and
        left.month == right.month and
        left.day_of_month == right.day_of_month and
        left.hour == right.hour and
        left.minute == right.minute;
}

/// Weather files may omit a year because the runscript owns the calendar
/// year. Persisted orchestration timestamps must be self-contained: daily
/// closeout can consume the last accepted timestamp before the first resumed
/// observation has a chance to supply the fallback year again.
pub fn withWeatherYear(timestamp: ecosys.weather.Timestamp, fallback_year: u16) ecosys.weather.Timestamp {
    var resolved = timestamp;
    if (resolved.year == null) resolved.year = fallback_year;
    return resolved;
}

pub fn dayOfYearFromTimestamp(timestamp: ecosys.weather.Timestamp) !u16 {
    if (timestamp.day_of_year) |day| return day;
    const date = try ecosys.plant_management_dispatch.dateFromTimestamp(timestamp);
    return try (ecosys.plant_management.PackedDate{ .day = date.day, .month = date.month, .year = date.year }).dayOfYear(date.year);
}

test "weather year fallback makes a resumed timestamp self-contained" {
    const source: ecosys.weather.Timestamp = .{
        .year = null,
        .day_of_year = 2,
        .month = null,
        .day_of_month = null,
        .hour = 24,
        .minute = 0,
    };
    const resolved = withWeatherYear(source, 1998);
    try std.testing.expectEqual(@as(?u16, 1998), resolved.year);
    try std.testing.expectEqual(source.day_of_year, resolved.day_of_year);
    try std.testing.expectEqual(source.hour, resolved.hour);

    const explicit = withWeatherYear(.{
        .year = 2001,
        .day_of_year = 2,
        .month = null,
        .day_of_month = null,
        .hour = 24,
        .minute = 0,
    }, 1998);
    try std.testing.expectEqual(@as(?u16, 2001), explicit.year);
}

pub fn soilOutputCatalog(allocator: std.mem.Allocator, editor_index: usize, layers: usize) !ecosys.soil_output_catalog.Catalog {
    return switch (editor_index) {
        0 => ecosys.soil_output_catalog.carbon(allocator, layers, layers, layers),
        1 => ecosys.soil_output_catalog.water(allocator, layers),
        2 => ecosys.soil_output_catalog.nitrogen(allocator, layers, layers),
        3 => ecosys.soil_output_catalog.phosphorus(allocator),
        4 => ecosys.soil_output_catalog.heat(allocator, layers),
        5 => ecosys.soil_output_catalog.dailyCarbon(allocator, layers),
        6 => ecosys.soil_output_catalog.dailyWater(allocator, layers, layers, layers),
        7 => ecosys.soil_output_catalog.dailyNitrogen(allocator, layers),
        8 => ecosys.soil_output_catalog.dailyPhosphorus(allocator, layers),
        9 => ecosys.soil_output_catalog.dailyHeat(allocator, layers, layers),
        else => error.OutputEditorIndexOutOfBounds,
    };
}

pub fn dailySoilWaterPotentialLayerCount(soil_layers: usize) usize {
    return soil_layers;
}

pub fn plantOutputCatalog(allocator: std.mem.Allocator, editor_index: usize, layers: usize) !ecosys.plant_output_catalog.Catalog {
    return switch (editor_index) {
        0 => ecosys.plant_output_catalog.carbon(allocator),
        1 => ecosys.plant_output_catalog.water(allocator, layers),
        2 => ecosys.plant_output_catalog.nitrogen(allocator, layers),
        3 => ecosys.plant_output_catalog.phosphorus(allocator, layers),
        4 => ecosys.plant_output_catalog.heat(allocator),
        5 => ecosys.plant_output_catalog.dailyCarbon(allocator, layers),
        6 => ecosys.plant_output_catalog.dailyWater(allocator),
        7 => ecosys.plant_output_catalog.dailyNitrogen(allocator),
        8 => ecosys.plant_output_catalog.dailyPhosphorus(allocator),
        9 => ecosys.plant_output_catalog.dailyDevelopment(allocator),
        else => error.OutputEditorIndexOutOfBounds,
    };
}

/// Resolves an input name written in the runscript.
///
/// A name is normally relative to the input root, which the runscript's
/// `input_root` record established. Two further forms are accepted because
/// both occur in real runscripts and neither is ambiguous:
///
///   - the name already includes the root directory, so it resolves from the
///     run directory instead of being joined to the root a second time;
///   - the name's leading directory component is a sibling root, which happens
///     when a selection file that the model reads is filed under the output
///     tree. The component is dropped and the remainder resolved under the
///     input root, because an input is identified by its role rather than by
///     which tree a user filed it in.
///
/// Every candidate is probed by opening the file, so resolution never reports
/// success for a path that does not exist.
pub fn resolveInputPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    runscript_directory: []const u8,
    name: []const u8,
) ![]u8 {
    const run_directory = std.fs.path.dirname(runscript_directory);

    // Name relative to the input root, the documented form.
    if (try openedJoin(allocator, io, &.{ runscript_directory, name })) |path| return path;

    // Name that already spells the root, resolved from the run directory.
    if (run_directory) |directory| {
        if (try openedJoin(allocator, io, &.{ directory, name })) |path| return path;
    }

    // Name whose leading component is a sibling root, re-resolved under the
    // input root without it.
    if (stripLeadingComponent(name)) |remainder| {
        if (try openedJoin(allocator, io, &.{ runscript_directory, remainder })) |path| return path;
        if (run_directory) |directory| {
            if (try openedJoin(allocator, io, &.{ directory, remainder })) |path| return path;
        }
    }

    return error.InputFileNotFound;
}

/// Joins the components and returns the path only if it names a readable file.
fn openedJoin(allocator: std.mem.Allocator, io: std.Io, components: []const []const u8) !?[]u8 {
    const path = try std.fs.path.join(allocator, components);
    errdefer allocator.free(path);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            allocator.free(path);
            return null;
        },
        else => return err,
    };
    file.close(io);
    return path;
}

/// Drops the first path component, or null when there is only one.
fn stripLeadingComponent(name: []const u8) ?[]const u8 {
    const separator = std.mem.indexOfAny(u8, name, "/\\") orelse return null;
    const remainder = name[separator + 1 ..];
    return if (remainder.len == 0) null else remainder;
}

/// Resolves a filename that another input file listed, relative to the
/// directory of the file that listed it.
///
/// A grid-cell mapping in `input/landscape/` naming `f25si98` means the site
/// file sitting beside it, so the reader must not have to repeat the
/// directory on every record. `lister_path` is the full path of the file
/// containing the name; `resolveInputPath` is the fallback for a name given
/// relative to the run root instead.
pub fn resolveSiblingInputPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    runscript_directory: []const u8,
    lister_path: []const u8,
    name: []const u8,
) ![]u8 {
    if (std.fs.path.dirname(lister_path)) |lister_directory| {
        const sibling = try std.fs.path.join(allocator, &.{ lister_directory, name });
        const sibling_file = std.Io.Dir.cwd().openFile(io, sibling, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (sibling_file) |file| {
            file.close(io);
            return sibling;
        }
        allocator.free(sibling);

        // A grid file may sort the files it names into subdirectories by role,
        // so a management grid in `management/soil/` names `f25til98` while the
        // file itself sits in `management/soil/tillage_disturbance/`. Searching
        // one level down keeps the record free of a path that only restates
        // how the run happens to be filed.
        if (try findInSubdirectory(allocator, io, lister_directory, name)) |path| return path;
    }
    if (resolveInputPath(allocator, io, runscript_directory, name)) |path| {
        return path;
    } else |err| switch (err) {
        error.InputFileNotFound => {},
        else => return err,
    }

    // A grid file may also name a file kept in a category directory elsewhere
    // under the input root, such as a plant grid naming a functional type that
    // lives in `plant_functional_types/`. Those categories are shared between
    // grid files, so they are filed once at the root rather than beside any one
    // of them.
    if (try findInSubdirectoryTree(allocator, io, runscript_directory, name, 2)) |path| return path;
    return error.InputFileNotFound;
}

/// Looks for `name` in each immediate subdirectory of `directory`.
///
/// The same name appearing under two subdirectories is an error rather than a
/// first-match win, because which one was intended cannot be known and picking
/// either would silently run with the wrong schedule.
fn findInSubdirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
) !?[]u8 {
    return findInSubdirectoryTree(allocator, io, directory, name, 1);
}

/// Looks for `name` in the subdirectories of `directory`, up to `depth` levels
/// below it. `depth` of one searches only the immediate children.
///
/// The same name appearing in two places is an error rather than a first-match
/// win, because which one was intended cannot be known and picking either would
/// silently run with the wrong input.
fn findInSubdirectoryTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
    depth: usize,
) !?[]u8 {
    if (depth == 0) return null;
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer dir.close(io);
    var found: ?[]u8 = null;
    errdefer if (found) |path| allocator.free(path);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const subdirectory = try std.fs.path.join(allocator, &.{ directory, entry.name });
        defer allocator.free(subdirectory);
        const candidate = (try openedJoin(allocator, io, &.{ subdirectory, name })) orelse
            (try findInSubdirectoryTree(allocator, io, subdirectory, name, depth - 1)) orelse
            continue;
        if (found) |existing| {
            std.log.err(
                "input name is ambiguous: name='{s}' found at '{s}' and '{s}'",
                .{ name, existing, candidate },
            );
            allocator.free(candidate);
            return error.AmbiguousInputFileName;
        }
        found = candidate;
    }
    return found;
}

/// Filename of the run's diagnostic log inside the tree's `logs/` directory.
pub const run_log_name = "run.log";

/// The open run log, if a tree has been created. `std.log` has no context
/// parameter, so the sink has to be reachable without one; a single run owns a
/// single output tree, so one process-wide sink is exactly the lifetime needed.
///
/// The writer is flushed after every line. A run that ends in a failure is
/// exactly when the log matters most, so buffered tail loss is not acceptable.
var active_run_log: ?*std.Io.File.Writer = null;
var active_run_log_lock: std.atomic.Value(bool) = .init(false);

/// Off-by-default switch for high-frequency, debug-shaped `info` logging left
/// over from closed frontier investigations (per-hour surface phosphorus/heat
/// dumps, `TEMP_CHEMISTRY_TRACE`, and similar). `main` sets this exactly once,
/// from the parsed CLI options, before the single-threaded startup phase ends
/// and any hourly work begins; every later read (including from worker
/// threads) is read-only, so this is not mutable model state and carries no
/// data-race or determinism risk. It does not gate `warn`/`err` diagnostics or
/// any call site that participates in an acceptance decision -- only pure,
/// unused-elsewhere `info`-level printing. See
/// `audit/runs/run-004-logging-overhead-fix-and-remeasurement-2026-09-18.md`.
pub var verbose_diagnostics_enabled: bool = false;

fn lockActiveRunLog() void {
    var spins: u32 = 0;
    while (active_run_log_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        if (spins < 1000) {
            spins += 1;
            std.atomic.spinLoopHint();
        } else {
            std.Thread.yield() catch {};
        }
    }
}

fn unlockActiveRunLog() void {
    active_run_log_lock.store(false, .release);
}

fn registerActiveRunLog(writer: *std.Io.File.Writer) !void {
    lockActiveRunLog();
    defer unlockActiveRunLog();
    if (active_run_log != null) return error.ActiveRunLogAlreadyRegistered;
    active_run_log = writer;
}

fn unregisterActiveRunLog(writer: *std.Io.File.Writer) void {
    lockActiveRunLog();
    defer unlockActiveRunLog();
    if (active_run_log == writer) {
        // Flush while still registered and protected: a concurrent logger
        // either completes before this point or observes null after it.
        writer.interface.flush() catch {};
        active_run_log = null;
    } else {
        // A tree must never unregister a writer owned by another live tree.
        std.debug.assert(active_run_log == null);
    }
}

/// A formatting operation erased down to one stable runtime call boundary.
///
/// `std.log` necessarily specializes its public hook for each format and
/// argument tuple. Keeping that specialization in this small callback lets the
/// same generated formatter serve both destinations. The non-generic router
/// below therefore does not duplicate writer, terminal, locking, and flush
/// machinery at every call site.
const ErasedLogMessage = struct {
    context: *const anyopaque,
    write_fn: *const fn (*const anyopaque, *std.Io.Writer) std.Io.Writer.Error!void,

    fn write(self: ErasedLogMessage, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.write_fn(self.context, writer);
    }
};

fn logLevelText(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    };
}

fn writeRunLogLine(
    writer: *std.Io.Writer,
    level_text: []const u8,
    scope_name: []const u8,
    message: ErasedLogMessage,
) std.Io.Writer.Error!void {
    try writer.writeAll("[");
    try writer.writeAll(scope_name);
    try writer.writeAll("] (");
    try writer.writeAll(level_text);
    try writer.writeAll("): ");
    try message.write(writer);
}

fn writeStderrLogLine(
    terminal: std.Io.Terminal,
    level: std.log.Level,
    scope_name: []const u8,
    is_default_scope: bool,
    message: ErasedLogMessage,
) std.Io.Writer.Error!void {
    terminal.setColor(switch (level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .magenta,
    }) catch {};
    terminal.setColor(.bold) catch {};
    try terminal.writer.writeAll(logLevelText(level));
    terminal.setColor(.reset) catch {};
    terminal.setColor(.dim) catch {};
    terminal.setColor(.bold) catch {};
    if (!is_default_scope) {
        try terminal.writer.writeAll("(");
        try terminal.writer.writeAll(scope_name);
        try terminal.writer.writeAll(")");
    }
    try terminal.writer.writeAll(": ");
    terminal.setColor(.reset) catch {};
    try message.write(terminal.writer);
}

/// The single optimizer boundary for every log call. This deliberately mirrors
/// `std.log.defaultLog` instead of forwarding to it, because forwarding would
/// instantiate the full formatter a second time for every message.
noinline fn routeLogToRunLogAndStderr(
    level: std.log.Level,
    scope_name: []const u8,
    is_default_scope: bool,
    message: ErasedLogMessage,
) void {
    // Preserve defaultLog's cancellation protection, stderr lock, 64-byte
    // buffer, terminal detection, colors, and swallowed writer errors.
    const io = std.Options.debug_io;
    const previous_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous_cancel_protection);
    // One critical section owns the complete file line, its flush, and the
    // paired stderr line. This prevents partial file records and guarantees
    // both destinations observe concurrent messages in the same order.
    lockActiveRunLog();
    defer unlockActiveRunLog();
    if (active_run_log) |sink| {
        writeRunLogLine(&sink.interface, logLevelText(level), scope_name, message) catch {};
        sink.interface.flush() catch {};
    }
    var buffer: [64]u8 = undefined;
    const terminal = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    writeStderrLogLine(terminal, level, scope_name, is_default_scope, message) catch {};
}

var captured_parallel_diagnostic_replay_context: u8 = 0;

fn replayCapturedParallelDiagnostic(
    _: *anyopaque,
    level: std.log.Level,
    scope_name: []const u8,
    is_default_scope: bool,
    message_bytes: []const u8,
) void {
    const RawMessage = struct {
        fn write(context: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const bytes: *const []const u8 = @ptrCast(@alignCast(context));
            return writer.writeAll(bytes.*);
        }
    };
    routeLogToRunLogAndStderr(
        level,
        scope_name,
        is_default_scope,
        .{
            .context = @ptrCast(&message_bytes),
            .write_fn = RawMessage.write,
        },
    );
}

/// Routes `std.log` output to the run log as well as standard error.
///
/// Install with `pub const std_options: std.Options = .{ .logFn =
/// run_support.logToRunLogAndStderr };`. Standard error is kept because a
/// failure before the tree exists still has to be visible, and because a user
/// watching a run expects to see it progress.
pub fn logToRunLogAndStderr(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const Args = @TypeOf(args);
    const Formatter = struct {
        noinline fn write(
            context: *const anyopaque,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            const typed_args: *const Args = @ptrCast(@alignCast(context));
            // The newline is part of the original format operation for both
            // destinations; keep it here so formatting/error behavior matches
            // std.log.defaultLog and the former run-log print exactly.
            return writer.print(format ++ "\n", typed_args.*);
        }
    };
    const erased_message: ErasedLogMessage = .{
        .context = @ptrCast(&args),
        .write_fn = Formatter.write,
    };
    if (ecosys.compute.captureActiveDiagnostic(
        .{
            .context = @ptrCast(&captured_parallel_diagnostic_replay_context),
            .write_fn = replayCapturedParallelDiagnostic,
        },
        level,
        @tagName(scope),
        scope == .default,
        .{
            .context = erased_message.context,
            .write_fn = erased_message.write_fn,
        },
    )) return;
    routeLogToRunLogAndStderr(
        level,
        @tagName(scope),
        scope == .default,
        erased_message,
    );
}

/// The structured output tree created under a run's resolved output root:
/// `logs/`, `tile_io/`, `checkpoints/`, and `modelled_outputs/{carbon,water,
/// nitrogen,heat_energy,phosphorus}/`. Category directory handles are kept
/// open for the run's lifetime so output banks can create files directly
/// inside them without re-resolving paths per file.
pub const OutputTree = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Root directory actually used for this run (may carry a `_v2`, `_v3`,
    /// ... suffix relative to the runscript's requested output_root when the
    /// unsuffixed directory already held prior output).
    root: std.Io.Dir,
    root_path: []const u8,
    logs: std.Io.Dir,
    /// The run's diagnostic log, kept open for the run's lifetime.
    run_log: std.Io.File,
    /// Writer over `run_log`. Heap-allocated because the global log sink holds
    /// a pointer to it, which must stay valid if the tree value is moved.
    run_log_writer: *std.Io.File.Writer,
    run_log_buffer: []u8,
    tile_io: std.Io.Dir,
    checkpoints: std.Io.Dir,
    carbon: std.Io.Dir,
    water: std.Io.Dir,
    nitrogen: std.Io.Dir,
    heat_energy: std.Io.Dir,
    phosphorus: std.Io.Dir,

    /// Category of a `modelled_outputs` subdirectory. `development` output
    /// (plant phenology/growth-stage records) is filed under `carbon` since
    /// it accompanies the carbon-family editors in the runscript layout.
    pub const Category = enum { carbon, water, nitrogen, heat_energy, phosphorus };
    pub const OpenMode = enum { new_run, resume_existing };
    const ResolvedRoot = struct { path: []u8, dir: std.Io.Dir };

    pub fn dirFor(self: *const OutputTree, category: Category) std.Io.Dir {
        return switch (category) {
            .carbon => self.carbon,
            .water => self.water,
            .nitrogen => self.nitrogen,
            .heat_energy => self.heat_energy,
            .phosphorus => self.phosphorus,
        };
    }

    /// Returns true when `dir` contains no entries (a fresh directory that
    /// is safe to reuse without risk of clobbering a prior run's output).
    fn isEmptyDir(dir: std.Io.Dir, io: std.Io) !bool {
        var iterator = dir.iterate();
        return (try iterator.next(io)) == null;
    }

    /// True when `dir` contains no regular file at any depth.
    ///
    /// Directory entries alone do not count, so a state_updateted output scaffold of
    /// empty category directories is still considered available for a run. The
    /// moment a run has written a single result file, the tree is no longer
    /// available and the caller versions instead of overwriting.
    fn containsNoFiles(dir: std.Io.Dir, io: std.Io) !bool {
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| switch (entry.kind) {
            .directory => {
                var child = dir.openDir(io, entry.name, .{ .iterate = true }) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir => continue,
                    else => return err,
                };
                defer child.close(io);
                if (!try containsNoFiles(child, io)) return false;
            },
            else => return false,
        };
        return true;
    }

    /// Resolves the actual output root to use for this run: `base_dir/requested_output_root`
    /// (or `base_dir` itself when `requested_output_root` is empty) when that directory
    /// does not yet exist or holds no output files, otherwise the first `_v2`, `_v3`, ...
    /// sibling that does not. The caller owns the returned path and Dir.
    ///
    /// "Holds no output files" rather than "is empty" because a run tree is
    /// normally state_updateted with its category directories already present and
    /// empty. Those directories are the layout the user asked for, so writing
    /// into them is correct; only a tree that already contains results is
    /// preserved by versioning.
    fn resolveOutputRoot(
        allocator: std.mem.Allocator,
        io: std.Io,
        base_dir: []const u8,
        requested_output_root: []const u8,
        mode: OpenMode,
    ) !ResolvedRoot {
        const base_candidate = if (requested_output_root.len == 0)
            try allocator.dupe(u8, base_dir)
        else
            try std.fs.path.join(allocator, &.{ base_dir, requested_output_root });
        errdefer allocator.free(base_candidate);

        if (mode == .resume_existing) {
            const existing = std.Io.Dir.cwd().openDir(io, base_candidate, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => return error.ResumeOutputRootNotFound,
                else => return err,
            };
            return .{ .path = base_candidate, .dir = existing };
        }

        var attempt: usize = 1;
        var candidate = base_candidate;
        var candidate_owned = false;
        while (true) : (attempt += 1) {
            const existing = std.Io.Dir.cwd().openDir(io, candidate, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (existing) |dir| {
                const empty = containsNoFiles(dir, io) catch |err| {
                    dir.close(io);
                    return err;
                };
                if (empty) return .{ .path = candidate, .dir = dir };
                dir.close(io);
                if (candidate_owned) allocator.free(candidate);
                candidate = try std.fmt.allocPrint(allocator, "{s}_v{d}", .{ base_candidate, attempt + 1 });
                candidate_owned = true;
                continue;
            }
            try std.Io.Dir.cwd().createDirPath(io, candidate);
            const dir = try std.Io.Dir.cwd().openDir(io, candidate, .{ .iterate = true });
            if (candidate_owned) {
                allocator.free(base_candidate);
            } else {
                // candidate is base_candidate; nothing extra to free.
            }
            return .{ .path = candidate, .dir = dir };
        }
    }

    /// Creates (or reuses, without clobbering) the structured output tree for
    /// this run under `base_dir` (the runscript's own directory) using the
    /// runscript's requested `output_root` (empty means "use base_dir
    /// itself"). See module docs for the collision-avoidance policy.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        base_dir: []const u8,
        requested_output_root: []const u8,
    ) !OutputTree {
        return initWithMode(allocator, io, base_dir, requested_output_root, .new_run);
    }

    /// Opens the exact requested root for checkpoint resume. It never versions
    /// to `_vN`, because doing so would disconnect the accepted output cursor
    /// from the scientific checkpoint.
    pub fn resumeExisting(
        allocator: std.mem.Allocator,
        io: std.Io,
        base_dir: []const u8,
        requested_output_root: []const u8,
    ) !OutputTree {
        return initWithMode(allocator, io, base_dir, requested_output_root, .resume_existing);
    }

    /// Opens the canonical root recorded in the accepted scientific manifest.
    /// The opened handle must resolve back to the identical path, so a moved
    /// root or replaced symlink/junction fails before `run.log` is appended.
    pub fn resumeCanonical(
        allocator: std.mem.Allocator,
        io: std.Io,
        canonical_root: []const u8,
    ) !OutputTree {
        try validateCanonicalRoot(canonical_root);
        const owned_path = try allocator.dupe(u8, canonical_root);
        const root = std.Io.Dir.cwd().openDir(io, canonical_root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(owned_path);
                return error.ResumeOutputRootNotFound;
            },
            else => {
                allocator.free(owned_path);
                return err;
            },
        };
        return initResolved(
            allocator,
            io,
            .{ .path = owned_path, .dir = root },
            .resume_existing,
            true,
        );
    }

    fn initWithMode(
        allocator: std.mem.Allocator,
        io: std.Io,
        base_dir: []const u8,
        requested_output_root: []const u8,
        mode: OpenMode,
    ) !OutputTree {
        const resolved = try resolveOutputRoot(allocator, io, base_dir, requested_output_root, mode);
        return initResolved(allocator, io, resolved, mode, false);
    }

    fn initResolved(
        allocator: std.mem.Allocator,
        io: std.Io,
        resolved: ResolvedRoot,
        mode: OpenMode,
        require_identical_canonical_path: bool,
    ) !OutputTree {
        var original_path: ?[]u8 = resolved.path;
        errdefer if (original_path) |path| allocator.free(path);
        var root = resolved.dir;
        errdefer root.close(io);

        const canonical_path = try canonicalRootPath(allocator, io, root);
        errdefer allocator.free(canonical_path);
        if (require_identical_canonical_path and
            !std.mem.eql(u8, original_path.?, canonical_path))
            return error.CheckpointOutputRootCanonicalMismatch;
        allocator.free(original_path.?);
        original_path = null;

        try root.createDirPath(io, "logs");
        var logs = try root.openDir(io, "logs", .{});
        errdefer logs.close(io);

        // The run log belongs with the run's other outputs, not in whatever
        // directory the model happened to be launched from. Diagnostics are
        // part of the record of a run: which hour a balance drifted, which
        // input was rejected, and how long the run reached.
        var run_log = try logs.createFile(io, run_log_name, .{
            .read = mode == .resume_existing,
            .truncate = mode == .new_run,
        });
        errdefer run_log.close(io);
        const run_log_buffer = try allocator.alloc(u8, 4096);
        errdefer allocator.free(run_log_buffer);
        const run_log_writer = try allocator.create(std.Io.File.Writer);
        errdefer allocator.destroy(run_log_writer);
        run_log_writer.* = run_log.writerStreaming(io, run_log_buffer);
        if (mode == .resume_existing) try run_log_writer.seekTo(try run_log.length(io));
        // Registering here is what makes every later `std.log` call land in the
        // tree. Anything logged before this point, such as a rejected
        // runscript, still reaches standard error.
        try registerActiveRunLog(run_log_writer);
        errdefer unregisterActiveRunLog(run_log_writer);

        try root.createDirPath(io, "tile_io");
        var tile_io = try root.openDir(io, "tile_io", .{});
        errdefer tile_io.close(io);

        try root.createDirPath(io, "checkpoints");
        var checkpoints = try root.openDir(io, "checkpoints", .{});
        errdefer checkpoints.close(io);

        try root.createDirPath(io, "modelled_outputs/carbon");
        var carbon = try root.openDir(io, "modelled_outputs/carbon", .{});
        errdefer carbon.close(io);

        try root.createDirPath(io, "modelled_outputs/water");
        var water = try root.openDir(io, "modelled_outputs/water", .{});
        errdefer water.close(io);

        try root.createDirPath(io, "modelled_outputs/nitrogen");
        var nitrogen = try root.openDir(io, "modelled_outputs/nitrogen", .{});
        errdefer nitrogen.close(io);

        try root.createDirPath(io, "modelled_outputs/heat_energy");
        var heat_energy = try root.openDir(io, "modelled_outputs/heat_energy", .{});
        errdefer heat_energy.close(io);

        try root.createDirPath(io, "modelled_outputs/phosphorus");
        const phosphorus = try root.openDir(io, "modelled_outputs/phosphorus", .{});

        return .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .root_path = canonical_path,
            .logs = logs,
            .run_log = run_log,
            .run_log_writer = run_log_writer,
            .run_log_buffer = run_log_buffer,
            .tile_io = tile_io,
            .checkpoints = checkpoints,
            .carbon = carbon,
            .water = water,
            .nitrogen = nitrogen,
            .heat_energy = heat_energy,
            .phosphorus = phosphorus,
        };
    }

    pub fn deinit(self: *OutputTree) void {
        // Unregister before closing, so a log call during teardown cannot
        // write to a closed handle.
        unregisterActiveRunLog(self.run_log_writer);
        self.allocator.destroy(self.run_log_writer);
        self.allocator.free(self.run_log_buffer);
        self.run_log.close(self.io);
        self.phosphorus.close(self.io);
        self.heat_energy.close(self.io);
        self.nitrogen.close(self.io);
        self.water.close(self.io);
        self.carbon.close(self.io);
        self.checkpoints.close(self.io);
        self.tile_io.close(self.io);
        self.logs.close(self.io);
        self.root.close(self.io);
        self.allocator.free(self.root_path);
        self.* = undefined;
    }
};

fn canonicalRootPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try directory.realPath(io, &buffer);
    const canonical = try allocator.dupe(u8, buffer[0..length]);
    errdefer allocator.free(canonical);
    try validateCanonicalRoot(canonical);
    return canonical;
}

fn validateCanonicalRoot(path: []const u8) !void {
    try ecosys.checkpoint_manifest.validateOutputIdentitySource(.{
        .canonical_root = path,
        .run_identity = 1,
    });
}

fn testOutputCoordinator(tree: *OutputTree, run_identity: u64) !ecosys.output_hour_transaction.Coordinator {
    return ecosys.output_hour_transaction.Coordinator.init(
        std.testing.allocator,
        std.testing.io,
        tree.root,
        .{
            .carbon = tree.carbon,
            .water = tree.water,
            .nitrogen = tree.nitrogen,
            .heat_energy = tree.heat_energy,
            .phosphorus = tree.phosphorus,
        },
        run_identity,
        256,
        .{},
    );
}

fn writeTestOutputHour(
    coordinator: *ecosys.output_hour_transaction.Coordinator,
    generation: u64,
) !void {
    const instant: ecosys.output_hour_transaction.Instant = .{
        .year = 2001,
        .day_of_year = 1,
        .hour = @intCast(generation - 1),
        .completed_scene_hours = generation,
    };
    var row_buffer: [32]u8 = undefined;
    const row = try std.fmt.bufPrint(&row_buffer, "{d},{d}\n", .{ generation, generation * 10 });
    try coordinator.beginHour(generation, instant);
    try coordinator.record(.carbon, "hourly.csv", "hour,value\n", row);
    try coordinator.commitHour();
}

test "log router preserves exact run-log and stderr bytes" {
    const FixedMessage = struct {
        fn write(_: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return writer.writeAll("value=42 text='exact'\n");
        }
    };
    var ignored_context: u8 = 0;
    const message: ErasedLogMessage = .{
        .context = &ignored_context,
        .write_fn = FixedMessage.write,
    };

    var stderr_buffer: [128]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buffer);
    try writeStderrLogLine(
        .{ .writer = &stderr_writer, .mode = .no_color },
        .warn,
        "soil_water",
        false,
        message,
    );
    try std.testing.expectEqualStrings(
        "warning(soil_water): value=42 text='exact'\n",
        stderr_writer.buffered(),
    );

    // The old implementation was one `Writer.print` call. Compare every
    // possible fixed-buffer failure point so splitting routing from formatting
    // cannot change partial bytes or whether a writer error is observed.
    const IntegerMessage = struct {
        fn write(context: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const value: *const u16 = @ptrCast(@alignCast(context));
            return writer.print("integer={d}\n", .{value.*});
        }
    };
    const expected_line = "[soil_water] (warning): integer=42\n";
    var integer: u16 = 42;
    const integer_message: ErasedLogMessage = .{
        .context = &integer,
        .write_fn = IntegerMessage.write,
    };
    for (0..expected_line.len + 1) |capacity| {
        var reference_buffer: [expected_line.len]u8 = undefined;
        var routed_buffer: [expected_line.len]u8 = undefined;
        var reference_writer: std.Io.Writer = .fixed(reference_buffer[0..capacity]);
        var routed_writer: std.Io.Writer = .fixed(routed_buffer[0..capacity]);
        var reference_error: ?std.Io.Writer.Error = null;
        reference_writer.print(
            "[soil_water] (warning): integer={d}\n",
            .{integer},
        ) catch |err| {
            reference_error = err;
        };
        var routed_error: ?std.Io.Writer.Error = null;
        writeRunLogLine(
            &routed_writer,
            "warning",
            "soil_water",
            integer_message,
        ) catch |err| {
            routed_error = err;
        };
        try std.testing.expectEqual(reference_error, routed_error);
        try std.testing.expectEqualSlices(
            u8,
            reference_writer.buffered(),
            routed_writer.buffered(),
        );
    }

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    var real_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base_dir_length = try temporary.dir.realPath(io, &real_path_buffer);
    var tree = try OutputTree.init(
        std.testing.allocator,
        io,
        real_path_buffer[0..base_dir_length],
        "run_output",
    );
    logToRunLogAndStderr(.info, .default, "integer={d} text='{s}'", .{ 42, "exact" });
    logToRunLogAndStderr(.err, .soil_water, "hex=0x{x}", .{@as(u16, 0x12ab)});
    tree.deinit();

    const run_log = try temporary.dir.readFileAlloc(
        io,
        "run_output/logs/run.log",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(run_log);
    try std.testing.expectEqualStrings(
        "[default] (info): integer=42 text='exact'\n" ++
            "[soil_water] (error): hex=0x12ab\n",
        run_log,
    );
}

test "concurrent log routing writes complete uniquely owned lines" {
    const thread_count = 4;
    const messages_per_thread = 8;
    const Worker = struct {
        ready: *std.atomic.Value(usize),
        start: *std.atomic.Value(bool),
        thread_index: usize,

        fn run(self: *@This()) void {
            _ = self.ready.fetchAdd(1, .release);
            var spins: u32 = 0;
            while (!self.start.load(.acquire)) {
                if (spins < 1000) {
                    spins += 1;
                    std.atomic.spinLoopHint();
                } else {
                    std.Thread.yield() catch {};
                }
            }
            for (0..messages_per_thread) |message_index| {
                logToRunLogAndStderr(
                    .info,
                    .default,
                    "thread={d} line={d} payload=abcdefghijklmnopqrstuvwxyz0123456789",
                    .{ self.thread_index, message_index },
                );
            }
        }
    };

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    var real_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base_dir_length = try temporary.dir.realPath(io, &real_path_buffer);
    var tree = try OutputTree.init(
        std.testing.allocator,
        io,
        real_path_buffer[0..base_dir_length],
        "concurrent_run",
    );
    var tree_open = true;
    defer if (tree_open) tree.deinit();

    var ready: std.atomic.Value(usize) = .init(0);
    var start: std.atomic.Value(bool) = .init(false);
    var workers: [thread_count]Worker = undefined;
    var threads: [thread_count]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer {
        start.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&workers, 0..) |*worker, thread_index| {
        worker.* = .{
            .ready = &ready,
            .start = &start,
            .thread_index = thread_index,
        };
        threads[spawned] = try std.Thread.spawn(.{}, Worker.run, .{worker});
        spawned += 1;
    }
    var spins: u32 = 0;
    while (ready.load(.acquire) != thread_count) {
        if (spins < 1000) {
            spins += 1;
            std.atomic.spinLoopHint();
        } else {
            std.Thread.yield() catch {};
        }
    }
    start.store(true, .release);
    for (threads[0..spawned]) |thread| thread.join();
    spawned = 0;
    tree.deinit();
    tree_open = false;

    const run_log = try temporary.dir.readFileAlloc(
        io,
        "concurrent_run/logs/run.log",
        std.testing.allocator,
        .limited(16 * 1024),
    );
    defer std.testing.allocator.free(run_log);
    try std.testing.expectEqual(
        @as(usize, thread_count * messages_per_thread),
        std.mem.count(u8, run_log, "\n"),
    );
    var expected_buffer: [128]u8 = undefined;
    for (0..thread_count) |thread_index| for (0..messages_per_thread) |message_index| {
        const expected = try std.fmt.bufPrint(
            &expected_buffer,
            "[default] (info): thread={d} line={d} payload=abcdefghijklmnopqrstuvwxyz0123456789\n",
            .{ thread_index, message_index },
        );
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, run_log, expected));
    };
}

test "parallel grid failures reach run log in canonical serial order" {
    const KernelContext = struct {
        fn apply(_: *@This(), _: []const usize, worker_index: usize) !void {
            logToRunLogAndStderr(
                .err,
                .grid_test,
                "worker={d}",
                .{worker_index},
            );
            if (worker_index != 0) return error.SyntheticGridFailure;
        }
    };

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    var real_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base_dir_length = try temporary.dir.realPath(io, &real_path_buffer);
    var tree = try OutputTree.init(
        std.testing.allocator,
        io,
        real_path_buffer[0..base_dir_length],
        "canonical_parallel_log",
    );
    var tree_open = true;
    defer if (tree_open) tree.deinit();

    var identity: u8 = 0;
    const offsets = [_]usize{ 0, 4 };
    const owned = [_]usize{ 8, 2, 6, 0 };
    const executor = try ecosys.compute.CpuExecutor.init(
        std.testing.allocator,
        4,
        .{
            .identity = @ptrCast(&identity),
            .maximum_owned_cell_count = owned.len,
            .owned_cell_offsets = &offsets,
            .owned_cells = &owned,
        },
    );
    defer executor.deinit();
    // A single-hardware-thread host cannot exercise a parallel failure. The
    // compute-level test covers the four-participant path independently of
    // host capacity.
    if (executor.statistics().effective_threads < 2) return;
    var kernel_context: KernelContext = .{};
    try std.testing.expectError(
        error.SyntheticGridFailure,
        executor.runOwnedCellsIndexed(.{
            .plan_identity = @ptrCast(&identity),
            .tile_index = 0,
            .cell_indices = &owned,
        }, &kernel_context, KernelContext.apply),
    );
    tree.deinit();
    tree_open = false;

    const run_log = try temporary.dir.readFileAlloc(
        io,
        "canonical_parallel_log/logs/run.log",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(run_log);
    try std.testing.expectEqualStrings(
        "[grid_test] (error): worker=0\n" ++
            "[grid_test] (error): worker=1\n",
        run_log,
    );
}

test "second active run-log writer is rejected without stealing ownership" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    var real_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base_dir_length = try temporary.dir.realPath(io, &real_path_buffer);
    const base_dir = real_path_buffer[0..base_dir_length];

    var first = try OutputTree.init(std.testing.allocator, io, base_dir, "first_run");
    var first_open = true;
    defer if (first_open) first.deinit();
    try std.testing.expectError(
        error.ActiveRunLogAlreadyRegistered,
        OutputTree.init(std.testing.allocator, io, base_dir, "second_run"),
    );
    logToRunLogAndStderr(.warn, .default, "first-owner-still-active", .{});
    first.deinit();
    first_open = false;

    const first_log = try temporary.dir.readFileAlloc(
        io,
        "first_run/logs/run.log",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(first_log);
    try std.testing.expectEqualStrings(
        "[default] (warning): first-owner-still-active\n",
        first_log,
    );

    // Successful replacement proves the first owner unregistered cleanly.
    var replacement = try OutputTree.init(std.testing.allocator, io, base_dir, "replacement_run");
    replacement.deinit();
}

test "OutputTree creates the full structured layout under a fresh output root" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_dir_len = try temporary.dir.realPath(io, &real_path_buf);
    const base_dir = real_path_buf[0..base_dir_len];

    var tree = try OutputTree.init(std.testing.allocator, io, base_dir, "run_output");
    defer tree.deinit();

    // isEmptyDir iterates, so the handle must carry iteration ability.
    // OutputTree.init opens the category directories without .iterate
    // because production only ever writes through them; reopen here.
    // `logs` is deliberately NOT expected to be empty: init creates the run
    // log inside it at :445, so asserting emptiness here could never pass.
    // Assert the run log is present instead, which is the real contract.
    var logs_iterable = try tree.root.openDir(io, "logs", .{ .iterate = true });
    defer logs_iterable.close(io);
    try std.testing.expect(!try OutputTree.isEmptyDir(logs_iterable, io));
    var carbon_iterable = try tree.root.openDir(
        io,
        "modelled_outputs/carbon",
        .{ .iterate = true },
    );
    defer carbon_iterable.close(io);
    try std.testing.expect(try OutputTree.isEmptyDir(carbon_iterable, io));
    _ = try tree.carbon.createFile(io, "probe.txt", .{});
}

test "OutputTree avoids clobbering non-empty prior output by suffixing _v2" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_dir_len = try temporary.dir.realPath(io, &real_path_buf);
    const base_dir = real_path_buf[0..base_dir_len];

    var first = try OutputTree.init(std.testing.allocator, io, base_dir, "run_output");
    _ = try first.carbon.createFile(io, "marker.txt", .{});
    first.deinit();

    var second = try OutputTree.init(std.testing.allocator, io, base_dir, "run_output");
    defer second.deinit();
    try std.testing.expect(std.mem.endsWith(u8, second.root_path, "_v2"));
}

test "OutputTree resume reopens exact root and appends prior run log" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_dir_len = try temporary.dir.realPath(io, &real_path_buf);
    const base_dir = real_path_buf[0..base_dir_len];

    var first = try OutputTree.init(std.testing.allocator, io, base_dir, "run_output");
    try first.run_log_writer.interface.writeAll("accepted-before-resume\n");
    try first.run_log_writer.interface.flush();
    _ = try first.carbon.createFile(io, "accepted.txt", .{});
    const accepted_root = try std.testing.allocator.dupe(u8, first.root_path);
    defer std.testing.allocator.free(accepted_root);
    first.deinit();

    var resumed = try OutputTree.resumeCanonical(std.testing.allocator, io, accepted_root);
    try std.testing.expect(!std.mem.endsWith(u8, resumed.root_path, "_v2"));
    try resumed.run_log_writer.interface.writeAll("continued-after-resume\n");
    try resumed.run_log_writer.interface.flush();
    resumed.deinit();

    const log_bytes = try temporary.dir.readFileAlloc(io, "run_output/logs/run.log", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(log_bytes);
    try std.testing.expectEqualStrings(
        "accepted-before-resume\ncontinued-after-resume\n",
        log_bytes,
    );
}

test "OutputTree resume fails closed when exact root is missing" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_dir_len = try temporary.dir.realPath(std.testing.io, &real_path_buf);
    const missing = try std.fs.path.join(
        std.testing.allocator,
        &.{ real_path_buf[0..base_dir_len], "missing-output" },
    );
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.ResumeOutputRootNotFound, OutputTree.resumeCanonical(
        std.testing.allocator,
        std.testing.io,
        missing,
    ));
}

test "OutputTree canonical resume disambiguates multiple versioned runs" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_dir_len = try temporary.dir.realPath(io, &real_path_buf);
    const base_dir = real_path_buf[0..base_dir_len];

    var first = try OutputTree.init(std.testing.allocator, io, base_dir, "run_output");
    try first.run_log_writer.interface.writeAll("first-run\n");
    first.deinit();

    var accepted = try OutputTree.init(std.testing.allocator, io, base_dir, "run_output");
    try std.testing.expect(std.mem.endsWith(u8, accepted.root_path, "_v2"));
    try accepted.run_log_writer.interface.writeAll("accepted-v2\n");
    try accepted.run_log_writer.interface.flush();
    const accepted_path = try std.testing.allocator.dupe(u8, accepted.root_path);
    defer std.testing.allocator.free(accepted_path);
    accepted.deinit();

    var other = try OutputTree.init(std.testing.allocator, io, base_dir, "run_output");
    try std.testing.expect(std.mem.endsWith(u8, other.root_path, "_v3"));
    try other.run_log_writer.interface.writeAll("other-v3\n");
    try other.run_log_writer.interface.flush();
    other.deinit();

    var resumed = try OutputTree.resumeCanonical(std.testing.allocator, io, accepted_path);
    try std.testing.expectEqualStrings(accepted_path, resumed.root_path);
    try resumed.run_log_writer.interface.writeAll("continued-v2\n");
    try resumed.run_log_writer.interface.flush();
    resumed.deinit();

    const accepted_log = try temporary.dir.readFileAlloc(io, "run_output_v2/logs/run.log", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(accepted_log);
    try std.testing.expectEqualStrings("accepted-v2\ncontinued-v2\n", accepted_log);
    const other_log = try temporary.dir.readFileAlloc(io, "run_output_v3/logs/run.log", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(other_log);
    try std.testing.expectEqualStrings("other-v3\n", other_log);
}

test "versioned output root checkpoint resume is byte identical to uninterrupted output" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    const run_identity: u64 = 0x1122_3344_5566_7788;
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_dir_len = try temporary.dir.realPath(io, &real_path_buf);
    const base_dir = real_path_buf[0..base_dir_len];

    // Occupy the requested root so the accepted run is forced onto `_v2`.
    var occupied = try OutputTree.init(std.testing.allocator, io, base_dir, "run_output");
    occupied.deinit();

    var accepted_tree = try OutputTree.init(std.testing.allocator, io, base_dir, "run_output");
    try std.testing.expect(std.mem.endsWith(u8, accepted_tree.root_path, "_v2"));
    var accepted_coordinator = try testOutputCoordinator(&accepted_tree, run_identity);
    try accepted_coordinator.reconcile(.fresh);
    try writeTestOutputHour(&accepted_coordinator, 1);
    try accepted_coordinator.checkpointWillPublish();

    var sources: [ecosys.checkpoint_manifest.section_count]ecosys.checkpoint_manifest.EntrySource = undefined;
    inline for (@typeInfo(ecosys.checkpoint_manifest.Section).@"enum".fields, 0..) |field, index|
        sources[index] = .{ .section = @enumFromInt(field.value), .file_name = field.name ++ ".bin", .bytes = field.name };
    const checkpoint_instant: ecosys.checkpoint_manifest.SimulationInstant = .{
        .year = 2001,
        .day_of_year = 1,
        .hour = 0,
        .completed_scene_hours = 1,
    };
    var manifest = try ecosys.checkpoint_manifest.build(
        std.testing.allocator,
        1,
        checkpoint_instant,
        .{ .canonical_root = accepted_tree.root_path, .run_identity = run_identity },
        .{ .columns = 1, .rows = 1, .soil_layers = 1, .snow_layers = 1, .plant_species_per_cell = 1, .root_axes_per_plant = 1 },
        &sources,
    );
    defer manifest.deinit();
    try ecosys.checkpoint_manifest.publishAtomic(std.testing.allocator, io, temporary.dir, "restart.manifest", manifest, 256);
    try accepted_coordinator.checkpointDidPublish(.{
        .checkpoint_generation = 1,
        .output_generation = 1,
        .instant = .{ .year = 2001, .day_of_year = 1, .hour = 0, .completed_scene_hours = 1 },
    });
    accepted_coordinator.deinit();
    accepted_tree.deinit();

    var restored_manifest = try ecosys.checkpoint_bundle_reader.readManifest(
        std.testing.allocator,
        io,
        temporary.dir,
        "restart.manifest",
        256,
        .{ .maximum_columns = 1, .maximum_rows = 1, .maximum_soil_layers = 1, .maximum_snow_layers = 1, .maximum_plant_species_per_cell = 1, .maximum_root_axes_per_plant = 1 },
    );
    defer restored_manifest.deinit();
    try std.testing.expectEqual(run_identity, restored_manifest.output.run_identity);
    var resumed_tree = try OutputTree.resumeCanonical(std.testing.allocator, io, restored_manifest.output.canonical_root);
    var resumed_coordinator = try testOutputCoordinator(&resumed_tree, run_identity);
    try resumed_coordinator.reconcile(.{ .checkpoint = .{
        .checkpoint_generation = restored_manifest.generation,
        .output_generation = restored_manifest.generation,
        .instant = .{ .year = 2001, .day_of_year = 1, .hour = 0, .completed_scene_hours = 1 },
    } });
    try writeTestOutputHour(&resumed_coordinator, 2);
    resumed_coordinator.deinit();
    resumed_tree.deinit();

    var uninterrupted_tree = try OutputTree.init(std.testing.allocator, io, base_dir, "run_output");
    try std.testing.expect(std.mem.endsWith(u8, uninterrupted_tree.root_path, "_v3"));
    var uninterrupted_coordinator = try testOutputCoordinator(&uninterrupted_tree, run_identity);
    try uninterrupted_coordinator.reconcile(.fresh);
    try writeTestOutputHour(&uninterrupted_coordinator, 1);
    try writeTestOutputHour(&uninterrupted_coordinator, 2);
    uninterrupted_coordinator.deinit();
    uninterrupted_tree.deinit();

    const resumed_bytes = try temporary.dir.readFileAlloc(io, "run_output_v2/modelled_outputs/carbon/hourly.csv", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(resumed_bytes);
    const uninterrupted_bytes = try temporary.dir.readFileAlloc(io, "run_output_v3/modelled_outputs/carbon/hourly.csv", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(uninterrupted_bytes);
    try std.testing.expectEqualStrings(uninterrupted_bytes, resumed_bytes);
    try std.testing.expectEqualStrings("hour,value\n1,10\n2,20\n", resumed_bytes);
}

/// Opens the OS temporary directory, returning null if the path cannot be
/// determined. On Windows, uses GetTempPathW (kernel32, no libc required).
/// On POSIX, reads $TMPDIR then $TMP from `environ_map` and falls back to /tmp.
/// The caller owns the returned Dir handle and must call close(io) on it.
pub fn openOsTempDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) !?std.Io.Dir {
    if (comptime @import("builtin").os.tag == .windows) {
        const GetTempPathW = struct {
            extern "kernel32" fn GetTempPathW(
                nBufferLength: u32,
                lpBuffer: [*]u16,
            ) callconv(.winapi) u32;
        }.GetTempPathW;
        var buf: [std.os.windows.MAX_PATH + 1]u16 = undefined;
        const len = GetTempPathW(buf.len, &buf);
        if (len == 0) return null;
        // GetTempPathW appends a trailing backslash; strip it for openDirAbsolute.
        const raw = buf[0..len];
        const path_u16 = if (raw[raw.len - 1] == '\\') raw[0 .. raw.len - 1] else raw;
        const path = try std.unicode.utf16LeToUtf8Alloc(allocator, path_u16);
        defer allocator.free(path);
        return try std.Io.Dir.openDirAbsolute(io, path, .{});
    } else {
        // Zig 0.16 removed `std.posix.getenv`; there is no ambient environment
        // to read, so the caller threads its `std.process.Init.environ_map` in.
        // This arm is comptime-dead on Windows, so it went unchecked until
        // `zig build check -Dtarget=x86_64-linux-gnu` was first run on
        // 2026-09-10 and failed here.
        for ([_][]const u8{ "TMPDIR", "TMP" }) |name| {
            const value = environ_map.get(name) orelse continue;
            if (value.len == 0) continue;
            return try std.Io.Dir.openDirAbsolute(io, value, .{});
        }
        return try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    }
}
