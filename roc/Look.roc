## HOW THE GAME LOOKS AND FEELS, said once: each breed's emoji, the park's
## colours, the edge bands' sizes and speeds, how near cows must be to be
## one herd, and how forgiving a press on a small critter is. Two read it:
## roc/print_page.roc, which prints it for the page (solo/look.js, which
## solo/scene.js, solo/pointer.js and solo/quips.js read), and
## roc/native.roc, the game on roc-ray. Each kind's own emoji and colour
## are World.roc's.
import World

Look := [].{

	## A dog's look is its breed's: dog n is breed n mod the breeds.
	dog_looks : List(Str)
	dog_looks = ["🐕", "🐩", "🦮", "🐕‍🦺"]

	## The park's checkerboard, a tile's colour by its column plus row,
	## even and odd; a poop; the leashed dog's ring, in the hand and kept.
	tile_even : U32
	tile_even = 0xffffff

	tile_odd : U32
	tile_odd = 0xeaf3fc

	poop_fill : U32
	poop_fill = 0x7a4a1a

	ring_in_hand : U32
	ring_in_hand = 0x22aa22

	ring_kept : U32
	ring_kept = 0xdd3333

	## **THE EDGE BANDS**: along each edge of the screen, `band_px` deep,
	## where a held dog (or a held pan) scrolls the view, faster the deeper,
	## from `slowest_px_per_tick` to `fastest_px_per_tick` (28 and 224 px a
	## second at 16 ticks).
	band_px : F32
	band_px = 80

	slowest_px_per_tick : F32
	slowest_px_per_tick = 1.75

	fastest_px_per_tick : F32
	fastest_px_per_tick = 14

	## Two cows are one herd when their centres are at most this far apart
	## on the larger axis (two cow-widths: a cow's gap between them).
	herd_link_px : I64
	herd_link_px = 2 * World.cow_px

	## A chicken is small: a press this near its square still counts.
	chicken_slop_px : I64
	chicken_slop_px = 4

	## A colour as the page writes it: `#rrggbb`.
	css : U32 -> Str
	css = |c| {
		digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
		var $out = ""
		var $v = c
		var $k = 0
		while $k < 6 {
			d = match digits.get(($v % 16).to_u64()) {
				Ok(s) => s
				Err(_) => "0"
			}
			$out = d.concat($out)
			$v = $v // 16
			$k = $k + 1
		}
		"#".concat($out)
	}
}

expect Look.css(0xeaf3fc) == "#eaf3fc" and Look.css(0x22aa22) == "#22aa22"
expect Look.dog_looks.len() == World.breeds.to_u64_wrap()
