// Dog Park, solo: one human, a few dogs, no server.
//
// Milestone 1: the park is exactly the screen. Your dog (ringed) and a
// couple of others stand in it; you drag yours anywhere inside it.
//
// ONE FRAME so far: a point is in CSS pixels from the screen's top-left,
// which is also the park's. Frames separate when the park outgrows the
// screen.
"use strict";

const dog_px = 40;

// ── the world ───────────────────────────────────────────────────────────────

// Where each dog stands, as fractions of the park's size, so any screen
// starts with the same picture.
const start_fractions = [
  { emoji: "🐕", own: true, fx: 0.5, fy: 0.5 },
  { emoji: "🐩", own: false, fx: 0.3, fy: 0.35 },
  { emoji: "🦮", own: false, fx: 0.7, fy: 0.65 },
];

function makeDogs(parkWidth, parkHeight) {
  return start_fractions.map((d) => ({
    emoji: d.emoji,
    kind: d.own ? "own" : "other",
    x: Math.round(d.fx * parkWidth),
    y: Math.round(d.fy * parkHeight),
  }));
}

// A point kept inside the park, a dog's half-size in from each edge.
function keptInPark(park, x, y) {
  const half = dog_px / 2;
  return {
    x: Math.min(Math.max(x, half), park.width - half),
    y: Math.min(Math.max(y, half), park.height - half),
  };
}

// ── drag ────────────────────────────────────────────────────────────────────

// Where the pointer grabbed the dog, relative to the dog's centre, so the
// dog doesn't jump to the pointer.
function grabbed(dog, pointerX, pointerY) {
  const dx = pointerX - dog.x;
  const dy = pointerY - dog.y;
  if (Math.abs(dx) > dog_px / 2 || Math.abs(dy) > dog_px / 2) return { kind: "missed" };
  return { kind: "holding", offsetX: dx, offsetY: dy };
}

// ── the blitter: owns no logic ──────────────────────────────────────────────

function blit(canvas, park, dogs) {
  const ratio = window.devicePixelRatio || 1;
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, park.width, park.height);
  ctx.font = `${dog_px}px serif`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  for (const d of dogs) {
    if (d.kind === "own") {
      ctx.beginPath();
      ctx.arc(d.x, d.y, dog_px * 0.7, 0, 2 * Math.PI);
      ctx.lineWidth = 3;
      ctx.strokeStyle = "#d33";
      ctx.stroke();
    }
    ctx.fillText(d.emoji, d.x, d.y);
  }
}

// ── the page ────────────────────────────────────────────────────────────────

function start() {
  const canvas = document.getElementById("park");
  const park = { width: 0, height: 0 };
  let dogs = null;
  let hold = { kind: "idle" };

  function fit() {
    const ratio = window.devicePixelRatio || 1;
    park.width = canvas.clientWidth;
    park.height = canvas.clientHeight;
    canvas.width = Math.floor(park.width * ratio);
    canvas.height = Math.floor(park.height * ratio);
    if (dogs === null) dogs = makeDogs(park.width, park.height);
    // A smaller screen keeps every dog inside it.
    for (const d of dogs) Object.assign(d, keptInPark(park, d.x, d.y));
  }
  fit();
  window.addEventListener("resize", fit);

  const own = () => dogs.find((d) => d.kind === "own");

  canvas.addEventListener("pointerdown", (e) => {
    const g = grabbed(own(), e.offsetX, e.offsetY);
    if (g.kind === "missed") return;
    hold = g;
    canvas.setPointerCapture(e.pointerId);
  });
  canvas.addEventListener("pointermove", (e) => {
    if (hold.kind !== "holding") return;
    Object.assign(own(), keptInPark(park, e.offsetX - hold.offsetX, e.offsetY - hold.offsetY));
  });
  const letGo = () => { hold = { kind: "idle" }; };
  canvas.addEventListener("pointerup", letGo);
  canvas.addEventListener("pointercancel", letGo);

  const frame = () => {
    blit(canvas, park, dogs);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}

start();
