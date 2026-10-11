//! Claiming (docs/FIXED-DOGS.md): the park's dogs, made once, and which of
//! them a newcomer claims. Pure: the world keeps what it decides.
//!
//! **A NEWCOMER CLAIMS** the unclaimed dog nearest the park's centre (the
//! wrapped distance, ties to the lower id), so the first humans see each
//! other; or, with every dog claimed, the one whose claim was touched
//! longest ago (ties to the lower id), which changes hands. With at least
//! one dog a claim always succeeds: there is no "park full".

const std = @import("std");
const frames = @import("frames.zig");
const park = @import("park.zig");
const dogs = @import("dogs.zig");
const HumanId = @import("humans.zig").HumanId;
const DogId = dogs.DogId;

/// How many dogs a park has: 400 of the 5,000 park's 2,500 lattice spots.
pub const dog_count: u32 = 400;

/// The seed of the shuffle that places the dogs and picks their breeds.
pub const dogs_seed: u64 = 0x0D06_9A2C;

/// What `makeDogs` made: the dogs, `0 ..< count`, each on its own lattice
/// spot, unclaimed; or why not.
pub const Made = union(enum) {
    made: []dogs.Dog,
    no_dogs,
    more_dogs_than_spots,
};

/// The park's dogs, made once: `count` lattice spots and breeds from a
/// seeded shuffle, so the same seed makes the same dogs.
pub fn makeDogs(allocator: std.mem.Allocator, p: park.Park, count: u32, seed: u64) !Made {
    const extent = p.extent();
    const spots = @as(usize, extent.columns) * extent.rows;
    if (count == 0) return .no_dogs;
    if (count > spots) return .more_dogs_than_spots;
    const order = try allocator.alloc(u32, spots);
    defer allocator.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    // The first `count` of a Fisher-Yates shuffle.
    for (0..count) |i| {
        const j = random.intRangeLessThan(usize, i, spots);
        std.mem.swap(u32, &order[i], &order[j]);
    }
    const made = try allocator.alloc(dogs.Dog, count);
    for (made, order[0..count], 0..) |*d, spot, i| {
        const lattice: park.LatticeSpot = .{ .column = @intCast(spot % extent.columns), .row = @intCast(spot / extent.columns) };
        d.* = .{
            .id = .of(@intCast(i)),
            .at = switch (p.pointOf(lattice)) {
                .on => |at| at,
                .off_park => unreachable, // a spot of this park's extent
            },
            .breed = random.enumValue(dogs.Breed),
            .claim = .unclaimed,
        };
    }
    return .{ .made = made };
}

/// Which dog a newcomer claims.
pub const Claiming = union(enum) {
    unclaimed: DogId,
    taken_over: TakenOver,
};

/// A dog that changes hands: it keeps where it stands.
pub const TakenOver = struct {
    dog: DogId,
    from: HumanId,
};

/// The claim for a newcomer, from every dog of the park (`all[i]` is dog
/// `i`, and there is at least one).
pub fn claimFor(p: park.Park, all: []const dogs.Dog) Claiming {
    std.debug.assert(all.len > 0);
    const centre: frames.ParkPoint = .at(p.size.width / 2, p.size.height / 2);
    var nearest: Best(u64) = .none_yet;
    var stalest: Best(i64) = .none_yet;
    for (all) |d| switch (d.claim) {
        .unclaimed => nearest.offer(wrappedDistanceSquared(p, d.at.point, centre), d.id),
        .claimed => |c| stalest.offer(c.touched.seconds(), d.id),
    };
    return switch (nearest) {
        .some => |n| .{ .unclaimed = n.id },
        .none_yet => switch (stalest) {
            .some => |s| .{ .taken_over = .{ .dog = s.id, .from = all[s.id.number()].claim.claimed.by } },
            .none_yet => unreachable, // every dog is claimed or not
        },
    };
}

/// The least of what is offered, ties to the lower id (`all` is offered in
/// id order, so the first offered of a tie is kept).
fn Best(comptime Key: type) type {
    return union(enum) {
        none_yet,
        some: struct { key: Key, id: DogId },

        fn offer(self: *@This(), key: Key, id: DogId) void {
            switch (self.*) {
                .none_yet => self.* = .{ .some = .{ .key = key, .id = id } },
                .some => |s| if (key < s.key) {
                    self.* = .{ .some = .{ .key = key, .id = id } };
                },
            }
        }
    };
}

/// The square of the distance from `a` to `b` the short way round the park.
pub fn wrappedDistanceSquared(p: park.Park, a: frames.ParkPoint, b: frames.ParkPoint) u64 {
    const dx = shortWay(a.x.number() - b.x.number(), p.size.width);
    const dy = shortWay(a.y.number() - b.y.number(), p.size.height);
    return dx * dx + dy * dy;
}

fn shortWay(d: frames.Coord, side: u31) u64 {
    const across: u64 = @abs(d);
    return @min(across, side - across);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const small: park.Park = (park.Park.of(.{ .width = 1000, .height = 1000 })).park;

fn dog(id: u32, x: frames.Coord, y: frames.Coord, claim: dogs.Claim) dogs.Dog {
    return .{ .id = .of(id), .at = small.wrap(.at(x, y)), .breed = .dog, .claim = claim };
}

fn by(human: u64, touched: i64) dogs.Claim {
    return .{ .claimed = .{ .by = .of(human), .touched = .of(touched) } };
}

test "a newcomer claims the unclaimed dog nearest the centre" {
    const all = [_]dogs.Dog{
        dog(0, 500, 500, by(1, 100)),
        dog(1, 650, 500, .unclaimed),
        dog(2, 520, 540, .unclaimed),
        dog(3, 900, 900, .unclaimed),
    };
    try testing.expectEqual(Claiming{ .unclaimed = .of(2) }, claimFor(small, &all));
}

test "nearness wraps: a dog across the seam from the centre's far side is near" {
    // The centre is (500, 500); a dog at x 999 is 499 away, and one at x 1
    // is 499 the other way: a tie, to the lower id.
    const all = [_]dogs.Dog{ dog(0, 999, 500, .unclaimed), dog(1, 1, 500, .unclaimed), dog(2, 0, 0, .unclaimed) };
    try testing.expectEqual(Claiming{ .unclaimed = .of(0) }, claimFor(small, &all));
    try testing.expectEqual(@as(u64, 499 * 499), wrappedDistanceSquared(small, .at(1, 500), .at(500, 500)));
    try testing.expectEqual(@as(u64, 2 * 2), wrappedDistanceSquared(small, .at(999, 0), .at(1, 0)));
}

test "with every dog claimed, the stalest claim changes hands; a tie goes to the lower id" {
    const all = [_]dogs.Dog{ dog(0, 500, 500, by(1, 300)), dog(1, 100, 100, by(2, 200)), dog(2, 0, 0, by(3, 200)) };
    try testing.expectEqual(Claiming{ .taken_over = .{ .dog = .of(1), .from = .of(2) } }, claimFor(small, &all));
}

test "the dogs are made the same from the same seed, each on its own spot, unclaimed" {
    const five = (park.Park.of(.{ .width = 5000, .height = 5000 })).park;
    const made = (try makeDogs(testing.allocator, five, dog_count, dogs_seed)).made;
    defer testing.allocator.free(made);
    try testing.expectEqual(@as(usize, dog_count), made.len);
    var spots: std.AutoHashMapUnmanaged(frames.ParkPoint, void) = .empty;
    defer spots.deinit(testing.allocator);
    for (made, 0..) |d, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), d.id.number());
        try testing.expectEqual(dogs.Claim.unclaimed, d.claim);
        try testing.expect(!(try spots.getOrPut(testing.allocator, d.at.point)).found_existing);
    }
    // The first dogs, pinned: a change to the shuffle or the seed is seen here.
    const again = (try makeDogs(testing.allocator, five, dog_count, dogs_seed)).made;
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(dogs.Dog, made, again);
    const pinned = [_]struct { x: frames.Coord, y: frames.Coord, breed: dogs.Breed }{
        .{ .x = 450, .y = 1650, .breed = .poodle },
        .{ .x = 3350, .y = 3150, .breed = .dog_face },
        .{ .x = 150, .y = 4350, .breed = .dog_face },
        .{ .x = 450, .y = 3150, .breed = .dog_face },
    };
    for (pinned, made[0..pinned.len]) |want, d| {
        try testing.expectEqual(frames.ParkPoint.at(want.x, want.y), d.at.point);
        try testing.expectEqual(want.breed, d.breed);
    }
}

test "a park with no dogs, or more dogs than spots, is not made" {
    try testing.expectEqual(Made.no_dogs, try makeDogs(testing.allocator, small, 0, dogs_seed));
    try testing.expectEqual(Made.more_dogs_than_spots, try makeDogs(testing.allocator, small, 101, dogs_seed));
    const all = (try makeDogs(testing.allocator, small, 100, dogs_seed)).made;
    testing.allocator.free(all);
}
