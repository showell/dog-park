// Dog Park, played: one human, the server keeping the dogs.
//
// THE PARK IS A CHECKERBOARD of 800 px tiles, each named by its column and
// row, 10 by 10 of them: the world, which no dog leaves. The page
// subscribes to the tiles around its viewport (at most 25; the page chooses
// which), and the server keeps it told about the dogs in them. Each time
// the tiles it wants change, it sends the whole set, each tile marked new
// or held; the server replaces its set and answers with the dogs in the
// tiles marked new. **A SUBSCRIPTION ONLY SAYS WHAT THE SERVER KEEPS YOU
// TOLD OF**: the page remembers every dog it has seen, where it last saw
// it, subscribed or not.
//
// Any dog you see can be picked up. Pressing a dog leashes it (the server is
// told, and acks); dragging it sends where it is, never more than one
// position waiting for its ack. The leash is let go when you press another
// dog, or 5 s after you let go of the dog. Holding a dog near any edge of
// the screen scrolls the viewport that way, the dog going with it.
// Dragging anywhere else pans the park, like a tablecloth. The server keeps
// your viewport and your leash, so a reload shows the same place.
//
// "z" toggles the OVERVIEW: the whole world on the screen, the tiles you
// know white and blue and the rest red, the dogs you know as dots (the dog
// you leashed last ringed), and your view as a rectangle you can drag.
//
// The dev console says what the server acks: tiles, leashes, releases,
// moves.
//
// TWO FRAMES, both in CSS pixels: a PARK point (parkX, parkY) is where a
// dog stands in the world; a VIEWPORT point (viewportX, viewportY) is where
// it is on the screen, from the screen's top-left. The viewport's own
// top-left is a park point; north is smaller parkY.
"use strict";

const dog_px = 40;

// ── frames ──────────────────────────────────────────────────────────────────

function viewportFromPark(viewport, parkX, parkY) {
  return { viewportX: parkX - viewport.parkX, viewportY: parkY - viewport.parkY };
}

function parkFromViewport(viewport, viewportX, viewportY) {
  return { parkX: viewport.parkX + viewportX, parkY: viewport.parkY + viewportY };
}


// A park point kept on screen, a dog's half-size in from each edge: a held
// dog never leaves the screen.
function keptOnScreen(viewport, parkX, parkY) {
  const half = dog_px / 2;
  return {
    parkX: Math.min(Math.max(parkX, viewport.parkX + half), viewport.parkX + viewport.width - half),
    parkY: Math.min(Math.max(parkY, viewport.parkY + half), viewport.parkY + viewport.height - half),
  };
}

// ── tiles and the world ─────────────────────────────────────────────────────

const tile_px = 800;
const most_tiles = 25;
const world_tiles = 10;
const world_px = world_tiles * tile_px;

// A park point kept in the world.
function keptInWorld(parkX, parkY) {
  return {
    parkX: Math.min(Math.max(parkX, 0), world_px - 1),
    parkY: Math.min(Math.max(parkY, 0), world_px - 1),
  };
}

// A viewport's top-left kept so its centre is in the world: a pan stops at
// the world's edge.
function viewportKeptOnWorld(viewport, parkX, parkY) {
  const centre = keptInWorld(parkX + viewport.width / 2, parkY + viewport.height / 2);
  return { parkX: centre.parkX - viewport.width / 2, parkY: centre.parkY - viewport.height / 2 };
}

function inWorld(t) {
  return t.col >= 0 && t.row >= 0 && t.col < world_tiles && t.row < world_tiles;
}
// How far past the viewport's edges the page subscribes, so a scroll finds
// its dogs already known.
const tile_margin_px = tile_px / 2;

function tileOf(parkX, parkY) {
  return { col: Math.floor(parkX / tile_px), row: Math.floor(parkY / tile_px) };
}

function tileKey(t) { return `${t.col},${t.row}`; }

// Every tile of the world meeting the park rectangle from (parkX, parkY),
// `width` by `height`.
function tilesMeeting(parkX, parkY, width, height) {
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

// The tiles the page wants: those within `tile_margin_px` of the viewport,
// or, on a screen too big for that, those it shows.
function wantedTiles(viewport) {
  const m = tile_margin_px;
  const near = tilesMeeting(viewport.parkX - m, viewport.parkY - m, viewport.width + 2 * m, viewport.height + 2 * m);
  if (near.length <= most_tiles) return near;
  const shown = tilesMeeting(viewport.parkX, viewport.parkY, viewport.width, viewport.height);
  if (shown.length <= most_tiles) return shown;
  console.error(`a screen this big shows ${shown.length} tiles, past the ${most_tiles} a page may subscribe`);
  return shown.slice(0, most_tiles);
}

// ── drag ────────────────────────────────────────────────────────────────────

// The dog under the pointer, the one drawn last (on top) first, and where
// the pointer grabbed it relative to its centre, so it doesn't jump.
function grabbed(viewport, dogs, pointerViewportX, pointerViewportY) {
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
const band_px = 80;
const slowest_px_per_frame = (2 / 3) * 0.7;
const fastest_px_per_frame = (16 / 3) * 0.7;

function bandSpeed(depthPx) {
  const depth = depthPx / band_px; // 0 at the band's inner edge, 1 at the screen's edge
  if (depth <= 0) return 0;
  return slowest_px_per_frame + Math.min(depth, 1) * (fastest_px_per_frame - slowest_px_per_frame);
}

// How far the viewport moves this frame along one axis, toward the far
// edge (negative: toward the near one), for a dog held at `dogViewportAt`
// on a screen `length` long that way: 0 outside both bands.
function axisScroll(dogViewportAt, length) {
  const half = dog_px / 2;
  const near = bandSpeed(half + band_px - dogViewportAt);
  const far = bandSpeed(dogViewportAt - (length - half - band_px));
  return far - near;
}

// ── the server ──────────────────────────────────────────────────────────────

async function post(path, body) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${path}: ${response.status} ${await response.text()}`);
  return response.json();
}

async function fetchMe() {
  const response = await fetch("/me");
  if (!response.ok) throw new Error(`/me: ${response.status}`);
  return response.json();
}

// ── what the page knows ─────────────────────────────────────────────────────

// Every dog the page has seen, by id, where it last saw it: live in a tile
// subscribed, remembered (perhaps stale) in one that is not.
const known = new Map();
// The tiles the server has acked as subscribed, by key.
let subscribed = new Map();

// ── the leash ───────────────────────────────────────────────────────────────

// How long a dog stays on your leash after you let go of it.
const leash_kept_ms = 5000;

// The dog on your leash, by id: none, or one held in your hand, or one let
// go of and kept on the leash until a timer lets it go.
let leashed = { kind: "none" };
// The dog you leashed last, by id, for the overview: none yet, or one.
let lastLeashed = { kind: "none" };

// A leash is asked for and the dog moved at once (optimistic); the ack is
// only said, for now.
function leashTo(dogId) {
  if (leashed.kind !== "none" && leashed.dogId !== dogId) releaseLeash();
  if (leashed.kind === "kept") clearTimeout(leashed.timer);
  const already = leashed.kind !== "none" && leashed.dogId === dogId;
  leashed = { kind: "in_hand", dogId };
  lastLeashed = { kind: "dog", dogId };
  if (already) return;
  post("/leash", { dog: dogId }).then(
    (ack) => console.log("leashed", ack),
    (e) => console.error("leash failed:", e.message),
  );
}

// Let go of the dog in your hand: it stays on the leash `leash_kept_ms`.
function keepOnLeash() {
  if (leashed.kind !== "in_hand") return;
  leashed = { kind: "kept", dogId: leashed.dogId, timer: setTimeout(releaseLeash, leash_kept_ms) };
}

function releaseLeash() {
  if (leashed.kind === "none") return;
  if (leashed.kind === "kept") clearTimeout(leashed.timer);
  const dogId = leashed.dogId;
  leashed = { kind: "none" };
  post("/release", { dog: dogId }).then(
    (ack) => console.log("released", ack),
    (e) => console.error("release failed:", e.message),
  );
}

// ── sends: at most one waiting each, the latest sent when it is acked ───────

const moves = { waiting: "none", due: new Set() }; // waiting: "none" or a dog

function sendMove(dog) {
  if (moves.waiting !== "none") { moves.due.add(dog); return; }
  moves.waiting = dog;
  const parkX = Math.round(dog.parkX);
  const parkY = Math.round(dog.parkY);
  const sentMs = performance.now();
  post("/move", { dog: dog.id, park_x: parkX, park_y: parkY }).then(
    (ack) => console.log(`moved ${ack.moved} to (${ack.park_x}, ${ack.park_y}) in ${Math.round(performance.now() - sentMs)} ms`),
    (e) => console.error("move failed:", e.message),
  ).finally(() => {
    moves.waiting = "none";
    const [next] = moves.due;
    if (next !== undefined) {
      moves.due.delete(next);
      sendMove(next);
    }
  });
}

const viewportSends = { waiting: false, due: false };

function sendViewport(viewport) {
  if (viewportSends.waiting) { viewportSends.due = true; return; }
  viewportSends.waiting = true;
  post("/viewport", { park_x: Math.round(viewport.parkX), park_y: Math.round(viewport.parkY) }).then(
    () => {},
    (e) => console.error("viewport failed:", e.message),
  ).finally(() => {
    viewportSends.waiting = false;
    if (viewportSends.due) {
      viewportSends.due = false;
      sendViewport(viewport);
    }
  });
}

// The tiles: when none is waiting and the tiles wanted differ from those
// subscribed, the whole set wanted is sent, each tile marked new (its dogs
// wanted) or held (its dogs known). The answer is the truth for each new
// tile: the dogs remembered there are dropped (one may have wandered off),
// but for one on your leash or in your hand, and the answer's dogs taken.
// A dog in a tile left out is remembered where it was.
const tileSends = { waiting: false };

function syncTiles(viewport, inHand) {
  if (tileSends.waiting) return;
  const wanted = new Map(wantedTiles(viewport).map((t) => [tileKey(t), t]));
  const added = [...wanted.keys()].filter((k) => !subscribed.has(k)).length;
  const dropped = [...subscribed.keys()].filter((k) => !wanted.has(k)).length;
  if (added === 0 && dropped === 0) return;
  tileSends.waiting = true;
  const named = [...wanted].map(([k, t]) => ({ col: t.col, row: t.row, is: subscribed.has(k) ? "held" : "new" }));
  post("/tiles", { tiles: named }).then(
    (ack) => {
      subscribed = wanted;
      const fresh = new Set(named.filter((t) => t.is === "new").map(tileKey));
      let replaced = 0;
      for (const [id, d] of known) {
        const kept = (leashed.kind !== "none" && leashed.dogId === id) || inHand() === d;
        if (!kept && fresh.has(tileKey(tileOf(d.parkX, d.parkY)))) { known.delete(id); replaced++; }
      }
      for (const d of ack.dogs) known.set(d.id, { id: d.id, emoji: d.emoji, parkX: d.park_x, parkY: d.park_y });
      console.log(`tiles: ${added} new, ${dropped} dropped, ${ack.subscribed} subscribed; ${ack.dogs.length} dogs arrived for ${replaced} remembered, ${known.size} known`);
    },
    (e) => console.error("tiles failed:", e.message),
  ).finally(() => { tileSends.waiting = false; });
}

// ── the blitter: owns no logic ──────────────────────────────────────────────

// Draws the ground (each tile a square of its shade, its label in its
// middle), then each dog at its viewport point with its label under it; a
// leashed dog ringed.
function blit(canvas, width, height, ground, sprites) {
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
    ctx.font = `${dog_px}px serif`;
    ctx.fillStyle = "#000";
    ctx.fillText(s.emoji, s.viewportX, s.viewportY);
    ctx.font = "11px monospace";
    ctx.fillStyle = "#555";
    ctx.fillText(s.label, s.viewportX, s.viewportY + dog_px * 0.85);
  }
}

// The overview: each tile a square of its shade, each dog a dot (dark when
// live, pale when remembered), a ringed dog with a ring, and the view a
// rectangle. All in viewport points.
function blitOverview(canvas, width, height, squares, dots, view) {
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
    ctx.arc(d.viewportX, d.viewportY, 2.5, 0, 2 * Math.PI);
    ctx.fillStyle = d.freshness === "live" ? "#333" : "#a88";
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

// ── the overview's frame ────────────────────────────────────────────────────

// The whole world fits the screen, `overview_margin_px` in from its edges:
// a park point at (parkX, parkY) is at origin + park * scale on screen.
const overview_margin_px = 20;

function overviewFrame(width, height) {
  const scale = Math.min(width - 2 * overview_margin_px, height - 2 * overview_margin_px) / world_px;
  return {
    scale,
    originX: (width - world_px * scale) / 2,
    originY: (height - world_px * scale) / 2,
  };
}

function overviewFromPark(o, parkX, parkY) {
  return { viewportX: o.originX + parkX * o.scale, viewportY: o.originY + parkY * o.scale };
}

// ── the page ────────────────────────────────────────────────────────────────

async function start() {
  const canvas = document.getElementById("park");
  const me = await fetchMe();
  const viewport = { parkX: 0, parkY: 0, width: 0, height: 0 };
  // Near (the park at its size) or the overview (the whole world).
  let mode = "near";
  // What the human's hand is doing: holding a dog, panning the park (from
  // the pointer's last viewport point), or resting.
  let hold = { kind: "resting" };
  const inHand = () => (hold.kind === "holding" ? hold.dog : "none");
  // The pointer's last viewport point while holding: a still pointer in
  // the band keeps scrolling.
  const pointer = { viewportX: 0, viewportY: 0 };

  function fit() {
    const ratio = window.devicePixelRatio || 1;
    viewport.width = canvas.clientWidth;
    viewport.height = canvas.clientHeight;
    canvas.width = Math.floor(viewport.width * ratio);
    canvas.height = Math.floor(viewport.height * ratio);
  }
  fit();
  if (me.viewport.at) {
    Object.assign(viewport, viewportKeptOnWorld(viewport, me.viewport.at.park_x, me.viewport.at.park_y));
  } else {
    // A first visit starts at the world's centre.
    viewport.parkX = Math.round(world_px / 2 - viewport.width / 2);
    viewport.parkY = Math.round(world_px / 2 - viewport.height / 2);
    sendViewport(viewport);
  }
  // A dog still on your leash from before the reload: kept on it the usual
  // time from now, then let go.
  if (me.leash.dog !== undefined) {
    leashed = { kind: "kept", dogId: me.leash.dog, timer: setTimeout(releaseLeash, leash_kept_ms) };
  }
  window.addEventListener("resize", fit);
  window.addEventListener("keydown", (e) => {
    if (e.key !== "z") return;
    if (hold.kind === "holding") keepOnLeash();
    hold = { kind: "resting" };
    mode = mode === "near" ? "overview" : "near";
  });

  // The held dog under the pointer, as far as the screen allows.
  function follow() {
    const want = parkFromViewport(viewport, pointer.viewportX - hold.grabDx, pointer.viewportY - hold.grabDy);
    const onScreen = keptOnScreen(viewport, want.parkX, want.parkY);
    Object.assign(hold.dog, keptInWorld(onScreen.parkX, onScreen.parkY));
    sendMove(hold.dog);
  }

  canvas.addEventListener("pointerdown", (e) => {
    canvas.setPointerCapture(e.pointerId);
    if (mode === "overview") {
      hold = { kind: "panning", lastViewportX: e.offsetX, lastViewportY: e.offsetY };
      return;
    }
    const g = grabbed(viewport, [...known.values()], e.offsetX, e.offsetY);
    if (g.kind === "holding") {
      hold = g;
      leashTo(g.dog.id);
    } else {
      hold = { kind: "panning", lastViewportX: e.offsetX, lastViewportY: e.offsetY };
    }
    pointer.viewportX = e.offsetX;
    pointer.viewportY = e.offsetY;
    canvas.setPointerCapture(e.pointerId);
  });
  canvas.addEventListener("pointermove", (e) => {
    if (hold.kind === "panning") {
      // Near, the park moves with the pointer, so the viewport moves
      // against it; in the overview, the view's rectangle moves with it.
      const dx = e.offsetX - hold.lastViewportX;
      const dy = e.offsetY - hold.lastViewportY;
      const o = overviewFrame(viewport.width, viewport.height);
      const want = mode === "near"
        ? { parkX: viewport.parkX - dx, parkY: viewport.parkY - dy }
        : { parkX: viewport.parkX + dx / o.scale, parkY: viewport.parkY + dy / o.scale };
      Object.assign(viewport, viewportKeptOnWorld(viewport, want.parkX, want.parkY));
      sendViewport(viewport);
      hold.lastViewportX = e.offsetX;
      hold.lastViewportY = e.offsetY;
      return;
    }
    if (hold.kind !== "holding") return;
    pointer.viewportX = e.offsetX;
    pointer.viewportY = e.offsetY;
    follow();
  });
  const letGo = () => {
    if (hold.kind === "holding") keepOnLeash();
    hold = { kind: "resting" };
  };
  canvas.addEventListener("pointerup", letGo);
  canvas.addEventListener("pointercancel", letGo);

  const frame = () => {
    syncTiles(viewport, inHand);
    if (mode === "overview") {
      drawOverview();
      requestAnimationFrame(frame);
      return;
    }
    if (hold.kind === "holding") {
      const dog = hold.dog;
      const at = viewportFromPark(viewport, dog.parkX, dog.parkY);
      const eastward = axisScroll(at.viewportX, viewport.width);
      const southward = axisScroll(at.viewportY, viewport.height);
      // The viewport and the dog move together: the dog stays put on screen
      // while it travels through the park.
      // The dog stops at the world's edge, and the scroll with it.
      const to = keptInWorld(dog.parkX + eastward, dog.parkY + southward);
      const movedX = to.parkX - dog.parkX;
      const movedY = to.parkY - dog.parkY;
      if (movedX !== 0 || movedY !== 0) {
        viewport.parkX += movedX;
        viewport.parkY += movedY;
        dog.parkX = to.parkX;
        dog.parkY = to.parkY;
        sendMove(dog);
        sendViewport(viewport);
      }
    }
    const ground = tilesMeeting(viewport.parkX, viewport.parkY, viewport.width, viewport.height).map((t) => ({
      shade: (t.col + t.row) % 2 === 0 ? "#ffffff" : "#eaf3fc",
      size: tile_px,
      label: `(${t.col}, ${t.row})`,
      ...viewportFromPark(viewport, t.col * tile_px, t.row * tile_px),
    }));
    const sprites = [...known.values()].map((d) => ({
      kind: leashed.kind !== "none" && leashed.dogId === d.id ? "leashed" : "free",
      emoji: d.emoji,
      label: `(${Math.round(d.parkX)}, ${Math.round(d.parkY)})`,
      ...viewportFromPark(viewport, d.parkX, d.parkY),
    }));
    blit(canvas, viewport.width, viewport.height, ground, sprites);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);

  function drawOverview() {
    const o = overviewFrame(viewport.width, viewport.height);
    const squares = [];
    for (let row = 0; row < world_tiles; row++) {
      for (let col = 0; col < world_tiles; col++) {
        const odd = (col + row) % 2 === 1;
        const shade = subscribed.has(tileKey({ col, row }))
          ? (odd ? "#eaf3fc" : "#ffffff")
          : (odd ? "#f2c4c4" : "#f8d8d8");
        squares.push({ shade, size: tile_px * o.scale, ...overviewFromPark(o, col * tile_px, row * tile_px) });
      }
    }
    const dots = [...known.values()].map((d) => ({
      kind: lastLeashed.kind === "dog" && lastLeashed.dogId === d.id ? "ringed" : "plain",
      freshness: subscribed.has(tileKey(tileOf(d.parkX, d.parkY))) ? "live" : "remembered",
      ...overviewFromPark(o, d.parkX, d.parkY),
    }));
    const corner = overviewFromPark(o, viewport.parkX, viewport.parkY);
    const view = { ...corner, width: viewport.width * o.scale, height: viewport.height * o.scale };
    blitOverview(canvas, viewport.width, viewport.height, squares, dots, view);
  }
}

start().catch((e) => console.error("Dog Park did not start:", e.message));
