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
const walk_reference = @import("walk_reference.zig");
const walk_judge = @import("physics_options").walk_judge;

/// **THE KINDS OF CRITTER** are the world's (world.zon's `kinds`, which
/// roc/World.roc says): the physics names none. Kind k is the kth there,
/// its name the enum's; its critters are numbered on their own, from 0.
pub const kinds = world_file.kinds;
pub const kind_count = kinds.len;
pub const Kind = @Enum(u8, .exhaustive, &kind_names, &std.simd.iota(u8, kind_count));
const kind_names = names: {
    var n: [kind_count][]const u8 = undefined;
    for (kinds, &n) |k, *name| name.* = k.name;
    const all = n;
    break :names all;
};
/// How many critters of each kind, and where each kind's begin among all
/// (`critterIndex`): the kinds in their order, each its critters in theirs.
pub const counts: [kind_count]u16 = c: {
    var out: [kind_count]u16 = undefined;
    for (kinds, &out) |k, *n| n.* = k.spots.len;
    break :c out;
};
pub const bases: [kind_count]u16 = b: {
    var out: [kind_count]u16 = undefined;
    var sum: u16 = 0;
    for (counts, &out) |n, *base| {
        base.* = sum;
        sum += n;
    }
    break :b out;
};
pub const critter_count: comptime_int = bases[kind_count - 1] + counts[kind_count - 1];
pub inline fn countOf(k: Kind) u16 {
    return counts[@intFromEnum(k)];
}
/// The kind a human leashes: the world's one with `leash`.
pub const leashed_kind: Kind = l: {
    var found: ?Kind = null;
    for (kinds, 0..) |k, i| if (k.leash) {
        if (found != null) @compileError("world.zon: two kinds leash");
        found = @enumFromInt(i);
    };
    break :l found orelse @compileError("world.zon: no kind leashes");
};
/// The kinds by rank (`rank`, lower first): the order the physics sees
/// them in and lists them by.
pub const by_rank: [kind_count]Kind = r: {
    var out: [kind_count]Kind = undefined;
    var n: usize = 0;
    for (0..kind_count) |rk| for (kinds, 0..) |k, i| if (k.rank == rk) {
        out[n] = @enumFromInt(i);
        n += 1;
    };
    if (n != kind_count) @compileError("world.zon: the kinds' ranks are not 0 .. kinds - 1, each once");
    break :r out;
};
/// Every critter, the kinds by rank, each its critters in theirs: the order
/// the formats list them in (the leashed critter aside, which some put
/// first).
pub const ranked: [critter_count]Critter = r: {
    var out: [critter_count]Critter = undefined;
    var n: usize = 0;
    for (by_rank) |k| for (0..counts[@intFromEnum(k)]) |i| {
        out[n] = .{ .kind = k, .n = i };
        n += 1;
    };
    break :r out;
};
/// The cascade's rank of each kind's critter 0, the leashed critter aside.
const rank_base: [kind_count]u32 = r: {
    var out: [kind_count]u32 = undefined;
    var sum: u32 = 1;
    for (by_rank) |k| {
        out[@intFromEnum(k)] = sum;
        sum += counts[@intFromEnum(k)];
    }
    break :r out;
};

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
pub inline fn pxOf(k: Kind) i32 {
    return kinds[@intFromEnum(k)].px;
}
pub inline fn halfOf(k: Kind) i32 {
    return halves[@intFromEnum(k)];
}
const halves: [kind_count]i32 = h: {
    var out: [kind_count]i32 = undefined;
    for (kinds, &out) |k, *half| half.* = px(k.px / 2);
    break :h out;
};
/// The largest critter's half side: how far a square can reach into a
/// neighbour's cells.
pub const biggest_half: i32 = b: {
    var most: i32 = 0;
    for (halves) |h| most = @max(most, h);
    break :b most;
};
/// A wish shorter than this is no step.
pub const dead_zone: i32 = px(rules.rules.limits.dead_zone);
/// **THE RULES' DISTANCES**, by the names the docs and tests use: the
/// rules' (rules.zig, which roc/Rules.roc says), which the wish applies.
/// A dog keeps `wary` from a moving dog of another breed; a cow from any
/// moving dog.
pub const wary: i32 = px(rules.rules.wary);
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
// At most one poop comes due a pixel-tick: the leashed dog's moves in one
// (the sweep, then at most one step round a bump) are each at most a step.
comptime {
    std.debug.assert(poop_every > 2 * step_most);
}
pub const poop_px: comptime_int = world_file.poop_px;
pub const poop_half: i32 = px(poop_px / 2);
pub const poop_count: comptime_int = rules.rules.poop.slots;
comptime {
    // `laid` counts in 32 bits and takes the slots in turn: its wrap keeps
    // their order only if the slots divide 2^32.
    if (!std.math.isPowerOfTwo(poop_count)) @compileError("rules.zon: the poop slots must be a power of two");
}
// Where a poop lands (`poop_back` behind its dog, else on rings
// `poop_grid` apart out to `poop_reach`) is roc/Walk.roc's `lay`, after the
// pixel-tick's walk; Zig places it (`placePoop`).

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
/// most it.
pub inline fn lengthOf(k: i64) i64 {
    return k;
}

/// A critter, by kind and number.
pub const Critter = struct {
    kind: Kind,
    n: u16,

    pub fn of(kind: Kind, n: u16) Critter {
        return .{ .kind = kind, .n = n };
    }
    pub fn half(self: Critter) i32 {
        return halfOf(self.kind);
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
    /// Every critter's point and whether the board has it, by
    /// `critterIndex`.
    points: [critter_count]Point,
    known_at: [critter_count]Known,
    /// How far each critter of the leashed kind has walked, in 256ths (its
    /// steps' larger axes): its poops so far are this over `poop_every`.
    walked: [counts[@intFromEnum(leashed_kind)]]u32,
    /// The poop slots, and how many poops the park has laid since its
    /// layout: the next takes slot `laid` mod `poop_count`.
    poops: [poop_count]Point,
    poop_known: [poop_count]Known,
    laid: u32 = 0,
    hold: Hold = .none,

    /// No critters at all.
    pub fn empty() Board {
        return .{
            .points = @splat(.{ .x = 0, .y = 0 }),
            .known_at = @splat(.absent),
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
        return self.points[critterIndex(c)];
    }

    pub fn put(self: *Board, c: Critter, p: Point) void {
        self.points[critterIndex(c)] = p;
    }

    pub fn known(self: *const Board, c: Critter) Known {
        return self.known_at[critterIndex(c)];
    }

    /// Places a critter and marks it present.
    pub fn place(self: *Board, c: Critter, p: Point) void {
        self.put(c, p);
        self.known_at[critterIndex(c)] = .present;
    }

    /// Kind `k`'s points, critter n at n; and whether the board has each
    /// (`ofMut` and `knownOfMut` to change them).
    pub fn of(self: *const Board, k: Kind) []const Point {
        return self.points[bases[@intFromEnum(k)]..][0..countOf(k)];
    }
    pub fn knownOf(self: *const Board, k: Kind) []const Known {
        return self.known_at[bases[@intFromEnum(k)]..][0..countOf(k)];
    }
    pub fn ofMut(self: *Board, k: Kind) []Point {
        return self.points[bases[@intFromEnum(k)]..][0..countOf(k)];
    }
    pub fn knownOfMut(self: *Board, k: Kind) []Known {
        return self.known_at[bases[@intFromEnum(k)]..][0..countOf(k)];
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
    if (c.kind == leashed_kind and leashed != null and leashed.? == c.n) return 0;
    return rank_base[@intFromEnum(c.kind)] + c.n;
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
            if (d >= countOf(leashed_kind) or b.known(.of(leashed_kind, d)) != .present) return .leash_no_such_dog;
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
    return bases[@intFromEnum(c.kind)] + @as(usize, c.n);
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
    /// **THE SEEN CRITTERS BY CELL ARE ROC'S** (roc/Grid.roc): lent once
    /// a tick, before its first pixel-tick (`lendCrits`), with the crits;
    /// Roc settles them into its grid (Walk.roc's `settle`) and keeps both
    /// through every walk and forage turn after. The physics never reads
    /// the grid but in the tests' check (`bucketsHold`).
    roc_settled: bool = false,

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
        const span = TileSpan.of(region(b.at(.of(leashed_kind, l))));
        s.span = span;
        s.add(.of(leashed_kind, l), l);
        for (by_rank) |k| for (0..countOf(k)) |i| {
            if (k != leashed_kind or i != l) s.consider(.of(k, @intCast(i)), span, l);
        };
        s.roc_settled = false;
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

    /// **THE BUCKETS HOLD** (the tests' check of Roc's grid): every seen
    /// critter in the cell of Roc's grid its point stands in, by the
    /// physics' own `cellOf` from where the physics put it, its crit says
    /// so, and no bit else set (a move that forgot its bit would let a
    /// square miss whoever it overlaps).
    pub fn bucketsHold(s: *Scene) bool {
        const w = &s.roc_walk;
        const words = @TypeOf(w.*).words;
        if (!s.roc_settled) return true;
        var bits: usize = 0;
        for (w.cells.slice()) |word| bits += @popCount(word);
        if (bits != s.len or w.crits.len != s.len) return false;
        for (0..s.len) |j| {
            const c = s.cellOf(s.at[j]);
            if (c != w.crits.items[j].cell) return false;
            if (w.cells.items[@as(usize, c) * words + j / 64] & (@as(u64, 1) << @intCast(j % 64)) == 0) return false;
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

    /// Seen critter `i` to `to`, wrapped into the world.
    pub fn put(s: *Scene, i: usize, to: Point) void {
        const p = wrapped(to);
        s.at[i] = p;
        s.board.put(s.seen[i].who, p);
    }

    /// The leashed dog (seen index 0) walked `len` more, each of its moves
    /// by its larger axis: how many `poop_every` it crossed, the poops due
    /// (roc/Walk.roc's `poops_due` counts them alike, and lays them).
    pub fn walkOn(s: *Scene, len: u32) u32 {
        const n = s.seen[0].who.n;
        const before = s.board.walked[n];
        const after = before +| len;
        s.board.walked[n] = after;
        return after / poop_every - before / poop_every;
    }
};

/// The most tiles a span is wide: the region's side, and one more for a
/// region that doesn't sit on the tiles' lines.
pub const span_tiles = tiles.world_tiles;

/// The end of a tile's list of poops.
const no_poop: u16 = std.math.maxInt(u16);


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

/// **ONE PIXEL-TICK** (decision 30), in Roc (roc/Walk.roc's `pixel_tick`,
/// through `walk`): the leashed dog takes the step, stopping just short of
/// pressing into anyone; stopped by a chicken it shoves it, by a poop or a
/// chicken it can't shove it slides sideways, and it bumps when that fails
/// too, or a dog or a cow at once. Then, if it moved, the walk, and where
/// the poop that came due lands (`lay`), which is placed here.
fn dragStep(sc: *Scene, axis: Axis, inc: i32) ?Bumped {
    if (inc == 0) return null;
    const r = walk(sc, axis, inc);
    const due = sc.walkOn(r.walked);
    // A pixel-tick's walk is under 2 px against a poop each 700 px; and a
    // walk that came to no step is no move (the poop due waits for none).
    std.debug.assert(due <= 1);
    std.debug.assert(due == 0 or r.step.x != 0 or r.step.y != 0);
    if (r.poop) |p| {
        std.debug.assert(due == 1);
        placePoop(sc, p.slot, p.at);
    }
    if (builtin.is_test) std.debug.assert(sc.bucketsHold());
    return r.bumped;
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
/// **WALKED IN ROC** (roc/Walk.roc, through roc_physics.zig), with the
/// leashed dog's step before it: this lends it the seen critters (where
/// each stands and its cell, what it is) and the cells' sets of them, the
/// poops by tile, and room for its working lists; Roc moves the critters
/// in place and hands the lists back, and this puts each critter it moved
/// where it left it, and, if the leashed dog moved, takes the walk's visit
/// order and the poop it laid, if one came due. Neither side allocates.
fn walk(sc: *Scene, axis: Axis, inc: i32) Stepped {
    const w = &sc.roc_walk;
    const before = sc.board.walked[sc.seen[0].who.n];
    lendCrits(sc);
    const axis_n: i32 = switch (axis) {
        .x => 0,
        .y => 1,
    };
    // **THE WALK'S JUDGE** (-Dwalk-judge, walk_reference.zig): the same
    // pixel-tick in plain Zig, compared field by field.
    var judge: if (walk_judge) walk_reference.Judge(critter_count, walk_most + 1) else void = undefined;
    if (walk_judge) judge.before(w.crits.slice(), w.from.slice(), w.poops.slice(), span_cells, axis_n, inc, before, sc.board.laid);
    const r = w.run(axis_n, inc, before, sc.board.laid);
    if (walk_judge) judge.after(w.crits.slice(), w.cells.slice(), @TypeOf(w.*).words, w.moving.slice(), r);
    takeCrits(sc);
    const step: Point = .{ .x = r.step_x, .y = r.step_y };
    if (step.x != 0 or step.y != 0) {
        const moving = w.moving.slice();
        sc.walk_len = moving.len - 1;
        for (moving[1..], 0..) |j, k| sc.walk[k] = @intCast(critterIndex(sc.seen[j].who));
    }
    const poop: ?Laid = if (r.poop_slot < 0) null else .{ .slot = @intCast(r.poop_slot), .at = .{ .x = r.poop_x, .y = r.poop_y } };
    return .{ .step = step, .walked = @intCast(r.walked), .poop = poop, .bumped = switch (r.bump_kind) {
        roc.bump_none => null,
        roc.bump_critter => .{ .critter = sc.seen[@intCast(r.bump_at)].who },
        roc.bump_poop => .{ .poop = @intCast(r.bump_at) },
        else => @panic("roc: a bump of no kind"),
    } };
}

/// The seen critters and the poops for Roc (roc_physics.zig's `Walk`):
/// the poops by tile, again if they changed; and once a tick, before its
/// first pixel-tick, each critter, where it stands, what it is and its
/// kin, with the cells all clear, for Roc to settle into its grid (its
/// cell and key are Roc's). Roc keeps both from then on: only Roc moves a
/// critter within a tick.
fn lendCrits(sc: *Scene) void {
    const w = &sc.roc_walk;
    if (sc.poops_changed) sc.lendPoops();
    if (sc.roc_settled) {
        for (w.crits.items[0..w.crits.len], 0..) |*c, j| c.key = if (j == 0) roc.visited else roc.not_lined_up;
        return;
    }
    w.crits.len = 0;
    w.cellsClear();
    for (sc.list(), sc.at[0..sc.len]) |o, p| {
        w.crits.push(.{
            .x = p.x,
            .y = p.y,
            .cell = 0,
            .half = o.half,
            .kind = @intFromEnum(o.who.kind),
            .kin = kinOf(o.who) orelse roc.no_kin,
            .key = roc.not_lined_up,
        });
    }
    w.settle();
    sc.roc_settled = true;
}

/// Each critter Roc moved, put where it left it.
fn takeCrits(sc: *Scene) void {
    for (sc.roc_walk.crits.slice(), 0..) |c, j| {
        if (c.x != sc.at[j].x or c.y != sc.at[j].y) sc.put(j, .{ .x = c.x, .y = c.y });
    }
}

/// What a pixel-tick did to the leashed dog: its net step, how far it
/// walked (each of its moves by its larger axis), the poop it laid if one
/// came due, and what it bumped.
const Stepped = struct { step: Point, walked: u32, poop: ?Laid, bumped: ?Bumped };
/// A poop the walk laid: its slot, and where (roc/Walk.roc's `Laid`).
const Laid = struct { slot: u16, at: Point };

/// **RIPE** (decision 31): every poop but the park's newest, the one in
/// slot `laid` − 1 (mod `poop_count`; with no poop yet, an empty slot).
/// A chicken eats only ripe poop, and the newest blocks it.
pub fn ripe(laid: u32, n: u16) bool {
    return n != (laid -% 1) % poop_count;
}

/// Whether a square of half `h` at `p` overlaps a poop the physics sees
/// (the invariant's check, `onPoops`).
fn onPoop(sc: *const Scene, p: Point, h: i32) bool {
    var poops = sc.near(p, h + poop_half);
    while (poops.next()) |m| {
        if (squaresOverlap(p, h, sc.board.poops[m], poop_half)) return true;
    }
    return false;
}

/// Who nudges whom, by the kind's `kin` (world.zon): a breed kind's
/// critters, each breed one kin; a herd kind's, all one; nobody.
fn kinOf(c: Critter) ?u8 {
    return switch (kinds[@intFromEnum(c.kind)].kin) {
        .breed => @intCast(c.n % breeds),
        .herd => herd_kin[@intFromEnum(c.kind)],
        .none => null,
    };
}

/// A herd kind's kin number: after the breeds, one for each herd kind in
/// the kinds' order.
const herd_kin: [kind_count]u8 = h: {
    var out: [kind_count]u8 = @splat(0);
    var next: u8 = breeds;
    for (kinds, &out) |k, *n| if (k.kin == .herd) {
        n.* = next;
        next += 1;
    };
    break :h out;
};

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
/// only if the leashed dog's net move over it is more than nothing, in Roc
/// (roc/Walk.roc's `forage_turn`): each critter whose kind forages (today
/// the chickens, roc/Wish.roc's `forage_of`), by seen index, steps toward
/// the nearest ripe poop it sees, or home (`layout.home`, lent by
/// seen index), and eats the ripe poop it then stands on, which is taken
/// off the park here. The buckets are checked after the whole turn (they
/// were after each chicken's step, when the turn was Zig's).
fn chickensTurn(sc: *Scene) void {
    const net = measure(delta(sc.seen[0].start, sc.pos(0)));
    if (net == 0) return;
    const w = &sc.roc_walk;
    lendCrits(sc);
    w.homes.len = 0;
    for (sc.list()) |o| {
        const h = layout.home(o.who);
        w.homes.push(.{ .x = h.x, .y = h.y });
    }
    const eaten = w.forage(@intCast(net), sc.board.laid);
    takeCrits(sc);
    for (eaten) |n| sc.eat(n);
    if (builtin.is_test) std.debug.assert(sc.bucketsHold());
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
