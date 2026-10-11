// Dog Park, solo: one human, a few dogs, no server.
//
// Milestone 3: the park reaches north and south past the screen. Holding
// your dog near the screen's top or bottom edge scrolls the viewport that
// way, and your dog goes with it at the same speed; the other dogs stay
// where they stand. Each dog shows its park point under it.
//
// TWO FRAMES, both in CSS pixels: a PARK point (parkX, parkY) is where a
// dog stands in the world; a VIEWPORT point (viewportX, viewportY) is
// where it is on the screen, from the screen's top-left. The viewport's
// own top-left is a park point; north is smaller parkY.
"use strict";

const dog_px = 40;

// ── frames ──────────────────────────────────────────────────────────────────

function viewportFromPark(viewport, parkX, parkY) {
  return { viewportX: parkX - viewport.parkX, viewportY: parkY - viewport.parkY };
}

function parkFromViewport(viewport, viewportX, viewportY) {
  return { parkX: viewport.parkX + viewportX, parkY: viewport.parkY + viewportY };
}

// ── the world ───────────────────────────────────────────────────────────────

// Where each dog starts, as fractions of the first screen, so any screen
// starts with the same picture.
const start_fractions = [
  { emoji: "🐕", own: true, fx: 0.5, fy: 0.5 },
  { emoji: "🐩", own: false, fx: 0.3, fy: 0.35 },
  { emoji: "🦮", own: false, fx: 0.7, fy: 0.65 },
];

function makeDogs(viewport) {
  return start_fractions.map((d) => ({
    emoji: d.emoji,
    kind: d.own ? "own" : "other",
    parkX: Math.round(d.fx * viewport.width),
    parkY: Math.round(d.fy * viewport.height),
  }));
}

// A park point kept on screen, a dog's half-size in from each edge: your
// dog never leaves the screen.
function keptOnScreen(viewport, parkX, parkY) {
  const half = dog_px / 2;
  return {
    parkX: Math.min(Math.max(parkX, viewport.parkX + half), viewport.parkX + viewport.width - half),
    parkY: Math.min(Math.max(parkY, viewport.parkY + half), viewport.parkY + viewport.height - half),
  };
}

// ── drag ────────────────────────────────────────────────────────────────────

// Where the pointer grabbed the dog, relative to the dog's centre, so the
// dog doesn't jump to the pointer. Both are viewport points.
function grabbed(viewport, dog, pointerViewportX, pointerViewportY) {
  const at = viewportFromPark(viewport, dog.parkX, dog.parkY);
  const dx = pointerViewportX - at.viewportX;
  const dy = pointerViewportY - at.viewportY;
  if (Math.abs(dx) > dog_px / 2 || Math.abs(dy) > dog_px / 2) return { kind: "missed" };
  return { kind: "holding", grabDx: dx, grabDy: dy };
}

// ── scroll (north and south, for now) ───────────────────────────────────────

// A band along the top edge and one along the bottom, where a held dog
// scrolls the viewport: from the dog's farthest place on screen (half its
// size from the edge) `band_px` inward. Deeper in the band, faster.
const band_px = 80;
const slowest_px_per_frame = 2 / 3;
const fastest_px_per_frame = 16 / 3;

function bandSpeed(depthPx) {
  const depth = depthPx / band_px; // 0 at the band's inner edge, 1 at the screen's edge
  if (depth <= 0) return 0;
  return slowest_px_per_frame + Math.min(depth, 1) * (fastest_px_per_frame - slowest_px_per_frame);
}

// How far the viewport moves south this frame (negative: north) for a dog
// held at `dogViewportY` on a screen `height` tall: 0 outside both bands.
function verticalScroll(dogViewportY, height) {
  const half = dog_px / 2;
  const north = bandSpeed(half + band_px - dogViewportY);
  const south = bandSpeed(dogViewportY - (height - half - band_px));
  return south - north;
}

// ── the blitter: owns no logic ──────────────────────────────────────────────

// Draws each sprite at its viewport point, its label under it; the own dog
// ringed.
function blit(canvas, width, height, sprites) {
  const ratio = window.devicePixelRatio || 1;
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  for (const s of sprites) {
    if (s.kind === "own") {
      ctx.beginPath();
      ctx.arc(s.viewportX, s.viewportY, dog_px * 0.7, 0, 2 * Math.PI);
      ctx.lineWidth = 3;
      ctx.strokeStyle = "#d33";
      ctx.stroke();
    }
    ctx.font = `${dog_px}px serif`;
    ctx.fillStyle = "#000";
    ctx.fillText(s.emoji, s.viewportX, s.viewportY);
    ctx.font = "11px monospace";
    ctx.fillStyle = "#555";
    ctx.fillText(s.label, s.viewportX, s.viewportY + dog_px * 0.85);
  }
}

// ── the page ────────────────────────────────────────────────────────────────

function start() {
  const canvas = document.getElementById("park");
  const viewport = { parkX: 0, parkY: 0, width: 0, height: 0 };
  let dogs = null;
  let hold = { kind: "idle" };
  // The pointer's last viewport point while holding: a still pointer in
  // the band keeps scrolling.
  const pointer = { viewportX: 0, viewportY: 0 };

  function fit() {
    const ratio = window.devicePixelRatio || 1;
    viewport.width = canvas.clientWidth;
    viewport.height = canvas.clientHeight;
    canvas.width = Math.floor(viewport.width * ratio);
    canvas.height = Math.floor(viewport.height * ratio);
    if (dogs === null) dogs = makeDogs(viewport);
    Object.assign(own(), keptOnScreen(viewport, own().parkX, own().parkY));
  }
  const own = () => dogs.find((d) => d.kind === "own");
  fit();
  window.addEventListener("resize", fit);

  // The own dog under the pointer, as far as the screen allows.
  function follow() {
    const want = parkFromViewport(viewport, pointer.viewportX - hold.grabDx, pointer.viewportY - hold.grabDy);
    Object.assign(own(), keptOnScreen(viewport, want.parkX, want.parkY));
  }

  canvas.addEventListener("pointerdown", (e) => {
    const g = grabbed(viewport, own(), e.offsetX, e.offsetY);
    if (g.kind === "missed") return;
    hold = g;
    pointer.viewportX = e.offsetX;
    pointer.viewportY = e.offsetY;
    canvas.setPointerCapture(e.pointerId);
  });
  canvas.addEventListener("pointermove", (e) => {
    if (hold.kind !== "holding") return;
    pointer.viewportX = e.offsetX;
    pointer.viewportY = e.offsetY;
    follow();
  });
  const letGo = () => { hold = { kind: "idle" }; };
  canvas.addEventListener("pointerup", letGo);
  canvas.addEventListener("pointercancel", letGo);

  const frame = () => {
    if (hold.kind === "holding") {
      const dog = own();
      const step = verticalScroll(viewportFromPark(viewport, dog.parkX, dog.parkY).viewportY, viewport.height);
      // The viewport and the dog move together: the dog stays put on screen
      // while it travels through the park.
      viewport.parkY += step;
      dog.parkY += step;
    }
    const sprites = dogs.map((d) => ({
      kind: d.kind,
      emoji: d.emoji,
      label: `(${Math.round(d.parkX)}, ${Math.round(d.parkY)})`,
      ...viewportFromPark(viewport, d.parkX, d.parkY),
    }));
    blit(canvas, viewport.width, viewport.height, sprites);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}

start();
