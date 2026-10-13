// Dog Park, played: one human, the server keeping the dogs.
//
// THE PARK IS A CHECKERBOARD of 500 px tiles, each named by its column and
// row, 10 by 10 of them: the world, which no dog leaves. The page
// subscribes to the tiles around its viewport (at most 25; the page chooses
// which), and the server keeps it told about the dogs in them. Each time
// the tiles it wants change, it sends the whole set, each tile marked new
// or held; the server replaces its set and answers with the dogs in the
// tiles marked new. **A SUBSCRIPTION ONLY SAYS WHAT THE SERVER KEEPS YOU
// TOLD OF**: the page remembers every dog it has seen, where it last saw
// it, subscribed or not.
//
// Any dog you see can be picked up. Pressing a dog leashes it (the server is
// told, and acks); dragging it sends where it is, never more than one
// position waiting for its ack. The leash is let go when you press another
// dog, or 5 s after you let go of the dog. Holding a dog near any edge of
// the screen scrolls the viewport that way, the dog going with it.
// Dragging anywhere else pans the park, like a tablecloth; holding the
// pointer near an edge keeps the cloth moving that way. The server keeps
// your viewport and your leash, so a reload shows the same place.
//
// THE COWS, one to a white tile, half again a dog's size, are the server's:
// a dog's move scares the cows ahead of it aside, and the move's ack says
// where each scared cow stepped to. A cow can't be picked up. **THE PAGE
// PREDICTS THEM WITH THE SERVER'S OWN RULE** (/cows.wasm, the server's
// cows.zig): every frame, from where the server last said the cows are, it
// replays each move the server has yet to answer, in the order the server
// will take them: the one in flight, then each one waiting, from where the
// server has that dog (its BEGIN point, which moves only when a move is
// sent) to where the dog is now. When nothing is lost on the way, the ack
// says what the page already shows.
//
// "z" toggles the OVERVIEW: the whole world on the screen, the tiles you
// know white and blue and the rest red, the dogs you know as dots (the dog
// you leashed last ringed), and your view as a rectangle you can drag by
// pressing inside it.
//
// The dev console says what the server acks: tiles, leashes, releases,
// moves.
//
// The page's modules: scene.js (the frames, tiles and the overview's
// frame, and what a frame draws), pointer.js (what a pointer event means,
// and the edge bands), blit.js (the drawing, and what a press is on),
// engine.js (what the page knows, the leash, the viewport, the sends; no
// DOM). This file gives the engine the real wire, clock, timers and
// console, wires the DOM to it, and runs the frame loop and the drawing. It
// starts only where there is a DOM, so node can import every module.

import { nearScene, overviewScene, dogOfTarget } from "./scene.js";
import { meaning, edgeScroll, inHand, pressedOn, resting } from "./pointer.js";
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
    setTimer: (f, ms) => setTimeout(f, ms),
    clearTimer: (timer) => clearTimeout(timer),
    log: console,
  });
  // Near (the park at its size) or the overview (the whole world).
  let mode = "near";
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

  // The page does what an event means, in order: the mode is the page's,
  // the rest the engine's.
  function apply(intents) {
    for (const i of intents) {
      if (i.kind === "mode") mode = i.mode;
      else engine.intent(i);
    }
  }
  function handle(event, hitId = null) {
    const out = meaning(hand, event, hitId, mode, engine.view().viewport);
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

  const frame = () => {
    engine.frame();
    if (mode === "overview") {
      const v = engine.view();
      drawn = { mode, objects: overviewScene(v.viewport, [...v.dogs.values()], v.cows, v.subscribed, v.lastLeashed) };
    } else {
      const dogId = inHand(hand);
      const before = engine.view();
      apply(edgeScroll(hand, before.viewport, dogId === "none" ? "none" : heldDog(before, dogId)));
      const v = engine.view();
      drawn = { mode, objects: nearScene(v.viewport, [...v.dogs.values()], v.cows, v.leashed) };
    }
    draw(ctx, drawn.objects);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}

function heldDog(view, dogId) {
  const dog = view.dogs.get(dogId);
  if (dog === undefined) throw new Error(`dog ${dogId} is in hand but not known`);
  return dog;
}

if (typeof document !== "undefined") start().catch((e) => console.error("Dog Park did not start:", e.message));
