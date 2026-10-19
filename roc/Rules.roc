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

	## The kinds, by the tags the rules name them with: World.roc's `kinds`,
	## in its order (Wish.roc's `kind_of` numbers them so).
	Kind : [Dog, Cow, Chicken]

	## A dog keeps this from a moving dog of another breed; a cow from any
	## moving dog.
	wary : I64
	wary = 158

	## **HOW A KIND MOVES IN THE WALK**: how it takes what it sees, and its
	## pace (in each pixel-tick of the walk it steps at most this share of
	## the leashed dog's step); or it is never in motion there (`Still`).
	## - A dog takes every moving critter's answer, and keeps pace.
	## - A cow takes its nearest moving critter's alone, at half the pace.
	## - A chicken is never in motion in the walk (it forages, after it).
	Mover : { gathers : Gathers, pace : Share }

	mover : Kind -> [Moves(Mover), Still]
	mover = |kind| match kind {
		Dog => Moves({ gathers: Each, pace: { num: 1, den: 1 } })
		Cow => Moves({ gathers: Nearest, pace: { num: 1, den: 2 } })
		Chicken => Still
	}

	## Whether a kind moves in the walk (`mover` says how), as a match of its
	## own: the walk asks it of every critter it lines up, and a record built
	## there costs (docs/ROC-SPEED.md).
	walks : Kind -> Bool
	walks = |kind| match kind {
		Dog => Bool.True
		Cow => Bool.True
		Chicken => Bool.False
	}

	## **THE RULES BY PAIR OF KINDS**: the answer of a moving critter of kind
	## `wisher` to one of kind `seen` it sees moving, `kin` when the two are
	## kin (World.roc's `kin`: a dog of its own breed; every cow to every
	## cow). Every pair is said, with no `_`: a kind added is a set of pairs
	## the compiler lists to fill.
	## - A dog: its place in the herd against its anchor, the nearest moving
	##   dog of its breed; room `wary` from a dog of another breed, and 63 px
	##   from a cow.
	## - A cow: `wary` from a dog; a cow within 245 px (70% of a tile, the
	##   first layout's spacing between neighbouring cows, so cows as laid
	##   out no longer draw together on their own: Steve, 2026-10-15), it
	##   closes in to touching.
	## - Neither heeds a chicken, and a chicken (never in motion in the walk)
	##   answers nobody.
	rule : Kind, Kind, Bool -> Rule
	rule = |wisher, seen, kin| match (wisher, seen) {
		(Dog, Dog) => if (kin) Herd({ inner: 42, outer: 70 }) else Keep(wary)
		(Dog, Cow) => Keep(63)
		(Dog, Chicken) => Ignore
		(Cow, Dog) => Keep(wary)
		(Cow, Cow) => Close(245)
		(Cow, Chicken) => Ignore
		(Chicken, Dog) => Ignore
		(Chicken, Cow) => Ignore
		(Chicken, Chicken) => Ignore
	}

	## **THE FORAGE** (decision 31), a behaviour a kind may have (Wish.roc's
	## `forage_of` says which do: today the chickens): once a tick, after
	## the drag, a forager steps toward the nearest ripe poop it sees within
	## `sight`; with none, home, when it is more than `home_band` from it. It
	## steps at most `step`, and at most `pace` of the leashed dog's net move
	## over the tick (so a still dog stills it), then eats the ripe poop it
	## stands on. A forager heeds no critter.
	Forage : { sight : I64, step : I64, pace : Share, home_band : I64 }

	## The chickens' forage.
	chickens : Forage
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
expect Rules.chickens.pace.den > 0
expect [Dog, Cow, Chicken].map(
	|k| Rules.walks(k) == (
		match Rules.mover(k) {
			Moves(_) => Bool.True
			Still => Bool.False
		}
	),
) == [Bool.True, Bool.True, Bool.True]
expect [Dog, Cow, Chicken].map(
	|k| match Rules.mover(k) {
		Moves(m) => m.pace.den > 0
		Still => Bool.True
	},
) == [Bool.True, Bool.True, Bool.True]
