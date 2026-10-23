## THE WORLD, in Roc: its size, the populated park in it, and where every
## critter stands when the park starts afresh. `zig build roc` runs
## it twice and checks in what it prints:
##
## - `roc roc/print_world.roc -- zon`: src/play/world.zon, which src/play/world.zig
##   imports as a `World` (the physics: the server, the page's wasm, the
##   kernel). The critter counts are its lists' lengths.
## - `roc roc/print_world.roc -- js`: solo/world.js, the numbers the page's script
##   draws with.
##
## This file and roc/World.roc are the one place the world is said.

## The world's numbers are roc/World.roc's.
import World
import Wish
import Layout

tile_px = World.tile_px

world_tiles = World.world_tiles

park_tiles = World.park_tiles

dog_px = World.dog_px

cow_px = World.cow_px

chicken_px = World.chicken_px

goat_px = World.goat_px

poop_px = World.poop_px

breeds = World.breeds

cell_per_tile = World.cell_per_tile

corner_in = World.corner_in

chicken_off = World.chicken_off

goat_above = World.goat_above

Level : World.Level

expect World.levels.keep_if(|lv| park_first(lv) < 0 or park_first(lv) * 2 + lv.park_tiles != lv.world_tiles or lv.park_tiles % 2 != 0).len() == 0
expect breeds == 4

## The largest level is the world the physics sizes its room by.
expect World.levels.map(|lv| lv.world_tiles).keep_if(|t| t > world_tiles).len() == 0
expect World.levels.keep_if(|lv| lv.world_tiles == world_tiles and lv.park_tiles == park_tiles).len() > 0

## Pixels to the physics' units, 256ths of a pixel.
px : I64 -> I64
px = |n| n * 256

## The park's layout is roc/Layout.roc's, which the game on roc-ray lays
## its park out with too.
Kind : Layout.Kind

Spot : Layout.Spot

park_first = Layout.park_first

tile_spots = Layout.tile_spots

park = Layout.park

of_kind = Layout.of_kind

## Level One: the dogs, and a cow on each of its two white tiles; Level Two:
## the dogs, eight cows, sixteen chickens and four goats.
level_one = World.level_one

level_two = World.level_two

expect [Dog, Cow, Chicken, Goat].map(|k| of_kind(level_one, k).len()) == [16, 2, 0, 0]
expect [Dog, Cow, Chicken, Goat].map(|k| of_kind(level_two, k).len()) == [64, 8, 16, 4]
expect World.levels.keep_if(|lv| of_kind(lv, Dog).len() != (lv.park_tiles * lv.park_tiles * breeds).to_u64_wrap()).len() == 0

## The most of a kind any level has: the physics' room for it.
most : Kind -> U64
most = |kind| {
	var $n = 0
	for lv in World.levels {
		here = of_kind(lv, kind).len()
		if here > $n {
			$n = here
		} else {
			{}
		}
	}
	$n
}

## A critter's square's half side, in pixels.
half : Kind -> I64
half = |kind| match kind {
	Dog => dog_px // 2
	Cow => cow_px // 2
	Chicken => chicken_px // 2
	Goat => goat_px // 2
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

expect World.levels.keep_if(|lv| !no_overlap(park(lv))).len() == 0

## A kind's tag, by its name in `World.kinds`.
tag_of : Str -> Kind
tag_of = |name| {
	if name == "dog" {
		Dog
	} else if name == "cow" {
		Cow
	} else if name == "chicken" {
		Chicken
	} else if name == "goat" {
		Goat
	} else {
		crash "print_world.roc: a kind World.kinds names that the park does not lay out"
	}
}

kin_zon : [Breed, Herd, NoKin] -> Str
kin_zon = |k| match k {
	Breed => ".breed"
	Herd => ".herd"
	NoKin => ".none"
}

## Each kind in kind-number order: world.zon's `.kinds` (`Zon`), or
## world.js's `kinds` (`Js`), its count the most any level has.
looks : [Zon, Js] -> Str
looks = |form| {
	var $out = ""
	for k in World.kinds {
		$out = $out.concat(
			match form {
				Zon => "        .{ .name = \"${k.name}\", .px = ${k.px.to_str()}, .colour = \"${k.colour}\", .rank = ${k.rank.to_str()}, .kin = ${kin_zon(k.kin)}, .leash = ${if (k.leash) "true" else "false"} },\n"
				Js => "  { name: \"${k.name}\", px: ${k.px.to_str()}, colour: \"${k.colour}\", emoji: \"${k.emoji}\", rank: ${k.rank.to_str()}, count: ${most(tag_of(k.name)).to_str()} },\n"
			},
		)
	}
	$out
}

## Wish.kind_of numbers the kinds as `World.kinds` does: kind n is the nth
## there, every one named. (Here, not in Wish.roc, so the physics' Roc
## does not import the kinds' looks.)
expect {
	name_of = |k| match k {
		Dog => "dog"
		Cow => "cow"
		Chicken => "chicken"
		Goat => "goat"
	}
	var $names = []
	var $n = 0
	while $n < World.kinds.len() {
		$names = $names.append(name_of(Wish.kind_of($n.to_u8_wrap())))
		$n = $n + 1
	}
	$names == World.kinds.map(|l| l.name)
}

## One kind leashes, and the ranks are each kind's own.
expect World.kinds.keep_if(|k| k.leash).len() == 1
expect World.kinds.map(|k| k.rank).len() == World.kinds.len() and World.kinds.keep_if(|k| k.rank < 0 or k.rank >= World.kinds.len().to_i64_wrap()).len() == 0

expect World.kinds.len() == 4
expect half(Dog) * 2 == dog_px and half(Cow) * 2 == cow_px and half(Chicken) * 2 == chicken_px and half(Goat) * 2 == goat_px
expect !no_overlap([{ kind: Dog, x: 10, y: 10 }, { kind: Cow, x: 40, y: 30 }])

points : Level, Kind -> Str
points = |lv, kind| {
	var $out = ""
	for s in of_kind(lv, kind) {
		$out = $out.concat("                .{ .x = ${px(s.x).to_str()}, .y = ${px(s.y).to_str()} },\n")
	}
	$out
}

## Each level: world.zon's `.levels` (`Zon`), its geometry and each kind's
## spots in kind-number order; or world.js's `levels` (`Js`), its geometry
## and each kind's count there.
level_lines : [Zon, Js] -> Str
level_lines = |form| {
	var $out = ""
	for lv in World.levels {
		match form {
			Zon => {
				var $spots = ""
				for k in World.kinds {
					$spots = $spots.concat("            .{\n${points(lv, tag_of(k.name))}            },\n")
				}
				$out = $out.concat("        .{ .world_tiles = ${lv.world_tiles.to_str()}, .park = .{ .first = ${park_first(lv).to_str()}, .tiles = ${lv.park_tiles.to_str()} }, .spots = .{\n${$spots}        } },\n")
			}
			Js => {
				counts = World.kinds.map(|k| of_kind(lv, tag_of(k.name)).len().to_str())
				$out = $out.concat("  { world_tiles: ${lv.world_tiles.to_str()}, park_tiles: ${lv.park_tiles.to_str()}, counts: [${Str.join_with(counts, ", ")}] },\n")
			}
		}
	}
	$out
}

zon : Str
zon =
	\\// THE WORLD, printed by roc/print_world.roc (`zig build roc`): do not
	\\// edit; edit that and print it again. Read by src/play/world.zig.
	\\.{
	\\    .tile_px = ${tile_px.to_str()},
	\\    .world_tiles = ${world_tiles.to_str()},
	\\    .park = .{ .first = ${((world_tiles - park_tiles) // 2).to_str()}, .tiles = ${park_tiles.to_str()} },
	\\    .poop_px = ${poop_px.to_str()},
	\\    .kinds = .{
	\\${looks(Zon)}    },
	\\    .breeds = ${breeds.to_str()},
	\\    .cell_per_tile = ${cell_per_tile.to_str()},
	\\    .levels = .{
	\\${level_lines(Zon)}    },
	\\}
	\\

js : Str
js =
	\\// THE WORLD's numbers for the page, printed by roc/print_world.roc (`zig build
	\\// roc`): do not edit; edit that and print it again. The physics
	\\// reads the same world (src/play/world.zon); test_page_modules.mjs holds
	\\// these to the wasm's.
	\\export const tile_px = ${tile_px.to_str()};
	\\export const world_tiles = ${world_tiles.to_str()};
	\\export const park_tiles = ${park_tiles.to_str()};
	\\export const cow_count = ${of_kind(level_two, Cow).len().to_str()};
	\\export const dog_px = ${dog_px.to_str()};
	\\export const cow_px = ${cow_px.to_str()};
	\\export const chicken_px = ${chicken_px.to_str()};
	\\export const poop_px = ${poop_px.to_str()};
	\\export const breeds = ${breeds.to_str()};
	\\// Each kind of critter, its number its place here (roc/World.roc).
	\\export const kinds = [
	\\${looks(Js)}];
	\\// The levels, Level One first: each its world and park, in tiles, and how
	\\// many of each kind it lays out (roc/World.roc's `levels`).
	\\export const levels = [
	\\${level_lines(Js)}];
	\\

main! = |args| {
	match args {
		["zon"] => echo!(zon)
		["js"] => echo!(js)
		_ => crash "roc/print_world.roc: say `zon` or `js`"
	}
	Ok({})
}
