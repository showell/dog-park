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

/// What a record says of its dog's claim, as a byte. Only a held claim is
/// ever kept: **A PROVISIONAL CLAIM LIVES IN MEMORY ONLY** (docs/CLAIMS-V1.md).
pub const ClaimTag = enum(u8) { unclaimed = 0, held = 1, _ };

/// A dog, as `data/dogs/<id>` holds it. **FORMAT 3** (docs/CLAIMS-V1.md):
/// its id, where it stands, its breed, and who holds it for good, a human of
/// 128 random bits. Nothing of when.
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
    /// Who holds the dog; zero for an unclaimed one.
    held_by: u128,

    comptime {
        std.debug.assert(@sizeOf(StoredDog) == 32);
        std.debug.assert(@offsetOf(StoredDog, "held_by") == 16);
        std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
    }

    /// The record of `d`: a provisional claim is kept as none, so a restart
    /// forgets it (its human is given a dog again on their next request).
    pub fn of(d: dogs.Dog) StoredDog {
        const held: ?HumanId = switch (d.claim) {
            .held => |h| h.by,
            .unclaimed, .provisional => null,
        };
        return .{
            .format = .v3,
            .breed_byte = @intFromEnum(d.breed),
            .claim_tag = if (held != null) .held else .unclaimed,
            .dog = d.id.number(),
            .park_x = d.at.point.x.number(),
            .park_y = d.at.point.y.number(),
            .held_by = if (held) |h| h.number() else 0,
        };
    }

    /// The dog a record stands for in `p`, or why it is not one.
    pub fn read(self: StoredDog, p: park.Park) Read {
        if (self.format != .v3) return .{ .unknown_format = @intFromEnum(self.format) };
        const breed = std.enums.fromInt(dogs.Breed, self.breed_byte) orelse
            return .{ .unknown_breed = self.breed_byte };
        const claim: dogs.Claim = switch (self.claim_tag) {
            .unclaimed => if (self.held_by != 0) return .unclaimed_names_a_human else .unclaimed,
            .held => if (self.held_by == 0) return .claim_by_no_human else .{ .held = .{ .by = HumanId.of(self.held_by) } },
            _ => return .{ .unknown_claim = @intFromEnum(self.claim_tag) },
        };
        return placed(self.dog, self.park_x, self.park_y, breed, claim, p);
    }
};

/// A format 2 record (32 bytes too): the same first 16 bytes, then a
/// claimant from the old counter and a touch, which are not read. **READ
/// WITH ITS CLAIM LET GO**: its claimant was a counter's number, which no
/// cookie names now (a cookie carries 128 random bits), so the dog is free
/// where it stands, and is written as format 3 the next time it changes.
pub const StoredDogV2 = extern struct {
    format: Format,
    breed_byte: u8,
    claim_tag: u8,
    reserved: u8,
    dog: u32,
    park_x: frames.Coord,
    park_y: frames.Coord,
    claimed_by: u64,
    touched: i64,

    comptime {
        std.debug.assert(@sizeOf(StoredDogV2) == 32);
    }

    pub fn read(self: StoredDogV2, p: park.Park) Read {
        if (self.format != .v2) return .{ .unknown_format = @intFromEnum(self.format) };
        const breed = std.enums.fromInt(dogs.Breed, self.breed_byte) orelse
            return .{ .unknown_breed = self.breed_byte };
        // Format 2's tags: 0 unclaimed, 1 claimed.
        if (self.claim_tag > 1) return .{ .unknown_claim = self.claim_tag };
        return placed(self.dog, self.park_x, self.park_y, breed, .unclaimed, p);
    }
};

fn placed(dog: u32, x: frames.Coord, y: frames.Coord, breed: dogs.Breed, claim: dogs.Claim, p: park.Park) Read {
    const at: frames.ParkPoint = .at(x, y);
    return switch (p.holding(at)) {
        .inside => |in| .{ .dog = .{ .id = .of(dog), .at = in, .breed = breed, .claim = claim } },
        .outside => .{ .outside_park = at },
    };
}

/// A record by its format byte: format 3, or format 2 with its claim let go;
/// null for one that is not 32 bytes.
pub fn readRecord(bytes: []const u8, p: park.Park) ?Read {
    if (bytes.len != @sizeOf(StoredDog)) return null;
    return switch (@as(Format, @enumFromInt(bytes[0]))) {
        .v2 => std.mem.bytesToValue(StoredDogV2, bytes).read(p),
        else => std.mem.bytesToValue(StoredDog, bytes).read(p),
    };
}

pub const Read = union(enum) {
    dog: dogs.Dog,
    claim_by_no_human,
    unclaimed_names_a_human,
    unknown_format: u8,
    unknown_breed: u8,
    unknown_claim: u8,
    outside_park: frames.ParkPoint,
};

const testing = std.testing;

const small: park.Park = (park.Park.of(.{ .width = 1000, .height = 600 })).park;

test "a dog of every breed, unclaimed or held, stored and read back, is the same dog" {
    inline for (@typeInfo(dogs.Breed).@"enum".fields) |f| {
        for ([_]dogs.Claim{ .unclaimed, .{ .held = .{ .by = .of(std.math.maxInt(u128)) } } }) |claim| {
            const d: dogs.Dog = .{ .id = .of(399), .at = .{ .point = .at(999, 0) }, .breed = @field(dogs.Breed, f.name), .claim = claim };
            try testing.expectEqual(d, readRecord(std.mem.asBytes(&StoredDog.of(d)), small).?.dog);
        }
    }
}

test "a provisional claim is never stored: the record says unclaimed" {
    const d: dogs.Dog = .{ .id = .of(3), .at = .{ .point = .at(5, 5) }, .breed = .dog, .claim = .{ .provisional = .madeAt(.of(9), .of(1_790_000_000)) } };
    try testing.expectEqual(dogs.Claim.unclaimed, StoredDog.of(d).read(small).dog.claim);
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
    r = base;
    r.claim_tag = .held; // by human 0
    try testing.expectEqual(Read.claim_by_no_human, r.read(small));
}

test "a format 2 record is the same dog, free where it stands" {
    const v2: StoredDogV2 = .{ .format = .v2, .breed_byte = @intFromEnum(dogs.Breed.poodle), .claim_tag = 1, .reserved = 0, .dog = 7, .park_x = 10, .park_y = 20, .claimed_by = 3, .touched = 1_790_000_000 };
    const d = readRecord(std.mem.asBytes(&v2), small).?.dog;
    try testing.expectEqual(dogs.Dog{ .id = .of(7), .at = small.wrap(.at(10, 20)), .breed = .poodle, .claim = .unclaimed }, d);
    var bad = v2;
    bad.claim_tag = 2;
    try testing.expectEqual(@as(u8, 2), readRecord(std.mem.asBytes(&bad), small).?.unknown_claim);
    try testing.expect(readRecord("short", small) == null);
    try testing.expect(readRecord(std.mem.asBytes(&v2) ++ "x", small) == null);
}
