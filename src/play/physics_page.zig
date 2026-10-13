//! **THE PHYSICS ON THE PAGE** (`physics.wasm`, docs/PHYSICS.md): the
//! board, the tick and the report's text, compiled to wasm32 from the same
//! sources the server judges with, behind exports the page's engine
//! (solo/engine.js) calls. The engine keeps the record (what the human did,
//! tick by tick) and the protocol; this keeps the boards and writes every
//! line, so the page's JavaScript never formats a number on the wire.
//!
//! **THREE BOARDS:** `live` (0), the one the page ticks and draws;
//! `kept` (1), the board at the last tick the server kept, moved forward on
//! each `kept` by replaying the ticks it kept; and `scratch` (2), for a
//! tick tried before it is taken (a replay's lost bump). A rewind copies
//! `kept` into `live` and replays.
//!
//! **MEMORY THE PAGE SHARES:** `inBuf` (an answer's line, written by the
//! page), `outBuf` (a line or lines, written here; each writer starts it
//! afresh and answers its length), `ints` (numbers both ways: a drag's
//! displacements, tile lists, what an answer line said), and each board's
//! critters (`dogsAt`, `dogKnown`, `cowsAt`, `cowKnown`: x, y pairs of
//! `i32` in 256ths, and one byte each, 1 when the board has it).
//!
//! Ticks cross as `f64` (JavaScript's numbers; a tick fits in 2^53).

const std = @import("std");
const physics = @import("physics.zig");
const wire = @import("physics_wire.zig");
const tiles = @import("tiles.zig");
const Text = wire.Text;
const Tick = physics.Tick;

const board_count = 3;
pub const live = 0;
pub const kept = 1;
pub const scratch = 2;

var boards: [board_count]physics.Board = @splat(physics.Board.empty());
var begun: [board_count]physics.Begun = @splat(.{});

var in_buf: [64 * 1024]u8 = undefined;
var out_buf: [96 * 1024]u8 = undefined;
/// Room for 4096 displacements (dx, dy, ms), or a `state` line's two tile
/// lists.
var ints_buf: [3 * 4096]i32 = undefined;
/// A tick an answer line named (a `board` line's, an `input` line's).
var line_tick: Tick = 0;
/// The last tick's flags and its displacements as merged and capped.
var flags: u32 = 0;
var capped_len: u32 = 0;
/// The last tick's jumpers, one byte a critter (dogs, then cows): 1 for a
/// critter that jumped (out from under, or a push's nearest spot).
var jumped: [physics.critter_count]u8 = @splat(0);

pub const Flag = struct {
    pub const bump: u32 = 1;
    pub const rest: u32 = 2;
    pub const release: u32 = 4;
    pub const moved: u32 = 8;
};

fn board(b: u32) *physics.Board {
    return &boards[b];
}

fn tickOf(t: f64) Tick {
    return @intFromFloat(t);
}

// ── memory ──────────────────────────────────────────────────────────────────

export fn physicsHash() u32 {
    return wire.physics_hash;
}
/// The physics' clock: the page ticks every 1000 / this ms.
export fn ticksPerSecond() u32 {
    return physics.ticks_per_second;
}
export fn inBuf() [*]u8 {
    return &in_buf;
}
export fn inCap() u32 {
    return in_buf.len;
}
export fn outBuf() [*]u8 {
    return &out_buf;
}
export fn ints() [*]i32 {
    return &ints_buf;
}
export fn intsCap() u32 {
    return ints_buf.len;
}
export fn dogCount() u32 {
    return physics.dog_count;
}
export fn cowCount() u32 {
    return physics.cow_count;
}
export fn dogsAt(b: u32) [*]i32 {
    return @ptrCast(&board(b).dogs);
}
export fn dogKnown(b: u32) [*]u8 {
    return @ptrCast(&board(b).dog_known);
}
export fn cowsAt(b: u32) [*]i32 {
    return @ptrCast(&board(b).cows);
}
export fn cowKnown(b: u32) [*]u8 {
    return @ptrCast(&board(b).cow_known);
}

// ── the boards ──────────────────────────────────────────────────────────────

/// A page load: every board empty, nothing leashed.
export fn reset() void {
    boards = @splat(physics.Board.empty());
    begun = @splat(.{});
}

/// Board `to` becomes a copy of board `from`, the inputs begun on it
/// included (a tick tried on `scratch` is the tick `live` would run).
export fn copyBoard(from: u32, to: u32) void {
    boards[to] = boards[from];
    begun[to] = begun[from];
}

/// The inputs begun on a board are forgotten (its next tick has none yet).
export fn clearBegun(b: u32) void {
    begun[b] = .{};
}

/// The leashed dog, or -1.
export fn leashedDog(b: u32) i32 {
    return if (board(b).leashedDog()) |d| d else -1;
}

/// The drag: -1 with nothing leashed, -2 while it is on, or the tick it
/// ended.
export fn dragOf(b: u32) f64 {
    return switch (board(b).hold) {
        .none => -1,
        .leashed => |l| switch (l.drag) {
            .on => -2,
            .ended => |e| @floatFromInt(e),
        },
    };
}

/// The tiles meeting the region around the board's leashed dog, as it
/// stands (after any inputs begun), into `ints` as col, row pairs; their
/// count, 0 with nothing leashed.
export fn regionTiles(b: u32) u32 {
    const l = board(b).leashedDog() orelse return 0;
    const span = physics.TileSpan.of(physics.region(board(b).dogs[l]));
    var n: u32 = 0;
    var row = span.row_lo;
    while (row <= span.row_hi) : (row += 1) {
        var col = span.col_lo;
        while (col <= span.col_hi) : (col += 1) {
            ints_buf[2 * n] = col;
            ints_buf[2 * n + 1] = row;
            n += 1;
        }
    }
    return n;
}

// ── writing ─────────────────────────────────────────────────────────────────

fn out() Text {
    return .{ .buf = &out_buf };
}

/// `dogpark 1 physics H load WxH`.
export fn writeLoad(w: u32, h: u32) u32 {
    var t = out();
    t.str("dogpark ") catch unreachable;
    t.dec(wire.language) catch unreachable;
    t.str(" physics ") catch unreachable;
    t.hash(wire.physics_hash) catch unreachable;
    t.str(" load ") catch unreachable;
    t.dec(w) catch unreachable;
    t.char('x') catch unreachable;
    t.dec(h) catch unreachable;
    t.char('\n') catch unreachable;
    return @intCast(t.len);
}

/// A report's header and `from` line; `wall` below 0 for none (a report
/// with no ticks).
export fn writeHeader(epoch_ms: f64, epoch_count: f64, req: f64, from: f64, wall: f64) u32 {
    var t = out();
    wire.write(&t, .{ .header = .{ .language = wire.language, .physics = wire.physics_hash, .epoch = .{ .ms = tickOf(epoch_ms), .count = tickOf(epoch_count) }, .req = tickOf(req) } }) catch unreachable;
    wire.write(&t, .{ .from = .{ .tick = tickOf(from), .wall = if (wall < 0) null else tickOf(wall) } }) catch unreachable;
    return @intCast(t.len);
}

/// The human's kinds of input, as the page names them.
pub const HumanKind = enum(u32) { release = 0, leash = 1, grab = 2, letgo = 3 };

fn humanOf(kind: u32, dog: u32) physics.Human {
    return switch (@as(HumanKind, @enumFromInt(kind))) {
        .release => .{ .release = @intCast(dog) },
        .leash => .{ .leash = @intCast(dog) },
        .grab => .grab,
        .letgo => .letgo,
    };
}

/// **ONE OF THE HUMAN'S INPUTS** at tick `t`, applied to board `b` (its
/// next tick's inputs begun) and written: the line's length, or -1 less the
/// refusal (physics.Refusal) when its precondition fails, the board
/// unchanged.
export fn human(b: u32, kind: u32, t: f64, dog: u32) i32 {
    const h = humanOf(kind, dog);
    if (h != .grab and h != .letgo and dog >= physics.dog_count) return -1 - @as(i32, @intFromEnum(physics.Refusal.leash_no_such_dog));
    if (physics.input(board(b), &begun[b], h)) |r| return -1 - @as(i32, @intFromEnum(r));
    var w = out();
    const at: Tick = tickOf(t);
    wire.write(&w, switch (h) {
        .release => |d| .{ .release = .{ .tick = at, .dog = d } },
        .leash => |d| .{ .leash = .{ .tick = at, .dog = d } },
        .grab => .{ .grab = at },
        .letgo => .{ .letgo = at },
    }) catch unreachable;
    return @intCast(w.len);
}

/// The first `n` col, row pairs in `ints` as a tile set (in the world, at
/// most 64; a repeat is dropped).
fn tileSet(from: usize, n: u32) ?wire.TileSet {
    var s: wire.TileSet = .{};
    for (0..n) |i| {
        const col = ints_buf[from + 2 * i];
        const row = ints_buf[from + 2 * i + 1];
        if (col < 0 or row < 0 or col >= tiles.world_tiles or row >= tiles.world_tiles) return null;
        s.add(.{ .col = col, .row = row }) catch return null;
    }
    return s;
}

/// `view T WxH c,r …`, the tiles the first `n` pairs in `ints`; 0 when they
/// are not a tile set the wire takes.
export fn writeView(t: f64, w: u32, h: u32, n: u32) u32 {
    const set = tileSet(0, n) orelse return 0;
    var o = out();
    wire.write(&o, .{ .view = .{ .tick = tickOf(t), .w = w, .h = h, .tiles = set } }) catch unreachable;
    return @intCast(o.len);
}

/// `held T c,r …`, as `writeView`.
export fn writeHeld(t: f64, n: u32) u32 {
    const set = tileSet(0, n) orelse return 0;
    var o = out();
    wire.write(&o, .{ .held = .{ .tick = tickOf(t), .tiles = set } }) catch unreachable;
    return @intCast(o.len);
}

/// The displacements in `ints`, `n` triples (dx, dy in 256ths, `@ms`).
var raw_disps: [4096]physics.Disp = undefined;

fn disps(n: u32) physics.Capped {
    const raw = &raw_disps;
    const m = @min(n, raw.len);
    for (0..m) |i| raw[i] = .{ .dx = ints_buf[3 * i], .dy = ints_buf[3 * i + 1], .ms = @intCast(@max(0, ints_buf[3 * i + 2])) };
    return physics.mergeAndCap(raw[0..m]);
}

/// **ONE TICK** on board `b`: its inputs are those begun; the drag is the
/// `n` displacements in `ints` (dx, dy, ms triples, as the pointer made
/// them), merged and capped here (items 2 and 3) and written back to
/// `ints` as the report carries them (`cappedLen` of them). Writes the
/// tick's checked lines (not its `t` line: `writeT`, when the report goes)
/// and answers their length; `tickFlags` says what happened.
export fn tick(b: u32, t: f64, n: u32) u32 {
    const drag = disps(n);
    var lines: physics.Lines = .{};
    const tk = tickOf(t);
    physics.run(board(b), tk, begun[b], drag.slice(), &lines);
    begun[b] = .{};
    for (&jumped, 0..) |*j, i| j.* = @intFromBool(lines.jumped.isSet(i));
    flags = 0;
    var o = out();
    for (lines.slice()) |c| {
        switch (c) {
            .critter => flags |= Flag.moved,
            .bump => flags |= Flag.bump,
            .release => flags |= Flag.release,
            .rest => flags |= Flag.rest,
        }
        wire.write(&o, wire.checkedLine(tk, c)) catch unreachable;
    }
    for (drag.slice(), 0..) |d, i| {
        ints_buf[3 * i] = d.dx;
        ints_buf[3 * i + 1] = d.dy;
        ints_buf[3 * i + 2] = @intCast(d.ms);
    }
    capped_len = @intCast(drag.len);
    return @intCast(o.len);
}

export fn tickFlags() u32 {
    return flags;
}

/// The last tick's jumpers: `critterCount` bytes, dogs then cows.
export fn jumpedAt() [*]u8 {
    return &jumped;
}

export fn cappedLen() u32 {
    return capped_len;
}

/// `t T +ms drag …`, the `n` displacements in `ints` (as `tick` left them).
export fn writeT(t: f64, plus_ms: f64, n: u32) u32 {
    var drag: physics.Capped = .{};
    for (0..@min(n, physics.most_displacements)) |i| {
        drag.list[i] = .{ .dx = ints_buf[3 * i], .dy = ints_buf[3 * i + 1], .ms = @intCast(@max(0, ints_buf[3 * i + 2])) };
        drag.len = i + 1;
    }
    var o = out();
    wire.write(&o, .{ .t = .{ .tick = tickOf(t), .ms = tickOf(@max(0, plus_ms)), .drag = drag } }) catch unreachable;
    return @intCast(o.len);
}

// ── reading the server's answers ────────────────────────────────────────────

/// The words of an answer line, split on single spaces.
const Words = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    fn of(text: []const u8) Words {
        return .{ .it = std.mem.splitScalar(u8, text, ' ') };
    }
    fn next(self: *Words) ?[]const u8 {
        const w = self.it.next() orelse return null;
        return if (w.len == 0) null else w;
    }
    fn expect(self: *Words, word: []const u8) error{Malformed}!void {
        if (!std.mem.eql(u8, self.next() orelse "", word)) return error.Malformed;
    }
};

fn critterOf(kind: []const u8, n: []const u8) error{Malformed}!physics.Critter {
    if (std.mem.eql(u8, kind, "dog")) return .dog(@intCast(try wire.parseDec(n, physics.dog_count - 1)));
    if (std.mem.eql(u8, kind, "cow")) return .cow(@intCast(try wire.parseDec(n, physics.cow_count - 1)));
    return error.Malformed;
}

fn tileOf(s: []const u8) error{Malformed}!tiles.Tile {
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse return error.Malformed;
    const top = tiles.world_tiles - 1;
    return .{ .col = @intCast(try wire.parseDec(s[0..comma], top)), .row = @intCast(try wire.parseDec(s[comma + 1 ..], top)) };
}

/// The critters on the rest of a line (`dog N a cow M b …`), each handed
/// to `each`.
fn critters(w: *Words, ctx: anytype, comptime each: fn (@TypeOf(ctx), physics.Critter, physics.Point) void) error{Malformed}!u32 {
    var n: u32 = 0;
    while (w.next()) |kind| {
        const c = try critterOf(kind, w.next() orelse return error.Malformed);
        const p = try wire.parsePos(w.next() orelse return error.Malformed);
        each(ctx, c, p);
        n += 1;
    }
    return n;
}

fn line(len: u32) []const u8 {
    return in_buf[0..@min(len, in_buf.len)];
}

/// **A `tile` LINE** in `inBuf`: its critters placed on every board in
/// `mask` (bit b for board b) that hasn't received them (a critter it
/// has is the page's to run, never moved by a tile sent again); the tile
/// into `ints` (col, row). Answers the critters it named, or -1.
export fn readTile(len: u32, mask: u32) i32 {
    var w = Words.of(line(len));
    return readTileWords(&w, mask) catch -1;
}

fn readTileWords(w: *Words, mask: u32) error{Malformed}!i32 {
    try w.expect("tile");
    const t = try tileOf(w.next() orelse return error.Malformed);
    ints_buf[0] = t.col;
    ints_buf[1] = t.row;
    const Ctx = struct {
        mask: u32,
        fn place(self: @This(), c: physics.Critter, p: physics.Point) void {
            for (&boards, 0..) |*b, i| {
                if (self.mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
                if (b.known(c) != .present) b.place(c, p);
            }
        }
    };
    return @intCast(try critters(w, Ctx{ .mask = mask }, Ctx.place));
}

/// **A `board T` LINE** in `inBuf`, laid over board `b`: each critter it
/// names takes the server's position. `lineTick` is T. Answers the
/// critters it named, or -1.
export fn readBoard(len: u32, b: u32) i32 {
    var w = Words.of(line(len));
    return readBoardWords(&w, b) catch -1;
}

fn readBoardWords(w: *Words, b: u32) error{Malformed}!i32 {
    try w.expect("board");
    line_tick = try wire.parseDec(w.next() orelse return error.Malformed, std.math.maxInt(u32));
    const Ctx = struct {
        b: *physics.Board,
        fn place(self: @This(), c: physics.Critter, p: physics.Point) void {
            self.b.place(c, p);
        }
    };
    return @intCast(try critters(w, Ctx{ .b = board(b) }, Ctx.place));
}

export fn lineTick() f64 {
    return @floatFromInt(line_tick);
}

/// **A `state` LINE** in `inBuf`: its leash and drag set on board `b`; its
/// view and held tiles into `ints`: w, h, the view's count and its col, row
/// pairs, then the held count and pairs. 0, or -1 when it doesn't read
/// (the board is then unchanged).
export fn readState(len: u32, b: u32) i32 {
    var w = Words.of(line(len));
    readStateWords(&w, b) catch return -1;
    return 0;
}

fn readStateWords(w: *Words, b: u32) error{Malformed}!void {
    try w.expect("state");
    try w.expect("leash");
    const who = w.next() orelse return error.Malformed;
    try w.expect("drag");
    const drag = w.next() orelse return error.Malformed;
    var hold: physics.Hold = .none;
    if (std.mem.eql(u8, who, "none")) {
        if (!std.mem.eql(u8, drag, "none")) return error.Malformed;
    } else {
        const dog: u16 = @intCast(try wire.parseDec(who, physics.dog_count - 1));
        const d: physics.Drag = if (std.mem.eql(u8, drag, "on")) .on else if (std.mem.eql(u8, drag, "ended"))
            .{ .ended = try wire.parseDec(w.next() orelse return error.Malformed, std.math.maxInt(u32)) }
        else
            return error.Malformed;
        hold = .{ .leashed = .{ .dog = dog, .drag = d } };
    }
    try w.expect("view");
    const size = w.next() orelse return error.Malformed;
    const x = std.mem.indexOfScalar(u8, size, 'x') orelse return error.Malformed;
    ints_buf[0] = @intCast(try wire.parseDec(size[0..x], 1 << 16));
    ints_buf[1] = @intCast(try wire.parseDec(size[x + 1 ..], 1 << 16));
    var at: usize = 3;
    var count_at: usize = 2;
    var n: i32 = 0;
    var in_held = false;
    while (w.next()) |word| {
        if (std.mem.eql(u8, word, "held")) {
            if (in_held) return error.Malformed;
            ints_buf[count_at] = n;
            count_at = at;
            at += 1;
            n = 0;
            in_held = true;
            continue;
        }
        if (n >= wire.most_tiles) return error.Malformed;
        const t = try tileOf(word);
        ints_buf[at] = t.col;
        ints_buf[at + 1] = t.row;
        at += 2;
        n += 1;
    }
    if (!in_held) return error.Malformed;
    ints_buf[count_at] = n;
    board(b).hold = hold;
}

/// **AN `input` LINE** in `inBuf` (`input leash T D` and the like): its
/// kind (HumanKind), its dog in `ints[0]`, its tick `lineTick`; -1 when it
/// doesn't read.
export fn readInput(len: u32) i32 {
    const text = line(len);
    if (!std.mem.startsWith(u8, text, "input ")) return -1;
    const parsed = wire.parse(text["input ".len..]) catch return -1;
    const h = wire.human(parsed) orelse return -1;
    line_tick = h.tick;
    ints_buf[0] = 0;
    return switch (h.h) {
        .release => |d| blk: {
            ints_buf[0] = d;
            break :blk @intFromEnum(HumanKind.release);
        },
        .leash => |d| blk: {
            ints_buf[0] = d;
            break :blk @intFromEnum(HumanKind.leash);
        },
        .grab => @intFromEnum(HumanKind.grab),
        .letgo => @intFromEnum(HumanKind.letgo),
    };
}

// ── tests ───────────────────────────────────────────────────────────────────

const judge = @import("physics_judge.zig");
const testing = std.testing;

fn outText(len: u32) []const u8 {
    return out_buf[0..len];
}

/// An answer line into `inBuf`, as the page writes it there.
fn putLine(text: []const u8) u32 {
    @memcpy(in_buf[0..text.len], text);
    return @intCast(text.len);
}

const the_dog: u16 = 125;

/// The page's side of a leash and `n` ticks dragging east, on the laid-out
/// board, written as one report; the judge's `Kept` ready for it (the
/// region's tiles sent, as a load's tile lines would have).
fn leashAndDrag(report: *std.ArrayList(u8), k: *judge.Kept, n: u32) !void {
    reset();
    boards[live] = physics.Board.laidOut();
    boards[kept] = boards[live];
    k.* = .{ .tick = 0, .board = physics.Board.laidOut() };
    try report.appendSlice(testing.allocator, outText(writeHeader(1791935990000, 1, 1, 0, 1791936000000)));
    try report.appendSlice(testing.allocator, outText(@intCast(human(live, @intFromEnum(HumanKind.leash), 1, the_dog))));
    const r = regionTiles(live);
    const span = physics.TileSpan.of(physics.region(boards[live].dogs[the_dog]));
    try testing.expectEqual(@as(u32, @intCast((span.col_hi - span.col_lo + 1) * (span.row_hi - span.row_lo + 1))), r);
    for (0..r) |i| k.sent.add(.{ .col = ints_buf[2 * i], .row = ints_buf[2 * i + 1] });
    try report.appendSlice(testing.allocator, outText(writeView(1, 1280, 800, r)));
    try report.appendSlice(testing.allocator, outText(writeHeld(1, r)));
    for (1..n + 1) |t| {
        ints_buf[0] = physics.px(3);
        ints_buf[1] = 0;
        ints_buf[2] = 5;
        const checked = outText(tick(live, @floatFromInt(t), 1));
        const copy = try testing.allocator.dupe(u8, checked);
        defer testing.allocator.free(copy);
        try report.appendSlice(testing.allocator, outText(writeT(@floatFromInt(t), @floatFromInt(63 * (t - 1)), cappedLen())));
        try report.appendSlice(testing.allocator, copy);
    }
}

test "the page's exports write a report the judge keeps" {
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(testing.allocator);
    const k = try testing.allocator.create(judge.Kept);
    defer testing.allocator.destroy(k);
    try leashAndDrag(&report, k, 4);
    var buf: [4096]u8 = undefined;
    var answer: Text = .{ .buf = &buf };
    var findings: judge.Findings = .{};
    try testing.expectEqual(judge.Verdict.kept, try judge.judge(k, wire.physics_hash, report.items, &answer, &findings));
    try testing.expectEqualStrings("req 1\nkept 4\n", answer.bytes());
    try testing.expectEqual(@as(f64, -2), dragOf(live));
    try testing.expectEqual(@as(i32, the_dog), leashedDog(live));
}

test "a differ's state, input and board lines read back onto a board; a tile line places only what the board hasn't" {
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(testing.allocator);
    const k = try testing.allocator.create(judge.Kept);
    defer testing.allocator.destroy(k);
    try leashAndDrag(&report, k, 3);
    // The page's dog drifted: the judge refutes the first tick.
    const moved = std.mem.indexOf(u8, report.items, " dog 125 ").?;
    const eol = std.mem.indexOfScalarPos(u8, report.items, moved, '\n').?;
    report.items[eol - 1] = if (report.items[eol - 1] == '0') '1' else '0';
    var buf: [8192]u8 = undefined;
    var answer: Text = .{ .buf = &buf };
    var findings: judge.Findings = .{};
    try testing.expectEqual(judge.Verdict.differ, try judge.judge(k, wire.physics_hash, report.items, &answer, &findings));
    var lines = std.mem.splitScalar(u8, answer.bytes(), '\n');
    try testing.expectEqualStrings("req 1", lines.next().?);
    try testing.expectEqualStrings("kept 0", lines.next().?);
    try testing.expect(std.mem.startsWith(u8, lines.next().?, "differ 1 dog 125 "));
    const state = lines.next().?;
    boards[scratch] = physics.Board.laidOut();
    try testing.expectEqual(@as(i32, 0), readState(putLine(state), scratch));
    // The state at the start of 1, before its inputs: nothing leashed, the
    // view and held of the load (none here).
    try testing.expectEqual(@as(i32, -1), leashedDog(scratch));
    try testing.expectEqual(@as(i32, 0), ints_buf[2]);
    const board_line = lines.next().?;
    try testing.expect(std.mem.startsWith(u8, board_line, "board 1"));
    boards[scratch].dogs[3] = .{ .x = 1, .y = 1 };
    try testing.expect(readBoard(putLine(board_line), scratch) >= 0);
    try testing.expectEqual(@as(f64, 1), lineTick());

    try testing.expectEqual(@as(i32, -1), readState(putLine("state leash 7 drag sideways view 0x0 held"), scratch));
    try testing.expectEqual(@as(i32, 0), readState(putLine("state leash 7 drag ended 12 view 640x480 3,4 5,6 held 5,6"), scratch));
    try testing.expectEqual(@as(f64, 12), dragOf(scratch));
    try testing.expectEqualSlices(i32, &.{ 640, 480, 2, 3, 4, 5, 6, 1, 5, 6 }, ints_buf[0..10]);

    try testing.expectEqual(@as(i32, @intFromEnum(HumanKind.leash)), readInput(putLine("input leash 9 219")));
    try testing.expectEqual(@as(i32, 219), ints_buf[0]);
    try testing.expectEqual(@as(f64, 9), lineTick());
    try testing.expectEqual(@as(i32, -1), readInput(putLine("input view 9 1x1")));

    reset();
    boards[live].place(.dog(2), .{ .x = 5, .y = 5 });
    try testing.expectEqual(@as(i32, 2), readTile(putLine("tile 27,27 dog 0 3557.00,361a.00 dog 2 1.00,1.00"), 0b011));
    try testing.expectEqual(physics.Point{ .x = 5, .y = 5 }, boards[live].dogs[2]);
    try testing.expectEqual(physics.Point{ .x = 256, .y = 256 }, boards[kept].dogs[2]);
    try testing.expectEqual(physics.Known.present, boards[live].dog_known[0]);
    try testing.expectEqual(physics.Known.absent, boards[scratch].dog_known[0]);
    try testing.expectEqualSlices(i32, &.{ 27, 27 }, ints_buf[0..2]);
    try testing.expectEqual(@as(i32, -1), readTile(putLine("tile 27,27 dog 0 03557.00,361a.00"), 1));
}

test "a refused input leaves the board and writes nothing" {
    reset();
    boards[live] = physics.Board.laidOut();
    try testing.expectEqual(@as(i32, -1 - @as(i32, @intFromEnum(physics.Refusal.grab_unleashed))), human(live, @intFromEnum(HumanKind.grab), 1, 0));
    try testing.expect(human(live, @intFromEnum(HumanKind.leash), 1, 4) > 0);
    try testing.expectEqualStrings("leash 1 4\n", out_buf[0..10]);
    try testing.expectEqual(@as(i32, -1 - @as(i32, @intFromEnum(physics.Refusal.leash_while_leashed))), human(live, @intFromEnum(HumanKind.leash), 1, 5));
    try testing.expectEqual(@as(i32, 4), leashedDog(live));
}
