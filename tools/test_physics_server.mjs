// The physics protocol on the wire (docs/PHYSICS.md): a scratch play server
// (tools/lib/scratch_server.mjs), then POST /load and POST /report as a
// page sends them.
//
//     zig build check      (or: zig build && node tools/test_physics_server.mjs)
//
// The protocol's logic is tested in Zig (src/play/physics_server_test.zig);
// this is what only a real host shows: the routes, their content type, the
// 64 KiB cap's 413, a resend's bytes, a restart's new epoch. The round
// trip's time is tools/bench_page.mjs's.

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { scratchServer } from "./lib/scratch_server.mjs";

const server = await scratchServer();
// Stopped however the run ends, a --test-name-pattern run included.
after(() => server.stop());
const post = (path, body) => server.post(path, body);

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

test("a second load takes over; a restart issues a new epoch, and the old page is told reload epoch", async () => {
  const second = await post("/load", `dogpark 1 physics ${hash} load 640x480\n`);
  assert.match(second.text, /^epoch \d+\.2\n/);
  assert.equal((await post("/report", header(3) + "held 1\n")).text, "req 3\ntaken over\n");
  const newest = second.text.match(/^epoch (\S+)\n/)[1];
  // The first start seeded from the first layout and wrote no seed files;
  // an older server's, left in the data dir, are ignored, and said so.
  assert.deepEqual(readdirSync(join(server.dir, "data")).filter((f) => f.endsWith(".json")), []);
  assert.doesNotMatch(server.log(), /dogs\.json/);
  writeFileSync(join(server.dir, "data", "dogs.json"), "not the dogs");
  writeFileSync(join(server.dir, "data", "cows.json"), "not the cows");
  await server.restart();
  const old = `dogpark 1 physics ${hash} page ${newest} req 1\nfrom 0\n`;
  assert.equal((await post("/report", old)).text, "req 1\nreload epoch\n");
  // The new run's log is made by its first entry: this load's.
  assert.match((await post("/load", `dogpark 1 physics ${hash} load 640x480\n`)).text, /^epoch \d+\.1\n/);
  const files = readdirSync(join(server.dir, "data", "physics")).sort();
  assert.equal(files.filter((f) => f.startsWith("log-")).length, 2, files.join(" "));
  assert.ok(files.includes("snapshot"));
  assert.match(server.log(), /the physics' board came back from its snapshot and \d+ log entries/);
  assert.match(server.log(), /an older server's dogs\.json or cows\.json is in .*: ignored/);
});
