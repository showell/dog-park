//! The population: every dog, kept in a spatial index. What it is asked and
//! what it answers, and the interface an index provides. No index lives
//! here; the box writes one (a quadtree, or simpler) against this.

const std = @import("std");
const frames = @import("frames.zig");
const park = @import("park.zig");
const dogs = @import("dogs.zig");
const DogId = dogs.DogId;

/// The dogs in a region of the park, but `except`: the asking human's own
/// dog comes apart (scene.Scene.own), so it is never among the others.
pub const Near = struct {
    region: park.ParkRect,
    except: Except,
};

/// The dog a query leaves out: the asker's own, or none (an asker with no
/// dog sees every dog).
pub const Except = union(enum) {
    nothing,
    dog: DogId,

    pub fn excludes(self: Except, id: DogId) bool {
        return switch (self) {
            .nothing => false,
            .dog => |own| own == id,
        };
    }
};

/// What `near` answers: how many dogs it wrote into the caller's slice (the
/// slice's length is the most it may write), and whether those are all.
pub const Found = struct {
    count: u32,
    completeness: Completeness,

    /// The dogs found: the front of the slice `near` wrote into.
    pub fn dogsIn(self: Found, into: []const dogs.Dog) []const dogs.Dog {
        return into[0..self.count];
    }
};

pub const Completeness = enum { all_in_region, more_in_region };

/// A dog looked up by its id: there, or not one this population holds.
pub const Lookup = union(enum) {
    found: dogs.Dog,
    no_dog,
};

/// What a population does. **KEYED BY DOG**: `put` replaces the dog of that
/// id, so a dog is never held twice.
pub const Population = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        near: *const fn (ptr: *anyopaque, q: Near, into: []dogs.Dog) Found,
        lookup: *const fn (ptr: *anyopaque, id: DogId) Lookup,
        put: *const fn (ptr: *anyopaque, dog: dogs.Dog) Put,
    };

    pub fn near(self: Population, q: Near, into: []dogs.Dog) Found {
        return self.vtable.near(self.ptr, q, into);
    }
    pub fn lookup(self: Population, id: DogId) Lookup {
        return self.vtable.lookup(self.ptr, id);
    }
    pub fn put(self: Population, dog: dogs.Dog) Put {
        return self.vtable.put(self.ptr, dog);
    }
};

/// What `put` did: took a dog it did not hold, moved one it did, or
/// refused (the index is full; its memory is bounded).
pub const Put = union(enum) {
    added,
    /// Where the dog stood before.
    replaced: park.InParkPoint,
    refused_full,
};

// ── the contract's reference ─────────────────────────────────────────────────

/// A population of at most `capacity` dogs, in a list: the contract's
/// reference, too slow to be an index, and the oracle an index is tested
/// against (index.zig).
pub fn ListPopulation(comptime capacity: usize) type {
    return struct {
        held: [capacity]dogs.Dog = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn population(self: *Self) Population {
            return .{ .ptr = self, .vtable = &.{ .near = near, .lookup = lookup, .put = put } };
        }

        fn of(ptr: *anyopaque) *Self {
            return @ptrCast(@alignCast(ptr));
        }

        fn near(ptr: *anyopaque, q: Near, into: []dogs.Dog) Found {
            const self = of(ptr);
            var count: u32 = 0;
            for (self.held[0..self.len]) |d| {
                if (q.except.excludes(d.id) or q.region.holds(d.at.point) == .outside) continue;
                if (count == into.len) return .{ .count = count, .completeness = .more_in_region };
                into[count] = d;
                count += 1;
            }
            return .{ .count = count, .completeness = .all_in_region };
        }

        fn lookup(ptr: *anyopaque, id: DogId) Lookup {
            for (of(ptr).held[0..of(ptr).len]) |d| if (d.id == id) return .{ .found = d };
            return .no_dog;
        }

        fn put(ptr: *anyopaque, dog: dogs.Dog) Put {
            const self = of(ptr);
            for (self.held[0..self.len]) |*d| if (d.id == dog.id) {
                const was = d.at;
                d.* = dog;
                return .{ .replaced = was };
            };
            if (self.len == capacity) return .refused_full;
            self.held[self.len] = dog;
            self.len += 1;
            return .added;
        }
    };
}

// ── tests: the interface's contract, on the smallest population ─────────────

const testing = std.testing;

fn dogAt(id: u32, x: frames.Coord, y: frames.Coord) dogs.Dog {
    return .{ .id = .of(id), .at = .{ .point = .at(x, y) }, .breed = .dog, .claim = .unclaimed };
}

test "put adds a dog, then replaces it: a dog is held once" {
    var list: ListPopulation(3) = .{};
    const pop = list.population();
    try testing.expectEqual(Put.added, pop.put(dogAt(1, 10, 10)));
    try testing.expectEqual(Put{ .replaced = .{ .point = .at(10, 10) } }, pop.put(dogAt(1, 20, 20)));
    try testing.expectEqual(dogAt(1, 20, 20), pop.lookup(.of(1)).found);
    try testing.expectEqual(Lookup.no_dog, pop.lookup(.of(2)));
    try testing.expectEqual(Put.added, pop.put(dogAt(2, 0, 0)));
    try testing.expectEqual(Put.added, pop.put(dogAt(3, 0, 0)));
    try testing.expectEqual(Put.refused_full, pop.put(dogAt(4, 0, 0)));
}

test "near leaves out the asker's dog, and says when its slice was too short" {
    var list: ListPopulation(3) = .{};
    const pop = list.population();
    _ = pop.put(dogAt(1, 10, 10));
    _ = pop.put(dogAt(2, 20, 20));
    _ = pop.put(dogAt(3, 30, 30));
    const everywhere: park.ParkRect = .{ .top_left = .at(0, 0), .size = .{ .width = 100, .height = 100 } };
    var into: [3]dogs.Dog = undefined;
    const all = pop.near(.{ .region = everywhere, .except = .{ .dog = .of(1) } }, &into);
    try testing.expectEqual(Completeness.all_in_region, all.completeness);
    try testing.expectEqual(@as(usize, 2), all.dogsIn(&into).len);
    for (all.dogsIn(&into)) |d| try testing.expect(d.id != DogId.of(1));
    const cut = pop.near(.{ .region = everywhere, .except = .{ .dog = .of(1) } }, into[0..1]);
    try testing.expectEqual(Completeness.more_in_region, cut.completeness);
    try testing.expectEqual(@as(usize, 1), cut.dogsIn(&into).len);
}
