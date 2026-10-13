// The engine (solo/engine.js) driven in node: a fake server answering its
// posts when told to, a fake clock and fake timers. What it sends, in what
// order and with what bodies, and what it then knows.
//
//   node tools/test_engine.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { createEngine } from "../solo/engine.js";

// A cows' rule that moves no cow: the wasm's shape, with nothing in it.
function stillRule() {
  const memory = new WebAssembly.Memory({ initial: 1 });
  return {
    memory, cowCapacity: () => 64, cowPositions: () => 0, pathPoints: () => 1024, pathCapacity: () => 100,
    replays: 0, replay() { this.replays++; },
  };
}

// The fake page: every post recorded and held until `answer()` lets the
// oldest one land; the clock and timers moved by hand; the console kept.
function fakePage({ me = { viewport: { at: { park_x: 2000, park_y: 2000 } }, leash: {} }, dogs = [], cows = [] } = {}) {
  const sent = [];
  const held = [];
  const said = [];
  const timers = new Map();
  let nextTimer = 1;
  const page = {
    clock: 0, sent, said, timers, dogs, cows,
    reply(path, body) {
      if (path === "/tiles") return { subscribed: body.tiles.length, dogs: page.dogs, cows: page.cows };
      if (path === "/move") { const p = body.path.at(-1); return { moved: body.dog, park_x: p[0], park_y: p[1], cows: [] }; }
      return { ok: true };
    },
    // Lets the oldest post land, and the engine take its answer.
    async answer(fail = false) { await page.answerTo(held[0].path, fail); },
    // Lets the oldest post to `path` land, the others still waiting.
    async answerTo(wanted, fail = false) {
      const at = held.findIndex((h) => h.path === wanted);
      assert.ok(at >= 0, `no ${wanted} waiting`);
      const [{ path, body, resolve, reject }] = held.splice(at, 1);
      if (fail) reject(new Error(`${path}: 500 down`)); else resolve(page.reply(path, body));
      await settle();
    },
    async answerAll() { while (held.length) await page.answer(); },
    fire(id) { const t = timers.get(id); timers.delete(id); t.f(); },
    paths: () => sent.map((s) => s.path),
  };
  const engine = createEngine({
    rule: stillRule(),
    post: (path, body) => new Promise((resolve, reject) => {
      sent.push({ path, body: structuredClone(body) });
      held.push({ path, body, resolve, reject });
    }),
    getJSON: async (path) => { assert.equal(path, "/me"); sent.push({ path }); return me; },
    now: () => page.clock,
    setTimer: (f, ms) => { const id = nextTimer++; timers.set(id, { f, ms }); return id; },
    clearTimer: (id) => { timers.delete(id); },
    log: {
      log: (...a) => said.push(["log", ...a]),
      warn: (...a) => said.push(["warn", ...a]),
      error: (...a) => said.push(["error", ...a]),
    },
  });
  return { page, engine };
}

const settle = async () => { for (let i = 0; i < 10; i++) await new Promise((r) => setImmediate(r)); };
const screen = { width: 800, height: 600 };

test("a load: the viewport where the server kept it, nothing sent", async () => {
  const { page, engine } = fakePage();
  await engine.load(() => screen);
  assert.deepEqual(page.paths(), ["/me"]);
  assert.deepEqual(engine.view().viewport, { parkX: 2000, parkY: 2000, width: 800, height: 600 });
  assert.deepEqual(engine.view().leashed, { kind: "none" });
});

test("a first visit starts at the world's centre and says so; a leash from before is kept 5 s, then released", async () => {
  const { page, engine } = fakePage({ me: { viewport: {}, leash: { dog: 7 } } });
  await engine.load(() => screen);
  assert.deepEqual(page.sent, [{ path: "/me" }, { path: "/viewport", body: { park_x: 2100, park_y: 2200 } }]);
  assert.deepEqual(engine.view().leashed, { kind: "kept", dogId: 7 });
  const [[id, timer]] = page.timers;
  assert.equal(timer.ms, 5000);
  page.fire(id);
  assert.deepEqual(page.sent.at(-1), { path: "/release", body: { dog: 7 } });
  assert.deepEqual(engine.view().leashed, { kind: "none" });
});

test("a grab sends /leash once; another dog's grab releases the first", async () => {
  const { page, engine } = fakePage();
  await engine.load(() => screen);
  engine.intent({ kind: "grab", dogId: 1 });
  engine.intent({ kind: "grab", dogId: 1 });
  assert.deepEqual(page.sent.slice(1), [{ path: "/leash", body: { dog: 1 } }]);
  engine.intent({ kind: "grab", dogId: 2 });
  assert.deepEqual(page.sent.slice(2), [{ path: "/release", body: { dog: 1 } }, { path: "/leash", body: { dog: 2 } }]);
  assert.deepEqual(engine.view().leashed, { kind: "in_hand", dogId: 2 });
  assert.deepEqual(engine.view().lastLeashed, { kind: "dog", dogId: 2 });
  await page.answerAll();
  assert.deepEqual(page.said.map((s) => s[1]), ["leashed", "released", "leashed"]);
});

test("a letgo starts the leash's timer, and its firing sends /release; a grab first stops it", async () => {
  const { page, engine } = fakePage();
  await engine.load(() => screen);
  engine.intent({ kind: "grab", dogId: 1 });
  engine.intent({ kind: "letgo" });
  assert.deepEqual(engine.view().leashed, { kind: "kept", dogId: 1 });
  assert.deepEqual([...page.timers.values()].map((t) => t.ms), [5000]);
  // Grabbed again while kept: the timer goes, and nothing is sent.
  engine.intent({ kind: "grab", dogId: 1 });
  assert.equal(page.timers.size, 0);
  assert.deepEqual(page.paths(), ["/me", "/leash"]);
  engine.intent({ kind: "letgo" });
  engine.intent({ kind: "letgo" }); // a second letgo has nothing in hand
  assert.equal(page.timers.size, 1);
  page.fire([...page.timers.keys()][0]);
  assert.deepEqual(page.sent.at(-1), { path: "/release", body: { dog: 1 } });
  assert.deepEqual(engine.view().leashed, { kind: "none" });
  assert.deepEqual(engine.view().lastLeashed, { kind: "dog", dogId: 1 });
});

// The page knowing dog 1 at (2100, 2100) and dog 2 at (2400, 2300): the
// tiles asked for and answered.
async function withDogs() {
  const out = fakePage({
    dogs: [{ id: 1, emoji: "🐕", park_x: 2100, park_y: 2100 }, { id: 2, emoji: "🐩", park_x: 2400, park_y: 2300 }],
    cows: [{ id: 10, half_x: 4300, half_y: 4220 }],
  });
  await out.engine.load(() => screen);
  out.engine.frame();
  await out.page.answer();
  return out;
}

test("the tiles: the wanted set sent all new, the answer known, nothing more until the viewport moves", async () => {
  const { page, engine } = await withDogs();
  const tiles = page.sent[1];
  assert.equal(tiles.path, "/tiles");
  assert.equal(tiles.body.tiles.length, 12);
  assert.ok(tiles.body.tiles.every((t) => t.is === "new"));
  assert.deepEqual(tiles.body.tiles[0], { col: 3, row: 3, is: "new" });
  const v = engine.view();
  assert.deepEqual([...v.dogs.values()], [
    { id: 1, emoji: "🐕", parkX: 2100, parkY: 2100 }, { id: 2, emoji: "🐩", parkX: 2400, parkY: 2300 },
  ]);
  assert.equal(v.subscribed.size, 12);
  assert.ok(v.subscribed.has("4,4"));
  // The cows are drawn from the next frame, at half the server's halves.
  assert.deepEqual(v.cows, []);
  engine.frame();
  assert.deepEqual(engine.view().cows, [{ id: 10, parkX: 2150, parkY: 2110 }]);
  assert.equal(page.sent.length, 2); // the same tiles: nothing sent
  assert.match(page.said.at(-1)[1], /^tiles: 12 new, 0 dropped, 12 subscribed; 2 dogs arrived for 0 remembered, 2 known; 1 cows arrived, 1 known$/);
});

test("a pan sends /viewport, one in flight, the latest sent once it lands; new tiles marked new, kept ones held", async () => {
  const { page, engine } = await withDogs();
  engine.intent({ kind: "pan", parkX: 2600.4, parkY: 2000 });
  engine.intent({ kind: "pan", parkX: 2700, parkY: 2000 });
  engine.intent({ kind: "pan", parkX: 2800.6, parkY: 1999.5 });
  assert.deepEqual(page.sent.slice(2), [{ path: "/viewport", body: { park_x: 2600, park_y: 2000 } }]);
  await page.answer();
  assert.deepEqual(page.sent.slice(3), [{ path: "/viewport", body: { park_x: 2801, park_y: 2000 } }]);
  await page.answer();
  assert.equal(page.sent.length, 4);
  assert.deepEqual(engine.view().viewport, { parkX: 2800.6, parkY: 1999.5, width: 800, height: 600 });
  // The tiles follow on the next frame: cols 5..7 (x 2550 to 3850), of which 5 and 6 are held.
  engine.frame();
  const tiles = page.sent[4].body.tiles;
  assert.deepEqual(tiles.filter((t) => t.row === 3).map((t) => `${t.col}:${t.is}`), ["5:held", "6:held", "7:new"]);
});

test("a tiles answer replaces what was remembered in a new tile, but not a dog on your leash; a moving one waits", async () => {
  const { page, engine } = await withDogs();
  // Dog 1 on the leash, dog 2 not; the server now has both elsewhere.
  engine.intent({ kind: "grab", dogId: 1 });
  await page.answer();
  page.dogs = [{ id: 1, emoji: "🐕", park_x: 1, park_y: 1 }, { id: 2, emoji: "🐩", park_x: 2450, park_y: 2350 }];
  // Away (every tile dropped), then back (every tile new).
  engine.intent({ kind: "pan", parkX: 4000, parkY: 4000 });
  await page.answer();
  engine.frame();
  await page.answer();
  engine.intent({ kind: "pan", parkX: 2000, parkY: 2000 });
  await page.answer();
  engine.frame();
  await page.answer();
  assert.deepEqual([...engine.view().dogs.values()].map((d) => [d.id, d.parkX, d.parkY]), [[1, 2100, 2100], [2, 2450, 2350]]);
  // A dog off the leash with a move unanswered (dog 1, dragged, then dog 2
  // grabbed, which releases it): a new tile drops it as remembered, and the
  // answer's dog 1 is not taken while the move waits. Today it is known
  // again only when a later answer brings it.
  engine.intent({ kind: "drag", dogId: 1, parkX: 2120, parkY: 2100 });
  engine.intent({ kind: "grab", dogId: 2 });
  assert.deepEqual(page.sent.slice(-3).map((x) => x.path), ["/move", "/release", "/leash"]);
  engine.intent({ kind: "pan", parkX: 4000, parkY: 4000 });
  await page.answerTo("/viewport");
  engine.frame();
  await page.answerTo("/tiles"); // away
  engine.intent({ kind: "pan", parkX: 2000, parkY: 2000 });
  await page.answerTo("/viewport");
  engine.frame();
  await page.answerTo("/tiles"); // back: the move still waits its answer
  assert.equal(engine.view().dogs.get(1), undefined);
  assert.deepEqual(engine.view().dogs.get(2), { id: 2, emoji: "🐩", parkX: 2450, parkY: 2350 });
  // Once it lands, the next answer is the truth again.
  await page.answerTo("/move");
  page.dogs = [{ id: 1, emoji: "🐕", park_x: 2160, park_y: 2160 }];
  engine.intent({ kind: "pan", parkX: 4000, parkY: 4000 });
  await page.answerTo("/viewport");
  engine.frame();
  await page.answerTo("/tiles");
  engine.intent({ kind: "pan", parkX: 2000, parkY: 2000 });
  await page.answerTo("/viewport");
  engine.frame();
  await page.answerTo("/tiles");
  assert.deepEqual(engine.view().dogs.get(1), { id: 1, emoji: "🐕", parkX: 2160, parkY: 2160 });
});

test("drags send /move, one in flight, the rest one path; a sub-pixel drag sends nothing", async () => {
  const { page, engine } = await withDogs();
  engine.intent({ kind: "grab", dogId: 1 });
  await page.answer();
  page.clock = 100;
  engine.intent({ kind: "drag", dogId: 1, parkX: 2110.2, parkY: 2100 });
  engine.intent({ kind: "drag", dogId: 1, parkX: 2110.4, parkY: 2100.3 }); // the same whole pixel
  engine.intent({ kind: "drag", dogId: 1, parkX: 2120, parkY: 2105 });
  engine.intent({ kind: "drag", dogId: 1, parkX: 2130, parkY: 2110 });
  assert.deepEqual(page.sent.slice(3), [{ path: "/move", body: { dog: 1, path: [[2110, 2100]] } }]);
  assert.deepEqual(engine.view().dogs.get(1), { id: 1, emoji: "🐕", parkX: 2130, parkY: 2110 });
  page.clock = 142.4;
  await page.answer();
  assert.deepEqual(page.said.at(-1), ["log", "moved 1 along 1 points to (2110, 2100) in 42 ms"]);
  assert.deepEqual(page.sent.slice(4), [{ path: "/move", body: { dog: 1, path: [[2120, 2105], [2130, 2110]] } }]);
  await page.answer();
  assert.equal(page.sent.length, 5);
  // Back where the server has it: nothing to send.
  engine.intent({ kind: "drag", dogId: 1, parkX: 2129.6, parkY: 2110.4 });
  assert.equal(page.sent.length, 5);
  // A failed move: the server has the dog where it had it, so the same
  // place is sent again.
  engine.intent({ kind: "drag", dogId: 1, parkX: 2140, parkY: 2110 });
  await page.answer(true);
  assert.deepEqual(page.said.at(-1), ["error", "move failed:", "/move: 500 down"]);
  engine.intent({ kind: "drag", dogId: 1, parkX: 2140, parkY: 2110 });
  assert.deepEqual(page.sent.at(-1), { path: "/move", body: { dog: 1, path: [[2140, 2110]] } });
});

test("a move's path holds 100 points, the newest taking the last one's place", async () => {
  const { page, engine } = await withDogs();
  engine.intent({ kind: "grab", dogId: 1 });
  engine.intent({ kind: "drag", dogId: 1, parkX: 2000, parkY: 2000 }); // in flight
  for (let i = 1; i <= 105; i++) engine.intent({ kind: "drag", dogId: 1, parkX: 2000 + i, parkY: 2000 });
  await page.answer(); // the leash
  await page.answer(); // the first move
  const path = page.sent.at(-1).body.path;
  assert.equal(path.length, 100);
  assert.deepEqual([path[0], path[98], path[99]], [[2001, 2000], [2099, 2000], [2105, 2000]]);
});

test("the view is a copy, and the engine takes no other intent", async () => {
  const { engine } = await withDogs();
  const v = engine.view();
  v.viewport.parkX = 0;
  v.dogs.get(1).parkX = 0;
  v.dogs.delete(2);
  v.subscribed.clear();
  const again = engine.view();
  assert.equal(again.viewport.parkX, 2000);
  assert.equal(again.dogs.get(1).parkX, 2100);
  assert.equal(again.dogs.size, 2);
  assert.equal(again.subscribed.size, 12);
  assert.throws(() => engine.intent({ kind: "mode", mode: "overview" }), /no intent mode/);
  assert.throws(() => engine.intent({ kind: "drag", dogId: 99, parkX: 0, parkY: 0 }), /dog 99 is in hand but not known/);
});

test("a resize changes the viewport's size, not its place", async () => {
  const { engine } = fakePage();
  await engine.load(() => screen);
  engine.resize({ width: 1000, height: 700 });
  assert.deepEqual(engine.view().viewport, { parkX: 2000, parkY: 2000, width: 1000, height: 700 });
});

test("two engines in one process share nothing", async () => {
  const a = await withDogs();
  const b = fakePage();
  await b.engine.load(() => ({ width: 400, height: 300 }));
  a.engine.intent({ kind: "grab", dogId: 1 });
  a.engine.intent({ kind: "pan", parkX: 2500, parkY: 2500 });
  const vb = b.engine.view();
  assert.equal(vb.dogs.size, 0);
  assert.equal(vb.subscribed.size, 0);
  assert.deepEqual(vb.leashed, { kind: "none" });
  assert.deepEqual(vb.viewport, { parkX: 2000, parkY: 2000, width: 400, height: 300 });
  // B's first tiles are all new, whatever A has.
  b.engine.frame();
  assert.ok(b.page.sent.at(-1).body.tiles.every((t) => t.is === "new"));
  assert.deepEqual(b.page.paths(), ["/me", "/tiles"]);
  assert.equal(a.engine.view().dogs.size, 2);
});
