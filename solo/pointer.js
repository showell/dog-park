// The pointer's pure helpers: how far the edge bands scroll. The listeners
// that use them are park.js's; what a press is on is blit.js's `hit`.

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
