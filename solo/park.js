// Dog Park, played: one human, the server keeping the dogs.
//
// THE PARK IS A CHECKERBOARD of 500 px tiles, each named by its column and
// row, 64 by 64 of them: the world, which no dog leaves, its dogs and cows
// in the 10 by 10 tiles in its middle. The page subscribes to the tiles
// around its viewport (at most 64; the page chooses which), and the server keeps it told about the dogs in them. Each time
// the tiles it wants change, it sends the whole set, each tile marked new
// or held; the server replaces its set and answers with the dogs in the
// tiles marked new. **A SUBSCRIPTION ONLY SAYS WHAT THE SERVER KEEPS YOU
// TOLD OF**: the page remembers every dog it has seen, where it last saw
// it, subscribed or not.
//
// THE PAGE TICKS 16 TIMES A SECOND, apart from its frames (engine.js): what
// the pointer does is taken at the next tick, and the frames draw between
// the last two ticks.
//
// Any dog you see can be picked up. Pressing a dog leashes it (the server is
// told, and acks); dragging it sends where each tick put it, never more than
// one path waiting for its ack. The leash is let go when you press another
// dog, or 80 ticks (5 s) after you let go of the dog. Holding a dog near any edge of
// the screen scrolls the viewport that way, the dog going with it.
// Dragging anywhere else pans the park, like a tablecloth; holding the
// pointer near an edge keeps the cloth moving that way. The server keeps
// your viewport and your leash, so a reload shows the same place.
//
// THE COWS, one to a white tile, half again a dog's size, are the server's:
// a dog's move scares the cows ahead of it aside, and the move's ack says
// where each scared cow stepped to. A cow can't be picked up. **THE PAGE
// PREDICTS THEM WITH THE SERVER'S OWN RULE** (/cows.wasm, the server's
// cows.zig): every tick, from where the server last said the cows are, it
// replays each move the server has yet to answer, in the order the server
// will take them: the one in flight, then each one waiting, from where the
// server has that dog (its BEGIN point, which moves only when a move is
// sent) to where the dog is now. When nothing is lost on the way, the ack
// says what the page already shows.
//
// "z" toggles the OVERVIEW: a window onto the world, more of it than near
// but never all, opening centred on your view: the tiles you know white
// and blue and the rest red, the dogs you know as dots (the dog you leashed
// last ringed), and your view as a rectangle you can drag by pressing
// inside it (the window follows it past its edge). Its scrollbars, along
// the bottom and the right, and the wheel, move the window over the world.
//
// The dev console says what the server acks: tiles, leashes, releases,
// moves.
//
// The page's modules: scene.js (the frames, tiles and the overview's
// frame, and what a frame draws), pointer.js (what a pointer event means,
// and the edge bands), blit.js (the drawing, and what a press is on),
// engine.js (what the page knows, the leash, the viewport, the sends, the
// tick; no DOM). This file gives the engine the real wire, clock and
// console, wires the DOM to it, and runs the frame loop and the drawing. It
// starts only where there is a DOM, so node can import every module.

import { nearScene, overviewScene, dogOfTarget, world_px } from "./scene.js";
import { meaning, panPointer, pressedOn, resting } from "./pointer.js";
import { draw } from "./blit.js";
import { createEngine } from "./engine.js";

// ── the wire ────────────────────────────────────────────────────────────────

async function post(path, body) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${path}: ${response.status} ${await response.text()}`);
  return response.json();
}

async function getJSON(path) {
  const response = await fetch(path);
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
  return response.json();
}

// The cows' rule, the server's own.
async function loadCowRule() {
  const { instance } = await WebAssembly.instantiateStreaming(fetch("/cows.wasm"));
  return instance.exports;
}

// ── the page ────────────────────────────────────────────────────────────────

async function start() {
  const canvas = document.getElementById("park");
  const ctx = canvas.getContext("2d");
  const engine = createEngine({
    rule: await loadCowRule(),
    post,
    getJSON,
    now: () => performance.now(),
    log: console,
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
  // the scene drawn, near between the last two ticks.
  const frame = (nowMs) => {
    engine.frame(nowMs, mode === "near" ? panPointer(hand) : "none");
    const v = engine.view();
    drawn = mode === "overview"
      ? { mode, objects: overviewScene(v.viewport, [...v.dogs.values()], v.cows, v.subscribed, v.lastLeashed, overviewAt) }
      : { mode, objects: nearScene(v.viewport, [...v.dogs.values()], v.cows, v.leashed, { alpha: v.alpha, was: v.was }) };
    draw(ctx, drawn.objects);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}

if (typeof document !== "undefined") start().catch((e) => console.error("Dog Park did not start:", e.message));
