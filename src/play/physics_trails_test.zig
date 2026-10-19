//! **POOP AND CHICKENS** (docs/PHYSICS.md, "Poop and chickens"): the
//! trail comes from the herd's tail; poop never lands on a critter and no
//! critter ever stands on poop; going around (the shove's all-or-none
//! check, the sidestep that stays when it would land on poop too); the
//! leashed dog never bumps a free chicken or a poop it can get around;
//! eating; a still tick moves no chicken; ripeness across the wraps; and
//! the poops-by-tile index. The exact tuning (step sizes, distances) is
//! tested by playing. Every scene stands near chicken 0's home, so its
//! chicken has no reason to walk home mid-test.

const std = @import("std");
const physics = @import("physics.zig");
const layout = @import("layout.zig");
const testing = std.testing;
const Board = physics.Board;
const Point = physics.Point;
const Lines = physics.Lines;

fn px(x: i32, y: i32) Point {
    return .{ .x = physics.px(x), .y = physics.px(y) };
}

fn d(x: i32, y: i32) physics.Disp {
    return .{ .dx = physics.px(x), .dy = physics.px(y) };
}

/// Chicken 0's home, and a point `x`, `y` px from it.
const home = layout.chickenHome(0);
fn nearHome(x: i32, y: i32) Point {
    return .{ .x = home.x + physics.px(x), .y = home.y + physics.px(y) };
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

/// A poop in slot `n`, at `at`.
fn poopAt(b: *Board, n: u16, at: Point) void {
    b.poops[n] = at;
    b.poop_known[n] = .present;
}

fn bumpOf(lines: *const Lines) ?physics.Bumped {
    for (lines.slice()) |c| if (c == .bump) return c.bump;
    return null;
}

fn lineOf(lines: *const Lines, who: physics.Critter) ?physics.CritterLine {
    for (lines.slice()) |c| if (c == .critter and c.critter.who.eql(who)) return c.critter;
    return null;
}

fn overlapsNone(b: *Board) !void {
    var found: [4][2]physics.Critter = undefined;
    try testing.expectEqual(@as(usize, 0), physics.overlaps(b, &found));
}

// ------------------------------------------------------------ the trail

test "the trail comes from the tail: a chain of three of the leashed dog's breed, and the last of them poops 30 px behind itself, into the park's next slots in turn" {
    // Proves rule 2: depth runs through the anchors (dog 4 follows the
    // leashed dog, dog 8 follows dog 4), and the deepest poops, away from
    // its anchor. Dog 1, another breed, is no part of the herd's depth.
    var b = leashedAt(px(300, 1050));
    b.place(.dog(4), px(244, 1050));
    b.place(.dog(8), px(188, 1050));
    var t: physics.Tick = 1;
    while (t <= 7) : (t += 1) _ = ticked(&b, t, &.{}, &.{d(100, 0)});
    // Each closes to the band's outer edge, 70 px behind the one ahead.
    try testing.expectEqual(px(930, 1050), b.dogs[4]);
    try testing.expectEqual(px(860, 1050), b.dogs[8]);
    try testing.expectEqual(@as(u32, 1), b.laid);
    try testing.expectEqual(px(830, 1050), b.poops[0]);
    // Seven more: the next 700 px, the next slot, behind the tail again.
    while (t <= 14) : (t += 1) _ = ticked(&b, t, &.{}, &.{d(100, 0)});
    try testing.expectEqual(@as(u32, 2), b.laid);
    try testing.expectEqual(px(1530, 1050), b.poops[1]);
    try testing.expectEqual(physics.Known.present, b.poop_known[0]);
    try overlapsNone(&b);
}

test "a poop whose spot is taken lands at the nearest free spot on the rings around it, never on a critter" {
    // Proves rule 3's search: a chicken stands on the spot behind the
    // leashed dog; the first ring (4 px out) is all inside it, and the
    // poop lands on a later ring, its north-west corner first, clear.
    var b = leashedAt(px(300, 1050));
    b.walked[0] = physics.poop_every - @as(u32, @intCast(physics.px(1)));
    b.place(.chicken(0), px(271, 1050));
    _ = ticked(&b, 1, &.{}, &.{d(1, 0)});
    try testing.expectEqual(@as(u32, 1), b.laid);
    // The spot is (271, 1050); 16 px clears the chicken's half and the
    // poop's, so the first spot that fits is on the ring 16 px out.
    try testing.expectEqual(px(271 - 16, 1050 - 16), b.poops[0]);
    try overlapsNone(&b);
}

// ---------------------------------------------------------- the sidestep

test "a dog whose step a poop vetoes takes the exact sidestep instead; and when the sidestep would land on poop too, it stays" {
    // Proves rule 5 in the walk, and that neither try lands on poop.
    // Dog 4 follows the leashed dog west; a poop touches its west side,
    // on its line: it steps 1 px south instead (on the line, +).
    var b = leashedAt(nearHome(-200, 400));
    b.place(.dog(4), nearHome(0, 400));
    poopAt(&b, 9, nearHome(-20, 400));
    b.laid = 10;
    _ = ticked(&b, 1, &.{}, &.{d(-1, 0)});
    try testing.expectEqual(nearHome(0, 401), b.dogs[4]);
    try overlapsNone(&b);
    // A second poop touching its south side: the sidestep is vetoed too.
    var c = leashedAt(nearHome(-200, 400));
    c.place(.dog(4), nearHome(0, 400));
    poopAt(&c, 9, nearHome(-20, 400));
    poopAt(&c, 3, nearHome(0, 420));
    c.laid = 10;
    _ = ticked(&c, 1, &.{}, &.{d(-1, 0)});
    try testing.expectEqual(nearHome(0, 400), c.dogs[4]);
    try overlapsNone(&c);
}

// ------------------------------------------------------------- the shove

test "a cow's step into a chicken shoves it by the step and as much again away from the cow's line; beside a nudged cow the chicken would land on, the step is vetoed whole and sidestepped" {
    // Proves rule 6 and its two phases: the chicken's landing is checked
    // against where the nudged cow is going, not only where it stands.
    // The leashed dog, east, scares cow 0 west half a pixel; chicken 0
    // touches cow 0's west side, 9 px north of its line.
    var b = leashedAt(nearHome(182, 9));
    b.place(.cow(0), nearHome(31, 9));
    b.place(.chicken(0), home);
    _ = ticked(&b, 1, &.{}, &.{d(1, 0)});
    try testing.expectEqual(Point{ .x = home.x + physics.px(31) - 128, .y = home.y + physics.px(9) }, b.cows[0]);
    try testing.expectEqual(Point{ .x = home.x - 128, .y = home.y - 128 }, b.chickens[0]);
    try overlapsNone(&b);
    // Cow 1, touching cow 0 on the north-west and the chicken on the
    // north: cow 0 nudges it, and the chicken, shoved north, would land
    // on it. Nobody goes west; cow 0 sidesteps south instead.
    var c = leashedAt(nearHome(182, 9));
    c.place(.cow(0), nearHome(31, 9));
    c.place(.cow(1), nearHome(-11, -31));
    c.place(.chicken(0), home);
    _ = ticked(&c, 1, &.{}, &.{d(1, 0)});
    try testing.expectEqual(Point{ .x = home.x + physics.px(31), .y = home.y + physics.px(9) + 128 }, c.cows[0]);
    try testing.expectEqual(nearHome(-11, -31), c.cows[1]);
    try testing.expectEqual(home, c.chickens[0]);
    try overlapsNone(&c);
}

// ------------------------------------------------------ the leashed dog

test "the leashed dog shoves a free chicken off its front: it slides off within a touch's width, the drag goes on, no bump" {
    // Proves rules 6 and 7 for the leashed dog: on its line, the chicken
    // goes south (+), a pixel each way a pixel-tick, until clear (24 px:
    // a dog's half and a chicken's).
    var b = leashedAt(nearHome(-24, 0));
    b.place(.chicken(0), home);
    const lines = ticked(&b, 1, &.{}, &.{d(40, 0)});
    try testing.expectEqual(@as(?physics.Bumped, null), bumpOf(&lines));
    try testing.expectEqual(nearHome(16, 0), b.dogs[0]);
    try testing.expectEqual(nearHome(24, 24), b.chickens[0]);
    try testing.expect(lineOf(&lines, .chicken(0)) != null);
    try overlapsNone(&b);
}

test "the leashed dog slides around a poop, a pixel sideways each pixel-tick, away from it, then goes on: no bump" {
    // Proves rule 7's slide: 5 px off its line to the south, so it slides
    // north, 15 pixel-ticks till clear of the poop (20 px: a dog's half and
    // a poop's), then 15 px east.
    var b = leashedAt(nearHome(0, 400));
    poopAt(&b, 4, nearHome(20, 405));
    b.laid = 5;
    const lines = ticked(&b, 1, &.{}, &.{d(30, 0)});
    try testing.expectEqual(@as(?physics.Bumped, null), bumpOf(&lines));
    try testing.expectEqual(nearHome(15, 385), b.dogs[0]);
    try overlapsNone(&b);
}

test "the leashed dog bumps a boxed-in chicken only when the shove and the slide both fail, and stays where it touched: no setback" {
    // Proves rule 7's last resort, and that the 6 px setback is gone: a
    // cow behind the chicken stops the shove, a dog of another breed
    // beside the leashed dog the slide.
    var b = leashedAt(nearHome(-24, 0));
    b.place(.chicken(0), home);
    b.place(.cow(0), nearHome(31, 0));
    b.place(.dog(1), nearHome(-24, 28));
    const lines = ticked(&b, 1, &.{}, &.{d(5, 0)});
    try testing.expectEqual(@as(?physics.Bumped, .{ .critter = .chicken(0) }), bumpOf(&lines));
    try testing.expectEqual(nearHome(-24, 0), b.dogs[0]);
    try testing.expectEqual(home, b.chickens[0]);
}

// ------------------------------------------------------ the chickens' turn

test "the newest poop blocks a chicken's step: it goes around it" {
    // Proves the fix that keeps no critter on unripe poop: the newest
    // poop touches the chicken's east side, on its way to a ripe one.
    var b = leashedAt(nearHome(0, 400));
    b.place(.chicken(0), home);
    poopAt(&b, 0, nearHome(100, 0));
    poopAt(&b, 1, nearHome(16, 0));
    b.laid = 2;
    _ = ticked(&b, 1, &.{}, &.{d(10, 0)});
    // Blocked east, it sidesteps the whole 5 px south (on the line, +).
    try testing.expectEqual(nearHome(0, 5), b.chickens[0]);
    try overlapsNone(&b);
}

test "a chicken in a chicken's step blocks it: it goes around it, as round a poop" {
    // Chicken 1 touches chicken 0's east side, on chicken 0's way to a
    // ripe poop; chicken 0 goes first, in seen order.
    var b = leashedAt(nearHome(0, 400));
    b.place(.chicken(0), home);
    b.place(.chicken(1), nearHome(20, 0));
    poopAt(&b, 0, nearHome(100, 0));
    b.laid = 7;
    _ = ticked(&b, 1, &.{}, &.{d(10, 0)});
    // Blocked east, it sidesteps the whole 5 px south (on the line, +).
    try testing.expectEqual(nearHome(0, 5), b.chickens[0]);
    try overlapsNone(&b);
}

test "a chicken eats every ripe poop its square overlaps, and the eaten slot is a line" {
    // Proves rule 10: 20 px off, a 5 px step overlaps it (16 is touching).
    var b = leashedAt(nearHome(0, 400));
    b.place(.chicken(0), home);
    poopAt(&b, 0, nearHome(20, 0));
    b.laid = 7;
    const lines = ticked(&b, 1, &.{}, &.{d(10, 0)});
    try testing.expectEqual(physics.Known.absent, b.poop_known[0]);
    var eaten: ?u16 = null;
    for (lines.slice()) |c| if (c == .eaten) {
        eaten = c.eaten;
    };
    try testing.expectEqual(@as(?u16, 0), eaten);
    try overlapsNone(&b);
}

test "a chicken sees ripe poop out to chicken_sight, and no farther: at it, it goes; a 256th past, it stays home" {
    for ([_]i32{ 0, 1 }) |past| {
        var b = leashedAt(nearHome(0, 400));
        b.place(.chicken(0), home);
        poopAt(&b, 0, .{ .x = home.x + physics.chicken_sight + past, .y = home.y });
        b.laid = 7;
        _ = ticked(&b, 1, &.{}, &.{d(10, 0)});
        if (past == 0) try testing.expect(b.chickens[0].x > home.x) else try testing.expectEqual(home, b.chickens[0]);
    }
}

test "no chicken moves in a tick the leashed dog ends where it began" {
    // Proves rule 9's "only if the leashed dog moved": its net move, not
    // its path. Out 10 px and back in one tick: the chicken, 100 px from
    // home, stays, and writes no line.
    var b = leashedAt(nearHome(0, 400));
    b.place(.chicken(0), nearHome(100, 0));
    const lines = ticked(&b, 1, &.{}, &.{ d(10, 0), d(-10, 0) });
    try testing.expectEqual(nearHome(100, 0), b.chickens[0]);
    try testing.expectEqual(@as(?physics.CritterLine, null), lineOf(&lines, .chicken(0)));
}

test "ripe: every slot but the newest, laid - 1 mod 2048, at laid 0 and 1 and across the slots' wrap and the counter's" {
    // Proves rule 11's arithmetic where it could slip: before any poop
    // (laid 0, the empty slot 2047), the first, the 2048th and 2049th,
    // and the u32 counter wrapping (2^32 is a multiple of 2048, so the
    // slot keeps counting).
    try testing.expect(physics.ripe(0, 0));
    try testing.expect(!physics.ripe(0, 2047));
    try testing.expect(!physics.ripe(1, 0));
    try testing.expect(physics.ripe(1, 1));
    try testing.expect(!physics.ripe(2048, 2047));
    try testing.expect(physics.ripe(2048, 0));
    try testing.expect(!physics.ripe(2049, 0));
    try testing.expect(physics.ripe(2049, 2047));
    try testing.expect(!physics.ripe(std.math.maxInt(u32), 2046));
    try testing.expect(physics.ripe(std.math.maxInt(u32), 2047));
}

// ------------------------------------------------------ the poops by tile

test "the poops by tile: a slot laid anew mid-drag leaves its old tile's list, so its old spot is free and its new one blocks" {
    // Proves `placePoop`'s unlink: slot 0's old poop stands 100 px ahead
    // of the leashed dog in the same tile as the spot behind it; the 2049th
    // poop takes slot 0 on the drag's first pixel-tick, and the dog walks
    // on through where the old one was.
    var b = leashedAt(px(500, 1050));
    poopAt(&b, 0, px(600, 1050));
    b.laid = physics.poop_count;
    b.walked[0] = physics.poop_every - @as(u32, @intCast(physics.px(1)));
    const lines = ticked(&b, 1, &.{}, &.{d(100, 0)});
    try testing.expectEqual(px(471, 1050), b.poops[0]);
    try testing.expectEqual(px(600, 1050), b.dogs[0]);
    try testing.expectEqual(@as(?physics.Bumped, null), bumpOf(&lines));
    try overlapsNone(&b);
    // The slot was seen at the start, so its line is its new point (the
    // page moves its poop), never an eaten line (metal-vmm QUEUE 210: the
    // lines walk only the slots seen at the start and those laid).
    var poop_lines: usize = 0;
    for (lines.slice()) |c| switch (c) {
        .poop => |l| {
            try testing.expectEqual(@as(u16, 0), l.n);
            try testing.expectEqual(px(471, 1050), l.at);
            poop_lines += 1;
        },
        .eaten => return error.TestUnexpectedResult,
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), poop_lines);
}

test "the poops by tile: a poop across the world's seam still blocks the leashed dog, which slides" {
    // Proves `near` takes the short way round (decision 14): the dog at
    // x = 10 px, the poop 20 px west of it (touching: a dog's half and a
    // poop's), at the far side of the world.
    var b = leashedAt(px(10, 1050));
    poopAt(&b, 3, px(@import("tiles.zig").world_px - 10, 1050));
    b.laid = 4;
    _ = ticked(&b, 1, &.{}, &.{d(-1, 0)});
    try testing.expectEqual(px(10, 1051), b.dogs[0]);
}
