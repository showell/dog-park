//! What the store keeps of a dog. **A FIXED LAYOUT** (an extern struct, 32
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

pub const Format = enum(u8) { v1 = 1, v2 = 2, _ };

/// What a record says of its dog's claim, as a byte.
pub const ClaimTag = enum(u8) { unclaimed = 0, claimed = 1, _ };

/// A dog, as `data/dogs/<id>` holds it. **FORMAT 2** (the dogs are fixed,
/// docs/FIXED-DOGS.md): its id, where it stands, its breed and its claim.
/// Format 1, a dog keyed by its owner, is not read: nothing was kept in it.
pub const StoredDog = extern struct {
    format: Format,
    /// A `dogs.Breed`'s number, kept as a byte: a record is not trusted to
    /// hold a breed this version knows.
    breed_byte: u8,
    claim_tag: ClaimTag,
    /// Zero in v2, and not read: a later format may give it meaning.
    reserved: u8 = 0,
    dog: u32,
    park_x: frames.Coord,
    park_y: frames.Coord,
    /// The claimant's id, and when they last touched it (unix seconds);
    /// zero for an unclaimed dog.
    claimed_by: u64,
    touched: i64,

    comptime {
        std.debug.assert(@sizeOf(StoredDog) == 32);
        std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
    }

    pub fn of(d: dogs.Dog) StoredDog {
        return .{
            .format = .v2,
            .breed_byte = @intFromEnum(d.breed),
            .claim_tag = switch (d.claim) {
                .unclaimed => .unclaimed,
                .claimed => .claimed,
            },
            .dog = d.id.number(),
            .park_x = d.at.point.x.number(),
            .park_y = d.at.point.y.number(),
            .claimed_by = switch (d.claim) {
                .unclaimed => 0,
                .claimed => |c| c.by.number(),
            },
            .touched = switch (d.claim) {
                .unclaimed => 0,
                .claimed => |c| c.touched.seconds(),
            },
        };
    }

    /// The dog a record stands for in `p`, or why it is not one.
    pub fn read(self: StoredDog, p: park.Park) Read {
        if (self.format != .v2) return .{ .unknown_format = @intFromEnum(self.format) };
        const breed = std.enums.fromInt(dogs.Breed, self.breed_byte) orelse
            return .{ .unknown_breed = self.breed_byte };
        const claim: dogs.Claim = switch (self.claim_tag) {
            .unclaimed => .unclaimed,
            .claimed => .{ .claimed = .{ .by = HumanId.of(self.claimed_by), .touched = .of(self.touched) } },
            _ => return .{ .unknown_claim = @intFromEnum(self.claim_tag) },
        };
        const at: frames.ParkPoint = .at(self.park_x, self.park_y);
        return switch (p.holding(at)) {
            .inside => |in| .{ .dog = .{ .id = .of(self.dog), .at = in, .breed = breed, .claim = claim } },
            .outside => .{ .outside_park = at },
        };
    }
};

pub const Read = union(enum) {
    dog: dogs.Dog,
    unknown_format: u8,
    unknown_breed: u8,
    unknown_claim: u8,
    outside_park: frames.ParkPoint,
};

const testing = std.testing;

const small: park.Park = (park.Park.of(.{ .width = 1000, .height = 600 })).park;

test "a dog of every breed and either claim, stored and read back, is the same dog" {
    inline for (@typeInfo(dogs.Breed).@"enum".fields) |f| {
        for ([_]dogs.Claim{ .unclaimed, .{ .claimed = .{ .by = .of(std.math.maxInt(u64)), .touched = .of(1_790_000_000) } } }) |claim| {
            const d: dogs.Dog = .{ .id = .of(399), .at = .{ .point = .at(999, 0) }, .breed = @field(dogs.Breed, f.name), .claim = claim };
            try testing.expectEqual(d, StoredDog.of(d).read(small).dog);
        }
    }
}

test "a record this version cannot read is said, not guessed" {
    const base = StoredDog.of(.{ .id = .of(1), .at = .{ .point = .at(0, 0) }, .breed = .dog, .claim = .unclaimed });
    var r = base;
    r.format = .v1;
    try testing.expectEqual(@as(u8, 1), r.read(small).unknown_format);
    r = base;
    r.breed_byte = @typeInfo(dogs.Breed).@"enum".fields.len;
    try testing.expectEqual(r.breed_byte, r.read(small).unknown_breed);
    r = base;
    r.claim_tag = @enumFromInt(7);
    try testing.expectEqual(@as(u8, 7), r.read(small).unknown_claim);
    r = base;
    r.park_x = 1000;
    try testing.expectEqual(frames.ParkPoint.at(1000, 0), r.read(small).outside_park);
}
