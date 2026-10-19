## THE WORLD, in Roc: its size, the populated park in it, and where every
## critter stands when the park starts afresh. `zig build roc` runs
## it twice and checks in what it prints:
##
## - `roc roc/world.roc -- zon`: src/play/world.zon, which src/play/world.zig
##   imports as a `World` (the physics: the server, the page's wasm, the
##   kernel). The critter counts are its lists' lengths.
## - `roc roc/world.roc -- js`: solo/world.js, the numbers the page's script
##   draws with.
##
## No build runs Roc; this file and roc/World.roc are the one place the
## world is said.

## The world's numbers are roc/World.roc's.
import World

tile_px = World.tile_px

world_tiles = World.world_tiles

park_tiles = World.park_tiles

dog_px = World.dog_px

cow_px = World.cow_px

chicken_px = World.chicken_px

poop_px = World.poop_px

breeds = World.breeds

cell_per_tile = World.cell_per_tile

corner_in = World.corner_in

chicken_off = World.chicken_off

park_first : I64
park_first = (world_tiles - park_tiles) // 2

expect park_first >= 0 and park_first * 2 + park_tiles == world_tiles
expect park_tiles % 2 == 0
expect breeds == 4

## Pixels to the physics' units, 256ths of a pixel.
px : I64 -> I64
px = |n| n * 256

Kind : [Dog, Cow, Chicken]

Spot : { kind : Kind, x : I64, y : I64 }

## Who stands in one tile of the park, and where, in pixels from its
## top-left corner. Every tile holds a dog of each breed, breed b in corner
## b (NW, NE, SW, SE); a white tile (column plus row even) a cow in the middle; a blue
## one two chickens either side of it.
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
					x: (park_first + $col) * tile_px + s.x,
					y: (park_first + $row) * tile_px + s.y,
				})
			}
			$col = $col + 1
		}
		$row = $row + 1
	}
	$all
}

## One kind's spots, in their order: each kind is numbered on its own.
of_kind : Kind -> List(Spot)
of_kind = |kind| park.keep_if(|s| s.kind == kind)

expect of_kind(Dog).len() == (park_tiles * park_tiles * breeds).to_u64_wrap()
expect of_kind(Cow).len() + of_kind(Chicken).len() // 2 == (park_tiles * park_tiles).to_u64_wrap()

## A critter's square's half side, in pixels.
half : Kind -> I64
half = |kind| match kind {
	Dog => dog_px // 2
	Cow => cow_px // 2
	Chicken => chicken_px // 2
}

## The short way between two coordinates round the torus, its length.
gap : I64, I64 -> I64
gap = |a, b| {
	world_px = world_tiles * tile_px
	d = (a - b) % world_px
	w = if (d < 0) d + world_px else d
	if (w > world_px - w) world_px - w else w
}

## The physics needs no two critters overlapping where they start (a load
## puts them back without resolving): each pair's squares apart on one axis.
no_overlap : List(Spot) -> Bool
no_overlap = |spots| {
	var $ok = Bool.True
	var $i = 0
	while $i < spots.len() {
		var $j = $i + 1
		while $j < spots.len() {
			match (spots.get($i), spots.get($j)) {
				(Ok(a), Ok(b)) => {
					reach = half(a.kind) + half(b.kind)
					if gap(a.x, b.x) < reach and gap(a.y, b.y) < reach {
						$ok = Bool.False
					} else {
						{}
					}
				}
				_ => {}
			}
			$j = $j + 1
		}
		$i = $i + 1
	}
	$ok
}

expect no_overlap(park)
expect !no_overlap([{ kind: Dog, x: 10, y: 10 }, { kind: Cow, x: 40, y: 30 }])

points : Kind -> Str
points = |kind| {
	var $out = ""
	for s in of_kind(kind) {
		$out = $out.concat("        .{ .x = ${px(s.x).to_str()}, .y = ${px(s.y).to_str()} },\n")
	}
	$out
}

zon : Str
zon =
	\\// THE WORLD, printed by roc/world.roc (`zig build roc`): do not
	\\// edit; edit that and print it again. Read by src/play/world.zig.
	\\.{
	\\    .tile_px = ${tile_px.to_str()},
	\\    .world_tiles = ${world_tiles.to_str()},
	\\    .park = .{ .first = ${park_first.to_str()}, .tiles = ${park_tiles.to_str()} },
	\\    .sizes = .{ .dog_px = ${dog_px.to_str()}, .cow_px = ${cow_px.to_str()}, .chicken_px = ${chicken_px.to_str()}, .poop_px = ${poop_px.to_str()} },
	\\    .breeds = ${breeds.to_str()},
	\\    .cell_per_tile = ${cell_per_tile.to_str()},
	\\    .dogs = .{
	\\${points(Dog)}    },
	\\    .cows = .{
	\\${points(Cow)}    },
	\\    .chickens = .{
	\\${points(Chicken)}    },
	\\}
	\\

js : Str
js =
	\\// THE WORLD's numbers for the page, printed by roc/world.roc (`zig build
	\\// roc`): do not edit; edit that and print it again. The physics
	\\// reads the same world (src/play/world.zon); test_page_modules.mjs holds
	\\// these to the wasm's.
	\\export const tile_px = ${tile_px.to_str()};
	\\export const world_tiles = ${world_tiles.to_str()};
	\\export const park_tiles = ${park_tiles.to_str()};
	\\export const cow_count = ${of_kind(Cow).len().to_str()};
	\\export const dog_px = ${dog_px.to_str()};
	\\export const cow_px = ${cow_px.to_str()};
	\\export const chicken_px = ${chicken_px.to_str()};
	\\export const poop_px = ${poop_px.to_str()};
	\\export const breeds = ${breeds.to_str()};
	\\

main! = |args| {
	match args {
		["zon"] => echo!(zon)
		["js"] => echo!(js)
		_ => crash "roc/world.roc: say `zon` or `js`"
	}
	Ok({})
}
