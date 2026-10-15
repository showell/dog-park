// A page in node: the engine (solo/engine.js) on the real physics.wasm
// (zig-out/web/physics.wasm, a fresh instance per page), its clock and
// timers fake and moved by the test, its wire whatever `post` the test
// gives (a scratch server's, or a script).

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createEngine } from "../../solo/engine.js";
import { instantiatePhysics, SCRATCH, flag } from "../../solo/physics.js";
import { world_px } from "../../solo/scene.js";
import { root } from "./scratch_server.mjs";

// The served build, unless DOGPARK_WASM names another (the fast tier's
// Debug build, zig-out/web-debug/physics.wasm).
export const wasmBytes = () => readFileSync(join(root, process.env.DOGPARK_WASM ?? "zig-out/web/physics.wasm"));

/**
 * A page: `post(path, text)` -> Promise of { status, text }. Every request
 * the engine makes is recorded in `sent` ({ path, text }); `settle()` waits
 * for the requests in flight to land and the engine to take them. A post
 * whose promise is marked `held` (a script's, answered when the test says)
 * is never waited for.
 */
export async function pageRig({ post, screen = { width: 1280, height: 800 }, at = "none", budget, spacing }) {
  const physics = await instantiatePhysics(wasmBytes());
  const tick_ms = 1000 / physics.ticksPerSecond();
  const sent = [];
  const said = [];
  const reloads = [];
  const live = new Set();
  const timers = new Map();
  let nextTimer = 0;
  const rig = {
    clock: 0,
    wallMs: 1_791_936_000_000,
    sent,
    said,
    reloads,
    physics,
    // Lets every request in flight land, and the engine take its answer.
    // **NO WALL TIME**: waits only for real work (a scratch server's
    // answer, `track`ed), never for a request a script holds (a promise
    // marked `held`), then drains the engine's microtasks and immediates.
    async settle() {
      for (let i = 0; i < 100; i++) {
        if (live.size) await Promise.allSettled([...live]);
        for (let k = 0; k < 10; k++) await new Promise((r) => setImmediate(r));
        if (!live.size) break;
      }
    },
    // Real work to wait for that the engine doesn't see (a server's answer
    // a test holds back).
    track(p) {
      const t = Promise.resolve(p).finally(() => live.delete(t));
      live.add(t);
    },
    // The clock moved to `ms`, firing each timer due on the way, in order.
    async advanceTo(ms) {
      for (;;) {
        const due = [...timers.entries()].filter(([, t]) => t.at <= ms).sort((a, b) => a[1].at - b[1].at || a[0] - b[0]);
        if (!due.length) break;
        const [id, t] = due[0];
        timers.delete(id);
        rig.clock = Math.max(rig.clock, t.at);
        t.fn();
        await rig.settle();
      }
      rig.clock = ms;
    },
    // `n` frames, one a tick, each after the requests in flight have landed.
    async ticks(n = 1, panAt = "none") {
      for (let k = 0; k < n; k++) {
        await rig.advanceTo(rig.clock + tick_ms);
        rig.wallMs += tick_ms;
        engine.frame(rig.clock, panAt);
        await rig.settle();
      }
    },
    timersPending: () => [...timers.values()].map((t) => t.at),
    warnings: () => said.filter((s) => s[0] !== "log").map((s) => s.slice(1).join(" ")),
  };
  const engine = createEngine({
    physics,
    post: (path, text) => {
      sent.push({ path, text });
      const p = post(path, text);
      if (!p.held) rig.track(p);
      return p;
    },
    now: () => rig.clock,
    wall: () => Math.round(rig.wallMs),
    setTimer: (ms, fn) => {
      const id = ++nextTimer;
      timers.set(id, { at: rig.clock + ms, fn });
      return id;
    },
    clearTimer: (id) => timers.delete(id),
    log: {
      log: (...a) => said.push(["log", ...a]),
      warn: (...a) => said.push(["warn", ...a]),
      error: (...a) => said.push(["error", ...a]),
    },
    reload: (why) => reloads.push(why),
    ...(budget === undefined ? {} : { budget }),
    ...(spacing === undefined ? {} : { spacing }),
  });
  rig.engine = engine;
  rig.load = async () => {
    const p = engine.load(() => screen, at);
    await rig.settle();
    await p;
    engine.frame(rig.clock); // the clock starts
    await rig.settle();
  };
  return rig;
}

/** A promise the rig's settle never waits for: a test answers it. */
export function held(executor) {
  const p = new Promise(executor);
  p.held = true;
  return p;
}

/** The reports sent, as texts. */
export const reports = (rig) => rig.sent.filter((s) => s.path === "/report").map((s) => s.text);

// ── the physics' numbers, asked of the wasm itself ───────────────────────────
// So a test derives what it waits for from the code under test, never from
// a number that tuning will change. A separate instance: no page's boards
// are touched.

const geometry = await instantiatePhysics(wasmBytes());
const hex = (px) => `${Math.round(px * 256).toString(16).replace(/(..)$/, ".$1").replace(/^\./, "0.")}`;

/** The region's tiles around a dog at park point (x, y), [{ col, row }]. */
export function regionAround(x, y) {
  geometry.reset();
  if (geometry.readState("state leash 0 drag on laid 0 view 0x0 held", SCRATCH) === "malformed") throw new Error("regionAround: the state line doesn't read");
  if (geometry.readBoard(`board 1 dog 0 ${hex(x)},${hex(y)}`, SCRATCH) === "malformed") throw new Error("regionAround: the board line doesn't read");
  return geometry.region(SCRATCH);
}

/** How many ticks after a letgo the leash comes off (the physics' let_go_ticks). */
export function letGoTicks() {
  geometry.reset();
  geometry.readBoard(`board 1 dog 0 ${hex(world_px / 2)},${hex(world_px / 2)}`, SCRATCH);
  geometry.human(SCRATCH, "leash", 1, 0);
  geometry.tick(SCRATCH, 1, []);
  geometry.clearBegun(SCRATCH);
  geometry.human(SCRATCH, "letgo", 2, 0);
  for (let t = 2; t < 100_000; t++) {
    if (geometry.tick(SCRATCH, t, []).flags & flag.release) return t - 2;
    geometry.clearBegun(SCRATCH);
  }
  throw new Error("the leash never came off");
}
