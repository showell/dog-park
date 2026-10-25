// **THE DROPLET REHEARSAL**: boots a boot image from droplet/image.mjs on
// zig-metal-unikernel's droplet/droplet.sh (QEMU laid out as a DigitalOcean
// droplet: its BIOS, the image's own loader, both network cards, the SCSI
// controller with no volume on it, 512 MB as the smallest droplet has), as
// that repo's droplet/rehearse.py boots chat's.
//
//     node droplet/rehearse.mjs <image.img>     (image.mjs runs it on every image)
//
// **THE IMAGE IS NEVER WRITTEN**: a copy boots, in a scratch folder, so the
// image deployed is the one that was built, never one a rehearsal wrote
// accounts into.
//
// **THE PRIVATE CARD, AS BUILT**: the image's conf says `card = private`, and
// nothing is overridden. droplet.sh forwards a box port to port 80 on its
// private card (PRIVATE_FWD), which is where every request goes, and another
// to the public card (PUBLIC_FWD), which must not answer.
//
// Checks: the boot says the data is on the boot disk, no volume attached,
// the private card, both disk checks clean; `GET /` with Begin Game; `POST
// /begin` sets a Secure, HttpOnly cookie; `/load` answers 200; `/admin/game`
// answers with ~/.dogpark_admin_key and refuses without it; the TODO list at
// /todo (its page, a list written and read back by its Secure cookie, a new
// visitor's empty); the public card answers nothing; no error line in the
// guest's log.

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import http from "node:http";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { bootGuest, freePort } from "../tools/lib/metal_guest.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dropletSh = resolve(root, "../zig-metal-unikernel/droplet/droplet.sh");
const cookie_name = "__Host-dogpark";
const boot_deadline_ms = 60_000;

/** True when the rehearsal passed; it says each step, and on a failure, the guest's log. */
export async function rehearse(image) {
  const t0 = performance.now();
  const scratch = mkdtempSync(join(tmpdir(), "dogpark-rehearse-"));
  const disk = join(scratch, "boot.img");
  let guest = null;
  let step = "copy the image";
  const expect = (cond, why) => { if (!cond) throw new Error(why); };
  try {
    execFileSync("cp", ["--sparse=always", image, disk]);
    const key = readFileSync(join(homedir(), ".dogpark_admin_key"), "utf8").trim();
    const publicPort = await freePort();

    step = "boot on the droplet's machine";
    guest = await bootGuest({
      serialPath: join(scratch, "serial.log"),
      deadlineMs: boot_deadline_ms,
      launch: (port) => ({
        command: dropletSh,
        args: [],
        env: { ...process.env, DISK: disk, PRIVATE_FWD: String(port), PUBLIC_FWD: String(publicPort), MEMORY: "512", NO_DOOR: "1" },
      }),
    });
    const booted = guest.serial();
    for (const said of ["  no volume attached\n", "  Dog Park's data: the boot disk\n", "  network: the private card\n"]) {
      expect(booted.includes(said), `the boot never says ${JSON.stringify(said.trim())}`);
    }
    const checks = booted.split("\n").filter((l) => /disk check/.test(l));
    expect(checks.length >= 1, "the boot reports no disk check");
    const req = (m, p, o) => guest.request(m, p, o);

    step = "GET /";
    const landing = await req("GET", "/");
    expect(landing.status === 200 && /Begin Game/.test(landing.text), `GET /: ${landing.status}, Begin Game ${/Begin Game/.test(landing.text)}`);

    step = "POST /begin";
    const begun = await req("POST", "/begin", { body: "" });
    expect(begun.status === 303, `POST /begin: ${begun.status}`);
    const set = begun.headers["set-cookie"]?.[0] ?? "";
    expect(set.startsWith(`${cookie_name}=`) && /; Secure(;|$)/.test(set) && /; HttpOnly(;|$)/.test(set), `the cookie is not a Secure, HttpOnly ${cookie_name}: ${set.replace(/=[^;]*/, "=…")}`);
    const cookie = set.split(";")[0];

    step = "/load";
    const game = await req("GET", "/dogpark", { cookie });
    expect(game.status === 200, `GET /dogpark: ${game.status}`);
    const hash = /dogpark-physics" content="([0-9a-f]{8})"/.exec(game.text)?.[1];
    expect(hash, "/dogpark names no physics hash");
    const load = await req("POST", "/load", { cookie, body: `dogpark 2 physics ${hash} load 1280x800\n` });
    expect(load.status === 200, `POST /load: ${load.status}: ${load.text.slice(0, 200)}`);

    step = "/admin/game";
    const admin = await req("GET", "/admin/game", { headers: { authorization: `Bearer ${key}` } });
    expect(admin.status === 200 && /<p>1 of 80 accounts handed out;/.test(admin.text), `/admin/game with the key: ${admin.status}`);
    const refused = await req("GET", "/admin/game");
    expect(refused.status === 403, `/admin/game without the key: ${refused.status}`);

    // roc-webbox's TODO list, mounted at /todo (src/combos/dogpark_todo.zig):
    // a list per visitor, by a Secure cookie.
    step = "/todo";
    const bare = await req("GET", "/todo");
    expect(bare.status === 303 && bare.headers.location === "/todo/", `GET /todo: ${bare.status} to ${bare.headers.location}`);
    const page = await req("GET", "/todo/");
    expect(page.status === 200 && /api\/todos/.test(page.text), `GET /todo/: ${page.status}`);
    const added = await req("POST", "/todo/api/todos", { body: "rehearse the droplet" });
    const visitor = added.headers["set-cookie"]?.[0] ?? "";
    expect(added.status === 200 && /rehearse the droplet/.test(added.text), `POST /todo/api/todos: ${added.status}: ${added.text.slice(0, 120)}`);
    expect(visitor.startsWith("__Host-roc-todo=") && /; Secure(;|$)/.test(visitor) && /; HttpOnly(;|$)/.test(visitor), `the list's cookie is not a Secure, HttpOnly __Host-roc-todo: ${visitor.replace(/=[^;]*/, "=…")}`);
    const mine = await req("GET", "/todo/api/todos", { cookie: visitor.split(";")[0] });
    expect(mine.status === 200 && /rehearse the droplet/.test(mine.text), `the visitor's list read back: ${mine.status}: ${mine.text.slice(0, 120)}`);
    const stranger = await req("GET", "/todo/api/todos");
    expect(stranger.status === 200 && stranger.text === "[]", `a new visitor's list: ${stranger.status}: ${stranger.text.slice(0, 120)}`);

    step = "the guest's log";
    await guest.checkSerial();

    step = "the public card answers nothing";
    const answered = await new Promise((ok) => {
      const r = http.get({ host: "127.0.0.1", port: publicPort, path: "/", agent: false }, () => ok(true));
      r.setTimeout(2000, () => r.destroy(new Error("timeout")));
      r.on("error", () => ok(false));
    });
    expect(!answered, "the public card answered");

    await guest.stop();
    console.log(`rehearse PASS (${((performance.now() - t0) / 1000).toFixed(1)} s): ${image} booted on the droplet's machine; private card, data on the boot disk, no volume; landing, Begin Game's Secure cookie, /load, /admin/game with the key and 403 without; /todo's list written and read back by its cookie; the public card silent`);
    rmSync(scratch, { recursive: true, force: true });
    return true;
  } catch (e) {
    if (guest) await guest.stop().catch(() => {});
    console.error(`rehearse FAIL: step "${step}": ${e.message}`);
    if (guest) console.error(`\nthe guest's log (${guest.serialPath}), its tail:\n${guest.tail()}`);
    console.error(`\nthe scratch copy and log are kept: ${scratch}`);
    return false;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) {
    console.error("usage: node droplet/rehearse.mjs <image.img>");
    process.exit(2);
  }
  process.exitCode = (await rehearse(resolve(process.argv[2]))) ? 0 : 1;
}
