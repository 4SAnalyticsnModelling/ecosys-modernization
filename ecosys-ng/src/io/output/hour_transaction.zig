const std = @import("std");
const execution_calendar_date = @import("../../driver/execution_calendar_date.zig");

const journal_magic = "ECOUTH01";
const bank_magic = "ECOUTBN1";
const cursor_magic = "ECOUTCR1";
const format_version: u32 = 1;
const checksum_seed: u64 = 0x45434f5554484f55;
const cursor_file_name = ".ecosys-output-cursor.bin";
const entry_tag: u8 = 0xe1;
const trailer_tag: u8 = 0xff;
const category_count = @typeInfo(Category).@"enum".fields.len;

/// The five stable output directories. One root-scoped coordinator owns the
/// commit boundary across all of them.
pub const Category = enum(u8) { carbon, water, nitrogen, heat_energy, phosphorus };

pub const CategoryDirs = struct {
    carbon: std.Io.Dir,
    water: std.Io.Dir,
    nitrogen: std.Io.Dir,
    heat_energy: std.Io.Dir,
    phosphorus: std.Io.Dir,

    fn get(self: CategoryDirs, category: Category) std.Io.Dir {
        return switch (category) {
            .carbon => self.carbon,
            .water => self.water,
            .nitrogen => self.nitrogen,
            .heat_energy => self.heat_energy,
            .phosphorus => self.phosphorus,
        };
    }
};

/// A globally ordered hour identity. The caller supplies `generation`; the
/// remaining fields make an accidentally reused generation fail closed.
pub const Instant = struct {
    year: i32,
    day_of_year: u16,
    hour: u8,
    execution_iteration: u64 = 0,
    scenario_index: u64 = 0,
    scenario_iteration: u64 = 0,
    scene_index: u64 = 0,
    completed_scene_hours: u64 = 0,
};

pub const AcceptedCheckpoint = struct {
    checkpoint_generation: u64,
    output_generation: u64,
    instant: Instant,
};

/// `initial_state` is intentionally distinct from `fresh`: it authorizes
/// deterministic replay of output which is ahead of the initial model state.
pub const ResumePoint = union(enum) {
    fresh,
    initial_state,
    checkpoint: AcceptedCheckpoint,
};

pub const FailurePoint = enum {
    none,
    before_journal_publish,
    after_journal_publish,
    during_materialization,
    after_materialization_before_cursor,
    during_cursor_publish,
    after_cursor_publish,
    before_checkpoint_publish,
    during_checkpoint_publish,
    after_checkpoint_publish,
    after_bank_publish_before_checkpoint_ack,
    after_checkpoint_ack,
};

pub const Limits = struct {
    maximum_file_name_bytes: usize = 255,
    maximum_header_bytes: usize = 16 * 1024 * 1024,
    maximum_row_bytes: usize = 16 * 1024 * 1024,
    /// How many derived output files keep an open read-write handle. Every
    /// `openFile` of a file that was modified since its previous close pays a
    /// filesystem-filter rescan; on Windows that was measured at 46.7 ms per
    /// reopen against 0.002 ms for an append through a retained handle, which
    /// made reopening once per simulated hour per file the largest single cost
    /// of publishing an accepted hour. Retaining handles removes that cost
    /// without changing what is written or when it is synchronized. Exceeding
    /// the limit evicts and reopens, degrading to the previous cost rather
    /// than failing.
    maximum_open_output_files: usize = 256,
};

/// How `checkpointWillPublish` verifies the accepted output prefixes. See
/// `Coordinator.validateAllStatePrefixes` for the measurement behind the
/// default and for exactly what the cheap mode gives up.
pub const CheckpointVerification = enum {
    /// Confirm each accepted prefix from the digest `applyEntry` maintains as
    /// it writes, plus the file length. A fixed number of syscalls per file.
    trust_incremental_digest,
    /// Re-read and re-hash every accepted byte of every output file at every
    /// checkpoint. Costs O(accepted bytes) per checkpoint, so O(hours squared)
    /// over a run. Opt in only for a deliberate verification pass.
    rehash_accepted_prefixes,
};

const PrefixCheck = struct {
    /// Reject a file longer than its accepted cursor.
    exact_length: bool = false,
    /// Recompute each digest from the bytes on disk and re-seed the running
    /// hasher, instead of trusting the incrementally maintained one.
    rehash_from_disk: bool,
};

const FileCursor = struct {
    header_length: u32,
    header_checksum: u64,
    byte_length: u64,
    checksum: u64,
    row_count: u64,
};

const TrackedFile = struct {
    cursor: FileCursor,
    hasher: std.hash.Wyhash,
};

const Cursor = struct {
    latest_generation: u64 = 0,
    latest_instant: Instant = zero_instant,
    latest_journal_checksum: u64 = 0,
    latest_entry_count: u64 = 0,
    acknowledged_generation: u64 = 0,
    acknowledged_instant: Instant = zero_instant,
    checkpoint_generation: u64 = 0,
    bank_checksum: u64 = 0,
    bank_entry_count: u64 = 0,
    pruned_through_generation: u64 = 0,
    obsolete_bank_generation: u64 = 0,
};

const zero_instant: Instant = .{ .year = 0, .day_of_year = 0, .hour = 0 };

const Entry = struct {
    category: Category,
    file_name: []u8,
    header: []u8,
    row: []u8,
    base: FileCursor,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.row);
        allocator.free(self.header);
        allocator.free(self.file_name);
        self.* = undefined;
    }
};

fn deinitEntries(entries: *std.ArrayListUnmanaged(Entry), allocator: std.mem.Allocator) void {
    for (entries.items) |*entry| entry.deinit(allocator);
    entries.deinit(allocator);
    entries.* = .empty;
}

const JournalSummary = struct {
    generation: u64,
    instant: Instant,
    checksum: u64,
    entry_count: u64,
};

const NewJournal = struct {
    atomic_file: std.Io.File.Atomic,
    dest_name: []u8,
    writer: std.Io.File.Writer,
    buffer: []u8,
    hasher: std.hash.Wyhash,
    generation: u64,
    instant: Instant,
    entry_count: u64 = 0,
    identities: std.AutoHashMapUnmanaged(u64, void) = .empty,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    fn deinit(self: *NewJournal, allocator: std.mem.Allocator, io: std.Io) void {
        deinitEntries(&self.entries, allocator);
        self.identities.deinit(allocator);
        self.atomic_file.deinit(io);
        allocator.free(self.dest_name);
        allocator.free(self.buffer);
        self.* = undefined;
    }
};

const ReplayJournal = struct {
    parser: HashedFileReader,
    generation: u64,
    instant: Instant,

    fn deinit(self: *ReplayJournal) void {
        self.parser.deinit();
        self.* = undefined;
    }
};

const Active = union(enum) { new: NewJournal, replay: ReplayJournal };

/// Crash-consistent owner for modelled output. Files are updated only from an
/// immutable, synchronized hour journal. Derived text files and the compact
/// cursor are synchronized at checkpoint boundaries; before then sequential
/// journals are the durable source used to recover the latest generation and
/// repair unacknowledged suffixes. A checkpoint-compacted bank retains the
/// exact accepted prefix cursor for every file.
pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    dirs: CategoryDirs,
    run_identity: u64,
    buffer_bytes: usize,
    limits: Limits,
    cursor: Cursor = .{},
    states: [category_count]std.StringHashMapUnmanaged(TrackedFile) =
        [_]std.StringHashMapUnmanaged(TrackedFile){.empty} ** category_count,
    /// Retained read-write handles for the derived output files, keyed exactly
    /// like `states`. Purely a cost cache: it changes no byte, offset, order,
    /// or synchronization point. See `Limits.maximum_open_output_files`.
    open_output_files: [category_count]std.StringHashMapUnmanaged(std.Io.File) =
        [_]std.StringHashMapUnmanaged(std.Io.File){.empty} ** category_count,
    active: ?Active = null,
    /// Assignable after `init` so restoring the exhaustive per-checkpoint
    /// re-read never requires changing the constructor signature.
    checkpoint_verification: CheckpointVerification = .trust_incremental_digest,
    reconciled: bool = false,
    failure_point: FailurePoint = .none,
    failure_fired: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        root: std.Io.Dir,
        dirs: CategoryDirs,
        run_identity: u64,
        buffer_bytes: usize,
        limits: Limits,
    ) !Coordinator {
        if (run_identity == 0) return error.InvalidOutputRunIdentity;
        if (buffer_bytes == 0) return error.InvalidOutputTransactionBufferSize;
        if (limits.maximum_file_name_bytes == 0 or limits.maximum_header_bytes == 0 or
            limits.maximum_row_bytes == 0 or limits.maximum_open_output_files == 0)
            return error.InvalidOutputTransactionLimits;
        return .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .dirs = dirs,
            .run_identity = run_identity,
            .buffer_bytes = buffer_bytes,
            .limits = limits,
        };
    }

    pub fn deinit(self: *Coordinator) void {
        self.abortActive();
        for (&self.open_output_files) |*cache| {
            var iterator = cache.iterator();
            while (iterator.next()) |entry_ptr| {
                entry_ptr.value_ptr.*.close(self.io);
                self.allocator.free(entry_ptr.key_ptr.*);
            }
            cache.deinit(self.allocator);
        }
        for (&self.states) |*map| {
            var iterator = map.keyIterator();
            while (iterator.next()) |name| self.allocator.free(name.*);
            map.deinit(self.allocator);
        }
        self.* = undefined;
    }

    /// Returns the retained read-write handle for one derived output file,
    /// opening or creating it on first use. The handle stays open for the run
    /// so an accepted hour never pays the reopen rescan described on
    /// `Limits.maximum_open_output_files`. Nothing about the written bytes or
    /// their durability changes: rows are still positional writes and are
    /// still synchronized only by `syncAllStateFiles` at a checkpoint.
    ///
    /// The handle itself carries no lock. Exclusion is still exactly as wide
    /// as it was when every mutation opened its own locked handle, because
    /// each read-modify-write, truncation, and synchronization takes the same
    /// whole-file exclusive lock for its own duration and releases it. A
    /// retained lock would instead make the file unreadable by anything else
    /// for the whole run.
    fn openOutputFile(self: *Coordinator, category: Category, file_name: []const u8) !std.Io.File {
        const cache = &self.open_output_files[@intFromEnum(category)];
        if (cache.get(file_name)) |file| return file;
        if (cache.count() >= self.limits.maximum_open_output_files)
            self.evictOpenOutputFile(category);
        const directory = self.dirs.get(category);
        const file = directory.openFile(self.io, file_name, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try directory.createFile(self.io, file_name, .{ .read = true, .truncate = false, .exclusive = true }),
            else => return err,
        };
        errdefer file.close(self.io);
        const owned_name = try self.allocator.dupe(u8, file_name);
        errdefer self.allocator.free(owned_name);
        try cache.put(self.allocator, owned_name, file);
        return file;
    }

    /// Closes one retained handle so a new one can be opened. Only the number
    /// of live handles is bounded; correctness never depends on which handle
    /// is resident, because every use reopens on demand.
    fn evictOpenOutputFile(self: *Coordinator, category: Category) void {
        const cache = &self.open_output_files[@intFromEnum(category)];
        var iterator = cache.iterator();
        const victim = iterator.next() orelse return;
        const owned_name = victim.key_ptr.*;
        victim.value_ptr.*.close(self.io);
        _ = cache.remove(owned_name);
        self.allocator.free(owned_name);
    }

    /// Loads the durable cursor, validates the accepted checkpoint boundary,
    /// rebuilds the live file bank, and repairs only journal-proven suffixes.
    pub fn reconcile(self: *Coordinator, resume_point: ResumePoint) !void {
        if (self.reconciled or self.active != null) return error.OutputCoordinatorAlreadyReconciled;
        self.cursor = (try readCursor(self.allocator, self.io, self.root, self.run_identity)) orelse .{};

        const accepted: ?AcceptedCheckpoint = switch (resume_point) {
            .fresh => null,
            .initial_state => .{ .checkpoint_generation = 0, .output_generation = 0, .instant = zero_instant },
            .checkpoint => |checkpoint| checkpoint,
        };
        if (self.cursor.acknowledged_generation != 0) {
            try self.loadBank();
            // Resume: the bank carries cursors but no hasher state, so this
            // pass has to read the accepted bytes to rebuild it.
            try self.validateAllStatePrefixes(.{ .rehash_from_disk = true });
            try self.truncateAllStateFilesToCursor();
        } else if (self.cursor.bank_entry_count != 0 or self.cursor.bank_checksum != 0) {
            return error.UnexpectedOutputBank;
        }

        const cursor_generation_on_disk = self.cursor.latest_generation;
        var generation = self.cursor.acknowledged_generation + 1;
        while (generation <= cursor_generation_on_disk) : (generation += 1) {
            const summary = try self.materializeJournal(generation, true, true);
            if (generation == cursor_generation_on_disk and
                (summary.checksum != self.cursor.latest_journal_checksum or
                    summary.entry_count != self.cursor.latest_entry_count or
                    !sameInstant(summary.instant, self.cursor.latest_instant)))
                return error.OutputCursorJournalMismatch;
        }
        // The cursor is checkpoint durability metadata, not an hourly fsync.
        // Recover every complete sequential journal linked after its last
        // publication. Atomic journal linking makes FileNotFound the only
        // normal terminator; malformed or externally altered tails fail closed.
        generation = cursor_generation_on_disk + 1;
        while (true) : (generation += 1) {
            const summary = self.materializeJournal(generation, true, true) catch |err| switch (err) {
                error.FileNotFound => break,
                else => return err,
            };
            self.cursor.latest_generation = generation;
            self.cursor.latest_instant = summary.instant;
            self.cursor.latest_journal_checksum = summary.checksum;
            self.cursor.latest_entry_count = summary.entry_count;
        }
        if (resume_point == .fresh and self.cursor.latest_generation != 0)
            return error.ExistingOutputRequiresResume;
        if (accepted) |checkpoint| {
            if (checkpoint.output_generation > self.cursor.latest_generation)
                return error.CheckpointAheadOfOutputCursor;
            if (checkpoint.output_generation != 0 and checkpoint.checkpoint_generation == 0)
                return error.InvalidAcceptedCheckpoint;
            if (checkpoint.output_generation != self.cursor.acknowledged_generation and
                checkpoint.output_generation != self.cursor.latest_generation)
                return error.CheckpointOutputBoundaryMismatch;
            if (checkpoint.output_generation < self.cursor.acknowledged_generation)
                return error.CheckpointOlderThanAcceptedOutput;
            if (checkpoint.output_generation == self.cursor.acknowledged_generation and
                checkpoint.output_generation != 0 and
                !sameInstant(checkpoint.instant, self.cursor.acknowledged_instant))
                return error.CheckpointOutputInstantMismatch;
            if (checkpoint.output_generation == self.cursor.latest_generation and
                checkpoint.output_generation != 0 and
                !sameInstant(checkpoint.instant, self.cursor.latest_instant))
                return error.CheckpointOutputInstantMismatch;
        }
        // Once per process, not once per checkpoint: this is the pass that
        // decides whether a previous process's output may be trusted, so it
        // reads every accepted byte.
        try self.validateAllStatePrefixes(.{ .rehash_from_disk = true });
        self.reconciled = true;

        if (accepted) |checkpoint| if (checkpoint.output_generation == self.cursor.latest_generation and
            checkpoint.output_generation > self.cursor.acknowledged_generation)
        {
            try self.acknowledgeDurableCheckpoint(checkpoint);
        };
        if (accepted != null and self.cursor.pruned_through_generation < self.cursor.acknowledged_generation)
            try self.pruneAcknowledgedJournals();
    }

    pub fn beginHour(self: *Coordinator, generation: u64, instant: Instant) !void {
        if (!self.reconciled) return error.OutputCoordinatorNotReconciled;
        if (self.active != null) return error.OutputHourAlreadyActive;
        if (generation == 0) return error.InvalidOutputGeneration;
        try validateInstant(instant);
        if (generation <= self.cursor.acknowledged_generation)
            return error.OutputGenerationAlreadyCheckpointed;
        if (generation > self.cursor.latest_generation + 1)
            return error.OutputGenerationGap;

        var name_buffer: [80]u8 = undefined;
        const name = try journalFileName(&name_buffer, generation);
        const existing = self.root.openFile(self.io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |file| {
            var parser = try HashedFileReader.init(self.allocator, self.io, file, self.limits);
            errdefer parser.deinit();
            const header = try readJournalHeader(&parser, self.run_identity);
            if (header.generation != generation or !sameInstant(header.instant, instant))
                return error.OutputJournalIdentityMismatch;
            self.active = .{ .replay = .{ .parser = parser, .generation = generation, .instant = instant } };
            return;
        }
        if (generation <= self.cursor.latest_generation)
            return error.MissingCommittedOutputJournal;

        const buffer = try self.allocator.alloc(u8, self.buffer_bytes);
        errdefer self.allocator.free(buffer);
        const dest_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(dest_name);
        var atomic_file = try self.root.createFileAtomic(self.io, dest_name, .{ .replace = false });
        errdefer atomic_file.deinit(self.io);
        var journal: NewJournal = .{
            .atomic_file = atomic_file,
            .dest_name = dest_name,
            .writer = atomic_file.file.writerStreaming(self.io, buffer),
            .buffer = buffer,
            .hasher = std.hash.Wyhash.init(checksum_seed),
            .generation = generation,
            .instant = instant,
        };
        try writeJournalHeader(&journal, self.run_identity);
        self.active = .{ .new = journal };
    }

    /// Records one already-rendered schema heading and row. No modelled output
    /// file is touched here.
    pub fn record(
        self: *Coordinator,
        category: Category,
        file_name: []const u8,
        header: []const u8,
        row: []const u8,
    ) !void {
        if (!safeFileName(file_name) or file_name.len > self.limits.maximum_file_name_bytes)
            return error.InvalidOutputFileName;
        if (!singleLine(header) or header.len > self.limits.maximum_header_bytes)
            return error.InvalidOutputHeader;
        if (!singleLine(row) or row.len > self.limits.maximum_row_bytes)
            return error.InvalidOutputRow;
        const active = &(self.active orelse return error.NoActiveOutputHour);
        switch (active.*) {
            .replay => |*replay| {
                var expected = (try readJournalEntry(&replay.parser, self.allocator)) orelse
                    return error.OutputReplayHasExtraRecord;
                defer expected.deinit(self.allocator);
                if (expected.category != category or
                    !std.mem.eql(u8, expected.file_name, file_name) or
                    !std.mem.eql(u8, expected.header, header) or
                    !std.mem.eql(u8, expected.row, row))
                {
                    const header_difference = firstDifference(expected.header, header);
                    const row_difference = firstDifference(expected.row, row);
                    std.log.err(
                        "output replay record mismatch: generation={} year={} day={} hour={} expected_category={s} actual_category={s} expected_file='{s}' actual_file='{s}' expected_header_bytes={} actual_header_bytes={} expected_header_checksum=0x{x} actual_header_checksum=0x{x} expected_row_bytes={} actual_row_bytes={} expected_row_checksum=0x{x} actual_row_checksum=0x{x} header_first_difference={?} row_first_difference={?}",
                        .{
                            replay.generation,
                            replay.instant.year,
                            replay.instant.day_of_year,
                            replay.instant.hour,
                            @tagName(expected.category),
                            @tagName(category),
                            expected.file_name,
                            file_name,
                            expected.header.len,
                            header.len,
                            checksum(expected.header),
                            checksum(header),
                            expected.row.len,
                            row.len,
                            checksum(expected.row),
                            checksum(row),
                            header_difference,
                            row_difference,
                        },
                    );
                    if (row_difference) |difference| {
                        const expected_window = differenceWindow(expected.row, difference);
                        const actual_window = differenceWindow(row, difference);
                        std.log.err(
                            "output replay row mismatch context: field_index={} expected_window='{s}' actual_window='{s}'",
                            .{
                                delimitedFieldIndex(expected.row, difference),
                                expected_window,
                                actual_window,
                            },
                        );
                    }
                    return error.OutputReplayRecordMismatch;
                }
            },
            .new => |*journal| {
                const identity = fileIdentity(category, file_name);
                if ((try journal.identities.getOrPut(self.allocator, identity)).found_existing)
                    return error.DuplicateOutputFileInHour;
                const base = try self.preflightBase(category, file_name, header);
                try journal.entries.ensureUnusedCapacity(self.allocator, 1);
                var entry: Entry = .{
                    .category = category,
                    .file_name = try self.allocator.dupe(u8, file_name),
                    .header = undefined,
                    .row = undefined,
                    .base = base,
                };
                errdefer self.allocator.free(entry.file_name);
                entry.header = try self.allocator.dupe(u8, header);
                errdefer self.allocator.free(entry.header);
                entry.row = try self.allocator.dupe(u8, row);
                errdefer self.allocator.free(entry.row);
                try writeJournalEntry(journal, category, file_name, header, row, base);
                journal.entries.appendAssumeCapacity(entry);
                journal.entry_count += 1;
            },
        }
    }

    /// Synchronizes and atomically publishes the immutable hour journal,
    /// materializes its derived text rows idempotently, then advances the
    /// in-memory cursor. The journal remains the durable source until the next
    /// checkpoint synchronizes derived files and publishes the compact cursor.
    pub fn commitHour(self: *Coordinator) !void {
        const active_ptr = &(self.active orelse return error.NoActiveOutputHour);
        var published_entries: std.ArrayListUnmanaged(Entry) = .empty;
        defer deinitEntries(&published_entries, self.allocator);
        var newly_published = false;
        const generation = switch (active_ptr.*) {
            .new => |journal| journal.generation,
            .replay => |replay| replay.generation,
        };
        var summary: JournalSummary = undefined;
        switch (active_ptr.*) {
            .new => |*journal| {
                try self.inject(.before_journal_publish);
                const digest = journal.hasher.final();
                try writeRawByte(&journal.writer.interface, trailer_tag);
                try writeRawInt(&journal.writer.interface, u64, journal.entry_count);
                try writeRawInt(&journal.writer.interface, u64, digest);
                try journal.writer.interface.flush();
                try journal.atomic_file.file.sync(self.io);
                try journal.atomic_file.link(self.io);
                summary = .{ .generation = generation, .instant = journal.instant, .checksum = digest, .entry_count = journal.entry_count };
                published_entries = journal.entries;
                journal.entries = .empty;
                newly_published = true;
                self.clearActive();
                try self.inject(.after_journal_publish);
            },
            .replay => |*replay| {
                if (try readJournalEntry(&replay.parser, self.allocator)) |unexpected| {
                    var owned = unexpected;
                    owned.deinit(self.allocator);
                    return error.OutputReplayMissingRecord;
                }
                summary = try finishJournal(&replay.parser, generation, replay.instant);
                self.clearActive();
            },
        }

        const replaying_committed = generation <= self.cursor.latest_generation;
        if (newly_published) {
            for (published_entries.items) |entry|
                try self.applyEntry(generation, !replaying_committed, replaying_committed, entry);
        } else {
            const materialized = try self.materializeJournal(
                generation,
                !replaying_committed,
                replaying_committed,
            );
            if (materialized.checksum != summary.checksum or materialized.entry_count != summary.entry_count or
                !sameInstant(materialized.instant, summary.instant))
                return error.OutputJournalChangedAfterPublish;
        }
        try self.inject(.after_materialization_before_cursor);
        if (generation > self.cursor.latest_generation) {
            self.cursor.latest_generation = generation;
            self.cursor.latest_instant = summary.instant;
            self.cursor.latest_journal_checksum = summary.checksum;
            self.cursor.latest_entry_count = summary.entry_count;
            try self.inject(.during_cursor_publish);
            try self.inject(.after_cursor_publish);
        }
    }

    /// Call immediately before checkpoint section publication.
    pub fn checkpointWillPublish(self: *Coordinator) !void {
        try self.inject(.before_checkpoint_publish);
        try self.validateAllStatePrefixes(.{
            .exact_length = true,
            .rehash_from_disk = self.checkpoint_verification == .rehash_accepted_prefixes,
        });
        try self.syncAllStateFiles();
        try publishCursor(self.allocator, self.io, self.root, self.run_identity, self.cursor, self.buffer_bytes);
        try self.inject(.during_checkpoint_publish);
    }

    /// Call only after the checkpoint manifest is durably published. The bank
    /// is published before the acknowledgement cursor; journals are pruned
    /// only after that cursor is durable.
    pub fn checkpointDidPublish(self: *Coordinator, accepted: AcceptedCheckpoint) !void {
        try self.inject(.after_checkpoint_publish);
        try self.acknowledgeDurableCheckpoint(accepted);
        try self.inject(.after_checkpoint_ack);
        try self.pruneAcknowledgedJournals();
    }

    pub fn setFailurePointForTesting(self: *Coordinator, point: FailurePoint) void {
        self.failure_point = point;
        self.failure_fired = false;
    }

    fn inject(self: *Coordinator, point: FailurePoint) !void {
        if (!self.failure_fired and self.failure_point == point) {
            self.failure_fired = true;
            return error.InjectedOutputFailure;
        }
    }

    fn preflightBase(self: *Coordinator, category: Category, file_name: []const u8, header: []const u8) !FileCursor {
        const map = &self.states[@intFromEnum(category)];
        const schema_checksum = checksum(header);
        if (map.get(file_name)) |tracked| {
            const expected = tracked.cursor;
            if (expected.header_length != header.len or expected.header_checksum != schema_checksum)
                return error.OutputSchemaMismatch;
            return expected;
        }
        // A retained handle already proves the file exists. A journal
        // materialized without advancing state opens a file without tracking
        // it, so consult the handles too rather than reporting a file this
        // coordinator itself created as absent.
        if (self.open_output_files[@intFromEnum(category)].contains(file_name))
            return error.UntrackedExistingOutputFile;
        const file = self.dirs.get(category).openFile(self.io, file_name, .{}) catch |err| switch (err) {
            error.FileNotFound => return .{
                .header_length = @intCast(header.len),
                .header_checksum = schema_checksum,
                .byte_length = 0,
                .checksum = checksum(""),
                .row_count = 0,
            },
            else => return err,
        };
        file.close(self.io);
        return error.UntrackedExistingOutputFile;
    }

    fn materializeJournal(
        self: *Coordinator,
        generation: u64,
        advance_state: bool,
        allow_later_suffix: bool,
    ) !JournalSummary {
        var name_buffer: [80]u8 = undefined;
        const name = try journalFileName(&name_buffer, generation);
        const file = try self.root.openFile(self.io, name, .{});
        var parser = try HashedFileReader.init(self.allocator, self.io, file, self.limits);
        defer parser.deinit();
        const header = try readJournalHeader(&parser, self.run_identity);
        if (header.generation != generation) return error.OutputJournalIdentityMismatch;
        while (try readJournalEntry(&parser, self.allocator)) |entry_value| {
            var entry = entry_value;
            defer entry.deinit(self.allocator);
            try self.applyEntry(generation, advance_state, allow_later_suffix, entry);
        }
        return finishJournal(&parser, generation, header.instant);
    }

    fn applyEntry(self: *Coordinator, generation: u64, advance_state: bool, allow_later_suffix: bool, entry: Entry) !void {
        if (advance_state) try self.validateLogicalBase(entry);
        const file = try self.openOutputFile(entry.category, entry.file_name);
        try file.lock(self.io, .exclusive);
        defer file.unlock(self.io);
        const existing = if (advance_state)
            self.states[@intFromEnum(entry.category)].get(entry.file_name)
        else
            null;
        var current_length = try file.length(self.io);
        if (advance_state and allow_later_suffix and existing == null and
            entry.base.byte_length == 0 and current_length != 0)
        {
            try file.setLength(self.io, 0);
            current_length = 0;
        }
        if (current_length < entry.base.byte_length) return error.AcceptedOutputPrefixTruncated;
        const intended_length = std.math.add(usize, if (entry.base.byte_length == 0) entry.header.len else 0, entry.row.len) catch return error.OutputRecordSizeOverflow;
        const intended = try self.allocator.alloc(u8, intended_length);
        defer self.allocator.free(intended);
        var copied: usize = 0;
        if (entry.base.byte_length == 0) {
            @memcpy(intended[0..entry.header.len], entry.header);
            copied = entry.header.len;
        }
        @memcpy(intended[copied..], entry.row);
        const expected_end = std.math.add(u64, entry.base.byte_length, intended.len) catch return error.OutputFileSizeOverflow;
        const suffix_length = current_length - entry.base.byte_length;
        const comparable: usize = @intCast(@min(suffix_length, intended.len));
        if (!try bytesEqualAt(self.io, file, entry.base.byte_length, intended[0..comparable]))
            return error.UncommittedOutputSuffixMismatch;
        if (current_length > expected_end and !allow_later_suffix and generation > self.cursor.latest_generation)
            return error.UnexpectedOutputSuffix;

        if (current_length < expected_end) {
            // Only bytes after the journal-proven accepted cursor are removed.
            // A plain append already sits exactly at the cursor, so the common
            // case skips the truncation rather than issuing a no-op resize.
            if (current_length != entry.base.byte_length)
                try file.setLength(self.io, entry.base.byte_length);
            if (!self.failure_fired and self.failure_point == .during_materialization) {
                self.failure_fired = true;
                const partial_length = @max(@as(usize, 1), intended.len / 2);
                try file.writePositionalAll(self.io, intended[0..partial_length], entry.base.byte_length);
                try file.sync(self.io);
                return error.InjectedOutputFailure;
            }
            try file.writePositionalAll(self.io, intended, entry.base.byte_length);
        }

        if (advance_state) {
            var hasher = if (existing) |tracked|
                tracked.hasher
            else
                std.hash.Wyhash.init(checksum_seed);
            if (entry.base.byte_length == 0) hasher.update(entry.header);
            hasher.update(entry.row);
            try self.putState(entry.category, entry.file_name, .{
                .cursor = .{
                    .header_length = @intCast(entry.header.len),
                    .header_checksum = checksum(entry.header),
                    .byte_length = expected_end,
                    .checksum = hasher.final(),
                    .row_count = try std.math.add(u64, entry.base.row_count, 1),
                },
                .hasher = hasher,
            });
        }
    }

    fn validateLogicalBase(self: *Coordinator, entry: Entry) !void {
        const existing = self.states[@intFromEnum(entry.category)].get(entry.file_name);
        if (existing) |tracked| {
            if (!sameCursor(tracked.cursor, entry.base)) return error.OutputJournalBaseCursorMismatch;
        } else if (entry.base.byte_length != 0 or entry.base.row_count != 0 or
            entry.base.checksum != checksum(""))
            return error.OutputJournalBaseCursorMismatch;
        if (entry.base.header_length != entry.header.len or
            entry.base.header_checksum != checksum(entry.header))
            return error.OutputJournalSchemaMismatch;
    }

    fn putState(self: *Coordinator, category: Category, file_name: []const u8, tracked_file: TrackedFile) !void {
        const map = &self.states[@intFromEnum(category)];
        if (map.getPtr(file_name)) |existing| {
            existing.* = tracked_file;
            return;
        }
        const owned_name = try self.allocator.dupe(u8, file_name);
        errdefer self.allocator.free(owned_name);
        try map.put(self.allocator, owned_name, tracked_file);
    }

    fn loadBank(self: *Coordinator) !void {
        var name_buffer: [80]u8 = undefined;
        const name = try bankFileName(&name_buffer, self.cursor.acknowledged_generation);
        const file = try self.root.openFile(self.io, name, .{});
        var parser = try HashedFileReader.init(self.allocator, self.io, file, self.limits);
        defer parser.deinit();
        try parser.expectHashed(bank_magic);
        if (try parser.readHashedInt(u32) != format_version) return error.UnsupportedOutputBankVersion;
        if (try parser.readHashedInt(u64) != self.run_identity) return error.OutputRunIdentityMismatch;
        const generation = try parser.readHashedInt(u64);
        const instant = try readHashedInstant(&parser);
        if (generation != self.cursor.acknowledged_generation or
            !sameInstant(instant, self.cursor.acknowledged_instant))
            return error.OutputBankCursorMismatch;
        const count = try parser.readHashedInt(u64);
        if (count != self.cursor.bank_entry_count) return error.OutputBankCursorMismatch;
        var index: u64 = 0;
        while (index < count) : (index += 1) {
            const category = std.enums.fromInt(Category, try parser.readHashedByte()) orelse return error.InvalidOutputCategory;
            const name_length = try parser.readHashedInt(u32);
            if (name_length == 0 or name_length > self.limits.maximum_file_name_bytes) return error.InvalidOutputFileName;
            const entry_name = try self.allocator.alloc(u8, name_length);
            errdefer self.allocator.free(entry_name);
            try parser.readHashed(entry_name);
            if (!safeFileName(entry_name)) return error.InvalidOutputFileName;
            const value = try readHashedFileCursor(&parser);
            const map = &self.states[@intFromEnum(category)];
            const bank_entry = try map.getOrPut(self.allocator, entry_name);
            if (bank_entry.found_existing) {
                self.allocator.free(entry_name);
                return error.DuplicateOutputBankEntry;
            }
            bank_entry.value_ptr.* = .{
                .cursor = value,
                .hasher = std.hash.Wyhash.init(checksum_seed),
            };
        }
        if (try parser.readRawByte() != trailer_tag) return error.InvalidOutputBankTrailer;
        const digest = try parser.readRawInt(u64);
        if (digest != parser.hasher.final() or digest != self.cursor.bank_checksum or parser.offset != parser.size)
            return error.OutputBankChecksumMismatch;
    }

    fn publishBank(self: *Coordinator, accepted: AcceptedCheckpoint) !struct { checksum: u64, count: u64 } {
        const buffer = try self.allocator.alloc(u8, self.buffer_bytes);
        defer self.allocator.free(buffer);
        var name_buffer: [80]u8 = undefined;
        const name = try bankFileName(&name_buffer, accepted.output_generation);
        var atomic_file = try self.root.createFileAtomic(self.io, name, .{ .replace = true });
        defer atomic_file.deinit(self.io);
        var writer = atomic_file.file.writerStreaming(self.io, buffer);
        var hasher = std.hash.Wyhash.init(checksum_seed);
        try writeHashed(&writer.interface, &hasher, bank_magic);
        try writeHashedInt(&writer.interface, &hasher, u32, format_version);
        try writeHashedInt(&writer.interface, &hasher, u64, self.run_identity);
        try writeHashedInt(&writer.interface, &hasher, u64, accepted.output_generation);
        try writeHashedInstant(&writer.interface, &hasher, accepted.instant);
        var count: u64 = 0;
        for (&self.states) |*map| count += map.count();
        try writeHashedInt(&writer.interface, &hasher, u64, count);
        for (&self.states, 0..) |*map, raw_category| {
            var iterator = map.iterator();
            while (iterator.next()) |entry_ptr| {
                try writeHashedByte(&writer.interface, &hasher, @intCast(raw_category));
                try writeHashedInt(&writer.interface, &hasher, u32, @intCast(entry_ptr.key_ptr.*.len));
                try writeHashed(&writer.interface, &hasher, entry_ptr.key_ptr.*);
                try writeHashedFileCursor(&writer.interface, &hasher, entry_ptr.value_ptr.cursor);
            }
        }
        const digest = hasher.final();
        try writeRawByte(&writer.interface, trailer_tag);
        try writeRawInt(&writer.interface, u64, digest);
        try writer.interface.flush();
        try atomic_file.file.sync(self.io);
        try atomic_file.replace(self.io);
        return .{ .checksum = digest, .count = count };
    }

    fn acknowledgeDurableCheckpoint(self: *Coordinator, accepted: AcceptedCheckpoint) !void {
        if (accepted.output_generation != self.cursor.latest_generation or
            !sameInstant(accepted.instant, self.cursor.latest_instant) or
            accepted.checkpoint_generation == 0)
            return error.CheckpointOutputBoundaryMismatch;
        if (accepted.output_generation <= self.cursor.acknowledged_generation)
            return error.CheckpointOutputAlreadyAcknowledged;
        const bank = try self.publishBank(accepted);
        try self.inject(.after_bank_publish_before_checkpoint_ack);
        const previous_bank_generation = self.cursor.acknowledged_generation;
        self.cursor.acknowledged_generation = accepted.output_generation;
        self.cursor.acknowledged_instant = accepted.instant;
        self.cursor.checkpoint_generation = accepted.checkpoint_generation;
        self.cursor.bank_checksum = bank.checksum;
        self.cursor.bank_entry_count = bank.count;
        self.cursor.obsolete_bank_generation = previous_bank_generation;
        try publishCursor(self.allocator, self.io, self.root, self.run_identity, self.cursor, self.buffer_bytes);
    }

    fn pruneAcknowledgedJournals(self: *Coordinator) !void {
        var generation = self.cursor.pruned_through_generation + 1;
        while (generation <= self.cursor.acknowledged_generation) : (generation += 1) {
            var name_buffer: [80]u8 = undefined;
            const name = try journalFileName(&name_buffer, generation);
            self.root.deleteFile(self.io, name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        self.cursor.pruned_through_generation = self.cursor.acknowledged_generation;
        if (self.cursor.obsolete_bank_generation != 0) {
            var bank_name_buffer: [80]u8 = undefined;
            const bank_name = try bankFileName(&bank_name_buffer, self.cursor.obsolete_bank_generation);
            self.root.deleteFile(self.io, bank_name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            self.cursor.obsolete_bank_generation = 0;
        }
        try publishCursor(self.allocator, self.io, self.root, self.run_identity, self.cursor, self.buffer_bytes);
    }

    // The three whole-bank passes below borrow `states` while calling
    // `openOutputFile`, which only ever mutates `open_output_files`, so no
    // iterator over `states` is invalidated.

    /// Confirms every tracked output file still matches its accepted cursor.
    ///
    /// `rehash_from_disk` re-reads and re-hashes each accepted prefix. That is
    /// load-bearing in exactly one place: a resumed run. `loadBank` restores
    /// each cursor from the bank but not the Wyhash internal state behind it,
    /// so the running hasher has to be rebuilt from the bytes on disk before
    /// any further row can extend it.
    ///
    /// It is deliberately NOT done at every checkpoint any more.
    /// `applyEntry` already maintains `TrackedFile.hasher` as an exact running
    /// hash of the accepted prefix -- `Wyhash.final` copies rather than
    /// consumes -- and no in-process path mutates an accepted prefix without
    /// going through `applyEntry`, so a per-checkpoint re-read only recomputes
    /// a digest this coordinator already holds. That cost was O(accepted
    /// bytes) per checkpoint and therefore O(hours squared) over a run:
    /// measured on the reference deck shape at 22.3 ms plus 2.49 ms per
    /// accepted megabyte per checkpoint, which projects to 221 GB re-read and
    /// roughly 551 s for one six-year run -- by itself more than the whole
    /// runtime target, and growing with the square of run length.
    ///
    /// The trade is explicit and narrow: an external process that rewrites an
    /// accepted output byte mid-run is no longer noticed at the next
    /// checkpoint. It is still noticed everywhere it decides anything, namely
    /// on resume, where this function does rehash and where the accepted
    /// prefix actually gets trusted, and by `preflightBase` failing closed on
    /// an untracked existing file. Set `checkpoint_verification` to
    /// `.rehash_accepted_prefixes` for a deliberate verification pass. Do not
    /// make that the default again without redoing the measurement above.
    ///
    /// The length checks below are not part of that trade: they run in both
    /// modes, so a truncated or over-long accepted prefix still fails closed
    /// at every checkpoint.
    fn validateAllStatePrefixes(self: *Coordinator, check: PrefixCheck) !void {
        for (&self.states, 0..) |*map, raw_category| {
            var iterator = map.iterator();
            while (iterator.next()) |entry_ptr| {
                const expected = entry_ptr.value_ptr.cursor;
                const file = try self.openOutputFile(@enumFromInt(raw_category), entry_ptr.key_ptr.*);
                const file_length = try file.length(self.io);
                if (file_length < expected.byte_length) return error.AcceptedOutputPrefixTruncated;
                if (check.exact_length and file_length != expected.byte_length)
                    return error.AcceptedOutputPrefixMismatch;
                if (!check.rehash_from_disk) continue;
                const actual = try inspectOpenPrefix(self.allocator, self.io, file, file_length, expected.byte_length, expected.header_length);
                if (!sameCursor(actual.cursor, expected)) return error.AcceptedOutputPrefixMismatch;
                entry_ptr.value_ptr.hasher = actual.hasher;
            }
        }
    }

    fn truncateAllStateFilesToCursor(self: *Coordinator) !void {
        for (&self.states, 0..) |*map, raw_category| {
            var iterator = map.iterator();
            while (iterator.next()) |entry_ptr| {
                const file = try self.openOutputFile(@enumFromInt(raw_category), entry_ptr.key_ptr.*);
                try file.lock(self.io, .exclusive);
                defer file.unlock(self.io);
                try file.setLength(self.io, entry_ptr.value_ptr.cursor.byte_length);
            }
        }
    }

    fn syncAllStateFiles(self: *Coordinator) !void {
        for (&self.states, 0..) |*map, raw_category| {
            var iterator = map.iterator();
            while (iterator.next()) |entry_ptr| {
                const file = try self.openOutputFile(@enumFromInt(raw_category), entry_ptr.key_ptr.*);
                try file.lock(self.io, .exclusive);
                defer file.unlock(self.io);
                try file.sync(self.io);
            }
        }
    }

    fn abortActive(self: *Coordinator) void {
        if (self.active) |*active| switch (active.*) {
            .new => |*journal| journal.deinit(self.allocator, self.io),
            .replay => |*replay| replay.deinit(),
        };
        self.active = null;
    }

    fn clearActive(self: *Coordinator) void {
        self.abortActive();
    }
};

const OpenPrefixInspection = struct {
    cursor: FileCursor,
    hasher: std.hash.Wyhash,
};

fn inspectOpenPrefix(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, file_length: u64, prefix_length: u64, header_length: u32) !OpenPrefixInspection {
    if (file_length < prefix_length) return error.AcceptedOutputPrefixTruncated;
    if (prefix_length == 0) {
        var hasher = std.hash.Wyhash.init(checksum_seed);
        return .{
            .cursor = .{
                .header_length = header_length,
                .header_checksum = 0,
                .byte_length = 0,
                .checksum = hasher.final(),
                .row_count = 0,
            },
            .hasher = hasher,
        };
    }
    if (header_length == 0 or header_length > prefix_length) return error.InvalidOutputHeader;
    const buffer = try allocator.alloc(u8, @intCast(@min(prefix_length, 64 * 1024)));
    defer allocator.free(buffer);
    var full_hasher = std.hash.Wyhash.init(checksum_seed);
    var header_hasher = std.hash.Wyhash.init(checksum_seed);
    var offset: u64 = 0;
    var rows_with_header: u64 = 0;
    var last_byte: u8 = 0;
    while (offset < prefix_length) {
        const wanted: usize = @intCast(@min(prefix_length - offset, buffer.len));
        const received = try file.readPositionalAll(io, buffer[0..wanted], offset);
        if (received != wanted) return error.AcceptedOutputPrefixTruncated;
        const bytes = buffer[0..received];
        full_hasher.update(bytes);
        for (bytes) |byte| if (byte == '\n') {
            rows_with_header += 1;
        };
        if (offset < header_length) {
            const header_part: usize = @intCast(@min(@as(u64, header_length) - offset, bytes.len));
            header_hasher.update(bytes[0..header_part]);
        }
        last_byte = bytes[bytes.len - 1];
        offset += received;
    }
    if (last_byte != '\n' or rows_with_header == 0) return error.InvalidExistingOutputFile;
    return .{
        .cursor = .{
            .header_length = header_length,
            .header_checksum = header_hasher.final(),
            .byte_length = prefix_length,
            .checksum = full_hasher.final(),
            .row_count = rows_with_header - 1,
        },
        .hasher = full_hasher,
    };
}

fn bytesEqualAt(io: std.Io, file: std.Io.File, offset: u64, expected: []const u8) !bool {
    var position: usize = 0;
    var buffer: [4096]u8 = undefined;
    while (position < expected.len) {
        const amount = @min(buffer.len, expected.len - position);
        const received = try file.readPositionalAll(io, buffer[0..amount], offset + position);
        if (received != amount or !std.mem.eql(u8, buffer[0..amount], expected[position..][0..amount])) return false;
        position += amount;
    }
    return true;
}

fn sameCursor(a: FileCursor, b: FileCursor) bool {
    return a.header_length == b.header_length and a.header_checksum == b.header_checksum and
        a.byte_length == b.byte_length and a.checksum == b.checksum and a.row_count == b.row_count;
}

const HashedFileReader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    size: u64,
    offset: u64 = 0,
    hasher: std.hash.Wyhash = std.hash.Wyhash.init(checksum_seed),
    journal_entries_read: u64 = 0,
    limits: Limits,

    fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, limits: Limits) !HashedFileReader {
        return .{ .allocator = allocator, .io = io, .file = file, .size = try file.length(io), .limits = limits };
    }

    fn deinit(self: *HashedFileReader) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    fn readRaw(self: *HashedFileReader, destination: []u8) !void {
        if (destination.len > self.size -| self.offset) return error.TruncatedOutputMetadata;
        const received = try self.file.readPositionalAll(self.io, destination, self.offset);
        if (received != destination.len) return error.TruncatedOutputMetadata;
        self.offset += received;
    }

    fn readHashed(self: *HashedFileReader, destination: []u8) !void {
        try self.readRaw(destination);
        self.hasher.update(destination);
    }

    fn expectHashed(self: *HashedFileReader, expected: []const u8) !void {
        const actual = try self.allocator.alloc(u8, expected.len);
        defer self.allocator.free(actual);
        try self.readHashed(actual);
        if (!std.mem.eql(u8, actual, expected)) return error.InvalidOutputMetadataMagic;
    }

    fn readRawByte(self: *HashedFileReader) !u8 {
        var bytes: [1]u8 = undefined;
        try self.readRaw(&bytes);
        return bytes[0];
    }

    fn readHashedByte(self: *HashedFileReader) !u8 {
        const value = try self.readRawByte();
        self.hasher.update(&.{value});
        return value;
    }

    fn readRawInt(self: *HashedFileReader, comptime T: type) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        try self.readRaw(&bytes);
        return std.mem.readInt(T, &bytes, .little);
    }

    fn readHashedInt(self: *HashedFileReader, comptime T: type) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        try self.readHashed(&bytes);
        return std.mem.readInt(T, &bytes, .little);
    }
};

fn writeJournalHeader(journal: *NewJournal, run_identity: u64) !void {
    try writeHashed(&journal.writer.interface, &journal.hasher, journal_magic);
    try writeHashedInt(&journal.writer.interface, &journal.hasher, u32, format_version);
    try writeHashedInt(&journal.writer.interface, &journal.hasher, u64, run_identity);
    try writeHashedInt(&journal.writer.interface, &journal.hasher, u64, journal.generation);
    try writeHashedInstant(&journal.writer.interface, &journal.hasher, journal.instant);
}

fn readJournalHeader(parser: *HashedFileReader, run_identity: u64) !struct { generation: u64, instant: Instant } {
    try parser.expectHashed(journal_magic);
    if (try parser.readHashedInt(u32) != format_version) return error.UnsupportedOutputJournalVersion;
    if (try parser.readHashedInt(u64) != run_identity) return error.OutputRunIdentityMismatch;
    const generation = try parser.readHashedInt(u64);
    const instant = try readHashedInstant(parser);
    try validateInstant(instant);
    return .{ .generation = generation, .instant = instant };
}

fn writeJournalEntry(journal: *NewJournal, category: Category, file_name: []const u8, header: []const u8, row: []const u8, base: FileCursor) !void {
    try writeHashedByte(&journal.writer.interface, &journal.hasher, entry_tag);
    try writeHashedByte(&journal.writer.interface, &journal.hasher, @intFromEnum(category));
    try writeHashedInt(&journal.writer.interface, &journal.hasher, u32, @intCast(file_name.len));
    try writeHashedInt(&journal.writer.interface, &journal.hasher, u32, @intCast(header.len));
    try writeHashedInt(&journal.writer.interface, &journal.hasher, u32, @intCast(row.len));
    try writeHashedFileCursor(&journal.writer.interface, &journal.hasher, base);
    try writeHashed(&journal.writer.interface, &journal.hasher, file_name);
    try writeHashed(&journal.writer.interface, &journal.hasher, header);
    try writeHashed(&journal.writer.interface, &journal.hasher, row);
}

fn readJournalEntry(parser: *HashedFileReader, allocator: std.mem.Allocator) !?Entry {
    const tag = try parser.readRawByte();
    if (tag == trailer_tag) {
        parser.offset -= 1;
        return null;
    }
    if (tag != entry_tag) return error.InvalidOutputJournalEntryTag;
    parser.hasher.update(&.{tag});
    const category = std.enums.fromInt(Category, try parser.readHashedByte()) orelse return error.InvalidOutputCategory;
    const file_name_length = try parser.readHashedInt(u32);
    const header_length = try parser.readHashedInt(u32);
    const row_length = try parser.readHashedInt(u32);
    if (file_name_length == 0 or file_name_length > parser.limits.maximum_file_name_bytes) return error.InvalidOutputFileName;
    if (header_length == 0 or header_length > parser.limits.maximum_header_bytes) return error.InvalidOutputHeader;
    if (row_length == 0 or row_length > parser.limits.maximum_row_bytes) return error.InvalidOutputRow;
    const base = try readHashedFileCursor(parser);
    const file_name = try allocator.alloc(u8, file_name_length);
    errdefer allocator.free(file_name);
    const header = try allocator.alloc(u8, header_length);
    errdefer allocator.free(header);
    const row = try allocator.alloc(u8, row_length);
    errdefer allocator.free(row);
    try parser.readHashed(file_name);
    try parser.readHashed(header);
    try parser.readHashed(row);
    if (!safeFileName(file_name) or !singleLine(header) or !singleLine(row)) return error.InvalidOutputJournalEntry;
    parser.journal_entries_read += 1;
    return .{ .category = category, .file_name = file_name, .header = header, .row = row, .base = base };
}

fn finishJournal(parser: *HashedFileReader, generation: u64, instant: Instant) !JournalSummary {
    if (try parser.readRawByte() != trailer_tag) return error.InvalidOutputJournalTrailer;
    const count = try parser.readRawInt(u64);
    const digest = try parser.readRawInt(u64);
    if (count != parser.journal_entries_read or digest != parser.hasher.final() or parser.offset != parser.size)
        return error.OutputJournalChecksumMismatch;
    return .{ .generation = generation, .instant = instant, .checksum = digest, .entry_count = count };
}

fn publishCursor(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, run_identity: u64, cursor: Cursor, buffer_bytes: usize) !void {
    const buffer = try allocator.alloc(u8, buffer_bytes);
    defer allocator.free(buffer);
    var atomic_file = try root.createFileAtomic(io, cursor_file_name, .{ .replace = true });
    defer atomic_file.deinit(io);
    var writer = atomic_file.file.writerStreaming(io, buffer);
    try writer.interface.writeAll(cursor_magic);
    try writeRawInt(&writer.interface, u32, format_version);
    try writeRawInt(&writer.interface, u64, run_identity);
    try writeRawInt(&writer.interface, u64, cursor.latest_generation);
    try writeRawInstant(&writer.interface, cursor.latest_instant);
    try writeRawInt(&writer.interface, u64, cursor.latest_journal_checksum);
    try writeRawInt(&writer.interface, u64, cursor.latest_entry_count);
    try writeRawInt(&writer.interface, u64, cursor.acknowledged_generation);
    try writeRawInstant(&writer.interface, cursor.acknowledged_instant);
    try writeRawInt(&writer.interface, u64, cursor.checkpoint_generation);
    try writeRawInt(&writer.interface, u64, cursor.bank_checksum);
    try writeRawInt(&writer.interface, u64, cursor.bank_entry_count);
    try writeRawInt(&writer.interface, u64, cursor.pruned_through_generation);
    try writeRawInt(&writer.interface, u64, cursor.obsolete_bank_generation);
    try writer.interface.flush();
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
}

fn readCursor(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, run_identity: u64) !?Cursor {
    const bytes = root.readFileAlloc(io, cursor_file_name, allocator, .limited(1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    if (!std.mem.eql(u8, try reader.takeArray(cursor_magic.len), cursor_magic)) return error.InvalidOutputCursorMagic;
    if (try reader.takeInt(u32, .little) != format_version) return error.UnsupportedOutputCursorVersion;
    if (try reader.takeInt(u64, .little) != run_identity) return error.OutputRunIdentityMismatch;
    const result: Cursor = .{
        .latest_generation = try reader.takeInt(u64, .little),
        .latest_instant = try readInstant(&reader),
        .latest_journal_checksum = try reader.takeInt(u64, .little),
        .latest_entry_count = try reader.takeInt(u64, .little),
        .acknowledged_generation = try reader.takeInt(u64, .little),
        .acknowledged_instant = try readInstant(&reader),
        .checkpoint_generation = try reader.takeInt(u64, .little),
        .bank_checksum = try reader.takeInt(u64, .little),
        .bank_entry_count = try reader.takeInt(u64, .little),
        .pruned_through_generation = try reader.takeInt(u64, .little),
        .obsolete_bank_generation = try reader.takeInt(u64, .little),
    };
    if (reader.peekByte()) |_| return error.TrailingOutputCursorData else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    if (result.latest_generation == 0) {
        if (result.acknowledged_generation != 0) return error.InvalidOutputCursor;
    } else try validateInstant(result.latest_instant);
    if (result.acknowledged_generation > result.latest_generation) return error.InvalidOutputCursor;
    if (result.pruned_through_generation > result.acknowledged_generation) return error.InvalidOutputCursor;
    if (result.obsolete_bank_generation > result.acknowledged_generation) return error.InvalidOutputCursor;
    if (result.acknowledged_generation != 0) try validateInstant(result.acknowledged_instant);
    return result;
}

fn writeHashedFileCursor(writer: *std.Io.Writer, hasher: *std.hash.Wyhash, cursor: FileCursor) !void {
    try writeHashedInt(writer, hasher, u32, cursor.header_length);
    try writeHashedInt(writer, hasher, u64, cursor.header_checksum);
    try writeHashedInt(writer, hasher, u64, cursor.byte_length);
    try writeHashedInt(writer, hasher, u64, cursor.checksum);
    try writeHashedInt(writer, hasher, u64, cursor.row_count);
}

fn readHashedFileCursor(parser: *HashedFileReader) !FileCursor {
    return .{
        .header_length = try parser.readHashedInt(u32),
        .header_checksum = try parser.readHashedInt(u64),
        .byte_length = try parser.readHashedInt(u64),
        .checksum = try parser.readHashedInt(u64),
        .row_count = try parser.readHashedInt(u64),
    };
}

fn writeHashedInstant(writer: *std.Io.Writer, hasher: *std.hash.Wyhash, instant: Instant) !void {
    try writeHashedInt(writer, hasher, i32, instant.year);
    try writeHashedInt(writer, hasher, u16, instant.day_of_year);
    try writeHashedByte(writer, hasher, instant.hour);
    try writeHashedInt(writer, hasher, u64, instant.execution_iteration);
    try writeHashedInt(writer, hasher, u64, instant.scenario_index);
    try writeHashedInt(writer, hasher, u64, instant.scenario_iteration);
    try writeHashedInt(writer, hasher, u64, instant.scene_index);
    try writeHashedInt(writer, hasher, u64, instant.completed_scene_hours);
}

fn readHashedInstant(parser: *HashedFileReader) !Instant {
    return .{
        .year = try parser.readHashedInt(i32),
        .day_of_year = try parser.readHashedInt(u16),
        .hour = try parser.readHashedByte(),
        .execution_iteration = try parser.readHashedInt(u64),
        .scenario_index = try parser.readHashedInt(u64),
        .scenario_iteration = try parser.readHashedInt(u64),
        .scene_index = try parser.readHashedInt(u64),
        .completed_scene_hours = try parser.readHashedInt(u64),
    };
}

fn writeRawInstant(writer: *std.Io.Writer, instant: Instant) !void {
    try writeRawInt(writer, i32, instant.year);
    try writeRawInt(writer, u16, instant.day_of_year);
    try writeRawByte(writer, instant.hour);
    try writeRawInt(writer, u64, instant.execution_iteration);
    try writeRawInt(writer, u64, instant.scenario_index);
    try writeRawInt(writer, u64, instant.scenario_iteration);
    try writeRawInt(writer, u64, instant.scene_index);
    try writeRawInt(writer, u64, instant.completed_scene_hours);
}

fn readInstant(reader: *std.Io.Reader) !Instant {
    return .{
        .year = try reader.takeInt(i32, .little),
        .day_of_year = try reader.takeInt(u16, .little),
        .hour = try reader.takeByte(),
        .execution_iteration = try reader.takeInt(u64, .little),
        .scenario_index = try reader.takeInt(u64, .little),
        .scenario_iteration = try reader.takeInt(u64, .little),
        .scene_index = try reader.takeInt(u64, .little),
        .completed_scene_hours = try reader.takeInt(u64, .little),
    };
}

fn writeHashed(writer: *std.Io.Writer, hasher: *std.hash.Wyhash, bytes: []const u8) !void {
    try writer.writeAll(bytes);
    hasher.update(bytes);
}

fn writeHashedByte(writer: *std.Io.Writer, hasher: *std.hash.Wyhash, value: u8) !void {
    try writeHashed(writer, hasher, &.{value});
}

fn writeHashedInt(writer: *std.Io.Writer, hasher: *std.hash.Wyhash, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writeHashed(writer, hasher, &bytes);
}

fn writeRawByte(writer: *std.Io.Writer, value: u8) !void {
    try writer.writeByte(value);
}

fn writeRawInt(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    try writer.writeInt(T, value, .little);
}

fn validateInstant(instant: Instant) !void {
    if (instant.year <= 0 or instant.year > 9999 or instant.hour > 23)
        return error.InvalidOutputInstant;
    _ = execution_calendar_date.fromDayOfYear(instant.day_of_year, @intCast(instant.year)) catch
        return error.InvalidOutputInstant;
}

fn sameInstant(a: Instant, b: Instant) bool {
    return std.meta.eql(a, b);
}

fn singleLine(bytes: []const u8) bool {
    return bytes.len != 0 and bytes[bytes.len - 1] == '\n' and
        std.mem.count(u8, bytes, "\n") == 1 and std.mem.indexOfScalar(u8, bytes, '\r') == null;
}

fn safeFileName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.indexOf(u8, name, "..") != null or name[0] == ' ' or
        name[name.len - 1] == ' ' or name[name.len - 1] == '.') return false;
    for (name) |byte| if (byte == 0 or byte < 0x20 or
        std.mem.indexOfScalar(u8, "/\\<>:\"|?*", byte) != null) return false;
    return true;
}

fn fileIdentity(category: Category, file_name: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(checksum_seed);
    hasher.update(&.{@intFromEnum(category)});
    hasher.update(file_name);
    return hasher.final();
}

fn firstDifference(expected: []const u8, actual: []const u8) ?usize {
    const shared_length = @min(expected.len, actual.len);
    for (expected[0..shared_length], actual[0..shared_length], 0..) |expected_byte, actual_byte, index| {
        if (expected_byte != actual_byte) return index;
    }
    return if (expected.len == actual.len) null else shared_length;
}

fn differenceWindow(bytes: []const u8, difference: usize) []const u8 {
    const start = difference -| 48;
    return bytes[start..@min(bytes.len, start + 160)];
}

fn delimitedFieldIndex(row: []const u8, difference: usize) usize {
    const prefix = row[0..@min(row.len, difference)];
    return std.mem.count(u8, prefix, ",") + std.mem.count(u8, prefix, "\t");
}

fn checksum(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(checksum_seed, bytes);
}

fn journalFileName(buffer: []u8, generation: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".ecosys-output-hour-{d}.bin", .{generation});
}

fn bankFileName(buffer: []u8, generation: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".ecosys-output-bank-{d}.bin", .{generation});
}

const test_header = "hour,value\n";

fn testInstant(generation: u64) Instant {
    return .{
        .year = 2001,
        .day_of_year = 1,
        .hour = @intCast(generation - 1),
        .completed_scene_hours = generation,
    };
}

fn testCheckpoint(generation: u64) AcceptedCheckpoint {
    return .{
        .checkpoint_generation = generation,
        .output_generation = generation,
        .instant = testInstant(generation),
    };
}

fn testCoordinatorWithLimits(directory: std.Io.Dir, limits: Limits) !Coordinator {
    return Coordinator.init(
        std.testing.allocator,
        std.testing.io,
        directory,
        .{
            .carbon = directory,
            .water = directory,
            .nitrogen = directory,
            .heat_energy = directory,
            .phosphorus = directory,
        },
        0x1234_5678_90ab_cdef,
        128,
        limits,
    );
}

fn testCoordinator(directory: std.Io.Dir) !Coordinator {
    return testCoordinatorWithLimits(directory, .{});
}

fn recordTestHour(coordinator: *Coordinator, generation: u64) !void {
    var row_buffer: [64]u8 = undefined;
    const row = try std.fmt.bufPrint(&row_buffer, "{d},{d}\n", .{ generation, generation * 10 });
    try coordinator.beginHour(generation, testInstant(generation));
    try coordinator.record(.carbon, "hourly.csv", test_header, row);
}

fn commitTestHour(coordinator: *Coordinator, generation: u64) !void {
    try recordTestHour(coordinator, generation);
    try coordinator.commitHour();
}

fn expectThreeRows(directory: std.Io.Dir) !void {
    const bytes = try directory.readFileAlloc(std.testing.io, "hourly.csv", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(
        "hour,value\n1,10\n2,20\n3,30\n",
        bytes,
    );
}

fn exerciseOutputCrash(point: FailurePoint) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    {
        var coordinator = try testCoordinator(temporary.dir);
        defer coordinator.deinit();
        try coordinator.reconcile(.fresh);
        try commitTestHour(&coordinator, 1);
        try coordinator.checkpointWillPublish();
        try coordinator.checkpointDidPublish(testCheckpoint(1));
        coordinator.setFailurePointForTesting(point);
        try recordTestHour(&coordinator, 2);
        try std.testing.expectError(error.InjectedOutputFailure, coordinator.commitHour());
    }
    {
        var coordinator = try testCoordinator(temporary.dir);
        defer coordinator.deinit();
        try coordinator.reconcile(.{ .checkpoint = testCheckpoint(1) });
        try commitTestHour(&coordinator, 2);
        try commitTestHour(&coordinator, 3);
    }
    try expectThreeRows(temporary.dir);
}

test "output hour crash points preserve accepted prefix and replay byte identically" {
    inline for (.{
        FailurePoint.before_journal_publish,
        .after_journal_publish,
        .during_materialization,
        .after_materialization_before_cursor,
        .during_cursor_publish,
        .after_cursor_publish,
    }) |point| try exerciseOutputCrash(point);
}

fn exerciseCheckpointCrash(point: FailurePoint) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var checkpoint_was_published = false;
    {
        var coordinator = try testCoordinator(temporary.dir);
        defer coordinator.deinit();
        try coordinator.reconcile(.fresh);
        try commitTestHour(&coordinator, 1);
        coordinator.setFailurePointForTesting(point);
        if (point == .before_checkpoint_publish or point == .during_checkpoint_publish) {
            try std.testing.expectError(error.InjectedOutputFailure, coordinator.checkpointWillPublish());
        } else {
            try coordinator.checkpointWillPublish();
            checkpoint_was_published = true;
            try std.testing.expectError(error.InjectedOutputFailure, coordinator.checkpointDidPublish(testCheckpoint(1)));
        }
    }
    {
        var coordinator = try testCoordinator(temporary.dir);
        defer coordinator.deinit();
        if (checkpoint_was_published) {
            try coordinator.reconcile(.{ .checkpoint = testCheckpoint(1) });
        } else {
            try coordinator.reconcile(.initial_state);
            try commitTestHour(&coordinator, 1);
            try coordinator.checkpointWillPublish();
            try coordinator.checkpointDidPublish(testCheckpoint(1));
        }
        try commitTestHour(&coordinator, 2);
        try commitTestHour(&coordinator, 3);
    }
    try expectThreeRows(temporary.dir);
}

test "checkpoint boundary crashes resume without duplicate or lost output rows" {
    inline for (.{
        FailurePoint.before_checkpoint_publish,
        .during_checkpoint_publish,
        .after_checkpoint_publish,
        .after_bank_publish_before_checkpoint_ack,
        .after_checkpoint_ack,
    }) |point| try exerciseCheckpointCrash(point);
}

test "resume rejects mutation of an accepted output prefix" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    {
        var coordinator = try testCoordinator(temporary.dir);
        defer coordinator.deinit();
        try coordinator.reconcile(.fresh);
        try commitTestHour(&coordinator, 1);
        try coordinator.checkpointWillPublish();
        try coordinator.checkpointDidPublish(testCheckpoint(1));
    }
    var file = try temporary.dir.openFile(std.testing.io, "hourly.csv", .{ .mode = .read_write });
    try file.writePositionalAll(std.testing.io, "H", 0);
    try file.sync(std.testing.io);
    file.close(std.testing.io);
    var resumed = try testCoordinator(temporary.dir);
    defer resumed.deinit();
    try std.testing.expectError(
        error.AcceptedOutputPrefixMismatch,
        resumed.reconcile(.{ .checkpoint = testCheckpoint(1) }),
    );
}

test "resume rebuilds an unacknowledged output suffix from durable journals" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    {
        var coordinator = try testCoordinator(temporary.dir);
        defer coordinator.deinit();
        try coordinator.reconcile(.fresh);
        try commitTestHour(&coordinator, 1);
        try coordinator.checkpointWillPublish();
        try coordinator.checkpointDidPublish(testCheckpoint(1));
        try commitTestHour(&coordinator, 2);
    }
    var file = try temporary.dir.openFile(std.testing.io, "hourly.csv", .{ .mode = .read_write });
    try file.writePositionalAll(std.testing.io, "2,99\n", test_header.len + "1,10\n".len);
    try file.sync(std.testing.io);
    file.close(std.testing.io);
    {
        var resumed = try testCoordinator(temporary.dir);
        defer resumed.deinit();
        try resumed.reconcile(.{ .checkpoint = testCheckpoint(1) });
    }
    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "hourly.csv",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("hour,value\n1,10\n2,20\n", bytes);
}

/// Records the same row into two files of one category, so a one-handle cache
/// evicts and reopens on every single entry.
fn commitTwoCarbonFileHour(coordinator: *Coordinator, generation: u64) !void {
    var row_buffer: [64]u8 = undefined;
    const row = try std.fmt.bufPrint(&row_buffer, "{d},{d}\n", .{ generation, generation * 10 });
    try coordinator.beginHour(generation, testInstant(generation));
    try coordinator.record(.carbon, "hourly.csv", test_header, row);
    try coordinator.record(.carbon, "second.csv", test_header, row);
    try coordinator.commitHour();
}

test "committed rows stay readable by others while the coordinator is live" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var coordinator = try testCoordinator(temporary.dir);
    defer coordinator.deinit();
    try coordinator.reconcile(.fresh);
    try commitTestHour(&coordinator, 1);
    // The coordinator retains an open handle on this file for the whole run.
    // Reading it from an independent handle must still work: a retained
    // whole-file lock, rather than one taken only around each mutation, would
    // make every other reader of accepted output fail for the whole run.
    {
        const bytes = try temporary.dir.readFileAlloc(
            std.testing.io,
            "hourly.csv",
            std.testing.allocator,
            .limited(1024),
        );
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings("hour,value\n1,10\n", bytes);
    }
    try commitTestHour(&coordinator, 2);
    try commitTestHour(&coordinator, 3);
    try coordinator.checkpointWillPublish();
    try coordinator.checkpointDidPublish(testCheckpoint(3));
    try expectThreeRows(temporary.dir);
}

test "output handle cache eviction preserves rows across a crash and resume" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // One resident handle against two files in the same category forces an
    // eviction and reopen for every entry of every hour.
    const limits: Limits = .{ .maximum_open_output_files = 1 };
    {
        var coordinator = try testCoordinatorWithLimits(temporary.dir, limits);
        defer coordinator.deinit();
        try coordinator.reconcile(.fresh);
        try commitTwoCarbonFileHour(&coordinator, 1);
        try coordinator.checkpointWillPublish();
        try coordinator.checkpointDidPublish(testCheckpoint(1));
        try commitTwoCarbonFileHour(&coordinator, 2);
        // Crash between checkpoints, after the hour-3 journal is durable but
        // before its rows reach the derived files.
        coordinator.setFailurePointForTesting(.after_journal_publish);
        var row_buffer: [64]u8 = undefined;
        const row = try std.fmt.bufPrint(&row_buffer, "{d},{d}\n", .{ 3, 30 });
        try coordinator.beginHour(3, testInstant(3));
        try coordinator.record(.carbon, "hourly.csv", test_header, row);
        try coordinator.record(.carbon, "second.csv", test_header, row);
        try std.testing.expectError(error.InjectedOutputFailure, coordinator.commitHour());
    }
    {
        var coordinator = try testCoordinatorWithLimits(temporary.dir, limits);
        defer coordinator.deinit();
        try coordinator.reconcile(.{ .checkpoint = testCheckpoint(1) });
        try commitTwoCarbonFileHour(&coordinator, 3);
    }
    try expectThreeRows(temporary.dir);
    const second = try temporary.dir.readFileAlloc(
        std.testing.io,
        "second.csv",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("hour,value\n1,10\n2,20\n3,30\n", second);
}

test "incremental digests equal a full rehash of every accepted prefix" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var coordinator = try testCoordinator(temporary.dir);
    defer coordinator.deinit();
    try coordinator.reconcile(.fresh);
    // Accumulate rows with the cheap default, so every digest comes only from
    // `applyEntry`'s running hasher and nothing re-reads the files.
    try std.testing.expectEqual(CheckpointVerification.trust_incremental_digest, coordinator.checkpoint_verification);
    for (1..4) |generation| try commitTwoCarbonFileHour(&coordinator, generation);
    // Now demand the exhaustive pass. It recomputes each digest, header
    // checksum, byte length, and row count from the bytes on disk and
    // compares them with `sameCursor` against the incrementally maintained
    // cursor, so it succeeds only if the two are exactly equal.
    coordinator.checkpoint_verification = .rehash_accepted_prefixes;
    try coordinator.checkpointWillPublish();
    try coordinator.checkpointDidPublish(testCheckpoint(3));
    try expectThreeRows(temporary.dir);
    // Still equal after the accepted boundary moved and more rows landed.
    for (4..6) |generation| try commitTwoCarbonFileHour(&coordinator, generation);
    try coordinator.checkpointWillPublish();
    try coordinator.checkpointDidPublish(testCheckpoint(5));
}

test "cheap checkpoint verification still rejects a resized accepted prefix" {
    inline for (.{ "truncate", "extend" }) |mutation| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var coordinator = try testCoordinator(temporary.dir);
        defer coordinator.deinit();
        try coordinator.reconcile(.fresh);
        try commitTestHour(&coordinator, 1);
        const file = try temporary.dir.openFile(std.testing.io, "hourly.csv", .{ .mode = .read_write });
        const length = try file.length(std.testing.io);
        if (comptime std.mem.eql(u8, mutation, "truncate"))
            try file.setLength(std.testing.io, length - 1)
        else
            try file.writePositionalAll(std.testing.io, "x\n", length);
        file.close(std.testing.io);
        try std.testing.expectError(
            if (comptime std.mem.eql(u8, mutation, "truncate"))
                error.AcceptedOutputPrefixTruncated
            else
                error.AcceptedOutputPrefixMismatch,
            coordinator.checkpointWillPublish(),
        );
    }
}

test "new hour rejects schema drift before publishing a journal" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var coordinator = try testCoordinator(temporary.dir);
    defer coordinator.deinit();
    try coordinator.reconcile(.fresh);
    try commitTestHour(&coordinator, 1);
    try coordinator.checkpointWillPublish();
    try coordinator.checkpointDidPublish(testCheckpoint(1));
    try coordinator.beginHour(2, testInstant(2));
    try std.testing.expectError(
        error.OutputSchemaMismatch,
        coordinator.record(.carbon, "hourly.csv", "hour,changed\n", "2,20\n"),
    );
}
