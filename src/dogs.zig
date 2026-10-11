//! Dogs. **A DOG IS KNOWN BY ITS OWNER.** Every human owns exactly one dog,
//! so a dog's id is its owner's: there is no dog without an owner, and no
//! way to name a second dog for one human. A population keyed by owner
//! (population.zig) holds at most one dog per human by construction.

const std = @import("std");
const frames = @import("frames.zig");
const HumanId = @import("humans.zig").HumanId;

pub const Breed = enum {
    dog,
    poodle,
    guide_dog,
    service_dog,
    hot_dog,
    wolf,
    fox,

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

/// A dog where it stands: its owner, its position in the park, its look.
pub const Dog = struct {
    owner: HumanId,
    at: frames.ParkPoint,
    breed: Breed,
};

test "every breed has an emoji" {
    inline for (@typeInfo(Breed).@"enum".fields) |f| {
        try std.testing.expect(@field(Breed, f.name).emoji().len > 0);
    }
}
