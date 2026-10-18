//! **THE RULES**: what a critter in the walk does about each moving critter
//! it sees (docs/PHYSICS.md, decisions 21-24), how fast it goes, the
//! chickens' foraging and the herd's poop (decisions 29, 31). roc/rules.roc says them;
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

/// A share of a step, `num` over `den`, rounded toward zero.
pub const Share = struct { num: u16, den: u16 };

/// A critter's answers by who it sees: `kin`, a dog of its own breed (a
/// dog's only); `dog`, any other dog; `cow`; `chicken`. Its `pace`: each
/// pixel-tick of the walk, it steps at most that share of the leashed
/// dog's step.
pub const Sees = struct { gathers: Gathers, kin: Rule, dog: Rule, cow: Rule, chicken: Rule, pace: Share };

/// **THE CHICKENS' TURN** (decision 31): a chicken sees ripe poop `sight`
/// off; it steps at most `step`, and at most `pace` of the leashed dog's net
/// move over the tick; with nothing to forage it walks home when it is more
/// than `home_band` from it.
pub const Chickens = struct { sight: u16, step: u16, pace: Share, home_band: u16 };

/// **POOP** (decision 29): a poop each `every` the leashed dog walks, `back`
/// behind its herd's deepest dog, else on rings `grid` apart out to
/// `reach`; the park keeps `slots` of them.
pub const Poop = struct { every: u16, back: u16, reach: u16, grid: u16, slots: u16 };

/// A dog's and a cow's answers (a chicken is never in the walk), the
/// chickens' turn and the poop.
pub const Rules = struct { dog: Sees, cow: Sees, chickens: Chickens, poop: Poop };

pub const rules: Rules = @import("rules.zon");
