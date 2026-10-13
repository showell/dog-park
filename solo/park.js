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
// frame, and what a frame draws), pointer.js (the edge bands), blit.js (the
// drawing, and what a press is on),
// engine.js (what the page knows, the leash, the sends). This file wires
// them to the DOM, and starts only where there is one, so node can import
// every module.

import {
  dog_px, world_px,
  viewportFromPark, parkFromViewport, keptOnScreen, keptInWorld, viewportKeptOnWorld,
  overviewFrame, nearScene, overviewScene, view_target, dogOfTarget,
} from "./scene.js";
import { axisScroll } from "./pointer.js";
import { draw, hit } from "./blit.js";
import {
  known, knownCows, subscribed, leashed, lastLeashed,
  fetchMe, leashTo, keepOnLeash, keptFromBefore, sendMove, sendViewport, syncTiles,
  loadCowRule, predictKnownCows,
} from "./engine.js";

// ── the page ────────────────────────────────────────────────────────────────

async function start() {
  const canvas = document.getElementById("park");
  const ctx = canvas.getContext("2d");
  const cowRule = await loadCowRule();
  const me = await fetchMe();
  const viewport = { parkX: 0, parkY: 0, width: 0, height: 0 };
  // Near (the park at its size) or the overview (the whole world).
  let mode = "near";
  // What the human's hand is doing: holding a dog, panning the park (from
  // the pointer's last viewport point), or resting.
  let hold = { kind: "resting" };
  const inHand = () => (hold.kind === "holding" ? hold.dog : "none");
  // The pointer's last viewport point while holding: a still pointer in
  // the band keeps scrolling.
  const pointer = { viewportX: 0, viewportY: 0 };
  // What the last frame drew: a press is on what the human saw.
  let drawn = [];

  function fit() {
    const ratio = window.devicePixelRatio || 1;
    viewport.width = canvas.clientWidth;
    viewport.height = canvas.clientHeight;
    canvas.width = Math.floor(viewport.width * ratio);
    canvas.height = Math.floor(viewport.height * ratio);
  }
  fit();
  if (me.viewport.at) {
    Object.assign(viewport, viewportKeptOnWorld(viewport, me.viewport.at.park_x, me.viewport.at.park_y));
  } else {
    // A first visit starts at the world's centre.
    viewport.parkX = Math.round(world_px / 2 - viewport.width / 2);
    viewport.parkY = Math.round(world_px / 2 - viewport.height / 2);
    sendViewport(viewport);
  }
  // A dog still on your leash from before the reload: kept on it the usual
  // time from now, then let go.
  if (me.leash.dog !== undefined) keptFromBefore(me.leash.dog);
  window.addEventListener("resize", fit);
  window.addEventListener("keydown", (e) => {
    if (e.key !== "z") return;
    if (hold.kind === "holding") keepOnLeash();
    hold = { kind: "resting" };
    mode = mode === "near" ? "overview" : "near";
  });

  // The held dog under the pointer, as far as the screen allows.
  function follow() {
    const want = parkFromViewport(viewport, pointer.viewportX - hold.grabDx, pointer.viewportY - hold.grabDy);
    const onScreen = keptOnScreen(viewport, want.parkX, want.parkY);
    Object.assign(hold.dog, keptInWorld(onScreen.parkX, onScreen.parkY));
    sendMove(hold.dog);
  }

  canvas.addEventListener("pointerdown", (e) => {
    canvas.setPointerCapture(e.pointerId);
    if (mode === "overview") {
      // The view's rectangle moves only when it is pressed.
      const inside = hit(drawn, e.offsetX, e.offsetY) === view_target;
      hold = inside ? { kind: "panning", lastViewportX: e.offsetX, lastViewportY: e.offsetY } : { kind: "resting" };
      return;
    }
    const dogId = dogOfTarget(hit(drawn, e.offsetX, e.offsetY));
    const dog = dogId === "none" ? undefined : known.get(dogId);
    if (dog !== undefined) {
      // Held where it was grabbed, relative to its centre, so it doesn't jump.
      const at = viewportFromPark(viewport, dog.parkX, dog.parkY);
      hold = { kind: "holding", dog, grabDx: e.offsetX - at.viewportX, grabDy: e.offsetY - at.viewportY };
      leashTo(dog.id);
    } else {
      hold = { kind: "panning", lastViewportX: e.offsetX, lastViewportY: e.offsetY };
    }
    pointer.viewportX = e.offsetX;
    pointer.viewportY = e.offsetY;
    canvas.setPointerCapture(e.pointerId);
  });
  canvas.addEventListener("pointermove", (e) => {
    if (hold.kind === "panning") {
      // Near, the park moves with the pointer, so the viewport moves
      // against it; in the overview, the view's rectangle moves with it.
      const dx = e.offsetX - hold.lastViewportX;
      const dy = e.offsetY - hold.lastViewportY;
      const o = overviewFrame(viewport.width, viewport.height);
      const want = mode === "near"
        ? { parkX: viewport.parkX - dx, parkY: viewport.parkY - dy }
        : { parkX: viewport.parkX + dx / o.scale, parkY: viewport.parkY + dy / o.scale };
      Object.assign(viewport, viewportKeptOnWorld(viewport, want.parkX, want.parkY));
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
    syncTiles(viewport, inHand);
    predictKnownCows(cowRule);
    if (mode === "overview") {
      drawOverview();
      requestAnimationFrame(frame);
      return;
    }
    if (hold.kind === "panning") {
      // The cloth keeps moving while the pointer is held near an edge: the
      // park toward that edge, so the viewport away from it.
      const want = {
        parkX: viewport.parkX - axisScroll(hold.lastViewportX, viewport.width, 0),
        parkY: viewport.parkY - axisScroll(hold.lastViewportY, viewport.height, 0),
      };
      const kept = viewportKeptOnWorld(viewport, want.parkX, want.parkY);
      if (kept.parkX !== viewport.parkX || kept.parkY !== viewport.parkY) {
        Object.assign(viewport, kept);
        sendViewport(viewport);
      }
    }
    if (hold.kind === "holding") {
      const dog = hold.dog;
      const at = viewportFromPark(viewport, dog.parkX, dog.parkY);
      const eastward = axisScroll(at.viewportX, viewport.width, dog_px / 2);
      const southward = axisScroll(at.viewportY, viewport.height, dog_px / 2);
      // The viewport and the dog move together: the dog stays put on screen
      // while it travels through the park.
      // The dog stops at the world's edge, and the scroll with it.
      const to = keptInWorld(dog.parkX + eastward, dog.parkY + southward);
      const movedX = to.parkX - dog.parkX;
      const movedY = to.parkY - dog.parkY;
      if (movedX !== 0 || movedY !== 0) {
        viewport.parkX += movedX;
        viewport.parkY += movedY;
        dog.parkX = to.parkX;
        dog.parkY = to.parkY;
        sendMove(dog);
        sendViewport(viewport);
      }
    }
    drawn = nearScene(viewport, [...known.values()], [...knownCows.values()], leashed);
    draw(ctx, drawn);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);

  function drawOverview() {
    drawn = overviewScene(viewport, [...known.values()], [...knownCows.values()], subscribed, lastLeashed);
    draw(ctx, drawn);
  }
}

if (typeof document !== "undefined") start().catch((e) => console.error("Dog Park did not start:", e.message));
