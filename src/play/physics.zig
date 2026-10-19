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
//! **A tick** (decisions 20-31): only while the leashed dog is dragged does
//! anything move. The drag is cut into pixel-ticks; in each, the leashed
//! dog takes the step (stopping just short of pressing into anyone, or
//! shoving a chicken, or sliding around a poop), then the walk moves up to
//! `walk_most` critters, dogs and cows, one at a time, out from the
//! leashed dog, shortest link first, then the herd's deepest dog poops if
//! one is due. A critter reacts only to critters in motion (the leashed
//! dog and those the walk moved before it this step), and takes its step
//! whole or not at all, or once more sideways: never onto anyone and never
//! onto poop. After the drag, the chickens' turn.

const std = @import("std");
const builtin = @import("builtin");
const tiles = @import("tiles.zig");
const layout = @import("layout.zig");
const world_file = @import("world.zig").world;
const rules = @import("rules.zig");
const roc = @import("roc_physics.zig");

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

/// The squares, in whole pixels, as the page draws them: the world's
/// (world.zig, roc/world.roc). Each critter is its square, centred on its
/// point. Dogs and cows at 70% of their first sizes, with the tiles and the
/// spacings below (Steve, 2026-10-15: "on a small screen we need a little
/// more density"); chickens and poop kept.
pub const dog_px: comptime_int = world_file.sizes.dog_px;
pub const cow_px: comptime_int = world_file.sizes.cow_px;
pub const chicken_px: comptime_int = world_file.sizes.chicken_px;
pub const dog_half: i32 = px(dog_px / 2);
pub const cow_half: i32 = px(cow_px / 2);
pub const chicken_half: i32 = px(chicken_px / 2);
/// A wish shorter than this is no step.
pub const dead_zone: i32 = px(rules.rules.limits.dead_zone);
/// **THE RULES' DISTANCES**, by the names the docs and tests use: the
/// rules' (rules.zig, which roc/Rules.roc says), which the wish applies.
/// A dog keeps `wary` from a moving dog of another breed; a cow from any
/// moving dog.
pub const wary: i32 = px(rules.rules.dog.dog.keep);
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
/// Breeds: dog n has look n mod `breeds` (the world's).
pub const breeds: comptime_int = world_file.breeds;
/// **THE WALK**: the most critters a pixel-tick moves, the leashed dog
/// aside: roc/Walk.roc's `walk_most`, which the room the physics lends the
/// walk is sized by (a walk that needed more would be a panic, `roc_alloc`).
pub const walk_most = rules.rules.limits.most;
/// **THE NUDGE**: the most critters one step moves together, the stepper
/// and the kin it nudges (decision 25).
pub const nudge_most = rules.rules.limits.nudge_most;
/// **POOP** (decision 29): the herd poops each time the leashed
/// dog has walked another `poop_every` (each step counted by its larger
/// axis): the deepest dog of its breed in that pixel-tick's walk, `poop_back`
/// behind itself, a square `poop_px` a side (drawn as a circle) that blocks
/// dogs and cows. It stays till a chicken eats it: the park's poops take
/// the `poop_count` slots in turn (`Board.laid`), so only the 2049th poop
/// since the load would take the first one's slot.
pub const poop_every: u32 = @intCast(px(rules.rules.poop.every));
pub const poop_px: comptime_int = world_file.sizes.poop_px;
pub const poop_half: i32 = px(poop_px / 2);
pub const poop_count: comptime_int = rules.rules.poop.slots;
comptime {
    // `laid` counts in 32 bits and takes the slots in turn: its wrap keeps
    // their order only if the slots divide 2^32.
    if (!std.math.isPowerOfTwo(poop_count)) @compileError("rules.zon: the poop slots must be a power of two");
}
/// How far behind its dog a poop lands, centre to centre; taken, the
/// spots tried next are on rings `poop_grid` apart around it, out to
/// `poop_reach`.
pub const poop_back: i32 = px(rules.rules.poop.back);
pub const poop_reach: i32 = px(rules.rules.poop.reach);
pub const poop_grid: i32 = px(rules.rules.poop.grid);
/// **THE CHICKENS' TURN** (decision 31): a chicken sees ripe poop this far
/// off; it steps at most half the leashed dog's net move in the tick, and
/// at most `chicken_step`; with nothing to forage it walks home when it is
/// more than `home_band` from it.
pub const chicken_sight: i32 = px(rules.rules.chickens.sight);
pub const chicken_step: i32 = px(rules.rules.chickens.step);
pub const home_band: i32 = px(rules.rules.chickens.home_band);

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

/// Numbered as roc/Wish.roc's `kind_of` reads them across the boundary.
pub const Kind = enum(u8) { dog = 0, cow = 1, chicken = 2 };

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
    /// The poop slots, and how many poops the park has laid since its
    /// layout: the next takes slot `laid` mod `poop_count`.
    poops: [poop_count]Point,
    poop_known: [poop_count]Known,
    laid: u32 = 0,
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

/// **THE REGION IS THE WORLD** (Steve, 2026-10-15: a 6 x 6-tile world,
/// single-player): the physics sees every critter, wherever the leashed
/// dog stands. The tiles from (0, 0), every one once.
pub fn region(_: Point) Rect {
    return .{ .lo = .{ .x = 0, .y = 0 }, .hi = .{ .x = world, .y = world } };
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

/// What the leashed dog bumped: a critter, or a poop by slot.
pub const Bumped = union(enum) {
    critter: Critter,
    poop: u16,
};

/// A tick's checked line.
pub const Checked = union(enum) {
    critter: CritterLine,
    poop: PoopLine,
    /// A poop slot emptied by the tick (a chicken ate it).
    eaten: u16,
    bump: Bumped,
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
    /// The region's tiles: everything the physics sees.
    span: TileSpan = undefined,
    /// The poops the physics sees: present in the region's tiles at the
    /// tick's start, or laid since, and not eaten. A listed slot is always
    /// present.
    poop_listed: std.StaticBitSet(poop_count) = undefined,
    /// **THE POOPS BY TILE** (metal-vmm QUEUE 207's measure): each listed
    /// slot is on the list of the span's tile its point stands in
    /// (`poop_head` by the tile's offset in the span, `poop_next` by slot,
    /// `no_poop` ends a list), so a square asks only the tiles it could
    /// reach (`Near`).
    poop_head: [span_tiles][span_tiles]u16 = undefined,
    poop_next: [poop_count]u16 = undefined,
    /// The slots a dog pooped into this tick.
    poop_laid: std.StaticBitSet(poop_count) = undefined,
    /// **THE SLOTS SEEN AT THE START** (metal-vmm QUEUE 210): listed when
    /// the tick began, what the page holds too; and for each such slot a
    /// poop is laid into, its point before (`poop_was`, set only then). A
    /// tick's poop lines walk these and the laid slots, not all 2048.
    poop_start: std.StaticBitSet(poop_count) = undefined,
    poop_was: [poop_count]Point = undefined,
    /// **THE LISTS THE WALK LENDS ROC** (roc/Walk.roc, `walk`): the listed
    /// poops by tile, again whenever they change (`poops_changed`); and the
    /// seen critters, for each walk.
    roc_walk: roc.Walk(critter_count, walk_most + 1, poop_count, span_tiles * span_tiles, span_cells) = .{},
    poops_changed: bool = true,
    /// **THE SEEN CRITTERS BY CELL** (metal-vmm QUEUE 210): seen index `j`
    /// is set in the cell of the world its point stands in (`cell` a side,
    /// `cellOf`), kept by `put` on every move; `seen_cell` is where each is set. A
    /// square asks only the cells it could reach (`critters`), and walks
    /// the set bits **in seen index order**, the order a scan of every
    /// seen critter took: who is nudged, shoved or blocks first follows it.
    seen_cells: [span_cells][span_cells]SeenSet = undefined,
    seen_cell: [critter_count]u16 = undefined,
    /// The poops the leashed dog's walk has crossed `poop_every` for since
    /// the last were laid (`layDue`, after the pixel-tick's walk).
    poop_due: u32 = 0,
    /// The last walk's deepest dog of the leashed dog's breed (ties to the
    /// later visited), and its anchor: who poops, and which way is behind.
    pooper: usize = 0,
    pooper_anchor: ?usize = null,
    /// The leashed dog's step this pixel-tick: behind it is the other way.
    step: Point = .{ .x = 0, .y = 0 },

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
        s.poop_due = 0;
        s.pooper = 0;
        s.pooper_anchor = null;
        s.step = .{ .x = 0, .y = 0 };
        const span = TileSpan.of(region(b.dogs[l]));
        s.span = span;
        s.add(.dog(l), l);
        for (0..cow_count) |i| s.consider(.cow(@intCast(i)), span, l);
        for (0..dog_count) |i| if (i != l) s.consider(.dog(@intCast(i)), span, l);
        for (0..chicken_count) |i| s.consider(.chicken(@intCast(i)), span, l);
        s.seen_cells = @splat(@splat(.initEmpty()));
        for (0..s.len) |j| {
            const c = s.cellOf(s.at[j]);
            s.seen_cell[j] = c;
            s.cellSet(c).set(j);
        }
        s.poop_listed = .initEmpty();
        s.poop_head = @splat(@splat(no_poop));
        s.poop_laid = .initEmpty();
        for (0..poop_count) |i| {
            if (b.poop_known[i] == .present and span.holdsPoint(b.poops[i])) s.listPoop(@intCast(i));
        }
        s.poop_start = s.poop_listed;
        s.poops_changed = true;
        return true;
    }

    /// The listed poops for the walk, by tile, row by row from the world's
    /// (0, 0), and in slot order on each.
    fn lendPoops(s: *Scene) void {
        const w = &s.roc_walk;
        const tiles_n = span_tiles * span_tiles;
        var count: [tiles_n]u16 = @splat(0);
        var it = s.poop_listed.iterator(.{});
        while (it.next()) |n| count[poopTile(s.board.poops[n])] += 1;
        var from: u16 = 0;
        for (count, 0..) |c, t| {
            w.from.items[t] = from;
            from += c;
        }
        w.from.items[tiles_n] = from;
        w.from.len = tiles_n + 1;
        var fill = w.from.items[0..tiles_n].*;
        it = s.poop_listed.iterator(.{});
        while (it.next()) |n| {
            const at = s.board.poops[n];
            const t = poopTile(at);
            w.poops.items[fill[t]] = .{ .x = at.x, .y = at.y, .slot = @intCast(n) };
            fill[t] += 1;
        }
        w.poops.len = from;
        s.poops_changed = false;
    }

    fn poopTile(p: Point) usize {
        const col: usize = @intCast(@divFloor(@mod(p.x, world), tile));
        const row: usize = @intCast(@divFloor(@mod(p.y, world), tile));
        return row * span_tiles + col;
    }

    /// Lists slot `n`, whose point stands in the span, on its tile's list.
    fn listPoop(s: *Scene, n: u16) void {
        if (s.poop_listed.isSet(n)) return;
        s.poop_listed.set(n);
        s.link(n);
    }

    fn headOf(s: *Scene, p: Point) *u16 {
        const col = @divFloor(@mod(p.x - s.span.col_lo * tile, world), tile);
        const row = @divFloor(@mod(p.y - s.span.row_lo * tile, world), tile);
        return &s.poop_head[@intCast(row)][@intCast(col)];
    }

    fn link(s: *Scene, n: u16) void {
        s.poops_changed = true;
        const head = s.headOf(s.board.poops[n]);
        s.poop_next[n] = head.*;
        head.* = n;
    }

    /// A chicken eats listed slot `n`: it is absent, and off the lists.
    fn eat(s: *Scene, n: u16) void {
        s.unlink(n);
        s.poop_listed.unset(n);
        s.board.poop_known[n] = .absent;
    }

    /// Takes listed slot `n` off its tile's list (before the slot is laid
    /// anew elsewhere, or eaten).
    fn unlink(s: *Scene, n: u16) void {
        s.poops_changed = true;
        var at = s.headOf(s.board.poops[n]);
        while (at.* != n) at = &s.poop_next[at.*];
        at.* = s.poop_next[n];
    }

    /// The listed slots whose point might lie within `reach` of `p` on
    /// both axes: those of the tiles the square meets, round the torus.
    pub fn near(s: *const Scene, p: Point, reach: i32) Near {
        const xs = Wrapped.of(@mod(p.x, world), reach, tile, span_tiles);
        const ys = Wrapped.of(@mod(p.y, world), reach, tile, span_tiles);
        return .{ .sc = s, .cols = xs, .rows = ys };
    }

    /// The cell a point stands in, `row * span_cells + col`, from the
    /// world's (0, 0).
    fn cellOf(_: *const Scene, p: Point) u16 {
        const col: usize = @intCast(@divFloor(@mod(p.x, world), cell));
        const row: usize = @intCast(@divFloor(@mod(p.y, world), cell));
        return @intCast(row * span_cells + col);
    }

    fn cellSet(s: *Scene, c: u16) *SeenSet {
        return &s.seen_cells[c / span_cells][c % span_cells];
    }

    /// Every seen critter whose point might lie within `reach` of `p` on
    /// both axes (fewer than `reach` away: a superset of those that are):
    /// those of the cells the square meets, round the torus.
    pub fn critters(s: *const Scene, p: Point, reach: i32) SeenSet {
        var out: SeenSet = .initEmpty();
        const xs = Wrapped.of(@mod(p.x, world), reach, cell, span_cells);
        const ys = Wrapped.of(@mod(p.y, world), reach, cell, span_cells);
        for (0..ys.n) |ri| {
            const r = ys.at(ri);
            for (0..xs.n) |ci| out.setUnion(s.seen_cells[r][xs.at(ci)]);
        }
        return out;
    }

    /// **THE BUCKETS HOLD** every seen critter in the cell its point
    /// stands in, and nowhere else: checked after every pixel-tick and
    /// chicken's turn in the tests (a move that forgot its bit would let a
    /// square miss whoever it overlaps).
    pub fn bucketsHold(s: *Scene) bool {
        var bits: usize = 0;
        for (s.seen_cells) |row| for (row) |set| {
            bits += set.count();
        };
        if (bits != s.len) return false;
        for (0..s.len) |j| {
            const c = s.cellOf(s.at[j]);
            if (c != s.seen_cell[j] or !s.cellSet(c).isSet(j)) return false;
        }
        return true;
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

    /// Seen critter `i` to `to`, wrapped into the world. The leashed dog
    /// (seen index 0) counts the step on its walk, and each `poop_every`
    /// it crosses is a poop due after the walk (`layDue`).
    pub fn put(s: *Scene, i: usize, to: Point) void {
        const p = wrapped(to);
        const was = s.at[i];
        s.at[i] = p;
        const c = s.cellOf(p);
        if (c != s.seen_cell[i]) {
            s.cellSet(s.seen_cell[i]).unset(i);
            s.cellSet(c).set(i);
            s.seen_cell[i] = c;
        }
        const who = s.seen[i].who;
        s.board.put(who, p);
        if (i != 0) return;
        const before = s.board.walked[who.n];
        const after = before +| @as(u32, @intCast(measure(delta(was, p))));
        s.board.walked[who.n] = after;
        s.poop_due += after / poop_every - before / poop_every;
    }
};

/// The most tiles a span is wide: the region's side, and one more for a
/// region that doesn't sit on the tiles' lines.
pub const span_tiles = tiles.world_tiles;

/// The end of a tile's list of poops.
const no_poop: u16 = std.math.maxInt(u16);

/// A set of seen indexes.
pub const SeenSet = std.StaticBitSet(critter_count);

/// **A CELL OF THE SEEN CRITTERS' BUCKETS**: a tile cut `cell_per_tile`
/// ways on each axis, a side a few critters wide.
pub const cell_per_tile = world_file.cell_per_tile;
pub const cell: i32 = @divExact(tile, cell_per_tile);
pub const span_cells: usize = span_tiles * cell_per_tile;

/// **A RANGE ROUND THE TORUS**: the `n` cells (or tiles), `size` a side,
/// that a span of `reach` either way of `v` (in [0, world)) meets, from
/// `lo`, each named by `at` in [0, `count`); never more than `count`, so
/// no cell comes twice.
const Wrapped = struct {
    lo: i32,
    n: usize,
    count: i32,

    fn of(v: i32, reach: i32, size: i32, count: usize) Wrapped {
        const lo = @divFloor(v - reach, size);
        const hi = @divFloor(v + reach, size);
        return .{ .lo = lo, .n = @min(@as(usize, @intCast(hi - lo + 1)), count), .count = @intCast(count) };
    }
    fn at(w: Wrapped, i: usize) usize {
        return @intCast(@mod(w.lo + @as(i32, @intCast(i)), w.count));
    }
};

comptime {
    // The world is whole cells and tiles.
    std.debug.assert(@mod(world, cell) == 0 and span_cells * cell == world);
}

/// The listed poop slots on some tiles (`Scene.near`), round the torus,
/// a tile's list at a time.
pub const Near = struct {
    sc: *const Scene,
    cols: Wrapped,
    rows: Wrapped,
    /// The next tile to open, counted row by row over the range.
    k: usize = 0,
    at: u16 = no_poop,

    pub fn next(it: *Near) ?u16 {
        while (it.at == no_poop) {
            if (it.k == it.cols.n * it.rows.n) return null;
            it.at = it.sc.poop_head[it.rows.at(it.k / it.cols.n)][it.cols.at(it.k % it.cols.n)];
            it.k += 1;
        }
        const n = it.at;
        it.at = it.sc.poop_next[n];
        return n;
    }
};

/// The result of sweeping a square along an axis.
const Swept = struct { by: i32, blocker: ?Bumped };

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

/// Sweeps the leashed dog (seen index 0) along `axis` by `s` against every
/// other seen critter and every poop the physics sees; the blocker is the
/// one that stops it shortest, the higher-ranked on a tie, poops after
/// critters, the lower slot first.
fn sweep(sc: *Scene, axis: Axis, s: i32) Swept {
    var best = s;
    var blocker: ?Bumped = null;
    const p = sc.pos(0);
    const h = sc.seen[0].half;
    var near = sc.critters(p, h + cow_half + mag(s));
    near.unset(0);
    var it = near.iterator(.{});
    while (it.next()) |j| {
        const o = sc.seen[j];
        const got = sweepLimit(p, h, axis, s, sc.pos(j), o.half);
        if (mag(got) < mag(best)) {
            best = got;
            blocker = .{ .critter = o.who };
        }
    }
    var poops = sc.near(p, h + poop_half + mag(s));
    var poop_best = s;
    var poop: ?u16 = null;
    while (poops.next()) |n| {
        const got = sweepLimit(p, h, axis, s, sc.board.poops[n], poop_half);
        if (mag(got) < mag(poop_best) or (poop != null and mag(got) == mag(poop_best) and n < poop.?)) {
            poop_best = got;
            poop = n;
        }
    }
    if (poop) |n| if (mag(poop_best) < mag(best)) {
        best = poop_best;
        blocker = .{ .poop = n };
    };
    return .{ .by = best, .blocker = blocker };
}

/// **ONE TICK**, after its inputs (`input`): the drag (when one is on),
/// then the timer. Writes the tick's checked lines.
pub fn run(b: *Board, t: Tick, begun: Begun, drag: []const Disp, out: *Lines) void {
    out.len = 0;
    out.walk_len = 0;
    var bumped: ?Bumped = null;
    if (b.hold == .leashed) {
        // **NO FILL FOR THE SCENE**: a safe build writes 0xaa over memory
        // declared `undefined`; `init` sets every field a scene reads.
        @setRuntimeSafety(false);
        var scene: Scene = undefined;
        {
            @setRuntimeSafety(std.debug.runtime_safety);
            if (scene.init(b)) {
                const sc = &scene;
                if (b.hold.leashed.drag == .on) {
                    bumped = playDrag(sc, drag);
                    chickensTurn(sc);
                }
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
                // Only a slot seen at the start or laid since can have a
                // line, so only those are walked, in slot order.
                var slots = sc.poop_start;
                slots.setUnion(sc.poop_laid);
                var it = slots.iterator(.{});
                while (it.next()) |n| {
                    const at = b.poops[n];
                    const was_seen = sc.poop_start.isSet(n);
                    if (b.poop_known[n] == .present) {
                        if (!sc.poop_laid.isSet(n)) continue;
                        const was = if (was_seen) sc.poop_was[n] else at;
                        if (!was_seen or at.x != was.x or at.y != was.y) out.push(.{ .poop = .{ .n = @intCast(n), .at = at } });
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
/// critter or poop the leashed dog bumped, if it did (the rest of the
/// drag is then dropped).
fn playDrag(sc: *Scene, drag: []const Disp) ?Bumped {
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

/// **ONE PIXEL-TICK** (decision 30): the leashed dog takes the step,
/// stopping just short of pressing into anyone. Stopped by a chicken, it
/// shoves it with the rest of the step; stopped by a poop, or by a chicken
/// it can't shove, it slides the step's size sideways, away from it, and
/// it bumps only when the slide fails too. A dog or a cow it bumps at
/// once. Then, if it moved, the walk, and the poops that came due.
fn dragStep(sc: *Scene, axis: Axis, inc: i32) ?Bumped {
    if (inc == 0) return null;
    const from = sc.pos(0);
    const r = sweep(sc, axis, inc);
    if (r.by != 0) sc.put(0, moved(from, axis, r.by));
    var bumped: ?Bumped = null;
    if (r.blocker) |blocker| {
        if (!goAround(sc, axis, inc - r.by, mag(inc), blocker)) bumped = blocker;
    }
    sc.step = delta(from, sc.pos(0));
    if (sc.step.x != 0 or sc.step.y != 0) {
        walk(sc, @intCast(measure(sc.step)));
        layDue(sc);
    }
    if (builtin.is_test) std.debug.assert(sc.bucketsHold());
    return bumped;
}

/// The leashed dog, stopped by `blocker` with `rest` of its step along
/// `axis` to go: a shove of a chicken, else the slide `size` across;
/// whether either went.
fn goAround(sc: *Scene, axis: Axis, rest: i32, size: i32, blocker: Bumped) bool {
    const at: Point = switch (blocker) {
        .critter => |c| at: {
            if (c.kind != .chicken) return false;
            if (stepWhole(sc, 0, onAxis(axis, rest)).why == .none) return true;
            break :at sc.board.at(c);
        },
        .poop => |n| sc.board.poops[n],
    };
    const off = on(delta(sc.pos(0), at), across(axis));
    return stepWhole(sc, 0, onAxis(across(axis), if (off > 0) -size else size)).why == .none;
}

/// A vector `v` long along `axis`.
fn onAxis(axis: Axis, v: i32) Point {
    return switch (axis) {
        .x => .{ .x = v, .y = 0 },
        .y => .{ .x = 0, .y = v },
    };
}

/// **THE WALK** (decisions 20-22, 31): out from the leashed dog (seen
/// index 0), shortest link first, dogs and cows only (a chicken takes its
/// turn after the drag, `chickensTurn`). The leashed dog lines up its
/// 3 nearest (roc/Walk.roc's `walk_fan`), each waiting keyed by its distance from the critter
/// that lined it up; the walk visits the least key (ties to the lower
/// rank), which steps (a dog at most `most` and a cow half, by its wish
/// from the critters in motion, going around a poop or a chicken in its
/// way), and lines up its own 3 nearest not yet
/// visited (a critter already waiting takes the nearer key). At most
/// `walk_most` critters; one the walk doesn't reach stays put. On the way
/// it finds the herd's deepest dog, who poops.
///
/// **WALKED IN ROC** (roc/Walk.roc, through roc_physics.zig): this lends
/// it the seen critters (where each stands and its cell, what it is) and
/// the cells' sets of them, the poops by tile, and room for its working
/// lists; Roc moves the critters in place and hands the lists back, and
/// this puts each critter it moved where it left it, and takes the visit
/// order and the pooper. Neither side allocates.
fn walk(sc: *Scene, most: i32) void {
    const w = &sc.roc_walk;
    if (sc.poops_changed) sc.lendPoops();
    w.crits.len = 0;
    w.cellsClear();
    for (sc.list(), sc.at[0..sc.len], 0..) |o, p, j| {
        w.cellPut(sc.seen_cell[j], j);
        w.crits.push(.{
            .x = p.x,
            .y = p.y,
            .cell = sc.seen_cell[j],
            .half = o.half,
            .kind = @intFromEnum(o.who.kind),
            .kin = kinOf(o.who) orelse roc.no_kin,
            .key = if (j == 0) roc.visited else roc.not_lined_up,
        });
    }
    const r = w.run(most);
    // The leashed dog took its step before the walk, which never moves it.
    for (w.crits.slice()[1..], 1..) |c, j| {
        if (c.x != sc.at[j].x or c.y != sc.at[j].y) sc.put(j, .{ .x = c.x, .y = c.y });
    }
    const moving = w.moving.slice();
    sc.walk_len = moving.len - 1;
    for (moving[1..], 0..) |j, k| sc.walk[k] = @intCast(critterIndex(sc.seen[j].who));
    sc.pooper = r.pooper;
    sc.pooper_anchor = if (r.anchor < 0) null else @intCast(r.anchor);
}

/// `pace` of `v`, rounded toward zero; known at compile time, so a share of
/// one is `v` itself and a half is `@divTrunc(v, 2)`.
inline fn share(comptime pace: rules.Share, v: anytype) @TypeOf(v) {
    if (comptime pace.num == pace.den) return v;
    return @divTrunc(v * pace.num, pace.den);
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

/// Why a step was vetoed: nothing (it went), a critter it may
/// not press (or a chicken, `chicken`: one it can't shove), or a poop; and
/// for the sidestep, where the critter that was blocked stood, and its
/// blocker.
pub const Veto = struct {
    why: Why = .none,
    at: Point = .{ .x = 0, .y = 0 },
    blocker: Point = .{ .x = 0, .y = 0 },

    pub const Why = enum { none, critter, chicken, poop };
};

/// **THE VETO, THE NUDGE AND THE SHOVE** (decisions 25, 30): seen critter
/// `i` takes `step` whole, or not at all.
/// - **The nudge:** where its square there would overlap kin (a cow a cow,
///   a dog a dog of its breed; the leashed dog has none), they take the
///   same step with it, and whoever they would overlap is nudged in turn,
///   up to `nudge_most` in all.
/// - **The shove:** a chicken a dog or cow of the group would overlap is
///   knocked by the step plus as much again sideways, away from that
///   critter's centre line (`shoveAside`), up to `nudge_most` chickens.
///   Each must land clear of everyone and every poop: of every
///   critter that stays put, every one the step moves where it lands, and
///   every other chicken shoved. A chicken shoves nobody.
/// - **The veto,** for every one of them, if any would overlap a critter
///   not kin and not a chicken it shoves, or stand on a poop (for a chicken's
///   own step only the newest, which isn't ripe).
/// All is checked before anyone moves. The group moves by one vector, so
/// its members keep clear of each other; no two critters overlap, by
/// induction.
fn stepWhole(sc: *Scene, i: usize, step: Point) Veto {
    if (step.x == 0 and step.y == 0) return .{};
    var group: [nudge_most]usize = undefined;
    group[0] = i;
    var n: usize = 1;
    var shoved: [nudge_most]usize = undefined;
    var by: [nudge_most]usize = undefined;
    var ns: usize = 0;
    var in_move: std.StaticBitSet(critter_count) = .initEmpty();
    in_move.set(i);
    const mover = sc.seen[i].who;
    const breed = if (i == 0) null else kinOf(mover);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const g = group[k];
        const from = sc.pos(g);
        const to = plus(from, step);
        const h = sc.seen[g].half;
        if (poopUnder(sc, to, h, if (mover.kind == .chicken) .eats_ripe else .eats_none)) |q| return .{ .why = .poop, .at = from, .blocker = q };
        var near = sc.critters(to, h + cow_half);
        var it = near.iterator(.{});
        while (it.next()) |j| {
            const o = sc.seen[j];
            if (in_move.isSet(j) or !squaresOverlap(to, h, sc.pos(j), o.half)) continue;
            if (o.who.kind == .chicken) {
                if (mover.kind == .chicken or ns == nudge_most) return .{ .why = .chicken, .at = from, .blocker = sc.pos(j) };
                shoved[ns] = j;
                by[ns] = g;
                ns += 1;
                in_move.set(j);
                continue;
            }
            if (j == 0 or breed == null or kinOf(o.who) != breed or n == nudge_most) return .{ .why = .critter, .at = from, .blocker = sc.pos(j) };
            group[n] = j;
            n += 1;
            in_move.set(j);
        }
    }
    var lands: [nudge_most]Point = undefined;
    for (shoved[0..ns], by[0..ns], 0..) |c, g, m| {
        const p = sc.pos(c);
        const land = wrapped(plus(plus(p, step), shoveAside(step, delta(sc.pos(g), p))));
        lands[m] = land;
        const cannot: Veto = .{ .why = .chicken, .at = sc.pos(g), .blocker = p };
        if (poopUnder(sc, land, chicken_half, .eats_none) != null) return cannot;
        var near = sc.critters(land, chicken_half + cow_half);
        var it = near.iterator(.{});
        while (it.next()) |j| {
            if (!in_move.isSet(j) and squaresOverlap(land, chicken_half, sc.pos(j), sc.seen[j].half)) return cannot;
        }
        for (group[0..n]) |o| if (squaresOverlap(land, chicken_half, plus(sc.pos(o), step), sc.seen[o].half)) return cannot;
        for (lands[0..m]) |o| if (squaresOverlap(land, chicken_half, o, chicken_half)) return cannot;
    }
    for (group[0..n]) |g| sc.put(g, plus(sc.pos(g), step));
    for (shoved[0..ns], lands[0..ns]) |c, land| sc.put(c, land);
    return .{};
}

fn plus(p: Point, v: Point) Point {
    return .{ .x = p.x + v.x, .y = p.y + v.y };
}

/// **A SHOVE'S SIDEWAYS PART** (decision 30): `step` turned a right angle,
/// toward the side of the stepper's centre line the chicken is on (`d`,
/// from the stepper to it); a chicken on the line goes to whichever side
/// is south, or east for a step north or south.
pub fn shoveAside(step: Point, d: Point) Point {
    const left: Point = .{ .x = -step.y, .y = step.x };
    const right: Point = .{ .x = step.y, .y = -step.x };
    const side = @as(i64, step.x) * d.y - @as(i64, step.y) * d.x;
    if (side > 0) return left;
    if (side < 0) return right;
    return if (left.y > 0 or (left.y == 0 and left.x > 0)) left else right;
}

/// **THE SIDESTEP** (decision 30): critter `i` takes `step` (`stepWhole`);
/// vetoed by a poop, or by a chicken it can't shove, it tries once more
/// with `sidestep`'s step.
fn stepAround(sc: *Scene, i: usize, step: Point) void {
    const v = stepWhole(sc, i, step);
    if (sidestep(v, step)) |again| _ = stepWhole(sc, i, again);
}

/// The step that goes around a veto's poop or chicken: `step` with the
/// axis on which the blocker is farther off zeroed (a tie zeroes x), and
/// on the other its own part kept, or, that part zero, the step's whole
/// size away from the blocker (on the line, +). Null for any other veto.
fn sidestep(v: Veto, step: Point) ?Point {
    if (v.why != .poop and v.why != .chicken) return null;
    const d = delta(v.at, v.blocker);
    const size: i32 = @intCast(measure(step));
    if (mag(d.x) >= mag(d.y)) return .{ .x = 0, .y = if (step.y != 0) step.y else if (d.y > 0) -size else size };
    return .{ .x = if (step.x != 0) step.x else if (d.x > 0) -size else size, .y = 0 };
}

/// **RIPE** (decision 31): every poop but the park's newest, the one in
/// slot `laid` − 1 (mod `poop_count`; with no poop yet, an empty slot).
/// A chicken eats only ripe poop, and the newest blocks it.
pub fn ripe(laid: u32, n: u16) bool {
    return n != (laid -% 1) % poop_count;
}

/// The place of a poop the physics sees that a square of half `h` at `p`
/// overlaps (poop is an obstacle to dogs and cows), if any, the lowest
/// slot's; for a chicken's step (`only_newest`), only the newest counts.
fn poopUnder(sc: *const Scene, p: Point, h: i32, mover: Eater) ?Point {
    var poops = sc.near(p, h + poop_half);
    var under: ?u16 = null;
    while (poops.next()) |n| {
        if (mover == .eats_ripe and ripe(sc.board.laid, n)) continue;
        if (squaresOverlap(p, h, sc.board.poops[n], poop_half) and (under == null or n < under.?)) under = n;
    }
    return if (under) |n| sc.board.poops[n] else null;
}

/// Whether a step's mover eats what it steps onto: a chicken walks onto
/// ripe poop (and eats it), so only the newest blocks it.
const Eater = enum { eats_ripe, eats_none };

fn onPoop(sc: *const Scene, p: Point, h: i32) bool {
    return poopUnder(sc, p, h, .eats_none) != null;
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

/// **THE HERD POOPS** (decision 29), once for each `poop_every` the
/// leashed dog's step crossed, after the pixel-tick's walk: its deepest
/// dog (`walk`), `poop_back` behind itself, away from its anchor (the
/// leashed dog, with none: back along its step).
fn layDue(sc: *Scene) void {
    while (sc.poop_due > 0) : (sc.poop_due -= 1) {
        const p = sc.pos(sc.pooper);
        const ahead = if (sc.pooper_anchor) |a| sc.pos(a) else plus(p, sc.step);
        layPoop(sc, plus(p, away(ahead, p, poop_back)));
    }
}

/// A poop into slot `laid` mod `poop_count`, at `spot` if it fits there
/// (`poopFits`), else at the nearest spot that does on rings `poop_grid`
/// apart around it, out to `poop_reach`, each walked clockwise from its
/// north-west corner. With no such spot, no poop.
fn layPoop(sc: *Scene, spot: Point) void {
    const slot: u16 = @intCast(sc.board.laid % poop_count);
    if (tryPoop(sc, slot, spot, 0, 0)) return;
    var r: i32 = poop_grid;
    while (r <= poop_reach) : (r += poop_grid) {
        const side = @divExact(2 * r, poop_grid);
        var k: i32 = 0;
        while (k < 4 * side) : (k += 1) {
            const off = @mod(k, side) * poop_grid;
            const d: Point = switch (@divFloor(k, side)) {
                0 => .{ .x = -r + off, .y = -r },
                1 => .{ .x = r, .y = -r + off },
                2 => .{ .x = r - off, .y = r },
                else => .{ .x = -r, .y = r - off },
            };
            if (tryPoop(sc, slot, spot, d.x, d.y)) return;
        }
    }
}

fn tryPoop(sc: *Scene, slot: u16, p: Point, dx: i32, dy: i32) bool {
    const q = wrapped(.{ .x = p.x + dx, .y = p.y + dy });
    if (!poopFits(sc, q, slot)) return false;
    placePoop(sc, slot, q);
    return true;
}

/// Whether a poop at `q` overlaps no critter and no other poop the physics
/// sees.
fn poopFits(sc: *const Scene, q: Point, slot: u16) bool {
    var near = sc.critters(q, poop_half + cow_half);
    var it = near.iterator(.{});
    while (it.next()) |j| {
        if (squaresOverlap(q, poop_half, sc.pos(j), sc.seen[j].half)) return false;
    }
    var poops = sc.near(q, 2 * poop_half);
    while (poops.next()) |n| {
        if (n == slot) continue;
        if (squaresOverlap(q, poop_half, sc.board.poops[n], poop_half)) return false;
    }
    return true;
}

fn placePoop(sc: *Scene, slot: u16, q: Point) void {
    const listed = sc.poop_listed.isSet(slot);
    if (sc.poop_start.isSet(slot) and !sc.poop_laid.isSet(slot)) sc.poop_was[slot] = sc.board.poops[slot];
    if (listed) sc.unlink(slot);
    sc.board.poops[slot] = q;
    sc.board.poop_known[slot] = .present;
    sc.board.laid +%= 1;
    sc.poop_laid.set(slot);
    if (listed) sc.link(slot) else sc.listPoop(slot);
}

/// **THE CHICKENS' TURN** (decision 31): once a tick, after the drag, and
/// only if the leashed dog's net move over it is more than nothing. Each
/// chicken the physics sees, by number, steps at most half that move and
/// at most `chicken_step`:
/// - toward the nearest ripe poop it sees within `chicken_sight` (ties to
///   the lower slot), going around what's in its way (`stepAround`);
/// - with none, toward its home (`layout.chickenHome`) when more than
///   `home_band` from it, whole or not at all: blocked, it waits;
/// - else it stays put, and writes no line.
/// Then it eats every ripe poop its square overlaps. It heeds no critter
/// and plans nothing: three chickens chase the one poop till it's gone.
fn chickensTurn(sc: *Scene) void {
    const net = measure(delta(sc.seen[0].start, sc.pos(0)));
    if (net == 0) return;
    const most: i32 = @intCast(@min(share(rules.rules.chickens.pace, net), chicken_step));
    for (sc.list(), 0..) |o, i| {
        if (o.who.kind != .chicken) continue;
        const p = sc.pos(i);
        if (nearestRipe(sc, p)) |q| {
            stepAround(sc, i, stepAtMost(delta(p, q), most));
        } else {
            const home = delta(p, layout.chickenHome(o.who.n));
            if (measure(home) <= home_band) continue;
            _ = stepWhole(sc, i, stepAtMost(home, most));
        }
        if (builtin.is_test) std.debug.assert(sc.bucketsHold());
        const now = sc.pos(i);
        var poops = sc.near(now, chicken_half + poop_half);
        while (poops.next()) |n| {
            if (ripe(sc.board.laid, n) and squaresOverlap(now, chicken_half, sc.board.poops[n], poop_half)) sc.eat(n);
        }
    }
}

/// The nearest ripe poop the physics sees within `chicken_sight` of `p`,
/// ties to the lower slot.
fn nearestRipe(sc: *const Scene, p: Point) ?Point {
    var best: ?u16 = null;
    var best_d: i64 = 0;
    var poops = sc.near(p, chicken_sight);
    while (poops.next()) |n| {
        if (!ripe(sc.board.laid, n)) continue;
        const d = measure(delta(p, sc.board.poops[n]));
        if (d > chicken_sight) continue;
        if (best == null or d < best_d or (d == best_d and n < best.?)) {
            best = n;
            best_d = d;
        }
    }
    return if (best) |n| sc.board.poops[n] else null;
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
/// first critter then the second, and every critter on a poop (counted,
/// not listed): the invariant the server checks after every tick (a
/// finding, not a refutation).
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
    return n + onPoops(&sc);
}

/// How many seen critters overlap a poop the physics sees (none should: no
/// step lands on one, a chicken's own steps only on a ripe one, which it
/// eats there and then).
pub fn onPoops(sc: *const Scene) usize {
    var n: usize = 0;
    for (sc.list(), 0..) |a, i| {
        if (onPoop(sc, sc.pos(i), a.half)) n += 1;
    }
    return n;
}

test {
    _ = @import("physics_test.zig");
    _ = @import("physics_trails_test.zig");
    _ = @import("physics_golden_test.zig");
}
