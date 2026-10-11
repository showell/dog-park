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

pub const Format = enum(u8) { v1 = 1, v2 = 2, v3 = 3, _ };

/// What a record says of its dog's claim, as a byte.
pub const ClaimTag = enum(u8) { unclaimed = 0, claimed = 1, _ };

/// A dog, as `data/dogs/<id>` holds it. **FORMAT 3** (docs/CLAIMS-V1.md):
/// its id, where it stands, its breed and its claim, by a human of 128 random
/// bits. **FORMAT 2 IS READ WITH ITS CLAIM LET GO**: its claimant was a
/// number from a counter, which no cookie names now (a cookie carries 128
/// bits), so the dog is free where it stands, and is written as format 3 the
/// next time it changes. Format 1, a dog keyed by its owner, is not read:
/// nothing was kept in it.
pub const StoredDog = extern struct {
    format: Format,
    /// A `dogs.Breed`'s number, kept as a byte: a record is not trusted to
    /// hold a breed this version knows.
    breed_byte: u8,
    claim_tag: ClaimTag,
    /// Zero, and not read: a later format may give it meaning.
    reserved: u8 = 0,
    dog: u32,
    park_x: frames.Coord,
    park_y: frames.Coord,
    /// The claimant's id, and when they last touched it (unix seconds);
    /// zero for an unclaimed dog.
    claimed_by: u128,
    touched: i64,
    /// Zero, and not read.
    reserved_end: i64 = 0,

    comptime {
        std.debug.assert(@sizeOf(StoredDog) == 48);
        std.debug.assert(@offsetOf(StoredDog, "claimed_by") == 16);
        std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
    }

    pub fn of(d: dogs.Dog) StoredDog {
        return .{
            .format = .v3,
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
        if (self.format != .v3) return .{ .unknown_format = @intFromEnum(self.format) };
        const breed = std.enums.fromInt(dogs.Breed, self.breed_byte) orelse
            return .{ .unknown_breed = self.breed_byte };
        const claim: dogs.Claim = switch (self.claim_tag) {
            .unclaimed => .unclaimed,
            .claimed => if (self.claimed_by == 0)
                return .claim_by_no_human
            else
                .{ .claimed = .{ .by = HumanId.of(self.claimed_by), .touched = .of(self.touched) } },
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
    claim_by_no_human,
    unknown_format: u8,
    unknown_breed: u8,
    unknown_claim: u8,
    outside_park: frames.ParkPoint,
};

const testing = std.testing;

const small: park.Park = (park.Park.of(.{ .width = 1000, .height = 600 })).park;

test "a dog of every breed and either claim, stored and read back, is the same dog" {
    inline for (@typeInfo(dogs.Breed).@"enum".fields) |f| {
        for ([_]dogs.Claim{ .unclaimed, .{ .claimed = .{ .by = .of(std.math.maxInt(u128)), .touched = .of(1_790_000_000) } } }) |claim| {
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

/// A format 2 record (32 bytes): the same first 16 bytes, then a claimant
/// from the old counter and a touch, which are not read.
pub const StoredDogV2 = extern struct {
    format: Format,
    breed_byte: u8,
    claim_tag: ClaimTag,
    reserved: u8,
    dog: u32,
    park_x: frames.Coord,
    park_y: frames.Coord,
    claimed_by: u64,
    touched: i64,

    comptime {
        std.debug.assert(@sizeOf(StoredDogV2) == 32);
    }

    /// The dog it stands for, its claim let go (no cookie names a counter's
    /// number now).
    pub fn read(self: StoredDogV2, p: park.Park) Read {
        if (self.format != .v2) return .{ .unknown_format = @intFromEnum(self.format) };
        const breed = std.enums.fromInt(dogs.Breed, self.breed_byte) orelse
            return .{ .unknown_breed = self.breed_byte };
        switch (self.claim_tag) {
            .unclaimed, .claimed => {},
            _ => return .{ .unknown_claim = @intFromEnum(self.claim_tag) },
        }
        const at: frames.ParkPoint = .at(self.park_x, self.park_y);
        return switch (p.holding(at)) {
            .inside => |in| .{ .dog = .{ .id = .of(self.dog), .at = in, .breed = breed, .claim = .unclaimed } },
            .outside => .{ .outside_park = at },
        };
    }
};

/// A record of either size: format 3's, or format 2's, read with its claim
/// let go. Anything else is a record of the wrong size.
pub fn readRecord(bytes: []const u8, p: park.Park) ?Read {
    if (bytes.len == @sizeOf(StoredDog)) return std.mem.bytesToValue(StoredDog, bytes).read(p);
    if (bytes.len == @sizeOf(StoredDogV2)) return std.mem.bytesToValue(StoredDogV2, bytes).read(p);
    return null;
}

test "a format 2 record is the same dog, free where it stands" {
    const v2: StoredDogV2 = .{ .format = .v2, .breed_byte = @intFromEnum(dogs.Breed.poodle), .claim_tag = .claimed, .reserved = 0, .dog = 7, .park_x = 10, .park_y = 20, .claimed_by = 3, .touched = 1_790_000_000 };
    const d = readRecord(std.mem.asBytes(&v2), small).?.dog;
    try testing.expectEqual(dogs.Dog{ .id = .of(7), .at = small.wrap(.at(10, 20)), .breed = .poodle, .claim = .unclaimed }, d);
    try testing.expect(readRecord("short", small) == null);
}

test "a format 3 claim by human zero is said, not read as a human" {
    var r = StoredDog.of(.{ .id = .of(1), .at = .{ .point = .at(0, 0) }, .breed = .dog, .claim = .unclaimed });
    r.claim_tag = .claimed;
    try testing.expectEqual(Read.claim_by_no_human, r.read(small));
}
