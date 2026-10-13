// The engine: what the page knows and how it talks to the server, with no
// DOM. The dogs and cows it has seen, the tiles subscribed, the leash, the
// viewport, the sends, and the cows' rule. Everything it does over the wire,
// with the clock or with timers goes through what `createEngine` is given,
// so node can drive it; one engine is one page.
//
//   createEngine({ rule, post, getJSON, now, setTimer, clearTimer, log })
//     rule        the cows' rule, /cows.wasm's exports
//     post        (path, body) -> Promise of the answer's JSON; rejects on
//                 no answer or one not ok
//     getJSON     (path) -> Promise of the answer's JSON
//     now         () -> ms, for the moves' round trips in the log
//     setTimer    (f, ms) -> a handle; clearTimer(handle)
//     log         { log, warn, error }, the dev console
//
//   engine.load(measure)  asks /me where the viewport was and whose leash
//                         is on; `measure()` -> { width, height }, the
//                         screen, read once the answer is in
//   engine.resize({ width, height })
//   engine.intent(i)      a pointer intent (pointer.js): grab, drag, letgo, pan
//   engine.frame()        each frame: the tiles synced, the cows predicted
//   engine.view()         plain data, copies: { viewport, dogs (a Map by id),
//                         cows, subscribed (a Set of tile keys), leashed,
//                         lastLeashed }

import { tileOf, tileKey, wantedTiles, world_px, viewportKeptOnWorld } from "./scene.js";

// How long a dog stays on your leash after you let go of it.
const leash_kept_ms = 5000;

// The most points one move's path holds (dogs.zig's most_path_points): past
// it, the newest point takes the last one's place.
const most_path_points = 100;

// **A COW THAT JUMPS IS SAID** (Steve saw big jumps): one drawn more than
// `jump_px` from where the last frame drew it is logged, with what moved it:
// the rule (the page's own prediction) or the server's word.
const jump_px = 8;

// Where a dog is, as the whole pixel the server is told.
export function wholePoint(dog) {
  return { parkX: Math.round(dog.parkX), parkY: Math.round(dog.parkY) };
}

export function createEngine({ rule, post, getJSON, now, setTimer, clearTimer, log }) {
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
  // go of and kept on the leash until a timer lets it go. **THE DOG IN YOUR
  // HAND IS THE LEASH'S `in_hand`**: a grab leashes, and nothing but a grab
  // or a letgo changes the leash while a dog is held.
  let leashed = { kind: "none" };
  // The dog you leashed last, by id, for the overview: none yet, or one.
  let lastLeashed = { kind: "none" };

  function heardOfCow(c, by) {
    serverCows.set(c.id, { id: c.id, halfX: c.half_x, halfY: c.half_y });
    toldOf.set(c.id, by);
  }

  // ── the leash ─────────────────────────────────────────────────────────────

  // A leash is asked for and the dog moved at once (optimistic); the ack is
  // only said, for now.
  function leashTo(dogId) {
    if (leashed.kind !== "none" && leashed.dogId !== dogId) releaseLeash();
    if (leashed.kind === "kept") clearTimer(leashed.timer);
    const already = leashed.kind !== "none" && leashed.dogId === dogId;
    leashed = { kind: "in_hand", dogId };
    lastLeashed = { kind: "dog", dogId };
    if (already) return;
    post("/leash", { dog: dogId }).then(
      (ack) => log.log("leashed", ack),
      (e) => log.error("leash failed:", e.message),
    );
  }

  // Let go of the dog in your hand: it stays on the leash `leash_kept_ms`.
  function keepOnLeash() {
    if (leashed.kind !== "in_hand") return;
    leashed = { kind: "kept", dogId: leashed.dogId, timer: setTimer(releaseLeash, leash_kept_ms) };
  }

  function releaseLeash() {
    if (leashed.kind === "none") return;
    if (leashed.kind === "kept") clearTimer(leashed.timer);
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

  // **THE PATH THE PAGE SAW**: where a dog is now joins its path when it has
  // moved a whole pixel, and the path goes when nothing is in flight. The
  // server replays the cows' rule along it, segment by segment, as the page
  // does (predictCows).
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

  // The tiles: when none is waiting and the tiles wanted differ from those
  // subscribed, the whole set wanted is sent, each tile marked new (its dogs
  // wanted) or held (its dogs known). The answer is the truth for each new
  // tile: the dogs remembered there are dropped (one may have wandered off),
  // but for one on your leash (in your hand or not), and the answer's dogs
  // taken. A dog in a tile left out is remembered where it was.
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
        const onLeash = (id) => leashed.kind !== "none" && leashed.dogId === id;
        let replaced = 0;
        for (const [id, d] of known) {
          if (!onLeash(id) && fresh.has(tileKey(tileOf(d.parkX, d.parkY)))) { known.delete(id); replaced++; }
        }
        for (const d of ack.dogs) {
          if (onLeash(d.id) || moving(d.id)) continue;
          known.set(d.id, { id: d.id, emoji: d.emoji, parkX: d.park_x, parkY: d.park_y });
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
  // seen, never changes, so a frame only adds to this. In park pixels, to
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

  return {
    async load(measure) {
      const me = await getJSON("/me");
      Object.assign(viewport, measure());
      if (me.viewport.at) {
        Object.assign(viewport, viewportKeptOnWorld(viewport, me.viewport.at.park_x, me.viewport.at.park_y));
      } else {
        // A first visit starts at the world's centre.
        viewport.parkX = Math.round(world_px / 2 - viewport.width / 2);
        viewport.parkY = Math.round(world_px / 2 - viewport.height / 2);
        sendViewport();
      }
      // A dog still on your leash from before the reload: kept on it the
      // usual time from now, then let go.
      if (me.leash.dog !== undefined) {
        leashed = { kind: "kept", dogId: me.leash.dog, timer: setTimer(releaseLeash, leash_kept_ms) };
      }
    },

    resize({ width, height }) {
      viewport.width = width;
      viewport.height = height;
    },

    intent(i) {
      switch (i.kind) {
        case "grab": leashTo(i.dogId); break;
        case "drag": {
          const dog = heldDog(i.dogId);
          dog.parkX = i.parkX;
          dog.parkY = i.parkY;
          sendMove(i.dogId);
          break;
        }
        case "letgo": keepOnLeash(); break;
        case "pan":
          viewport.parkX = i.parkX;
          viewport.parkY = i.parkY;
          sendViewport();
          break;
        default: throw new Error(`no intent ${i.kind}`);
      }
    },

    // Each frame: the tiles wanted asked for, and the cows drawn predicted
    // afresh, any that jumped said.
    frame() {
      syncTiles();
      const drawn = predictCows();
      sayJumps(knownCows, drawn);
      knownCows = drawn;
    },

    view() {
      const plain = (l) => (l.kind === "none" ? { kind: "none" } : { kind: l.kind, dogId: l.dogId });
      return {
        viewport: { ...viewport },
        dogs: new Map([...known].map(([id, d]) => [id, { ...d }])),
        cows: [...knownCows.values()].map((c) => ({ ...c })),
        subscribed: new Set(subscribed.keys()),
        leashed: plain(leashed),
        lastLeashed: plain(lastLeashed),
      };
    },
  };
}
