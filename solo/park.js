// Dog Park, played: one human, the server keeping the dogs.
//
// Any dog you see can be picked up. Pressing a dog leashes it (the server
// is told, and acks); dragging it sends where it is to the server, never
// more than one position waiting for its ack; the server keeps each one.
// The leash is let go when you press another dog, or 5 s after you let go
// of the dog (the page says so to the server). The server keeps where your
// viewport is, and your leash, so a reload shows you the same place, and a
// dog still on your leash still ringed.
// Holding a dog near any edge of the screen scrolls the viewport that way,
// the dog going with it at the same speed. Dragging anywhere else pans the
// park, like a tablecloth under the dogs. Each dog shows its park point.
//
// The dev console says what the server acks: each leash, release and move.
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

// The screen the server's first layout was drawn for: the viewport starts
// centred on its middle.
const first_screen = { width: 1280, height: 800 };

// A park point kept on screen, a dog's half-size in from each edge: a held
// dog never leaves the screen.
function keptOnScreen(viewport, parkX, parkY) {
  const half = dog_px / 2;
  return {
    parkX: Math.min(Math.max(parkX, viewport.parkX + half), viewport.parkX + viewport.width - half),
    parkY: Math.min(Math.max(parkY, viewport.parkY + half), viewport.parkY + viewport.height - half),
  };
}

// ── drag ────────────────────────────────────────────────────────────────────

// The dog under the pointer, the one drawn last (on top) first, and where
// the pointer grabbed it relative to its centre, so it doesn't jump.
function grabbed(viewport, dogs, pointerViewportX, pointerViewportY) {
  for (let i = dogs.length - 1; i >= 0; i--) {
    const at = viewportFromPark(viewport, dogs[i].parkX, dogs[i].parkY);
    const dx = pointerViewportX - at.viewportX;
    const dy = pointerViewportY - at.viewportY;
    if (Math.abs(dx) <= dog_px / 2 && Math.abs(dy) <= dog_px / 2) {
      return { kind: "holding", dog: dogs[i], grabDx: dx, grabDy: dy };
    }
  }
  return { kind: "missed" };
}

// ── scroll ──────────────────────────────────────────────────────────────────

// A band along each edge of the screen, where a held dog scrolls the
// viewport: from the dog's farthest place on screen (half its size from the
// edge) `band_px` inward. Deeper in the band, faster.
const band_px = 80;
const slowest_px_per_frame = (2 / 3) * 0.7;
const fastest_px_per_frame = (16 / 3) * 0.7;

function bandSpeed(depthPx) {
  const depth = depthPx / band_px; // 0 at the band's inner edge, 1 at the screen's edge
  if (depth <= 0) return 0;
  return slowest_px_per_frame + Math.min(depth, 1) * (fastest_px_per_frame - slowest_px_per_frame);
}

// How far the viewport moves this frame along one axis, toward the far
// edge (negative: toward the near one), for a dog held at `dogViewportAt`
// on a screen `length` long that way: 0 outside both bands.
function axisScroll(dogViewportAt, length) {
  const half = dog_px / 2;
  const near = bandSpeed(half + band_px - dogViewportAt);
  const far = bandSpeed(dogViewportAt - (length - half - band_px));
  return far - near;
}

// ── the server ──────────────────────────────────────────────────────────────

async function post(path, body) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${path}: ${response.status} ${await response.text()}`);
  return response.json();
}

async function fetchDogs() {
  const response = await fetch("/dogs");
  if (!response.ok) throw new Error(`/dogs: ${response.status}`);
  return (await response.json()).dogs.map((d) => ({ id: d.id, emoji: d.emoji, parkX: d.park_x, parkY: d.park_y }));
}

async function fetchMe() {
  const response = await fetch("/me");
  if (!response.ok) throw new Error(`/me: ${response.status}`);
  return response.json();
}

// ── the leash ───────────────────────────────────────────────────────────────

// How long a dog stays on your leash after you let go of it.
const leash_kept_ms = 5000;

// The dog on your leash: none, or a dog held in your hand, or a dog let go
// of and kept on the leash until a timer lets it go.
let leashed = { kind: "none" };

// A leash is asked for and the dog moved at once (optimistic); the ack is
// only said, for now.
function leashTo(dog) {
  if (leashed.kind !== "none" && leashed.dog !== dog) releaseLeash();
  if (leashed.kind === "kept") clearTimeout(leashed.timer);
  const already = leashed.kind !== "none" && leashed.dog === dog;
  leashed = { kind: "in_hand", dog };
  if (already) return;
  post("/leash", { dog: dog.id }).then(
    (ack) => console.log("leashed", ack),
    (e) => console.error("leash failed:", e.message),
  );
}

// Let go of the dog in your hand: it stays on the leash `leash_kept_ms`.
function keepOnLeash() {
  if (leashed.kind !== "in_hand") return;
  const dog = leashed.dog;
  leashed = { kind: "kept", dog, timer: setTimeout(releaseLeash, leash_kept_ms) };
}

function releaseLeash() {
  if (leashed.kind === "none") return;
  if (leashed.kind === "kept") clearTimeout(leashed.timer);
  const dog = leashed.dog;
  leashed = { kind: "none" };
  post("/release", { dog: dog.id }).then(
    (ack) => console.log("released", ack),
    (e) => console.error("release failed:", e.message),
  );
}

// Moves to the server: at most one waiting for its ack. Each send carries
// where the dog is now, so the dogs moved while one waits are sent, each
// at its latest place, as the acks come.
const moves = { waiting: "none", due: new Set() }; // waiting: "none" or a dog

function sendMove(dog) {
  if (moves.waiting !== "none") { moves.due.add(dog); return; }
  moves.waiting = dog;
  const parkX = Math.round(dog.parkX);
  const parkY = Math.round(dog.parkY);
  const sentMs = performance.now();
  post("/move", { dog: dog.id, park_x: parkX, park_y: parkY }).then(
    (ack) => console.log(`moved ${ack.moved} to (${ack.park_x}, ${ack.park_y}) in ${Math.round(performance.now() - sentMs)} ms`),
    (e) => console.error("move failed:", e.message),
  ).finally(() => {
    moves.waiting = "none";
    const [next] = moves.due;
    if (next !== undefined) {
      moves.due.delete(next);
      sendMove(next);
    }
  });
}

// The viewport to the server, the same way: at most one waiting, the latest
// sent when it is acked.
const viewportSends = { waiting: false, due: false };

function sendViewport(viewport) {
  if (viewportSends.waiting) { viewportSends.due = true; return; }
  viewportSends.waiting = true;
  post("/viewport", { park_x: Math.round(viewport.parkX), park_y: Math.round(viewport.parkY) }).then(
    () => {},
    (e) => console.error("viewport failed:", e.message),
  ).finally(() => {
    viewportSends.waiting = false;
    if (viewportSends.due) {
      viewportSends.due = false;
      sendViewport(viewport);
    }
  });
}

// ── the blitter: owns no logic ──────────────────────────────────────────────

// Draws each sprite at its viewport point, its label under it; a leashed
// dog ringed.
function blit(canvas, width, height, sprites) {
  const ratio = window.devicePixelRatio || 1;
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  for (const s of sprites) {
    if (s.kind === "leashed") {
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

async function start() {
  const canvas = document.getElementById("park");
  const me = await fetchMe();
  const dogs = await fetchDogs();
  const viewport = { parkX: 0, parkY: 0, width: 0, height: 0 };
  // What the human's hand is doing: holding a dog, panning the park (from
  // the pointer's last viewport point), or resting.
  let hold = { kind: "resting" };
  // The pointer's last viewport point while holding: a still pointer in
  // the band keeps scrolling.
  const pointer = { viewportX: 0, viewportY: 0 };

  function fit() {
    const ratio = window.devicePixelRatio || 1;
    viewport.width = canvas.clientWidth;
    viewport.height = canvas.clientHeight;
    canvas.width = Math.floor(viewport.width * ratio);
    canvas.height = Math.floor(viewport.height * ratio);
  }
  fit();
  if (me.viewport.at) {
    viewport.parkX = me.viewport.at.park_x;
    viewport.parkY = me.viewport.at.park_y;
  } else {
    viewport.parkX = Math.round(first_screen.width / 2 - viewport.width / 2);
    viewport.parkY = Math.round(first_screen.height / 2 - viewport.height / 2);
    sendViewport(viewport);
  }
  // A dog still on your leash from before the reload: kept on it the usual
  // time from now, then let go.
  if (me.leash.dog !== undefined) {
    const dog = dogs.find((d) => d.id === me.leash.dog);
    leashed = { kind: "kept", dog, timer: setTimeout(releaseLeash, leash_kept_ms) };
  }
  window.addEventListener("resize", fit);

  // The held dog under the pointer, as far as the screen allows.
  function follow() {
    const want = parkFromViewport(viewport, pointer.viewportX - hold.grabDx, pointer.viewportY - hold.grabDy);
    Object.assign(hold.dog, keptOnScreen(viewport, want.parkX, want.parkY));
    sendMove(hold.dog);
  }

  canvas.addEventListener("pointerdown", (e) => {
    const g = grabbed(viewport, dogs, e.offsetX, e.offsetY);
    if (g.kind === "holding") {
      hold = g;
      leashTo(g.dog);
    } else {
      hold = { kind: "panning", lastViewportX: e.offsetX, lastViewportY: e.offsetY };
    }
    pointer.viewportX = e.offsetX;
    pointer.viewportY = e.offsetY;
    canvas.setPointerCapture(e.pointerId);
  });
  canvas.addEventListener("pointermove", (e) => {
    if (hold.kind === "panning") {
      // The park moves with the pointer, so the viewport moves against it.
      viewport.parkX -= e.offsetX - hold.lastViewportX;
      viewport.parkY -= e.offsetY - hold.lastViewportY;
      sendViewport(viewport);
      hold.lastViewportX = e.offsetX;
      hold.lastViewportY = e.offsetY;
      return;
    }
    if (hold.kind !== "holding") return;
    pointer.viewportX = e.offsetX;
    pointer.viewportY = e.offsetY;
    follow();
  });
  const letGo = () => {
    if (hold.kind === "holding") keepOnLeash();
    hold = { kind: "resting" };
  };
  canvas.addEventListener("pointerup", letGo);
  canvas.addEventListener("pointercancel", letGo);

  const frame = () => {
    if (hold.kind === "holding") {
      const dog = hold.dog;
      const at = viewportFromPark(viewport, dog.parkX, dog.parkY);
      const eastward = axisScroll(at.viewportX, viewport.width);
      const southward = axisScroll(at.viewportY, viewport.height);
      // The viewport and the dog move together: the dog stays put on screen
      // while it travels through the park.
      if (eastward !== 0 || southward !== 0) {
        viewport.parkX += eastward;
        viewport.parkY += southward;
        dog.parkX += eastward;
        dog.parkY += southward;
        sendMove(dog);
        sendViewport(viewport);
      }
    }
    const onLeash = leashed.kind === "none" ? "none" : leashed.dog;
    const sprites = dogs.map((d) => ({
      kind: d === onLeash ? "leashed" : "free",
      emoji: d.emoji,
      label: `(${Math.round(d.parkX)}, ${Math.round(d.parkY)})`,
      ...viewportFromPark(viewport, d.parkX, d.parkY),
    }));
    blit(canvas, viewport.width, viewport.height, sprites);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}

start().catch((e) => console.error("Dog Park did not start:", e.message));
