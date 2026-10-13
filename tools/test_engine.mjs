// The engine (solo/engine.js) on the real physics.wasm, its wire a script:
// every request held until the test answers it, with whatever text or
// status the test chooses. The answers a real server rarely gives (a 413,
// `req ?`, `reload`, `taken over`, `stuck`, a lost answer, a 502 after
// another), and the page's own rules around them. The agreement with a
// real server is tools/test_page_physics.mjs.
//
//     zig build && node --test tools/test_engine.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { pageRig, reports, held } from "./lib/page_rig.mjs";
import { LIVE, KEPT } from "../solo/physics.js";

// A position on the wire, from whole px.
const hex = (px) => `${px.toString(16)}.00`;

// The page's wire, scripted: each request waits in `waiting` until answered.
function script() {
  const waiting = [];
  return {
    waiting,
    post: (path, text) => held((resolve, reject) => waiting.push({ path, text, resolve, reject })),
    // Answers the oldest request waiting (its path must be `path`).
    async answer(rig, path, text, status = 200) {
      const at = waiting.findIndex((w) => w.path === path);
      assert.ok(at >= 0, `no ${path} waiting`);
      const [w] = waiting.splice(at, 1);
      w.resolve({ status, text });
      await rig.settle();
      return w;
    },
  };
}

// Dogs 0 and 1 and cow 0 in tile 32,32 (the world's middle).
const tileLine = `tile 32,32 cow 0 ${hex(16300)},${hex(16300)} dog 0 ${hex(16100)},${hex(16100)} dog 1 ${hex(16200)},${hex(16150)}`;

const loadAnswer = (k = 10) => `epoch 1791935990000.1\nkept ${k}\nstate leash none drag none view 1280x800 held\n`;

// A loaded page: the load answered, the first report (its view) waiting.
async function loadedPage(s, answer = loadAnswer()) {
  const rig = await pageRig({ post: s.post });
  const loading = rig.engine.load(() => ({ width: 1280, height: 800 }));
  await rig.settle();
  await s.answer(rig, "/load", answer);
  await loading;
  rig.engine.frame(rig.clock);
  await rig.settle();
  return rig;
}

test("a load: its line names the wasm's hash and the screen; the first report is req 1 from K with the view, and the next holds what came", async () => {
  const s = script();
  const rig = await loadedPage(s);
  assert.equal(rig.sent[0].text, `dogpark 1 physics ${rig.physics.hash} load 1280x800\n`);
  const first = reports(rig)[0];
  assert.match(first, new RegExp(`^dogpark 1 physics ${rig.physics.hash} page 1791935990000\\.1 req 1\\nfrom 10\\nview 11 1280x800( \\d+,\\d+)+\\n$`));
  assert.match(first, / 32,32[ \n]/);
  await s.answer(rig, "/report", `req 1\nkept 10\n${tileLine}\n`);
  await rig.ticks(5);
  assert.equal(reports(rig)[1], `dogpark 1 physics ${rig.physics.hash} page 1791935990000.1 req 2\nfrom 10\nheld 11 32,32\n`);
  const v = rig.engine.view();
  assert.deepEqual(v.dogs.get(1), { id: 1, emoji: "🐩", parkX: 16200, parkY: 16150 });
  assert.deepEqual(v.cows, [{ id: 0, parkX: 16300, parkY: 16300 }]);
  assert.deepEqual(rig.physics.critters(KEPT), rig.physics.critters(LIVE));
});

test("30, the first half: a 413 to the first report after a load stops the page; to a later one, the page reloads at once, never resending", async () => {
  const s = script();
  const rig = await loadedPage(s);
  await s.answer(rig, "/report", "too big", 413);
  assert.equal(rig.engine.view().status.kind, "stopped");
  assert.match(rig.engine.view().status.message, /first report after a load was answered 413/);
  assert.deepEqual(rig.reloads, []);
  await rig.ticks(200);
  assert.equal(reports(rig).length, 1, "nothing resent, nothing more sent");

  const s2 = script();
  const later = await loadedPage(s2);
  await s2.answer(later, "/report", `req 1\nkept 10\n${tileLine}\n`);
  await later.ticks(5);
  await s2.answer(later, "/report", "too big", 413);
  assert.equal(later.reloads.length, 1);
  assert.match(later.reloads[0], /413/);
  await later.ticks(200);
  assert.equal(reports(later).length, 2);
});

test("18 and 24: req ? to the first report stops the page with its message and never rewinds; to a later one, the page reloads rather than resend", async () => {
  const s = script();
  const rig = await loadedPage(s);
  await s.answer(rig, "/report", "req ?\n");
  assert.equal(rig.engine.view().status.kind, "stopped");
  assert.match(rig.engine.view().status.message, /req \?/);
  assert.deepEqual(rig.reloads, []);
  await rig.ticks(100);
  assert.equal(reports(rig).length, 1);
  assert.ok(rig.warnings().every((w) => !w.startsWith("differ")));

  const s2 = script();
  const later = await loadedPage(s2);
  await s2.answer(later, "/report", `req 1\nkept 10\n${tileLine}\n`);
  await later.ticks(5);
  await s2.answer(later, "/report", "req ?\n");
  assert.deepEqual(later.reloads, ["req ?, its header unreadable"]);
  await later.ticks(100);
  assert.equal(reports(later).length, 2);
});

test("any reload answer reloads, but the first report's stops; taken over and stuck stop the page", async () => {
  for (const [answer, first, later] of [
    ["reload epoch", "stopped", "reload"],
    ["reload from 7", "stopped", "reload"],
    ["reload differs", "stopped", "reload"],
    ["taken over", "stopped", "stopped"],
    ["stuck 1042", "stopped", "stopped"],
  ]) {
    const s = script();
    const rig = await loadedPage(s);
    await s.answer(rig, "/report", `req 1\n${answer}\n`);
    assert.equal(rig.engine.view().status.kind, first, answer);
    assert.deepEqual(rig.reloads, []);

    const s2 = script();
    const p = await loadedPage(s2);
    await s2.answer(p, "/report", `req 1\nkept 10\n${tileLine}\n`);
    await p.ticks(5);
    await s2.answer(p, "/report", `req 2\n${answer}\n`);
    if (later === "reload") assert.deepEqual(p.reloads, [answer], answer);
    else {
      assert.equal(p.engine.view().status.kind, "stopped", answer);
      assert.deepEqual(p.reloads, []);
    }
  }
  const s = script();
  const rig = await loadedPage(s);
  await s.answer(rig, "/report", "req 1\nstuck 1042\n");
  assert.equal(rig.engine.view().status.message, "the physics disagrees with itself at tick 1042");
});

test("a load answered stuck, reload physics or req ? stops the page with its reason", async () => {
  for (const [answer, says] of [
    ["stuck 77\n", /disagrees with itself at tick 77/],
    ["reload physics 00000001\n", /is not the server's \(00000001\)/],
    ["req ?\n", /can't read this page's load line/],
  ]) {
    const s = script();
    const rig = await pageRig({ post: s.post });
    const loading = rig.engine.load(() => ({ width: 1280, height: 800 }));
    await rig.settle();
    await s.answer(rig, "/load", answer);
    await loading;
    assert.equal(rig.engine.view().status.kind, "stopped");
    assert.match(rig.engine.view().status.message, says);
  }
});

test("3: no answer in 5 s: the same bytes again at once; the abandoned try's late answer is dropped unread", async () => {
  const s = script();
  const rig = await loadedPage(s);
  const [first] = s.waiting.splice(0, 1);
  await rig.ticks(79); // 4.94 s
  assert.equal(reports(rig).length, 1);
  await rig.ticks(1);
  assert.equal(reports(rig).length, 2);
  assert.equal(reports(rig)[1], reports(rig)[0]);
  // The first try's answer, late: dropped, the page still waiting.
  first.resolve({ status: 200, text: "req 1\nreload epoch\n" });
  await rig.settle();
  assert.equal(rig.engine.view().status.kind, "playing");
  assert.deepEqual(rig.reloads, []);
  await s.answer(rig, "/report", `req 1\nkept 10\n${tileLine}\n`);
  await rig.ticks(5);
  assert.match(reports(rig)[2], /req 2\nfrom 10\nheld 11 32,32\n$/);
});

test("the tries of one request: 5 s apart, then 10, 20, 40 and 60 for ever, the same bytes each time", async () => {
  const s = script();
  const rig = await loadedPage(s);
  const triedAt = [rig.clock];
  for (let n = 0; n < 6; n++) {
    await s.answer(rig, "/report", "bad gateway", 502);
    while (s.waiting.length === 0) await rig.ticks(1);
    triedAt.push(rig.clock);
  }
  const gaps = triedAt.slice(1).map((t, i) => Math.round((t - triedAt[i]) / 1000));
  assert.deepEqual(gaps, [5, 10, 20, 40, 60, 60]);
  assert.ok(reports(rig).every((r) => r === reports(rig)[0]));
  assert.equal(rig.engine.view().status.kind, "playing");
});

test("23: a tile sent again (after a differ) doesn't move a critter the page has", async () => {
  const s = script();
  const rig = await loadedPage(s);
  await s.answer(rig, "/report", `req 1\nkept 10\n${tileLine}\n`);
  await rig.ticks(5);
  const moved = `tile 32,32 cow 0 ${hex(16000)},${hex(16000)} dog 0 ${hex(16010)},${hex(16010)} dog 2 ${hex(16400)},${hex(16400)}\n`;
  await s.answer(rig, "/report", `req 2\nkept 10\n${moved}`);
  const v = rig.engine.view();
  assert.deepEqual([v.dogs.get(0).parkX, v.dogs.get(0).parkY], [16100, 16100]);
  assert.deepEqual([v.cows[0].parkX, v.cows[0].parkY], [16300, 16300]);
  // A critter it hadn't is placed.
  assert.deepEqual([v.dogs.get(2).parkX, v.dogs.get(2).parkY], [16400, 16400]);
});

test("at most 16 of the human's inputs a tick: the 17th is dropped and said", async () => {
  const s = script();
  const rig = await loadedPage(s);
  await s.answer(rig, "/report", `req 1\nkept 10\n${tileLine}\n`);
  await rig.ticks(1);
  // Frozen: the leash's region isn't held (its tiles never come), so every
  // input takes tick 11. A grab of dog 0, then seven of 1, 0, ...: a leash,
  // then a release and a leash each, 15; then one more grab of the same
  // dog is the 16th, and a 17th is dropped.
  rig.engine.intent({ kind: "grab", dogId: 0 });
  for (let i = 1; i <= 7; i++) rig.engine.intent({ kind: "grab", dogId: i % 2 });
  rig.engine.intent({ kind: "grab", dogId: 1 });
  rig.engine.intent({ kind: "grab", dogId: 1 });
  const humans = rig.engine.debug().record.filter((e) => e.kind === "human");
  assert.equal(humans.length, 16);
  assert.ok(humans.every((e) => e.t === 11));
  assert.match(rig.warnings().join("\n"), /a grab at tick 11 dropped: 16 inputs there already/);
});

// ── replays, against a scripted world ───────────────────────────────────────

// A tiny world for the script: critters in tile 32,32 only; every report
// answered `kept` its last tick, with a tile line for each tile its views
// subscribe that hasn't gone out yet (`hold` keeps a tile back).
function world(critters) {
  const sent = new Set();
  const hold = new Set();
  const tileOf = (c) => `${Math.floor(c.x / 500)},${Math.floor(c.y / 500)}`;
  const lineOf = (key) => `tile ${key}${critters.filter((c) => tileOf(c) === key).map((c) => ` ${c.kind} ${c.n} ${hex(c.x)},${hex(c.y)}`).join("")}`;
  return {
    sent,
    hold,
    tileLines(views) {
      const out = [];
      for (const key of views) {
        if (sent.has(key) || hold.has(key)) continue;
        sent.add(key);
        out.push(lineOf(key));
      }
      return out;
    },
    viewsOf: (text) => text.split("\n").filter((l) => l.startsWith("view ")).flatMap((l) => l.split(" ").slice(3)),
    keptOf(text) {
      const req = /req (\d+)\n/.exec(text)[1];
      const ticks = [...text.matchAll(/\nt (\d+) /g)].map((m) => Number(m[1]));
      const from = Number(/\nfrom (\d+)/.exec(text)[1]);
      return { req, kept: ticks.length ? ticks.at(-1) : from };
    },
  };
}

// Answers every report waiting with `kept`, as the world does.
async function keepAll(s, rig, w) {
  while (s.waiting.some((x) => x.path === "/report")) {
    const r = s.waiting.find((x) => x.path === "/report");
    const { req, kept } = w.keptOf(r.text);
    await s.answer(rig, "/report", [`req ${req}`, `kept ${kept}`, ...w.tileLines(w.viewsOf(r.text))].join("\n") + "\n");
  }
}

// A page on the scripted world: loaded, 200 x 200 on dog 0, every tile
// it sees came. Ticks until nothing waits.
async function onWorld(critters, budget) {
  const s = script();
  const w = world(critters);
  const rig = await pageRig({ post: s.post, screen: { width: 200, height: 200 }, at: { parkX: 16000, parkY: 16000 }, budget });
  const loading = rig.engine.load(() => ({ width: 200, height: 200 }), { parkX: 16000, parkY: 16000 });
  await rig.settle();
  await s.answer(rig, "/load", loadAnswer());
  await loading;
  rig.engine.frame(rig.clock);
  await rig.settle();
  const settle = async (n) => {
    for (let i = 0; i < n; i++) {
      await keepAll(s, rig, w);
      await rig.ticks(1);
    }
  };
  await settle(10);
  return { s, w, rig, settle };
}

// The differ the server would write: kept T - 1, its line, the state at
// T's start (dog 0 leashed with the drag on, the page's own view and held:
// nothing in these tests changes them after the leash), and a board.
function differAnswer(rig, req, T, line, board) {
  const d = rig.engine.debug();
  const tiles = (keys) => keys.map((k) => ` ${k}`).join("");
  const state = `state leash 0 drag on view 200x200${tiles(d.view)} held${tiles(d.held)}`;
  return `req ${req}\nkept ${T - 1}\ndiffer ${T} ${line}\n${state}\nboard ${T}${board.map((c) => ` ${c.kind} ${c.n} ${hex(c.x)},${hex(c.y)}`).join("")}\n`;
}

test("22: a replay whose path reaches a new tile before its recorded held: the view goes at that tick, the replay waits for the tile, then resumes", async () => {
  const { s, w, rig, settle } = await onWorld([{ kind: "dog", n: 0, x: 16100, y: 16100 }]);
  rig.engine.intent({ kind: "grab", dogId: 0 });
  await settle(6);
  assert.equal(rig.engine.debug().K, rig.engine.view().tick, "ticking, every tick kept");
  // The region's east edge is at 17100: column 35 (from 17500) is 400 px off.
  assert.ok(!rig.engine.debug().view.includes("35,32"));
  // Ten ticks east at 10 px a tick, the answers held back.
  for (let i = 0; i < 10; i++) {
    rig.engine.intent({ kind: "drag", dogId: 0, dx: 10, dy: 0 });
    await rig.ticks(1);
  }
  const inFlight = s.waiting.find((x) => x.path === "/report");
  const T = Number(/\nt (\d+) /.exec(inFlight.text)[1]);
  const was = /\n dog 0 ([0-9a-f.]+),[0-9a-f.]+ > /.exec(inFlight.text)[1];
  const x0 = parseInt(was, 16);
  // The server had the dog 330 px further east: on replay, its region
  // reaches column 35 seven ticks in.
  const req = /req (\d+)\n/.exec(inFlight.text)[1];
  const [waiting] = s.waiting.splice(s.waiting.indexOf(inFlight), 1);
  w.hold.add("35,30").add("35,31").add("35,32").add("35,33").add("35,34");
  waiting.resolve({ status: 200, text: differAnswer(rig, req, T, `dog 0 ${hex(x0 + 330)},${hex(16100)} > ${hex(x0 + 340)},${hex(16100)}`, [{ kind: "dog", n: 0, x: x0 + 330, y: 16100 }]) });
  await rig.settle();
  const d = rig.engine.debug();
  const view = d.record.find((e) => e.kind === "view" && e.tiles.some((t) => t.col === 35));
  assert.ok(view, "a view adding column 35");
  // At the first tick whose region meets it: the dog's region at a tick's
  // start (its east edge 1000 px past the dog) passes 17500 over the tick
  // before.
  const before = d.record.find((e) => e.kind === "tick" && e.t === view.t - 1);
  const [, a, b] = / dog 0 ([0-9a-f]+)\.[0-9a-f]+,[^ ]+ > ([0-9a-f]+)\.[0-9a-f]+,/.exec(before.checked);
  assert.ok(parseInt(a, 16) + 1000 <= 17500 && parseInt(b, 16) + 1000 > 17500, before.checked);
  assert.ok(d.cursor < d.record.length, "the replay waits");
  assert.equal(d.record[d.cursor].kind, "tick");
  assert.equal(d.record[d.cursor].t, view.t);
  // The next report carries the replayed ticks before it and the view.
  await rig.ticks(5);
  const next = s.waiting.find((x) => x.path === "/report");
  assert.match(next.text, new RegExp(`\\nfrom ${T - 1} wall \\d+\\n`));
  assert.match(next.text, new RegExp(`\\nview ${view.t} 200x200[^\\n]* 35,32[ \\n]`));
  assert.doesNotMatch(next.text, new RegExp(`\\nt ${view.t} `));
  // The tile comes; the held goes at that tick and the replay runs on.
  w.hold.clear();
  await keepAll(s, rig, w);
  await settle(8);
  const after = rig.engine.debug();
  assert.equal(after.cursor, after.record.length);
  const all = reports(rig).join("");
  assert.match(all, new RegExp(`\\nheld ${view.t} [^\\n]*35,32`));
  assert.match(all, new RegExp(`\\nt ${view.t} `));
  assert.equal(rig.engine.view().status.kind, "playing");
});

test("22, the other branch: a tile the page already has is held at once, and the replay doesn't stop", async () => {
  const { s, w, rig, settle } = await onWorld([{ kind: "dog", n: 0, x: 16100, y: 16100 }]);
  // Column 35's tiles, rows 30 to 34 (the region's), came earlier: a pan
  // there and back.
  for (const parkY of [15200, 16000, 16800]) {
    rig.engine.intent({ kind: "pan", parkX: 17400, parkY });
    await settle(6);
  }
  rig.engine.intent({ kind: "pan", parkX: 16000, parkY: 16000 });
  await settle(6);
  for (let row = 30; row <= 34; row++) assert.ok(rig.engine.debug().received.includes(`35,${row}`));
  assert.ok(!rig.engine.debug().view.includes("35,32"));
  rig.engine.intent({ kind: "grab", dogId: 0 });
  await settle(6);
  for (let i = 0; i < 10; i++) {
    rig.engine.intent({ kind: "drag", dogId: 0, dx: 10, dy: 0 });
    await rig.ticks(1);
  }
  const inFlight = s.waiting.find((x) => x.path === "/report");
  const T = Number(/\nt (\d+) /.exec(inFlight.text)[1]);
  const x0 = parseInt(/\n dog 0 ([0-9a-f.]+),/.exec(inFlight.text)[1], 16);
  const req = /req (\d+)\n/.exec(inFlight.text)[1];
  s.waiting.splice(s.waiting.indexOf(inFlight), 1);
  inFlight.resolve({ status: 200, text: differAnswer(rig, req, T, `dog 0 ${hex(x0 + 330)},${hex(16100)} > ${hex(x0 + 340)},${hex(16100)}`, [{ kind: "dog", n: 0, x: x0 + 330, y: 16100 }]) });
  await rig.settle();
  const d = rig.engine.debug();
  assert.equal(d.cursor, d.record.length, "the replay ran to the end");
  const view = d.record.find((e) => e.kind === "view" && e.tiles.some((t) => t.col === 35));
  const held = d.record.find((e) => e.kind === "held" && e.tiles.some((t) => t.col === 35));
  assert.ok(view && held);
  assert.equal(held.t, view.t);
  assert.ok(d.record.indexOf(view) < d.record.indexOf(held));
});

test("a bump lets go of the pointer: the drags after it are not the dog's, and the leash stays", async () => {
  // Dog 1 50 px east of dog 0: 10 px between their squares.
  const { rig, settle } = await onWorld([{ kind: "dog", n: 0, x: 16100, y: 16100 }, { kind: "dog", n: 1, x: 16150, y: 16100 }]);
  rig.engine.intent({ kind: "grab", dogId: 0 });
  await settle(4);
  assert.equal(rig.engine.view().holding, true);
  rig.engine.intent({ kind: "drag", dogId: 0, dx: 30, dy: 0 });
  await settle(1);
  assert.equal(rig.engine.view().holding, false);
  const all = reports(rig).join("");
  assert.match(all, /\nbump \d+ dog 1\n/);
  rig.engine.intent({ kind: "drag", dogId: 0, dx: 30, dy: 0 });
  await settle(3);
  assert.deepEqual(rig.engine.view().leashed, { kind: "kept", dogId: 0 });
  // Only the one drag before the bump was ever recorded.
  assert.equal([...reports(rig).join("").matchAll(/ drag /g)].length, 1);
});

test("a replay that loses a bump stands it as a letgo at that tick; one that gains a bump drops the drags after it", async () => {
  // Lost: the page bumped dog 1, the server had dog 1 out of the way.
  {
    const { s, rig, settle } = await onWorld([{ kind: "dog", n: 0, x: 16100, y: 16100 }, { kind: "dog", n: 1, x: 16150, y: 16100 }]);
    rig.engine.intent({ kind: "grab", dogId: 0 });
    await settle(4);
    rig.engine.intent({ kind: "drag", dogId: 0, dx: 30, dy: 0 });
    await rig.ticks(3);
    const inFlight = s.waiting.find((x) => x.path === "/report" && /\nbump /.test(x.text));
    assert.ok(inFlight, "the bump went");
    const T = Number(/\nt (\d+) [^\n]* drag /.exec(inFlight.text)[1]);
    assert.match(inFlight.text, new RegExp(`\\nbump ${T} dog 1\\n`));
    const req = /req (\d+)\n/.exec(inFlight.text)[1];
    s.waiting.splice(s.waiting.indexOf(inFlight), 1);
    inFlight.resolve({ status: 200, text: differAnswer(rig, req, T, `dog 0 ${hex(16100)},${hex(16100)} > ${hex(16130)},${hex(16100)}`, [{ kind: "dog", n: 0, x: 16100, y: 16100 }, { kind: "dog", n: 1, x: 16300, y: 16100 }]) });
    await rig.settle();
    const rec = rig.engine.debug().record;
    const at = rec.findIndex((e) => e.kind === "tick" && e.t === T);
    assert.deepEqual([rec[at - 1].kind, rec[at - 1].h, rec[at - 1].t], ["human", "letgo", T]);
    assert.ok(!(rec[at].flags & 1), "no bump now");
    assert.match(rec[at].checked, / dog 0 3ee4.00,3ee4.00 > 3f02.00,3ee4.00\n/);
  }
  // Gained: the page's way was clear, the server had dog 1 in it.
  {
    const { s, rig, settle } = await onWorld([{ kind: "dog", n: 0, x: 16100, y: 16100 }, { kind: "dog", n: 1, x: 16300, y: 16100 }]);
    rig.engine.intent({ kind: "grab", dogId: 0 });
    await settle(4);
    for (let i = 0; i < 4; i++) {
      rig.engine.intent({ kind: "drag", dogId: 0, dx: 10, dy: 0 });
      await rig.ticks(1);
    }
    const inFlight = s.waiting.find((x) => x.path === "/report" && / drag /.test(x.text));
    const T = Number(/\nt (\d+) [^\n]* drag /.exec(inFlight.text)[1]);
    const req = /req (\d+)\n/.exec(inFlight.text)[1];
    s.waiting.splice(s.waiting.indexOf(inFlight), 1);
    inFlight.resolve({ status: 200, text: differAnswer(rig, req, T, `bump ${T} dog 1`, [{ kind: "dog", n: 0, x: 16100, y: 16100 }, { kind: "dog", n: 1, x: 16145, y: 16100 }]) });
    await rig.settle();
    assert.equal(rig.engine.view().holding, false, "the pointer let go");
    const rec = rig.engine.debug().record;
    const ticks = rec.filter((e) => e.kind === "tick");
    assert.ok(ticks[0].flags & 1, "the bump");
    assert.ok(ticks.slice(1).every((e) => e.drag.length === 0), "no drag after it");
    rig.engine.intent({ kind: "drag", dogId: 0, dx: 10, dy: 0 });
    await rig.ticks(2);
    assert.ok(rig.engine.debug().record.filter((e) => e.kind === "tick").slice(1).every((e) => e.drag.length === 0));
  }
});

test("7: a replay held back at the byte budget while the human acts: the new input takes the tick after the last recorded one", async () => {
  // A budget of 1000 bytes (48 KiB in play), so a short replay reaches it.
  const { s, rig, settle } = await onWorld([{ kind: "dog", n: 0, x: 16100, y: 16100 }, { kind: "dog", n: 1, x: 16200, y: 16100 }], 1000);
  rig.engine.intent({ kind: "grab", dogId: 0 });
  await settle(4);
  // Answers held: the page runs on until its unsent text reaches the budget.
  for (let i = 0; i < 30; i++) {
    rig.engine.intent({ kind: "drag", dogId: 0, dx: 0, dy: 3 });
    await rig.ticks(1);
  }
  const frozen = rig.engine.debug();
  assert.ok(frozen.unsentBytes >= 1000, "frozen at the budget");
  const lastRun = frozen.record.filter((e) => e.kind === "tick").at(-1).t;
  await rig.ticks(3);
  assert.equal(rig.engine.debug().record.filter((e) => e.kind === "tick").at(-1).t, lastRun, "no tick past the budget");
  // The in-flight report refuted at its first tick, the board as the page has
  // it: the replay regenerates every tick, but stops at the budget.
  const inFlight = s.waiting.find((x) => x.path === "/report");
  const T = Number(/\nt (\d+) /.exec(inFlight.text)[1]);
  const req = /req (\d+)\n/.exec(inFlight.text)[1];
  const at = (n) => {
    const m = new RegExp(`\\n dog ${n} ([0-9a-f.]+),([0-9a-f.]+) > `).exec(inFlight.text.slice(inFlight.text.indexOf(`\nt ${T} `)));
    return m ? { x: parseInt(m[1], 16), y: parseInt(m[2], 16) } : null;
  };
  const d0 = at(0) ?? { x: 16100, y: 16100 };
  const d1 = at(1);
  s.waiting.splice(s.waiting.indexOf(inFlight), 1);
  inFlight.resolve({ status: 200, text: differAnswer(rig, req, T, "rest 1", [{ kind: "dog", n: 0, ...d0 }, ...(d1 ? [{ kind: "dog", n: 1, ...d1 }] : [])]) });
  await rig.settle();
  const replayed = rig.engine.debug();
  assert.ok(replayed.cursor < replayed.record.length, "the replay is held back");
  const next = s.waiting.find((x) => x.path === "/report");
  assert.ok(next, "a report went at once, at the budget");
  assert.match(next.text, /\n( dog |cow |rest )[^\n]*\n$/, "ending on a tick's lines");
  // The human lets go: after the last recorded tick, not inside the held-back ones.
  const lastRecorded = replayed.record.filter((e) => e.kind === "tick").at(-1).t;
  rig.engine.intent({ kind: "letgo" });
  const letgo = rig.engine.debug().record.at(-1);
  assert.deepEqual([letgo.kind, letgo.h, letgo.t], ["human", "letgo", lastRecorded + 1]);
  // Kept, and kept again: the replay resumes, and the letgo plays in its place.
  await settle(60);
  const done = rig.engine.debug();
  assert.equal(done.cursor, done.record.length);
  assert.match(reports(rig).join(""), new RegExp(`\\nletgo ${lastRecorded + 1}\\n`));
  assert.ok(reports(rig).every((r) => r.length < 1000 + 600), "no report much past the budget");
});
