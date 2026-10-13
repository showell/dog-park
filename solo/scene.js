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

export const tile_px = 500;
export const most_tiles = 25;
export const world_tiles = 10;
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
  const shown = tilesMeeting(viewport.parkX, viewport.parkY, viewport.width, viewport.height);
  console.error(`a screen this big shows ${shown.length} tiles, past the ${most_tiles} a page may subscribe`);
  return shown.slice(0, most_tiles);
}

// ── the overview's frame ────────────────────────────────────────────────────

// The whole world fits the screen, `overview_margin_px` in from its edges:
// a park point at (parkX, parkY) is at origin + park * scale on screen.
const overview_margin_px = 20;

export function overviewFrame(width, height) {
  const scale = Math.min(width - 2 * overview_margin_px, height - 2 * overview_margin_px) / world_px;
  return {
    scale,
    originX: (width - world_px * scale) / 2,
    originY: (height - world_px * scale) / 2,
  };
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

export function dogTarget(dogId) { return `dog:${dogId}`; }

// The dog's id a target names, or "none" for any other.
export function dogOfTarget(id) {
  const m = /^dog:(\d+)$/.exec(id ?? "");
  return m ? Number(m[1]) : "none";
}

// **BETWEEN TICKS, A FRAME DRAWS EACH THING PART WAY** from where it was at
// the tick before (`was`, a park point, or undefined: new since) to where
// it is (`cur`), `alpha` of the way (0 to 1, the frame's way through its
// tick). A move of more than `snap_px` on either axis in one tick is drawn
// where it ends (a cow's jump, a dog the server put elsewhere): sliding
// would draw it through whatever is between.
export const snap_px = 50;

export function between(was, cur, alpha) {
  if (was === undefined || Math.abs(cur.parkX - was.parkX) > snap_px || Math.abs(cur.parkY - was.parkY) > snap_px) {
    return { parkX: cur.parkX, parkY: cur.parkY };
  }
  return { parkX: was.parkX + (cur.parkX - was.parkX) * alpha, parkY: was.parkY + (cur.parkY - was.parkY) * alpha };
}

// Where everything is drawn as it is: no tick under way.
export const still = { alpha: 1, was: { viewport: undefined, dogs: new Map(), cows: new Map() } };

// The park near: the tiles on screen (each a square of its shade, its name
// in its middle), then each cow, then each dog, each with its place under
// it (where it is, not where it is drawn), the leashed dog ringed. `dogs`
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
        stroke: "#d33", lineWidth: 3, role: "scenery" });
    }
    sprite(dogTarget(d.id), d, drawn, d.emoji, dog_px, "target");
  }
  return out;
}

// The overview: the whole world on the screen, each tile a square (white
// and blue where subscribed, pink where not), each cow a brown dot and each
// dog a smaller dark one (pale where its tile is not subscribed: only
// remembered), the dog leashed last ringed, and the view a rectangle.
export function overviewScene(viewport, dogs, cows, subscribed, lastLeashed) {
  const o = overviewFrame(viewport.width, viewport.height);
  const out = [{ id: "ground", shape: "rect", x: 0, y: 0, w: viewport.width, h: viewport.height, fill: "#556", role: "scenery" }];
  for (let row = 0; row < world_tiles; row++) {
    for (let col = 0; col < world_tiles; col++) {
      const odd = (col + row) % 2 === 1;
      const fill = subscribed.has(tileKey({ col, row }))
        ? (odd ? "#eaf3fc" : "#ffffff")
        : (odd ? "#f2c4c4" : "#f8d8d8");
      const at = overviewFromPark(o, col * tile_px, row * tile_px);
      out.push({ id: `tile:${col},${row}`, shape: "rect", x: at.viewportX, y: at.viewportY,
        w: tile_px * o.scale, h: tile_px * o.scale, fill, role: "scenery" });
    }
  }
  const live = (c) => subscribed.has(tileKey(tileOf(c.parkX, c.parkY)));
  for (const c of cows) {
    const at = overviewFromPark(o, c.parkX, c.parkY);
    out.push({ id: `cow:${c.id}`, shape: "dot", x: at.viewportX, y: at.viewportY, w: 8, h: 8,
      fill: live(c) ? "#7a4a1a" : "#c9a37a", role: "scenery" });
  }
  for (const d of dogs) {
    const at = overviewFromPark(o, d.parkX, d.parkY);
    out.push({ id: dogTarget(d.id), shape: "dot", x: at.viewportX, y: at.viewportY, w: 5, h: 5,
      fill: live(d) ? "#333" : "#a88", role: "scenery" });
    if (lastLeashed.kind === "dog" && lastLeashed.dogId === d.id) {
      out.push({ id: `${dogTarget(d.id)}:ring`, shape: "ring", x: at.viewportX, y: at.viewportY, w: 22, h: 22,
        stroke: "#d33", lineWidth: 3, role: "scenery" });
    }
  }
  const corner = overviewFromPark(o, viewport.parkX, viewport.parkY);
  out.push({ id: view_target, shape: "frame", x: corner.viewportX, y: corner.viewportY,
    w: viewport.width * o.scale, h: viewport.height * o.scale, stroke: "#222", lineWidth: 2, role: "target" });
  return out;
}
