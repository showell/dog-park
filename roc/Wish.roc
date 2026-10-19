## WHAT A CRITTER WANTS (docs/PHYSICS.md, decisions 21-24), in Roc: its
## wish, from the moving critters it sees, by the rules (Rules.roc). The
## walk (Walk.roc) takes it for each critter it visits, handing it only
## what the arithmetic needs: who each one is to the wisher, and the two
## vectors between them, already the short way round the world. All
## lengths are in 256ths of a pixel; a length is a vector's larger axis.

import Rules

Wish := [].{

	## One moving critter the wisher sees. `kind`: its `Kind` as physics.zig
	## numbers it (`kind_of` names it); `kin`: a dog of the wisher's own
	## breed, and the wisher a dog; `j`: its seen index, for ties (to the
	## lower); `half`: its square's half side; `ax, ay`: from it to the
	## wisher (away), `tx, ty`: from the wisher to it (toward). The two are
	## each other's negation but where an axis is half a world.
	Near : { ax : I32, ay : I32, half : I32, tx : I32, ty : I32, j : U16, kin : Bool, kind : U8 }

	## The wisher: its kind, as `Near`'s, and its square's half side.
	Me : { half : I32, kind : U8 }

	## A critter's kind. It crosses from the host as physics.zig's `Kind`
	## numbers it, and is named here, once: every rule by kind is a `match`,
	## so a kind added is one the compiler shows every rule missing.
	Kind : [Dog, Cow, Chicken]

	kind_of : U8 -> Kind
	kind_of = |code| match code {
		0 => Dog
		1 => Cow
		2 => Chicken
		_ => crash "a kind physics.zig's Kind does not number"
	}

	## What it wants: a step `x, y`, and its anchor, the `j` of the critter a
	## `Herd` answer chose, or -1.
	Out : { anchor : I32, x : I32, y : I32 }

	wish : Me, List(Near) -> Out
	wish = |me, near| {
		var $s = start
		for n in near {
			$s = add(me, $s, n)
		}
		finish(me, $s)
	}

	## **THE WISH AS A FOLD**: `start`, then `add` each moving critter, then
	## `finish`; for a caller that holds them otherwise than as a list
	## (Walk.roc, which makes each from its own lists as it goes). The state
	## is numbers only, and the anchor and the nearest are kept as what the
	## wish needs of them: in the walk's loop, a record, a tag or a call
	## carried round it is kept on the stack.
	##
	## The summed answers (`x`, `y`); the anchor (the nearest critter a `Herd`
	## answer named, by its `j`; -1, none), its distance and band, and the
	## vectors to and from it (`a_`); and for `Nearest`, the nearest so far
	## (`b_`; `b_d` -1, none yet), all it is to the wisher.
	State : {
		a_ax : I64,
		a_ay : I64,
		a_tx : I64,
		a_ty : I64,
		anchor : I64,
		anchor_d : I64,
		b_ax : I64,
		b_ay : I64,
		b_d : I64,
		b_half : I32,
		b_j : U16,
		b_kin : Bool,
		b_kind : U8,
		b_tx : I64,
		b_ty : I64,
		inner : I64,
		outer : I64,
		x : I64,
		y : I64,
	}

	start : State
	start = { a_ax: 0, a_ay: 0, a_tx: 0, a_ty: 0, anchor: -1, anchor_d: 0, b_ax: 0, b_ay: 0, b_d: -1, b_half: 0, b_j: 0, b_kin: Bool.False, b_kind: 0, b_tx: 0, b_ty: 0, inner: 0, outer: 0, x: 0, y: 0 }

	## The rules of a wisher of kind `kind`. A chicken is never in motion in
	## the walk, so it never wishes.
	sees_of : U8 -> Rules.Sees
	sees_of = |kind| match kind_of(kind) {
		Dog => Rules.dog
		Cow => Rules.cow
		Chicken => crash "a chicken has no wish: it is never in motion in the walk"
	}

	## The rule, as numbers, for who `n` is to the wisher.
	pick : Rules.Sees, Near -> Flat
	pick = |sees, n| flat(
		match kind_of(n.kind) {
			Dog => if (n.kin) sees.kin else sees.dog
			Cow => sees.cow
			Chicken => sees.chicken
		},
	)

	## One moving critter, `n`, taken in.
	add : Me, State, Near -> State
	add = |me, s, n| {
		sees = sees_of(me.kind)
		ax = n.ax.to_i64()
		ay = n.ay.to_i64()
		d = measure(ax, ay)
		match sees.gathers {
			Each => answer(s, pick(sees, n), me.half.to_i64(), n, d)
			Nearest => {
				if s.b_d < 0 or d < s.b_d or (d == s.b_d and n.j < s.b_j) {
					{ ..s, b_ax: ax, b_ay: ay, b_d: d, b_half: n.half, b_j: n.j, b_kin: n.kin, b_kind: n.kind, b_tx: n.tx.to_i64(), b_ty: n.ty.to_i64() }
				} else {
					s
				}
			}
		}
	}

	## The answer of rule `r` to `n`, `d` away, taken in.
	answer : State, Flat, I64, Near, I64 -> State
	answer = |s, r, half, n, d| {
		ax = n.ax.to_i64()
		ay = n.ay.to_i64()
		if r.code == 2 {
			j = n.j.to_i64()
			if s.anchor < 0 or d < s.anchor_d or (d == s.anchor_d and j < s.anchor) {
				{ ..s, anchor: j, anchor_d: d, inner: r.a, outer: r.b, a_ax: ax, a_ay: ay, a_tx: n.tx.to_i64(), a_ty: n.ty.to_i64() }
			} else {
				s
			}
		} else if r.code == 1 {
			if d <= r.a {
				w = away(ax, ay, r.a - d)
				{ ..s, x: s.x + w.x, y: s.y + w.y }
			} else {
				s
			}
		} else if r.code == 3 {
			touch = half + n.half.to_i64()
			if d > touch and d <= r.a {
				w = along(n.tx.to_i64(), n.ty.to_i64(), d - touch)
				{ ..s, x: s.x + w.x, y: s.y + w.y }
			} else {
				s
			}
		} else {
			s
		}
	}

	## The wish, from all taken in: for `Nearest`, the nearest's answer;
	## then the anchor's band.
	finish : Me, State -> Out
	finish = |me, s0| {
		s = if s0.b_d < 0 {
			s0
		} else {
			n = { ax: s0.b_ax.to_i32_wrap(), ay: s0.b_ay.to_i32_wrap(), half: s0.b_half, tx: s0.b_tx.to_i32_wrap(), ty: s0.b_ty.to_i32_wrap(), j: s0.b_j, kin: s0.b_kin, kind: s0.b_kind }
			answer(s0, pick(sees_of(me.kind), n), me.half.to_i64(), n, s0.b_d)
		}
		band = if s.anchor < 0 {
			{ x: 0, y: 0 }
		} else if s.anchor_d > s.outer {
			along(s.a_tx, s.a_ty, s.anchor_d - s.outer)
		} else if s.anchor_d < s.inner {
			away(s.a_ax, s.a_ay, s.inner - s.anchor_d)
		} else {
			{ x: 0, y: 0 }
		}
		{ anchor: s.anchor.to_i32_wrap(), x: (s.x + band.x).to_i32_wrap(), y: (s.y + band.y).to_i32_wrap() }
	}

	## A rule as numbers: `code` 0 `Ignore`, 1 `Keep` (`a` its reach), 2
	## `Herd` (`a`, `b` its band's edges), 3 `Close` (`a` its reach); in
	## 256ths.
	Flat : { a : I64, b : I64, code : U8 }

	flat : Rules.Rule -> Flat
	flat = |rule| match rule {
		Ignore => { a: 0, b: 0, code: 0 }
		Keep(reach) => { a: px(reach), b: 0, code: 1 }
		Herd({ inner, outer }) => { a: px(inner), b: px(outer), code: 2 }
		Close(reach) => { a: px(reach), b: 0, code: 3 }
	}

	## Whole pixels to 256ths.
	px : I64 -> I64
	px = |n| n * 256

	## A vector's length: its larger axis.
	measure : I64, I64 -> I64
	measure = |x, y| {
		mx = x.abs()
		my = y.abs()
		if (mx > my) mx else my
	}

	## A wish `length` long along `(vx, vy)`: each axis times the length,
	## divided by the vector's length, truncated toward zero.
	along : I64, I64, I64 -> { x : I64, y : I64 }
	along = |vx, vy, length| {
		l = measure(vx, vy)
		{ x: vx * length // l, y: vy * length // l }
	}

	## A wish `length` long along the away vector; east when the critters'
	## centres coincide.
	away : I64, I64, I64 -> { x : I64, y : I64 }
	away = |vx, vy, length| if (vx == 0 and vy == 0) { x: length, y: 0 } else along(vx, vy, length)
}

## Pure-Roc checks of the wish, in 256ths (158 px is 40448).
dog_me = { half: 14 * 256, kind: 0 }

cow_me = { half: 21 * 256, kind: 1 }

nb = |kind, kin, j, x, y| { ax: -x, ay: -y, half: if (kind == 1) 21 * 256 else 14 * 256, tx: x, ty: y, j: j, kin: kin, kind: kind }

## The kinds as physics.zig's `Kind` numbers them.
expect Wish.kind_of(0) == Dog and Wish.kind_of(1) == Cow and Wish.kind_of(2) == Chicken

## Alone, a critter wants nothing.
expect Wish.wish(dog_me, []) == { anchor: -1, x: 0, y: 0 }

## A dog of another breed 100 px east: room `wary` (158 px) from it, so 58 px
## west.
expect Wish.wish(dog_me, [nb(0, Bool.False, 3, 100 * 256, 0)]) == { anchor: -1, x: -58 * 256, y: 0 }

## Farther than `wary`, nothing.
expect Wish.wish(dog_me, [nb(0, Bool.False, 3, 200 * 256, 0)]) == { anchor: -1, x: 0, y: 0 }

## Its kin 100 px east is its anchor, past the band's outer edge (70 px): it
## closes the 30 px.
expect Wish.wish(dog_me, [nb(0, Bool.True, 5, 100 * 256, 0)]) == { anchor: 5, x: 30 * 256, y: 0 }

## Of two kin the nearer anchors; at an equal distance, the lower index.
expect Wish.wish(dog_me, [nb(0, Bool.True, 9, 60 * 256, 0), nb(0, Bool.True, 4, 0, 60 * 256)]).anchor == 4

## A cow heeds only its nearest: a cow 100 px east (within 245) draws it
## toward touching (42 px apart), though a dog 150 px west would scare it.
expect Wish.wish(cow_me, [nb(1, Bool.False, 2, 100 * 256, 0), nb(0, Bool.False, 7, -150 * 256, 0)]) == { anchor: -1, x: 58 * 256, y: 0 }

## Coinciding centres: away is east.
expect Wish.wish(dog_me, [nb(0, Bool.False, 3, 0, 0)]) == { anchor: -1, x: 158 * 256, y: 0 }

## Inside the band's inner edge (42 px), it opens the shortfall: kin 30 px
## east, so 12 px west; in the band (42 to 70), content.
expect Wish.wish(dog_me, [nb(0, Bool.True, 5, 30 * 256, 0)]) == { anchor: 5, x: -12 * 256, y: 0 }
expect Wish.wish(dog_me, [nb(0, Bool.True, 5, 55 * 256, 0)]) == { anchor: 5, x: 0, y: 0 }

## A dog keeps 63 px from a cow, and the rooms add: a cow 50 px north and
## a dog of another breed 150 px east, so 13 px south and 8 px west.
expect Wish.wish(dog_me, [nb(1, Bool.False, 2, 0, -50 * 256), nb(0, Bool.False, 3, 150 * 256, 0)]) == { anchor: -1, x: -8 * 256, y: 13 * 256 }

## The room and the anchor together: kin 100 px east (closes 30) and a dog
## of another breed 150 px east (8 west): 22 px east.
expect Wish.wish(dog_me, [nb(0, Bool.True, 5, 100 * 256, 0), nb(0, Bool.False, 3, 150 * 256, 0)]) == { anchor: 5, x: 22 * 256, y: 0 }

## A chicken is nothing to a dog.
expect Wish.wish(dog_me, [nb(2, Bool.False, 40, 10 * 256, 0)]) == { anchor: -1, x: 0, y: 0 }

## A cow touching (42 px) or past its pull (245 px) is drawn no closer; a
## dog nearest, it flees by the shortfall inside `wary`.
expect Wish.wish(cow_me, [nb(1, Bool.False, 2, 42 * 256, 0)]) == { anchor: -1, x: 0, y: 0 }
expect Wish.wish(cow_me, [nb(1, Bool.False, 2, 246 * 256, 0)]) == { anchor: -1, x: 0, y: 0 }
expect Wish.wish(cow_me, [nb(0, Bool.False, 7, 0, 100 * 256)]) == { anchor: -1, x: 0, y: -58 * 256 }

## A cow's nearest, at an equal distance, is the lower index: the cow (2,
## east) before the dog (7, north), so it closes in east rather than flees
## south.
expect Wish.wish(cow_me, [nb(0, Bool.False, 7, 0, -100 * 256), nb(1, Bool.False, 2, 100 * 256, 0)]) == { anchor: -1, x: 58 * 256, y: 0 }

## A wish along a diagonal is each axis scaled and truncated toward zero:
## a dog of another breed 100 px east and 37 px south, 58 px short, so
## -58 px and -(37 * 58 / 100) px, truncated: -21.46 px is -5493 256ths.
expect Wish.wish(dog_me, [nb(0, Bool.False, 3, 100 * 256, 37 * 256)]) == { anchor: -1, x: -58 * 256, y: -5493 }

## The vectors as given: the away vector is used for room, the toward one
## for closing in, so at half a world (where both point the same way) each
## rule reads its own.
expect Wish.wish(dog_me, [{ ax: 100 * 256, ay: 0, half: 14 * 256, tx: 100 * 256, ty: 0, j: 3, kin: Bool.False, kind: 0 }]) == { anchor: -1, x: 58 * 256, y: 0 }

## The pull reaches its edge: a cow exactly 245 px east draws it.
expect Wish.wish(cow_me, [nb(1, Bool.False, 2, 245 * 256, 0)]) == { anchor: -1, x: 203 * 256, y: 0 }
