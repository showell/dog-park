//! **THE WALK'S INDEPENDENT JUDGE**: one pixel-tick of roc/Walk.roc's
//! `pixel_tick` (the leashed dog's step, then the walk, with roc/Wish.roc's
//! wish), again, in plain Zig, sharing no code with the Roc and none of the
//! scene's bucketing: every critter and every poop is scanned, never a cell
//! or a tile. It reads the same inputs the Roc is lent (the critters as
//! `roc_physics.Crit`, the poops, the axis and the step) and the rules and
//! the world from rules.zon and world.zon, the printed config.
//!
//! The scans keep only the orders the Roc's results depend on: critters in
//! seen index order (the sweep's and the gather's first-found), and for
//! poops the lower slot. Every other choice in the Roc is a strict total
//! order (a distance, then an index or a slot), so a scan in any order
//! picks the same.
//!
//! `Judge` runs it beside the Roc (physics.zig's `walk`, with
//! `-Dwalk-judge`) and panics at the first output that differs.

const std = @import("std");
const roc = @import("roc_physics.zig");
const rules = @import("rules.zig").rules;
const world = @import("world.zig").world;

pub const Crit = roc.Crit;
pub const Poop = roc.Poop;

const Pt = struct { x: i32, y: i32 };

// The kinds as roc_physics.zig's `Crit.kind` numbers them: their places in
// world.zon's `kinds`.
const dog: u8 = 0;
const cow: u8 = 1;
const chicken: u8 = 2;
comptime {
    std.debug.assert(std.mem.eql(u8, world.kinds[dog].name, "dog") and std.mem.eql(u8, world.kinds[cow].name, "cow") and std.mem.eql(u8, world.kinds[chicken].name, "chicken"));
}

const world_side: i32 = @as(i32, world.world_tiles) * world.tile_px * 256;
const half_world: i32 = @divTrunc(world_side, 2);
const cells_a_side: i32 = @as(i32, world.world_tiles) * world.cell_per_tile;
const cell_side: i32 = @divTrunc(@as(i32, world.tile_px) * 256, world.cell_per_tile);
const poop_half: i32 = @as(i32, world.sizes.poop_px / 2) * 256;
const walk_most: usize = rules.limits.most;
const nudge_most: usize = rules.limits.nudge_most;
const dead_zone: i32 = @as(i32, rules.limits.dead_zone) * 256;

const why_went: u8 = 0;
const why_pressed: u8 = 1;
const why_chicken: u8 = 2;
const why_poop: u8 = 3;

const Veto = struct { why: u8 = why_went, at: Pt = .{ .x = 0, .y = 0 }, blocker: Pt = .{ .x = 0, .y = 0 } };

/// What a pixel-tick hands back besides the critters (changed in place)
/// and the walk's visit order (`moving[0..moving_len]`).
pub const Result = struct {
    step_x: i32,
    step_y: i32,
    walked: i32,
    bump_kind: i32,
    bump_at: i32,
    pooper: i32,
    anchor: i32,
    moving_len: usize,
};

/// The world's state for one pixel-tick: the critters (changed in place),
/// the poops (only read), and the walk's room.
const Tick = struct {
    crits: []Crit,
    poops: []const Poop,
    moving: []u16,
    moving_len: usize = 0,
    depth: []u16,
};

/// **ONE PIXEL-TICK**: `crits` are moved in place; `moving` (room for
/// `walk_most + 1`) gets the visit order; `depth` is room for one per
/// critter.
pub fn pixelTick(crits: []Crit, poops: []const Poop, moving: []u16, depth: []u16, axis: i32, inc: i32) Result {
    var t: Tick = .{ .crits = crits, .poops = poops, .moving = moving, .depth = depth };
    const from = pt(crits[0]);
    const d = drag(&t, axis, inc);
    const step = delta(from, pt(crits[0]));
    var res: Result = .{ .step_x = step.x, .step_y = step.y, .walked = d.walked, .bump_kind = d.bump_kind, .bump_at = d.bump_at, .pooper = 0, .anchor = -1, .moving_len = 0 };
    if (step.x != 0 or step.y != 0) {
        const w = walk(&t, measure(step));
        res.pooper = w.pooper;
        res.anchor = w.anchor;
        res.moving_len = t.moving_len;
    }
    return res;
}

// ── the leashed dog's step ──────────────────────────────────────────────

const Dragged = struct { walked: i32, bump_kind: i32, bump_at: i32 };
const Bump = struct { kind: i32 = roc.bump_none, at: i32 = 0, stood: Pt = .{ .x = 0, .y = 0 } };

fn drag(t: *Tick, axis: i32, inc: i32) Dragged {
    const breed = t.crits[0].kin;
    const from = pt(t.crits[0]);
    t.crits[0].kin = roc.no_kin;
    defer t.crits[0].kin = breed;
    const sw = sweep(t, axis, inc);
    if (sw.by != 0) moveTo(t, 0, wrapped(plus(from, onAxis(axis, sw.by))));
    if (sw.bump.kind == roc.bump_none) return .{ .walked = abs(sw.by), .bump_kind = roc.bump_none, .bump_at = 0 };
    const more = goAround(t, axis, inc - sw.by, abs(inc), sw.bump);
    if (more.went) return .{ .walked = abs(sw.by) + more.walked, .bump_kind = roc.bump_none, .bump_at = 0 };
    return .{ .walked = abs(sw.by) + more.walked, .bump_kind = sw.bump.kind, .bump_at = sw.bump.at };
}

fn goAround(t: *Tick, axis: i32, rest: i32, size: i32, bump: Bump) struct { went: bool, walked: i32 } {
    const is_chicken = bump.kind == roc.bump_critter and t.crits[@intCast(bump.at)].kind == chicken;
    if (bump.kind == roc.bump_critter and !is_chicken) return .{ .went = false, .walked = 0 };
    if (is_chicken and stepWhole(t, 0, onAxis(axis, rest)).why == why_went) return .{ .went = true, .walked = abs(rest) };
    const off = partOn(delta(pt(t.crits[0]), bump.stood), 1 - axis);
    const slid = stepWhole(t, 0, onAxis(1 - axis, if (off > 0) -size else size));
    return if (slid.why == why_went) .{ .went = true, .walked = size } else .{ .went = false, .walked = 0 };
}

/// The leashed dog's sweep against every other critter (the lower seen
/// index on a tie), then every poop (only if shorter still; the lower slot
/// on a tie).
fn sweep(t: *const Tick, axis: i32, step: i32) struct { by: i32, bump: Bump } {
    const me = t.crits[0];
    const p = pt(me);
    var best = step;
    var bump: Bump = .{};
    for (t.crits[1..], 1..) |o, j| {
        const got = sweepLimit(p, me.half, axis, step, pt(o), o.half);
        if (abs(got) < abs(best)) {
            best = got;
            bump = .{ .kind = roc.bump_critter, .at = @intCast(j), .stood = pt(o) };
        }
    }
    var poop_best = step;
    var poop: i64 = -1;
    var poop_at: Pt = .{ .x = 0, .y = 0 };
    for (t.poops) |q| {
        const got = sweepLimit(p, me.half, axis, step, .{ .x = q.x, .y = q.y }, poop_half);
        if (abs(got) < abs(poop_best) or (poop >= 0 and abs(got) == abs(poop_best) and q.slot < poop)) {
            poop_best = got;
            poop = q.slot;
            poop_at = .{ .x = q.x, .y = q.y };
        }
    }
    if (poop >= 0 and abs(poop_best) < abs(best)) return .{ .by = poop_best, .bump = .{ .kind = roc.bump_poop, .at = @intCast(poop), .stood = poop_at } };
    return .{ .by = best, .bump = bump };
}

fn sweepLimit(p: Pt, h: i32, axis: i32, s: i32, o: Pt, oh: i32) i32 {
    const d = delta(p, o);
    const hs = h + oh;
    const on_line = partOn(d, axis);
    if (abs(partOn(d, 1 - axis)) >= hs or s == 0) return s;
    if (abs(on_line) >= hs) {
        if (sign(on_line) != sign(s)) return s;
        const gap = abs(on_line) - hs;
        return if (abs(s) > gap) sign(s) * gap else s;
    }
    if (on_line == 0 or sign(on_line) != sign(s)) return s;
    return 0;
}

// ── the walk ────────────────────────────────────────────────────────────

fn walk(t: *Tick, most: i32) struct { pooper: i32, anchor: i32 } {
    t.depth[0] = 0;
    t.moving[0] = 0;
    t.moving_len = 1;
    const herd = t.crits[0].kin;
    lineUp(t, 0);
    var pooper: usize = 0;
    var anchor: i32 = -1;
    var count: usize = 0;
    while (count < walk_most) {
        const i = leastWaiting(t.crits) orelse break;
        const me = t.crits[i];
        t.crits[i].key = roc.visited;
        const wished = wishOf(t, i);
        t.moving[t.moving_len] = @intCast(i);
        t.moving_len += 1;
        count += 1;
        const pace = (if (me.kind == dog) rules.dog else if (me.kind == cow) rules.cow else @panic("walk_reference: a chicken lined up")).pace;
        stepAround(t, i, stepAtMost(.{ .x = wished.x, .y = wished.y }, share(pace, most)));
        if (me.kind == dog and me.kin == herd and wished.anchor >= 0) {
            const d = t.depth[@intCast(wished.anchor)] + 1;
            t.depth[i] = d;
            if (d >= t.depth[pooper]) {
                pooper = i;
                anchor = wished.anchor;
            }
        }
        lineUp(t, i);
    }
    return .{ .pooper = @intCast(pooper), .anchor = anchor };
}

fn share(pace: anytype, v: i32) i32 {
    if (pace.num == pace.den) return v;
    return @intCast(@divTrunc(@as(i64, v) * pace.num, @as(i64, pace.den)));
}

/// The waiting critter with the least key, the lower index on a tie.
fn leastWaiting(crits: []const Crit) ?usize {
    var best: ?usize = null;
    for (crits, 0..) |c, j| {
        if (c.key >= 0 and (best == null or c.key < crits[best.?].key)) best = j;
    }
    return best;
}

/// Critter `from`'s three nearest dogs and cows not yet visited, by
/// (distance, index), every critter looked at; each waits with that
/// distance or the nearer key it already has.
fn lineUp(t: *Tick, from: usize) void {
    const p = pt(t.crits[from]);
    var near: [3]?usize = .{ null, null, null };
    var dist: [3]i32 = .{ 0, 0, 0 };
    for (t.crits, 0..) |o, j| {
        if (o.key == roc.visited or o.kind == chicken) continue;
        var d = measure(delta(pt(o), p));
        var jj: usize = j;
        // Insertion into the three, kept sorted.
        for (0..3) |k| {
            if (near[k] == null or d < dist[k] or (d == dist[k] and jj < near[k].?)) {
                const pd = dist[k];
                const pj = near[k];
                dist[k] = d;
                near[k] = jj;
                if (pj == null) break;
                d = pd;
                jj = pj.?;
            }
        }
    }
    for (near, dist) |who, d| {
        const j = who orelse continue;
        const c = &t.crits[j];
        if (!(c.key >= 0 and c.key <= d)) c.key = d;
    }
}

// ── the wish (roc/Wish.roc) ────────────────────────────────────────────

const Wished = struct { anchor: i32, x: i32, y: i32 };

/// One moving critter as the wisher sees it.
const Near = struct { ax: i64, ay: i64, tx: i64, ty: i64, half: i64, j: u16, kin: bool, kind: u8 };

fn ruleFor(sees: rules_mod.Sees, n: Near) rules_mod.Rule {
    return switch (n.kind) {
        dog => if (n.kin) sees.kin else sees.dog,
        cow => sees.cow,
        chicken => sees.chicken,
        else => @panic("walk_reference: a kind world.zon does not number"),
    };
}

const rules_mod = @import("rules.zig");

fn seesOf(kind: u8) rules_mod.Sees {
    return switch (kind) {
        dog => rules.dog,
        cow => rules.cow,
        else => @panic("walk_reference: a chicken wished"),
    };
}

/// Critter `i`'s wish, from every critter in motion (the walk's `moving`).
fn wishOf(t: *const Tick, i: usize) Wished {
    const me = t.crits[i];
    const sees = seesOf(me.kind);
    const half: i64 = me.half;
    var sum_x: i64 = 0;
    var sum_y: i64 = 0;
    var anchor: ?Near = null;
    var anchor_d: i64 = 0;
    var inner: i64 = 0;
    var outer: i64 = 0;
    var nearest: ?Near = null;
    var nearest_d: i64 = 0;
    for (t.moving[0..t.moving_len]) |j| {
        const o = t.crits[j];
        const tx = short(o.x - me.x);
        const ty = short(o.y - me.y);
        const n: Near = .{
            .ax = turned(tx),
            .ay = turned(ty),
            .tx = tx,
            .ty = ty,
            .half = o.half,
            .j = j,
            .kin = me.kind == dog and o.kind == dog and o.kin == me.kin,
            .kind = o.kind,
        };
        const d = measure64(n.ax, n.ay);
        switch (sees.gathers) {
            .nearest => if (nearest == null or d < nearest_d or (d == nearest_d and n.j < nearest.?.j)) {
                nearest = n;
                nearest_d = d;
            },
            .each => answer(ruleFor(sees, n), half, n, d, &sum_x, &sum_y, &anchor, &anchor_d, &inner, &outer),
        }
    }
    if (nearest) |n| answer(ruleFor(sees, n), half, n, nearest_d, &sum_x, &sum_y, &anchor, &anchor_d, &inner, &outer);
    var band: [2]i64 = .{ 0, 0 };
    if (anchor) |a| {
        if (anchor_d > outer) {
            band = along(a.tx, a.ty, anchor_d - outer);
        } else if (anchor_d < inner) {
            band = away(a.ax, a.ay, inner - anchor_d);
        }
    }
    return .{
        .anchor = if (anchor) |a| a.j else -1,
        .x = @truncate(sum_x + band[0]),
        .y = @truncate(sum_y + band[1]),
    };
}

fn answer(rule: rules_mod.Rule, half: i64, n: Near, d: i64, sx: *i64, sy: *i64, anchor: *?Near, anchor_d: *i64, inner: *i64, outer: *i64) void {
    switch (rule) {
        .ignore => {},
        .herd => |b| if (anchor.* == null or d < anchor_d.* or (d == anchor_d.* and n.j < anchor.*.?.j)) {
            anchor.* = n;
            anchor_d.* = d;
            inner.* = @as(i64, b.inner) * 256;
            outer.* = @as(i64, b.outer) * 256;
        },
        .keep => |reach| {
            const r = @as(i64, reach) * 256;
            if (d <= r) {
                const w = away(n.ax, n.ay, r - d);
                sx.* += w[0];
                sy.* += w[1];
            }
        },
        .close => |reach| {
            const touch = half + n.half;
            if (d > touch and d <= @as(i64, reach) * 256) {
                const w = along(n.tx, n.ty, d - touch);
                sx.* += w[0];
                sy.* += w[1];
            }
        },
    }
}

fn along(vx: i64, vy: i64, length: i64) [2]i64 {
    const l = measure64(vx, vy);
    return .{ @divTrunc(vx * length, l), @divTrunc(vy * length, l) };
}

fn away(vx: i64, vy: i64, length: i64) [2]i64 {
    if (vx == 0 and vy == 0) return .{ length, 0 };
    return along(vx, vy, length);
}

fn measure64(x: i64, y: i64) i64 {
    return @max(@as(i64, @intCast(@abs(x))), @as(i64, @intCast(@abs(y))));
}

/// A short-way difference turned round (at exactly half a world, kept).
fn turned(d: i32) i32 {
    return if (d == -half_world) d else -d;
}

fn stepAtMost(total: Pt, most: i32) Pt {
    const m = measure(total);
    if (m < dead_zone) return .{ .x = 0, .y = 0 };
    if (m <= most) return total;
    return .{
        .x = @intCast(@divTrunc(@as(i64, total.x) * most, m)),
        .y = @intCast(@divTrunc(@as(i64, total.y) * most, m)),
    };
}

// ── a step: the veto, the nudge, the shove ──────────────────────────────

fn stepAround(t: *Tick, i: usize, step: Pt) void {
    const v = stepWhole(t, i, step);
    if (v.why == why_chicken or v.why == why_poop) _ = stepWhole(t, i, sidestep(v, step));
}

fn sidestep(v: Veto, step: Pt) Pt {
    const d = delta(v.at, v.blocker);
    const size = measure(step);
    if (abs(d.x) >= abs(d.y)) return .{ .x = 0, .y = if (step.y != 0) step.y else if (d.y > 0) -size else size };
    return .{ .x = if (step.x != 0) step.x else if (d.x > 0) -size else size, .y = 0 };
}

const Group = struct {
    group: [nudge_most]usize = undefined,
    n: usize = 0,
    shoved: [nudge_most]usize = undefined,
    by: [nudge_most]usize = undefined,
    ns: usize = 0,

    fn inMove(g: *const Group, j: usize) bool {
        return std.mem.indexOfScalar(usize, g.group[0..g.n], j) != null or std.mem.indexOfScalar(usize, g.shoved[0..g.ns], j) != null;
    }
};

fn stepWhole(t: *Tick, i: usize, step: Pt) Veto {
    if (step.x == 0 and step.y == 0) return .{};
    var g: Group = .{};
    g.group[0] = i;
    g.n = 1;
    const breed = t.crits[i].kin;
    var k: usize = 0;
    while (k < g.n) : (k += 1) {
        const me = t.crits[g.group[k]];
        const from = pt(me);
        const to = plus(from, step);
        if (poopUnder(t, to, me.half)) |q| return .{ .why = why_poop, .at = from, .blocker = q };
        for (t.crits, 0..) |o, j| {
            if (!overlap(to, me.half, pt(o), o.half) or g.inMove(j)) continue;
            if (o.kind == chicken) {
                if (g.ns == nudge_most) return .{ .why = why_chicken, .at = from, .blocker = pt(o) };
                g.shoved[g.ns] = j;
                g.by[g.ns] = g.group[k];
                g.ns += 1;
            } else if (j == 0 or o.kin != breed or g.n == nudge_most) {
                return .{ .why = why_pressed, .at = from, .blocker = pt(o) };
            } else {
                g.group[g.n] = j;
                g.n += 1;
            }
        }
    }
    // Every shove must land clear.
    for (0..g.ns) |m| {
        const c = t.crits[g.shoved[m]];
        const land = landOf(t, step, &g, m);
        var bad = poopUnder(t, land, c.half) != null;
        for (t.crits, 0..) |o, j| {
            if (bad) break;
            bad = overlap(land, c.half, pt(o), o.half) and !g.inMove(j);
        }
        for (g.group[0..g.n]) |gj| {
            if (bad) break;
            bad = overlap(land, c.half, plus(pt(t.crits[gj]), step), t.crits[gj].half);
        }
        for (0..m) |e| {
            if (bad) break;
            bad = overlap(land, c.half, landOf(t, step, &g, e), c.half);
        }
        if (bad) return .{ .why = why_chicken, .at = pt(t.crits[g.by[m]]), .blocker = pt(c) };
    }
    for (0..g.ns) |m| moveTo(t, g.shoved[m], landOf(t, step, &g, m));
    for (g.group[0..g.n]) |gj| moveTo(t, gj, wrapped(plus(pt(t.crits[gj]), step)));
    return .{};
}

fn landOf(t: *const Tick, step: Pt, g: *const Group, m: usize) Pt {
    const p = pt(t.crits[g.shoved[m]]);
    return wrapped(plus(plus(p, step), shoveAside(step, delta(pt(t.crits[g.by[m]]), p))));
}

fn shoveAside(step: Pt, d: Pt) Pt {
    const left: Pt = .{ .x = -step.y, .y = step.x };
    const right: Pt = .{ .x = step.y, .y = -step.x };
    const turn = @as(i64, step.x) * d.y - @as(i64, step.y) * d.x;
    if (turn > 0) return left;
    if (turn < 0) return right;
    return if (left.y > 0 or (left.y == 0 and left.x > 0)) left else right;
}

/// The lowest slot's poop a square of half `h` at `p` overlaps; every poop
/// looked at.
fn poopUnder(t: *const Tick, p: Pt, h: i32) ?Pt {
    var best: ?Poop = null;
    for (t.poops) |q| {
        if ((best == null or q.slot < best.?.slot) and overlap(p, h, .{ .x = q.x, .y = q.y }, poop_half)) best = q;
    }
    return if (best) |q| .{ .x = q.x, .y = q.y } else null;
}

fn moveTo(t: *Tick, j: usize, p: Pt) void {
    const c = &t.crits[j];
    c.x = p.x;
    c.y = p.y;
    c.cell = cellOf(p);
}

pub fn cellOf(p: Pt) u16 {
    return @intCast(@divTrunc(p.y, cell_side) * cells_a_side + @divTrunc(p.x, cell_side));
}

// ── the torus ──────────────────────────────────────────────────────────

fn pt(c: Crit) Pt {
    return .{ .x = c.x, .y = c.y };
}

fn delta(a: Pt, b: Pt) Pt {
    return .{ .x = short(b.x - a.x), .y = short(b.y - a.y) };
}

/// A difference the short way round, in [-half_world, half_world).
fn short(d: i32) i32 {
    return @mod(d + half_world, world_side) - half_world;
}

fn overlap(p: Pt, ph: i32, q: Pt, qh: i32) bool {
    const d = delta(p, q);
    return abs(d.x) < ph + qh and abs(d.y) < ph + qh;
}

fn wrapped(p: Pt) Pt {
    return .{ .x = @mod(p.x, world_side), .y = @mod(p.y, world_side) };
}

fn plus(p: Pt, v: Pt) Pt {
    return .{ .x = p.x + v.x, .y = p.y + v.y };
}

fn measure(v: Pt) i32 {
    return @max(abs(v.x), abs(v.y));
}

fn onAxis(axis: i32, v: i32) Pt {
    return if (axis == 0) .{ .x = v, .y = 0 } else .{ .x = 0, .y = v };
}

fn partOn(v: Pt, axis: i32) i32 {
    return if (axis == 0) v.x else v.y;
}

fn sign(v: i32) i32 {
    return if (v > 0) 1 else if (v < 0) -1 else 0;
}

fn abs(v: i32) i32 {
    return @intCast(@abs(v));
}

// ── the judge ──────────────────────────────────────────────────────────

/// **THE JUDGE**: `before` copies what the Roc is lent and runs the
/// reference on the copy; `after`, given what the Roc handed back, panics
/// at the first difference.
pub fn Judge(comptime seen_most: usize, comptime moving_most: usize) type {
    return struct {
        crits: [seen_most]Crit = undefined,
        n: usize = 0,
        moving: [moving_most]u16 = undefined,
        depth: [seen_most]u16 = undefined,
        res: Result = undefined,
        axis: i32 = 0,
        inc: i32 = 0,

        const Self = @This();

        pub fn before(self: *Self, crits: []const Crit, from: []const u16, poops: []const Poop, side: usize, axis: i32, inc: i32) void {
            if (side != cells_a_side) std.debug.panic("walk judge: the physics lends {d} cells a side, world.zon makes {d}", .{ side, cells_a_side });
            if (from.len == 0 or from[from.len - 1] != poops.len) std.debug.panic("walk judge: the poops' tile offsets end at {d}, {d} poops lent", .{ if (from.len == 0) 0 else from[from.len - 1], poops.len });
            self.n = crits.len;
            self.axis = axis;
            self.inc = inc;
            @memcpy(self.crits[0..self.n], crits);
            self.res = pixelTick(self.crits[0..self.n], poops, &self.moving, &self.depth, axis, inc);
        }

        fn differ(self: *const Self, what: []const u8, index: usize, ref: i64, got: i64) noreturn {
            std.debug.panic("walk judge: {s}[{d}] differs: reference {d}, Roc {d} (axis {d}, inc {d})", .{ what, index, ref, got, self.axis, self.inc });
        }

        pub fn after(self: *const Self, crits: []const Crit, cells: []const u64, words: usize, moving: []const u16, ran: anytype) void {
            const r = self.res;
            if (crits.len != self.n) self.differ("critter count", 0, @intCast(self.n), @intCast(crits.len));
            // Places first, every critter's, then the rest: a place is
            // nearer the cause than the keys it changes.
            inline for (.{ "x", "y", "cell", "key", "half", "kin", "kind" }) |f| {
                for (self.crits[0..self.n], crits, 0..) |a, b, j| {
                    if (@field(a, f) != @field(b, f)) self.differ("crit." ++ f, j, @intCast(@field(a, f)), @intCast(@field(b, f)));
                }
            }
            inline for (.{ "step_x", "step_y", "walked", "bump_kind", "bump_at", "anchor" }) |f| {
                if (@field(r, f) != @field(ran, f)) self.differ(f, 0, @field(r, f), @field(ran, f));
            }
            if (r.pooper != ran.pooper) self.differ("pooper", 0, r.pooper, @intCast(ran.pooper));
            if (r.moving_len != moving.len) self.differ("moving.len", 0, @intCast(r.moving_len), @intCast(moving.len));
            for (self.moving[0..r.moving_len], moving, 0..) |a, b, k| {
                if (a != b) self.differ("moving", k, a, b);
            }
            // The Roc's cells hold each critter in the cell it says, and no more.
            var bits: usize = 0;
            for (cells) |word| bits += @popCount(word);
            if (bits != self.n) self.differ("cells' critters", 0, @intCast(self.n), @intCast(bits));
            for (crits, 0..) |c, j| {
                if (cells[@as(usize, c.cell) * words + j / 64] & (@as(u64, 1) << @intCast(j % 64)) == 0) self.differ("cells: not in its cell", j, c.cell, -1);
            }
        }
    };
}
