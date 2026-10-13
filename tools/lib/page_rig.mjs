// A page in node: the engine (solo/engine.js) on the real physics.wasm
// (zig-out/web/physics.wasm, a fresh instance per page), its clock and
// timers fake and moved by the test, its wire whatever `post` the test
// gives (a scratch server's, or a script).

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createEngine, tick_ms } from "../../solo/engine.js";
import { instantiatePhysics } from "../../solo/physics.js";
import { root } from "./scratch_server.mjs";

export const wasmBytes = () => readFileSync(join(root, "zig-out/web/physics.wasm"));

/**
 * A page: `post(path, text)` -> Promise of { status, text }. Every request
 * the engine makes is recorded in `sent` ({ path, text }); `settle()` waits
 * for the requests in flight to land and the engine to take them.
 */
export async function pageRig({ post, screen = { width: 1280, height: 800 }, at = "none", budget }) {
  const physics = await instantiatePhysics(wasmBytes());
  const sent = [];
  const said = [];
  const reloads = [];
  const inFlight = new Set();
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
    // A request whose answer never comes (a test's lost answer) is waited
    // for 50 ms at most.
    async settle() {
      for (let i = 0; i < 50 && inFlight.size; i++) {
        const before = inFlight.size;
        await Promise.race([Promise.allSettled([...inFlight]), new Promise((r) => setTimeout(r, 50))]);
        await new Promise((r) => setImmediate(r));
        if (inFlight.size === before && i > 0) break;
      }
      for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
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
      const p = Promise.resolve().then(() => post(path, text));
      const tracked = p.finally(() => inFlight.delete(tracked));
      inFlight.add(tracked);
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

/** The reports sent, as texts. */
export const reports = (rig) => rig.sent.filter((s) => s.path === "/report").map((s) => s.text);
