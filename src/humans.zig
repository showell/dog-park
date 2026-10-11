//! Humans. Each device is a human, known by a signed cookie that carries its
//! id; there is no sign-up beyond that.
//!
//! **A HUMAN'S ID IS 128 RANDOM BITS** (docs/CLAIMS-V1.md), made when a device
//! first arrives, from the OS's random source. Nothing hands ids out in
//! order, so there is no counter to keep, a first visit writes nothing, and
//! a restored `data/` or `auth/` cannot hand out an id a live cookie names.

const std = @import("std");
const Io = std.Io;

/// A human's id: a number, but not one to do arithmetic with, nor to mix
/// with any other id. Never zero (no human is zero).
pub const HumanId = enum(u128) {
    _,

    /// A human of a known number, for tests and records: never zero.
    pub fn of(n: u128) HumanId {
        std.debug.assert(n != 0);
        return @enumFromInt(n);
    }

    pub fn number(self: HumanId) u128 {
        return @intFromEnum(self);
    }

    /// A new human: 128 bits from the OS's random source, with no fallback
    /// (`io.randomSecure`: no entropy is an error, never a guessable seed),
    /// drawn again in the one case in 2^128 they are all zero.
    pub fn fresh(io: Io) Io.RandomSecureError!HumanId {
        while (true) {
            var bytes: [16]u8 = undefined;
            try io.randomSecure(&bytes);
            const n = std.mem.readInt(u128, &bytes, .little);
            if (n != 0) return @enumFromInt(n);
        }
    }

    /// The id as a cookie carries it: 32 lowercase hex digits, always.
    pub fn name(self: HumanId, buffer: *[32]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{x:0>32}", .{self.number()}) catch unreachable;
    }

    /// The id a cookie's text names: exactly 32 lowercase hex digits, not all
    /// zero, so one id has one spelling. The one place text becomes a human.
    pub fn parse(text: []const u8) ?HumanId {
        if (text.len != 32) return null;
        for (text) |c| switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => return null,
        };
        const n = std.fmt.parseInt(u128, text, 16) catch return null;
        if (n == 0) return null;
        return @enumFromInt(n);
    }
};

/// Who a request is from: a human the cookie names, or a device with none
/// yet (its first request, which makes it one).
pub const Visitor = union(enum) {
    known: HumanId,
    new_device,
};

const testing = std.testing;

test "an id round-trips through its name, which is 32 lowercase hex digits" {
    var buffer: [32]u8 = undefined;
    const h = HumanId.of(42);
    try testing.expectEqualStrings("0000000000000000000000000000002a", h.name(&buffer));
    try testing.expectEqual(h, HumanId.parse(h.name(&buffer)).?);
    const top = HumanId.of(std.math.maxInt(u128));
    try testing.expectEqual(top, HumanId.parse(top.name(&buffer)).?);
    try testing.expect(HumanId != u128);
}

test "a name that is not one spelling of one human is no one" {
    for ([_][]const u8{
        "",
        "2a",
        "0000000000000000000000000000002A", // upper case: another spelling
        "00000000000000000000000000000000", // no human is zero
        "0000000000000000000000000000002a0", // 33 digits
        "000000000000000000000000000000g1",
        "+000000000000000000000000000002a",
    }) |bad| try testing.expect(HumanId.parse(bad) == null);
}

test "fresh humans are random and never zero" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const a = try HumanId.fresh(threaded.io());
    const b = try HumanId.fresh(threaded.io());
    try testing.expect(a != b);
    try testing.expect(a.number() != 0);
}
