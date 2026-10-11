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
    return -Math.floor(planeX / parkSide) * parkSide;
  },
};

// ── wire ────────────────────────────────────────────────────────────────────
// The request and the answer exactly as wire.zig has them.

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
  // The drag not yet sent, and whether a request is out.
  unsentOwnDogDx: 0,
  unsentOwnDogDy: 0,
  asking: false,
  // A scene is wanted (scrolled near the covered region's edge).
  wantScene: true,
  noRoom: null,
};

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

function shiftScene(scene, planeDx, planeDy) {
  scene.covers_plane_x += planeDx;
  scene.covers_plane_y += planeDy;
  scene.own.plane_x += planeDx;
  scene.own.plane_y += planeDy;
  for (const d of scene.others) { d.plane_x += planeDx; d.plane_y += planeDy; }
}

function wrapViewportHome() {
  if (!state.scene) return;
  const planeDx = frames.homeShift(parkWidth(), state.viewport.planeX);
  const planeDy = frames.homeShift(parkHeight(), state.viewport.planeY);
  if (planeDx !== 0 || planeDy !== 0) shiftPlane(planeDx, planeDy);
}

// An answer arrived for a request sent when the origin had wrapped by
// `wrappedAtSend`.
function take(answer, wrappedAtSend) {
  if (answer.no_room) { state.noRoom = answer.no_room; return; }
  const scene = answer.scene;
  shiftScene(scene, wrapped.planeDx - wrappedAtSend.planeDx, wrapped.planeDy - wrappedAtSend.planeDy);
  const first = state.scene === null;
  state.scene = scene;
  if (first) {
    // The first scene: centre the viewport on the own dog, and ask again.
    state.ownPlaneX = scene.own.plane_x;
    state.ownPlaneY = scene.own.plane_y;
    state.viewport.planeX = state.ownPlaneX - Math.floor(state.viewport.width / 2);
    state.viewport.planeY = state.ownPlaneY - Math.floor(state.viewport.height / 2);
    wrapViewportHome();
    state.wantScene = true;
    return;
  }
  switch (scene.move) {
    case "stayed":
    case "moved":
      // The drag was kept: the optimistic place stands.
      break;
    default:
      // Refused: the dog snaps back to the server's.
      snapBackTo(scene.own);
      break;
  }
}

// The dog put where the server has it, at the copy nearest where it was
// drawn, and the drag since dropped.
function snapBackTo(own) {
  state.ownPlaneX = frames.nearestCopy(parkWidth(), own.plane_x, state.ownPlaneX);
  state.ownPlaneY = frames.nearestCopy(parkHeight(), own.plane_y, state.ownPlaneY);
  state.unsentOwnDogDx = 0;
  state.unsentOwnDogDy = 0;
}

async function ask() {
  if (state.asking) return;
  const move = { ownDogDx: state.unsentOwnDogDx, ownDogDy: state.unsentOwnDogDy };
  if (!state.wantScene && move.ownDogDx === 0 && move.ownDogDy === 0) return;
  state.asking = true;
  state.wantScene = false;
  state.unsentOwnDogDx = 0;
  state.unsentOwnDogDy = 0;
  const wrappedAtSend = { ...wrapped };
  try {
    take(await fetchScene(state.viewport, move), wrappedAtSend);
  } catch (e) {
    // A failed request snaps the dog back to the last answer.
    console.warn(e);
    if (state.scene) snapBackTo(state.scene.own);
    state.wantScene = true;
  } finally {
    state.asking = false;
  }
}

// ── drag ────────────────────────────────────────────────────────────────────

const dog_px = 40;
const drag = { active: false, lastViewportX: 0, lastViewportY: 0, pointerViewportX: 0, pointerViewportY: 0 };

function moveOwnDog(ownDogDx, ownDogDy) {
  state.ownPlaneX += ownDogDx;
  state.ownPlaneY += ownDogDy;
  state.unsentOwnDogDx += ownDogDx;
  state.unsentOwnDogDy += ownDogDy;
}

function startDrag(e) {
  if (!state.scene) return;
  const own = frames.viewportFromPlane(state.viewport, state.ownPlaneX, state.ownPlaneY);
  if (Math.abs(e.offsetX - own.viewportX) > dog_px / 2 || Math.abs(e.offsetY - own.viewportY) > dog_px / 2) return;
  drag.active = true;
  drag.lastViewportX = drag.pointerViewportX = e.offsetX;
  drag.lastViewportY = drag.pointerViewportY = e.offsetY;
  e.target.setPointerCapture(e.pointerId);
}

function continueDrag(e) {
  if (!drag.active) return;
  moveOwnDog(e.offsetX - drag.lastViewportX, e.offsetY - drag.lastViewportY);
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
  if (!drag.active) return;
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
// and draws each emoji, the own dog ringed, a faint one pale.

function blit(canvas, sprites) {
  const ratio = window.devicePixelRatio || 1;
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, canvas.width / ratio, canvas.height / ratio);
  ctx.font = `${dog_px}px serif`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  for (const s of sprites) {
    if (s.own) {
      ctx.beginPath();
      ctx.arc(s.viewportX, s.viewportY, dog_px * 0.7, 0, 2 * Math.PI);
      ctx.lineWidth = 3;
      ctx.strokeStyle = "#d33";
      ctx.stroke();
    }
    ctx.fillStyle = s.faint ? "#ccc" : "#000";
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
      out.push({ viewportX: at.viewportX, viewportY: at.viewportY, emoji: "\u00b7", own: false, faint: true });
    }
  }
  for (const d of s.others) {
    const at = frames.viewportFromPlane(v, d.plane_x, d.plane_y);
    out.push({ viewportX: at.viewportX, viewportY: at.viewportY, emoji: d.emoji, own: false, faint: false });
  }
  const firstPlaneX = frames.nearestCopy(s.park_width, state.ownPlaneX, v.planeX) - s.park_width;
  const firstPlaneY = frames.nearestCopy(s.park_height, state.ownPlaneY, v.planeY) - s.park_height;
  for (let planeX = firstPlaneX; planeX < v.planeX + v.width + dog_px; planeX += s.park_width) {
    for (let planeY = firstPlaneY; planeY < v.planeY + v.height + dog_px; planeY += s.park_height) {
      const at = frames.viewportFromPlane(v, planeX, planeY);
      out.push({ viewportX: at.viewportX, viewportY: at.viewportY, emoji: s.own.emoji, own: true, faint: false });
    }
  }
  return out;
}

// ── the loop ────────────────────────────────────────────────────────────────

const ask_every_ms = 80;

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
  window.addEventListener("resize", () => { fitCanvas(canvas); state.wantScene = true; });
  canvas.addEventListener("pointerdown", startDrag);
  canvas.addEventListener("pointermove", continueDrag);
  canvas.addEventListener("pointerup", endDrag);
  canvas.addEventListener("pointercancel", endDrag);
  setInterval(() => {
    if (nearCoveredEdge()) state.wantScene = true;
    ask();
  }, ask_every_ms);
  const frame = () => {
    autoScroll();
    if (state.noRoom) {
      blit(canvas, [{ viewportX: state.viewport.width / 2, viewportY: state.viewport.height / 2, emoji: "🚫", own: false, faint: false }]);
    } else {
      blit(canvas, sprites());
    }
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}

if (typeof document !== "undefined") start();
