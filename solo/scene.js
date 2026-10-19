// The park's geometry and what a frame draws: its sizes, the two frames
// (park and viewport points), the tiles and the world, the overview's
// frame, and the scene builders, the lists blit.js draws. All pure.
//
// TWO FRAMES, both in CSS pixels: a PARK point (parkX, parkY) is where a
// dog stands in the world; a VIEWPORT point (viewportX, viewportY) is where
// it is on the screen, from the screen's top-left. The viewport's own
// top-left is a park point; north is smaller parkY.

// The critters' squares and a poop's, in CSS pixels, the breeds, and the
// kinds of critter: world.js's, which roc/world.roc prints, as it prints
// the physics' world.
import { dog_px, cow_px, chicken_px, poop_px, breeds, kinds } from "./world.js";
export { dog_px, cow_px, chicken_px, poop_px, breeds, kinds };
export const cow_emoji = "🐄";
// The kinds the page draws with art (and plays with by name); any other
// kind World.roc says is drawn as its square (`critterShape`).
export const drawn_kinds = ["dog", "cow", "chicken"];
// Full-bodied.
export const chicken_emoji = "🐓";
// A dog's poop: a little brown circle, under every critter.
export const poop_fill = "#7a4a1a";
// The breeds: dog n has look n mod `breeds`, one look each.
export const dog_looks = ["🐕", "🐩", "🦮", "🐕‍🦺"];
if (dog_looks.length !== breeds) throw new Error("a look for each breed: as many dog_looks as world.js's breeds");

// ── frames ──────────────────────────────────────────────────────────────────

export function viewportFromPark(viewport, parkX, parkY) {
  return { viewportX: parkX - viewport.parkX, viewportY: parkY - viewport.parkY };
}

export function parkFromViewport(viewport, viewportX, viewportY) {
  return { parkX: viewport.parkX + viewportX, parkY: viewport.parkY + viewportY };
}


// ── tiles and the world ─────────────────────────────────────────────────────

// The world: `world_tiles` by `world_tiles` tiles of `tile_px`, a torus
// (docs/PHYSICS.md decision 14): its right edge meets its left, its bottom
// its top. The populated park is the `park_tiles` by `park_tiles` tiles in
// its middle, a cow in each white tile, a ring of empty tiles round it
// (Steve, 2026-10-15). These are world.js's, which roc/world.roc prints, as
// it prints the physics' world. A page subscribes to at most `most_tiles`
// (the server refuses more): the whole world fits.
import { tile_px, world_tiles, park_tiles, cow_count } from "./world.js";
export { tile_px, world_tiles, park_tiles, cow_count };
export const most_tiles = 64;
if (world_tiles * world_tiles > most_tiles) throw new Error("the page holds the whole world: it must fit in a view");
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

// **WHAT THE PAGE SUBSCRIBES** (decision 13): every tile of the world,
// always (Steve, 2026-10-15: "at this scale we would almost be sending the
// whole world down"), so the page knows every critter whether or not a dog
// is leashed, and the goal's count is the park's, never what one screen
// shows. The region (the world) is among them, so the physics never waits.
export function subscription() {
  const out = [];
  for (let row = 0; row < world_tiles; row++) for (let col = 0; col < world_tiles; col++) out.push({ col, row });
  return out;
}

// ── the overview's frame ────────────────────────────────────────────────────

// **THE OVERVIEW IS THE WHOLE WORLD, ONCE**: a square window, as large as
// fits `overview_margin_px` in from the screen's edges, holding exactly
// `world_tiles` tiles each way (Steve, 2026-10-15: "my world view at any
// point should be 6 rows; it could be 561234"). Its top-left, `at`, is a
// park point in [0, world_px): the window scrolls round the torus, so the
// rows and columns it shows start wherever it is, and it shows whatever
// copy of a thing is in it. A park point in the
// window's copy of the world (parkX, parkY) is at origin + park * scale on
// screen. Two scrollbars in the margins, along the bottom and the right,
// say where the window is in the world: a track the window's length, and a
// thumb on it as long, and as far along, as the window is in the world;
// the thumb wraps too, its part past the track's end drawn from its start.
export const overview_margin_px = 20;
export const overview_tiles = world_tiles;
const scrollbar_px = 12;

export function overviewFrame(width, height, at) {
  const m = overview_margin_px;
  const side = Math.max(0, Math.min(width, height) - 2 * m);
  const scale = side / (overview_tiles * tile_px);
  const window = { x: (width - side) / 2, y: (height - side) / 2, w: side, h: side };
  const span = { parkW: window.w / scale, parkH: window.h / scale };
  const kept = overviewKept(span, at);
  const across = (m - scrollbar_px) / 2;
  return {
    scale,
    originX: window.x - kept.parkX * scale,
    originY: window.y - kept.parkY * scale,
    at: kept,
    window,
    span,
    tracks: {
      x: { x: window.x, y: window.y + window.h + across, w: window.w, h: scrollbar_px },
      y: { x: window.x + window.w + across, y: window.y, w: scrollbar_px, h: window.h },
    },
  };
}

// The window's top-left named in the world: it shows the world once,
// from wherever round the torus it starts.
function overviewKept(_span, at) {
  return { parkX: wrapped(at.parkX), parkY: wrapped(at.parkY) };
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
  // A window that is the whole world shows every view: it stays.
  if (o.span.parkW >= world_px && o.span.parkH >= world_px) return o.at;
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
export const still = { alpha: 1, was: { viewport: undefined, dogs: new Map(), cows: new Map(), chickens: new Map() } };

// The park near: the tiles on screen (each a square of its shade, its name
// in its middle), then each poop (a brown dot), each chicken, each cow,
// then each dog, each with its place under
// it (where it is, not where it is drawn), the leashed dog ringed (green while the drag is on, red once it has
// ended: a bump turns it red). `dogs`
// and `cows` in the order they are drawn; `motion` = { alpha, was } (the
// engine's view: was.viewport a park point, was.dogs, was.cows and
// was.chickens Maps of
// them by id), each drawn `between` there and here, the leashed dog too.
// Across the seam, each thing is drawn at its copy nearest the viewport's
// centre, and each tile's copy on screen. `more.labels` ("hidden", or
// "shown" in the page's debugging mode, "d") says whether a dog's number and
// the critters' places in the last walk are drawn; a tile's coordinates are
// always shown.
//
// A critter as drawn, centred on `at`: its art, `emoji`, where the page has
// some; else a square of its kind's colour, the kind's `px` across (roc/
// World.roc's `kinds`: a kind made there is drawn before it has art).
export function critterShape(id, at, look, emoji, role) {
  if (emoji !== undefined) return { id, shape: "glyph", x: at.viewportX, y: at.viewportY, w: look.px, h: look.px, text: emoji, fill: "#000", role };
  return { id, shape: "rect", x: at.viewportX - look.px / 2, y: at.viewportY - look.px / 2, w: look.px, h: look.px, fill: look.colour, role };
}

export function nearScene(viewportNow, dogs, cows, leashed, motion = still, visits = new Map(), more = { chickens: [], poops: [], others: [], labels: "hidden" }) {
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
  // In debugging mode only, a dog's label: its number, and its place in the
  // last walk (1 to 30) when it had one. A cow's: only its place in the walk.
  const shown = more.labels === "shown";
  const sprite = (id, critter, drawn, emoji, size, role, label = "none") => {
    const at = onScreen(drawn);
    out.push(critterShape(id, at, { px: size }, emoji, role));
    if (label !== "none" && label !== "") out.push({ id: `${id}:label`, shape: "text", x: at.viewportX, y: at.viewportY + size * 0.85, w: 0, h: 0,
      text: label, font: "12px monospace", fill: "#333", role: "scenery" });
  };
  for (const p of more.poops) {
    const at = onScreen(p);
    out.push({ id: `poop:${p.id}`, shape: "dot", x: at.viewportX, y: at.viewportY, w: poop_px, h: poop_px, fill: poop_fill, role: "scenery" });
  }
  // A kind with no art: its square, in its colour (World.roc's `kinds`).
  for (const o of more.others ?? []) {
    const look = kinds.find((k) => k.name === o.kind);
    out.push(critterShape(`${o.kind}:${o.id}`, onScreen(o), look, undefined, "scenery"));
  }
  for (const c of more.chickens) {
    sprite(`chicken:${c.id}`, c, between(was.chickens.get(c.id), c, alpha), chicken_emoji, chicken_px, "scenery");
  }
  for (const c of cows) {
    const visit = visits.get(`cow:${c.id}`);
    sprite(`cow:${c.id}`, c, between(was.cows.get(c.id), c, alpha), cow_emoji, cow_px, "scenery", !shown || visit === undefined ? "none" : `#${visit}`);
  }
  for (const d of dogs) {
    const drawn = between(was.dogs.get(d.id), d, alpha);
    if (leashed.kind !== "none" && leashed.dogId === d.id) {
      const at = onScreen(drawn);
      out.push({ id: `${dogTarget(d.id)}:ring`, shape: "ring", x: at.viewportX, y: at.viewportY, w: 2 * (dog_px * 0.7), h: 2 * (dog_px * 0.7),
        stroke: leashed.kind === "in_hand" ? "#2a2" : "#d33", lineWidth: 3, role: "scenery" });
    }
    const visit = visits.get(`dog:${d.id}`);
    sprite(dogTarget(d.id), d, drawn, d.emoji, dog_px, "target", !shown ? "none" : visit === undefined ? `${d.id}` : `${d.id} #${visit}`);
  }
  return out;
}

// The overview: a window onto the world (overviewFrame, its top-left `at`),
// each tile in it a square (white and blue where subscribed, pink where
// not), each cow a brown dot, each chicken a red speck and each dog a
// smaller dark dot (pale where its
// tile is not subscribed: only remembered), the dog leashed last ringed;
// the margins over what spills past the window; the view a rectangle; and
// the two scrollbars.
export function overviewScene(viewport, dogs, cows, subscribed, lastLeashed, at, chickens = []) {
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
  for (const c of chickens) {
    if (!shown(c)) continue;
    const p = overviewFromPark(o, c.parkX, c.parkY);
    out.push({ id: `chicken:${c.id}`, shape: "dot", x: p.viewportX, y: p.viewportY, w: 4, h: 4,
      fill: live(c) ? "#c8102e" : "#e9a0a8", role: "scenery" });
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

// ── the goal ────────────────────────────────────────────────────────────────

// **THE HERD** (Steve, 2026-10-15: "the object of the game will be to get
// all 8 cows herded together"): two cows are in one herd when their
// centres are at most `herd_link_px` apart on the larger axis, round the
// torus (two cow-widths: a cow's gap between them); a herd is every cow
// linked to it, through others. The largest herd's size is the score.
export const herd_link_px = 2 * cow_px;

export function largestHerd(cows) {
  const n = cows.length;
  const parent = cows.map((_, i) => i);
  const root = (i) => (parent[i] === i ? i : (parent[i] = root(parent[i])));
  for (let i = 0; i < n; i++) {
    for (let j = i + 1; j < n; j++) {
      const dx = Math.abs(offset(cows[i].parkX, cows[j].parkX));
      const dy = Math.abs(offset(cows[i].parkY, cows[j].parkY));
      if (Math.max(dx, dy) <= herd_link_px) parent[root(i)] = root(j);
    }
  }
  const sizes = new Map();
  for (let i = 0; i < n; i++) sizes.set(root(i), (sizes.get(root(i)) ?? 0) + 1);
  return Math.max(0, ...sizes.values());
}
