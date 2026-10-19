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
  { name: "dog", px: 28, colour: "#a0522d", rank: 1, count: 64 },
  { name: "cow", px: 42, colour: "#555555", rank: 0, count: 8 },
  { name: "chicken", px: 20, colour: "#d4a017", rank: 2, count: 16 },
];
