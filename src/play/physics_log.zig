//! **THE LOG AND THE SNAPSHOTS** (docs/PHYSICS.md, "The log"): what the
//! physics server keeps on disk, as text, and how a restart puts the board
//! back from it without re-running the physics.
//!
//! **The log** is a file of entries, each framed so a torn tail shows:
//!
//!     entry <kind> <bytes>\n
//!     <bytes of body>
//!     end\n
//!
//! The kinds:
//! - `resolved`: the load resolution, the log's first entry: a critter
//!   line ` dog N a > b` for each critter it moved.
//! - `report`: a kept report as written, or a `differ`'d one's kept prefix
//!   (its lines before tick T).
//! - `load`: `load E WxH`, then the `view` and `held` the load kept at K + 1.
//! - `finding`: a line for people (an overlap, `req ?`, a refused reuse of a
//!   request number, `stuck`); never applied.
//!
//! **A snapshot** is every critter's position, the last kept tick K, the
//! inputs kept for K + 1, the hold (leash and drag), the physics hash, the
//! run's start (so the next run's epochs are later), and the log file and
//! byte offset it covers. One file, replaced whole.
//!
//! **A restart applies, never re-runs:** each entry after the snapshot is
//! taken as written: inputs set the leash and the drag, critter lines put
//! critters where they ended, `bump` and a timer's `release` end drags and
//! leashes. Nothing is checked against the physics, so a log written under
//! other physics applies the same.

const std = @import("std");
const physics = @import("physics.zig");
const wire = @import("physics_wire.zig");
const judge = @import("physics_judge.zig");
const Tick = physics.Tick;
const Board = physics.Board;
const Critter = physics.Critter;

pub const Kind = enum { resolved, report, load, finding };

/// One entry, framed, ready to append.
pub fn framed(alloc: std.mem.Allocator, kind: Kind, body: []const u8) ![]u8 {
    const nl: []const u8 = if (body.len > 0 and body[body.len - 1] != '\n') "\n" else "";
    return std.fmt.allocPrint(alloc, "entry {t} {d}\n{s}{s}end\n", .{ kind, body.len + nl.len, body, nl });
}

pub const Entry = struct { kind: Kind, body: []const u8 };

/// The entries of a log's bytes, in order. A tail cut short by a crash
/// mid-append is `torn`: it ends the entries, and its bytes are dropped. A
/// bad entry with a whole one after it is `corrupt`: not a crash's doing.
pub const Entries = struct {
    bytes: []const u8,
    at: usize = 0,
    torn: usize = 0,

    pub const Error = error{CorruptLog};

    pub fn next(self: *Entries) Error!?Entry {
        if (self.at == self.bytes.len) return null;
        const rest = self.bytes[self.at..];
        const e = parseOne(rest) catch |err| switch (err) {
            error.Torn => {
                self.torn = rest.len;
                self.at = self.bytes.len;
                return null;
            },
            error.Bad => {
                // A crash cuts only the end: a whole entry after this one
                // means the log was damaged some other way.
                if (std.mem.indexOf(u8, rest, "\nend\nentry ") != null) return error.CorruptLog;
                self.torn = rest.len;
                self.at = self.bytes.len;
                return null;
            },
        };
        self.at += e.len;
        return e.entry;
    }

    fn parseOne(rest: []const u8) error{ Torn, Bad }!struct { entry: Entry, len: usize } {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.Torn;
        var words = std.mem.splitScalar(u8, rest[0..nl], ' ');
        if (!std.mem.eql(u8, words.next() orelse "", "entry")) return error.Bad;
        const kind = std.meta.stringToEnum(Kind, words.next() orelse "") orelse return error.Bad;
        const n = wire.parseDec(words.next() orelse "", 1 << 30) catch return error.Bad;
        if (words.next() != null) return error.Bad;
        const body_at = nl + 1;
        const end_at = body_at + n;
        if (end_at + 4 > rest.len) return error.Torn;
        if (!std.mem.eql(u8, rest[end_at .. end_at + 4], "end\n")) return error.Bad;
        return .{ .entry = .{ .kind = kind, .body = rest[body_at..end_at] }, .len = end_at + 4 };
    }
};

// ── applying ───────────────────────────────────────────────────────────────

pub const ApplyError = error{ LogDoesNotApply, CorruptLog };

/// **APPLIES ONE ENTRY** to the kept state, as written.
pub fn apply(kept: *judge.Kept, e: Entry) ApplyError!void {
    switch (e.kind) {
        .load, .finding => {},
        .resolved => {
            var lines: wire.Lines = .{ .rest = e.body };
            while (lines.next()) |text| {
                const line = wire.parse(kept.board.geometry(), text) catch return error.CorruptLog;
                if (line != .critter) return error.CorruptLog;
                try moveAsWritten(&kept.board, line.critter);
            }
        },
        .report => try applyReport(kept, e.body),
    }
}

fn moveAsWritten(b: *Board, c: physics.CritterLine) ApplyError!void {
    const was = b.at(c.who);
    if (was.x != c.before.x or was.y != c.before.y) return error.LogDoesNotApply;
    b.put(c.who, c.after);
}

/// A tick being applied: its number and what its inputs came to.
const Open = struct { t: Tick, begun: physics.Begun };

fn applyReport(kept: *judge.Kept, body: []const u8) ApplyError!void {
    var lines: wire.Lines = .{ .rest = body };
    var open: ?Open = null;
    while (lines.next()) |text| {
        const line = wire.parse(kept.board.geometry(), text) catch return error.CorruptLog;
        switch (line) {
            .header, .view, .held => {},
            .from => |f| if (f.tick != kept.tick) return error.LogDoesNotApply,
            .critter => |c| {
                if (open == null) return error.CorruptLog;
                try moveAsWritten(&kept.board, c);
            },
            // A dog's walk isn't in the log (a tick's lines say where it
            // ended, not the steps it took), nor the count of poops laid
            // (one laid and eaten in a tick may leave no line): an applied
            // log leaves both at the snapshot's. A load now picks the game
            // up, so after a restart the next poop may come a little early
            // or late, or take a slot early (an old poop vanishes). No
            // invariant rests on them, and page and server agree: the load
            // sends `laid`, and the page takes the board from the server.
            .poop => |p| {
                if (open == null) return error.CorruptLog;
                kept.board.poops[p.n] = p.at;
                kept.board.poop_known[p.n] = .present;
            },
            .eaten => |n| {
                if (open == null) return error.CorruptLog;
                if (kept.board.poop_known[n] != .present) return error.LogDoesNotApply;
                kept.board.poop_known[n] = .absent;
            },
            .bump => |bu| {
                const o = open orelse return error.CorruptLog;
                if (bu.tick != o.t) return error.CorruptLog;
                endDrag(&kept.board, o.t);
            },
            .rest => {},
            .release => |r| if (open != null and r.tick == open.?.t) {
                // The timer's release, a checked line.
                close(kept, &open);
                kept.board.hold = .none;
            } else try waitFor(kept, &open, line),
            .leash, .grab, .letgo => try waitFor(kept, &open, line),
            .t => |tl| {
                close(kept, &open);
                if (tl.tick != kept.tick + 1) return error.LogDoesNotApply;
                var begun: physics.Begun = .{};
                for (kept.pendingSlice()) |h| _ = physics.input(&kept.board, &begun, h);
                kept.pending_len = 0;
                kept.tick = tl.tick;
                open = .{ .t = tl.tick, .begun = begun };
            },
        }
    }
    close(kept, &open);
}

/// An input for the next tick: it waits, as the judge keeps it.
fn waitFor(kept: *judge.Kept, open: *?Open, line: wire.Line) ApplyError!void {
    close(kept, open);
    const in = wire.human(line).?;
    if (in.tick != kept.tick + 1 or kept.pending_len == physics.most_humans) return error.LogDoesNotApply;
    kept.pending[kept.pending_len] = in.h;
    kept.pending_len += 1;
}

/// The end of an applied tick: a `letgo` ends the drag after it.
fn close(kept: *judge.Kept, open: *?Open) void {
    const o = open.* orelse return;
    if (o.begun.letting_go == .after_drag) endDrag(&kept.board, o.t);
    open.* = null;
}

fn endDrag(b: *Board, t: Tick) void {
    switch (b.hold) {
        .none => {},
        .leashed => |*l| if (l.drag == .on) {
            l.drag = .{ .ended = t };
        },
    }
}

// ── what a report keeps ─────────────────────────────────────────────────────

/// The report's lines before tick `t` (a `differ`'s kept prefix): its
/// header, its `from`, and every line of the ticks before `t`, read by the
/// kept board's level's world (`g`).
pub fn keptPrefix(g: physics.Geometry, report: []const u8, t: Tick) []const u8 {
    var lines: wire.Lines = .{ .rest = report };
    var at: usize = 0;
    while (true) {
        const before = lines.rest;
        const text = lines.next() orelse break;
        const line = wire.parse(g, text) catch break;
        const tick: ?Tick = switch (line) {
            .header, .from, .critter, .poop, .eaten => null,
            .leash => |l| l.tick,
            .release => |r| r.tick,
            .grab, .letgo, .rest => |x| x,
            .held => |h| h.tick,
            .view => |v| v.tick,
            .t => |tl| tl.tick,
            .bump => |bu| bu.tick,
        };
        if (tick) |k| if (k >= t) break;
        at += before.len - lines.rest.len;
    }
    return report[0..at];
}

// ── the load resolution ─────────────────────────────────────────────────────

pub const Resolution = union(enum) {
    /// Every critter clear: these moved (critter lines, for the log).
    resolved: usize,
    /// This critter has nowhere to go: the server does not start.
    nowhere: Critter,
};

/// **THE PARK ON LOAD**, once, on a board never resolved: it must have no
/// two critters overlapping. The first layout has none, and no tick makes
/// one (the walk's veto, the leashed dog's sweep), so a board with one is a
/// bug: the server does not start (`nowhere` names the later of the pair).
/// Nothing moves, so nothing goes to `out`.
pub fn resolve(b: *Board, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !Resolution {
    _ = out;
    _ = alloc;
    const all = physics.ranked;
    for (all, 0..) |c, i| {
        if (b.known(c) != .present) continue;
        for (all[0..i]) |o| {
            if (b.known(o) == .present and b.geometry().squaresOverlap(b.at(c), c.half(), b.at(o), o.half())) return .{ .nowhere = c };
        }
    }
    return .{ .resolved = 0 };
}

// ── snapshots ───────────────────────────────────────────────────────────────

pub const Snapshot = struct {
    /// The physics hash the server ran under when it wrote this.
    physics: u32,
    /// The run's start (Unix ms): the next run's is later.
    started: u64,
    /// The log file it covers (a run's: `log-<started>`) and how much of it.
    log_started: u64,
    log_offset: u64,
    /// The last kept tick, the board at its end, the hold, and the inputs
    /// kept for the tick after.
    kept: judge.Kept,
};

pub fn logName(alloc: std.mem.Allocator, started: u64) ![]u8 {
    return std.fmt.allocPrint(alloc, "log-{d}", .{started});
}

/// The snapshot as text: a line each, critters in rank order (no leash
/// first: positions, and a dog's walk), then each poop by number, `end`
/// last.
pub fn writeSnapshot(alloc: std.mem.Allocator, s: *const Snapshot) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    var hash: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&hash, "{x:0>8}", .{s.physics}) catch unreachable;
    try w.print("dogpark snapshot 3\nphysics {s}\nstarted {d}\nlog {d} {d}\nkept {d}\n", .{ &hash, s.started, s.log_started, s.log_offset, s.kept.tick });
    switch (s.kept.board.hold) {
        .none => try w.writeAll("hold none\n"),
        .leashed => |l| switch (l.drag) {
            .on => try w.print("hold {d} drag on\n", .{l.dog}),
            .ended => |e| try w.print("hold {d} drag ended {d}\n", .{ l.dog, e }),
        },
    }
    try w.print("laid {d}\n", .{s.kept.board.laid});
    var buf: [128]u8 = undefined;
    for (s.kept.pendingSlice()) |h| {
        var t: wire.Text = .{ .buf = &buf };
        const k = s.kept.tick + 1;
        try wire.write(&t, switch (h) {
            .leash => |d| .{ .leash = .{ .tick = k, .dog = d } },
            .release => |d| .{ .release = .{ .tick = k, .dog = d } },
            .grab => .{ .grab = k },
            .letgo => .{ .letgo = k },
        });
        try w.writeAll(t.bytes());
    }
    for (physics.ranked) |c| try position(w, &s.kept.board, c);
    for (s.kept.board.poops, s.kept.board.poop_known, 0..) |p, k, i| {
        if (k != .present) continue;
        var pb: [64]u8 = undefined;
        var t: wire.Text = .{ .buf = &pb };
        wire.poopAt(&t, @intCast(i), p) catch unreachable;
        try w.writeAll(t.bytes());
        try w.writeByte('\n');
    }
    try w.writeAll("end\n");
    return out.toOwnedSlice();
}

fn position(w: *std.Io.Writer, b: *const Board, c: Critter) !void {
    var buf: [64]u8 = undefined;
    var t: wire.Text = .{ .buf = &buf };
    wire.entry(&t, b, c) catch unreachable;
    try w.writeAll(t.bytes());
    try w.writeByte('\n');
}

pub const SnapshotError = error{SnapshotDoesNotRead};

/// The snapshot a text holds: every line as `writeSnapshot` writes it, every
/// critter once, in order.
pub fn readSnapshot(bytes: []const u8) SnapshotError!Snapshot {
    return readSnapshotOr(bytes) catch error.SnapshotDoesNotRead;
}

fn readSnapshotOr(bytes: []const u8) !Snapshot {
    var lines: wire.Lines = .{ .rest = bytes };
    if (!std.mem.eql(u8, lines.next() orelse "", "dogpark snapshot 3")) return error.Bad;
    var s: Snapshot = undefined;
    s.physics = try std.fmt.parseInt(u32, try after(lines.next(), "physics "), 16);
    s.started = try wire.parseDec(try after(lines.next(), "started "), std.math.maxInt(u63));
    {
        var it = std.mem.splitScalar(u8, try after(lines.next(), "log "), ' ');
        s.log_started = try wire.parseDec(it.next() orelse "", std.math.maxInt(u63));
        s.log_offset = try wire.parseDec(it.next() orelse "", std.math.maxInt(u63));
        if (it.next() != null) return error.Bad;
    }
    s.kept = .{ .tick = try wire.parseDec(try after(lines.next(), "kept "), std.math.maxInt(u63)), .board = Board.laidOut() };
    {
        const hold = try after(lines.next(), "hold ");
        if (std.mem.eql(u8, hold, "none")) {
            s.kept.board.hold = .none;
        } else {
            var it = std.mem.splitScalar(u8, hold, ' ');
            const dog = try wire.parseNumber(it.next() orelse "", physics.countOf(physics.leashed_kind));
            if (!std.mem.eql(u8, it.next() orelse "", "drag")) return error.Bad;
            const which = it.next() orelse "";
            const drag: physics.Drag = if (std.mem.eql(u8, which, "on")) .on else if (std.mem.eql(u8, which, "ended")) .{ .ended = try wire.parseDec(it.next() orelse "", std.math.maxInt(u63)) } else return error.Bad;
            if (it.next() != null) return error.Bad;
            s.kept.board.hold = .{ .leashed = .{ .dog = dog, .drag = drag } };
        }
    }
    s.kept.board.laid = @intCast(try wire.parseDec(try after(lines.next(), "laid "), std.math.maxInt(u32)));
    var text = lines.next() orelse return error.Bad;
    while (true) : (text = lines.next() orelse return error.Bad) {
        const line = wire.parse(s.kept.board.geometry(), text) catch break;
        const in = wire.human(line) orelse return error.Bad;
        if (in.tick != s.kept.tick + 1 or s.kept.pending_len == physics.most_humans) return error.Bad;
        s.kept.pending[s.kept.pending_len] = in.h;
        s.kept.pending_len += 1;
    }
    for (physics.ranked, 0..) |c, i| {
        if (i > 0) text = lines.next() orelse return error.Bad;
        var e = wire.Entries.of(s.kept.board.geometry(), text);
        const one = (try e.next()) orelse return error.Bad;
        if (one != .critter or !one.critter.who.eql(c) or try e.next() != null) return error.Bad;
        s.kept.board.place(c, one.critter.at);
        if (c.kind == physics.leashed_kind) s.kept.board.walked[c.n] = one.critter.walked;
    }
    // The poops, by rising number, then `end`.
    s.kept.board.poop_known = @splat(.absent);
    var last: ?u16 = null;
    while (true) {
        text = lines.next() orelse return error.Bad;
        if (std.mem.eql(u8, text, "end")) break;
        var e = wire.Entries.of(s.kept.board.geometry(), text);
        const one = (try e.next()) orelse return error.Bad;
        if (one != .poop or try e.next() != null) return error.Bad;
        if (last != null and one.poop.n <= last.?) return error.Bad;
        last = one.poop.n;
        s.kept.board.poops[one.poop.n] = one.poop.at;
        s.kept.board.poop_known[one.poop.n] = .present;
    }
    if (lines.next() != null) return error.Bad;
    return s;
}

fn after(line: ?[]const u8, word: []const u8) ![]const u8 {
    const l = line orelse return error.Bad;
    if (!std.mem.startsWith(u8, l, word)) return error.Bad;
    return l[word.len..];
}
