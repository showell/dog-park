//! The physics' tests (docs/PHYSICS.md, "Tests to write first"): test 12
//! (more held tiles change nothing) as far as the board can say it;
//! cows.zig's tests carried to 256ths (27); the 70 px lane (20); pushes and
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

// ------------------------------------------------- cows.zig's, in 256ths

test "the first layout in 256ths: cow 0 in the middle of the park's first white tile, dog 0 where dogs.zig lays it" {
    const b = Board.laidOut();
    try testing.expectEqual(px(13_750, 13_750), b.cows[0]);
    try testing.expectEqual(px(13_655, 13_850), b.dogs[0]);
    try testing.expectEqual(@as(usize, 50), physics.cow_count);
    try testing.expectEqual(@as(i32, 17_920), physics.lane);
}

test "a dog moving 2 px north moves a cow ahead of it 1 px east or west, away from its line" {
    // The cow 300 px north, 100 px east of the dog's line: east, by half the
    // step (512 / 2 = 256, 1 px).
    try testing.expectEqual(px(1101, 700), cowAfter(px(1000, 1000), d(0, -2), px(1100, 700)));
    try testing.expectEqual(px(899, 700), cowAfter(px(1000, 1000), d(0, -2), px(900, 700)));
    // A 1 px step: half a pixel, 128.
    try testing.expectEqual(Point{ .x = physics.px(1100) + 128, .y = physics.px(700) }, cowAfter(px(1000, 1000), d(0, -1), px(1100, 700)));
    // Moving east 2 px, a cow ahead and north of the line goes north 1 px.
    try testing.expectEqual(px(1300, 899), cowAfter(px(1000, 1000), d(2, 0), px(1300, 900)));
}

test "on the dog's line, the cow goes to the dog's right: east's is south, west's north, north's east, south's west" {
    try testing.expectEqual(px(1300, 1001), cowAfter(px(1000, 1000), d(2, 0), px(1300, 1000)));
    try testing.expectEqual(px(700, 999), cowAfter(px(1000, 1000), d(-2, 0), px(700, 1000)));
    try testing.expectEqual(px(1001, 700), cowAfter(px(1000, 1000), d(0, -2), px(1000, 700)));
    try testing.expectEqual(px(999, 1300), cowAfter(px(1000, 1000), d(0, 2), px(1000, 1300)));
}

test "ahead only, in the box, and awake: 400 px ahead or off moves; 401 either way, behind, or the box's corner (567 px off, asleep) stays" {
    // The dog ends at x 1002: 400 px ahead is x 1402.
    try testing.expectEqual(px(1402, 899), cowAfter(px(1000, 1000), d(2, 0), px(1402, 900)));
    try testing.expectEqual(px(1403, 900), cowAfter(px(1000, 1000), d(2, 0), px(1403, 900)));
    // 400 px off the line, 500 px from the dog's start (awake: at most).
    try testing.expectEqual(px(1300, 599), cowAfter(px(1000, 1000), d(2, 0), px(1300, 600)));
    try testing.expectEqual(px(1102, 599), cowAfter(px(1000, 1000), d(2, 0), px(1102, 599)));
    // Behind.
    try testing.expectEqual(px(900, 900), cowAfter(px(1000, 1000), d(2, 0), px(900, 900)));
    // The scare box's corner: in today's rule it moves; now it is asleep.
    try testing.expectEqual(px(1402, 600), cowAfter(px(1000, 1000), d(2, 0), px(1402, 600)));
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

test "in the lane: half speed while there is time; as fast as clears it by the time the dog arrives; at once when it is there" {
    // East, the cow on the line 300 px ahead: 230 px to come, 70 to clear:
    // half speed is enough.
    try testing.expectEqual(px(1300, 1001), cowAfter(px(998, 1000), d(2, 0), px(1300, 1000)));
    // 100 px ahead: 30 px to come, 70 to clear, the dog 10 px a step:
    // 17920 * 2560 / 7680, rounded up: 5974 (cows.zig's half pixels said 47,
    // 6016).
    try testing.expectEqual(Point{ .x = physics.px(1100), .y = physics.px(1000) + 5974 }, cowAfter(px(990, 1000), d(10, 0), px(1100, 1000)));
    // 70 px ahead: the dog is on it; all 70 px now.
    try testing.expectEqual(px(1070, 1070), cowAfter(px(990, 1000), d(10, 0), px(1070, 1000)));
    // 30 px north of the line, 70 ahead: 40 px to clear, north.
    try testing.expectEqual(px(1070, 930), cowAfter(px(990, 1000), d(10, 0), px(1070, 970)));
}

test "the world's edge: no room to clear on the cow's side, the other side; no room to scoot, a shorter step or none" {
    const wall = tiles.world_px;
    // Heading north 50 px from the wall, the cow 10 px east of the line, 70
    // px ahead (the dog on it): east it has 10 px and needs 60; west, 80,
    // all now.
    try testing.expectEqual(px(wall - 120, 930), cowAfter(px(wall - 50, 1010), d(0, -10), px(wall - 40, 930)));
    // Heading north, the cow 2 px from the east wall, ahead and well off the
    // line: 2 of its 5 px.
    try testing.expectEqual(px(wall - 30, 800), cowAfter(px(wall - 400, 1010), d(0, -10), px(wall - 32, 800)));
    // Against the wall already: none.
    try testing.expectEqual(px(wall - 30, 800), cowAfter(px(wall - 400, 1010), d(0, -10), px(wall - 30, 800)));
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
    while (trials < 3000) {
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

test "a drag in the laid-out park scares every awake cow ahead of it, and only those" {
    var b = Board.laidOut();
    const o = tiles.park_offset_px;
    b.dogs[0] = px(o, o + 250);
    b.hold = .{ .leashed = .{ .dog = 0, .drag = .on } };
    const lines = ticked(&b, 1, &.{}, &.{d(10, 0)});
    // Cow 0, 240 px ahead on the line: half speed, 5 px south.
    try testing.expectEqual(px(o + 250, o + 255), b.cows[0]);
    for (lines.slice()) |c| switch (c) {
        .critter => |l| if (l.who.kind == .cow) try testing.expectEqual(@as(u16, 0), l.who.n),
        else => {},
    };
}

// ------------------------------------------------------- the 70 px lane

test "a cow on the line 70 px ahead, the drag stepping 1 px: it clears the lane, 70 px, in that one step, and stays within the region" {
    var b = leashedAt(px(16000, 16000));
    b.place(.cow(0), px(16071, 16000));
    const region = physics.region(b.dogs[0]);
    const lines = ticked(&b, 1, &.{}, &.{d(1, 0)});
    try testing.expectEqual(px(16071, 16070), b.cows[0]);
    try testing.expect(region.holds(physics.Rect.square(b.cows[0], physics.cow_half)));
    try testing.expectEqual(px(16001, 16000), b.dogs[0]);
    try testing.expectEqual(@as(?Critter, null), bumpOf(&lines));
}

// ------------------------------------------------------ pushes and jumps

test "a cow lands on an awake dog: the dog jumps to the nearest spot clear of everyone and the cow's sweep, then takes its wish step" {
    const b0 = 16000;
    var b = leashedAt(px(b0, b0));
    b.place(.cow(0), px(b0 + 70, b0));
    b.place(.dog(1), px(b0 + 70, b0 + 100));
    _ = ticked(&b, 1, &.{}, &.{d(10, 0)});
    // The cow cleared the lane at once, 70 px south, onto dog 1; the nearest
    // spot is pressed against the cow's south side, 20 px down.
    try testing.expectEqual(px(b0 + 70, b0 + 70), b.cows[0]);
    const spot = px(b0 + 70, b0 + 120);
    try testing.expect(physics.mag(b.dogs[1].x - spot.x) <= physics.speed and physics.mag(b.dogs[1].y - spot.y) <= physics.speed);
    try testing.expectEqual(px(b0 + 10, b0), b.dogs[0]);
    var pairs: [4][2]Critter = undefined;
    try testing.expectEqual(@as(usize, 0), physics.overlaps(&b, &pairs));
}

test "the area the cow swept is no landing spot: a dog under the front of the cow's end square jumps sideways, east before west" {
    const b0 = 16000;
    var b = leashedAt(px(b0, b0));
    b.place(.cow(0), px(b0 + 70, b0));
    // Dog 1 just past the cow's south side; the cow lands 70 px south.
    b.place(.dog(1), px(b0 + 70, b0 + 50));
    _ = ticked(&b, 1, &.{}, &.{d(10, 0)});
    try testing.expectEqual(px(b0 + 70, b0 + 70), b.cows[0]);
    // North of the cow (30 px) is in its sweep; east and west are 50 px.
    const spot = px(b0 + 120, b0 + 50);
    try testing.expect(physics.mag(b.dogs[1].x - spot.x) <= physics.speed and physics.mag(b.dogs[1].y - spot.y) <= physics.speed);
}

test "a cow lands on a dog in a packed field with nowhere to go: it stops short of the first critter along its sweep, and pushes no one" {
    const b0 = 16000;
    var b = leashedAt(px(b0, b0));
    b.place(.cow(0), px(b0 + 70, b0));
    const dog1 = px(b0 + 70, b0 + 90);
    b.place(.dog(1), dog1);
    // A field of touching dogs on D's grid, 15 x 15 around it, leaving the
    // leashed dog, the cow and the area the cow sweeps.
    const keep_clear = [_]physics.Rect{
        physics.Rect.square(b.dogs[0], physics.dog_half),
        .{ .lo = px(b0 + 40, b0 - 30), .hi = px(b0 + 100, b0 + 100) },
    };
    var n: u16 = 2;
    var j: i32 = -7;
    while (j <= 7) : (j += 1) {
        var i: i32 = -7;
        while (i <= 7) : (i += 1) {
            if (i == 0 and j == 0) continue;
            const at: Point = .{ .x = dog1.x + physics.px(40 * i), .y = dog1.y + physics.px(40 * j) };
            const sq = physics.Rect.square(at, physics.dog_half);
            if (sq.overlaps(keep_clear[0]) or sq.overlaps(keep_clear[1])) continue;
            b.place(.dog(n), at);
            n += 1;
        }
    }
    _ = ticked(&b, 1, &.{}, &.{d(10, 0)});
    // Dog 1's square starts at y + 70: the cow's bottom stops there.
    try testing.expectEqual(px(b0 + 70, b0 + 40), b.cows[0]);
    try testing.expect(physics.mag(b.dogs[1].x - dog1.x) <= physics.speed and physics.mag(b.dogs[1].y - dog1.y) <= physics.speed);
    var pairs: [4][2]Critter = undefined;
    try testing.expectEqual(@as(usize, 0), physics.overlaps(&b, &pairs));
}

test "a push at the region's reach: a scared cow 472 px out pushes a dog 500 px out, outward; it lands inside the region" {
    const b0 = 16000;
    var b = leashedAt(px(b0, b0));
    b.place(.cow(0), px(b0 + 250, b0 - 400));
    b.place(.dog(1), px(b0 + 300, b0 - 400));
    const region = physics.region(b.dogs[0]);
    _ = ticked(&b, 1, &.{}, &.{d(0, -100)});
    // Ten steps of 10 px north, the cow 5 px east each: the dog pushed east
    // ahead of it.
    try testing.expectEqual(px(b0 + 300, b0 - 400), b.cows[0]);
    try testing.expect(b.dogs[1].x >= physics.px(b0 + 350) - physics.speed);
    try testing.expect(region.holds(physics.Rect.square(b.dogs[1], physics.dog_half)));
    var pairs: [4][2]Critter = undefined;
    try testing.expectEqual(@as(usize, 0), physics.overlaps(&b, &pairs));
}

test "a cow's step stops short of a sleeping dog: sleepers aren't pushed" {
    const b0 = 16000;
    var b = leashedAt(px(b0, b0));
    b.place(.cow(0), px(b0 + 300, b0 - 380));
    // 518 px from the leashed dog: seen, asleep; 2 px past the cow's side.
    b.place(.dog(1), px(b0 + 352, b0 - 380));
    _ = ticked(&b, 1, &.{}, &.{d(0, -10)});
    try testing.expectEqual(px(b0 + 302, b0 - 380), b.cows[0]);
    try testing.expectEqual(px(b0 + 352, b0 - 380), b.dogs[1]);
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

test "a bump ends the drag, not the leash: the dog stops just short, the rest of the tick's drag is dropped, the timer runs 80 ticks to the release" {
    const b0 = 16000;
    var b = leashedAt(px(b0, b0));
    b.place(.dog(5), px(b0 + 100, b0));
    const lines = ticked(&b, 10, &.{}, &.{ d(80, 0), d(0, 30) });
    try testing.expectEqual(px(b0 + 60, b0), b.dogs[0]);
    try testing.expectEqual(@as(?Critter, .dog(5)), bumpOf(&lines));
    try testing.expectEqual(physics.Hold{ .leashed = .{ .dog = 0, .drag = .{ .ended = 10 } } }, b.hold);
    // The bump is the last line, after the critter lines.
    try testing.expect(lines.slice()[lines.len - 1] == .bump);
    // A drag with no drag on is ignored.
    _ = ticked(&b, 11, &.{}, &.{d(-10, 0)});
    try testing.expectEqual(px(b0 + 60, b0), b.dogs[0]);
    var t: physics.Tick = 12;
    while (t < 90) : (t += 1) {
        const l = ticked(&b, t, &.{}, &.{});
        try testing.expect(!hasRest(&l));
    }
    const last = ticked(&b, 90, &.{}, &.{});
    try testing.expect(last.slice()[last.len - 1] == .release);
    try testing.expectEqual(@as(u16, 0), last.slice()[last.len - 1].release);
    try testing.expectEqual(physics.Hold.none, b.hold);
}

test "a grab at T + 80 beats the release; a letgo then starts the timer again" {
    var b = leashedAt(px(16000, 16000));
    _ = ticked(&b, 10, &.{.letgo}, &.{});
    try testing.expectEqual(physics.Drag{ .ended = 10 }, b.hold.leashed.drag);
    var t: physics.Tick = 11;
    while (t < 90) : (t += 1) _ = ticked(&b, t, &.{}, &.{});
    const lines = ticked(&b, 90, &.{.grab}, &.{});
    for (lines.slice()) |c| try testing.expect(c != .release);
    try testing.expectEqual(physics.Drag.on, b.hold.leashed.drag);
}

test "a bump that presses two critters at once names the higher-ranked" {
    const b0 = 16000;
    var b = leashedAt(px(b0, b0));
    b.place(.dog(9), px(b0 + 100, b0 + 10));
    b.place(.dog(5), px(b0 + 100, b0 - 10));
    const lines = ticked(&b, 1, &.{}, &.{d(80, 0)});
    try testing.expectEqual(@as(?Critter, .dog(5)), bumpOf(&lines));
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

test "a dog in its herd band is content; inside it, it steps away; past it, toward; a dead zone of 1 px" {
    const b0 = 16000;
    const Case = struct { at: Point, step: Point };
    const cases = [_]Case{
        // Same breed (4 mod 4 = 0), 80 px: in the band.
        .{ .at = px(b0 + 80, b0), .step = .{ .x = 0, .y = 0 } },
        // 50 px: 10 px too close: away, at the speed.
        .{ .at = px(b0 + 50, b0), .step = .{ .x = physics.speed, .y = 0 } },
        // 150 px: 50 px too far: toward.
        .{ .at = px(b0 + 150, b0), .step = .{ .x = -physics.speed, .y = 0 } },
        // 100.5 px: inside the dead zone.
        .{ .at = .{ .x = physics.px(b0 + 100) + 128, .y = physics.px(b0) }, .step = .{ .x = 0, .y = 0 } },
        // Diagonal, 200 px each way: toward, the speed split by the isqrt.
        .{ .at = px(b0 + 200, b0 + 200), .step = .{ .x = -11, .y = -11 } },
    };
    for (cases) |c| {
        var b = leashedAt(px(b0, b0));
        b.place(.dog(4), c.at);
        const sc = physics.Scene.of(&b).?;
        try testing.expectEqual(c.step, physics.wishStep(&sc, 1));
    }
}

test "a dog keeps 150 px from other breeds above it, and 90 px from cows; wishes add up" {
    const b0 = 16000;
    var b = leashedAt(px(b0, b0));
    // Dog 1, another breed, 100 px east: 50 px short, east.
    b.place(.dog(1), px(b0 + 100, b0));
    var sc = physics.Scene.of(&b).?;
    try testing.expectEqual(Point{ .x = physics.px(50), .y = 0 }, physics.wishTotal(&sc, 1));
    // And a cow 60 px south of it: 30 px short, north.
    b.place(.cow(0), px(b0 + 100, b0 + 60));
    sc = physics.Scene.of(&b).?;
    try testing.expectEqual(Point{ .x = physics.px(50), .y = -physics.px(30) }, physics.wishTotal(&sc, 2));
    // Dogs below never count: dog 1 is not wary of dog 2 (another breed).
    b.place(.dog(2), px(b0 + 140, b0));
    sc = physics.Scene.of(&b).?;
    try testing.expectEqual(Point{ .x = physics.px(50), .y = -physics.px(30) }, physics.wishTotal(&sc, 2));
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
    // 100 px too far, west.
    try testing.expectEqual(Point{ .x = -physics.px(100), .y = 0 }, physics.wishTotal(&sc, 2));
    // Dog 4 sits 400 px from the leashed dog: its only anchor, toward it.
    try testing.expectEqual(Point{ .x = -physics.px(300), .y = 0 }, physics.wishTotal(&sc, 1));
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

test "the speed: 16/256 of a pixel a tick, so a too-far dog closes 1 px in 16 ticks" {
    var b = leashedAt(px(16000, 16000));
    b.place(.dog(4), px(16200, 16000));
    var t: physics.Tick = 1;
    while (t <= 16) : (t += 1) _ = ticked(&b, t, &.{}, &.{});
    try testing.expectEqual(px(16199, 16000), b.dogs[4]);
}

// --------------------------------------------------------------- the cap

test "merged and capped: past 16 displacements are added into the 16th; each axis has 100 px a tick, cut where it crosses" {
    var raw: [20]physics.Disp = undefined;
    for (&raw, 0..) |*r, i| r.* = .{ .dx = physics.px(10), .dy = 0, .ms = @intCast(i) };
    const c = physics.mergeAndCap(&raw);
    try testing.expectEqual(@as(usize, 16), c.len);
    for (c.slice()[0..10]) |one| try testing.expectEqual(physics.px(10), one.dx);
    for (c.slice()[10..]) |one| try testing.expectEqual(@as(i32, 0), one.dx);
    try testing.expectEqual(@as(u32, 19), c.list[15].ms);
    try testing.expect(physics.withinCap(c.slice()));
    const cut = physics.mergeAndCap(&.{ d(60, 10), d(60, -10), d(5, 5) });
    try testing.expectEqualSlices(physics.Disp, &.{ d(60, 10), d(40, -10), d(0, 5) }, cut.slice());
    try testing.expect(!physics.withinCap(&.{ d(60, 0), d(41, 0) }));
    try testing.expect(physics.withinCap(&.{ d(60, 0), d(-40, 0) }));
}

test "a tick's drag moves the leashed dog at most 100 px on each axis" {
    var b = leashedAt(px(16000, 16000));
    const c = physics.mergeAndCap(&.{ d(90, -90), d(90, -90) });
    _ = ticked(&b, 1, &.{}, c.slice());
    try testing.expectEqual(px(16100, 15900), b.dogs[0]);
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
    // The region from 15250 to 17250 meets tiles 30 to 34; a cow at x 17510
    // stands in tile 35, its square from 17480.
    var b = leashedAt(px(16250, 16250));
    b.place(.cow(0), px(17510, 16250));
    b.place(.cow(1), px(17490, 16900));
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
    var server = Board.laidOut();
    // Dog 112, in the park's middle.
    const leashed: u16 = 112;
    var small = PageBoard.init(&server);
    var large = PageBoard.init(&server);
    large.hold(&server, .{ .col_lo = 26, .col_hi = 37, .row_lo = 26, .row_hi = 37 });
    var prng: std.Random.DefaultPrng = .init(20261013);
    const rand = prng.random();
    var heading = d(30, 10);
    var bumps: usize = 0;
    var moved: usize = 0;
    var t: physics.Tick = 1;
    var humans: [2]physics.Human = undefined;
    var nh: usize = 1;
    humans[0] = .{ .leash = leashed };
    while (t <= 400) : (t += 1) {
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
        const n = rand.uintLessThan(usize, 4);
        for (raw[0..n]) |*r| r.* = .{ .dx = @divTrunc(heading.dx, 2) + physics.px(rand.intRangeAtMost(i32, -3, 3)), .dy = @divTrunc(heading.dy, 2), .ms = 0 };
        const drag = physics.mergeAndCap(raw[0..n]);
        if (rand.uintLessThan(u32, 40) == 0 and server.leashedDog() != null) {
            humans[nh] = .letgo;
            nh += 1;
        }
        const a = ticked(&server, t, humans[0..nh], drag.slice());
        const b = ticked(&small.board, t, humans[0..nh], drag.slice());
        const c = ticked(&large.board, t, humans[0..nh], drag.slice());
        try testing.expectEqualSlices(physics.Checked, a.slice(), b.slice());
        try testing.expectEqualSlices(physics.Checked, a.slice(), c.slice());
        nh = 0;
        if (bumpOf(&a) != null) bumps += 1;
        moved += a.len;
        // After a bump or a letgo, grab again now and then.
        if (server.hold == .leashed and server.hold.leashed.drag != .on and rand.uintLessThan(u32, 4) == 0) {
            humans[0] = .grab;
            nh = 1;
        }
    }
    // The walk did something worth comparing.
    try testing.expect(bumps > 0);
    try testing.expect(moved > 100);
}

// ------------------------------------------- the arithmetic on every target

test "the wish arithmetic at the i64 extremes gives the same bits on every target: a seeded fuzz, folded into one checksum (test 11)" {
    var prng: std.Random.DefaultPrng = .init(11);
    const rand = prng.random();
    var crc = std.hash.Crc32.init();
    for (0..200_000) |k| {
        // Vectors across the whole world (squared lengths to 1.3e14), wish
        // lengths to the follow distance (products to 3e12).
        const span: i32 = if (k % 2 == 0) physics.world else physics.px(500);
        const v: Point = .{ .x = rand.intRangeAtMost(i32, -span, span), .y = rand.intRangeAtMost(i32, -span, span) };
        if (v.x == 0 and v.y == 0) continue;
        const w = physics.wishAlong(v, rand.intRangeAtMost(i32, 0, physics.follow));
        const s = physics.stepOf(.{ .x = rand.intRangeAtMost(i32, -physics.world, physics.world), .y = rand.intRangeAtMost(i32, -physics.world, physics.world) });
        const r = physics.isqrt(physics.len2(v));
        crc.update(std.mem.asBytes(&[_]i64{ w.x, w.y, s.x, s.y, r }));
    }
    try testing.expectEqual(@as(u32, 1780965645), crc.final());
}
