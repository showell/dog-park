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
  assert.equal(typeof blit.blit, "function");
  assert.equal(typeof blit.blitOverview, "function");
  assert.equal(typeof engine.syncTiles, "function");
  // park.js wires the DOM and exports nothing; its import starting nothing
  // is this file finishing at all (a start would throw on `document`).
  assert.deepEqual(Object.keys(park), []);
});

test("nothing is known at import", () => {
  assert.equal(engine.known.size, 0);
  assert.equal(engine.knownCows.size, 0);
  assert.equal(engine.subscribed.size, 0);
  assert.deepEqual(engine.leashed, { kind: "none" });
  assert.deepEqual(engine.lastLeashed, { kind: "none" });
});

test("the two frames are each other's inverse", () => {
  const viewport = { parkX: 1200, parkY: 800, width: 1000, height: 700 };
  assert.deepEqual(scene.viewportFromPark(viewport, 1250, 830), { viewportX: 50, viewportY: 30 });
  assert.deepEqual(scene.parkFromViewport(viewport, 50, 30), { parkX: 1250, parkY: 830 });
});

test("a held dog is kept on screen and in the world", () => {
  const viewport = { parkX: 1000, parkY: 1000, width: 400, height: 300 };
  assert.deepEqual(scene.keptOnScreen(viewport, 900, 1500), { parkX: 1020, parkY: 1280 });
  assert.deepEqual(scene.keptInWorld(-5, 99999), { parkX: 0, parkY: scene.world_px - 1 });
  // A pan stops with the viewport's centre on the world's edge.
  assert.deepEqual(scene.viewportKeptOnWorld(viewport, -1000, 0), { parkX: -200, parkY: 0 });
});

test("tiles: a point's tile, its key, and those meeting a rectangle", () => {
  assert.deepEqual(scene.tileOf(499, 500), { col: 0, row: 1 });
  assert.equal(scene.tileKey({ col: 3, row: 7 }), "3,7");
  assert.deepEqual(scene.tilesMeeting(499, 0, 2, 1), [{ col: 0, row: 0 }, { col: 1, row: 0 }]);
  // Tiles past the world's edge are left out.
  assert.deepEqual(scene.tilesMeeting(-10, -10, 20, 20), [{ col: 0, row: 0 }]);
});

test("the tiles wanted: the widest margin within the cap", () => {
  // 1000 x 700 at (2000, 2000): the 250 px margin meets cols 3..6, rows 3..5.
  const small = scene.wantedTiles({ parkX: 2000, parkY: 2000, width: 1000, height: 700 });
  assert.equal(small.length, 12);
  assert.deepEqual([small[0], small.at(-1)], [{ col: 3, row: 3 }, { col: 6, row: 5 }]);
  // 1600 square at (1200, 1200): 250 px meets 6 x 6, past the cap; 125 px meets cols and rows 2..5.
  const mid = scene.wantedTiles({ parkX: 1200, parkY: 1200, width: 1600, height: 1600 });
  assert.equal(mid.length, 16);
  assert.deepEqual([mid[0], mid.at(-1)], [{ col: 2, row: 2 }, { col: 5, row: 5 }]);
  // 1800 square at (1100, 1100): 250 and 125 px both meet 6 x 6; no margin meets 2..5.
  const wide = scene.wantedTiles({ parkX: 1100, parkY: 1100, width: 1800, height: 1800 });
  assert.equal(wide.length, 16);
  assert.deepEqual([wide[0], wide.at(-1)], [{ col: 2, row: 2 }, { col: 5, row: 5 }]);
});

test("the overview frame fits the world with its margin, centred", () => {
  const o = scene.overviewFrame(1040, 700);
  assert.equal(o.scale, 660 / scene.world_px);
  assert.deepEqual(scene.overviewFromPark(o, 0, 0), { viewportX: 190, viewportY: 20 });
  assert.deepEqual(scene.overviewFromPark(o, scene.world_px, scene.world_px), { viewportX: 850, viewportY: 680 });
});

test("a press grabs the topmost dog under it, or misses", () => {
  const viewport = { parkX: 0, parkY: 0, width: 800, height: 600 };
  const dogs = [{ id: 1, parkX: 100, parkY: 100 }, { id: 2, parkX: 110, parkY: 100 }];
  const g = pointer.grabbed(viewport, dogs, 105, 95);
  assert.equal(g.kind, "holding");
  assert.equal(g.dog.id, 2); // drawn last, so on top
  assert.equal(g.grabDx, -5);
  assert.equal(g.grabDy, -5);
  assert.deepEqual(pointer.grabbed(viewport, dogs, 300, 300), { kind: "missed" });
});

test("the edge bands: nothing in the middle, faster deeper in", () => {
  assert.equal(pointer.bandSpeed(0), 0);
  assert.equal(pointer.bandSpeed(pointer.band_px), pointer.fastest_px_per_frame);
  assert.equal(pointer.bandSpeed(10 * pointer.band_px), pointer.fastest_px_per_frame);
  assert.equal(pointer.axisScroll(400, 800, 0), 0);
  assert.equal(pointer.axisScroll(800, 800, 0), pointer.fastest_px_per_frame);
  assert.equal(pointer.axisScroll(0, 800, 0), -pointer.fastest_px_per_frame);
  // A dog's reach: its centre comes no nearer the edge than its half-size.
  assert.equal(pointer.axisScroll(780, 800, scene.dog_px / 2), pointer.fastest_px_per_frame);
  const shallow = pointer.axisScroll(800 - 20 - pointer.band_px + 8, 800, 20);
  assert.ok(shallow > 0 && shallow < pointer.fastest_px_per_frame);
});

test("a dog's place is told as whole pixels", () => {
  assert.deepEqual(engine.wholePoint({ parkX: 10.5, parkY: -3.4 }), { parkX: 11, parkY: -3 });
});
