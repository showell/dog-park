//! **THE GAME'S TICK IN ROC, JUDGED** (`-Dgame-judge`, `zig build
//! game-judge`): roc/Game.roc's tick, the one the game on roc-ray plays
//! (roc/native.roc), run beside this physics' every tick on a copy of the
//! board, and every critter's place, every dog's walked count, the poops,
//! the poops laid and the leash compared after it. It panics at the first
//! difference. The tick crosses as roc/game.roc's `roc_game_tick`, the
//! board laid flat (roc/game_platform/main.roc), its lists in memory from
//! an arena made for the tick (roc_physics.zig's `roc_allocator`).
//!
//! The board goes over as Game.roc keeps one: the present critters, the
//! kinds in kind-number order and each kind's in number order (so dog n is
//! index n), each with its home; the poops present, by slot.

const std = @import("std");
const physics = @import("physics.zig");
const layout = @import("layout.zig");
const roc = @import("roc_physics.zig");
const RocList = roc.RocList;
const Crit = roc.Crit;
const Poop = roc.Poop;
const Pt = roc.Pt;

const Disp = extern struct { dx: i32, dy: i32 };
const HumanIn = extern struct { dog: u64, kind: u64 };
/// Laid out as Roc lays the record: of fields aligned alike, the smaller
/// first, each size by name (read off the words a call handed back: the
/// U64s, then the lists).
const Ticked = extern struct { bump_kind: u64, drag_at: u64, drag_kind: u64, hold_dog: u64, hold_kind: u64, laid: u64, crits: RocList, poops: RocList, walked: RocList };

extern fn roc_game_tick(level: u64, t: u64, hold_kind: u64, hold_dog: u64, drag_kind: u64, drag_at: u64, laid: u64, crits: RocList, homes: RocList, walked: RocList, poops: RocList, humans: RocList, disps: RocList) callconv(.c) Ticked;

comptime {
    std.debug.assert(@sizeOf(Ticked) == 3 * @sizeOf(RocList) + 6 * 8);
}

/// A list Roc owns from here: its elements after Roc's refcount word (1,
/// unique), in memory from `roc_alloc`, so Roc may free or grow it.
fn listOf(comptime T: type, items: []const T) RocList {
    if (items.len == 0) return .{ .bytes = null, .length = 0, .capacity_or_alloc_ptr = 0 };
    const word = @max(@sizeOf(isize), @alignOf(T));
    const raw: [*]u8 = @ptrCast(roc.roc_alloc(word + items.len * @sizeOf(T), word));
    const data = raw + word;
    @as(*isize, @ptrCast(@alignCast(data - @sizeOf(isize)))).* = 1;
    @memcpy(@as([*]T, @ptrCast(@alignCast(data)))[0..items.len], items);
    return .{ .bytes = data, .length = items.len, .capacity_or_alloc_ptr = items.len << 1 };
}

fn itemsOf(comptime T: type, l: RocList) []const T {
    if (l.length == 0) return &.{};
    return @as([*]const T, @ptrCast(@alignCast(l.bytes.?)))[0..l.length];
}

fn fail(t: physics.Tick, comptime what: []const u8, args: anytype) noreturn {
    std.debug.panic("game judge, tick {d}: " ++ what ++ " (Game.roc against physics.zig)", .{t} ++ args);
}

/// Judges the tick `t` that took `before` to `after` with `humans` and
/// `drag`, which the physics did not refuse.
pub fn judge(before: *const physics.Board, t: physics.Tick, humans: []const physics.Human, drag: []const physics.Disp, after: *const physics.Board) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    roc.roc_allocator = arena.allocator();
    defer roc.roc_allocator = null;
    const a = arena.allocator();

    // The present critters, kind by kind, and where each is in that list.
    var who: std.ArrayList(physics.Critter) = .empty;
    var crits: std.ArrayList(Crit) = .empty;
    var homes: std.ArrayList(Pt) = .empty;
    var walked: std.ArrayList(u32) = .empty;
    var index_of_dog: [physics.counts[@backingInt(physics.leashed_kind)]]u64 = @splat(std.math.maxInt(u64));
    for (0..physics.kind_count) |k| for (0..physics.counts[k]) |n| {
        const c: physics.Critter = .of(@fromBackingInt(@intCast(k)), @intCast(n));
        if (before.known(c) != .present) continue;
        if (c.kind == physics.leashed_kind) index_of_dog[n] = who.items.len;
        const p = before.at(c);
        const h = layout.home(before.level, c);
        who.append(a, c) catch @panic("out of memory");
        crits.append(a, .{ .key = roc.not_lined_up, .half = c.half(), .x = p.x, .y = p.y, .kin = physics.kinOf(c) orelse roc.no_kin, .kind = @backingInt(c.kind) }) catch @panic("out of memory");
        homes.append(a, .{ .x = h.x, .y = h.y }) catch @panic("out of memory");
        walked.append(a, if (c.kind == physics.leashed_kind) before.walked[n] else 0) catch @panic("out of memory");
    };
    var poops: std.ArrayList(Poop) = .empty;
    for (0..physics.poop_count) |slot| if (before.poop_known[slot] == .present) {
        poops.append(a, .{ .slot = @intCast(slot), .x = before.poops[slot].x, .y = before.poops[slot].y }) catch @panic("out of memory");
    };
    var inputs: std.ArrayList(HumanIn) = .empty;
    for (humans) |h| inputs.append(a, switch (h) {
        .release => |d| .{ .kind = 0, .dog = index_of_dog[d] },
        .leash => |d| .{ .kind = 1, .dog = index_of_dog[d] },
        .grab => .{ .kind = 2, .dog = 0 },
        .letgo => .{ .kind = 3, .dog = 0 },
    }) catch @panic("out of memory");
    var disps: std.ArrayList(Disp) = .empty;
    for (drag) |d| disps.append(a, .{ .dx = d.dx, .dy = d.dy }) catch @panic("out of memory");
    const hold = holdOf(before.hold, &index_of_dog);

    const r = roc_game_tick(before.level, t - 1, hold.kind, hold.dog, hold.drag_kind, hold.drag_at, before.laid, listOf(Crit, crits.items), listOf(Pt, homes.items), listOf(u32, walked.items), listOf(Poop, poops.items), listOf(HumanIn, inputs.items), listOf(Disp, disps.items));

    const got = itemsOf(Crit, r.crits);
    if (got.len != who.items.len) fail(t, "{d} critters, the Zig {d}", .{ got.len, who.items.len });
    for (who.items, got, 0..) |c, g, i| {
        const want = after.at(c);
        if (g.x != want.x or g.y != want.y) fail(t, "{t} {d} (index {d}) at ({d}, {d}), the Zig ({d}, {d})", .{ c.kind, c.n, i, g.x, g.y, want.x, want.y });
    }
    const got_walked = itemsOf(u32, r.walked);
    for (who.items, got_walked) |c, w| {
        if (c.kind == physics.leashed_kind and w != after.walked[c.n]) fail(t, "dog {d} has walked {d}, the Zig {d}", .{ c.n, w, after.walked[c.n] });
    }
    if (r.laid != after.laid) fail(t, "{d} poops laid, the Zig {d}", .{ r.laid, after.laid });
    var seen: [physics.poop_count]bool = @splat(false);
    for (itemsOf(Poop, r.poops)) |p| {
        if (after.poop_known[p.slot] != .present) fail(t, "a poop in slot {d}, the Zig none", .{p.slot});
        if (after.poops[p.slot].x != p.x or after.poops[p.slot].y != p.y) fail(t, "slot {d}'s poop at ({d}, {d}), the Zig ({d}, {d})", .{ p.slot, p.x, p.y, after.poops[p.slot].x, after.poops[p.slot].y });
        seen[p.slot] = true;
    }
    for (0..physics.poop_count) |slot| if (after.poop_known[slot] == .present and !seen[slot]) fail(t, "no poop in slot {d}, the Zig one", .{slot});
    const want_hold = holdOf(after.hold, &index_of_dog);
    if (r.hold_kind != want_hold.kind or r.hold_dog != want_hold.dog or r.drag_kind != want_hold.drag_kind or r.drag_at != want_hold.drag_at)
        fail(t, "the hold {d} dog {d} drag {d} at {d}, the Zig {d} dog {d} drag {d} at {d}", .{ r.hold_kind, r.hold_dog, r.drag_kind, r.drag_at, want_hold.kind, want_hold.dog, want_hold.drag_kind, want_hold.drag_at });
}

const FlatHold = struct { kind: u64, dog: u64, drag_kind: u64, drag_at: u64 };

fn holdOf(h: physics.Hold, index_of_dog: []const u64) FlatHold {
    return switch (h) {
        .none => .{ .kind = 0, .dog = 0, .drag_kind = 0, .drag_at = 0 },
        .leashed => |l| switch (l.drag) {
            .on => .{ .kind = 1, .dog = index_of_dog[l.dog], .drag_kind = 0, .drag_at = 0 },
            .ended => |e| .{ .kind = 1, .dog = index_of_dog[l.dog], .drag_kind = 1, .drag_at = e },
        },
    };
}
