## WHERE EVERY CRITTER STANDS when a level's park starts afresh, in whole
## pixels. Two read it: roc/world.roc, which prints it for the physics' Zig
## and the page, and roc/native.roc, the game on roc-ray, which lays its
## park out with it.
import World

Layout := [].{

	Kind : [Dog, Cow, Chicken, Goat]

	Spot : { kind : Kind, x : I64, y : I64 }

	## Where a level's park begins: its first tile on each axis, so the park
	## sits in the middle of its world.
	park_first : World.Level -> I64
	park_first = |lv| (lv.world_tiles - lv.park_tiles) // 2

	## Who stands in one tile of the park, and where, in pixels from its
	## top-left corner. Every tile holds a dog of each breed, breed b in corner
	## b (NW, NE, SW, SE); a white tile (column plus row even) a cow in the middle; a blue
	## one two chickens either side of it, and a blue tile in an even row and
	## odd column (four of the eight in Level Two) a goat above them; a level
	## without chickens or goats leaves them out.
	tile_spots : World.Level, I64, I64 -> List(Spot)
	tile_spots = |lv, col, row| {
		far = World.tile_px - World.corner_in
		mid = World.tile_px // 2
		dogs = [
			{ kind: Dog, x: World.corner_in, y: World.corner_in },
			{ kind: Dog, x: far, y: World.corner_in },
			{ kind: Dog, x: World.corner_in, y: far },
			{ kind: Dog, x: far, y: far },
		]
		if (col + row) % 2 == 0 {
			dogs.concat([{ kind: Cow, x: mid, y: mid }])
		} else {
			chickens = if lv.chickens {
				dogs.concat([
					{ kind: Chicken, x: mid - World.chicken_off, y: mid },
					{ kind: Chicken, x: mid + World.chicken_off, y: mid },
				])
			} else {
				dogs
			}
			if lv.goats and row % 2 == 0 and col % 2 == 1 {
				chickens.concat([{ kind: Goat, x: mid, y: mid - World.goat_above }])
			} else {
				chickens
			}
		}
	}

	## Every spot in a level's park, tile by tile, row by row, in world pixels.
	park : World.Level -> List(Spot)
	park = |lv| {
		var $all = []
		var $row = 0
		while $row < lv.park_tiles {
			var $col = 0
			while $col < lv.park_tiles {
				for s in tile_spots(lv, $col, $row) {
					$all = $all.append({
						kind: s.kind,
						x: (park_first(lv) + $col) * World.tile_px + s.x,
						y: (park_first(lv) + $row) * World.tile_px + s.y,
					})
				}
				$col = $col + 1
			}
			$row = $row + 1
		}
		$all
	}

	## One kind's spots in a level, in their order: each kind is numbered on
	## its own, and critter n of a kind is critter n in every level.
	of_kind : World.Level, Kind -> List(Spot)
	of_kind = |lv, kind| park(lv).keep_if(|s| s.kind == kind)
}
