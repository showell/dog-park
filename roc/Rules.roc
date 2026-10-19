## THE RULES, as a Roc module: what a critter in the walk does about each
## moving critter it sees (docs/PHYSICS.md, decisions 21-24), how fast it
## goes, the chickens' foraging and the herd's poop (decisions 29, 31).
## Two read it: roc/rules.roc prints it for the physics' Zig
## (src/play/rules.zon), and Wish.roc answers by it inside the physics.
## Distances are in whole pixels; "distance" is the larger axis.
Rules := [].{

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

	## THE WALK'S LIMITS (decisions 20, 25): one pixel-tick's walk visits
	## at most `most` critters; one step moves at most `nudge_most` together
	## (the stepper and the kin it nudges) and shoves at most as many
	## chickens; a wish shorter than `dead_zone` pixels is no step. The
	## physics' Zig sizes its walk's room by these (rules.zon).
	Limits : { most : I64, nudge_most : I64, dead_zone : I64 }

	limits : Limits
	limits = { most: 48, nudge_most: 8, dead_zone: 1 }

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
}

expect Rules.is_power_of_two(Rules.poop.slots) and Rules.poop.slots <= 65536
expect Rules.poop.grid > 0 and Rules.poop.reach % Rules.poop.grid == 0
expect Rules.chickens.pace.den > 0 and Rules.dog.pace.den > 0 and Rules.cow.pace.den > 0
