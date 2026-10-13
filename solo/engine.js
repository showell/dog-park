// The engine: the page's side of docs/PHYSICS.md, with no DOM. The physics
// runs in the wasm (physics.js), the very code the server judges with; this
// keeps THE RECORD (what the human did, tick by tick), runs it, writes the
// reports and takes the answers. Everything it does over the wire or with
// a clock goes through what `createEngine` is given, so node can drive it;
// one engine is one page load.
//
// **THE RECORD** is a list of entries after the last tick the server kept
// (K), each a line of the report:
//   { kind: "human", t, h, dog, text }   leash, release, grab or letgo at t
//   { kind: "view", t, width, height, tiles, text }
//   { kind: "held", t, tiles, text }
//   { kind: "tick", t, wallMs, drag, checked, flags }   drag as capped
// `cursor` says how many of them the live board has run; past it (a replay
// held back for a tile or the byte budget) they wait. A report carries the
// run entries; the kept ones leave the record, moving the KEPT board on
// (replayed there); a `differ` lays the server's board over KEPT and runs
// the rest of the record again from there (the rewind).
//
//   createEngine({ physics, post, now, wall, setTimer, clearTimer, log, reload })
//     physics     physics.js's wrapper over the wasm
//     post        (path, text) -> Promise of { status, text }; rejects when
//                 nothing came back
//     now         () -> ms, the page's clock (performance.now)
//     wall        () -> Unix ms, recorded in reports as data only
//     setTimer    (ms, fn) -> handle; clearTimer(handle)
//     log         { log, warn, error }, the dev console
//     reload      (why) -> the page loads afresh (a new epoch)
//     budget      the unsent bytes that send a report at once and freeze the
//                 physics: `budget_bytes`, unless a test wants less
//
//   engine.load(measure, at)  POST /load; `measure()` -> { width, height };
//                         `at` a remembered viewport top-left { parkX,
//                         parkY }, or "none" (the world's centre); a
//                         leashed dog is put in the middle of the screen
//   engine.resize({ width, height })
//   engine.intent(i)      a pointer intent (pointer.js): grab, drag, letgo, pan
//   engine.frame(nowMs, panAt)
//                         each frame: the ticks due by `nowMs` run (the first
//                         frame starts the clock and runs none), then a report
//                         goes if one is due; `panAt` is where the pointer holds
//                         a pan (pointer.js's panPointer). Answers the ticks run
//   engine.view()         plain data, copies: { viewport, dogs (a Map by id),
//                         cows, subscribed (a Set of tile keys), leashed,
//                         lastLeashed, tick, alpha, was, status, holding }
//   engine.debug()        the protocol's state, for tests and the console

import { LIVE, KEPT, SCRATCH, flag } from "./physics.js";
import { tileKey, subscription, world_px, most_tiles, viewportKeptOnWorld, dog_looks } from "./scene.js";
import { edgeScroll } from "./pointer.js";

// The tick: 16 a second.
export const tick_ms = 62.5;
// A stall catches up at most this many ticks; the rest are dropped, never owed.
export const most_catch_up_ticks = 8;
// The page runs at most this many ticks past the last kept one.
export const window_ticks = 32;
// A report goes at once at this much unsent text, and the physics freezes
// there (the server's body limit is 64 KiB).
export const budget_bytes = 48 * 1024;
// No sooner than this after the last report went.
export const spacing_ms = 250;
// An exchange with no answer in this long is abandoned and tried again.
export const answer_ms = 5000;
// Between tries of one request: 5 s, then 10, 20, 40, and 60 for ever.
export const backoff_ms = [5000, 10000, 20000, 40000, 60000];
// The most of the human's inputs at one tick.
export const most_humans = 16;

// The ticks a frame at `nowMs` runs, the last tick having begun at
// `lastTickMs`: those whose start has come, at most `most_catch_up_ticks`;
// and when the last of them began (`nowMs` itself when some were dropped).
export function ticksDue(lastTickMs, nowMs) {
  const due = Math.max(0, Math.floor((nowMs - lastTickMs) / tick_ms));
  if (due <= most_catch_up_ticks) return { ticks: due, lastTickMs: lastTickMs + due * tick_ms, dropped: 0 };
  return { ticks: most_catch_up_ticks, lastTickMs: nowMs, dropped: due - most_catch_up_ticks };
}

const keyed = (tiles) => new Map(tiles.map((t) => [tileKey(t), t]));
const sameKeys = (a, b) => a.size === b.size && [...a.keys()].every((k) => b.has(k));
const px = (v256) => v256 / 256;

export function createEngine({ physics, post, now, wall, setTimer, clearTimer, log, reload, budget = budget_bytes }) {
  // ── what the page shows ───────────────────────────────────────────────────

  const viewport = { parkX: 0, parkY: 0, width: 0, height: 0 };
  // "loading" | "playing" | { stopped: message } | { reloading: why }
  let status = { kind: "loading" };
  // The critters on the live board, drawn; and where they were at the tick
  // before (the frames draw between).
  let dogs = new Map();
  let cows = new Map();
  let wasDogs = new Map();
  let wasCows = new Map();
  const wasViewport = { parkX: 0, parkY: 0 };
  let lastLeashed = { kind: "none" };

  // ── the protocol's state ──────────────────────────────────────────────────

  let epoch = null; // { ms, count }
  let K = 0; // the last kept tick
  // The human's inputs the server kept for K + 1 ({ h, dog }), and the view
  // and held tiles in effect there.
  let keptInputs = [];
  let keptView = { width: 0, height: 0, tiles: new Map() };
  let keptHeld = new Map();
  // The record past K, and how much of it the live board has run.
  let record = [];
  let cursor = 0;
  // The view and held tiles at the cursor.
  let view = { width: 0, height: 0, tiles: new Map() };
  let held = new Map();
  // Every tile whose critters came in a `tile` line this epoch.
  const received = new Set();
  // The last subscription wanted, so a coalesced view isn't written again.
  let lastWanted = "";
  // Requests: the last number used, the one in flight ({ req, count, x }),
  // when the last went, and how many have been answered this epoch.
  let req = 0;
  let flight = null;
  let lastSendMs = -Infinity;
  let answered = 0;
  // The exchange in flight (a load's or a report's), and a count to tell a
  // late answer from the current one.
  let current = null;
  let exchanges = 0;

  // ── the tick ──────────────────────────────────────────────────────────────

  let clock = "unstarted";
  let alpha = 1;
  // Whether the page ticks: a rest or a release stops it; the human's input
  // starts it.
  let ticking = false;
  // Whether the pointer holds the leashed dog (a grab or leash until a
  // letgo or a bump).
  let holding = false;
  // A replay gained a bump: its drags and letgos are dropped until a grab.
  let dropping = false;
  // The pointer's displacements since the last tick, in 256ths ([dx, dy,
  // ms]), and the fractions of a 256th not yet given.
  let pendingDrag = [];
  const fraction = { x: 0, y: 0 };

  // ── the record ────────────────────────────────────────────────────────────

  function lastTick() {
    for (let i = record.length - 1; i >= 0; i--) if (record[i].kind === "tick") return record[i].t;
    return K;
  }
  const nextTick = () => lastTick() + 1;
  // Where the unsent entries start: past the request in flight.
  const unsentFrom = () => (flight ? flight.count : 0);

  function bytesOf(e) {
    if (e.kind === "tick") return e.checked.length + 24 + 26 * e.drag.length;
    return e.text.length;
  }

  function unsentBytes() {
    let n = 0;
    for (let i = unsentFrom(); i < cursor; i++) n += bytesOf(record[i]);
    return n;
  }

  function humansAt(t) {
    let n = t === K + 1 ? keptInputs.length : 0;
    for (const e of record) if (e.kind === "human" && e.t === t) n++;
    return n;
  }

  function applyView(e) {
    view = { width: e.width, height: e.height, tiles: keyed(e.tiles) };
    for (const k of [...held.keys()]) if (!view.tiles.has(k)) held.delete(k);
  }

  function applyHeld(e) {
    for (const t of e.tiles) held.set(tileKey(t), t);
  }

  // An entry added at the end: run at once when everything before it has.
  function append(e) {
    record.push(e);
    if (cursor === record.length - 1) {
      if (e.kind === "view") applyView(e);
      else if (e.kind === "held") applyHeld(e);
      cursor++;
    }
  }

  // The unsent entry of `kind` at tick `t` just before `at` (only inputs of
  // that tick between), to coalesce into; or null.
  function coalescing(kind, t, at) {
    for (let i = at - 1; i >= unsentFrom(); i--) {
      const e = record[i];
      if (e.t !== t || e.kind === "tick") return null;
      if (e.kind === kind) return e;
    }
    return null;
  }

  // **A VIEW AT TICK t**: the page coalesces a tick's views to one, the
  // union of every view written for it (the newest's tiles first, at most
  // 64), so a tile one of them added is never dropped. Inserted at `at`.
  function writeView(t, wanted, at = record.length) {
    const width = Math.round(viewport.width);
    const height = Math.round(viewport.height);
    const tiles = [...keyed(wanted).values()].slice(0, most_tiles);
    const into = coalescing("view", t, at);
    if (into) {
      const union = keyed(tiles);
      for (const old of into.tiles) if (union.size < most_tiles && !union.has(tileKey(old))) union.set(tileKey(old), old);
      into.tiles = [...union.values()];
      into.width = width;
      into.height = height;
      into.text = physics.viewLine(t, width, height, into.tiles);
      if (record.indexOf(into) < cursor) applyView(into);
      return;
    }
    const e = { kind: "view", t, width, height, tiles: [...tiles], text: physics.viewLine(t, width, height, tiles) };
    if (at === record.length) return append(e);
    record.splice(at, 0, e);
    applyView(e);
    cursor++;
  }

  // **A HELD AT TICK t**, coalesced the same way.
  function writeHeld(t, tiles, at = record.length) {
    const into = coalescing("held", t, at);
    if (into) {
      const union = keyed(into.tiles);
      for (const n of tiles) union.set(tileKey(n), n);
      into.tiles = [...union.values()];
      into.text = physics.heldLine(t, into.tiles);
      if (record.indexOf(into) < cursor) applyHeld(into);
      return;
    }
    const e = { kind: "held", t, tiles: [...tiles], text: physics.heldLine(t, tiles) };
    if (at === record.length) return append(e);
    record.splice(at, 0, e);
    applyHeld(e);
    cursor++;
  }

  // **ONE OF THE HUMAN'S INPUTS** at the next tick: run at once on the live
  // board when nothing waits before it. A 17th at one tick is dropped, as
  // is one whose precondition fails; both are said.
  function writeHuman(h, dog = 0) {
    const t = nextTick();
    if (humansAt(t) >= most_humans) {
      log.warn(`a ${h} at tick ${t} dropped: ${most_humans} inputs there already`);
      return false;
    }
    const e = { kind: "human", t, h, dog, text: "" };
    if (cursor === record.length) {
      const r = physics.human(LIVE, h, t, dog);
      if (r.refused !== undefined) {
        log.warn(`a ${h} ${dog} at tick ${t} refused (${r.refused}), dropped`);
        return false;
      }
      e.text = r.text;
      record.push(e);
      cursor++;
    } else record.push(e);
    ticking = true;
    return true;
  }

  // **THE SUBSCRIPTION** (decision 13): the region's tiles and the display's,
  // written as a view at the next tick when what the page wants changes;
  // and a held for every tile in the view whose critters came this epoch
  // and that isn't held. Only with nothing waiting in the record.
  function syncSubscription() {
    if (cursor !== record.length || status.kind !== "playing") return;
    const t = nextTick();
    const want = subscription(physics.region(LIVE), viewport);
    const wantKey = `${Math.round(viewport.width)}x${Math.round(viewport.height)} ${want.map(tileKey).sort().join(" ")}`;
    if (wantKey !== lastWanted) {
      lastWanted = wantKey;
      const same = sameKeys(keyed(want), view.tiles) && view.width === Math.round(viewport.width) && view.height === Math.round(viewport.height);
      if (!same) writeView(t, want);
    }
    const toHold = [...view.tiles.values()].filter((n) => received.has(tileKey(n)) && !held.has(tileKey(n)));
    if (toHold.length) writeHeld(t, toHold);
  }

  const regionHeld = () => physics.region(LIVE).every((n) => held.has(tileKey(n)));

  // ── the live tick ─────────────────────────────────────────────────────────

  // One 62.5 ms slot: the record's waiting entries first; then, when the
  // page ticks and nothing freezes it, the next tick with the pointer's
  // drag and the edge bands'.
  function slot(panAt) {
    wasViewport.parkX = viewport.parkX;
    wasViewport.parkY = viewport.parkY;
    wasDogs = dogs;
    wasCows = cows;
    if (status.kind !== "playing") return;
    if (cursor < record.length) {
      resume();
      if (cursor < record.length) return;
    }
    const dragOn = physics.drag(LIVE) === "on";
    if (!(holding && dragOn) && panAt !== "none") {
      for (const e of edgeScroll({ kind: "pan", x: panAt.x, y: panAt.y }, viewport)) moveViewport(e.parkX, e.parkY);
    }
    if (pendingDrag.length && dragOn) ticking = true;
    if (!ticking) return;
    const t = nextTick();
    if (t > K + window_ticks) return;
    if (unsentBytes() >= budget) return;
    syncSubscription();
    if (!regionHeld()) return;
    const drag = pendingDrag;
    pendingDrag = [];
    // The edge band carries the held dog, and the viewport follows it as
    // far as the tick took it that way.
    const leashedDog = physics.leashed(LIVE);
    const before = leashedDog === "none" ? null : dogs.get(leashedDog);
    let band = { x: 0, y: 0 };
    if (holding && dragOn && before) {
      const e = edgeScroll({ kind: "dog", dogId: leashedDog, parkX: before.parkX, parkY: before.parkY }, viewport);
      if (e.length) band = { x: e[0].parkX - before.parkX, y: e[0].parkY - before.parkY };
      if (band.x !== 0 || band.y !== 0) drag.push([Math.round(band.x * 256), Math.round(band.y * 256), 0]);
    }
    const r = physics.tick(LIVE, t, drag);
    record.push({ kind: "tick", t, wallMs: wall(), drag: r.drag, checked: r.checked, flags: r.flags });
    cursor++;
    ticked(r.flags);
    refresh(false);
    if (before && (band.x !== 0 || band.y !== 0)) {
      const after = dogs.get(leashedDog);
      const follow = (b, moved) => (b === 0 || Math.sign(moved) !== Math.sign(b) ? 0 : Math.sign(b) * Math.min(Math.abs(b), Math.abs(moved)));
      moveViewport(viewport.parkX + follow(band.x, after.parkX - before.parkX), viewport.parkY + follow(band.y, after.parkY - before.parkY));
    }
  }

  function ticked(flags) {
    if (flags & flag.bump) {
      // The drag is over: the pointer is let go (the leash stays on).
      holding = false;
      pendingDrag = [];
    }
    ticking = !(flags & (flag.rest | flag.release));
  }

  // **THE REPLAY**: the record's entries past the cursor, run on the live
  // board (docs/PHYSICS.md item 6): every input word for word; a view
  // written for a tile the tick's region needs and the view lacks, and a
  // held for one whose critters the page has; stopping at a tick whose
  // region still isn't held (until the tile comes) or at the byte budget.
  // A tick that bumped and no longer does stands as a letgo there; one that
  // bumps now and didn't drops the drags and letgos after it until a grab.
  function resume() {
    while (cursor < record.length) {
      const e = record[cursor];
      if (e.kind === "human") {
        if (dropping && e.h === "letgo") { record.splice(cursor, 1); continue; }
        if (dropping && (e.h === "grab" || e.h === "leash")) dropping = false;
        const r = physics.human(LIVE, e.h, e.t, e.dog);
        if (r.refused !== undefined) {
          log.warn(`replay: a ${e.h} ${e.dog} at tick ${e.t} refused (${r.refused}), dropped`);
          record.splice(cursor, 1);
          continue;
        }
        e.text = r.text;
        cursor++;
        ticking = true;
        continue;
      }
      if (e.kind === "view") { applyView(e); cursor++; continue; }
      if (e.kind === "held") {
        const ok = e.tiles.filter((n) => view.tiles.has(tileKey(n)) && received.has(tileKey(n)));
        if (ok.length === 0) { record.splice(cursor, 1); continue; }
        if (ok.length !== e.tiles.length) { e.tiles = ok; e.text = physics.heldLine(e.t, ok); }
        applyHeld(e);
        cursor++;
        continue;
      }
      if (unsentBytes() >= budget) return;
      const missing = physics.region(LIVE).filter((n) => !held.has(tileKey(n)));
      if (missing.length) {
        const unviewed = missing.filter((n) => !view.tiles.has(tileKey(n)));
        if (unviewed.length) writeView(e.t, [...physics.region(LIVE), ...view.tiles.values()], cursor);
        const holdable = missing.filter((n) => received.has(tileKey(n)));
        if (holdable.length) writeHeld(e.t, holdable, cursor);
        if (!regionHeld()) return;
      }
      const drag = dropping ? [] : e.drag;
      if (e.flags & flag.bump) {
        physics.copy(LIVE, SCRATCH);
        if (!(physics.tick(SCRATCH, e.t, drag).flags & flag.bump)) {
          const r = physics.human(LIVE, "letgo", e.t);
          if (r.text !== undefined) {
            record.splice(cursor, 0, { kind: "human", t: e.t, h: "letgo", dog: 0, text: r.text });
            cursor++;
          }
        }
      }
      const r = physics.tick(LIVE, e.t, drag);
      if ((r.flags & flag.bump) && !(e.flags & flag.bump)) dropping = true;
      e.drag = r.drag;
      e.checked = r.checked;
      e.flags = r.flags;
      cursor++;
      ticked(r.flags);
    }
  }

  // ── what the page draws ───────────────────────────────────────────────────

  // The live board's critters, in park px; `snap`: drawn where they are,
  // with no slide from before (a load, a rewind, a tile's arrival).
  function refresh(snap) {
    const c = physics.critters(LIVE);
    dogs = new Map(c.dogs.map((d) => [d.id, { id: d.id, emoji: dog_looks[d.id % dog_looks.length], parkX: px(d.x), parkY: px(d.y) }]));
    cows = new Map(c.cows.map((d) => [d.id, { id: d.id, parkX: px(d.x), parkY: px(d.y) }]));
    if (snap) {
      wasDogs = dogs;
      wasCows = cows;
    }
  }

  function moveViewport(parkX, parkY) {
    viewport.parkX = parkX;
    viewport.parkY = parkY;
  }

  // ── the wire ──────────────────────────────────────────────────────────────

  // **ONE REQUEST, TRIED UNTIL ANSWERED**: no answer within 5 s, or a 5xx,
  // and it goes again byte for byte, the tries 5, 10, 20, 40 and then 60 s
  // apart, never given up; an answer to an abandoned try is dropped unread.
  function exchange(path, body, onAnswer) {
    const x = { path, body, onAnswer, tries: 0, triedMs: 0, id: 0, timer: null };
    current = x;
    attempt(x);
    return x;
  }

  function attempt(x) {
    const id = ++exchanges;
    x.id = id;
    x.tries++;
    x.triedMs = now();
    x.timer = setTimer(answer_ms, () => failed(x, id, `no answer in ${answer_ms / 1000} s`));
    post(x.path, x.body).then(
      (r) => {
        if (current !== x || x.id !== id) return;
        if (r.status >= 500) return failed(x, id, `a ${r.status}`);
        clearTimer(x.timer);
        current = null;
        x.onAnswer(r);
      },
      (e) => failed(x, id, e.message),
    );
  }

  function failed(x, id, why) {
    if (current !== x || x.id !== id) return;
    clearTimer(x.timer);
    x.id = 0;
    const wait = backoff_ms[Math.min(x.tries - 1, backoff_ms.length - 1)];
    const delay = Math.max(0, x.triedMs + wait - now());
    log.warn(`${x.path}, try ${x.tries}: ${why}; again in ${Math.round(delay)} ms, the same bytes`);
    x.timer = setTimer(delay, () => { if (current === x) attempt(x); });
  }

  function stop(message) {
    status = { kind: "stopped", message };
    if (current && current.timer !== null) clearTimer(current.timer);
    current = null;
    log.error(`Dog Park stopped: ${message}`);
  }

  // A reload answer, a 413, an unreadable answer, `req ?`: the page loads
  // afresh, unless this was the first report after its load, which a load
  // just answered (another would loop).
  function startAgain(why) {
    if (answered === 0) return stop(`the first report after a load was answered ${why}: the page's reports can't be taken`);
    status = { kind: "reloading", why };
    log.warn(`reloading: ${why}`);
    reload(why);
  }

  // **A REPORT**: every run entry, after the header and `from K`; `wall`
  // the first tick's, each `t` line's `+ms` from it.
  function send() {
    const count = cursor;
    const firstTick = record.slice(0, count).find((e) => e.kind === "tick");
    const wallMs = firstTick ? firstTick.wallMs : "none";
    let body = physics.header(epoch, req + 1, K, wallMs);
    for (const e of record.slice(0, count)) {
      body += e.kind === "tick" ? physics.tLine(e.t, e.wallMs - wallMs, e.drag) + e.checked : e.text;
    }
    req++;
    lastSendMs = now();
    flight = { req, count };
    flight.x = exchange("/report", body, takeAnswer);
  }

  function pump() {
    if (status.kind !== "playing") return;
    if (cursor < record.length) resume();
    syncSubscription();
    if (flight || cursor === 0) return;
    if (now() - lastSendMs >= spacing_ms || unsentBytes() >= budget) send();
  }

  // ── the answers ───────────────────────────────────────────────────────────

  function takeAnswer(r) {
    const sent = flight;
    flight = null;
    if (r.status === 413) return startAgain("413, the report past the body limit");
    if (r.status !== 200) return startAgain(`${r.status}`);
    const lines = r.text.split("\n");
    if (lines.at(-1) === "") lines.pop();
    if (lines[0] === "req ?") return startAgain("req ?, its header unreadable");
    if (lines[0] !== `req ${sent.req}`) return startAgain(`"${lines[0]}" to req ${sent.req}`);
    const second = lines[1] ?? "";
    if (second.startsWith("reload ")) return startAgain(second);
    if (second === "taken over") return stop("a newer page load holds the park (another tab, or a reload)");
    if (second.startsWith("stuck ")) return stop(`the physics disagrees with itself at tick ${second.slice(6)}`);
    const kept = /^kept (\d+)$/.exec(second);
    if (!kept) return startAgain(`an answer that doesn't read: "${second}"`);
    const T = Number(kept[1]);
    const rest = lines.slice(2);
    const ok = rest.length && rest[0].startsWith("differ ") ? differ(sent, T, rest) : keep(sent, T, rest);
    if (!ok) return;
    answered++;
    refresh(true);
    pump();
  }

  // **KEPT T**: the request's entries are the server's now: the kept board
  // moves on through them, and they leave the record.
  function keep(sent, T, rest) {
    const entries = record.slice(0, sent.count);
    const ran = entries.filter((e) => e.kind === "tick").map((e) => e.t);
    const last = ran.length ? ran.at(-1) : K;
    if (T !== last) { startAgain(`kept ${T} to a report that ran to ${last}`); return false; }
    advanceKept(entries);
    record.splice(0, sent.count);
    cursor -= sent.count;
    K = T;
    return tileLines(rest);
  }

  // **DIFFER T**: kept through T - 1; the state, the inputs kept for T and
  // the board at T's start laid over the kept board; then the record from T
  // runs again on it (the rewind).
  function differ(sent, keptTo, rest) {
    const m = /^differ (\d+) (.*)$/.exec(rest[0]);
    const T = m ? Number(m[1]) : NaN;
    if (!m || T !== keptTo + 1) { startAgain(`a differ that doesn't read: "${rest[0]}"`); return false; }
    log.warn(`differ at tick ${T}: the server's line ${m[2]}`);
    let at = 1;
    const stateLine = rest[at++] ?? "";
    const inputs = [];
    while ((rest[at] ?? "").startsWith("input ")) inputs.push(rest[at++]);
    const boardLine = rest[at++] ?? "";
    const thenTiles = rest.slice(at);
    const keptPart = record.slice(0, sent.count).filter((e) => e.t < T);
    advanceKept(keptPart);
    K = keptTo;
    const s = physics.readState(stateLine, KEPT);
    if (s === "malformed") { startAgain(`a state line that doesn't read: "${stateLine}"`); return false; }
    keptView = { width: s.view.width, height: s.view.height, tiles: keyed(s.view.tiles) };
    keptHeld = keyed(s.held);
    keptInputs = [];
    for (const line of inputs) {
      const i = physics.readInput(line);
      if (i === "malformed") { startAgain(`an input line that doesn't read: "${line}"`); return false; }
      keptInputs.push({ h: i.h, dog: i.dog });
    }
    if (physics.readBoard(boardLine, KEPT) !== T) { startAgain(`a board line that doesn't read: "${boardLine}"`); return false; }
    record.splice(0, keptPart.length);
    if (!tileLines(thenTiles)) return false;
    rewind();
    return true;
  }

  // The kept board, moved on through entries the server kept: the inputs
  // kept for K + 1 and every entry up to the last tick run; any inputs
  // after it wait for the next tick, kept.
  function advanceKept(entries) {
    const lastTickAt = entries.map((e) => e.kind).lastIndexOf("tick");
    if (lastTickAt >= 0) {
      physics.clearBegun(KEPT);
      for (const i of keptInputs) physics.human(KEPT, i.h, K + 1, i.dog);
      keptInputs = [];
    }
    entries.forEach((e, i) => {
      if (e.kind === "view") {
        keptView = { width: e.width, height: e.height, tiles: keyed(e.tiles) };
        for (const k of [...keptHeld.keys()]) if (!keptView.tiles.has(k)) keptHeld.delete(k);
      } else if (e.kind === "held") {
        for (const n of e.tiles) keptHeld.set(tileKey(n), n);
      } else if (e.kind === "human") {
        if (i > lastTickAt) keptInputs.push({ h: e.h, dog: e.dog });
        else physics.human(KEPT, e.h, e.t, e.dog);
      } else {
        const r = physics.tick(KEPT, e.t, e.drag);
        // The same code on the same inputs: a difference is a page bug.
        if (r.checked !== e.checked) log.error(`the kept board's run of tick ${e.t} differs from the live one's`);
      }
    });
  }

  // The live board from the kept one, and the record run again on it.
  function rewind() {
    physics.copy(KEPT, LIVE);
    physics.clearBegun(LIVE);
    for (const i of keptInputs) physics.human(LIVE, i.h, K + 1, i.dog);
    view = { width: keptView.width, height: keptView.height, tiles: new Map(keptView.tiles) };
    held = new Map(keptHeld);
    cursor = 0;
    dropping = false;
    lastWanted = "";
    ticking = keptInputs.length > 0 || physics.drag(LIVE) !== "none";
    resume();
  }

  // **TILE LINES**: each tile's critters on the live and kept boards, where
  // the page hasn't received them this epoch.
  function tileLines(lines) {
    for (const line of lines) {
      const t = physics.readTile(line, [LIVE, KEPT]);
      if (t === "malformed") { startAgain(`a tile line that doesn't read: "${line.slice(0, 60)}"`); return false; }
      received.add(tileKey(t));
    }
    return true;
  }

  // ── a load ────────────────────────────────────────────────────────────────

  function loaded(r, at, done) {
    if (r.status !== 200) return done(stop(`the load was answered ${r.status}`));
    const lines = r.text.split("\n");
    if (lines.at(-1) === "") lines.pop();
    const first = lines[0] ?? "";
    if (first === "req ?") return done(stop("the server can't read this page's load line"));
    if (first.startsWith("reload physics")) return done(stop(`this page's physics (${physics.hash}) is not the server's (${first.slice(15)}): reload the page`));
    if (first.startsWith("reload ")) return done(stop(`the load was answered "${first}"`));
    if (first.startsWith("stuck ")) return done(stop(`the physics disagrees with itself at tick ${first.slice(6)}`));
    const e = /^epoch (\d+)\.(\d+)$/.exec(first);
    const k = /^kept (\d+)$/.exec(lines[1] ?? "");
    if (!e || !k) return done(stop(`a load answer that doesn't read: "${first}"`));
    physics.reset();
    epoch = { ms: Number(e[1]), count: Number(e[2]) };
    K = Number(k[1]);
    const s = physics.readState(lines[2] ?? "", KEPT);
    if (s === "malformed") return done(stop(`a load's state line that doesn't read: "${lines[2]}"`));
    keptView = { width: s.view.width, height: s.view.height, tiles: keyed(s.view.tiles) };
    keptHeld = keyed(s.held);
    keptInputs = [];
    let i = 3;
    for (; (lines[i] ?? "").startsWith("input "); i++) {
      const input = physics.readInput(lines[i]);
      if (input === "malformed") return done(stop(`a load's input line that doesn't read: "${lines[i]}"`));
      keptInputs.push({ h: input.h, dog: input.dog });
    }
    for (; i < lines.length; i++) {
      const t = physics.readTile(lines[i], [LIVE, KEPT]);
      if (t === "malformed") return done(stop(`a load's tile line that doesn't read: "${lines[i].slice(0, 60)}"`));
      received.add(tileKey(t));
    }
    record = [];
    req = 0;
    answered = 0;
    status = { kind: "playing" };
    rewind();
    refresh(true);
    // The viewport: on the leashed dog, else where it was, else the world's
    // centre (the populated park's middle).
    const leashedDog = physics.leashed(LIVE);
    if (leashedDog !== "none") {
      const d = dogs.get(leashedDog);
      lastLeashed = { kind: "dog", dogId: leashedDog };
      Object.assign(viewport, viewportKeptOnWorld(viewport, d.parkX - viewport.width / 2, d.parkY - viewport.height / 2));
    } else if (at !== "none") {
      Object.assign(viewport, viewportKeptOnWorld(viewport, at.parkX, at.parkY));
    } else {
      viewport.parkX = Math.round(world_px / 2 - viewport.width / 2);
      viewport.parkY = Math.round(world_px / 2 - viewport.height / 2);
    }
    wasViewport.parkX = viewport.parkX;
    wasViewport.parkY = viewport.parkY;
    // A drag on from before: nobody's pointer is down now. A drag on or a
    // timer running: the page ticks at once, so the release lands on the
    // tick it does on the server.
    if (physics.drag(LIVE) === "on") writeHuman("letgo");
    ticking = physics.drag(LIVE) !== "none";
    log.log(`loaded: epoch ${epoch.ms}.${epoch.count}, kept ${K}, ${received.size} tiles, ${dogs.size} dogs and ${cows.size} cows`);
    pump();
    done();
  }

  return {
    load(measure, at = "none") {
      Object.assign(viewport, measure());
      return new Promise((resolve) => {
        exchange("/load", physics.loadLine(Math.round(viewport.width), Math.round(viewport.height)), (r) => loaded(r, at, resolve));
      });
    },

    resize({ width, height }) {
      viewport.width = width;
      viewport.height = height;
    },

    intent(i) {
      if (status.kind !== "playing") return;
      switch (i.kind) {
        case "grab": {
          const leashedNow = physics.leashed(LIVE);
          if (leashedNow === i.dogId) writeHuman("grab");
          else {
            if (leashedNow !== "none") writeHuman("release", leashedNow);
            if (!writeHuman("leash", i.dogId)) return;
          }
          holding = true;
          pendingDrag = [];
          fraction.x = 0;
          fraction.y = 0;
          lastLeashed = { kind: "dog", dogId: i.dogId };
          break;
        }
        case "drag": {
          if (!holding) return;
          // Whole 256ths go to the tick; the fraction stays for the next.
          const x = fraction.x + i.dx * 256;
          const y = fraction.y + i.dy * 256;
          const dx = Math.trunc(x);
          const dy = Math.trunc(y);
          fraction.x = x - dx;
          fraction.y = y - dy;
          const ms = clock === "unstarted" ? 0 : Math.max(0, Math.round(now() - clock.lastTickMs));
          if (dx !== 0 || dy !== 0) pendingDrag.push([dx, dy, ms]);
          break;
        }
        case "letgo":
          if (!holding) return;
          holding = false;
          writeHuman("letgo");
          break;
        case "pan":
          // The viewport moves now, and what the frames slide from with it.
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
      for (let k = 0; k < due.ticks; k++) slot(panAt);
      clock.lastTickMs = due.lastTickMs;
      alpha = Math.min(1, Math.max(0, (nowMs - clock.lastTickMs) / tick_ms));
      pump();
      return due.ticks;
    },

    view() {
      const points = (m) => new Map([...m].map(([id, p]) => [id, { parkX: p.parkX, parkY: p.parkY }]));
      const leashedDog = physics.leashed(LIVE);
      const leashed = leashedDog === "none" ? { kind: "none" } : { kind: physics.drag(LIVE) === "on" ? "in_hand" : "kept", dogId: leashedDog };
      return {
        viewport: { ...viewport },
        dogs: new Map([...dogs].map(([id, d]) => [id, { ...d }])),
        cows: [...cows.values()].map((c) => ({ ...c })),
        subscribed: new Set(view.tiles.keys()),
        leashed,
        lastLeashed: { ...lastLeashed },
        tick: lastTick(),
        alpha,
        was: { viewport: { ...wasViewport }, dogs: points(wasDogs), cows: points(wasCows) },
        status: { ...status },
        holding,
      };
    },

    debug() {
      return {
        K, req, cursor, epoch, ticking, holding, dropping,
        record: record.map((e) => ({ ...e })),
        inFlight: flight ? { req: flight.req, count: flight.count, tries: flight.x.tries } : "none",
        keptInputs: keptInputs.map((i) => ({ ...i })),
        view: [...view.tiles.keys()].sort(),
        held: [...held.keys()].sort(),
        received: [...received].sort(),
        unsentBytes: unsentBytes(),
      };
    },
  };
}
