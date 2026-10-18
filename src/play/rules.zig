//! **THE RULES**: what a critter in the walk does about each moving critter
//! it sees (docs/PHYSICS.md, decisions 21-24). roc/rules.roc says them;
//! `zig build roc` prints them into rules.zon, checked in, which this file
//! imports at compile time, so no build runs Roc. These types are the seam:
//! a rules.zon that does not fit them does not compile. physics.zig's
//! `wishOf` applies the rules; the geometry (distance, direction, the
//! rounding) is its own. Distances here are in whole pixels.

/// One critter's answer to another it sees moving.
pub const Rule = union(enum) {
    /// Nothing.
    ignore,
    /// Keep this far: away from it, by the shortfall inside the reach.
    keep: u16,
    /// The nearest one such is its anchor: it stays between `inner` and
    /// `outer` of it, moving away inside and closing in outside.
    herd: struct { inner: u16, outer: u16 },
    /// Close in to touching, from within this; from farther, nothing.
    close: u16,
};

/// Every moving critter's answer summed, or the nearest one's alone (ties
/// to the lower rank).
pub const Gathers = enum { each, nearest };

/// A critter's answers by who it sees: `kin`, a dog of its own breed (a
/// dog's only); `dog`, any other dog; `cow`; `chicken`.
pub const Sees = struct { gathers: Gathers, kin: Rule, dog: Rule, cow: Rule, chicken: Rule };

/// A dog's and a cow's: a chicken is never in the walk.
pub const Rules = struct { dog: Sees, cow: Sees };

pub const rules: Rules = @import("rules.zon");

test "the rules are the original: what Zig said before Roc did, frozen here (the golden runs check what they do)" {
    const std = @import("std");
    const want: Rules = .{
        .dog = .{ .gathers = .each, .kin = .{ .herd = .{ .inner = 42, .outer = 70 } }, .dog = .{ .keep = 158 }, .cow = .{ .keep = 63 }, .chicken = .ignore },
        .cow = .{ .gathers = .nearest, .kin = .{ .keep = 158 }, .dog = .{ .keep = 158 }, .cow = .{ .close = 245 }, .chicken = .ignore },
    };
    try std.testing.expect(std.meta.eql(want, rules));
}
