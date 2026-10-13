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

// ── what a frame draws, and what a press is on ──────────────────────────────

const ids = (objects) => objects.map((o) => o.id);

test("the near scene: tiles, then cows, then dogs, the leashed dog ringed", () => {
  // 600 x 400 at (450, 0): tiles (0,0) to (2,0), the tile columns from x -450.
  const viewport = { parkX: 450, parkY: 0, width: 600, height: 400 };
  const dogs = [{ id: 7, emoji: "🐕", parkX: 500, parkY: 100 }, { id: 3, emoji: "🐩", parkX: 4000.4, parkY: 4000 }];
  const cows = [{ id: 23, parkX: 600.5, parkY: 250 }];
  const near = scene.nearScene(viewport, dogs, cows, { kind: "kept", dogId: 7 });
  assert.deepEqual(ids(near), [
    "tile:0,0", "tile:0,0:label", "tile:1,0", "tile:1,0:label", "tile:2,0", "tile:2,0:label",
    "cow:23", "cow:23:label", "dog:7:ring", "dog:7", "dog:7:label", "dog:3", "dog:3:label",
  ]);
  const byId = new Map(near.map((o) => [o.id, o]));
  assert.deepEqual(byId.get("tile:1,0"), { id: "tile:1,0", shape: "rect", x: 50, y: 0, w: 500, h: 500, fill: "#eaf3fc", role: "scenery" });
  assert.deepEqual(byId.get("tile:0,0:label"), { id: "tile:0,0:label", shape: "text", x: -200, y: 250, w: 0, h: 0, text: "(0, 0)", font: "20px monospace", fill: "#9ab", role: "scenery" });
  assert.equal(byId.get("tile:0,0").fill, "#ffffff");
  // A cow: a 60 px glyph, never a target, its place to the pixel under it.
  assert.deepEqual(byId.get("cow:23"), { id: "cow:23", shape: "glyph", x: 150.5, y: 250, w: 60, h: 60, text: "🐄", fill: "#000", role: "scenery" });
  assert.deepEqual(byId.get("cow:23:label"), { id: "cow:23:label", shape: "text", x: 150.5, y: 301, w: 0, h: 0, text: "(601, 250)", font: "11px monospace", fill: "#555", role: "scenery" });
  // The leashed dog: a red ring under its 40 px glyph, which is a target.
  assert.deepEqual(byId.get("dog:7:ring"), { id: "dog:7:ring", shape: "ring", x: 50, y: 100, w: 2 * (40 * 0.7), h: 2 * (40 * 0.7), stroke: "#d33", lineWidth: 3, role: "scenery" });
  assert.deepEqual(byId.get("dog:7"), { id: "dog:7", shape: "glyph", x: 50, y: 100, w: 40, h: 40, text: "🐕", fill: "#000", role: "target" });
  // A far dog is still drawn (off the screen), unringed.
  assert.deepEqual(byId.get("dog:3"), { id: "dog:3", shape: "glyph", x: 3550.4, y: 4000, w: 40, h: 40, text: "🐩", fill: "#000", role: "target" });
  assert.equal(byId.get("dog:3:label").text, "(4000, 4000)");
  // No leash, no ring.
  assert.ok(!ids(scene.nearScene(viewport, dogs, cows, { kind: "none" })).includes("dog:7:ring"));
});

test("the overview scene: shades by subscription, dots by freshness, the last leashed ringed, the view on top", () => {
  // 1040 x 700: scale 660 / 5000, origin (190, 20); a tile is 66 px.
  const viewport = { parkX: 500, parkY: 1000, width: 1040, height: 700 };
  const subscribed = new Map([["1,2", true], ["0,0", true]]);
  const dogs = [{ id: 7, parkX: 600, parkY: 1100 }, { id: 3, parkX: 4000, parkY: 4000 }];
  const cows = [{ id: 23, parkX: 50, parkY: 50 }, { id: 24, parkX: 2600, parkY: 50 }];
  const over = scene.overviewScene(viewport, dogs, cows, subscribed, { kind: "dog", dogId: 3 });
  assert.equal(over.length, 1 + 100 + 2 + 2 + 1 + 1);
  assert.deepEqual(over[0], { id: "ground", shape: "rect", x: 0, y: 0, w: 1040, h: 700, fill: "#556", role: "scenery" });
  const byId = new Map(over.map((o) => [o.id, o]));
  // Subscribed: white and blue; not: two pinks.
  assert.equal(byId.get("tile:0,0").fill, "#ffffff");
  assert.equal(byId.get("tile:1,2").fill, "#eaf3fc");
  assert.equal(byId.get("tile:2,2").fill, "#f8d8d8");
  assert.equal(byId.get("tile:2,1").fill, "#f2c4c4");
  assert.equal(byId.get("tile:1,2").x, 190 + 66);
  assert.equal(byId.get("tile:1,2").w, 500 * 660 / 5000);
  // A cow in a subscribed tile is dark brown, one elsewhere pale; 8 px across.
  assert.deepEqual(byId.get("cow:23"), { id: "cow:23", shape: "dot", x: 190 + 50 * 0.132, y: 20 + 50 * 0.132, w: 8, h: 8, fill: "#7a4a1a", role: "scenery" });
  assert.equal(byId.get("cow:24").fill, "#c9a37a");
  // A dog: dark when live, pale when remembered; 5 px across; the last leashed ringed, after its dot.
  assert.equal(byId.get("dog:7").fill, "#333");
  assert.equal(byId.get("dog:3").fill, "#a88");
  assert.equal(byId.get("dog:3").w, 5);
  assert.equal(byId.get("dog:3").role, "scenery");
  assert.deepEqual(ids(over).slice(-4), ["dog:7", "dog:3", "dog:3:ring", "view"]);
  assert.deepEqual(byId.get("dog:3:ring"), { id: "dog:3:ring", shape: "ring", x: byId.get("dog:3").x, y: byId.get("dog:3").y, w: 22, h: 22, stroke: "#d33", lineWidth: 3, role: "scenery" });
  assert.deepEqual(over.at(-1), { id: "view", shape: "frame", x: 190 + 500 * 0.132, y: 20 + 1000 * 0.132, w: 1040 * 0.132, h: 700 * 0.132, stroke: "#222", lineWidth: 2, role: "target" });
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

test("a press in the overview is on the view's rectangle or nothing", () => {
  const viewport = { parkX: 500, parkY: 1000, width: 1040, height: 700 };
  const over = scene.overviewScene(viewport, [{ id: 7, parkX: 600, parkY: 1100 }], [], new Map(), { kind: "dog", dogId: 7 });
  const view = over.at(-1);
  assert.equal(blit.hit(over, view.x, view.y), scene.view_target);
  assert.equal(blit.hit(over, view.x + view.w, view.y + view.h), scene.view_target);
  assert.equal(blit.hit(over, view.x - 1, view.y), null);
  assert.equal(blit.hit(over, 5, 5), null);
});

// ── what a pointer event means ──────────────────────────────────────────────

// A gesture as a table: each row an event (and what the press hit), and the
// hand and intents it must give, from the hand the row before left.
function play(rows, { mode = "near", viewport } = {}) {
  let hand = pointer.resting;
  for (const [i, r] of rows.entries()) {
    const out = pointer.meaning(hand, r.event, r.hit ?? null, r.mode ?? mode, viewport);
    assert.deepEqual(out, { hand: r.hand, intents: r.intents }, `row ${i}: ${JSON.stringify(r.event)}`);
    hand = out.hand;
  }
}

const near = { parkX: 1000, parkY: 1000, width: 800, height: 600 };

test("a gesture on a dog: grab where pressed, drags that keep it on screen, let go", () => {
  // Dog 219 at park (1100, 1200), so at viewport (100, 200); pressed 5 px right and 3 px up of its centre.
  const held = { kind: "dragging", dogId: 219, offsetX: 5, offsetY: -3 };
  play([
    { event: { type: "down", x: 105, y: 197, dogAt: { parkX: 1100, parkY: 1200 } }, hit: "dog:219",
      hand: held, intents: [{ kind: "grab", dogId: 219 }] },
    { event: { type: "move", x: 115, y: 190 },
      hand: held, intents: [{ kind: "drag", dogId: 219, parkX: 1110, parkY: 1193 }] },
    // Past the screen's left edge: held a half dog in from it.
    { event: { type: "move", x: -50, y: 190 },
      hand: held, intents: [{ kind: "drag", dogId: 219, parkX: 1020, parkY: 1193 }] },
    { event: { type: "up" }, hand: pointer.resting, intents: [{ kind: "letgo" }] },
    // A move with nothing in hand means nothing; so does a second up.
    { event: { type: "move", x: 300, y: 300 }, hand: pointer.resting, intents: [] },
    { event: { type: "up" }, hand: pointer.resting, intents: [] },
  ], { viewport: near });
});

test("a drag stops at the world's edge", () => {
  // The viewport hangs past the world's top-left corner.
  const corner = { parkX: -300, parkY: -200, width: 800, height: 600 };
  play([
    { event: { type: "down", x: 400, y: 300, dogAt: { parkX: 100, parkY: 100 } }, hit: "dog:5",
      hand: { kind: "dragging", dogId: 5, offsetX: 0, offsetY: 0 }, intents: [{ kind: "grab", dogId: 5 }] },
    { event: { type: "move", x: 30, y: 30 },
      hand: { kind: "dragging", dogId: 5, offsetX: 0, offsetY: 0 }, intents: [{ kind: "drag", dogId: 5, parkX: 0, parkY: 0 }] },
    { event: { type: "cancel" }, hand: pointer.resting, intents: [{ kind: "letgo" }] },
  ], { viewport: corner });
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

test("a pan stops with the viewport's centre on the world's edge", () => {
  play([
    { event: { type: "down", x: 0, y: 0, dogAt: "none" }, hand: { kind: "panning", lastX: 0, lastY: 0 }, intents: [] },
    { event: { type: "move", x: 5000, y: 0 }, hand: { kind: "panning", lastX: 5000, lastY: 0 }, intents: [{ kind: "pan", parkX: -400, parkY: 1000 }] },
  ], { viewport: near });
});

test("in the overview, a press on the view's rectangle drags it, scaled; one off it means nothing", () => {
  // 1040 x 700: scale 660 / 5000 = 0.132.
  const viewport = { parkX: 500, parkY: 1000, width: 1040, height: 700 };
  play([
    { event: { type: "down", x: 300, y: 200, dogAt: "none" }, hit: scene.view_target,
      hand: { kind: "panning", lastX: 300, lastY: 200 }, intents: [] },
    { event: { type: "move", x: 300 + 13.2, y: 200 - 6.6 },
      hand: { kind: "panning", lastX: 313.2, lastY: 193.4 }, intents: [{ kind: "pan", parkX: 500 + 13.2 / 0.132, parkY: 1000 - 6.6 / 0.132 }] },
    { event: { type: "up" }, hand: pointer.resting, intents: [] },
    // Off the rectangle: on nothing, so resting, and a move means nothing.
    { event: { type: "down", x: 5, y: 5, dogAt: "none" }, hit: null, hand: pointer.resting, intents: [] },
    { event: { type: "move", x: 50, y: 50 }, hand: pointer.resting, intents: [] },
  ], { mode: "overview", viewport });
});

test('"z" mid-drag lets go and flips the mode; resting, it only flips', () => {
  const held = { kind: "dragging", dogId: 7, offsetX: 0, offsetY: 0 };
  play([
    { event: { type: "down", x: 100, y: 200, dogAt: { parkX: 1100, parkY: 1200 } }, hit: "dog:7",
      hand: held, intents: [{ kind: "grab", dogId: 7 }] },
    { event: { type: "z" }, hand: pointer.resting, intents: [{ kind: "letgo" }, { kind: "mode", mode: "overview" }] },
    // The move after means nothing: the hand rests.
    { event: { type: "move", x: 120, y: 200 }, mode: "overview", hand: pointer.resting, intents: [] },
    { event: { type: "z" }, mode: "overview", hand: pointer.resting, intents: [{ kind: "mode", mode: "near" }] },
  ], { viewport: near });
  // A pan under way just stops.
  play([
    { event: { type: "down", x: 0, y: 0, dogAt: "none" }, hand: { kind: "panning", lastX: 0, lastY: 0 }, intents: [] },
    { event: { type: "z" }, hand: pointer.resting, intents: [{ kind: "mode", mode: "overview" }] },
  ], { viewport: near });
});

test("no event outside the five", () => {
  assert.throws(() => pointer.meaning(pointer.resting, { type: "wheel" }, null, "near", near), /no pointer event wheel/);
});

test("the edge bands each frame: a pan keeps going, a held dog carries the viewport", () => {
  const f = pointer.fastest_px_per_frame;
  // Resting, or a pan or a dog away from every edge: nothing.
  assert.deepEqual(pointer.edgeScroll(pointer.resting, near, "none"), []);
  assert.deepEqual(pointer.edgeScroll({ kind: "panning", lastX: 400, lastY: 300 }, near, "none"), []);
  const held = { kind: "dragging", dogId: 9, offsetX: 0, offsetY: 0 };
  assert.deepEqual(pointer.edgeScroll(held, near, { parkX: 1400, parkY: 1300 }), []);
  // A pan held on the right edge: the park goes toward it, so the viewport away.
  assert.deepEqual(pointer.edgeScroll({ kind: "panning", lastX: 800, lastY: 300 }, near, "none"),
    [{ kind: "pan", parkX: 1000 - f, parkY: 1000 }]);
  // ... and with the viewport's centre on the world's edge, it stops.
  const east = { parkX: 4999 - 400, parkY: 1000, width: 800, height: 600 };
  assert.deepEqual(pointer.edgeScroll({ kind: "panning", lastX: 0, lastY: 300 }, east, "none"), []);
  // A dog held at the bottom edge: it and the viewport go south together.
  assert.deepEqual(pointer.edgeScroll(held, near, { parkX: 1400, parkY: 1580 }), [
    { kind: "drag", dogId: 9, parkX: 1400, parkY: 1580 + f },
    { kind: "pan", parkX: 1000, parkY: 1000 + f },
  ]);
  // A dog at the world's edge goes no further, and the viewport with it.
  const top = { parkX: 1000, parkY: -20, width: 800, height: 600 };
  assert.deepEqual(pointer.edgeScroll(held, top, { parkX: 1400, parkY: 0 }), []);
});

test("the dog in hand is a number", () => {
  assert.equal(pointer.inHand(pointer.resting), "none");
  assert.equal(pointer.inHand({ kind: "panning", lastX: 0, lastY: 0 }), "none");
  assert.equal(pointer.inHand({ kind: "dragging", dogId: 219, offsetX: 0, offsetY: 0 }), 219);
});

test("a press is on what was drawn in the mode it is made in", () => {
  const viewport = { parkX: 0, parkY: 0, width: 800, height: 600 };
  const nearList = scene.nearScene(viewport, [{ id: 1, emoji: "🐕", parkX: 100, parkY: 100 }], [], { kind: "none" });
  const overList = scene.overviewScene(viewport, [], [], new Map(), { kind: "none" });
  const view = overList.at(-1);
  assert.equal(pointer.pressedOn({ mode: "near", objects: nearList }, "near", 100, 100), "dog:1");
  assert.equal(pointer.pressedOn({ mode: "overview", objects: overList }, "overview", view.x, view.y), scene.view_target);
  // Pressed after "z", before a frame drew the new mode: on nothing.
  assert.equal(pointer.pressedOn({ mode: "near", objects: nearList }, "overview", 100, 100), null);
  assert.equal(pointer.pressedOn({ mode: "overview", objects: overList }, "near", view.x, view.y), null);
});
