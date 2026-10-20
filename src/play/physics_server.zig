//! **THE PHYSICS SERVER'S PROTOCOL** (docs/PHYSICS.md, "Request numbers",
//! "The server's answers", "Loading the page", "The log"): around the
//! judge's re-run of one report (physics_judge.zig), everything the server
//! keeps between requests:
//! - **epochs:** a load issues `start.count`, `start` the run's start in
//!   Unix ms (later than the last run's, which the snapshot keeps), so an
//!   epoch is unique across runs; only the newest is answered;
//! - **request numbers:** the last answered R, its answer and its body's
//!   hash, so a resend gets the stored answer byte for byte;
//! - **the breaker:** three `differ`s in a row on one epoch answer `reload
//!   differs`; three of those with no kept tick between mark the park
//!   `stuck`;
//! - **tile lines:** the critters of every tile the view subscribes that
//!   no kept `held` has named this epoch;
//! - **the log and snapshots** (physics_log.zig), through webbox's store.
//!
//! One request at a time: webbox's hosts run one handler at a time, and
//! this keeps its state plainly.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const store = webbox.store;
const physics = @import("physics.zig");
const wire = @import("physics_wire.zig");
const judge = @import("physics_judge.zig");
const plog = @import("physics_log.zig");
const tiles = @import("tiles.zig");
const Tick = physics.Tick;
const Text = wire.Text;

/// The most bytes a report's body may hold: the route's cap (webbox's body
/// rule answers 413 past it).
pub const most_body = 64 * 1024;

/// The longest answer: a `differ`'s state and board and every tile line
/// fit well inside (300 critters at about 25 bytes, twice).
pub const most_answer = 64 * 1024;

/// A snapshot every this many kept ticks (4 s of play).
pub const snapshot_every: Tick = 64;

/// **THE LOG, ROTATED AND KEPT FOR AN HOUR** (Steve, 2026-10-15; the sizes
/// from notes/dog-park-capacity.md). The snapshot and the log after it are
/// all a restart needs; the logs before are a debugging record, bounded:
/// - at a snapshot, a log past `rotate_bytes` is closed and a new one begun,
///   named by its start (ms), the snapshot pointing at its first byte;
/// - a closed log goes once its successor began more than `keep_logs_ms`
///   ago (it ended then);
/// - and, oldest first, while a game's closed logs pass `most_log_bytes`
///   (80 games, about 2 GB);
/// - the log being written is never removed.
pub const rotate_bytes: u64 = 1 << 20;
pub const keep_logs_ms: u64 = 60 * 60 * 1000;
pub const most_log_bytes: u64 = 25 << 20;

/// Three `differ`s in a row trip the breaker; three trips with no kept tick
/// between mark the park stuck.
pub const breaker_differs = 3;
pub const stuck_trips = 3;

fn nowMs(io: Io) u64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_ms));
}

pub const Server = struct {
    /// The folder the log and the snapshot live in (`<data>/physics`).
    dir: []const u8,
    /// The physics hash the server answers to: the compiled one, but a test
    /// may take the doc's placeholder.
    physics_hash: u32 = wire.physics_hash,
    /// This run's start, Unix ms: every epoch it issues is `started.count`.
    started: u64,
    /// The newest epoch's count; 0 before the first load.
    epoch: u64 = 0,
    kept: judge.Kept,
    /// The last answered request number this epoch, and its answer and its
    /// body's hash.
    last: ?u64 = null,
    stored: [most_answer]u8 = undefined,
    stored_len: usize = 0,
    stored_hash: [32]u8 = undefined,
    /// Requests answered `differ` in a row, this epoch.
    differs_in_a_row: u32 = 0,
    /// `reload differs` answered with no kept tick between, across epochs.
    trips: u32 = 0,
    /// The tick of the last `differ`, for `stuck`.
    last_differ: Tick = 0,
    stuck: ?Tick = null,
    /// `req ?` answered this run.
    unreadable: u64 = 0,
    /// Findings this run (overlaps, drags with no drag on, refusals logged).
    findings: judge.Findings = .{},
    /// The log being written: its start (its name, `log-<ms>`), its path and
    /// its size; and the size it is closed at (`rotate_bytes`; a test sets
    /// less). The long-lived allocator its path comes from.
    log_started: u64 = 0,
    log_path: []const u8,
    log_size: u64 = 0,
    rotate_at: u64 = rotate_bytes,
    /// The most bytes of closed logs kept (`most_log_bytes`; a test sets less).
    keep_bytes: u64 = most_log_bytes,
    long: std.mem.Allocator = undefined,
    /// The kept tick of the last snapshot.
    snapshot_tick: Tick = 0,
    /// The highest level the player has unlocked, 1-based, for the load's
    /// `level L of U` (app.zig keeps it, per player); never less than the
    /// board's own.
    unlocked: u32 = 0,
    /// The answer being written.
    answer: [most_answer]u8 = undefined,

    // ── starting ────────────────────────────────────────────────────────────

    pub const Started = struct {
        /// How the board came back: from the snapshot and the log after it,
        /// or resolved afresh from the first layout.
        board: union(enum) { applied: struct { entries: usize, torn_bytes: usize }, resolved: usize },
        kept: Tick,
    };

    pub const StartError = error{ SnapshotDoesNotRead, CorruptLog, LogDoesNotApply, LogWithNoSnapshot, ParkDoesNotResolve };

    /// **STARTS A RUN** in `self` (its buffers are large: the caller holds
    /// it in place): the board from the last snapshot and the log after it,
    /// applied; or, on a board never resolved, `base` (the first layout)
    /// resolved once and logged as the log's first entry. A new
    /// run's start, later than the last; a snapshot naming this run's log.
    pub fn start(self: *Server, io: Io, long: std.mem.Allocator, data_dir: []const u8, base: *const physics.Board, now_ms: u64) !Started {
        var arena: std.heap.ArenaAllocator = .init(long);
        defer arena.deinit();
        const alloc = arena.allocator();
        const dir = try std.fs.path.join(long, &.{ data_dir, "physics" });
        // Field by field: the answer buffers are large, never a temporary.
        self.dir = dir;
        self.long = long;
        self.rotate_at = rotate_bytes;
        self.keep_bytes = most_log_bytes;
        self.log_started = 0;
        self.physics_hash = wire.physics_hash;
        self.started = 0;
        self.epoch = 0;
        self.kept = .{ .tick = 0, .board = base.* };
        self.last = null;
        self.stored_len = 0;
        self.differs_in_a_row = 0;
        self.trips = 0;
        self.last_differ = 0;
        self.stuck = null;
        self.unreadable = 0;
        self.findings = .{};
        self.log_path = "";
        self.log_size = 0;
        self.snapshot_tick = 0;
        self.unlocked = 0;
        const snap_path = try std.fs.path.join(alloc, &.{ dir, "snapshot" });
        var started: Started = undefined;
        var last_start: u64 = 0;
        if (try store.readOrNull(io, alloc, snap_path, .limited(1 << 20))) |bytes| {
            const s = try plog.readSnapshot(bytes);
            last_start = s.started;
            self.kept = s.kept;
            const log = try std.fs.path.join(alloc, &.{ dir, try plog.logName(alloc, s.log_started) });
            const all = (try store.readOrNull(io, alloc, log, .unlimited)) orelse "";
            if (s.log_offset > all.len) return error.CorruptLog;
            started = .{ .board = .{ .applied = try self.applyLog(all[s.log_offset..]) }, .kept = 0 };
        } else if (try onlyLog(io, alloc, dir)) |log| {
            // The resolution was logged and the first snapshot never
            // written: apply the log onto the board it resolved.
            const all = try store.read(io, alloc, log, .unlimited);
            started = .{ .board = .{ .applied = try self.applyLog(all) }, .kept = 0 };
            last_start = std.fmt.parseInt(u64, std.fs.path.basename(log)["log-".len..], 10) catch return error.CorruptLog;
        } else {
            var moves: std.ArrayList(u8) = .empty;
            const resolution = try plog.resolve(&self.kept.board, &moves, alloc);
            self.started = @max(now_ms, 1);
            self.log_started = self.started;
            self.log_path = try std.fs.path.join(long, &.{ dir, try plog.logName(alloc, self.started) });
            switch (resolution) {
                .nowhere => |c| {
                    // Fail, never warn, and say which: the log's one entry
                    // names it (the host prints the error's name).
                    _ = try store.append(io, alloc, self.log_path, try plog.framed(alloc, .finding, try std.fmt.allocPrint(alloc, "the park does not start: {t} {d} overlaps another\n", .{ c.kind, c.n })));
                    return error.ParkDoesNotResolve;
                },
                .resolved => |n| started = .{ .board = .{ .resolved = n }, .kept = 0 },
            }
            self.log_size = try store.append(io, alloc, self.log_path, try plog.framed(alloc, .resolved, moves.items));
            try self.snapshot(io, alloc);
            started.kept = self.kept.tick;
            return started;
        }
        self.started = @max(now_ms, last_start + 1);
        self.log_started = self.started;
        self.log_path = try std.fs.path.join(long, &.{ dir, try plog.logName(alloc, self.started) });
        self.log_size = 0;
        try self.snapshot(io, alloc);
        // The runs before this one closed their logs: kept as any closed log.
        try self.prune(io, alloc, now_ms);
        started.kept = self.kept.tick;
        return started;
    }

    fn applyLog(self: *Server, bytes: []const u8) !@FieldType(@FieldType(Started, "board"), "applied") {
        var entries: plog.Entries = .{ .bytes = bytes };
        var n: usize = 0;
        while (try entries.next()) |e| {
            try plog.apply(&self.kept, e);
            n += 1;
        }
        return .{ .entries = n, .torn_bytes = entries.torn };
    }

    /// The one log in the folder, when there is no snapshot; two is a
    /// mystery, not a crash's doing.
    fn onlyLog(io: Io, alloc: std.mem.Allocator, dir: []const u8) !?[]const u8 {
        var found: ?[]const u8 = null;
        for (try store.list(io, alloc, dir)) |e| {
            if (!std.mem.startsWith(u8, e.name, "log-")) continue;
            if (found != null) return error.LogWithNoSnapshot;
            found = try std.fs.path.join(alloc, &.{ dir, e.name });
        }
        return found;
    }

    /// The board's level, 1-based: Level One is 1.
    pub fn level(self: *const Server) u32 {
        return @as(u32, self.kept.board.level) + 1;
    }

    /// **LEAVES THIS GAME** (another level is played): a snapshot, so the
    /// next start of it applies nothing, and the run's paths given back.
    /// `self` is free for another `start`.
    pub fn leave(self: *Server, io: Io, alloc: std.mem.Allocator) !void {
        try self.snapshot(io, alloc);
        self.long.free(self.log_path);
        self.long.free(self.dir);
        self.log_path = "";
        self.dir = "";
    }

    fn snapshot(self: *Server, io: Io, alloc: std.mem.Allocator) !void {
        try self.snapshotAt(io, alloc, self.log_started, self.log_size);
    }

    /// The snapshot, naming the log a restart applies from: `log_started`
    /// from `offset`.
    fn snapshotAt(self: *Server, io: Io, alloc: std.mem.Allocator, log_started: u64, offset: u64) !void {
        var k = self.kept;
        k.view = .{};
        k.held = .{};
        const s: plog.Snapshot = .{ .physics = self.physics_hash, .started = self.started, .log_started = log_started, .log_offset = offset, .kept = k };
        try store.replace(io, alloc, try std.fs.path.join(alloc, &.{ self.dir, "snapshot" }), try plog.writeSnapshot(alloc, &s), .{});
        self.snapshot_tick = self.kept.tick;
    }

    /// **A SNAPSHOT, AND THE LOG ROTATED** when it has passed `rotate_at`:
    /// the snapshot names the new log at its first byte before anything
    /// is appended there, and the server switches only once it is written,
    /// so a restart always applies the log the entries went to.
    fn snapshotAndRotate(self: *Server, io: Io, alloc: std.mem.Allocator, now_ms: u64) !void {
        if (self.log_size < self.rotate_at) return self.snapshot(io, alloc);
        const next = @max(now_ms, self.log_started + 1);
        const path = try std.fs.path.join(self.long, &.{ self.dir, try plog.logName(alloc, next) });
        errdefer self.long.free(path);
        try self.snapshotAt(io, alloc, next, 0);
        self.long.free(self.log_path);
        self.log_path = path;
        self.log_started = next;
        self.log_size = 0;
        try self.prune(io, alloc, now_ms);
    }

    /// **THE CLOSED LOGS KEPT** (`keep_logs_ms`, `most_log_bytes`): by
    /// their names' starts, each ending where the next began; never the log
    /// being written.
    pub fn prune(self: *Server, io: Io, alloc: std.mem.Allocator, now_ms: u64) !void {
        const Closed = struct { started: u64, size: u64 };
        var closed: std.ArrayList(Closed) = .empty;
        for (try store.list(io, alloc, self.dir)) |e| {
            if (!std.mem.startsWith(u8, e.name, "log-")) continue;
            const id = std.fmt.parseInt(u64, e.name["log-".len..], 10) catch continue;
            if (id >= self.log_started) continue;
            const st = try store.stat(io, alloc, try std.fs.path.join(alloc, &.{ self.dir, e.name }));
            try closed.append(alloc, .{ .started = id, .size = st.size });
        }
        std.mem.sort(Closed, closed.items, {}, struct {
            fn lt(_: void, a: Closed, b: Closed) bool {
                return a.started < b.started;
            }
        }.lt);
        // A closed log's end: the next one's start.
        var bytes: u64 = 0;
        for (closed.items) |c| bytes += c.size;
        for (closed.items, 0..) |c, i| {
            const ended = if (i + 1 < closed.items.len) closed.items[i + 1].started else self.log_started;
            const stale = now_ms > ended and now_ms - ended > keep_logs_ms;
            if (!stale and bytes <= self.keep_bytes) continue;
            try store.remove(io, alloc, try std.fs.path.join(alloc, &.{ self.dir, try plog.logName(alloc, c.started) }));
            bytes -= c.size;
        }
    }

    fn append(self: *Server, io: Io, alloc: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        self.log_size = try store.append(io, alloc, self.log_path, bytes);
    }

    // ── a report ────────────────────────────────────────────────────────────

    /// **ANSWERS A REPORT.** The answer is in `self.answer` until the next
    /// request. Kept ticks are appended to the log before this returns; an
    /// error (the disk) leaves everything as it was, so a resend is judged
    /// afresh.
    pub fn report(self: *Server, io: Io, alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
        var out: Text = .{ .buf = &self.answer };
        var lines: wire.Lines = .{ .rest = body };
        const header = blk: {
            const first = lines.next() orelse break :blk null;
            const parsed = wire.parse(self.kept.board.geometry(), first) catch break :blk null;
            break :blk switch (parsed) {
                .header => |h| h,
                else => null,
            };
        } orelse {
            self.unreadable += 1;
            try self.append(io, alloc, try plog.framed(alloc, .finding, try std.fmt.allocPrint(alloc, "req ? number {d} at kept {d}\n", .{ self.unreadable, self.kept.tick })));
            try out.str("req ?\n");
            return out.bytes();
        };
        try out.str("req ");
        try out.dec(header.req);
        try out.char('\n');
        if (header.language != wire.language) {
            try out.str("reload language ");
            try out.dec(wire.language);
            try out.char('\n');
            return out.bytes();
        }
        if (header.physics != self.physics_hash) {
            try out.str("reload physics ");
            try out.hash(self.physics_hash);
            try out.char('\n');
            return out.bytes();
        }
        if (self.stuck) |t| return stuckAnswer(&out, t);
        if (header.epoch.ms != self.started or header.epoch.count == 0 or header.epoch.count > self.epoch) {
            try out.str("reload epoch\n");
            return out.bytes();
        }
        if (header.epoch.count < self.epoch) {
            try out.str("taken over\n");
            return out.bytes();
        }
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &hash, .{});
        const next = (self.last orelse 0) + 1;
        if (self.last != null and header.req == self.last.?) {
            if (std.mem.eql(u8, &hash, &self.stored_hash)) return self.stored[0..self.stored_len];
            return self.refuseHeader(io, alloc, &out, body, "a reused request number with another body");
        }
        if (header.req != next) return self.refuseHeader(io, alloc, &out, body, "a request number out of order");

        // A new request: judged, logged, then answered.
        const before = self.kept;
        out.len = 0;
        var found: judge.Findings = .{};
        const verdict = try judge.judge(&self.kept, self.physics_hash, body, &out, &found);
        errdefer self.kept = before;
        const kept_text: []const u8 = switch (verdict) {
            .kept => body,
            .differ => plog.keptPrefix(self.kept.board.geometry(), body, self.kept.tick + 1),
            .reload, .unreadable => "",
        };
        var entry: std.ArrayList(u8) = .empty;
        if (self.kept.tick != before.tick or verdict == .kept) {
            try entry.appendSlice(alloc, try plog.framed(alloc, .report, kept_text));
        }
        if (found.overlaps > 0 or found.idle_drags > 0) {
            try entry.appendSlice(alloc, try plog.framed(alloc, .finding, try std.fmt.allocPrint(alloc, "req {d} through kept {d}: {d} overlaps, {d} drags with no drag on\n", .{ header.req, self.kept.tick, found.overlaps, found.idle_drags })));
        }
        var sent = self.kept.sent;
        switch (verdict) {
            .kept => self.differs_in_a_row = 0,
            .differ => {
                self.differs_in_a_row += 1;
                self.last_differ = self.kept.tick + 1;
                // Logged as its own line: the report's kept prefix alone
                // can't say the page and the server disagreed.
                try entry.appendSlice(alloc, try plog.framed(alloc, .finding, try std.fmt.allocPrint(alloc, "req {d} differ at tick {d}\n", .{ header.req, self.last_differ })));
            },
            .reload, .unreadable => {},
        }
        if (self.kept.tick != before.tick) self.trips = 0;
        var stuck_now: ?Tick = null;
        if (verdict == .differ and self.differs_in_a_row >= breaker_differs) {
            out.len = 0;
            try out.str("req ");
            try out.dec(header.req);
            try out.str("\nreload differs\n");
            if (self.trips + 1 >= stuck_trips) {
                stuck_now = self.last_differ;
                try entry.appendSlice(alloc, try plog.framed(alloc, .finding, try std.fmt.allocPrint(alloc, "stuck at tick {d}: the physics disagrees with itself\n", .{self.last_differ})));
            }
        } else if (verdict == .kept or verdict == .differ) {
            try self.tileLines(&out, &sent);
        }
        try self.append(io, alloc, entry.items);
        // Logged: from here nothing fails but a snapshot, which is redone.
        self.kept.sent = sent;
        if (verdict == .differ and self.differs_in_a_row >= breaker_differs) {
            self.trips += 1;
            self.differs_in_a_row = 0;
        }
        if (stuck_now) |t| self.stuck = t;
        self.findings.overlaps += found.overlaps;
        self.findings.idle_drags += found.idle_drags;
        self.keepAnswer(header.req, out.bytes(), &hash);
        // A snapshot (and a rotation, a prune) that fails is let go: the log,
        // appended and synced before this answer, is the record; a missed
        // snapshot only lengthens the next restart's log, and a rotation
        // switches only once its snapshot is written.
        if (self.kept.tick >= self.snapshot_tick + snapshot_every) self.snapshotAndRotate(io, alloc, nowMs(io)) catch {};
        return self.stored[0..self.stored_len];
    }

    fn keepAnswer(self: *Server, req: u64, answer: []const u8, hash: *const [32]u8) void {
        @memcpy(self.stored[0..answer.len], answer);
        self.stored_len = answer.len;
        self.stored_hash = hash.*;
        self.last = req;
    }

    /// A report refused whole by its header line: `differ K+1 none` it,
    /// counted as a `differ`, logged; the stored answer stays.
    fn refuseHeader(self: *Server, io: Io, alloc: std.mem.Allocator, out: *Text, body: []const u8, why: []const u8) ![]const u8 {
        const header_len = out.len;
        try judge.refuseWhole(&self.kept, body, out);
        var sent = self.kept.sent;
        try self.tileLines(out, &sent);
        const first = std.mem.sliceTo(body, '\n');
        try self.append(io, alloc, try plog.framed(alloc, .finding, try std.fmt.allocPrint(alloc, "refused, {s}: {s}\n", .{ why, first })));
        self.kept.sent = sent;
        self.differs_in_a_row += 1;
        self.last_differ = self.kept.tick + 1;
        if (self.differs_in_a_row >= breaker_differs) {
            out.len = header_len;
            try out.str("reload differs\n");
            self.trips += 1;
            self.differs_in_a_row = 0;
            if (self.trips >= stuck_trips) self.stuck = self.last_differ;
        }
        return out.bytes();
    }

    fn stuckAnswer(out: *Text, t: Tick) ![]const u8 {
        try out.str("stuck ");
        try out.dec(t);
        try out.char('\n');
        return out.bytes();
    }

    /// **THE TILE LINES**: every tile the view subscribes that no kept
    /// `held` has named this epoch, its critters as they stand at the end
    /// of the last kept tick, in rank order; marked sent.
    fn tileLines(self: *const Server, out: *Text, sent: *judge.Tiles) !void {
        const k = &self.kept;
        const leashed = k.board.leashedDog();
        for (k.view.tiles.sorted().slice()) |t| {
            if (k.named.holds(t)) continue;
            try out.str("tile ");
            try out.dec(@intCast(t.col));
            try out.char(',');
            try out.dec(@intCast(t.row));
            if (leashed) |l| try tileEntry(out, &k.board, t, .of(physics.leashed_kind, l));
            for (physics.ranked) |c| {
                if (leashed != null and c.kind == physics.leashed_kind and leashed.? == c.n) continue;
                try tileEntry(out, &k.board, t, c);
            }
            for (k.board.poops, k.board.poop_known, 0..) |p, known, i| {
                if (known != .present) continue;
                const at = k.board.geometry().tileOf(p);
                if (at.col != t.col or at.row != t.row) continue;
                try out.char(' ');
                try wire.poopAt(out, @intCast(i), p);
            }
            try out.char('\n');
            sent.add(t);
        }
    }

    fn tileEntry(out: *Text, b: *const physics.Board, t: tiles.Tile, c: physics.Critter) !void {
        if (b.known(c) != .present) return;
        const p = b.at(c);
        const at = b.geometry().tileOf(p);
        if (at.col != t.col or at.row != t.row) return;
        try out.char(' ');
        try wire.entry(out, b, c);
    }

    // ── a load ──────────────────────────────────────────────────────────────

    /// **ANSWERS A LOAD**: `dogpark 2 physics H load WxH`. A new epoch; the
    /// stored answer and the last request number cleared; at K + 1, a view
    /// of the region's tiles (none when nothing is leashed, after the inputs
    /// kept for K + 1) and a held of them, logged; the answer's `tile` lines
    /// carry them.
    /// What a load does to the board.
    pub const LoadFrom = enum {
        /// The game as it stands: the leash comes off (the park sleeps),
        /// the critters stay where they are.
        kept,
        /// The game from its beginning: the first layout.
        layout,
    };

    pub fn load(self: *Server, io: Io, alloc: std.mem.Allocator, body: []const u8, from: LoadFrom) ![]const u8 {
        var out: Text = .{ .buf = &self.answer };
        const asked = parseLoad(body) catch {
            self.unreadable += 1;
            try self.append(io, alloc, try plog.framed(alloc, .finding, try std.fmt.allocPrint(alloc, "req ? number {d} (a load) at kept {d}\n", .{ self.unreadable, self.kept.tick })));
            try out.str("req ?\n");
            return out.bytes();
        };
        if (asked.language != wire.language) {
            try out.str("reload language ");
            try out.dec(wire.language);
            try out.char('\n');
            return out.bytes();
        }
        if (asked.physics != self.physics_hash) {
            try out.str("reload physics ");
            try out.hash(self.physics_hash);
            try out.char('\n');
            return out.bytes();
        }
        if (self.stuck) |t| return stuckAnswer(&out, t);
        // **A LOAD PICKS UP THE GAME** (Steve, 2026-10-15, replacing
        // "every load starts the park afresh"): nothing leashed, nothing
        // pending, the critters as they stand; or, asked to reset, the first
        // layout. Snapshotted before the load's entry, so a restart applies
        // the log from here.
        switch (from) {
            .kept => self.kept.board.hold = .none,
            .layout => self.kept.board = physics.Board.laidOutAt(self.kept.board.level),
        }
        self.kept.pending_len = 0;
        try self.snapshot(io, alloc);
        const k1 = self.kept.tick + 1;
        // The region at K + 1, around the dog leashed after the inputs kept
        // for it.
        var region: wire.TileSet = .{};
        {
            var b = self.kept.board;
            var begun: physics.Begun = .{};
            for (self.kept.pendingSlice()) |h| _ = physics.input(&b, &begun, h);
            if (b.leashedDog()) |l| {
                const g = b.geometry();
                const span = physics.TileSpan.of(g, g.region(b.of(physics.leashed_kind)[l]));
                var row = span.row_lo;
                while (row <= span.row_hi) : (row += 1) {
                    var col = span.col_lo;
                    while (col <= span.col_hi) : (col += 1) region.add(g.tileAt(col, row)) catch unreachable;
                }
            }
        }
        const epoch = self.epoch + 1;
        var entry: std.ArrayList(u8) = .empty;
        {
            var buf: [2048]u8 = undefined;
            var t: Text = .{ .buf = &buf };
            try t.str("load ");
            try t.dec(self.started);
            try t.char('.');
            try t.dec(epoch);
            try t.char(' ');
            try t.dec(asked.w);
            try t.char('x');
            try t.dec(asked.h);
            try t.char('\n');
            try wire.write(&t, .{ .view = .{ .tick = k1, .w = asked.w, .h = asked.h, .tiles = region } });
            try wire.write(&t, .{ .held = .{ .tick = k1, .tiles = region } });
            try entry.appendSlice(alloc, try plog.framed(alloc, .load, t.bytes()));
        }
        try self.append(io, alloc, entry.items);
        self.epoch = epoch;
        self.last = null;
        self.stored_len = 0;
        self.differs_in_a_row = 0;
        self.kept.view = .{ .w = asked.w, .h = asked.h, .tiles = region };
        self.kept.held = region;
        self.kept.sent = .{};
        self.kept.named = .{};
        try out.str("epoch ");
        try out.dec(self.started);
        try out.char('.');
        try out.dec(epoch);
        try out.str("\nkept ");
        try out.dec(self.kept.tick);
        try out.str("\nlevel ");
        try out.dec(self.level());
        try out.str(" of ");
        try out.dec(@max(self.unlocked, self.level()));
        try out.char('\n');
        try judge.stateAndInputs(&out, &self.kept, k1);
        // Every region tile goes out, then counts as named: the load's held.
        var sent: judge.Tiles = .{};
        try self.tileLines(&out, &sent);
        self.kept.sent = sent;
        for (region.slice()) |t| self.kept.named.add(t);
        return out.bytes();
    }

    const Load = struct { language: u64, physics: u32, w: u64, h: u64 };

    fn parseLoad(body: []const u8) !Load {
        const line = if (std.mem.endsWith(u8, body, "\n")) body[0 .. body.len - 1] else body;
        var it = std.mem.splitScalar(u8, line, ' ');
        if (!std.mem.eql(u8, it.next() orelse "", "dogpark")) return error.Bad;
        const language = try wire.parseDec(it.next() orelse "", std.math.maxInt(u32));
        if (!std.mem.eql(u8, it.next() orelse "", "physics")) return error.Bad;
        const h = it.next() orelse "";
        if (h.len != 8) return error.Bad;
        for (h) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.Bad;
        const hash = try std.fmt.parseInt(u32, h, 16);
        if (!std.mem.eql(u8, it.next() orelse "", "load")) return error.Bad;
        const size = it.next() orelse "";
        const x = std.mem.indexOfScalar(u8, size, 'x') orelse return error.Bad;
        const w = try wire.parseDec(size[0..x], 1 << 16);
        const hi = try wire.parseDec(size[x + 1 ..], 1 << 16);
        if (it.next() != null) return error.Bad;
        return .{ .language = language, .physics = hash, .w = w, .h = hi };
    }
};

test {
    _ = @import("physics_server_test.zig");
}
