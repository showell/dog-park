## THE PAGE'S WORDS AND LOOK, in Roc: roc/Words.roc and roc/Look.roc, which
## the game on roc-ray reads too, printed for the page. `zig build roc`
## runs it twice and checks in what it prints:
##
## - `roc roc/print_page.roc -- words`: solo/words.js, which solo/quips.js
##   and solo/scene.js read;
## - `roc roc/print_page.roc -- look`: solo/look.js, which solo/scene.js,
##   solo/pointer.js and solo/quips.js read.
##
## These files and roc/World.roc are the one place the page's words and
## look are said.
import Words
import Look

## A string as JavaScript writes it, in double quotes.
js_str : Str -> Str
js_str = |s| "\"${s.replace_each("\\", "\\\\").replace_each("\"", "\\\"")}\""

js_list : List(Str) -> Str
js_list = |ls| "[${Str.join_with(ls.map(js_str), ", ")}]"

## A table of lines by kind, an object of lists, one kind a line.
js_table : List({ kind : Str, lines : List(Str) }) -> Str
js_table = |table| {
	var $out = "{\n"
	for t in table {
		$out = $out.concat("  ${t.kind}: [\n")
		for l in t.lines {
			$out = $out.concat("    ${js_str(l)},\n")
		}
		$out = $out.concat("  ],\n")
	}
	$out.concat("}")
}

words : Str
words =
	\\// THE GAME'S WORDS for the page, printed by roc/print_page.roc (`zig build
	\\// roc`) from roc/Words.roc: do not edit; edit that and print it again.
	\\// The game on roc-ray says the same (roc/native.roc). A template's `{name}`
	\\// is filled in where it is said.
	\\export const press_lines = ${js_table(Words.press_lines)};
	\\export const any_line = ${js_str(Words.any_line)};
	\\export const persistent = ${Words.persistent.to_str()};
	\\export const persistence = ${js_list(Words.persistence)};
	\\export const bump_lines = ${js_table(Words.bump_lines)};
	\\export const any_bump = ${js_str(Words.any_bump)};
	\\export const score = ${js_str(Words.score)};
	\\export const won_two = ${js_str(Words.won_two)};
	\\export const won_all = ${js_str(Words.won_all)};
	\\export const number_words = ${js_list(Words.number_words)};
	\\

look : Str
look =
	\\// HOW THE GAME LOOKS AND FEELS, for the page, printed by roc/print_page.roc
	\\// (`zig build roc`) from roc/Look.roc: do not edit; edit that and print it
	\\// again. The game on roc-ray looks the same (roc/native.roc).
	\\export const dog_looks = ${js_list(Look.dog_looks)};
	\\export const tile_even = ${js_str(Look.css(Look.tile_even))};
	\\export const tile_odd = ${js_str(Look.css(Look.tile_odd))};
	\\export const poop_fill = ${js_str(Look.css(Look.poop_fill))};
	\\export const ring_in_hand = ${js_str(Look.css(Look.ring_in_hand))};
	\\export const ring_kept = ${js_str(Look.css(Look.ring_kept))};
	\\export const band_px = ${Look.band_px.to_str()};
	\\export const slowest_px_per_tick = ${Look.slowest_px_per_tick.to_str()};
	\\export const fastest_px_per_tick = ${Look.fastest_px_per_tick.to_str()};
	\\export const herd_link_px = ${Look.herd_link_px.to_str()};
	\\export const chicken_slop_px = ${Look.chicken_slop_px.to_str()};
	\\

main! = |args| {
	match args {
		["words"] => echo!(words)
		["look"] => echo!(look)
		_ => crash "roc/print_page.roc: say `words` or `look`"
	}
	Ok({})
}
