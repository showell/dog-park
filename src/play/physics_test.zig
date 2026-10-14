//! The physics' tests (docs/PHYSICS.md, "Tests to write first"): test 12
//! (more held tiles change nothing) as far as the board can say it; the
//! cows' grid rule (27); the lane (20); pushes and
//! jumps (8, 28, and the nearest spot's ties); coincident centres (9); the
//! leashed dog against an overlap (10); bumps, the timer, rest; the wishes;
//! the cap. The worked example (26) is physics_judge_test.zig's.

const std = @import("std");
const physics = @import("physics.zig");
const tiles = @import("tiles.zig");
const testing = std.testing;
const Board = physics.Board;
const Point = physics.Point;
const Critter = physics.Critter;
const Lines = physics.Lines;

/// The seeded fuzz loops' size: a tenth on every edit, all of it in the
/// slow tier (`zig build slow`, or -Dfuzz=full).
const fuzz = @import("test_options").fuzz;
fn fuzzed(full: usize) usize {
    return switch (fuzz) {
        .fast => full / 10,
        .full => full,
    };
}

fn px(x: i32, y: i32) Point {
    return .{ .x = physics.px(x), .y = physics.px(y) };
}

/// A drag displacement of whole pixels.
fn d(x: i32, y: i32) physics.Disp {
    return .{ .dx = physics.px(x), .dy = physics.px(y) };
}

/// An empty board with dog 0 leashed at `at`, a drag on.
fn leashedAt(at: Point) Board {
    var b = Board.empty();
    b.place(.dog(0), at);
    b.hold = .{ .leashed = .{ .dog = 0, .drag = .on } };
    return b;
}

fn ticked(b: *Board, t: physics.Tick, humans: []const physics.Human, drag: []const physics.Disp) Lines {
    var lines: Lines = .{};
    if (physics.tick(b, t, humans, drag, &lines)) |r| std.debug.panic("refused: {t}", .{r});
    return lines;
}

/// One cow at `cow`, the leashed dog at `from` dragged by `by`: where the
/// cow ends.
fn cowAfter(from: Point, by: physics.Disp, cow: Point) Point {
    var b = leashedAt(from);
    b.place(.cow(0), cow);
    _ = ticked(&b, 1, &.{}, &.{by});
    return b.cows[0];
}

fn bumpOf(lines: *const Lines) ?Critter {
    for (lines.slice()) |c| switch (c) {
        .bump => |who| return who,
        else => {},
    };
    return null;
}

fn hasRest(lines: *const Lines) bool {
    for (lines.slice()) |c| if (c == .rest) return true;
    return false;
}

// --------------------------------------------------- the cows' grid rule

test "the first layout is the golden one: every dog and cow where the old whole- and half-pixel layout put it, every critter present, no one leashed" {
    const b = Board.laidOut();
    var crc = std.hash.Crc32.init();
    crc.update(std.mem.sliceAsBytes(&b.dogs));
    crc.update(std.mem.sliceAsBytes(&b.cows));
    crc.update(std.mem.sliceAsBytes(&b.dog_known));
    crc.update(std.mem.sliceAsBytes(&b.cow_known));
    try testing.expectEqual(@as(u32, 870706651), crc.final());
    try testing.expectEqual(physics.Hold.none, b.hold);
    try testing.expectEqual(Point{ .x = 13575 * 256, .y = 13575 * 256 }, b.dogs[0]);
    try testing.expectEqual(Point{ .x = 13750 * 256, .y = 13750 * 256 }, b.cows[0]);
}

/// A drag's way: an axis, and which way along it.
const Way = struct { axis: physics.Axis, way: i32 };
const four_ways = [_]Way{ .{ .axis = .x, .way = 1 }, .{ .axis = .x, .way = -1 }, .{ .axis = .y, .way = 1 }, .{ .axis = .y, .way = -1 } };

/// The point `ahead` along `w` from `from`, and `off` across it.
fn along(from: Point, w: Way, ahead: i32, off: i32) Point {
    return switch (w.axis) {
        .x => .{ .x = from.x + w.way * ahead, .y = from.y + off },
        .y => .{ .x = from.x + off, .y = from.y + w.way * ahead },
    };
}

/// A drag of `n` whole pixels along `w`.
fn dragAlong(w: Way, n: i32) physics.Disp {
    return switch (w.axis) {
        .x => d(w.way * n, 0),
        .y => d(0, w.way * n),
    };
}

fn awakeAt(from: Point, p: Point) bool {
    return physics.measure(physics.delta(from, p)) <= physics.measureOf(physics.awake_reach);
}

// ------------------------------------------- overlaps that slipped through

test "the leashed dog overlapping another: a bump only when the drag shrinks |Δ| on its axis or would carry it past; along it, away, or from Δ = 0, free" {
    const b0 = 16000;
    const Case = struct { other: Point, drag: physics.Disp, bump: bool };
    const cases = [_]Case{
        .{ .other = px(b0 + 30, b0), .drag = d(5, 0), .bump = true },
        .{ .other = px(b0 + 30, b0), .drag = d(-5, 0), .bump = false },
        .{ .other = px(b0 + 30, b0), .drag = d(0, 5), .bump = false },
        .{ .other = px(b0 + 30, b0 + 10), .drag = d(0, 5), .bump = true },
        .{ .other = px(b0 + 30, b0 + 10), .drag = d(0, -5), .bump = false },
        .{ .other = px(b0, b0 + 30), .drag = d(5, 0), .bump = false },
        .{ .other = px(b0 + 3, b0), .drag = d(5, 0), .bump = true },
    };
    for (cases) |c| {
        var b = leashedAt(px(b0, b0));
        b.place(.dog(1), c.other);
        const lines = ticked(&b, 1, &.{}, &.{c.drag});
        if (c.bump) {
            try testing.expectEqual(@as(?Critter, .dog(1)), bumpOf(&lines));
            try testing.expectEqual(px(b0, b0), b.dogs[0]);
        } else {
            try testing.expectEqual(@as(?Critter, null), bumpOf(&lines));
            try testing.expectEqual(Point{ .x = physics.px(b0) + c.drag.dx, .y = physics.px(b0) + c.drag.dy }, b.dogs[0]);
        }
    }
}

// ------------------------------------------ the torus' seam (decision 14)

test "the seam: the leashed dog dragged across x = 0, then y = 0: it wraps on each axis, the line says where" {
    const world = physics.world;
    var b = leashedAt(px(30, 30));
    const lines = ticked(&b, 1, &.{}, &.{ d(-50, 0), d(0, -50) });
    const after: Point = .{ .x = world - physics.px(20), .y = world - physics.px(20) };
    try testing.expectEqual(after, b.dogs[0]);
    try testing.expectEqual(@as(?Critter, null), bumpOf(&lines));
    try testing.expectEqual(physics.Checked{ .critter = .{ .who = .dog(0), .before = px(30, 30), .after = after } }, lines.slice()[0]);
}

test "the seam: a critter across the corner from the leashed dog is seen, the short way round" {
    const world = physics.world;
    var b = leashedAt(px(60, 60));
    // Dog 1, another breed, 100 px west and north across the corner:
    // within `wary` of the leashed dog.
    b.place(.dog(1), .{ .x = world - physics.px(40), .y = world - physics.px(40) });
    const sc = physics.Scene.of(&b).?;
    try testing.expectEqual(@as(usize, 2), sc.len);
    try testing.expectEqual(px(-100, -100), physics.delta(b.dogs[0], b.dogs[1]));
    try testing.expect(physics.measure(physics.delta(b.dogs[0], b.dogs[1])) < physics.measureOf(physics.wary));
}

// -------------------------------------------------- bumps, timer, rest

test "a bump ends the drag, not the leash: the dog stops just short, the rest of the tick's drag is dropped, the leash comes off let_go_ticks later" {
    // Dog 5 touching the leashed dog's east side: the drag's first pixel
    // presses into it before it can get out of the way (there is no edge
    // to pin it against on the torus, decision 14).
    const short = px(16000, 16000);
    var b = leashedAt(short);
    b.place(.dog(5), .{ .x = short.x + 2 * physics.dog_half, .y = short.y });
    const lines = ticked(&b, 10, &.{}, &.{ d(80, 0), d(0, 30) });
    try testing.expectEqual(short, b.dogs[0]);
    try testing.expectEqual(@as(?Critter, .dog(5)), bumpOf(&lines));
    try testing.expectEqual(physics.Hold{ .leashed = .{ .dog = 0, .drag = .{ .ended = 10 } } }, b.hold);
    // The bump is the last line, after the critter lines.
    try testing.expect(lines.slice()[lines.len - 1] == .bump);
    // A drag with no drag on is ignored.
    _ = ticked(&b, 11, &.{}, &.{d(-10, 0)});
    try testing.expectEqual(short, b.dogs[0]);
    const release = 10 + physics.let_go_ticks;
    var t: physics.Tick = 12;
    while (t < release) : (t += 1) {
        const l = ticked(&b, t, &.{}, &.{});
        try testing.expect(!hasRest(&l));
        try testing.expect(b.hold == .leashed);
    }
    const last = ticked(&b, release, &.{}, &.{});
    try testing.expect(last.slice()[last.len - 1] == .release);
    try testing.expectEqual(@as(u16, 0), last.slice()[last.len - 1].release);
    try testing.expectEqual(physics.Hold.none, b.hold);
}

test "a grab as the timer runs out beats the release; a letgo then starts the timer again" {
    var b = leashedAt(px(16000, 16000));
    _ = ticked(&b, 10, &.{.letgo}, &.{});
    try testing.expectEqual(physics.Drag{ .ended = 10 }, b.hold.leashed.drag);
    const release = 10 + physics.let_go_ticks;
    var t: physics.Tick = 11;
    while (t < release) : (t += 1) _ = ticked(&b, t, &.{}, &.{});
    const lines = ticked(&b, release, &.{.grab}, &.{});
    for (lines.slice()) |c| try testing.expect(c != .release);
    try testing.expectEqual(physics.Drag.on, b.hold.leashed.drag);
    _ = ticked(&b, release + 1, &.{.letgo}, &.{});
    try testing.expectEqual(physics.Drag{ .ended = release + 1 }, b.hold.leashed.drag);
}

test "a bump that presses two critters at once names the higher-ranked" {
    const from = px(16000, 16000);
    var b = leashedAt(from);
    // Two dogs touching the leashed dog's east side, one above the other's
    // top: the first pixel of the drag presses both.
    b.place(.dog(9), .{ .x = from.x + 2 * physics.dog_half, .y = from.y + physics.dog_half });
    b.place(.dog(5), .{ .x = from.x + 2 * physics.dog_half, .y = from.y - physics.dog_half });
    const lines = ticked(&b, 1, &.{}, &.{d(80, 0)});
    try testing.expectEqual(@as(?Critter, .dog(5)), bumpOf(&lines));
    try testing.expectEqual(from, b.dogs[0]);
}

test "grab, letgo, grab at one tick leaves a drag on, the displacements played; letgo with no drag on is a no-op" {
    var b = leashedAt(px(16000, 16000));
    b.hold.leashed.drag = .{ .ended = 3 };
    _ = ticked(&b, 5, &.{ .grab, .letgo, .grab }, &.{d(5, 0)});
    try testing.expectEqual(physics.Drag.on, b.hold.leashed.drag);
    try testing.expectEqual(px(16005, 16000), b.dogs[0]);
    _ = ticked(&b, 6, &.{.letgo}, &.{d(5, 0)});
    try testing.expectEqual(physics.Drag{ .ended = 6 }, b.hold.leashed.drag);
    try testing.expectEqual(px(16010, 16000), b.dogs[0]);
    _ = ticked(&b, 7, &.{.letgo}, &.{});
    try testing.expectEqual(physics.Drag{ .ended = 6 }, b.hold.leashed.drag);
}

test "the inputs' preconditions: a leash while leashed, a release of another dog, a grab with nothing leashed, a 17th input" {
    var b = leashedAt(px(16000, 16000));
    b.place(.dog(1), px(17000, 16000));
    var lines: Lines = .{};
    try testing.expectEqual(@as(?physics.Refusal, .leash_while_leashed), physics.tick(&b, 1, &.{.{ .leash = 1 }}, &.{}, &lines));
    try testing.expectEqual(@as(?physics.Refusal, .release_not_leashed), physics.tick(&b, 1, &.{.{ .release = 1 }}, &.{}, &lines));
    try testing.expectEqual(@as(?physics.Refusal, null), physics.tick(&b, 1, &.{ .{ .release = 0 }, .{ .leash = 1 } }, &.{}, &lines));
    try testing.expectEqual(@as(?u16, 1), b.leashedDog());
    var c = Board.empty();
    try testing.expectEqual(@as(?physics.Refusal, .grab_unleashed), physics.tick(&c, 1, &.{.grab}, &.{}, &lines));
    try testing.expectEqual(@as(?physics.Refusal, .leash_no_such_dog), physics.tick(&c, 1, &.{.{ .leash = 3 }}, &.{}, &lines));
    var many: [17]physics.Human = @splat(.letgo);
    try testing.expectEqual(@as(?physics.Refusal, .too_many_inputs), physics.tick(&b, 2, &many, &.{}, &lines));
}

test "rest: nothing moved, no input but a view or held, no timer running; the pointer held still rests too" {
    var b = leashedAt(px(16000, 16000));
    var l = ticked(&b, 1, &.{}, &.{});
    try testing.expect(hasRest(&l));
    try testing.expectEqual(@as(usize, 1), l.len);
    // An input is not a rest, even moving nothing.
    l = ticked(&b, 2, &.{.grab}, &.{});
    try testing.expect(!hasRest(&l));
    // Dogs move only in a drag: a dog out of its band, with no drag, rests.
    b.place(.dog(4), px(16200, 16000));
    l = ticked(&b, 3, &.{}, &.{});
    try testing.expect(hasRest(&l));
    // Unleashed, nothing moves and nothing is timed.
    var u = Board.laidOut();
    l = ticked(&u, 1, &.{}, &.{});
    try testing.expect(hasRest(&l));
}

// ------------------------------------------------------------ the wishes

// ----------------------------------------------------------- pixel-ticks

// --------------------------------------------------------------- the cap

test "merged and capped: past 16 displacements are added into the 16th; each axis has 100 px a tick, cut where it crosses" {
    var raw: [20]physics.Disp = undefined;
    for (&raw, 0..) |*r, i| r.* = .{ .dx = physics.px(10), .dy = 0, .ms = @intCast(i) };
    const c = physics.mergeAndCap(&raw);
    try testing.expectEqual(@as(usize, 16), c.len);
    // The cap in 10 px steps: those whole, the rest cut to nothing.
    const whole: usize = @intCast(@divExact(physics.cap, physics.px(10)));
    try testing.expect(whole < 16);
    for (c.slice()[0..whole]) |one| try testing.expectEqual(physics.px(10), one.dx);
    for (c.slice()[whole..]) |one| try testing.expectEqual(@as(i32, 0), one.dx);
    try testing.expectEqual(@as(u32, 19), c.list[15].ms);
    try testing.expect(physics.withinCap(c.slice()));
    // Three fifths of the cap, then three fifths more: cut to two fifths.
    const fifth = @divExact(physics.cap, physics.px(5));
    const cut = physics.mergeAndCap(&.{ d(3 * fifth, 10), d(3 * fifth, -10), d(5, 5) });
    try testing.expectEqualSlices(physics.Disp, &.{ d(3 * fifth, 10), d(2 * fifth, -10), d(0, 5) }, cut.slice());
    try testing.expect(!physics.withinCap(&.{ d(3 * fifth, 0), d(2 * fifth + 1, 0) }));
    try testing.expect(physics.withinCap(&.{ d(3 * fifth, 0), d(-2 * fifth, 0) }));
}

test "a tick's drag moves the leashed dog at most 100 px on each axis" {
    var b = leashedAt(px(16000, 16000));
    // Nine tenths of the cap, twice, each way: the cap, each way.
    const most = @divExact(physics.cap, physics.px(10)) * 9;
    const c = physics.mergeAndCap(&.{ d(most, -most), d(most, -most) });
    _ = ticked(&b, 1, &.{}, c.slice());
    try testing.expectEqual(Point{ .x = physics.px(16000) + physics.cap, .y = physics.px(16000) - physics.cap }, b.dogs[0]);
}

test "across the seam the drag wraps, and carries on (decision 14: no edge)" {
    var b = leashedAt(px(30, 16000));
    const lines = ticked(&b, 1, &.{}, &.{ d(-50, 0), d(0, 20) });
    // 50 px west from 30 px: 20 px short of the world's east side.
    try testing.expectEqual(Point{ .x = physics.world - physics.px(20), .y = physics.px(16020) }, b.dogs[0]);
    try testing.expectEqual(@as(?Critter, null), bumpOf(&lines));
    try testing.expectEqual(physics.Drag.on, b.hold.leashed.drag);
}

// ------------------------------------------- what the physics sees (12, 14)

test "a critter whose point stands in a tile not meeting the region is unseen, though its square pokes into one that does" {
    // The leashed dog the region's reach west of a tile's west edge: the
    // region ends on it.
    const edge = physics.tile * 35;
    const from: Point = .{ .x = edge - physics.region_reach, .y = edge - physics.region_reach };
    try testing.expectEqual(edge, physics.region(from).hi.x);
    var b = leashedAt(from);
    // Cow 0 just past the edge (its square pokes back over it); cow 1 just
    // short of it, far south: seen, as every critter in the region's tiles.
    b.place(.cow(0), .{ .x = edge + physics.px(10), .y = from.y });
    b.place(.cow(1), .{ .x = edge - physics.px(10), .y = from.y + physics.px(1000) });
    const sc = physics.Scene.of(&b).?;
    try testing.expectEqual(@as(usize, 2), sc.len);
    try testing.expect(sc.list()[1].who.eql(.cow(1)));
}

test "the torus' tiles (decision 14): a region across x = 0, y = 0 and the corner spans the wrapped tiles; tileOf wraps a point" {
    const w = tiles.world_tiles;
    const edge_in = physics.px(200);
    const mid = physics.world / 2;
    // Across x = 0: columns 61 to 63 and 0 to 3, named 61 to 67.
    const west = physics.TileSpan.of(physics.region(.{ .x = edge_in, .y = mid }));
    try testing.expectEqual(physics.TileSpan{ .col_lo = w - 3, .col_hi = w + 3, .row_lo = 29, .row_hi = 34 }, west);
    for ([_]i32{ w - 3, w - 1, 0, 3 }) |c| try testing.expect(west.holds(.{ .col = c, .row = 32 }));
    for ([_]i32{ w - 4, 4 }) |c| try testing.expect(!west.holds(.{ .col = c, .row = 32 }));
    try testing.expect(!west.holds(.{ .col = 0, .row = 35 }));
    // Across y = 0, the mirror.
    const north = physics.TileSpan.of(physics.region(.{ .x = mid, .y = edge_in }));
    try testing.expectEqual(physics.TileSpan{ .col_lo = 29, .col_hi = 34, .row_lo = w - 3, .row_hi = w + 3 }, north);
    // Across the corner from the far side: 60 to 63 and 0 to 2 both ways.
    const corner = physics.TileSpan.of(physics.region(.{ .x = physics.world - edge_in, .y = physics.world - edge_in }));
    try testing.expectEqual(physics.TileSpan{ .col_lo = 60, .col_hi = 66, .row_lo = 60, .row_hi = 66 }, corner);
    for ([_][2]i32{ .{ 63, 63 }, .{ 0, 0 }, .{ 63, 0 }, .{ 0, 63 }, .{ 2, 60 } }) |cr| try testing.expect(corner.holds(.{ .col = cr[0], .row = cr[1] }));
    try testing.expect(!corner.holds(.{ .col = 3, .row = 0 }));
    try testing.expectEqual(tiles.Tile{ .col = 2, .row = 0 }, physics.TileSpan.at(w + 2, w));
    // tileOf: a point wrapped first.
    try testing.expectEqual(tiles.Tile{ .col = w - 1, .row = 0 }, physics.tileOf(.{ .x = -1, .y = physics.world }));
    try testing.expectEqual(tiles.Tile{ .col = 0, .row = w - 1 }, physics.tileOf(.{ .x = physics.world + physics.tile - 1, .y = -physics.tile }));
}

test "a critter across the seam from the leashed dog, in the region's wrapped tiles, is seen" {
    const edge_in = physics.px(200);
    var b = leashedAt(.{ .x = edge_in, .y = edge_in });
    b.place(.cow(0), .{ .x = physics.world - edge_in, .y = physics.world - edge_in });
    b.place(.cow(1), .{ .x = physics.world / 2, .y = edge_in });
    const sc = physics.Scene.of(&b).?;
    try testing.expectEqual(@as(usize, 2), sc.len);
    try testing.expect(sc.list()[1].who.eql(.cow(0)));
}

/// A page's board for test 12: the critters of the tiles it has.
const PageBoard = struct {
    board: Board,
    held: [tiles.world_tiles][tiles.world_tiles]Held = @splat(@splat(.not_held)),

    const Held = enum { not_held, held };

    fn init(server: *const Board) PageBoard {
        var p: PageBoard = .{ .board = server.* };
        p.board.dog_known = @splat(.absent);
        p.board.cow_known = @splat(.absent);
        return p;
    }

    /// Holds the tiles of `span` it doesn't hold yet, taking their critters
    /// as the server has them.
    fn hold(p: *PageBoard, server: *const Board, span: physics.TileSpan) void {
        var row = span.row_lo;
        while (row <= span.row_hi) : (row += 1) {
            var col = span.col_lo;
            while (col <= span.col_hi) : (col += 1) {
                const t = physics.TileSpan.at(col, row);
                if (p.held[@intCast(t.row)][@intCast(t.col)] == .held) continue;
                p.held[@intCast(t.row)][@intCast(t.col)] = .held;
                for (server.dogs, 0..) |at, i| if (std.meta.eql(physics.tileOf(at), t)) p.board.place(.dog(@intCast(i)), at);
                for (server.cows, 0..) |at, i| if (std.meta.eql(physics.tileOf(at), t)) p.board.place(.cow(@intCast(i)), at);
            }
        }
    }
};

test "subscribing more tiles changes nothing: the server's board, a page holding only the region's tiles and one holding a large display's give the same lines, every tick" {
    // Two walks, each with a letgo (the walk's dogs get out of the way, so
    // these walks rarely bump; the bump tests hold the page to the server
    // there). A hundred ticks each; four hundred in the slow tier.
    const ticks: physics.Tick = switch (fuzz) {
        .fast => 100,
        .full => 400,
    };
    var moved: usize = 0;
    var walks: usize = 0;
    var seed: u64 = 1;
    while (walks < 2 and seed <= 16) : (seed += 1) {
        const walk = try walkCompared(seed, ticks);
        moved += walk.moved;
        if (walk.letgos > 0) walks += 1;
    }
    try testing.expectEqual(@as(usize, 2), walks);
    try testing.expect(moved > 100);
}

const Walk = struct { bumps: usize = 0, letgos: usize = 0, moved: usize = 0 };

fn walkCompared(seed: u64, ticks: physics.Tick) !Walk {
    var walk: Walk = .{};
    var server = Board.laidOut();
    // Dog 112, in the park's middle.
    const leashed: u16 = 112;
    var small = PageBoard.init(&server);
    var large = PageBoard.init(&server);
    large.hold(&server, .{ .col_lo = 26, .col_hi = 37, .row_lo = 26, .row_hi = 37 });
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();
    var heading = d(30, 10);
    var t: physics.Tick = 1;
    var humans: [2]physics.Human = undefined;
    var nh: usize = 1;
    humans[0] = .{ .leash = leashed };
    while (t <= ticks) : (t += 1) {
        // The page holds the region's tiles before it runs the tick.
        if (server.leashedDog() == null and nh == 0) {
            humans[0] = .{ .leash = leashed };
            nh = 1;
        }
        const at = server.dogs[leashed];
        const span = physics.TileSpan.of(physics.region(at));
        small.hold(&server, span);
        large.hold(&server, span);
        if (rand.uintLessThan(u32, 20) == 0) heading = d(rand.intRangeAtMost(i32, -40, 40), rand.intRangeAtMost(i32, -40, 40));
        var raw: [3]physics.Disp = undefined;
        const n: usize = rand.uintLessThan(u32, 4);
        for (raw[0..n]) |*r| r.* = .{ .dx = @divTrunc(heading.dx, 2) + physics.px(rand.intRangeAtMost(i32, -3, 3)), .dy = @divTrunc(heading.dy, 2), .ms = 0 };
        const drag = physics.mergeAndCap(raw[0..n]);
        if (rand.uintLessThan(u32, 40) == 0 and server.leashedDog() != null) {
            humans[nh] = .letgo;
            nh += 1;
            walk.letgos += 1;
        }
        const a = ticked(&server, t, humans[0..nh], drag.slice());
        const b = ticked(&small.board, t, humans[0..nh], drag.slice());
        const c = ticked(&large.board, t, humans[0..nh], drag.slice());
        try testing.expectEqualSlices(physics.Checked, a.slice(), b.slice());
        try testing.expectEqualSlices(physics.Checked, a.slice(), c.slice());
        nh = 0;
        if (bumpOf(&a) != null) walk.bumps += 1;
        walk.moved += a.len;
        // After a bump or a letgo, grab again now and then.
        if (server.hold == .leashed and server.hold.leashed.drag != .on and rand.uintLessThan(u32, 4) == 0) {
            humans[0] = .grab;
            nh = 1;
        }
    }
    return walk;
}

// ------------------------------------------- the arithmetic on every target

test "the wish arithmetic at the i64 extremes gives the same bits on every target: a seeded fuzz, folded into one checksum (test 11)" {
    // Fixed ranges, not the tuned numbers, so the checksum pins only the
    // arithmetic: vectors across a 32,000 px world (squared lengths to
    // 1.3e14), lengths to 1,000 px (products to 4e12).
    const span: i32 = physics.px(32_000);
    const longest: i32 = physics.px(1000);
    var prng: std.Random.DefaultPrng = .init(11);
    const rand = prng.random();
    var crc = std.hash.Crc32.init();
    for (0..fuzzed(200_000)) |k| {
        const reach: i32 = if (k % 2 == 0) span else physics.px(500);
        const v: Point = .{ .x = rand.intRangeAtMost(i32, -reach, reach), .y = rand.intRangeAtMost(i32, -reach, reach) };
        if (v.x == 0 and v.y == 0) continue;
        const w = physics.wishAlong(v, rand.intRangeAtMost(i32, 0, longest));
        const total: Point = .{ .x = rand.intRangeAtMost(i32, -span, span), .y = rand.intRangeAtMost(i32, -span, span) };
        const s = if (total.x == 0 and total.y == 0) total else physics.wishAlong(total, rand.intRangeAtMost(i32, 0, longest));
        const r = physics.lengthOf(physics.measure(v));
        crc.update(std.mem.asBytes(&[_]i64{ w.x, w.y, s.x, s.y, r }));
    }
    // Golden: the first 20,000 samples' checksum, and all 200,000's.
    // The same on every target.
    try testing.expectEqual(@as(u32, switch (fuzz) {
        .fast => 2874612707,
        .full => 1179115397,
    }), crc.final());
}

test "shortWay is the @mod formula, at every edge and over a seeded fuzz of the whole i32 range (202)" {
    const w = physics.world;
    const h = physics.half_world;
    const plain = struct {
        fn f(v: i32) i32 {
            return @mod(v + h, w) - h;
        }
    }.f;
    const edges = [_]i32{ 0, 1, -1, h - 1, h, h + 1, -h - 1, -h, -h + 1, w - 1, w, w + 1, -w - 1, -w, -w + 1, w + h - 1, w + h, w + h + 1, -w - h - 1, -w - h, -w - h + 1, 2 * w, -2 * w, std.math.maxInt(i32) - h, std.math.minInt(i32) + h };
    for (edges) |v| try testing.expectEqual(plain(v), physics.shortWay(v));
    var prng: std.Random.DefaultPrng = .init(202);
    const r = prng.random();
    for (0..fuzzed(100_000)) |_| {
        const v = r.intRangeAtMost(i32, std.math.minInt(i32) + h, std.math.maxInt(i32) - h);
        try testing.expectEqual(plain(v), physics.shortWay(v));
        const close = r.intRangeAtMost(i32, -w - h, w + h);
        try testing.expectEqual(plain(close), physics.shortWay(close));
    }
}

test "quotientAlong is @divTrunc(c * length, l) for |c| <= l: either side of 2^32, the i32 range's ends, and over a seeded fuzz (202)" {
    const plain = struct {
        fn f(c: i32, length: i32, l: i64) i32 {
            return @intCast(@divTrunc(@as(i64, c) * length, l));
        }
    }.f;
    const max = std.math.maxInt(i32);
    const ls = [_]i64{ 1, 2, 3, 255, 256, 65535, 65536, 65537, max - 1, max, @as(i64, max) + 1, 1 << 32, (1 << 32) + 1, 3 << 31 };
    const lengths = [_]i32{ 0, 1, -1, 2, 255, 256, 65535, 65536, 65537, -65537, max, -max, max - 1, -(max - 1) };
    for (ls) |l| for (lengths) |length| {
        const top: i32 = @intCast(@min(l, max));
        for ([_]i32{ 0, 1, 2, top - 1, top, @divTrunc(top, 2), @divTrunc(top, 3) + 1 }) |c| {
            if (c > top) continue;
            try testing.expectEqual(plain(c, length, l), physics.quotientAlong(c, length, l));
            try testing.expectEqual(plain(-c, length, l), physics.quotientAlong(-c, length, l));
        }
    };
    var prng: std.Random.DefaultPrng = .init(2027);
    const r = prng.random();
    for (0..fuzzed(100_000)) |_| {
        const l = r.intRangeAtMost(i64, 1, if (r.boolean()) 1 << 17 else 1 << 33);
        const c = r.intRangeAtMost(i32, -@as(i32, @intCast(@min(l, max))), @intCast(@min(l, max)));
        const length = r.intRangeAtMost(i32, -max, max) >> r.int(u5);
        try testing.expectEqual(plain(c, length, l), physics.quotientAlong(c, length, l));
    }
}

test "holdsPoint is holds(tileOf(p)): spans that wrap, cover the world or more, and points anywhere in i32 (202)" {
    var prng: std.Random.DefaultPrng = .init(2029);
    const r = prng.random();
    const wt: i32 = tiles.world_tiles;
    for (0..fuzzed(20_000)) |_| {
        const lo = r.intRangeLessThan(i32, 0, wt);
        const span: physics.TileSpan = .{
            .col_lo = lo,
            .col_hi = lo + r.intRangeAtMost(i32, -1, wt + 2),
            .row_lo = r.intRangeLessThan(i32, 0, wt),
            .row_hi = 0,
        };
        var sp = span;
        sp.row_hi = sp.row_lo + r.intRangeAtMost(i32, -1, wt + 2);
        for (0..8) |k| {
            const p: physics.Point = switch (k % 3) {
                0 => .{ .x = r.int(i32), .y = r.int(i32) },
                1 => .{ .x = r.intRangeLessThan(i32, 0, physics.world), .y = r.intRangeLessThan(i32, 0, physics.world) },
                // A tile's edge, each side.
                else => .{ .x = (lo + r.intRangeAtMost(i32, -2, 3)) * physics.tile + r.intRangeAtMost(i32, -1, 0), .y = sp.row_hi * physics.tile + r.intRangeAtMost(i32, -1, physics.tile) },
            };
            try testing.expectEqual(sp.holds(physics.tileOf(p)), sp.holdsPoint(p));
        }
    }
}

test "the walk: a dog already waiting takes a nearer dog's key (Steve's 172, 176, 180, 174, 184 at 69927)" {
    // From play: the leashed dog (172 there, 0 here), 176 (4) 55 px off,
    // 180 (8) 139, 174 (2, another breed) 186, 184 (12) 240 but 101 from
    // 180. 176 lines up 184 first, far (207); 180, visited next, is
    // nearer it, so 184 comes before 174.
    const at = px(16000, 16000);
    var b = leashedAt(at);
    b.place(.dog(4), .{ .x = at.x + physics.px(55), .y = at.y + physics.px(33) });
    b.place(.dog(8), .{ .x = at.x + physics.px(62), .y = at.y + physics.px(139) });
    b.place(.dog(2), .{ .x = at.x - physics.px(187), .y = at.y + physics.px(124) });
    b.place(.dog(12), .{ .x = at.x + physics.px(83), .y = at.y + physics.px(240) });
    const lines = ticked(&b, 1, &.{}, &.{d(1, 0)});
    try testing.expectEqualSlices(u16, &.{ 4, 8, 12, 2 }, lines.walk[0..lines.walk_len]);
}

test "the invariant: seeded drags through the laid-out park, and no two critters the physics sees ever overlap" {
    // The veto keeps it by induction (decision 22); this is the induction's
    // check over the whole park: long drags, bumps, let-gos and grabs.
    var prng: std.Random.DefaultPrng = .init(22);
    const rand = prng.random();
    var b = Board.laidOut();
    var lines: Lines = .{};
    try testing.expectEqual(@as(?physics.Refusal, null), physics.tick(&b, 1, &.{.{ .leash = 112 }}, &.{}, &lines));
    var found: [8][2]physics.Critter = undefined;
    var t: physics.Tick = 2;
    while (t < 2 + fuzzed(400)) : (t += 1) {
        const drag = [1]physics.Disp{.{ .dx = physics.px(rand.intRangeAtMost(i32, -12, 12)), .dy = physics.px(rand.intRangeAtMost(i32, -12, 12)) }};
        const humans: []const physics.Human = if (b.hold == .leashed and b.hold.leashed.drag != .on) &.{.grab} else &.{};
        try testing.expectEqual(@as(?physics.Refusal, null), physics.tick(&b, t, humans, &drag, &lines));
        try testing.expectEqual(@as(usize, 0), physics.overlaps(&b, &found));
    }
}
