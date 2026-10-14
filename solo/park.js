// Dog Park, played: one human, the park on the new physics (docs/PHYSICS.md).
//
// THE PARK IS A CHECKERBOARD of 500 px tiles, each named by its column and
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
// drag (the pointer is let go; the leash stays). The leash comes off when
// you press another dog, or 320 ticks (20 s) after the drag ended, and the
// park sleeps. Holding a dog near an edge of the screen carries it on, the
// viewport following. Dragging anywhere else pans the park; the tiles the
// screen shows are subscribed as it moves.
//
// "z" toggles the OVERVIEW: a window onto the world, more of it than near
// but never all, opening centred on your view: the tiles subscribed white
// and blue and the rest red, the critters the page has as dots (the dog
// you leashed last ringed), and your view as a rectangle you can drag by
// pressing inside it. Its scrollbars and the wheel move the window.
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

import { nearScene, overviewScene, messageScene, dogOfTarget, world_px } from "./scene.js";
import { meaning, panPointer, pressedOn, resting } from "./pointer.js";
import { draw } from "./blit.js";
import { createEngine } from "./engine.js";
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

// **NO REMEMBERED VIEWPORT**: every load starts the park afresh (decision
// 16), its dogs back where they were laid out, so a view kept from the last
// visit can only show where they no longer are: empty land (Steve,
// 2026-10-14: "9103 has no critters"). A load opens on the park's middle.
// What an older page kept is cleared.
try { localStorage.removeItem("dogpark.viewport"); } catch { /* no storage */ }

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
  // The overview's window's top-left, a park point (scene.js's
  // overviewFrame keeps it in the world); "z" centres it on the view.
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
  await engine.load(fit);

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
    if (e.key === "z") handle({ type: "z" });
  });
  canvas.addEventListener("pointerdown", (e) => {
    canvas.setPointerCapture(e.pointerId);
    const hitId = pressedOn(drawn, mode, e.offsetX, e.offsetY);
    const dog = engine.view().dogs.get(dogOfTarget(hitId));
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
    drawn = mode === "overview"
      ? { mode, objects: overviewScene(v.viewport, [...v.dogs.values()], v.cows, v.subscribed, v.lastLeashed, overviewAt) }
      : { mode, objects: nearScene(v.viewport, [...v.dogs.values()], v.cows, v.leashed, { alpha: v.alpha, was: v.was }, v.visits) };
    const note = v.status.kind === "stopped" ? v.status.message : v.status.kind === "reloading" ? `reloading: ${v.status.why}` : "none";
    draw(ctx, note === "none" ? drawn.objects : [...drawn.objects, ...messageScene(v.viewport, note)]);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}

if (typeof document !== "undefined") start().catch((e) => console.error("Dog Park did not start:", e.message));
