// The pointer, pure: how far the edge bands scroll a tick, and what a
// pointer event means (the hand after it, and what the page does). park.js's
// listeners turn DOM events into these events and apply the intents; the
// engine runs the edge bands each tick.

import {
  dog_px, viewportFromPark, wrappedPoint, nearest,
  overviewFrame, overviewCentredOn, overviewShowing, overviewMoved, overviewScrolled, overviewJumped,
  view_target, dogOfTarget, scrollOfTarget,
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
//   { kind: "dragging", dogId, lastX, lastY }
//       a dog by its number, held, from the pointer's last viewport point:
//       **A DRAG IS A DISPLACEMENT** (docs/PHYSICS.md), how far the pointer
//       moved, which the next tick adds to where the dog actually is; the
//       pointer never puts the dog anywhere, so the two may drift apart (a
//       bump, the 100 px cap, a freeze: the torus has no edge, decision 14)
//   { kind: "scrolling", axis, lastX, lastY }
//       the overview's scrollbar on `axis` ("x" or "y") held, from the
//       pointer's last viewport point
//
// AN EVENT, in viewport points:
//
//   { type: "down", x, y, dogAt }   dogAt: the pressed dog's park point, or
//                                   "none" when the press is on no dog the
//                                   page knows
//   { type: "move", x, y }
//   { type: "up" }  { type: "cancel" }
//   { type: "wheel", dx, dy }       a wheel or trackpad scroll, in px
//   { type: "map" }                 the "m" key or the Map/Back button: flips near and the overview
//
// AN INTENT, what the page does about it, in order:
//
//   { kind: "grab", dogId }                 leash the dog (at the next tick)
//   { kind: "drag", dogId, dx, dy }         the pointer moved the dog (dx, dy)
//                                           px; the next tick plays them in order
//   { kind: "letgo" }                       the dog in hand goes, kept on the
//                                           leash (at the next tick, after its drags)
//   { kind: "pan", parkX, parkY }           the viewport's top-left is now here
//   { kind: "scroll", parkX, parkY }        the overview's window's top-left
//                                           is now here (scene.js's overviewFrame)
//   { kind: "mode", mode }                  "near" or "overview" from now on
//
// No intent at all is an empty list.

export const resting = { kind: "resting" };

// What `event` means to a hand in `mode`, the press on `hitId` (what
// blit.js's `hit` answered over the list last drawn, null for nothing) with
// the viewport as it is and the overview's window at `overviewAt` (its
// top-left, a park point): the hand after it, and the intents.
export function meaning(hand, event, hitId, mode, viewport, overviewAt = { parkX: 0, parkY: 0 }) {
  const o = overviewFrame(viewport.width, viewport.height, overviewAt);
  const scrollTo = (at) => (at.parkX === o.at.parkX && at.parkY === o.at.parkY ? [] : [{ kind: "scroll", parkX: at.parkX, parkY: at.parkY }]);
  switch (event.type) {
    case "down": {
      if (mode === "overview") {
        // The view's rectangle moves only when it is pressed; a scrollbar's
        // thumb is held where pressed, and a press on its track jumps the
        // thumb there, then holds it.
        if (hitId === view_target) return { hand: { kind: "panning", lastX: event.x, lastY: event.y }, intents: [] };
        const bar = scrollOfTarget(hitId);
        if (bar === "none") return { hand: resting, intents: [] };
        const hand2 = { kind: "scrolling", axis: bar.axis, lastX: event.x, lastY: event.y };
        return { hand: hand2, intents: bar.part === "thumb" ? [] : scrollTo(overviewJumped(o, bar.axis, event.x, event.y)) };
      }
      const dogId = dogOfTarget(hitId);
      if (dogId === "none" || event.dogAt === "none") {
        return { hand: { kind: "panning", lastX: event.x, lastY: event.y }, intents: [] };
      }
      return {
        hand: { kind: "dragging", dogId, lastX: event.x, lastY: event.y },
        intents: [{ kind: "grab", dogId }],
      };
    }
    case "move": {
      if (hand.kind === "panning") {
        // Near, the park moves with the pointer, so the viewport moves
        // against it; in the overview, the view's rectangle moves with it.
        const dx = event.x - hand.lastX;
        const dy = event.y - hand.lastY;
        const want = mode === "near"
          ? { parkX: viewport.parkX - dx, parkY: viewport.parkY - dy }
          : { parkX: viewport.parkX + dx / o.scale, parkY: viewport.parkY + dy / o.scale };
        const to = wrappedPoint(want.parkX, want.parkY);
        // In the overview, the window follows the view's rectangle past its edge.
        const follow = mode === "near" ? [] : scrollTo(overviewShowing(o, { ...viewport, ...to }));
        return {
          hand: { kind: "panning", lastX: event.x, lastY: event.y },
          intents: [{ kind: "pan", parkX: to.parkX, parkY: to.parkY }, ...follow],
        };
      }
      if (hand.kind === "scrolling") {
        const d = hand.axis === "x" ? event.x - hand.lastX : event.y - hand.lastY;
        return {
          hand: { ...hand, lastX: event.x, lastY: event.y },
          intents: scrollTo(overviewScrolled(o, hand.axis, d)),
        };
      }
      if (hand.kind !== "dragging") return { hand, intents: [] };
      // How far the pointer moved: near, a viewport px is a park px.
      const dx = event.x - hand.lastX;
      const dy = event.y - hand.lastY;
      if (dx === 0 && dy === 0) return { hand, intents: [] };
      return { hand: { ...hand, lastX: event.x, lastY: event.y }, intents: [{ kind: "drag", dogId: hand.dogId, dx, dy }] };
    }
    case "up":
    case "cancel":
      return { hand: resting, intents: hand.kind === "dragging" ? [{ kind: "letgo" }] : [] };
    case "wheel":
      // The overview's window scrolls with the wheel, as a page's content
      // does; near, a wheel means nothing.
      if (mode !== "overview") return { hand, intents: [] };
      return { hand, intents: scrollTo(overviewMoved(o, event.dx / o.scale, event.dy / o.scale)) };
    case "map": {
      // The overview opens on a window centred on the view.
      const centred = overviewCentredOn(viewport);
      const flipped = mode === "near"
        ? [{ kind: "mode", mode: "overview" }, { kind: "scroll", parkX: centred.parkX, parkY: centred.parkY }]
        : [{ kind: "mode", mode: "near" }];
      return { hand: resting, intents: hand.kind === "dragging" ? [{ kind: "letgo" }, ...flipped] : flipped };
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
// both going on across the seam, the viewport and the dog wrapped into the
// world. Intents (a drag, then a pan, or a pan)
// only when something moves.
export function edgeScroll(band, viewport) {
  if (band === "none") return [];
  if (band.kind === "pan") {
    const want = {
      parkX: viewport.parkX - axisScroll(band.x, viewport.width, 0),
      parkY: viewport.parkY - axisScroll(band.y, viewport.height, 0),
    };
    const kept = wrappedPoint(want.parkX, want.parkY);
    if (kept.parkX === viewport.parkX && kept.parkY === viewport.parkY) return [];
    return [{ kind: "pan", parkX: kept.parkX, parkY: kept.parkY }];
  }
  const at = viewportFromPark(viewport,
    nearest(band.parkX, viewport.parkX + viewport.width / 2), nearest(band.parkY, viewport.parkY + viewport.height / 2));
  const eastward = axisScroll(at.viewportX, viewport.width, dog_px / 2);
  const southward = axisScroll(at.viewportY, viewport.height, dog_px / 2);
  if (eastward === 0 && southward === 0) return [];
  const to = wrappedPoint(band.parkX + eastward, band.parkY + southward);
  const pan = wrappedPoint(viewport.parkX + eastward, viewport.parkY + southward);
  return [
    { kind: "drag", dogId: band.dogId, parkX: to.parkX, parkY: to.parkY },
    { kind: "pan", parkX: pan.parkX, parkY: pan.parkY },
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
