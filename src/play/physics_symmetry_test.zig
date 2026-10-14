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
//! - **The transpose (and so a quarter turn): not exact.** A dog's wish
//!   step sweeps x, then y (`wishes`); transposed, the same step sweeps
//!   the other axis first, and a step that clips a corner is stopped by it
//!   in one order and not the other. A fraction of a pixel per clipped
//!   corner, and it compounds: over the fuzz's 300-tick scenes, typically
//!   a pixel or three, and now and then a drift becomes a bump in one
//!   orientation and not the other, the drag ends, and the scenes part.
//!   A quarter turn is mirror x after the transpose, and the mirror is
//!   exact, so its drift is the transpose's exactly; the tests hold that.
//!
//! The drag is given as single-axis displacements, so its own x-then-y
//! order maps to itself; only the wishes' order is left to show.

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
    return switch (s) {
        .mirror_x => .{ .x = world - p.x, .y = p.y },
        .mirror_y => .{ .x = p.x, .y = world - p.y },
        .transpose => .{ .x = p.y, .y = p.x },
        .quarter_turn => .{ .x = world - p.y, .y = p.x },
    };
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

/// How far apart, per axis, the farthest critter is between two boards.
fn apart(a: *const Board, b: *const Board) i32 {
    var w: i32 = 0;
    for (a.dogs, b.dogs) |p, q| w = @max(w, @max(physics.mag(p.x - q.x), physics.mag(p.y - q.y)));
    for (a.cows, b.cows) |p, q| w = @max(w, @max(physics.mag(p.x - q.x), physics.mag(p.y - q.y)));
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

// ------------------------------------------------------- hand-made scenes

test "a dog chasing the leashed dog, one of another breed keeping its distance: exact under every symmetry" {
    var b = leashedBoard();
    b.place(.dog(4), px(16300, 16170));
    b.place(.dog(1), px(15830, 16090));
    var script: [200]TickIn = undefined;
    straight(&script, .{ .dx = physics.px(3), .dy = physics.px(1) });
    for (std.enums.values(Sym)) |s| try expectExact(s, b, 0, &script);
}

test "a cow scooted off the dog's line: exact under every symmetry" {
    var b = leashedBoard();
    b.place(.cow(0), px(16200, 16013));
    var script: [60]TickIn = undefined;
    straight(&script, .{ .dx = physics.px(4), .dy = 0 });
    for (std.enums.values(Sym)) |s| try expectExact(s, b, 0, &script);
}

test "a leashed drag through the laid-out herd: exact under every symmetry" {
    const b = Board.laidOut();
    var script: [200]TickIn = undefined;
    straight(&script, .{ .dx = physics.px(7), .dy = physics.px(3) });
    for (std.enums.values(Sym)) |s| try expectExact(s, b, 112, &script);
}

test "a cow ON the dog's line goes to the dog's right: a quarter turn keeps that, a mirror makes it left, so the mirrors part at once" {
    var b = leashedBoard();
    b.place(.cow(0), px(16200, 16000));
    var script: [60]TickIn = undefined;
    straight(&script, .{ .dx = physics.px(4), .dy = 0 });
    try expectExact(.quarter_turn, b, 0, &script);
    for ([_]Sym{ .mirror_x, .mirror_y, .transpose }) |s| {
        try testing.expectEqual(@as(?physics.Tick, 1), drift(s, b, 0, &script).first);
    }
}

test "a pack: exact under the mirrors; the transpose parts (the wishes sweep x, then y), and a quarter turn by the very same drift" {
    var b = leashedBoard();
    var prng: std.Random.DefaultPrng = .init(5);
    const r = prng.random();
    for (1..13) |i| b.place(.dog(@intCast(i)), px(16000 + r.intRangeAtMost(i32, -400, 400), 16000 + r.intRangeAtMost(i32, -400, 400)));
    var script: [200]TickIn = undefined;
    straight(&script, .{ .dx = physics.px(2), .dy = physics.px(-1) });
    try expectExact(.mirror_x, b, 0, &script);
    try expectExact(.mirror_y, b, 0, &script);
    const t = drift(.transpose, b, 0, &script);
    try testing.expectEqual(@as(?physics.Tick, 27), t.first);
    try testing.expectEqual(t, drift(.quarter_turn, b, 0, &script));
}

// **THE MINIMAL SCENE**: the leashed dog still, dog 4 (its breed) 400 px
// off on the diagonal, closing on it at the speed, its step (−84, −84)
// in 256ths; a cow just off its path, 40 and 20 256ths beyond touching.
// Sweeping x first, dog 4 passes the cow on x and is stopped on y 20
// short: (−84, −20). Transposed, the cow is 20 and 40 off, x again
// first, and the dog ends (−84, −40), which is (−40, −84) back in this
// frame. One tick, 64 256ths apart.
test "the minimal scene: a dog's diagonal step clips a cow's corner in one axis order and not the other" {
    const hs = physics.dog_half + physics.cow_half;
    var b = leashedBoard();
    const dog: Point = px(16400, 16400);
    b.place(.dog(4), dog);
    b.place(.cow(0), .{ .x = dog.x - hs - 40, .y = dog.y - hs - 20 });
    const one = [1]TickIn{.{}};
    var a = b;
    play(&a, null, 1, 0, one[0]);
    try testing.expectEqual(Point{ .x = dog.x - 84, .y = dog.y - 20 }, a.dogs[4]);
    try expectExact(.mirror_x, b, 0, &one);
    try expectExact(.mirror_y, b, 0, &one);
    var t = mapBoard(.transpose, b);
    play(&t, .transpose, 1, 0, one[0]);
    try testing.expectEqual(mapPoint(.transpose, .{ .x = dog.x - 40, .y = dog.y - 84 }), t.dogs[4]);
    try testing.expectEqual(@as(i32, 64), drift(.transpose, b, 0, &one).worst);
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

test "random scenes (seeded): exact under the mirrors; a quarter turn drifts exactly as the transpose does" {
    var script: [300]TickIn = undefined;
    var prng: std.Random.DefaultPrng = .init(77);
    const r = prng.random();
    var parted: usize = 0;
    for (0..fuzzed(100)) |_| {
        var b: Board = undefined;
        randomScene(r, &b, &script);
        try expectExact(.mirror_x, b, 0, &script);
        try expectExact(.mirror_y, b, 0, &script);
        const t = drift(.transpose, b, 0, &script);
        try testing.expectEqual(t, drift(.quarter_turn, b, 0, &script));
        if (t.first != null) parted += 1;
    }
    // The transpose is no symmetry: most scenes part. Were none to, the
    // axis order would have stopped mattering and this file's account of
    // it would be stale.
    try testing.expect(parted > 0);
}

/// **ONE TICK'S DRIFT, WITHOUT A DRAG**: each dog takes one wish step, at
/// most `speed` long; the two axis orders each move a dog, per axis,
/// between 0 and the step's part, so they differ by at most `speed` on an
/// axis. That is one dog's bound; the fuzz holds it for the whole board,
/// later dogs reading the earlier ones' moved places. (With a drag the
/// wishes run once per pixel-tick, and one tick's drift was seen past a
/// pixel: no bound is claimed for it here.)
const one_tick_drift_most = physics.speed;

test "random scenes (seeded), each tick from the same board: with no drag, the transpose's drift in one tick is at most the speed" {
    var script: [300]TickIn = undefined;
    var prng: std.Random.DefaultPrng = .init(78);
    const r = prng.random();
    var worst: i32 = 0;
    for (0..fuzzed(100)) |_| {
        var b: Board = undefined;
        randomScene(r, &b, &script);
        for (&script) |*in| in.n = 0;
        for (script, 1..) |in, t| {
            var c = mapBoard(.transpose, b);
            play(&b, null, t, 0, in);
            play(&c, .transpose, t, 0, in);
            const mb = mapBoard(.transpose, b);
            worst = @max(worst, apart(&mb, &c));
        }
    }
    try testing.expect(worst <= one_tick_drift_most);
    // Not vacuous: some tick does drift.
    try testing.expect(worst > 0);
}
