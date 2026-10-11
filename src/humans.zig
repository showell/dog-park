//! Humans. Each device is a human, known by a signed cookie that carries its
//! id; there is no sign-up beyond that.

const std = @import("std");

/// A human's id: a number, but not one to do arithmetic with, nor to mix
/// with any other id. Made only from what the signed cookie carries.
pub const HumanId = enum(u64) {
    _,

    /// The id a verified cookie carries: the one place a number becomes
    /// a human, so a forged one can be looked for.
    pub fn of(n: u64) HumanId {
        return @enumFromInt(n);
    }

    pub fn number(self: HumanId) u64 {
        return @intFromEnum(self);
    }
};

/// Who a request is from: a human the cookie names, or a device with none
/// yet (its first request, which makes it one).
pub const Visitor = union(enum) {
    known: HumanId,
    new_device,
};

test "an id round-trips, and is not a plain number" {
    const h = HumanId.of(42);
    try std.testing.expectEqual(@as(u64, 42), h.number());
    try std.testing.expect(HumanId != u64);
}

test "a request is from a known human or a new device, and nothing between" {
    const visitors = [_]Visitor{ .{ .known = .of(5) }, .new_device };
    var known: u32 = 0;
    for (visitors) |v| switch (v) {
        .known => |h| {
            try std.testing.expectEqual(@as(u64, 5), h.number());
            known += 1;
        },
        .new_device => {},
    };
    try std.testing.expectEqual(@as(u32, 1), known);
}
