// How long the page's physics takes, in the wasm under node (V8, as a
// browser runs it): one tick, and a 32-tick replay as a rewind runs it,
// with the park's middle dog leashed and dragged among its neighbours.
// The board comes from a scratch server (tools/lib/scratch_server.mjs).
// And a small report's round trip through the host: 50 POSTs to a scratch
// server of its own.
//
//     zig build && node tools/bench_page.mjs

import { scratchServer } from "./lib/scratch_server.mjs";
import { pageRig } from "./lib/page_rig.mjs";
import { LIVE, SCRATCH } from "../solo/physics.js";

const server = await scratchServer();
try {
  const rig = await pageRig({ post: (p, t) => server.post(p, t) });
  await rig.load();
  await rig.ticks(8);
  const v = rig.engine.view();
  const dog = [...v.dogs.values()].sort((a, b) => Math.hypot(a.parkX - 16000, a.parkY - 16000) - Math.hypot(b.parkX - 16000, b.parkY - 16000))[0];
  rig.engine.intent({ kind: "grab", dogId: dog.id });
  await rig.ticks(4);
  const { physics } = rig;
  const drag = [[3 * 256, 256, 0]];
  const awake = physics.region(LIVE).length;
  // One tick: the same tick tried again and again on a copy of the live board.
  const n = 5000;
  let t = performance.now();
  for (let i = 0; i < n; i++) {
    physics.copy(LIVE, SCRATCH);
    physics.tick(SCRATCH, 1000, drag);
  }
  const tickUs = ((performance.now() - t) / n) * 1000;
  t = performance.now();
  for (let i = 0; i < n; i++) physics.copy(LIVE, SCRATCH);
  const copyUs = ((performance.now() - t) / n) * 1000;
  // A replay: a board copied (as a rewind copies the kept one) and 32 ticks
  // run on it, the dog leashed.
  const m = 300;
  t = performance.now();
  for (let i = 0; i < m; i++) {
    physics.copy(LIVE, SCRATCH);
    for (let k = 1; k <= 32; k++) physics.tick(SCRATCH, 1000 + k, drag);
  }
  const replayMs = (performance.now() - t) / m;
  if (physics.leashed(SCRATCH) === "none") throw new Error("the replay's board has nothing leashed");
  const c = physics.critters(LIVE);
  console.log(`page tick: ${(tickUs - copyUs).toFixed(1)} us (a board copy ${copyUs.toFixed(1)} us besides); a 32-tick replay: ${replayMs.toFixed(2)} ms; ${c.dogs.length} dogs and ${c.cows.length} cows on the board, the region ${awake} tiles`);
} finally {
  await server.stop();
}

// A small report's round trip through the host: a load, a view, then 50
// reports holding one tile, each answered `kept 0`.
const host = await scratchServer();
try {
  const hash = /^reload physics ([0-9a-f]{8})\n$/.exec((await host.post("/load", "dogpark 1 physics 00000000 load 1280x800\n")).text)[1];
  const epoch = /^epoch (\S+)\n/.exec((await host.post("/load", `dogpark 1 physics ${hash} load 1280x800\n`)).text)[1];
  const header = (req) => `dogpark 1 physics ${hash} page ${epoch} req ${req}\nfrom 0\n`;
  await host.post("/report", header(1) + "view 1 1280x800 27,27\n");
  const n = 50;
  const t = performance.now();
  for (let i = 0; i < n; i++) {
    const r = await host.post("/report", header(2 + i) + "held 1 27,27\n");
    if (r.text !== `req ${2 + i}\nkept 0\n`) throw new Error(`report ${2 + i}: ${r.text}`);
  }
  console.log(`a small report's round trip, through the host: ${((performance.now() - t) / n).toFixed(2)} ms`);
} finally {
  await host.stop();
}
