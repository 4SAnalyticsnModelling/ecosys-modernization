const std = @import("std");
const builtin = @import("builtin");

pub const CellRange = struct {
    first: usize,
    end: usize,

    pub fn count(self: CellRange) usize {
        return self.end - self.first;
    }
};

pub const StridedIndexRange = struct {
    next_index: usize,
    end: usize,
    stride: usize,

    pub fn next(self: *StridedIndexRange) ?usize {
        if (self.next_index >= self.end or self.stride == 0) return null;
        const current = self.next_index;
        self.next_index = std.math.add(usize, current, self.stride) catch self.end;
        return current;
    }
};

/// Nominal capability describing the one serial tile plan an executor serves.
/// `state.spatial_grid.TilePlan` issues this together with `OwnedCellTile`
/// values; keeping the types here avoids a core -> state import cycle.
pub const OwnedCellPlan = struct {
    identity: *const anyopaque,
    maximum_owned_cell_count: usize,
    owned_cell_offsets: []const usize,
    owned_cells: []const usize,
};

/// The exact Morton-ordered owned interior of one tile. Production dispatch
/// accepts this capability instead of an arbitrary cell slice, and verifies it
/// belongs to the plan used to construct the executor.
pub const OwnedCellTile = struct {
    plan_identity: *const anyopaque,
    tile_index: usize,
    cell_indices: []const usize,

    pub fn cells(self: OwnedCellTile) []const usize {
        return self.cell_indices;
    }
};

/// A log message erased by the executable's `std_options.logFn`. Parallel
/// workers format into participant-local storage; the executor replays those
/// records on the caller after every participant has joined. This keeps
/// diagnostics in canonical grid-partition order without serializing science
/// work or allowing a later partition to print after an earlier one failed.
pub const CapturedDiagnosticMessage = struct {
    context: *const anyopaque,
    write_fn: *const fn (*const anyopaque, *std.Io.Writer) std.Io.Writer.Error!void,

    fn write(self: CapturedDiagnosticMessage, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.write_fn(self.context, writer);
    }
};

pub const CapturedDiagnosticReplay = struct {
    context: *anyopaque,
    write_fn: *const fn (
        context: *anyopaque,
        level: std.log.Level,
        scope_name: []const u8,
        is_default_scope: bool,
        message: []const u8,
    ) void,
};

const DiagnosticCapture = struct {
    const Record = struct {
        level: std.log.Level,
        scope_name: []const u8,
        is_default_scope: bool,
        first_byte: usize,
        end_byte: usize,
        replay: CapturedDiagnosticReplay,
    };

    allocator: std.mem.Allocator,
    bytes: std.Io.Writer.Allocating,
    records: std.ArrayList(Record) = .empty,
    capture_failed: bool = false,
    fallback_replay: ?CapturedDiagnosticReplay = null,

    fn init(allocator: std.mem.Allocator) !DiagnosticCapture {
        var bytes = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
        errdefer bytes.deinit();
        var records: std.ArrayList(Record) = .empty;
        errdefer records.deinit(allocator);
        try records.ensureTotalCapacity(allocator, 8);
        return .{
            .allocator = allocator,
            .bytes = bytes,
            .records = records,
        };
    }

    fn deinit(self: *DiagnosticCapture) void {
        self.records.deinit(self.allocator);
        self.bytes.deinit();
        self.* = undefined;
    }

    fn reset(self: *DiagnosticCapture) void {
        self.bytes.clearRetainingCapacity();
        self.records.clearRetainingCapacity();
        self.capture_failed = false;
        self.fallback_replay = null;
    }

    fn append(
        self: *DiagnosticCapture,
        replay: CapturedDiagnosticReplay,
        level: std.log.Level,
        scope_name: []const u8,
        is_default_scope: bool,
        message: CapturedDiagnosticMessage,
    ) void {
        if (self.capture_failed) return;
        self.fallback_replay = replay;
        const first_byte = self.bytes.written().len;
        message.write(&self.bytes.writer) catch {
            self.bytes.shrinkRetainingCapacity(first_byte);
            self.capture_failed = true;
            return;
        };
        self.records.append(self.allocator, .{
            .level = level,
            .scope_name = scope_name,
            .is_default_scope = is_default_scope,
            .first_byte = first_byte,
            .end_byte = self.bytes.written().len,
            .replay = replay,
        }) catch {
            self.bytes.shrinkRetainingCapacity(first_byte);
            self.capture_failed = true;
        };
    }

    fn replayAndReset(self: *DiagnosticCapture) void {
        const written = self.bytes.written();
        for (self.records.items) |record| record.replay.write_fn(
            record.replay.context,
            record.level,
            record.scope_name,
            record.is_default_scope,
            written[record.first_byte..record.end_byte],
        );
        if (self.capture_failed) if (self.fallback_replay) |replay| replay.write_fn(
            replay.context,
            .err,
            "default",
            true,
            "parallel diagnostic capture exhausted memory; one or more records were unavailable\n",
        );
        self.reset();
    }
};

threadlocal var active_diagnostic_capture: ?*DiagnosticCapture = null;

/// Called by the executable log router. Returns false outside an executor
/// participant, in which case the caller must route the message immediately.
pub fn captureActiveDiagnostic(
    replay: CapturedDiagnosticReplay,
    level: std.log.Level,
    scope_name: []const u8,
    is_default_scope: bool,
    message: CapturedDiagnosticMessage,
) bool {
    const capture = active_diagnostic_capture orelse return false;
    capture.append(replay, level, scope_name, is_default_scope, message);
    return true;
}

fn beginDiagnosticCapture(capture: *DiagnosticCapture) void {
    std.debug.assert(active_diagnostic_capture == null);
    capture.reset();
    active_diagnostic_capture = capture;
}

fn endDiagnosticCapture(capture: *DiagnosticCapture) void {
    std.debug.assert(active_diagnostic_capture == capture);
    active_diagnostic_capture = null;
}

/// Replays only the canonical prefix that a serial traversal could reach.
/// When a partition fails, diagnostics from higher-index partitions are
/// discarded after all workers join; their scientific effects are handled by
/// the enclosing transaction rollback exactly as before.
fn replayCanonicalDiagnostics(
    captures: []DiagnosticCapture,
    errors: []const ?anyerror,
) void {
    var replay_count = captures.len;
    for (errors, 0..) |maybe_error, worker_index| if (maybe_error != null) {
        replay_count = worker_index + 1;
        break;
    };
    for (captures[0..replay_count]) |*capture| capture.replayAndReset();
    for (captures[replay_count..]) |*capture| capture.reset();
}

/// A persistent pool of background threads, shared by every
/// dispatch a `CpuExecutor` makes over its lifetime. This Zig toolchain's
/// `std.Thread.Mutex`/`Condition`/`Futex` were folded into `std.Io` (a
/// heavyweight async-runtime abstraction requiring a constructed `Io`
/// instance, e.g. `std.Io.Threaded`, which installs its own signal handlers
/// and spawns its own worker threads -- disproportionate to a narrow local
/// primitive and a needless second thread pool). This pool synchronizes with
/// atomics and parks idle workers on the generation address on the supported
/// production hosts. A round is described by a
/// type-erased `Task` (a function pointer plus an opaque context pointer)
/// built fresh, on the stack, by each `runGridColumnsParallel`/`runCells` call;
/// `generation` and each worker's own local `seen` counter replace per-call
/// thread spawn/join with a poll-based handshake.
const Pool = struct {
    const Task = struct {
        run: *const fn (ctx: *const anyopaque, worker_index: usize) void,
        ctx: *const anyopaque,
    };

    allocator: std.mem.Allocator,
    threads: []std.Thread,
    worker_errors: []?anyerror,
    worker_diagnostics: []DiagnosticCapture,
    generation: std.atomic.Value(u32) = .init(0),
    active_this_round: std.atomic.Value(usize) = .init(0),
    pending: std.atomic.Value(usize) = .init(0),
    acknowledged: std.atomic.Value(usize) = .init(0),
    task_run: std.atomic.Value(?*const fn (ctx: *const anyopaque, worker_index: usize) void) = .init(null),
    task_ctx: std.atomic.Value(?*const anyopaque) = .init(null),
    dispatch_in_use: std.atomic.Value(bool) = .init(false),
    parallel_dispatch_count: std.atomic.Value(u64) = .init(0),
    shutdown: std.atomic.Value(bool) = .init(false),

    const blocking_idle_wait = switch (builtin.os.tag) {
        .windows, .linux => true,
        else => false,
    };

    /// Dispatch completion is normally short, so the caller uses a bounded
    /// spin/yield backoff. Idle workers must not use this loop: `yield` keeps
    /// them runnable and can consume a core throughout serial model phases.
    fn backoff(spins: *u32) void {
        if (spins.* < 1000) {
            spins.* += 1;
            std.atomic.spinLoopHint();
        } else {
            std.Thread.yield() catch {};
        }
    }

    fn parkOnGeneration(pool: *Pool, expected: u32) void {
        switch (builtin.os.tag) {
            .windows => {
                _ = std.os.windows.ntdll.RtlWaitOnAddress(
                    &pool.generation.raw,
                    &expected,
                    @sizeOf(u32),
                    null,
                );
            },
            .linux => {
                _ = std.os.linux.futex_4arg(
                    &pool.generation.raw,
                    .{ .cmd = .WAIT, .private = true },
                    expected,
                    null,
                );
            },
            else => unreachable,
        }
    }

    fn wakeIdleWorkers(pool: *Pool) void {
        switch (builtin.os.tag) {
            .windows => std.os.windows.ntdll.RtlWakeAddressAll(&pool.generation.raw),
            .linux => {
                _ = std.os.linux.futex_3arg(
                    &pool.generation.raw,
                    .{ .cmd = .WAKE, .private = true },
                    @intCast(@min(pool.threads.len, std.math.maxInt(u32))),
                );
            },
            else => {},
        }
    }

    fn signalShutdown(pool: *Pool) void {
        pool.shutdown.store(true, .release);
        // Incrementing the wait address prevents a lost wake when a worker is
        // between its shutdown check and the operating-system wait call.
        _ = pool.generation.fetchAdd(1, .release);
        if (blocking_idle_wait) pool.wakeIdleWorkers();
    }

    fn init(
        allocator: std.mem.Allocator,
        background_worker_count: usize,
        participant_count: usize,
    ) !*Pool {
        const pool = try allocator.create(Pool);
        errdefer allocator.destroy(pool);
        const threads = try allocator.alloc(std.Thread, background_worker_count);
        errdefer allocator.free(threads);
        const worker_errors = try allocator.alloc(?anyerror, participant_count);
        errdefer allocator.free(worker_errors);
        const worker_diagnostics = try allocator.alloc(DiagnosticCapture, participant_count);
        errdefer allocator.free(worker_diagnostics);
        var initialized_diagnostics: usize = 0;
        errdefer for (worker_diagnostics[0..initialized_diagnostics]) |*capture| capture.deinit();
        while (initialized_diagnostics < worker_diagnostics.len) : (initialized_diagnostics += 1)
            worker_diagnostics[initialized_diagnostics] = try DiagnosticCapture.init(allocator);
        pool.* = .{
            .allocator = allocator,
            .threads = threads,
            .worker_errors = worker_errors,
            .worker_diagnostics = worker_diagnostics,
        };
        var spawned: usize = 0;
        errdefer {
            pool.signalShutdown();
            for (pool.threads[0..spawned]) |thread| thread.join();
        }
        while (spawned < background_worker_count) : (spawned += 1) {
            pool.threads[spawned] = try std.Thread.spawn(.{}, workerLoop, .{ pool, spawned });
        }
        return pool;
    }

    fn deinit(pool: *Pool) void {
        std.debug.assert(!pool.dispatch_in_use.load(.acquire));
        pool.signalShutdown();
        for (pool.threads) |thread| thread.join();
        for (pool.worker_diagnostics) |*capture| capture.deinit();
        pool.allocator.free(pool.worker_diagnostics);
        pool.allocator.free(pool.worker_errors);
        pool.allocator.free(pool.threads);
        pool.allocator.destroy(pool);
    }

    fn workerLoop(pool: *Pool, worker_index: usize) void {
        var seen: u32 = 0;
        while (true) {
            var spins: u32 = 0;
            var generation = pool.generation.load(.acquire);
            while (generation == seen) {
                if (pool.shutdown.load(.acquire)) return;
                if (blocking_idle_wait) {
                    pool.parkOnGeneration(seen);
                } else {
                    backoff(&spins);
                }
                generation = pool.generation.load(.acquire);
            }
            if (pool.shutdown.load(.acquire)) return;
            seen = generation;
            if (worker_index < pool.active_this_round.load(.acquire)) {
                const run = pool.task_run.load(.acquire).?;
                const ctx = pool.task_ctx.load(.acquire).?;
                run(ctx, worker_index);
                _ = pool.pending.fetchSub(1, .release);
            }
            // Every worker, including an inactive one, must acknowledge the
            // generation before dispatch may reuse the mutable round fields.
            // Waiting only for `pending` permits a lagging inactive worker to
            // observe generation N with generation N+1's task/active count,
            // then execute the new task a second time after observing N+1.
            _ = pool.acknowledged.fetchAdd(1, .release);
        }
    }

    fn acquireDispatch(pool: *Pool) !void {
        if (pool.dispatch_in_use.cmpxchgStrong(
            false,
            true,
            .acq_rel,
            .acquire,
        ) != null) return error.ConcurrentExecutorDispatch;
    }

    fn releaseDispatch(pool: *Pool) void {
        std.debug.assert(pool.dispatch_in_use.load(.acquire));
        pool.dispatch_in_use.store(false, .release);
    }

    /// Runs one participant on the caller and blocks until every background
    /// participant has run `task` once and every pool worker has acknowledged
    /// this generation. `acquireDispatch` must already own the mutable round
    /// fields. All
    /// fields workers read are published with `.release` stores before the
    /// `.release` bump of `generation`, and workers `.acquire`-load
    /// `generation` before reading them, so the handshake is correctly
    /// ordered without a mutex.
    fn dispatchAcquired(pool: *Pool, participant_count: usize, task: Task) void {
        std.debug.assert(pool.dispatch_in_use.load(.acquire));
        std.debug.assert(participant_count >= 2);
        const active_background_count = participant_count - 1;
        std.debug.assert(active_background_count <= pool.threads.len);
        pool.task_ctx.store(task.ctx, .release);
        pool.task_run.store(task.run, .release);
        pool.active_this_round.store(active_background_count, .release);
        pool.pending.store(active_background_count, .release);
        pool.acknowledged.store(0, .release);
        _ = pool.generation.fetchAdd(1, .release);
        if (blocking_idle_wait) pool.wakeIdleWorkers();
        _ = pool.parallel_dispatch_count.fetchAdd(1, .monotonic);

        // N is the total participant ceiling, not the number of spawned
        // workers. Keeping the final, highest-index partition on the caller
        // preserves partition and error-priority order while avoiding an
        // additional runnable coordinator thread.
        task.run(task.ctx, participant_count - 1);

        var spins: u32 = 0;
        while (pool.pending.load(.acquire) != 0) backoff(&spins);
        while (pool.acknowledged.load(.acquire) != pool.threads.len) backoff(&spins);
    }
};

test "pool backoff counter saturates in yield phase" {
    var spins: u32 = 999;
    Pool.backoff(&spins);
    try std.testing.expectEqual(@as(u32, 1000), spins);
    spins = std.math.maxInt(u32);
    Pool.backoff(&spins);
    try std.testing.expectEqual(std.math.maxInt(u32), spins);
}

test "idle workers use an address wait on supported production hosts" {
    switch (builtin.os.tag) {
        .windows, .linux => try std.testing.expect(Pool.blocking_idle_wait),
        else => {},
    }
}

pub const CpuExecutor = struct {
    allocator: std.mem.Allocator,
    requested_worker_count: usize,
    worker_count: usize,
    tile_cell_count: usize,
    owned_cell_plan_identity: *const anyopaque,
    owned_cell_offsets: []const usize,
    owned_cells: []const usize,
    pool: *Pool,

    pub const Statistics = struct {
        requested_threads: usize,
        effective_threads: usize,
        background_threads: usize,
        maximum_tile_cells: usize,
        parallel_dispatches: u64,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        worker_count: usize,
        owned_cell_plan: OwnedCellPlan,
    ) !CpuExecutor {
        const hardware_thread_count = std.Thread.getCpuCount() catch 1;
        return initWithHardwareThreadCount(
            allocator,
            worker_count,
            owned_cell_plan,
            @max(hardware_thread_count, 1),
        );
    }

    fn validateOwnedCellPlan(plan: OwnedCellPlan) !void {
        if (plan.owned_cell_offsets.len < 2 or
            plan.owned_cell_offsets[0] != 0 or
            plan.owned_cell_offsets[plan.owned_cell_offsets.len - 1] != plan.owned_cells.len)
            return error.InvalidOwnedCellPlan;
        var maximum: usize = 0;
        for (0..plan.owned_cell_offsets.len - 1) |tile_index| {
            const first = plan.owned_cell_offsets[tile_index];
            const end = plan.owned_cell_offsets[tile_index + 1];
            if (first >= end or end > plan.owned_cells.len)
                return error.InvalidOwnedCellPlan;
            maximum = @max(maximum, end - first);
        }
        if (maximum != plan.maximum_owned_cell_count)
            return error.InvalidOwnedCellPlan;
    }

    fn initWithHardwareThreadCount(
        allocator: std.mem.Allocator,
        worker_count: usize,
        owned_cell_plan: OwnedCellPlan,
        hardware_thread_count: usize,
    ) !CpuExecutor {
        try validateOwnedCellPlan(owned_cell_plan);
        return initConfigured(
            allocator,
            worker_count,
            owned_cell_plan.identity,
            owned_cell_plan.maximum_owned_cell_count,
            owned_cell_plan.owned_cell_offsets,
            owned_cell_plan.owned_cells,
            hardware_thread_count,
        );
    }

    fn initConfigured(
        allocator: std.mem.Allocator,
        worker_count: usize,
        owned_cell_plan_identity: *const anyopaque,
        maximum_owned_cell_count: usize,
        owned_cell_offsets: []const usize,
        owned_cells: []const usize,
        hardware_thread_count: usize,
    ) !CpuExecutor {
        if (worker_count == 0) return error.NoWorkerThreads;
        if (maximum_owned_cell_count == 0) return error.EmptyTile;
        // The requested value is a total-participant ceiling including the
        // caller. Keep participants available for independent vertical-layer
        // work even when the horizontal tile contains only one cell. Spatial
        // dispatches still cap their active participant count to the owned
        // cells passed to them. Cap the persistent pool to hardware concurrency
        // so a large runscript or CLI value cannot oversubscribe the host.
        const effective_worker_count = @min(
            worker_count,
            @max(hardware_thread_count, 1),
        );
        const background_worker_count = effective_worker_count - 1;
        const pool = try Pool.init(
            allocator,
            background_worker_count,
            effective_worker_count,
        );
        return .{
            .allocator = allocator,
            .requested_worker_count = worker_count,
            .worker_count = effective_worker_count,
            .tile_cell_count = maximum_owned_cell_count,
            .owned_cell_plan_identity = owned_cell_plan_identity,
            .owned_cell_offsets = owned_cell_offsets,
            .owned_cells = owned_cells,
            .pool = pool,
        };
    }

    pub fn statistics(self: CpuExecutor) Statistics {
        return .{
            .requested_threads = self.requested_worker_count,
            .effective_threads = self.worker_count,
            .background_threads = self.pool.threads.len,
            .maximum_tile_cells = self.tile_cell_count,
            .parallel_dispatches = self.pool.parallel_dispatch_count.load(.monotonic),
        };
    }

    /// Shuts down and joins the persistent worker pool. `CpuExecutor` is
    /// copied by value at many call sites (e.g. stored in per-tile science
    /// contexts); every copy shares the same `pool` pointer, so `deinit`
    /// must be called exactly once, by whichever scope owns the value
    /// returned from `init` -- matching the existing `defer x.deinit()`
    /// convention used immediately after every other allocation in this
    /// codebase. Calling any dispatch method after `deinit` is undefined
    /// behavior, same as using any other resource after it is freed.
    pub fn deinit(self: CpuExecutor) void {
        self.pool.deinit();
    }

    /// Parallelizes the complete set of grid cells belonging to one
    /// active spatial tile. Spatial tile traversal is deliberately absent
    /// here and remains serial in the stage orchestration layer.
    fn run(self: CpuExecutor, cell_count: usize, context: anytype, comptime kernel: anytype) !void {
        if (cell_count == 0) return error.EmptyGrid;
        try self.runGridColumnsParallel(
            context,
            kernel,
            .{ .first = 0, .end = cell_count },
        );
    }

    /// Partitions horizontal grid columns inside the one active serial tile.
    /// This function does not schedule, overlap, or advance tiles.
    fn runGridColumnsParallel(self: CpuExecutor, context: anytype, comptime kernel: anytype, grid_columns: CellRange) !void {
        const Adapter = struct {
            science_context: @TypeOf(context),

            fn apply(
                adapter: *@This(),
                range: CellRange,
                _: usize,
            ) !void {
                try kernel(adapter.science_context, range);
            }
        };
        var adapter = Adapter{ .science_context = context };
        try self.runIndependentRangeIndexed(grid_columns, &adapter, Adapter.apply);
    }

    /// Partitions a contiguous range of independent non-spatial work items
    /// among stable participant indices. This deliberately carries no owned-
    /// cell capability: callers must use it only when every item is independent
    /// and the enclosing stage owns the complete range transactionally.
    pub fn runIndependentRangeIndexed(
        self: CpuExecutor,
        work_items: CellRange,
        context: anytype,
        comptime kernel: anytype,
    ) !void {
        if (work_items.end <= work_items.first) return error.EmptyWorkRange;
        const active_worker_count = @min(self.worker_count, work_items.count());
        try self.pool.acquireDispatch();
        defer self.pool.releaseDispatch();
        if (active_worker_count == 1) return kernel(context, work_items, 0);
        const worker_errors = self.pool.worker_errors[0..active_worker_count];
        @memset(worker_errors, null);
        const worker_diagnostics = self.pool.worker_diagnostics[0..active_worker_count];

        const RoundCtx = struct {
            context: @TypeOf(context),
            errors: []?anyerror,
            diagnostics: []DiagnosticCapture,
            work_items: CellRange,
            active_worker_count: usize,
        };
        const Worker = struct {
            fn entry(
                worker_context: @TypeOf(context),
                errors: []?anyerror,
                diagnostics: []DiagnosticCapture,
                work_item_range: CellRange,
                worker_index: usize,
                workers: usize,
            ) void {
                beginDiagnosticCapture(&diagnostics[worker_index]);
                defer endDiagnosticCapture(&diagnostics[worker_index]);
                const local = balancedPartition(work_item_range.count(), worker_index, workers) catch |err| {
                    errors[worker_index] = err;
                    return;
                };
                const first = std.math.add(usize, work_item_range.first, local.first) catch |err| {
                    errors[worker_index] = err;
                    return;
                };
                const end = std.math.add(usize, work_item_range.first, local.end) catch |err| {
                    errors[worker_index] = err;
                    return;
                };
                const range = CellRange{
                    .first = first,
                    .end = end,
                };
                kernel(worker_context, range, worker_index) catch |err| {
                    errors[worker_index] = err;
                };
            }

            fn trampoline(erased: *const anyopaque, worker_index: usize) void {
                const round: *const RoundCtx = @ptrCast(@alignCast(erased));
                entry(round.context, round.errors, round.diagnostics, round.work_items, worker_index, round.active_worker_count);
            }
        };
        const round_ctx = RoundCtx{
            .context = context,
            .errors = worker_errors,
            .diagnostics = worker_diagnostics,
            .work_items = work_items,
            .active_worker_count = active_worker_count,
        };

        self.pool.dispatchAcquired(active_worker_count, .{ .run = Worker.trampoline, .ctx = &round_ctx });
        replayCanonicalDiagnostics(worker_diagnostics, worker_errors);
        for (worker_errors) |maybe_error| if (maybe_error) |err| return err;
    }

    /// Assigns independent non-spatial work items round-robin to stable
    /// participant indices. This is deterministic and improves load balance
    /// when adjacent canonical indices have correlated costs. Participant-level
    /// diagnostics and errors replay in participant order; callers that require
    /// canonical item failure priority must record failures per item and scan
    /// them after this dispatch returns.
    pub fn runIndependentStridedIndexed(
        self: CpuExecutor,
        work_items: CellRange,
        context: anytype,
        comptime kernel: anytype,
    ) !void {
        if (work_items.end <= work_items.first) return error.EmptyWorkRange;
        const active_worker_count = @min(self.worker_count, work_items.count());
        try self.pool.acquireDispatch();
        defer self.pool.releaseDispatch();
        if (active_worker_count == 1) return kernel(context, .{
            .next_index = work_items.first,
            .end = work_items.end,
            .stride = 1,
        }, 0);
        const worker_errors = self.pool.worker_errors[0..active_worker_count];
        @memset(worker_errors, null);
        const worker_diagnostics = self.pool.worker_diagnostics[0..active_worker_count];

        const RoundCtx = struct {
            context: @TypeOf(context),
            errors: []?anyerror,
            diagnostics: []DiagnosticCapture,
            work_items: CellRange,
            active_worker_count: usize,
        };
        const Worker = struct {
            fn entry(
                worker_context: @TypeOf(context),
                errors: []?anyerror,
                diagnostics: []DiagnosticCapture,
                work_item_range: CellRange,
                worker_index: usize,
                workers: usize,
            ) void {
                beginDiagnosticCapture(&diagnostics[worker_index]);
                defer endDiagnosticCapture(&diagnostics[worker_index]);
                const first = std.math.add(usize, work_item_range.first, worker_index) catch |err| {
                    errors[worker_index] = err;
                    return;
                };
                kernel(worker_context, StridedIndexRange{
                    .next_index = first,
                    .end = work_item_range.end,
                    .stride = workers,
                }, worker_index) catch |err| {
                    errors[worker_index] = err;
                };
            }

            fn trampoline(erased: *const anyopaque, worker_index: usize) void {
                const round: *const RoundCtx = @ptrCast(@alignCast(erased));
                entry(round.context, round.errors, round.diagnostics, round.work_items, worker_index, round.active_worker_count);
            }
        };
        const round_ctx = RoundCtx{
            .context = context,
            .errors = worker_errors,
            .diagnostics = worker_diagnostics,
            .work_items = work_items,
            .active_worker_count = active_worker_count,
        };

        self.pool.dispatchAcquired(active_worker_count, .{ .run = Worker.trampoline, .ctx = &round_ctx });
        replayCanonicalDiagnostics(worker_diagnostics, worker_errors);
        for (worker_errors) |maybe_error| if (maybe_error) |err| return err;
    }

    /// Parallelizes an explicit Morton-ordered cell list belonging to one
    /// already-loaded tile. This function never advances to another tile.
    fn runCells(
        self: CpuExecutor,
        cells: []const usize,
        context: anytype,
        comptime kernel: anytype,
    ) !void {
        const Adapter = struct {
            science_context: @TypeOf(context),

            fn apply(
                adapter: *@This(),
                worker_cells: []const usize,
                _: usize,
            ) !void {
                try kernel(adapter.science_context, worker_cells);
            }
        };
        var adapter = Adapter{ .science_context = context };
        try self.runCellsIndexed(cells, &adapter, Adapter.apply);
    }

    /// Partitions one canonical tile-owned cell slice among stable participant
    /// indices. The caller participates as the highest active index; the
    /// serial fast path is always index zero. Tile traversal remains outside
    /// this executor and therefore serial.
    fn runCellsIndexed(
        self: CpuExecutor,
        cells: []const usize,
        context: anytype,
        comptime kernel: anytype,
    ) !void {
        if (cells.len == 0) return error.EmptyTile;
        const active_worker_count = @min(self.worker_count, cells.len);
        try self.pool.acquireDispatch();
        defer self.pool.releaseDispatch();
        if (active_worker_count == 1) return kernel(context, cells, 0);
        const worker_errors = self.pool.worker_errors[0..active_worker_count];
        @memset(worker_errors, null);
        const worker_diagnostics = self.pool.worker_diagnostics[0..active_worker_count];
        const RoundCtx = struct {
            context: @TypeOf(context),
            cells: []const usize,
            errors: []?anyerror,
            diagnostics: []DiagnosticCapture,
            active_worker_count: usize,
        };
        const Worker = struct {
            fn entry(
                worker_context: @TypeOf(context),
                all_cells: []const usize,
                errors: []?anyerror,
                diagnostics: []DiagnosticCapture,
                worker_index: usize,
                workers: usize,
            ) void {
                beginDiagnosticCapture(&diagnostics[worker_index]);
                defer endDiagnosticCapture(&diagnostics[worker_index]);
                const partition = balancedPartition(all_cells.len, worker_index, workers) catch |err| {
                    errors[worker_index] = err;
                    return;
                };
                kernel(
                    worker_context,
                    all_cells[partition.first..partition.end],
                    worker_index,
                ) catch |err| {
                    errors[worker_index] = err;
                };
            }

            fn trampoline(erased: *const anyopaque, worker_index: usize) void {
                const round: *const RoundCtx = @ptrCast(@alignCast(erased));
                entry(round.context, round.cells, round.errors, round.diagnostics, worker_index, round.active_worker_count);
            }
        };
        const round_ctx = RoundCtx{
            .context = context,
            .cells = cells,
            .errors = worker_errors,
            .diagnostics = worker_diagnostics,
            .active_worker_count = active_worker_count,
        };
        self.pool.dispatchAcquired(active_worker_count, .{ .run = Worker.trampoline, .ctx = &round_ctx });
        replayCanonicalDiagnostics(worker_diagnostics, worker_errors);
        for (worker_errors) |maybe_error| if (maybe_error) |err| return err;
    }

    fn validatedOwnedCells(self: CpuExecutor, tile: OwnedCellTile) ![]const usize {
        if (tile.plan_identity != self.owned_cell_plan_identity)
            return error.OwnedCellPlanMismatch;
        if (tile.tile_index >= self.owned_cell_offsets.len - 1)
            return error.OwnedTileIndexOutOfRange;
        const expected = self.owned_cells[self.owned_cell_offsets[tile.tile_index]..self.owned_cell_offsets[tile.tile_index + 1]];
        if (tile.cell_indices.len != expected.len or
            tile.cell_indices.ptr != expected.ptr)
            return error.NonCanonicalOwnedCellTile;
        if (expected.len == 0) return error.EmptyTile;
        if (expected.len > self.tile_cell_count)
            return error.OwnedTileExceedsExecutorCapacity;
        return expected;
    }

    /// Production entry point for one active tile. The nominal capability and
    /// plan-identity check prevent a full-domain or halo slice from being
    /// dispatched accidentally.
    pub fn runOwnedCells(
        self: CpuExecutor,
        tile: OwnedCellTile,
        context: anytype,
        comptime kernel: anytype,
    ) !void {
        try self.runIndexedCells(try self.validatedOwnedCells(tile), context, kernel);
    }

    /// Worker-local-workspace counterpart of `runOwnedCells`. The kernel is
    /// invoked once per active participant with a disjoint canonical subslice
    /// and its stable index in `0..active_participant_count`. A one-participant
    /// dispatch receives the entire canonical tile and index zero.
    pub fn runOwnedCellsIndexed(
        self: CpuExecutor,
        tile: OwnedCellTile,
        context: anytype,
        comptime kernel: anytype,
    ) !void {
        try self.runCellsIndexed(
            try self.validatedOwnedCells(tile),
            context,
            kernel,
        );
    }

    /// Adapts an existing contiguous `CellRange` kernel to an explicit
    /// non-contiguous Morton-owned cell list. Each invocation contains one
    /// global cell, preventing a range from spanning unowned halo cells.
    fn runIndexedCells(
        self: CpuExecutor,
        cells: []const usize,
        context: anytype,
        comptime cell_range_kernel: anytype,
    ) !void {
        const Adapter = struct {
            science_context: @TypeOf(context),

            noinline fn apply(
                adapter: *@This(),
                worker_cells: []const usize,
            ) !void {
                for (worker_cells) |cell| {
                    try @call(.never_inline, cell_range_kernel, .{
                        adapter.science_context,
                        CellRange{
                            .first = cell,
                            .end = try std.math.add(usize, cell, 1),
                        },
                    });
                }
            }
        };
        var adapter = Adapter{ .science_context = context };
        try self.runCells(cells, &adapter, Adapter.apply);
    }

    /// Production complete-column counterpart of `runOwnedCells`.
    pub fn runOwnedCellLayers(
        self: CpuExecutor,
        tile: OwnedCellTile,
        layer_count_per_cell: usize,
        context: anytype,
        comptime cell_layer_kernel: anytype,
    ) !void {
        try self.runIndexedCellLayers(
            try self.validatedOwnedCells(tile),
            layer_count_per_cell,
            context,
            cell_layer_kernel,
        );
    }

    /// Assigns complete horizontal grid cells to workers while adapting a
    /// cell-layer kernel that consumes a contiguous flattened layer range.
    /// No worker boundary can split the vertical column of one grid cell.
    fn runCellLayers(
        self: CpuExecutor,
        cell_count: usize,
        layer_count_per_cell: usize,
        context: anytype,
        comptime layer_kernel: anytype,
    ) !void {
        if (cell_count == 0) return error.EmptyGrid;
        if (layer_count_per_cell == 0) return error.NoSoilLayers;
        const Adapter = struct {
            science_context: @TypeOf(context),
            layers_per_cell: usize,

            fn apply(adapter: *@This(), cells: CellRange) !void {
                const first_layer = try std.math.mul(
                    usize,
                    cells.first,
                    adapter.layers_per_cell,
                );
                const end_layer = try std.math.mul(
                    usize,
                    cells.end,
                    adapter.layers_per_cell,
                );
                try layer_kernel(
                    adapter.science_context,
                    .{ .first = first_layer, .end = end_layer },
                );
            }
        };
        var adapter = Adapter{
            .science_context = context,
            .layers_per_cell = layer_count_per_cell,
        };
        // This is one already-loaded spatial tile. Parallelism is across its
        // grid cells; this method never advances to another tile.
        try self.runGridColumnsParallel(
            &adapter,
            Adapter.apply,
            .{ .first = 0, .end = cell_count },
        );
    }

    /// Parallelizes the Morton-ordered owned cells of one loaded spatial tile
    /// while preserving each cell's complete vertical column. Unlike
    /// `runCellLayers`, this accepts non-contiguous global cell indices, which
    /// is required when a rectangular tile occupies only part of each domain
    /// row. Tiles themselves remain serial in the stage orchestration layer.
    fn runIndexedCellLayers(
        self: CpuExecutor,
        cells: []const usize,
        layer_count_per_cell: usize,
        context: anytype,
        comptime cell_layer_kernel: anytype,
    ) !void {
        if (cells.len == 0) return error.EmptyTile;
        if (layer_count_per_cell == 0) return error.NoSoilLayers;
        const Adapter = struct {
            science_context: @TypeOf(context),
            layers_per_cell: usize,

            noinline fn apply(
                adapter: *@This(),
                worker_cells: []const usize,
            ) !void {
                for (worker_cells) |cell| {
                    const first_layer = try std.math.mul(
                        usize,
                        cell,
                        adapter.layers_per_cell,
                    );
                    try @call(.never_inline, cell_layer_kernel, .{
                        adapter.science_context,
                        CellRange{
                            .first = first_layer,
                            .end = try std.math.add(
                                usize,
                                first_layer,
                                adapter.layers_per_cell,
                            ),
                        },
                    });
                }
            }
        };
        var adapter = Adapter{
            .science_context = context,
            .layers_per_cell = layer_count_per_cell,
        };
        try self.runCells(cells, &adapter, Adapter.apply);
    }
};

fn balancedPartition(item_count: usize, participant_index: usize, participant_count: usize) !CellRange {
    if (participant_count == 0 or participant_count > item_count or participant_index >= participant_count)
        return error.InvalidComputePartition;
    const base_count = item_count / participant_count;
    const extra_count = item_count % participant_count;
    const base_first = try std.math.mul(usize, participant_index, base_count);
    const first = try std.math.add(usize, base_first, @min(participant_index, extra_count));
    const count = try std.math.add(
        usize,
        base_count,
        @intFromBool(participant_index < extra_count),
    );
    return .{
        .first = first,
        .end = try std.math.add(usize, first, count),
    };
}

test "balanced grid partition covers boundary and uneven cases without empty participants" {
    try std.testing.expectError(error.InvalidComputePartition, balancedPartition(0, 0, 0));
    try std.testing.expectError(error.InvalidComputePartition, balancedPartition(1, 0, 0));
    try std.testing.expectError(error.InvalidComputePartition, balancedPartition(1, 1, 1));
    try std.testing.expectError(error.InvalidComputePartition, balancedPartition(1, 0, 2));

    try std.testing.expectEqual(CellRange{ .first = 0, .end = 7 }, try balancedPartition(7, 0, 1));
    for (0..5) |index| try std.testing.expectEqual(
        CellRange{ .first = index, .end = index + 1 },
        try balancedPartition(5, index, 5),
    );
    const uneven_expected = [_]CellRange{
        .{ .first = 0, .end = 2 },
        .{ .first = 2, .end = 3 },
        .{ .first = 3, .end = 4 },
        .{ .first = 4, .end = 5 },
    };
    for (uneven_expected, 0..) |expected, index|
        try std.testing.expectEqual(expected, try balancedPartition(5, index, 4));

    const maximum = std.math.maxInt(usize);
    const last = try balancedPartition(maximum, 1, 2);
    try std.testing.expectEqual(maximum / 2 + 1, last.first);
    try std.testing.expectEqual(maximum, last.end);
}

const FillContext = struct { values: []usize };

var test_owned_cell_plan_identity: u8 = 0;

fn initTestExecutor(
    allocator: std.mem.Allocator,
    worker_count: usize,
    maximum_owned_cell_count: usize,
) !CpuExecutor {
    return CpuExecutor.initConfigured(
        allocator,
        worker_count,
        @ptrCast(&test_owned_cell_plan_identity),
        maximum_owned_cell_count,
        &.{},
        &.{},
        std.math.maxInt(usize),
    );
}

fn fillSquares(context: *FillContext, range: CellRange) !void {
    for (range.first..range.end) |index| context.values[index] = try std.math.mul(usize, index, index);
}

test "runtime workers process every cell in one loaded tile exactly" {
    const allocator = std.testing.allocator;
    const values = try allocator.alloc(usize, 10_003);
    defer allocator.free(values);
    @memset(values, std.math.maxInt(usize));
    var context = FillContext{ .values = values };
    const executor = try initTestExecutor(allocator, 7, 113);
    defer executor.deinit();
    try executor.run(values.len, &context, fillSquares);
    for (values, 0..) |value, index| try std.testing.expectEqual(index * index, value);
}

test "executor retains balanced layer participants while one-cell spatial work stays serial" {
    var value = [_]usize{std.math.maxInt(usize)};
    var context = FillContext{ .values = &value };
    const executor = try initTestExecutor(std.testing.allocator, 4, 1);
    defer executor.deinit();

    try std.testing.expectEqual(@as(usize, 4), executor.worker_count);
    try std.testing.expectEqual(@as(usize, 3), executor.pool.threads.len);
    try executor.run(1, &context, fillSquares);
    try std.testing.expectEqual(@as(usize, 0), value[0]);
    try std.testing.expectEqual(@as(u64, 0), executor.statistics().parallel_dispatches);

    const LayerContext = struct {
        worker_by_layer: []usize,

        fn apply(self: *@This(), range: CellRange, worker_index: usize) !void {
            for (range.first..range.end) |layer| self.worker_by_layer[layer] = worker_index;
        }
    };
    var worker_by_layer = [_]usize{std.math.maxInt(usize)} ** 10;
    var layer_context = LayerContext{ .worker_by_layer = &worker_by_layer };
    try executor.runIndependentRangeIndexed(
        .{ .first = 0, .end = worker_by_layer.len },
        &layer_context,
        LayerContext.apply,
    );
    try std.testing.expectEqualSlices(
        usize,
        &.{ 0, 0, 0, 1, 1, 1, 2, 2, 3, 3 },
        &worker_by_layer,
    );
    try std.testing.expectEqual(@as(u64, 1), executor.statistics().parallel_dispatches);

    @memset(&worker_by_layer, std.math.maxInt(usize));
    try executor.runIndependentStridedIndexed(
        .{ .first = 0, .end = worker_by_layer.len },
        &layer_context,
        struct {
            fn apply(self: *LayerContext, worker_layers: StridedIndexRange, worker_index: usize) !void {
                var layers = worker_layers;
                while (layers.next()) |layer| self.worker_by_layer[layer] = worker_index;
            }
        }.apply,
    );
    try std.testing.expectEqualSlices(
        usize,
        &.{ 0, 1, 2, 3, 0, 1, 2, 3, 0, 1 },
        &worker_by_layer,
    );
    try std.testing.expectEqual(@as(u64, 2), executor.statistics().parallel_dispatches);
}

test "executor participant ceiling includes hardware concurrency" {
    var identity: u8 = 0;
    const offsets = [_]usize{ 0, 17 };
    const owned = [_]usize{0} ** 17;
    const executor = try CpuExecutor.initWithHardwareThreadCount(
        std.testing.allocator,
        99,
        .{
            .identity = @ptrCast(&identity),
            .maximum_owned_cell_count = 17,
            .owned_cell_offsets = &offsets,
            .owned_cells = &owned,
        },
        3,
    );
    defer executor.deinit();
    const statistics = executor.statistics();
    try std.testing.expectEqual(@as(usize, 99), statistics.requested_threads);
    try std.testing.expectEqual(@as(usize, 3), statistics.effective_threads);
    try std.testing.expectEqual(@as(usize, 2), statistics.background_threads);
}

test "public executor never exceeds queried hardware participants" {
    const hardware_thread_count = @max(std.Thread.getCpuCount() catch 1, 1);
    var identity: u8 = 0;
    const requested = try std.math.add(usize, hardware_thread_count, 7);
    const owned = try std.testing.allocator.alloc(usize, requested);
    defer std.testing.allocator.free(owned);
    const offsets = [_]usize{ 0, requested };
    const executor = try CpuExecutor.init(
        std.testing.allocator,
        requested,
        .{
            .identity = @ptrCast(&identity),
            .maximum_owned_cell_count = requested,
            .owned_cell_offsets = &offsets,
            .owned_cells = owned,
        },
    );
    defer executor.deinit();
    try std.testing.expect(executor.statistics().effective_threads <= hardware_thread_count);
}

test "owned-cell capability dispatches only its tile and rejects other plans" {
    const Context = struct {
        visits: []u8,

        fn apply(self: *@This(), cells: CellRange) !void {
            for (cells.first..cells.end) |cell| self.visits[cell] += 1;
        }
    };
    var identity: u8 = 0;
    var other_identity: u8 = 0;
    const offsets = [_]usize{ 0, 2 };
    const owned = [_]usize{ 1, 4 };
    const executor = try CpuExecutor.initWithHardwareThreadCount(
        std.testing.allocator,
        4,
        .{
            .identity = @ptrCast(&identity),
            .maximum_owned_cell_count = 2,
            .owned_cell_offsets = &offsets,
            .owned_cells = &owned,
        },
        4,
    );
    defer executor.deinit();
    var visits = [_]u8{0} ** 6;
    var context = Context{ .visits = &visits };
    try executor.runOwnedCells(.{
        .plan_identity = @ptrCast(&identity),
        .tile_index = 0,
        .cell_indices = &owned,
    }, &context, Context.apply);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 0, 1, 0 }, &visits);

    try std.testing.expectError(error.OwnedCellPlanMismatch, executor.runOwnedCells(.{
        .plan_identity = @ptrCast(&other_identity),
        .tile_index = 0,
        .cell_indices = &owned,
    }, &context, Context.apply));
    try std.testing.expectError(error.NonCanonicalOwnedCellTile, executor.runOwnedCells(.{
        .plan_identity = @ptrCast(&identity),
        .tile_index = 0,
        .cell_indices = &.{ 0, 1, 2 },
    }, &context, Context.apply));
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 0, 1, 0 }, &visits);
}

test "owned indexed dispatch gives exact disjoint canonical slices and stable worker indices" {
    const Context = struct {
        canonical: []const usize,
        visits: []u8,
        worker_by_position: []usize,
        active_participants: usize,

        fn apply(
            self: *@This(),
            cells: []const usize,
            worker_index: usize,
        ) !void {
            if (worker_index >= self.active_participants)
                return error.WorkerIndexOutOfRange;
            const expected_partition = try balancedPartition(
                self.canonical.len,
                worker_index,
                self.active_participants,
            );
            const expected = self.canonical[expected_partition.first..expected_partition.end];
            if (cells.len != expected.len or cells.ptr != expected.ptr)
                return error.NonCanonicalWorkerSlice;
            for (cells, expected_partition.first..) |cell, position| {
                if (cell != self.canonical[position])
                    return error.NonCanonicalWorkerCell;
                if (self.visits[position] != 0)
                    return error.OwnedCellProcessedMoreThanOnce;
                self.visits[position] = 1;
                self.worker_by_position[position] = worker_index;
            }
        }
    };
    var identity: u8 = 0;
    const offsets = [_]usize{ 0, 5 };
    const owned = [_]usize{ 10, 2, 9, 4, 7 };
    const executor = try CpuExecutor.initWithHardwareThreadCount(
        std.testing.allocator,
        99,
        .{
            .identity = @ptrCast(&identity),
            .maximum_owned_cell_count = owned.len,
            .owned_cell_offsets = &offsets,
            .owned_cells = &owned,
        },
        4,
    );
    defer executor.deinit();
    try std.testing.expectEqual(
        @as(usize, 4),
        executor.statistics().effective_threads,
    );
    var visits = [_]u8{0} ** owned.len;
    var worker_by_position = [_]usize{std.math.maxInt(usize)} ** owned.len;
    var context = Context{
        .canonical = &owned,
        .visits = &visits,
        .worker_by_position = &worker_by_position,
        .active_participants = 4,
    };
    try executor.runOwnedCellsIndexed(.{
        .plan_identity = @ptrCast(&identity),
        .tile_index = 0,
        .cell_indices = &owned,
    }, &context, Context.apply);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1 }, &visits);
    try std.testing.expectEqualSlices(
        usize,
        &.{ 0, 0, 1, 2, 3 },
        &worker_by_position,
    );
}

test "owned indexed serial path uses worker zero and rejects forged tiles" {
    const Context = struct {
        expected: []const usize,
        calls: usize = 0,
        worker_index: usize = std.math.maxInt(usize),

        fn apply(
            self: *@This(),
            cells: []const usize,
            worker_index: usize,
        ) !void {
            if (cells.len != self.expected.len or cells.ptr != self.expected.ptr)
                return error.NonCanonicalSerialSlice;
            self.calls += 1;
            self.worker_index = worker_index;
        }
    };
    var identity: u8 = 0;
    var other_identity: u8 = 0;
    const offsets = [_]usize{ 0, 1 };
    const owned = [_]usize{17};
    var forged = [_]usize{17};
    const executor = try CpuExecutor.initWithHardwareThreadCount(
        std.testing.allocator,
        8,
        .{
            .identity = @ptrCast(&identity),
            .maximum_owned_cell_count = 1,
            .owned_cell_offsets = &offsets,
            .owned_cells = &owned,
        },
        8,
    );
    defer executor.deinit();
    var context = Context{ .expected = &owned };
    try executor.runOwnedCellsIndexed(.{
        .plan_identity = @ptrCast(&identity),
        .tile_index = 0,
        .cell_indices = &owned,
    }, &context, Context.apply);
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expectEqual(@as(usize, 0), context.worker_index);
    try std.testing.expectEqual(@as(u64, 0), executor.statistics().parallel_dispatches);

    try std.testing.expectError(
        error.NonCanonicalOwnedCellTile,
        executor.runOwnedCellsIndexed(.{
            .plan_identity = @ptrCast(&identity),
            .tile_index = 0,
            .cell_indices = &forged,
        }, &context, Context.apply),
    );
    try std.testing.expectError(
        error.OwnedCellPlanMismatch,
        executor.runOwnedCellsIndexed(.{
            .plan_identity = @ptrCast(&other_identity),
            .tile_index = 0,
            .cell_indices = &owned,
        }, &context, Context.apply),
    );
    try std.testing.expectEqual(@as(usize, 1), context.calls);
}

test "owned indexed dispatch returns the lowest worker error" {
    const Context = struct {
        fn apply(_: *@This(), _: []const usize, worker_index: usize) !void {
            if (worker_index == 0) return error.LowestWorkerFailure;
            return error.LaterWorkerFailure;
        }
    };
    var identity: u8 = 0;
    const offsets = [_]usize{ 0, 4 };
    const owned = [_]usize{ 0, 1, 2, 3 };
    const executor = try CpuExecutor.initWithHardwareThreadCount(
        std.testing.allocator,
        4,
        .{
            .identity = @ptrCast(&identity),
            .maximum_owned_cell_count = owned.len,
            .owned_cell_offsets = &offsets,
            .owned_cells = &owned,
        },
        4,
    );
    defer executor.deinit();
    var context: Context = .{};
    try std.testing.expectError(
        error.LowestWorkerFailure,
        executor.runOwnedCellsIndexed(.{
            .plan_identity = @ptrCast(&identity),
            .tile_index = 0,
            .cell_indices = &owned,
        }, &context, Context.apply),
    );
}

test "parallel diagnostics replay the serial-reachable grid prefix in canonical order" {
    const ReplayLog = struct {
        bytes: [128]u8 = undefined,
        len: usize = 0,

        fn replay(
            erased: *anyopaque,
            _: std.log.Level,
            _: []const u8,
            _: bool,
            message: []const u8,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(erased));
            std.debug.assert(message.len <= self.bytes.len - self.len);
            @memcpy(self.bytes[self.len..][0..message.len], message);
            self.len += message.len;
        }
    };
    const Context = struct {
        replay_log: *ReplayLog,

        fn apply(
            self: *@This(),
            _: []const usize,
            worker_index: usize,
        ) !void {
            const Formatter = struct {
                fn write(
                    erased: *const anyopaque,
                    writer: *std.Io.Writer,
                ) std.Io.Writer.Error!void {
                    const index: *const usize = @ptrCast(@alignCast(erased));
                    return writer.print("worker={d}\n", .{index.*});
                }
            };
            if (!captureActiveDiagnostic(
                .{
                    .context = @ptrCast(self.replay_log),
                    .write_fn = ReplayLog.replay,
                },
                .err,
                "grid_test",
                false,
                .{
                    .context = @ptrCast(&worker_index),
                    .write_fn = Formatter.write,
                },
            )) return error.MissingParallelDiagnosticCapture;
            // The caller owns the highest partition and therefore records
            // first on a typical dispatch. Every nonzero partition fails, so
            // serial traversal can reach only partitions zero and one.
            if (worker_index != 0) return error.SyntheticGridFailure;
        }
    };

    var identity: u8 = 0;
    const offsets = [_]usize{ 0, 4 };
    const owned = [_]usize{ 3, 1, 7, 5 };
    const executor = try CpuExecutor.initWithHardwareThreadCount(
        std.testing.allocator,
        4,
        .{
            .identity = @ptrCast(&identity),
            .maximum_owned_cell_count = owned.len,
            .owned_cell_offsets = &offsets,
            .owned_cells = &owned,
        },
        4,
    );
    defer executor.deinit();
    var replay_log: ReplayLog = .{};
    var context = Context{ .replay_log = &replay_log };
    try std.testing.expectError(
        error.SyntheticGridFailure,
        executor.runOwnedCellsIndexed(.{
            .plan_identity = @ptrCast(&identity),
            .tile_index = 0,
            .cell_indices = &owned,
        }, &context, Context.apply),
    );
    try std.testing.expectEqualStrings(
        "worker=0\nworker=1\n",
        replay_log.bytes[0..replay_log.len],
    );
}

test "owned indexed dispatch rejects nested use of the same executor" {
    const Context = struct {
        executor: CpuExecutor,
        tile: OwnedCellTile,

        fn inner(_: *@This(), _: []const usize, _: usize) !void {}

        fn outer(
            self: *@This(),
            _: []const usize,
            _: usize,
        ) !void {
            try self.executor.runOwnedCellsIndexed(
                self.tile,
                self,
                inner,
            );
        }
    };
    var identity: u8 = 0;
    const offsets = [_]usize{ 0, 1 };
    const owned = [_]usize{3};
    const executor = try CpuExecutor.initWithHardwareThreadCount(
        std.testing.allocator,
        1,
        .{
            .identity = @ptrCast(&identity),
            .maximum_owned_cell_count = 1,
            .owned_cell_offsets = &offsets,
            .owned_cells = &owned,
        },
        1,
    );
    defer executor.deinit();
    const tile: OwnedCellTile = .{
        .plan_identity = @ptrCast(&identity),
        .tile_index = 0,
        .cell_indices = &owned,
    };
    var context = Context{ .executor = executor, .tile = tile };
    try std.testing.expectError(
        error.ConcurrentExecutorDispatch,
        executor.runOwnedCellsIndexed(tile, &context, Context.outer),
    );
}

const CallerParticipationContext = struct {
    caller_id: std.Thread.Id,
    caller_by_cell: []bool,
};

fn markCallerPartition(
    context: *CallerParticipationContext,
    range: CellRange,
) !void {
    const is_caller = std.Thread.getCurrentId() == context.caller_id;
    for (range.first..range.end) |cell| context.caller_by_cell[cell] = is_caller;
}

test "thread limit counts caller and caller owns final partition" {
    var caller_by_cell = [_]bool{false} ** 8;
    var context = CallerParticipationContext{
        .caller_id = std.Thread.getCurrentId(),
        .caller_by_cell = &caller_by_cell,
    };
    const executor = try initTestExecutor(std.testing.allocator, 7, 4);
    defer executor.deinit();

    const before = executor.statistics();
    try std.testing.expectEqual(@as(usize, 7), before.requested_threads);
    try std.testing.expectEqual(@as(usize, 7), before.effective_threads);
    try std.testing.expectEqual(@as(usize, 6), before.background_threads);
    try std.testing.expectEqual(@as(usize, 4), before.maximum_tile_cells);
    try std.testing.expectEqual(@as(u64, 0), before.parallel_dispatches);

    try executor.run(caller_by_cell.len, &context, markCallerPartition);
    try std.testing.expectEqualSlices(
        bool,
        &([_]bool{ false, false, false, false, false, false, false, true }),
        &caller_by_cell,
    );
    try std.testing.expectEqual(@as(u64, 1), executor.statistics().parallel_dispatches);
}

const FailureContext = struct { failing_cell: usize };

fn failInsideTile(context: *FailureContext, range: CellRange) !void {
    if (context.failing_cell >= range.first and context.failing_cell < range.end) return error.DeliberateKernelFailure;
}

test "worker kernel errors are propagated" {
    var context = FailureContext{ .failing_cell = 777 };
    const executor = try initTestExecutor(std.testing.allocator, 4, 64);
    defer executor.deinit();
    try std.testing.expectError(error.DeliberateKernelFailure, executor.run(1000, &context, failInsideTile));
}

fn failEveryPartition(_: *u8, range: CellRange) !void {
    if (range.first == 0) return error.LowestPartitionFailure;
    return error.LaterPartitionFailure;
}

test "caller participation preserves lowest-partition error priority" {
    var context: u8 = 0;
    const executor = try initTestExecutor(std.testing.allocator, 4, 4);
    defer executor.deinit();
    try std.testing.expectError(
        error.LowestPartitionFailure,
        executor.run(8, &context, failEveryPartition),
    );
}

const BlockingDispatchContext = struct {
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    dispatch_error: ?anyerror = null,
};

fn blockDispatch(context: *BlockingDispatchContext, _: CellRange) !void {
    context.entered.store(true, .release);
    var spins: u32 = 0;
    while (!context.release.load(.acquire)) Pool.backoff(&spins);
}

const BlockingDispatchThread = struct {
    fn run(executor: CpuExecutor, context: *BlockingDispatchContext) void {
        executor.run(4, context, blockDispatch) catch |err| {
            context.dispatch_error = err;
        };
    }
};

test "concurrent dispatch on one executor is rejected before shared round state changes" {
    const executor = try initTestExecutor(std.testing.allocator, 4, 4);
    defer executor.deinit();
    var blocking_context: BlockingDispatchContext = .{};
    const thread = try std.Thread.spawn(
        .{},
        BlockingDispatchThread.run,
        .{ executor, &blocking_context },
    );

    var spins: u32 = 0;
    while (!blocking_context.entered.load(.acquire)) Pool.backoff(&spins);
    // A background worker may observe the published generation immediately
    // before the caller increments the diagnostic dispatch counter.
    while (executor.statistics().parallel_dispatches == 0) Pool.backoff(&spins);
    var value = [_]usize{std.math.maxInt(usize)};
    var fill_context = FillContext{ .values = &value };
    try std.testing.expectError(
        error.ConcurrentExecutorDispatch,
        executor.run(1, &fill_context, fillSquares),
    );
    try std.testing.expectEqual(std.math.maxInt(usize), value[0]);
    try std.testing.expectEqual(@as(u64, 1), executor.statistics().parallel_dispatches);

    blocking_context.release.store(true, .release);
    thread.join();
    try std.testing.expect(blocking_context.dispatch_error == null);
}

test "indexed cell dispatch adapts CellRange kernels without touching halos" {
    const values = try std.testing.allocator.alloc(usize, 12);
    defer std.testing.allocator.free(values);
    @memset(values, std.math.maxInt(usize));
    const morton_owned_cells = [_]usize{ 1, 2, 5, 6, 9, 10 };
    var context = FillContext{ .values = values };
    const executor = try initTestExecutor(std.testing.allocator, 3, 6);
    defer executor.deinit();
    try executor.runIndexedCells(
        &morton_owned_cells,
        &context,
        fillSquares,
    );
    for (values, 0..) |value, cell| {
        if (std.mem.indexOfScalar(
            usize,
            &morton_owned_cells,
            cell,
        ) != null) {
            try std.testing.expectEqual(cell * cell, value);
        } else {
            try std.testing.expectEqual(std.math.maxInt(usize), value);
        }
    }
}

const LayerOwnershipContext = struct {
    owner_by_layer: []usize,
    next_owner: std.atomic.Value(usize) = .init(0),
};

fn markWholeCellLayers(
    context: *LayerOwnershipContext,
    range: CellRange,
) !void {
    const owner = context.next_owner.fetchAdd(1, .monotonic);
    for (range.first..range.end) |layer| {
        if (context.owner_by_layer[layer] != std.math.maxInt(usize))
            return error.LayerProcessedMoreThanOnce;
        context.owner_by_layer[layer] = owner;
    }
}

test "cell-layer dispatch never splits one grid column between workers" {
    const layers_per_cell: usize = 7;
    const cell_count: usize = 13;
    const owners = try std.testing.allocator.alloc(
        usize,
        cell_count * layers_per_cell,
    );
    defer std.testing.allocator.free(owners);
    @memset(owners, std.math.maxInt(usize));
    var context = LayerOwnershipContext{
        .owner_by_layer = owners,
    };
    const executor = try initTestExecutor(std.testing.allocator, 4, cell_count);
    defer executor.deinit();
    try executor.runCellLayers(
        cell_count,
        layers_per_cell,
        &context,
        markWholeCellLayers,
    );
    for (0..cell_count) |cell| {
        const first = cell * layers_per_cell;
        for (owners[first..][0..layers_per_cell]) |owner|
            try std.testing.expectEqual(owners[first], owner);
    }
}

const IndexedLayerContext = struct {
    visits_by_layer: []u8,
    visited_cells: []u8,
};

fn markIndexedCellLayers(
    context: *IndexedLayerContext,
    range: CellRange,
) !void {
    const cell = range.first / 3;
    if (context.visited_cells[cell] != 0) return error.CellProcessedMoreThanOnce;
    context.visited_cells[cell] = 1;
    for (range.first..range.end) |layer| {
        if (context.visits_by_layer[layer] != 0)
            return error.LayerProcessedMoreThanOnce;
        context.visits_by_layer[layer] = 1;
    }
}

test "indexed cell-layer dispatch supports non-contiguous Morton tile cells" {
    const cell_count: usize = 12;
    const layers_per_cell: usize = 3;
    // A two-column rectangular tile inside a four-column global domain.
    const morton_owned_cells = [_]usize{ 1, 2, 5, 6, 9, 10 };
    const visits = try std.testing.allocator.alloc(
        u8,
        cell_count * layers_per_cell,
    );
    defer std.testing.allocator.free(visits);
    const visited_cells = try std.testing.allocator.alloc(u8, cell_count);
    defer std.testing.allocator.free(visited_cells);
    @memset(visits, 0);
    @memset(visited_cells, 0);
    var context = IndexedLayerContext{
        .visits_by_layer = visits,
        .visited_cells = visited_cells,
    };
    const executor = try initTestExecutor(std.testing.allocator, 3, 6);
    defer executor.deinit();
    try executor.runIndexedCellLayers(
        &morton_owned_cells,
        layers_per_cell,
        &context,
        markIndexedCellLayers,
    );
    for (0..cell_count) |cell| {
        const expected: u8 =
            if (std.mem.indexOfScalar(usize, &morton_owned_cells, cell) != null)
                1
            else
                0;
        try std.testing.expectEqual(expected, visited_cells[cell]);
        const first = cell * layers_per_cell;
        for (visits[first..][0..layers_per_cell]) |visit|
            try std.testing.expectEqual(expected, visit);
    }
}

test "owned multi-tile layer dispatch keeps tiles serial and columns whole" {
    const cell_count: usize = 12;
    const layers_per_cell: usize = 3;
    var plan_identity: u8 = 0;
    const offsets = [_]usize{ 0, 4, 8 };
    const owned_cells = [_]usize{ 1, 4, 7, 10, 2, 5, 8, 11 };
    const executor = try CpuExecutor.initWithHardwareThreadCount(
        std.testing.allocator,
        4,
        .{
            .identity = @ptrCast(&plan_identity),
            .maximum_owned_cell_count = 4,
            .owned_cell_offsets = &offsets,
            .owned_cells = &owned_cells,
        },
        4,
    );
    defer executor.deinit();

    var visits = [_]u8{0} ** (cell_count * layers_per_cell);
    var visited_cells = [_]u8{0} ** cell_count;
    var context = IndexedLayerContext{
        .visits_by_layer = &visits,
        .visited_cells = &visited_cells,
    };
    const first_tile = OwnedCellTile{
        .plan_identity = @ptrCast(&plan_identity),
        .tile_index = 0,
        .cell_indices = owned_cells[offsets[0]..offsets[1]],
    };
    const second_tile = OwnedCellTile{
        .plan_identity = @ptrCast(&plan_identity),
        .tile_index = 1,
        .cell_indices = owned_cells[offsets[1]..offsets[2]],
    };

    try executor.runOwnedCellLayers(
        first_tile,
        layers_per_cell,
        &context,
        markIndexedCellLayers,
    );
    for (0..cell_count) |cell| {
        const expected: u8 = @intFromBool(
            std.mem.indexOfScalar(usize, first_tile.cells(), cell) != null,
        );
        try std.testing.expectEqual(expected, visited_cells[cell]);
        const first_layer = cell * layers_per_cell;
        for (visits[first_layer..][0..layers_per_cell]) |visit|
            try std.testing.expectEqual(expected, visit);
    }

    // The first dispatch has completed before the second tile is admitted.
    try executor.runOwnedCellLayers(
        second_tile,
        layers_per_cell,
        &context,
        markIndexedCellLayers,
    );
    for (0..cell_count) |cell| {
        const expected: u8 = @intFromBool(
            std.mem.indexOfScalar(usize, &owned_cells, cell) != null,
        );
        try std.testing.expectEqual(expected, visited_cells[cell]);
        const first_layer = cell * layers_per_cell;
        for (visits[first_layer..][0..layers_per_cell]) |visit|
            try std.testing.expectEqual(expected, visit);
    }
    try std.testing.expectEqual(@as(u64, 2), executor.statistics().parallel_dispatches);
}

const RepeatedDispatchContext = struct {
    visits: []std.atomic.Value(u32),
};

fn markVisitRange(context: *RepeatedDispatchContext, range: CellRange) !void {
    for (range.first..range.end) |index| _ = context.visits[index].fetchAdd(1, .monotonic);
}

fn markVisitCells(context: *RepeatedDispatchContext, cells: []const usize) !void {
    for (cells) |index| _ = context.visits[index].fetchAdd(1, .monotonic);
}

const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocation_calls: usize = 0,
    requested_bytes: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocate,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn reset(self: *@This()) void {
        self.allocation_calls = 0;
        self.requested_bytes = 0;
    }

    fn fromOpaque(pointer: *anyopaque) *@This() {
        return @ptrCast(@alignCast(pointer));
    }

    fn allocate(pointer: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self = fromOpaque(pointer);
        const result = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.allocation_calls += 1;
        self.requested_bytes += len;
        return result;
    }

    fn resize(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self = fromOpaque(pointer);
        if (!self.child.rawResize(memory, alignment, new_len, return_address)) return false;
        if (new_len > memory.len) self.requested_bytes += new_len - memory.len;
        return true;
    }

    fn remap(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self = fromOpaque(pointer);
        const result = self.child.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        if (new_len > memory.len) self.requested_bytes += new_len - memory.len;
        return result;
    }

    fn free(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        fromOpaque(pointer).child.rawFree(memory, alignment, return_address);
    }
};

test "persistent pool dispatches allocate no steady-state memory" {
    const cell_count: usize = 41;
    const visits = try std.testing.allocator.alloc(std.atomic.Value(u32), cell_count);
    defer std.testing.allocator.free(visits);
    const cells = try std.testing.allocator.alloc(usize, cell_count);
    defer std.testing.allocator.free(cells);
    for (cells, 0..) |*cell, index| cell.* = index;
    var context = RepeatedDispatchContext{ .visits = visits };

    var counter: CountingAllocator = .{ .child = std.testing.allocator };
    const executor = try initTestExecutor(counter.allocator(), 6, cell_count);
    defer executor.deinit();
    counter.reset();

    for (0..100) |_| {
        for (visits) |*visit| visit.store(0, .monotonic);
        try executor.run(cell_count, &context, markVisitRange);
        try executor.runCells(cells, &context, markVisitCells);
    }
    try std.testing.expectEqual(@as(usize, 0), counter.allocation_calls);
    try std.testing.expectEqual(@as(usize, 0), counter.requested_bytes);
    for (visits) |*visit| try std.testing.expectEqual(@as(u32, 2), visit.load(.monotonic));
}

// Reuses one persistent pool across thousands of rounds with a varying
// `active_worker_count` (including rounds smaller than `worker_count`),
// asserting every visited cell is processed exactly once per round. The
// single-round tests above cannot catch a missed-wakeup or double-dispatch
// race in the pool's generation/wait/signal handshake; only repetition can.
test "persistent pool: run() visits every cell exactly once across many rounds with varying active worker counts" {
    const allocator = std.testing.allocator;
    const cell_count: usize = 37;
    const visits = try allocator.alloc(std.atomic.Value(u32), cell_count);
    defer allocator.free(visits);
    var context = RepeatedDispatchContext{ .visits = visits };
    const executor = try initTestExecutor(allocator, 5, cell_count);
    defer executor.deinit();

    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        for (visits) |*v| v.store(0, .monotonic);
        const this_round_count = 1 + (round % cell_count);
        try executor.run(this_round_count, &context, markVisitRange);
        for (visits[0..this_round_count]) |*v| try std.testing.expectEqual(@as(u32, 1), v.load(.monotonic));
        for (visits[this_round_count..]) |*v| try std.testing.expectEqual(@as(u32, 0), v.load(.monotonic));
    }
}

test "persistent pool: runCells() visits every listed cell exactly once across many rounds with varying active worker counts" {
    const allocator = std.testing.allocator;
    const cell_count: usize = 41;
    const visits = try allocator.alloc(std.atomic.Value(u32), cell_count);
    defer allocator.free(visits);
    var context = RepeatedDispatchContext{ .visits = visits };
    const executor = try initTestExecutor(allocator, 6, cell_count);
    defer executor.deinit();

    const all_cells = try allocator.alloc(usize, cell_count);
    defer allocator.free(all_cells);
    for (all_cells, 0..) |*cell, index| cell.* = index;

    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        for (visits) |*v| v.store(0, .monotonic);
        const this_round_count = 1 + (round % cell_count);
        try executor.runCells(all_cells[0..this_round_count], &context, markVisitCells);
        for (visits[0..this_round_count]) |*v| try std.testing.expectEqual(@as(u32, 1), v.load(.monotonic));
        for (visits[this_round_count..]) |*v| try std.testing.expectEqual(@as(u32, 0), v.load(.monotonic));
    }
}

test "persistent pool: two executors with independent pools do not interfere" {
    const allocator = std.testing.allocator;
    const cell_count: usize = 29;
    const visits_a = try allocator.alloc(std.atomic.Value(u32), cell_count);
    defer allocator.free(visits_a);
    const visits_b = try allocator.alloc(std.atomic.Value(u32), cell_count);
    defer allocator.free(visits_b);
    var context_a = RepeatedDispatchContext{ .visits = visits_a };
    var context_b = RepeatedDispatchContext{ .visits = visits_b };
    const executor_a = try initTestExecutor(allocator, 4, cell_count);
    defer executor_a.deinit();
    const executor_b = try initTestExecutor(allocator, 5, cell_count);
    defer executor_b.deinit();

    var round: usize = 0;
    while (round < 500) : (round += 1) {
        for (visits_a) |*v| v.store(0, .monotonic);
        for (visits_b) |*v| v.store(0, .monotonic);
        try executor_a.run(cell_count, &context_a, markVisitRange);
        try executor_b.run(cell_count, &context_b, markVisitRange);
        for (visits_a) |*v| try std.testing.expectEqual(@as(u32, 1), v.load(.monotonic));
        for (visits_b) |*v| try std.testing.expectEqual(@as(u32, 1), v.load(.monotonic));
    }
}
