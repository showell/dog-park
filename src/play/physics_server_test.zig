//! **THE PROTOCOL'S TESTS THAT NEED A SERVER** (docs/PHYSICS.md, "Tests
//! to write first": 1-7, 13, 15-19, 21-25, 30), driving physics_server.zig
//! directly: a temporary data dir through webbox's store, and a fake clock
//! (each start is handed its Unix ms). The page's side is `Page` below: it
//! runs the same physics on its own copy of the board and writes the
//! report's lines, as the page will.
//!
//! And the worked example through the real route (`POST /report`, as
//! webbox serves app.zig): the doc's report in, its kept answer out, byte
//! for byte.

const std = @import("std");
const webbox = @import("webbox");
const physics = @import("physics.zig");
const wire = @import("physics_wire.zig");
const judge = @import("physics_judge.zig");
const plog = @import("physics_log.zig");
const server_mod = @import("physics_server.zig");
const tiles = @import("tiles.zig");
const testing = std.testing;
const Server = server_mod.Server;
const Board = physics.Board;
const Tick = physics.Tick;

/// The clock at the first start.
const t0: u64 = 1_791_935_990_000;

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    tmp: testing.TmpDir,
    data: []const u8,
    server: *Server,
    started: Server.Started = undefined,

    fn init(self: *Rig, now: u64) !void {
        self.arena = .init(testing.allocator);
        self.threaded = .init(testing.allocator, .{});
        self.tmp = testing.tmpDir(.{});
        const a = self.arena.allocator();
        self.data = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &self.tmp.sub_path, "data" });
        self.server = try testing.allocator.create(Server);
        try self.restart(now);
    }

    /// A new run on the same data dir: what a server start does.
    fn restart(self: *Rig, now: u64) !void {
        const base = Board.laidOut();
        self.started = try self.server.start(self.io(), self.arena.allocator(), self.data, &base, now);
    }

    fn deinit(self: *Rig) void {
        testing.allocator.destroy(self.server);
        self.tmp.cleanup();
        self.threaded.deinit();
        self.arena.deinit();
    }

    fn io(self: *Rig) std.Io {
        return self.threaded.io();
    }

    fn report(self: *Rig, body: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, try self.server.report(self.io(), self.arena.allocator(), body));
    }

    fn load(self: *Rig, size: []const u8) ![]const u8 {
        const body = try std.fmt.allocPrint(self.arena.allocator(), "dogpark 1 physics {x:0>8} load {s}\n", .{ self.server.physics_hash, size });
        return self.arena.allocator().dupe(u8, try self.server.load(self.io(), self.arena.allocator(), body));
    }

    fn logBytes(self: *Rig) ![]const u8 {
        return (try webbox.store.readOrNull(self.io(), self.arena.allocator(), self.server.log_path, .unlimited)) orelse "";
    }
};

/// The page: its own board (a copy of the server's at the load, which the
/// physics only ever reads in the region's tiles), its epoch and request
/// numbers, the inputs waiting for the next tick, and the report it is
/// writing.
const Page = struct {
    alloc: std.mem.Allocator,
    hash: u32,
    epoch: wire.Epoch,
    req: u64 = 0,
    board: Board,
    /// The last tick it recorded; the server's last kept is `from`.
    last: Tick,
    from: Tick,
    humans: [physics.most_humans]physics.Human = undefined,
    humans_len: usize = 0,
    text: std.ArrayList(u8) = .empty,
    ms: u64 = 0,

    /// A page that has just loaded: `epoch E` and `kept K` from the answer.
    fn loaded(rig: *Rig, answer: []const u8) !Page {
        const e = (try field(answer, "epoch ")).?;
        const dot = std.mem.indexOfScalar(u8, e, '.').?;
        const k = try std.fmt.parseInt(Tick, (try field(answer, "kept ")).?, 10);
        var p: Page = .{
            .alloc = rig.arena.allocator(),
            .hash = rig.server.physics_hash,
            .epoch = .{ .ms = try std.fmt.parseInt(u64, e[0..dot], 10), .count = try std.fmt.parseInt(u64, e[dot + 1 ..], 10) },
            .board = rig.server.kept.board,
            .last = k,
            .from = k,
        };
        // The load's input lines: played at K + 1, never sent.
        var lines = std.mem.splitScalar(u8, answer, '\n');
        while (lines.next()) |l| if (std.mem.startsWith(u8, l, "input ")) {
            p.humans[p.humans_len] = wire.human(try wire.parse(l["input ".len..])).?.h;
            p.humans_len += 1;
        };
        return p;
    }

    /// A new request's header and `from`.
    fn begin(p: *Page) !void {
        p.req += 1;
        p.text = .empty;
        try p.write(.{ .header = .{ .language = wire.language, .physics = p.hash, .epoch = p.epoch, .req = p.req } });
        try p.write(.{ .from = .{ .tick = p.from, .wall = 1_791_936_000_000 } });
    }

    fn write(p: *Page, line: wire.Line) !void {
        var buf: [2048]u8 = undefined;
        var w: wire.Text = .{ .buf = &buf };
        try wire.write(&w, line);
        try p.text.appendSlice(p.alloc, w.bytes());
    }

    /// One of the human's inputs at the next tick.
    fn input(p: *Page, line: wire.Line) !void {
        try p.write(line);
        p.humans[p.humans_len] = wire.human(line).?.h;
        p.humans_len += 1;
    }

    /// The next tick, run on the page's board, written out.
    fn tick(p: *Page, drag: []const physics.Disp) !void {
        const t = p.last + 1;
        const capped = physics.mergeAndCap(drag);
        var lines: physics.Lines = .{};
        try testing.expectEqual(@as(?physics.Refusal, null), physics.tick(&p.board, t, p.humans[0..p.humans_len], capped.slice(), &lines));
        p.humans_len = 0;
        try p.write(.{ .t = .{ .tick = t, .ms = p.ms, .drag = capped } });
        p.ms += 63;
        for (lines.slice()) |c| try p.write(wire.checkedLine(t, c));
        p.last = t;
    }

    fn body(p: *Page) []const u8 {
        return p.text.items;
    }

    /// The answer kept everything it sent: `from` moves on.
    fn acked(p: *Page) void {
        p.from = p.last;
    }
};

/// The value after `word` on the answer's line that starts with it.
fn field(answer: []const u8, word: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, answer, '\n');
    while (lines.next()) |l| if (std.mem.startsWith(u8, l, word)) return l[word.len..];
    return null;
}

fn count(answer: []const u8, prefix: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, answer, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, prefix)) n += 1;
    }
    return n;
}

/// A tile line as the server writes one for `t`, from `b`, nothing
/// leashed: `tile c,r`, then the critters standing in it, cows then dogs,
/// each by number.
fn tileLineOf(alloc: std.mem.Allocator, b: *const Board, t: tiles.Tile) ![]const u8 {
    var buf: [4096]u8 = undefined;
    var w: wire.Text = .{ .buf = &buf };
    try w.str("\ntile ");
    try w.dec(@intCast(t.col));
    try w.char(',');
    try w.dec(@intCast(t.row));
    var n: usize = 0;
    for ([_]physics.Kind{ .cow, .dog }) |kind| {
        const many: usize = if (kind == .cow) physics.cow_count else physics.dog_count;
        for (0..many) |i| {
            const c: physics.Critter = .{ .kind = kind, .n = @intCast(i) };
            const at = physics.tileOf(b.at(c));
            if (at.col != t.col or at.row != t.row) continue;
            try w.char(' ');
            try w.critter(c);
            try w.char(' ');
            try w.pos(b.at(c));
            n += 1;
        }
    }
    try testing.expect(n > 0);
    try w.char('\n');
    return alloc.dupe(u8, w.bytes());
}

fn tileSetOf(cols: [2]i32, rows: [2]i32) wire.TileSet {
    var s: wire.TileSet = .{};
    var r = rows[0];
    while (r <= rows[1]) : (r += 1) {
        var c = cols[0];
        while (c <= cols[1]) : (c += 1) s.add(physics.TileSpan.at(c, r)) catch unreachable;
    }
    return s;
}

/// The region's tiles around a dog.
fn regionOf(b: *const Board, dog: u16) wire.TileSet {
    const span = physics.TileSpan.of(physics.region(b.dogs[dog]));
    return tileSetOf(.{ span.col_lo, span.col_hi }, .{ span.row_lo, span.row_hi });
}

/// The dog leashed in these tests: in the park's middle, among others.
const the_dog: u16 = 125;

/// **A LEASH, STEP BY STEP** (the doc's "A leash, step by step"): `leash
/// K+1 D` and a view of the region, as inputs with no tick; the answer
/// brings the region's tiles; then `held K+1` and the tick.
fn leashUp(rig: *Rig, page: *Page, dog: u16) !void {
    const region = regionOf(&page.board, dog);
    try page.begin();
    try page.input(.{ .leash = .{ .tick = page.last + 1, .dog = dog } });
    try page.write(.{ .view = .{ .tick = page.last + 1, .w = 1280, .h = 800, .tiles = region } });
    const a1 = try rig.report(page.body());
    try testing.expectEqual(region.len, count(a1, "tile "));
    try page.begin();
    try page.write(.{ .held = .{ .tick = page.last + 1, .tiles = region } });
    try page.tick(&.{});
    const a2 = try rig.report(page.body());
    try expectKept(a2, page.req, page.last);
    page.acked();
}

fn expectKept(answer: []const u8, req: u64, kept: Tick) !void {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "req {d}\nkept {d}\n", .{ req, kept }), answer);
}

/// A few ticks of a drag east, written and sent; the answer must keep them.
fn dragTicks(rig: *Rig, page: *Page, n: usize) !void {
    try page.begin();
    for (0..n) |_| try page.tick(&.{.{ .dx = physics.px(2), .dy = 0 }});
    try expectKept(try rig.report(page.body()), page.req, page.last);
    page.acked();
}

// ── the tests the doc lists ─────────────────────────────────────────────────

test "1. an unleashed pan: a report with only a view gets its tile lines; the page's held then gets none" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    // The park's corner tile and the empty ground west of it, two rows.
    const corner = tiles.park_offset_px / tiles.tile_px;
    const view = tileSetOf(.{ corner - 1, corner + 2 }, .{ corner, corner + 1 });
    try page.begin();
    try page.write(.{ .view = .{ .tick = page.last + 1, .w = 1280, .h = 800, .tiles = view } });
    const a = try rig.report(page.body());
    var want: [64]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, a, try std.fmt.bufPrint(&want, "req 1\nkept 0\ntile {d},{d}\n", .{ corner - 1, corner })));
    try testing.expectEqual(view.len, count(a, "tile "));
    // The corner tile holds exactly the critters the layout put there: its
    // cows by number, then its dogs by number.
    try testing.expect(std.mem.indexOf(u8, a, try tileLineOf(rig.arena.allocator(), &Board.laidOut(), .{ .col = corner, .row = corner })) != null);
    try page.begin();
    try page.write(.{ .held = .{ .tick = page.last + 1, .tiles = view } });
    try expectKept(try rig.report(page.body()), 2, 0);
    // A pan one column east: only the new column's tiles come.
    var wider = view;
    try wider.add(.{ .col = 30, .row = 27 });
    try wider.add(.{ .col = 30, .row = 28 });
    try page.begin();
    try page.write(.{ .view = .{ .tick = page.last + 1, .w = 1280, .h = 800, .tiles = wider } });
    const b = try rig.report(page.body());
    try testing.expectEqual(@as(usize, 2), count(b, "tile "));
    try testing.expect(std.mem.indexOf(u8, b, "\ntile 30,27 ") != null);
}

test "2. a differ at from + 1 is answered differ, with state and board, never reload" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    try leashUp(&rig, &page, the_dog);
    const before = page.board;
    try page.begin();
    try page.tick(&.{.{ .dx = physics.px(3), .dy = 0 }});
    const right = try rig.arena.allocator().dupe(u8, page.body());
    // The leashed dog's line written a 256th off.
    const at = std.mem.indexOf(u8, right, "\n dog 125 ").?;
    const end = std.mem.indexOfScalarPos(u8, right, at + 1, '\n').?;
    const wrong = try std.mem.concat(rig.arena.allocator(), u8, &.{ right[0 .. end - 1], if (right[end - 1] == '0') "1" else "0", right[end..] });
    const a = try rig.report(wrong);
    var buf: [64]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, a, try std.fmt.bufPrint(&buf, "req {d}\nkept {d}\ndiffer {d} dog 125 ", .{ page.req, page.from, page.from + 1 })));
    try testing.expect(std.mem.indexOf(u8, a, "\nstate leash 125 drag on view 1280x800 ") != null);
    try testing.expect(std.mem.indexOf(u8, a, "\nboard ") != null);
    try testing.expect(std.mem.indexOf(u8, a, "reload") == null);
    // The page rewinds and sends its own run again: kept.
    page.board = before;
    page.last = page.from;
    try page.begin();
    try page.tick(&.{.{ .dx = physics.px(3), .dy = 0 }});
    try expectKept(try rig.report(page.body()), page.req, page.last);
}

test "3 and 30 (502). a lost answer: the byte-identical resend gets the stored answer, nothing re-run or logged; the next request carries on" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    try leashUp(&rig, &page, the_dog);
    try page.begin();
    for (0..4) |_| try page.tick(&.{.{ .dx = physics.px(5), .dy = physics.px(1) }});
    const first = try rig.report(page.body());
    const log_after = rig.server.log_size;
    const board_after = rig.server.kept.board;
    // The answer was lost (or a 502): the same bytes again.
    const again = try rig.report(page.body());
    try testing.expectEqualStrings(first, again);
    try testing.expectEqual(log_after, rig.server.log_size);
    try testing.expect(std.meta.eql(board_after.dogs, rig.server.kept.board.dogs));
    page.acked();
    try dragTicks(&rig, &page, 3);
}

test "4. every load starts the park afresh: after play, a load gives back the first layout, nothing leashed or pending, and a restart after it comes back to that board" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    try leashUp(&rig, &page, the_dog);
    try dragTicks(&rig, &page, 5);
    // A leash kept for the next tick, still waiting.
    try page.begin();
    try page.input(.{ .letgo = page.last + 1 });
    _ = try rig.report(page.body());
    try testing.expect(!std.meta.eql(Board.laidOut().dogs, rig.server.kept.board.dogs));
    try testing.expect(rig.server.kept.pending_len > 0);
    const kept = rig.server.kept.tick;
    // The page reloads.
    const answer = try rig.load("1280x800");
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "epoch {d}.2\nkept {d}\nstate leash none drag none view 1280x800 held\n", .{ t0, kept }), answer);
    const first = Board.laidOut();
    try testing.expect(std.meta.eql(first.dogs, rig.server.kept.board.dogs));
    try testing.expect(std.meta.eql(first.cows, rig.server.kept.board.cows));
    try testing.expectEqual(physics.Hold.none, rig.server.kept.board.hold);
    try testing.expectEqual(@as(usize, 0), rig.server.kept.pending_len);
    // A deploy after the load: the same board, at the same tick.
    try rig.restart(t0 + 60_000);
    try testing.expect(rig.started.board == .applied);
    try testing.expectEqual(kept, rig.server.kept.tick);
    try testing.expect(std.meta.eql(first.dogs, rig.server.kept.board.dogs));
    try testing.expect(std.meta.eql(first.cows, rig.server.kept.board.cows));
    try testing.expectEqual(physics.Hold.none, rig.server.kept.board.hold);
    // And the page that loads now plays on from it.
    var fresh = try Page.loaded(&rig, try rig.load("1280x800"));
    try leashUp(&rig, &fresh, the_dog);
    try dragTicks(&rig, &fresh, 2);
}

test "5. a restart under a new physics hash, with a log tail after the snapshot: the board is where the tail left it" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    rig.server.physics_hash = 0xaaaa_aaaa;
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    try leashUp(&rig, &page, the_dog);
    try dragTicks(&rig, &page, 10);
    try page.begin();
    try page.input(.{ .letgo = page.last + 1 });
    try page.tick(&.{});
    try page.input(.{ .grab = page.last + 1 });
    _ = try rig.report(page.body());
    const was = rig.server.kept;
    try testing.expect(was.tick < server_mod.snapshot_every);
    // A deploy: the compiled hash, not the one the log was written under.
    try rig.restart(t0 + 60_000);
    try testing.expectEqual(wire.physics_hash, rig.server.physics_hash);
    try testing.expectEqual(was.tick, rig.server.kept.tick);
    try testing.expect(std.meta.eql(was.board.dogs, rig.server.kept.board.dogs));
    try testing.expect(std.meta.eql(was.board.cows, rig.server.kept.board.cows));
    try testing.expectEqual(was.board.hold, rig.server.kept.board.hold);
    try testing.expectEqualSlices(physics.Human, was.pendingSlice(), rig.server.kept.pendingSlice());
    try testing.expect(rig.started.board == .applied);
}

test "6. a letgo at from + 33, recorded while frozen at the 32-tick window, is kept for that tick" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    try leashUp(&rig, &page, the_dog);
    const from = page.from;
    try page.begin();
    for (0..32) |_| try page.tick(&.{.{ .dx = physics.px(1), .dy = 0 }});
    try page.input(.{ .letgo = from + 33 });
    try expectKept(try rig.report(page.body()), page.req, from + 32);
    try testing.expectEqualSlices(physics.Human, &.{.letgo}, rig.server.kept.pendingSlice());
    page.acked();
    try page.begin();
    try page.tick(&.{});
    try expectKept(try rig.report(page.body()), page.req, from + 33);
    try testing.expectEqual(physics.Drag{ .ended = from + 33 }, rig.server.kept.board.hold.leashed.drag);
    // A 33rd tick in one report is past the window: refused at its t line.
    page.acked();
    try page.begin();
    for (0..33) |_| try page.tick(&.{});
    var buf: [64]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, try rig.report(page.body()), try std.fmt.bufPrint(&buf, "\ndiffer {d} none t {d} ", .{ page.from + 33, page.from + 33 })) != null);
}

test "7. a replay held back at 48 KiB: the human's inputs take the tick after the last recorded one, across two reports" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    try leashUp(&rig, &page, the_dog);
    try page.begin();
    for (0..5) |_| try page.tick(&.{.{ .dx = physics.px(1), .dy = 0 }});
    try page.input(.{ .letgo = page.last + 1 });
    try expectKept(try rig.report(page.body()), page.req, page.last);
    page.acked();
    // The next report adds another input for the same tick, then runs it.
    try page.begin();
    try page.input(.{ .grab = page.last + 1 });
    try page.tick(&.{.{ .dx = physics.px(1), .dy = 0 }});
    try expectKept(try rig.report(page.body()), page.req, page.last);
    try testing.expectEqual(physics.Drag.on, rig.server.kept.board.hold.leashed.drag);
}

test "13. a leash at the screen's edge, small display against large, the same recorded inputs: the small one waits for the region, and the lines match" {
    var boards: [2]Board = undefined;
    var lines: [2][]const u8 = undefined;
    for ([_]enum { small, large }{ .small, .large }, 0..) |display, i| {
        var rig: Rig = undefined;
        try rig.init(t0);
        defer rig.deinit();
        var page = try Page.loaded(&rig, try rig.load("1280x800"));
        const region = regionOf(&page.board, the_dog);
        // The small display's 4 tiles hold the dog, at the region's edge;
        // the large one's every tile of the region.
        const dog_tile = physics.tileOf(page.board.dogs[the_dog]);
        var view = switch (display) {
            .small => tileSetOf(.{ dog_tile.col, dog_tile.col + 1 }, .{ dog_tile.row, dog_tile.row + 1 }),
            .large => region,
        };
        try page.begin();
        try page.write(.{ .view = .{ .tick = 1, .w = 1280, .h = 800, .tiles = view } });
        _ = try rig.report(page.body());
        try page.begin();
        try page.write(.{ .held = .{ .tick = 1, .tiles = view } });
        try page.input(.{ .leash = .{ .tick = 1, .dog = the_dog } });
        if (display == .small) {
            // It can't run tick 1 yet: a page that did is refused there.
            var early = page;
            early.text = try page.text.clone(rig.arena.allocator());
            try early.tick(&.{});
            try testing.expect(std.mem.indexOf(u8, try rig.report(early.body()), "\ndiffer 1 none t 1 +0\n") != null);
            // The same request again, frozen instead: the region's view.
            try page.begin();
            try page.write(.{ .held = .{ .tick = 1, .tiles = view } });
            try page.input(.{ .leash = .{ .tick = 1, .dog = the_dog } });
            for (region.slice()) |t| try view.add(t);
            try page.write(.{ .view = .{ .tick = 1, .w = 1280, .h = 800, .tiles = view } });
            const a = try rig.report(page.body());
            try testing.expectEqual(region.len - 4, count(a, "tile "));
            try page.begin();
            try page.write(.{ .held = .{ .tick = 1, .tiles = region } });
            // The leash and the first view went in the earlier request.
            page.humans_len = 1;
        }
        const ticks_from = page.text.items.len;
        try page.tick(&.{.{ .dx = physics.px(4), .dy = physics.px(2) }});
        for (0..6) |_| try page.tick(&.{.{ .dx = -physics.px(3), .dy = physics.px(1) }});
        try expectKept(try rig.report(page.body()), page.req, 7);
        lines[i] = try testing.allocator.dupe(u8, page.text.items[ticks_from..]);
        boards[i] = rig.server.kept.board;
    }
    defer for (lines) |l| testing.allocator.free(l);
    try testing.expectEqualStrings(lines[0], lines[1]);
    try testing.expect(std.meta.eql(boards[0].dogs, boards[1].dogs));
    try testing.expect(std.meta.eql(boards[0].cows, boards[1].cows));
}

test "15. a lost answer and a trailing leash: the byte-identical resend gets the stored answer, and R + 1 doesn't repeat the leash" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    const region = regionOf(&page.board, the_dog);
    try page.begin();
    try page.input(.{ .leash = .{ .tick = 1, .dog = the_dog } });
    try page.write(.{ .view = .{ .tick = 1, .w = 1280, .h = 800, .tiles = region } });
    const first = try rig.report(page.body());
    try testing.expectEqualStrings(first, try rig.report(page.body()));
    try testing.expectEqualSlices(physics.Human, &.{.{ .leash = the_dog }}, rig.server.kept.pendingSlice());
    // R + 1 repeating the leash is refused: the leash is kept already.
    var again = page;
    try again.begin();
    try again.write(.{ .held = .{ .tick = 1, .tiles = region } });
    try again.write(.{ .leash = .{ .tick = 1, .dog = the_dog } });
    try testing.expect(std.mem.indexOf(u8, try rig.report(again.body()), "\ndiffer 1 none leash 1 125\n") != null);
    // R + 2 without it: kept, the leash taken from the first request.
    page.req = again.req;
    try page.begin();
    try page.write(.{ .held = .{ .tick = 1, .tiles = region } });
    try page.tick(&.{});
    try expectKept(try rig.report(page.body()), page.req, 1);
    try testing.expectEqual(@as(?u16, the_dog), rig.server.kept.board.leashedDog());
}

test "16. a reload, then req 1, while the old epoch's stored answer was also req 1: the load cleared it, so req 1 is new" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var old = try Page.loaded(&rig, try rig.load("1280x800"));
    try old.begin();
    try old.write(.{ .view = .{ .tick = 1, .w = 1280, .h = 800, .tiles = tileSetOf(.{ 30, 30 }, .{ 30, 30 }) } });
    _ = try rig.report(old.body());
    var page = try Page.loaded(&rig, try rig.load("640x480"));
    try page.begin();
    try page.write(.{ .view = .{ .tick = 1, .w = 640, .h = 480, .tiles = tileSetOf(.{ 31, 31 }, .{ 31, 31 }) } });
    const a = try rig.report(page.body());
    try testing.expect(std.mem.startsWith(u8, a, "req 1\nkept 0\ntile 31,31 "));
    // And the old page, now behind: taken over.
    try old.begin();
    try testing.expectEqualStrings("req 2\ntaken over\n", try rig.report(old.body()));
}

test "17. a restart, then an old page whose epoch counts the same as a new one: reload epoch, even on the same clock" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var old = try Page.loaded(&rig, try rig.load("1280x800"));
    // The clock didn't move (or went back): the run's start still does.
    try rig.restart(t0 - 5);
    try testing.expectEqual(t0 + 1, rig.server.started);
    const fresh = try rig.load("1280x800");
    var buf: [64]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, fresh, try std.fmt.bufPrint(&buf, "epoch {d}.1\n", .{t0 + 1})));
    try old.begin();
    try testing.expectEqualStrings("req 1\nreload epoch\n", try rig.report(old.body()));
}

test "18 and 24. req ?: a garbled header gets req ? alone, every time, counted and logged, never a differ, the breaker or stuck" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    try leashUp(&rig, &page, the_dog);
    const stored = try rig.arena.allocator().dupe(u8, rig.server.stored[0..rig.server.stored_len]);
    for ([_][]const u8{ "", "\n", "dogpark 1 physics 5E0C91A2 page 1.1 req 3\nfrom 1\n", "dogpark 1 physics 5e0c91a2 page 1.1 req 03\n", "from 1\n" }, 1..) |garbled, n| {
        for (0..3) |_| try testing.expectEqualStrings("req ?\n", try rig.report(garbled));
        try testing.expectEqual(@as(u64, 3 * n), rig.server.unreadable);
    }
    try testing.expectEqual(@as(u32, 0), rig.server.differs_in_a_row);
    try testing.expectEqual(@as(?Tick, null), rig.server.stuck);
    try testing.expectEqualStrings(stored, rig.server.stored[0..rig.server.stored_len]);
    try testing.expect(std.mem.indexOf(u8, try rig.logBytes(), "entry finding ") != null);
    // A load that can't be read: req ? too.
    try testing.expectEqualStrings("req ?\n", try rig.server.load(rig.io(), rig.arena.allocator(), "dogpark 1 physics 5e0c91a2 load 1280\n"));
}

test "19. a torn log tail at restart: dropped, and the board is where the last whole report left it; a damaged middle stops the start" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    try leashUp(&rig, &page, the_dog);
    try dragTicks(&rig, &page, 5);
    const was = rig.server.kept;
    const log = rig.server.log_path;
    // A crash mid-append: half an entry.
    const torn = "entry report 400\ndogpark 1 physics 00000000 page 1.1 req 9\nfrom 6 wall 1\nt 7 +0\n dog 125 ";
    _ = try webbox.store.append(rig.io(), rig.arena.allocator(), log, torn);
    try rig.restart(t0 + 1000);
    try testing.expectEqual(torn.len, rig.started.board.applied.torn_bytes);
    try testing.expectEqual(was.tick, rig.server.kept.tick);
    try testing.expect(std.meta.eql(was.board.dogs, rig.server.kept.board.dogs));
    // The new run appends to a log of its own, never after the torn bytes.
    try testing.expect(!std.mem.eql(u8, log, rig.server.log_path));
    var again = try Page.loaded(&rig, try rig.load("1280x800"));
    try dragTicks(&rig, &again, 2);
    // A damaged entry with a whole one after it is not a crash's doing.
    const bytes = try rig.logBytes();
    const broken = try rig.arena.allocator().dupe(u8, bytes);
    const at = std.mem.indexOf(u8, broken, "entry load").?;
    broken[at] = 'E';
    try webbox.store.replace(rig.io(), rig.arena.allocator(), rig.server.log_path, broken, .{});
    // The snapshot names the start of this log: everything in it applies.
    try testing.expectError(error.CorruptLog, rig.restart(t0 + 2000));
}

test "21. thirty unleashed pans, each a view and a held for one tick: no refusal, no stuck" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    var held: wire.TileSet = .{};
    for (0..30) |i| {
        const c: i32 = 20 + @as(i32, @intCast(i));
        const view = tileSetOf(.{ c, c + 2 }, .{ 30, 31 });
        try page.begin();
        // The pan's view at tick 1, coalesced with the held tiles it keeps.
        try page.write(.{ .view = .{ .tick = 1, .w = 1280, .h = 800, .tiles = view } });
        var still: wire.TileSet = .{};
        for (held.slice()) |t| if (view.holds(t)) try still.add(t);
        if (still.len > 0) try page.write(.{ .held = .{ .tick = 1, .tiles = still } });
        const a = try rig.report(page.body());
        try testing.expect(std.mem.startsWith(u8, a, "req "));
        try testing.expect(std.mem.indexOf(u8, a, "differ") == null);
        // Its new tiles came; the page holds them from its next request.
        held = view;
    }
    try testing.expectEqual(@as(u32, 0), rig.server.differs_in_a_row);
    try testing.expectEqual(@as(?Tick, null), rig.server.stuck);
    try testing.expectEqual(@as(Tick, 0), rig.server.kept.tick);
}

test "22. a replay that reaches a new tile before its held: a held of a tile never sent is refused; the view sends it, then the held is kept" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    try leashUp(&rig, &page, the_dog);
    var view = rig.server.kept.view.tiles;
    const beyond: tiles.Tile = .{ .col = 40, .row = 40 };
    try view.add(beyond);
    const t = page.last + 1;
    // Wrong: the held for the new tile in the same request as its view.
    var bad = page;
    try bad.begin();
    try bad.write(.{ .view = .{ .tick = t, .w = 1280, .h = 800, .tiles = view } });
    var all_held = view;
    try bad.write(.{ .held = .{ .tick = t, .tiles = all_held } });
    const refused = try rig.report(bad.body());
    try testing.expect(std.mem.indexOf(u8, refused, "\ndiffer ") != null);
    try testing.expect(std.mem.indexOf(u8, refused, " none held ") != null);
    // Its answer still brings the tile: the view was... not kept. So the
    // page writes the view and stops (a trailing input).
    page.req = bad.req;
    try page.begin();
    try page.write(.{ .view = .{ .tick = t, .w = 1280, .h = 800, .tiles = view } });
    const a = try rig.report(page.body());
    try testing.expect(std.mem.indexOf(u8, a, "\ntile 40,40\n") != null);
    try page.begin();
    all_held = .{};
    try all_held.add(beyond);
    try page.write(.{ .held = .{ .tick = t, .tiles = all_held } });
    try page.tick(&.{});
    try expectKept(try rig.report(page.body()), page.req, t);
}

test "23. a tile sent again after a differ, its held never kept: the page's board keeps the critters it is running" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    try leashUp(&rig, &page, the_dog);
    var view = rig.server.kept.view.tiles;
    try view.add(.{ .col = 40, .row = 40 });
    try page.begin();
    try page.write(.{ .view = .{ .tick = page.last + 1, .w = 1280, .h = 800, .tiles = view } });
    try testing.expectEqual(@as(usize, 1), count(try rig.report(page.body()), "tile "));
    // The held and a tick whose line is wrong: differ at that tick.
    try page.begin();
    var one: wire.TileSet = .{};
    try one.add(.{ .col = 40, .row = 40 });
    try page.write(.{ .held = .{ .tick = page.last + 1, .tiles = one } });
    try page.write(.{ .t = .{ .tick = page.last + 1, .ms = 0, .drag = .{} } });
    // The server's run rests there (the drag on, nothing moving).
    try page.write(.{ .bump = .{ .tick = page.last + 1, .who = .cow(0) } });
    const a = try rig.report(page.body());
    try testing.expect(std.mem.indexOf(u8, a, "\ndiffer ") != null);
    try testing.expect(std.mem.indexOf(u8, a, "\ntile 40,40\n") != null);
}

test "the torus' seam (decision 14): an unleashed view of the world's four corner tiles, named in the world, gets them, and its held is kept" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    // An unleashed view of the four corner tiles, named in the world.
    const edge = tiles.world_tiles - 1;
    var seam: wire.TileSet = .{};
    for ([_][2]i32{ .{ edge, 0 }, .{ 0, 0 }, .{ edge, edge }, .{ 0, edge } }) |cr| try seam.add(.{ .col = cr[0], .row = cr[1] });
    try page.begin();
    try page.write(.{ .view = .{ .tick = page.last + 1, .w = 1280, .h = 800, .tiles = seam } });
    const a = try rig.report(page.body());
    try testing.expectEqual(@as(usize, 4), count(a, "tile "));
    var buf: [32]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, a, try std.fmt.bufPrint(&buf, "\ntile {d},0\n", .{edge})) != null);
    try page.begin();
    try page.write(.{ .held = .{ .tick = page.last + 1, .tiles = seam } });
    try expectKept(try rig.report(page.body()), 2, 0);
}

test "the torus' seam (decision 14): a leash at the world's corner views and holds the wrapped region, and its ticks are kept" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    const edge = tiles.world_tiles - 1;
    // The dog moved to the corner, a cow across the seam from it, on both
    // boards (as a restart from such a log would have them).
    const near = physics.px(200);
    const far = physics.world - near;
    for ([_]*Board{ &rig.server.kept.board, &page.board }) |b| {
        b.place(.dog(the_dog), .{ .x = near, .y = near });
        b.place(.cow(0), .{ .x = far, .y = near });
    }
    try leashUp(&rig, &page, the_dog);
    try testing.expect(regionOf(&page.board, the_dog).holds(.{ .col = edge, .row = 0 }));
    try dragTicks(&rig, &page, 4);
}

test "25. the park in the world: the first layout's counts; the empty world reads as empty" {
    try testing.expectEqual(@as(usize, tiles.park_tiles * tiles.park_tiles * physics.breeds), physics.dog_count);
    try testing.expectEqual(@as(usize, tiles.park_tiles * tiles.park_tiles / 2), physics.cow_count);
    // Through the protocol: the world's corner tile and the one beside the
    // park are empty; the park's tiles are not.
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    var view: wire.TileSet = .{};
    const first = tiles.park_offset_px / tiles.tile_px;
    const last = first + tiles.park_tiles - 1;
    const edge = tiles.world_tiles - 1;
    for ([_][2]i32{ .{ 0, 0 }, .{ edge, edge }, .{ first - 1, first + 3 }, .{ last, last } }) |cr| try view.add(.{ .col = cr[0], .row = cr[1] });
    try page.begin();
    try page.write(.{ .view = .{ .tick = 1, .w = 1280, .h = 800, .tiles = view } });
    const a = try rig.report(page.body());
    const alloc = rig.arena.allocator();
    try testing.expect(std.mem.indexOf(u8, a, "\ntile 0,0\n") != null);
    try testing.expect(std.mem.indexOf(u8, a, try std.fmt.allocPrint(alloc, "\ntile {d},{d}\n", .{ edge, edge })) != null);
    try testing.expect(std.mem.indexOf(u8, a, try std.fmt.allocPrint(alloc, "\ntile {d},{d}\n", .{ first - 1, first + 3 })) != null);
    try testing.expect(std.mem.indexOf(u8, a, try std.fmt.allocPrint(alloc, "\ntile {d},{d} ", .{ last, last })) != null);
}

// ── the protocol's other rules ──────────────────────────────────────────────

test "a reused request number with another body is refused (differ K+1 none its header), counted, logged; the stored answer stays" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    try leashUp(&rig, &page, the_dog);
    const stored = try rig.arena.allocator().dupe(u8, rig.server.stored[0..rig.server.stored_len]);
    const original = try rig.arena.allocator().dupe(u8, page.body());
    var other = page;
    other.req -= 1;
    try other.begin();
    try other.tick(&.{});
    const a = try rig.report(other.body());
    var buf: [128]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, a, try std.fmt.bufPrint(&buf, "req {d}\nkept {d}\ndiffer {d} none dogpark 1 physics ", .{ page.req, page.from, page.from + 1 })));
    try testing.expect(std.mem.indexOf(u8, a, "\nstate leash 125 ") != null);
    try testing.expectEqual(@as(u32, 1), rig.server.differs_in_a_row);
    try testing.expect(std.mem.indexOf(u8, try rig.logBytes(), "refused, a reused request number with another body") != null);
    try testing.expectEqualStrings(stored, try rig.report(original));
    // And a number that skips ahead: refused the same way, not stored.
    other.req += 5;
    try other.begin();
    try testing.expect(std.mem.indexOf(u8, try rig.report(other.body()), "\ndiffer ") != null);
}

test "the breaker: the third differ in a row answers reload differs; three of those with no kept tick between mark the park stuck, until a restart" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var stuck_at: Tick = 0;
    for (0..3) |trip| {
        var page = try Page.loaded(&rig, try rig.load("1280x800"));
        if (trip == 0) try leashUp(&rig, &page, the_dog);
        for (0..3) |i| {
            try page.begin();
            try page.write(.{ .t = .{ .tick = page.from + 1, .ms = 0, .drag = .{} } });
            try page.write(.{ .bump = .{ .tick = page.from + 1, .who = .cow(0) } });
            const a = try rig.report(page.body());
            if (i < 2) {
                try testing.expect(std.mem.indexOf(u8, a, "\ndiffer ") != null);
            } else {
                var buf: [64]u8 = undefined;
                try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "req {d}\nreload differs\n", .{page.req}), a);
            }
        }
        stuck_at = page.from + 1;
    }
    var buf: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&buf, "stuck {d}\n", .{stuck_at});
    try testing.expectEqualStrings(want, try rig.load("1280x800"));
    try testing.expect(std.mem.indexOf(u8, try rig.logBytes(), "stuck at tick") != null);
    // A deploy clears it.
    try rig.restart(t0 + 10);
    try testing.expect(std.mem.startsWith(u8, try rig.load("1280x800"), "epoch "));
}

test "the header's order: language, physics, epoch, then the request number and from" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    var buf: [256]u8 = undefined;
    const h = rig.server.physics_hash;
    try testing.expectEqualStrings("req 1\nreload language 1\n", try rig.report(try std.fmt.bufPrint(&buf, "dogpark 2 physics {x:0>8} page 9.9 req 1\nfrom 0\n", .{h})));
    try testing.expect(std.mem.startsWith(u8, try rig.report(try std.fmt.bufPrint(&buf, "dogpark 1 physics {x:0>8} page 9.9 req 1\nfrom 0\n", .{h +% 1})), "req 1\nreload physics "));
    try testing.expectEqualStrings("req 1\nreload epoch\n", try rig.report(try std.fmt.bufPrint(&buf, "dogpark 1 physics {x:0>8} page 9.1 req 1\nfrom 0\n", .{h})));
    try testing.expectEqualStrings("req 1\nreload epoch\n", try rig.report(try std.fmt.bufPrint(&buf, "dogpark 1 physics {x:0>8} page {d}.2 req 1\nfrom 0\n", .{ h, t0 })));
    try testing.expectEqualStrings("req 1\nreload from 0\n", try rig.report(try std.fmt.bufPrint(&buf, "dogpark 1 physics {x:0>8} page {d}.1 req 1\nfrom 3\n", .{ h, t0 })));
    // A reload from K is an answer like any: R is answered, R + 1 is next.
    page.req = 1;
    try page.begin();
    try expectKept(try rig.report(page.body()), 2, 0);
}

test "the log: kept reports as written, a differ's kept prefix, the load's view and held; a snapshot every 64 kept ticks" {
    var rig: Rig = undefined;
    try rig.init(t0);
    defer rig.deinit();
    var page = try Page.loaded(&rig, try rig.load("1280x800"));
    try leashUp(&rig, &page, the_dog);
    try page.begin();
    try page.tick(&.{.{ .dx = physics.px(2), .dy = 0 }});
    try page.tick(&.{.{ .dx = physics.px(2), .dy = 0 }});
    const prefix_len = page.text.items.len;
    try page.tick(&.{});
    try page.write(.{ .rest = page.last });
    const a = try rig.report(page.body());
    try testing.expect(std.mem.indexOf(u8, a, "\ndiffer ") != null);
    const log = try rig.logBytes();
    var buf: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&buf, "entry report {d}\n", .{prefix_len});
    try testing.expect(std.mem.indexOf(u8, log, want) != null);
    try testing.expect(std.mem.indexOf(u8, log, page.text.items[0..prefix_len]) != null);
    try testing.expect(std.mem.indexOf(u8, log, "entry load ") != null);
    // The snapshot moves at 64 kept ticks.
    page.last = rig.server.kept.tick;
    page.board = rig.server.kept.board;
    page.acked();
    const snap_was = rig.server.snapshot_tick;
    // Ticks with the drag on and the pointer still: the region stays put.
    for (0..3) |_| {
        try page.begin();
        for (0..30) |_| try page.tick(&.{});
        try expectKept(try rig.report(page.body()), page.req, page.last);
        page.acked();
    }
    try testing.expect(rig.server.snapshot_tick > snap_was);
    try testing.expect(rig.server.snapshot_tick + server_mod.snapshot_every > rig.server.kept.tick);
}

test "the log's frames: a torn tail is dropped, a bad entry before a whole one is corrupt" {
    const a = testing.allocator;
    const one = try plog.framed(a, .finding, "x\n");
    defer a.free(one);
    try testing.expectEqualStrings("entry finding 2\nx\nend\n", one);
    const two = try std.mem.concat(a, u8, &.{ one, one });
    defer a.free(two);
    for (0..two.len) |cut| {
        var e: plog.Entries = .{ .bytes = two[0..cut] };
        var n: usize = 0;
        while (try e.next()) |_| n += 1;
        try testing.expectEqual(@as(usize, if (cut < one.len) 0 else 1), n);
        try testing.expectEqual(cut - n * one.len, e.torn);
    }
    const bad = try std.mem.concat(a, u8, &.{ "entry finding 3\nx\nend\n", one });
    defer a.free(bad);
    var e: plog.Entries = .{ .bytes = bad };
    try testing.expectError(error.CorruptLog, e.next());
}

test "the load resolution: an overlapping park is resolved once, logged first, and never again" {
    var rig: Rig = undefined;
    rig.arena = .init(testing.allocator);
    rig.threaded = .init(testing.allocator, .{});
    rig.tmp = testing.tmpDir(.{});
    rig.data = try std.fs.path.join(rig.arena.allocator(), &.{ ".zig-cache", "tmp", &rig.tmp.sub_path, "data" });
    rig.server = try testing.allocator.create(Server);
    defer rig.deinit();
    var base = Board.laidOut();
    // Dog 7 dragged onto dog 6, and dog 8 onto cow 3.
    base.dogs[7] = .{ .x = base.dogs[6].x + physics.px(5), .y = base.dogs[6].y };
    base.dogs[8] = base.cows[3];
    rig.started = try rig.server.start(rig.io(), rig.arena.allocator(), rig.data, &base, t0);
    try testing.expectEqual(@as(usize, 2), rig.started.board.resolved);
    const b = &rig.server.kept.board;
    var pairs: [4][2]physics.Critter = undefined;
    for ([_]u16{ 6, 7, 8 }) |n| {
        b.hold = .{ .leashed = .{ .dog = n, .drag = .on } };
        try testing.expectEqual(@as(usize, 0), physics.overlaps(b, &pairs));
    }
    b.hold = .none;
    const log = try rig.logBytes();
    try testing.expect(std.mem.startsWith(u8, log, "entry resolved "));
    try testing.expect(std.mem.indexOf(u8, log, "\n dog 7 ") != null);
    // A restart applies the snapshot: nothing resolved again, same board.
    const was = rig.server.kept.board;
    var other = Board.laidOut();
    other.dogs[0].x += physics.px(1);
    rig.started = try rig.server.start(rig.io(), rig.arena.allocator(), rig.data, &other, t0 + 1);
    try testing.expect(rig.started.board == .applied);
    try testing.expect(std.meta.eql(was.dogs, rig.server.kept.board.dogs));
}

test "a park with a critter that has nowhere to go does not start, and the log says which" {
    var rig: Rig = undefined;
    rig.arena = .init(testing.allocator);
    rig.threaded = .init(testing.allocator, .{});
    rig.tmp = testing.tmpDir(.{});
    rig.data = try std.fs.path.join(rig.arena.allocator(), &.{ ".zig-cache", "tmp", &rig.tmp.sub_path, "data" });
    rig.server = try testing.allocator.create(Server);
    defer rig.deinit();
    // Dog 0 in the world's corner, sticking out of it, with no neighbour to
    // make a way out.
    var base = Board.laidOut();
    base.dogs[0] = .{ .x = physics.px(5), .y = physics.px(5) };
    try testing.expectError(error.ParkDoesNotResolve, rig.server.start(rig.io(), rig.arena.allocator(), rig.data, &base, t0));
    try testing.expect(std.mem.indexOf(u8, try rig.logBytes(), "the park does not resolve: dog 0 has nowhere to go") != null);
}

test "a snapshot reads back what it wrote" {
    var k: judge.Kept = .{ .tick = 99, .board = Board.laidOut() };
    k.board.dogs[3].x += 77;
    k.board.hold = .{ .leashed = .{ .dog = 3, .drag = .{ .ended = 97 } } };
    k.pending[0] = .grab;
    k.pending[1] = .letgo;
    k.pending_len = 2;
    const s: plog.Snapshot = .{ .physics = 0x0102_0304, .started = t0, .log_started = t0, .log_offset = 1234, .kept = k };
    const text = try plog.writeSnapshot(testing.allocator, &s);
    defer testing.allocator.free(text);
    const back = try plog.readSnapshot(text);
    try testing.expectEqual(s.physics, back.physics);
    try testing.expectEqual(s.log_offset, back.log_offset);
    try testing.expectEqual(@as(Tick, 99), back.kept.tick);
    try testing.expectEqual(k.board.hold, back.kept.board.hold);
    try testing.expectEqualSlices(physics.Human, k.pendingSlice(), back.kept.pendingSlice());
    try testing.expect(std.meta.eql(k.board.dogs, back.kept.board.dogs));
    try testing.expectError(error.SnapshotDoesNotRead, plog.readSnapshot(text[0 .. text.len - 4]));
}

// ── the worked example, through the real route ──────────────────────────────

const app = @import("app.zig");
const Served = webbox.site.Site(app);

const example = @import("physics_judge_test.zig");
const example_report = example.example_report;

/// POSTs `body` to `path` through the site, as webbox's hosts route it.
fn post(io: std.Io, alloc: std.mem.Allocator, hub: *webbox.bus.Hub, path: []const u8, body: []const u8) !struct { status: []const u8, body: []const u8 } {
    const raw = try std.fmt.allocPrint(alloc, "POST {s} HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n{s}", .{ path, body.len, body });
    var out: std.Io.Writer.Allocating = .init(alloc);
    var reader: std.Io.Reader = .fixed(raw);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    var b = webbox.bus.Bus.of(hub);
    try testing.expect((try Served.route(&req, io, alloc, &b)) == null);
    try out.writer.flush();
    const all = out.written();
    const split = std.mem.indexOf(u8, all, "\r\n\r\n").?;
    return .{ .status = all[9..12], .body = all[split + 4 ..] };
}

test "the worked example through POST /report: the doc's report in, req 4 kept 1043 out, byte for byte; and a body past 64 KiB is a 413" {
    // The doc's worked example is the played knobs' (physics_judge_test.zig).
    if (physics.knobs != .played) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    _ = try app.setup(io, a, .{ .data_dir = try std.fs.path.join(a, &.{ root, "data" }), .auth_dir = try std.fs.path.join(a, &.{ root, "auth" }) });
    var hub = webbox.bus.Hub.init(io, testing.allocator);
    defer hub.entries.deinit(testing.allocator);
    // The server as request 3 left it: the doc's board at kept 1040, the
    // leash waiting, the region's view, the viewport's 8 tiles held, the
    // others sent with request 3's answer; epoch .3, request 3 answered.
    const s = &app.the_physics;
    s.physics_hash = 0x5e0c91a2;
    s.started = 1791935990000;
    s.epoch = 3;
    s.last = 3;
    s.kept = example.exampleKept();
    const got = try post(io, a, &hub, "/report", example_report);
    try testing.expectEqualStrings("200", got.status);
    try testing.expectEqualStrings("req 4\nkept 1043\n", got.body);
    // The resend: the same bytes back.
    try testing.expectEqualStrings("req 4\nkept 1043\n", (try post(io, a, &hub, "/report", example_report)).body);
    // 64 KiB is the route's cap; one byte more is a 413.
    try testing.expectEqual(@as(u64, 64 * 1024), app.bodyLimit("/report"));
    try testing.expectEqual(@as(u64, 64 * 1024), app.bodyLimit("/load"));
    const big = try a.alloc(u8, 64 * 1024 + 1);
    @memset(big, 'x');
    try testing.expectEqualStrings("413", (try post(io, a, &hub, "/report", big)).status);
}
