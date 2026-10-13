// The physics protocol on the wire (docs/PHYSICS.md): a scratch play server
// (zig-out/bin/dog-park-play, built by `zig build`) on a free port with a
// temporary data dir, spawned as one process and stopped by its PID; then
// POST /load and POST /report as a page sends them.
//
//     zig build && node tools/test_physics_server.mjs
//
// The protocol's logic is tested in Zig (src/play/physics_server_test.zig);
// this is what only a real host shows: the routes, their content type, the
// 64 KiB cap's 413, a resend's bytes, a restart's new epoch, and the time a
// small report's round trip takes.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const binary = join(root, "zig-out/bin/dog-park-play");

function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

/** Starts the scratch server; resolves once it answers. */
async function start(dir, port) {
  const child = spawn(binary, [], {
    cwd: root,
    env: { ...process.env, DOGPARK_PORT: String(port), DOGPARK_BIND: "127.0.0.1", DOGPARK_CONFIG: join(dir, "config") },
    stdio: ["ignore", "ignore", "pipe"],
  });
  let log = "";
  child.stderr.on("data", (d) => (log += d));
  for (let i = 0; i < 100; i++) {
    if (child.exitCode !== null) throw new Error(`the server stopped:\n${log}`);
    try {
      await fetch(`http://127.0.0.1:${port}/`);
      return { child, log: () => log };
    } catch {
      await new Promise((r) => setTimeout(r, 50));
    }
  }
  child.kill();
  throw new Error(`the server never answered:\n${log}`);
}

async function stop(server) {
  if (server.child.exitCode !== null) return;
  const gone = new Promise((r) => server.child.once("exit", r));
  process.kill(server.child.pid, "SIGTERM");
  await gone;
}

const dir = mkdtempSync(join(tmpdir(), "dogpark-physics-"));
writeFileSync(join(dir, "config"), `data_dir=${join(dir, "data")}\nauth_dir=${join(dir, "auth")}\n`);
// The host's second root: webbox opens it; Dog Park keeps nothing there.
mkdirSync(join(dir, "auth"));
const port = await freePort();
const base = `http://127.0.0.1:${port}`;
let server = await start(dir, port);

async function post(path, body) {
  const r = await fetch(base + path, { method: "POST", body });
  return { status: r.status, type: r.headers.get("content-type"), text: await r.text() };
}

let hash;
let epoch;

test("a load: a new epoch, kept 0, nothing leashed, no tiles", async () => {
  // The hash: a load with a wrong one is told the server's.
  const wrong = await post("/load", "dogpark 1 physics 00000000 load 1280x800\n");
  hash = wrong.text.match(/^reload physics ([0-9a-f]{8})\n$/)[1];
  const a = await post("/load", `dogpark 1 physics ${hash} load 1280x800\n`);
  assert.equal(a.status, 200);
  assert.equal(a.type, "text/plain; charset=utf-8");
  const m = a.text.match(/^epoch (\d+)\.1\nkept 0\nstate leash none drag none view 1280x800 held\n$/);
  assert.ok(m, a.text);
  epoch = `${m[1]}.1`;
  assert.ok(Math.abs(Number(m[1]) - Date.now()) < 60_000, "the epoch is the run's start, Unix ms");
});

const header = (req) => `dogpark 1 physics ${hash} page ${epoch} req ${req}\nfrom 0\n`;

test("an unleashed pan: a view gets its tiles' critters; the resend gets the same bytes", async () => {
  const body = header(1) + "view 1 1280x800 27,27 26,27\n";
  const a = await post("/report", body);
  // The empty ground west of the park, then the park's corner tile: its
  // cows, then its dogs, by number (the layout is the Zig tests' to pin).
  const pos = "[0-9a-f]+\\.[0-9a-f]{2},[0-9a-f]+\\.[0-9a-f]{2}";
  assert.match(a.text, new RegExp(`^req 1\\nkept 0\\ntile 26,27\\ntile 27,27( cow \\d+ ${pos})+( dog \\d+ ${pos})+\\n$`));
  const again = await post("/report", body);
  assert.equal(again.text, a.text);
  const held = await post("/report", header(2) + "held 1 27,27 26,27\n");
  assert.equal(held.text, "req 2\nkept 0\n");
});

test("req ?, reload epoch, and a body past 64 KiB is a 413 (64 KiB itself is read)", async () => {
  assert.equal((await post("/report", "hello\n")).text, "req ?\n");
  assert.equal((await post("/report", `dogpark 1 physics ${hash} page 1.1 req 3\nfrom 0\n`)).text, "req 3\nreload epoch\n");
  assert.equal((await post("/report", "x".repeat(64 * 1024 + 1))).status, 413);
  const at = await post("/report", "x".repeat(64 * 1024));
  assert.equal(at.status, 200);
  assert.equal(at.text, "req ?\n");
});

test("a small report's round trip, through the host", async () => {
  const n = 50;
  const t = performance.now();
  for (let i = 0; i < n; i++) {
    const r = await post("/report", header(3 + i) + "held 1 27,27\n");
    assert.equal(r.text, `req ${3 + i}\nkept 0\n`);
  }
  const ms = (performance.now() - t) / n;
  console.log(`# a small report's round trip: ${ms.toFixed(2)} ms`);
});

test("a second load takes over; a restart issues a new epoch, and the old page is told reload epoch", async () => {
  const second = await post("/load", `dogpark 1 physics ${hash} load 640x480\n`);
  assert.match(second.text, /^epoch \d+\.2\n/);
  assert.equal((await post("/report", header(60) + "held 1\n")).text, "req 60\ntaken over\n");
  const newest = second.text.match(/^epoch (\S+)\n/)[1];
  await stop(server);
  server = await start(dir, port);
  const old = `dogpark 1 physics ${hash} page ${newest} req 1\nfrom 0\n`;
  assert.equal((await post("/report", old)).text, "req 1\nreload epoch\n");
  // The new run's log is made by its first entry: this load's.
  assert.match((await post("/load", `dogpark 1 physics ${hash} load 640x480\n`)).text, /^epoch \d+\.1\n/);
  const files = readdirSync(join(dir, "data", "physics")).sort();
  assert.equal(files.filter((f) => f.startsWith("log-")).length, 2, files.join(" "));
  assert.ok(files.includes("snapshot"));
  assert.match(server.log(), /the physics' board came back from its snapshot and \d+ log entries/);
});

test("stop the scratch server", async () => {
  await stop(server);
  rmSync(dir, { recursive: true, force: true });
});
