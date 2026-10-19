//! The physics' tests, each with its purpose (docs/PHYSICS.md, "Tested"):
//! the no-overlap invariant over seeded drags; more held tiles change
//! nothing; the torus' seam and tiles; bumps, the timer, rest and the
//! inputs; the cap; the arithmetic on every target; and the few motion
//! cases that came from play (the walk's keys, the edge, the cows, the
//! nudge). Poop and chickens are physics_trails_test.zig's; the worked
//! example is physics_judge_test.zig's.

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

/// The world's middle, in whole pixels: scenes stand here, clear of the
/// seam unless they mean it.
const mid: i32 = tiles.world_px / 2;

test "physics.zig's Kind numbers the kinds as World.roc's kinds does, each its size" {
    const kinds = @import("world.zig").world.kinds;
    const fields = @typeInfo(physics.Kind).@"enum".fields;
    try testing.expectEqual(fields.len, kinds.len);
    inline for (fields) |f| {
        try testing.expectEqualStrings(f.name, kinds[f.value].name);
        const half = physics.Critter.half(.{ .kind = @enumFromInt(f.value), .n = 0 });
        try testing.expectEqual(physics.px(kinds[f.value].px / 2), half);
    }
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
    b.place(.of(.dog, 0), at);
    b.hold = .{ .leashed = .{ .dog = 0, .drag = .on } };
    return b;
}

fn ticked(b: *Board, t: physics.Tick, humans: []const physics.Human, drag: []const physics.Disp) Lines {
    var lines: Lines = .{};
    if (physics.tick(b, t, humans, drag, &lines)) |r| std.debug.panic("refused: {t}", .{r});
    return lines;
}

fn bumpOf(lines: *const Lines) ?physics.Bumped {
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

// ------------------------------------------- overlaps that slipped through

test "the leashed dog overlapping another: a bump only when the drag shrinks |Δ| on its axis or would carry it past; along it, away, or from Δ = 0, free" {
    // Dog 1 overlapping the leashed dog (dogs are 2 * dog_half a side).
    const b0 = mid;
    const Case = struct { other: Point, drag: physics.Disp, bump: bool };
    const cases = [_]Case{
        .{ .other = px(b0 + 21, b0), .drag = d(5, 0), .bump = true },
        .{ .other = px(b0 + 21, b0), .drag = d(-5, 0), .bump = false },
        .{ .other = px(b0 + 21, b0), .drag = d(0, 5), .bump = false },
        .{ .other = px(b0 + 21, b0 + 7), .drag = d(0, 5), .bump = true },
        .{ .other = px(b0 + 21, b0 + 7), .drag = d(0, -5), .bump = false },
        .{ .other = px(b0, b0 + 21), .drag = d(5, 0), .bump = false },
        .{ .other = px(b0 + 2, b0), .drag = d(5, 0), .bump = true },
    };
    for (cases) |c| {
        var b = leashedAt(px(b0, b0));
        b.place(.of(.dog, 1), c.other);
        const lines = ticked(&b, 1, &.{}, &.{c.drag});
        if (c.bump) {
            try testing.expectEqual(@as(?physics.Bumped, .{ .critter = .of(.dog, 1) }), bumpOf(&lines));
            try testing.expectEqual(px(b0, b0), b.of(.dog)[0]);
        } else {
            try testing.expectEqual(@as(?physics.Bumped, null), bumpOf(&lines));
            try testing.expectEqual(Point{ .x = physics.px(b0) + c.drag.dx, .y = physics.px(b0) + c.drag.dy }, b.of(.dog)[0]);
        }
    }
}

// ------------------------------------------ the torus' seam (decision 14)

test "the seam: the leashed dog dragged across x = 0, then y = 0: it wraps on each axis, the line says where" {
    const world = physics.world;
    var b = leashedAt(px(30, 30));
    const lines = ticked(&b, 1, &.{}, &.{ d(-50, 0), d(0, -50) });
    const after: Point = .{ .x = world - physics.px(20), .y = world - physics.px(20) };
    try testing.expectEqual(after, b.of(.dog)[0]);
    try testing.expectEqual(@as(?physics.Bumped, null), bumpOf(&lines));
    try testing.expectEqual(physics.Checked{ .critter = .{ .who = .of(.dog, 0), .before = px(30, 30), .after = after } }, lines.slice()[0]);
}

test "the seam: a critter across the corner from the leashed dog is seen, the short way round" {
    const world = physics.world;
    var b = leashedAt(px(60, 60));
    // Dog 1, another breed, 100 px west and north across the corner:
    // within `wary` of the leashed dog.
    b.place(.of(.dog, 1), .{ .x = world - physics.px(40), .y = world - physics.px(40) });
    const sc = physics.Scene.of(&b).?;
    try testing.expectEqual(@as(usize, 2), sc.len);
    try testing.expectEqual(px(-100, -100), physics.delta(b.of(.dog)[0], b.of(.dog)[1]));
    try testing.expect(physics.measure(physics.delta(b.of(.dog)[0], b.of(.dog)[1])) < physics.measureOf(physics.wary));
}

// -------------------------------------------------- bumps, timer, rest

test "a bump ends the drag, not the leash: the dog stops just short, the rest of the tick's drag is dropped, the leash comes off let_go_ticks later" {
    // Dog 5 touching the leashed dog's east side: the drag's first pixel
    // presses into it before it can get out of the way (there is no edge
    // to pin it against on the torus, decision 14).
    const short = px(mid, mid);
    var b = leashedAt(short);
    b.place(.of(.dog, 5), .{ .x = short.x + 2 * physics.halfOf(.dog), .y = short.y });
    const lines = ticked(&b, 10, &.{}, &.{ d(80, 0), d(0, 30) });
    try testing.expectEqual(short, b.of(.dog)[0]);
    try testing.expectEqual(@as(?physics.Bumped, .{ .critter = .of(.dog, 5) }), bumpOf(&lines));
    try testing.expectEqual(physics.Hold{ .leashed = .{ .dog = 0, .drag = .{ .ended = 10 } } }, b.hold);
    // The bump is the last line, after the critter lines.
    try testing.expect(lines.slice()[lines.len - 1] == .bump);
    // A drag with no drag on is ignored.
    _ = ticked(&b, 11, &.{}, &.{d(-10, 0)});
    try testing.expectEqual(short, b.of(.dog)[0]);
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
    var b = leashedAt(px(mid, mid));
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
    const from = px(mid, mid);
    var b = leashedAt(from);
    // Two dogs touching the leashed dog's east side, one above the other's
    // top: the first pixel of the drag presses both.
    b.place(.of(.dog, 9), .{ .x = from.x + 2 * physics.halfOf(.dog), .y = from.y + physics.halfOf(.dog) });
    b.place(.of(.dog, 5), .{ .x = from.x + 2 * physics.halfOf(.dog), .y = from.y - physics.halfOf(.dog) });
    const lines = ticked(&b, 1, &.{}, &.{d(80, 0)});
    try testing.expectEqual(@as(?physics.Bumped, .{ .critter = .of(.dog, 5) }), bumpOf(&lines));
    try testing.expectEqual(from, b.of(.dog)[0]);
}

test "grab, letgo, grab at one tick leaves a drag on, the displacements played; letgo with no drag on is a no-op" {
    var b = leashedAt(px(mid, mid));
    b.hold.leashed.drag = .{ .ended = 3 };
    _ = ticked(&b, 5, &.{ .grab, .letgo, .grab }, &.{d(5, 0)});
    try testing.expectEqual(physics.Drag.on, b.hold.leashed.drag);
    try testing.expectEqual(px(mid + 5, mid), b.of(.dog)[0]);
    _ = ticked(&b, 6, &.{.letgo}, &.{d(5, 0)});
    try testing.expectEqual(physics.Drag{ .ended = 6 }, b.hold.leashed.drag);
    try testing.expectEqual(px(mid + 10, mid), b.of(.dog)[0]);
    _ = ticked(&b, 7, &.{.letgo}, &.{});
    try testing.expectEqual(physics.Drag{ .ended = 6 }, b.hold.leashed.drag);
}

test "the inputs' preconditions: a leash while leashed, a release of another dog, a grab with nothing leashed, a 17th input" {
    var b = leashedAt(px(mid, mid));
    b.place(.of(.dog, 1), px(mid + 900, mid));
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
    var b = leashedAt(px(mid, mid));
    var l = ticked(&b, 1, &.{}, &.{});
    try testing.expect(hasRest(&l));
    try testing.expectEqual(@as(usize, 1), l.len);
    // An input is not a rest, even moving nothing.
    l = ticked(&b, 2, &.{.grab}, &.{});
    try testing.expect(!hasRest(&l));
    // Dogs move only in a drag: a dog out of its band, with no drag, rests.
    b.place(.of(.dog, 4), px(mid + 200, mid));
    l = ticked(&b, 3, &.{}, &.{});
    try testing.expect(hasRest(&l));
    // Unleashed, nothing moves and nothing is timed.
    var u = Board.laidOut();
    l = ticked(&u, 1, &.{}, &.{});
    try testing.expect(hasRest(&l));
}

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
    var b = leashedAt(px(mid, mid));
    // Nine tenths of the cap, twice, each way: the cap, each way.
    const most = @divExact(physics.cap, physics.px(10)) * 9;
    const c = physics.mergeAndCap(&.{ d(most, -most), d(most, -most) });
    _ = ticked(&b, 1, &.{}, c.slice());
    try testing.expectEqual(Point{ .x = physics.px(mid) + physics.cap, .y = physics.px(mid) - physics.cap }, b.of(.dog)[0]);
}

test "across the seam the drag wraps, and carries on (decision 14: no edge)" {
    var b = leashedAt(px(30, mid));
    const lines = ticked(&b, 1, &.{}, &.{ d(-50, 0), d(0, 20) });
    // 50 px west from 30 px: 20 px short of the world's east side.
    try testing.expectEqual(Point{ .x = physics.world - physics.px(20), .y = physics.px(mid + 20) }, b.of(.dog)[0]);
    try testing.expectEqual(@as(?physics.Bumped, null), bumpOf(&lines));
    try testing.expectEqual(physics.Drag.on, b.hold.leashed.drag);
}

// ------------------------------------------- what the physics sees (12, 14)

test "the region is the world: its tiles are every tile once, from (0, 0), wherever the leashed dog stands; tileOf wraps a point" {
    const w = tiles.world_tiles;
    for ([_]Point{ px(0, 0), px(mid, mid), .{ .x = physics.world - 1, .y = 0 } }) |at| {
        try testing.expectEqual(physics.TileSpan{ .col_lo = 0, .col_hi = w - 1, .row_lo = 0, .row_hi = w - 1 }, physics.TileSpan.of(physics.region(at)));
    }
    try testing.expectEqual(tiles.Tile{ .col = w - 1, .row = 0 }, physics.tileOf(.{ .x = -1, .y = physics.world }));
    try testing.expectEqual(tiles.Tile{ .col = 0, .row = w - 1 }, physics.tileOf(.{ .x = physics.world + physics.tile - 1, .y = -physics.tile }));
}

test "the physics sees every critter, wherever it stands: across the seam from the leashed dog, and on the far side of the world" {
    var b = leashedAt(px(10, 10));
    b.place(.of(.cow, 0), .{ .x = physics.world - physics.px(10), .y = physics.world - physics.px(10) });
    b.place(.of(.cow, 1), px(mid, mid));
    b.place(.of(.dog, 5), .{ .x = physics.world / 2 + physics.px(300), .y = physics.px(10) });
    const sc = physics.Scene.of(&b).?;
    try testing.expectEqual(@as(usize, 4), sc.len);
}

test "the walk's neighbours wrap: a dog across the seam, nearer than one on this side, is visited first" {
    // Dog 4 (the leashed dog's breed) 40 px west across x = 0; dog 8 60 px
    // east. The ring search must find dog 4 the short way round.
    var b = leashedAt(px(10, mid));
    b.place(.of(.dog, 4), .{ .x = physics.world - physics.px(30), .y = physics.px(mid) });
    b.place(.of(.dog, 8), px(70, mid));
    const lines = ticked(&b, 1, &.{}, &.{d(0, 1)});
    try testing.expectEqualSlices(u16, &.{ 4, 8 }, lines.walk[0..2]);
}

// ------------------------------------------- the arithmetic on every target

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
    const at = px(mid, mid);
    var b = leashedAt(at);
    b.place(.of(.dog, 4), .{ .x = at.x + physics.px(55), .y = at.y + physics.px(33) });
    b.place(.of(.dog, 8), .{ .x = at.x + physics.px(62), .y = at.y + physics.px(139) });
    b.place(.of(.dog, 2), .{ .x = at.x - physics.px(187), .y = at.y + physics.px(124) });
    b.place(.of(.dog, 12), .{ .x = at.x + physics.px(83), .y = at.y + physics.px(240) });
    const lines = ticked(&b, 1, &.{}, &.{d(1, 0)});
    try testing.expectEqualSlices(u16, &.{ 4, 8, 12, 2 }, lines.walk[0..lines.walk_len]);
}

test "the invariant: seeded drags through the laid-out park, and no two critters the physics sees ever overlap, and none stands on poop, through poops laid, eaten, and chickens shoved" {
    // The veto keeps it by induction (decisions 22, 30); this is the
    // induction's check over the whole park: drags along a heading that
    // turns now and then, bumps, let-gos and grabs. It runs on until the
    // herd has laid a few poops (so some are ripe) and the drag has shoved
    // a chicken: one that moved in a tick it had no reason of its own to
    // (at home, no ripe poop in sight).
    var prng: std.Random.DefaultPrng = .init(22);
    const rand = prng.random();
    var b = Board.laidOut();
    var lines: Lines = .{};
    try testing.expectEqual(@as(?physics.Refusal, null), physics.tick(&b, 1, &.{.{ .leash = 25 }}, &.{}, &lines));
    var found: [8][2]physics.Critter = undefined;
    var heading = d(10, 4);
    var shoved: usize = 0;
    var t: physics.Tick = 2;
    while (t < 2 + fuzzed(400) or b.laid < 3 or shoved == 0) : (t += 1) {
        try testing.expect(t < 2000);
        if (rand.uintLessThan(u32, 16) == 0) heading = d(rand.intRangeAtMost(i32, -12, 12), rand.intRangeAtMost(i32, -12, 12));
        const drag = [1]physics.Disp{.{ .dx = heading.dx + physics.px(rand.intRangeAtMost(i32, -3, 3)), .dy = heading.dy + physics.px(rand.intRangeAtMost(i32, -3, 3)) }};
        const humans: []const physics.Human = if (b.hold == .leashed and b.hold.leashed.drag != .on) &.{.grab} else &.{};
        var idle: [physics.countOf(.chicken)]bool = undefined;
        for (&idle, b.ofMut(.chicken)) |*i, c| i.* = idleChicken(&b, c, @intCast(&i.* - &idle[0]));
        const before: [physics.countOf(.chicken)]physics.Point = b.of(.chicken)[0..physics.countOf(.chicken)].*;
        try testing.expectEqual(@as(?physics.Refusal, null), physics.tick(&b, t, humans, &drag, &lines));
        try testing.expectEqual(@as(usize, 0), physics.overlaps(&b, &found));
        for (idle, before, b.of(.chicken)) |i, was, now| {
            if (i and (was.x != now.x or was.y != now.y)) shoved += 1;
        }
    }
}

/// Whether chicken `n` at `c` has no step of its own to take: at home and
/// no ripe poop within its sight.
fn idleChicken(b: *const Board, c: Point, n: u16) bool {
    if (physics.measure(physics.delta(c, @import("layout.zig").home(.of(.chicken, n)))) > physics.home_band) return false;
    for (b.poops, b.poop_known, 0..) |p, k, slot| {
        if (k == .present and physics.ripe(b.laid, @intCast(slot)) and physics.measure(physics.delta(c, p)) <= physics.chicken_sight) return false;
    }
    return true;
}

test "a cow heeds only its nearest moving critter: a cow within cow_pull, it closes in; a dog, it flees (decision 24)" {
    // The leashed dog, dragged west, scares cow 0 (140 px off, inside
    // `wary`) west. Cow 1, 70 px west of cow 0 and 210 from the dog, has
    // cow 0 nearest, within `cow_pull`: it closes in, east, at half a dog's
    // step. Cow 2 is inside the dog's `wary` (140 px) but cow 0 and cow 1
    // are nearer (88 each, a tie the lower rank wins): it ignores the dog
    // and closes in on cow 0, north. Cow 3, alone 260 px past cow 1 (past
    // `cow_pull`), stays.
    const at = px(mid, mid);
    var b = leashedAt(at);
    b.place(.of(.cow, 0), px(mid - 140, mid));
    b.place(.of(.cow, 1), px(mid - 210, mid));
    b.place(.of(.cow, 2), px(mid - 140, mid + 88));
    b.place(.of(.cow, 3), px(mid - 210, mid - 350));
    _ = ticked(&b, 1, &.{}, &.{d(-1, 0)});
    try testing.expectEqual(physics.px(mid - 140) - 128, b.of(.cow)[0].x);
    try testing.expectEqual(physics.px(mid - 210) + 128, b.of(.cow)[1].x);
    try testing.expectEqual(physics.px(mid - 140), b.of(.cow)[2].x);
    try testing.expectEqual(physics.px(mid + 88) - 128, b.of(.cow)[2].y);
    try testing.expectEqual(px(mid - 210, mid - 350), b.of(.cow)[3]);
}

test "the nudge (decision 25): a lone dog drives three touching cows west in unison; their pull on each other keeps them together" {
    // Steve's case (cows 27, 23, 28 beside dog 185): a row of cows, each
    // touching the next. The dog scares the nearest; without the nudge the
    // cow in its way vetoes its step, and that cow, touching its nearest
    // moving kin, wants nothing: the row is stuck.
    const at = px(mid, mid);
    const touch = 2 * physics.halfOf(.cow);
    var b = leashedAt(at);
    b.place(.of(.cow, 0), px(mid - 140, mid));
    b.place(.of(.cow, 1), .{ .x = physics.px(mid - 140) - touch, .y = physics.px(mid) });
    b.place(.of(.cow, 2), .{ .x = physics.px(mid - 140) - 2 * touch, .y = physics.px(mid) });
    var t: physics.Tick = 1;
    while (t <= 20) : (t += 1) _ = ticked(&b, t, &.{}, &.{d(-10, 0)});
    try testing.expect(b.of(.cow)[0].x < physics.px(mid - 140 - 28));
    try testing.expectEqual(b.of(.cow)[0].x - touch, b.of(.cow)[1].x);
    try testing.expectEqual(b.of(.cow)[1].x - touch, b.of(.cow)[2].x);
    for (b.of(.cow)[0..3]) |c| try testing.expectEqual(physics.px(mid), c.y);
}

test "the nudge stops at a critter not kin: a cow pressed against a dog vetoes the whole row" {
    // One pixel-tick: the dog flees the moving cow 1 only later in it.
    const at = px(mid, mid);
    const touch = 2 * physics.halfOf(.cow);
    var b = leashedAt(at);
    const c0: Point = px(mid - 140, mid);
    const c1: Point = .{ .x = c0.x - touch, .y = c0.y };
    b.place(.of(.cow, 0), c0);
    b.place(.of(.cow, 1), c1);
    b.place(.of(.dog, 1), .{ .x = c1.x - physics.halfOf(.cow) - physics.halfOf(.dog), .y = c1.y });
    _ = ticked(&b, 1, &.{}, &.{d(-1, 0)});
    try testing.expectEqual(c0, b.of(.cow)[0]);
    try testing.expectEqual(c1, b.of(.cow)[1]);
}
