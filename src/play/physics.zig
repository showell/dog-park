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
//! the world (`wrapped`).
//!
//! **A tick** (decisions 20-26): only while the leashed dog is dragged does
//! anything move. The drag is cut into pixel-ticks; in each, the leashed
//! dog takes the step (stopping just short of pressing into anyone), then
//! the walk moves up to `walk_most` critters, dogs and cows, one at a time,
//! out from the leashed dog, shortest link first. A critter reacts only to
//! critters in motion (the leashed dog and those the walk moved before it
//! this step), and takes its step whole or not at all: never onto anyone,
//! and never near the edge of what the physics sees.

const std = @import("std");
const tiles = @import("tiles.zig");
const layout = @import("layout.zig");

pub const dog_count = layout.dog_count;
pub const cow_count = layout.cow_count;
pub const chicken_count = layout.chicken_count;
pub const critter_count = dog_count + cow_count + chicken_count;

/// 256ths in a pixel.
pub const unit: i32 = 256;

pub fn px(n: i32) i32 {
    return n * unit;
}

/// **THE CLOCK**: ticks in a second. The page's tick is 1000 /
/// `ticks_per_second` ms (engine.js reads it from the wasm).
pub const ticks_per_second = 16;

/// `n` seconds, in ticks.
pub fn seconds(comptime n: comptime_int) comptime_int {
    return n * ticks_per_second;
}

/// The world's side, in 256ths.
pub const world: i32 = px(tiles.world_px);
/// A tile's side, in 256ths.
pub const tile: i32 = px(tiles.tile_px);

// **THE KNOBS** (docs/PHYSICS.md), tuned by playing. **Distance is the
// larger axis** (Chebyshev, decision 19): every reach is a square, as the
// critters are.

/// The squares, in whole pixels, as the page draws them. Each critter is
/// its square, centred on its point.
pub const dog_px = 40;
pub const cow_px = 60;
pub const chicken_px = 20;
pub const dog_half: i32 = px(dog_px / 2);
pub const cow_half: i32 = px(cow_px / 2);
pub const chicken_half: i32 = px(chicken_px / 2);
/// A wish shorter than this is no step.
pub const dead_zone: i32 = px(1);
/// A dog keeps this from a moving dog of another breed; a cow from any
/// moving dog.
pub const wary: i32 = px(225);
/// A dog's band around its anchor: too close inside, too far outside.
pub const band_inner: i32 = px(60);
pub const band_outer: i32 = px(100);
/// A dog keeps this from a moving cow.
pub const cow_room: i32 = px(90);
/// The region: the 3000 px square around the leashed dog; every critter in
/// the tiles it meets is seen (and awake).
pub const region_reach: i32 = px(1500);
/// A drag's internal steps, the PIXEL-TICKS: at most 1 px. After each, the
/// walk's dogs step at most as far as the leashed dog did, its cows half.
pub const step_most: i32 = px(1);
/// A tick's drag moves the leashed dog at most 100 px on each axis.
pub const cap: i32 = px(100);
pub const most_displacements = 16;
/// The most of the human's inputs at one tick.
pub const most_humans = 16;
/// The leash comes off 20 s after the drag ends.
pub const let_go_ticks = seconds(20);
/// The most ticks a report runs past the last kept one.
pub const most_ticks = 32;
/// Breeds: dog n has look n mod 4.
pub const breeds = 4;
/// **THE WALK**: the most critters a pixel-tick moves, the leashed dog
/// aside, and how many each visited critter lines up.
pub const walk_most = 40;
pub const walk_fan = 3;
/// **THE NUDGE**: the most critters one step moves together, the stepper
/// and the kin it nudges (decision 25).
pub const nudge_most = 8;
/// **POOP** (decision 26): a dog poops each time it has walked another
/// `poop_every` (each step counted by its larger axis), in the nearest
/// empty spot, a square `poop_px` a side (drawn as a circle) that no
/// critter treats as an obstacle. Each dog has `poops_per_dog` slots, used
/// in turn: its fifth poop takes its first one's.
pub const poop_every: u32 = @intCast(px(50));
pub const poop_px = 12;
pub const poop_half: i32 = px(poop_px / 2);
pub const poops_per_dog = 4;
pub const poop_count = dog_count * poops_per_dog;
/// How far from a dog its poop may land, at most; the spots tried are
/// `poop_grid` apart.
pub const poop_reach: i32 = px(200);
pub const poop_grid: i32 = px(4);
/// A chicken sees poop this far off (half a tile), and steps toward the
/// nearest it sees.
pub const chicken_sight: i32 = px(250);

comptime {
    // **THE WORLD IS WIDER THAN THE REGION** (decision 14): the region's
    // tiles never wrap onto themselves, so no critter is seen twice.
    if (2 * region_reach + 4 * tile >= world) @compileError("the world must be wider than the region's tiles");
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

/// A vector's length: its larger axis. Every reach is compared in it:
/// `measure(v) <= measureOf(reach)`.
pub inline fn measure(v: Point) i64 {
    return @max(@as(i64, @intCast(@abs(v.x))), @as(i64, @intCast(@abs(v.y))));
}

/// The `measure` of a vector `r` long, `r` ≥ 0: `r` itself.
pub inline fn measureOf(r: i64) i64 {
    return r;
}

/// The length a `measure` stands for: itself. A vector's every axis is at
/// most it (`quotientAlong`).
pub inline fn lengthOf(k: i64) i64 {
    return k;
}

/// **A WISH'S AXIS: `@divTrunc(c × length, l)`, FOR |c| ≤ l** (202), where
/// `l` > 0 is the `lengthOf` length of the vector `c` is an axis of, so
/// |c| ≤ `l` (an axis is at most the larger axis), and `length` >
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

pub const Kind = enum(u8) { dog, cow, chicken };

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
    pub fn chicken(n: u16) Critter {
        return .{ .kind = .chicken, .n = n };
    }
    pub fn half(self: Critter) i32 {
        return switch (self.kind) {
            .dog => dog_half,
            .cow => cow_half,
            .chicken => chicken_half,
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
    chickens: [chicken_count]Point,
    dog_known: [dog_count]Known,
    cow_known: [cow_count]Known,
    chicken_known: [chicken_count]Known,
    /// How far each dog has walked, in 256ths (its steps' larger axes):
    /// its poops so far are this over `poop_every`.
    walked: [dog_count]u32,
    /// The poop slots: dog n's are n × `poops_per_dog` onward.
    poops: [poop_count]Point,
    poop_known: [poop_count]Known,
    hold: Hold = .none,

    /// No critters at all.
    pub fn empty() Board {
        return .{
            .dogs = @splat(.{ .x = 0, .y = 0 }),
            .cows = @splat(.{ .x = 0, .y = 0 }),
            .chickens = @splat(.{ .x = 0, .y = 0 }),
            .dog_known = @splat(.absent),
            .cow_known = @splat(.absent),
            .chicken_known = @splat(.absent),
            .walked = @splat(0),
            .poops = @splat(.{ .x = 0, .y = 0 }),
            .poop_known = @splat(.absent),
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
            .chicken => self.chickens[c.n],
        };
    }

    pub fn put(self: *Board, c: Critter, p: Point) void {
        switch (c.kind) {
            .dog => self.dogs[c.n] = p,
            .cow => self.cows[c.n] = p,
            .chicken => self.chickens[c.n] = p,
        }
    }

    pub fn known(self: *const Board, c: Critter) Known {
        return switch (c.kind) {
            .dog => self.dog_known[c.n],
            .cow => self.cow_known[c.n],
            .chicken => self.chicken_known[c.n],
        };
    }

    /// Places a critter and marks it present.
    pub fn place(self: *Board, c: Critter, p: Point) void {
        self.put(c, p);
        switch (c.kind) {
            .dog => self.dog_known[c.n] = .present,
            .cow => self.cow_known[c.n] = .present,
            .chicken => self.chicken_known[c.n] = .present,
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
/// n is 1 + cows + n, chicken n after every dog. Lower is more alpha.
pub fn rank(leashed: ?u16, c: Critter) u32 {
    if (c.kind == .dog and leashed != null and leashed.? == c.n) return 0;
    return switch (c.kind) {
        .cow => 1 + @as(u32, c.n),
        .dog => 1 + cow_count + @as(u32, c.n),
        .chicken => 1 + cow_count + dog_count + @as(u32, c.n),
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

/// A poop slot that holds a new poop at the tick's end.
pub const PoopLine = struct { n: u16, at: Point };

/// A tick's checked line.
pub const Checked = union(enum) {
    critter: CritterLine,
    poop: PoopLine,
    /// A poop slot emptied by the tick (a chicken ate it).
    eaten: u16,
    bump: Critter,
    release: u16,
    rest,
};

/// A tick's checked lines, in order: critter lines in rank order, then the
/// poop slots it changed, by number (`poop` or `eaten`), then a `bump`, a
/// timer's `release` or a `rest`.
pub const Lines = struct {
    list: [critter_count + poop_count + 2]Checked = undefined,
    len: usize = 0,
    /// The tick's last walk: the critters it moved, by `critterIndex`, in
    /// visit order. For the page's labels; not on the wire.
    walk: [walk_most]u16 = undefined,
    walk_len: usize = 0,

    pub fn push(self: *Lines, c: Checked) void {
        self.list[self.len] = c;
        self.len += 1;
    }
    pub fn slice(self: *const Lines) []const Checked {
        return self.list[0..self.len];
    }
};

/// A critter's index among all: dog n is n, cow n is dogs + n.
pub fn critterIndex(c: Critter) usize {
    return switch (c.kind) {
        .dog => c.n,
        .cow => dog_count + @as(usize, c.n),
        .chicken => dog_count + cow_count + @as(usize, c.n),
    };
}

/// A critter the physics sees this tick: in a tile the region meets.
pub const Seen = struct {
    who: Critter,
    rank: u32,
    half: i32,
    start: Point,
};

/// **ONE TICK'S VIEW OF THE BOARD**: every critter in the region's tiles
/// (all of them awake), in rank order, the leashed dog first, and their
/// places as the tick moves them.
pub const Scene = struct {
    board: *Board,
    seen: [critter_count]Seen = undefined,
    at: [critter_count]Point = undefined,
    len: usize = 0,
    /// The last walk's critters, by `critterIndex`, in visit order.
    walk: [walk_most]u16 = undefined,
    walk_len: usize = 0,
    /// The critters in motion this step, by seen index: the leashed dog,
    /// then each the walk has visited.
    moving: [walk_most + 1]u16 = undefined,
    moving_len: usize = 0,
    /// The region's tiles: everything the physics sees.
    span: TileSpan = undefined,
    /// The poop slots the physics sees: present in the region's tiles at
    /// the tick's start, or laid since (eaten ones stay listed, absent).
    poops: [poop_count]u16 = undefined,
    poops_len: usize = 0,
    poop_listed: std.StaticBitSet(poop_count) = undefined,
    /// The slots a dog pooped into this tick.
    poop_laid: std.StaticBitSet(poop_count) = undefined,

    pub fn of(b: *Board) ?Scene {
        var s: Scene = undefined;
        if (!s.init(b)) return null;
        return s;
    }

    pub fn init(s: *Scene, b: *Board) bool {
        const l = b.leashedDog() orelse return false;
        s.board = b;
        s.len = 0;
        s.walk_len = 0;
        s.moving_len = 0;
        const span = TileSpan.of(region(b.dogs[l]));
        s.span = span;
        s.add(.dog(l), l);
        for (0..cow_count) |i| s.consider(.cow(@intCast(i)), span, l);
        for (0..dog_count) |i| if (i != l) s.consider(.dog(@intCast(i)), span, l);
        for (0..chicken_count) |i| s.consider(.chicken(@intCast(i)), span, l);
        s.poops_len = 0;
        s.poop_listed = .initEmpty();
        s.poop_laid = .initEmpty();
        for (0..poop_count) |i| {
            if (b.poop_known[i] == .present and span.holdsPoint(b.poops[i])) s.listPoop(@intCast(i));
        }
        return true;
    }

    fn listPoop(s: *Scene, n: u16) void {
        if (s.poop_listed.isSet(n)) return;
        s.poop_listed.set(n);
        s.poops[s.poops_len] = n;
        s.poops_len += 1;
    }

    fn consider(s: *Scene, c: Critter, span: TileSpan, l: u16) void {
        if (s.board.known(c) != .present) return;
        if (!span.holdsPoint(s.board.at(c))) return;
        s.add(c, l);
    }

    fn add(s: *Scene, c: Critter, l: u16) void {
        const p = s.board.at(c);
        s.seen[s.len] = .{ .who = c, .rank = rank(l, c), .half = c.half(), .start = p };
        s.at[s.len] = p;
        s.len += 1;
    }

    pub fn list(s: *const Scene) []const Seen {
        return s.seen[0..s.len];
    }

    pub fn pos(s: *const Scene, i: usize) Point {
        return s.at[i];
    }

    /// Seen critter `i` to `to`, wrapped into the world. A dog counts the
    /// step on its walk and poops at each `poop_every`.
    pub fn put(s: *Scene, i: usize, to: Point) void {
        const p = wrapped(to);
        const was = s.at[i];
        s.at[i] = p;
        const who = s.seen[i].who;
        s.board.put(who, p);
        if (who.kind != .dog) return;
        const before = s.board.walked[who.n];
        const after = before +| @as(u32, @intCast(measure(delta(was, p))));
        s.board.walked[who.n] = after;
        var k = before / poop_every;
        while (k < after / poop_every) : (k += 1) layPoop(s, who.n, k + 1, p);
    }
};

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

/// Sweeps seen critter `i` along `axis` by `s` against every other seen
/// critter; the blocker is the one that stops it shortest, the
/// higher-ranked on a tie.
fn sweep(sc: *Scene, i: usize, axis: Axis, s: i32) Swept {
    var best = s;
    var blocker: ?usize = null;
    const me = sc.seen[i];
    for (sc.list(), 0..) |o, j| {
        if (j == i) continue;
        const got = sweepLimit(sc.pos(i), me.half, axis, s, sc.pos(j), o.half);
        if (mag(got) < mag(best)) {
            best = got;
            blocker = j;
        }
    }
    return .{ .by = best, .blocker = blocker };
}

/// **ONE TICK**, after its inputs (`input`): the drag (when one is on),
/// then the timer. Writes the tick's checked lines.
pub fn run(b: *Board, t: Tick, begun: Begun, drag: []const Disp, out: *Lines) void {
    out.len = 0;
    out.walk_len = 0;
    var bumped: ?Critter = null;
    if (b.hold == .leashed) {
        // **NO FILL FOR THE SCENE**: a safe build writes 0xaa over memory
        // declared `undefined`; `init` sets every field a scene reads.
        @setRuntimeSafety(false);
        var scene: Scene = undefined;
        {
            @setRuntimeSafety(std.debug.runtime_safety);
            if (scene.init(b)) {
                const sc = &scene;
                const poops_were = b.poops;
                const poops_known_were = b.poop_known;
                if (b.hold.leashed.drag == .on) bumped = playDrag(sc, drag);
                if (bumped != null or begun.letting_go == .after_drag) b.hold.leashed.drag = .{ .ended = t };
                out.walk = sc.walk;
                out.walk_len = sc.walk_len;
                for (sc.list()) |s| {
                    const now = b.at(s.who);
                    if (now.x != s.start.x or now.y != s.start.y) out.push(.{ .critter = .{ .who = s.who, .before = s.start, .after = now } });
                }
                // A slot's line goes by what it held in the region's tiles
                // at the start (what the page holds too), never by a poop
                // elsewhere that a new one replaced.
                for (0..poop_count) |n| {
                    const k = b.poop_known[n];
                    const at = b.poops[n];
                    const was = poops_were[n];
                    const was_seen = poops_known_were[n] == .present and sc.span.holdsPoint(was);
                    if (k == .present) {
                        if (sc.poop_laid.isSet(n) and (!was_seen or at.x != was.x or at.y != was.y)) out.push(.{ .poop = .{ .n = @intCast(n), .at = at } });
                    } else if (was_seen) {
                        out.push(.{ .eaten = @intCast(n) });
                    }
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

/// The drag's displacements, x then y, each cut into pixel-ticks; the
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

/// One pixel-tick: the leashed dog takes the step, stopping just short of
/// pressing into anyone; then the walk; then the chickens.
fn dragStep(sc: *Scene, axis: Axis, inc: i32) ?Critter {
    if (inc == 0) return null;
    const r = sweep(sc, 0, axis, inc);
    sc.put(0, moved(sc.pos(0), axis, r.by));
    if (r.by != 0) {
        walk(sc, mag(r.by));
        chickensStep(sc, mag(r.by));
    }
    if (r.blocker) |j| return sc.seen[j].who;
    return null;
}

/// **THE WALK** (decisions 20-22): out from the leashed dog (seen index
/// 0), shortest link first. The leashed dog lines up its `walk_fan`
/// nearest critters, each waiting keyed by its distance from the critter
/// that lined it up; the walk visits the least key (ties to the lower
/// rank), which wishes from the critters in motion, steps (a dog at most
/// `most`, a cow half), and lines up its own `walk_fan` nearest not yet
/// visited (a critter already waiting takes the nearer key). At most
/// `walk_most` critters; one the walk doesn't reach stays put.
fn walk(sc: *Scene, most: i32) void {
    sc.walk_len = 0;
    sc.moving[0] = 0;
    sc.moving_len = 1;
    var waiting: Waiting = .{};
    var visited: std.StaticBitSet(critter_count) = .initEmpty();
    visited.set(0);
    lineUp(sc, 0, &waiting, &visited);
    while (sc.walk_len < walk_most) {
        const i: usize = waiting.pop() orelse break;
        visited.set(i);
        sc.moving[sc.moving_len] = @intCast(i);
        sc.moving_len += 1;
        sc.walk[sc.walk_len] = @intCast(critterIndex(sc.seen[i].who));
        sc.walk_len += 1;
        const limit = if (sc.seen[i].who.kind == .cow) @divTrunc(most, 2) else most;
        stepVetoed(sc, i, stepAtMost(wishOf(sc, i), limit));
        lineUp(sc, i, &waiting, &visited);
    }
}

/// The walk's waiting critters, each keyed by its distance from the one
/// that lined it up, held in order: the least key (then the lower rank)
/// last, so it pops.
const Waiting = struct {
    key: [walk_most * walk_fan + walk_fan]i64 = undefined,
    who: [walk_most * walk_fan + walk_fan]u16 = undefined,
    len: usize = 0,

    /// `who` waits with `key`, or, already waiting with a larger key, with
    /// this one instead.
    fn offer(w: *Waiting, key: i64, who: u16) void {
        for (w.who[0..w.len], 0..) |o, k| if (o == who) {
            if (w.key[k] <= key) return;
            std.mem.copyForwards(i64, w.key[k .. w.len - 1], w.key[k + 1 .. w.len]);
            std.mem.copyForwards(u16, w.who[k .. w.len - 1], w.who[k + 1 .. w.len]);
            w.len -= 1;
            break;
        };
        var k = w.len;
        while (k > 0 and (w.key[k - 1] < key or (w.key[k - 1] == key and w.who[k - 1] < who))) : (k -= 1) {
            w.key[k] = w.key[k - 1];
            w.who[k] = w.who[k - 1];
        }
        w.key[k] = key;
        w.who[k] = who;
        w.len += 1;
    }

    fn pop(w: *Waiting) ?u16 {
        if (w.len == 0) return null;
        w.len -= 1;
        return w.who[w.len];
    }
};

/// Seen critter `from`'s `walk_fan` nearest not yet `visited` (ties to the
/// lower rank), from where it stands now, offered to `waiting` keyed by
/// their distance from it.
fn lineUp(sc: *const Scene, from: usize, waiting: *Waiting, visited: *const std.StaticBitSet(critter_count)) void {
    const p = sc.pos(from);
    var near_key: [walk_fan]i64 = undefined;
    var near_who: [walk_fan]u16 = undefined;
    var n: usize = 0;
    for (1..sc.len) |j| {
        if (visited.isSet(j) or sc.seen[j].who.kind == .chicken) continue;
        const d = measure(delta(sc.pos(j), p));
        // In rank order, so a tie keeps the one already in.
        if (n == walk_fan and d >= near_key[n - 1]) continue;
        var k = if (n < walk_fan) n else n - 1;
        while (k > 0 and near_key[k - 1] > d) : (k -= 1) {
            near_key[k] = near_key[k - 1];
            near_who[k] = near_who[k - 1];
        }
        near_key[k] = d;
        near_who[k] = @intCast(j);
        if (n < walk_fan) n += 1;
    }
    for (near_key[0..n], near_who[0..n]) |d, j| waiting.offer(d, j);
}

/// **WHAT A CRITTER WANTS** (decisions 21-24), from the critters in motion
/// only, where they now stand:
/// - a cow: from the nearest moving critter alone (ties to the lower rank):
///   a cow, it closes in to touching; a dog, it keeps `wary` from it;
/// - a dog: room `cow_room` from every moving cow, `wary` from every
///   moving dog of another breed, and its place in the herd against its
///   anchor, the nearest moving dog of its breed (ties to the lower rank).
pub fn wishOf(sc: *const Scene, i: usize) Point {
    if (sc.seen[i].who.kind == .cow) return cowWish(sc, i);
    const me = sc.seen[i].who;
    const p = sc.pos(i);
    var total: Point = .{ .x = 0, .y = 0 };
    var anchor: ?usize = null;
    var anchor_d: i64 = 0;
    for (sc.moving[0..sc.moving_len]) |j16| {
        const j: usize = j16;
        if (j == i) continue;
        const o = sc.seen[j].who;
        const q = sc.pos(j);
        switch (o.kind) {
            // The walk moves no chicken, so none is ever in motion here.
            .chicken => {},
            .cow => addRoom(&total, q, p, cow_room),
            .dog => if (o.n % breeds != me.n % breeds) {
                addRoom(&total, q, p, wary);
            } else {
                const d = measure(delta(q, p));
                if (anchor == null or d < anchor_d or (d == anchor_d and j < anchor.?)) {
                    anchor = j;
                    anchor_d = d;
                }
            },
        }
    }
    if (anchor) |j| {
        const q = sc.pos(j);
        if (anchor_d > band_outer) {
            add(&total, wishAlong(delta(p, q), @as(i32, @intCast(anchor_d)) - band_outer));
        } else if (anchor_d < band_inner) {
            add(&total, away(q, p, band_inner - @as(i32, @intCast(anchor_d))));
        }
    }
    return total;
}

/// A cow's wish (decision 24): the nearest moving critter decides it. A
/// cow, it closes the gap to touching; a dog, room `wary` from it.
fn cowWish(sc: *const Scene, i: usize) Point {
    const p = sc.pos(i);
    var nearest: ?usize = null;
    var nearest_d: i64 = 0;
    for (sc.moving[0..sc.moving_len]) |j16| {
        const j: usize = j16;
        if (j == i) continue;
        const d = measure(delta(sc.pos(j), p));
        if (nearest == null or d < nearest_d or (d == nearest_d and j < nearest.?)) {
            nearest = j;
            nearest_d = d;
        }
    }
    var total: Point = .{ .x = 0, .y = 0 };
    const j = nearest orelse return total;
    const q = sc.pos(j);
    switch (sc.seen[j].who.kind) {
        .dog => addRoom(&total, q, p, wary),
        .cow => if (nearest_d > 2 * cow_half) {
            total = wishAlong(delta(p, q), @as(i32, @intCast(nearest_d)) - 2 * cow_half);
        },
        .chicken => {},
    }
    return total;
}

/// Room from a critter at `q` for the one at `p`: away, by the shortfall
/// inside `reach`.
fn addRoom(total: *Point, q: Point, p: Point, reach: i32) void {
    const d = measure(delta(q, p));
    if (d > reach) return;
    add(total, away(q, p, reach - @as(i32, @intCast(d))));
}

/// The step a total of wishes comes to, at most `most` on its larger axis:
/// none inside the dead zone; the total itself within `most`; else scaled
/// to it.
pub fn stepAtMost(total: Point, most: i32) Point {
    const t = measure(total);
    if (t < dead_zone) return .{ .x = 0, .y = 0 };
    if (t <= most) return total;
    return .{
        .x = @intCast(@divTrunc(@as(i64, total.x) * most, t)),
        .y = @intCast(@divTrunc(@as(i64, total.y) * most, t)),
    };
}

/// **THE VETO AND THE NUDGE** (Steve, 2026-10-14; decision 25): seen
/// critter `i` takes `step` whole, or not at all. Where its square there
/// would overlap kin (a cow a cow, a dog a dog of its breed, never the
/// leashed dog), it nudges them: they take the same step with it, and
/// whoever they would overlap is nudged in turn, up to `nudge_most` in
/// all. The step is vetoed, for every one of them, if any would overlap a
/// critter not kin, or come within `cow_half` of the seen tiles' edge,
/// where a critter the physics doesn't see may poke in (decision 23). The
/// group moves by one vector, so its members keep clear of each other; no
/// two critters overlap, by induction.
fn stepVetoed(sc: *Scene, i: usize, step: Point) void {
    if (step.x == 0 and step.y == 0) return;
    var group: [nudge_most]usize = undefined;
    group[0] = i;
    var n: usize = 1;
    var in_group: std.StaticBitSet(critter_count) = .initEmpty();
    in_group.set(i);
    const breed = kinOf(sc.seen[i].who);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const g = group[k];
        const to = wrapped(.{ .x = sc.pos(g).x + step.x, .y = sc.pos(g).y + step.y });
        const h = sc.seen[g].half;
        if (!clearOfTheEdge(sc.span, to, h)) return;
        for (sc.list(), 0..) |o, j| {
            if (in_group.isSet(j) or !squaresOverlap(to, h, sc.pos(j), o.half)) continue;
            if (j == 0 or breed == null or kinOf(o.who) != breed or n == nudge_most) return;
            group[n] = j;
            n += 1;
            in_group.set(j);
        }
    }
    for (group[0..n]) |g| sc.put(g, .{ .x = sc.pos(g).x + step.x, .y = sc.pos(g).y + step.y });
}

/// Who nudges whom: cows are one kin, each breed of dog another; a
/// chicken has no kin.
fn kinOf(c: Critter) ?u8 {
    return switch (c.kind) {
        .cow => breeds,
        .dog => @intCast(c.n % breeds),
        .chicken => null,
    };
}

/// **A DOG POOPS** (decision 26): its `k`th poop, in slot n ×
/// `poops_per_dog` + k mod `poops_per_dog` (taking whatever that slot
/// held), at the nearest spot to `p` where its square overlaps no critter
/// and no poop the physics sees: rings `poop_grid` apart out to
/// `poop_reach`, each walked clockwise from its north-west corner. With no
/// such spot, no poop.
fn layPoop(sc: *Scene, dog: u16, k: u32, p: Point) void {
    const slot: u16 = @intCast(@as(u32, dog) * poops_per_dog + k % poops_per_dog);
    var r: i32 = 0;
    while (r <= poop_reach) : (r += poop_grid) {
        if (r == 0) {
            if (poopFits(sc, p, slot)) return placePoop(sc, slot, p);
            continue;
        }
        // Clockwise: the north side west to east, the east side down, the
        // south side east to west, the west side up.
        var t: i32 = -r;
        while (t < r) : (t += poop_grid) if (tryPoop(sc, slot, p, t, -r)) return;
        t = -r;
        while (t < r) : (t += poop_grid) if (tryPoop(sc, slot, p, r, t)) return;
        t = r;
        while (t > -r) : (t -= poop_grid) if (tryPoop(sc, slot, p, t, r)) return;
        t = r;
        while (t > -r) : (t -= poop_grid) if (tryPoop(sc, slot, p, -r, t)) return;
    }
}

fn tryPoop(sc: *Scene, slot: u16, p: Point, dx: i32, dy: i32) bool {
    const q = wrapped(.{ .x = p.x + dx, .y = p.y + dy });
    if (!poopFits(sc, q, slot)) return false;
    placePoop(sc, slot, q);
    return true;
}

/// Whether a poop at `q` overlaps no critter and no other poop the
/// physics sees.
fn poopFits(sc: *const Scene, q: Point, slot: u16) bool {
    for (sc.list(), 0..) |o, j| if (squaresOverlap(q, poop_half, sc.pos(j), o.half)) return false;
    for (sc.poops[0..sc.poops_len]) |n| {
        if (n == slot or sc.board.poop_known[n] != .present) continue;
        if (squaresOverlap(q, poop_half, sc.board.poops[n], poop_half)) return false;
    }
    return true;
}

fn placePoop(sc: *Scene, slot: u16, q: Point) void {
    sc.board.poops[slot] = q;
    sc.board.poop_known[slot] = .present;
    sc.poop_laid.set(slot);
    sc.listPoop(slot);
}

/// **THE CHICKENS** (decision 26), after each pixel-tick's walk, in
/// number order: each steps toward the nearest poop it sees within
/// `chicken_sight` (ties to the lower slot), at most as far as the
/// leashed dog did, whole or not at all (the veto, no nudge: a chicken has
/// no kin). Then it eats every poop its square overlaps. A chicken is
/// fearless and heeds no critter; it plans nothing, so three chase the one
/// poop till it's gone.
fn chickensStep(sc: *Scene, most: i32) void {
    for (sc.list(), 0..) |o, i| {
        if (o.who.kind != .chicken) continue;
        const p = sc.pos(i);
        var target: ?Point = null;
        var target_d: i64 = 0;
        for (sc.poops[0..sc.poops_len]) |n| {
            if (sc.board.poop_known[n] != .present) continue;
            const d = measure(delta(p, sc.board.poops[n]));
            if (d > chicken_sight) continue;
            if (target == null or d < target_d) {
                target = sc.board.poops[n];
                target_d = d;
            }
        }
        if (target) |q| stepVetoed(sc, i, stepAtMost(delta(p, q), most));
        const now = sc.pos(i);
        for (sc.poops[0..sc.poops_len]) |n| {
            if (sc.board.poop_known[n] == .present and squaresOverlap(now, chicken_half, sc.board.poops[n], poop_half)) sc.board.poop_known[n] = .absent;
        }
    }
}

/// Whether the square of half `h` at `p` keeps `cow_half` (the most any
/// square pokes past its point) inside the span's tiles on both axes, so
/// no critter whose point is outside them can overlap it.
pub fn clearOfTheEdge(span: TileSpan, p: Point, h: i32) bool {
    return clearOn(p.x, h, span.col_lo, span.col_hi) and clearOn(p.y, h, span.row_lo, span.row_hi);
}

fn clearOn(v: i32, h: i32, lo: i32, hi: i32) bool {
    const off = @mod(@as(i64, v) - @as(i64, lo) * tile, world);
    const room: i64 = h + cow_half;
    return off >= room and off + room <= (@as(i64, hi) - lo + 1) * tile;
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
/// divided by `v`'s length (its larger axis), truncated toward zero.
pub fn wishAlong(v: Point, length: i32) Point {
    const l = measure(v);
    return .{ .x = quotientAlong(v.x, length, l), .y = quotientAlong(v.y, length, l) };
}

/// Every overlapping pair among the critters the physics sees, by the
/// first critter then the second: the invariant the server checks after
/// every tick (a finding, not a refutation).
pub fn overlaps(b: *Board, found: []([2]Critter)) usize {
    @setRuntimeSafety(false);
    var sc: Scene = undefined;
    @setRuntimeSafety(std.debug.runtime_safety);
    if (!sc.init(b)) return 0;
    var n: usize = 0;
    for (sc.list(), 0..) |a, i| {
        for (sc.list()[i + 1 ..], i + 1..) |o, j| {
            if (!squaresOverlap(sc.pos(i), a.half, sc.pos(j), o.half)) continue;
            if (n < found.len) found[n] = .{ a.who, o.who };
            n += 1;
        }
    }
    return n;
}

test {
    _ = @import("physics_test.zig");
}
