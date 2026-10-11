//! The population: every dog, kept in a spatial index. What it is asked and
//! what it answers, and the interface an index provides. No index lives
//! here; the box writes one (a quadtree, or simpler) against this.

const std = @import("std");
const frames = @import("frames.zig");
const park = @import("park.zig");
const dogs = @import("dogs.zig");
const HumanId = @import("humans.zig").HumanId;

/// The dogs in a region of the park, at most `most` of them.
pub const Near = struct {
    region: park.ParkRect,
    most: u32,
};

/// What `near` answers: the dogs found, written into the caller's slice,
/// and whether those are all of them.
pub const Found = struct {
    dogs: []const dogs.Dog,
    completeness: Completeness,
};

pub const Completeness = enum { all_in_region, cut_at_most };

/// A dog looked up by its owner: there, or the human has none yet.
pub const Lookup = union(enum) {
    found: dogs.Dog,
    no_dog: HumanId,
};

/// What a population does. **KEYED BY OWNER**: `put` replaces the owner's
/// dog, so one human cannot hold two.
pub const Population = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        near: *const fn (ptr: *anyopaque, q: Near, into: []dogs.Dog) Found,
        lookup: *const fn (ptr: *anyopaque, owner: HumanId) Lookup,
        put: *const fn (ptr: *anyopaque, dog: dogs.Dog) Put,
    };

    pub fn near(self: Population, q: Near, into: []dogs.Dog) Found {
        return self.vtable.near(self.ptr, q, into);
    }
    pub fn lookup(self: Population, owner: HumanId) Lookup {
        return self.vtable.lookup(self.ptr, owner);
    }
    pub fn put(self: Population, dog: dogs.Dog) Put {
        return self.vtable.put(self.ptr, dog);
    }
};

/// What `put` did: placed a new owner's dog, moved an owner's dog, or
/// refused (the index is full; its memory is bounded).
pub const Put = union(enum) {
    added,
    replaced: frames.ParkPoint, // where the dog stood before
    refused_full,
};

test "the interface's shapes compile" {
    std.testing.refAllDecls(@This());
}
