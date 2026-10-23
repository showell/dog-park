## DOG PARK ON ROC-RAY: the game as a native program, on its own. Level
## One laid out by Layout.roc and walked by the physics' own Roc
## (Walk.roc's `pixel_tick`, the walk and the wish in it); no server judges
## it. Press a dog to leash it and drag: each pixel the pointer moves is a
## pixel-tick, until the dog bumps; let go and the leash goes too.
##
## roc-ray is a sibling checkout of dog-park (`../../roc-ray`), as roc-apps'
## canvas apps name it. Built for Windows by .github/workflows/native.yml.
app [Model, program] { rr: platform "../../roc-ray/platform/main.roc" }

import rr.App
import rr.Capture
import rr.Color
import rr.Draw
import rr.Task
import Layout
import Walk
import World

level : World.Level
level = World.level_one

## The world, in whole pixels and in the walk's 256ths, and the cells it is
## kept by.
world_px : I64
world_px = level.world_tiles * World.tile_px

world : I32
world = (world_px * 256).to_i32_wrap()

side : I32
side = (level.world_tiles * World.cell_per_tile).to_i32_wrap()

geo : Walk.Geo
geo = Walk.geo_of(side)

## The window: the whole world as a square `view` across, as big as the
## window allows (`view_of`), and a band under it for words. It opens at
## `view_start`; whatever size the screen or its scaling makes it, the
## drawing and the clicks follow (a fixed 840 by 910 ran off a laptop's
## screen, and the park with it).
band_px : F32
band_px = 50

view_start : F32
view_start = 640

view_of : I32, I32 -> F32
view_of = |width, height| {
	w = width.to_f32()
	h = height.to_f32() - band_px
	if (w < h) w else h
}

scale_of : F32 -> F32
scale_of = |view| view / world_px.to_f32()

## A kind's number, as World.kinds and the walk number it.
kind_of : Layout.Kind -> U8
kind_of = |k| match k {
	Dog => 0
	Cow => 1
	Chicken => 2
	Goat => 3
}

px_of : Layout.Kind -> I64
px_of = |k| match k {
	Dog => World.dog_px
	Cow => World.cow_px
	Chicken => World.chicken_px
	Goat => World.goat_px
}

## Who nudges whom: a dog its breed (dog n is breed n mod the breeds), each
## herd kind its own number after the breeds, a chicken nobody.
no_kin : U8
no_kin = 255

## A level's park as it starts: every critter in Layout's order, which is
## the order this game keeps them in (`crits`).
start_crits : World.Level -> List(Walk.Crit)
start_crits = |lv| {
	var $out = []
	var $dogs = 0
	for s in Layout.park(lv) {
		kin = match s.kind {
			Dog => ($dogs % World.breeds).to_u8_wrap()
			Cow => World.breeds.to_u8_wrap()
			Goat => (World.breeds + 1).to_u8_wrap()
			Chicken => no_kin
		}
		$out = $out.append({
			half: (px_of(s.kind) // 2 * 256).to_i32_wrap(),
			key: Walk.not_lined_up,
			kin,
			kind: kind_of(s.kind),
			x: (s.x * 256).to_i32_wrap(),
			y: (s.y * 256).to_i32_wrap(),
		})
		if s.kind == Dog {
			$dogs = $dogs + 1
		} else {
			{}
		}
	}
	$out
}

Vec : { x : F32, y : F32 }

Model : {
	crits : List(Walk.Crit),

	## The world's square on the screen, its side (`view_of` the window).
	view : F32,

	## The leashed dog, by its index in `crits`; -1, none.
	leashed : I64,
	dragging : Bool,

	## The pointer where the drag last took it, and the part of a 256th the
	## drag has not yet moved.
	pointer : Vec,
	carry : Vec,

	## How far the leashed dog has walked (the poop comes due by it), and
	## the poops laid.
	walked : U32,
	laid : U32,
	poops : List(Walk.Poop),
	note : Str,
}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default.with_title("Dog Park").with_size({ width: view_start.to_i32_wrap(), height: (view_start + band_px).to_i32_wrap() }).with_output_dir("shots"),
	|io| {
		crits = start_crits(level)
		_ = io.stdout().line!(diagnose(crits))
		Ok({
			crits,
			view: view_start,
			leashed: -1,
			dragging: Bool.False,
			pointer: { x: 0, y: 0 },
			carry: { x: 0, y: 0 },
			walked: 0,
			laid: 0,
			poops: [],
			note: "",
		})
	},
)

## **WHAT THIS BUILD COMPUTES**, printed once at the start: the numbers and
## the loops the drawing and the clicks stand on (the scale, the tiles the
## drawing's loops visit, where dog 0 is drawn, and whom a click there
## finds), so a build that draws nothing says why without a window.
diagnose : List(Walk.Crit) -> Str
diagnose = |crits| {
	var $tiles = 0
	var $row = 0
	while $row < level.world_tiles {
		var $col = 0
		while $col < level.world_tiles {
			$tiles = $tiles + 1
			$col = $col + 1
		}
		$row = $row + 1
	}
	first = get_crit(crits, 0)
	s = on_screen(view_start, Walk.pt(first))
	back = dog_at(crits, to_world(view_start, s))
	"native: scale ${scale_of(view_start).to_str()}, ${crits.len().to_str()} critters, ${$tiles.to_str()} tiles by the loops, dog 0 at (${first.x.to_str()}, ${first.y.to_str()}) drawn at (${s.x.to_str()}, ${s.y.to_str()}), a click there finds dog ${back.to_str()}"
}

## A screenshot finished (S saves one, shots/shot.png: how the build's
## windowed run on the runner shows what it draws).
Msg : [Shot(Try({}, Capture.ScreenshotError))]

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model0, input, io| {
	model = { ..model0, view: view_of(input.window.size.width, input.window.size.height) }
	if input.devices.key_pressed(KeyS) {
		Task.spawn!(input, || Shot(io.capture().screenshot!("shot.png")))
	}
	mouse = input.devices.mouse
	p = mouse.position()
	if mouse.button_pressed(Left) {
		hit = dog_at(model.crits, to_world(model.view, p))
		Ok({ ..model, leashed: hit, dragging: hit >= 0, pointer: p, carry: { x: 0, y: 0 }, note: "" })
	} else if mouse.button_released(Left) {
		Ok({ ..model, leashed: -1, dragging: Bool.False })
	} else if model.dragging and mouse.button_down(Left) {
		fx = (p.x - model.pointer.x) / scale_of(model.view) * 256 + model.carry.x
		fy = (p.y - model.pointer.y) / scale_of(model.view) * 256 + model.carry.y
		dx = capped(fx.to_i32_wrap())
		dy = capped(fy.to_i32_wrap())
		moved = drag({ ..model, pointer: p, carry: { x: fx - dx.to_f32(), y: fy - dy.to_f32() } }, dx, dy)
		Ok(moved)
	} else {
		Ok(model)
	}
}

## At most 100 pixels a host cycle on each axis, as the physics caps a
## tick's drag.
capped : I32 -> I32
capped = |v| if v > 25600 25600 else if v < -25600 -25600 else v

to_world : F32, Vec -> Walk.Pt
to_world = |view, p| {
	s = scale_of(view)
	{ x: (p.x / s * 256).to_i32_wrap(), y: (p.y / s * 256).to_i32_wrap() }
}

## The dog whose square holds point `w` (its index in `crits`), or -1.
dog_at : List(Walk.Crit), Walk.Pt -> I64
dog_at = |crits, w| {
	var $hit = -1
	var $i = 0
	for c in crits {
		d = Walk.delta(geo, Walk.pt(c), w)
		if c.kind == 0 and d.x.abs() <= c.half and d.y.abs() <= c.half {
			$hit = $i
		} else {
			{}
		}
		$i = $i + 1
	}
	$hit
}

## **THE DRAG**: `dx` then `dy`, in 256ths, cut into pixel-ticks of at most a
## pixel (the `i`th of `n` to `part * i / n`, toward zero), each one
## `pixel_tick`, until the leashed dog bumps.
drag : Model, I32, I32 -> Model
drag = |model0, dx, dy| {
	var $m = model0
	var $axis = 0
	while $axis < 2 and $m.dragging {
		part = (if ($axis == 0) dx else dy).to_i64()
		n = ((if (part < 0) 0 - part else part) + 255) // 256
		var $done = 0
		var $i = 1
		while $i <= n and $m.dragging {
			now = part * $i // n
			inc = (now - $done).to_i32_wrap()
			$done = now
			if inc != 0 {
				$m = pixel_tick($m, $axis, inc)
			} else {
				{}
			}
			$i = $i + 1
		}
		$axis = $axis + 1
	}
	$m
}

## The critters in the order the walk takes them: the leashed dog, then
## every other kind by kind number's rank (cows, dogs, chickens, goats),
## each in `crits` order.
seen_order : List(Walk.Crit), I64 -> List(U64)
seen_order = |crits, leashed| {
	var $order = [leashed.to_u64_wrap()]
	for k in [1, 0, 2, 3] {
		var $i = 0
		for c in crits {
			if c.kind == k and $i.to_i64_wrap() != leashed {
				$order = $order.append($i)
			} else {
				{}
			}
			$i = $i + 1
		}
	}
	$order
}

## One pixel-tick: the critters lent to the walk in its order, keyed as it
## starts (the leashed dog visited), filed into fresh cells, the poops by
## tile; what it moved put back, the poop it laid kept, a bump ending the
## drag.
pixel_tick : Model, I32, I32 -> Model
pixel_tick = |m, axis, inc| {
	order = seen_order(m.crits, m.leashed)
	seen = order.map(
		|j| {
			c = get_crit(m.crits, j)
			{ ..c, key: if (j.to_i64_wrap() == m.leashed) Walk.visited else Walk.not_lined_up }
		},
	)
	n = seen.len()
	words = (n + 63) // 64
	cells = List.repeat(0, (side * side).to_u64_wrap() * words)
	park = Walk.filed(geo, { cells, crits: seen })
	r = Walk.pixel_tick(lend_poops(m.poops), { depth: List.repeat(0, n), moving: [], park }, axis, inc, m.walked, m.laid)
	moved = r.walk.work.park.crits
	var $crits = m.crits
	var $k = 0
	for j in order {
		$crits = put_crit($crits, j, get_crit(moved, $k))
		$k = $k + 1
	}
	walked_sum = m.walked.to_u64() + r.walked.to_u64_wrap()
	walked = if (walked_sum > 4294967295) 4294967295 else walked_sum.to_u32_wrap()
	laid_one = r.poop.slot >= 0
	poops = if laid_one {
		slot = r.poop.slot.to_u16_wrap()
		m.poops.keep_if(|q| q.slot != slot).append({ slot, x: r.poop.x, y: r.poop.y })
	} else {
		m.poops
	}
	bumped = r.bump.kind != Walk.bump_none
	{
		..m,
		crits: $crits,
		walked,
		laid: if (laid_one) m.laid + 1 else m.laid,
		poops,
		dragging: !bumped,
		note: if (bumped) "Bump! Press a dog to go on." else m.note,
	}
}

## The poops by tile, as the walk reads them: tile `t`'s at
## `poops[from[t] .. from[t + 1]]`, row by row from the world's (0, 0), and
## in slot order on each.
lend_poops : List(Walk.Poop) -> Walk.Lent
lend_poops = |poops| {
	tiles_n = level.world_tiles * level.world_tiles
	var $from = []
	var $out = []
	var $t = 0
	while $t < tiles_n {
		$from = $from.append($out.len().to_u16_wrap())
		var $here = []
		for p in poops {
			if tile_of(p) == $t {
				$here = $here.append(p)
			} else {
				{}
			}
		}
		$out = $out.concat(by_slot($here))
		$t = $t + 1
	}
	{ from: $from.append($out.len().to_u16_wrap()), poops: $out, side }
}

tile_of : Walk.Poop -> I64
tile_of = |p| (p.y // Walk.tile).to_i64() * level.world_tiles + (p.x // Walk.tile).to_i64()

## A few poops in slot order (an insertion sort: a tile holds a handful).
by_slot : List(Walk.Poop) -> List(Walk.Poop)
by_slot = |ps| {
	var $out = []
	for p in ps {
		var $before = []
		var $after = []
		for q in $out {
			if q.slot < p.slot {
				$before = $before.append(q)
			} else {
				$after = $after.append(q)
			}
		}
		$out = $before.append(p).concat($after)
	}
	$out
}

get_crit : List(Walk.Crit), U64 -> Walk.Crit
get_crit = |l, j| match l.get(j) {
	Ok(c) => c
	Err(_) => crash "native: no critter there"
}

put_crit : List(Walk.Crit), U64, Walk.Crit -> List(Walk.Crit)
put_crit = |l, j, c| match l.set(j, c) {
	Ok(m) => m
	Err(_) => crash "native: no critter there"
}

## **THE HERD**: the two cows within two cow-widths of each other, round
## the torus, Level One's win.
herded : List(Walk.Crit) -> Bool
herded = |crits| {
	cows = crits.keep_if(|c| c.kind == 1)
	match (cows.get(0), cows.get(1)) {
		(Ok(a), Ok(b)) => Walk.measure(Walk.delta(geo, Walk.pt(a), Walk.pt(b))) <= (2 * World.cow_px * 256).to_i32_wrap()
		_ => Bool.False
	}
}

## ── drawing ──

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x2b3a24))
	first = Layout.park_first(level)
	scale = scale_of(model.view)
	tile_on = World.tile_px.to_f32() * scale
	var $row = 0
	while $row < level.world_tiles {
		var $col = 0
		while $col < level.world_tiles {
			in_park = $col >= first and $col < first + level.park_tiles and $row >= first and $row < first + level.park_tiles
			colour = if !in_park {
				Color.from_hex_rgb(0x9cc58a)
			} else if ($col + $row) % 2 == 0 {
				Color.from_hex_rgb(0xf4f1e8)
			} else {
				Color.from_hex_rgb(0xcfe3f3)
			}
			frame.rectangle!({ x: $col.to_f32() * tile_on, y: $row.to_f32() * tile_on, width: tile_on, height: tile_on, style: Draw.filled(colour) })
			$col = $col + 1
		}
		$row = $row + 1
	}
	poop_r = World.poop_px.to_f32() / 2 * scale
	for p in model.poops {
		frame.circle!({ center: on_screen(model.view, { x: p.x, y: p.y }), radius: poop_r, style: Draw.filled(Color.from_hex_rgb(0x6b4a2b)) })
	}
	var $i = 0.I64
	for c in model.crits {
		at = on_screen(model.view, Walk.pt(c))
		h = c.half.to_f32() / 256 * scale
		if $i == model.leashed {
			frame.rectangle!({ x: at.x - h - 3, y: at.y - h - 3, width: 2 * h + 6, height: 2 * h + 6, style: Draw.filled(Color.from_hex_rgb(0x111111)) })
		} else {
			{}
		}
		frame.rectangle!({ x: at.x - h, y: at.y - h, width: 2 * h, height: 2 * h, style: Draw.filled(look(c)) })
		$i = $i + 1
	}
	words = if herded(model.crits) {
		"You have herded both cows!"
	} else if model.note != "" {
		model.note
	} else {
		"Press a dog and drag it. Herd the two cows together."
	}
	frame.text_at!({ pos: { x: 14, y: model.view + 14 }, text: words, size: 20, color: Color.from_hex_rgb(0xf4f1e8) })
	Ok({})
}

on_screen : F32, Walk.Pt -> Vec
on_screen = |view, p| {
	s = scale_of(view)
	x = Walk.around(p.x, world)
	y = Walk.around(p.y, world)
	{ x: x.to_f32() / 256 * s, y: y.to_f32() / 256 * s }
}

## A dog's colour is its breed's; a cow is dark.
look : Walk.Crit -> Color.Rgba
look = |c| {
	if c.kind == 1 {
		Color.from_hex_rgb(0x4a4a4a)
	} else if c.kin == 0 {
		Color.from_hex_rgb(0xa0522d)
	} else if c.kin == 1 {
		Color.from_hex_rgb(0xd2a24c)
	} else if c.kin == 2 {
		Color.from_hex_rgb(0x2f2f2f)
	} else {
		Color.from_hex_rgb(0xe8e0d0)
	}
}

expect start_crits(World.level_one).len() == 18
expect start_crits(World.level_one).keep_if(|c| c.kind == 1).len() == 2
expect !herded(start_crits(World.level_one))
expect seen_order(start_crits(World.level_one), 0).len() == 18
expect start_crits(World.level_two).len() == 64 + 8 + 16 + 4
