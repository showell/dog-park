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
import { pageRig, reports } from "./lib/page_rig.mjs";
import { LIVE, KEPT } from "../solo/physics.js";

// A position on the wire, from whole px.
const hex = (px) => `${px.toString(16)}.00`;

// The page's wire, scripted: each request waits in `waiting` until answered.
function script() {
  const waiting = [];
  return {
    waiting,
    post: (path, text) => new Promise((resolve, reject) => waiting.push({ path, text, resolve, reject })),
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
