//! The humans: each a device's random id, where its viewport was, and the
//! dog it holds on a leash. Leashes live in memory only; a viewport is kept
//! on disk, one small file a human.

const std = @import("std");
const Io = @import("host_io").Io;
const dogs = @import("dogs.zig");
const tiles = @import("tiles.zig");

/// 128 random bits, written as 32 lowercase hex digits (its cookie and its
/// file's name).
pub const HumanId = enum(u128) {
    _,

    pub const hex_len = 32;

    pub fn random(io: Io) HumanId {
        var bytes: [16]u8 = undefined;
        io.random(&bytes);
        return @enumFromInt(std.mem.readInt(u128, &bytes, .little));
    }

    pub fn hex(self: HumanId) [hex_len]u8 {
        var out: [hex_len]u8 = undefined;
        _ = std.fmt.bufPrint(&out, "{x:0>32}", .{@intFromEnum(self)}) catch unreachable;
        return out;
    }

    pub const Parsed = union(enum) { id: HumanId, not_an_id };

    /// Exactly 32 lowercase hex digits, and nothing else.
    pub fn parse(text: []const u8) Parsed {
        if (text.len != hex_len) return .not_an_id;
        for (text) |c| switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => return .not_an_id,
        };
        return .{ .id = @enumFromInt(std.fmt.parseInt(u128, text, 16) catch return .not_an_id) };
    }
};

pub fn validId(text: []const u8) bool {
    return HumanId.parse(text) == .id;
}

/// Where a human's viewport was, its top-left in the park: kept, or not
/// yet known (a first visit).
pub const Viewport = union(enum) { unknown, at: dogs.ParkPoint };

pub const Leash = union(enum) { none, dog: dogs.DogId };

pub const Human = struct {
    viewport: Viewport = .unknown,
    leash: Leash = .none,
    /// The tiles whose dogs this human's page is told of: the whole set, as
    /// its page last named them.
    tiles: tiles.Subscribed = .{},
};

/// Who holds each dog.
pub const Holder = union(enum) { free, human: HumanId };

/// What a leash asked for came to.
pub const Leashing = union(enum) {
    /// Leashed, and the dog it held before (if another) let go.
    leashed: struct { dog: dogs.DogId, let_go: Leash },
    /// Another human holds it.
    held_by_another: dogs.DogId,
};

pub const Releasing = enum { released, not_held };

/// Every human seen since the start, and who holds each dog.
pub const Humans = struct {
    map: std.AutoHashMapUnmanaged(HumanId, Human) = .empty,
    holders: [dogs.dog_count]Holder = @splat(.free),

    pub fn leash(self: *Humans, alloc: std.mem.Allocator, who: HumanId, dog: dogs.DogId) !Leashing {
        switch (self.holders[@intFromEnum(dog)]) {
            .human => |h| if (h != who) return .{ .held_by_another = dog },
            .free => {},
        }
        const human = try self.of(alloc, who);
        const before = human.leash;
        switch (before) {
            .dog => |old| self.holders[@intFromEnum(old)] = .free,
            .none => {},
        }
        human.leash = .{ .dog = dog };
        self.holders[@intFromEnum(dog)] = .{ .human = who };
        const let_go: Leash = switch (before) {
            .dog => |old| if (old == dog) .none else before,
            .none => .none,
        };
        return .{ .leashed = .{ .dog = dog, .let_go = let_go } };
    }

    pub fn release(self: *Humans, alloc: std.mem.Allocator, who: HumanId, dog: dogs.DogId) !Releasing {
        const human = try self.of(alloc, who);
        switch (human.leash) {
            .dog => |held| if (held == dog) {
                human.leash = .none;
                self.holders[@intFromEnum(dog)] = .free;
                return .released;
            },
            .none => {},
        }
        return .not_held;
    }

    /// The human, made on first sight.
    pub fn of(self: *Humans, alloc: std.mem.Allocator, who: HumanId) !*Human {
        const got = try self.map.getOrPut(alloc, who);
        if (!got.found_existing) got.value_ptr.* = .{};
        return got.value_ptr;
    }
};

const testing = std.testing;

test "a human id: 32 hex digits read back; 31, 33, or an uppercase one, are no id" {
    const id: HumanId = @enumFromInt(0x0123456789abcdef0011223344556677);
    const text = id.hex();
    try testing.expectEqualStrings("0123456789abcdef0011223344556677", &text);
    try testing.expectEqual(HumanId.Parsed{ .id = id }, HumanId.parse(&text));
    try testing.expectEqual(HumanId.Parsed.not_an_id, HumanId.parse(text[0..31]));
    try testing.expectEqual(HumanId.Parsed.not_an_id, HumanId.parse("0123456789abcdef00112233445566770"));
    try testing.expectEqual(HumanId.Parsed.not_an_id, HumanId.parse("0123456789ABCDEF0011223344556677"));
}

test "a second leash lets the first dog go; another human can't take a held dog until it is released" {
    var hs: Humans = .{};
    defer hs.map.deinit(testing.allocator);
    const alice: HumanId = @enumFromInt(1);
    const bob: HumanId = @enumFromInt(2);
    const one: dogs.DogId = @enumFromInt(1);
    const two: dogs.DogId = @enumFromInt(2);
    try testing.expectEqual(Leash.none, (try hs.leash(testing.allocator, alice, one)).leashed.let_go);
    try testing.expectEqual(Leash{ .dog = one }, (try hs.leash(testing.allocator, alice, two)).leashed.let_go);
    try testing.expectEqual(Holder.free, hs.holders[1]);
    try testing.expectEqual(Leashing{ .held_by_another = two }, try hs.leash(testing.allocator, bob, two));
    try testing.expectEqual(Releasing.not_held, try hs.release(testing.allocator, bob, two));
    try testing.expectEqual(Releasing.released, try hs.release(testing.allocator, alice, two));
    try testing.expectEqual(Leash.none, (try hs.leash(testing.allocator, bob, two)).leashed.let_go);
}

test "leashing the dog already held lets nothing go" {
    var hs: Humans = .{};
    defer hs.map.deinit(testing.allocator);
    const alice: HumanId = @enumFromInt(1);
    const one: dogs.DogId = @enumFromInt(1);
    _ = try hs.leash(testing.allocator, alice, one);
    try testing.expectEqual(Leash.none, (try hs.leash(testing.allocator, alice, one)).leashed.let_go);
    try testing.expectEqual(Holder{ .human = alice }, hs.holders[1]);
}
