## THE WORLD'S NUMBERS, as a Roc module: its size, the park in it, the
## critters' squares and their breeds. Two read it: roc/print_world.roc, which
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

	## **THE LEVELS**, Level One first, each a world `world_tiles` tiles a
	## side with its park `park_tiles` a side in the middle, laid out by
	## roc/print_world.roc's rule, with the chickens and the goats or without. A
	## level is its geometry and its first layout alone: the kinds, their
	## sizes and their rules are every level's (Steve, 2026-10-20). The
	## largest is `world_tiles` and `park_tiles` above, by which the physics
	## sizes its room.
	Level : { world_tiles : I64, park_tiles : I64, chickens : Bool, goats : Bool }

	level_one : Level
	level_one = { world_tiles: 4, park_tiles: 2, chickens: Bool.False, goats: Bool.False }

	level_two : Level
	level_two = { world_tiles: 6, park_tiles: 4, chickens: Bool.True, goats: Bool.True }

	levels : List(Level)
	levels = [level_one, level_two]

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

	goat_px : I64
	goat_px = 30

	poop_px : I64
	poop_px = 12

	## THE KINDS OF CRITTER, each said here once; the physics' Zig knows no
	## kind but by these. A kind's number is its place in `kinds`: the
	## number physics.zig's `Kind` and the walk's `Wish.kind_of` cross with.
	## - `name`: what the formats and the page call it;
	## - `px`: its square's side;
	## - `colour`: how the page draws a kind it has no art for, a square of
	##   that colour `px` across;
	## - `emoji`: the page's art for a kind it draws by `kinds` alone, or ""
	##   for none (a dog's look is its breed's, solo/scene.js's `dog_looks`);
	## - `rank`: its place in the cascade (lower is more alpha; the leashed
	##   critter is before all), and the order the physics lists the kinds;
	## - `kin`: who it nudges and is nudged by: `breed`, its own breed of
	##   the kind (critter n is of breed n mod `breeds`); `herd`, every one of
	##   the kind; `none`, nobody;
	## - `leash`: whether a human leashes it (one kind does, the walk's own).
	Look : {
		name : Str,
		px : I64,
		colour : Str,
		emoji : Str,
		rank : I64,
		kin : [Breed, Herd, NoKin],
		leash : Bool,
	}

	kinds : List(Look)
	kinds = [
		{
			name: "dog",
			px: dog_px,
			colour: "#a0522d",
			emoji: "",
			rank: 1,
			kin: Breed,
			leash: Bool.True,
		},
		{
			name: "cow",
			px: cow_px,
			colour: "#555555",
			emoji: "🐄",
			rank: 0,
			kin: Herd,
			leash: Bool.False,
		},
		{
			name: "chicken",
			px: chicken_px,
			colour: "#d4a017",
			emoji: "🐓",
			rank: 2,
			kin: NoKin,
			leash: Bool.False,
		},
		{
			name: "goat",
			px: goat_px,
			colour: "#8a8a8a",
			emoji: "🐐",
			rank: 3,
			kin: Herd,
			leash: Bool.False,
		},
	]

	## The critters are kept by cells: a tile cut `cell_per_tile` ways on
	## each axis (the physics' `Scene` and the walk both).
	cell_per_tile : I64
	cell_per_tile = 2

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

	## How far above a goat's blue tile's middle it stands: over its
	## chickens, under the tile's top dogs.
	goat_above : I64
	goat_above = 45
}
