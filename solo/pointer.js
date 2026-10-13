// The pointer's pure helpers: which dog a press grabs, and how far the edge
// bands scroll. The listeners that use them are park.js's.

import { dog_px, viewportFromPark } from "./scene.js";

// ── drag ────────────────────────────────────────────────────────────────────

// The dog under the pointer, the one drawn last (on top) first, and where
// the pointer grabbed it relative to its centre, so it doesn't jump.
export function grabbed(viewport, dogs, pointerViewportX, pointerViewportY) {
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
export const band_px = 80;
export const slowest_px_per_frame = (2 / 3) * 0.7;
export const fastest_px_per_frame = (16 / 3) * 0.7;

export function bandSpeed(depthPx) {
  const depth = depthPx / band_px; // 0 at the band's inner edge, 1 at the screen's edge
  if (depth <= 0) return 0;
  return slowest_px_per_frame + Math.min(depth, 1) * (fastest_px_per_frame - slowest_px_per_frame);
}

// How far the band moves the viewport this frame along one axis, toward the
// far edge (negative: toward the near one), for something at `viewportAt` on
// a screen `length` long that way, which comes no nearer an edge than
// `reachPx` (a dog's half-size; 0 for the pointer): 0 outside both bands.
export function axisScroll(viewportAt, length, reachPx) {
  const near = bandSpeed(reachPx + band_px - viewportAt);
  const far = bandSpeed(viewportAt - (length - reachPx - band_px));
  return far - near;
}
