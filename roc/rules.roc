## THE RULES, in Roc: what a critter in the walk does about each moving
## critter it sees (docs/PHYSICS.md, decisions 21-24), how fast it goes,
## the chickens' foraging and the herd's poop (decisions 29, 31). `zig build roc` runs
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

## A share of a step, `num` over `den`, rounded toward zero.
Share : { num : I64, den : I64 }

## A critter's answers by who it sees: `kin`, a dog of its own breed (a
## dog's only: a cow has no breed, and sees every dog as `dog`); `dog`, any
## other dog; `cow`; `chicken`. And its pace: in each pixel-tick of the
## walk, it steps at most this share of the leashed dog's step.
Sees : { gathers : Gathers, kin : Rule, dog : Rule, cow : Rule, chicken : Rule, pace : Share }

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
	pace: { num: 1, den: 1 },
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
	pace: { num: 1, den: 2 },
}

## THE CHICKENS' TURN (decision 31): once a tick, after the drag, each
## chicken steps toward the nearest ripe poop it sees within `sight`;
## with none, home, when it is more than `home_band` from it. It steps at
## most `step`, and at most `pace` of the leashed dog's net move over the
## tick (so a still dog stills them), then eats the ripe poop it stands
## on. A chicken heeds no critter.
Chickens : { sight : I64, step : I64, pace : Share, home_band : I64 }

chickens : Chickens
chickens = { sight: 500, step: 8, pace: { num: 1, den: 2 }, home_band: 32 }

## POOP (decision 29): the herd poops each time the leashed dog has walked
## another `every` (each step counted by its larger axis): its deepest dog,
## `back` behind itself. Where that spot is taken, the nearest free one on
## rings `grid` apart around it, out to `reach`; with none, no poop. The
## park keeps `slots` poops, taken in turn: the newest is never ripe.
Poop : { every : I64, back : I64, reach : I64, grid : I64, slots : I64 }

poop : Poop
poop = { every: 700, back: 30, reach: 200, grid: 4, slots: 2048 }

## The physics counts poops laid in 32 bits and takes slots in turn, so the
## slots are a power of two (the count's wrap keeps their order).
is_power_of_two : I64 -> Bool
is_power_of_two = |n| {
	var $k = 1
	while $k < n {
		$k = $k * 2
	}
	$k == n
}

expect is_power_of_two(poop.slots) and poop.slots <= 65536
expect poop.grid > 0 and poop.reach % poop.grid == 0
expect chickens.pace.den > 0 and dog.pace.den > 0 and cow.pace.den > 0

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

zon_share : Share -> Str
zon_share = |sh| ".{ .num = ${sh.num.to_str()}, .den = ${sh.den.to_str()} }"

zon_sees : Sees -> Str
zon_sees = |s| ".{ .gathers = ${zon_gathers(s.gathers)}, .kin = ${zon_rule(s.kin)}, .dog = ${zon_rule(s.dog)}, .cow = ${zon_rule(s.cow)}, .chicken = ${zon_rule(s.chicken)}, .pace = ${zon_share(s.pace)} }"

zon_chickens : Chickens -> Str
zon_chickens = |c| ".{ .sight = ${c.sight.to_str()}, .step = ${c.step.to_str()}, .pace = ${zon_share(c.pace)}, .home_band = ${c.home_band.to_str()} }"

zon_poop : Poop -> Str
zon_poop = |p| ".{ .every = ${p.every.to_str()}, .back = ${p.back.to_str()}, .reach = ${p.reach.to_str()}, .grid = ${p.grid.to_str()}, .slots = ${p.slots.to_str()} }"

zon : Str
zon =
	\\// THE RULES, printed by roc/rules.roc (`zig build roc`): do not edit;
	\\// edit that and print it again. Read by src/play/rules.zig.
	\\.{
	\\    .dog = ${zon_sees(dog)},
	\\    .cow = ${zon_sees(cow)},
	\\    .chickens = ${zon_chickens(chickens)},
	\\    .poop = ${zon_poop(poop)},
	\\}
	\\

main! = |args| {
	match args {
		["zon"] => echo!(zon)
		_ => crash "roc/rules.roc: say `zon`"
	}
	Ok({})
}
