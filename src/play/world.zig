//! **THE WORLD**, as the physics reads it: how big it is, where the
//! populated park sits in it, and where every critter stands when the park
//! starts afresh. roc/world.roc says it; `zig build roc` prints it into
//! world.zon, checked in, which this file imports at compile time, so no
//! build runs Roc. `World` is the seam: a world.zon that does not fit it does
//! not compile. The critter counts are its lists' lengths (layout.zig).

/// A point in 256ths of a pixel (physics.zig's `Point`, which layout.zig
/// makes of it).
pub const Spot = struct { x: i32, y: i32 };

pub const World = struct {
    /// A tile's side, in pixels.
    tile_px: u16,
    /// The world is `world_tiles` by `world_tiles` tiles, a torus.
    world_tiles: u16,
    /// The populated park: `tiles` by `tiles` tiles from tile (`first`,
    /// `first`). The rest of the world is empty ground.
    park: struct { first: u16, tiles: u16 },
    /// The critters' squares and a poop's, in whole pixels, as the physics
    /// moves them and the page draws them.
    sizes: struct { dog_px: u16, cow_px: u16, chicken_px: u16, poop_px: u16 },
    /// Dog n is of breed n mod `breeds`.
    breeds: u8,
    /// Each kind in its own numbering: dog n is `dogs[n]`. A chicken's spot
    /// is its home too (docs/PHYSICS.md, "Poop and chickens").
    dogs: []const Spot,
    cows: []const Spot,
    chickens: []const Spot,
};

pub const world: World = @import("world.zon");
