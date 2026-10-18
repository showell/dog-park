## THE RULES, in Roc: what a critter in the walk does about each moving
## critter it sees (docs/PHYSICS.md, decisions 21-24). `zig build roc` runs
## it (`roc roc/rules.roc -- zon`) and checks in what it prints,
## src/play/rules.zon, which src/play/rules.zig imports as `Rules`; the
## physics (physics.zig's `wishOf`) applies them, its geometry its own.
## Distances are in whole pixels; "distance" is the larger axis.

## One critter's answer to another it sees moving.
Rule : [
	## Nothing.
	Ignore,

	## Keep this far: away from it, by the shortfall inside the reach.
	Keep(I64),

	## The nearest one such is its anchor: it stays between `inner` and
	## `outer` of it, moving away inside and closing in outside.
	Herd({ inner : I64, outer : I64 }),

	## Close in to touching, from within this; from farther, nothing.
	Close(I64),
]

## How a critter takes what it sees: every moving critter's answer summed
## (`Each`), or its nearest moving critter's alone (`Nearest`; ties to the
## lower rank).
Gathers : [Each, Nearest]

## A critter's answers by who it sees: `kin`, a dog of its own breed (a
## dog's only: a cow has no breed, and sees every dog as `dog`); `dog`, any
## other dog; `cow`; `chicken`.
Sees : { gathers : Gathers, kin : Rule, dog : Rule, cow : Rule, chicken : Rule }

## A dog keeps this from a moving dog of another breed; a cow from any
## moving dog.
wary : I64
wary = 158

## A dog: room from every moving dog of another breed and every moving cow,
## and its place in the herd, against its anchor (the nearest moving dog of
## its breed). A chicken is never in motion in the walk.
dog : Sees
dog = {
	gathers: Each,
	kin: Herd({ inner: 42, outer: 70 }),
	dog: Keep(wary),
	cow: Keep(63),
	chicken: Ignore,
}

## A cow: its nearest moving critter alone decides. A dog, it keeps `wary`
## from it; a cow within 245 px (70% of a tile, the first layout's spacing
## between neighbouring cows, so cows as laid out no longer draw together
## on their own: Steve, 2026-10-15), it closes in to touching.
cow : Sees
cow = {
	gathers: Nearest,
	kin: Keep(wary),
	dog: Keep(wary),
	cow: Close(245),
	chicken: Ignore,
}

expect dog.kin == Herd({ inner: 42, outer: 70 })
expect cow.kin == cow.dog

zon_rule : Rule -> Str
zon_rule = |rule| match rule {
	Ignore => ".ignore"
	Keep(reach) => ".{ .keep = ${reach.to_str()} }"
	Herd({ inner, outer }) => ".{ .herd = .{ .inner = ${inner.to_str()}, .outer = ${outer.to_str()} } }"
	Close(reach) => ".{ .close = ${reach.to_str()} }"
}

zon_gathers : Gathers -> Str
zon_gathers = |g| match g {
	Each => ".each"
	Nearest => ".nearest"
}

zon_sees : Sees -> Str
zon_sees = |s| ".{ .gathers = ${zon_gathers(s.gathers)}, .kin = ${zon_rule(s.kin)}, .dog = ${zon_rule(s.dog)}, .cow = ${zon_rule(s.cow)}, .chicken = ${zon_rule(s.chicken)} }"

zon : Str
zon =
	\\// THE RULES, printed by roc/rules.roc (`zig build roc`): do not edit;
	\\// edit that and print it again. Read by src/play/rules.zig.
	\\.{
	\\    .dog = ${zon_sees(dog)},
	\\    .cow = ${zon_sees(cow)},
	\\}
	\\

main! = |args| {
	match args {
		["zon"] => echo!(zon)
		_ => crash "roc/rules.roc: say `zon`"
	}
	Ok({})
}
