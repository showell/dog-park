## THE WORLD, in Roc: its size, the populated park in it, and where every
## critter stands when the park starts afresh. `zig build roc-world` runs
## it twice and checks in what it prints:
##
## - `roc roc/world.roc -- zon`: src/play/world.zon, which src/play/world.zig
##   imports as a `World` (the physics: the server, the page's wasm, the
##   kernel). The critter counts are its lists' lengths.
## - `roc roc/world.roc -- js`: solo/world.js, the numbers the page's script
##   draws with.
##
## No build runs Roc; this file is the one place the world is said.

## The world is `world_tiles` by `world_tiles` square tiles of `tile_px`
## pixels, a torus.
tile_px = 350

world_tiles = 6

## The populated park: `park_tiles` by `park_tiles` tiles in the world's
## middle; the rest of the world is empty ground.
park_tiles = 4

park_first = (world_tiles - park_tiles) // 2

## How far in from its corner of a tile a dog stands, on each axis; how far
## each of a blue tile's two chickens stands from its middle.
corner_in = 52

chicken_off = 15

expect park_first >= 0 and park_first * 2 + park_tiles == world_tiles
expect park_tiles % 2 == 0

## Pixels to the physics' units, 256ths of a pixel.
px : I64 -> I64
px = |n| n * 256

Kind : [Dog, Cow, Chicken]

Spot : { kind : Kind, x : I64, y : I64 }

## Who stands in one tile of the park, and where, in pixels from its
## top-left corner. Every tile holds four dogs, breed b in corner b (NW, NE,
## SW, SE); a white tile (column plus row even) a cow in the middle; a blue
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

expect of_kind(Dog).len() == 64 and of_kind(Cow).len() == 8 and of_kind(Chicken).len() == 16

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
	\\// THE WORLD, printed by roc/world.roc (`zig build roc-world`): do not
	\\// edit; edit that and print it again. Read by src/play/world.zig.
	\\.{
	\\    .tile_px = ${tile_px.to_str()},
	\\    .world_tiles = ${world_tiles.to_str()},
	\\    .park = .{ .first = ${park_first.to_str()}, .tiles = ${park_tiles.to_str()} },
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
	\\// roc-world`): do not edit; edit that and print it again. The physics
	\\// reads the same world (src/play/world.zon); test_page_modules.mjs holds
	\\// these to the wasm's.
	\\export const tile_px = ${tile_px.to_str()};
	\\export const world_tiles = ${world_tiles.to_str()};
	\\export const park_tiles = ${park_tiles.to_str()};
	\\export const cow_count = ${of_kind(Cow).len().to_str()};
	\\

main! = |args| {
	match args {
		["zon"] => echo!(zon)
		["js"] => echo!(js)
		_ => crash "roc/world.roc: say `zon` or `js`"
	}
	Ok({})
}
