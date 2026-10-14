//! The physics' tests (docs/PHYSICS.md, "Tests to write first"): test 12
//! (more held tiles change nothing) as far as the board can say it; the
//! cows' grid rule (27); the lane (20); pushes and
//! jumps (8, 28, and the nearest spot's ties); coincident centres (9); the
//! leashed dog against an overlap (10); bumps, the timer, rest; the wishes;
//! the cap. The worked example (26) is physics_judge_test.zig's.

const std = @import("std");
const physics = @import("physics.zig");
const jump = @import("physics_jump.zig");
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
    return physics.len2(physics.delta(from, p)) <= @as(i64, physics.awake_reach) * physics.awake_reach;
}

test "a dog's step moves a cow ahead of it, in the scare box and out of the lane: across the step's axis only, away from the dog's line, never farther than the dog stepped" {
    const from = px(16000, 16000);
    const ahead = @divTrunc(physics.scare_box, 2);
    const off = @divTrunc(physics.lane + physics.scare_box, 2);
    try testing.expect(off > physics.lane and off <= physics.scare_box);
    for (four_ways) |w| {
        for ([_]i32{ 1, -1 }) |side| {
            const cow = along(from, w, ahead, side * off);
            try testing.expect(awakeAt(from, cow));
            const after = cowAfter(from, dragAlong(w, 2), cow);
            const moved = physics.delta(cow, after);
            try testing.expectEqual(@as(i32, 0), physics.on(moved, w.axis));
            const by = physics.on(moved, physics.across(w.axis));
            try testing.expectEqual(side, physics.sign(by));
            try testing.expect(physics.mag(by) <= physics.px(2));
        }
    }
}

test "on the dog's line, the cow goes to the dog's right: east's is south, west's north, north's east, south's west" {
    const from = px(16000, 16000);
    // The way across that is the dog's right, for each way: +y is south.
    const rights = [_]i32{ 1, -1, -1, 1 };
    for (four_ways, rights) |w, right| {
        const cow = along(from, w, physics.scare_box, 0);
        const moved = physics.delta(cow, cowAfter(from, dragAlong(w, 2), cow));
        try testing.expectEqual(@as(i32, 0), physics.on(moved, w.axis));
        try testing.expectEqual(right, physics.sign(physics.on(moved, physics.across(w.axis))));
    }
}

test "ahead only, and in the box: a cow at the box's far edge, ahead and off, moves; a 256th past either, beside or behind, stays" {
    const from = px(16000, 16000);
    const w: Way = .{ .axis = .x, .way = 1 };
    // Measured from where the dog's 1 px step takes it.
    const dog_after = along(from, w, physics.px(1), 0);
    const edge = along(dog_after, w, physics.scare_box, physics.scare_box);
    try testing.expect(awakeAt(from, edge));
    try testing.expect(!std.meta.eql(edge, cowAfter(from, d(1, 0), edge)));
    for ([_]Point{
        along(dog_after, w, physics.scare_box + 1, physics.scare_box),
        along(dog_after, w, physics.scare_box, physics.scare_box + 1),
        along(dog_after, w, 0, physics.lane),
        along(dog_after, w, -physics.px(10), physics.lane),
    }) |cow| try testing.expectEqual(cow, cowAfter(from, d(1, 0), cow));
}

test "a diagonal step is the step along x, a pause, then the step along y" {
    const cow = px(1150, 750);
    // East 4 (the cow ahead, north of the line): north 2 px; then south 6
    // (the cow behind on y): nothing.
    try testing.expectEqual(px(1150, 748), cowAfter(px(1000, 1000), d(4, 6), cow));
    var b = leashedAt(px(1000, 1000));
    b.place(.cow(0), cow);
    _ = ticked(&b, 1, &.{}, &.{d(4, 0)});
    _ = ticked(&b, 2, &.{}, &.{d(0, 6)});
    try testing.expectEqual(px(1150, 748), b.cows[0]);
}

test "in the lane: with time to spare, no faster than the dog; at once when the dog is on it; and the dog never comes within the lane" {
    const from = px(16000, 16000);
    // Far ahead on the line: a little, away, no more than the dog's step.
    const far = along(from, .{ .axis = .x, .way = 1 }, physics.scare_box, 0);
    // Time to spare: the lane's reach ahead is at most half the box.
    try testing.expect(physics.scare_box >= 2 * physics.lane);
    const a = cowAfter(from, d(1, 0), far);
    try testing.expectEqual(far.x, a.x);
    try testing.expect(a.y > far.y and a.y - far.y <= physics.px(1));
    // The dog on it (the lane's reach ahead): clear of the lane in one step.
    const on_it = along(from, .{ .axis = .x, .way = 1 }, physics.lane, 0);
    const b = cowAfter(from, d(1, 0), on_it);
    try testing.expectEqual(on_it.x, b.x);
    try testing.expect(b.y - on_it.y >= physics.lane);
    // Dragged at it a pixel a tick from the box's edge, past it: the cow is
    // clear of the lane every tick.
    var board = leashedAt(from);
    board.place(.cow(0), far);
    var t: physics.Tick = 1;
    while (board.dogs[0].x <= far.x + physics.lane) : (t += 1) {
        _ = ticked(&board, t, &.{}, &.{d(1, 0)});
        const gap = physics.delta(board.dogs[0], board.cows[0]);
        try testing.expect(@max(physics.mag(gap.x), physics.mag(gap.y)) >= physics.lane);
        try testing.expectEqual(far.x, board.cows[0].x);
    }
}

test "the world's edge: no room to clear the lane on the cow's side, the other side; no room to scoot, none; a little room, that much" {
    const world = physics.world;
    const w: Way = .{ .axis = .y, .way = -1 };
    // Heading north, the cow against the east wall, a pixel east of the
    // dog's line, the dog on it: it clears the lane to the west.
    try testing.expect(physics.dog_half <= physics.cow_half + physics.px(1));
    const wall_cow = world - physics.cow_half;
    const dog: Point = .{ .x = wall_cow - physics.px(1), .y = physics.px(16000) };
    const cow = along(dog, w, physics.lane, physics.px(1));
    const a = cowAfter(dog, d(0, -1), cow);
    try testing.expectEqual(cow.y, a.y);
    try testing.expect(dog.x - a.x >= physics.lane);
    // Off the line, ahead, wanting east against the wall: no step.
    const off = @divTrunc(physics.lane + physics.scare_box, 2);
    const away: Point = .{ .x = wall_cow - off, .y = physics.px(16000) };
    const pinned = along(away, w, @divTrunc(physics.scare_box, 2), off);
    try testing.expectEqual(pinned, cowAfter(away, d(0, -2), pinned));
    // A quarter pixel of room: exactly that.
    const room = @divExact(physics.unit, 4);
    const close: Point = .{ .x = pinned.x - room, .y = pinned.y };
    try testing.expectEqual(Point{ .x = wall_cow, .y = close.y }, cowAfter(away, d(0, -2), close));
}

test "a 100 px drag (the cap) doesn't pass through a cow: it clears the lane, never moves ahead, and the dog goes by without a bump" {
    // The cow 100 px ahead: the dog ends on its x.
    var b = leashedAt(px(800, 1000));
    b.place(.cow(0), px(900, 1000));
    const lines = ticked(&b, 1, &.{}, &.{d(100, 0)});
    try testing.expectEqual(physics.px(900), b.cows[0].x);
    try testing.expect(b.cows[0].y - physics.px(1000) >= physics.lane);
    try testing.expectEqual(px(900, 1000), b.dogs[0]);
    try testing.expectEqual(@as(?Critter, null), bumpOf(&lines));
}

test "random drags near a cow (seeded): each axis's part moves the cow across it only, and it never comes within the lane" {
    var prng: std.Random.DefaultPrng = .init(0xc0ffee);
    const rand = prng.random();
    var trials: usize = 0;
    while (trials < fuzzed(3000)) {
        const dog = px(rand.intRangeAtMost(i32, 1000, 4000), rand.intRangeAtMost(i32, 1000, 4000));
        var cow: Point = .{ .x = dog.x + physics.px(rand.intRangeAtMost(i32, -200, 200)) + 128 * rand.intRangeAtMost(i32, 0, 1), .y = dog.y + physics.px(rand.intRangeAtMost(i32, -200, 200)) };
        if (@max(physics.mag(cow.x - dog.x), physics.mag(cow.y - dog.y)) < physics.lane) continue;
        trials += 1;
        var b = leashedAt(dog);
        b.place(.cow(0), cow);
        var t: physics.Tick = 1;
        for (0..10) |_| {
            const step = d(rand.intRangeAtMost(i32, -15, 15), rand.intRangeAtMost(i32, -15, 15));
            _ = ticked(&b, t, &.{.grab}, &.{.{ .dx = step.dx, .dy = 0 }});
            try testing.expectEqual(cow.x, b.cows[0].x);
            cow = b.cows[0];
            _ = ticked(&b, t + 1, &.{.grab}, &.{.{ .dx = 0, .dy = step.dy }});
            try testing.expectEqual(cow.y, b.cows[0].y);
            cow = b.cows[0];
            t += 2;
            const at = physics.delta(b.dogs[0], cow);
            try testing.expect(@max(physics.mag(at.x), physics.mag(at.y)) >= physics.lane);
        }
    }
}

test "a drag in the laid-out park scares only cows ahead of it in the box, each across the drag's axis, and the first cow on its line does move" {
    var b = Board.laidOut();
    const cow0 = b.cows[0];
    // Dog 0 on cow 0's line, the box's reach behind it.
    const from: Point = .{ .x = cow0.x - physics.scare_box, .y = cow0.y };
    b.dogs[0] = from;
    b.hold = .{ .leashed = .{ .dog = 0, .drag = .on } };
    const lines = ticked(&b, 1, &.{}, &.{d(10, 0)});
    var cows_moved: usize = 0;
    for (lines.slice()) |c| switch (c) {
        .critter => |l| if (l.who.kind == .cow) {
            cows_moved += 1;
            try testing.expectEqual(l.before.x, l.after.x);
            const gap = physics.delta(from, l.before);
            try testing.expect(gap.x > 0 and gap.x <= physics.scare_box + physics.px(10));
            try testing.expect(physics.mag(gap.y) <= physics.scare_box);
        },
        else => {},
    };
    try testing.expect(cows_moved >= 1);
    try testing.expect(b.cows[0].y != cow0.y);
}

// ------------------------------------------------------------- the lane

test "a cow on the line just past the lane's reach, the drag stepping 1 px: it clears the lane, exactly, in that one step, and stays within the region" {
    const from = px(16000, 16000);
    var b = leashedAt(from);
    const cow: Point = .{ .x = from.x + physics.lane + physics.px(1), .y = from.y };
    b.place(.cow(0), cow);
    const region = physics.region(b.dogs[0]);
    const lines = ticked(&b, 1, &.{}, &.{d(1, 0)});
    try testing.expectEqual(Point{ .x = cow.x, .y = cow.y + physics.lane }, b.cows[0]);
    try testing.expect(region.holds(physics.Rect.square(b.cows[0], physics.cow_half)));
    try testing.expectEqual(Point{ .x = from.x + physics.px(1), .y = from.y }, b.dogs[0]);
    try testing.expectEqual(@as(?Critter, null), bumpOf(&lines));
}

// ------------------------------------------------------ pushes and jumps

/// How far a dog may have gone on its own in a tick of a 1 px drag: one
/// pixel-tick's step, then the tick's own.
const one_px_tick = physics.px(1) + physics.speed;

fn near(p: Point, q: Point, most: i32) bool {
    return physics.mag(p.x - q.x) <= most and physics.mag(p.y - q.y) <= most;
}

test "a cow lands on an awake dog: the dog jumps to the nearest spot clear of everyone and the cow's sweep, then takes its wish steps" {
    const from = px(16000, 16000);
    var b = leashedAt(from);
    const cow: Point = .{ .x = from.x + physics.lane, .y = from.y };
    b.place(.cow(0), cow);
    // Where the cow lands (the lane, south), and a dog overlapping that by
    // 20 px.
    const lands: Point = .{ .x = cow.x, .y = from.y + physics.lane };
    const spot: Point = .{ .x = cow.x, .y = lands.y + physics.cow_half + physics.dog_half };
    b.place(.dog(1), .{ .x = cow.x, .y = spot.y - physics.px(20) });
    _ = ticked(&b, 1, &.{}, &.{d(1, 0)});
    try testing.expectEqual(lands, b.cows[0]);
    try testing.expect(near(b.dogs[1], spot, one_px_tick));
    try testing.expectEqual(Point{ .x = from.x + physics.px(1), .y = from.y }, b.dogs[0]);
    var pairs: [4][2]Critter = undefined;
    try testing.expectEqual(@as(usize, 0), physics.overlaps(&b, &pairs));
}

test "the area the cow swept is no landing spot: a dog under the front of the cow's end square jumps sideways, east before west" {
    const from = px(16000, 16000);
    var b = leashedAt(from);
    const cow: Point = .{ .x = from.x + physics.lane, .y = from.y };
    b.place(.cow(0), cow);
    // Dog 1 touching the cow's south side; the cow lands the lane south.
    const dog1: Point = .{ .x = cow.x, .y = cow.y + physics.cow_half + physics.dog_half };
    b.place(.dog(1), dog1);
    _ = ticked(&b, 1, &.{}, &.{d(1, 0)});
    try testing.expectEqual(Point{ .x = cow.x, .y = from.y + physics.lane }, b.cows[0]);
    // North of the cow is in its sweep; east and west are the nearest.
    try testing.expect(near(b.dogs[1], .{ .x = cow.x + physics.cow_half + physics.dog_half, .y = dog1.y }, one_px_tick));
}

test "a cow lands on a dog in a packed field with nowhere to go: it stops short of the first critter along its sweep, and pushes no one" {
    const from = px(16000, 16000);
    var b = leashedAt(from);
    const cow: Point = .{ .x = from.x + physics.lane, .y = from.y };
    b.place(.cow(0), cow);
    // Dog 1's square starts where the cow's lands: on the lane.
    const dog1: Point = .{ .x = cow.x, .y = from.y + physics.lane + physics.dog_half };
    b.place(.dog(1), dog1);
    // A field of touching dogs on dog 1's grid, 15 x 15 around it, leaving
    // the leashed dog, the cow and the area the cow sweeps.
    const keep_clear = [_]physics.Rect{
        physics.Rect.square(b.dogs[0], physics.dog_half),
        .{ .lo = .{ .x = cow.x - physics.cow_half, .y = cow.y - physics.cow_half }, .hi = .{ .x = cow.x + physics.cow_half, .y = from.y + physics.lane + physics.cow_half } },
    };
    var n: u16 = 2;
    var j: i32 = -7;
    while (j <= 7) : (j += 1) {
        var i: i32 = -7;
        while (i <= 7) : (i += 1) {
            if (i == 0 and j == 0) continue;
            const at: Point = .{ .x = dog1.x + 2 * physics.dog_half * i, .y = dog1.y + 2 * physics.dog_half * j };
            const sq = physics.Rect.square(at, physics.dog_half);
            if (sq.overlaps(keep_clear[0]) or sq.overlaps(keep_clear[1])) continue;
            b.place(.dog(n), at);
            n += 1;
        }
    }
    _ = ticked(&b, 1, &.{}, &.{d(1, 0)});
    // The cow's square stops at dog 1's.
    try testing.expectEqual(Point{ .x = cow.x, .y = dog1.y - physics.dog_half - physics.cow_half }, b.cows[0]);
    try testing.expect(near(b.dogs[1], dog1, one_px_tick));
    var pairs: [4][2]Critter = undefined;
    try testing.expectEqual(@as(usize, 0), physics.overlaps(&b, &pairs));
}

test "a scared cow pushes an awake dog beside it: the dog ends clear, on the far side, in the region; nothing overlaps" {
    const from = px(16000, 16000);
    var b = leashedAt(from);
    const w: Way = .{ .axis = .y, .way = -1 };
    // Ahead of a drag north, east of its line, out of the lane: the cow
    // steps east, into dog 1, touching its east side.
    const cow = along(from, w, physics.scare_box - physics.px(10), @divTrunc(physics.lane + physics.scare_box, 2));
    b.place(.cow(0), cow);
    b.place(.dog(1), .{ .x = cow.x + physics.cow_half + physics.dog_half, .y = cow.y });
    try testing.expect(awakeAt(from, b.dogs[1]));
    const region = physics.region(b.dogs[0]);
    _ = ticked(&b, 1, &.{}, &.{d(0, -40)});
    try testing.expectEqual(cow.y, b.cows[0].y);
    try testing.expect(b.cows[0].x > cow.x);
    try testing.expect(b.dogs[1].x >= b.cows[0].x + physics.cow_half + physics.dog_half);
    try testing.expect(region.holds(physics.Rect.square(b.dogs[1], physics.dog_half)));
    var pairs: [4][2]Critter = undefined;
    try testing.expectEqual(@as(usize, 0), physics.overlaps(&b, &pairs));
}

test "a cow's step stops short of a sleeping dog, where one can stand beside a scared cow (skipped while the sphere holds the scare box's corner and a dog beside it)" {
    const from = px(16000, 16000);
    const w: Way = .{ .axis = .y, .way = -1 };
    // The box's far corner, and a dog 2 px past the cow's east side.
    const cow = along(from, w, physics.scare_box, physics.scare_box);
    const sleeper: Point = .{ .x = cow.x + physics.cow_half + physics.dog_half + physics.px(2), .y = cow.y };
    if (awakeAt(from, sleeper)) return error.SkipZigTest;
    var b = leashedAt(from);
    b.place(.cow(0), cow);
    b.place(.dog(1), sleeper);
    _ = ticked(&b, 1, &.{}, &.{d(0, -1)});
    try testing.expectEqual(sleeper, b.dogs[1]);
    try testing.expect(b.cows[0].x + physics.cow_half <= sleeper.x - physics.dog_half);
}

fn obstacle(lo: Point, hi: Point, tie: u32) jump.Obstacle {
    return .{ .rect = .{ .lo = lo, .hi = hi }, .rank = tie };
}

const everywhere: physics.Rect = .{ .lo = px(-10_000, -10_000), .hi = px(10_000, 10_000) };

test "the nearest spot: ties go east first, then south, west, north" {
    // Not in the world: the region is the test's, the world clamps; so the
    // mover stands well inside it.
    const p = px(1000, 1000);
    const obs = [_]jump.Obstacle{obstacle(px(980, 980), px(1020, 1020), 0)};
    try testing.expectEqual(px(1040, 1000), jump.nearestSpot(p, physics.dog_half, &obs, physics.world_rect).?);
}

test "the nearest spot: a tie in distance goes to the higher-ranked square first, before the direction" {
    const p = px(1000, 1000);
    // A, tall, ranked 2: its south and north ways are 50 px. B, wide, ranked
    // 10: its east and west ways are 50 px. Every 40 px way is blocked by
    // the other. A's south beats B's east.
    const obs = [_]jump.Obstacle{
        obstacle(px(980, 970), px(1020, 1030), 2),
        obstacle(px(970, 980), px(1030, 1020), 10),
    };
    try testing.expectEqual(px(1000, 1050), jump.nearestSpot(p, physics.dog_half, &obs, physics.world_rect).?);
}

test "the nearest spot: with every way out blocked, the corners; NE first" {
    const p = px(1000, 1000);
    const obs = [_]jump.Obstacle{
        obstacle(px(980, 980), px(1020, 1020), 0),
        obstacle(px(1020, 980), px(1060, 1020), 4),
        obstacle(px(980, 1020), px(1020, 1060), 6),
        obstacle(px(940, 980), px(980, 1020), 8),
        obstacle(px(980, 940), px(1020, 980), 10),
    };
    try testing.expectEqual(px(1040, 960), jump.nearestSpot(p, physics.dog_half, &obs, physics.world_rect).?);
}

test "the nearest spot: only squares wholly in the region; none within reach is nowhere to go" {
    const p = px(1000, 1000);
    const obs = [_]jump.Obstacle{obstacle(px(980, 980), px(1020, 1020), 0)};
    // The region's east edge at 1050: the east way (square to 1060) is out;
    // south wins.
    const tight: physics.Rect = .{ .lo = px(0, 0), .hi = px(1050, 2000) };
    try testing.expectEqual(px(1000, 1040), jump.nearestSpot(p, physics.dog_half, &obs, tight).?);
    // Nothing within 100 px: no candidates.
    const far = [_]jump.Obstacle{obstacle(px(1200, 1200), px(1240, 1240), 0)};
    try testing.expectEqual(@as(?Point, null), jump.nearestSpot(p, physics.dog_half, &far, physics.world_rect));
}

// ------------------------------------------- overlaps that slipped through

test "coincident centres: away goes east" {
    var b = leashedAt(px(16000, 16000));
    // Dog 1, another breed, on the leashed dog's point: the whole wary
    // distance, east.
    b.place(.dog(1), px(16000, 16000));
    const sc = physics.Scene.of(&b).?;
    try testing.expectEqual(Point{ .x = physics.wary, .y = 0 }, physics.wishTotal(&sc, 1));
}

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

test "an awake dog overlapping one above it gets out from under at the start of its step" {
    var b = leashedAt(px(16000, 16000));
    b.place(.cow(0), px(16300, 16300));
    // Dog 1 half under the cow: it jumps, then steps.
    b.place(.dog(1), px(16300, 16340));
    _ = ticked(&b, 1, &.{}, &.{});
    var pairs: [4][2]Critter = undefined;
    try testing.expectEqual(@as(usize, 0), physics.overlaps(&b, &pairs));
    try testing.expect(physics.mag(b.dogs[1].y - physics.px(16350)) <= physics.speed);
}

// -------------------------------------------------- bumps, timer, rest

test "a bump ends the drag, not the leash: the dog stops just short, the rest of the tick's drag is dropped, the leash comes off let_go_ticks later" {
    // Dog 5 against the world's east edge, where it can't get out of the
    // way; the leashed dog 20 px west of it.
    const y = physics.px(16000);
    const five: Point = .{ .x = physics.world - physics.dog_half, .y = y };
    const short: Point = .{ .x = five.x - 2 * physics.dog_half, .y = y };
    var b = leashedAt(.{ .x = short.x - physics.px(20), .y = y });
    b.place(.dog(5), five);
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
    // A dog out of its band moves: no rest.
    b.place(.dog(4), px(16200, 16000));
    l = ticked(&b, 3, &.{}, &.{});
    try testing.expect(!hasRest(&l));
    // Unleashed, nothing moves and nothing is timed.
    var u = Board.laidOut();
    l = ticked(&u, 1, &.{}, &.{});
    try testing.expect(hasRest(&l));
}

// ------------------------------------------------------------ the wishes

test "a dog in its herd band is content; inside it, it steps away; past it, toward; a dead zone" {
    const from = px(16000, 16000);
    const Case = struct { off: Point, step: Point };
    const mid = @divTrunc(physics.band_inner + physics.band_outer, 2);
    const ten = physics.px(10);
    const cases = [_]Case{
        // Same breed (4 mod 4 = 0), in the band.
        .{ .off = .{ .x = mid, .y = 0 }, .step = .{ .x = 0, .y = 0 } },
        // 10 px too close: away.
        .{ .off = .{ .x = physics.band_inner - ten, .y = 0 }, .step = .{ .x = @min(ten, physics.speed), .y = 0 } },
        // 10 px too far: toward.
        .{ .off = .{ .x = physics.band_outer + ten, .y = 0 }, .step = .{ .x = -@min(ten, physics.speed), .y = 0 } },
        // Too far by less than the dead zone: no step.
        .{ .off = .{ .x = physics.band_outer + @divTrunc(physics.dead_zone, 2), .y = 0 }, .step = .{ .x = 0, .y = 0 } },
    };
    for (cases) |c| {
        var b = leashedAt(from);
        b.place(.dog(4), .{ .x = from.x + c.off.x, .y = from.y + c.off.y });
        const sc = physics.Scene.of(&b).?;
        try testing.expectEqual(c.step, physics.wishStep(&sc, 1));
    }
    // Diagonal, the band's outer edge each way: toward, along the diagonal,
    // no longer than the speed.
    var b = leashedAt(from);
    b.place(.dog(4), .{ .x = from.x + physics.band_outer, .y = from.y + physics.band_outer });
    const sc = physics.Scene.of(&b).?;
    const s = physics.wishStep(&sc, 1);
    try testing.expect(s.x < 0 and s.x == s.y);
    try testing.expect(physics.len2(s) <= @as(i64, physics.speed) * physics.speed);
}

test "a dog keeps its wary distance from other breeds above it, and its room from cows; wishes add up" {
    const from = px(16000, 16000);
    var b = leashedAt(from);
    // Dog 1, another breed, half the wary distance east: the other half,
    // east.
    const half_wary = @divTrunc(physics.wary, 2);
    b.place(.dog(1), .{ .x = from.x + half_wary, .y = from.y });
    var sc = physics.Scene.of(&b).?;
    const wary_wish: Point = .{ .x = physics.wary - half_wary, .y = 0 };
    try testing.expectEqual(wary_wish, physics.wishTotal(&sc, 1));
    // And a cow south of it, short of its room: the rest, north.
    const cow_at = @divTrunc(physics.cow_room + physics.cow_half + physics.dog_half, 2);
    b.place(.cow(0), .{ .x = from.x + half_wary, .y = from.y + cow_at });
    sc = physics.Scene.of(&b).?;
    const both: Point = .{ .x = wary_wish.x, .y = -(physics.cow_room - cow_at) };
    try testing.expectEqual(both, physics.wishTotal(&sc, 2));
    // Dogs below never count: dog 1 is not wary of dog 2 (another breed).
    b.place(.dog(2), .{ .x = from.x + half_wary + 2 * physics.dog_half, .y = from.y });
    sc = physics.Scene.of(&b).?;
    try testing.expectEqual(both, physics.wishTotal(&sc, 2));
}

test "the anchor is the nearest more-alpha dog of its breed; ties go to the leashed dog, then the lower number" {
    const b0 = 16000;
    var b = leashedAt(px(b0, b0));
    // Dog 8 (breed 0), 200 px east of the leashed dog; dog 4 (breed 0) 200
    // px east of dog 8: equally near dog 8, which anchors on the leashed dog.
    b.place(.dog(8), px(b0 + 200, b0));
    b.place(.dog(4), px(b0 + 400, b0));
    var sc = physics.Scene.of(&b).?;
    // Dog 8 (index 2: dogs 4 then 8): anchors on the leashed dog, 200 px:
    // past the band's outer edge, west.
    try testing.expect(physics.band_outer < physics.px(200));
    try testing.expectEqual(Point{ .x = -(physics.px(200) - physics.band_outer), .y = 0 }, physics.wishTotal(&sc, 2));
    // Dog 4 sits 400 px from the leashed dog: its only anchor, toward it.
    try testing.expectEqual(Point{ .x = -(physics.px(400) - physics.band_outer), .y = 0 }, physics.wishTotal(&sc, 1));
    // Dog 12 between dog 4 and dog 8, equally near both (100 px): dog 4.
    b.place(.dog(12), px(b0 + 300, b0 + 100));
    sc = physics.Scene.of(&b).?;
    const w = physics.wishTotal(&sc, 3);
    // Toward dog 4 at (400, 0) from (300, 100): 141 px, 41 too far, NE.
    try testing.expect(w.x > 0 and w.y < 0);
}

test "a dog's own step stops where it would press into anyone, awake or asleep, above or below" {
    const b0 = 16000;
    var b = leashedAt(px(b0, b0));
    b.place(.dog(4), px(b0 + 150, b0));
    // Dog 9 touching dog 4's west side: dog 4 can't step toward its anchor.
    b.place(.dog(9), px(b0 + 110, b0));
    _ = ticked(&b, 1, &.{}, &.{});
    try testing.expectEqual(px(b0 + 150, b0), b.dogs[4]);
}

test "the speed: with no drag, a dog far past its band closes `speed` 256ths every tick" {
    const from = px(16000, 16000);
    var b = leashedAt(from);
    const start: Point = .{ .x = from.x + physics.band_outer + physics.px(100), .y = from.y };
    b.place(.dog(4), start);
    var t: physics.Tick = 1;
    while (t <= 4) : (t += 1) {
        _ = ticked(&b, t, &.{}, &.{});
        try testing.expectEqual(Point{ .x = start.x - @as(i32, @intCast(t)) * physics.speed, .y = start.y }, b.dogs[4]);
    }
}

// ----------------------------------------------------------- pixel-ticks

test "pixel-ticks: in a drag of N px, a lone awake dog of another breed moves at most N px and the tick's own step, and away from the leashed dog" {
    const from = px(16000, 16000);
    const n = 20;
    // Toward it, and away from it.
    for ([_]i32{ n, -n }) |dx| {
        var b = leashedAt(from);
        const start: Point = .{ .x = from.x + @divTrunc(physics.wary, 2), .y = from.y + physics.px(10) };
        b.place(.dog(1), start);
        try testing.expect(1 % physics.breeds != 0);
        _ = ticked(&b, 1, &.{}, &.{d(dx, 0)});
        const moved = physics.delta(start, b.dogs[1]);
        const most: i64 = physics.px(n) + physics.speed;
        try testing.expect(physics.len2(moved) <= most * most);
        // Away: along the line from the leashed dog's start to it.
        const out = physics.delta(from, start);
        try testing.expect(@as(i64, moved.x) * out.x + @as(i64, moved.y) * out.y > 0);
    }
    // Its own step alone, with no drag, is far shorter.
    try testing.expect(physics.speed < physics.px(n));
}

test "pixel-ticks: a dog of the leashed dog's breed keeps up with a long drag, which the speed alone could not" {
    const from = px(16000, 16000);
    var b = leashedAt(from);
    const start: Point = .{ .x = from.x + @divTrunc(physics.band_inner + physics.band_outer, 2), .y = from.y };
    const follower: u16 = physics.breeds;
    b.place(.dog(follower), start);
    // Dragging west, half the cap a tick, a little past the follow distance.
    const per_tick = @divExact(physics.cap, physics.px(2));
    const ticks = @divTrunc(physics.follow, physics.px(per_tick)) + 4;
    try testing.expect(physics.px(ticks * per_tick) > physics.follow);
    var t: physics.Tick = 1;
    while (t <= ticks) : (t += 1) _ = ticked(&b, t, &.{}, &.{d(-per_tick, 0)});
    try testing.expectEqual(Point{ .x = from.x - physics.px(ticks * per_tick), .y = from.y }, b.dogs[0]);
    // Still in its band, give or take the dead zone and one pixel-tick.
    const gap: i64 = physics.isqrt(physics.len2(physics.delta(b.dogs[0], b.dogs[follower])));
    try testing.expect(gap <= physics.band_outer + physics.dead_zone + physics.px(1));
    // The speed alone covers a sliver of that.
    try testing.expect(ticks * physics.speed < start.x - b.dogs[follower].x);
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
    var b = leashedAt(px(16000, 16000));
    // Nine tenths of the cap, twice, each way: the cap, each way.
    const most = @divExact(physics.cap, physics.px(10)) * 9;
    const c = physics.mergeAndCap(&.{ d(most, -most), d(most, -most) });
    _ = ticked(&b, 1, &.{}, c.slice());
    try testing.expectEqual(Point{ .x = physics.px(16000) + physics.cap, .y = physics.px(16000) - physics.cap }, b.dogs[0]);
}

test "at the world's edge the drag is clamped, and carries on" {
    var b = leashedAt(px(30, 16000));
    const lines = ticked(&b, 1, &.{}, &.{ d(-50, 0), d(0, 20) });
    try testing.expectEqual(px(20, 16020), b.dogs[0]);
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
    // short of it, far enough south to be asleep.
    b.place(.cow(0), .{ .x = edge + physics.px(10), .y = from.y });
    try testing.expect(physics.awake_reach < physics.region_reach);
    b.place(.cow(1), .{ .x = edge - physics.px(10), .y = from.y + physics.awake_reach });
    const sc = physics.Scene.of(&b).?;
    try testing.expectEqual(@as(usize, 2), sc.len);
    try testing.expect(sc.list()[1].who.eql(.cow(1)));
    try testing.expectEqual(physics.Seen.Awake.asleep, sc.list()[1].awake);
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
                if (p.held[@intCast(row)][@intCast(col)] == .held) continue;
                p.held[@intCast(row)][@intCast(col)] = .held;
                for (server.dogs, 0..) |at, i| if (physics.tileOf(at).col == col and physics.tileOf(at).row == row) p.board.place(.dog(@intCast(i)), at);
                for (server.cows, 0..) |at, i| if (physics.tileOf(at).col == col and physics.tileOf(at).row == row) p.board.place(.cow(@intCast(i)), at);
            }
        }
    }
};

test "subscribing more tiles changes nothing: the server's board, a page holding only the region's tiles and one holding a large display's give the same lines, every tick" {
    // Two walks on seeds that bump early: a walk's bumps depend on its seed
    // (dogs flee a drag a pixel at a time), and the bump is what the
    // comparison most needs, so each walk must have one, and a letgo.
    // A hundred ticks each; four hundred in the slow tier.
    const ticks: physics.Tick = switch (fuzz) {
        .fast => 100,
        .full => 400,
    };
    var moved: usize = 0;
    for ([_]u64{ 1, 2 }) |seed| {
        const walk = try walkCompared(seed, ticks);
        try testing.expect(walk.bumps > 0);
        try testing.expect(walk.letgos > 0);
        moved += walk.moved;
    }
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
        const r = physics.isqrt(physics.len2(v));
        crc.update(std.mem.asBytes(&[_]i64{ w.x, w.y, s.x, s.y, r }));
    }
    // Golden: the first 20,000 samples' checksum, and all 200,000's.
    try testing.expectEqual(@as(u32, switch (fuzz) {
        .fast => 549483793,
        .full => 2544406423,
    }), crc.final());
}

test "the wishes' grid sums every awake dog's wishes as the scan over every awake critter does: crowds on a lattice (ties for the anchor), dogs moved after the scene is built" {
    var prng: std.Random.DefaultPrng = .init(31);
    const r = prng.random();
    var dogs_checked: usize = 0;
    for (0..fuzzed(400)) |_| {
        const c0 = 16000;
        // A lattice step: many dogs equally far from one another.
        const step = r.intRangeAtMost(i32, 10, 160);
        const spread = r.intRangeAtMost(i32, 1, 8);
        var b = leashedAt(px(c0, c0));
        const n = r.intRangeAtMost(u16, 2, physics.dog_count - 1);
        for (1..n) |i| b.place(.dog(@intCast(i)), px(c0 + step * r.intRangeAtMost(i32, -spread, spread), c0 + step * r.intRangeAtMost(i32, -spread, spread)));
        for (0..r.uintLessThan(usize, physics.cow_count)) |i| b.place(.cow(@intCast(i)), px(c0 + r.intRangeAtMost(i32, -500, 500), c0 + r.intRangeAtMost(i32, -500, 500)));
        var sc = physics.Scene.of(&b).?;
        // Some move, across cells, as the wishes' steps and jumps move them.
        for (0..r.uintLessThan(usize, 20)) |_| {
            const i = r.uintLessThan(usize, sc.len);
            const p = sc.pos(i);
            sc.put(i, .{ .x = p.x + r.intRangeAtMost(i32, -physics.px(300), physics.px(300)), .y = p.y + r.intRangeAtMost(i32, -physics.px(300), physics.px(300)) });
        }
        for (sc.awakeOnes()) |w| {
            const me = sc.seen[w];
            if (me.who.kind != .dog or me.rank == 0) continue;
            try testing.expectEqual(physics.wishTotalScanned(&sc, w), physics.wishTotalGridded(&sc, w));
            dogs_checked += 1;
        }
    }
    try testing.expect(dogs_checked > fuzzed(400));
}
