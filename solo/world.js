// THE WORLD's numbers for the page, printed by roc/world.roc (`zig build
// roc`): do not edit; edit that and print it again. The physics
// reads the same world (src/play/world.zon); test_page_modules.mjs holds
// these to the wasm's.
export const tile_px = 350;
export const world_tiles = 6;
export const park_tiles = 4;
export const cow_count = 8;
export const dog_px = 28;
export const cow_px = 42;
export const chicken_px = 20;
export const poop_px = 12;
export const breeds = 4;
// Each kind of critter, its number its place here (roc/World.roc).
export const kinds = [
  { name: "dog", px: 28, colour: "#a0522d", emoji: "", rank: 1, count: 64 },
  { name: "cow", px: 42, colour: "#555555", emoji: "🐄", rank: 0, count: 8 },
  { name: "chicken", px: 20, colour: "#d4a017", emoji: "🐓", rank: 2, count: 16 },
  { name: "goat", px: 30, colour: "#8a8a8a", emoji: "🐐", rank: 3, count: 4 },
];
// The levels, Level One first: each its world and park, in tiles, and how
// many of each kind it lays out (roc/World.roc's `levels`).
export const levels = [
  { world_tiles: 4, park_tiles: 2, counts: [16, 2, 0, 0] },
  { world_tiles: 6, park_tiles: 4, counts: [64, 8, 16, 4] },
];
