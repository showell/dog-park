// The browser's half, checked without a browser (metal-vmm QUEUE 163.4):
// park.js loaded into a sandbox, and its pure parts asked what park.zig and
// wire.zig say they must answer. Node, no packages; run by ops/smoke.
//
//   node ops/park_js_check.js     (exits non-zero on the first failure)
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const source = fs.readFileSync(path.join(__dirname, "..", "src", "park.js"), "utf8");
const sandbox = { console, performance: { now: () => 0 } };
vm.createContext(sandbox);
// The script's top-level names are its own; hand back the ones checked here.
const park = vm.runInContext(source + "\n;({ frames, state, wrapped, take, askAfter, askingIsDue, sprites, pressStarts, panBy, drag });", sandbox);
const { frames, state, wrapped, take, askAfter, askingIsDue, sprites, pressStarts, panBy, drag } = park;

// Objects made in the sandbox have its prototypes, so they are compared by
// their JSON, field by field in order.
function same(actual, expected) {
  assert.strictEqual(JSON.stringify(actual), JSON.stringify(expected));
}

let checks = 0;
function check(name, fn) {
  fn();
  checks += 1;
  void name;
}

// ── frames, as park.zig has them ────────────────────────────────────────────

check("nearestCopy: the copy within half a park, a tie going east or south", () => {
  assert.strictEqual(frames.nearestCopy(1000, 10, 400), 10);
  assert.strictEqual(frames.nearestCopy(1000, 10, 990), 1010);
  assert.strictEqual(frames.nearestCopy(1000, 10, -3000), -2990);
  // A tie, half a park away, goes east (park.zig's test, the same numbers).
  assert.strictEqual(frames.nearestCopy(1000, 10, 510), 1010);
  assert.strictEqual(frames.nearestCopy(1000, 10, 509), 10);
});

check("homeShift: a whole number of park sizes back into [0, side), floored", () => {
  assert.strictEqual(frames.homeShift(1000, 0), 0);
  assert.strictEqual(frames.homeShift(1000, 999), 0);
  assert.strictEqual(frames.homeShift(1000, 1000), -1000);
  assert.strictEqual(frames.homeShift(1000, -1), 1000);
  assert.strictEqual(frames.homeShift(1000, -1000), 1000);
  assert.strictEqual(frames.homeShift(1000, -1001), 2000);
  for (const x of [-12345, -1, 0, 1, 4999, 5000, 77777]) {
    const home = x + frames.homeShift(5000, x);
    assert.ok(home >= 0 && home < 5000, `${x} -> ${home}`);
  }
});

check("viewport and plane, both ways", () => {
  const v = { planeX: -1000, planeY: 500, width: 800, height: 600 };
  const seen = frames.viewportFromPlane(v, -960, 560);
  same(seen, { viewportX: 40, viewportY: 60 });
  same(frames.planeFromViewport(v, 40, 60), { planeX: -960, planeY: 560 });
});

// ── take: the answer is the truth ───────────────────────────────────────────

// A scene as wire.zig writes it. `own` is the own dog's fields (is, move)
// beside its place; `null` for no dog free.
function scene(ownX, ownY, own, extra) {
  return {
    covers_plane_x: 0, covers_plane_y: 0, covers_width: 1200, covers_height: 1000,
    park_width: 5000, park_height: 5000,
    own: own === null
      ? { no_dog_free: {} }
      : { has_dog: { plane_x: ownX, plane_y: ownY, emoji: "x", is: "same_dog", move: "stayed", ...own } },
    others: [{ plane_x: 1100, plane_y: 1100, emoji: "o" }],
    others_complete: "all",
    ...extra,
  };
}

function reset() {
  state.viewport = { planeX: 1000, planeY: 1000, width: 800, height: 600 };
  state.scene = scene(1400, 1300, {}, {});
  drag.active = false;
  state.ownPlaneX = 1400;
  state.ownPlaneY = 1300;
  state.unsentOwnDogDx = 0;
  state.unsentOwnDogDy = 0;
  wrapped.planeDx = 0;
  wrapped.planeDy = 0;
}

check("take: a kept move puts the dog where the server has it, plus the drag since", () => {
  reset();
  state.unsentOwnDogDx = 7;
  state.unsentOwnDogDy = -3;
  take({ scene: scene(1430, 1290, { move: "moved" }, {}) }, { planeDx: 0, planeDy: 0 });
  same([state.ownPlaneX, state.ownPlaneY], [1437, 1287]);
  same([state.unsentOwnDogDx, state.unsentOwnDogDy], [7, -3]);
});

check("take: a refusal puts the dog back where the server has it, and drops the drag since", () => {
  reset();
  state.unsentOwnDogDx = 7;
  take({ scene: scene(1400, 1300, { move: "refused_too_far_at_once" }, {}) }, { planeDx: 0, planeDy: 0 });
  same([state.ownPlaneX, state.ownPlaneY], [1400, 1300]);
  assert.strictEqual(state.unsentOwnDogDx, 0);
});

check("take: an answer to a request sent before the origin wrapped is shifted by the wrap", () => {
  reset();
  // The origin wrapped a park west after the request went.
  wrapped.planeDx = -5000;
  take({ scene: scene(6400, 1300, { move: "moved" }, { covers_plane_x: 5000 }) }, { planeDx: 0, planeDy: 0 });
  assert.strictEqual(state.ownPlaneX, 1400);
  assert.strictEqual(state.scene.covers_plane_x, 0);
});

check("take: a dog newly ours centres the viewport on it and drops the drag meant for the other", () => {
  reset();
  state.unsentOwnDogDx = 50;
  take({ scene: scene(3000, 3000, { is: "new_dog" }, {}) }, { planeDx: 0, planeDy: 0 });
  same([state.ownPlaneX, state.ownPlaneY], [3000, 3000]);
  same([state.viewport.planeX, state.viewport.planeY], [2600, 2700]);
  assert.strictEqual(state.unsentOwnDogDx, 0);
});

check("no dog free: read-only, nothing of ours drawn, a press pans, and the drag since is dropped", () => {
  reset();
  state.unsentOwnDogDx = 9;
  take({ scene: scene(0, 0, null, {}) }, { planeDx: 0, planeDy: 0 });
  assert.strictEqual(state.unsentOwnDogDx, 0);
  const kinds = sprites().map((s) => s.kind);
  assert.ok(!kinds.includes("own"), "no ringed dog");
  assert.ok(kinds.includes("other"), "the others still drawn");
  assert.strictEqual(pressStarts(400, 300), "pan");
  // Dragging the background 30 right and 10 down: the park follows the
  // pointer, the viewport goes the other way.
  panBy(30, 10);
  same([state.viewport.planeX, state.viewport.planeY], [970, 990]);
  // Panned past the park's corner, the origin wraps home, as ever.
  panBy(1000, 1000);
  same([state.viewport.planeX, state.viewport.planeY], [4970, 4990]);
  same([wrapped.planeDx, wrapped.planeDy], [5000, 5000]);
});

check("a later answer with a dog: centred on it, ringed, and draggable on it", () => {
  reset();
  take({ scene: scene(0, 0, null, {}) }, { planeDx: 0, planeDy: 0 });
  take({ scene: scene(2000, 2500, { is: "new_dog" }, {}) }, { planeDx: 0, planeDy: 0 });
  same([state.viewport.planeX, state.viewport.planeY], [1600, 2200]);
  assert.ok(sprites().some((s) => s.kind === "own"));
  assert.strictEqual(pressStarts(400, 300), "dog");
  assert.strictEqual(pressStarts(10, 10), "nothing");
});

// ── the ask loop ────────────────────────────────────────────────────────────

check("the ask loop: idle wants, sends, is answered, goes idle", () => {
  let a = { kind: "idle", wants: "a_scene", lastAskedMs: 0 };
  assert.ok(askingIsDue(a, false, 10));
  a = askAfter(a, "sent", 10);
  assert.strictEqual(a.kind, "asking");
  assert.ok(!askingIsDue(a, true, 20), "never two out at once");
  a = askAfter(a, "answered", 30);
  same(a, { kind: "idle", wants: "nothing", lastAskedMs: 10 });
  assert.ok(!askingIsDue(a, false, 500));
  assert.ok(askingIsDue(a, true, 500), "a drag goes");
  assert.ok(askingIsDue(a, false, 1011), "an idle second asks");
});

check("the ask loop: a scene wanted while asking is asked for after the answer", () => {
  let a = askAfter({ kind: "idle", wants: "nothing", lastAskedMs: 0 }, "sent", 0);
  a = askAfter(a, "want_a_scene", 5);
  a = askAfter(a, "answered", 10);
  assert.strictEqual(a.wants, "a_scene");
});

check("the ask loop: failures back off, doubling to half a minute, and an answer ends it", () => {
  let a = askAfter({ kind: "idle", wants: "a_scene", lastAskedMs: 0 }, "sent", 0);
  a = askAfter(a, "failed", 100);
  same(a, { kind: "backing_off", untilMs: 600, failures: 1 });
  assert.ok(!askingIsDue(askAfter(a, "tick", 599), true, 599), "nothing asked while backing off");
  let now = 600;
  const waits = [];
  for (let i = 0; i < 9; i += 1) {
    a = askAfter(a, "tick", now);
    assert.strictEqual(a.kind, "retrying");
    assert.ok(askingIsDue(a, false, now));
    a = askAfter(a, "sent", now);
    a = askAfter(a, "failed", now);
    waits.push(a.untilMs - now);
    now = a.untilMs;
  }
  same(waits, [1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000, 30000]);
  a = askAfter(askAfter(askAfter(a, "tick", now), "sent", now), "answered", now + 5);
  assert.strictEqual(a.kind, "idle");
});

console.log(`park.js: ${checks} checks pass`);
