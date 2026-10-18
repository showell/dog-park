## THE FIRST LAYOUT, in Roc: where every critter stands when the park starts
## afresh. `zig build roc-layout` runs it (`roc roc/layout.roc`); it prints one line per
## critter, `<kind> <x> <y>` in 256ths of a pixel, dogs then cows then
## chickens, each kind in its own numbering. src/play/layout.zig embeds
## what it printed (src/play/layout.txt) and holds it to the Zig layout.

# The world's numbers (src/play/tiles.zig and layout.zig own them).
tile_px = 350

world_tiles = 6

park_tiles = 4

corner_in = 52

chicken_off = 15

## Pixels to the physics' units, 256ths of a pixel.
px : I64 -> I64
px = |n| n * 256

park_offset_px = (world_tiles - park_tiles) // 2 * tile_px

## Who stands in one tile of the park, and where, in pixels from its
## top-left corner. A white tile (column plus row even) holds a cow in
## the middle; a blue one two chickens either side of it. Every tile holds
## four dogs, breed b in corner b: NW, NE, SW, SE.
Spot : { kind : [Dog, Cow, Chicken], x : I64, y : I64 }

tile_spots : I64, I64 -> List(Spot)
tile_spots = |col, row| {
	far = tile_px - corner_in
	mid = tile_px // 2
	dogs = [
		{ kind: Dog, x: corner_in, y: corner_in },
		{ kind: Dog, x: far, y: corner_in },
		{ kind: Dog, x: corner_in, y: far },
		{ kind: Dog, x: far, y: far },
	]
	if (col + row) % 2 == 0 {
		dogs.concat([{ kind: Cow, x: mid, y: mid }])
	} else {
		dogs.concat([
			{ kind: Chicken, x: mid - chicken_off, y: mid },
			{ kind: Chicken, x: mid + chicken_off, y: mid },
		])
	}
}

## Every spot in the park, tile by tile, row by row, in world pixels.
park : List(Spot)
park = {
	var $all = []
	var $row = 0
	while $row < park_tiles {
		var $col = 0
		while $col < park_tiles {
			for s in tile_spots($col, $row) {
				$all = $all.append({
					kind: s.kind,
					x: park_offset_px + $col * tile_px + s.x,
					y: park_offset_px + $row * tile_px + s.y,
				})
			}
			$col = $col + 1
		}
		$row = $row + 1
	}
	$all
}

kind_name : [Dog, Cow, Chicken] -> Str
kind_name = |k| match k {
	Dog => "dog"
	Cow => "cow"
	Chicken => "chicken"
}

line : Spot -> Str
line = |s| "${kind_name(s.kind)} ${px(s.x).to_str()} ${px(s.y).to_str()}\n"

main! = |_args| {
	for kind in [Dog, Cow, Chicken] {
		for s in park {
			if s.kind == kind {
				echo!(line(s))
			} else {
				{}
			}
		}
	}
	Ok({})
}

expect park.len() == 4 * 4 * 4 + 8 + 16
