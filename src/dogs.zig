//! Dogs. **A DOG IS KNOWN BY ITS OWNER.** Every human owns exactly one dog,
//! so a dog's id is its owner's: there is no dog without an owner, and no
//! way to name a second dog for one human. A population keyed by owner
//! (population.zig) holds at most one dog per human by construction.

const std = @import("std");
const frames = @import("frames.zig");
const park = @import("park.zig");
const HumanId = @import("humans.zig").HumanId;

/// A dog's look. **THE NUMBERS ARE STORED** (stored.zig): a new breed takes
/// the next number, and none is ever renumbered or reused.
pub const Breed = enum(u8) {
    dog = 0,
    poodle = 1,
    guide_dog = 2,
    service_dog = 3,
    hot_dog = 4,
    wolf = 5,
    fox = 6,

    pub fn emoji(self: Breed) []const u8 {
        return switch (self) {
            .dog => "🐕",
            .poodle => "🐩",
            .guide_dog => "🦮",
            .service_dog => "🐕‍🦺",
            .hot_dog => "🌭",
            .wolf => "🐺",
            .fox => "🦊",
        };
    }
};

/// A dog where it stands: its owner, its place in the park, its look.
pub const Dog = struct {
    owner: HumanId,
    at: park.InParkPoint,
    breed: Breed,

    /// The dog with its owner left out: what a scene shows of it.
    pub fn drawn(self: Dog) Drawn {
        return .{ .at = self.at, .breed = self.breed };
    }

    /// The frame centred on this dog.
    pub fn frame(self: Dog) frames.OwnDogFrame {
        return .{ .dog_at = self.at.point };
    }
};

/// A dog as drawn: where, and its look. No owner, so a scene's own dog
/// cannot name somebody else as its owner.
pub const Drawn = struct {
    at: park.InParkPoint,
    breed: Breed,
};

test "every breed has an emoji" {
    inline for (@typeInfo(Breed).@"enum".fields) |f| {
        try std.testing.expect(@field(Breed, f.name).emoji().len > 0);
    }
}

test "the breeds are numbered 0 up, with no gap (stored.zig reads them so)" {
    inline for (@typeInfo(Breed).@"enum".fields, 0..) |f, i| {
        try std.testing.expectEqual(i, f.value);
    }
}

test "a dog's own frame is centred on it" {
    const d: Dog = .{ .owner = .of(1), .at = .{ .point = .at(300, 400) }, .breed = .wolf };
    try std.testing.expectEqual(frames.OwnDogPoint.at(0, 0), d.frame().fromPark(d.at.point));
}
