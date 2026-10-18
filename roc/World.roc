## THE WORLD'S NUMBERS, as a Roc module: its size, the park in it, the
## critters' squares and their breeds. Two read it: roc/world.roc, which
## lays the park out with them and prints them for the physics' Zig and
## the page, and Walk.roc, which walks the critters in it inside the
## physics. Lengths are in whole pixels.
World := [].{

	## The world is `world_tiles` by `world_tiles` square tiles of `tile_px`
	## pixels, a torus.
	tile_px : I64
	tile_px = 350

	world_tiles : I64
	world_tiles = 6

	## The populated park: `park_tiles` by `park_tiles` tiles in the world's
	## middle; the rest of the world is empty ground.
	park_tiles : I64
	park_tiles = 4

	## The critters' squares, in whole pixels, as the physics moves them and
	## the page draws them (each centred on its point); a dog's poop is a
	## square too, drawn as a circle. Dogs and cows at 70% of their first
	## sizes, with the tiles (Steve, 2026-10-15); chickens and poop kept.
	dog_px : I64
	dog_px = 28

	cow_px : I64
	cow_px = 42

	chicken_px : I64
	chicken_px = 20

	poop_px : I64
	poop_px = 12

	## Dog n is of breed n mod `breeds`, and stands in its tile's corner of
	## that number: so there are as many breeds as a tile has corners.
	breeds : I64
	breeds = 4

	## How far in from its corner of a tile a dog stands, on each axis; how far
	## each of a blue tile's two chickens stands from its middle.
	corner_in : I64
	corner_in = 52

	chicken_off : I64
	chicken_off = 15
}
