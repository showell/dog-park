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
const jump = @import("physics_jump.zig");
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
                const line = wire.parse(text) catch return error.CorruptLog;
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
        const line = wire.parse(text) catch return error.CorruptLog;
        switch (line) {
            .header, .view, .held => {},
            .from => |f| if (f.tick != kept.tick) return error.LogDoesNotApply,
            .critter => |c| {
                if (open == null) return error.CorruptLog;
                try moveAsWritten(&kept.board, c);
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
/// header, its `from`, and every line of the ticks before `t`.
pub fn keptPrefix(report: []const u8, t: Tick) []const u8 {
    var lines: wire.Lines = .{ .rest = report };
    var at: usize = 0;
    while (true) {
        const before = lines.rest;
        const text = lines.next() orelse break;
        const line = wire.parse(text) catch break;
        const tick: ?Tick = switch (line) {
            .header, .from, .critter => null,
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

/// **THE PARK ON LOAD**, once, on a board never resolved: the leashed dog
/// (if any) clamped into the world, then in rank order each critter that
/// overlaps one above it, or sticks out of the world, jumps to the nearest
/// spot clear of everyone. The moves go to `out` as critter lines.
pub fn resolve(b: *Board, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !Resolution {
    const leashed = b.leashedDog();
    var moved: usize = 0;
    if (leashed) |l| {
        const p = b.dogs[l];
        const h = physics.dog_half;
        const q: physics.Point = .{ .x = std.math.clamp(p.x, h, physics.world - h), .y = std.math.clamp(p.y, h, physics.world - h) };
        if (q.x != p.x or q.y != p.y) {
            try writeMove(out, alloc, .{ .who = .dog(l), .before = p, .after = q });
            b.dogs[l] = q;
            moved += 1;
        }
    }
    var order: [physics.critter_count]Critter = undefined;
    var n: usize = 0;
    for (0..physics.cow_count) |i| {
        order[n] = .cow(@intCast(i));
        n += 1;
    }
    for (0..physics.dog_count) |i| {
        if (leashed != null and leashed.? == i) continue;
        order[n] = .dog(@intCast(i));
        n += 1;
    }
    if (leashed) |l| {
        // Nothing outranks it: it is the first above every other.
        std.mem.copyBackwards(Critter, order[1 .. n + 1], order[0..n]);
        order[0] = .dog(l);
        n += 1;
    }
    for (order[0..n], 0..) |c, i| {
        if (i == 0 and leashed != null) continue;
        if (b.known(c) != .present) continue;
        const p = b.at(c);
        const half = c.half();
        var clash = !physics.world_rect.holds(physics.Rect.square(p, half));
        if (!clash) for (order[0..i]) |o| {
            if (b.known(o) == .present and physics.squaresOverlap(p, half, b.at(o), o.half())) {
                clash = true;
                break;
            }
        };
        if (!clash) continue;
        var obs: jump.Obstacles = .{};
        for (order[0..n]) |o| {
            if (o.eql(c) or b.known(o) != .present) continue;
            obs.add(physics.Rect.square(b.at(o), o.half()), 2 * physics.rank(leashed, o));
        }
        const spot = jump.nearestSpot(p, half, obs.slice(), physics.world_rect) orelse return .{ .nowhere = c };
        try writeMove(out, alloc, .{ .who = c, .before = p, .after = spot });
        b.put(c, spot);
        moved += 1;
    }
    return .{ .resolved = moved };
}

fn writeMove(out: *std.ArrayList(u8), alloc: std.mem.Allocator, c: physics.CritterLine) !void {
    var buf: [128]u8 = undefined;
    var w: wire.Text = .{ .buf = &buf };
    try wire.write(&w, .{ .critter = c });
    try out.appendSlice(alloc, w.bytes());
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
/// first: positions only), `end` last.
pub fn writeSnapshot(alloc: std.mem.Allocator, s: *const Snapshot) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    var hash: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&hash, "{x:0>8}", .{s.physics}) catch unreachable;
    try w.print("dogpark snapshot 1\nphysics {s}\nstarted {d}\nlog {d} {d}\nkept {d}\n", .{ &hash, s.started, s.log_started, s.log_offset, s.kept.tick });
    switch (s.kept.board.hold) {
        .none => try w.writeAll("hold none\n"),
        .leashed => |l| switch (l.drag) {
            .on => try w.print("hold {d} drag on\n", .{l.dog}),
            .ended => |e| try w.print("hold {d} drag ended {d}\n", .{ l.dog, e }),
        },
    }
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
    for (0..physics.cow_count) |i| try position(w, &s.kept.board, .cow(@intCast(i)));
    for (0..physics.dog_count) |i| try position(w, &s.kept.board, .dog(@intCast(i)));
    try w.writeAll("end\n");
    return out.toOwnedSlice();
}

fn position(w: *std.Io.Writer, b: *const Board, c: Critter) !void {
    var buf: [64]u8 = undefined;
    var t: wire.Text = .{ .buf = &buf };
    t.critter(c) catch unreachable;
    t.char(' ') catch unreachable;
    t.pos(b.at(c)) catch unreachable;
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
    if (!std.mem.eql(u8, lines.next() orelse "", "dogpark snapshot 1")) return error.Bad;
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
            const dog: u16 = @intCast(try wire.parseDec(it.next() orelse "", physics.dog_count - 1));
            if (!std.mem.eql(u8, it.next() orelse "", "drag")) return error.Bad;
            const which = it.next() orelse "";
            const drag: physics.Drag = if (std.mem.eql(u8, which, "on")) .on else if (std.mem.eql(u8, which, "ended")) .{ .ended = try wire.parseDec(it.next() orelse "", std.math.maxInt(u63)) } else return error.Bad;
            if (it.next() != null) return error.Bad;
            s.kept.board.hold = .{ .leashed = .{ .dog = dog, .drag = drag } };
        }
    }
    var text = lines.next() orelse return error.Bad;
    while (true) : (text = lines.next() orelse return error.Bad) {
        const line = wire.parse(text) catch break;
        const in = wire.human(line) orelse return error.Bad;
        if (in.tick != s.kept.tick + 1 or s.kept.pending_len == physics.most_humans) return error.Bad;
        s.kept.pending[s.kept.pending_len] = in.h;
        s.kept.pending_len += 1;
    }
    var expect: [physics.critter_count]Critter = undefined;
    for (0..physics.cow_count) |i| expect[i] = .cow(@intCast(i));
    for (0..physics.dog_count) |i| expect[physics.cow_count + i] = .dog(@intCast(i));
    for (expect, 0..) |c, i| {
        if (i > 0) text = lines.next() orelse return error.Bad;
        var it = std.mem.splitScalar(u8, text, ' ');
        const kind = it.next() orelse "";
        const n = it.next() orelse "";
        const parsed = try parseCritterWords(kind, n);
        if (!parsed.eql(c)) return error.Bad;
        s.kept.board.place(c, try wire.parsePos(it.next() orelse ""));
        if (it.next() != null) return error.Bad;
    }
    if (!std.mem.eql(u8, lines.next() orelse "", "end") or lines.next() != null) return error.Bad;
    return s;
}

fn parseCritterWords(kind: []const u8, n: []const u8) !Critter {
    if (std.mem.eql(u8, kind, "dog")) return .dog(@intCast(try wire.parseDec(n, physics.dog_count - 1)));
    if (std.mem.eql(u8, kind, "cow")) return .cow(@intCast(try wire.parseDec(n, physics.cow_count - 1)));
    return error.Bad;
}

fn after(line: ?[]const u8, word: []const u8) ![]const u8 {
    const l = line orelse return error.Bad;
    if (!std.mem.startsWith(u8, l, word)) return error.Bad;
    return l[word.len..];
}
