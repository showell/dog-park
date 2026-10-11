//! The dogs: a fixed few, each with its id, its look and its park point.
//! The park is a plane of whole CSS pixels; north is smaller `park_y`.

const std = @import("std");

/// A dog is known by its place in the list, made once.
pub const DogId = enum(u8) { _ };

pub const ParkPoint = struct { park_x: i32, park_y: i32 };

pub const Dog = struct { emoji: []const u8, at: ParkPoint };

/// The screen the first layout is drawn for: dogs are laid out as fractions
/// of it, three on it, one just past each edge, a pair past each corner.
pub const first_screen = .{ .width = 1280, .height = 800 };

const Placed = struct { emoji: []const u8, fx: f32, fy: f32 };
const first_layout = [_]Placed{
    .{ .emoji = "🐕", .fx = 0.5, .fy = 0.5 },
    .{ .emoji = "🐩", .fx = 0.3, .fy = 0.35 },
    .{ .emoji = "🦮", .fx = 0.7, .fy = 0.65 },
    .{ .emoji = "🐶", .fx = 0.5, .fy = -0.2 },
    .{ .emoji = "🐕‍🦺", .fx = 0.5, .fy = 1.2 },
    .{ .emoji = "🐩", .fx = -0.2, .fy = 0.5 },
    .{ .emoji = "🦮", .fx = 1.2, .fy = 0.5 },
    .{ .emoji = "🐶", .fx = 1.2, .fy = -0.2 },
    .{ .emoji = "🐩", .fx = 1.28, .fy = -0.2 },
    .{ .emoji = "🐕‍🦺", .fx = 1.2, .fy = 1.2 },
    .{ .emoji = "🦮", .fx = 1.28, .fy = 1.2 },
    .{ .emoji = "🐶", .fx = -0.2, .fy = 1.2 },
    .{ .emoji = "🐕‍🦺", .fx = -0.28, .fy = 1.2 },
    .{ .emoji = "🐩", .fx = -0.2, .fy = -0.2 },
    .{ .emoji = "🦮", .fx = -0.28, .fy = -0.2 },
};

pub const dog_count = first_layout.len;

/// What a request names: one of the dogs, or none of them.
pub const Lookup = union(enum) { dog: DogId, no_such_dog };

pub const LeashRequest = struct { dog: u32 };
pub const MoveRequest = struct { dog: u32, park_x: i32, park_y: i32 };

/// How the dogs are written down: `{"dogs":[{"id","emoji","park_x","park_y"}, ...]}`.
const Written = struct { dogs: []const struct { id: u32, emoji: []const u8, park_x: i32, park_y: i32 } };

pub const Dogs = struct {
    list: [dog_count]Dog,

    pub fn laidOut() Dogs {
        var d: Dogs = undefined;
        for (first_layout, &d.list) |p, *dog| dog.* = .{ .emoji = p.emoji, .at = .{
            .park_x = @intFromFloat(@round(p.fx * first_screen.width)),
            .park_y = @intFromFloat(@round(p.fy * first_screen.height)),
        } };
        return d;
    }

    pub const ReadError = error{ NotDogs, WrongDogs };

    /// The dogs as written: exactly the laid-out dogs, in order, each where
    /// it was kept. The looks are the layout's, so a file can't change them.
    pub fn read(bytes: []const u8) ReadError!Dogs {
        var buf: [16 * 1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const w = std.json.parseFromSliceLeaky(Written, fba.allocator(), bytes, .{}) catch return error.NotDogs;
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

test "the first layout: the middle dog at the first screen's centre, the north one 20% past its top" {
    const d = Dogs.laidOut();
    try testing.expectEqual(ParkPoint{ .park_x = 640, .park_y = 400 }, d.at(@enumFromInt(0)));
    try testing.expectEqual(ParkPoint{ .park_x = 640, .park_y = -160 }, d.at(@enumFromInt(3)));
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
