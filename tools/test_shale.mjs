// The operator's Shale route (src/play/shale.zig, metal-vmm QUEUE 214) on
// a real host: a scratch play server (tools/lib/scratch_server.mjs), its
// auth folder given a key, and signed scripts sent with the admin bearer.
//
//     zig build && node tools/test_shale.mjs
//
// The envelope, its signature, its sequence and the background run are
// shale's (script_route.zig) and tested there; this is what only Dog
// Park shows: the admin key first, atomic off, the cookbook (tools/shale/)
// on the files a real game writes, and play going on while a scan runs.

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import net from "node:net";
import { scratchServer, root } from "./lib/scratch_server.mjs";

const server = await scratchServer();
after(() => server.stop());
const auth = join(server.dir, "auth");
const data = join(server.dir, "data");
const admin = readFileSync(join(auth, "_admin_key"), "utf8").trim();
const target = "dogpark.test";

/** A key pair, its public half as the route's config writes it. */
function keyPair() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const hex = Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url").toString("hex");
  return { privateKey, hex };
}

const key = keyPair();
// **SET BY HAND**, as the README says: the config, and the sequence beside it.
mkdirSync(join(auth, "shale"), { recursive: true });
writeFileSync(join(auth, "shale.conf"), `public_key = ${key.hex}\ntarget = ${target}\n`);
writeFileSync(join(auth, "shale", "sequence"), "0\n");

let sequence = 0;
/** A signed envelope (script_route.zig's format): the next number, unless one is given. */
function envelope(source, { mode = "background", by = key, seq } = {}) {
  const n = seq ?? ++sequence;
  const expires = Math.floor(Date.now() / 1000) + 600;
  const header = `shale-1 target=${target} sequence=${n} expires=${expires}${mode === "atomic" ? "" : ` mode=${mode}`}\n`;
  const signed = header + source;
  const sig = sign(null, Buffer.from(signed), by.privateKey).toString("hex");
  return `shale-signature ${sig}\n${signed}`;
}

const send = (body) => server.bearer(admin, "POST", "/admin/script", body);
const status = () => server.bearer(admin, "GET", "/admin/script");

/** The background run's status once it has ended (it is stepped between requests). */
async function ended() {
  const deadline = Date.now() + 20_000;
  for (;;) {
    const s = await status();
    if (!/ running: /.test(s.text)) return s.text;
    if (Date.now() > deadline) throw new Error(`still running:\n${s.text}`);
    await new Promise((r) => setTimeout(r, 20));
  }
}

const cookbook = (name) => readFileSync(join(root, "tools/shale", name), "utf8");

test("the admin key comes first: no bearer, no script", async () => {
  const r = await server.as(undefined, "POST", "/admin/script", envelope('print("hi")\n'));
  assert.equal(r.status, 403);
  sequence--; // never seen by the route
});

test("a stranger's script is never read: refused from its head, before its body comes", async () => {
  // Its head alone, a 60 KiB body promised and never sent: a host that read
  // a body before checking its sender would wait for it (the box's cold
  // review of 214, finding 4).
  const answer = await new Promise((resolve, reject) => {
    const c = net.connect(server.port, "127.0.0.1");
    let got = "";
    const timer = setTimeout(() => { c.destroy(); resolve(`no answer in 2 s; got ${JSON.stringify(got)}`); }, 2000);
    c.on("data", (d) => { got += d; if (got.includes("\r\n\r\n")) { clearTimeout(timer); c.destroy(); resolve(got); } });
    c.on("error", reject);
    c.write(`POST /admin/script HTTP/1.1\r\nHost: x\r\nContent-Length: ${60 * 1024}\r\n\r\n`);
  });
  assert.match(answer, /^HTTP\/1\.1 4\d\d /);
});

test("an unsigned, a wrongly signed or a replayed script is refused; an atomic one is off", async () => {
  const unsigned = await send(`shale-signature ${"0".repeat(128)}\n${envelope('print("hi")\n').split("\n").slice(1).join("\n")}`);
  assert.equal(unsigned.status, 403);
  assert.match(unsigned.text, /bad_signature/);
  const other = await send(envelope('print("hi")\n', { by: keyPair() }));
  assert.equal(other.status, 403);
  assert.match(other.text, /bad_signature/);
  const body = envelope('print("hi")\n');
  assert.equal((await send(body)).status, 202);
  assert.match(await ended(), /finished/);
  const again = await send(body);
  assert.equal(again.status, 409);
  assert.match(again.text, /replayed/);
  const atomic = await send(envelope('print("hi")\n', { mode: "atomic" }));
  assert.equal(atomic.status, 403);
  assert.match(atomic.text, /atomic_off/);
});

test("a background script cannot write: it stops naming atomic, and the file is there", async () => {
  const r = await send(envelope('remove("players")\n'));
  assert.equal(r.status, 202);
  const s = await ended();
  assert.match(s, /stopped/);
  assert.match(s, /`atomic`/);
  assert.equal(readFileSync(join(data, "players"), "utf8"), "1\n");
});

test("the cookbook on the files a real game writes", async () => {
  // A load starts the game (its folder, its first log, its snapshot); two
  // reports the server cannot read are two `req ?` findings in its log.
  const wrong = await server.post("/load", "dogpark 2 physics 00000000 load 1280x800\n");
  const hash = wrong.text.match(/^reload physics ([0-9a-f]{8})\n$/)[1];
  assert.equal((await server.post("/load", `dogpark 2 physics ${hash} load 1280x800\n`)).status, 200);
  assert.equal((await server.post("/report", "hello\n")).text, "req ?\n");
  assert.equal((await server.post("/report", "hello again\n")).text, "req ?\n");

  assert.equal((await send(envelope(cookbook("accounts.shale")))).status, 202);
  assert.equal((await ended()).split("\n").slice(1).join("\n"), "accounts 1 of 80, 79 left\ngames started 1, accounts that never played 0\n");

  assert.equal((await send(envelope(cookbook("games.shale")))).status, 202);
  const games = await ended();
  assert.match(games, /\n1 games\ngame +kept +last_log +last_log_size +logs +bytes\ngame-0 +0 +\d{4}-\d\d-\d\dT[\d:]+Z +[\d.]+ (B|KiB) +1 +[\d.]+ (B|KiB)\n$/);

  assert.equal((await send(envelope(cookbook("trouble.shale")))).status, 202);
  const trouble = await ended();
  assert.match(trouble, /\n1 games, the last hour\ngame +logs +reports +differs +unreadable +overlaps +idle_drags +stuck +refused\ngame-0 +1 +0 +0 +2 +0 +0 +0 +0\n$/);
});

test("play goes on while a scan of every game's logs runs: the worst wait a report saw", async () => {
  // Five more games' hours of logs, as the server frames them: 1 MiB logs of
  // reports, a finding in each (a scan's worst: everything read).
  const report = "entry report 60\ndogpark 2 physics 00000000 page 1.1 req 1\nfrom 0\nheld 1\nend\n";
  const finding = "entry finding 26\nreq ? number 1 at kept 0\nend\n";
  const differ = "entry finding 24\nreq 1 differ at tick 9\nend\n";
  const log = finding + differ + report.repeat(Math.floor((1 << 20) / report.length));
  const start = Date.now() - 30 * 60_000;
  for (let g = 1; g <= 5; g++) {
    const dir = join(data, `game-${g}`, "physics");
    mkdirSync(dir, { recursive: true });
    for (let i = 0; i < 10; i++) writeFileSync(join(dir, `log-${start + i * 60_000}`), log);
  }
  assert.equal((await send(envelope(cookbook("trouble.shale")))).status, 202);
  // A player's reports, one after another, while it runs; every request
  // timed, the status asked between them too (a host that held the turn
  // for the whole scan made whichever came next wait it out).
  let worst = 0;
  let reports = 0;
  const timed = async (f) => {
    const began = performance.now();
    const r = await f();
    worst = Math.max(worst, performance.now() - began);
    return r;
  };
  for (;;) {
    const r = await timed(() => server.post("/report", "hello\n"));
    reports++;
    assert.equal(r.text, "req ?\n");
    if (!/ running: /.test((await timed(status)).text)) break;
  }
  const done = await ended();
  assert.match(done, /game-5 +10 +\d+ +10 +10 +0 +0 +0 +0\n$/);
  console.log(`# a scan of 50 MiB of logs ran beside ${reports} reports; the worst wait a request saw: ${worst.toFixed(1)} ms`);
  // A slice, and the request's own time: never the scan's.
  assert.ok(worst < 250, `a request waited ${worst} ms`);
});
