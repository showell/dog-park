// The blitter: draws a list of objects onto a canvas, and says which object
// is under a point. It knows shapes, colours and the screen, and nothing of
// what the objects stand for; the scene builders (scene.js) make the lists.
//
// AN OBJECT, in viewport points (CSS px from the screen's top-left):
//
//   { id:    string, opaque here: what `hit` answers
//     shape: "rect"  a filled rectangle,  (x, y) its top-left, w by h
//          | "frame" a stroked rectangle, (x, y) its top-left, w by h
//          | "dot"   a filled circle,     (x, y) its centre, w across
//          | "ring"  a stroked circle,    (x, y) its centre, w across
//          | "glyph" text drawn h px high in serif (an emoji), centred on (x, y)
//          | "text"  text in `font`, centred on (x, y)
//     x, y, w, h: numbers; for a dot, a ring or a glyph the w by h box
//                 centred on (x, y) is what `hit` tests
//     fill:      colour (rect, dot, glyph, text)
//     stroke, lineWidth: colour and px (frame, ring)
//     text:      string (glyph, text);  font: CSS font (text)
//     role:      "target" (`hit` can answer it) | "scenery" (it never does) }
//
// **THE LIST'S ORDER IS THE DRAWING ORDER**: each object is drawn over those
// before it, so the LAST object is on top, and `hit` looks from the last
// back. Hit order is draw order by construction.

// Clears the canvas and draws `objects` in order.
export function draw(ctx, objects) {
  const ratio = globalThis.devicePixelRatio || 1;
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, ctx.canvas.width, ctx.canvas.height);
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  for (const o of objects) {
    switch (o.shape) {
      case "rect":
        ctx.fillStyle = o.fill;
        ctx.fillRect(o.x, o.y, o.w, o.h);
        break;
      case "frame":
        ctx.lineWidth = o.lineWidth;
        ctx.strokeStyle = o.stroke;
        ctx.strokeRect(o.x, o.y, o.w, o.h);
        break;
      case "dot":
        ctx.beginPath();
        ctx.arc(o.x, o.y, o.w / 2, 0, 2 * Math.PI);
        ctx.fillStyle = o.fill;
        ctx.fill();
        break;
      case "ring":
        ctx.beginPath();
        ctx.arc(o.x, o.y, o.w / 2, 0, 2 * Math.PI);
        ctx.lineWidth = o.lineWidth;
        ctx.strokeStyle = o.stroke;
        ctx.stroke();
        break;
      case "glyph":
        ctx.font = `${o.h}px serif`;
        ctx.fillStyle = o.fill;
        ctx.fillText(o.text, o.x, o.y);
        break;
      case "text":
        ctx.font = o.font;
        ctx.fillStyle = o.fill;
        ctx.fillText(o.text, o.x, o.y);
        break;
      default:
        throw new Error(`no shape ${o.shape} (${o.id})`);
    }
  }
}

// The id of the topmost target whose box holds the point (edges included),
// or null when there is none.
export function hit(objects, x, y) {
  for (let i = objects.length - 1; i >= 0; i--) {
    const o = objects[i];
    if (o.role === "scenery") continue;
    if (o.role !== "target") throw new Error(`no role ${o.role} (${o.id})`);
    if (inBox(o, x, y)) return o.id;
  }
  return null;
}

function inBox(o, x, y) {
  if (o.shape === "rect" || o.shape === "frame") {
    return x >= o.x && x <= o.x + o.w && y >= o.y && y <= o.y + o.h;
  }
  return Math.abs(x - o.x) <= o.w / 2 && Math.abs(y - o.y) <= o.h / 2;
}
