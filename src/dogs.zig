//! Dogs. **THE DOGS ARE FIXED** (docs/FIXED-DOGS.md): a park has a number
//! of them, made once with its data and never made or destroyed after, each
//! with its own id. A human does not bring a dog: they are given one, which
//! is theirs once they drag it (docs/CLAIMS-V1.md).

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

/// A moment, in the wall clock's Unix seconds: when a provisional claim
/// ends. Not a duration.
pub const Instant = enum(i64) {
    _,

    pub fn of(unix_seconds: i64) Instant {
        return @enumFromInt(unix_seconds);
    }

    pub fn seconds(self: Instant) i64 {
        return @intFromEnum(self);
    }

    pub fn after(self: Instant, seconds_later: i64) Instant {
        return .of(self.seconds() +| seconds_later);
    }
};

/// **HOW LONG A NEW HUMAN HAS TO DRAG THEIR DOG** (docs/CLAIMS-V1.md): a
/// provisional claim ends this long after it was made, if the dog has not
/// been dragged.
pub const provisional_seconds: i64 = 120;

/// Who holds a dog: nobody; a new human, until they drag it or until it
/// ends (memory only: a restart forgets it); or a human for good.
pub const Claim = union(enum) {
    unclaimed,
    provisional: Provisional,
    held: Held,

    /// **THE CLAIM AS IT STANDS AT `now`**: a provisional claim at or past
    /// its end is no claim. The one place expiry is decided.
    pub fn at(self: Claim, now: Instant) Claim {
        return switch (self) {
            .provisional => |pc| if (now.seconds() >= pc.until.seconds()) .unclaimed else self,
            .unclaimed, .held => self,
        };
    }

    /// Who the claim names, ended or not.
    pub fn holder(self: Claim) ?HumanId {
        return switch (self) {
            .unclaimed => null,
            .provisional => |pc| pc.by,
            .held => |h| h.by,
        };
    }
};

pub const Provisional = struct {
    by: HumanId,
    until: Instant,

    /// A claim made at `now`, ending `provisional_seconds` after.
    pub fn madeAt(by: HumanId, now: Instant) Provisional {
        return .{ .by = by, .until = now.after(provisional_seconds) };
    }
};

pub const Held = struct {
    by: HumanId,
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

test "a provisional claim stands at 119 s and is gone at 120 s; a held claim never ends" {
    const made: Instant = .of(1_790_000_000);
    const pc: Claim = .{ .provisional = .madeAt(.of(7), made) };
    try std.testing.expectEqual(pc, pc.at(made.after(119)));
    try std.testing.expectEqual(Claim.unclaimed, pc.at(made.after(120)));
    try std.testing.expectEqual(Claim.unclaimed, pc.at(made.after(1_000_000)));
    const held: Claim = .{ .held = .{ .by = .of(7) } };
    try std.testing.expectEqual(held, held.at(made.after(std.math.maxInt(i64))));
    try std.testing.expectEqual(Claim.unclaimed, (Claim{ .unclaimed = {} }).at(made));
    // An end past i64's largest second saturates, and never wraps to the past.
    const far: Claim = .{ .provisional = .madeAt(.of(7), .of(std.math.maxInt(i64) - 5)) };
    try std.testing.expectEqual(far, far.at(.of(std.math.maxInt(i64) - 1)));
}

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
