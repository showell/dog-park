//! **THE PHYSICS' ROC**: the critters' wish (roc/Wish.roc) and the walk
//! (roc/Walk.roc), compiled by `zig build roc` into
//! roc/lib/physics-<target>.a (checked in; no build runs Roc), which every
//! build of the physics links. This file is the seam: the C functions Roc
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

/// One moving critter the wisher sees (roc/Wish.roc's `Near`): who it is to
/// the wisher (`kind`: physics.zig's `Kind`; `kin`: a dog of the wisher's
/// breed, the wisher a dog), its seen index `j` for ties, its square's half
/// side, and the vectors from it to the wisher (`ax`, `ay`) and back
/// (`tx`, `ty`), the short way round the world.
pub const Near = extern struct { ax: i32, ay: i32, half: i32, tx: i32, ty: i32, j: u16, kin: bool, kind: u8 };

/// The wisher (`Me`): its square's half side, and its kind.
pub const Me = extern struct { half: i32, kind: u8 };

/// What it wants (`Out`): a step, and its anchor's seen index, or -1.
pub const Out = extern struct { anchor: i32, x: i32, y: i32 };

/// Roc's `List`: its elements, how many, and its capacity shifted left one
/// (the low bit clear: no seamless slice).
pub const RocList = extern struct { bytes: ?[*]u8, length: usize, capacity_or_alloc_ptr: usize };

extern fn roc_wish(me: Me, near: RocList) callconv(.c) Out;

/// The nearby critters, after Roc's refcount word: 0, static data.
pub fn Neighbours(comptime most: usize) type {
    return extern struct {
        refcount: isize align(@alignOf(usize)) = 0,
        items: [most]Near = undefined,
        len: usize = 0,

        pub fn push(self: *@This(), n: Near) void {
            self.items[self.len] = n;
            self.len += 1;
        }

        /// The wish of `me`, from these.
        pub fn wish(self: *@This(), me: Me) Out {
            std.debug.assert(self.refcount == 0);
            return roc_wish(me, .{
                .bytes = if (self.len == 0) null else @ptrCast(&self.items),
                .length = self.len,
                .capacity_or_alloc_ptr = self.len << 1,
            });
        }
    };
}

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
pub const not_lined_up: i64 = -1;
pub const visited: i64 = -2;

/// A poop the physics sees, and its slot (`Poop`).
pub const Poop = extern struct { x: i32, y: i32, slot: u16 };

const Walked = extern struct { cells: RocList, crits: RocList, depth: RocList, moving: RocList, anchor: i32, pooper: i32 };

extern fn roc_walk(most: i32, side: i32, from: RocList, poops: RocList, cells: RocList, crits: RocList, depth: RocList, moving: RocList) callconv(.c) Walked;

/// **THE WALK'S LISTS** (roc/Walk.roc's `Lent` and `Work`), for at most
/// `seen_most` critters, `moving_most` of them in motion, `poops_most`
/// poops, `tiles` tiles and `side` by `side` cells. The physics fills
/// `poops` and `from` whenever the poops change, and `crits` and `cells`
/// (`words` a cell, `cellPut`) for each walk; the walk changes those two and
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

        pub const words = std.math.divCeil(usize, seen_most, 64) catch unreachable;

        /// No critter in any cell.
        pub fn cellsClear(self: *@This()) void {
            self.cells.len = side * side * words;
            @memset(&self.cells.items, 0);
        }

        /// Seen critter `j` stands in cell `c`.
        pub fn cellPut(self: *@This(), c: u16, j: usize) void {
            self.cells.items[@as(usize, c) * words + j / 64] |= @as(u64, 1) << @intCast(j % 64);
        }

        /// The walk after the leashed dog's step of size `most`: the
        /// lists as it left them, and its pooper and the pooper's anchor
        /// (-1, none).
        pub fn run(self: *@This(), most: i32) struct { pooper: usize, anchor: i32 } {
            const n = self.crits.len;
            self.depth.len = n;
            self.moving.len = 0;
            const r = roc_walk(most, side, self.from.toRead(), self.poops.toRead(), self.cells.toChange(), self.crits.toChange(), self.depth.toChange(), self.moving.toChange());
            self.cells.back(r.cells);
            self.crits.back(r.crits);
            self.depth.back(r.depth);
            self.moving.back(r.moving);
            std.debug.assert(self.crits.len == n and self.from.refcount == 0 and self.poops.refcount == 0);
            return .{ .pooper = @intCast(r.pooper), .anchor = r.anchor };
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
    std.debug.assert(@sizeOf(Crit) == 24 and @sizeOf(Poop) == 12 and @sizeOf(Walked) == 4 * @sizeOf(RocList) + 8);
    std.debug.assert(@sizeOf(Near) == 24 and @sizeOf(Me) == 8 and @sizeOf(Out) == 12);
}
