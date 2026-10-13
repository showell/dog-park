// The park's geometry and what a frame draws: its sizes, the two frames
// (park and viewport points), the tiles and the world, the overview's
// frame, and the scene builders, the lists blit.js draws. All pure.
//
// TWO FRAMES, both in CSS pixels: a PARK point (parkX, parkY) is where a
// dog stands in the world; a VIEWPORT point (viewportX, viewportY) is where
// it is on the screen, from the screen's top-left. The viewport's own
// top-left is a park point; north is smaller parkY.

export const dog_px = 40;
export const cow_px = dog_px * 1.5;
export const cow_emoji = "🐄";
// The four breeds: dog n has look n mod 4 (dogs.zig's `looks`).
export const dog_looks = ["🐕", "🐩", "🦮", "🐕‍🦺"];

// ── frames ──────────────────────────────────────────────────────────────────

export function viewportFromPark(viewport, parkX, parkY) {
  return { viewportX: parkX - viewport.parkX, viewportY: parkY - viewport.parkY };
}

export function parkFromViewport(viewport, viewportX, viewportY) {
  return { parkX: viewport.parkX + viewportX, parkY: viewport.parkY + viewportY };
}


// A park point kept on screen, a dog's half-size in from each edge: a held
// dog never leaves the screen.
export function keptOnScreen(viewport, parkX, parkY) {
  const half = dog_px / 2;
  return {
    parkX: Math.min(Math.max(parkX, viewport.parkX + half), viewport.parkX + viewport.width - half),
    parkY: Math.min(Math.max(parkY, viewport.parkY + half), viewport.parkY + viewport.height - half),
  };
}

// ── tiles and the world ─────────────────────────────────────────────────────

// The world: `world_tiles` by `world_tiles` tiles (the server's tiles.zig),
// its edges clamping; the populated park is the 10 x 10 tiles in its middle.
// A page subscribes to at most `most_tiles` (the server refuses more).
export const tile_px = 500;
export const most_tiles = 64;
export const world_tiles = 64;
export const world_px = world_tiles * tile_px;

// A park point kept in the world.
export function keptInWorld(parkX, parkY) {
  return {
    parkX: Math.min(Math.max(parkX, 0), world_px - 1),
    parkY: Math.min(Math.max(parkY, 0), world_px - 1),
  };
}

// A viewport's top-left kept so its centre is in the world: a pan stops at
// the world's edge.
export function viewportKeptOnWorld(viewport, parkX, parkY) {
  const centre = keptInWorld(parkX + viewport.width / 2, parkY + viewport.height / 2);
  return { parkX: centre.parkX - viewport.width / 2, parkY: centre.parkY - viewport.height / 2 };
}

export function inWorld(t) {
  return t.col >= 0 && t.row >= 0 && t.col < world_tiles && t.row < world_tiles;
}
// How far past the viewport's edges the page subscribes, so a scroll finds
// its dogs already known: the widest of these that keeps a screen within
// `most_tiles`.
const tile_margins_px = [tile_px / 2, tile_px / 4, 0];

export function tileOf(parkX, parkY) {
  return { col: Math.floor(parkX / tile_px), row: Math.floor(parkY / tile_px) };
}

export function tileKey(t) { return `${t.col},${t.row}`; }

// Every tile of the world meeting the park rectangle from (parkX, parkY),
// `width` by `height`.
export function tilesMeeting(parkX, parkY, width, height) {
  const first = tileOf(parkX, parkY);
  const last = tileOf(parkX + width - 1, parkY + height - 1);
  const out = [];
  for (let row = first.row; row <= last.row; row++) {
    for (let col = first.col; col <= last.col; col++) {
      if (inWorld({ col, row })) out.push({ col, row });
    }
  }
  return out;
}

// The tiles the page wants: those within the widest margin of the viewport
// that keeps them within `most_tiles`.
export function wantedTiles(viewport) {
  for (const m of tile_margins_px) {
    const near = tilesMeeting(viewport.parkX - m, viewport.parkY - m, viewport.width + 2 * m, viewport.height + 2 * m);
    if (near.length <= most_tiles) return near;
  }
  // A screen this big shows more than a page may subscribe: the
  // subscription keeps those nearest its centre.
  return tilesMeeting(viewport.parkX, viewport.parkY, viewport.width, viewport.height);
}

// **WHAT THE PAGE SUBSCRIBES** (docs/PHYSICS.md item 11, decision 13): the
// region's tiles first (while a dog is leashed: the physics can't tick
// without them), then the display's (`wantedTiles`), nearest the
// viewport's centre first (the square metric, from each tile's centre;
// ties by row, then column), at most `most_tiles` in all.
export function subscription(regionTiles, viewport) {
  const out = new Map(regionTiles.map((t) => [tileKey(t), t]));
  const cx = viewport.parkX + viewport.width / 2;
  const cy = viewport.parkY + viewport.height / 2;
  const away = (t) => Math.max(Math.abs((t.col + 0.5) * tile_px - cx), Math.abs((t.row + 0.5) * tile_px - cy));
  const display = wantedTiles(viewport).sort((a, b) => away(a) - away(b) || a.row - b.row || a.col - b.col);
  for (const t of display) {
    if (out.size >= most_tiles) break;
    out.set(tileKey(t), t);
  }
  return [...out.values()];
}

// ── the overview's frame ────────────────────────────────────────────────────

// **THE OVERVIEW IS A WINDOW ONTO THE WORLD**, never all of it: the screen,
// `overview_margin_px` in from its edges, at the scale that puts
// `overview_tiles` tiles across its shorter side (the scale the whole 10 x
// 10 world had, so a critter's dot is as visible as it was). Its top-left,
// `at`, is a park point, kept so the window stays in the world; a park
// point (parkX, parkY) is at origin + park * scale on screen. Two
// scrollbars in the margins, along the bottom and the right, say where the
// window is in the world: a track the window's length, and a thumb on it as
// long, and as far along, as the window is in the world.
export const overview_margin_px = 20;
export const overview_tiles = 10;
const scrollbar_px = 12;

export function overviewFrame(width, height, at) {
  const m = overview_margin_px;
  const scale = (Math.min(width, height) - 2 * m) / (overview_tiles * tile_px);
  const window = { x: m, y: m, w: width - 2 * m, h: height - 2 * m };
  const span = { parkW: window.w / scale, parkH: window.h / scale };
  const kept = overviewKept(span, at);
  const across = (m - scrollbar_px) / 2;
  return {
    scale,
    originX: m - kept.parkX * scale,
    originY: m - kept.parkY * scale,
    at: kept,
    window,
    span,
    tracks: {
      x: { x: window.x, y: height - m + across, w: window.w, h: scrollbar_px },
      y: { x: width - m + across, y: window.y, w: scrollbar_px, h: window.h },
    },
  };
}

// The window's top-left kept so the window stays in the world (centred on
// an axis it is wider than the world along).
function overviewKept(span, at) {
  const axis = (a, len) => (len >= world_px ? (world_px - len) / 2 : Math.min(Math.max(a, 0), world_px - len));
  return { parkX: axis(at.parkX, span.parkW), parkY: axis(at.parkY, span.parkH) };
}

// The window's top-left for the overview just opened: centred on the
// viewport, kept in the world.
export function overviewCentredOn(viewport) {
  const o = overviewFrame(viewport.width, viewport.height, { parkX: 0, parkY: 0 });
  return overviewFrame(viewport.width, viewport.height, {
    parkX: viewport.parkX + viewport.width / 2 - o.span.parkW / 2,
    parkY: viewport.parkY + viewport.height / 2 - o.span.parkH / 2,
  }).at;
}

// The window's top-left moved as little as shows the whole viewport (it is
// always smaller than the window), kept in the world: a dragged view's
// rectangle carries the window with it at the window's edge.
export function overviewShowing(o, viewport) {
  const axis = (a, len, v, vlen) => Math.min(Math.max(a, v + vlen - len), v);
  const want = {
    parkX: axis(o.at.parkX, o.span.parkW, viewport.parkX, viewport.width),
    parkY: axis(o.at.parkY, o.span.parkH, viewport.parkY, viewport.height),
  };
  return overviewKept(o.span, want);
}

// The thumb on a scrollbar's track: as long, and as far along, as the
// window is in the world.
export function overviewThumb(o, axis) {
  const t = o.tracks[axis];
  if (axis === "x") return { x: t.x + (o.at.parkX / world_px) * t.w, y: t.y, w: (o.span.parkW / world_px) * t.w, h: t.h };
  return { x: t.x, y: t.y + (o.at.parkY / world_px) * t.h, w: t.w, h: (o.span.parkH / world_px) * t.h };
}

// The window's top-left moved by (dParkX, dParkY), kept in the world.
export function overviewMoved(o, dParkX, dParkY) {
  return overviewKept(o.span, { parkX: o.at.parkX + dParkX, parkY: o.at.parkY + dParkY });
}

// The window's top-left with the thumb on `axis` dragged `d` px along its
// track (the world moves the other way), kept in the world.
export function overviewScrolled(o, axis, d) {
  const t = o.tracks[axis];
  return axis === "x" ? overviewMoved(o, (d * world_px) / t.w, 0) : overviewMoved(o, 0, (d * world_px) / t.h);
}

// The window's top-left with the thumb on `axis` centred on the track's
// point at (x, y): a press on the track off the thumb jumps there.
export function overviewJumped(o, axis, x, y) {
  const t = o.tracks[axis];
  const want = axis === "x"
    ? { parkX: ((x - t.x) / t.w) * world_px - o.span.parkW / 2, parkY: o.at.parkY }
    : { parkX: o.at.parkX, parkY: ((y - t.y) / t.h) * world_px - o.span.parkH / 2 };
  return overviewKept(o.span, want);
}

export function overviewFromPark(o, parkX, parkY) {
  return { viewportX: o.originX + parkX * o.scale, viewportY: o.originY + parkY * o.scale };
}

// ── what a frame draws ──────────────────────────────────────────────────────

// The lists blit.js draws, built from what the page knows: each a plain
// list of objects (blit.js says their shape), in drawing order, the last on
// top. The dogs are the near scene's targets, the view's rectangle the
// overview's; nothing else can be hit.

export const view_target = "view";

// A scrollbar's track and its thumb, in the overview, by axis ("x" or "y").
export function trackTarget(axis) { return `scroll:${axis}`; }
export function thumbTarget(axis) { return `scroll:${axis}:thumb`; }

// The axis a scrollbar target names, and whether it is the thumb; or "none"
// for any other target.
export function scrollOfTarget(id) {
  const m = /^scroll:([xy])(:thumb)?$/.exec(id ?? "");
  return m ? { axis: m[1], part: m[2] ? "thumb" : "track" } : "none";
}

export function dogTarget(dogId) { return `dog:${dogId}`; }

// The dog's id a target names, or "none" for any other.
export function dogOfTarget(id) {
  const m = /^dog:(\d+)$/.exec(id ?? "");
  return m ? Number(m[1]) : "none";
}

// **BETWEEN TICKS, A FRAME DRAWS EACH THING PART WAY** from where it was at
// the tick before (`was`, a park point, or undefined: new since) to where
// it is (`cur`), `alpha` of the way (0 to 1, the frame's way through its
// tick). With no `was` it is drawn where it is: the engine leaves out a
// critter the physics says JUMPED this tick (out from under, or a push's
// nearest spot), since sliding would draw it through whatever is between;
// every other move glides, however far a fast drag carried it.
export function between(was, cur, alpha) {
  if (was === undefined) return { parkX: cur.parkX, parkY: cur.parkY };
  return { parkX: was.parkX + (cur.parkX - was.parkX) * alpha, parkY: was.parkY + (cur.parkY - was.parkY) * alpha };
}

// Where everything is drawn as it is: no tick under way.
export const still = { alpha: 1, was: { viewport: undefined, dogs: new Map(), cows: new Map() } };

// The park near: the tiles on screen (each a square of its shade, its name
// in its middle), then each cow, then each dog, each with its place under
// it (where it is, not where it is drawn), the leashed dog ringed (green while the drag is on, red once it has
// ended: a bump turns it red). `dogs`
// and `cows` in the order they are drawn; `motion` = { alpha, was } (the
// engine's view: was.viewport a park point, was.dogs and was.cows Maps of
// them by id), each drawn `between` there and here, the leashed dog too.
export function nearScene(viewportNow, dogs, cows, leashed, motion = still) {
  const { alpha, was } = motion;
  const viewport = { ...viewportNow, ...between(was.viewport, viewportNow, alpha) };
  const out = [];
  for (const t of tilesMeeting(viewport.parkX, viewport.parkY, viewport.width, viewport.height)) {
    const at = viewportFromPark(viewport, t.col * tile_px, t.row * tile_px);
    const id = `tile:${tileKey(t)}`;
    out.push({ id, shape: "rect", x: at.viewportX, y: at.viewportY, w: tile_px, h: tile_px,
      fill: (t.col + t.row) % 2 === 0 ? "#ffffff" : "#eaf3fc", role: "scenery" });
    out.push({ id: `${id}:label`, shape: "text", x: at.viewportX + tile_px / 2, y: at.viewportY + tile_px / 2, w: 0, h: 0,
      text: `(${t.col}, ${t.row})`, font: "20px monospace", fill: "#9ab", role: "scenery" });
  }
  const sprite = (id, critter, drawn, emoji, size, role) => {
    const at = viewportFromPark(viewport, drawn.parkX, drawn.parkY);
    out.push({ id, shape: "glyph", x: at.viewportX, y: at.viewportY, w: size, h: size,
      text: emoji, fill: "#000", role });
    out.push({ id: `${id}:label`, shape: "text", x: at.viewportX, y: at.viewportY + size * 0.85, w: 0, h: 0,
      text: `(${Math.round(critter.parkX)}, ${Math.round(critter.parkY)})`, font: "11px monospace", fill: "#555", role: "scenery" });
  };
  for (const c of cows) sprite(`cow:${c.id}`, c, between(was.cows.get(c.id), c, alpha), cow_emoji, cow_px, "scenery");
  for (const d of dogs) {
    const drawn = between(was.dogs.get(d.id), d, alpha);
    if (leashed.kind !== "none" && leashed.dogId === d.id) {
      const at = viewportFromPark(viewport, drawn.parkX, drawn.parkY);
      out.push({ id: `${dogTarget(d.id)}:ring`, shape: "ring", x: at.viewportX, y: at.viewportY, w: 2 * (dog_px * 0.7), h: 2 * (dog_px * 0.7),
        stroke: leashed.kind === "in_hand" ? "#2a2" : "#d33", lineWidth: 3, role: "scenery" });
    }
    sprite(dogTarget(d.id), d, drawn, d.emoji, dog_px, "target");
  }
  return out;
}

// The overview: a window onto the world (overviewFrame, its top-left `at`),
// each tile in it a square (white and blue where subscribed, pink where
// not), each cow a brown dot and each dog a smaller dark one (pale where its
// tile is not subscribed: only remembered), the dog leashed last ringed;
// the margins over what spills past the window; the view a rectangle; and
// the two scrollbars.
export function overviewScene(viewport, dogs, cows, subscribed, lastLeashed, at) {
  const o = overviewFrame(viewport.width, viewport.height, at);
  const ground = "#556";
  const out = [{ id: "ground", shape: "rect", x: 0, y: 0, w: viewport.width, h: viewport.height, fill: ground, role: "scenery" }];
  for (const { col, row } of tilesMeeting(o.at.parkX, o.at.parkY, o.span.parkW, o.span.parkH)) {
    const odd = (col + row) % 2 === 1;
    const fill = subscribed.has(tileKey({ col, row }))
      ? (odd ? "#eaf3fc" : "#ffffff")
      : (odd ? "#f2c4c4" : "#f8d8d8");
    const corner = overviewFromPark(o, col * tile_px, row * tile_px);
    out.push({ id: `tile:${col},${row}`, shape: "rect", x: corner.viewportX, y: corner.viewportY,
      w: tile_px * o.scale, h: tile_px * o.scale, fill, role: "scenery" });
  }
  const shown = (c) => c.parkX >= o.at.parkX && c.parkX <= o.at.parkX + o.span.parkW
    && c.parkY >= o.at.parkY && c.parkY <= o.at.parkY + o.span.parkH;
  const live = (c) => subscribed.has(tileKey(tileOf(c.parkX, c.parkY)));
  for (const c of cows) {
    if (!shown(c)) continue;
    const p = overviewFromPark(o, c.parkX, c.parkY);
    out.push({ id: `cow:${c.id}`, shape: "dot", x: p.viewportX, y: p.viewportY, w: 8, h: 8,
      fill: live(c) ? "#7a4a1a" : "#c9a37a", role: "scenery" });
  }
  for (const d of dogs) {
    if (!shown(d)) continue;
    const p = overviewFromPark(o, d.parkX, d.parkY);
    out.push({ id: dogTarget(d.id), shape: "dot", x: p.viewportX, y: p.viewportY, w: 5, h: 5,
      fill: live(d) ? "#333" : "#a88", role: "scenery" });
    if (lastLeashed.kind === "dog" && lastLeashed.dogId === d.id) {
      out.push({ id: `${dogTarget(d.id)}:ring`, shape: "ring", x: p.viewportX, y: p.viewportY, w: 22, h: 22,
        stroke: "#d33", lineWidth: 3, role: "scenery" });
    }
  }
  // The margins, over the tiles and dots that spill past the window.
  const w = o.window;
  for (const [id, x, y, mw, mh] of [
    ["top", 0, 0, viewport.width, w.y],
    ["bottom", 0, w.y + w.h, viewport.width, viewport.height - w.y - w.h],
    ["left", 0, w.y, w.x, w.h],
    ["right", w.x + w.w, w.y, viewport.width - w.x - w.w, w.h],
  ]) out.push({ id: `margin:${id}`, shape: "rect", x, y, w: mw, h: mh, fill: ground, role: "scenery" });
  const corner = overviewFromPark(o, viewport.parkX, viewport.parkY);
  out.push({ id: view_target, shape: "frame", x: corner.viewportX, y: corner.viewportY,
    w: viewport.width * o.scale, h: viewport.height * o.scale, stroke: "#222", lineWidth: 2, role: "target" });
  for (const axis of ["x", "y"]) {
    const t = o.tracks[axis];
    out.push({ id: trackTarget(axis), shape: "rect", x: t.x, y: t.y, w: t.w, h: t.h, fill: "#778", role: "target" });
    const th = overviewThumb(o, axis);
    out.push({ id: thumbTarget(axis), shape: "rect", x: th.x, y: th.y, w: th.w, h: th.h, fill: "#dde", role: "target" });
  }
  return out;
}

// A message across the screen, over whatever is drawn: why the page has
// stopped, or what it waits for.
export function messageScene(viewport, text) {
  return [
    { id: "message:back", shape: "rect", x: 0, y: viewport.height / 2 - 30, w: viewport.width, h: 60, fill: "rgba(0,0,0,0.7)", role: "scenery" },
    { id: "message", shape: "text", x: viewport.width / 2, y: viewport.height / 2, w: 0, h: 0, text, font: "18px sans-serif", fill: "#fff", role: "scenery" },
  ];
}
