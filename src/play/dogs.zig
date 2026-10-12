//! The dogs: a fixed number, each with its id, its look and its park point.
//! The park is a plane of whole CSS pixels; north is smaller `park_y`.

const std = @import("std");
const tiles = @import("tiles.zig");

/// A dog is known by its place in the list, made once.
pub const DogId = enum(u16) { _ };

pub const ParkPoint = struct { park_x: i32, park_y: i32 };

pub const Dog = struct { emoji: []const u8, at: ParkPoint };

/// The first layout: in every tile of the world, three dogs in a blue tile
/// and two in a white one (a tile is blue when its column plus its row is
/// odd), at these places in the tile. Their looks take turns.
const in_blue = [_]ParkPoint{ .{ .park_x = 125, .park_y = 125 }, .{ .park_x = 375, .park_y = 250 }, .{ .park_x = 190, .park_y = 390 } };
const in_white = [_]ParkPoint{ .{ .park_x = 155, .park_y = 350 }, .{ .park_x = 350, .park_y = 150 } };
const looks = [_][]const u8{ "🐕", "🐩", "🦮", "🐶", "🐕‍🦺" };

const blue_tiles = tiles.world_tiles * tiles.world_tiles / 2;
const white_tiles = tiles.world_tiles * tiles.world_tiles - blue_tiles;
pub const dog_count = blue_tiles * in_blue.len + white_tiles * in_white.len;

/// What a request names: one of the dogs, or none of them.
pub const Lookup = union(enum) { dog: DogId, no_such_dog };

pub const LeashRequest = struct { dog: u32 };
/// A move: the dog's path since the server last had it, each whole park
/// pixel the page saw it at, in order (`[park_x, park_y]` each); it ends at
/// the last. The server replays the cows' rule along it, segment by segment,
/// as the page did.
pub const MoveRequest = struct { dog: u32, path: []const [2]i32 };

/// The most points one move's path holds: 100 at 12 bytes is well inside a
/// body's 4 KiB (app.zig's longest_body). A page with more to say replaces
/// its last point.
pub const most_path_points = 100;

/// How the dogs are written down: `{"dogs":[{"id","emoji","park_x","park_y"}, ...]}`.
const Written = struct { dogs: []const struct { id: u32, emoji: []const u8, park_x: i32, park_y: i32 } };

pub const Dogs = struct {
    list: [dog_count]Dog,

    pub fn laidOut() Dogs {
        var d: Dogs = undefined;
        var n: usize = 0;
        var row: i32 = 0;
        while (row < tiles.world_tiles) : (row += 1) {
            var col: i32 = 0;
            while (col < tiles.world_tiles) : (col += 1) {
                const places: []const ParkPoint = if (@mod(col + row, 2) == 1) &in_blue else &in_white;
                for (places) |p| {
                    d.list[n] = .{ .emoji = looks[n % looks.len], .at = .{
                        .park_x = col * tiles.tile_px + p.park_x,
                        .park_y = row * tiles.tile_px + p.park_y,
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
    /// it was kept. The looks are the layout's, so a file can't change them.
    pub fn read(bytes: []const u8) ReadError!Dogs {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const w = std.json.parseFromSliceLeaky(Written, arena.allocator(), bytes, .{}) catch return error.NotDogs;
        if (w.dogs.len != dog_count) return error.WrongDogs;
        var d = laidOut();
        for (w.dogs, &d.list, 0..) |stored, *dog, i| {
            if (stored.id != i or !std.mem.eql(u8, stored.emoji, dog.emoji)) return error.WrongDogs;
            dog.at = .{ .park_x = stored.park_x, .park_y = stored.park_y };
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

    pub fn lookup(self: *const Dogs, asked: u32) Lookup {
        _ = self;
        return if (asked < dog_count) .{ .dog = @enumFromInt(asked) } else .no_such_dog;
    }

    pub fn at(self: *const Dogs, dog: DogId) ParkPoint {
        return self.list[@intFromEnum(dog)].at;
    }

    pub fn moveTo(self: *Dogs, dog: DogId, to: ParkPoint) void {
        self.list[@intFromEnum(dog)].at = to;
    }
};

const testing = std.testing;

test "the first layout: 250 dogs; the white tile (0, 0) holds two, the blue tile (1, 0) three; the last in tile (9, 9)" {
    const d = Dogs.laidOut();
    try testing.expectEqual(@as(usize, 250), dog_count);
    try testing.expectEqual(ParkPoint{ .park_x = 155, .park_y = 350 }, d.at(@enumFromInt(0)));
    try testing.expectEqual(ParkPoint{ .park_x = 350, .park_y = 150 }, d.at(@enumFromInt(1)));
    try testing.expectEqual(ParkPoint{ .park_x = 625, .park_y = 125 }, d.at(@enumFromInt(2)));
    try testing.expectEqual(tiles.Tile{ .col = 9, .row = 9 }, tiles.Tile.of(d.at(@enumFromInt(dog_count - 1))));
}

test "dogs written read back the same, moves and all" {
    var d = Dogs.laidOut();
    d.moveTo(@enumFromInt(2), .{ .park_x = -5000, .park_y = 77 });
    const bytes = try d.written(testing.allocator);
    defer testing.allocator.free(bytes);
    const back = try Dogs.read(bytes);
    try testing.expectEqual(ParkPoint{ .park_x = -5000, .park_y = 77 }, back.at(@enumFromInt(2)));
    try testing.expectEqual(d.at(@enumFromInt(14)), back.at(@enumFromInt(14)));
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

test "a lookup: the last dog is one, the next number is no dog" {
    const d = Dogs.laidOut();
    try testing.expectEqual(Lookup{ .dog = @enumFromInt(dog_count - 1) }, d.lookup(dog_count - 1));
    try testing.expectEqual(Lookup.no_such_dog, d.lookup(dog_count));
}
