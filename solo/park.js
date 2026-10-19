// Dog Park, played: one human, the park on the new physics (docs/PHYSICS.md).
//
// THE PARK IS A CHECKERBOARD of 350 px tiles, each named by its column and
// row, 64 by 64 of them: the world, its dogs and cows in the 10 by 10
// tiles in its middle. **THE PAGE RUNS THE PHYSICS** (physics.wasm, the
// server's own Zig, served as /physics-<hash>.wasm, the hash named in
// index.html), 16 ticks a second, and reports each tick's lines to the
// server, which re-runs them and keeps them (POST /report); a page load is
// POST /load. The engine (engine.js) keeps the record and the protocol.
//
// Pressing a dog leashes it; dragging it moves it by how far the pointer
// moved, tick by tick, the cows ahead of it scooting aside and the other
// dogs keeping their distance or following (its own breed). A bump ends the
// drag (the pointer is let go; the leash stays), with a word on what it
// hit (quips.js). The leash comes off when
// you press another dog, or 320 ticks (20 s) after the drag ended, and the
// park sleeps. Holding a dog near an edge of the screen carries it on, the
// viewport following. Dragging anywhere else pans the park; the tiles the
// screen shows are subscribed as it moves.
//
// "m", or the Map button, toggles the MAP (the overview): the whole world
// once, opening centred on your view: the critters as dots (the dog you
// leashed last ringed), and your view as a rectangle you can drag by
// pressing inside it. Its scrollbars and the wheel move it round the
// torus. "m" again, or Back, returns.
//
// The dev console says what the engine does: loads, differs, retries.
//
// The page's modules: scene.js (the frames, tiles, the overview's frame,
// and what a frame draws), pointer.js (what a pointer event means, and the
// edge bands), blit.js (the drawing, and what a press is on), physics.js
// (the wasm's exports), engine.js (the record, the protocol and the tick;
// no DOM). This file gives the engine the real wire, clocks and console,
// wires the DOM to it, and runs the frame loop and the drawing. It starts
// only where there is a DOM, so node can import every module.

import { nearScene, overviewScene, messageScene, dogOfTarget, world_px, tile_px, largestHerd, cow_count } from "./scene.js";
import { meaning, panPointer, pressedOn, resting } from "./pointer.js";
import { draw } from "./blit.js";
import { createEngine } from "./engine.js";
import { pressedCritter, quipper, bumper } from "./quips.js";
import { instantiatePhysics } from "./physics.js";

// ── the wire ────────────────────────────────────────────────────────────────

// A text in, the server's answer out: { status, text }; rejects when
// nothing came back (the engine abandons a try after 5 s itself).
async function post(path, text) {
  const response = await fetch(path, { method: "POST", headers: { "content-type": "text/plain" }, body: text });
  return { status: response.status, text: await response.text() };
}

// The physics the server judges with, under its hash (index.html names it).
async function loadPhysics() {
  const hash = document.querySelector('meta[name="dogpark-physics"]').content;
  const response = await fetch(`/physics-${hash}.wasm`);
  if (!response.ok) throw new Error(`/physics-${hash}.wasm: ${response.status}`);
  const physics = await instantiatePhysics(response);
  if (physics.hash !== hash) throw new Error(`/physics-${hash}.wasm is physics ${physics.hash}`);
  return physics;
}

// **THE REMEMBERED VIEWPORT** (Steve, 2026-10-15): a load picks the
// player's game up, so it opens where the player last looked. A new game,
// or Start over, opens on the park's middle (the key is cleared). Storage
// may be missing or refuse: then every load opens on the middle.
// The key names the geometry (the tile and the world): a view kept under
// another would open on the wrong ground.
const viewport_key = `dogpark.viewport.${tile_px}.${world_px}`;
function savedViewport() {
  try {
    const v = JSON.parse(localStorage.getItem(viewport_key) ?? "null");
    if (v && Number.isFinite(v.parkX) && Number.isFinite(v.parkY)) return { parkX: v.parkX, parkY: v.parkY };
  } catch { /* none kept */ }
  return "none";
}
function saveViewport(v) {
  try { localStorage.setItem(viewport_key, JSON.stringify({ parkX: v.parkX, parkY: v.parkY })); } catch { /* not kept */ }
}
function forgetViewport() {
  try { localStorage.removeItem(viewport_key); } catch { /* nothing kept */ }
}

// ── the page ────────────────────────────────────────────────────────────────

async function start() {
  const canvas = document.getElementById("park");
  const ctx = canvas.getContext("2d");
  const engine = createEngine({
    physics: await loadPhysics(),
    post,
    now: () => performance.now(),
    wall: () => Date.now(),
    setTimer: (ms, fn) => setTimeout(fn, ms),
    clearTimer: (h) => clearTimeout(h),
    log: console,
    reload: () => location.reload(),
  });
  // Near (the park at its size) or the overview (a window onto the world).
  let mode = "near";
  // **DEBUGGING MODE** ("d", or the Debug button): each dog's number and the
  // critters' places in the last walk. Off by default; the tiles'
  // coordinates show either way.
  let labels = "hidden";
  // The overview's window's top-left, a park point (scene.js's
  // overviewFrame keeps it in the world); "m" centres it on the view.
  let overviewAt = { parkX: world_px / 2, parkY: world_px / 2 };
  // What the human's hand is doing (pointer.js says the shapes).
  let hand = resting;
  // What the last frame drew, and in which mode: a press is on what the
  // human saw.
  let drawn = { mode, objects: [] };

  // The canvas sized to the screen, in device pixels; the screen's size.
  function fit() {
    const ratio = window.devicePixelRatio || 1;
    const width = canvas.clientWidth;
    const height = canvas.clientHeight;
    canvas.width = Math.floor(width * ratio);
    canvas.height = Math.floor(height * ratio);
    return { width, height };
  }
  await engine.load(fit, savedViewport());
  const score = document.getElementById("score");
  // Kept at most twice a second, when it moved.
  let savedAt = { parkX: NaN, parkY: NaN };
  let savedMs = -Infinity;

  // The page does what an event means, in order: the mode and the
  // overview's window are the page's, the rest the engine's.
  function apply(intents) {
    for (const i of intents) {
      if (i.kind === "mode") mode = i.mode;
      else if (i.kind === "scroll") overviewAt = { parkX: i.parkX, parkY: i.parkY };
      else engine.intent(i);
    }
  }
  function handle(event, hitId = null) {
    const out = meaning(hand, event, hitId, mode, engine.view().viewport, overviewAt);
    hand = out.hand;
    apply(out.intents);
  }

  window.addEventListener("resize", () => engine.resize(fit()));
  window.addEventListener("keydown", (e) => {
    if (e.key === "m") handle({ type: "map" });
    if (e.key === "d") labels = labels === "hidden" ? "shown" : "hidden";
  });
  const debugButton = document.getElementById("debug");
  debugButton?.addEventListener("click", () => { labels = labels === "hidden" ? "shown" : "hidden"; });
  // The Map button: its label says what a press (or "m") does now.
  const mapButton = document.getElementById("map");
  mapButton?.addEventListener("click", () => handle({ type: "map" }));
  // A press on a cow or a chicken: a word, and nothing moves.
  const quips = quipper();
  // A drag that bumps: a word on what it hit.
  const bumps = bumper();
  let bumpsSaid = 0;
  const toast = document.getElementById("toast");
  let toastTimer = null;
  function say(line) {
    if (!toast) return;
    toast.textContent = line;
    toast.classList.add("shown");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove("shown"), 3500);
  }
  canvas.addEventListener("pointerdown", (e) => {
    const hitId = pressedOn(drawn, mode, e.offsetX, e.offsetY);
    const v = engine.view();
    const dog = v.dogs.get(dogOfTarget(hitId));
    if (mode === "near" && dog === undefined) {
      const critter = pressedCritter(v.viewport, e.offsetX, e.offsetY, v.cows, v.chickens ?? []);
      if (critter !== null) return say(quips.say(critter));
    }
    if (dog !== undefined) quips.forgive();
    canvas.setPointerCapture(e.pointerId);
    handle({ type: "down", x: e.offsetX, y: e.offsetY, dogAt: dog === undefined ? "none" : { parkX: dog.parkX, parkY: dog.parkY } }, hitId);
  });
  canvas.addEventListener("pointermove", (e) => handle({ type: "move", x: e.offsetX, y: e.offsetY }));
  canvas.addEventListener("pointerup", () => handle({ type: "up" }));
  canvas.addEventListener("pointercancel", () => handle({ type: "cancel" }));
  canvas.addEventListener("wheel", (e) => {
    // The overview's own; near, the browser keeps its wheel (a pinch's zoom).
    if (mode !== "overview") return;
    e.preventDefault();
    // A line or a page of scroll as px, as a browser would scroll a page.
    const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? canvas.clientHeight : 1;
    handle({ type: "wheel", dx: e.deltaX * unit, dy: e.deltaY * unit });
  }, { passive: false });

  // Each frame: the ticks due run (the edge bands, near, among them), then
  // the scene drawn, near between the last two ticks. A bump lets go of the
  // pointer: the hand rests until the next press.
  const frame = (nowMs) => {
    engine.frame(nowMs, mode === "near" ? panPointer(hand) : "none");
    const v = engine.view();
    if (hand.kind === "dragging" && !v.holding) hand = resting;
    if (v.bumped.count !== bumpsSaid) {
      bumpsSaid = v.bumped.count;
      if (v.bumped.kind !== "none") say(bumps.say(v.bumped.kind));
    }
    drawn = mode === "overview"
      ? { mode, objects: overviewScene(v.viewport, [...v.dogs.values()], v.cows, v.subscribed, v.lastLeashed, overviewAt, v.chickens ?? [], v.others ?? []) }
      : { mode, objects: nearScene(v.viewport, [...v.dogs.values()], v.cows, v.leashed, { alpha: v.alpha, was: v.was }, v.visits, { chickens: v.chickens ?? [], poops: v.poops ?? [], others: v.others ?? [], labels }) };
    const note = v.status.kind === "stopped" ? v.status.message
      : v.status.kind === "reloading" ? `reloading: ${v.status.why}`
      : v.waitingS !== null ? `Someone else is playing right now. Your turn comes in about ${v.waitingS} s.`
      : "none";
    draw(ctx, note === "none" ? drawn.objects : [...drawn.objects, ...messageScene(v.viewport, note)]);
    // The goal, shown when it changes.
    // Out of the park's cows, never the ones this page happens to know.
    if (v.cows.length > 0) {
      const herd = largestHerd(v.cows);
      const won = herd === cow_count;
      const text = won ? `All ${cow_count} cows herded together! 🎉` : `Herd: ${herd} of ${cow_count} cows`;
      if (score && score.textContent !== text) {
        score.textContent = text;
        score.classList.toggle("won", won);
      }
    }
    if (mapButton) {
      const label = mode === "overview" ? "Back (m)" : "Map (m)";
      if (mapButton.textContent !== label) mapButton.textContent = label;
    }
    if (debugButton) {
      const pressed = labels === "shown" ? "true" : "false";
      if (debugButton.getAttribute("aria-pressed") !== pressed) debugButton.setAttribute("aria-pressed", pressed);
    }
    if (nowMs - savedMs >= 500 && (v.viewport.parkX !== savedAt.parkX || v.viewport.parkY !== savedAt.parkY)) {
      savedAt = { parkX: v.viewport.parkX, parkY: v.viewport.parkY };
      savedMs = nowMs;
      saveViewport(savedAt);
    }
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);

  // **START OVER**: this device's game back to its first layout, at the
  // next load (`POST /reset`), and the page loads again.
  document.getElementById("reset")?.addEventListener("click", async () => {
    if (!confirm("Start over? Every critter goes back to where the game began.")) return;
    const r = await post("/reset", "");
    if (r.status !== 200) return console.error(`/reset: ${r.status} ${r.text}`);
    forgetViewport();
    location.reload();
  });
}

if (typeof document !== "undefined") start().catch((e) => console.error("Dog Park did not start:", e.message));
