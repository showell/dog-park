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
// The four breeds: dog n has look n mod 4 (the physics' breeds).
export const dog_looks = ["🐕", "🐩", "🦮", "🐕‍🦺"];

// ── frames ──────────────────────────────────────────────────────────────────

export function viewportFromPark(viewport, parkX, parkY) {
  return { viewportX: parkX - viewport.parkX, viewportY: parkY - viewport.parkY };
}

export function parkFromViewport(viewport, viewportX, viewportY) {
  return { parkX: viewport.parkX + viewportX, parkY: viewport.parkY + viewportY };
}


// ── tiles and the world ─────────────────────────────────────────────────────

// The world: `world_tiles` by `world_tiles` tiles (the server's tiles.zig),
// a torus (docs/PHYSICS.md decision 14): its right edge meets its left, its
// bottom its top. The populated park is the 10 x 10 tiles in its middle. A
// page subscribes to at most `most_tiles` (the server refuses more).
export const tile_px = 500;
export const most_tiles = 64;
export const world_tiles = 64;
export const world_px = world_tiles * tile_px;

// **EVERY PARK POINT HAS ONE NAME IN [0, world_px)**, and many copies a
// whole world apart; the page stores the name and draws the copy nearest
// what it is drawn against.
export function wrapped(a, size = world_px) {
  const r = a % size;
  return r < 0 ? r + size : r + 0; // + 0: never -0

}

export function wrappedPoint(parkX, parkY) {
  return { parkX: wrapped(parkX), parkY: wrapped(parkY) };
}

// The short way round from `from` to `to`, in [-world_px / 2, world_px / 2).
export function offset(from, to) {
  const d = wrapped(to - from);
  return d >= world_px / 2 ? d - world_px : d;
}

// The copy of `a` nearest `ref` (`a` itself when that is nearest).
export function nearest(a, ref) {
  return a + Math.round((ref - a) / world_px) * world_px;
}

export function wrapTile(t) {
  return { col: wrapped(t.col, world_tiles), row: wrapped(t.row, world_tiles) };
}

// How far past the viewport's edges the page subscribes, so a scroll finds
// its dogs already known: the widest of these that keeps a screen within
// `most_tiles`.
const tile_margins_px = [tile_px / 2, tile_px / 4, 0];

export function tileOf(parkX, parkY) {
  return { col: Math.floor(parkX / tile_px), row: Math.floor(parkY / tile_px) };
}

export function tileKey(t) { return `${t.col},${t.row}`; }

// The tiles' copies meeting the park rectangle from (parkX, parkY), `width`
// by `height`, row by row, unwrapped: (col, row) is the copy whose corner is
// (col, row) * tile_px, in the rectangle's own copy of the world.
export function tileCopiesMeeting(parkX, parkY, width, height) {
  const first = tileOf(parkX, parkY);
  const last = tileOf(parkX + width - 1, parkY + height - 1);
  const out = [];
  for (let row = first.row; row <= last.row; row++) {
    for (let col = first.col; col <= last.col; col++) out.push({ col, row });
  }
  return out;
}

// Every tile of the world meeting that rectangle, wrapped, each once.
export function tilesMeeting(parkX, parkY, width, height) {
  const out = new Map();
  for (const t of tileCopiesMeeting(parkX, parkY, width, height)) {
    const w = wrapTile(t);
    out.set(tileKey(w), w);
  }
  return [...out.values()];
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
// viewport's centre first (the square metric, from each tile's centre the
// short way round; ties by row, then column, as the tiles lie around the
// centre: north before south, west before east, across the seam too), at
// most `most_tiles` in all. Every tile wrapped: a region's range across the
// seam may come in either naming.
export function subscription(regionTiles, viewport) {
  const out = new Map(regionTiles.map((t) => [tileKey(wrapTile(t)), wrapTile(t)]));
  const cx = viewport.parkX + viewport.width / 2;
  const cy = viewport.parkY + viewport.height / 2;
  const dx = (t) => offset(cx, (t.col + 0.5) * tile_px);
  const dy = (t) => offset(cy, (t.row + 0.5) * tile_px);
  const away = (t) => Math.max(Math.abs(dx(t)), Math.abs(dy(t)));
  const display = wantedTiles(viewport).sort((a, b) => away(a) - away(b) || dy(a) - dy(b) || dx(a) - dx(b));
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
// `at`, is a park point in [0, world_px): the window scrolls on round the
// torus, and shows whatever copy of a thing is in it. A park point in the
// window's copy of the world (parkX, parkY) is at origin + park * scale on
// screen. Two scrollbars in the margins, along the bottom and the right,
// say where the window is in the world: a track the window's length, and a
// thumb on it as long, and as far along, as the window is in the world;
// the thumb wraps too, its part past the track's end drawn from its start.
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

// The window's top-left named in the world (centred on an axis it is at
// least as wide as the world along: it shows it all).
function overviewKept(span, at) {
  const axis = (a, len) => (len >= world_px ? (world_px - len) / 2 : wrapped(a));
  return { parkX: axis(at.parkX, span.parkW), parkY: axis(at.parkY, span.parkH) };
}

// The window's top-left for the overview just opened: centred on the
// viewport.
export function overviewCentredOn(viewport) {
  const o = overviewFrame(viewport.width, viewport.height, { parkX: 0, parkY: 0 });
  return overviewFrame(viewport.width, viewport.height, {
    parkX: viewport.parkX + viewport.width / 2 - o.span.parkW / 2,
    parkY: viewport.parkY + viewport.height / 2 - o.span.parkH / 2,
  }).at;
}

// The window's top-left moved as little as shows the whole viewport (it is
// always smaller than the window), the viewport's copy nearest the
// window's centre: a dragged view's rectangle carries the window with it
// at the window's edge.
export function overviewShowing(o, viewport) {
  const axis = (a, len, v, vlen) => Math.min(Math.max(a, v + vlen - len), v);
  const vx = nearest(viewport.parkX + viewport.width / 2, o.at.parkX + o.span.parkW / 2) - viewport.width / 2;
  const vy = nearest(viewport.parkY + viewport.height / 2, o.at.parkY + o.span.parkH / 2) - viewport.height / 2;
  const want = {
    parkX: axis(o.at.parkX, o.span.parkW, vx, viewport.width),
    parkY: axis(o.at.parkY, o.span.parkH, vy, viewport.height),
  };
  return overviewKept(o.span, want);
}

// The thumb on a scrollbar's track, in one piece or, across the seam, two
// (the part past the track's end drawn from its start): as long, and as
// far along, as the window is in the world.
export function overviewThumb(o, axis) {
  const t = o.tracks[axis];
  const [at, span, len] = axis === "x" ? [o.at.parkX, o.span.parkW, t.w] : [o.at.parkY, o.span.parkH, t.h];
  const piece = (from, to) => (axis === "x" ? { x: t.x + from, y: t.y, w: to - from, h: t.h } : { x: t.x, y: t.y + from, w: t.w, h: to - from });
  if (span >= world_px) return [piece(0, len)];
  const from = (at / world_px) * len;
  const to = ((at + span) / world_px) * len;
  return to <= len ? [piece(from, to)] : [piece(from, len), piece(0, to - len)];
}

// The window's top-left moved by (dParkX, dParkY).
export function overviewMoved(o, dParkX, dParkY) {
  return overviewKept(o.span, { parkX: o.at.parkX + dParkX, parkY: o.at.parkY + dParkY });
}

// The window's top-left with the thumb on `axis` dragged `d` px along its
// track (the world moves the other way).
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

// Where a park point is in the overview: its copy nearest the window's
// centre.
export function overviewFromPark(o, parkX, parkY) {
  const x = nearest(parkX, o.at.parkX + o.span.parkW / 2);
  const y = nearest(parkY, o.at.parkY + o.span.parkH / 2);
  return { viewportX: o.originX + x * o.scale, viewportY: o.originY + y * o.scale };
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
// every other move glides, however far a fast drag carried it, the short
// way round: from x = world_px - 1 to x = 0 is a 1 px glide across the seam.
export function between(was, cur, alpha) {
  if (was === undefined) return { parkX: cur.parkX, parkY: cur.parkY };
  return wrappedPoint(was.parkX + offset(was.parkX, cur.parkX) * alpha, was.parkY + offset(was.parkY, cur.parkY) * alpha);
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
// Across the seam, each thing is drawn at its copy nearest the viewport's
// centre, and each tile's copy on screen.
export function nearScene(viewportNow, dogs, cows, leashed, motion = still) {
  const { alpha, was } = motion;
  const viewport = { ...viewportNow, ...between(was.viewport, viewportNow, alpha) };
  const out = [];
  for (const copy of tileCopiesMeeting(viewport.parkX, viewport.parkY, viewport.width, viewport.height)) {
    const t = wrapTile(copy);
    const at = viewportFromPark(viewport, copy.col * tile_px, copy.row * tile_px);
    const id = `tile:${tileKey(t)}`;
    out.push({ id, shape: "rect", x: at.viewportX, y: at.viewportY, w: tile_px, h: tile_px,
      fill: (t.col + t.row) % 2 === 0 ? "#ffffff" : "#eaf3fc", role: "scenery" });
    out.push({ id: `${id}:label`, shape: "text", x: at.viewportX + tile_px / 2, y: at.viewportY + tile_px / 2, w: 0, h: 0,
      text: `(${t.col}, ${t.row})`, font: "20px monospace", fill: "#9ab", role: "scenery" });
  }
  const onScreen = (p) => viewportFromPark(viewport,
    nearest(p.parkX, viewport.parkX + viewport.width / 2), nearest(p.parkY, viewport.parkY + viewport.height / 2));
  const sprite = (id, critter, drawn, emoji, size, role) => {
    const at = onScreen(drawn);
    out.push({ id, shape: "glyph", x: at.viewportX, y: at.viewportY, w: size, h: size,
      text: emoji, fill: "#000", role });
    out.push({ id: `${id}:label`, shape: "text", x: at.viewportX, y: at.viewportY + size * 0.85, w: 0, h: 0,
      text: `(${Math.round(critter.parkX)}, ${Math.round(critter.parkY)})`, font: "11px monospace", fill: "#555", role: "scenery" });
  };
  for (const c of cows) sprite(`cow:${c.id}`, c, between(was.cows.get(c.id), c, alpha), cow_emoji, cow_px, "scenery");
  for (const d of dogs) {
    const drawn = between(was.dogs.get(d.id), d, alpha);
    if (leashed.kind !== "none" && leashed.dogId === d.id) {
      const at = onScreen(drawn);
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
  const w = o.window;
  const out = [{ id: "ground", shape: "rect", x: 0, y: 0, w: viewport.width, h: viewport.height, fill: ground, role: "scenery" }];
  for (const copy of tileCopiesMeeting(o.at.parkX, o.at.parkY, o.span.parkW, o.span.parkH)) {
    const { col, row } = wrapTile(copy);
    const odd = (col + row) % 2 === 1;
    const fill = subscribed.has(tileKey({ col, row }))
      ? (odd ? "#eaf3fc" : "#ffffff")
      : (odd ? "#f2c4c4" : "#f8d8d8");
    const corner = { viewportX: o.originX + copy.col * tile_px * o.scale, viewportY: o.originY + copy.row * tile_px * o.scale };
    out.push({ id: `tile:${col},${row}`, shape: "rect", x: corner.viewportX, y: corner.viewportY,
      w: tile_px * o.scale, h: tile_px * o.scale, fill, role: "scenery" });
  }
  const shown = (c) => {
    const x = nearest(c.parkX, o.at.parkX + o.span.parkW / 2);
    const y = nearest(c.parkY, o.at.parkY + o.span.parkH / 2);
    return x >= o.at.parkX && x <= o.at.parkX + o.span.parkW && y >= o.at.parkY && y <= o.at.parkY + o.span.parkH;
  };
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
    for (const th of overviewThumb(o, axis)) {
      out.push({ id: thumbTarget(axis), shape: "rect", x: th.x, y: th.y, w: th.w, h: th.h, fill: "#dde", role: "target" });
    }
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
