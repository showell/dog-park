// The page's modules import in node, with no DOM, and none starts anything
// as it loads; their pure functions answer as the page relies on.
//
//   node tools/test_page_modules.mjs
import { test } from "node:test";
import assert from "node:assert/strict";

const scene = await import("../solo/scene.js");
const pointer = await import("../solo/pointer.js");
const blit = await import("../solo/blit.js");
const engine = await import("../solo/engine.js");
const park = await import("../solo/park.js");

test("every module imports without a DOM", () => {
  assert.equal(typeof document, "undefined");
  assert.equal(typeof blit.draw, "function");
  assert.equal(typeof blit.hit, "function");
  assert.equal(typeof engine.createEngine, "function");
  // park.js wires the DOM and exports nothing; its import starting nothing
  // is this file finishing at all (a start would throw on `document`).
  assert.deepEqual(Object.keys(park), []);
});

test("the engine keeps no state of its own: its exports are a maker, pure helpers and constants", () => {
  assert.deepEqual(Object.keys(engine).sort(), ["answer_ms", "backoff_ms", "budget_bytes", "createEngine", "most_catch_up_ticks", "most_humans", "spacing_ms", "ticksDue", "window_ticks"]);
  // docs/PHYSICS.md's numbers.
  assert.deepEqual(engine.backoff_ms, [5000, 10000, 20000, 40000, 60000]);
  assert.equal(engine.window_ticks, 32);
  assert.equal(engine.budget_bytes, 48 * 1024);
  assert.equal(engine.spacing_ms, 1000);
  assert.equal(engine.answer_ms, 5000);
  assert.equal(engine.most_humans, 16);
});

test("the ticks due: one per 62.5 ms begun, at most 8 after a stall, the rest dropped", () => {
  assert.deepEqual(engine.ticksDue(0, 62.4, 62.5), { ticks: 0, lastTickMs: 0, dropped: 0 });
  assert.deepEqual(engine.ticksDue(0, 62.5, 62.5), { ticks: 1, lastTickMs: 62.5, dropped: 0 });
  assert.deepEqual(engine.ticksDue(100, 300, 62.5), { ticks: 3, lastTickMs: 287.5, dropped: 0 });
  assert.deepEqual(engine.ticksDue(0, 8 * 62.5 + 1, 62.5), { ticks: 8, lastTickMs: 500, dropped: 0 });
  // A 2 s stall: 32 due, 8 run, the clock restarting at the frame.
  assert.deepEqual(engine.ticksDue(0, 2000, 62.5), { ticks: 8, lastTickMs: 2000, dropped: 24 });
  // A clock that went back runs nothing.
  assert.deepEqual(engine.ticksDue(500, 400, 62.5), { ticks: 0, lastTickMs: 500, dropped: 0 });
});

test("the two frames are each other's inverse", () => {
  const viewport = { parkX: 1200, parkY: 800, width: 1000, height: 700 };
  assert.deepEqual(scene.viewportFromPark(viewport, 1250, 830), { viewportX: 50, viewportY: 30 });
  assert.deepEqual(scene.parkFromViewport(viewport, 50, 30), { parkX: 1250, parkY: 830 });
});

test("a park point is named in the world, round the torus", () => {
  const W = scene.world_px;
  assert.deepEqual(scene.wrappedPoint(-5, 99999), { parkX: W - 5, parkY: 99999 % W });
  assert.deepEqual(scene.wrappedPoint(-1000, 0), { parkX: W - 1000, parkY: 0 });
  assert.ok(Object.is(scene.wrapped(-W), 0) && Object.is(scene.wrapped(-0), 0));
  assert.equal(scene.wrapped(1550.4), 1550.4);
  // The short way round, and the nearest copy.
  assert.equal(scene.offset(W - 1, 0), 1);
  assert.equal(scene.offset(0, W - 1), -1);
  assert.equal(scene.offset(100, 300), 200);
  assert.equal(scene.nearest(W - 10, 20), -10);
  assert.equal(scene.nearest(10, W - 20), W + 10);
  assert.equal(scene.nearest(1550.4, 750), 1550.4);
  assert.deepEqual(scene.wrapTile({ col: -1, row: scene.world_tiles }), { col: scene.world_tiles - 1, row: 0 });
});

test("tiles: a point's tile, its key, and those meeting a rectangle", () => {
  const T = scene.tile_px;
  const last = scene.world_tiles - 1;
  assert.deepEqual(scene.tileOf(T - 1, T), { col: 0, row: 1 });
  assert.equal(scene.tileKey({ col: 3, row: 7 }), "3,7");
  assert.deepEqual(scene.tilesMeeting(T - 1, 0, 2, 1), [{ col: 0, row: 0 }, { col: 1, row: 0 }]);
  // Across the seam, the tiles wrap: row by row as they lie, each once.
  assert.deepEqual(scene.tilesMeeting(-10, -10, 20, 20), [{ col: last, row: last }, { col: 0, row: last }, { col: last, row: 0 }, { col: 0, row: 0 }]);
  assert.deepEqual(scene.tileCopiesMeeting(-10, -10, 20, 20), [{ col: -1, row: -1 }, { col: 0, row: -1 }, { col: -1, row: 0 }, { col: 0, row: 0 }]);
});

test("the world is world_tiles square tiles a side, the page may hold all of it, and a point is named round the torus", () => {
  const T = scene.tile_px;
  const W = scene.world_px;
  assert.equal(W, scene.world_tiles * T);
  assert.ok(scene.park_tiles <= scene.world_tiles);
  assert.ok(scene.world_tiles * scene.world_tiles <= scene.most_tiles);
  assert.deepEqual(scene.wrappedPoint(W - 0.5, W), { parkX: W - 0.5, parkY: 0 });
  const last = scene.world_tiles - 1;
  assert.deepEqual(scene.tilesMeeting(W - 10, W - 10, 50, 50), [{ col: last, row: last }, { col: 0, row: last }, { col: last, row: 0 }, { col: 0, row: 0 }]);
});

test("the page's world is the physics': world.js and the wasm, both printed from roc/world.roc, say the same tiles, park, counts, sizes and breeds", async () => {
  const { readFileSync } = await import("node:fs");
  const file = process.env.DOGPARK_WASM ?? new URL("../zig-out/web/physics.wasm", import.meta.url);
  const { instance } = await WebAssembly.instantiate(readFileSync(file));
  const x = instance.exports;
  assert.equal(scene.tile_px, x.tilePx());
  assert.equal(scene.world_tiles, x.worldTiles());
  assert.equal(scene.cow_count, x.cowCount());
  assert.equal(scene.park_tiles * scene.park_tiles * scene.breeds, x.dogCount());
  assert.equal(scene.dog_px, x.dogPx());
  assert.equal(scene.cow_px, x.cowPx());
  assert.equal(scene.chicken_px, x.chickenPx());
  assert.equal(scene.poop_px, x.poopPx());
  assert.equal(scene.breeds, x.breeds());
  // The kinds, in their numbers' order, each its size.
  assert.deepEqual(scene.kinds.map((k) => k.name), ["dog", "cow", "chicken"]);
  assert.deepEqual(scene.kinds.map((k) => k.px), [x.dogPx(), x.cowPx(), x.chickenPx()]);
});

test("a critter with art is its glyph; a kind with none, a square of its colour, its px across, centred where it stands", () => {
  const at = { viewportX: 100, viewportY: 50 };
  const goat = { name: "goat", px: 30, colour: "#123456" };
  assert.deepEqual(scene.critterShape("goat:0", at, goat, undefined, "scenery"),
    { id: "goat:0", shape: "rect", x: 85, y: 35, w: 30, h: 30, fill: "#123456", role: "scenery" });
  assert.deepEqual(scene.critterShape("cow:1", at, scene.kinds[1], scene.cow_emoji, "scenery"),
    { id: "cow:1", shape: "glyph", x: 100, y: 50, w: scene.cow_px, h: scene.cow_px, text: "🐄", fill: "#000", role: "scenery" });
  for (const k of scene.kinds) assert.match(k.colour, /^#[0-9a-f]{6}$/);
});

test("the overview frame: the whole world once, a square window as large as fits, its top-left anywhere round the torus", () => {
  const W = scene.world_px;
  // 1040 x 700: a 660 px square, centred across: the world at 660 / W.
  const o = scene.overviewFrame(1040, 700, { parkX: 0, parkY: 0 });
  assert.equal(o.scale, 660 / W);
  assert.deepEqual(o.window, { x: 190, y: 20, w: 660, h: 660 });
  assert.deepEqual(o.span, { parkW: W, parkH: W });
  // The world's middle in the window's middle.
  assert.deepEqual(scene.overviewFromPark(o, W / 2, W / 2), { viewportX: 520, viewportY: 350 });
  // The window's top-left at (700, 1050): half a world on from it is the window's middle.
  const mid = scene.overviewFrame(1040, 700, { parkX: 700, parkY: 1050 });
  assert.deepEqual(scene.overviewFromPark(mid, 700 + W / 2, 1050 + W / 2), { viewportX: 520, viewportY: 350 });
  // Past the world's far corner, or before its near one, the window wraps round.
  assert.deepEqual(scene.overviewFrame(1040, 700, { parkX: 99999, parkY: 99999 }).at, { parkX: 99999 % W, parkY: 99999 % W });
  assert.deepEqual(scene.overviewFrame(1040, 700, { parkX: -5, parkY: -5 }).at, { parkX: W - 5, parkY: W - 5 });
  // The scrollbars beside the window, its length; each thumb the whole track,
  // as the window is the whole world.
  assert.deepEqual(o.tracks, { x: { x: 190, y: 684, w: 660, h: 12 }, y: { x: 854, y: 20, w: 12, h: 660 } });
  assert.deepEqual(scene.overviewThumb(mid, "x"), [{ x: 190, y: 684, w: 660, h: 12 }]);
  assert.deepEqual(scene.overviewThumb(mid, "y"), [{ x: 854, y: 20, w: 12, h: 660 }]);
});

test("the overview opens centred on the view, round the torus", () => {
  const W = scene.world_px;
  // Named in the world, [0, W), whatever its size.
  const named = (v) => ((v % W) + W) % W;
  // The view's centre (1400, 1200) in the window's middle.
  assert.deepEqual(scene.overviewCentredOn({ parkX: 1000, parkY: 900, width: 800, height: 600 }), { parkX: named(1400 - W / 2), parkY: named(1200 - W / 2) });
  // At the world's corner: centred across the seam.
  assert.deepEqual(scene.overviewCentredOn({ parkX: 0, parkY: 0, width: 800, height: 600 }), { parkX: named(400 - W / 2), parkY: named(300 - W / 2) });
});

test("the overview's window moves: by a thumb's drag and the wheel, round the torus; a view is always in it", () => {
  const W = scene.world_px;
  const o = scene.overviewFrame(1040, 700, { parkX: 1000, parkY: 1000 });
  // A thumb dragged 66 px along its 660 px track: a tenth of the world.
  assert.deepEqual(scene.overviewScrolled(o, "x", 66), { parkX: 1000 + W / 10, parkY: 1000 });
  assert.deepEqual(scene.overviewScrolled(o, "y", -66), { parkX: 1000, parkY: 1000 - W / 10 });
  // ... on round the torus.
  assert.deepEqual(scene.overviewScrolled(o, "x", 330 + 66 * 2), { parkX: 1000 + W / 2 + W / 5 - W, parkY: 1000 });
  assert.deepEqual(scene.overviewMoved(o, 100, -200), { parkX: 1100, parkY: 800 });
  // The window is the world: any view is in it, and it stays put.
  const view = { width: 1040, height: 700 };
  for (const at of [[1200, 1200], [0, 0], [W - 300, 50]]) {
    assert.deepEqual(scene.overviewShowing(o, { ...view, parkX: at[0], parkY: at[1] }), o.at);
  }
});

test("the edge bands: nothing in the middle, faster deeper in, a tick's speeds", () => {
  // A tick's: what a frame was at 60 Hz ((2/3) * 0.7 and (16/3) * 0.7 px),
  // times 60/16.
  assert.equal(pointer.slowest_px_per_tick, 1.75);
  assert.equal(pointer.fastest_px_per_tick, 14);
  assert.equal(pointer.bandSpeed(0), 0);
  assert.equal(pointer.bandSpeed(pointer.band_px), pointer.fastest_px_per_tick);
  assert.equal(pointer.bandSpeed(10 * pointer.band_px), pointer.fastest_px_per_tick);
  assert.equal(pointer.axisScroll(400, 800, 0), 0);
  assert.equal(pointer.axisScroll(800, 800, 0), pointer.fastest_px_per_tick);
  assert.equal(pointer.axisScroll(0, 800, 0), -pointer.fastest_px_per_tick);
  // A dog's reach: its centre comes no nearer the edge than its half-size.
  assert.equal(pointer.axisScroll(800 - scene.dog_px / 2, 800, scene.dog_px / 2), pointer.fastest_px_per_tick);
  const shallow = pointer.axisScroll(800 - scene.dog_px / 2 - pointer.band_px + 8, 800, scene.dog_px / 2);
  assert.ok(shallow > 0 && shallow < pointer.fastest_px_per_tick);
});

test("the subscription: every tile of the world, each once, named in the world", () => {
  const all = scene.subscription();
  assert.equal(all.length, scene.world_tiles * scene.world_tiles);
  assert.equal(new Set(all.map(scene.tileKey)).size, all.length);
  assert.ok(all.every((t) => t.col >= 0 && t.col < scene.world_tiles && t.row >= 0 && t.row < scene.world_tiles));
});

test("a dog's look is its breed, n mod 4", () => {
  assert.deepEqual(scene.dog_looks, ["🐕", "🐩", "🦮", "🐕‍🦺"]);
});

// ── what a frame draws, and what a press is on ──────────────────────────────

test("between ticks: part way however far (a fast drag's walk glides), where it is when new", () => {
  const was = { parkX: 100, parkY: 200 };
  assert.deepEqual(scene.between(was, { parkX: 140, parkY: 180 }, 0), { parkX: 100, parkY: 200 });
  assert.deepEqual(scene.between(was, { parkX: 140, parkY: 180 }, 0.25), { parkX: 110, parkY: 195 });
  assert.deepEqual(scene.between(was, { parkX: 140, parkY: 180 }, 1), { parkX: 140, parkY: 180 });
  assert.deepEqual(scene.between(was, { parkX: 150, parkY: 200 }, 0.5), { parkX: 125, parkY: 200 });
  assert.deepEqual(scene.between(was, { parkX: 200, parkY: 200 }, 0.5), { parkX: 150, parkY: 200 });
  assert.deepEqual(scene.between(was, { parkX: 100, parkY: 100 }, 0.5), { parkX: 100, parkY: 150 });
  assert.deepEqual(scene.between(undefined, { parkX: 7, parkY: 8 }, 0.5), { parkX: 7, parkY: 8 });
});

test("the near scene between ticks: the viewport, the cows and the dogs each part way; places as they are", () => {
  const viewport = { parkX: 450, parkY: 0, width: 600, height: 400 };
  const dogs = [{ id: 7, emoji: "🐕", parkX: 520, parkY: 100 }, { id: 3, emoji: "🐩", parkX: 900, parkY: 300 }];
  const cows = [{ id: 23, parkX: 600, parkY: 250 }];
  const motion = {
    alpha: 0.5,
    was: { viewport: { parkX: 440, parkY: 0 }, dogs: new Map([[7, { parkX: 500, parkY: 100 }]]), cows: new Map([[23, { parkX: 500, parkY: 250 }]]) },
  };
  const byId = new Map(scene.nearScene(viewport, dogs, cows, { kind: "in_hand", dogId: 7 }, motion, new Map(), { chickens: [], poops: [], labels: "shown" }).map((o) => [o.id, o]));
  // The viewport drawn at 445: dog 7 at 510, so x 65; its ring with it.
  assert.equal(byId.get("tile:1,0").x, scene.tile_px - 445);
  assert.deepEqual([byId.get("dog:7").x, byId.get("dog:7").y], [65, 100]);
  assert.deepEqual([byId.get("dog:7:ring").x, byId.get("dog:7:ring").y], [65, 100]);
  assert.equal(byId.get("dog:7:label").text, "7");
  // Dog 3 is new since the last tick: where it is. Cow 23 moved 100 px: it glides.
  assert.equal(byId.get("dog:3").x, 455);
  assert.equal(byId.get("cow:23").x, 105);
  // With no motion, as it is.
  assert.equal(scene.nearScene(viewport, dogs, cows, { kind: "none" }).find((o) => o.id === "dog:7").x, 70);
});

const ids = (objects) => objects.map((o) => o.id);

test("the near scene: tiles, then cows, then dogs, the leashed dog ringed", () => {
  const T = scene.tile_px;
  // 600 x 300 at (300, 0): tiles (0,0) to (2,0), the tile columns from x -300.
  const viewport = { parkX: 300, parkY: 0, width: 600, height: 300 };
  const dogs = [{ id: 7, emoji: "🐕", parkX: 500, parkY: 100 }, { id: 3, emoji: "🐩", parkX: 1500.4, parkY: 1000 }];
  const cows = [{ id: 23, parkX: 600.5, parkY: 250 }];
  // Dog numbers are a debugging aid ("d"): hidden unless asked for; the tiles' coordinates always shown.
  assert.deepEqual(ids(scene.nearScene(viewport, dogs, cows, { kind: "kept", dogId: 7 })), [
    "tile:0,0", "tile:0,0:label", "tile:1,0", "tile:1,0:label", "tile:2,0", "tile:2,0:label",
    "cow:23", "dog:7:ring", "dog:7", "dog:3",
  ]);
  const near = scene.nearScene(viewport, dogs, cows, { kind: "kept", dogId: 7 }, undefined, new Map(), { chickens: [], poops: [], labels: "shown" });
  assert.deepEqual(ids(near), [
    "tile:0,0", "tile:0,0:label", "tile:1,0", "tile:1,0:label", "tile:2,0", "tile:2,0:label",
    "cow:23", "dog:7:ring", "dog:7", "dog:7:label", "dog:3", "dog:3:label",
  ]);
  const byId = new Map(near.map((o) => [o.id, o]));
  assert.deepEqual(byId.get("tile:1,0"), { id: "tile:1,0", shape: "rect", x: T - 300, y: 0, w: T, h: T, fill: "#eaf3fc", role: "scenery" });
  assert.deepEqual(byId.get("tile:0,0:label"), { id: "tile:0,0:label", shape: "text", x: T / 2 - 300, y: T / 2, w: 0, h: 0, text: "(0, 0)", font: "20px monospace", fill: "#9ab", role: "scenery" });
  assert.equal(byId.get("tile:0,0").fill, "#ffffff");
  // A cow: a glyph cow_px across, never a target, its place to the pixel under it.
  assert.deepEqual(byId.get("cow:23"), { id: "cow:23", shape: "glyph", x: 300.5, y: 250, w: scene.cow_px, h: scene.cow_px, text: "🐄", fill: "#000", role: "scenery" });
  // A cow has no label; a dog's is its number.
  assert.equal(byId.get("cow:23:label"), undefined);
  // The leashed dog: a ring under its dog_px glyph, which is a target.
  assert.deepEqual(byId.get("dog:7:ring"), { id: "dog:7:ring", shape: "ring", x: 200, y: 100, w: 2 * (scene.dog_px * 0.7), h: 2 * (scene.dog_px * 0.7), stroke: "#d33", lineWidth: 3, role: "scenery" });
  assert.deepEqual(byId.get("dog:7"), { id: "dog:7", shape: "glyph", x: 200, y: 100, w: scene.dog_px, h: scene.dog_px, text: "🐕", fill: "#000", role: "target" });
  // A far dog is still drawn (off the screen), unringed.
  assert.deepEqual(byId.get("dog:3"), { id: "dog:3", shape: "glyph", x: 1200.4, y: 1000, w: scene.dog_px, h: scene.dog_px, text: "🐩", fill: "#000", role: "target" });
  assert.equal(byId.get("dog:3:label").text, "3");
  // No leash, no ring.
  assert.ok(!ids(scene.nearScene(viewport, dogs, cows, { kind: "none" })).includes("dog:7:ring"));
  // The last walk's places (#n) are debugging labels too: none unless shown.
  const visits = new Map([["dog:7", 3], ["cow:23", 5]]);
  const quiet = new Map(scene.nearScene(viewport, dogs, cows, { kind: "none" }, undefined, visits).map((o) => [o.id, o]));
  assert.equal(quiet.get("dog:7:label"), undefined);
  assert.equal(quiet.get("cow:23:label"), undefined);
  const shown = new Map(scene.nearScene(viewport, dogs, cows, { kind: "none" }, undefined, visits, { chickens: [], poops: [], labels: "shown" }).map((o) => [o.id, o]));
  assert.equal(shown.get("dog:7:label").text, "7 #3");
  assert.equal(shown.get("cow:23:label").text, "#5");
});

test("the overview scene: the world's tiles shaded by subscription, its dots by freshness, the last leashed ringed, the margins, the view, the scrollbars", () => {
  const T = scene.tile_px;
  // 1040 x 700, the window at the world's corner: a 660 px square at (190, 20), scale 660 / W.
  const s = 660 / W;
  const viewport = { parkX: 350, parkY: 700, width: 1040, height: 700 };
  const subscribed = new Map([["1,2", true], ["0,0", true]]);
  const dogs = [{ id: 7, parkX: 400, parkY: 750 }, { id: 3, parkX: 1500, parkY: 1500 }];
  const cows = [{ id: 23, parkX: 50, parkY: 50 }, { id: 24, parkX: 800, parkY: 50 }];
  const over = scene.overviewScene(viewport, dogs, cows, subscribed, { kind: "dog", dogId: 3 }, { parkX: 0, parkY: 0 });
  const tiles = scene.world_tiles * scene.world_tiles;
  assert.equal(over.length, 1 + tiles + 2 + 2 + 1 + 4 + 1 + 4);
  assert.deepEqual(over[0], { id: "ground", shape: "rect", x: 0, y: 0, w: 1040, h: 700, fill: "#556", role: "scenery" });
  const byId = new Map(over.map((o) => [o.id, o]));
  // Subscribed: white and blue; not: two pinks.
  assert.equal(byId.get("tile:0,0").fill, "#ffffff");
  assert.equal(byId.get("tile:1,2").fill, "#eaf3fc");
  assert.equal(byId.get("tile:2,2").fill, "#f8d8d8");
  assert.equal(byId.get("tile:2,1").fill, "#f2c4c4");
  assert.equal(byId.get("tile:1,2").x, 190 + T * s);
  assert.equal(byId.get("tile:1,2").w, T * s);
  // A cow in a subscribed tile is dark brown, one elsewhere pale; 8 px across.
  assert.deepEqual(byId.get("cow:23"), { id: "cow:23", shape: "dot", x: 190 + 50 * s, y: 20 + 50 * s, w: 8, h: 8, fill: "#7a4a1a", role: "scenery" });
  assert.equal(byId.get("cow:24").fill, "#c9a37a");
  // A dog: dark when live, pale when remembered; 5 px across; the last leashed ringed, after its dot.
  assert.equal(byId.get("dog:7").fill, "#333");
  assert.equal(byId.get("dog:3").fill, "#a88");
  assert.equal(byId.get("dog:3").w, 5);
  assert.equal(byId.get("dog:3").role, "scenery");
  assert.deepEqual(byId.get("dog:3:ring"), { id: "dog:3:ring", shape: "ring", x: byId.get("dog:3").x, y: byId.get("dog:3").y, w: 22, h: 22, stroke: "#d33", lineWidth: 3, role: "scenery" });
  // Over the dots, the margins; then the view; then the scrollbars, each thumb over its track.
  assert.deepEqual(ids(over).slice(-12), ["dog:7", "dog:3", "dog:3:ring", "margin:top", "margin:bottom", "margin:left", "margin:right",
    "view", "scroll:x", "scroll:x:thumb", "scroll:y", "scroll:y:thumb"]);
  assert.deepEqual(byId.get("margin:bottom"), { id: "margin:bottom", shape: "rect", x: 0, y: 680, w: 1040, h: 20, fill: "#556", role: "scenery" });
  assert.deepEqual(byId.get("view"), { id: "view", shape: "frame", x: 190 + 350 * s, y: 20 + 700 * s, w: 1040 * s, h: 700 * s, stroke: "#222", lineWidth: 2, role: "target" });
  assert.deepEqual(byId.get("scroll:x"), { id: "scroll:x", shape: "rect", x: 190, y: 684, w: 660, h: 12, fill: "#778", role: "target" });
  assert.equal(byId.get("scroll:y:thumb").role, "target");
  // The window elsewhere round the torus: a critter drawn from its corner.
  const mid = scene.overviewScene(viewport, [{ id: 0, parkX: 855, parkY: 1050 }], [], subscribed, { kind: "none" }, { parkX: 700, parkY: 700 });
  const dog0 = mid.find((o) => o.id === "dog:0");
  assert.deepEqual([dog0.x, dog0.y].map((v) => Math.round(v * 1e6) / 1e6), [190 + 155 * s, 20 + 350 * s].map((v) => Math.round(v * 1e6) / 1e6));
});

test("hit: the topmost target whose box holds the point, edges included", () => {
  const objects = [
    { id: "ground", shape: "rect", x: 0, y: 0, w: 100, h: 100, role: "target" },
    { id: "a", shape: "glyph", x: 50, y: 50, w: 40, h: 40, role: "target" },
    { id: "b", shape: "glyph", x: 60, y: 50, w: 40, h: 40, role: "target" },
    { id: "cover", shape: "dot", x: 55, y: 50, w: 10, h: 10, role: "scenery" },
  ];
  // b is after a, so on top; the scenery over both catches nothing.
  assert.equal(blit.hit(objects, 55, 50), "b");
  assert.equal(blit.hit(objects, 31, 50), "a");
  assert.equal(blit.hit(objects, 80, 70), "b"); // b's corner
  assert.equal(blit.hit(objects, 81, 70), "ground");
  assert.equal(blit.hit(objects, 100, 100), "ground"); // the rect's corner
  assert.equal(blit.hit(objects, 100.5, 50), null);
  assert.equal(blit.hit([], 0, 0), null);
  assert.throws(() => blit.hit([{ id: "x", shape: "dot", x: 0, y: 0, w: 1, h: 1, role: true }], 0, 0), /no role/);
});

test("a press in the near scene names the topmost dog, and a cow or a tile is a miss", () => {
  const viewport = { parkX: 0, parkY: 0, width: 800, height: 600 };
  const dogs = [{ id: 1, emoji: "🐕", parkX: 100, parkY: 100 }, { id: 2, emoji: "🐕", parkX: 110, parkY: 100 }];
  const near = scene.nearScene(viewport, dogs, [{ id: 9, parkX: 300, parkY: 300 }], { kind: "none" });
  assert.equal(scene.dogOfTarget(blit.hit(near, 105, 95)), 2); // drawn last, so on top
  assert.equal(scene.dogOfTarget(blit.hit(near, 100 - scene.dog_px / 2 + 1, 95)), 1);
  assert.equal(scene.dogOfTarget(blit.hit(near, 300, 300)), "none"); // a cow
  assert.equal(blit.hit(near, 500, 500), null); // ground
  assert.equal(scene.dogOfTarget(null), "none");
  assert.equal(scene.dogOfTarget("view"), "none");
  assert.equal(scene.dogOfTarget(scene.dogTarget(19)), 19);
});

test("a press in the overview is on the view's rectangle, a scrollbar's thumb, or nothing", () => {
  const viewport = { parkX: 500, parkY: 1000, width: 1040, height: 700 };
  const over = scene.overviewScene(viewport, [{ id: 7, parkX: 600, parkY: 1100 }], [], new Map(), { kind: "dog", dogId: 7 }, { parkX: 0, parkY: 0 });
  const view = over.find((o) => o.id === scene.view_target);
  assert.equal(blit.hit(over, view.x, view.y), scene.view_target);
  assert.equal(blit.hit(over, view.x + view.w, view.y + view.h), scene.view_target);
  assert.equal(blit.hit(over, view.x - 1, view.y), null);
  assert.equal(blit.hit(over, 5, 5), null);
  // The window is the world, so each thumb is its whole track (190 to 850 at y 684 to 696; x 854 to 866).
  assert.equal(blit.hit(over, 200, 690), scene.thumbTarget("x"));
  assert.equal(blit.hit(over, 840, 690), scene.thumbTarget("x"));
  assert.equal(blit.hit(over, 860, 600), scene.thumbTarget("y"));
  assert.deepEqual(scene.scrollOfTarget(scene.thumbTarget("y")), { axis: "y", part: "thumb" });
  assert.deepEqual(scene.scrollOfTarget(scene.trackTarget("x")), { axis: "x", part: "track" });
  assert.equal(scene.scrollOfTarget("view"), "none");
  assert.equal(scene.scrollOfTarget(null), "none");
});

// ── what a pointer event means ──────────────────────────────────────────────

// A gesture as a table: each row an event (and what the press hit), and the
// hand and intents it must give, from the hand the row before left.
function play(rows, { mode = "near", viewport, overviewAt } = {}) {
  let hand = pointer.resting;
  for (const [i, r] of rows.entries()) {
    const out = pointer.meaning(hand, r.event, r.hit ?? null, r.mode ?? mode, viewport, overviewAt);
    assert.deepEqual(out, { hand: r.hand, intents: r.intents }, `row ${i}: ${JSON.stringify(r.event)}`);
    hand = out.hand;
  }
}

const near = { parkX: 1000, parkY: 1000, width: 800, height: 600 };

test("a gesture on a dog: grab where pressed, drags as displacements, let go", () => {
  // Dog 219 at park (1100, 1200), so at viewport (100, 200); pressed 5 px right and 3 px up of its centre.
  play([
    { event: { type: "down", x: 105, y: 197, dogAt: { parkX: 1100, parkY: 1200 } }, hit: "dog:219",
      hand: { kind: "dragging", dogId: 219, lastX: 105, lastY: 197 }, intents: [{ kind: "grab", dogId: 219 }] },
    { event: { type: "move", x: 115, y: 190 },
      hand: { kind: "dragging", dogId: 219, lastX: 115, lastY: 190 }, intents: [{ kind: "drag", dogId: 219, dx: 10, dy: -7 }] },
    // Past the screen's edge: the displacement all the same (the tick
    // decides where the dog goes).
    { event: { type: "move", x: -50.5, y: 190 },
      hand: { kind: "dragging", dogId: 219, lastX: -50.5, lastY: 190 }, intents: [{ kind: "drag", dogId: 219, dx: -165.5, dy: 0 }] },
    // A move that goes nowhere means nothing.
    { event: { type: "move", x: -50.5, y: 190 },
      hand: { kind: "dragging", dogId: 219, lastX: -50.5, lastY: 190 }, intents: [] },
    { event: { type: "up" }, hand: pointer.resting, intents: [{ kind: "letgo" }] },
    // A move with nothing in hand means nothing; so does a second up.
    { event: { type: "move", x: 300, y: 300 }, hand: pointer.resting, intents: [] },
    { event: { type: "up" }, hand: pointer.resting, intents: [] },
  ], { viewport: near });
});

test("a cancel lets go too", () => {
  play([
    { event: { type: "down", x: 400, y: 300, dogAt: { parkX: 100, parkY: 100 } }, hit: "dog:5",
      hand: { kind: "dragging", dogId: 5, lastX: 400, lastY: 300 }, intents: [{ kind: "grab", dogId: 5 }] },
    { event: { type: "cancel" }, hand: pointer.resting, intents: [{ kind: "letgo" }] },
  ], { viewport: near });
});

test("a press on empty ground pans: the viewport against the pointer", () => {
  play([
    { event: { type: "down", x: 400, y: 300, dogAt: "none" }, hit: null,
      hand: { kind: "panning", lastX: 400, lastY: 300 }, intents: [] },
    { event: { type: "move", x: 410, y: 280 },
      hand: { kind: "panning", lastX: 410, lastY: 280 }, intents: [{ kind: "pan", parkX: 990, parkY: 1020 }] },
    { event: { type: "up" }, hand: pointer.resting, intents: [] },
  ], { viewport: near });
  // A press on a cow, or on a dog that just left what the page knows, pans too.
  play([
    { event: { type: "down", x: 1, y: 2, dogAt: "none" }, hit: "cow:23", hand: { kind: "panning", lastX: 1, lastY: 2 }, intents: [] },
  ], { viewport: near });
  play([
    { event: { type: "down", x: 1, y: 2, dogAt: "none" }, hit: "dog:219", hand: { kind: "panning", lastX: 1, lastY: 2 }, intents: [] },
  ], { viewport: near });
});

test("a pan goes on across the seam, the viewport named in the world", () => {
  play([
    { event: { type: "down", x: 0, y: 0, dogAt: "none" }, hand: { kind: "panning", lastX: 0, lastY: 0 }, intents: [] },
    { event: { type: "move", x: 5000, y: 0 }, hand: { kind: "panning", lastX: 5000, lastY: 0 }, intents: [{ kind: "pan", parkX: scene.wrapped(1000 - 5000), parkY: 1000 }] },
    { event: { type: "move", x: 5000, y: 3000 }, hand: { kind: "panning", lastX: 5000, lastY: 3000 }, intents: [{ kind: "pan", parkX: 1000, parkY: scene.wrapped(1000 - 3000) }] },
  ], { viewport: near });
});

test("in the overview, a press on the view's rectangle drags it, scaled, once past the tap's slop; one off it means nothing", () => {
  // 1040 x 700: scale 660 / W.
  const s = 660 / W;
  const viewport = { parkX: 500, parkY: 1000, width: 1040, height: 700 };
  play([
    { event: { type: "down", x: 300, y: 200, dogAt: "none" }, hit: scene.view_target,
      hand: { kind: "tapping", downX: 300, downY: 200 }, intents: [] },
    { event: { type: "move", x: 300 + 13.2, y: 200 - 6.6 },
      hand: { kind: "panning", lastX: 313.2, lastY: 193.4 }, intents: [{ kind: "pan", parkX: 500 + 13.2 / s, parkY: 1000 - 6.6 / s }] },
    { event: { type: "up" }, hand: pointer.resting, intents: [] },
    // Off the rectangle: on nothing, so resting, and a move means nothing.
    { event: { type: "down", x: 5, y: 5, dogAt: "none" }, hit: null, hand: pointer.resting, intents: [] },
    { event: { type: "move", x: 50, y: 50 }, hand: pointer.resting, intents: [] },
  ], { mode: "overview", viewport });
});

test("in the overview, a scrollbar: the thumb (the whole track) held where pressed; the wheel scrolls, round the torus", () => {
  const viewport = { parkX: 1500, parkY: 1500, width: 1040, height: 700 };
  const overviewAt = { parkX: 1000, parkY: 1000 };
  const s = 660 / W;
  play([
    { event: { type: "down", x: 400, y: 690, dogAt: "none" }, hit: scene.thumbTarget("x"),
      hand: { kind: "scrolling", axis: "x", lastX: 400, lastY: 690 }, intents: [] },
    // 66 px along the 660 px track: a tenth of the world; the pointer's drift across it means nothing.
    { event: { type: "move", x: 466, y: 650 },
      hand: { kind: "scrolling", axis: "x", lastX: 466, lastY: 650 }, intents: [{ kind: "scroll", parkX: 1000 + W / 10, parkY: 1000 }] },
    { event: { type: "up" }, hand: pointer.resting, intents: [] },
  ], { mode: "overview", viewport, overviewAt });
  play([
    { event: { type: "wheel", dx: 13.2, dy: -6.6 }, hand: pointer.resting, intents: [{ kind: "scroll", parkX: 1000 + 13.2 / s, parkY: 1000 - 6.6 / s }] },
    { event: { type: "wheel", dx: 0, dy: 0 }, hand: pointer.resting, intents: [] },
  ], { mode: "overview", viewport, overviewAt });
  play([
    { event: { type: "wheel", dx: 0, dy: -330 }, hand: pointer.resting, intents: [{ kind: "scroll", parkX: 1000, parkY: scene.wrapped(1000 - 330 / s) }] },
  ], { mode: "overview", viewport, overviewAt });
  // Near, a wheel means nothing.
  play([{ event: { type: "wheel", dx: 10, dy: 10 }, hand: pointer.resting, intents: [] }], { viewport });
});

test('"m" (the map) mid-drag lets go and flips the mode; resting, it only flips; the overview opens centred on the view', () => {
  const centred = scene.overviewCentredOn(near);
  const opened = { kind: "scroll", parkX: centred.parkX, parkY: centred.parkY };
  const held = { kind: "dragging", dogId: 7, lastX: 100, lastY: 200 };
  play([
    { event: { type: "down", x: 100, y: 200, dogAt: { parkX: 1100, parkY: 1200 } }, hit: "dog:7",
      hand: held, intents: [{ kind: "grab", dogId: 7 }] },
    { event: { type: "map" }, hand: pointer.resting, intents: [{ kind: "letgo" }, { kind: "mode", mode: "overview" }, opened] },
    // The move after means nothing: the hand rests.
    { event: { type: "move", x: 120, y: 200 }, mode: "overview", hand: pointer.resting, intents: [] },
    { event: { type: "map" }, mode: "overview", hand: pointer.resting, intents: [{ kind: "mode", mode: "near" }] },
  ], { viewport: near });
  // A pan under way just stops.
  play([
    { event: { type: "down", x: 0, y: 0, dogAt: "none" }, hand: { kind: "panning", lastX: 0, lastY: 0 }, intents: [] },
    { event: { type: "map" }, hand: pointer.resting, intents: [{ kind: "mode", mode: "overview" }, opened] },
  ], { viewport: near });
  // A scrollbar held just stops.
  assert.deepEqual(pointer.meaning({ kind: "scrolling", axis: "x", lastX: 0, lastY: 0 }, { type: "map" }, null, "overview", near),
    { hand: pointer.resting, intents: [{ kind: "mode", mode: "near" }] });
});

test("no event outside the six", () => {
  assert.throws(() => pointer.meaning(pointer.resting, { type: "keyup" }, null, "near", near), /no pointer event keyup/);
});

test("the edge bands each tick: a pan keeps going, a held dog carries the viewport", () => {
  const f = pointer.fastest_px_per_tick;
  // Nothing held, or a pan or a dog away from every edge: nothing.
  assert.deepEqual(pointer.edgeScroll("none", near), []);
  assert.deepEqual(pointer.edgeScroll({ kind: "pan", x: 400, y: 300 }, near), []);
  const held = (parkX, parkY) => ({ kind: "dog", dogId: 9, parkX, parkY });
  assert.deepEqual(pointer.edgeScroll(held(1400, 1300), near), []);
  // A pan held on the right edge: the park goes toward it, so the viewport away.
  assert.deepEqual(pointer.edgeScroll({ kind: "pan", x: 800, y: 300 }, near),
    [{ kind: "pan", parkX: 1000 - f, parkY: 1000 }]);
  // ... and on across the seam.
  const west = { parkX: 5, parkY: 1000, width: 800, height: 600 };
  assert.deepEqual(pointer.edgeScroll({ kind: "pan", x: 800, y: 300 }, west), [{ kind: "pan", parkX: W + 5 - f, parkY: 1000 }]);
  // A dog held at the bottom edge (its square at the screen's edge): it and the viewport go south together.
  const bottom = 1600 - scene.dog_px / 2;
  assert.deepEqual(pointer.edgeScroll(held(1400, bottom), near), [
    { kind: "drag", dogId: 9, parkX: 1400, parkY: bottom + f },
    { kind: "pan", parkX: 1000, parkY: 1000 + f },
  ]);
  // A dog at the world's top edge goes on north across the seam, and the viewport with it.
  const top = { parkX: 1000, parkY: W - scene.dog_px / 2, width: 800, height: 600 };
  assert.deepEqual(pointer.edgeScroll(held(1400, 0), top), [
    { kind: "drag", dogId: 9, parkX: 1400, parkY: W - f },
    { kind: "pan", parkX: 1000, parkY: W - scene.dog_px / 2 - f },
  ]);
});

test("where a hand holds a pan: the pointer, or none", () => {
  assert.equal(pointer.panPointer(pointer.resting), "none");
  assert.deepEqual(pointer.panPointer({ kind: "panning", lastX: 3, lastY: 4 }), { x: 3, y: 4 });
  assert.equal(pointer.panPointer({ kind: "dragging", dogId: 219, lastX: 0, lastY: 0 }), "none");
});

test("a press is on what was drawn in the mode it is made in", () => {
  const viewport = { parkX: 0, parkY: 0, width: 800, height: 600 };
  const nearList = scene.nearScene(viewport, [{ id: 1, emoji: "🐕", parkX: 100, parkY: 100 }], [], { kind: "none" });
  const overList = scene.overviewScene(viewport, [], [], new Map(), { kind: "none" }, { parkX: 0, parkY: 0 });
  const view = overList.find((o) => o.id === scene.view_target);
  assert.equal(pointer.pressedOn({ mode: "near", objects: nearList }, "near", 100, 100), "dog:1");
  assert.equal(pointer.pressedOn({ mode: "overview", objects: overList }, "overview", view.x, view.y), scene.view_target);
  // Pressed after "m", before a frame drew the new mode: on nothing.
  assert.equal(pointer.pressedOn({ mode: "near", objects: nearList }, "overview", 100, 100), null);
  assert.equal(pointer.pressedOn({ mode: "overview", objects: overList }, "near", view.x, view.y), null);
});

// ── across the seam (the torus, docs/PHYSICS.md decision 14) ───────────────

const W = scene.world_px;

test("across the seam, the near scene: a viewport straddling x = 0, y = 0 and the corner draws the tiles there, the critters at their copies on screen", () => {
  const T = scene.tile_px;
  const last = scene.world_tiles - 1;
  // 800 x 600 at (-300, -200) named in the world: its top-left at (W - 300, W - 200).
  const viewport = { parkX: W - 300, parkY: W - 200, width: 800, height: 600 };
  const dogs = [{ id: 1, emoji: "🐕", parkX: W - 10, parkY: 100 }, { id: 2, emoji: "🐕", parkX: 10, parkY: 100 }];
  const cows = [{ id: 5, parkX: 200, parkY: W - 50 }];
  const near = scene.nearScene(viewport, dogs, cows, { kind: "kept", dogId: 2 }, undefined, new Map(), { chickens: [], poops: [], labels: "shown" });
  const byId = new Map(near.map((o) => [o.id, o]));
  // The tiles: the last row and column above and west of the seam, the first ones past it.
  const tileIds = ids(near).filter((i) => /^tile:[^:]*$/.test(i));
  for (const id of [`tile:${last},${last}`, `tile:0,${last}`, `tile:${last},0`, "tile:0,0"]) assert.ok(tileIds.includes(id), id);
  assert.deepEqual([byId.get(`tile:${last},${last}`).x, byId.get(`tile:${last},${last}`).y], [300 - T, 200 - T]);
  assert.deepEqual([byId.get("tile:0,0").x, byId.get("tile:0,0").y], [300, 200]);
  assert.equal(byId.get(`tile:${last},0:label`).text, `(${last}, 0)`);
  // The checkerboard runs on across the seam (an even world): (last, last) and (0, 0) alike, (0, last) the other shade.
  assert.equal(byId.get(`tile:${last},${last}`).fill, byId.get("tile:0,0").fill);
  assert.notEqual(byId.get(`tile:0,${last}`).fill, byId.get("tile:0,0").fill);
  // Two dogs 20 px apart across the seam are drawn 20 px apart; the ring on the one past it.
  assert.deepEqual([byId.get("dog:1").x, byId.get("dog:1").y], [290, 300]);
  assert.deepEqual([byId.get("dog:2").x, byId.get("dog:2").y], [310, 300]);
  assert.deepEqual([byId.get("dog:2:ring").x, byId.get("dog:2:ring").y], [310, 300]);
  assert.deepEqual([byId.get("cow:5").x, byId.get("cow:5").y], [500, 150]);
  assert.equal(byId.get("dog:1:label").text, "1");
});

test("across the seam: a viewport a whole world away, or a critter's copy, draws the same", () => {
  const dogs = [{ id: 1, emoji: "🐕", parkX: W - 10, parkY: 5 }, { id: 2, emoji: "🐕", parkX: 10, parkY: W - 5 }];
  const cows = [{ id: 5, parkX: 200, parkY: 31990 }];
  for (const at of [{ parkX: W - 300, parkY: W - 200 }, { parkX: 100, parkY: 7000 }, { parkX: 15000, parkY: W - 400 }]) {
    const viewport = { ...at, width: 800, height: 600 };
    const base = scene.nearScene(viewport, dogs, cows, { kind: "none" });
    for (const [kx, ky] of [[1, 0], [0, -1], [-2, 3]]) {
      const moved = { ...viewport, parkX: at.parkX + kx * W, parkY: at.parkY + ky * W };
      assert.deepEqual(scene.nearScene(moved, dogs, cows, { kind: "none" }), base);
      const copies = (cs) => cs.map((c) => ({ ...c, parkX: c.parkX - kx * W, parkY: c.parkY + ky * W }));
      const drawn = scene.nearScene(viewport, copies(dogs), copies(cows), { kind: "none" });
      assert.deepEqual(drawn.filter((o) => !o.id.endsWith(":label")), base.filter((o) => !o.id.endsWith(":label")));
    }
  }
});

test("across the seam, between ticks: a critter that wraps from x = world - 1 to x = 0 glides 1 px, not across the world", () => {
  assert.deepEqual(scene.between({ parkX: W - 1, parkY: 100 }, { parkX: 0, parkY: 100 }, 0.5), { parkX: W - 0.5, parkY: 100 });
  assert.deepEqual(scene.between({ parkX: 0.5, parkY: 0 }, { parkX: W - 0.5, parkY: W - 1 }, 0.5), { parkX: 0, parkY: W - 0.5 });
  assert.deepEqual(scene.between({ parkX: W - 1, parkY: 100 }, { parkX: 0, parkY: 100 }, 1), { parkX: 0, parkY: 100 });
  // Drawn: half way, it is half a px from where it was on screen, the viewport too gliding across.
  const viewport = { parkX: 10, parkY: 0, width: 800, height: 600 };
  const motion = { alpha: 0.25, was: { viewport: { parkX: W - 30, parkY: 0 }, dogs: new Map([[1, { parkX: W - 1, parkY: 100 }]]), cows: new Map() } };
  const dog = scene.nearScene(viewport, [{ id: 1, emoji: "🐕", parkX: 3, parkY: 100 }], [], { kind: "none" }, motion).find((o) => o.id === "dog:1");
  // The viewport at W - 30 + 40 * 0.25 = W - 20; the dog at W - 1 + 4 * 0.25 = 0.
  assert.deepEqual([dog.x, dog.y], [20, 100]);
});

test("across the seam, the overview: dots and the view at their copies in the window, which starts past the corner", () => {
  // 1040 x 700, the window's top-left at (W - 1000, W - 500): it wraps round the corner.
  const viewport = { parkX: W - 100, parkY: 100, width: 1040, height: 700 };
  const over = scene.overviewScene(viewport, [{ id: 1, parkX: 50, parkY: 50 }, { id: 2, parkX: W - 50, parkY: W - 50 }], [], new Map(), { kind: "none" },
    { parkX: W - 1000, parkY: W - 500 });
  const byId = new Map(over.map((o) => [o.id, o]));
  const s = 660 / W;
  const at = (x, y) => [x, y].map((p) => Math.round(p * 1e6) / 1e6);
  assert.deepEqual(at(byId.get("dog:1").x, byId.get("dog:1").y), at(190 + 1050 * s, 20 + 550 * s));
  assert.deepEqual(at(byId.get("dog:2").x, byId.get("dog:2").y), at(190 + 950 * s, 20 + 450 * s));
  assert.deepEqual(at(byId.get("view").x, byId.get("view").y), at(190 + 900 * s, 20 + 600 * s));
  assert.deepEqual(at(byId.get("tile:0,0").x, byId.get("tile:0,0").y), at(190 + 1000 * s, 20 + 500 * s));
  // One thumb, the whole track, pressable.
  const thumbs = over.filter((o) => o.id === scene.thumbTarget("x"));
  assert.equal(thumbs.length, 1);
  assert.equal(blit.hit(over, thumbs[0].x + 1, thumbs[0].y + 1), scene.thumbTarget("x"));
});

test("in the map, a tap on the view's rectangle goes back to normal mode; a press that travels past the slop drags it; a cancel is no tap", () => {
  const view = { parkX: scene.world_px / 2, parkY: scene.world_px / 2, width: 1280, height: 800 };
  const at = { parkX: 0, parkY: 0 };
  const press = (hand, event) => pointer.meaning(hand, event, scene.view_target, "overview", view, at);
  const slop = pointer.tap_slop_px;
  // A clean tap, and one that jitters within the slop.
  let down = press(pointer.resting, { type: "down", x: 300, y: 200, dogAt: "none" });
  assert.deepEqual(down.intents, []);
  assert.deepEqual(press(down.hand, { type: "up" }).intents, [{ kind: "mode", mode: "near" }]);
  const jitter = press(down.hand, { type: "move", x: 300 + slop, y: 200 - slop });
  assert.deepEqual(jitter.intents, [], "within the slop the view stays put");
  assert.deepEqual(press(jitter.hand, { type: "up" }).intents, [{ kind: "mode", mode: "near" }]);
  // Past the slop: a drag, from where the press went down, and no mode on letting go.
  const dragged = press(down.hand, { type: "move", x: 300 + slop + 1, y: 200 });
  assert.equal(dragged.intents[0].kind, "pan");
  assert.equal(dragged.intents[0].parkX, scene.wrapped(view.parkX + (slop + 1) / scene.overviewFrame(view.width, view.height, at).scale));
  assert.deepEqual(press(dragged.hand, { type: "up" }).intents, []);
  // The system took the pointer: no tap.
  assert.deepEqual(press(down.hand, { type: "cancel" }).intents, []);
});

test("tough love: a press on a cow or a chicken is named (a dog is the page's own hit), round the torus; the lines turn, never twice running, and persistence is noticed until a dog is grabbed", async () => {
  const quips = await import("../solo/quips.js");
  const view = { parkX: 100, parkY: 100, width: 800, height: 600 };
  const cows = [{ parkX: 300, parkY: 300 }];
  const chickens = [{ parkX: 500, parkY: 300 }, { parkX: 10, parkY: 10 }];
  assert.equal(quips.pressedCritter(view, 200, 200, cows, chickens), "cow");
  assert.equal(quips.pressedCritter(view, 200 + scene.cow_px / 2, 200, cows, chickens), "cow");
  assert.equal(quips.pressedCritter(view, 200 + scene.cow_px / 2 + 1, 200, cows, chickens), null);
  assert.equal(quips.pressedCritter(view, 400 + scene.chicken_px / 2 + 4, 200, cows, chickens), "chicken");
  assert.equal(quips.pressedCritter(view, 300, 400, cows, chickens), null, "empty ground: the tablecloth");
  // A chicken across the world's seam from the view's copy.
  const seam = { parkX: scene.world_px - 50, parkY: scene.world_px - 50, width: 800, height: 600 };
  assert.equal(quips.pressedCritter(seam, 60, 60, cows, chickens), "chicken");
  const q = quips.quipper(() => 0);
  const said = [q.say("cow"), q.say("cow"), q.say("chicken"), q.say("cow")];
  assert.notEqual(said[0], said[1]);
  assert.match(said[2], /chicken|BAWK|herd|union|dinosaur|poop/i);
  const fifth = q.say("chicken");
  assert.equal(fifth, "Okay, now you're just doing it on purpose.");
  q.forgive();
  assert.notEqual(q.say("cow"), "The critters have started a group chat about you.");
  // A bump: what it hit, from the tick's lines, and a line for each kind, turning, with no persistence remark.
  assert.equal(quips.bumpedKind("dog 3 1a00,1b00\nbump 1042 chicken 2\n"), "chicken");
  assert.equal(quips.bumpedKind("bump 7 poop 12\n"), "poop");
  assert.equal(quips.bumpedKind("dog 3 1a00,1b00\n"), null);
  const b = quips.bumper(() => 0);
  for (const kind of ["dog", "cow", "chicken", "poop"]) assert.notEqual(b.say(kind), b.say(kind));
  for (let i = 0; i < 10; i++) assert.doesNotMatch(b.say("cow"), /on purpose|group chat|Still no/);
});
