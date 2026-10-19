// The physics, as the page calls it: physics.wasm's exports (the server's
// own physics_page.zig, compiled to wasm32) behind plain JavaScript values.
// No protocol and no state of its own: the boards live in the wasm, and
// every line on the wire is written there (the page never formats a number
// it sends). engine.js keeps the record and the protocol.
//
// THE BOARDS, by number: LIVE (the one the page ticks and draws), KEPT (the
// board at the last tick the server kept) and SCRATCH (a tick tried before
// it is taken).
//
//   createPhysics(exports)
//     raw                          the exports themselves (tests, the console)
//     hash                         the physics hash, eight hex digits
//     ticksPerSecond()             the physics' clock: a tick every 1000 / this ms
//     reset()                      a page load: every board empty
//     copy(from, to)               board `to` becomes `from`, inputs begun and all
//     clearBegun(board)
//     leashed(board)               the leashed dog's number, or "none"
//     drag(board)                  "none" | "on" | { ended: tick }
//     region(board)                the tiles meeting the region, [{ col, row }]
//     human(board, h, t, dog)      h: "release" | "leash" | "grab" | "letgo";
//                                  applied and written: { text } or { refused }
//     tick(board, t, drag)         drag: [[dx, dy, ms], ...] in 256ths, as the
//                                  pointer made them; merged, capped and run:
//                                  { checked (text), drag (as capped), flags,
//                                    walk: ["KIND:ID"], the last walk's
//                                    critters in visit order }
//     tLine(t, plusMs, drag)       the `t` line, for a capped drag
//     header({ ms, count }, req, from, wall)   wall: a number, or "none"
//     loadLine(width, height)
//     viewLine(t, width, height, tiles), heldLine(t, tiles)
//     critters(board)              { dogs: [{ id, x, y }], cows: [...], ... }, in 256ths,
//                                  the critters the board has, a list for
//                                  each kind (its name + "s"), and poops
//     readTile(line, boards)       a `tile` line placed on those boards (a list):
//                                  its tile, { col, row }, or "malformed"
//     readBoard(line, board)       a `board T` line laid over the board: T or "malformed"
//     readState(line, board)       a `state` line's leash and drag set on the board:
//                                  { view: { width, height, tiles }, held }, or "malformed"
//     readInput(line)              an `input` line: { h, t, dog }, or "malformed"

import { kinds as world_kinds } from "./world.js";

export const LIVE = 0;
export const KEPT = 1;
export const SCRATCH = 2;

// physics_page.zig's Flag.
export const flag = { bump: 1, rest: 2, release: 4, moved: 8 };

const human_kinds = ["release", "leash", "grab", "letgo"];

export function createPhysics(x) {
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const bytes = (ptr, len) => new Uint8Array(x.memory.buffer, ptr, len);
  const ints = () => new Int32Array(x.memory.buffer, x.ints(), x.intsCap());
  // THE KINDS, by number, as the wasm counts them (its world, which
  // world.js names: test_page_modules.mjs holds the two together): each
  // one's name, how many, and where its critters begin among all.
  const kinds = Array.from({ length: x.kindCount() }, (_, k) => ({ name: world_kinds[k].name, base: x.kindBase(k), size: x.kindSize(k) }));
  const nameOf = (i) => {
    const k = kinds.find((k) => i >= k.base && i < k.base + k.size);
    return `${k.name}:${i - k.base}`;
  };
  // The last tick's walk: the critters it moved, in visit order, as
  // "KIND:ID" ("dog:3", "cow:0").
  const takeWalk = () => [...new Uint16Array(x.memory.buffer, x.walkAt(), x.walkLen())].map(nameOf);
  const text = (len) => decoder.decode(bytes(x.outBuf(), len));
  const putLine = (line) => {
    const b = encoder.encode(line);
    if (b.length > x.inCap()) return -1;
    bytes(x.inBuf(), b.length).set(b);
    return b.length;
  };
  const putTiles = (tiles) => {
    const a = ints();
    tiles.forEach((t, i) => { a[2 * i] = t.col; a[2 * i + 1] = t.row; });
    return tiles.length;
  };
  const putDrag = (drag) => {
    const a = ints();
    const room = Math.floor(a.length / 3);
    // Past the room, the rest are added into the last (the shared Zig adds
    // every one past 16 into the 16th, so the sum is the same).
    const list = drag.length <= room ? drag : [...drag.slice(0, room - 1), drag.slice(room - 1).reduce((s, d) => [s[0] + d[0], s[1] + d[1], d[2]])];
    list.forEach((d, i) => { a[3 * i] = d[0]; a[3 * i + 1] = d[1]; a[3 * i + 2] = d[2]; });
    return list.length;
  };
  const takeDrag = (n) => {
    const a = ints();
    const out = [];
    for (let i = 0; i < n; i++) out.push([a[3 * i], a[3 * i + 1], a[3 * i + 2]]);
    return out;
  };
  const tileList = (a, at, n) => {
    const out = [];
    for (let i = 0; i < n; i++) out.push({ col: a[at + 2 * i], row: a[at + 2 * i + 1] });
    return out;
  };
  const listOf = (positions, known, count) => {
    const p = new Int32Array(x.memory.buffer, positions, 2 * count);
    const k = new Uint8Array(x.memory.buffer, known, count);
    const out = [];
    for (let i = 0; i < count; i++) if (k[i] === 1) out.push({ id: i, x: p[2 * i], y: p[2 * i + 1] });
    return out;
  };

  return {
    // The wasm's exports themselves, for tests and the console.
    raw: x,
    hash: (x.physicsHash() >>> 0).toString(16).padStart(8, "0"),
    ticksPerSecond: () => x.ticksPerSecond(),
    reset: () => x.reset(),
    copy: (from, to) => x.copyBoard(from, to),
    clearBegun: (b) => x.clearBegun(b),
    leashed(b) {
      const d = x.leashedDog(b);
      return d < 0 ? "none" : d;
    },
    drag(b) {
      const d = x.dragOf(b);
      return d === -1 ? "none" : d === -2 ? "on" : { ended: d };
    },
    region(b) {
      const n = x.regionTiles(b);
      return tileList(ints(), 0, n);
    },
    human(b, h, t, dog = 0) {
      const kind = human_kinds.indexOf(h);
      if (kind < 0) throw new Error(`no human input ${h}`);
      const r = x.human(b, kind, t, dog);
      return r < 0 ? { refused: -1 - r } : { text: text(r) };
    },
    tick(b, t, drag) {
      const len = x.tick(b, t, putDrag(drag));
      return { checked: text(len), drag: takeDrag(x.cappedLen()), flags: x.tickFlags(), walk: takeWalk() };
    },
    tLine(t, plusMs, drag) { return text(x.writeT(t, plusMs, putDrag(drag))); },
    header(epoch, req, from, wall) { return text(x.writeHeader(epoch.ms, epoch.count, req, from, wall === "none" ? -1 : wall)); },
    loadLine: (w, h) => text(x.writeLoad(w, h)),
    viewLine(t, w, h, tiles) { return text(x.writeView(t, w, h, putTiles(tiles))); },
    heldLine(t, tiles) { return text(x.writeHeld(t, putTiles(tiles))); },
    critters(b) {
      const out = { poops: listOf(x.poopsAt(b), x.poopKnown(b), x.poopCount()) };
      for (const k of kinds) out[`${k.name}s`] = listOf(x.crittersAt(b) + 8 * k.base, x.crittersKnown(b) + k.base, k.size);
      return out;
    },
    readTile(line, boards) {
      const n = putLine(line);
      const mask = boards.reduce((m, b) => m | (1 << b), 0);
      if (n < 0 || x.readTile(n, mask) < 0) return "malformed";
      const a = ints();
      return { col: a[0], row: a[1] };
    },
    readBoard(line, b) {
      const n = putLine(line);
      if (n < 0 || x.readBoard(n, b) < 0) return "malformed";
      return x.lineTick();
    },
    readState(line, b) {
      const n = putLine(line);
      if (n < 0 || x.readState(n, b) < 0) return "malformed";
      const a = ints();
      const nv = a[2];
      const nh = a[3 + 2 * nv];
      return { view: { width: a[0], height: a[1], tiles: tileList(a, 3, nv) }, held: tileList(a, 4 + 2 * nv, nh) };
    },
    readInput(line) {
      const n = putLine(line);
      const kind = n < 0 ? -1 : x.readInput(n);
      if (kind < 0) return "malformed";
      return { h: human_kinds[kind], t: x.lineTick(), dog: ints()[0] };
    },
  };
}

// The wasm's exports, from its bytes (node) or a response (the page).
export async function instantiatePhysics(source) {
  const { instance } = source instanceof Response
    ? await WebAssembly.instantiateStreaming(source)
    : await WebAssembly.instantiate(source);
  return createPhysics(instance.exports);
}
