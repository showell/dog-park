//! **THE SERVER'S RE-RUN** of one report (docs/PHYSICS.md, "The server's
//! answers"): from its board at the last kept tick, it plays the report's
//! inputs and ticks with the same compiled physics the page ran, compares
//! every checked line by its parsed integers, and writes the answer:
//! `kept T`, or `kept T-1` and `differ T ...` with the `state`, `input`
//! and `board` lines.
//!
//! **What this is not:** the request numbers, epochs, stored answers, the
//! breaker, `stuck` and `tile` lines are the server's protocol, around this
//! (physics_server.zig). The header's `req` is echoed; its language and
//! physics hash are checked; its epoch is the caller's business. The tiles
//! sent this epoch and those named in a kept `held` ride in `Kept`, so a
//! `held` naming a tile never sent is refused here, and a `differ` forgets
//! a `held` it didn't keep.

const std = @import("std");
const physics = @import("physics.zig");
const wire = @import("physics_wire.zig");
const tiles = @import("tiles.zig");
const Text = wire.Text;
const Tick = physics.Tick;

/// What the server keeps between reports.
pub const Kept = struct {
    /// The last kept tick, K.
    tick: Tick,
    /// The board at the end of K.
    board: physics.Board,
    /// The view in effect, and the held tiles (any kept for K + 1
    /// included: they are never the physics' business, and the `state`
    /// line carries them).
    view: View = .{},
    held: wire.TileSet = .{},
    /// The human's inputs an earlier request kept for K + 1, in order.
    pending: [physics.most_humans]physics.Human = undefined,
    pending_len: usize = 0,
    /// The tiles whose critters went out this epoch (`tile` lines): a
    /// `held` may name only these.
    sent: Tiles = .{},
    /// The tiles named in a kept `held` this epoch: never sent again.
    named: Tiles = .{},

    pub const View = struct { w: u64 = 0, h: u64 = 0, tiles: wire.TileSet = .{} };

    pub fn pendingSlice(self: *const Kept) []const physics.Human {
        return self.pending[0..self.pending_len];
    }
};

/// A set of a world's tiles, one bit each, sized by the room (any level's
/// tile is one of the room's).
pub const Tiles = struct {
    bits: std.StaticBitSet(tiles.room_tiles * tiles.room_tiles) = .initEmpty(),

    fn index(t: tiles.Tile) usize {
        return @as(usize, @intCast(t.row)) * tiles.room_tiles + @as(usize, @intCast(t.col));
    }
    pub fn holds(self: *const Tiles, t: tiles.Tile) bool {
        return self.bits.isSet(index(t));
    }
    pub fn add(self: *Tiles, t: tiles.Tile) void {
        self.bits.set(index(t));
    }
};

/// Every overlap the re-run left among the critters the physics sees, per
/// kept tick: findings for the log, never a refutation.
pub const Findings = struct {
    overlaps: usize = 0,
    /// A `drag` on a tick with no drag on: ignored, and noted.
    idle_drags: usize = 0,
};

/// The judge's verdict, besides the answer's text.
pub const Verdict = enum { kept, differ, reload, unreadable };

/// **JUDGES A REPORT** against `kept`, which moves to the last kept tick;
/// the answer goes to `out`.
pub fn judge(kept: *Kept, physics_hash: u32, report: []const u8, out: *Text, findings: *Findings) Text.Error!Verdict {
    var lines: wire.Lines = .{ .rest = report };
    // Every position and tile is bounded by the kept board's level's world.
    const g = kept.board.geometry();
    const header = blk: {
        const first = lines.next() orelse break :blk null;
        const parsed = wire.parse(g, first) catch break :blk null;
        break :blk switch (parsed) {
            .header => |h| h,
            else => null,
        };
    } orelse {
        try out.str("req ?\n");
        return .unreadable;
    };
    try out.str("req ");
    try out.dec(header.req);
    try out.char('\n');
    if (header.language != wire.language) {
        try out.str("reload language ");
        try out.dec(wire.language);
        try out.char('\n');
        return .reload;
    }
    if (header.physics != physics_hash) {
        try out.str("reload physics ");
        try out.hash(physics_hash);
        try out.char('\n');
        return .reload;
    }
    const from: ?wire.From = blk: {
        const second = lines.next() orelse break :blk null;
        const parsed = wire.parse(g, second) catch break :blk null;
        break :blk switch (parsed) {
            .from => |f| f,
            else => null,
        };
    };
    if (from == null or from.?.tick != kept.tick) {
        try out.str("reload from ");
        try out.dec(kept.tick);
        try out.char('\n');
        return .reload;
    }
    var named = namedIn(g, lines);
    var run: Run = .{ .kept = kept, .from = kept.tick, .lines = lines, .findings = findings };
    const differ = run.all();
    if (differ) |d| {
        try out.str("kept ");
        try out.dec(d.tick - 1);
        try out.char('\n');
        try out.str("differ ");
        try out.dec(d.tick);
        try out.char(' ');
        switch (d.says) {
            .server => |line| try quote(out, line),
            .none => |text| {
                try out.str("none ");
                try out.str(if (text.len > 0 and text[0] == ' ') text[1..] else text);
            },
        }
        try out.char('\n');
        try writeState(out, kept, d.tick, &named);
        return .differ;
    }
    try out.str("kept ");
    try out.dec(kept.tick);
    try out.char('\n');
    return .kept;
}

/// A line as `differ` quotes it: a critter line unindented.
fn quote(out: *Text, line: wire.Line) Text.Error!void {
    switch (line) {
        .critter => |c| try wire.critterMove(out, c),
        .poop => |p| try wire.poopAt(out, p.n, p.at),
        .eaten => |n| {
            try out.str("eaten ");
            try out.dec(n);
        },
        else => {
            var buf: [1024]u8 = undefined;
            var w: Text = .{ .buf = &buf };
            try wire.write(&w, line);
            try out.str(w.bytes()[0 .. w.len - 1]);
        },
    }
}

/// The critters a report names in its critter lines.
const Named = struct {
    marks: [physics.critter_count]Mark = @splat(.unnamed),

    const Mark = enum { unnamed, named };

    fn has(self: *const Named, c: physics.Critter) bool {
        return self.marks[physics.critterIndex(c)] == .named;
    }
    fn name(self: *Named, c: physics.Critter) void {
        self.marks[physics.critterIndex(c)] = .named;
    }
};

fn namedIn(g: physics.Geometry, lines: wire.Lines) Named {
    var n: Named = .{};
    var it = lines;
    while (it.next()) |text| {
        const line = wire.parse(g, text) catch continue;
        switch (line) {
            .critter => |c| n.name(c.who),
            else => {},
        }
    }
    return n;
}

/// A refused report as a whole (its header: a reused request number with
/// another body, or one out of order): `kept K`, `differ K+1 none` the
/// header line, the state, inputs and board at K + 1.
pub fn refuseWhole(kept: *const Kept, report: []const u8, out: *Text) Text.Error!void {
    var lines: wire.Lines = .{ .rest = report };
    const header = lines.next() orelse "";
    const named = namedIn(kept.board.geometry(), lines);
    try out.str("kept ");
    try out.dec(kept.tick);
    try out.str("\ndiffer ");
    try out.dec(kept.tick + 1);
    try out.str(" none ");
    try out.str(header);
    try out.char('\n');
    try writeState(out, kept, kept.tick + 1, &named);
}

/// After `differ T`: the `state` at the start of T before its inputs, the
/// `input` lines kept earlier for T, and the `board`.
fn writeState(out: *Text, kept: *const Kept, t: Tick, named: *const Named) Text.Error!void {
    try stateAndInputs(out, kept, t);
    try writeBoard(out, kept, t, named);
}

/// The `state` line and the `input` lines kept for `t`: a `differ`'s, and a
/// load's (with no board).
pub fn stateAndInputs(out: *Text, kept: *const Kept, t: Tick) Text.Error!void {
    const b = &kept.board;
    try out.str("state leash ");
    switch (b.hold) {
        .none => try out.str("none drag none"),
        .leashed => |l| {
            try out.dec(l.dog);
            switch (l.drag) {
                .on => try out.str(" drag on"),
                .ended => |e| {
                    try out.str(" drag ended ");
                    try out.dec(e);
                },
            }
        },
    }
    try out.str(" laid ");
    try out.dec(b.laid);
    try out.str(" view ");
    try out.dec(kept.view.w);
    try out.char('x');
    try out.dec(kept.view.h);
    try out.tileList(kept.view.tiles.sorted().slice());
    try out.str(" held");
    try out.tileList(kept.held.sorted().slice());
    try out.char('\n');
    for (kept.pendingSlice()) |h| {
        try out.str("input ");
        try wire.write(out, switch (h) {
            .leash => |d| .{ .leash = .{ .tick = t, .dog = d } },
            .release => |d| .{ .release = .{ .tick = t, .dog = d } },
            .grab => .{ .grab = t },
            .letgo => .{ .letgo = t },
        });
    }
}

fn writeBoard(out: *Text, kept: *const Kept, t: Tick, named: *const Named) Text.Error!void {
    const b = &kept.board;
    // The board: every critter awake at the start of T, and every one the
    // report named, in rank order.
    var board = kept.board;
    var awake: Named = .{};
    // A scene lists poop slots by the thousand: `scene` keeps it off the
    // stack.
    const sc: ?*const physics.Scene = if (scene.init(&board)) &scene else null;
    if (sc) |s| for (s.list()) |one| awake.name(one.who);
    try out.str("board ");
    try out.dec(t);
    const leashed = b.leashedDog();
    if (leashed) |l| try boardEntry(out, b, .of(physics.leashed_kind, l));
    for (physics.ranked) |c| {
        if (leashed != null and c.kind == physics.leashed_kind and leashed.? == c.n) continue;
        if (b.known(c) == .present and (awake.has(c) or named.has(c))) try boardEntry(out, b, c);
    }
    // Every poop in the region's tiles, by number: the page drops its
    // others there.
    if (sc) |s| {
        var listed = s.poop_listed;
        var it = listed.iterator(.{});
        while (it.next()) |n| {
            try out.char(' ');
            try wire.poopAt(out, @intCast(n), b.poops[n]);
        }
    }
    try out.char('\n');
}

/// The scene `writeBoard` looks through.
var scene: physics.Scene = undefined;

fn boardEntry(out: *Text, b: *const physics.Board, c: physics.Critter) Text.Error!void {
    try out.char(' ');
    try wire.entry(out, b, c);
}

/// Where the re-run first disagrees: the server's own line, or `none` and
/// the report's.
const Differ = struct {
    tick: Tick,
    says: union(enum) { server: wire.Line, none: []const u8 },
};

const Run = struct {
    kept: *Kept,
    /// The report's `from`: ticks run to `from` + 32, inputs to `from` + 33.
    from: Tick,
    lines: wire.Lines,
    findings: *Findings,
    /// A line read and not yet used.
    peeked: ?[]const u8 = null,
    /// Each tick's checked lines, the server's: one for the report, as
    /// `physics.run` starts each tick's afresh (its `len`, `jumped` and
    /// `pair_checks`), not a 10 KB value made and zeroed every tick (202).
    tick_lines: physics.Lines = undefined,

    fn next(self: *Run) ?[]const u8 {
        if (self.peeked) |p| {
            self.peeked = null;
            return p;
        }
        return self.lines.next();
    }

    /// Every tick of the report, in order; null when all of it is kept.
    fn all(self: *Run) ?Differ {
        while (true) {
            const t = self.kept.tick + 1;
            const start = self.kept.*;
            const got = self.one(t);
            switch (got) {
                .ran => {},
                .end => |e| {
                    // Inputs for `t` with no `t` line wait for it: the board
                    // stays at the end of K; the view and held tiles stand.
                    const view = self.kept.view;
                    const held = self.kept.held;
                    const named = self.kept.named;
                    self.kept.* = start;
                    self.kept.view = view;
                    self.kept.held = held;
                    self.kept.named = named;
                    for (e.slice()) |h| {
                        self.kept.pending[self.kept.pending_len] = h;
                        self.kept.pending_len += 1;
                    }
                    return null;
                },
                .differ => |d| {
                    self.kept.* = start;
                    return d;
                },
            }
        }
    }

    const Waiting = struct {
        list: [physics.most_humans]physics.Human = undefined,
        len: usize = 0,

        fn slice(self: *const Waiting) []const physics.Human {
            return self.list[0..self.len];
        }
    };

    const One = union(enum) { ran, end: Waiting, differ: Differ };

    /// Tick `t`: its inputs, then its `t` line and checked lines; or the
    /// end, keeping inputs that wait for `t`.
    fn one(self: *Run, t: Tick) One {
        const k = self.kept;
        const from = self.from;
        var begun: physics.Begun = .{};
        for (k.pendingSlice()) |h| {
            // Kept already: never refused now.
            _ = physics.input(&k.board, &begun, h);
        }
        var waiting: Waiting = .{};
        while (self.next()) |text| {
            const line = wire.parse(k.board.geometry(), text) catch return refuse(t, text);
            switch (line) {
                .leash, .release, .grab, .letgo => {
                    const in = wire.human(line).?;
                    if (in.tick != t or t > from + physics.most_ticks + 1) return refuse(t, text);
                    if (physics.input(&k.board, &begun, in.h) != null) return refuse(t, text);
                    waiting.list[waiting.len] = in.h;
                    waiting.len += 1;
                },
                .view => |v| {
                    if (v.tick != t or t > from + physics.most_ticks + 1) return refuse(t, text);
                    k.view = .{ .w = v.w, .h = v.h, .tiles = v.tiles };
                    var still: wire.TileSet = .{};
                    for (k.held.slice()) |h| if (v.tiles.holds(h)) still.add(h) catch unreachable;
                    k.held = still;
                },
                .held => |h| {
                    if (h.tick != t or t > from + physics.most_ticks + 1) return refuse(t, text);
                    for (h.tiles.slice()) |tile| {
                        if (!k.view.tiles.holds(tile) or !k.sent.holds(tile)) return refuse(t, text);
                    }
                    for (h.tiles.slice()) |tile| {
                        k.held.add(tile) catch return refuse(t, text);
                        k.named.add(tile);
                    }
                },
                .t => |tl| {
                    if (tl.tick != t or t > from + physics.most_ticks) return refuse(t, text);
                    if (!physics.withinCap(tl.drag.slice())) return refuse(t, text);
                    if (!self.regionHeld()) return refuse(t, text);
                    const lines = &self.tick_lines;
                    const drag_on = k.board.hold == .leashed and k.board.hold.leashed.drag == .on;
                    if (tl.drag.len > 0 and !drag_on) self.findings.idle_drags += 1;
                    physics.run(&k.board, t, begun, tl.drag.slice(), lines);
                    if (self.compare(t, lines)) |d| return .{ .differ = d };
                    k.tick = t;
                    k.pending_len = 0;
                    var pairs: [1][2]physics.Critter = undefined;
                    self.findings.overlaps += physics.overlaps(&k.board, &pairs);
                    return .ran;
                },
                else => return refuse(t, text),
            }
        }
        return .{ .end = waiting };
    }

    /// Whether every tile meeting the tick's region is held.
    fn regionHeld(self: *Run) bool {
        const k = self.kept;
        const l = k.board.leashedDog() orelse return true;
        const g = k.board.geometry();
        const span = physics.TileSpan.of(g, g.region(k.board.of(physics.leashed_kind)[l]));
        var row = span.row_lo;
        while (row <= span.row_hi) : (row += 1) {
            var col = span.col_lo;
            while (col <= span.col_hi) : (col += 1) {
                if (!k.held.holds(g.tileAt(col, row))) return false;
            }
        }
        return true;
    }

    /// The report's checked lines for `t` against the server's.
    fn compare(self: *Run, t: Tick, server: *const physics.Lines) ?Differ {
        for (server.slice()) |c| {
            const mine = wire.checkedLine(t, c);
            const text = self.next() orelse return .{ .tick = t, .says = .{ .server = mine } };
            const theirs = wire.parse(self.kept.board.geometry(), text) catch {
                self.peeked = text;
                return .{ .tick = t, .says = .{ .server = mine } };
            };
            if (!isChecked(theirs, t) or !wire.same(mine, theirs)) {
                self.peeked = text;
                return .{ .tick = t, .says = .{ .server = mine } };
            }
        }
        if (self.next()) |text| {
            const theirs = wire.parse(self.kept.board.geometry(), text) catch {
                // A malformed line that can only be one of this tick's is
                // refused here; any other is the next tick's to refuse.
                if (std.mem.startsWith(u8, text, " ") or std.mem.startsWith(u8, text, "bump ") or std.mem.startsWith(u8, text, "rest ")) return refuse(t, text).differ;
                self.peeked = text;
                return null;
            };
            if (isChecked(theirs, t)) return .{ .tick = t, .says = .{ .none = text } };
            self.peeked = text;
        }
        return null;
    }
};

/// Whether a line is one of tick `t`'s checked lines (a `release` at the
/// next tick is an input).
fn isChecked(line: wire.Line, t: Tick) bool {
    return switch (line) {
        .critter, .poop, .eaten, .bump, .rest => true,
        .release => |r| r.tick == t,
        else => false,
    };
}

fn refuse(t: Tick, text: []const u8) Run.One {
    return .{ .differ = .{ .tick = t, .says = .{ .none = text } } };
}

test {
    _ = @import("physics_judge_test.zig");
}
