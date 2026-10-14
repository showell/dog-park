//! **THE PHYSICS** (docs/PHYSICS.md): the critters' board and one tick of
//! it, the shared Zig that the page (as wasm) and the server (natively)
//! both run, so they agree to the bit.
//!
//! A tick is a pure function: the board before, plus what the human did
//! during it (`Human` inputs, then the drag's displacements), gives the
//! board after and the tick's checked lines (`Lines`). No randomness, no
//! clock, no allocator: fixed buffers only, so it compiles to
//! wasm32-freestanding.
//!
//! **Units:** every position is an `i32` count of 256ths of a pixel, in
//! [0, `world`); every product is `i64`.
//!
//! **The torus** (decision 14): a critter leaving one edge enters the
//! opposite one. Every centre-to-centre difference goes through `delta`,
//! which takes the short way round; every move wraps its result back into
//! the world (`wrapped`: `moved`, `Scene.put`). A rectangle is compared
//! only with others in one frame: the copy of each point nearest the
//! tick's anchor, the leashed dog where the tick began (`nearestCopy`,
//! `Scene.frame`), which the world's comptime width check keeps
//! unambiguous.
//!
//! **The cascade:** the leashed dog, then the cows by number, then the
//! other dogs by number (`rank`). Within a tick: for each internal step of
//! the drag, the cows react (their grid rule, `scoot`), then the
//! leashed dog takes the step; then every awake dog takes its wish step.
//! The nearest spot clear of everyone (a push's or an overlap's jump) is
//! physics_jump.zig.

const std = @import("std");
const tiles = @import("tiles.zig");
const layout = @import("layout.zig");
const jump = @import("physics_jump.zig");

pub const dog_count = layout.dog_count;
pub const cow_count = layout.cow_count;
pub const critter_count = dog_count + cow_count;

/// 256ths in a pixel.
pub const unit: i32 = 256;

pub fn px(n: i32) i32 {
    return n * unit;
}

/// **THE CLOCK**: ticks in a second. The page's tick is 1000 /
/// `ticks_per_second` ms (engine.js reads it from the wasm).
pub const ticks_per_second = 16;

/// A rate of `units_per_second` 256ths a second, as 256ths a tick; a rate
/// that doesn't divide into whole 256ths a tick doesn't compile.
pub fn perTick(comptime units_per_second: i32) i32 {
    if (@rem(units_per_second, ticks_per_second) != 0)
        @compileError(std.fmt.comptimePrint("{d} 256ths a second is not a whole number of 256ths a tick", .{units_per_second}));
    return @divExact(units_per_second, ticks_per_second);
}

/// `n` seconds, in ticks.
pub fn seconds(comptime n: comptime_int) comptime_int {
    return n * ticks_per_second;
}

/// The world's side, in 256ths.
pub const world: i32 = px(tiles.world_px);
/// A tile's side, in 256ths.
pub const tile: i32 = px(tiles.tile_px);

// **THE KNOBS** (docs/PHYSICS.md), in Steve's units, all tuned by playing.
// Each tuned knob is `tuned(played, alt)`: `played` is Steve's; `alt`
// (zig build -Dknobs=alt, in the slow tier) moves it by about half, so a
// test that pins a value rather than a property fails there.

pub const Knobs = @TypeOf(@import("physics_options").knobs);
pub const knobs: Knobs = @import("physics_options").knobs;

/// **THE METRIC** (metal-vmm QUEUE 205(b), `zig build -Dmetric`): how far
/// apart two critters are, for every rule that reaches (awake, `wary`,
/// `follow`, the herd band, `cow_room`, a step's `speed` and its
/// `dead_zone`):
/// - `euclid`, the straight line (the played one);
/// - `chebyshev`, the larger axis: a reach is a square, as the critters
///   are, and a step at the speed may go that far on both axes at once;
/// - `manhattan`, the axes added: a reach is a diamond.
/// A wish keeps its direction under all three; only its length is the
/// metric's. Unchanged by it: the overlap test (squares'), the drag's
/// budget (per axis), and a jump's nearest clear spot, by straight line
/// (physics_jump.zig), so a jump has the same few ties under every metric.
pub const Metric = @TypeOf(@import("physics_options").metric);
pub const metric: Metric = @import("physics_options").metric;

fn tuned(comptime played: anytype, comptime alt: @TypeOf(played)) @TypeOf(played) {
    return switch (knobs) {
        .played => played,
        .alt => alt,
    };
}

/// The squares, in whole pixels, as the page draws them (park.js's dog_px
/// and cow_px). Each critter is its square, centred on its point.
pub const dog_px = 40;
pub const cow_px = 60;
pub const dog_half: i32 = px(dog_px / 2);
pub const cow_half: i32 = px(cow_px / 2);
/// A dog's own step: 7.5 px a second.
pub const speed: i32 = perTick(tuned(px(15) / 2, px(45) / 4));
pub const dead_zone: i32 = tuned(px(1), px(1) / 2);
pub const awake_reach: i32 = tuned(px(800), px(1200));
pub const wary: i32 = tuned(px(225), px(675) / 2);
pub const follow: i32 = tuned(px(600), px(900));
pub const band_inner: i32 = tuned(px(60), px(30));
pub const band_outer: i32 = tuned(px(100), px(150));
pub const cow_room: i32 = tuned(px(90), px(135));
/// The region: the 3000 px square around the leashed dog.
pub const region_reach: i32 = px(1500);
/// A drag's internal steps, the PIXEL-TICKS: at most 1 px. After each, every
/// awake dog takes a step as long as the leashed dog's, at most (Steve,
/// 2026-10-13: the leashed dog's motion speeds up time for the others).
pub const step_most: i32 = tuned(px(1), px(3) / 2);
/// A tick's drag moves the leashed dog at most 100 px on each axis.
pub const cap: i32 = tuned(px(100), px(50));
pub const most_displacements = 16;
/// The most of the human's inputs at one tick.
pub const most_humans = 16;
/// The leash comes off 20 s after the drag ends.
pub const let_go_ticks = tuned(seconds(20), seconds(10));
/// The most ticks a report runs past the last kept one.
pub const most_ticks = 32;
/// How far a dog's move along an axis reaches: a cow at most this far ahead
/// on that axis, and at most this far off it, is scared (`scoot`).
pub const scare_box: i32 = tuned(px(280), px(420));
/// The least gap a cow keeps between the dog's square and its own: half a
/// dog.
pub const clearance: i32 = tuned(px(dog_px / 2), px(dog_px / 4));
/// A cow's lane: a dog's half, a cow's half and the clearance.
pub const lane: i32 = dog_half + cow_half + clearance;
/// A jump's candidates come from squares within this gap, on both axes.
pub const jump_reach: i32 = tuned(px(100), px(150));
/// Breeds: dog n has look n mod 4.
pub const breeds = 4;

/// **THE REGION'S SIZE, DERIVED** (docs/PHYSICS.md): the longest reach a
/// tick has from the leashed dog's point, per axis, from the knobs above. A
/// tuning past `region_reach` doesn't compile.
pub const region_needs: i32 = blk: {
    // A walking dog: awake within the sphere, its wish steps over the tick
    // (at most the leashed dog's Manhattan move under the cap, plus one at
    // the speed), its square, and a critter its square could press into.
    const walk = awake_reach + 2 * cap + speed + dog_half + cow_half;
    // A scared cow's point at the end of its step: past the scare box by
    // half a step, or out to the lane, from a dog within the cap.
    const scared = @max(scare_box + @divFloor(step_most, 2), lane) + cap;
    // A cow's push: what it lands on lies under it, that critter's jump past
    // a cow within the reach, its landing square, and what could overlap it.
    const push = scared + 2 * cow_half + (jump_reach + 2 * px(cow_px)) + 2 * cow_half;
    // A dog pushed so, then walking the rest of the drag.
    const pushed_walk = scared + dog_half + cow_half + (jump_reach + px(dog_px) + px(cow_px)) + 2 * cap + speed + dog_half + cow_half;
    break :blk @max(@max(walk, push), pushed_walk);
};
comptime {
    // A cow's room reaches past touching, or cows press before they part.
    if (cow_room <= dog_half + cow_half) @compileError("cow_room must exceed a dog's half and a cow's half");
    if (region_needs > region_reach)
        @compileError(std.fmt.comptimePrint("the region ({d}/256 px each way) is short of the {d}/256 px the knobs' reaches need", .{ region_reach, region_needs }));
    // **THE WORLD IS WIDER THAN THE REGION PLUS ITS REACHES** (decision 14):
    // the region's tiles (its side, and a tile more each way where it ends
    // inside one) and what a tick reaches past them, each way, short of the
    // world, so the region's span never wraps onto itself and no critter
    // is ever seen twice.
    if (2 * region_reach + 2 * tile + 2 * region_needs >= world)
        @compileError("the world must be wider than the region plus its reaches (decision 14)");
}

pub const Tick = u64;

pub const Point = extern struct { x: i32, y: i32 };

/// **THE ONE DIFFERENCE**: from `a` to `b`, per axis, the short way round
/// the torus: each axis in [−world/2, world/2) (decision 14). Every
/// centre-to-centre difference in the physics goes through here.
pub inline fn delta(a: Point, b: Point) Point {
    return .{ .x = shortWay(b.x - a.x), .y = shortWay(b.y - a.y) };
}

pub const half_world: i32 = @divExact(world, 2);

/// A difference on one axis, the short way round: in [−world/2, world/2).
/// Two points in the world are less than a world apart, so one add or
/// subtract of the world brings it round; only a difference past that
/// (none the physics makes) takes the division. The same as
/// `@mod(d + half_world, world) - half_world` for every `d`. Most
/// differences are already short, and one unsigned compare says so.
pub fn shortWay(d: i32) i32 {
    if (@as(u32, @bitCast(d +% half_world)) < world) return d;
    if (d >= half_world) {
        if (d < world + half_world) return d - world;
    } else if (d >= -half_world) {
        return d;
    } else if (d >= -half_world - world) return d + world;
    return @mod(d + half_world, world) - half_world;
}

/// A point back in the world, [0, `world`) on each axis: where a move that
/// crossed the seam lands.
pub fn wrapped(p: Point) Point {
    return .{ .x = @mod(p.x, world), .y = @mod(p.y, world) };
}

/// The copy of `p` nearest `anchor`: `anchor` plus the short way to `p`. In
/// one tick every rectangle is built from such copies around one anchor,
/// so the region, the swept area and the jump compare like with like
/// across the seam.
pub fn nearestCopy(anchor: Point, p: Point) Point {
    const d = delta(anchor, p);
    return .{ .x = anchor.x + d.x, .y = anchor.y + d.y };
}

pub const Axis = enum { x, y };

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

/// `p` moved `by` along `axis`, wrapped into the world.
pub fn moved(p: Point, axis: Axis, by: i32) Point {
    return wrapped(switch (axis) {
        .x => .{ .x = p.x + by, .y = p.y },
        .y => .{ .x = p.x, .y = p.y + by },
    });
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

/// The integer square root, rounded down: a float's guess, then corrected
/// in integers until r² ≤ v < (r + 1)², so the float only makes it fast.
///
/// **BELOW 2⁵² THE GUESS IS EXACT** (202), and the correction is skipped:
/// `v` converts exactly and the root is rounded correctly, so the guess is
/// at least r (r is a double, and rounding keeps order). And √v ≤
/// √((r + 1)² − 1), more than 1 / (2(r + 1)) short of r + 1, while near r +
/// 1 ≤ 2²⁶ half a double's spacing is at most 2⁻²⁸ below a power of two
/// and 2⁻²⁷ elsewhere: the root never rounds up to r + 1.
pub inline fn isqrt(v: i64) i64 {
    std.debug.assert(v >= 0);
    const u: u64 = @intCast(v);
    var r: u64 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(u))));
    if (u < 1 << 52) return @intCast(r);
    while (r * r > u) r -= 1;
    while ((r + 1) * (r + 1) <= u) r += 1;
    return @intCast(r);
}

/// A vector's length under `metric`, as a key that orders as the length
/// does: under `euclid` its square (no root is needed to compare), under
/// the others the length itself. Every reach is compared in keys:
/// `measure(v) <= measureOf(reach)`.
pub inline fn measure(v: Point) i64 {
    const x: i64 = v.x;
    const y: i64 = v.y;
    return switch (metric) {
        .euclid => x * x + y * y,
        .chebyshev => @max(@as(i64, @intCast(@abs(x))), @as(i64, @intCast(@abs(y)))),
        .manhattan => @as(i64, @intCast(@abs(x))) + @as(i64, @intCast(@abs(y))),
    };
}

/// The key `measure` gives a vector `r` long, `r` ≥ 0.
pub inline fn measureOf(r: i64) i64 {
    return if (metric == .euclid) r * r else r;
}

/// The length a `measure` key stands for, rounded down: under `euclid`
/// `isqrt`, the one root the physics takes; under the others the key.
/// A vector's every axis is at most it, under all three (`quotientAlong`).
pub inline fn lengthOf(k: i64) i64 {
    return if (metric == .euclid) isqrt(k) else k;
}

/// How many times `Scene.drift` (the most any critter moved on an axis)
/// bounds how much nearer two critters can have come under `metric`: each
/// moved at most √2 × drift by straight line (and 2√2 < 3), drift on its
/// larger axis, 2 × drift on both added.
pub const drift_nearer: i32 = switch (metric) {
    .euclid => 3,
    .chebyshev => 2,
    .manhattan => 4,
};

/// **A WISH'S AXIS: `@divTrunc(c × length, l)`, FOR |c| ≤ l** (202), where
/// `l` > 0 is the `lengthOf` length of the vector `c` is an axis of, so
/// |c| ≤ `l` (under `euclid` c² ≤ the squared length, and |c| is whole;
/// under the others an axis is at most their length), and `length` >
/// minInt(i32). Truncated toward zero, it is the magnitudes' quotient with
/// the product's sign, at most |`length`| < 2³¹: so it is worked in
/// unsigned magnitudes, and the narrowings ReleaseSafe would check cannot
/// fail. The magnitudes are nearly always below 2³² (`wary` × `wary` is),
/// where an unsigned 32-bit division is cheaper than a 64-bit one
/// natively. Not on wasm, where V8's 64-bit division measured as fast as
/// the branches around a 32-bit one: there it is `@divTrunc` itself.
pub inline fn quotientAlong(c: i32, length: i32, l: i64) i32 {
    if (comptime @import("builtin").cpu.arch.isWasm()) return @intCast(@divTrunc(@as(i64, c) * length, l));
    const m: u64 = @as(u64, @abs(c)) * @abs(length);
    const d: u64 = @bitCast(l);
    const q: u64 = if (m >> 32 == 0 and d >> 32 == 0) @as(u32, @truncate(m)) / @as(u32, @truncate(d)) else m / d;
    const r: i32 = @bitCast(@as(u32, @truncate(q)));
    return if ((c < 0) != (length < 0)) -%r else r;
}

pub const Kind = enum(u8) { dog, cow };

/// A critter, by kind and number.
pub const Critter = struct {
    kind: Kind,
    n: u16,

    pub fn dog(n: u16) Critter {
        return .{ .kind = .dog, .n = n };
    }
    pub fn cow(n: u16) Critter {
        return .{ .kind = .cow, .n = n };
    }
    pub fn half(self: Critter) i32 {
        return switch (self.kind) {
            .dog => dog_half,
            .cow => cow_half,
        };
    }
    pub fn eql(a: Critter, b: Critter) bool {
        return a.kind == b.kind and a.n == b.n;
    }
};

/// Whether the board has a critter: the page has only those it received;
/// the server has every one.
pub const Known = enum(u8) { absent, present };

/// A leashed dog's drag: on (the pointer is down), or ended at a tick (the
/// let-go timer runs from it).
pub const Drag = union(enum) { on, ended: Tick };

pub const Leashed = struct { dog: u16, drag: Drag };

/// Who is leashed, if anyone, and the drag.
pub const Hold = union(enum) { none, leashed: Leashed };

pub const Board = struct {
    dogs: [dog_count]Point,
    cows: [cow_count]Point,
    dog_known: [dog_count]Known,
    cow_known: [cow_count]Known,
    hold: Hold = .none,

    /// No critters at all.
    pub fn empty() Board {
        return .{
            .dogs = @splat(.{ .x = 0, .y = 0 }),
            .cows = @splat(.{ .x = 0, .y = 0 }),
            .dog_known = @splat(.absent),
            .cow_known = @splat(.absent),
        };
    }

    /// The first layout (layout.zig), every critter present.
    pub fn laidOut() Board {
        return layout.board();
    }

    pub fn at(self: *const Board, c: Critter) Point {
        return switch (c.kind) {
            .dog => self.dogs[c.n],
            .cow => self.cows[c.n],
        };
    }

    pub fn put(self: *Board, c: Critter, p: Point) void {
        switch (c.kind) {
            .dog => self.dogs[c.n] = p,
            .cow => self.cows[c.n] = p,
        }
    }

    pub fn known(self: *const Board, c: Critter) Known {
        return switch (c.kind) {
            .dog => self.dog_known[c.n],
            .cow => self.cow_known[c.n],
        };
    }

    /// Places a critter and marks it present.
    pub fn place(self: *Board, c: Critter, p: Point) void {
        self.put(c, p);
        switch (c.kind) {
            .dog => self.dog_known[c.n] = .present,
            .cow => self.cow_known[c.n] = .present,
        }
    }

    pub fn leashedDog(self: *const Board) ?u16 {
        return switch (self.hold) {
            .none => null,
            .leashed => |l| l.dog,
        };
    }
};

/// **RANK**: the cascade's order. The leashed dog is 0, cow n is 1 + n, dog
/// n is 1 + cows + n. Lower is more alpha.
pub fn rank(leashed: ?u16, c: Critter) u32 {
    if (c.kind == .dog and leashed != null and leashed.? == c.n) return 0;
    return switch (c.kind) {
        .cow => 1 + @as(u32, c.n),
        .dog => 1 + cow_count + @as(u32, c.n),
    };
}

/// A closed rectangle, in 256ths, in some frame (`nearestCopy`): its
/// corners may lie past the world's edges, and it is compared only with
/// rectangles of the same frame.
pub const Rect = struct {
    lo: Point,
    hi: Point,

    pub fn square(p: Point, half: i32) Rect {
        return .{ .lo = .{ .x = p.x - half, .y = p.y - half }, .hi = .{ .x = p.x + half, .y = p.y + half } };
    }
    /// Whether `inner` lies wholly in this rectangle (touching is inside).
    pub fn holds(self: Rect, inner: Rect) bool {
        return inner.lo.x >= self.lo.x and inner.hi.x <= self.hi.x and inner.lo.y >= self.lo.y and inner.hi.y <= self.hi.y;
    }
    /// Whether two rectangles share some interior (touching is not).
    pub fn overlaps(a: Rect, b: Rect) bool {
        return a.lo.x < b.hi.x and b.lo.x < a.hi.x and a.lo.y < b.hi.y and b.lo.y < a.hi.y;
    }
};

/// Two squares overlap: |px − qx| < (a + b)/2 and |py − qy| < (a + b)/2.
pub fn squaresOverlap(p: Point, ph: i32, q: Point, qh: i32) bool {
    const d = delta(p, q);
    return mag(d.x) < ph + qh and mag(d.y) < ph + qh;
}

/// The region: the square `region_reach` each way around the leashed dog
/// at the tick's start (docs/PHYSICS.md derives its size), in that dog's
/// frame.
pub fn region(center: Point) Rect {
    return Rect.square(center, region_reach);
}

/// The tiles a rectangle meets, half-open: sharing some of a tile's
/// interior. On the torus (decision 14): `col_lo` and `row_lo` are named in
/// the world, [0, `world_tiles`), and `col_hi` and `row_hi` count on past
/// its last tile across the seam (64 is tile 0), so `lo..hi` always counts
/// up; `at` names a tile of the range in the world. A span is never wider
/// than the world (the region's comptime check).
pub const TileSpan = struct {
    col_lo: i32,
    col_hi: i32,
    row_lo: i32,
    row_hi: i32,

    pub fn of(r: Rect) TileSpan {
        const col = @divFloor(r.lo.x, tile);
        const row = @divFloor(r.lo.y, tile);
        const col_lo = @mod(col, tiles.world_tiles);
        const row_lo = @mod(row, tiles.world_tiles);
        return .{
            .col_lo = col_lo,
            .col_hi = col_lo + (ceilDiv(r.hi.x, tile) - 1 - col),
            .row_lo = row_lo,
            .row_hi = row_lo + (ceilDiv(r.hi.y, tile) - 1 - row),
        };
    }
    /// Whether `t` (named in the world) lies in the wrapped range.
    pub fn holds(self: TileSpan, t: tiles.Tile) bool {
        return @mod(t.col - self.col_lo, tiles.world_tiles) <= self.col_hi - self.col_lo and
            @mod(t.row - self.row_lo, tiles.world_tiles) <= self.row_hi - self.row_lo;
    }
    /// `holds(tileOf(p))`, from the point (202): a tile divides the world,
    /// so the point's offset from the span's first tile, round the world,
    /// is its tile's offset in tiles times `tile` plus its place in the
    /// tile, and the tile's offset is at most `hi - lo` exactly when the
    /// point's is less than `hi - lo + 1` tiles.
    pub fn holdsPoint(self: TileSpan, p: Point) bool {
        return holdsOn(p.x, self.col_lo, self.col_hi) and holdsOn(p.y, self.row_lo, self.row_hi);
    }
    fn holdsOn(v: i32, lo: i32, hi: i32) bool {
        const off = @mod(@as(i64, v) - @as(i64, lo) * tile, world);
        return off < (@as(i64, hi) - lo + 1) * tile;
    }
    /// The tile at `col`, `row` of the range, named in the world.
    pub fn at(col: i32, row: i32) tiles.Tile {
        return (tiles.Tile{ .col = col, .row = row }).wrapped();
    }
};

fn ceilDiv(a: i32, b: i32) i32 {
    return -@divFloor(-a, b);
}

/// The tile a point stands in, named in the world: the point wrapped first.
pub fn tileOf(p: Point) tiles.Tile {
    return .{ .col = @divFloor(@mod(p.x, world), tile), .row = @divFloor(@mod(p.y, world), tile) };
}

/// A drag displacement, in 256ths, and when the pointer was there (`@ms`,
/// data only).
pub const Disp = struct { dx: i32, dy: i32, ms: u32 = 0 };

pub const Capped = struct {
    list: [most_displacements]Disp = undefined,
    len: usize = 0,

    pub fn slice(self: *const Capped) []const Disp {
        return self.list[0..self.len];
    }
};

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
pub const Human = union(enum) {
    release: u16,
    leash: u16,
    grab,
    letgo,
};

/// Why an input is refused: its precondition fails.
pub const Refusal = enum {
    too_many_inputs,
    leash_while_leashed,
    leash_no_such_dog,
    release_not_leashed,
    grab_unleashed,
};

/// What a tick's inputs came to, before its `t` line runs.
pub const Begun = struct {
    humans: u8 = 0,
    /// A `letgo` with the drag on: it ends after the tick's drag plays.
    letting_go: LettingGo = .no,

    pub const LettingGo = enum { no, after_drag };
};

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

pub const CritterLine = struct { who: Critter, before: Point, after: Point };

/// A tick's checked line.
pub const Checked = union(enum) {
    critter: CritterLine,
    bump: Critter,
    release: u16,
    rest,
};

/// A tick's checked lines, in order: critter lines in rank order, then a
/// `bump`, a timer's `release` or a `rest`.
pub const Lines = struct {
    list: [critter_count + 2]Checked = undefined,
    len: usize = 0,
    /// The critters that JUMPED this tick (out from under, or a push's
    /// nearest spot), by `critterIndex`: the page snaps these and glides
    /// the rest.
    jumped: Jumped = .initEmpty(),
    /// The tick's pair checks: every test of one critter against another.
    /// A deterministic cost, so a test can bound it.
    pair_checks: u64 = 0,

    pub fn push(self: *Lines, c: Checked) void {
        self.list[self.len] = c;
        self.len += 1;
    }
    pub fn slice(self: *const Lines) []const Checked {
        return self.list[0..self.len];
    }
};

pub const Jumped = std.StaticBitSet(critter_count);

/// A critter's place in a `Jumped`: dog n is n, cow n is dogs + n.
pub fn critterIndex(c: Critter) usize {
    return switch (c.kind) {
        .dog => c.n,
        .cow => dog_count + @as(usize, c.n),
    };
}

/// The largest half-square.
pub const half_most: i32 = @max(dog_half, cow_half);
/// **THE NEIGHBOUR LISTS' SKIN**: a seen critter's neighbours are the seen
/// critters within 2 × `half_most` + `skin` (on either axis) when the lists
/// were built. A pair left out is skipped only while 2 × `drift` + the
/// step ≤ `skin` (`Scene.near`), so a skipped pair can't touch the sweep.
/// A cost knob only: it changes no result.
pub const skin: i32 = px(48);
/// The most the neighbour lists hold, all critters together; a build that
/// would hold more leaves every scan full.
pub const neighbours_most = 16384;
/// The most the room lists hold (`Scene.rooms`), all dogs together; a build
/// that would hold more leaves every dog reading the wishes' grid.
pub const rooms_most = 24576;

/// **A GRID ACROSS THE SEAM** (decision 14): the side of a grid's square
/// cell that is at least `need`, divides the world exactly, and leaves a
/// number of cells a side that `fold` divides, the smallest such. Then a
/// cell's index mod `fold` is the same on both sides of the seam: the
/// world's last cell and its first are neighbours in the fold too.
fn seamCell(comptime need: i32, comptime fold: i32) i32 {
    comptime {
        if (need <= 0) @compileError("a grid's cell must be at least 1/256 px");
        var n: i32 = @divFloor(@divFloor(world, need), fold) * fold;
        while (n > 0) : (n -= fold) {
            if (@mod(world, n) == 0) return @divExact(world, n);
        }
        @compileError(std.fmt.comptimePrint("no cell of at least {d}/256 px divides the world ({d}/256 px) into a multiple of {d} cells a side", .{ need, world, fold }));
    }
}

/// The cell holding coordinate `v`, unfolded: floor division, so a
/// coordinate below 0 or past the world (a difference taken the short way
/// round, decision 14) lands in the cell next to the seam's other side
/// once folded.
fn cellOf(v: i32, comptime cell: i32) i32 {
    return @divFloor(v, cell);
}

/// The neighbour lists' grid: a critter's neighbours are within `nb_reach`
/// on either axis, so in its cell's 3 × 3 when a cell is at least that;
/// the cells folded onto a square `grid_side` a side (folding only adds
/// candidates, each still measured).
const nb_reach: i32 = 2 * half_most + skin;
const grid_side = 32;
pub const nb_cell: i32 = seamCell(nb_reach, grid_side);
comptime {
    if (nb_cell < nb_reach) @compileError("the neighbour grid's cell is short of the neighbours' reach");
    if (@mod(world, nb_cell) != 0) @compileError("the neighbour grid's cell must divide the world, or the seam splits a cell");
    if (@mod(@divExact(world, nb_cell), grid_side) != 0) @compileError("the neighbour grid's fold must divide its cells a side, or neighbours across the seam fold apart");
    // A 3 × 3 window never folds onto itself.
    if (grid_side < 3) @compileError("the neighbour grid's fold must be at least 3");
}

/// The folded cell `(dx, dy)` cells from the one `p` stands in.
fn gridCell(p: Point, dx: i32, dy: i32) u16 {
    const cx = @mod(cellOf(p.x, nb_cell) + dx, grid_side);
    const cy = @mod(cellOf(p.y, nb_cell) + dy, grid_side);
    return @intCast(cy * grid_side + cx);
}

/// Each seen critter in an `nb_cell` square, the cells folded onto a
/// `grid_side` square, each cell's in rank order: a critter within
/// `nb_reach` of another on both axes is in its cell's 3 × 3.
///
/// Kept in the scene (`Scene.cells`) and built there (202): built in a
/// frame of its own, a safe build filled it with 0xaa first, every build.
const Cells = struct {
    from: [grid_side * grid_side + 1]u16,
    by_cell: [critter_count]u16,
    /// Each critter's cell, the build's own.
    cell_of: [critter_count]u16,

    fn build(c: *Cells, s: *const Scene) void {
        var cell_len: [grid_side * grid_side]u16 = @splat(0);
        for (0..s.len) |i| {
            const k = gridCell(s.pos(i), 0, 0);
            c.cell_of[i] = k;
            cell_len[k] += 1;
        }
        c.from[0] = 0;
        for (cell_len, 0..) |l, k| c.from[k + 1] = c.from[k] + l;
        var fill: [grid_side * grid_side]u16 = c.from[0 .. grid_side * grid_side].*;
        for (0..s.len) |i| {
            c.by_cell[fill[c.cell_of[i]]] = @intCast(i);
            fill[c.cell_of[i]] += 1;
        }
    }

    fn in(c: *const Cells, k: u16) []const u16 {
        return c.by_cell[c.from[k]..c.from[k + 1]];
    }
};

/// **THE WISHES' GRID**: every awake critter in a `wish_cell` square, by
/// class (a dog's breed, or a cow), the cells folded onto a square
/// `wish_grid` a side; kept current by `Scene.put`. A wish's sum reads only
/// the cells its reach meets (`wishTotal`). A cost knob only: it changes no
/// result. The cell follows `wary`, the reach most sums read, so they read
/// 3 × 3 cells at most.
const wish_grid = 16;
pub const wish_cell: i32 = seamCell(wary, wish_grid);
const wish_classes = breeds + 1;
const wish_none: u16 = std.math.maxInt(u16);
/// The anchor's search goes ring by ring to `wish_rings` cells out, where a
/// ring's nearest point is past `follow`.
const wish_rings: i32 = @divFloor(follow, wish_cell) + 1;
comptime {
    if (wish_cell < wary) @compileError("the wishes' grid's cell is short of `wary`");
    if (@mod(world, wish_cell) != 0) @compileError("the wishes' grid's cell must divide the world, or the seam splits a cell");
    if (@mod(@divExact(world, wish_cell), wish_grid) != 0) @compileError("the wishes' grid's fold must divide its cells a side, or neighbours across the seam fold apart");
    // A window of cells, the widest the wishes read, never folds onto
    // itself: no bucket is read twice. A reach r spans at most
    // 2 * ceil(r / wish_cell) + 1 cells a side; the anchor's rings, at most
    // 2 * wish_rings + 1.
    std.debug.assert(2 * wish_rings + 1 <= wish_grid);
    std.debug.assert(wary <= follow and cow_room <= follow);
}

fn wishClass(c: Critter) u16 {
    return switch (c.kind) {
        .dog => c.n % breeds,
        .cow => breeds,
    };
}

/// The grid's cell for a point, by axis, unfolded.
fn wishCellOf(v: i32) i32 {
    return cellOf(v, wish_cell);
}

/// The bucket for class `class` and unfolded cell (`cx`, `cy`).
fn wishBucket(class: u16, cx: i32, cy: i32) usize {
    const fx: usize = @intCast(@mod(cx, wish_grid));
    const fy: usize = @intCast(@mod(cy, wish_grid));
    return (@as(usize, class) * wish_grid + fy) * wish_grid + fx;
}

/// Whether a seen critter may overlap another: `clear` promises it
/// overlaps no one.
pub const Overlap = enum(u8) { clear, maybe };

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
    /// The tick's anchor: the leashed dog where the tick began. The region
    /// and every rectangle of the tick are in its frame (`frame`).
    center: Point,
    region: Rect,
    seen: [critter_count]Seen = undefined,
    /// Where each seen critter is now, kept here beside the board's copy so
    /// the tick's inner loops read one array.
    at: [critter_count]Point = undefined,
    len: usize = 0,
    /// Whether every one of `at` is in the world, [0, `world`) on each
    /// axis: a board's are when they came from the wire or a move (`put`
    /// wraps), but a board can be placed anywhere. The room lists' vectors
    /// need it (`addRoomsListed`).
    in_world: bool = true,
    /// The awake ones' places in `seen`, in rank order: what the wishes read.
    awake: [critter_count]u16 = undefined,
    awake_len: usize = 0,
    /// Each seen critter's `Overlap`: maybe for all until the first build
    /// (`refresh`) measures them.
    overlap: [critter_count]Overlap = undefined,
    /// The neighbour lists (`skin`): seen critter i's are
    /// `nb[nb_from[i]..nb_from[i + 1]]`, in rank order; built at `nb_at`.
    lists: Lists = .none,
    nb_from: [critter_count + 1]u16 = undefined,
    nb: [neighbours_most]u16 = undefined,
    nb_at: [critter_count]Point = undefined,
    /// The most any seen critter has moved, on either axis, since the lists
    /// were built.
    drift: i32 = 0,
    jumped: Jumped = .initEmpty(),
    pair_checks: u64 = 0,
    /// The wishes' grid (`wish_cell`): each bucket's first awake critter,
    /// each one's next and previous in its bucket, and its bucket.
    wg_head: [wish_classes * wish_grid * wish_grid]u16 = @splat(wish_none),
    wg_next: [critter_count]u16 = undefined,
    wg_prev: [critter_count]u16 = undefined,
    wg_bucket: [critter_count]u16 = undefined,
    /// **THE ROOM LISTS** (202): for each awake unleashed dog when the wishes
    /// read the grid, the awake cows and other breeds' dogs above it within
    /// its reach of them (`cow_room`, `wary`) plus `skin`, as they stood when
    /// the neighbour lists were built (`refresh`): `rl[rl_lo[i]..rl_hi[i]]`,
    /// the strangers before `rl_mid[i]` and the cows from it.
    /// A cost knob only: one left out was past the reach plus `skin`, and
    /// while `drift_nearer` × `drift` < `skin` (by straight line, each of
    /// two critters moved at most √2 × `drift`) it is still past the reach
    /// (`roomsServe`).
    rooms: Lists = .none,
    rl_lo: [critter_count]u16 = undefined,
    rl_mid: [critter_count]u16 = undefined,
    rl_hi: [critter_count]u16 = undefined,
    rl: [rooms_most]u16 = undefined,
    /// The neighbours' grid, as the last build left it (`Cells`).
    cells: Cells = undefined,

    pub const Lists = enum { none, built };

    pub fn of(b: *Board) ?Scene {
        var s: Scene = undefined;
        if (!s.init(b)) return null;
        return s;
    }

    /// `of`, built where it stands (202): a scene is big (its lists), and
    /// one returned by value is copied whole, every tick. Each field with
    /// a default is set here by name: a struct literal stored whole is
    /// written whole, the big `undefined` arrays too. A test holds every
    /// such field to the literal's.
    pub fn init(s: *Scene, b: *Board) bool {
        const l = b.leashedDog() orelse return false;
        const center = b.dogs[l];
        s.board = b;
        s.leashed = l;
        s.center = center;
        s.region = region(center);
        s.len = 0;
        s.in_world = true;
        s.awake_len = 0;
        s.lists = .none;
        s.drift = 0;
        s.jumped = .initEmpty();
        s.pair_checks = 0;
        s.wg_head = @splat(wish_none);
        s.rooms = .none;
        const span = TileSpan.of(s.region);
        const sphere: i64 = measureOf(awake_reach);
        s.add(.dog(l), .awake);
        for (0..cow_count) |i| s.consider(.cow(@intCast(i)), span, center, sphere);
        for (0..dog_count) |i| {
            if (i == l) continue;
            s.consider(.dog(@intCast(i)), span, center, sphere);
        }
        // Linked from the last up, each at its bucket's head: every bucket
        // in rank order, as `wgLink` keeps it.
        var k = s.awake_len;
        while (k > 0) {
            k -= 1;
            const i = s.awake[k];
            s.wgLinkHead(i, s.wgBucketAt(i, s.at[i]));
        }
        return true;
    }

    fn consider(s: *Scene, c: Critter, span: TileSpan, center: Point, sphere: i64) void {
        if (s.board.known(c) != .present) return;
        const p = s.board.at(c);
        if (!span.holdsPoint(p)) return;
        s.add(c, if (measure(delta(center, p)) <= sphere) .awake else .asleep);
    }

    fn add(s: *Scene, c: Critter, awake: Seen.Awake) void {
        s.seen[s.len] = .{ .who = c, .rank = rank(s.leashed, c), .half = c.half(), .awake = awake, .start = s.board.at(c) };
        s.at[s.len] = s.board.at(c);
        s.in_world = s.in_world and inWorld(s.at[s.len]);
        s.overlap[s.len] = .maybe;
        if (awake == .awake) {
            s.awake[s.awake_len] = @intCast(s.len);
            s.awake_len += 1;
        }
        s.len += 1;
    }

    fn wgBucketAt(s: *const Scene, i: usize, p: Point) u16 {
        return @intCast(wishBucket(wishClass(s.seen[i].who), wishCellOf(p.x), wishCellOf(p.y)));
    }

    /// `i` into bucket `k` at its head: only where every one there ranks
    /// below it (the scene's build, last first).
    fn wgLinkHead(s: *Scene, i: usize, k: u16) void {
        const h = s.wg_head[k];
        s.wg_next[i] = h;
        s.wg_prev[i] = wish_none;
        if (h != wish_none) s.wg_prev[h] = @intCast(i);
        s.wg_head[k] = @intCast(i);
        s.wg_bucket[i] = k;
    }

    /// **EACH BUCKET IN RANK ORDER** (202): `i` into bucket `k` after every
    /// one ranked above it, so a wish's read stops at the first critter not
    /// above the dog (`addRoom`, `anchorOf`). A move into another bucket is
    /// rare (a cell is `wish_cell` wide), so the walk to its place is cheap.
    fn wgLink(s: *Scene, i: usize, k: u16) void {
        var prev: u16 = wish_none;
        var at = s.wg_head[k];
        while (at != wish_none and at < i) : (at = s.wg_next[at]) prev = at;
        s.wg_next[i] = at;
        s.wg_prev[i] = prev;
        if (at != wish_none) s.wg_prev[at] = @intCast(i);
        if (prev == wish_none) s.wg_head[k] = @intCast(i) else s.wg_next[prev] = @intCast(i);
        s.wg_bucket[i] = k;
    }

    fn wgUnlink(s: *Scene, i: usize) void {
        const n = s.wg_next[i];
        const pv = s.wg_prev[i];
        if (pv == wish_none) s.wg_head[s.wg_bucket[i]] = n else s.wg_next[pv] = n;
        if (n != wish_none) s.wg_prev[n] = pv;
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

    /// Seen critter `i` to `p`, wrapped into the world.
    pub fn put(s: *Scene, i: usize, to: Point) void {
        const p = wrapped(to);
        s.at[i] = p;
        s.board.put(s.seen[i].who, p);
        if (s.seen[i].awake == .awake) {
            const k = s.wgBucketAt(i, p);
            if (k != s.wg_bucket[i]) {
                s.wgUnlink(i);
                s.wgLink(i, k);
            }
        }
        if (s.lists == .built) {
            const d = delta(s.nb_at[i], p);
            s.drift = @max(s.drift, @max(mag(d.x), mag(d.y)));
        }
    }

    /// `p` in the tick's frame: its copy nearest the anchor.
    pub fn frame(s: *const Scene, p: Point) Point {
        return nearestCopy(s.center, p);
    }

    /// A jump: seen critter `i` to `p`, flagged as jumped; it and everyone
    /// it overlaps there may overlap.
    pub fn jumpTo(s: *Scene, i: usize, to: Point) void {
        s.put(i, to);
        const p = s.pos(i);
        s.jumped.set(critterIndex(s.seen[i].who));
        s.overlap[i] = .maybe;
        for (s.list(), 0..) |o, j| {
            if (j == i) continue;
            s.pair_checks += 1;
            if (squaresOverlap(p, s.seen[i].half, s.pos(j), o.half)) s.overlap[j] = .maybe;
        }
    }

    /// Rebuilds the neighbour lists unless they still serve a step of
    /// `most`; a build measures every critter's `Overlap` afresh.
    pub fn refresh(s: *Scene, most: i32) void {
        if (s.lists == .built and 2 * s.drift + most <= skin and (s.rooms != .built or 3 * s.drift < skin)) return;
        const reach = nb_reach;
        var n: usize = 0;
        for (0..s.len) |i| s.overlap[i] = .clear;
        s.cells.build(s);
        const cells = &s.cells;
        var cand: [critter_count]u16 = undefined;
        for (0..s.len) |i| {
            s.nb_from[i] = @intCast(n);
            const p = s.pos(i);
            var cand_len: usize = 0;
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    for (cells.in(gridCell(p, dx, dy))) |j| {
                        if (j == i) continue;
                        s.pair_checks += 1;
                        const d = delta(p, s.pos(j));
                        if (mag(d.x) >= reach or mag(d.y) >= reach) continue;
                        cand[cand_len] = j;
                        cand_len += 1;
                    }
                }
            }
            // Those within reach, in rank order (only they are sorted).
            std.sort.insertion(u16, cand[0..cand_len], {}, std.sort.asc(u16));
            for (cand[0..cand_len]) |j16| {
                const j: usize = j16;
                if (n == neighbours_most) {
                    s.lists = .none;
                    for (0..s.len) |k| s.overlap[k] = .maybe;
                    return;
                }
                s.nb[n] = @intCast(j);
                n += 1;
                if (squaresOverlap(p, s.seen[i].half, s.pos(j), s.seen[j].half)) s.overlap[i] = .maybe;
            }
        }
        s.nb_from[s.len] = @intCast(n);
        @memcpy(s.nb_at[0..s.len], s.at[0..s.len]);
        s.drift = 0;
        s.lists = .built;
        s.buildRooms();
    }

    /// The room lists (`rooms`), from the wishes' grid, for the dogs that
    /// read it: among more than `wish_scan_most` awake critters.
    fn buildRooms(s: *Scene) void {
        s.rooms = .none;
        if (s.awake_len <= wish_scan_most) return;
        var n: usize = 0;
        for (s.awakeOnes()) |w16| {
            const i: usize = w16;
            const me = s.seen[i];
            s.rl_lo[i] = @intCast(n);
            s.rl_mid[i] = @intCast(n);
            s.rl_hi[i] = @intCast(n);
            if (me.who.kind != .dog or me.rank == 0) continue;
            const breed = me.who.n % breeds;
            const p = s.pos(i);
            // The other breeds, then the cows (class `breeds`), last.
            for (0..breeds + 1) |class| {
                if (class == breed) continue;
                if (class == breeds) s.rl_mid[i] = @intCast(n);
                const reach: i32 = (if (class == breeds) cow_room else wary) + skin;
                const reach2 = measureOf(reach);
                var cy = wishCellOf(p.y - reach);
                while (cy <= wishCellOf(p.y + reach)) : (cy += 1) {
                    var cx = wishCellOf(p.x - reach);
                    while (cx <= wishCellOf(p.x + reach)) : (cx += 1) {
                        var j = s.wg_head[wishBucket(@intCast(class), cx, cy)];
                        while (j != wish_none and j < i) : (j = s.wg_next[j]) {
                            if (measure(delta(s.pos(j), p)) > reach2) continue;
                            if (n == rooms_most) return;
                            s.rl[n] = j;
                            n += 1;
                        }
                    }
                }
            }
            s.rl_hi[i] = @intCast(n);
        }
        s.rooms = .built;
    }

    /// Whether dog `i`'s room list holds every critter whose room it must
    /// keep now.
    fn roomsServe(s: *const Scene) bool {
        return s.rooms == .built and s.lists == .built and drift_nearer * s.drift < skin;
    }

    /// Seen critter `i`'s neighbours when they hold everyone a step of `s`
    /// (0: an overlap test) can meet; else null, for a full scan.
    pub fn near(s: *const Scene, i: usize, step: i32) ?[]const u16 {
        if (s.lists != .built or 2 * s.drift + mag(step) > skin) return null;
        return s.nb[s.nb_from[i]..s.nb_from[i + 1]];
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
///
/// Against a neighbour list (`Scene.near`) it scans only the neighbours, in
/// the same order: one left out is at least 2 × `half_most` + `skin` − 2 ×
/// `drift` ≥ the two halves + |s| away on some axis, where `sweepLimit`
/// gives `s` back, which never beats the best.
fn sweep(sc: *Scene, i: usize, axis: Axis, s: i32, which: Blocks) Swept {
    var acc: SweepAcc = .{ .best = s };
    if (sc.near(i, s)) |list| {
        for (list) |j| acc.against(sc, i, j, axis, s, which);
    } else {
        for (0..sc.len) |j| if (j != i) acc.against(sc, i, j, axis, s, which);
    }
    return .{ .by = acc.best, .blocker = acc.blocker };
}

const SweepAcc = struct {
    best: i32,
    blocker: ?usize = null,

    fn against(acc: *SweepAcc, sc: *Scene, i: usize, j: usize, axis: Axis, s: i32, which: Blocks) void {
        const me = sc.seen[i];
        const o = sc.seen[j];
        if (which == .cow_blockers and !blocksCow(me, o)) return;
        sc.pair_checks += 1;
        const got = sweepLimit(sc.pos(i), me.half, axis, s, sc.pos(j), o.half);
        if (mag(got) < mag(acc.best)) {
            acc.best = got;
            acc.blocker = j;
        }
    }
};

/// A cow's step stops short of the leashed dog, any sleeper and any cow
/// above it; it pushes the rest (awake dogs, awake cows below it).
fn blocksCow(cow: Seen, o: Seen) bool {
    return o.rank == 0 or o.awake == .asleep or (o.who.kind == .cow and o.rank < cow.rank);
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
    const side: i32 = if (off != 0) sign(off) else switch (axis) {
        .x => way,
        .y => -way,
    };
    // Half as far as the dog: the step halved, truncated. On the torus
    // there is no edge to run out of room at (decision 14).
    var by: i32 = @divTrunc(step, 2);
    if (mag(off) < lane) {
        const out = lane - mag(off);
        const left_to_come = ahead - lane;
        const needed: i32 = if (left_to_come <= 0) out else @intCast(std.math.divCeil(i64, @as(i64, out) * step, left_to_come) catch unreachable);
        by = @max(by, @min(out, needed));
    }
    if (by <= 0) return 0;
    return side * by;
}

/// **ONE TICK**, after its inputs (`input`): the drag (when one is on),
/// then the dogs' wishes, then the timer. Writes the tick's checked lines.
pub fn run(b: *Board, t: Tick, begun: Begun, drag: []const Disp, out: *Lines) void {
    out.len = 0;
    var bumped: ?Critter = null;
    out.jumped = .initEmpty();
    out.pair_checks = 0;
    {
        // **NO FILL FOR THE SCENE** (202): a safe build writes 0xaa over
        // memory declared `undefined`, and a scene is about 110 KB, every
        // tick; `init` sets every field a scene reads before it reads it.
        // Only the fill is off: the tick itself runs at the build's safety.
        @setRuntimeSafety(false);
        var scene: Scene = undefined;
        {
            @setRuntimeSafety(std.debug.runtime_safety);
            if (scene.init(b)) {
                const sc = &scene;
                defer {
                    out.jumped = sc.jumped;
                    out.pair_checks = sc.pair_checks;
                }
                const drag_on = b.hold.leashed.drag == .on;
                if (drag_on) bumped = playDrag(sc, drag);
                if (bumped != null or begun.letting_go == .after_drag) b.hold.leashed.drag = .{ .ended = t };
                wishes(sc, speed);
                for (sc.list()) |s| {
                    const now = b.at(s.who);
                    if (now.x != s.start.x or now.y != s.start.y) out.push(.{ .critter = .{ .who = s.who, .before = s.start, .after = now } });
                }
            }
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

/// One internal step of the drag: the cows react to it, then the leashed
/// dog takes it, stopping just short of pressing into anyone.
fn dragStep(sc: *Scene, axis: Axis, inc: i32) ?Critter {
    const dog = sc.pos(0);
    if (inc == 0) return null;
    const dog_after = moved(dog, axis, inc);
    sc.refresh(step_most);
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
    // The rectangles below are in the tick's frame.
    const start_f = sc.frame(start);
    const end_f = sc.frame(end);
    var pushed: [critter_count]usize = undefined;
    var count: usize = 0;
    for (sc.list(), 0..) |o, j| {
        if (j == i or blocksCow(sc.seen[i], o)) continue;
        sc.pair_checks += 1;
        if (squaresOverlap(end, cow_half, sc.pos(j), o.half)) {
            pushed[count] = j;
            count += 1;
        }
    }
    if (count == 0) return;
    const swept_area: Rect = .{
        .lo = .{ .x = @min(start_f.x, end_f.x) - cow_half, .y = @min(start_f.y, end_f.y) - cow_half },
        .hi = .{ .x = @max(start_f.x, end_f.x) + cow_half, .y = @max(start_f.y, end_f.y) + cow_half },
    };
    // Each spot in the tick's frame, wrapped only as it is taken.
    var spots: [critter_count]Point = undefined;
    for (pushed[0..count], 0..) |j, k| {
        var obs: jump.Obstacles = .{};
        obs.add(Rect.square(end_f, cow_half), 2 * sc.seen[i].rank);
        obs.add(swept_area, 2 * sc.seen[i].rank + 1);
        for (pushed[0..k], spots[0..k]) |placed, spot| obs.add(Rect.square(spot, sc.seen[placed].half), 2 * sc.seen[placed].rank);
        for (sc.list(), 0..) |o, m| {
            if (m == i or std.mem.indexOfScalar(usize, pushed[0..count], m) != null) continue;
            obs.add(Rect.square(sc.frame(sc.pos(m)), o.half), 2 * o.rank);
        }
        spots[k] = jump.nearestSpot(sc.frame(sc.pos(j)), sc.seen[j].half, obs.slice(), sc.region) orelse {
            // Nowhere for one: the cow stops short of the first critter
            // along its sweep, and pushes no one.
            sc.put(i, start);
            const short = sweep(sc, i, crossing, want, .everyone);
            sc.put(i, moved(start, crossing, short.by));
            return;
        };
    }
    for (pushed[0..count], spots[0..count]) |j, spot| sc.jumpTo(j, spot);
}

/// **AN OVERLAP THAT SLIPPED THROUGH**: an awake critter overlapping one
/// above it jumps to the nearest spot clear of everyone; with nowhere to go
/// it stays.
///
/// Only an overlap can make it jump, and a critter whose `Overlap` is clear
/// overlaps no one: a sweep never presses into anyone, so a new overlap
/// comes only from a jump, and `jumpTo` marks it. A critter found clear is
/// marked so.
fn outFromUnder(sc: *Scene, i: usize) void {
    const me = sc.seen[i];
    if (me.awake != .awake or me.rank == 0) return;
    if (sc.overlap[i] == .clear) return;
    const p = sc.pos(i);
    var under = false;
    var any = false;
    if (sc.near(i, 0)) |list| {
        for (list) |j| {
            sc.pair_checks += 1;
            if (squaresOverlap(p, me.half, sc.pos(j), sc.seen[j].half)) {
                any = true;
                if (j < i) under = true;
            }
        }
    } else {
        for (sc.list(), 0..) |o, j| {
            if (j == i) continue;
            sc.pair_checks += 1;
            if (squaresOverlap(p, me.half, sc.pos(j), o.half)) {
                any = true;
                if (j < i) under = true;
            }
        }
    }
    if (!any) sc.overlap[i] = .clear;
    if (under) jumpOut(sc, i);
}

/// Dog `i`, under someone above it, to the nearest spot clear of everyone.
/// Its own function (202): the obstacles are a big array, and in
/// `outFromUnder` every call paid for its stack, though few ever jump.
noinline fn jumpOut(sc: *Scene, i: usize) void {
    var obs: jump.Obstacles = .{};
    for (sc.list(), 0..) |o, j| {
        if (j == i) continue;
        obs.add(Rect.square(sc.frame(sc.pos(j)), o.half), 2 * o.rank);
    }
    if (jump.nearestSpot(sc.frame(sc.pos(i)), sc.seen[i].half, obs.slice(), sc.region)) |spot| sc.jumpTo(i, spot);
}

/// **THE DOGS' WISHES**, every awake dog by number, each step at most
/// `most`: once a tick at the speed, and once per pixel-tick of the drag at
/// the leashed dog's own step.
fn wishes(sc: *Scene, most: i32) void {
    sc.refresh(most);
    for (sc.awakeOnes()) |w16| {
        const i: usize = w16;
        const s = sc.seen[i];
        if (s.who.kind != .dog or s.rank == 0) continue;
        outFromUnder(sc, i);
        stepSwept(sc, i, stepAtMost(wishTotal(sc, i), most));
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

/// Dog `i`'s step `s` as one straight move
/// against everyone: first dropped on each axis that presses deeper into a
/// square it overlaps (`awayFrom`); then taken to its earliest contact
/// (`stepContact`, `cutTo`); then, if that contact was on one face, the
/// rest of the other axis slides along it (`sweep`). Nothing here prefers x
/// to y: the transpose maps the move to itself.
///
/// Against a neighbour list it scans only the neighbours: one left out is
/// at least the two halves + the step's longer axis away on some axis, so
/// the step never meets it. A critter marked `clear` overlaps no one, so
/// its overlap scan is skipped.
fn stepSwept(sc: *Scene, i: usize, want: Point) void {
    const p = sc.pos(i);
    const reach = @max(mag(want.x), mag(want.y));
    const near_list = sc.near(i, reach);
    var s = want;
    const may_overlap = sc.overlap[i] == .maybe;
    if (may_overlap) {
        if (near_list) |list| {
            for (list) |j| s = stepAway(sc, i, j, s);
        } else {
            for (0..sc.len) |j| if (j != i) {
                s = stepAway(sc, i, j, s);
            };
        }
    }
    if (s.x == 0 and s.y == 0) return;
    var first: ?Contact = null;
    // Each scanned critter a pair check, counted here for the scan.
    sc.pair_checks += if (near_list) |list| list.len else sc.len - 1;
    if (near_list) |list| {
        first = stepMeetsListed(sc, i, s, may_overlap, list);
    } else {
        for (0..sc.len) |j| if (j != i) {
            if (stepMeets(sc, i, j, s, may_overlap)) |c| first = earliest(first, c);
        };
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

fn stepAway(sc: *Scene, i: usize, j: usize, s: Point) Point {
    if (!squaresOverlap(sc.pos(i), sc.seen[i].half, sc.pos(j), sc.seen[j].half)) return s;
    return awayFrom(sc.pos(i), s, sc.pos(j));
}

/// Seen critter `j` against `i`'s step `s`; one beyond the two halves plus
/// the step's part on some axis is never met, and is passed over before
/// the fractions.
pub inline fn stepMeets(sc: *const Scene, i: usize, j: usize, s: Point, may_overlap: bool) ?Contact {
    const p = sc.pos(i);
    const q = sc.pos(j);
    const hs = sc.seen[i].half + sc.seen[j].half;
    const d = delta(p, q);
    if (mag(d.x) >= hs + mag(s.x) or mag(d.y) >= hs + mag(s.y)) return null;
    if (may_overlap and squaresOverlap(p, sc.seen[i].half, q, sc.seen[j].half)) return null;
    return stepContact(p, sc.seen[i].half, s, q, sc.seen[j].half);
}

/// **THE STEP'S SCAN OF ITS NEIGHBOURS** (202): `stepMeets` over `list`,
/// in order, the earliest contact. Where every point is in the world, the
/// first test, the one nearly every neighbour fails (beyond the two halves
/// plus the step's part on some axis), runs `room_lanes` neighbours at a
/// time in i32 vectors (the short way by one select each side, as
/// `addRoomsListed`); a neighbour that passes it takes `stepMeets` itself,
/// in the list's order.
pub fn stepMeetsListed(sc: *const Scene, i: usize, s: Point, may_overlap: bool, list: []const u16) ?Contact {
    var first: ?Contact = null;
    var rest = list;
    const p = sc.pos(i);
    // A short list is cheaper one by one: gathering a chunk costs about
    // what its tests save.
    if (room_lanes > 1 and list.len >= 2 * room_lanes and sc.in_world and inWorld(p)) {
        const N = room_lanes;
        const VI = @Vector(N, i32);
        const at_x: VI = @splat(p.x);
        const at_y: VI = @splat(p.y);
        const w: VI = @splat(world);
        const hw: VI = @splat(half_world);
        const reach_x: VI = @splat(sc.seen[i].half + mag(s.x));
        const reach_y: VI = @splat(sc.seen[i].half + mag(s.y));
        while (rest.len >= N) : (rest = rest[N..]) {
            var qx: [N]i32 = undefined;
            var qy: [N]i32 = undefined;
            var qh: [N]i32 = undefined;
            inline for (0..N) |k| {
                const q = sc.pos(rest[k]);
                qx[k] = q.x;
                qy[k] = q.y;
                qh[k] = sc.seen[rest[k]].half;
            }
            var dx: VI = @as(VI, qx) - at_x;
            var dy: VI = @as(VI, qy) - at_y;
            dx = @select(i32, dx >= hw, dx - w, @select(i32, dx < -hw, dx + w, dx));
            dy = @select(i32, dy >= hw, dy - w, @select(i32, dy < -hw, dy + w, dy));
            const h: VI = qh;
            const close = @select(bool, @abs(dx) < @as(@Vector(N, u32), @bitCast(reach_x + h)), @abs(dy) < @as(@Vector(N, u32), @bitCast(reach_y + h)), @as(@Vector(N, bool), @splat(false)));
            if (!@reduce(.Or, close)) continue;
            inline for (0..N) |k| if (close[k]) {
                if (stepMeets(sc, i, rest[k], s, may_overlap)) |c| first = earliest(first, c);
            };
        }
    }
    for (rest) |j| if (stepMeets(sc, i, j, s, may_overlap)) |c| {
        first = earliest(first, c);
    };
    return first;
}

/// The earlier of the earliest so far (if any) and `y`; at the same moment,
/// their faces together.
fn earliest(a: ?Contact, y: Contact) Contact {
    const x = a orelse return y;
    if (Contact.before(y, x)) return y;
    if (Contact.before(x, y)) return x;
    return .{ .num = x.num, .den = x.den, .face = x.face.with(y.face) };
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
    const t2 = measure(total);
    if (t2 < measureOf(dead_zone)) return .{ .x = 0, .y = 0 };
    if (t2 <= measureOf(most)) return total;
    const l = lengthOf(t2);
    return .{
        .x = @intCast(@divTrunc(@as(i64, total.x) * most, l)),
        .y = @intCast(@divTrunc(@as(i64, total.y) * most, l)),
    };
}

/// The sum of dog `i`'s wishes: room from other breeds above it, its place
/// against its anchor, room from the cows. Only awake critters count.
///
/// Among more than `wish_scan_most` awake critters, an awake unleashed dog
/// reads the wishes' grid (`wishTotalGridded`); anyone else, or anyone
/// among fewer, is summed over every awake critter (`wishTotalScanned`).
/// The two give the same wishes; the sum is of integers, so its order is
/// free.
pub fn wishTotal(sc: *const Scene, i: usize) Point {
    const me = sc.seen[i];
    if (sc.awake_len <= wish_scan_most or me.who.kind != .dog or me.rank == 0 or me.awake != .awake) return wishTotalScanned(sc, i);
    return wishTotalGridded(sc, i);
}

/// The most awake critters whose wishes are cheaper scanned than read from
/// the grid. A cost knob only.
pub const wish_scan_most = 64;

/// `wishTotal` from the wishes' grid, for an awake unleashed dog: the
/// strangers and cows in the cells within `wary` and `cow_room`, and its
/// anchor ring by ring outward (`anchorOf`).
pub fn wishTotalGridded(sc: *const Scene, i: usize) Point {
    const me = sc.seen[i];
    std.debug.assert(me.who.kind == .dog and me.rank != 0 and me.awake == .awake);
    const p = sc.pos(i);
    const breed = me.who.n % breeds;
    var total: Point = .{ .x = 0, .y = 0 };
    if (sc.roomsServe()) {
        // Its room list: the strangers within `wary`, the cows within
        // `cow_room`, measured now.
        addRoomsListed(sc, &total, p, sc.rl[sc.rl_lo[i]..sc.rl_mid[i]], wary);
        addRoomsListed(sc, &total, p, sc.rl[sc.rl_mid[i]..sc.rl_hi[i]], cow_room);
    } else {
        // Strangers: other breeds above it, within `wary`.
        for (0..breeds) |b| {
            if (b == breed) continue;
            addRoom(sc, &total, i, p, @intCast(b), wary);
        }
        // Every awake cow is above it, within `cow_room`.
        addRoom(sc, &total, i, p, breeds, cow_room);
    }
    if (anchorOf(sc, i, p, breed)) |a| addAnchor(&total, p, sc.pos(a.j), a.d2);
    return total;
}

/// Adds, for each awake critter of class `class` above dog `i` (at `p`)
/// within `reach`, a push away as long as the shortfall.
fn addRoom(sc: *const Scene, total: *Point, i: usize, p: Point, class: u16, reach: i32) void {
    const reach2 = measureOf(reach);
    var cy = wishCellOf(p.y - reach);
    while (cy <= wishCellOf(p.y + reach)) : (cy += 1) {
        var cx = wishCellOf(p.x - reach);
        while (cx <= wishCellOf(p.x + reach)) : (cx += 1) {
            // In rank order: past the first not above dog `i`, none count.
            var j = sc.wg_head[wishBucket(class, cx, cy)];
            while (j != wish_none and j < i) : (j = sc.wg_next[j]) {
                const v = delta(sc.pos(j), p);
                const d2 = measure(v);
                if (d2 > reach2) continue;
                const l = lengthOf(d2);
                add(total, awayRooted(v, l, reach - @as(i32, @intCast(l))));
            }
        }
    }
}

fn inWorld(p: Point) bool {
    return p.x >= 0 and p.x < world and p.y >= 0 and p.y < world;
}

/// The lanes `addRoomsListed` works in: f64 vectors of the target's width
/// (`std.simd.suggestVectorLength`), or none (the scalar loop alone) where
/// the target has no vectors, as wasm32 without simd128.
const room_lanes: comptime_int = std.simd.suggestVectorLength(f64) orelse 1;

/// Adds, for each critter of `list` within `reach` of `p`, a push away as
/// long as the shortfall.
///
/// **IN f64 VECTORS, EXACTLY** (202), `room_lanes` critters at a time,
/// when every point is in the world (`Scene.in_world`), else one by one
/// in integers. The vectors give the same pushes, term for term:
/// - two points in the world are less than a world apart on each axis, so
///   the short way is one add or subtract of the world, in i32;
/// - the axes (|v| ≤ `half_world` < 2²³) convert to f64 exactly, and their
///   squares and sum (< 2⁴⁷) are exact;
/// - below 2⁵² a double's square root, truncated, is `isqrt` (as there);
///   under the other metrics the length is the axes' larger or sum, in
///   i32 (each axis < 2²³), exactly `lengthOf`;
/// - the shortfall `reach` − l and each axis times it (< 2⁴⁶) are exact;
/// - a quotient of integers below 2⁵³, rounded once, truncates to the
///   integer one: if whole it is exact, and otherwise the true quotient is
///   at least 1/l from an integer while the rounding moves it at most its
///   size × 2⁻⁵³ < 1/l;
/// - coincident centres push east, as `awayRooted`.
/// The sum is of integers, so its order is free.
fn addRoomsListed(sc: *const Scene, total: *Point, p: Point, list: []const u16, reach: i32) void {
    var rest = list;
    if (room_lanes > 1 and sc.in_world and inWorld(p)) {
        const N = room_lanes;
        const VI = @Vector(N, i32);
        const VF = @Vector(N, f64);
        const at_x: VI = @splat(p.x);
        const at_y: VI = @splat(p.y);
        const w: VI = @splat(world);
        const hw: VI = @splat(half_world);
        const zero: VI = @splat(0);
        const reach_v: VI = @splat(reach);
        const reach2: VF = @splat(@as(f64, @floatFromInt(@as(i64, reach) * reach)));
        var sum_x: VI = zero;
        var sum_y: VI = zero;
        while (rest.len >= N) : (rest = rest[N..]) {
            var qx: [N]i32 = undefined;
            var qy: [N]i32 = undefined;
            inline for (0..N) |k| {
                const q = sc.pos(rest[k]);
                qx[k] = q.x;
                qy[k] = q.y;
            }
            var vx: VI = at_x - @as(VI, qx);
            var vy: VI = at_y - @as(VI, qy);
            vx = @select(i32, vx >= hw, vx - w, @select(i32, vx < -hw, vx + w, vx));
            vy = @select(i32, vy >= hw, vy - w, @select(i32, vy < -hw, vy + w, vy));
            const fx: VF = @floatFromInt(vx);
            const fy: VF = @floatFromInt(vy);
            const ux: VI = @bitCast(@abs(vx));
            const uy: VI = @bitCast(@abs(vy));
            const d2 = fx * fx + fy * fy;
            const l: VI = switch (metric) {
                .euclid => @intFromFloat(@sqrt(d2)),
                .chebyshev => @max(ux, uy),
                .manhattan => ux + uy,
            };
            const near = if (metric == .euclid) d2 <= reach2 else l <= reach_v;
            const short: VF = @floatFromInt(reach_v - l);
            const lf: VF = @floatFromInt(@max(l, @as(VI, @splat(1))));
            const ax: VI = @intFromFloat(fx * short / lf);
            const ay: VI = @intFromFloat(fy * short / lf);
            const same_spot = l == zero;
            const wx = @select(i32, same_spot, reach_v, ax);
            const wy = @select(i32, same_spot, zero, ay);
            sum_x += @select(i32, near, wx, zero);
            sum_y += @select(i32, near, wy, zero);
        }
        add(total, .{ .x = @reduce(.Add, sum_x), .y = @reduce(.Add, sum_y) });
    }
    const reach2 = measureOf(reach);
    for (rest) |j| {
        const v = delta(sc.pos(j), p);
        const d2 = measure(v);
        if (d2 > reach2) continue;
        const l = lengthOf(d2);
        add(total, awayRooted(v, l, reach - @as(i32, @intCast(l))));
    }
}

const Anchor = struct { j: usize, d2: i64 };

/// **THE ANCHOR, BY RINGS**: the nearest awake dog of `breed` above dog `i`
/// (at `p`) within `follow`; on a tie, the higher-ranked (`seen` is in rank
/// order, so the lower index). Ring k is the cells k cells out from `p`'s
/// on either axis; a point there is more than (k - 1) cells' width from
/// `p` on some axis. The search stops before a ring whose least distance
/// is past the best found (it can hold nothing nearer, nor a tie) or past
/// `follow`.
fn anchorOf(sc: *const Scene, i: usize, p: Point, breed: u16) ?Anchor {
    const follow2 = measureOf(follow);
    const pcx = wishCellOf(p.x);
    const pcy = wishCellOf(p.y);
    var best: ?Anchor = null;
    var k: i32 = 0;
    while (k <= wish_rings) : (k += 1) {
        if (k > 0) {
            // Under every metric a length is at least the larger axis.
            const least = measureOf(@as(i64, k - 1) * wish_cell);
            if (least > follow2) break;
            if (best) |b| if (least > b.d2) break;
        }
        var cy = pcy - k;
        while (cy <= pcy + k) : (cy += 1) {
            const edge_row = cy == pcy - k or cy == pcy + k;
            var cx = pcx - k;
            while (cx <= pcx + k) : (cx += if (edge_row or cx == pcx + k) 1 else 2 * k) {
                var j = sc.wg_head[wishBucket(breed, cx, cy)];
                while (j != wish_none and j < i) : (j = sc.wg_next[j]) {
                    const d2 = measure(delta(sc.pos(j), p));
                    if (d2 > follow2) continue;
                    if (best) |b| if (d2 > b.d2 or (d2 == b.d2 and j > b.j)) continue;
                    best = .{ .j = j, .d2 = d2 };
                }
            }
        }
    }
    return best;
}

/// The anchor's wish: toward it from past `band_outer`, away from it
/// inside `band_inner`.
fn addAnchor(total: *Point, p: Point, q: Point, anchor_d2: i64) void {
    if (anchor_d2 > measureOf(band_outer)) {
        add(total, wishAlong(delta(p, q), @as(i32, @intCast(lengthOf(anchor_d2))) - band_outer));
    } else if (anchor_d2 < measureOf(band_inner)) {
        add(total, away(q, p, band_inner - @as(i32, @intCast(lengthOf(anchor_d2)))));
    }
}

/// `wishTotal` over every awake critter, in rank order.
pub fn wishTotalScanned(sc: *const Scene, i: usize) Point {
    const me = sc.seen[i];
    const p = sc.pos(i);
    const breed = me.who.n % breeds;
    var total: Point = .{ .x = 0, .y = 0 };
    var anchor: ?usize = null;
    var anchor_d2: i64 = 0;
    // In rank order: past an unleashed dog, every awake one is a dog below
    // it, and none of those count.
    const past_me_none_count = me.who.kind == .dog and me.rank != 0;
    for (sc.awakeOnes()) |j16| {
        const j: usize = j16;
        const o = sc.seen[j];
        if (j == i) continue;
        if (past_me_none_count and j > i) break;
        const q = sc.pos(j);
        const v = delta(q, p);
        const d2 = measure(v);
        switch (o.who.kind) {
            .cow => if (d2 <= measureOf(cow_room)) {
                const l = lengthOf(d2);
                add(&total, awayRooted(v, l, cow_room - @as(i32, @intCast(l))));
            },
            .dog => {
                if (o.rank >= me.rank) continue;
                if (o.who.n % breeds != breed) {
                    if (d2 <= measureOf(wary)) {
                        const l = lengthOf(d2);
                        add(&total, awayRooted(v, l, wary - @as(i32, @intCast(l))));
                    }
                } else if (d2 <= measureOf(follow) and (anchor == null or d2 < anchor_d2)) {
                    anchor = j;
                    anchor_d2 = d2;
                }
            },
        }
    }
    if (anchor) |j| addAnchor(&total, p, sc.pos(j), anchor_d2);
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
    return awayRooted(v, lengthOf(measure(v)), length);
}

/// `away`, `v` from the other's centre to the critter's and `l` its
/// `lengthOf` length, already taken.
inline fn awayRooted(v: Point, l: i64, length: i32) Point {
    if (v.x == 0 and v.y == 0) return .{ .x = length, .y = 0 };
    return wishAlongRooted(v, l, length);
}

/// A wish `length` long along `v`: each axis of `v` times the length,
/// divided by `v`'s length (`isqrt`), truncated toward zero.
pub fn wishAlong(v: Point, length: i32) Point {
    return wishAlongRooted(v, lengthOf(measure(v)), length);
}

/// `wishAlong`, `l` being `v`'s `lengthOf` length.
inline fn wishAlongRooted(v: Point, l: i64, length: i32) Point {
    return .{
        .x = quotientAlong(v.x, length, l),
        .y = quotientAlong(v.y, length, l),
    };
}

/// Every overlapping pair among the critters the physics sees: the
/// invariant the server checks after every tick (a finding, not a
/// refutation).
///
/// Each critter is checked against those after it in its cell's 3 × 3 of
/// the neighbours' grid (`Cells`: two squares that overlap are less than
/// 2 × `half_most` < `nb_cell` apart on both axes), and each one's finds
/// sorted, so `found` is in the order of every pair in turn: by the first
/// critter, then the second.
pub fn overlaps(b: *Board, found: []([2]Critter)) usize {
    // No fill for the scene, as in `run`.
    @setRuntimeSafety(false);
    var sc: Scene = undefined;
    return overlapsIn(&sc, b, found);
}

fn overlapsIn(sc: *Scene, b: *Board, found: []([2]Critter)) usize {
    if (!sc.init(b)) return 0;
    sc.cells.build(sc);
    const cells = &sc.cells;
    var n: usize = 0;
    var hit: [critter_count]u16 = undefined;
    for (sc.list(), 0..) |a, i| {
        const p = sc.pos(i);
        var hits: usize = 0;
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                for (cells.in(gridCell(p, dx, dy))) |j| {
                    if (j <= i) continue;
                    if (!squaresOverlap(p, a.half, sc.pos(j), sc.seen[j].half)) continue;
                    hit[hits] = j;
                    hits += 1;
                }
            }
        }
        std.sort.insertion(u16, hit[0..hits], {}, std.sort.asc(u16));
        for (hit[0..hits]) |j| {
            if (n < found.len) found[n] = .{ a.who, sc.seen[j].who };
            n += 1;
        }
    }
    return n;
}

test {
    _ = @import("physics_test.zig");
}
