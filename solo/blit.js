// The blitters: each draws a list it is handed onto the canvas, and owns no
// logic.

import { dog_px } from "./scene.js";

// Draws the ground (each tile a square of its shade, its label in its
// middle), then each sprite (cows first, so dogs are on top) at its
// viewport point and size, with its label under it; a leashed dog ringed.
export function blit(canvas, width, height, ground, sprites) {
  const ratio = window.devicePixelRatio || 1;
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  for (const g of ground) {
    ctx.fillStyle = g.shade;
    ctx.fillRect(g.viewportX, g.viewportY, g.size, g.size);
    ctx.font = "20px monospace";
    ctx.fillStyle = "#9ab";
    ctx.fillText(g.label, g.viewportX + g.size / 2, g.viewportY + g.size / 2);
  }
  for (const s of sprites) {
    if (s.kind === "leashed") {
      ctx.beginPath();
      ctx.arc(s.viewportX, s.viewportY, dog_px * 0.7, 0, 2 * Math.PI);
      ctx.lineWidth = 3;
      ctx.strokeStyle = "#d33";
      ctx.stroke();
    }
    ctx.font = `${s.size}px serif`;
    ctx.fillStyle = "#000";
    ctx.fillText(s.emoji, s.viewportX, s.viewportY);
    ctx.font = "11px monospace";
    ctx.fillStyle = "#555";
    ctx.fillText(s.label, s.viewportX, s.viewportY + s.size * 0.85);
  }
}

// The overview: each tile a square of its shade, each dog a dot (dark when
// live, pale when remembered), a ringed dog with a ring, each cow a larger
// brown dot, and the view a rectangle. All in viewport points.
export function blitOverview(canvas, width, height, squares, dots, view) {
  const ratio = window.devicePixelRatio || 1;
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.fillStyle = "#556";
  ctx.fillRect(0, 0, width, height);
  for (const q of squares) {
    ctx.fillStyle = q.shade;
    ctx.fillRect(q.viewportX, q.viewportY, q.size, q.size);
  }
  for (const d of dots) {
    ctx.beginPath();
    ctx.arc(d.viewportX, d.viewportY, d.kind === "cow" ? 4 : 2.5, 0, 2 * Math.PI);
    ctx.fillStyle = d.kind === "cow" ? (d.freshness === "live" ? "#7a4a1a" : "#c9a37a") : d.freshness === "live" ? "#333" : "#a88";
    ctx.fill();
    if (d.kind === "ringed") {
      ctx.beginPath();
      ctx.arc(d.viewportX, d.viewportY, 11, 0, 2 * Math.PI);
      ctx.lineWidth = 3;
      ctx.strokeStyle = "#d33";
      ctx.stroke();
    }
  }
  ctx.lineWidth = 2;
  ctx.strokeStyle = "#222";
  ctx.strokeRect(view.viewportX, view.viewportY, view.width, view.height);
}
