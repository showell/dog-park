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
    dog_face = 1,
    poodle = 2,
    guide_dog = 3,
    service_dog = 4,

    pub fn emoji(self: Breed) []const u8 {
        return switch (self) {
            .dog => "🐕",
            .dog_face => "🐶",
            .poodle => "🐩",
            .guide_dog => "🦮",
            .service_dog => "🐕‍🦺",
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

test "a dog's own frame is centred on it" {
    const d: Dog = .{ .owner = .of(1), .at = .{ .point = .at(300, 400) }, .breed = .poodle };
    try std.testing.expectEqual(frames.OwnDogPoint.at(0, 0), d.frame().fromPark(d.at.point));
}
