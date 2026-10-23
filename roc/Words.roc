## THE GAME'S WORDS, said once: what the park says when a critter only a
## dog moves is pressed, when the leashed dog bumps into something, and how
## the score and the levels read. Two read it: roc/print_page.roc, which
## prints them for the page (solo/words.js, which solo/quips.js and
## solo/scene.js read), and roc/native.roc, the game on roc-ray, which draws
## them without their emoji (its font has none).
##
## A template's `{name}` is filled in where it is said (`fill`).
Words := [].{

	## A press on a critter only a dog moves, by its kind: a line of each in
	## turn (Steve, 2026-10-15, "tough love").
	press_lines : List({ kind : Str, lines : List(Str) })
	press_lines = [
		{
			kind: "cow",
			lines: [
				"Moo means no. 🐄 Cows only move for dogs.",
				"That cow weighs 1,400 pounds and does not do lifts. Send a dog.",
				"The cow has filed a formal complaint with the Dog Park Authority.",
				"You can't drag a cow. Nobody can. That's why dogs were invented.",
				"The cow regards your cursor with profound bovine indifference.",
				"Hands off the merchandise. Herd her with a dog.",
			],
		},
		{
			kind: "chicken",
			lines: [
				"🐓 BAWK. The chicken has escaped your grasp, and also your respect.",
				"Chickens are free-range, not free-drag.",
				"That chicken is on the clock. It has poop to eat.",
				"The chickens have unionized. Grabbing is a grievance.",
				"The chicken looks at you with 66 million years of dinosaur contempt.",
				"You can't herd chickens. Ask anyone. Ask the chickens.",
			],
		},
		{
			kind: "goat",
			lines: [
				"🐐 You can't drag a goat. You can barely suggest things to a goat.",
				"The goat chewed on your cursor a bit. Send a dog.",
				"Goats only move for dogs, and then only toward them.",
				"That goat has opinions. None of them involve being dragged.",
				"Bleat. (Translation: no.)",
			],
		},
	]

	## A kind with no lines of its own.
	any_line : Str
	any_line = "That {kind} isn't going anywhere for you. Send a dog."

	## After this many presses in a row with no dog grabbed between, the
	## park takes it personally.
	persistent : U64
	persistent = 4

	persistence : List(Str)
	persistence = [
		"Okay, now you're just doing it on purpose.",
		"The critters have started a group chat about you.",
		"Still no. Have you met the dogs? They're right there.",
	]

	## A bump, by what the leashed dog walked into: a kind, or poop.
	bump_lines : List({ kind : Str, lines : List(Str) })
	bump_lines = [
		{
			kind: "dog",
			lines: [
				"Bonk. 🐕 Dogs don't stack. We checked.",
				"That dog was standing there first. Go around.",
				"Two dogs, one spot. Physics says no.",
				"Your dog just walked into a colleague. They're sniffing it out now.",
				"Leash yanked, dog bonked. Maybe steer a little?",
			],
		},
		{
			kind: "cow",
			lines: [
				"You walked your dog into a cow. The cow won. 🐄",
				"Herding means near the cows, not through them.",
				"That's 1,400 pounds of not moving for you.",
				"The cow did not budge. The cow never budges. Bark from further back.",
				"Cows are load-bearing. Steer around.",
			],
		},
		{
			kind: "chicken",
			lines: [
				"🐓 The chicken held its ground. Respect the chicken.",
				"Your dog has been out-stubborned by a chicken.",
				"That chicken is boxed in and in no mood. Go around.",
				"Dog vs. chicken: the chicken wins on points.",
			],
		},
		{
			kind: "goat",
			lines: [
				"🐐 The goat headbutted back. The goat always headbutts back.",
				"Your dog met a goat. The goat was not impressed.",
				"Goats don't yield. Goats have never yielded. Go around.",
				"That goat has eaten tougher things than your dog. Mostly tin cans.",
				"Bleat. Your dog has been told.",
			],
		},
		{
			kind: "poop",
			lines: [
				"💩 Even your dog won't walk through that.",
				"Your dog refuses. It has standards.",
				"The chickens haven't got to that one yet. Go around.",
				"Nope. The dog took one sniff and stopped.",
			],
		},
	]

	## A bump into a kind with no lines of its own.
	any_bump : Str
	any_bump = "Bonk. Your dog walked into a {kind}. Go around."

	## The score while the cows are apart, and the goal met: both cows, or
	## all of them (Steve, 2026-10-20: "You have herded both cows!").
	score : Str
	score = "Herd: {herd} of {cows} cows"

	won_two : Str
	won_two = "You have herded both cows! 🎉"

	won_all : Str
	won_all = "All {cows} cows herded together! 🎉"

	## A level's name: "Level One", "Level Two", ... (past ten, its number).
	number_words : List(Str)
	number_words = ["One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]

	level_name : U64 -> Str
	level_name = |n| match number_words.get(n - 1) {
		Ok(w) => "Level ${w}"
		Err(_) => "Level ${n.to_str()}"
	}

	## `template` with each `{name}` in `subs` filled in.
	fill : Str, List({ name : Str, value : Str }) -> Str
	fill = |template, subs| {
		var $out = template
		for w in subs {
			$out = $out.replace_each("{${w.name}}", w.value)
		}
		$out
	}

	## A kind's lines from a table, or none.
	lines_of : List({ kind : Str, lines : List(Str) }), Str -> List(Str)
	lines_of = |table, kind| match table.keep_if(|t| t.kind == kind).first() {
		Ok(t) => t.lines
		Err(_) => []
	}

	won_text : U64 -> Str
	won_text = |cows| if (cows == 2) won_two else fill(won_all, [{ name: "cows", value: cows.to_str() }])

	score_text : U64, U64 -> Str
	score_text = |herd, cows| fill(score, [{ name: "herd", value: herd.to_str() }, { name: "cows", value: cows.to_str() }])

	## `s` with every character past ASCII left out, and the spaces that
	## leaves doubled or at an end taken out: a line for a font with no emoji.
	plain : Str -> Str
	plain = |s| {
		var $bytes = []
		for b in s.to_utf8() {
			if b < 128 {
				$bytes = $bytes.append(b)
			} else {
				{}
			}
		}
		kept = match Str.from_utf8($bytes) {
			Ok(t) => t
			Err(_) => ""
		}
		var $out = kept
		while $out.contains("  ") {
			$out = $out.replace_each("  ", " ")
		}
		$out.trim()
	}
}

expect Words.level_name(1) == "Level One" and Words.level_name(11) == "Level 11"
expect Words.won_text(8) == "All 8 cows herded together! 🎉"
expect Words.score_text(1, 2) == "Herd: 1 of 2 cows"
expect Words.plain("Moo means no. 🐄 Cows only move for dogs.") == "Moo means no. Cows only move for dogs."
expect Words.plain("💩 Even your dog won't walk through that.") == "Even your dog won't walk through that."
expect Words.lines_of(Words.press_lines, "goat").len() == 5
