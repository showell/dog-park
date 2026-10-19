const std = @import("std");

const RocList = extern struct { bytes: ?[*]u8, length: usize, capacity_or_alloc_ptr: usize };

extern fn roc_flip(mode: i64, l: RocList, j: u64) callconv(.c) RocList;

var allocs: usize = 0;
var arena: [1 << 16]u8 align(16) = undefined;
var used: usize = 0;

export fn roc_alloc(len: usize, alignment: usize) callconv(.c) *anyopaque {
    allocs += 1;
    used = std.mem.alignForward(usize, used, @max(alignment, 16));
    const p = &arena[used];
    used += len;
    return p;
}
export fn roc_realloc(ptr: *anyopaque, len: usize, alignment: usize) callconv(.c) *anyopaque {
    _ = ptr;
    return roc_alloc(len, alignment);
}
export fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    _ = ptr;
    _ = alignment;
}
export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    std.debug.print("roc crashed: {s}\n", .{bytes[0..len]});
    std.process.exit(2);
}

/// A lent list: the refcount word, then the items.
var lent: extern struct { refcount: isize, items: [4]u64 } = .{ .refcount = 1, .items = .{ 0, 0, 0, 0 } };

pub fn main() void {
    for ([_]i64{ 0, 1, 2, 3 }) |mode| {
        lent = .{ .refcount = 1, .items = .{ 0, 0, 0, 0 } };
        allocs = 0;
        const l: RocList = .{ .bytes = @ptrCast(&lent.items), .length = 4, .capacity_or_alloc_ptr = 4 << 1 };
        const r = roc_flip(mode, l, 70);
        const in_place = r.bytes == @as(?[*]u8, @ptrCast(&lent.items));
        std.debug.print("mode {d} ({s}): allocs {d}, in place {}, refcount {d}, word 1 = {x}\n", .{ mode, switch (mode) {
            0 => "inline",
            1 => "same module",
            2 => "Grid.roc",
            else => "plant: old list kept",
        }, allocs, in_place, lent.refcount, if (in_place) lent.items[1] else 0 });
    }
}
