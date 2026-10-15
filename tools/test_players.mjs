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

test("Begin Game: a device with an account keeps it; four more get one; the sixth finds the park full", async () => {
  const again = await server.as(server.cookie, "POST", "/begin", "");
  assert.equal(again.status, 303);
  assert.equal(cookieOf(again), undefined, "no new cookie for a device that has one");
  for (let i = 0; i < 4; i++) {
    const r = await server.as(undefined, "POST", "/begin", "");
    assert.equal(r.status, 303);
    assert.equal(r.headers.location, "/dogpark");
    others.push(cookieOf(r));
  }
  assert.equal(new Set([server.cookie, ...others]).size, 5);
  const sixth = await server.as(undefined, "POST", "/begin", "");
  assert.equal(sixth.status, 200);
  assert.match(sixth.text, /The park is full/);
  assert.equal(cookieOf(sixth), undefined);
  // A restart hands out no more.
  await server.restart();
  assert.match((await server.as(undefined, "POST", "/begin", "")).text, /The park is full/);
});

test("one player at a time: another account waits, told how long, while the first holds the turn", async () => {
  const first = await server.as(server.cookie, "POST", "/load", loadLine());
  assert.equal(first.status, 200);
  const other = others[0];
  const busy = await server.as(other, "POST", "/load", loadLine());
  assert.equal(busy.status, 503);
  assert.match(busy.text, /^busy (1\d|20)\n$/);
  // The holder plays on.
  assert.equal((await server.as(server.cookie, "POST", "/load", loadLine())).status, 200);
});

test("Start over: the account's next load is answered, and a device with no account can't ask", async () => {
  // What a reset does to the board is physics_server_test.zig's; here, the route.
  assert.equal((await server.as(server.cookie, "POST", "/reset", "")).status, 200);
  assert.equal((await server.as(server.cookie, "POST", "/load", loadLine())).status, 200);
  assert.equal((await server.as(undefined, "POST", "/reset", "")).status, 403);
});
