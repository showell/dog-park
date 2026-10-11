//! What the store keeps of a dog. **A FIXED LAYOUT** (an extern struct, 24
//! bytes, no padding the compiler chose), each field named for its frame,
//! with a format number first, so a record written today is read the same
//! by any later version that knows its format. **LITTLE-ENDIAN**, asserted:
//! every host Dog Park runs on (a Linux droplet, the bare-metal host) is
//! x86_64, so the host's order is the record's.

const std = @import("std");
const frames = @import("frames.zig");
const park = @import("park.zig");
const dogs = @import("dogs.zig");
const HumanId = @import("humans.zig").HumanId;

pub const Format = enum(u8) { v1 = 1, _ };

pub const StoredDog = extern struct {
    format: Format,
    /// A `dogs.Breed`'s number, kept as a byte: a record is not trusted to
    /// hold a breed this version knows.
    breed_byte: u8,
    /// Zero in v1, and not read: a later format may give it meaning.
    reserved: [6]u8 = @splat(0),
    owner: u64,
    park_x: frames.Coord,
    park_y: frames.Coord,

    comptime {
        std.debug.assert(@sizeOf(StoredDog) == 24);
        std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
    }

    pub fn of(d: dogs.Dog) StoredDog {
        return .{
            .format = .v1,
            .breed_byte = @intFromEnum(d.breed),
            .owner = d.owner.number(),
            .park_x = d.at.point.x.number(),
            .park_y = d.at.point.y.number(),
        };
    }

    /// The dog a record stands for in `p`, or why it is not one.
    pub fn read(self: StoredDog, p: park.Park) Read {
        if (self.format != .v1) return .{ .unknown_format = @intFromEnum(self.format) };
        const breed = std.enums.fromInt(dogs.Breed, self.breed_byte) orelse
            return .{ .unknown_breed = self.breed_byte };
        const at: frames.ParkPoint = .at(self.park_x, self.park_y);
        return switch (p.holding(at)) {
            .inside => |in| .{ .dog = .{ .owner = HumanId.of(self.owner), .at = in, .breed = breed } },
            .outside => .{ .outside_park = at },
        };
    }
};

pub const Read = union(enum) {
    dog: dogs.Dog,
    unknown_format: u8,
    unknown_breed: u8,
    outside_park: frames.ParkPoint,
};

const testing = std.testing;

const small: park.Park = (park.Park.of(.{ .width = 1000, .height = 600 })).park;

test "a dog of every breed stored and read back is the same dog" {
    inline for (@typeInfo(dogs.Breed).@"enum".fields) |f| {
        const d: dogs.Dog = .{ .owner = .of(std.math.maxInt(u64)), .at = .{ .point = .at(999, 0) }, .breed = @field(dogs.Breed, f.name) };
        try testing.expectEqual(d, StoredDog.of(d).read(small).dog);
    }
}

test "a record this version cannot read is said, not guessed" {
    const base = StoredDog.of(.{ .owner = .of(1), .at = .{ .point = .at(0, 0) }, .breed = .dog });
    var r = base;
    r.format = @enumFromInt(9);
    try testing.expectEqual(@as(u8, 9), r.read(small).unknown_format);
    r = base;
    r.breed_byte = @typeInfo(dogs.Breed).@"enum".fields.len;
    try testing.expectEqual(r.breed_byte, r.read(small).unknown_breed);
    r = base;
    r.park_x = 1000;
    try testing.expectEqual(frames.ParkPoint.at(1000, 0), r.read(small).outside_park);
}
