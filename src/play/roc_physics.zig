//! **THE PHYSICS' ROC**: the critters' wish (roc/Wish.roc), compiled by
//! `zig build roc` into roc/lib/physics-<target>.a (checked in; no build
//! runs Roc), which every build of the physics links. This file is the
//! seam: the C function Roc provides, its arguments laid out as Roc lays
//! records out (fields by alignment, largest first, then by name), and the
//! two host functions the archive calls.
//!
//! The nearby critters go to Roc as a `List` over a buffer of this file's,
//! its refcount word Roc's "static data" (0): Roc neither frees it nor
//! writes it, so a wish allocates nothing on either side.

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
const RocList = extern struct { bytes: ?[*]u8, length: usize, capacity_or_alloc_ptr: usize };

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

/// A Roc crash: an overflow, or a division by zero, in the wish. The
/// physics' numbers keep it from both; one is a bug, so a panic.
export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    std.debug.panic("roc crashed: {s}", .{bytes[0..len]});
}

/// Roc drops its reference to the list at the end of a wish: for static
/// data, no call here. One is a broken seam (the refcount word moved).
export fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    _ = ptr;
    _ = alignment;
    @panic("roc_dealloc: Roc freed a list the physics lent it as static data");
}

comptime {
    // The layouts Roc's records have: 24, 8 and 12 bytes.
    std.debug.assert(@sizeOf(Near) == 24 and @sizeOf(Me) == 8 and @sizeOf(Out) == 12);
}
