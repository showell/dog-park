//! **THE PHYSICS UNDER THE WORLD'S SYMMETRIES**: a scene mirrored or
//! rotated about the world's centre, its drag mapped the same way, played
//! against the scene itself, the outcome mapped and compared bit for bit.
//!
//! What holds, and what does not:
//! - **Mirror x, mirror y: exact**, over hand-made scenes and the seeded
//!   fuzz. Every division truncates toward zero, which is odd
//!   (−a / b = −(a / b)), so the integer arithmetic commutes with a sign
//!   flip; the world is a whole number of tiles, so the tile spans mirror.
//!   The exception is a tie broken by a direction: a cow on the dog's line
//!   goes to the dog's RIGHT (docs/PHYSICS.md), and a mirror turns right
//!   into left (the nearest spot's E, S, W, N order and coincident
//!   centres' east are the same kind of tie).
//! - **The transpose (and so a quarter turn): exact**, over the same
//!   scenes and fuzz. A dog's wish step is one straight move (decision
//!   18, `stepSwept`): its contact is a fraction of the whole step, both
//!   axes cut at that fraction the same way, and a slide only along the
//!   one face it met, so no axis goes first. A quarter turn is mirror x
//!   after the transpose. The same direction-broken ties apply: the
//!   on-line cow's right is kept by a quarter turn, not by the transpose.
//!
//! - **A shift by any vector, mod the world (the torus' signature,
//!   decision 14): exact**, over the same scenes and fuzz, the action put
//!   across the seam and the corner too. Every difference is the short way
//!   round and every rectangle is in the tick's own frame, so nothing
//!   depends on where in the world the scene stands, beyond the tile grid
//!   (which critters the region's tiles hold): these scenes keep everything
//!   that matters far inside the region.
//!
//! The drag is given as single-axis displacements, so its own x-then-y
//! order maps to itself under every symmetry here.

const std = @import("std");
const physics = @import("physics.zig");
const testing = std.testing;
const Board = physics.Board;
const Point = physics.Point;
const Disp = physics.Disp;
const world = physics.world;

const fuzz = @import("test_options").fuzz;
fn fuzzed(full: usize) usize {
    return switch (fuzz) {
        .fast => full / 10,
        .full => full,
    };
}

/// The world's symmetries tested, about its centre: a quarter turn is
/// clockwise on the screen (+y is south).
const Sym = enum { mirror_x, mirror_y, transpose, quarter_turn };

fn mapPoint(s: Sym, p: Point) Point {
    return physics.wrapped(switch (s) {
        .mirror_x => .{ .x = world - p.x, .y = p.y },
        .mirror_y => .{ .x = p.x, .y = world - p.y },
        .transpose => .{ .x = p.y, .y = p.x },
        .quarter_turn => .{ .x = world - p.y, .y = p.x },
    });
}

fn mapDisp(s: Sym, d: Disp) Disp {
    return switch (s) {
        .mirror_x => .{ .dx = -d.dx, .dy = d.dy, .ms = d.ms },
        .mirror_y => .{ .dx = d.dx, .dy = -d.dy, .ms = d.ms },
        .transpose => .{ .dx = d.dy, .dy = d.dx, .ms = d.ms },
        .quarter_turn => .{ .dx = -d.dy, .dy = d.dx, .ms = d.ms },
    };
}

fn mapBoard(s: Sym, b: Board) Board {
    var m = b;
    for (&m.dogs) |*p| p.* = mapPoint(s, p.*);
    for (&m.cows) |*p| p.* = mapPoint(s, p.*);
    return m;
}

/// The most displacements a scripted tick has: single-axis ones, well
/// within `most_displacements`.
const most_steps = 8;
const TickIn = struct { drag: [most_steps]Disp = undefined, n: usize = 0, letgo: bool = false };

/// How far apart, per axis, the farthest critter is between two boards,
/// the short way round.
fn apart(a: *const Board, b: *const Board) i32 {
    var w: i32 = 0;
    for (a.dogs, b.dogs) |p, q| {
        const d = physics.delta(p, q);
        w = @max(w, @max(physics.mag(d.x), physics.mag(d.y)));
    }
    for (a.cows, b.cows) |p, q| {
        const d = physics.delta(p, q);
        w = @max(w, @max(physics.mag(d.x), physics.mag(d.y)));
    }
    return w;
}

/// One tick of a script on a board, its drag mapped by `s` (null: as is);
/// the leash goes on at tick 1.
fn play(b: *Board, s: ?Sym, t: physics.Tick, leashed: u16, in: TickIn) void {
    var humans: [2]physics.Human = undefined;
    var nh: usize = 0;
    if (t == 1) {
        humans[nh] = .{ .leash = leashed };
        nh += 1;
    }
    if (in.letgo) {
        humans[nh] = .letgo;
        nh += 1;
    }
    var drag: [most_steps]Disp = undefined;
    for (in.drag[0..in.n], 0..) |d, k| drag[k] = if (s) |sym| mapDisp(sym, d) else d;
    var lines: physics.Lines = .{};
    if (physics.tick(b, t, humans[0..nh], drag[0..in.n], &lines)) |r| std.debug.panic("refused: {t}", .{r});
}

const Drift = struct {
    /// The first tick after which the mapped outcome and the mapped
    /// scene's differ.
    first: ?physics.Tick = null,
    /// The farthest apart any critter was, per axis, in 256ths.
    worst: i32 = 0,
    /// The ticks after which the holds differed (a bump in one only).
    hold_differs: usize = 0,
};

/// The scene and its image under `s`, played side by side.
fn drift(s: Sym, start: Board, leashed: u16, script: []const TickIn) Drift {
    var a = start;
    var b = mapBoard(s, start);
    var d: Drift = .{};
    for (script, 1..) |in, t| {
        play(&a, null, t, leashed, in);
        play(&b, s, t, leashed, in);
        const ma = mapBoard(s, a);
        const w = apart(&ma, &b);
        if (w != 0 and d.first == null) d.first = t;
        d.worst = @max(d.worst, w);
        if (!std.meta.eql(a.hold, b.hold)) d.hold_differs += 1;
    }
    return d;
}

fn px(x: i32, y: i32) Point {
    return .{ .x = physics.px(x), .y = physics.px(y) };
}

const centre = px(16000, 16000);

fn leashedBoard() Board {
    var b = Board.empty();
    b.place(.dog(0), centre);
    return b;
}

/// Every tick drags `d`, as its x part then its y part.
fn straight(script: []TickIn, d: Disp) void {
    for (script) |*t| {
        t.* = .{};
        t.drag[0] = .{ .dx = d.dx, .dy = 0 };
        t.drag[1] = .{ .dx = 0, .dy = d.dy };
        t.n = 2;
    }
}

fn expectExact(s: Sym, start: Board, leashed: u16, script: []const TickIn) !void {
    const d = drift(s, start, leashed, script);
    if (d.first) |t| {
        std.debug.print("{t}: the outcomes part after tick {}, {} 256ths apart at worst\n", .{ s, t, d.worst });
        return error.NotSymmetric;
    }
    try testing.expectEqual(@as(usize, 0), d.hold_differs);
}

// ---------------------------------------------- the shift (decision 14)

/// Every critter moved by `v`, mod the world.
fn shiftBoard(v: Point, b: Board) Board {
    var m = b;
    for (&m.dogs) |*p| p.* = physics.wrapped(.{ .x = p.x + v.x, .y = p.y + v.y });
    for (&m.cows) |*p| p.* = physics.wrapped(.{ .x = p.x + v.x, .y = p.y + v.y });
    return m;
}

/// The vectors a scene is shifted by: the scenes stand at the world's
/// middle, so these put the action across x = 0, across y = 0, on the
/// corner, a pixel off it either way, and at odd places in 256ths.
const shifts = [_]Point{
    .{ .x = -physics.px(16000), .y = 0 },
    .{ .x = 0, .y = -physics.px(16000) },
    .{ .x = -physics.px(16000), .y = -physics.px(16000) },
    .{ .x = physics.px(16000) + physics.px(1), .y = physics.px(16000) - physics.px(1) },
    .{ .x = physics.px(15800), .y = -physics.px(16200) },
    .{ .x = 1, .y = 0 },
    .{ .x = 12345 * 256 + 77, .y = -(9876 * 256 + 3) },
    .{ .x = physics.world - 1, .y = 1 },
};

/// The scene and itself shifted by `v`, played side by side.
fn shiftDrift(v: Point, start: Board, leashed: u16, script: []const TickIn) Drift {
    var a = start;
    var b = shiftBoard(v, start);
    var d: Drift = .{};
    for (script, 1..) |in, t| {
        play(&a, null, t, leashed, in);
        play(&b, null, t, leashed, in);
        const ma = shiftBoard(v, a);
        const w = apart(&ma, &b);
        if (w != 0 and d.first == null) d.first = t;
        d.worst = @max(d.worst, w);
        if (!std.meta.eql(a.hold, b.hold)) d.hold_differs += 1;
    }
    return d;
}

fn expectShifted(start: Board, leashed: u16, script: []const TickIn) !void {
    for (shifts) |v| {
        const d = shiftDrift(v, start, leashed, script);
        if (d.first) |t| {
            std.debug.print("shifted by ({}, {}): the outcomes part after tick {}, {} 256ths apart at worst\n", .{ v.x, v.y, t, d.worst });
            return error.NotShiftInvariant;
        }
        try testing.expectEqual(@as(usize, 0), d.hold_differs);
    }
}

// ------------------------------------------------------- hand-made scenes

test "a dog chasing the leashed dog, one of another breed keeping its distance: exact under every symmetry" {
    var b = leashedBoard();
    b.place(.dog(4), px(16300, 16170));
    b.place(.dog(1), px(15830, 16090));
    var script: [200]TickIn = undefined;
    straight(&script, .{ .dx = physics.px(3), .dy = physics.px(1) });
    for (std.enums.values(Sym)) |s| try expectExact(s, b, 0, &script);
    try expectShifted(b, 0, &script);
}

test "a cow scooted off the dog's line: exact under every symmetry" {
    var b = leashedBoard();
    b.place(.cow(0), px(16200, 16013));
    var script: [60]TickIn = undefined;
    straight(&script, .{ .dx = physics.px(4), .dy = 0 });
    for (std.enums.values(Sym)) |s| try expectExact(s, b, 0, &script);
    try expectShifted(b, 0, &script);
}

test "a leashed drag through the laid-out herd: exact under every symmetry" {
    const b = Board.laidOut();
    var script: [200]TickIn = undefined;
    straight(&script, .{ .dx = physics.px(7), .dy = physics.px(3) });
    for (std.enums.values(Sym)) |s| try expectExact(s, b, 112, &script);
    try expectShifted(b, 112, &script);
}

test "a cow ON the dog's line goes to the dog's right: a quarter turn keeps that, a mirror makes it left, so the mirrors part at once" {
    var b = leashedBoard();
    b.place(.cow(0), px(16200, 16000));
    var script: [60]TickIn = undefined;
    straight(&script, .{ .dx = physics.px(4), .dy = 0 });
    try expectExact(.quarter_turn, b, 0, &script);
    // A shift keeps the dog's right too.
    try expectShifted(b, 0, &script);
    for ([_]Sym{ .mirror_x, .mirror_y, .transpose }) |s| {
        try testing.expectEqual(@as(?physics.Tick, 1), drift(s, b, 0, &script).first);
    }
}

test "a pack: exact under every symmetry" {
    var b = leashedBoard();
    var prng: std.Random.DefaultPrng = .init(5);
    const r = prng.random();
    for (1..13) |i| b.place(.dog(@intCast(i)), px(16000 + r.intRangeAtMost(i32, -400, 400), 16000 + r.intRangeAtMost(i32, -400, 400)));
    var script: [200]TickIn = undefined;
    straight(&script, .{ .dx = physics.px(2), .dy = physics.px(-1) });
    for (std.enums.values(Sym)) |s| try expectExact(s, b, 0, &script);
    try expectShifted(b, 0, &script);
}

// **THE MINIMAL SCENE**: the leashed dog still, dog 4 (its breed) 400 px
// off on the diagonal, closing on it at the speed, its step (−84, −84)
// in 256ths; a cow just off its path, 40 and 20 256ths beyond touching.
// Swept x then y, dog 4 would pass the cow on x and stop on y 20 short,
// (−84, −20), and transposed end (−40, −84) in this frame: 64 256ths
// apart. As one move (decision 18), the step overlaps the cow
// on y at 20/84 of the way and presses into its x face at 40/84: cut
// there to (−40, −40), it slides the rest of y to (−40, −84), and the
// transpose gives the same.
test "the minimal scene: a dog's diagonal step meets a cow's face, not its corner, the same in every orientation" {
    // Its numbers are the played knobs' speed and halves.
    if (physics.knobs != .played) return error.SkipZigTest;
    const hs = physics.dog_half + physics.cow_half;
    var b = leashedBoard();
    const dog: Point = px(16400, 16400);
    b.place(.dog(4), dog);
    b.place(.cow(0), .{ .x = dog.x - hs - 40, .y = dog.y - hs - 20 });
    const one = [1]TickIn{.{}};
    var a = b;
    play(&a, null, 1, 0, one[0]);
    try testing.expectEqual(Point{ .x = dog.x - 40, .y = dog.y - 84 }, a.dogs[4]);
    for (std.enums.values(Sym)) |s| try expectExact(s, b, 0, &one);
    try expectShifted(b, 0, &one);
}

// --------------------------------------------------------- the seeded fuzz

/// Up to 40 dogs and 8 cows within 500 px of the leashed dog on each axis;
/// a drag of up to three displacements a tick, each split x then y,
/// heading one way for about 20 ticks at a time, within the cap; now and
/// then a letgo.
fn randomScene(r: std.Random, b: *Board, script: []TickIn) void {
    b.* = leashedBoard();
    const spread = physics.px(500);
    const dogs = r.intRangeAtMost(u16, 1, 40);
    for (1..dogs + 1) |i| b.place(.dog(@intCast(i)), .{ .x = centre.x + r.intRangeAtMost(i32, -spread, spread), .y = centre.y + r.intRangeAtMost(i32, -spread, spread) });
    const cows = r.intRangeAtMost(u16, 0, 8);
    for (0..cows) |i| b.place(.cow(@intCast(i)), .{ .x = centre.x + r.intRangeAtMost(i32, -spread, spread), .y = centre.y + r.intRangeAtMost(i32, -spread, spread) });
    var hx: i32 = r.intRangeAtMost(i32, -2000, 2000);
    var hy: i32 = r.intRangeAtMost(i32, -2000, 2000);
    for (script) |*t| {
        t.* = .{};
        if (r.uintLessThan(u32, 20) == 0) {
            hx = r.intRangeAtMost(i32, -2000, 2000);
            hy = r.intRangeAtMost(i32, -2000, 2000);
        }
        const n = r.uintLessThan(u32, 4);
        for (0..n) |_| {
            t.drag[t.n] = .{ .dx = hx + r.intRangeAtMost(i32, -300, 300), .dy = 0 };
            t.drag[t.n + 1] = .{ .dx = 0, .dy = hy + r.intRangeAtMost(i32, -300, 300) };
            t.n += 2;
        }
        std.debug.assert(physics.withinCap(t.drag[0..t.n]));
        t.letgo = r.uintLessThan(u32, 60) == 0;
    }
}

test "random scenes (seeded): exact under every symmetry" {
    var script: [300]TickIn = undefined;
    var prng: std.Random.DefaultPrng = .init(77);
    const r = prng.random();
    for (0..fuzzed(100)) |_| {
        var b: Board = undefined;
        randomScene(r, &b, &script);
        for (std.enums.values(Sym)) |s| try expectExact(s, b, 0, &script);
        try expectShifted(b, 0, &script);
    }
}
