// The page's cows agree with the server's: the play server (zig-out/bin/
// dog-park-play) is started in a scratch folder, a dog is dragged about at
// random near the cows, and before each batch of moves the page's
// prediction (zig-out/web/cows.wasm, replaying each move's path segment by
// segment from where the server last said the cows are, as park.js's
// predictCows does) must equal where the server's acks then put them,
// exactly. A batch is one to three moves, as a page sends them when one is
// in flight and more wait; a move is a path of 1 to 12 points.
//
//   zig build && node tools/test_cows_agree.mjs
import { spawn } from "node:child_process";
import { mkdtempSync, mkdirSync, cpSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "node:net";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const moves_wanted = 3000;

function freePort() {
  return new Promise((resolve) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => { const { port } = s.address(); s.close(() => resolve(port)); });
  });
}

// A seeded generator (mulberry32), so a failure replays.
function seeded(seed) {
  return () => {
    seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const work = mkdtempSync(join(tmpdir(), "cows-agree-"));
cpSync(join(root, "solo"), join(work, "solo"), { recursive: true });
mkdirSync(join(work, "data"));
mkdirSync(join(work, "auth"));
const port = await freePort();
// No DOGPARK_CONFIG: its data/ and auth/ in the scratch folder.
const env = { ...process.env, DOGPARK_PORT: String(port) };
delete env.DOGPARK_CONFIG;
const server = spawn(join(root, "zig-out/bin/dog-park-play"), [], { cwd: work, env, stdio: ["ignore", "ignore", "inherit"] });
const base = `http://127.0.0.1:${port}`;
let failed = 0;
try {
  for (let i = 0; ; i++) {
    try { await fetch(`${base}/park.js`); break; } catch { if (i > 200) throw new Error("the server never listened"); }
    await new Promise((r) => setTimeout(r, 25));
  }
  const me = await fetch(`${base}/me`);
  const cookie = me.headers.get("set-cookie").split(";")[0];
  const post = async (path, body) => {
    const r = await fetch(`${base}${path}`, { method: "POST", headers: { cookie, "content-type": "application/json" }, body: JSON.stringify(body) });
    if (!r.ok) throw new Error(`${path}: ${r.status} ${await r.text()}`);
    return r.json();
  };
  // The 5 x 5 tiles at the world's corner: 13 cows, and dog 0.
  const tiles = [];
  for (let row = 0; row < 5; row++) for (let col = 0; col < 5; col++) tiles.push({ col, row, is: "new" });
  const seen = await post("/tiles", { tiles });
  const serverCows = new Map(seen.cows.map((c) => [c.id, { parkX: c.park_x, parkY: c.park_y }]));
  const dog0 = seen.dogs.find((d) => d.id === 0);
  let serverDog = { parkX: dog0.park_x, parkY: dog0.park_y };

  const { instance } = await WebAssembly.instantiate(readFileSync(join(root, "zig-out/web/cows.wasm")));
  const rule = instance.exports;
  const predict = (from, paths) => {
    const ids = [...serverCows.keys()];
    const at = new Int32Array(rule.memory.buffer, rule.cowPositions(), 2 * ids.length);
    ids.forEach((id, i) => { at[2 * i] = serverCows.get(id).parkX; at[2 * i + 1] = serverCows.get(id).parkY; });
    let was = from;
    for (const to of paths.flat()) {
      if (was.parkX !== to.parkX || was.parkY !== to.parkY) rule.react(ids.length, was.parkX, was.parkY, to.parkX, to.parkY);
      was = to;
    }
    return new Map(ids.map((id, i) => [id, { parkX: at[2 * i], parkY: at[2 * i + 1] }]));
  };

  const random = seeded(20261013);
  const cowIds = [...serverCows.keys()];
  let done = 0;
  let scared = 0;
  let target = serverCows.get(cowIds[0]);
  while (done < moves_wanted) {
    // Head for a cow, wobbling, 1 to 40 px a move; now and then a new cow.
    if (random() < 0.05) target = serverCows.get(cowIds[Math.floor(random() * cowIds.length)]);
    // Frames: 1 to 15 px each, a path of 1 to 12 of them a move.
    const batch = [];
    let at = serverDog;
    for (let k = 1 + Math.floor(random() * 3); k > 0; k--) {
      const path = [];
      for (let n = 1 + Math.floor(random() * 12); n > 0; n--) {
        const dx = target.parkX - at.parkX, dy = target.parkY - at.parkY, len = Math.hypot(dx, dy) || 1;
        const step = 1 + random() * 14;
        const wobble = (random() - 0.5) * 12;
        at = {
          parkX: Math.min(2499, Math.max(0, Math.round(at.parkX + (dx / len) * step + wobble))),
          parkY: Math.min(2499, Math.max(0, Math.round(at.parkY + (dy / len) * step - wobble))),
        };
        path.push(at);
      }
      batch.push(path);
    }
    const predicted = predict(serverDog, batch);
    for (const path of batch) {
      const ack = await post("/move", { dog: 0, path: path.map((p) => [p.parkX, p.parkY]) });
      for (const c of ack.cows) { serverCows.set(c.id, { parkX: c.park_x, parkY: c.park_y }); scared++; }
      serverDog = path[path.length - 1];
      done++;
    }
    for (const [id, p] of predicted) {
      const s = serverCows.get(id);
      if (s.parkX !== p.parkX || s.parkY !== p.parkY) {
        failed++;
        if (failed <= 5) console.log(`FAIL move ${done}: cow ${id} predicted (${p.parkX}, ${p.parkY}), the server put it at (${s.parkX}, ${s.parkY})`);
      }
    }
  }
  console.log(`${failed ? "FAIL" : "PASS"} cows agree: ${done} moves, ${scared} cow steps, ${failed} predictions the server did not make`);
} finally {
  server.kill();
  rmSync(work, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
