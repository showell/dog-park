//! The cows: one in the middle of every white tile of the populated park
//! (tiles.zig), where the physics (physics.zig) moves them, scared of the
//! leashed dog's drag. Here: their first layout, the file that seeds the
//! physics' board (`cows.json`, in half pixels), and the numbers the
//! physics takes from them. Each critter is its sprite's square (a dog
//! `dog_px` a side, a cow `cow_px`), centred on its point.

const std = @import("std");
const dogs = @import("dogs.zig");
const tiles = @import("tiles.zig");
const ParkPoint = dogs.ParkPoint;

/// A cow is known by its place in the list, made once.
pub const CowId = enum(u16) { _ };

/// Where a cow stands, in HALF park pixels: (half_x / 2, half_y / 2) is its
/// park point.
pub const CowPoint = extern struct { half_x: i32, half_y: i32 };

/// The squares, as the page draws them (park.js's dog_px and cow_px).
pub const dog_px = 40;
pub const cow_px = 60;

/// How far a dog's move along an axis reaches: a cow at most this far ahead
/// on that axis, and at most this far off it, is scared (physics.zig's
/// `scoot`).
pub const scare_box_px = 280;

/// The least gap a cow keeps between the dog's square and its own: half a
/// dog.
pub const clearance_px = dog_px / 2;

/// The half-pixels in a pixel.
const halves = 2;

/// A cow's centre keeps its whole square in the world.
const lowest = (cow_px / 2) * halves;
const highest = (tiles.world_px - cow_px / 2) * halves;

pub const cow_count = tiles.park_tiles * tiles.park_tiles - tiles.park_tiles * tiles.park_tiles / 2;

fn inWorld(at: CowPoint) bool {
    return at.half_x >= lowest and at.half_x <= highest and at.half_y >= lowest and at.half_y <= highest;
}

/// A dog's park point in half pixels.
fn halvesOf(p: ParkPoint) CowPoint {
    return .{ .half_x = p.park_x * halves, .half_y = p.park_y * halves };
}

/// How the cows are written down, in half pixels:
/// `{"cows":[{"id","half_x","half_y"}, ...]}`.
const Written = struct { cows: []const struct { id: u32, half_x: i32, half_y: i32 } };

pub const Cows = struct {
    list: [cow_count]CowPoint,

    /// One cow in the middle of every white tile of the populated park (a
    /// tile is white when its column plus its row is even), row by row.
    pub fn laidOut() Cows {
        var c: Cows = undefined;
        var n: usize = 0;
        var row: i32 = 0;
        while (row < tiles.park_tiles) : (row += 1) {
            var col: i32 = 0;
            while (col < tiles.park_tiles) : (col += 1) {
                if (@mod(col + row, 2) == 1) continue;
                c.list[n] = halvesOf(.{
                    .park_x = tiles.park_offset_px + col * tiles.tile_px + tiles.tile_px / 2,
                    .park_y = tiles.park_offset_px + row * tiles.tile_px + tiles.tile_px / 2,
                });
                n += 1;
            }
        }
        std.debug.assert(n == cow_count);
        return c;
    }

    pub const ReadError = error{ NotCows, WrongCows };

    /// The cows as written: exactly the laid-out cows, in order, each where
    /// it was kept, its whole square in the world.
    pub fn read(bytes: []const u8) ReadError!Cows {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const w = std.json.parseFromSliceLeaky(Written, arena.allocator(), bytes, .{}) catch return error.NotCows;
        if (w.cows.len != cow_count) return error.WrongCows;
        var c = laidOut();
        for (w.cows, &c.list, 0..) |stored, *cow, i| {
            const kept: CowPoint = .{ .half_x = stored.half_x, .half_y = stored.half_y };
            if (stored.id != i or !inWorld(kept)) return error.WrongCows;
            cow.* = kept;
        }
        return c;
    }

    pub fn written(self: *const Cows, alloc: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        try out.writer.writeAll("{\"cows\":[");
        for (self.list, 0..) |cow, i| {
            if (i > 0) try out.writer.writeAll(",");
            try out.writer.print("\n{{\"id\":{d},\"half_x\":{d},\"half_y\":{d}}}", .{ i, cow.half_x, cow.half_y });
        }
        try out.writer.writeAll("\n]}\n");
        return out.toOwnedSlice();
    }

    pub fn at(self: *const Cows, cow: CowId) CowPoint {
        return self.list[@intFromEnum(cow)];
    }
};

const testing = std.testing;

/// A cow at (x, y) in half pixels.
fn h(x: i32, y: i32) CowPoint {
    return .{ .half_x = x, .half_y = y };
}

test "the first layout: a cow in the middle of each white tile of the park, row by row, in half pixels" {
    const c = Cows.laidOut();
    try testing.expectEqual(@as(usize, tiles.park_tiles * tiles.park_tiles / 2), cow_count);
    var n: usize = 0;
    var row: i32 = 0;
    while (row < tiles.park_tiles) : (row += 1) {
        var col: i32 = 0;
        while (col < tiles.park_tiles) : (col += 1) {
            if (@mod(col + row, 2) == 1) continue;
            const at = c.at(@enumFromInt(n));
            // Twice the park point of the tile's middle.
            try testing.expectEqual(h(2 * (tiles.park_offset_px + col * tiles.tile_px) + tiles.tile_px, 2 * (tiles.park_offset_px + row * tiles.tile_px) + tiles.tile_px), at);
            n += 1;
        }
    }
    try testing.expectEqual(cow_count, n);
}

test "cows written read back the same; a cow outside the world, missing or out of order does not read" {
    var c = Cows.laidOut();
    c.list[0] = h(501, 511);
    const bytes = try c.written(testing.allocator);
    defer testing.allocator.free(bytes);
    const back = try Cows.read(bytes);
    try testing.expectEqual(h(501, 511), back.at(@enumFromInt(0)));
    try testing.expectError(error.NotCows, Cows.read("not json"));
    try testing.expectError(error.WrongCows, Cows.read("{\"cows\":[]}"));
    const outside = try std.mem.replaceOwned(u8, testing.allocator, bytes, "\"half_x\":501,", "\"half_x\":59,");
    defer testing.allocator.free(outside);
    try testing.expectError(error.WrongCows, Cows.read(outside));
    const swapped = try std.mem.replaceOwned(u8, testing.allocator, bytes, "{\"id\":0,", "{\"id\":1,");
    defer testing.allocator.free(swapped);
    try testing.expectError(error.WrongCows, Cows.read(swapped));
}
