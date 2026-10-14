//! **THE PHYSICS AS IT WAS** before the neighbour lists and the overlap
//! marks (test only): the reference `physics_identity_test.zig` holds the
//! physics to, board for board.
//!
//! The physics (docs/PHYSICS.md): the critters' board and one tick of
//! it, the shared Zig that the page (as wasm) and the server (natively)
//! both run, so they agree to the bit.
//!
//! A tick is a pure function: the board before, plus what the human did
//! during it (`Human` inputs, then the drag's displacements), gives the
//! board after and the tick's checked lines (`Lines`). No randomness, no
//! clock, no allocator: fixed buffers only, so it compiles to
//! wasm32-freestanding.
//!
//! **Units:** every position is an `i32` count of 256ths of a pixel; every
//! product is `i64`. Every centre-to-centre difference goes through
//! `delta` (decision 14: the wrap will change that one function).
//!
//! **The cascade:** the leashed dog, then the cows by number, then the
//! other dogs by number (`rank`). Within a tick: for each internal step of
//! the drag, the cows react (their grid rule, `scoot`), then the
//! leashed dog takes the step; then every awake dog takes its wish step.
//! The nearest spot clear of everyone (a push's or an overlap's jump) is
//! physics_jump.zig.

const std = @import("std");
const tiles = @import("tiles.zig");
const jump = @import("physics_jump.zig");
const physics = @import("physics.zig");

pub const dog_count = physics.dog_count;
pub const cow_count = physics.cow_count;
pub const critter_count = dog_count + cow_count;

/// 256ths in a pixel.
pub const unit: i32 = 256;

pub fn px(n: i32) i32 {
    return n * unit;
}

/// The world's side, in 256ths.
pub const world: i32 = px(tiles.world_px);
/// A tile's side, in 256ths.
pub const tile: i32 = px(tiles.tile_px);

// The knobs: physics.zig's own (`-Dknobs` picks the tuning), so the
// identity test proves the optimisation under every tuning.
pub const dog_half = physics.dog_half;
pub const cow_half = physics.cow_half;
pub const speed = physics.speed;
pub const dead_zone = physics.dead_zone;
pub const awake_reach = physics.awake_reach;
pub const wary = physics.wary;
pub const follow = physics.follow;
pub const band_inner = physics.band_inner;
pub const band_outer = physics.band_outer;
pub const cow_room = physics.cow_room;
pub const region_reach = physics.region_reach;
pub const step_most = physics.step_most;
pub const cap = physics.cap;
pub const most_displacements = physics.most_displacements;
pub const most_humans = physics.most_humans;
pub const let_go_ticks = physics.let_go_ticks;
pub const most_ticks = physics.most_ticks;
pub const scare_box = physics.scare_box;
pub const lane = physics.lane;
pub const jump_reach = physics.jump_reach;
/// Breeds: dog n has look n mod 4.
pub const breeds = 4;

pub const Tick = u64;

pub const Point = physics.Point;

/// **THE ONE DIFFERENCE**: from `a` to `b`, per axis. Every centre-to-centre
/// difference in the physics goes through here (decision 14).
pub fn delta(a: Point, b: Point) Point {
    return .{ .x = b.x - a.x, .y = b.y - a.y };
}

pub const Axis = physics.Axis;

pub fn on(p: Point, axis: Axis) i32 {
    return switch (axis) {
        .x => p.x,
        .y => p.y,
    };
}

pub fn across(axis: Axis) Axis {
    return switch (axis) {
        .x => .y,
        .y => .x,
    };
}

pub fn moved(p: Point, axis: Axis, by: i32) Point {
    return switch (axis) {
        .x => .{ .x = p.x + by, .y = p.y },
        .y => .{ .x = p.x, .y = p.y + by },
    };
}

pub fn mag(v: i32) i32 {
    return if (v < 0) -v else v;
}

pub fn sign(v: i32) i32 {
    return if (v > 0) 1 else if (v < 0) -1 else 0;
}

/// The squared length of a vector, in `i64`.
pub fn len2(v: Point) i64 {
    const x: i64 = v.x;
    const y: i64 = v.y;
    return x * x + y * y;
}

/// The integer square root, rounded down.
pub fn isqrt(v: i64) i64 {
    std.debug.assert(v >= 0);
    return std.math.sqrt(@as(u64, @intCast(v)));
}

pub const Kind = physics.Kind;

/// A critter, by kind and number.
pub const Critter = physics.Critter;

/// Whether the board has a critter: the page has only those it received;
/// the server has every one.
pub const Known = physics.Known;

/// A leashed dog's drag: on (the pointer is down), or ended at a tick (the
/// let-go timer runs from it).
pub const Drag = physics.Drag;

pub const Leashed = physics.Leashed;

/// Who is leashed, if anyone, and the drag.
pub const Hold = physics.Hold;

pub const Board = physics.Board;

/// **RANK**: the cascade's order. The leashed dog is 0, cow n is 1 + n, dog
/// n is 1 + cows + n. Lower is more alpha.
pub fn rank(leashed: ?u16, c: Critter) u32 {
    if (c.kind == .dog and leashed != null and leashed.? == c.n) return 0;
    return switch (c.kind) {
        .cow => 1 + @as(u32, c.n),
        .dog => 1 + cow_count + @as(u32, c.n),
    };
}

/// A closed rectangle, in 256ths.
pub const Rect = physics.Rect;

pub const world_rect: Rect = .{ .lo = .{ .x = 0, .y = 0 }, .hi = .{ .x = world, .y = world } };

/// Two squares overlap: |px − qx| < (a + b)/2 and |py − qy| < (a + b)/2.
pub fn squaresOverlap(p: Point, ph: i32, q: Point, qh: i32) bool {
    const d = delta(p, q);
    return mag(d.x) < ph + qh and mag(d.y) < ph + qh;
}

/// The region: the 2000 px square around the leashed dog at the tick's
/// start.
pub fn region(center: Point) Rect {
    return Rect.square(center, region_reach);
}

/// The tiles a rectangle meets, half-open: sharing some of a tile's
/// interior; clipped to the world.
pub const TileSpan = struct {
    col_lo: i32,
    col_hi: i32,
    row_lo: i32,
    row_hi: i32,

    pub fn of(r: Rect) TileSpan {
        return .{
            .col_lo = @max(0, @divFloor(r.lo.x, tile)),
            .col_hi = @min(tiles.world_tiles - 1, ceilDiv(r.hi.x, tile) - 1),
            .row_lo = @max(0, @divFloor(r.lo.y, tile)),
            .row_hi = @min(tiles.world_tiles - 1, ceilDiv(r.hi.y, tile) - 1),
        };
    }
    pub fn holds(self: TileSpan, t: tiles.Tile) bool {
        return t.col >= self.col_lo and t.col <= self.col_hi and t.row >= self.row_lo and t.row <= self.row_hi;
    }
};

fn ceilDiv(a: i32, b: i32) i32 {
    return -@divFloor(-a, b);
}

/// The tile a point stands in.
pub fn tileOf(p: Point) tiles.Tile {
    return .{ .col = @divFloor(p.x, tile), .row = @divFloor(p.y, tile) };
}

/// A drag displacement, in 256ths, and when the pointer was there (`@ms`,
/// data only).
pub const Disp = physics.Disp;

pub const Capped = physics.Capped;

/// **MERGED AND CAPPED** (item 2, item 3): past 16, the displacements are
/// first added into the 16th (its `@ms` the last's); then each axis has a
/// 100 px budget for the tick, counted on the input: a displacement that
/// crosses it has that axis cut to what is left, and that axis plays no
/// more this tick.
pub fn mergeAndCap(raw: []const Disp) Capped {
    var out: Capped = .{};
    for (raw, 0..) |d, i| {
        if (i < most_displacements) {
            out.list[i] = d;
            out.len = i + 1;
        } else {
            const last = &out.list[most_displacements - 1];
            last.dx += d.dx;
            last.dy += d.dy;
            last.ms = d.ms;
        }
    }
    var left_x: i32 = cap;
    var left_y: i32 = cap;
    for (out.list[0..out.len]) |*d| {
        d.dx = budgeted(d.dx, &left_x);
        d.dy = budgeted(d.dy, &left_y);
    }
    return out;
}

fn budgeted(v: i32, left: *i32) i32 {
    if (mag(v) <= left.*) {
        left.* -= mag(v);
        return v;
    }
    const cut = sign(v) * left.*;
    left.* = 0;
    return cut;
}

/// Whether a tick's displacements are within the bounds a report's parse
/// holds them to: at most 16, each at most 100 px on each axis, the
/// absolute x parts adding up to at most 100 px, and the y parts.
pub fn withinCap(d: []const Disp) bool {
    if (d.len > most_displacements) return false;
    var sum_x: i64 = 0;
    var sum_y: i64 = 0;
    for (d) |one| {
        if (mag(one.dx) > cap or mag(one.dy) > cap) return false;
        sum_x += mag(one.dx);
        sum_y += mag(one.dy);
    }
    return sum_x <= cap and sum_y <= cap;
}

/// One of the human's inputs at a tick (`view` and `held` are not the
/// physics' business).
pub const Human = physics.Human;

/// Why an input is refused: its precondition fails.
pub const Refusal = physics.Refusal;

/// What a tick's inputs came to, before its `t` line runs.
pub const Begun = physics.Begun;

/// **AN INPUT**, applied in the order written; refused when its
/// precondition fails (the board is then unchanged).
pub fn input(b: *Board, begun: *Begun, h: Human) ?Refusal {
    if (begun.humans >= most_humans) return .too_many_inputs;
    switch (h) {
        .release => |d| {
            const l = b.leashedDog() orelse return .release_not_leashed;
            if (l != d) return .release_not_leashed;
            b.hold = .none;
            begun.letting_go = .no;
        },
        .leash => |d| {
            if (b.hold != .none) return .leash_while_leashed;
            if (d >= dog_count or b.dog_known[d] != .present) return .leash_no_such_dog;
            b.hold = .{ .leashed = .{ .dog = d, .drag = .on } };
            begun.letting_go = .no;
        },
        .grab => switch (b.hold) {
            .none => return .grab_unleashed,
            .leashed => |*l| {
                l.drag = .on;
                begun.letting_go = .no;
            },
        },
        // With no drag on, a no-op, kept as an input.
        .letgo => switch (b.hold) {
            .none => {},
            .leashed => |l| if (l.drag == .on) {
                begun.letting_go = .after_drag;
            },
        },
    }
    begun.humans += 1;
    return null;
}

pub const CritterLine = physics.CritterLine;

/// A tick's checked line.
pub const Checked = physics.Checked;

/// A tick's checked lines, in order: critter lines in rank order, then a
/// `bump`, a timer's `release` or a `rest`.
pub const Lines = physics.Lines;

/// A critter the physics sees this tick: its point stands in a tile
/// meeting the region, and the board has it.
pub const Seen = struct {
    who: Critter,
    rank: u32,
    half: i32,
    awake: Awake,
    /// Where it was at the tick's start.
    start: Point,

    pub const Awake = enum { asleep, awake };
};

/// **THE TICK'S WORLD**: the board, the region, and every critter the
/// physics sees, in rank order. Built once at the tick's start.
pub const Scene = struct {
    board: *Board,
    leashed: u16,
    region: Rect,
    seen: [critter_count]Seen = undefined,
    /// Where each seen critter is now, kept here beside the board's copy so
    /// the tick's inner loops read one array.
    at: [critter_count]Point = undefined,
    len: usize = 0,
    /// The awake ones' places in `seen`, in rank order: what the wishes read.
    awake: [critter_count]u16 = undefined,
    awake_len: usize = 0,

    pub fn of(b: *Board) ?Scene {
        const l = b.leashedDog() orelse return null;
        const center = b.dogs[l];
        var s: Scene = .{ .board = b, .leashed = l, .region = region(center) };
        const span = TileSpan.of(s.region);
        const sphere: i64 = @as(i64, awake_reach) * awake_reach;
        s.add(.dog(l), .awake);
        for (0..cow_count) |i| s.consider(.cow(@intCast(i)), span, center, sphere);
        for (0..dog_count) |i| {
            if (i == l) continue;
            s.consider(.dog(@intCast(i)), span, center, sphere);
        }
        return s;
    }

    fn consider(s: *Scene, c: Critter, span: TileSpan, center: Point, sphere: i64) void {
        if (s.board.known(c) != .present) return;
        const p = s.board.at(c);
        if (!span.holds(tileOf(p))) return;
        s.add(c, if (len2(delta(center, p)) <= sphere) .awake else .asleep);
    }

    fn add(s: *Scene, c: Critter, awake: Seen.Awake) void {
        s.seen[s.len] = .{ .who = c, .rank = rank(s.leashed, c), .half = c.half(), .awake = awake, .start = s.board.at(c) };
        s.at[s.len] = s.board.at(c);
        if (awake == .awake) {
            s.awake[s.awake_len] = @intCast(s.len);
            s.awake_len += 1;
        }
        s.len += 1;
    }

    pub fn awakeOnes(s: *const Scene) []const u16 {
        return s.awake[0..s.awake_len];
    }

    pub fn list(s: *const Scene) []const Seen {
        return s.seen[0..s.len];
    }

    pub fn pos(s: *const Scene, i: usize) Point {
        return s.at[i];
    }

    pub fn put(s: *Scene, i: usize, p: Point) void {
        s.at[i] = p;
        s.board.put(s.seen[i].who, p);
    }
};

/// What blocks a mover's sweep.
const Blocks = enum { everyone, cow_blockers };

/// The result of sweeping a square along an axis.
const Swept = struct { by: i32, blocker: ?usize };

/// How far the square of half `h` at `p` may go along `axis` by `s`
/// (signed) against the square of half `oh` at `o`: contact means pressing
/// in, so touching across the move doesn't block, and against a square it
/// already overlaps a step may not shrink |Δ| on that axis nor change its
/// sign (from Δ = 0 either way is free).
pub fn sweepLimit(p: Point, h: i32, axis: Axis, s: i32, o: Point, oh: i32) i32 {
    const d = delta(p, o);
    const hs = h + oh;
    if (mag(on(d, across(axis))) >= hs or s == 0) return s;
    const along = on(d, axis);
    if (mag(along) >= hs) {
        if (sign(along) != sign(s)) return s;
        const gap = mag(along) - hs;
        return if (mag(s) > gap) sign(s) * gap else s;
    }
    if (along == 0 or sign(along) != sign(s)) return s;
    return 0;
}

/// Sweeps seen critter `i` along `axis` by `s` against the seen critters
/// `which` selects, in rank order; the blocker is the one that stops it
/// shortest, the higher-ranked on a tie.
fn sweep(sc: *const Scene, i: usize, axis: Axis, s: i32, which: Blocks) Swept {
    const p = sc.pos(i);
    const me = sc.seen[i];
    var best = s;
    var blocker: ?usize = null;
    for (sc.list(), 0..) |o, j| {
        if (j == i) continue;
        if (which == .cow_blockers and !blocksCow(me, o)) continue;
        const got = sweepLimit(p, me.half, axis, s, sc.pos(j), o.half);
        if (mag(got) < mag(best)) {
            best = got;
            blocker = j;
        }
    }
    return .{ .by = best, .blocker = blocker };
}

/// A cow's step stops short of the leashed dog, any sleeper and any cow
/// above it; it pushes the rest (awake dogs, awake cows below it).
fn blocksCow(cow: Seen, o: Seen) bool {
    return o.rank == 0 or o.awake == .asleep or (o.who.kind == .cow and o.rank < cow.rank);
}

/// The part of `s` along `axis` that keeps the square of half `h` at `p` in
/// the world (provisional: decision 14).
fn inWorld(p: Point, h: i32, axis: Axis, s: i32) i32 {
    const to = on(p, axis) + s;
    const lo = h;
    const hi = world - h;
    if (to < lo) return @min(0, lo - on(p, axis));
    if (to > hi) return @max(0, hi - on(p, axis));
    return s;
}

/// How far a cow can go along `axis`, to `side`, before its square leaves
/// the world.
fn room(cow: Point, axis: Axis, side: i32) i32 {
    return @max(0, if (side > 0) world - cow_half - on(cow, axis) else on(cow, axis) - cow_half);
}

/// **THE COWS' GRID RULE, IN 256ths** (item 1): the
/// dog, its centre at `dog` after the step, moved `step` (> 0) along `axis`,
/// that way (`way`); how far the cow at `cow` moves across that axis
/// (signed; 0 for not at all).
pub fn scoot(axis: Axis, way: i32, step: i32, dog: Point, cow: Point) i32 {
    const d = delta(dog, cow);
    const ahead = on(d, axis) * way;
    const off = on(d, across(axis));
    if (ahead <= 0 or ahead > scare_box or mag(off) > scare_box) return 0;
    // Away from the dog's line; on it, to the dog's right.
    var side: i32 = if (off != 0) sign(off) else switch (axis) {
        .x => way,
        .y => -way,
    };
    // Half as far as the dog: the step halved, truncated.
    var by: i32 = @divTrunc(step, 2);
    if (mag(off) < lane) {
        var out = lane - mag(off);
        if (room(cow, across(axis), side) < out) {
            const other = lane + mag(off);
            if (room(cow, across(axis), -side) >= other) {
                side = -side;
                out = other;
            }
        }
        const left_to_come = ahead - lane;
        const needed: i32 = if (left_to_come <= 0) out else @intCast(std.math.divCeil(i64, @as(i64, out) * step, left_to_come) catch unreachable);
        by = @max(by, @min(out, needed));
    }
    by = @min(by, room(cow, across(axis), side));
    if (by <= 0) return 0;
    return side * by;
}

/// **ONE TICK**, after its inputs (`input`): the drag (when one is on),
/// then the dogs' wishes, then the timer. Writes the tick's checked lines.
pub fn run(b: *Board, t: Tick, begun: Begun, drag: []const Disp, out: *Lines) void {
    out.len = 0;
    var bumped: ?Critter = null;
    var sc_opt = Scene.of(b);
    if (sc_opt) |*sc| {
        const drag_on = b.hold.leashed.drag == .on;
        if (drag_on) bumped = playDrag(sc, drag);
        if (bumped != null or begun.letting_go == .after_drag) b.hold.leashed.drag = .{ .ended = t };
        wishes(sc, speed);
        for (sc.list()) |s| {
            const now = b.at(s.who);
            if (now.x != s.start.x or now.y != s.start.y) out.push(.{ .critter = .{ .who = s.who, .before = s.start, .after = now } });
        }
    }
    if (bumped) |c| out.push(.{ .bump = c });
    switch (b.hold) {
        .none => {},
        .leashed => |l| switch (l.drag) {
            .on => {},
            .ended => |e| if (t >= e + let_go_ticks) {
                out.push(.{ .release = l.dog });
                b.hold = .none;
            },
        },
    }
    const timer_running = switch (b.hold) {
        .none => false,
        .leashed => |l| l.drag != .on,
    };
    if (out.len == 0 and begun.humans == 0 and drag.len == 0 and !timer_running) out.push(.rest);
}

/// The inputs, then the tick: the whole tick for a caller that needn't
/// point at a refused input.
pub fn tick(b: *Board, t: Tick, humans: []const Human, drag: []const Disp, out: *Lines) ?Refusal {
    var begun: Begun = .{};
    for (humans) |h| if (input(b, &begun, h)) |r| return r;
    run(b, t, begun, drag, out);
    return null;
}

/// The drag's displacements, x then y, each cut into internal steps; the
/// critter the leashed dog bumped, if it did (the rest of the drag is then
/// dropped).
fn playDrag(sc: *Scene, drag: []const Disp) ?Critter {
    for (drag) |d| {
        for ([_]Axis{ .x, .y }) |axis| {
            const part: i64 = if (axis == .x) d.dx else d.dy;
            if (part == 0) continue;
            const n: i64 = std.math.divCeil(i64, @intCast(@abs(part)), step_most) catch unreachable;
            var done: i64 = 0;
            var i: i64 = 1;
            while (i <= n) : (i += 1) {
                const now = @divTrunc(part * i, n);
                const inc: i32 = @intCast(now - done);
                done = now;
                if (dragStep(sc, axis, inc)) |c| return c;
            }
        }
    }
    return null;
}

/// One internal step of the drag: shaped by the world's edge, the cows
/// react to it, then the leashed dog takes it, stopping just short of
/// pressing into anyone.
fn dragStep(sc: *Scene, axis: Axis, raw: i32) ?Critter {
    const dog = sc.pos(0);
    const inc = inWorld(dog, dog_half, axis, raw);
    if (inc == 0) return null;
    const dog_after = moved(dog, axis, inc);
    for (sc.list(), 0..) |s, i| {
        if (s.who.kind != .cow or s.awake != .awake) continue;
        outFromUnder(sc, i);
        cowStep(sc, i, axis, sign(inc), mag(inc), dog_after);
    }
    const r = sweep(sc, 0, axis, inc, .everyone);
    sc.put(0, moved(dog, axis, r.by));
    if (r.by != 0) wishes(sc, mag(r.by));
    if (r.blocker) |j| return sc.seen[j].who;
    return null;
}

/// A cow's grid step and its pushes.
fn cowStep(sc: *Scene, i: usize, axis: Axis, way: i32, step: i32, dog_after: Point) void {
    const start = sc.pos(i);
    const crossing = across(axis);
    const want = scoot(axis, way, step, dog_after, start);
    if (want == 0) return;
    const r = sweep(sc, i, crossing, want, .cow_blockers);
    if (r.by == 0) return;
    const end = moved(start, crossing, r.by);
    sc.put(i, end);
    var pushed: [critter_count]usize = undefined;
    var count: usize = 0;
    for (sc.list(), 0..) |o, j| {
        if (j == i or blocksCow(sc.seen[i], o)) continue;
        if (squaresOverlap(end, cow_half, sc.pos(j), o.half)) {
            pushed[count] = j;
            count += 1;
        }
    }
    if (count == 0) return;
    const swept_area: Rect = .{
        .lo = .{ .x = @min(start.x, end.x) - cow_half, .y = @min(start.y, end.y) - cow_half },
        .hi = .{ .x = @max(start.x, end.x) + cow_half, .y = @max(start.y, end.y) + cow_half },
    };
    var spots: [critter_count]Point = undefined;
    for (pushed[0..count], 0..) |j, k| {
        var obs: jump.Obstacles = .{};
        obs.add(Rect.square(end, cow_half), 2 * sc.seen[i].rank);
        obs.add(swept_area, 2 * sc.seen[i].rank + 1);
        for (pushed[0..k], spots[0..k]) |placed, spot| obs.add(Rect.square(spot, sc.seen[placed].half), 2 * sc.seen[placed].rank);
        for (sc.list(), 0..) |o, m| {
            if (m == i or std.mem.indexOfScalar(usize, pushed[0..count], m) != null) continue;
            obs.add(Rect.square(sc.pos(m), o.half), 2 * o.rank);
        }
        spots[k] = jump.nearestSpot(sc.pos(j), sc.seen[j].half, obs.slice(), sc.region) orelse {
            // Nowhere for one: the cow stops short of the first critter
            // along its sweep, and pushes no one.
            sc.put(i, start);
            const short = sweep(sc, i, crossing, want, .everyone);
            sc.put(i, moved(start, crossing, short.by));
            return;
        };
    }
    for (pushed[0..count], spots[0..count]) |j, spot| sc.put(j, spot);
}

/// **AN OVERLAP THAT SLIPPED THROUGH**: an awake critter overlapping one
/// above it jumps to the nearest spot clear of everyone; with nowhere to go
/// it stays.
fn outFromUnder(sc: *Scene, i: usize) void {
    const me = sc.seen[i];
    if (me.awake != .awake or me.rank == 0) return;
    const p = sc.pos(i);
    var under = false;
    for (sc.list()[0..i], 0..) |o, j| {
        if (squaresOverlap(p, me.half, sc.pos(j), o.half)) {
            under = true;
            break;
        }
    }
    if (!under) return;
    var obs: jump.Obstacles = .{};
    for (sc.list(), 0..) |o, j| {
        if (j == i) continue;
        obs.add(Rect.square(sc.pos(j), o.half), 2 * o.rank);
    }
    if (jump.nearestSpot(p, me.half, obs.slice(), sc.region)) |spot| sc.put(i, spot);
}

/// **THE DOGS' WISHES**, every awake dog by number, each step at most
/// `most`: once a tick at the speed, and once per pixel-tick of the drag at
/// the leashed dog's own step.
fn wishes(sc: *Scene, most: i32) void {
    for (sc.awakeOnes()) |w16| {
        const i: usize = w16;
        const s = sc.seen[i];
        if (s.who.kind != .dog or s.rank == 0) continue;
        outFromUnder(sc, i);
        const step = stepAtMost(wishTotal(sc, i), most);
        const at = sc.pos(i);
        stepSwept(sc, i, .{ .x = inWorld(at, dog_half, .x, step.x), .y = inWorld(at, dog_half, .y, step.y) });
    }
}

/// Which axis a straight step meets a square on: the face it presses into,
/// or both at once (a corner met exactly, or two squares met at the same
/// moment on different faces).
pub const Face = enum {
    x,
    y,
    both,

    fn with(a: Face, b: Face) Face {
        return if (a == b) a else .both;
    }
};

/// When a straight step first presses into a square: at `num` / `den` of
/// the step (0 ≤ num < den), on `face`.
pub const Contact = struct {
    num: i64,
    den: i64,
    face: Face,

    /// Whether `a` comes before `b` (a fraction compared by cross products).
    fn before(a: Contact, b: Contact) bool {
        return a.num * b.den < b.num * a.den;
    }

    fn sameTime(a: Contact, b: Contact) bool {
        return a.num * b.den == b.num * a.den;
    }
};

/// One axis's span of a step's fractions during which the squares overlap
/// on that axis: (enter, exit) over `den`, the open interval; `always` when
/// the step does not move on that axis and they overlap on it, `never`
/// when it does not and they do not.
const Span = union(enum) { always, never, during: struct { enter: i64, exit: i64, den: i64 } };

fn spanOn(d: i32, hs: i32, s: i32) Span {
    if (s == 0) return if (mag(d) < hs) .always else .never;
    const w: i64 = sign(s) * @as(i64, d);
    return .{ .during = .{ .enter = w - hs, .exit = w + hs, .den = mag(s) } };
}

/// **THE STEP AS ONE MOVE** (decision 18): when the square of half `h` at
/// `p`, stepping straight by `s`, first presses into the square of half
/// `oh` at `o`, which it does not overlap at the start; null if it never
/// does within the step (touching doesn't block, nor does reaching
/// contact exactly at the step's end). Exact: the moment is a fraction
/// with the step's own length on one axis as its denominator.
pub fn stepContact(p: Point, h: i32, s: Point, o: Point, oh: i32) ?Contact {
    const d = delta(p, o);
    const hs = h + oh;
    const sx = spanOn(d.x, hs, s.x);
    const sy = spanOn(d.y, hs, s.y);
    if (sx == .never or sy == .never) return null;
    // Both `always` would be an overlap at the start, which the caller
    // has already handled.
    const ax = switch (sx) {
        .during => |v| v,
        else => return contactOn(sy.during, .y),
    };
    const ay = switch (sy) {
        .during => |v| v,
        else => return contactOn(ax, .x),
    };
    // The later entry and the earlier exit, as cross products.
    const enter_cmp = std.math.order(ax.enter * ay.den, ay.enter * ax.den);
    const entry: @TypeOf(ax) = if (enter_cmp == .lt) ay else ax;
    const face: Face = switch (enter_cmp) {
        .lt => .y,
        .gt => .x,
        .eq => .both,
    };
    const exit_x_first = ax.exit * ay.den < ay.exit * ax.den;
    const exit_num = if (exit_x_first) ax.exit else ay.exit;
    const exit_den = if (exit_x_first) ax.den else ay.den;
    if (entry.enter * exit_den >= exit_num * entry.den) return null;
    if (entry.enter >= entry.den or exit_num <= 0) return null;
    return .{ .num = @max(0, entry.enter), .den = entry.den, .face = face };
}

fn contactOn(a: anytype, face: Face) ?Contact {
    if (a.enter >= a.den or a.exit <= 0) return null;
    return .{ .num = @max(0, a.enter), .den = a.den, .face = face };
}

/// A step against a square it already overlaps: each axis that would
/// shrink |Δ| on it is dropped (from Δ = 0 either way is free), as
/// `sweepLimit` has it.
pub fn awayFrom(p: Point, s: Point, o: Point) Point {
    const d = delta(p, o);
    return .{
        .x = if (d.x != 0 and sign(d.x) == sign(s.x)) 0 else s.x,
        .y = if (d.y != 0 and sign(d.y) == sign(s.y)) 0 else s.y,
    };
}

/// The step `s` cut to `c`'s moment, each axis truncated toward zero: on
/// the face's axis that is the gap exactly, and the other axis never
/// reaches past the segment, so the point is clear of every square the
/// segment is clear of.
pub fn cutTo(s: Point, c: Contact) Point {
    return .{
        .x = @intCast(@divTrunc(@as(i64, s.x) * c.num, c.den)),
        .y = @intCast(@divTrunc(@as(i64, s.y) * c.num, c.den)),
    };
}

/// Dog `i`'s step `s` (already kept in the world) as one straight move
/// against everyone, scanning everyone: dropped on each axis that presses
/// deeper into a square it overlaps, taken to its earliest contact, then
/// slid along a single face it met.
fn stepSwept(sc: *Scene, i: usize, want: Point) void {
    const me = sc.seen[i];
    const p = sc.pos(i);
    var s = want;
    for (sc.list(), 0..) |o, j| {
        if (j == i) continue;
        if (squaresOverlap(p, me.half, sc.pos(j), o.half)) s = awayFrom(p, s, sc.pos(j));
    }
    if (s.x == 0 and s.y == 0) return;
    var first: ?Contact = null;
    for (sc.list(), 0..) |o, j| {
        if (j == i) continue;
        if (squaresOverlap(p, me.half, sc.pos(j), o.half)) continue;
        const c = stepContact(p, me.half, s, sc.pos(j), o.half) orelse continue;
        const f = first orelse {
            first = c;
            continue;
        };
        if (c.num * f.den < f.num * c.den) {
            first = c;
        } else if (c.num * f.den == f.num * c.den) {
            first = .{ .num = f.num, .den = f.den, .face = if (f.face == c.face) f.face else .both };
        }
    }
    const c = first orelse return sc.put(i, .{ .x = p.x + s.x, .y = p.y + s.y });
    const cut = cutTo(s, c);
    const at: Point = .{ .x = p.x + cut.x, .y = p.y + cut.y };
    sc.put(i, at);
    const slide: Axis = switch (c.face) {
        .x => .y,
        .y => .x,
        .both => return,
    };
    const rest = on(s, slide) - on(cut, slide);
    if (rest == 0) return;
    const r = sweep(sc, i, slide, rest, .everyone);
    sc.put(i, moved(at, slide, r.by));
}

/// The step dog `i` wants: its wishes summed, the dead zone, the speed.
pub fn wishStep(sc: *const Scene, i: usize) Point {
    return stepOf(wishTotal(sc, i));
}

/// The step a total of wishes comes to: none inside the dead zone; the
/// total itself within the speed; else scaled to the speed.
pub fn stepOf(total: Point) Point {
    return stepAtMost(total, speed);
}

/// The step a total of wishes comes to, at most `most` long.
pub fn stepAtMost(total: Point, most: i32) Point {
    const t2 = len2(total);
    if (t2 < @as(i64, dead_zone) * dead_zone) return .{ .x = 0, .y = 0 };
    if (t2 <= @as(i64, most) * most) return total;
    const l = isqrt(t2);
    return .{
        .x = @intCast(@divTrunc(@as(i64, total.x) * most, l)),
        .y = @intCast(@divTrunc(@as(i64, total.y) * most, l)),
    };
}

/// The sum of dog `i`'s wishes: room from other breeds above it, its place
/// against its anchor, room from the cows. Only awake critters count.
pub fn wishTotal(sc: *const Scene, i: usize) Point {
    const me = sc.seen[i];
    const p = sc.pos(i);
    const breed = me.who.n % breeds;
    var total: Point = .{ .x = 0, .y = 0 };
    var anchor: ?usize = null;
    var anchor_d2: i64 = 0;
    for (sc.awakeOnes()) |j16| {
        const j: usize = j16;
        const o = sc.seen[j];
        if (j == i) continue;
        const q = sc.pos(j);
        const d2 = len2(delta(q, p));
        switch (o.who.kind) {
            .cow => if (d2 <= @as(i64, cow_room) * cow_room) {
                add(&total, away(q, p, cow_room - @as(i32, @intCast(isqrt(d2)))));
            },
            .dog => {
                if (o.rank >= me.rank) continue;
                if (o.who.n % breeds != breed) {
                    if (d2 <= @as(i64, wary) * wary) add(&total, away(q, p, wary - @as(i32, @intCast(isqrt(d2)))));
                } else if (d2 <= @as(i64, follow) * follow and (anchor == null or d2 < anchor_d2)) {
                    anchor = j;
                    anchor_d2 = d2;
                }
            },
        }
    }
    if (anchor) |j| {
        const q = sc.pos(j);
        if (anchor_d2 > @as(i64, band_outer) * band_outer) {
            add(&total, wishAlong(delta(p, q), @as(i32, @intCast(isqrt(anchor_d2))) - band_outer));
        } else if (anchor_d2 < @as(i64, band_inner) * band_inner) {
            add(&total, away(q, p, band_inner - @as(i32, @intCast(isqrt(anchor_d2)))));
        }
    }
    return total;
}

fn add(total: *Point, w: Point) void {
    total.x += w.x;
    total.y += w.y;
}

/// A wish `length` long, straight away from `from`, for the critter at
/// `p`; when the centres coincide, east.
fn away(from: Point, p: Point, length: i32) Point {
    const v = delta(from, p);
    if (v.x == 0 and v.y == 0) return .{ .x = length, .y = 0 };
    return wishAlong(v, length);
}

/// A wish `length` long along `v`: each axis of `v` times the length,
/// divided by `v`'s length (`isqrt`), truncated toward zero.
pub fn wishAlong(v: Point, length: i32) Point {
    const l = isqrt(len2(v));
    return .{
        .x = @intCast(@divTrunc(@as(i64, v.x) * length, l)),
        .y = @intCast(@divTrunc(@as(i64, v.y) * length, l)),
    };
}

/// Every overlapping pair among the critters the physics sees: the
/// invariant the server checks after every tick (a finding, not a
/// refutation).
pub fn overlaps(b: *Board, found: []([2]Critter)) usize {
    const sc = Scene.of(b) orelse return 0;
    var n: usize = 0;
    for (sc.list(), 0..) |a, i| {
        for (sc.list()[i + 1 ..], i + 1..) |c, j| {
            if (squaresOverlap(sc.pos(i), a.half, sc.pos(j), c.half)) {
                if (n < found.len) found[n] = .{ a.who, c.who };
                n += 1;
            }
        }
    }
    return n;
}
