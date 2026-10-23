// THE GAME'S WORDS for the page, printed by roc/print_page.roc (`zig build
// roc`) from roc/Words.roc: do not edit; edit that and print it again.
// The game on roc-ray says the same (roc/native.roc). A template's `{name}`
// is filled in where it is said.
export const press_lines = {
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
  goat: [
    "🐐 You can't drag a goat. You can barely suggest things to a goat.",
    "The goat chewed on your cursor a bit. Send a dog.",
    "Goats only move for dogs, and then only toward them.",
    "That goat has opinions. None of them involve being dragged.",
    "Bleat. (Translation: no.)",
  ],
};
export const any_line = "That {kind} isn't going anywhere for you. Send a dog.";
export const persistent = 4;
export const persistence = ["Okay, now you're just doing it on purpose.", "The critters have started a group chat about you.", "Still no. Have you met the dogs? They're right there."];
export const bump_lines = {
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
  goat: [
    "🐐 The goat headbutted back. The goat always headbutts back.",
    "Your dog met a goat. The goat was not impressed.",
    "Goats don't yield. Goats have never yielded. Go around.",
    "That goat has eaten tougher things than your dog. Mostly tin cans.",
    "Bleat. Your dog has been told.",
  ],
  poop: [
    "💩 Even your dog won't walk through that.",
    "Your dog refuses. It has standards.",
    "The chickens haven't got to that one yet. Go around.",
    "Nope. The dog took one sniff and stopped.",
  ],
};
export const any_bump = "Bonk. Your dog walked into a {kind}. Go around.";
export const score = "Herd: {herd} of {cows} cows";
export const won_two = "You have herded both cows! 🎉";
export const won_all = "All {cows} cows herded together! 🎉";
export const number_words = ["One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"];
