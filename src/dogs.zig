//! Dogs. **THE DOGS ARE FIXED** (docs/FIXED-DOGS.md): a park has a number
//! of them, made once with its data and never made or destroyed after, each
//! with its own id. A human does not bring a dog: they claim one, and a dog
//! changes hands when every dog is claimed and its claim is the stalest.

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

/// A dog's id: `0 ..< count`, fixed when the park's dogs are made.
pub const DogId = enum(u32) {
    _,

    pub fn of(n: u32) DogId {
        return @enumFromInt(n);
    }

    pub fn number(self: DogId) u32 {
        return @intFromEnum(self);
    }
};

/// A moment, in the wall clock's Unix seconds: when a claim was last
/// touched. Not a duration, and not the monotonic clock's: a claim's
/// staleness is compared across restarts.
pub const Instant = enum(i64) {
    _,

    pub fn of(unix_seconds: i64) Instant {
        return @enumFromInt(unix_seconds);
    }

    pub fn seconds(self: Instant) i64 {
        return @intFromEnum(self);
    }
};

/// Who holds a dog: nobody, or a human, as of when they last asked for a
/// scene (a move or a stay: a human who only looks still holds their dog).
pub const Claim = union(enum) {
    unclaimed,
    claimed: Claimed,
};

pub const Claimed = struct {
    by: HumanId,
    touched: Instant,
};

/// A dog where it stands: its id, its place in the park, its look, and
/// who holds it.
pub const Dog = struct {
    id: DogId,
    at: park.InParkPoint,
    breed: Breed,
    claim: Claim,

    /// The dog with its owner left out, drawn at its copy nearest `near`.
    pub fn drawnNear(self: Dog, p: park.Park, near: frames.PlanePoint) Drawn {
        return .{ .at = p.nearestCopy(self.at, near), .breed = self.breed };
    }
};

/// A dog as drawn: a copy of it in the plane, and its look. No owner, so a
/// scene's own dog cannot name somebody else as its owner.
pub const Drawn = struct {
    at: frames.PlanePoint,
    breed: Breed,

    /// The frame centred on this copy of the dog.
    pub fn frame(self: Drawn) frames.OwnDogFrame {
        return .{ .dog_at = self.at };
    }
};

test "every breed has an emoji" {
    inline for (@typeInfo(Breed).@"enum".fields) |f| {
        try std.testing.expect(@field(Breed, f.name).emoji().len > 0);
    }
}

test "a dog is drawn at its copy nearest a plane point, and its frame is centred there" {
    const p = (park.Park.of(.{ .width = 1000, .height = 600 })).park;
    const d: Dog = .{ .id = .of(1), .at = p.wrap(.at(30, 400)), .breed = .poodle, .claim = .unclaimed };
    const drawn = d.drawnNear(p, .at(980, 400));
    try std.testing.expectEqual(frames.PlanePoint.at(1030, 400), drawn.at);
    try std.testing.expectEqual(frames.OwnDogPoint.at(0, 0), drawn.frame().fromPlane(drawn.at));
}
