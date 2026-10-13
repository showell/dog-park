//! The dogs: a fixed number, each with its id, its look and its park point.
//! The park is a plane of whole CSS pixels; north is smaller `park_y`.

const std = @import("std");
const tiles = @import("tiles.zig");

/// A dog is known by its place in the list, made once.
pub const DogId = enum(u16) { _ };

pub const ParkPoint = struct { park_x: i32, park_y: i32 };

pub const Dog = struct { emoji: []const u8, at: ParkPoint };

/// The first layout: in every tile of the populated park (tiles.zig), four
/// dogs, one of each breed, each near its own corner of the tile: breed 0
/// north-west, 1 north-east, 2 south-west, 3 south-east. Dog n has look n
/// mod 4, its breed in the physics (docs/PHYSICS.md, "Breeds"), so a
/// tile's four dogs are numbered 4k to 4k + 3. White tiles also hold a cow
/// in the middle (cows.zig).
const corner_in = 75;
const corners = [_]ParkPoint{
    .{ .park_x = corner_in, .park_y = corner_in },
    .{ .park_x = tiles.tile_px - corner_in, .park_y = corner_in },
    .{ .park_x = corner_in, .park_y = tiles.tile_px - corner_in },
    .{ .park_x = tiles.tile_px - corner_in, .park_y = tiles.tile_px - corner_in },
};
pub const looks = [_][]const u8{ "🐕", "🐩", "🦮", "🐕‍🦺" };

pub const dog_count = tiles.park_tiles * tiles.park_tiles * corners.len;

/// How the dogs are written down: `{"dogs":[{"id","emoji","park_x","park_y"}, ...]}`.
const Written = struct { dogs: []const struct { id: u32, emoji: []const u8, park_x: i32, park_y: i32 } };

pub const Dogs = struct {
    list: [dog_count]Dog,

    pub fn laidOut() Dogs {
        var d: Dogs = undefined;
        var n: usize = 0;
        var row: i32 = 0;
        while (row < tiles.park_tiles) : (row += 1) {
            var col: i32 = 0;
            while (col < tiles.park_tiles) : (col += 1) {
                for (corners) |p| {
                    d.list[n] = .{ .emoji = looks[n % looks.len], .at = .{
                        .park_x = tiles.park_offset_px + col * tiles.tile_px + p.park_x,
                        .park_y = tiles.park_offset_px + row * tiles.tile_px + p.park_y,
                    } };
                    n += 1;
                }
            }
        }
        std.debug.assert(n == dog_count);
        return d;
    }

    pub const ReadError = error{ NotDogs, WrongDogs };

    /// The dogs as written: exactly the laid-out dogs, in order, each where
    /// it was kept, in the world. The looks are the layout's, so a file
    /// can't change them.
    pub fn read(bytes: []const u8) ReadError!Dogs {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const w = std.json.parseFromSliceLeaky(Written, arena.allocator(), bytes, .{}) catch return error.NotDogs;
        if (w.dogs.len != dog_count) return error.WrongDogs;
        var d = laidOut();
        for (w.dogs, &d.list, 0..) |stored, *dog, i| {
            const kept: ParkPoint = .{ .park_x = stored.park_x, .park_y = stored.park_y };
            if (stored.id != i or !std.mem.eql(u8, stored.emoji, dog.emoji) or tiles.where(kept) == .outside_world) return error.WrongDogs;
            dog.at = kept;
        }
        return d;
    }

    pub fn written(self: *const Dogs, alloc: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        try out.writer.writeAll("{\"dogs\":[");
        for (self.list, 0..) |dog, i| {
            if (i > 0) try out.writer.writeAll(",");
            try out.writer.print("\n{{\"id\":{d},\"emoji\":\"{s}\",\"park_x\":{d},\"park_y\":{d}}}", .{ i, dog.emoji, dog.at.park_x, dog.at.park_y });
        }
        try out.writer.writeAll("\n]}\n");
        return out.toOwnedSlice();
    }

    pub fn at(self: *const Dogs, dog: DogId) ParkPoint {
        return self.list[@intFromEnum(dog)].at;
    }
};

const testing = std.testing;

test "the first layout: four dogs to each tile of the park, one of each breed, breed b in the tile's corner b (NW, NE, SW, SE), numbered tile by tile" {
    const d = Dogs.laidOut();
    try testing.expectEqual(@as(usize, tiles.park_tiles * tiles.park_tiles * looks.len), dog_count);
    const half = tiles.tile_px / 2;
    for (d.list, 0..) |dog, n| {
        const breed = n % looks.len;
        try testing.expectEqualStrings(looks[breed], dog.emoji);
        // Its tile: the park's (n / 4)th, row by row.
        const k: i32 = @intCast(n / looks.len);
        const t = tiles.Tile.of(dog.at);
        const first = tiles.park_offset_px / tiles.tile_px;
        try testing.expectEqual(tiles.Tile{ .col = first + @mod(k, tiles.park_tiles), .row = first + @divFloor(k, tiles.park_tiles) }, t);
        // Its corner: east for breeds 1 and 3, south for 2 and 3.
        const in_x = dog.at.park_x - t.col * tiles.tile_px;
        const in_y = dog.at.park_y - t.row * tiles.tile_px;
        try testing.expectEqual(breed % 2 == 1, in_x >= half);
        try testing.expectEqual(breed >= 2, in_y >= half);
    }
}

test "dogs written read back the same, moves and all" {
    var d = Dogs.laidOut();
    d.list[2].at = .{ .park_x = 0, .park_y = tiles.world_px - 1 };
    const bytes = try d.written(testing.allocator);
    defer testing.allocator.free(bytes);
    const back = try Dogs.read(bytes);
    try testing.expectEqual(ParkPoint{ .park_x = 0, .park_y = tiles.world_px - 1 }, back.at(@enumFromInt(2)));
    try testing.expectEqual(d.at(@enumFromInt(14)), back.at(@enumFromInt(14)));
}

test "a dogs file with a dog outside the world does not read, as a cows file's does not" {
    for ([_]ParkPoint{ .{ .park_x = -1, .park_y = 77 }, .{ .park_x = 77, .park_y = tiles.world_px } }) |outside| {
        var d = Dogs.laidOut();
        d.list[2].at = outside;
        const bytes = try d.written(testing.allocator);
        defer testing.allocator.free(bytes);
        try testing.expectError(error.WrongDogs, Dogs.read(bytes));
    }
}

test "a dogs file with a dog missing, out of order, or another look does not read" {
    const d = Dogs.laidOut();
    const bytes = try d.written(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectError(error.NotDogs, Dogs.read("not json"));
    try testing.expectError(error.WrongDogs, Dogs.read("{\"dogs\":[]}"));
    const swapped = try std.mem.replaceOwned(u8, testing.allocator, bytes, "{\"id\":0,", "{\"id\":1,");
    defer testing.allocator.free(swapped);
    try testing.expectError(error.WrongDogs, Dogs.read(swapped));
}
