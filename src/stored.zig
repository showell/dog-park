//! What the store keeps of a dog. Plain fields in a fixed order, each named
//! for its frame, with a format number first, so a record written today is
//! read the same by any later version that knows its format.

const std = @import("std");
const frames = @import("frames.zig");
const dogs = @import("dogs.zig");
const HumanId = @import("humans.zig").HumanId;

pub const Format = enum(u8) { v1 = 1, _ };

pub const StoredDog = struct {
    format: Format,
    owner: u64,
    park_x: frames.Coord,
    park_y: frames.Coord,
    breed: dogs.Breed,

    pub fn of(d: dogs.Dog) StoredDog {
        return .{ .format = .v1, .owner = d.owner.number(), .park_x = d.at.x, .park_y = d.at.y, .breed = d.breed };
    }

    /// The dog a record stands for, or why it is not one.
    pub fn read(self: StoredDog) Read {
        return switch (self.format) {
            .v1 => .{ .dog = .{ .owner = HumanId.of(self.owner), .at = .{ .x = self.park_x, .y = self.park_y }, .breed = self.breed } },
            _ => .{ .unknown_format = @intFromEnum(self.format) },
        };
    }
};

pub const Read = union(enum) {
    dog: dogs.Dog,
    unknown_format: u8,
};

test "a dog stored and read back is the same dog" {
    const d: dogs.Dog = .{ .owner = HumanId.of(7), .at = .{ .x = 150, .y = 250 }, .breed = .poodle };
    try std.testing.expectEqual(d, StoredDog.of(d).read().dog);
}

test "a record of a format this does not know is said, not guessed" {
    var r = StoredDog.of(.{ .owner = HumanId.of(1), .at = .{ .x = 0, .y = 0 }, .breed = .dog });
    r.format = @enumFromInt(9);
    try std.testing.expectEqual(@as(u8, 9), r.read().unknown_format);
}
