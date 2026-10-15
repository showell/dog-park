// **TOUGH LOVE** (Steve, 2026-10-15): cows and chickens can't be dragged
// (only dogs move them), and a press on one says so, with a joke, so the
// player learns it once. A press on empty ground still drags the
// tablecloth (pans the view); a press on a dog leashes it, as ever. Pure:
// park.js shows the line.

import { parkFromViewport, offset, cow_px, chicken_px } from "./scene.js";

// A chicken is small: a press this near its square still counts.
const chicken_slop_px = 4;

// The critter under a press at viewport point (x, y): "cow", "chicken", or
// null. Dogs are the page's own hit test, and come first.
export function pressedCritter(viewport, x, y, cows, chickens) {
  const at = parkFromViewport(viewport, x, y);
  const within = (c, half) => Math.abs(offset(c.parkX, at.parkX)) <= half && Math.abs(offset(c.parkY, at.parkY)) <= half;
  if (cows.some((c) => within(c, cow_px / 2))) return "cow";
  if (chickens.some((c) => within(c, chicken_px / 2 + chicken_slop_px))) return "chicken";
  return null;
}

const lines = {
  cow: [
    "Moo means no. 🐄 Cows only move for dogs.",
    "That cow weighs 1,400 pounds and does not do lifts. Send a dog.",
    "The cow has filed a formal complaint with the Dog Park Authority.",
    "You can't drag a cow. Nobody can. That's why dogs were invented.",
    "The cow regards your cursor with profound bovine indifference.",
    "Hands off the merchandise. Herd her with a dog.",
  ],
  chicken: [
    "🐓 BAWK. The chicken has escaped your grasp, and also your respect.",
    "Chickens are free-range, not free-drag.",
    "That chicken is on the clock. It has poop to eat.",
    "The chickens have unionized. Grabbing is a grievance.",
    "The chicken looks at you with 66 million years of dinosaur contempt.",
    "You can't herd chickens. Ask anyone. Ask the chickens.",
  ],
};

// After this many tries in a row, the park takes it personally.
const persistent = 4;
const persistence = [
  "Okay, now you're just doing it on purpose.",
  "The critters have started a group chat about you.",
  "Still no. Have you met the dogs? They're right there.",
];

// The next line for a press on a `kind`, never the one just said: each
// kind's lines in turn from a random start, and, past `persistent` tries
// in a row with no dog grabbed between, the park's remarks on that.
// `random` is Math.random's shape, for tests.
export function quipper(random = Math.random) {
  const next = { cow: Math.floor(random() * lines.cow.length), chicken: Math.floor(random() * lines.chicken.length) };
  let tries = 0;
  let remark = 0;
  return {
    say(kind) {
      tries++;
      if (tries > persistent) return persistence[remark++ % persistence.length];
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
