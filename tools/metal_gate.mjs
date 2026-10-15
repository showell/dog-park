// **THE QEMU GATE** (`zig build metal-gate`, metal-vmm QUEUE 215(c)): Dog
// Park as the metal kernel serves it, zig-out/bin/dogpark.elf booted under
// QEMU on a fresh scratch disk, one short session through the real page
// code, then a reboot on the same disk. Run it LAST, before a Dog Park
// deploy, never out of habit (README, "The QEMU gate").
//
//     zig build metal-gate --summary all     (the build's and the run's times apart)
//
// It judges logic, not speed: QEMU's user network (slirp), one boot disk
// holding solo/, auth/ and the data, no volume, no zig-metal-unikernel.conf
// (the kernel's defaults: the public card, serve until stopped).
//
// **FAIL LOUDLY**: an unexpected status, a report not kept, a finding on
// /admin/game, or an error line in the guest's serial log stops the gate
// with the step that failed and the log's tail; the exit code is the verdict.
//
// **THE DISK IS BUILT HERE**, with the tools zig-metal-unikernel's
// probe/judge_gopher.py uses (sgdisk, mkfs.vfat, mtools; no root), not by
// importing it: that module is gopher's judge (it reads angry-gopher's
// assets.zon at import, and its disk defaults to FAT32 for chat's volume),
// and the kernel has no general disk builder yet.

import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, cpSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { root } from "./lib/scratch_server.mjs";
import { pageRig, letGoTicks } from "./lib/page_rig.mjs";
import { bootGuest } from "./lib/metal_guest.mjs";

const elf = join(root, "zig-out/bin/dogpark.elf");
const wasm = join(root, "zig-out/web/physics.wasm");
const PART_FIRST = 2048; // the partition's first sector, as judge_gopher.py's
const SECTOR = 512;
const MTOOLS_ENV = { ...process.env, TZ: "UTC", MTOOLS_SKIP_CHECK: "1" };
/** How long a boot may take to say it is listening. */
const boot_deadline_ms = 30_000;
const admin_key = "d06fa4c0".repeat(8);
const cookie_name = "__Host-dogpark";

const scratch = mkdtempSync(join(tmpdir(), "dogpark-metal-gate-"));
const image = join(scratch, "disk.img");
const times = [];
let step = "start";

const ms = (t0) => Math.round(performance.now() - t0);
function fail(why) {
  throw new Error(why);
}
function expect(cond, why) {
  if (!cond) fail(why);
}

// ── the disk ────────────────────────────────────────────────────────────────

const mt = (...args) => execFileSync(args[0], args.slice(1), { env: MTOOLS_ENV, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
const at = () => `${image}@@${PART_FIRST * SECTOR}`;

/** A 64 MiB GPT disk, partition 1 FAT16, holding solo/ and auth/_admin_key. */
function buildDisk() {
  const content = join(scratch, "content");
  mkdirSync(join(content, "auth"), { recursive: true });
  cpSync(join(root, "solo"), join(content, "solo"), { recursive: true });
  writeFileSync(join(content, "auth", "_admin_key"), admin_key);
  writeFileSync(image, "");
  execFileSync("truncate", ["-s", String(64 << 20), image]);
  mt("sgdisk", "-o", "-n", `1:${PART_FIRST}:0`, "-t", "1:0700", "-c", "1:dogpark", image);
  const last = Number(/^Last sector: (\d+)/m.exec(mt("sgdisk", "-i", "1", image))[1]);
  mt("mkfs.vfat", "-F", "16", "-S", String(SECTOR), "-n", "DOGPARK", "--offset", String(PART_FIRST), image, String((last - PART_FIRST + 1) >> 1));
  for (const entry of ["auth", "solo"]) mt("mcopy", "-s", "-m", "-o", "-D", "o", "-i", at(), join(content, entry), "::/");
}

/** fsck.fat -n on the partition (copied out: fsck takes no offset), a reader that is not the kernel's: a problem fails the gate. */
function fsck() {
  const part = join(scratch, "partition.img");
  execFileSync("dd", [`if=${image}`, `of=${part}`, `bs=${SECTOR}`, `skip=${PART_FIRST}`, "status=none"]);
  try {
    execFileSync("fsck.fat", ["-n", part], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  } catch (e) {
    fail(`fsck.fat finds the disk unclean (exit ${e.status}):\n${e.stdout}${e.stderr}`);
  } finally {
    rmSync(part, { force: true });
  }
}

/** The names in a folder of the disk (mdir -b), or [] when there is none. */
function diskNames(dir) {
  const out = mt("mdir", "-b", "-i", at(), `::/${dir}`);
  return out.split("\n").filter(Boolean).map((l) => l.replace(/^::\/.*\//, "").replace(/\/$/, ""));
}

// ── the machine (tools/lib/metal_guest.mjs) ─────────────────────────────────

let guest = null;

/** Boots the kernel on the scratch disk; resolves with its port once the serial log says it is listening. */
async function boot(n) {
  guest = null;
  guest = await bootGuest({
    serialPath: join(scratch, `serial-${n}.log`),
    deadlineMs: boot_deadline_ms,
    launch: (port) => ({
      command: "qemu-system-x86_64",
      args: [
        // rtc=on: under KVM microvm leaves the CMOS clock out unless asked, and the kernel reads it.
        "-M", "microvm,rtc=on,pit=on", "-kernel", elf, "-enable-kvm",
        "-nographic", "-no-reboot", "-m", "512",
        "-global", "virtio-mmio.force-legacy=false",
        "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
        // cache=unsafe: a guest flush is not a sync of the box's disk; the bytes still reach the file.
        "-drive", `id=d,file=${image},format=raw,if=none,cache=unsafe`,
        "-device", "virtio-blk-device,drive=d",
        "-cpu", "max", "-device", "virtio-rng-device",
        "-netdev", `user,id=n0,hostfwd=tcp:127.0.0.1:${port}-:80`,
        "-device", "virtio-net-device,netdev=n0",
      ],
    }),
  });
  return guest.port;
}

async function stopQemu() {
  if (guest) await guest.stop();
}

const request = (_port, method, path, opts) => guest.request(method, path, opts);
const checkSerial = () => guest.checkSerial();

function status(r, want, what) {
  expect(r.status === want, `${what}: ${r.status}, want ${want}\n${r.text.slice(0, 400)}`);
}

// ── the session ─────────────────────────────────────────────────────────────

const loadLine = (hash) => `dogpark 1 physics ${hash} load 1280x800\n`;

/** The page (tools/lib/page_rig.mjs) wired to the guest: every answer recorded. */
async function pageOn(port, cookie) {
  const answers = [];
  const rig = await pageRig({
    post: async (path, text) => {
      const r = await request(port, "POST", path, { body: text, cookie });
      answers.push({ path, status: r.status, text: r.text });
      return { status: r.status, text: r.text };
    },
  });
  return { rig, answers };
}

/** Every answer 200; every report's `kept`, never a `differ`; no warning from the page. */
function allKept({ rig, answers }, what) {
  for (const a of answers) {
    expect(a.status === 200, `${what}: ${a.path} answered ${a.status}: ${a.text.slice(0, 200)}`);
    expect(!/\ndiffer /.test(a.text), `${what}: a differ:\n${a.text.slice(0, 400)}`);
    if (a.path === "/report") expect(/^req \d+\nkept \d+\n/.test(a.text), `${what}: a report not kept:\n${a.text.slice(0, 400)}`);
  }
  expect(rig.warnings().length === 0, `${what}: the page warned: ${rig.warnings().join("; ")}`);
  expect(answers.some((a) => a.path === "/report"), `${what}: no report went`);
}

// The dog nearest the view's middle.
function middleDog(rig) {
  const v = rig.engine.view();
  const cx = v.viewport.parkX + v.viewport.width / 2;
  const cy = v.viewport.parkY + v.viewport.height / 2;
  return [...v.dogs.values()].sort((a, b) => Math.hypot(a.parkX - cx, a.parkY - cy) - Math.hypot(b.parkX - cx, b.parkY - cy))[0];
}

/** A leash on the middle dog, a short drag, the let-go, then frames until the leash is off and every tick is kept. */
async function leashAndDrag(rig, dragTicks) {
  await rig.ticks(4);
  const dog = middleDog(rig);
  expect(dog, "no dog in view to leash");
  rig.engine.intent({ kind: "grab", dogId: dog.id });
  for (let i = 0; i < dragTicks; i++) {
    rig.engine.intent({ kind: "drag", dogId: dog.id, dx: 3, dy: 1 });
    await rig.ticks(1);
  }
  rig.engine.intent({ kind: "letgo" });
  const cap = letGoTicks() + 60;
  for (let n = 0; n < cap && rig.engine.debug().ticking; n++) await rig.ticks(1);
  for (let n = 0; n < 60 && (rig.engine.debug().cursor > 0 || rig.engine.debug().inFlight !== "none"); n++) await rig.ticks(1);
  const d = rig.engine.debug();
  expect(!d.ticking && d.cursor === 0, `the drag never settled: ticking ${d.ticking}, ${d.cursor} ticks unreported`);
  expect(/\nleash \d+ \d+\n/.test(rig.sent.map((s) => s.text).join("")), "no report carried the leash");
  return d.K;
}

/** /admin/game by the bearer: 200, `claimed` accounts, the game's row, no finding; without the key, 403. */
async function adminGame(port, claimed, keptTick) {
  const page = await request(port, "GET", "/admin/game", { headers: { authorization: `Bearer ${admin_key}` } });
  status(page, 200, "/admin/game with the bearer");
  expect(page.text.includes(`<p>${claimed} of 80 accounts handed out;`), `/admin/game doesn't say ${claimed} of 80 accounts:\n${page.text.slice(0, 600)}`);
  const games = page.text.slice(page.text.indexOf("<h2>The games</h2>"));
  const row = /<tr><td>0<\/td>(.*?)<\/tr>/.exec(games);
  expect(row, `/admin/game has no row for account 0:\n${page.text.slice(0, 1200)}`);
  const cells = [...row[1].matchAll(/<td[^>]*>(.*?)<\/td>/g)].map((m) => m[1]);
  // account, last request, leash, kept tick, epoch, herd, poops, logs, findings: the row less its first cell.
  expect(Number(cells[2]) === keptTick, `/admin/game's kept tick ${cells[2]}, the page's ${keptTick}`);
  expect(/^0 overlaps, 0 idle drags, 0 unreadable, 0 trips$/.test(cells[7]), `/admin/game finds: ${cells[7]}`);
  expect(!/class="bad"/.test(page.text), `/admin/game marks something bad:\n${row[0]}`);
  status(await request(port, "GET", "/admin/game"), 403, "/admin/game without the key");
  status(await request(port, "GET", "/admin/game", { headers: { authorization: `Bearer ${"0".repeat(64)}` } }), 403, "/admin/game with a wrong key");
}

/** The physics logs' start times (log-<ms>) on the disk, ascending. */
function logStarts() {
  return diskNames("data/game-0/physics").map((n) => /^log-(\d+)$/.exec(n)).filter(Boolean).map((m) => Number(m[1])).sort((a, b) => a - b);
}

async function gate() {
  const all = performance.now();
  const wasmBytes = readFileSync(wasm);

  step = "the scratch disk";
  let t = performance.now();
  buildDisk();
  times.push(["disk", ms(t)]);

  step = "boot 1";
  t = performance.now();
  const before1 = Date.now();
  let port = await boot(1);
  times.push(["boot 1", ms(t)]);

  t = performance.now();
  step = "GET /";
  const landing = await request(port, "GET", "/");
  status(landing, 200, "GET /");
  expect(/Begin Game/.test(landing.text) && /<form method="post" action="\/begin">/.test(landing.text), "the landing page has no Begin Game form");

  step = "POST /begin";
  const begun = await request(port, "POST", "/begin", { body: "" });
  status(begun, 303, "POST /begin");
  expect(begun.headers.location === "/dogpark", `POST /begin goes to ${begun.headers.location}`);
  const set = begun.headers["set-cookie"]?.[0] ?? "";
  expect(set.startsWith(`${cookie_name}=`), `the cookie is not ${cookie_name}: ${set}`);
  expect(/; Secure(;|$)/.test(set) && /; HttpOnly(;|$)/.test(set) && /; Path=\/(;|$)/.test(set), `the cookie is not Secure, HttpOnly, Path=/: ${set}`);
  // Sent back over http by hand: the guest can't tell, a browser would only over HTTPS.
  const cookie = set.split(";")[0];

  step = "GET /dogpark and the wasm";
  status(await request(port, "GET", "/dogpark"), 303, "GET /dogpark without the cookie");
  const game = await request(port, "GET", "/dogpark", { cookie });
  status(game, 200, "GET /dogpark");
  const hash = /dogpark-physics" content="([0-9a-f]{8})"/.exec(game.text)?.[1];
  expect(hash, "/dogpark names no physics hash");
  const served = await request(port, "GET", `/physics-${hash}.wasm`);
  status(served, 200, `GET /physics-${hash}.wasm`);
  expect(served.headers["content-type"] === "application/wasm", `the wasm's content-type: ${served.headers["content-type"]}`);
  expect(Buffer.compare(served.body, wasmBytes) === 0, `the served wasm (${served.body.length} bytes) is not zig-out/web/physics.wasm (${wasmBytes.length})`);
  status(await request(port, "GET", "/park.js"), 200, "GET /park.js");

  step = "a load, a leash and a drag";
  const page = await pageOn(port, cookie);
  await page.rig.load();
  const kept = await leashAndDrag(page.rig, 12);
  allKept(page, step);
  expect(kept > 0, `the game kept tick ${kept}`);

  step = "/admin/game";
  await adminGame(port, 1, kept);
  await checkSerial();
  times.push(["session 1", ms(t)]);

  step = "stop 1";
  await stopQemu();
  const after1 = Date.now();
  fsck();
  const logs1 = logStarts();
  expect(logs1.length === 1, `boot 1 left ${logs1.length} logs: ${logs1}`);
  expect(logs1[0] >= before1 - 2000 && logs1[0] <= after1 + 2000, `boot 1's log-${logs1[0]} is not in the run's wall-clock window ${before1}..${after1} (the guest's clock)`);

  step = "boot 2, the same disk";
  t = performance.now();
  const before2 = Date.now();
  port = await boot(2);
  times.push(["boot 2", ms(t)]);
  t = performance.now();

  step = "the cookie after the reboot";
  status(await request(port, "GET", "/dogpark", { cookie }), 200, "GET /dogpark with boot 1's cookie");

  step = "a load after the reboot";
  const again = await pageOn(port, cookie);
  await again.rig.load();
  const load = again.answers.find((a) => a.path === "/load");
  expect(load && load.status === 200, `the load: ${load?.status}`);
  const loadKept = Number(/\nkept (\d+)\n/.exec(load.text)?.[1]);
  expect(loadKept === kept, `the load after the reboot answers kept ${loadKept}, the game had kept ${kept}`);

  step = "a drag after the reboot";
  const kept2 = await leashAndDrag(again.rig, 6);
  allKept(again, step);
  expect(kept2 > kept, `kept ${kept2} after the second drag, not past ${kept}`);
  await adminGame(port, 1, kept2);
  await checkSerial();
  times.push(["session 2", ms(t)]);

  step = "stop 2 and the logs' names";
  await stopQemu();
  const after2 = Date.now();
  fsck();
  const logs2 = logStarts();
  expect(logs2.length >= 2 && logs2.includes(logs1[0]), `after boot 2 the logs are ${logs2}, boot 1's log-${logs1[0]} gone`);
  const newest = logs2.at(-1);
  expect(newest > logs1[0], `boot 2's log-${newest} is not after boot 1's log-${logs1[0]}`);
  expect(newest >= before2 - 2000 && newest <= after2 + 2000, `boot 2's log-${newest} is not in its wall-clock window ${before2}..${after2} (the guest's clock)`);

  times.push(["total", ms(all)]);
}

try {
  await gate();
  console.log(`metal-gate PASS: ${times.map(([k, v]) => `${k} ${(v / 1000).toFixed(1)} s`).join(", ")}`);
  rmSync(scratch, { recursive: true, force: true });
} catch (e) {
  await stopQemu().catch(() => {});
  console.error(`metal-gate FAIL: step "${step}": ${e.message}`);
  if (guest) console.error(`\nthe guest's log (${guest.serialPath}), its tail:\n${guest.tail()}`);
  console.error(`\nthe scratch disk and logs are kept: ${scratch}`);
  process.exitCode = 1;
}
