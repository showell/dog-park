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

/// The squares, in whole pixels, as the page draws them (park.js's dog_px
/// and cow_px). Each critter is its square, centred on its point.
pub const dog_px = 40;
pub const cow_px = 60;
pub const dog_half: i32 = px(dog_px / 2);
pub const cow_half: i32 = px(cow_px / 2);
/// A dog's own step: 7.5 px a second.
pub const speed: i32 = perTick(px(15) / 2);
pub const dead_zone: i32 = px(1);
pub const awake_reach: i32 = px(800);
pub const wary: i32 = px(225);
pub const follow: i32 = px(600);
pub const band_inner: i32 = px(60);
pub const band_outer: i32 = px(100);
pub const cow_room: i32 = px(90);
/// The region: the 3000 px square around the leashed dog.
pub const region_reach: i32 = px(1500);
/// A drag's internal steps, the PIXEL-TICKS: at most 1 px. After each, every
/// awake dog takes a step as long as the leashed dog's, at most (Steve,
/// 2026-10-13: the leashed dog's motion speeds up time for the others).
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
/// How far a dog's move along an axis reaches: a cow at most this far ahead
/// on that axis, and at most this far off it, is scared (`scoot`).
pub const scare_box: i32 = px(280);
/// The least gap a cow keeps between the dog's square and its own: half a
/// dog.
pub const clearance: i32 = px(dog_px / 2);
/// A cow's lane: a dog's half, a cow's half and the clearance.
pub const lane: i32 = dog_half + cow_half + clearance;
/// A jump's candidates come from squares within this gap, on both axes.
pub const jump_reach: i32 = px(100);
/// Breeds: dog n has look n mod 4.
pub const breeds = 4;

pub const Tick = u64;

pub const Point = extern struct { x: i32, y: i32 };

/// **THE ONE DIFFERENCE**: from `a` to `b`, per axis. Every centre-to-centre
/// difference in the physics goes through here (decision 14).
pub fn delta(a: Point, b: Point) Point {
    return .{ .x = b.x - a.x, .y = b.y - a.y };
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

/// The integer square root, rounded down: a float's guess, then corrected
/// in integers until r² ≤ v < (r + 1)², so the float only makes it fast.
pub fn isqrt(v: i64) i64 {
    std.debug.assert(v >= 0);
    const u: u64 = @intCast(v);
    var r: u64 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(u))));
    while (r * r > u) r -= 1;
    while ((r + 1) * (r + 1) <= u) r += 1;
    return @intCast(r);
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

/// A closed rectangle, in 256ths.
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

/// The neighbour lists' grid: cells folded onto a square this many a side
/// (folding only adds candidates, each still measured).
const grid_side = 32;

/// The folded cell `(dx, dy)` cells from the one `p` stands in.
fn gridCell(p: Point, side: i32, dx: i32, dy: i32) u16 {
    const cx = @mod(@divFloor(p.x, side) + dx, grid_side);
    const cy = @mod(@divFloor(p.y, side) + dy, grid_side);
    return @intCast(cy * grid_side + cx);
}

/// **THE WISHES' GRID**: every awake critter in a `wish_cell` square, by
/// class (a dog's breed, or a cow), the cells folded onto a square
/// `wish_grid` a side; kept current by `Scene.put`. A wish's sum reads only
/// the cells its reach meets (`wishTotal`). A cost knob only: it changes no
/// result.
pub const wish_cell: i32 = wary;
const wish_grid = 16;
const wish_classes = breeds + 1;
const wish_none: u16 = std.math.maxInt(u16);
/// The anchor's search goes ring by ring to `wish_rings` cells out, where a
/// ring's nearest point is past `follow`.
const wish_rings: i32 = @divFloor(follow, wish_cell) + 1;
comptime {
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
    return @divFloor(v, wish_cell);
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
    region: Rect,
    seen: [critter_count]Seen = undefined,
    /// Where each seen critter is now, kept here beside the board's copy so
    /// the tick's inner loops read one array.
    at: [critter_count]Point = undefined,
    len: usize = 0,
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

    pub const Lists = enum { none, built };

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
        for (s.awakeOnes()) |i| s.wgLink(i, s.wgBucketAt(i, s.at[i]));
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

    fn wgLink(s: *Scene, i: usize, k: u16) void {
        const h = s.wg_head[k];
        s.wg_next[i] = h;
        s.wg_prev[i] = wish_none;
        if (h != wish_none) s.wg_prev[h] = @intCast(i);
        s.wg_head[k] = @intCast(i);
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

    pub fn put(s: *Scene, i: usize, p: Point) void {
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

    /// A jump: seen critter `i` to `p`, flagged as jumped; it and everyone
    /// it overlaps there may overlap.
    pub fn jumpTo(s: *Scene, i: usize, p: Point) void {
        s.put(i, p);
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
        if (s.lists == .built and 2 * s.drift + most <= skin) return;
        const reach = 2 * half_most + skin;
        var n: usize = 0;
        for (0..s.len) |i| s.overlap[i] = .clear;
        // Each critter in a cell `reach` square, the cells folded onto a
        // `grid_side` square; a critter's neighbours are in its cell's 3 × 3.
        var cell_len: [grid_side * grid_side]u16 = @splat(0);
        var cell_of: [critter_count]u16 = undefined;
        for (0..s.len) |i| {
            const c = gridCell(s.pos(i), reach, 0, 0);
            cell_of[i] = c;
            cell_len[c] += 1;
        }
        var cell_from: [grid_side * grid_side + 1]u16 = undefined;
        cell_from[0] = 0;
        for (cell_len, 0..) |l, c| cell_from[c + 1] = cell_from[c] + l;
        var fill: [grid_side * grid_side]u16 = cell_from[0 .. grid_side * grid_side].*;
        var by_cell: [critter_count]u16 = undefined;
        for (0..s.len) |i| {
            by_cell[fill[cell_of[i]]] = @intCast(i);
            fill[cell_of[i]] += 1;
        }
        var cand: [critter_count]u16 = undefined;
        for (0..s.len) |i| {
            s.nb_from[i] = @intCast(n);
            const p = s.pos(i);
            var cand_len: usize = 0;
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    const c = gridCell(p, reach, dx, dy);
                    for (by_cell[cell_from[c]..cell_from[c + 1]]) |j| {
                        cand[cand_len] = j;
                        cand_len += 1;
                    }
                }
            }
            std.sort.insertion(u16, cand[0..cand_len], {}, std.sort.asc(u16));
            for (cand[0..cand_len]) |j16| {
                const j: usize = j16;
                if (j == i) continue;
                s.pair_checks += 1;
                const d = delta(p, s.pos(j));
                if (mag(d.x) >= reach or mag(d.y) >= reach) continue;
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
    out.jumped = .initEmpty();
    out.pair_checks = 0;
    var sc_opt = Scene.of(b);
    if (sc_opt) |*sc| {
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
    if (!under) return;
    var obs: jump.Obstacles = .{};
    for (sc.list(), 0..) |o, j| {
        if (j == i) continue;
        obs.add(Rect.square(sc.pos(j), o.half), 2 * o.rank);
    }
    if (jump.nearestSpot(p, me.half, obs.slice(), sc.region)) |spot| sc.jumpTo(i, spot);
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
        const step = stepAtMost(wishTotal(sc, i), most);
        var at = sc.pos(i);
        for ([_]Axis{ .x, .y }) |axis| {
            const want = inWorld(at, dog_half, axis, on(step, axis));
            if (want == 0) continue;
            const r = sweep(sc, i, axis, want, .everyone);
            at = moved(at, axis, r.by);
            sc.put(i, at);
        }
    }
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
    // Strangers: other breeds above it, within `wary`.
    for (0..breeds) |b| {
        if (b == breed) continue;
        addRoom(sc, &total, i, p, @intCast(b), wary);
    }
    // Every awake cow is above it, within `cow_room`.
    addRoom(sc, &total, i, p, breeds, cow_room);
    if (anchorOf(sc, i, p, breed)) |a| addAnchor(&total, p, sc.pos(a.j), a.d2);
    return total;
}

/// Adds, for each awake critter of class `class` above dog `i` (at `p`)
/// within `reach`, a push away as long as the shortfall.
fn addRoom(sc: *const Scene, total: *Point, i: usize, p: Point, class: u16, reach: i32) void {
    const reach2 = @as(i64, reach) * reach;
    var cy = wishCellOf(p.y - reach);
    while (cy <= wishCellOf(p.y + reach)) : (cy += 1) {
        var cx = wishCellOf(p.x - reach);
        while (cx <= wishCellOf(p.x + reach)) : (cx += 1) {
            var j = sc.wg_head[wishBucket(class, cx, cy)];
            while (j != wish_none) : (j = sc.wg_next[j]) {
                if (j >= i) continue;
                const v = delta(sc.pos(j), p);
                const d2 = len2(v);
                if (d2 > reach2) continue;
                const l = isqrt(d2);
                add(total, awayRooted(v, l, reach - @as(i32, @intCast(l))));
            }
        }
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
    const follow2 = @as(i64, follow) * follow;
    const pcx = wishCellOf(p.x);
    const pcy = wishCellOf(p.y);
    var best: ?Anchor = null;
    var k: i32 = 0;
    while (k <= wish_rings) : (k += 1) {
        if (k > 0) {
            const least = @as(i64, k - 1) * wish_cell;
            if (least * least > follow2) break;
            if (best) |b| if (least * least > b.d2) break;
        }
        var cy = pcy - k;
        while (cy <= pcy + k) : (cy += 1) {
            const edge_row = cy == pcy - k or cy == pcy + k;
            var cx = pcx - k;
            while (cx <= pcx + k) : (cx += if (edge_row or cx == pcx + k) 1 else 2 * k) {
                var j = sc.wg_head[wishBucket(breed, cx, cy)];
                while (j != wish_none) : (j = sc.wg_next[j]) {
                    if (j >= i) continue;
                    const d2 = len2(delta(sc.pos(j), p));
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
    if (anchor_d2 > @as(i64, band_outer) * band_outer) {
        add(total, wishAlong(delta(p, q), @as(i32, @intCast(isqrt(anchor_d2))) - band_outer));
    } else if (anchor_d2 < @as(i64, band_inner) * band_inner) {
        add(total, away(q, p, band_inner - @as(i32, @intCast(isqrt(anchor_d2)))));
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
    return awayRooted(v, isqrt(len2(v)), length);
}

/// `away`, `v` from the other's centre to the critter's and `l` its
/// `isqrt` length, already taken.
fn awayRooted(v: Point, l: i64, length: i32) Point {
    if (v.x == 0 and v.y == 0) return .{ .x = length, .y = 0 };
    return wishAlongRooted(v, l, length);
}

/// A wish `length` long along `v`: each axis of `v` times the length,
/// divided by `v`'s length (`isqrt`), truncated toward zero.
pub fn wishAlong(v: Point, length: i32) Point {
    return wishAlongRooted(v, isqrt(len2(v)), length);
}

/// `wishAlong`, `l` being `v`'s `isqrt` length.
fn wishAlongRooted(v: Point, l: i64, length: i32) Point {
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

test {
    _ = @import("physics_test.zig");
}
