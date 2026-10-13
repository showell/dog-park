// The engine: what the page knows and how it talks to the server, with no
// DOM. The dogs and cows it has seen, the tiles subscribed, the leash, the
// viewport, the sends, the cows' rule, and the tick. Everything it does over
// the wire or with the clock goes through what `createEngine` is given, so
// node can drive it; one engine is one page.
//
// **THE PAGE TICKS 16 TIMES A SECOND** (docs/PHYSICS.md's tick, 62.5 ms),
// apart from the frames: `frame(nowMs)` runs the ticks due since the last,
// 0 or more, and everything that moves a critter or the viewport by itself
// happens in a tick. The pointer's grab, drag and letgo are recorded as they
// come and applied, in order, at the next tick: the held dog lands where the
// pointer last put it before the tick. The edge bands move the held dog (and
// the viewport with it), or a pan held at an edge moves the viewport, a
// tick's worth each tick. The leash's let-go is 80 ticks. The tiles are
// synced, the moved dog's place sent and the cows predicted once a tick. A
// pan by the pointer itself moves the viewport at once: it moves no critter.
//
// Between ticks the frames draw each critter, and the viewport, between
// where it was at the tick before and where it is now (`view().alpha`, the
// way through the tick; scene.js's `between`).
//
//   createEngine({ rule, post, getJSON, now, log })
//     rule        the cows' rule, /cows.wasm's exports
//     post        (path, body) -> Promise of the answer's JSON; rejects on
//                 no answer or one not ok
//     getJSON     (path) -> Promise of the answer's JSON
//     now         () -> ms, for the moves' round trips in the log
//     log         { log, warn, error }, the dev console
//
//   engine.load(measure)  asks /me where the viewport was and whose leash
//                         is on; `measure()` -> { width, height }, the
//                         screen, read once the answer is in
//   engine.resize({ width, height })
//   engine.intent(i)      a pointer intent (pointer.js): grab, drag and letgo
//                         wait for the next tick; a pan is applied at once
//   engine.frame(nowMs, panAt)
//                         each frame: the ticks due by `nowMs` run (the
//                         first frame starts the clock and runs none);
//                         `panAt` is where the pointer holds a pan, a
//                         viewport point { x, y }, or "none" (pointer.js's
//                         panPointer): the edge bands' pan. Answers the
//                         number of ticks run
//   engine.view()         plain data, copies: { viewport, dogs (a Map by id),
//                         cows, subscribed (a Set of tile keys), leashed,
//                         lastLeashed, tick, alpha, was } where `was` is
//                         { viewport, dogs, cows }: the viewport's park point
//                         and each critter's (Maps by id) at the tick before

import { tileOf, tileKey, wantedTiles, world_px, viewportKeptOnWorld } from "./scene.js";
import { edgeScroll } from "./pointer.js";

// The tick: 16 a second.
export const tick_ms = 62.5;

// **A STALL CATCHES UP AT MOST `most_catch_up_ticks`** (half a second): a
// frame after a longer gap (a background tab, a slow machine) runs that
// many, and the rest are dropped, never owed: the clock starts again from
// that frame. The physics has no clock, so a dropped tick changes nothing
// but how far the edge bands carried you.
export const most_catch_up_ticks = 8;

// How long a dog stays on your leash after you let go of it: 5 s.
export const leash_kept_ticks = 80;

// The most points one move's path holds (dogs.zig's most_path_points): past
// it, the newest point takes the last one's place.
const most_path_points = 100;

// **A COW THAT JUMPS IS SAID** (Steve saw big jumps): one predicted more
// than `jump_px` from where the last tick had it is logged, with what moved
// it: the rule (the page's own prediction) or the server's word. A tick is
// 3.75 frames at 60 Hz, so this is the 8 px a frame it was.
const jump_px = 30;

// Where a dog is, as the whole pixel the server is told.
export function wholePoint(dog) {
  return { parkX: Math.round(dog.parkX), parkY: Math.round(dog.parkY) };
}

// The ticks a frame at `nowMs` runs, the last tick having begun at
// `lastTickMs`: those whose start has come, at most `most_catch_up_ticks`;
// and when the last of them began (`nowMs` itself when some were dropped:
// the clock starts again there). `dropped` is how many were.
export function ticksDue(lastTickMs, nowMs) {
  const due = Math.max(0, Math.floor((nowMs - lastTickMs) / tick_ms));
  if (due <= most_catch_up_ticks) return { ticks: due, lastTickMs: lastTickMs + due * tick_ms, dropped: 0 };
  return { ticks: most_catch_up_ticks, lastTickMs: nowMs, dropped: due - most_catch_up_ticks };
}

export function createEngine({ rule, post, getJSON, now, log }) {
  // ── what the page knows ───────────────────────────────────────────────────

  // The viewport: its top-left a park point, its size the screen's.
  const viewport = { parkX: 0, parkY: 0, width: 0, height: 0 };
  // Every dog the page has seen, by id, where it last saw it: live in a tile
  // subscribed, remembered (perhaps stale) in one that is not.
  const known = new Map();
  // Every cow the page has seen, by id, where the SERVER last said it is, in
  // HALF park pixels (cows.zig's CowPoint): halfX / 2 is its park x.
  const serverCows = new Map();
  // The cows the server told of since the last frame, and by what: so a cow
  // that jumps can be said to have jumped by the rule or by the server.
  const toldOf = new Map();
  // The cows as drawn: `serverCows` with the unanswered moves replayed
  // (predictCows), each frame.
  let knownCows = new Map();
  // Where the server has each dog, or will once the move in flight lands: a
  // move's BEGIN point. Set by the tiles' answer and by each send.
  const beginPoints = new Map();
  // The tiles the server has acked as subscribed, by key.
  let subscribed = new Map();

  // The dog on your leash, by id: none, or one held in your hand, or one let
  // go of and kept on the leash until tick `untilTick`, when it is let go.
  // **THE DOG IN YOUR HAND IS THE LEASH'S `in_hand`**: a grab leashes, and
  // nothing but a grab or a letgo changes the leash while a dog is held.
  let leashed = { kind: "none" };
  // The dog you leashed last, by id, for the overview: none yet, or one.
  let lastLeashed = { kind: "none" };

  // ── the tick ──────────────────────────────────────────────────────────────

  // The clock: "unstarted" until the first frame, then when the last tick
  // began (a frame's ms). `tick` counts the ticks run.
  let clock = "unstarted";
  let tick = 0;
  // How far the last frame was through its tick, 0 to 1 (1 before any).
  let alpha = 1;
  // The pointer's grab, drag and letgo intents since the last tick, in order.
  let inputs = [];
  // Where the viewport and each critter were at the tick before this one:
  // the frames draw between there and here.
  const wasViewport = { parkX: 0, parkY: 0 };
  let wasDogs = new Map();
  let wasCows = new Map();

  function heardOfCow(c, by) {
    serverCows.set(c.id, { id: c.id, halfX: c.half_x, halfY: c.half_y });
    toldOf.set(c.id, by);
  }

  // ── the leash ─────────────────────────────────────────────────────────────

  // A leash is asked for and the dog moved at once (optimistic); the ack is
  // only said, for now.
  function leashTo(dogId) {
    if (leashed.kind !== "none" && leashed.dogId !== dogId) releaseLeash();
    const already = leashed.kind !== "none" && leashed.dogId === dogId;
    leashed = { kind: "in_hand", dogId };
    lastLeashed = { kind: "dog", dogId };
    if (already) return;
    post("/leash", { dog: dogId }).then(
      (ack) => log.log("leashed", ack),
      (e) => log.error("leash failed:", e.message),
    );
  }

  // Let go of the dog in your hand: it stays on the leash
  // `leash_kept_ticks` from this tick.
  function keepOnLeash() {
    if (leashed.kind !== "in_hand") return;
    leashed = { kind: "kept", dogId: leashed.dogId, untilTick: tick + leash_kept_ticks };
  }

  function releaseLeash() {
    if (leashed.kind === "none") return;
    const dogId = leashed.dogId;
    leashed = { kind: "none" };
    post("/release", { dog: dogId }).then(
      (ack) => log.log("released", ack),
      (e) => log.error("release failed:", e.message),
    );
  }

  // ── sends: at most one waiting each, the latest sent when it is acked ─────

  // waiting: "none", or the move in flight: its dog's id, where the server
  // had the dog (`begin`), and the path sent. pending: each dog's path not
  // sent yet, by dog id, in the order the server will be sent them.
  const moves = { waiting: "none", pending: new Map() };

  // The last point the server has, or will have once told, of a dog.
  function lastPoint(dogId) {
    const pending = moves.pending.get(dogId);
    return pending ? pending.path[pending.path.length - 1] : beginPoints.get(dogId);
  }

  // **THE PATH THE PAGE SAW**: once a tick, where a dog the tick moved now
  // is joins its path when it has moved a whole pixel (one point a tick),
  // and the path goes when nothing is in flight. The server replays the
  // cows' rule along it, segment by segment, as the page does (predictCows).
  function sendMove(dogId) {
    const at = wholePoint(known.get(dogId));
    const last = lastPoint(dogId);
    if (last && last.parkX === at.parkX && last.parkY === at.parkY) return;
    let pending = moves.pending.get(dogId);
    if (!pending) {
      pending = { dogId, path: [] };
      moves.pending.set(dogId, pending);
    }
    if (pending.path.length === most_path_points) pending.path[most_path_points - 1] = at;
    else pending.path.push(at);
    if (moves.waiting === "none") sendNext();
  }

  function sendNext() {
    const [next] = moves.pending.values();
    if (next === undefined) return;
    moves.pending.delete(next.dogId);
    const { dogId, path } = next;
    const begin = beginPoints.get(dogId);
    moves.waiting = { dogId, begin, path };
    beginPoints.set(dogId, path[path.length - 1]);
    const sentMs = now();
    post("/move", { dog: dogId, path: path.map((p) => [p.parkX, p.parkY]) }).then(
      (ack) => {
        for (const c of ack.cows) heardOfCow(c, "a move's ack");
        const scared = ack.cows.length ? `, scaring ${ack.cows.map((c) => `cow ${c.id} to (${c.half_x / 2}, ${c.half_y / 2})`).join(", ")}` : "";
        log.log(`moved ${ack.moved} along ${path.length} points to (${ack.park_x}, ${ack.park_y}) in ${Math.round(now() - sentMs)} ms${scared}`);
      },
      (e) => {
        // Not moved: the server has the dog where it had it.
        if (begin) beginPoints.set(dogId, begin);
        log.error("move failed:", e.message);
      },
    ).finally(() => {
      moves.waiting = "none";
      sendNext();
    });
  }

  // Whether a move of the dog `id` is in flight or waiting.
  function moving(id) {
    return (moves.waiting !== "none" && moves.waiting.dogId === id) || moves.pending.has(id);
  }

  // The viewport as it is when the send goes: one in flight, and at most one
  // more due once it lands.
  const viewportSends = { waiting: false, due: false };

  function sendViewport() {
    if (viewportSends.waiting) { viewportSends.due = true; return; }
    viewportSends.waiting = true;
    post("/viewport", { park_x: Math.round(viewport.parkX), park_y: Math.round(viewport.parkY) }).then(
      () => {},
      (e) => log.error("viewport failed:", e.message),
    ).finally(() => {
      viewportSends.waiting = false;
      if (viewportSends.due) {
        viewportSends.due = false;
        sendViewport();
      }
    });
  }

  // The tiles, once a tick: when none is waiting and the tiles wanted differ
  // from those subscribed, the whole set wanted is sent, each tile marked new
  // (its dogs wanted) or held (its dogs known). The answer is the truth for
  // each new tile: the dogs remembered there are dropped (one may have
  // wandered off), but for one on your leash (in your hand or not, or
  // grabbed and waiting for the tick), and the answer's dogs taken, drawn
  // where they are from the next frame (no sliding there). A dog in a tile
  // left out is remembered where it was.
  const tileSends = { waiting: false };

  function syncTiles() {
    if (tileSends.waiting) return;
    const wanted = new Map(wantedTiles(viewport).map((t) => [tileKey(t), t]));
    const added = [...wanted.keys()].filter((k) => !subscribed.has(k)).length;
    const dropped = [...subscribed.keys()].filter((k) => !wanted.has(k)).length;
    if (added === 0 && dropped === 0) return;
    tileSends.waiting = true;
    const named = [...wanted].map(([k, t]) => ({ col: t.col, row: t.row, is: subscribed.has(k) ? "held" : "new" }));
    post("/tiles", { tiles: named }).then(
      (ack) => {
        subscribed = wanted;
        const fresh = new Set(named.filter((t) => t.is === "new").map(tileKey));
        const onLeash = (id) => (leashed.kind !== "none" && leashed.dogId === id)
          || inputs.some((i) => i.kind === "grab" && i.dogId === id);
        let replaced = 0;
        for (const [id, d] of known) {
          if (!onLeash(id) && fresh.has(tileKey(tileOf(d.parkX, d.parkY)))) { known.delete(id); replaced++; }
        }
        for (const d of ack.dogs) {
          if (onLeash(d.id) || moving(d.id)) continue;
          known.set(d.id, { id: d.id, emoji: d.emoji, parkX: d.park_x, parkY: d.park_y });
          wasDogs.set(d.id, { parkX: d.park_x, parkY: d.park_y });
          beginPoints.set(d.id, { parkX: d.park_x, parkY: d.park_y });
        }
        for (const [id, c] of serverCows) {
          if (fresh.has(tileKey(tileOf(c.halfX / 2, c.halfY / 2)))) serverCows.delete(id);
        }
        for (const c of ack.cows) heardOfCow(c, "the tiles' answer");
        log.log(`tiles: ${added} new, ${dropped} dropped, ${ack.subscribed} subscribed; ${ack.dogs.length} dogs arrived for ${replaced} remembered, ${known.size} known; ${ack.cows.length} cows arrived, ${serverCows.size} known`);
      },
      (e) => log.error("tiles failed:", e.message),
    ).finally(() => { tileSends.waiting = false; });
  }

  // ── the cows' rule, the server's own ─────────────────────────────────────

  // The cows as the server will have them once it has taken every move the
  // page has made: the server's last word, then the path in flight, then
  // each path waiting, from its dog's begin point, in the order the server
  // will take them (cows.zig's replay, in the wasm). Each segment, once
  // seen, never changes, so a tick only adds to this. In park pixels, to
  // the half.
  function predictCows() {
    const ids = [...serverCows.keys()].slice(0, rule.cowCapacity());
    const at = new Int32Array(rule.memory.buffer, rule.cowPositions(), 2 * ids.length);
    ids.forEach((id, i) => {
      const c = serverCows.get(id);
      at[2 * i] = c.halfX;
      at[2 * i + 1] = c.halfY;
    });
    const points = new Int32Array(rule.memory.buffer, rule.pathPoints(), 2 * rule.pathCapacity());
    const replay = (begin, path) => {
      if (begin === undefined) return; // a dog the server has not told of: nothing to start from
      [begin, ...path].forEach((p, i) => {
        points[2 * i] = p.parkX;
        points[2 * i + 1] = p.parkY;
      });
      rule.replay(ids.length, 1 + path.length);
    };
    if (moves.waiting !== "none") replay(moves.waiting.begin, moves.waiting.path);
    for (const { dogId, path } of moves.pending.values()) replay(beginPoints.get(dogId), path);
    const out = new Map();
    ids.forEach((id, i) => out.set(id, { id, parkX: at[2 * i] / 2, parkY: at[2 * i + 1] / 2 }));
    return out;
  }

  function sayJumps(before, after) {
    for (const [id, c] of after) {
      const was = before.get(id);
      if (was === undefined) continue;
      const by = Math.hypot(c.parkX - was.parkX, c.parkY - was.parkY);
      if (by > jump_px) {
        log.warn(`cow ${id} jumped ${by.toFixed(1)} px, (${was.parkX}, ${was.parkY}) to (${c.parkX}, ${c.parkY}), by ${toldOf.get(id) ?? "the rule"}`);
      }
    }
    toldOf.clear();
  }

  // ── what the page asks of it ─────────────────────────────────────────────

  function heldDog(dogId) {
    const dog = known.get(dogId);
    if (dog === undefined) throw new Error(`dog ${dogId} is in hand but not known`);
    return dog;
  }

  function moveViewport(parkX, parkY) {
    viewport.parkX = parkX;
    viewport.parkY = parkY;
    sendViewport();
  }

  // One tick: what was is now where things are; the pointer's inputs, in
  // order; the leash let go when its ticks have run (a grab this tick came
  // first); the edge bands (the held dog and the viewport with it, or a
  // pan held at an edge); each dog moved sent; the tiles synced; the cows
  // predicted.
  function runTick(panAt) {
    tick++;
    wasViewport.parkX = viewport.parkX;
    wasViewport.parkY = viewport.parkY;
    wasDogs = new Map([...known].map(([id, d]) => [id, { parkX: d.parkX, parkY: d.parkY }]));
    wasCows = new Map([...knownCows].map(([id, c]) => [id, { parkX: c.parkX, parkY: c.parkY }]));
    const moved = new Set();
    const taken = inputs;
    inputs = [];
    for (const i of taken) {
      switch (i.kind) {
        case "grab":
          // A dog dragged this tick is sent before another's grab lets it go.
          for (const id of moved) sendMove(id);
          leashTo(i.dogId);
          break;
        case "drag": {
          const dog = heldDog(i.dogId);
          dog.parkX = i.parkX;
          dog.parkY = i.parkY;
          moved.add(i.dogId);
          break;
        }
        case "letgo": keepOnLeash(); break;
        default: throw new Error(`no input ${i.kind}`);
      }
    }
    if (leashed.kind === "kept" && tick >= leashed.untilTick) releaseLeash();
    const band = leashed.kind === "in_hand"
      ? { kind: "dog", dogId: leashed.dogId, ...pointOf(heldDog(leashed.dogId)) }
      : panAt === "none" ? "none" : { kind: "pan", x: panAt.x, y: panAt.y };
    for (const e of edgeScroll(band, viewport)) {
      if (e.kind === "drag") {
        const dog = heldDog(e.dogId);
        dog.parkX = e.parkX;
        dog.parkY = e.parkY;
        moved.add(e.dogId);
      } else {
        moveViewport(e.parkX, e.parkY);
      }
    }
    for (const id of moved) sendMove(id);
    syncTiles();
    const drawn = predictCows();
    sayJumps(knownCows, drawn);
    knownCows = drawn;
  }

  return {
    async load(measure) {
      const me = await getJSON("/me");
      Object.assign(viewport, measure());
      if (me.viewport.at) {
        Object.assign(viewport, viewportKeptOnWorld(viewport, me.viewport.at.park_x, me.viewport.at.park_y));
      } else {
        // A first visit starts at the world's centre, the populated park's
        // middle.
        viewport.parkX = Math.round(world_px / 2 - viewport.width / 2);
        viewport.parkY = Math.round(world_px / 2 - viewport.height / 2);
        sendViewport();
      }
      wasViewport.parkX = viewport.parkX;
      wasViewport.parkY = viewport.parkY;
      // A dog still on your leash from before the reload: kept on it the
      // usual ticks from now, then let go.
      if (me.leash.dog !== undefined) {
        leashed = { kind: "kept", dogId: me.leash.dog, untilTick: tick + leash_kept_ticks };
      }
    },

    resize({ width, height }) {
      viewport.width = width;
      viewport.height = height;
    },

    intent(i) {
      switch (i.kind) {
        case "grab":
        case "letgo":
          inputs.push({ ...i });
          break;
        case "drag":
          heldDog(i.dogId);
          inputs.push({ ...i });
          break;
        case "pan":
          // The pointer's own pan: the viewport moves now, and what the
          // frames slide from moves with it, so a tick's slide carries on.
          wasViewport.parkX += i.parkX - viewport.parkX;
          wasViewport.parkY += i.parkY - viewport.parkY;
          moveViewport(i.parkX, i.parkY);
          break;
        default: throw new Error(`no intent ${i.kind}`);
      }
    },

    frame(nowMs, panAt = "none") {
      if (clock === "unstarted") clock = { lastTickMs: nowMs };
      const due = ticksDue(clock.lastTickMs, nowMs);
      if (due.dropped > 0) log.warn(`a stall of ${Math.round(nowMs - clock.lastTickMs)} ms: ${due.ticks} ticks run, ${due.dropped} dropped`);
      for (let k = 0; k < due.ticks; k++) runTick(panAt);
      clock.lastTickMs = due.lastTickMs;
      alpha = Math.min(1, Math.max(0, (nowMs - clock.lastTickMs) / tick_ms));
      return due.ticks;
    },

    view() {
      const plain = (l) => (l.kind === "none" ? { kind: "none" } : { kind: l.kind, dogId: l.dogId });
      const points = (m) => new Map([...m].map(([id, p]) => [id, { parkX: p.parkX, parkY: p.parkY }]));
      return {
        viewport: { ...viewport },
        dogs: new Map([...known].map(([id, d]) => [id, { ...d }])),
        cows: [...knownCows.values()].map((c) => ({ ...c })),
        subscribed: new Set(subscribed.keys()),
        leashed: plain(leashed),
        lastLeashed: plain(lastLeashed),
        tick,
        alpha,
        was: { viewport: { ...wasViewport }, dogs: points(wasDogs), cows: points(wasCows) },
      };
    },
  };
}

function pointOf(d) {
  return { parkX: d.parkX, parkY: d.parkY };
}
