//! **THE WORLD**, as the physics reads it: how big it is, where the
//! populated park sits in it, and where every critter stands when the park
//! starts afresh. roc/world.roc says it; `zig build roc-world` prints it into
//! world.zon, checked in, which this file imports at compile time, so no
//! build runs Roc. `World` is the seam: a world.zon that does not fit it does
//! not compile. The critter counts are its lists' lengths (layout.zig).

/// A point in 256ths of a pixel (physics.zig's `Point`, which layout.zig
/// makes of it).
pub const Spot = struct { x: i32, y: i32 };

pub const World = struct {
    /// A tile's side, in pixels.
    tile_px: comptime_int,
    /// The world is `world_tiles` by `world_tiles` tiles, a torus.
    world_tiles: comptime_int,
    /// The populated park: `tiles` by `tiles` tiles from tile (`first`,
    /// `first`). The rest of the world is empty ground.
    park: struct { first: comptime_int, tiles: comptime_int },
    /// Each kind in its own numbering: dog n is `dogs[n]`. A chicken's spot
    /// is its home too (docs/PHYSICS.md, "Poop and chickens").
    dogs: []const Spot,
    cows: []const Spot,
    chickens: []const Spot,
};

pub const world: World = @import("world.zon");
