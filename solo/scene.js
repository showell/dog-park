// The park's geometry: its sizes, the two frames (park and viewport points),
// the tiles and the world, and the overview's frame. All pure.
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
