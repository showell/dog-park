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
  assert.equal(engine.spacing_ms, 250);
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
  assert.deepEqual(scene.wrappedPoint(-5, 99999), { parkX: W - 5, parkY: 99999 - 3 * W });
  assert.deepEqual(scene.wrappedPoint(-1000, 0), { parkX: W - 1000, parkY: 0 });
  assert.ok(Object.is(scene.wrapped(-W), 0) && Object.is(scene.wrapped(-0), 0));
  assert.equal(scene.wrapped(3550.4), 3550.4);
  // The short way round, and the nearest copy.
  assert.equal(scene.offset(W - 1, 0), 1);
  assert.equal(scene.offset(0, W - 1), -1);
  assert.equal(scene.offset(100, 300), 200);
  assert.equal(scene.nearest(W - 10, 20), -10);
  assert.equal(scene.nearest(10, W - 20), W + 10);
  assert.equal(scene.nearest(3550.4, 750), 3550.4);
  assert.deepEqual(scene.wrapTile({ col: -1, row: 64 }), { col: 63, row: 0 });
});

test("tiles: a point's tile, its key, and those meeting a rectangle", () => {
  assert.deepEqual(scene.tileOf(499, 500), { col: 0, row: 1 });
  assert.equal(scene.tileKey({ col: 3, row: 7 }), "3,7");
  assert.deepEqual(scene.tilesMeeting(499, 0, 2, 1), [{ col: 0, row: 0 }, { col: 1, row: 0 }]);
  // Across the seam, the tiles wrap: row by row as they lie, each once.
  assert.deepEqual(scene.tilesMeeting(-10, -10, 20, 20), [{ col: 63, row: 63 }, { col: 0, row: 63 }, { col: 63, row: 0 }, { col: 0, row: 0 }]);
  assert.deepEqual(scene.tileCopiesMeeting(-10, -10, 20, 20), [{ col: -1, row: -1 }, { col: 0, row: -1 }, { col: -1, row: 0 }, { col: 0, row: 0 }]);
});

test("the tiles wanted: the widest margin within the cap", () => {
  // 1000 x 700 at (2000, 2000): the 250 px margin meets cols 3..6, rows 3..5.
  const small = scene.wantedTiles({ parkX: 2000, parkY: 2000, width: 1000, height: 700 });
  assert.equal(small.length, 12);
  assert.deepEqual([small[0], small.at(-1)], [{ col: 3, row: 3 }, { col: 6, row: 5 }]);
  // The cap is 64 tiles, 8 x 8 (the server's tiles.zig).
  assert.equal(scene.most_tiles, 64);
  // 1600 square at (1200, 1200): 250 px meets 6 x 6, within the cap.
  const square = scene.wantedTiles({ parkX: 1200, parkY: 1200, width: 1600, height: 1600 });
  assert.equal(square.length, 36);
  assert.deepEqual([square[0], square.at(-1)], [{ col: 1, row: 1 }, { col: 6, row: 6 }]);
  // 3300 square at (2200, 2200): 250 px meets 9 x 9, past the cap; 125 px meets cols and rows 4..11.
  const mid = scene.wantedTiles({ parkX: 2200, parkY: 2200, width: 3300, height: 3300 });
  assert.equal(mid.length, 64);
  assert.deepEqual([mid[0], mid.at(-1)], [{ col: 4, row: 4 }, { col: 11, row: 11 }]);
  // 4000 square at (2000, 2000): every margin meets 10 x 10, past the cap;
  // the screen's own tiles are 8 x 8, cols and rows 4..11.
  const wide = scene.wantedTiles({ parkX: 2000, parkY: 2000, width: 4000, height: 4000 });
  assert.equal(wide.length, 64);
  assert.deepEqual([wide[0], wide.at(-1)], [{ col: 4, row: 4 }, { col: 11, row: 11 }]);
  // 4100 square: the screen itself meets 10 x 10, past the cap: all of
  // them (the subscription keeps the nearest 64).
  assert.equal(scene.wantedTiles({ parkX: 1950, parkY: 1950, width: 4100, height: 4100 }).length, 100);
});

test("the world is 64 x 64 tiles, the server's; its middle is the populated park's", () => {
  assert.equal(scene.world_tiles, 64);
  assert.equal(scene.world_px, 32000);
  // The park: 10 x 10 tiles from 13,500 px (tiles.zig's park_offset_px).
  assert.equal(scene.world_px / 2, 13500 + 10 * scene.tile_px / 2);
  assert.deepEqual(scene.wrappedPoint(31999.5, 32000), { parkX: 31999.5, parkY: 0 });
  assert.deepEqual(scene.tilesMeeting(31990, 31990, 50, 50), [{ col: 63, row: 63 }, { col: 0, row: 63 }, { col: 63, row: 0 }, { col: 0, row: 0 }]);
});

test("the overview frame: a window 10 tiles across its shorter side, at its top-left, named in the world", () => {
  // 1040 x 700: the window is 1000 x 660 on screen, 660 px for 5000 park px
  // (the scale the whole 10 x 10 world had): 7576 x 5000 of the world.
  const o = scene.overviewFrame(1040, 700, { parkX: 0, parkY: 0 });
  assert.equal(o.scale, 660 / 5000);
  assert.deepEqual(o.window, { x: 20, y: 20, w: 1000, h: 660 });
  assert.deepEqual(o.span, { parkW: 1000 / 0.132, parkH: 5000 });
  assert.deepEqual(scene.overviewFromPark(o, 0, 0), { viewportX: 20, viewportY: 20 });
  // Never the whole world.
  assert.ok(o.span.parkW < scene.world_px && o.span.parkH < scene.world_px);
  // The window's top-left at (13500, 14000): that point is the window's corner.
  const mid = scene.overviewFrame(1040, 700, { parkX: 13500, parkY: 14000 });
  assert.deepEqual(scene.overviewFromPark(mid, 13500, 14000), { viewportX: 20, viewportY: 20 });
  // Past the world's far corner, or before its near one, the window wraps round.
  assert.deepEqual(scene.overviewFrame(1040, 700, { parkX: 99999, parkY: 99999 }).at, { parkX: 99999 - 3 * 32000, parkY: 99999 - 3 * 32000 });
  assert.deepEqual(scene.overviewFrame(1040, 700, { parkX: -5, parkY: -5 }).at, { parkX: 32000 - 5, parkY: 32000 - 5 });
  // The scrollbars in the margins, the window's length; each thumb as long,
  // and as far along, as the window is in the world.
  assert.deepEqual(o.tracks, { x: { x: 20, y: 684, w: 1000, h: 12 }, y: { x: 1024, y: 20, w: 12, h: 660 } });
  assert.deepEqual(scene.overviewThumb(o, "x"), [{ x: 20, y: 684, w: (1000 / 0.132 / 32000) * 1000, h: 12 }]);
  assert.deepEqual(scene.overviewThumb(mid, "y"), [{ x: 1024, y: 20 + (14000 / 32000) * 660, w: 12, h: ((14000 + 5000) / 32000) * 660 - (14000 / 32000) * 660 }]);
  // Across the seam the thumb wraps: its part past the track's end drawn from its start.
  const seam = scene.overviewFrame(1040, 700, { parkX: 0, parkY: 30000 });
  assert.deepEqual(scene.overviewThumb(seam, "y"), [
    { x: 1024, y: 20 + (30000 / 32000) * 660, w: 12, h: 660 - (30000 / 32000) * 660 },
    { x: 1024, y: 20, w: 12, h: (35000 / 32000) * 660 - 660 },
  ]);
});

test("the overview opens centred on the view, the park's middle on a first visit's", () => {
  // 800 x 600: 560 px for 5000 park px; the window 760 / 0.112 park px wide.
  const at = scene.overviewCentredOn({ parkX: 15600, parkY: 15700, width: 800, height: 600 });
  assert.deepEqual(at, { parkX: 16000 - 760 / 0.112 / 2, parkY: 13500 });
  // At the world's corner: centred across the seam.
  assert.deepEqual(scene.overviewCentredOn({ parkX: 0, parkY: 0, width: 800, height: 600 }),
    { parkX: 32000 + 400 - 760 / 0.112 / 2, parkY: 32000 + 300 - 2500 });
});

test("the overview's window moves: by a thumb's drag, a track's jump, and to show the view", () => {
  const o = scene.overviewFrame(1040, 700, { parkX: 10000, parkY: 10000 });
  // A thumb dragged 10 px along its 1000 px track: 320 park px.
  assert.deepEqual(scene.overviewScrolled(o, "x", 10), { parkX: 10320, parkY: 10000 });
  assert.deepEqual(scene.overviewScrolled(o, "y", -66), { parkX: 10000, parkY: 10000 - 3200 });
  // ... on round the torus.
  assert.deepEqual(scene.overviewScrolled(o, "x", -500), { parkX: 32000 + 10000 - 16000, parkY: 10000 });
  // A press at the track's middle centres the thumb there: the window's middle at the world's.
  assert.deepEqual(scene.overviewJumped(o, "x", 520, 690), { parkX: 16000 - 1000 / 0.132 / 2, parkY: 10000 });
  assert.deepEqual(scene.overviewMoved(o, 100, -200), { parkX: 10100, parkY: 9800 });
  // A view inside the window leaves it; one past its edge moves it as little as shows it.
  const view = { width: 1040, height: 700 };
  assert.deepEqual(scene.overviewShowing(o, { ...view, parkX: 12000, parkY: 12000 }), o.at);
  assert.deepEqual(scene.overviewShowing(o, { ...view, parkX: 9000, parkY: 14800 }), { parkX: 9000, parkY: 14800 + 700 - 5000 });
  // Across the seam: a window at the world's bottom-right corner shows a view
  // just past it, at its copy nearest the window, and carries the window over.
  const corner = scene.overviewFrame(1040, 700, { parkX: 32000 - 7000, parkY: 32000 - 4000 });
  assert.deepEqual(scene.overviewShowing(corner, { ...view, parkX: 31000, parkY: 31000 }), corner.at);
  assert.deepEqual(scene.overviewShowing(corner, { ...view, parkX: 31000, parkY: 400 }),
    { parkX: 32000 - 7000, parkY: 32000 + 400 + 700 - 5000 });
  // A view straddling the seam west of a window just east of it: the window's top-left wraps.
  const east = scene.overviewFrame(1040, 700, { parkX: 100, parkY: 10000 });
  assert.deepEqual(scene.overviewShowing(east, { ...view, parkX: 31800, parkY: 12000 }), { parkX: 31800, parkY: 10000 });
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
  assert.equal(pointer.axisScroll(780, 800, scene.dog_px / 2), pointer.fastest_px_per_tick);
  const shallow = pointer.axisScroll(800 - 20 - pointer.band_px + 8, 800, 20);
  assert.ok(shallow > 0 && shallow < pointer.fastest_px_per_tick);
});

test("the subscription: the region's tiles first, then the display's nearest the centre, at most 64", () => {
  // 1000 x 700 at (2000, 2000): the display's 12 tiles (cols 3..6, rows
  // 3..5), the centre (2500, 2350) in tile 5,4.
  const v = { parkX: 2000, parkY: 2000, width: 1000, height: 700 };
  const display = scene.subscription([], v);
  assert.equal(display.length, 12);
  assert.deepEqual(display.slice(0, 2), [{ col: 4, row: 4 }, { col: 5, row: 4 }]);
  // The region first, whatever the distance; a tile in both once.
  const region = [{ col: 40, row: 40 }, { col: 4, row: 4 }];
  const both = scene.subscription(region, v);
  assert.deepEqual(both.slice(0, 3), [{ col: 40, row: 40 }, { col: 4, row: 4 }, { col: 5, row: 4 }]);
  assert.equal(both.length, 13);
  // Over the cap: the region's 25 and the display's nearest 39.
  const big = { parkX: 2000, parkY: 2000, width: 4000, height: 4000 };
  const r25 = [];
  for (let c = 30; c < 35; c++) for (let r = 30; r < 35; r++) r25.push({ col: c, row: r });
  const capped = scene.subscription(r25, big);
  assert.equal(capped.length, 64);
  assert.deepEqual(capped.slice(0, 25), r25);
  // The nearest display tiles to (4000, 4000): the four around it.
  assert.deepEqual(capped.slice(25, 29), [{ col: 7, row: 7 }, { col: 8, row: 7 }, { col: 7, row: 8 }, { col: 8, row: 8 }]);
});

test("a dog's look is its breed, n mod 4", () => {
  assert.deepEqual(scene.dog_looks, ["🐕", "🐩", "🦮", "🐕‍🦺"]);
});

// ── what a frame draws, and what a press is on ──────────────────────────────

test("between ticks: part way however far (a fast drag's walk glides), where it is when new (or jumped: the engine leaves it out)", () => {
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
  const byId = new Map(scene.nearScene(viewport, dogs, cows, { kind: "in_hand", dogId: 7 }, motion).map((o) => [o.id, o]));
  // The viewport drawn at 445: dog 7 at 510, so x 65; its ring with it.
  assert.equal(byId.get("tile:1,0").x, 55);
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
  // 600 x 400 at (450, 0): tiles (0,0) to (2,0), the tile columns from x -450.
  const viewport = { parkX: 450, parkY: 0, width: 600, height: 400 };
  const dogs = [{ id: 7, emoji: "🐕", parkX: 500, parkY: 100 }, { id: 3, emoji: "🐩", parkX: 4000.4, parkY: 4000 }];
  const cows = [{ id: 23, parkX: 600.5, parkY: 250 }];
  const near = scene.nearScene(viewport, dogs, cows, { kind: "kept", dogId: 7 });
  assert.deepEqual(ids(near), [
    "tile:0,0", "tile:0,0:label", "tile:1,0", "tile:1,0:label", "tile:2,0", "tile:2,0:label",
    "cow:23", "dog:7:ring", "dog:7", "dog:7:label", "dog:3", "dog:3:label",
  ]);
  const byId = new Map(near.map((o) => [o.id, o]));
  assert.deepEqual(byId.get("tile:1,0"), { id: "tile:1,0", shape: "rect", x: 50, y: 0, w: 500, h: 500, fill: "#eaf3fc", role: "scenery" });
  assert.deepEqual(byId.get("tile:0,0:label"), { id: "tile:0,0:label", shape: "text", x: -200, y: 250, w: 0, h: 0, text: "(0, 0)", font: "20px monospace", fill: "#9ab", role: "scenery" });
  assert.equal(byId.get("tile:0,0").fill, "#ffffff");
  // A cow: a 60 px glyph, never a target, its place to the pixel under it.
  assert.deepEqual(byId.get("cow:23"), { id: "cow:23", shape: "glyph", x: 150.5, y: 250, w: 60, h: 60, text: "🐄", fill: "#000", role: "scenery" });
  // A cow has no label; a dog's is its number.
  assert.equal(byId.get("cow:23:label"), undefined);
  // The leashed dog: a red ring under its 40 px glyph, which is a target.
  assert.deepEqual(byId.get("dog:7:ring"), { id: "dog:7:ring", shape: "ring", x: 50, y: 100, w: 2 * (40 * 0.7), h: 2 * (40 * 0.7), stroke: "#d33", lineWidth: 3, role: "scenery" });
  assert.deepEqual(byId.get("dog:7"), { id: "dog:7", shape: "glyph", x: 50, y: 100, w: 40, h: 40, text: "🐕", fill: "#000", role: "target" });
  // A far dog is still drawn (off the screen), unringed.
  assert.deepEqual(byId.get("dog:3"), { id: "dog:3", shape: "glyph", x: 3550.4, y: 4000, w: 40, h: 40, text: "🐩", fill: "#000", role: "target" });
  assert.equal(byId.get("dog:3:label").text, "3");
  // No leash, no ring.
  assert.ok(!ids(scene.nearScene(viewport, dogs, cows, { kind: "none" })).includes("dog:7:ring"));
});

test("the overview scene: the window's tiles shaded by subscription, its dots by freshness, the last leashed ringed, the margins, the view, the scrollbars", () => {
  // 1040 x 700, the window at the world's corner: scale 660 / 5000, origin
  // (20, 20); a tile is 66 px, and 16 x 10 of them meet the window.
  const viewport = { parkX: 500, parkY: 1000, width: 1040, height: 700 };
  const subscribed = new Map([["1,2", true], ["0,0", true]]);
  const dogs = [{ id: 7, parkX: 600, parkY: 1100 }, { id: 3, parkX: 4000, parkY: 4000 }, { id: 9, parkX: 20000, parkY: 100 }];
  const cows = [{ id: 23, parkX: 50, parkY: 50 }, { id: 24, parkX: 2600, parkY: 50 }, { id: 25, parkX: 50, parkY: 5001 }];
  const over = scene.overviewScene(viewport, dogs, cows, subscribed, { kind: "dog", dogId: 3 }, { parkX: 0, parkY: 0 });
  assert.equal(over.length, 1 + 160 + 2 + 2 + 1 + 4 + 1 + 4);
  assert.deepEqual(over[0], { id: "ground", shape: "rect", x: 0, y: 0, w: 1040, h: 700, fill: "#556", role: "scenery" });
  const byId = new Map(over.map((o) => [o.id, o]));
  // Subscribed: white and blue; not: two pinks.
  assert.equal(byId.get("tile:0,0").fill, "#ffffff");
  assert.equal(byId.get("tile:1,2").fill, "#eaf3fc");
  assert.equal(byId.get("tile:2,2").fill, "#f8d8d8");
  assert.equal(byId.get("tile:2,1").fill, "#f2c4c4");
  assert.equal(byId.get("tile:1,2").x, 20 + 66);
  assert.equal(byId.get("tile:1,2").w, 500 * 660 / 5000);
  assert.ok(byId.has("tile:15,9") && !byId.has("tile:16,9") && !byId.has("tile:15,10"));
  // A cow in a subscribed tile is dark brown, one elsewhere pale; 8 px across.
  assert.deepEqual(byId.get("cow:23"), { id: "cow:23", shape: "dot", x: 20 + 50 * 0.132, y: 20 + 50 * 0.132, w: 8, h: 8, fill: "#7a4a1a", role: "scenery" });
  assert.equal(byId.get("cow:24").fill, "#c9a37a");
  // A critter outside the window is not drawn.
  assert.ok(!byId.has("cow:25") && !byId.has("dog:9"));
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
  assert.deepEqual(byId.get("view"), { id: "view", shape: "frame", x: 20 + 500 * 0.132, y: 20 + 1000 * 0.132, w: 1040 * 0.132, h: 700 * 0.132, stroke: "#222", lineWidth: 2, role: "target" });
  assert.deepEqual(byId.get("scroll:x"), { id: "scroll:x", shape: "rect", x: 20, y: 684, w: 1000, h: 12, fill: "#778", role: "target" });
  assert.equal(byId.get("scroll:y:thumb").role, "target");
  // The window in the park's middle: the park's critters there, drawn from its corner.
  const mid = scene.overviewScene(viewport, [{ id: 0, parkX: 13655, parkY: 13850 }], [], subscribed, { kind: "none" }, { parkX: 13500, parkY: 13500 });
  // (To a millionth of a px: the origin is 20 - 13500 * scale.)
  const dog0 = mid.find((o) => o.id === "dog:0");
  assert.deepEqual([dog0.x, dog0.y].map((v) => Math.round(v * 1e6) / 1e6), [20 + 155 * 0.132, 20 + 350 * 0.132]);
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
  assert.equal(scene.dogOfTarget(blit.hit(near, 85, 95)), 1);
  assert.equal(scene.dogOfTarget(blit.hit(near, 300, 300)), "none"); // a cow
  assert.equal(blit.hit(near, 500, 500), null); // ground
  assert.equal(scene.dogOfTarget(null), "none");
  assert.equal(scene.dogOfTarget("view"), "none");
  assert.equal(scene.dogOfTarget(scene.dogTarget(219)), 219);
});

test("a press in the overview is on the view's rectangle, a scrollbar's thumb or track, or nothing", () => {
  const viewport = { parkX: 500, parkY: 1000, width: 1040, height: 700 };
  const over = scene.overviewScene(viewport, [{ id: 7, parkX: 600, parkY: 1100 }], [], new Map(), { kind: "dog", dogId: 7 }, { parkX: 0, parkY: 0 });
  const view = over.find((o) => o.id === scene.view_target);
  assert.equal(blit.hit(over, view.x, view.y), scene.view_target);
  assert.equal(blit.hit(over, view.x + view.w, view.y + view.h), scene.view_target);
  assert.equal(blit.hit(over, view.x - 1, view.y), null);
  assert.equal(blit.hit(over, 5, 5), null);
  // The x thumb runs from 20 to about 257 on its track at y 684 to 696.
  assert.equal(blit.hit(over, 100, 690), scene.thumbTarget("x"));
  assert.equal(blit.hit(over, 600, 690), scene.trackTarget("x"));
  assert.equal(blit.hit(over, 1030, 600), scene.trackTarget("y"));
  assert.equal(blit.hit(over, 1030, 30), scene.thumbTarget("y"));
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
    { event: { type: "move", x: 5000, y: 0 }, hand: { kind: "panning", lastX: 5000, lastY: 0 }, intents: [{ kind: "pan", parkX: 32000 - 4000, parkY: 1000 }] },
    { event: { type: "move", x: 5000, y: 3000 }, hand: { kind: "panning", lastX: 5000, lastY: 3000 }, intents: [{ kind: "pan", parkX: 1000, parkY: 32000 - 2000 }] },
  ], { viewport: near });
});

test("in the overview, a press on the view's rectangle drags it, scaled; one off it means nothing", () => {
  // 1040 x 700: scale 660 / 5000 = 0.132.
  const viewport = { parkX: 500, parkY: 1000, width: 1040, height: 700 };
  play([
    { event: { type: "down", x: 300, y: 200, dogAt: "none" }, hit: scene.view_target,
      hand: { kind: "panning", lastX: 300, lastY: 200 }, intents: [] },
    { event: { type: "move", x: 300 + 13.2, y: 200 - 6.6 },
      hand: { kind: "panning", lastX: 313.2, lastY: 193.4 }, intents: [{ kind: "pan", parkX: 500 + (313.2 - 300) / 0.132, parkY: 1000 + (193.4 - 200) / 0.132 }] },
    { event: { type: "up" }, hand: pointer.resting, intents: [] },
    // Off the rectangle: on nothing, so resting, and a move means nothing.
    { event: { type: "down", x: 5, y: 5, dogAt: "none" }, hit: null, hand: pointer.resting, intents: [] },
    { event: { type: "move", x: 50, y: 50 }, hand: pointer.resting, intents: [] },
  ], { mode: "overview", viewport });
});

test("in the overview, the view's rectangle dragged past the window's edge carries the window", () => {
  // The window at (0, 0) is 7576 x 5000 park px; the view, 700 high, at y 4200: 100 px from its bottom.
  const viewport = { parkX: 500, parkY: 4200, width: 1040, height: 700 };
  play([
    { event: { type: "down", x: 300, y: 600, dogAt: "none" }, hit: scene.view_target,
      hand: { kind: "panning", lastX: 300, lastY: 600 }, intents: [] },
    // 26.4 px down is 200 park px: the view's bottom at 5100, so the window's at 5100 too.
    { event: { type: "move", x: 300, y: 626.4 },
      hand: { kind: "panning", lastX: 300, lastY: 626.4 },
      intents: [{ kind: "pan", parkX: 500, parkY: 4200 + 26.4 / 0.132 }, { kind: "scroll", parkX: 0, parkY: 4200 + 26.4 / 0.132 + 700 - 5000 }] },
  ], { mode: "overview", viewport, overviewAt: { parkX: 0, parkY: 0 } });
});

test("in the overview, a scrollbar: the thumb held where pressed, the track jumping the thumb there; the wheel scrolls", () => {
  const viewport = { parkX: 15000, parkY: 15000, width: 1040, height: 700 };
  const overviewAt = { parkX: 10000, parkY: 10000 };
  play([
    { event: { type: "down", x: 400, y: 690, dogAt: "none" }, hit: scene.thumbTarget("x"),
      hand: { kind: "scrolling", axis: "x", lastX: 400, lastY: 690 }, intents: [] },
    // 10 px along the 1000 px track: 320 park px; the pointer's drift across it means nothing.
    { event: { type: "move", x: 410, y: 650 },
      hand: { kind: "scrolling", axis: "x", lastX: 410, lastY: 650 }, intents: [{ kind: "scroll", parkX: 10320, parkY: 10000 }] },
    { event: { type: "up" }, hand: pointer.resting, intents: [] },
  ], { mode: "overview", viewport, overviewAt });
  play([
    { event: { type: "down", x: 1030, y: 350, dogAt: "none" }, hit: scene.trackTarget("y"),
      hand: { kind: "scrolling", axis: "y", lastX: 1030, lastY: 350 }, intents: [{ kind: "scroll", parkX: 10000, parkY: 16000 - 2500 }] },
  ], { mode: "overview", viewport, overviewAt });
  play([
    { event: { type: "wheel", dx: 13.2, dy: -6.6 }, hand: pointer.resting, intents: [{ kind: "scroll", parkX: 10100, parkY: 9950 }] },
    // Against the world's edge, nothing moves.
    { event: { type: "wheel", dx: 0, dy: 0 }, hand: pointer.resting, intents: [] },
  ], { mode: "overview", viewport, overviewAt });
  play([
    { event: { type: "wheel", dx: 0, dy: -1650 }, hand: pointer.resting, intents: [{ kind: "scroll", parkX: 10000, parkY: 32000 + 10000 - 12500 }] },
  ], { mode: "overview", viewport, overviewAt });
  // Near, a wheel means nothing.
  play([{ event: { type: "wheel", dx: 10, dy: 10 }, hand: pointer.resting, intents: [] }], { viewport });
});

test('"z" mid-drag lets go and flips the mode; resting, it only flips; the overview opens centred on the view', () => {
  const centred = scene.overviewCentredOn(near);
  const opened = { kind: "scroll", parkX: centred.parkX, parkY: centred.parkY };
  const held = { kind: "dragging", dogId: 7, lastX: 100, lastY: 200 };
  play([
    { event: { type: "down", x: 100, y: 200, dogAt: { parkX: 1100, parkY: 1200 } }, hit: "dog:7",
      hand: held, intents: [{ kind: "grab", dogId: 7 }] },
    { event: { type: "z" }, hand: pointer.resting, intents: [{ kind: "letgo" }, { kind: "mode", mode: "overview" }, opened] },
    // The move after means nothing: the hand rests.
    { event: { type: "move", x: 120, y: 200 }, mode: "overview", hand: pointer.resting, intents: [] },
    { event: { type: "z" }, mode: "overview", hand: pointer.resting, intents: [{ kind: "mode", mode: "near" }] },
  ], { viewport: near });
  // A pan under way just stops.
  play([
    { event: { type: "down", x: 0, y: 0, dogAt: "none" }, hand: { kind: "panning", lastX: 0, lastY: 0 }, intents: [] },
    { event: { type: "z" }, hand: pointer.resting, intents: [{ kind: "mode", mode: "overview" }, opened] },
  ], { viewport: near });
  // A scrollbar held just stops.
  assert.deepEqual(pointer.meaning({ kind: "scrolling", axis: "x", lastX: 0, lastY: 0 }, { type: "z" }, null, "overview", near),
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
  assert.deepEqual(pointer.edgeScroll({ kind: "pan", x: 800, y: 300 }, west), [{ kind: "pan", parkX: 32000 + 5 - f, parkY: 1000 }]);
  // A dog held at the bottom edge: it and the viewport go south together.
  assert.deepEqual(pointer.edgeScroll(held(1400, 1580), near), [
    { kind: "drag", dogId: 9, parkX: 1400, parkY: 1580 + f },
    { kind: "pan", parkX: 1000, parkY: 1000 + f },
  ]);
  // A dog at the world's top edge goes on north across the seam, and the viewport with it.
  const top = { parkX: 1000, parkY: 32000 - 20, width: 800, height: 600 };
  assert.deepEqual(pointer.edgeScroll(held(1400, 0), top), [
    { kind: "drag", dogId: 9, parkX: 1400, parkY: 32000 - f },
    { kind: "pan", parkX: 1000, parkY: 32000 - 20 - f },
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
  // Pressed after "z", before a frame drew the new mode: on nothing.
  assert.equal(pointer.pressedOn({ mode: "near", objects: nearList }, "overview", 100, 100), null);
  assert.equal(pointer.pressedOn({ mode: "overview", objects: overList }, "near", view.x, view.y), null);
});

// ── across the seam (the torus, docs/PHYSICS.md decision 14) ───────────────

const W = scene.world_px;

test("across the seam, the near scene: a viewport straddling x = 0, y = 0 and the corner draws the tiles there, the critters at their copies on screen", () => {
  // 800 x 600 at (-300, -200) named in the world: its top-left at (31700, 31800).
  const viewport = { parkX: W - 300, parkY: W - 200, width: 800, height: 600 };
  const dogs = [{ id: 1, emoji: "🐕", parkX: W - 10, parkY: 100 }, { id: 2, emoji: "🐕", parkX: 10, parkY: 100 }];
  const cows = [{ id: 5, parkX: 200, parkY: W - 50 }];
  const near = scene.nearScene(viewport, dogs, cows, { kind: "kept", dogId: 2 });
  const byId = new Map(near.map((o) => [o.id, o]));
  // The tiles: (63, 63) and (0, 63) above the seam, (63, 0) and (0, 0) below it, where they lie.
  assert.deepEqual(ids(near).filter((i) => /^tile:[^:]*$/.test(i)), ["tile:63,63", "tile:0,63", "tile:63,0", "tile:0,0"]);
  assert.deepEqual([byId.get("tile:63,63").x, byId.get("tile:63,63").y], [-200, -300]);
  assert.deepEqual([byId.get("tile:0,0").x, byId.get("tile:0,0").y], [300, 200]);
  assert.equal(byId.get("tile:63,0:label").text, "(63, 0)");
  // The checkerboard runs on across the seam: (63, 63) and (0, 0) alike, (0, 63) the other shade.
  assert.equal(byId.get("tile:63,63").fill, byId.get("tile:0,0").fill);
  assert.notEqual(byId.get("tile:0,63").fill, byId.get("tile:0,0").fill);
  // Two dogs 20 px apart across the seam are drawn 20 px apart; the ring on the one past it.
  assert.deepEqual([byId.get("dog:1").x, byId.get("dog:1").y], [290, 300]);
  assert.deepEqual([byId.get("dog:2").x, byId.get("dog:2").y], [310, 300]);
  assert.deepEqual([byId.get("dog:2:ring").x, byId.get("dog:2:ring").y], [310, 300]);
  assert.deepEqual([byId.get("cow:5").x, byId.get("cow:5").y], [500, 150]);
  // A dog's label is its number.
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

test("across the seam, the subscription: the display's tiles wrap; the region's come in either naming; a whole world's translation changes nothing", () => {
  // 1000 x 700 centred on the corner: the 250 px margin meets cols -2..1, rows -2..1, wrapped.
  const v = { parkX: W - 500, parkY: W - 350, width: 1000, height: 700 };
  const display = scene.subscription([], v);
  assert.equal(display.length, 16);
  assert.ok(display.every((t) => t.col >= 0 && t.col < 64 && t.row >= 0 && t.row < 64));
  assert.deepEqual(new Set(display.map(scene.tileKey)),
    new Set([62, 63, 0, 1].flatMap((r) => [62, 63, 0, 1].map((c) => `${c},${r}`))));
  // Nearest first; ties by row, then column, as they lie round the centre: north and west first.
  assert.deepEqual(display.slice(0, 4), [{ col: 63, row: 63 }, { col: 0, row: 63 }, { col: 63, row: 0 }, { col: 0, row: 0 }]);
  // The same order in a copy of the world away from the seam.
  const plain = scene.subscription([], { ...v, parkX: 20 * 500 - 500, parkY: 30 * 500 - 350 });
  assert.deepEqual(display.map((t) => [(t.col + 20) % 64, (t.row + 30) % 64]), plain.map((t) => [t.col, t.row]));
  // A region across the seam, in either naming: the same tiles, wrapped, once each.
  const raw = [{ col: 63, row: 0 }, { col: 64, row: 0 }, { col: -1, row: 1 }, { col: 0, row: 1 }];
  const both = scene.subscription(raw, v);
  assert.deepEqual(both.slice(0, 4), [{ col: 63, row: 0 }, { col: 0, row: 0 }, { col: 63, row: 1 }, { col: 0, row: 1 }]);
  assert.equal(both.length, 16); // all four in the display too
  for (const [kx, ky] of [[1, 0], [0, 1], [-1, -1], [3, -2]]) {
    assert.deepEqual(scene.subscription(raw, { ...v, parkX: v.parkX + kx * W, parkY: v.parkY + ky * W }), both);
  }
});

test("across the seam, the overview: dots and the view at their copies in the window, the thumb in two pieces", () => {
  // 1040 x 700, the window's top-left at (W - 1000, W - 500): it straddles the corner.
  const viewport = { parkX: W - 100, parkY: 100, width: 1040, height: 700 };
  const over = scene.overviewScene(viewport, [{ id: 1, parkX: 50, parkY: 50 }, { id: 2, parkX: W - 50, parkY: W - 50 }], [], new Map(), { kind: "none" },
    { parkX: W - 1000, parkY: W - 500 });
  const byId = new Map(over.map((o) => [o.id, o]));
  const s = 0.132;
  const at = (x, y) => [x, y].map((p) => Math.round(p * 1e6) / 1e6);
  assert.deepEqual(at(byId.get("dog:1").x, byId.get("dog:1").y), at(20 + 1050 * s, 20 + 550 * s));
  assert.deepEqual(at(byId.get("dog:2").x, byId.get("dog:2").y), at(20 + 950 * s, 20 + 450 * s));
  assert.deepEqual(at(byId.get("view").x, byId.get("view").y), at(20 + 900 * s, 20 + 600 * s));
  assert.ok(byId.has("tile:63,63") && byId.has("tile:0,0"));
  assert.deepEqual(at(byId.get("tile:0,0").x, byId.get("tile:0,0").y), at(20 + 1000 * s, 20 + 500 * s));
  // Two thumb pieces on the x track, both pressable.
  const thumbs = over.filter((o) => o.id === scene.thumbTarget("x"));
  assert.equal(thumbs.length, 2);
  assert.equal(blit.hit(over, thumbs[1].x + 1, thumbs[1].y + 1), scene.thumbTarget("x"));
  assert.equal(blit.hit(over, thumbs[0].x + 1, thumbs[0].y + 1), scene.thumbTarget("x"));
});
