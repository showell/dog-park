// **TOUGH LOVE** (Steve, 2026-10-15): cows, chickens and goats can't be dragged
// (only dogs move them), and a press on one says so, with a joke, so the
// player learns it once. A press on empty ground still drags the
// tablecloth (pans the view); a press on a dog leashes it, as ever. And a
// drag that pulls the leashed dog into another critter (or a poop it can't
// get round) ends in a bump, which gets its own line, by what it hit.
// Pure: park.js shows the line.

import { parkFromViewport, offset, cow_px, chicken_px, kinds } from "./scene.js";
import { press_lines, any_line, bump_lines, any_bump, persistent, persistence } from "./words.js";
import { chicken_slop_px } from "./look.js";

// The critter under a press at viewport point (x, y): "cow", "chicken",
// another kind's name (`others`, the kinds World.roc says that the page
// plays with by `kinds` alone: the goats), or null. Dogs are the page's
// own hit test, and come first.
export function pressedCritter(viewport, x, y, cows, chickens, others = []) {
  const at = parkFromViewport(viewport, x, y);
  const within = (c, half) => Math.abs(offset(c.parkX, at.parkX)) <= half && Math.abs(offset(c.parkY, at.parkY)) <= half;
  if (cows.some((c) => within(c, cow_px / 2))) return "cow";
  if (chickens.some((c) => within(c, chicken_px / 2 + chicken_slop_px))) return "chicken";
  const other = others.find((o) => within(o, kinds.find((k) => k.name === o.kind).px / 2));
  return other === undefined ? null : other.kind;
}

// The lines, the bump lines and the park's remarks are roc/Words.roc's,
// printed into words.js (`zig build roc`); the game on roc-ray says the same.
const lines = press_lines;
const fill = (template, kind) => template.replace("{kind}", kind);

// A kind with no lines of its own (one World.roc has, the page not yet).
const anyLine = (kind) => fill(any_line, kind);
const anyBump = (kind) => fill(any_bump, kind);

// What a tick's bump hit, from its checked lines ("bump <tick> <kind> ..."):
// a kind's name ("dog", "goat", ...) or "poop", or null when it didn't bump.
export function bumpedKind(checked) {
  const m = /^bump \d+ ([a-z]+)\b/m.exec(checked);
  return m === null ? null : m[1];
}

const bumpLines = bump_lines;

// The next line for a bump on a `kind`, never the one just said: each
// kind's lines in turn from a random start. No persistence remark: bumping
// is part of herding, never a lesson refused.
export function bumper(random = Math.random) {
  const next = Object.fromEntries(Object.entries(bumpLines).map(([k, ls]) => [k, Math.floor(random() * ls.length)]));
  return {
    say(kind) {
      const ls = bumpLines[kind];
      if (ls === undefined) return anyBump(kind);
      return ls[next[kind]++ % ls.length];
    },
  };
}

// The next line for a press on a `kind`, never the one just said: each
// kind's lines in turn from a random start, and, past `persistent` tries
// in a row with no dog grabbed between, the park's remarks on that.
// `random` is Math.random's shape, for tests.
export function quipper(random = Math.random) {
  const next = Object.fromEntries(Object.entries(lines).map(([k, ls]) => [k, Math.floor(random() * ls.length)]));
  let tries = 0;
  let remark = 0;
  return {
    say(kind) {
      tries++;
      if (tries > persistent) return persistence[remark++ % persistence.length];
      if (lines[kind] === undefined) return anyLine(kind);
      const line = lines[kind][next[kind] % lines[kind].length];
      next[kind]++;
      return line;
    },
    // A dog grabbed: the lesson took.
    forgive() {
      tries = 0;
    },
  };
}
