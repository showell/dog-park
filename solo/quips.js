// **TOUGH LOVE** (Steve, 2026-10-15): cows and chickens can't be dragged
// (only dogs move them), and a press on one says so, with a joke, so the
// player learns it once. A press on empty ground still drags the
// tablecloth (pans the view); a press on a dog leashes it, as ever. And a
// drag that pulls the leashed dog into another critter (or a poop it can't
// get round) ends in a bump, which gets its own line, by what it hit.
// Pure: park.js shows the line.

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

// What a tick's bump hit, from its checked lines ("bump <tick> <kind> ..."):
// "dog", "cow", "chicken" or "poop", or null when it didn't bump.
export function bumpedKind(checked) {
  const m = /^bump \d+ (dog|cow|chicken|poop)\b/m.exec(checked);
  return m === null ? null : m[1];
}

const bumpLines = {
  dog: [
    "Bonk. 🐕 Dogs don't stack. We checked.",
    "That dog was standing there first. Go around.",
    "Two dogs, one spot. Physics says no.",
    "Your dog just walked into a colleague. They're sniffing it out now.",
    "Leash yanked, dog bonked. Maybe steer a little?",
  ],
  cow: [
    "You walked your dog into a cow. The cow won. 🐄",
    "Herding means near the cows, not through them.",
    "That's 1,400 pounds of not moving for you.",
    "The cow did not budge. The cow never budges. Bark from further back.",
    "Cows are load-bearing. Steer around.",
  ],
  chicken: [
    "🐓 The chicken held its ground. Respect the chicken.",
    "Your dog has been out-stubborned by a chicken.",
    "That chicken is boxed in and in no mood. Go around.",
    "Dog vs. chicken: the chicken wins on points.",
  ],
  poop: [
    "💩 Even your dog won't walk through that.",
    "Your dog refuses. It has standards.",
    "The chickens haven't got to that one yet. Go around.",
    "Nope. The dog took one sniff and stopped.",
  ],
};

// The next line for a bump on a `kind`, never the one just said: each
// kind's lines in turn from a random start. No persistence remark: bumping
// is part of herding, never a lesson refused.
export function bumper(random = Math.random) {
  const next = Object.fromEntries(Object.entries(bumpLines).map(([k, ls]) => [k, Math.floor(random() * ls.length)]));
  return {
    say(kind) {
      const ls = bumpLines[kind];
      return ls[next[kind]++ % ls.length];
    },
  };
}

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
