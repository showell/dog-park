// Who may play (src/play/players.zig, docs/PHYSICS.md "Who may play"): a
// scratch play server (tools/lib/scratch_server.mjs, which takes the first
// account itself), then the landing page, Begin Game, the five accounts,
// the turn, and Start over, as browsers on several devices would meet them.
//
//     zig build check      (or: zig build && node tools/test_players.mjs)
//
// The rules' logic is unit-tested in Zig (players.zig); this is what only
// a real host shows: the cookie and the redirects, the 503, a reset's load.

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { scratchServer } from "./lib/scratch_server.mjs";

const server = await scratchServer();
after(() => server.stop());

const cookieOf = (r) => r.headers["set-cookie"]?.[0]?.split(";")[0];
let hash;
// The other four accounts' cookies, once Begin Game has handed them out.
let others = [];
const loadLine = () => `dogpark 1 physics ${hash} load 1280x800\n`;

test("the landing page has the button; /dogpark without an account goes back to it", async () => {
  const landing = await server.as(undefined, "GET", "/");
  assert.equal(landing.status, 200);
  assert.match(landing.text, /<form method="post" action="\/begin">/);
  assert.match(landing.text, /Begin Game/);
  const bare = await server.as(undefined, "GET", "/dogpark");
  assert.equal(bare.status, 303);
  assert.equal(bare.headers.location, "/");
  // With the account, the game's page, its wasm named.
  const game = await server.as(server.cookie, "GET", "/dogpark");
  assert.equal(game.status, 200);
  assert.match(game.text, /dogpark-physics" content="[0-9a-f]{8}"/);
  hash = game.text.match(/dogpark-physics" content="([0-9a-f]{8})"/)[1];
});

test("no account, no game: a load or a report without the cookie is a 403", async () => {
  assert.equal((await server.as(undefined, "POST", "/load", loadLine())).status, 403);
  assert.equal((await server.as("dogpark=forged.1.abc", "POST", "/report", "x\n")).status, 403);
});

// The caps (src/play/players.zig): accounts, and accounts playing at once.
const most_players = 80;
const most_playing = 5;

test("Begin Game: a device with an account keeps it; the rest get one each, up to the most; the next finds the park full", async () => {
  const again = await server.as(server.cookie, "POST", "/begin", "");
  assert.equal(again.status, 303);
  assert.equal(cookieOf(again), undefined, "no new cookie for a device that has one");
  for (let i = 1; i < most_players; i++) {
    const r = await server.as(undefined, "POST", "/begin", "");
    assert.equal(r.status, 303, `account ${i}`);
    assert.equal(r.headers.location, "/dogpark");
    others.push(cookieOf(r));
  }
  assert.equal(new Set([server.cookie, ...others]).size, most_players);
  const past = await server.as(undefined, "POST", "/begin", "");
  assert.equal(past.status, 200);
  assert.match(past.text, /The park is full/);
  assert.equal(cookieOf(past), undefined);
  // A restart hands out no more, and every account's cookie still reads.
  await server.restart();
  assert.match((await server.as(undefined, "POST", "/begin", "")).text, /The park is full/);
  assert.equal((await server.as(others.at(-1), "GET", "/dogpark")).status, 200);
});

test("up to most_playing at once: each plays its own game; the next loads and pans freely, but its ticks wait, told how long; a player plays on", async () => {
  const header = (epoch, req) => `dogpark 1 physics ${hash} page ${epoch} req ${req}\n`;
  // A tick from an account: it loads its game, and its first report carries a tick.
  const play = async (cookie) => {
    const loaded = await server.as(cookie, "POST", "/load", loadLine());
    assert.equal(loaded.status, 200);
    const epoch = loaded.text.match(/^epoch (\S+)\n/)[1];
    const k = loaded.text.match(/\nkept (\d+)\n/)[1];
    return { epoch, k, answer: await server.as(cookie, "POST", "/report", `${header(epoch, 1)}from ${k} wall 1\nt ${+k + 1} +0\n`) };
  };
  const players = [server.cookie, ...others.slice(0, most_playing - 1)];
  const games = [];
  for (const cookie of players) {
    const g = await play(cookie);
    assert.match(g.answer.text, /^req 1\nkept /, g.answer.text);
    games.push(g);
  }
  // One more: it loads its own game and pans, but its tick waits.
  const next = others[most_playing - 1];
  const theirs = await server.as(next, "POST", "/load", loadLine());
  assert.equal(theirs.status, 200);
  const e = theirs.text.match(/^epoch (\S+)\n/)[1];
  const k = theirs.text.match(/\nkept (\d+)\n/)[1];
  const pan = await server.as(next, "POST", "/report", `${header(e, 1)}from ${k}\nview ${+k + 1} 640x480\n`);
  assert.match(pan.text, /^req 1\nkept /, pan.text);
  const busy = await server.as(next, "POST", "/report", `${header(e, 2)}from ${k} wall 1\nt ${+k + 1} +0\n`);
  assert.equal(busy.status, 503);
  assert.match(busy.text, /^busy (1\d|20)\n$/);
  // A player plays on.
  const kept = games[0].answer.text.match(/^req 1\nkept (\d+)\n/)[1];
  const on = await server.as(players[0], "POST", "/report", `${header(games[0].epoch, 2)}from ${kept} wall 1\nt ${+kept + 1} +0\n`);
  assert.match(on.text, /^req 2\nkept /, on.text);
});

test("Start over: the account's next load is answered, and a device with no account can't ask", async () => {
  // What a reset does to the board is physics_server_test.zig's; here, the route.
  assert.equal((await server.as(server.cookie, "POST", "/reset", "")).status, 200);
  assert.equal((await server.as(server.cookie, "POST", "/load", loadLine())).status, 200);
  assert.equal((await server.as(undefined, "POST", "/reset", "")).status, 403);
});

test("/version: anyone may ask which commit serves, since when, and how much is in use", async () => {
  const r = await server.as(undefined, "GET", "/version");
  assert.equal(r.status, 200);
  assert.match(r.headers["content-type"], /^application\/json/);
  const v = JSON.parse(r.text);
  assert.equal(v.result, "success");
  assert.equal(v.app, "dog-park");
  assert.match(v.commit, /^([0-9a-f]{7,}(\+dirty)?|unknown)$/);
  assert.ok(v.started_ms > 0 && v.started_ms <= v.now_ms, r.text);
  assert.equal(v.accounts_most, most_players);
  assert.equal(v.turns_most, most_playing);
  assert.ok(v.accounts >= 0 && v.accounts <= most_players, r.text);
  assert.ok(v.turns_held >= 0 && v.turns_held <= most_playing, r.text);
  assert.equal((await server.as(undefined, "POST", "/version", "")).status, 405);
});

test("the operator's pages: nothing without the admin key; the bearer or a login's cookie opens them", async () => {
  const { readFileSync } = await import("node:fs");
  const { join } = await import("node:path");
  const key = readFileSync(join(server.dir, "auth", "_admin_key"), "utf8").trim();
  for (const path of ["/admin/game", "/admin/host"]) {
    assert.equal((await server.as(undefined, "GET", path)).status, 403, path);
    // A player's cookie is not the operator's.
    assert.equal((await server.as(server.cookie, "GET", path)).status, 403, path);
  }
  const front = await server.as(undefined, "GET", "/admin");
  assert.equal(front.status, 200);
  assert.match(front.text, /<form method="post" action="\/admin\/login">/);
  // The bearer, as curl sends it.
  const bearer = await server.bearer(key, "GET", "/admin/game");
  assert.equal(bearer.status, 200);
  assert.match(bearer.text, /\d+ of 80 accounts handed out; \d+ of 5 turns held/);
  assert.match(bearer.text, /<th>herd<\/th>/);
  assert.equal((await server.bearer("0".repeat(64), "GET", "/admin/game")).status, 403);
  assert.equal((await server.bearer(key, "GET", "/admin/host")).status, 200);
  // A login: a wrong key is refused; the right one sets the cookie and goes to the game.
  assert.equal((await server.as(undefined, "POST", "/admin/login", "key=" + "0".repeat(64))).status, 403);
  const ok = await server.as(undefined, "POST", "/admin/login", `key=${key}`);
  assert.equal(ok.status, 303);
  assert.equal(ok.headers.location, "/admin/game");
  const cookie = ok.headers["set-cookie"][0].split(";")[0];
  assert.equal((await server.as(cookie, "GET", "/admin/game")).status, 200);
});

test("the host's log, /admin/log, for the operator only: its header names Dog Park, and a filter spelled wrong is a 400 (metal-vmm QUEUE 221)", async () => {
  const { readFileSync } = await import("node:fs");
  const { join } = await import("node:path");
  const key = readFileSync(join(server.dir, "auth", "_admin_key"), "utf8").trim();
  assert.equal((await server.as(undefined, "GET", "/admin/log")).status, 403);
  assert.equal((await server.as(server.cookie, "GET", "/admin/log")).status, 403);
  assert.equal((await server.bearer("0".repeat(64), "GET", "/admin/log")).status, 403);
  const log = await server.bearer(key, "GET", "/admin/log");
  assert.equal(log.status, 200);
  assert.match(log.headers["content-type"], /^text\/plain/);
  assert.match(log.text, /^# The host's log, for agents/);
  assert.match(log.text, /\n# the application: Dog Park, physics [0-9a-f]{8}\n/);
  assert.match(log.text, /\n# requests since boot: /);
  assert.equal((await server.bearer(key, "GET", "/admin/log?boot=sometimes")).status, 400);
});
