// Dog Park, the browser's half. Plain JavaScript, no bundler, embedded by
// the server (app.zig) like any asset. Structured by the same names as the
// Zig: frames, wire, state, drag, scroll, the blitter.
//
// ONE SCALE: a park unit is one CSS pixel, so a displacement is the same in
// every frame. EVERY VARIABLE SAYS ITS FRAME: planeX (the plane the park
// tiles, where the viewport lives), viewportX (from the viewport's top-left),
// ownDogDx (a drag, the own dog's displacement). Park points never reach the
// browser: the server sends plane copies.
"use strict";

// ── frames ──────────────────────────────────────────────────────────────────

const frames = {
  // frames.zig's Viewport.fromPlane and toPlane.
  viewportFromPlane(viewport, planeX, planeY) {
    return { viewportX: planeX - viewport.planeX, viewportY: planeY - viewport.planeY };
  },
  planeFromViewport(viewport, viewportX, viewportY) {
    return { planeX: viewport.planeX + viewportX, planeY: viewport.planeY + viewportY };
  },
  // park.zig's nearestCopy, on one axis: the copy of planeX, a whole number
  // of park sizes away, nearest nearPlaneX (a tie goes east or south).
  nearestCopy(parkSide, planeX, nearPlaneX) {
    return planeX + Math.floor((nearPlaneX - planeX + Math.floor(parkSide / 2)) / parkSide) * parkSide;
  },
  // How far to shift a viewport's origin so it is back in the park's home
  // tile, [0, parkSide): a whole number of park sizes, so nothing on screen
  // moves (every plane point shifts with it).
  homeShift(parkSide, planeX) {
    return 0 - Math.floor(planeX / parkSide) * parkSide;
  },
};

// ── wire ────────────────────────────────────────────────────────────────────
// The request and the answer exactly as wire.zig has them.

// A request that hangs gives up, so the next ask is not blocked behind it.
const ask_gives_up_ms = 5000;

async function fetchScene(viewport, move) {
  const request = {
    viewport_plane_x: Math.round(viewport.planeX),
    viewport_plane_y: Math.round(viewport.planeY),
    viewport_width: viewport.width,
    viewport_height: viewport.height,
    move: move.ownDogDx === 0 && move.ownDogDy === 0
      ? { stay: {} }
      : { drag: { own_dog_dx: move.ownDogDx, own_dog_dy: move.ownDogDy } },
  };
  const response = await fetch("/scene", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(request),
    credentials: "same-origin",
    signal: AbortSignal.timeout(ask_gives_up_ms),
  });
  if (!response.ok) throw new Error(`POST /scene: ${response.status}`);
  return response.json();
}

// ── state ───────────────────────────────────────────────────────────────────

const state = {
  // The viewport, in the plane: its origin kept in the park's home tile.
  viewport: { planeX: 0, planeY: 0, width: 0, height: 0 },
  // The last scene answered (wire.WireScene), its plane points shifted with
  // the viewport's origin.
  scene: null,
  // The own dog where the browser draws it: optimistic while dragging.
  ownPlaneX: 0,
  ownPlaneY: 0,
  // The drag not yet sent.
  unsentOwnDogDx: 0,
  unsentOwnDogDy: 0,
  // The ask loop, one value (askAfter below says how it moves):
  //   { kind: "idle", wants: "nothing" | "a_scene", lastAskedMs }
  //   { kind: "asking", thenWants: "nothing" | "a_scene", lastAskedMs }
  //   { kind: "backing_off", untilMs, failures }     after a failure
  //   { kind: "retrying", failures }                 backed off, due again
  //   { kind: "asking_again", failures, lastAskedMs } a retry is out
  ask: { kind: "idle", wants: "a_scene", lastAskedMs: 0 },
};

// ── the ask loop ────────────────────────────────────────────────────────────
// Pure: the loop's next value, for an event at `nowMs`. Events:
//   "want_a_scene"  something wants one (the first, a new dog, a resize, the
//                   viewport near the covered region's edge, an idle second)
//   "sent"          a request went
//   "answered"      it came back whole
//   "failed"        it did not (a 4xx, a 5xx, the network, given up on)
//   "tick"          time passed
// A failure backs off, doubling from half a second to half a minute, so a
// page that cannot be answered does not ask twelve times a second for ever.

const backoff_first_ms = 500;
const backoff_most_ms = 30000;

function askAfter(ask, event, nowMs) {
  switch (ask.kind) {
    case "idle":
      if (event === "want_a_scene") return { ...ask, wants: "a_scene" };
      if (event === "sent") return { kind: "asking", thenWants: "nothing", lastAskedMs: nowMs };
      return ask;
    case "asking":
      if (event === "want_a_scene") return { ...ask, thenWants: "a_scene" };
      if (event === "answered") return { kind: "idle", wants: ask.thenWants, lastAskedMs: ask.lastAskedMs };
      if (event === "failed") return { kind: "backing_off", untilMs: nowMs + backoff_first_ms, failures: 1 };
      return ask;
    case "backing_off":
      if (event === "tick" && nowMs >= ask.untilMs) return { kind: "retrying", failures: ask.failures };
      return ask;
    case "retrying":
      // Backed off: the next request is a retry, and its failure backs off
      // longer.
      if (event === "sent") return { kind: "asking_again", failures: ask.failures, lastAskedMs: nowMs };
      return ask;
    case "asking_again":
      if (event === "answered") return { kind: "idle", wants: "nothing", lastAskedMs: ask.lastAskedMs };
      if (event === "failed") {
        const failures = ask.failures + 1;
        return { kind: "backing_off", untilMs: nowMs + Math.min(backoff_most_ms, backoff_first_ms * 2 ** (failures - 1)), failures };
      }
      return ask;
  }
  return ask;
}

// Whether, in this value, a request should go now.
function askingIsDue(ask, unsentMove, nowMs) {
  switch (ask.kind) {
    case "idle":
      return ask.wants === "a_scene" || unsentMove || nowMs - ask.lastAskedMs > idle_ask_every_ms;
    case "retrying":
      return true;
    default:
      return false;
  }
}

function want() {
  state.ask = askAfter(state.ask, "want_a_scene", performance.now());
}

function parkWidth() { return state.scene ? state.scene.park_width : 1; }
function parkHeight() { return state.scene ? state.scene.park_height : 1; }

// How far, in all, the viewport's origin has been carried home by wrapping:
// a whole number of park sizes on each axis. A request notes it as sent, so
// its answer's plane points are shifted by what was wrapped since.
const wrapped = { planeDx: 0, planeDy: 0 };

// Every plane point the browser holds, moved by whole park sizes: the
// viewport's origin wrapping home, so nothing on screen moves.
function shiftPlane(planeDx, planeDy) {
  wrapped.planeDx += planeDx;
  wrapped.planeDy += planeDy;
  state.viewport.planeX += planeDx;
  state.viewport.planeY += planeDy;
  state.ownPlaneX += planeDx;
  state.ownPlaneY += planeDy;
  if (state.scene) shiftScene(state.scene, planeDx, planeDy);
}

// The scene's own dog (wire.zig's WireOwnDog), or null when no dog was free
// for us: the page is read-only then (docs/CLAIMS-V1.md).
function ownDog(scene) {
  return scene && scene.own.has_dog ? scene.own.has_dog : null;
}

function shiftScene(scene, planeDx, planeDy) {
  scene.covers_plane_x += planeDx;
  scene.covers_plane_y += planeDy;
  const own = ownDog(scene);
  if (own) { own.plane_x += planeDx; own.plane_y += planeDy; }
  for (const d of scene.others) { d.plane_x += planeDx; d.plane_y += planeDy; }
}

function wrapViewportHome() {
  if (!state.scene) return;
  const planeDx = frames.homeShift(parkWidth(), state.viewport.planeX);
  const planeDy = frames.homeShift(parkHeight(), state.viewport.planeY);
  if (planeDx !== 0 || planeDy !== 0) shiftPlane(planeDx, planeDy);
}

// An answer arrived for a request sent when the origin had wrapped by
// `wrappedAtSend`. **THE ANSWER IS THE TRUTH**: the own dog is put where the
// server has it (the copy near the viewport, as answered) plus whatever has
// been dragged since the request went, so a request the server applied but
// the browser saw fail is made good by the next answer, and a refusal puts
// the dog back where it came from, on screen.
function take(answer, wrappedAtSend) {
  const scene = answer.scene;
  shiftScene(scene, wrapped.planeDx - wrappedAtSend.planeDx, wrapped.planeDy - wrappedAtSend.planeDy);
  const first = state.scene === null;
  state.scene = scene;
  const own = ownDog(scene);
  if (!own) {
    // **NO DOG FREE FOR US: READ-ONLY.** Nothing ringed, nothing to drag (a
    // drag of the background pans instead), and the ask loop keeps its idle
    // pace; a later answer with a dog centres on it.
    state.unsentOwnDogDx = 0;
    state.unsentOwnDogDy = 0;
    drag.active = false;
    return;
  }
  if (first || own.is === "new_dog") {
    // The first scene, or a dog newly ours (perhaps not the one shown, or
    // given again after ours ended undragged, or the first after a
    // read-only spell): centre the viewport on it, drop any drag meant for
    // another, and ask again.
    state.unsentOwnDogDx = 0;
    state.unsentOwnDogDy = 0;
    drag.active = false;
    state.ownPlaneX = own.plane_x;
    state.ownPlaneY = own.plane_y;
    state.viewport.planeX = state.ownPlaneX - Math.floor(state.viewport.width / 2);
    state.viewport.planeY = state.ownPlaneY - Math.floor(state.viewport.height / 2);
    wrapViewportHome();
    want();
    return;
  }
  switch (own.move) {
    case "stayed":
    case "moved":
      break;
    default:
      // Refused: the drag since is dropped too.
      state.unsentOwnDogDx = 0;
      state.unsentOwnDogDy = 0;
      break;
  }
  state.ownPlaneX = own.plane_x + state.unsentOwnDogDx;
  state.ownPlaneY = own.plane_y + state.unsentOwnDogDy;
}

// Whole park units only cross the wire: a pointer's fraction stays behind,
// in what is not yet sent.
// At most `longest_drag_px` on an axis goes in one request (outcomes.zig's
// longest_drag); the rest waits for the next.
const longest_drag_px = 2000;

function sendableUnits(ownDogD) {
  return Math.max(-longest_drag_px, Math.min(longest_drag_px, Math.trunc(ownDogD)));
}

async function ask() {
  const move = { ownDogDx: sendableUnits(state.unsentOwnDogDx), ownDogDy: sendableUnits(state.unsentOwnDogDy) };
  const unsentMove = move.ownDogDx !== 0 || move.ownDogDy !== 0;
  state.ask = askAfter(state.ask, "tick", performance.now());
  if (!askingIsDue(state.ask, unsentMove, performance.now())) return;
  state.ask = askAfter(state.ask, "sent", performance.now());
  state.unsentOwnDogDx -= move.ownDogDx;
  state.unsentOwnDogDy -= move.ownDogDy;
  const wrappedAtSend = { ...wrapped };
  let answer;
  try {
    answer = await fetchScene(state.viewport, move);
  } catch (e) {
    // A failed request snaps the dog back to the last answer, dropping the
    // drag since; the next answer says whether the server applied it.
    console.warn(e);
    const own = ownDog(state.scene);
    if (own) {
      state.unsentOwnDogDx = 0;
      state.unsentOwnDogDy = 0;
      state.ownPlaneX = own.plane_x;
      state.ownPlaneY = own.plane_y;
    }
    state.ask = askAfter(state.ask, "failed", performance.now());
    return;
  }
  state.ask = askAfter(state.ask, "answered", performance.now());
  take(answer, wrappedAtSend);
}

// ── drag ────────────────────────────────────────────────────────────────────

const dog_px = 40;
// A drag is of the own dog, or, read-only, of the background (`kind`).
const drag = { active: false, kind: "dog", lastViewportX: 0, lastViewportY: 0, pointerViewportX: 0, pointerViewportY: 0 };

// What a press at a viewport point starts: a drag of the own dog (on it), a
// pan (read-only, anywhere), or nothing.
function pressStarts(viewportX, viewportY) {
  if (!state.scene) return "nothing";
  if (!ownDog(state.scene)) return "pan";
  const own = frames.viewportFromPlane(state.viewport, state.ownPlaneX, state.ownPlaneY);
  if (Math.abs(viewportX - own.viewportX) > dog_px / 2 || Math.abs(viewportY - own.viewportY) > dog_px / 2) return "nothing";
  return "dog";
}

// The background dragged by a pointer's displacement: the park follows the
// pointer, so the viewport moves the other way, and wraps home as ever.
function panBy(viewportDx, viewportDy) {
  state.viewport.planeX -= viewportDx;
  state.viewport.planeY -= viewportDy;
  wrapViewportHome();
}

function moveOwnDog(ownDogDx, ownDogDy) {
  state.ownPlaneX += ownDogDx;
  state.ownPlaneY += ownDogDy;
  state.unsentOwnDogDx += ownDogDx;
  state.unsentOwnDogDy += ownDogDy;
}

function startDrag(e) {
  const starts = pressStarts(e.offsetX, e.offsetY);
  if (starts === "nothing") return;
  drag.active = true;
  drag.kind = starts;
  drag.lastViewportX = drag.pointerViewportX = e.offsetX;
  drag.lastViewportY = drag.pointerViewportY = e.offsetY;
  e.target.setPointerCapture(e.pointerId);
}

function continueDrag(e) {
  if (!drag.active) return;
  if (drag.kind === "pan") panBy(e.offsetX - drag.lastViewportX, e.offsetY - drag.lastViewportY);
  else moveOwnDog(e.offsetX - drag.lastViewportX, e.offsetY - drag.lastViewportY);
  drag.lastViewportX = drag.pointerViewportX = e.offsetX;
  drag.lastViewportY = drag.pointerViewportY = e.offsetY;
}

function endDrag() { drag.active = false; }

// ── scroll ──────────────────────────────────────────────────────────────────

const edge_px = 40;
const scroll_px_per_frame = 8;
// How close to the covered region's edge the viewport may come before a new
// scene is asked for.
const ask_within_px = 60;

// While dragging near a screen edge, the viewport scrolls that way, and the
// dog with it (it stays under the pointer). There is no edge to stop at.
function autoScroll() {
  if (!drag.active || drag.kind !== "dog") return;
  const v = state.viewport;
  let planeDx = 0;
  let planeDy = 0;
  if (drag.pointerViewportX < edge_px) planeDx = -scroll_px_per_frame;
  if (drag.pointerViewportX > v.width - edge_px) planeDx = scroll_px_per_frame;
  if (drag.pointerViewportY < edge_px) planeDy = -scroll_px_per_frame;
  if (drag.pointerViewportY > v.height - edge_px) planeDy = scroll_px_per_frame;
  if (planeDx === 0 && planeDy === 0) return;
  v.planeX += planeDx;
  v.planeY += planeDy;
  moveOwnDog(planeDx, planeDy);
  wrapViewportHome();
}

function nearCoveredEdge() {
  const s = state.scene;
  if (!s) return true;
  const v = state.viewport;
  return v.planeX < s.covers_plane_x + ask_within_px ||
    v.planeY < s.covers_plane_y + ask_within_px ||
    v.planeX + v.width > s.covers_plane_x + s.covers_width - ask_within_px ||
    v.planeY + v.height > s.covers_plane_y + s.covers_height - ask_within_px;
}

// ── the blitter ─────────────────────────────────────────────────────────────
// Owns no logic: given what to draw at viewport points, it clears the canvas
// and draws each emoji in its kind's style.

// Each kind of sprite's look, chosen here and nowhere else.
const sprite_styles = {
  own: { colour: "#000", ring: "#d33" },
  other: { colour: "#000", ring: "none" },
  lattice_spot: { colour: "#ccc", ring: "none" },
};

function blit(canvas, sprites) {
  const ratio = window.devicePixelRatio || 1;
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, canvas.width / ratio, canvas.height / ratio);
  ctx.font = `${dog_px}px serif`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  for (const s of sprites) {
    const style = sprite_styles[s.kind];
    if (style.ring !== "none") {
      ctx.beginPath();
      ctx.arc(s.viewportX, s.viewportY, dog_px * 0.7, 0, 2 * Math.PI);
      ctx.lineWidth = 3;
      ctx.strokeStyle = style.ring;
      ctx.stroke();
    }
    ctx.fillStyle = style.colour;
    ctx.fillText(s.emoji, s.viewportX, s.viewportY);
  }
}

// ── what to draw ────────────────────────────────────────────────────────────

// The lattice's spots in view, faint, so a scroll can be seen; then the
// others the scene sent; then every copy of the own dog in view (a screen
// wider than the park sees more than one); each at its viewport point.
const lattice_px = 100;
function sprites() {
  const s = state.scene;
  if (!s) return [];
  const v = state.viewport;
  const out = [];
  const half = lattice_px / 2;
  const firstSpotPlaneX = Math.floor((v.planeX - half) / lattice_px) * lattice_px + half;
  const firstSpotPlaneY = Math.floor((v.planeY - half) / lattice_px) * lattice_px + half;
  for (let planeX = firstSpotPlaneX; planeX < v.planeX + v.width + half; planeX += lattice_px) {
    for (let planeY = firstSpotPlaneY; planeY < v.planeY + v.height + half; planeY += lattice_px) {
      const at = frames.viewportFromPlane(v, planeX, planeY);
      out.push({ viewportX: at.viewportX, viewportY: at.viewportY, emoji: "\u00b7", kind: "lattice_spot" });
    }
  }
  for (const d of s.others) {
    const at = frames.viewportFromPlane(v, d.plane_x, d.plane_y);
    out.push({ viewportX: at.viewportX, viewportY: at.viewportY, emoji: d.emoji, kind: "other" });
  }
  const own = ownDog(s);
  if (!own) return out; // read-only: no dog of ours to draw
  const firstPlaneX = frames.nearestCopy(s.park_width, state.ownPlaneX, v.planeX) - s.park_width;
  const firstPlaneY = frames.nearestCopy(s.park_height, state.ownPlaneY, v.planeY) - s.park_height;
  for (let planeX = firstPlaneX; planeX < v.planeX + v.width + dog_px; planeX += s.park_width) {
    for (let planeY = firstPlaneY; planeY < v.planeY + v.height + dog_px; planeY += s.park_height) {
      const at = frames.viewportFromPlane(v, planeX, planeY);
      if (at.viewportX < -dog_px || at.viewportY < -dog_px) continue;
      out.push({ viewportX: at.viewportX, viewportY: at.viewportY, emoji: own.emoji, kind: "own" });
    }
  }
  return out;
}

// ── the loop ────────────────────────────────────────────────────────────────

const ask_every_ms = 80;
// With nothing else asked, how often a stay asks what the others are doing
// (until the server can tell, later, by SSE).
const idle_ask_every_ms = 1000;

function fitCanvas(canvas) {
  const ratio = window.devicePixelRatio || 1;
  state.viewport.width = Math.max(1, Math.floor(canvas.clientWidth));
  state.viewport.height = Math.max(1, Math.floor(canvas.clientHeight));
  canvas.width = Math.floor(state.viewport.width * ratio);
  canvas.height = Math.floor(state.viewport.height * ratio);
}

function start() {
  const canvas = document.getElementById("park");
  fitCanvas(canvas);
  window.addEventListener("resize", () => { fitCanvas(canvas); want(); });
  canvas.addEventListener("pointerdown", startDrag);
  canvas.addEventListener("pointermove", continueDrag);
  canvas.addEventListener("pointerup", endDrag);
  canvas.addEventListener("pointercancel", endDrag);
  setInterval(() => {
    if (state.scene && nearCoveredEdge()) want();
    ask();
  }, ask_every_ms);
  const frame = () => {
    autoScroll();
    blit(canvas, sprites());
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}

if (typeof document !== "undefined") start();
