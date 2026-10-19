//! **THE RULES**: what a critter in the walk does about each moving critter
//! it sees (docs/PHYSICS.md, decisions 21-24), how fast it goes, the
//! chickens' foraging and the herd's poop (decisions 29, 31). roc/Rules.roc
//! says them, and the wish (roc/Wish.roc) applies them in Roc; `zig build
//! roc` prints them into rules.zon too, checked in, which this file imports
//! at compile time for the Zig's own uses: the chickens' turn, the poop, and
//! the tests' distances. These types are
//! the seam: a rules.zon that does not fit them does not compile.
//! Distances here are in whole pixels.

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
/// to the lower index).
pub const Gathers = enum { each, nearest };

/// How a kind moves in the walk: how it takes what it sees, and its pace.
pub const Mover = struct { gathers: Gathers, pace: Share };

/// A kind's answer to a kind it sees, when the two are kin and when not.
pub const Answer = struct { kin: Rule, other: Rule };

/// A share of a step, `num` over `den`, rounded toward zero.
pub const Share = struct { num: u16, den: u16 };

/// **THE CHICKENS' TURN** (decision 31): a chicken sees ripe poop `sight`
/// off; it steps at most `step`, and at most `pace` of the leashed dog's net
/// move over the tick; with nothing to forage it walks home when it is more
/// than `home_band` from it.
pub const Chickens = struct { sight: u16, step: u16, pace: Share, home_band: u16 };

/// **POOP** (decision 29): a poop each `every` the leashed dog walks, `back`
/// behind its herd's deepest dog, else on rings `grid` apart out to
/// `reach`; the park keeps `slots` of them.
pub const Poop = struct { every: u16, back: u16, reach: u16, grid: u16, slots: u16 };

/// **THE WALK'S LIMITS** (decisions 20, 25): one pixel-tick's walk visits at
/// most `most` critters; one step moves at most `nudge_most` together and
/// shoves at most as many chickens; a wish under `dead_zone` px is no step.
pub const Limits = struct { most: u16, nudge_most: u16, dead_zone: u16 };

/// The distance a dog keeps from a dog of another breed and a cow from any
/// dog (the tests' `wary`); how each kind moves in the walk (`movers`, by
/// kind number; null, never in motion there) and each kind's answer to
/// each (`answers[wisher][seen]`), roc/Rules.roc's `mover` and `rule`,
/// which the wish applies in Roc and the walk's judge reads here; the
/// chickens' forage, the poop and the walk's limits.
pub const Rules = struct { wary: u16, movers: []const ?Mover, answers: []const []const Answer, chickens: Chickens, poop: Poop, limits: Limits };

pub const rules: Rules = @import("rules.zon");
