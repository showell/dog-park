//! **THE PHYSICS' ROC**: one pixel-tick, the leashed dog's step and then
//! the walk (roc/Walk.roc's `pixel_tick`, with the critters' wish in it,
//! roc/Wish.roc), compiled by `zig build roc` into
//! roc/lib/physics-<target>.a (checked in; no build runs Roc), which every
//! build of the physics links. This file is the seam: the C function Roc
//! provides, their arguments laid out as Roc lays records out (fields by
//! alignment, largest first, then by name), and the host functions the
//! archive calls.
//!
//! Every list goes to Roc as a `List` over a buffer of the physics' own
//! (`Lent`), after Roc's refcount word: 0, "static data", for one Roc only
//! reads (it neither frees nor writes it); 1, unique, for one Roc changes
//! in place and hands back. Each is lent with the room its use needs, so
//! Roc allocates nothing, and a call into it allocates nothing on either
//! side: `roc_alloc` and `roc_realloc` are there to be linked, and panic.

const std = @import("std");

/// Roc's `List`: its elements, how many, and its capacity shifted left one
/// (the low bit clear: no seamless slice).
pub const RocList = extern struct { bytes: ?[*]u8, length: usize, capacity_or_alloc_ptr: usize };

/// **A LENT LIST**: room for `most` of `T`, after Roc's refcount word,
/// which Roc reads just before a list's first element: where `T` is aligned
/// wider than the word (an `i64` on wasm32), padding goes before the word,
/// never between it and the elements.
pub fn Lent(comptime T: type, comptime most: usize) type {
    const alignment = @max(@alignOf(usize), @alignOf(T));
    return extern struct {
        pad: [alignment - @sizeOf(isize)]u8 align(alignment) = undefined,
        refcount: isize = 0,
        items: [most]T = undefined,
        len: usize = 0,

        const Self = @This();

        comptime {
            std.debug.assert(@offsetOf(Self, "items") == @offsetOf(Self, "refcount") + @sizeOf(isize));
        }

        pub fn push(self: *Self, v: T) void {
            self.items[self.len] = v;
            self.len += 1;
        }

        pub fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        /// The list for Roc only to read.
        fn toRead(self: *Self) RocList {
            self.refcount = 0;
            return self.list();
        }

        /// The list for Roc to change and hand back.
        fn toChange(self: *Self) RocList {
            self.refcount = 1;
            return self.list();
        }

        fn list(self: *Self) RocList {
            return .{ .bytes = @ptrCast(&self.items), .length = self.len, .capacity_or_alloc_ptr = most << 1 };
        }

        /// The list Roc handed back: this one, changed in place, and still
        /// unique; its length is the new one.
        fn back(self: *Self, l: RocList) void {
            if (l.bytes != @as(?[*]u8, @ptrCast(&self.items)) or self.refcount != 1 or l.length > most) @panic("roc: a lent list came back moved or shared");
            self.len = l.length;
        }
    };
}

/// Seen critter `j` (roc/Walk.roc's `Crit`): where it stands, and the cell
/// it stands in (physics.zig's `Scene.cellOf`); its square's half side; its kind (physics.zig's `Kind`); its kin, who it
/// nudges (a dog its breed, a cow the breeds' count, a chicken `no_kin`);
/// and its key while it waits to be visited: `not_lined_up`, or `visited`
/// (the leashed dog is lent as visited: the walk starts from it).
pub const Crit = extern struct { key: i64, half: i32, x: i32, y: i32, cell: u16, kin: u8, kind: u8 };
pub const no_kin: u8 = 255;

/// What stopped the leashed dog (roc/Walk.roc's `Bump`): nothing, the seen
/// critter at `bump_at`, or the poop in slot `bump_at`.
pub const bump_none: i32 = 0;
pub const bump_critter: i32 = 1;
pub const bump_poop: i32 = 2;
pub const not_lined_up: i64 = -1;
pub const visited: i64 = -2;

/// A poop the physics sees, and its slot (`Poop`).
pub const Poop = extern struct { x: i32, y: i32, slot: u16 };

const Walked = extern struct { cells: RocList, crits: RocList, depth: RocList, eaten: RocList, moving: RocList, anchor: i32, bump_at: i32, bump_kind: i32, poop_slot: i32, poop_x: i32, poop_y: i32, pooper: i32, step_x: i32, step_y: i32, walked: i32 };

/// A point (roc/Walk.roc's `Pt`): a forager's home, by seen index.
pub const Pt = extern struct { x: i32, y: i32 };
/// `mode` (roc/physics.roc's `walk`): a pixel-tick, or the forage turn.
const mode_pixel_tick: i32 = 0;
const mode_forage: i32 = 1;
const mode_settle: i32 = 2;
extern fn roc_walk(mode: i32, axis: i32, inc: i32, side: i32, before: u32, laid: u32, from: RocList, poops: RocList, homes: RocList, cells: RocList, crits: RocList, depth: RocList, eaten: RocList, moving: RocList) callconv(.c) Walked;

/// **THE WALK'S LISTS** (roc/Walk.roc's `Lent` and `Work`), for at most
/// `seen_most` critters, `moving_most` of them in motion, `poops_most`
/// poops, `tiles` tiles and `side` by `side` cells. The physics fills
/// `poops` and `from` whenever the poops change, and `crits` once a
/// tick with `cells` clear (`words` a cell), which Roc settles (`settle`)
/// and keeps from then on; the walk changes those two and
/// fills `moving` (the leashed dog, then each visited); `depth` is its
/// working room.
pub fn Walk(comptime seen_most: usize, comptime moving_most: usize, comptime poops_most: usize, comptime tiles: usize, comptime side: usize) type {
    return struct {
        from: Lent(u16, tiles + 1) = .{},
        poops: Lent(Poop, poops_most) = .{},
        cells: Lent(u64, side * side * words) = .{},
        crits: Lent(Crit, seen_most) = .{},
        depth: Lent(u16, seen_most) = .{},
        moving: Lent(u16, moving_most) = .{},
        /// The forage turn's: each forager's home, by seen index (the
        /// physics fills it with the crits); and the poops eaten, lent empty.
        homes: Lent(Pt, seen_most) = .{},
        eaten: Lent(u16, poops_most) = .{},

        pub const words = std.math.divCeil(usize, seen_most, 64) catch unreachable;

        /// No critter in any cell.
        pub fn cellsClear(self: *@This()) void {
            self.cells.len = side * side * words;
            @memset(&self.cells.items, 0);
        }

        /// Roc settles the crits into the cells (roc/Walk.roc's `settle`):
        /// each crit's cell, and its bit in it.
        pub fn settle(self: *@This()) void {
            const n = self.crits.len;
            self.depth.len = 0;
            self.moving.len = 0;
            self.eaten.len = 0;
            _ = self.call(mode_settle, 0, 0, 0, 0);
            std.debug.assert(self.crits.len == n);
        }

        /// One pixel-tick: the leashed dog's step `inc` along `axis` (0 x,
        /// 1 y), then, if it moved, the walk and the poop due, the dog having
        /// walked `before` and `laid` poops laid. The lists as it left them;
        /// the dog's net step, how far it walked (each move by its larger
        /// axis) and what it bumped; and the poop laid: its slot (-1, none)
        /// and where.
        pub fn run(self: *@This(), axis: i32, inc: i32, before: u32, laid: u32) Ran {
            const n = self.crits.len;
            self.depth.len = n;
            self.moving.len = 0;
            self.eaten.len = 0;
            const r = self.call(mode_pixel_tick, axis, inc, before, laid);
            std.debug.assert(self.crits.len == n and self.from.refcount == 0 and self.poops.refcount == 0);
            return .{ .step_x = r.step_x, .step_y = r.step_y, .walked = r.walked, .bump_kind = r.bump_kind, .bump_at = r.bump_at, .poop_slot = r.poop_slot, .poop_x = r.poop_x, .poop_y = r.poop_y };
        }

        pub const Ran = struct { step_x: i32, step_y: i32, walked: i32, bump_kind: i32, bump_at: i32, poop_slot: i32, poop_x: i32, poop_y: i32 };
        /// The forage turn (roc/Walk.roc's `forage_turn`), the leashed dog's
        /// net move over the tick `net` and `laid` poops laid: the crits and
        /// cells as it left them, and the slots the foragers ate.
        pub fn forage(self: *@This(), net: i32, laid: u32) []const u16 {
            const n = self.crits.len;
            self.depth.len = 0;
            self.moving.len = 0;
            self.eaten.len = 0;
            std.debug.assert(self.homes.len == n);
            _ = self.call(mode_forage, 0, net, 0, laid);
            std.debug.assert(self.crits.len == n);
            return self.eaten.slice();
        }
        fn call(self: *@This(), mode: i32, axis: i32, inc: i32, before: u32, laid: u32) Walked {
            const r = roc_walk(mode, axis, inc, side, before, laid, self.from.toRead(), self.poops.toRead(), self.homes.toRead(), self.cells.toChange(), self.crits.toChange(), self.depth.toChange(), self.eaten.toChange(), self.moving.toChange());
            self.cells.back(r.cells);
            self.crits.back(r.crits);
            self.depth.back(r.depth);
            self.eaten.back(r.eaten);
            self.moving.back(r.moving);
            std.debug.assert(self.from.refcount == 0 and self.poops.refcount == 0 and self.homes.refcount == 0);
            return r;
        }
    };
}

/// A Roc crash: an overflow, or a division by zero, in the wish. The
/// physics' numbers keep it from both; one is a bug, so a panic.
export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    std.debug.panic("roc crashed: {s}", .{bytes[0..len]});
}

/// Roc drops its reference to a list it only read at the end of a call:
/// for static data, no call here; and it hands back every list it changed.
/// One is a broken seam (a refcount word moved, or a list kept).
export fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    _ = ptr;
    _ = alignment;
    @panic("roc_dealloc: Roc freed a list the physics lent it as static data");
}

/// Roc asks for memory only to grow a list past its room, and every list is
/// lent with room for all a call puts in it: one is a broken seam.
export fn roc_alloc(len: usize, alignment: usize) callconv(.c) *anyopaque {
    _ = len;
    _ = alignment;
    @panic("roc_alloc: Roc grew a list past the room the physics lent it");
}

export fn roc_realloc(ptr: *anyopaque, len: usize, alignment: usize) callconv(.c) *anyopaque {
    _ = ptr;
    _ = len;
    _ = alignment;
    @panic("roc_realloc: Roc grew a list past the room the physics lent it");
}

comptime {
    // The layouts Roc's records have.
    std.debug.assert(@sizeOf(Crit) == 24 and @sizeOf(Poop) == 12 and @sizeOf(Walked) == std.mem.alignForward(usize, 5 * @sizeOf(RocList) + 10 * 4, @alignOf(RocList)));
}
