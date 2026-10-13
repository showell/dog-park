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
// frame), pointer.js (the grab and the edge bands), blit.js (the drawing),
// engine.js (what the page knows, the leash, the sends). This file wires
// them to the DOM, and starts only where there is one, so node can import
// every module.

import {
  dog_px, cow_px, cow_emoji, tile_px, world_tiles, world_px,
  viewportFromPark, parkFromViewport, keptOnScreen, keptInWorld, viewportKeptOnWorld,
  tileOf, tileKey, tilesMeeting, overviewFrame, overviewFromPark,
} from "./scene.js";
import { grabbed, axisScroll } from "./pointer.js";
import { blit, blitOverview } from "./blit.js";
import {
  known, knownCows, subscribed, leashed, lastLeashed,
  fetchMe, leashTo, keepOnLeash, keptFromBefore, sendMove, sendViewport, syncTiles,
  loadCowRule, predictKnownCows,
} from "./engine.js";

// ── the page ────────────────────────────────────────────────────────────────

async function start() {
  const canvas = document.getElementById("park");
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
      const o = overviewFrame(viewport.width, viewport.height);
      const corner = overviewFromPark(o, viewport.parkX, viewport.parkY);
      const inside = e.offsetX >= corner.viewportX && e.offsetX <= corner.viewportX + viewport.width * o.scale &&
        e.offsetY >= corner.viewportY && e.offsetY <= corner.viewportY + viewport.height * o.scale;
      hold = inside ? { kind: "panning", lastViewportX: e.offsetX, lastViewportY: e.offsetY } : { kind: "resting" };
      return;
    }
    const g = grabbed(viewport, [...known.values()], e.offsetX, e.offsetY);
    if (g.kind === "holding") {
      hold = g;
      leashTo(g.dog.id);
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
    const ground = tilesMeeting(viewport.parkX, viewport.parkY, viewport.width, viewport.height).map((t) => ({
      shade: (t.col + t.row) % 2 === 0 ? "#ffffff" : "#eaf3fc",
      size: tile_px,
      label: `(${t.col}, ${t.row})`,
      ...viewportFromPark(viewport, t.col * tile_px, t.row * tile_px),
    }));
    const cowSprites = [...knownCows.values()].map((c) => ({
      kind: "cow",
      emoji: cow_emoji,
      size: cow_px,
      label: `(${Math.round(c.parkX)}, ${Math.round(c.parkY)})`,
      ...viewportFromPark(viewport, c.parkX, c.parkY),
    }));
    const sprites = [...cowSprites, ...[...known.values()].map((d) => ({
      kind: leashed.kind !== "none" && leashed.dogId === d.id ? "leashed" : "free",
      emoji: d.emoji,
      size: dog_px,
      label: `(${Math.round(d.parkX)}, ${Math.round(d.parkY)})`,
      ...viewportFromPark(viewport, d.parkX, d.parkY),
    }))];
    blit(canvas, viewport.width, viewport.height, ground, sprites);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);

  function drawOverview() {
    const o = overviewFrame(viewport.width, viewport.height);
    const squares = [];
    for (let row = 0; row < world_tiles; row++) {
      for (let col = 0; col < world_tiles; col++) {
        const odd = (col + row) % 2 === 1;
        const shade = subscribed.has(tileKey({ col, row }))
          ? (odd ? "#eaf3fc" : "#ffffff")
          : (odd ? "#f2c4c4" : "#f8d8d8");
        squares.push({ shade, size: tile_px * o.scale, ...overviewFromPark(o, col * tile_px, row * tile_px) });
      }
    }
    const cowDots = [...knownCows.values()].map((c) => ({
      kind: "cow",
      freshness: subscribed.has(tileKey(tileOf(c.parkX, c.parkY))) ? "live" : "remembered",
      ...overviewFromPark(o, c.parkX, c.parkY),
    }));
    const dots = [...cowDots, ...[...known.values()].map((d) => ({
      kind: lastLeashed.kind === "dog" && lastLeashed.dogId === d.id ? "ringed" : "plain",
      freshness: subscribed.has(tileKey(tileOf(d.parkX, d.parkY))) ? "live" : "remembered",
      ...overviewFromPark(o, d.parkX, d.parkY),
    }))];
    const corner = overviewFromPark(o, viewport.parkX, viewport.parkY);
    const view = { ...corner, width: viewport.width * o.scale, height: viewport.height * o.scale };
    blitOverview(canvas, viewport.width, viewport.height, squares, dots, view);
  }
}

if (typeof document !== "undefined") start().catch((e) => console.error("Dog Park did not start:", e.message));
