// The pointer, pure: how far the edge bands scroll a tick, and what a
// pointer event means (the hand after it, and what the page does). park.js's
// listeners turn DOM events into these events and apply the intents; the
// engine runs the edge bands each tick.

import {
  dog_px, viewportFromPark, parkFromViewport, keptOnScreen, keptInWorld, viewportKeptOnWorld,
  overviewFrame, view_target, dogOfTarget,
} from "./scene.js";
import { hit } from "./blit.js";

// ── scroll ──────────────────────────────────────────────────────────────────

// A band along each edge of the screen, where a held dog scrolls the
// viewport: from the dog's farthest place on screen (half its size from the
// edge) `band_px` inward. Deeper in the band, faster. The speeds are a
// tick's: 28 and 224 px a second, the 7/15 and 56/15 px a frame they were
// at 60 Hz, now the same at any frame rate.
export const band_px = 80;
export const slowest_px_per_tick = 1.75;
export const fastest_px_per_tick = 14;

export function bandSpeed(depthPx) {
  const depth = depthPx / band_px; // 0 at the band's inner edge, 1 at the screen's edge
  if (depth <= 0) return 0;
  return slowest_px_per_tick + Math.min(depth, 1) * (fastest_px_per_tick - slowest_px_per_tick);
}

// How far the band moves the viewport this tick along one axis, toward the
// far edge (negative: toward the near one), for something at `viewportAt` on
// a screen `length` long that way, which comes no nearer an edge than
// `reachPx` (a dog's half-size; 0 for the pointer): 0 outside both bands.
export function axisScroll(viewportAt, length, reachPx) {
  const near = bandSpeed(reachPx + band_px - viewportAt);
  const far = bandSpeed(viewportAt - (length - reachPx - band_px));
  return far - near;
}

// ── what a pointer event means ──────────────────────────────────────────────

// THE HAND, what the human's pointer is doing, a plain value:
//
//   { kind: "resting" }
//   { kind: "panning", lastX, lastY }        from the pointer's last viewport point
//   { kind: "dragging", dogId, offsetX, offsetY }
//       a dog by its number, held where it was grabbed: the pointer is
//       (offsetX, offsetY) from the dog's centre, so the dog doesn't jump
//
// AN EVENT, in viewport points:
//
//   { type: "down", x, y, dogAt }   dogAt: the pressed dog's park point, or
//                                   "none" when the press is on no dog the
//                                   page knows
//   { type: "move", x, y }
//   { type: "up" }  { type: "cancel" }
//   { type: "z" }                   the key that flips near and the overview
//
// AN INTENT, what the page does about it, in order:
//
//   { kind: "grab", dogId }                 leash the dog (at the next tick)
//   { kind: "drag", dogId, parkX, parkY }   the pointer puts the dog here; the
//                                           next tick takes the last of these
//   { kind: "letgo" }                       the dog in hand goes, kept on the
//                                           leash (at the next tick, after its drags)
//   { kind: "pan", parkX, parkY }           the viewport's top-left is now here
//   { kind: "mode", mode }                  "near" or "overview" from now on
//
// No intent at all is an empty list.

export const resting = { kind: "resting" };

// What `event` means to a hand in `mode`, the press on `hitId` (what
// blit.js's `hit` answered over the list last drawn, null for nothing) with
// the viewport as it is: the hand after it, and the intents.
export function meaning(hand, event, hitId, mode, viewport) {
  switch (event.type) {
    case "down": {
      if (mode === "overview") {
        // The view's rectangle moves only when it is pressed.
        const hand2 = hitId === view_target ? { kind: "panning", lastX: event.x, lastY: event.y } : resting;
        return { hand: hand2, intents: [] };
      }
      const dogId = dogOfTarget(hitId);
      if (dogId === "none" || event.dogAt === "none") {
        return { hand: { kind: "panning", lastX: event.x, lastY: event.y }, intents: [] };
      }
      const at = viewportFromPark(viewport, event.dogAt.parkX, event.dogAt.parkY);
      return {
        hand: { kind: "dragging", dogId, offsetX: event.x - at.viewportX, offsetY: event.y - at.viewportY },
        intents: [{ kind: "grab", dogId }],
      };
    }
    case "move": {
      if (hand.kind === "panning") {
        // Near, the park moves with the pointer, so the viewport moves
        // against it; in the overview, the view's rectangle moves with it.
        const dx = event.x - hand.lastX;
        const dy = event.y - hand.lastY;
        const o = overviewFrame(viewport.width, viewport.height);
        const want = mode === "near"
          ? { parkX: viewport.parkX - dx, parkY: viewport.parkY - dy }
          : { parkX: viewport.parkX + dx / o.scale, parkY: viewport.parkY + dy / o.scale };
        const to = viewportKeptOnWorld(viewport, want.parkX, want.parkY);
        return {
          hand: { kind: "panning", lastX: event.x, lastY: event.y },
          intents: [{ kind: "pan", parkX: to.parkX, parkY: to.parkY }],
        };
      }
      if (hand.kind !== "dragging") return { hand, intents: [] };
      // The held dog under the pointer, as far as the screen allows.
      const want = parkFromViewport(viewport, event.x - hand.offsetX, event.y - hand.offsetY);
      const onScreen = keptOnScreen(viewport, want.parkX, want.parkY);
      const to = keptInWorld(onScreen.parkX, onScreen.parkY);
      return { hand, intents: [{ kind: "drag", dogId: hand.dogId, parkX: to.parkX, parkY: to.parkY }] };
    }
    case "up":
    case "cancel":
      return { hand: resting, intents: hand.kind === "dragging" ? [{ kind: "letgo" }] : [] };
    case "z": {
      const flipped = { kind: "mode", mode: mode === "near" ? "overview" : "near" };
      return { hand: resting, intents: hand.kind === "dragging" ? [{ kind: "letgo" }, flipped] : [flipped] };
    }
    default:
      throw new Error(`no pointer event ${event.type}`);
  }
}

// What a tick's edge bands do, near, to `band`, what is held:
//
//   "none"
//   { kind: "pan", x, y }                 a pan, the pointer at viewport (x, y):
//                                          held near an edge, it keeps the cloth
//                                          moving (the park toward that edge, so
//                                          the viewport away from it)
//   { kind: "dog", dogId, parkX, parkY }  the held dog where the tick has it:
//                                          near an edge, it carries the viewport
//                                          with it, the dog staying put on screen
//                                          while it travels through the park
//
// both stopping at the world's edge. Intents (a drag, then a pan, or a pan)
// only when something moves.
export function edgeScroll(band, viewport) {
  if (band === "none") return [];
  if (band.kind === "pan") {
    const want = {
      parkX: viewport.parkX - axisScroll(band.x, viewport.width, 0),
      parkY: viewport.parkY - axisScroll(band.y, viewport.height, 0),
    };
    const kept = viewportKeptOnWorld(viewport, want.parkX, want.parkY);
    if (kept.parkX === viewport.parkX && kept.parkY === viewport.parkY) return [];
    return [{ kind: "pan", parkX: kept.parkX, parkY: kept.parkY }];
  }
  const at = viewportFromPark(viewport, band.parkX, band.parkY);
  const eastward = axisScroll(at.viewportX, viewport.width, dog_px / 2);
  const southward = axisScroll(at.viewportY, viewport.height, dog_px / 2);
  const to = keptInWorld(band.parkX + eastward, band.parkY + southward);
  const movedX = to.parkX - band.parkX;
  const movedY = to.parkY - band.parkY;
  if (movedX === 0 && movedY === 0) return [];
  return [
    { kind: "drag", dogId: band.dogId, parkX: to.parkX, parkY: to.parkY },
    { kind: "pan", parkX: viewport.parkX + movedX, parkY: viewport.parkY + movedY },
  ];
}

// Where a hand holds a pan, for the edge bands: the pointer's viewport
// point, or "none" (resting, or holding a dog: the engine knows that dog).
export function panPointer(hand) {
  return hand.kind === "panning" ? { x: hand.lastX, y: hand.lastY } : "none";
}

// What a press at (x, y) is on, in `mode`: `hit` over what the last frame
// drew, `drawn` = { mode, objects }; a list drawn in the other mode (the
// mode flipped since) is on nothing.
export function pressedOn(drawn, mode, x, y) {
  return drawn.mode === mode ? hit(drawn.objects, x, y) : null;
}
