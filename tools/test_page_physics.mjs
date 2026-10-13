// The page on the new physics, end to end: the engine (solo/engine.js) on
// the real physics.wasm, talking to a real scratch server
// (tools/lib/scratch_server.mjs: zig-out/bin/dog-park-play on a free port
// and a temporary data dir, stopped by its PID), its clock and timers fake.
// CC's sketch B (the page and the server agree; a differ rewinds and heals)
// and the page's side of docs/PHYSICS.md's tests to write first.
//
//     zig build && node --test tools/test_page_physics.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { scratchServer } from "./lib/scratch_server.mjs";
import { pageRig, reports, wasmBytes, held as heldPromise } from "./lib/page_rig.mjs";
import { LIVE, KEPT } from "../solo/physics.js";

// The dog nearest the screen's middle, of those the page has.
function middleDog(rig) {
  const v = rig.engine.view();
  const cx = v.viewport.parkX + v.viewport.width / 2;
  const cy = v.viewport.parkY + v.viewport.height / 2;
  return [...v.dogs.values()].sort((a, b) => Math.hypot(a.parkX - cx, a.parkY - cy) - Math.hypot(b.parkX - cx, b.parkY - cy))[0];
}

// Every answer the server gave, by request number, from a recording post.
function recording(server) {
  const answers = [];
  return {
    answers,
    post: async (path, text) => {
      const r = await server.post(path, text);
      answers.push({ path, sent: text, ...r });
      return r;
    },
  };
}

const differs = (rig) => rig.warnings().filter((w) => w.startsWith("differ"));

// The checked lines of every report (critter, bump, rest, release lines).
function checkedLines(texts) {
  return texts.flatMap((t) => t.split("\n").filter((l) => /^( dog | cow |bump |rest )/.test(l) || /^release \d+ \d+$/.test(l)));
}

// Leashes the middle dog and drags it `ticks` ticks (dx, dy px a tick), then lets go.
async function dragAbout(rig, ticks, dx, dy) {
  const dog = middleDog(rig);
  rig.engine.intent({ kind: "grab", dogId: dog.id });
  for (let i = 0; i < ticks; i++) {
    rig.engine.intent({ kind: "drag", dogId: dog.id, dx, dy });
    await rig.ticks(1);
  }
  rig.engine.intent({ kind: "letgo" });
  return dog;
}

test("1. an unleashed pan: the view brings its tiles' critters, then the page holds them; every answer kept", async () => {
  const server = await scratchServer();
  try {
    const wire = recording(server);
    const rig = await pageRig({ post: wire.post });
    await rig.load();
    await rig.ticks(8);
    const [first, second] = reports(rig);
    assert.match(first, /^dogpark 1 physics [0-9a-f]{8} page \d+\.1 req 1\nfrom 0\nview 1 1280x800( \d+,\d+)+\n$/);
    const viewTiles = first.split("\n")[2].split(" ").slice(3);
    // The answer: its tiles' critters, a tile line each.
    const a1 = wire.answers.find((a) => a.sent === first);
    assert.equal(a1.text.split("\n").filter((l) => l.startsWith("tile ")).length, viewTiles.length);
    // The next report holds exactly them, at the same tick: nothing has ticked.
    assert.match(second, /^dogpark .* req 2\nfrom 0\nheld 1( \d+,\d+)+\n$/);
    assert.deepEqual(second.split("\n")[2].split(" ").slice(2).sort(), [...viewTiles].sort());
    assert.ok(wire.answers.filter((a) => a.path === "/report").every((a) => /^req \d+\nkept 0\n/.test(a.text)), "every report kept");
    // Pan two tiles east: a view of the new tiles, then their held; nothing else.
    const v = rig.engine.view().viewport;
    for (let i = 1; i <= 10; i++) {
      rig.engine.intent({ kind: "pan", parkX: v.parkX + 100 * i, parkY: v.parkY });
      await rig.ticks(1);
    }
    await rig.ticks(10);
    assert.deepEqual(differs(rig), []);
    const d = rig.engine.debug();
    assert.deepEqual(d.held, d.view, "every subscribed tile held");
    assert.ok(d.held.every((k) => d.received.includes(k)), "a held names only tiles whose critters came");
    assert.equal(rig.engine.view().status.kind, "playing");
  } finally {
    await server.stop();
  }
});

test("sketch B, the first half: a leash, a drag and its let-go, every tick kept, the park asleep 80 ticks after", async () => {
  const server = await scratchServer();
  try {
    const wire = recording(server);
    const rig = await pageRig({ post: wire.post });
    await rig.load();
    await rig.ticks(4);
    const dog = await dragAbout(rig, 40, 3, 1);
    await rig.ticks(120);
    assert.deepEqual(rig.warnings(), []);
    for (const a of wire.answers.filter((x) => x.path === "/report")) assert.match(a.text, /^req \d+\nkept \d+\n/, a.text);
    const d = rig.engine.debug();
    assert.equal(d.ticking, false);
    assert.deepEqual(rig.engine.view().leashed, { kind: "none" });
    // The release, 80 ticks after the letgo, written by the shared Zig and kept.
    const all = reports(rig).join("");
    const letgo = Number(/\nletgo (\d+)\n/.exec(all)[1]);
    assert.match(all, new RegExp(`\\nrelease ${letgo + 80} ${dog.id}\\n`));
    assert.equal(d.K, letgo + 80);
    // The kept board is the live one, critter for critter.
    assert.deepEqual(rig.physics.critters(KEPT), rig.physics.critters(LIVE));
    // The dog went 40 ticks of (3, 1) px from where it was: nothing in its way.
    const now = rig.engine.view().dogs.get(dog.id);
    assert.deepEqual([now.parkX - dog.parkX, now.parkY - dog.parkY], [120, 40]);
  } finally {
    await server.stop();
  }
});

test("sketch B, the second half, and 2: a page whose board drifted is refuted, rewinds (no reload) and heals", async () => {
  const server = await scratchServer();
  try {
    const wire = recording(server);
    const rig = await pageRig({ post: wire.post });
    await rig.load();
    await rig.ticks(4);
    const dog = middleDog(rig);
    rig.engine.intent({ kind: "grab", dogId: dog.id });
    for (let i = 0; i < 6; i++) {
      rig.engine.intent({ kind: "drag", dogId: dog.id, dx: 3, dy: 1 });
      await rig.ticks(1);
    }
    // Drift: the leashed dog moved 2 px on the page's boards (the live one
    // and the kept one) behind the physics' back, as a page bug might: only
    // the server's board line can put it back.
    const K = rig.engine.debug().K;
    const x = rig.physics.raw;
    for (const b of [LIVE, KEPT]) new Int32Array(x.memory.buffer, x.dogsAt(b), 2 * x.dogCount())[2 * dog.id] += 512;
    for (let i = 0; i < 10; i++) {
      rig.engine.intent({ kind: "drag", dogId: dog.id, dx: 3, dy: 1 });
      await rig.ticks(1);
    }
    rig.engine.intent({ kind: "letgo" });
    await rig.ticks(20);
    const refuted = wire.answers.filter((a) => /\ndiffer /.test(a.text));
    assert.equal(refuted.length, 1, "one differ");
    const answer = refuted[0].text;
    // Refuted at a tick after the drift, with the server's line, the state and the board.
    const T = Number(/\ndiffer (\d+) dog /.exec(answer)[1]);
    assert.ok(T > K);
    assert.match(answer, new RegExp(`\\nkept ${T - 1}\\ndiffer ${T} dog ${dog.id} `));
    assert.match(answer, /\nstate leash \d+ drag on view /);
    assert.match(answer, new RegExp(`\\nboard ${T} dog ${dog.id} `));
    // The next report starts from T - 1 and is kept: the rewind healed it.
    const after = wire.answers.findIndex((a) => a === refuted[0]);
    const next = wire.answers[after + 1];
    assert.match(next.sent, new RegExp(`\\nfrom ${T - 1}( wall \\d+)?\\n`));
    assert.match(next.text, /^req \d+\nkept \d+\n/);
    assert.ok(wire.answers.slice(after + 1).every((a) => /^req \d+\nkept \d+\n/.test(a.text)));
    assert.deepEqual(rig.reloads, []);
    assert.equal(rig.engine.view().status.kind, "playing");
    // The dog is where the server has it: the board line laid over, the rest replayed.
    assert.deepEqual(rig.physics.critters(KEPT), rig.physics.critters(LIVE));
  } finally {
    await server.stop();
  }
});

test("3 and 15: a lost answer to a report carrying a leash: the resend is byte for byte, gets the stored answer, and the next request doesn't repeat the leash", async () => {
  const server = await scratchServer();
  try {
    const wire = recording(server);
    let swallow = "none";
    let rig;
    rig = await pageRig({
      post: (path, text) => {
        const answered = wire.post(path, text);
        if (swallow === "next" && path === "/report" && /\nleash \d+ \d+\n/.test(text)) {
          swallow = text;
          rig.track(answered); // the server takes it...
          return heldPromise(() => {}); // ...and its answer never comes back
        }
        return answered;
      },
    });
    await rig.load();
    await rig.ticks(8);
    swallow = "next";
    const dog = middleDog(rig);
    rig.engine.intent({ kind: "grab", dogId: dog.id });
    await rig.ticks(1);
    assert.notEqual(swallow, "next", "the report with the leash went");
    const lost = swallow;
    // The leash waits for the region's tiles: inputs with no tick.
    assert.doesNotMatch(lost, /\nt \d+ /);
    // Within 5 s, nothing more goes; at 5 s the same bytes go again.
    const before = reports(rig).length;
    await rig.ticks(79);
    assert.equal(reports(rig).length, before);
    await rig.ticks(2);
    const resend = reports(rig)[before];
    assert.equal(resend, lost);
    const answers = wire.answers.filter((a) => a.sent === lost);
    assert.equal(answers.length, 2);
    assert.equal(answers[1].text, answers[0].text, "the server's stored answer");
    await rig.ticks(10);
    // R + 1 holds the region (the tiles came with the stored answer), and
    // the ticks follow; no later request repeats the leash.
    const later = reports(rig).slice(before + 1);
    assert.match(later[0], /^dogpark .*\nfrom 0\nheld 1 /);
    assert.ok(later.some((r) => /\nt \d+ /.test(r)));
    assert.ok(later.every((r) => !/\nleash /.test(r)));
    assert.match(rig.warnings().join("\n"), /\/report, try 1: no answer in 5 s/);
    assert.ok(wire.answers.every((a) => !/\ndiffer /.test(a.text)));
  } finally {
    await server.stop();
  }
});

test("30, the second half: a 502 is transient: the same bytes again on the backoff, and the page plays on", async () => {
  const server = await scratchServer();
  try {
    let fail = 0;
    const rig = await pageRig({
      post: async (path, text) => {
        if (path === "/report" && fail > 0) {
          fail--;
          return { status: 502, text: "bad gateway" };
        }
        return server.post(path, text);
      },
    });
    await rig.load();
    await rig.ticks(8);
    fail = 2;
    const dog = await dragAbout(rig, 3, 2, 0);
    const n = reports(rig).length;
    const failedText = reports(rig).at(-1);
    // 5 s, then 10 s from the second try: three tries of the same bytes.
    await rig.ticks(16 * 16);
    const all = reports(rig);
    assert.equal(all[n - 1], failedText);
    assert.equal(all[n], failedText);
    assert.equal(all[n + 1], failedText);
    assert.notEqual(all[n + 2], failedText);
    assert.match(rig.warnings().join("\n"), /try 1: a 502; again in 5000 ms[\s\S]*try 2: a 502; again in 10000 ms/);
    assert.equal(rig.engine.view().status.kind, "playing");
    assert.deepEqual(differs(rig), []);
    assert.ok(rig.engine.view().dogs.get(dog.id).parkX > dog.parkX);
  } finally {
    await server.stop();
  }
});

test("21: thirty unleashed pans: no refusal, and one view and one held a tick in any report", async () => {
  const server = await scratchServer();
  try {
    const wire = recording(server);
    const rig = await pageRig({ post: wire.post });
    await rig.load();
    await rig.ticks(4);
    const v = rig.engine.view().viewport;
    for (let i = 1; i <= 30; i++) {
      rig.engine.intent({ kind: "pan", parkX: v.parkX + 37 * i, parkY: v.parkY - 23 * i });
      rig.engine.frame(rig.clock + 1);
      await rig.ticks(1);
    }
    await rig.ticks(10);
    for (const r of reports(rig)) {
      const views = r.split("\n").filter((l) => l.startsWith("view "));
      const helds = r.split("\n").filter((l) => l.startsWith("held "));
      assert.ok(views.length <= 1 && helds.length <= 1, r);
    }
    assert.ok(wire.answers.filter((a) => a.path === "/report").every((a) => /^req \d+\nkept 0\n/.test(a.text)));
    assert.equal(rig.engine.view().status.kind, "playing");
  } finally {
    await server.stop();
  }
});

test("6: frozen at the 32-tick window, a letgo takes from + 33, and the server keeps it", async () => {
  const server = await scratchServer();
  try {
    let holdAnswers = false;
    const held = [];
    let rig;
    rig = await pageRig({
      post: (path, text) => {
        const answered = server.post(path, text);
        if (!(holdAnswers && path === "/report")) return answered;
        rig.track(answered);
        return heldPromise((resolve) => held.push(() => answered.then(resolve)));
      },
    });
    await rig.load();
    await rig.ticks(4);
    const dog = middleDog(rig);
    rig.engine.intent({ kind: "grab", dogId: dog.id });
    await rig.ticks(4);
    const from = rig.engine.debug().K;
    holdAnswers = true;
    for (let i = 0; i < 40; i++) {
      rig.engine.intent({ kind: "drag", dogId: dog.id, dx: 1, dy: 0 });
      await rig.ticks(1);
      if (i === 0) await rig.ticks(0);
    }
    // One report in flight; the page ran to K + 32 and froze there.
    const d = rig.engine.debug();
    const last = d.record.filter((e) => e.kind === "tick").at(-1).t;
    assert.equal(last, d.K + 32);
    rig.engine.intent({ kind: "letgo" });
    const letgo = rig.engine.debug().record.at(-1);
    assert.deepEqual([letgo.kind, letgo.h, letgo.t], ["human", "letgo", d.K + 33]);
    holdAnswers = false;
    while (held.length) { held.shift()(); await rig.settle(); }
    await rig.ticks(200);
    assert.deepEqual(differs(rig), []);
    assert.ok(rig.engine.debug().K > from + 33);
    assert.equal(rig.engine.debug().ticking, false, "released 80 ticks after the letgo, asleep");
  } finally {
    await server.stop();
  }
});

test("4: a reload after a kept trailing leash: the load's input line carries it, and the next reports are kept", async () => {
  const server = await scratchServer();
  try {
    const rig = await pageRig({ post: (p, t) => server.post(p, t) });
    await rig.load();
    await rig.ticks(8);
    const dog = middleDog(rig);
    rig.engine.intent({ kind: "grab", dogId: dog.id });
    await rig.ticks(1); // the report with the leash and its view goes, and is kept
    const trailing = reports(rig).at(-1);
    assert.match(trailing, new RegExp(`\\nleash (\\d+) ${dog.id}\\n`));
    assert.doesNotMatch(trailing, /\nt \d+ /);
    // A second page loads before the first ticks.
    const wire = recording(server);
    const fresh = await pageRig({ post: wire.post });
    await fresh.load();
    const loadAnswer = wire.answers[0].text;
    const k = Number(/\nkept (\d+)\n/.exec(loadAnswer)[1]);
    assert.match(loadAnswer, new RegExp(`\\nstate leash none drag none view 1280x800( \\d+,\\d+)* held( \\d+,\\d+)*\\ninput leash ${k + 1} ${dog.id}\\n`));
    assert.deepEqual(fresh.engine.view().leashed, { kind: "in_hand", dogId: dog.id });
    await fresh.ticks(120);
    const asked = wire.answers.filter((a) => a.path === "/report");
    assert.ok(asked.length >= 3);
    assert.ok(asked.every((a) => /^req \d+\nkept \d+\n/.test(a.text)), asked.map((a) => a.text).join("\n"));
    // Its first tick let go of the drag nobody holds: the letgo after the
    // leash, and the release 80 ticks on.
    assert.match(asked[0].sent, new RegExp(`\\nletgo ${k + 1}\\n`));
    assert.match(reports(fresh).join(""), new RegExp(`\\nrelease ${k + 81} ${dog.id}\\n`));
    // The first page is told it was taken over, and stops.
    await rig.ticks(10);
    assert.equal(rig.engine.view().status.kind, "stopped");
    assert.match(rig.engine.view().status.message, /newer page load/);
  } finally {
    await server.stop();
  }
});

test("12 and 13: a small display and a large one, fed the same inputs, write the same checked lines", async () => {
  const lines = [];
  let dogId = "none";
  for (const screen of [{ width: 640, height: 400 }, { width: 2560, height: 1440 }]) {
    const server = await scratchServer();
    try {
      const rig = await pageRig({ post: (p, t) => server.post(p, t), screen, at: { parkX: 16000 - screen.width / 2, parkY: 16000 - screen.height / 2 } });
      await rig.load();
      await rig.ticks(10);
      // The small screen's middle dog, the screen centred on it (out of the
      // edge bands, whose displacements are inputs too), its region mostly
      // off that screen.
      if (dogId === "none") dogId = middleDog(rig).id;
      const d = rig.engine.view().dogs.get(dogId);
      rig.engine.intent({ kind: "pan", parkX: d.parkX - screen.width / 2, parkY: d.parkY - screen.height / 2 });
      await rig.ticks(10);
      // The same recorded inputs on both (docs/PHYSICS.md, test 13: a real
      // pointer would land on other ticks while the small one is frozen):
      // one displacement a tick run, whenever that tick runs.
      rig.engine.intent({ kind: "grab", dogId });
      for (let given = 0; given < 30;) {
        const before = rig.engine.view().tick;
        if (given === 0 || before > rig.lastGiven) {
          rig.engine.intent({ kind: "drag", dogId, dx: -4, dy: 2.5 });
          rig.lastGiven = before;
          given++;
        }
        await rig.ticks(1);
      }
      while (rig.engine.view().tick <= rig.lastGiven) await rig.ticks(1);
      rig.engine.intent({ kind: "letgo" });
      await rig.ticks(110);
      assert.deepEqual(differs(rig), []);
      // The small one froze for the region's tiles: its leash went with no
      // tick; the large one had them all and ticked at once.
      const leashReport = reports(rig).find((r) => /\nleash \d+ /.test(r));
      if (screen.width === 640) assert.doesNotMatch(leashReport, /\nt \d+ /);
      else assert.match(leashReport, /\nt 1 /);
      lines.push(checkedLines(reports(rig)));
    } finally {
      await server.stop();
    }
  }
  assert.ok(lines[0].length > 30);
  assert.deepEqual(lines[1], lines[0]);
});

test("the server serves the wasm the page runs, under its hash, cached for good; the page names it", async () => {
  const server = await scratchServer();
  try {
    const page = await server.get("/");
    const hash = /<meta name="dogpark-physics" content="([0-9a-f]{8})">/.exec(page.body.toString())[1];
    const wasm = await server.get(`/physics-${hash}.wasm`);
    assert.equal(wasm.status, 200);
    assert.equal(wasm.headers.get("content-type"), "application/wasm");
    assert.match(wasm.headers.get("cache-control"), /immutable/);
    assert.ok(wasm.body.equals(wasmBytes()), "the very bytes zig build made");
    assert.equal((await server.get("/physics-00000000.wasm")).status, 404);
    const rig = await pageRig({ post: (p, t) => server.post(p, t) });
    assert.equal(rig.physics.hash, hash);
  } finally {
    await server.stop();
  }
});
