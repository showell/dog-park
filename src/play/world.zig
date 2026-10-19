//! **THE WORLD**, as the physics reads it: how big it is, where the
//! populated park sits in it, and where every critter stands when the park
//! starts afresh. roc/world.roc says it; `zig build roc` prints it into
//! world.zon, checked in, which this file imports at compile time, so no
//! build runs Roc. `World` is the seam: a world.zon that does not fit it does
//! not compile. The critter counts are its kinds' spots' lengths.

/// A point in 256ths of a pixel (physics.zig's `Point`, which layout.zig
/// makes of it).
pub const Spot = struct { x: i32, y: i32 };

/// A kind of critter (roc/World.roc's `Look`): its name, its square's side
/// in pixels, the colour the page draws it with no art, its rank in the
/// cascade, who its kin are, whether a human leashes it, and where each of
/// its critters stands in the first layout (critter n at `spots[n]`; a
/// critter's spot is its home too, docs/PHYSICS.md, "Poop and chickens").
pub const Look = struct { name: []const u8, px: u16, colour: []const u8, rank: u8, kin: Kin, leash: bool, spots: []const Spot };

/// Who a critter nudges and is nudged by: its breed of its kind; every one
/// of its kind; nobody.
pub const Kin = enum { breed, herd, none };

pub const World = struct {
    /// A tile's side, in pixels.
    tile_px: u16,
    /// The world is `world_tiles` by `world_tiles` tiles, a torus.
    world_tiles: u16,
    /// The populated park: `tiles` by `tiles` tiles from tile (`first`,
    /// `first`). The rest of the world is empty ground.
    park: struct { first: u16, tiles: u16 },
    /// A poop's square, in whole pixels.
    poop_px: u16,
    /// Each kind of critter, its number its place here (roc/World.roc's
    /// `kinds`).
    kinds: []const Look,
    /// Critter n of a kind kin by breed is of breed n mod `breeds`.
    breeds: u8,
    /// The critters are kept by cells, a tile cut `cell_per_tile` ways on
    /// each axis.
    cell_per_tile: u8,
};

pub const world: World = @import("world.zon");
