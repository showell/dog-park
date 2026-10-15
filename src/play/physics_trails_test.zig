//! **LAYER 1: TRAILS WITHOUT OBSTRUCTION** (docs/PHYSICS.md, "Poop and
//! chickens"; decisions 29-31): where the herd's poop lands, how a step
//! goes around a poop or a chicken (the sidestep, the shove), the leashed
//! dog's slide, and the chickens' turn. Each test says what it proves.
//! Every scene stands near chicken 0's home, so its chicken has no reason
//! to walk home in the middle of what the test watches.

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

test "the leashed dog alone poops 30 px behind itself, back along its step, at the pixel-tick its walk passes 700 px" {
    // Proves rule 3 for the herd of one: no follower, so the leashed dog
    // is the deepest, and behind is the reverse of its step. 700 px east
    // in seven ticks: the poop is due on the very last pixel-tick.
    var b = leashedAt(px(15000, 16250));
    var t: physics.Tick = 1;
    while (t <= 6) : (t += 1) _ = ticked(&b, t, &.{}, &.{d(100, 0)});
    try testing.expectEqual(@as(u32, 0), b.laid);
    const lines = ticked(&b, 7, &.{}, &.{d(100, 0)});
    try testing.expectEqual(@as(u32, 1), b.laid);
    try testing.expectEqual(px(15700, 16250), b.dogs[0]);
    try testing.expectEqual(px(15670, 16250), b.poops[0]);
    var poop: ?physics.PoopLine = null;
    for (lines.slice()) |c| if (c == .poop) {
        poop = c.poop;
    };
    try testing.expectEqual(physics.PoopLine{ .n = 0, .at = px(15670, 16250) }, poop.?);
}

test "the trail comes from the tail: a chain of three of the leashed dog's breed, and the last of them poops 30 px behind itself, into the park's next slots in turn" {
    // Proves rule 2: depth runs through the anchors (dog 4 follows the
    // leashed dog, dog 8 follows dog 4), and the deepest poops, away from
    // its anchor. Dog 1, another breed, is no part of the herd's depth.
    var b = leashedAt(px(15000, 16250));
    b.place(.dog(4), px(14920, 16250));
    b.place(.dog(8), px(14840, 16250));
    var t: physics.Tick = 1;
    while (t <= 7) : (t += 1) _ = ticked(&b, t, &.{}, &.{d(100, 0)});
    // Each closes to the band's outer edge, 100 px behind the one ahead.
    try testing.expectEqual(px(15600, 16250), b.dogs[4]);
    try testing.expectEqual(px(15500, 16250), b.dogs[8]);
    try testing.expectEqual(@as(u32, 1), b.laid);
    try testing.expectEqual(px(15470, 16250), b.poops[0]);
    // Seven more: the next 700 px, the next slot, behind the tail again.
    while (t <= 14) : (t += 1) _ = ticked(&b, t, &.{}, &.{d(100, 0)});
    try testing.expectEqual(@as(u32, 2), b.laid);
    try testing.expectEqual(px(16170, 16250), b.poops[1]);
    try testing.expectEqual(physics.Known.present, b.poop_known[0]);
    try overlapsNone(&b);
}

test "a poop whose spot is taken lands at the nearest free spot on the rings around it, never on a critter" {
    // Proves rule 3's search: a chicken stands on the spot behind the
    // leashed dog; the first ring (4 px out) is all inside it, and the
    // poop lands on a later ring, its north-west corner first, clear.
    var b = leashedAt(px(15000, 16250));
    b.walked[0] = physics.poop_every - @as(u32, @intCast(physics.px(1)));
    b.place(.chicken(0), px(14971, 16250));
    _ = ticked(&b, 1, &.{}, &.{d(1, 0)});
    try testing.expectEqual(@as(u32, 1), b.laid);
    // The spot is (14971, 16250); 16 px clears the chicken's half and the
    // poop's, so the first spot that fits is on the ring 16 px out.
    try testing.expectEqual(px(14971 - 16, 16250 - 16), b.poops[0]);
    try overlapsNone(&b);
}

// ---------------------------------------------------------- the sidestep

test "the sidestep, as a function: the axis the blocker is farther along is zeroed (ties zero x), the other keeps its part or, with none, goes the step's size away (on the line, +)" {
    // Proves rule 5's arithmetic, case by case.
    const o: Point = .{ .x = 0, .y = 0 };
    const Case = struct { why: physics.Veto.Why, blocker: Point, step: Point, want: ?Point };
    const cases = [_]Case{
        // Ahead to the east, the step diagonal: x zeroed, y kept.
        .{ .why = .poop, .blocker = px(26, 5), .step = .{ .x = 256, .y = 100 }, .want = .{ .x = 0, .y = 100 } },
        // Ahead to the north: y zeroed, x kept.
        .{ .why = .chicken, .blocker = px(5, -26), .step = .{ .x = 256, .y = -100 }, .want = .{ .x = 256, .y = 0 } },
        // Straight ahead east, a little south: x zeroed, the whole size north.
        .{ .why = .poop, .blocker = px(26, 3), .step = .{ .x = 256, .y = 0 }, .want = .{ .x = 0, .y = -256 } },
        // Straight ahead south, on the line: y zeroed, + (east).
        .{ .why = .poop, .blocker = px(0, 26), .step = .{ .x = 0, .y = 128 }, .want = .{ .x = 128, .y = 0 } },
        // A tie of the axes zeroes x.
        .{ .why = .poop, .blocker = px(10, 10), .step = .{ .x = 256, .y = 256 }, .want = .{ .x = 0, .y = 256 } },
        // Only a poop or a chicken is gone around.
        .{ .why = .critter, .blocker = px(26, 0), .step = .{ .x = 256, .y = 0 }, .want = null },
        .{ .why = .edge, .blocker = o, .step = .{ .x = 256, .y = 0 }, .want = null },
    };
    for (cases) |c| {
        try testing.expectEqual(c.want, physics.sidestep(.{ .why = c.why, .at = o, .blocker = c.blocker }, c.step));
    }
}

test "a dog whose step a poop vetoes takes the exact sidestep instead; and when the sidestep would land on poop too, it stays" {
    // Proves rule 5 in the walk, and that neither try lands on poop.
    // Dog 4 follows the leashed dog west; a poop touches its west side,
    // on its line: it steps 1 px south instead (on the line, +).
    var b = leashedAt(nearHome(-200, 400));
    b.place(.dog(4), nearHome(0, 400));
    poopAt(&b, 9, nearHome(-26, 400));
    b.laid = 10;
    _ = ticked(&b, 1, &.{}, &.{d(-1, 0)});
    try testing.expectEqual(nearHome(0, 401), b.dogs[4]);
    try overlapsNone(&b);
    // A second poop touching its south side: the sidestep is vetoed too.
    var c = leashedAt(nearHome(-200, 400));
    c.place(.dog(4), nearHome(0, 400));
    poopAt(&c, 9, nearHome(-26, 400));
    poopAt(&c, 3, nearHome(0, 426));
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
    // touches cow 0's west side, 19 px north of its line.
    var b = leashedAt(nearHome(191, 19));
    b.place(.cow(0), nearHome(40, 19));
    b.place(.chicken(0), home);
    _ = ticked(&b, 1, &.{}, &.{d(1, 0)});
    try testing.expectEqual(Point{ .x = home.x + physics.px(40) - 128, .y = home.y + physics.px(19) }, b.cows[0]);
    try testing.expectEqual(Point{ .x = home.x - 128, .y = home.y - 128 }, b.chickens[0]);
    try overlapsNone(&b);
    // Cow 1, touching cow 0 on the north-west and the chicken on the
    // north: cow 0 nudges it, and the chicken, shoved north, would land
    // on it. Nobody goes west; cow 0 sidesteps south instead.
    var c = leashedAt(nearHome(191, 19));
    c.place(.cow(0), nearHome(40, 19));
    c.place(.cow(1), nearHome(-20, -40));
    c.place(.chicken(0), home);
    _ = ticked(&c, 1, &.{}, &.{d(1, 0)});
    try testing.expectEqual(Point{ .x = home.x + physics.px(40), .y = home.y + physics.px(19) + 128 }, c.cows[0]);
    try testing.expectEqual(nearHome(-20, -40), c.cows[1]);
    try testing.expectEqual(home, c.chickens[0]);
    try overlapsNone(&c);
}

// ------------------------------------------------------ the leashed dog

test "the leashed dog shoves a free chicken off its front: it slides off within 30 px, the drag goes on, no bump" {
    // Proves rules 6 and 7 for the leashed dog: on its line, the chicken
    // goes south (+), a pixel each way a pixel-tick, until clear.
    var b = leashedAt(nearHome(-30, 0));
    b.place(.chicken(0), home);
    const lines = ticked(&b, 1, &.{}, &.{d(40, 0)});
    try testing.expectEqual(@as(?physics.Bumped, null), bumpOf(&lines));
    try testing.expectEqual(nearHome(10, 0), b.dogs[0]);
    try testing.expectEqual(nearHome(30, 30), b.chickens[0]);
    try testing.expect(lineOf(&lines, .chicken(0)) != null);
    try overlapsNone(&b);
}

test "the leashed dog slides around a poop, a pixel sideways each pixel-tick, away from it, then goes on: no bump" {
    // Proves rule 7's slide: 5 px off its line to the south, so it slides
    // north, 21 pixel-ticks till clear of the poop, then 9 px east.
    var b = leashedAt(nearHome(0, 400));
    poopAt(&b, 4, nearHome(26, 405));
    b.laid = 5;
    const lines = ticked(&b, 1, &.{}, &.{d(30, 0)});
    try testing.expectEqual(@as(?physics.Bumped, null), bumpOf(&lines));
    try testing.expectEqual(nearHome(9, 379), b.dogs[0]);
    try overlapsNone(&b);
}

test "the leashed dog bumps a boxed-in chicken only when the shove and the slide both fail, and stays where it touched: no setback" {
    // Proves rule 7's last resort, and that the 6 px setback is gone: a
    // cow behind the chicken stops the shove, a dog of another breed
    // beside the leashed dog the slide.
    var b = leashedAt(nearHome(-30, 0));
    b.place(.chicken(0), home);
    b.place(.cow(0), nearHome(40, 0));
    b.place(.dog(1), nearHome(-30, 40));
    const lines = ticked(&b, 1, &.{}, &.{d(5, 0)});
    try testing.expectEqual(@as(?physics.Bumped, .{ .critter = .chicken(0) }), bumpOf(&lines));
    try testing.expectEqual(nearHome(-30, 0), b.dogs[0]);
    try testing.expectEqual(home, b.chickens[0]);
}

// ------------------------------------------------------ the chickens' turn

test "the chickens' turn: a chicken steps half the leashed dog's net move toward the nearest ripe poop, at most 8 px, passing over the newest" {
    // Proves rule 9's step size and rule 11's ripeness: the newest poop
    // (slot 1, laid 2) is nearer, but not ripe, so the chicken goes for
    // slot 0.
    var b = leashedAt(nearHome(0, 400));
    b.place(.chicken(0), home);
    poopAt(&b, 0, nearHome(100, 0));
    poopAt(&b, 1, nearHome(-50, 0));
    b.laid = 2;
    var lines = ticked(&b, 1, &.{}, &.{d(10, 0)});
    try testing.expectEqual(nearHome(5, 0), b.chickens[0]);
    try testing.expectEqual(physics.CritterLine{ .who = .chicken(0), .before = home, .after = nearHome(5, 0) }, lineOf(&lines, .chicken(0)).?);
    lines = ticked(&b, 2, &.{}, &.{d(30, 0)});
    try testing.expectEqual(nearHome(13, 0), b.chickens[0]);
}

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

test "with nothing to forage a chicken walks home, but only from more than 32 px off; one at rest writes no line" {
    // Proves rule 9's homing and its deadband.
    var b = leashedAt(nearHome(0, 400));
    b.place(.chicken(0), nearHome(100, 0));
    _ = ticked(&b, 1, &.{}, &.{d(30, 0)});
    try testing.expectEqual(nearHome(92, 0), b.chickens[0]);
    var c = leashedAt(nearHome(0, 400));
    c.place(.chicken(0), nearHome(30, 0));
    const lines = ticked(&c, 1, &.{}, &.{d(30, 0)});
    try testing.expectEqual(nearHome(30, 0), c.chickens[0]);
    try testing.expectEqual(@as(?physics.CritterLine, null), lineOf(&lines, .chicken(0)));
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
    var b = leashedAt(px(15200, 16250));
    poopAt(&b, 0, px(15300, 16250));
    b.laid = physics.poop_count;
    b.walked[0] = physics.poop_every - @as(u32, @intCast(physics.px(1)));
    const lines = ticked(&b, 1, &.{}, &.{d(100, 0)});
    try testing.expectEqual(px(15171, 16250), b.poops[0]);
    try testing.expectEqual(px(15300, 16250), b.dogs[0]);
    try testing.expectEqual(@as(?physics.Bumped, null), bumpOf(&lines));
    try overlapsNone(&b);
}

test "the poops by tile: a poop across the world's seam still blocks the leashed dog, which slides" {
    // Proves `near` takes the short way round (decision 14): the dog at
    // x = 10 px, the poop 26 px west of it, at the far side of the world.
    var b = leashedAt(px(10, 16250));
    poopAt(&b, 3, px(@import("tiles.zig").world_px - 16, 16250));
    b.laid = 4;
    _ = ticked(&b, 1, &.{}, &.{d(-1, 0)});
    try testing.expectEqual(px(10, 16251), b.dogs[0]);
}
