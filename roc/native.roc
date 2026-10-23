## DOG PARK ON ROC-RAY: the game as a native program, on its own, played as
## the page plays it (solo/park.js, engine.js, pointer.js, scene.js). The
## physics is Game.roc's tick over the physics' own walk, 16 ticks a second;
## no server judges it. Press a dog to leash it and drag: the pointer's
## moves are the tick's drag, capped at 100 px an axis; let go and the dog
## stays leashed till its timer runs out or another is pressed. Drag the
## ground to look round the park; a held dog near the window's edge scrolls
## it. Herd every cow into one group to win, and go on to the next level.
##
## roc-ray is a sibling checkout of dog-park (`../../roc-ray`), as roc-apps'
## canvas apps name it. Built for Windows by .github/workflows/native.yml.
app [Model, program] { rr: platform "../../roc-ray/platform/main.roc" }

import rr.App
import rr.Assets
import rr.Capture
import rr.Color
import rr.Draw
import rr.Math
import rr.Task
import Game
import Walk
import World
import "art/1f415.png" as dog_0_png : List(U8)
import "art/1f429.png" as dog_1_png : List(U8)
import "art/1f9ae.png" as dog_2_png : List(U8)
import "art/1f415-200d-1f9ba.png" as dog_3_png : List(U8)
import "art/1f404.png" as cow_png : List(U8)
import "art/1f413.png" as chicken_png : List(U8)
import "art/1f410.png" as goat_png : List(U8)

Vec : { x : F32, y : F32 }

## **THE ART** (roc/art/README.md): the page's emoji, as images compiled in,
## a dog's by its breed, every other kind's by its kind.
Art : { dogs : List(Draw.Texture), cow : Draw.Texture, chicken : Draw.Texture, goat : Draw.Texture }

load_art! : {} => Try(Art, [TextureLoadFailed, ResourceLimit])
load_art! = |{}| {
	png! = |bytes| Assets.texture_from_bytes!({ format: Png, bytes })
	Ok({
		dogs: [png!(dog_0_png)?, png!(dog_1_png)?, png!(dog_2_png)?, png!(dog_3_png)?],
		cow: png!(cow_png)?,
		chicken: png!(chicken_png)?,
		goat: png!(goat_png)?,
	})
}

## **THE HAND** (pointer.js): resting, panning the view, or holding the
## leashed dog, each from the pointer's last point on the window.
Hand : [Resting, Panning(Vec), Dragging(Vec)]

Model : {
	art : Art,

	## The level being played (its index in World.levels), its board, and
	## the critters as the tick before left them (a frame slides from them).
	level : U64,
	board : Game.Board,
	was : List(Walk.Crit),

	## The window's top-left, a park point in pixels, and its size.
	view : Vec,
	screen : Vec,
	hand : Hand,

	## What the next tick plays: the human's inputs, and the pointer's moves
	## in whole 256ths (the fraction kept for the next move).
	humans : List(Game.Human),
	disps : List(Game.Disp),
	fraction : Vec,

	## Seconds since the last tick.
	clock : F32,

	## The line under the score: a quip or a bump's, or none.
	note : Str,
	quips : Quips,
}

program = { init!, update!, render! }

screen_start : Vec
screen_start = { x: 960, y: 640 }

init! : App.Init(Model, _)
init! = App.init(
	App.default.with_title("Dog Park").with_size({ width: screen_start.x.to_i32_wrap(), height: screen_start.y.to_i32_wrap() }).with_output_dir("shots"),
	|io| {
		art = load_art!({})?
		m = play_level(
			{
				art,
				level: 0,
				board: Game.start(World.level_one),
				was: [],
				view: { x: 0, y: 0 },
				screen: screen_start,
				hand: Resting,
				humans: [],
				disps: [],
				fraction: { x: 0, y: 0 },
				clock: 0,
				note: "",
				quips: quips_start,
			},
			0,
		)
		_ = io.stdout().line!("native: ${level_name(0)}, ${m.board.crits.len().to_str()} critters, herd ${Game.largest_herd(m.board).to_str()} of ${Game.cows(m.board).to_str()}")
		Ok(m)
	},
)

## A level begun afresh, the window on its park's middle (park.js).
play_level : Model, U64 -> Model
play_level = |m, n| {
	lv = level_of(n)
	board = Game.start(lv)
	middle = ((lv.world_tiles * World.tile_px) // 2).to_f32()
	{
		..m,
		level: n,
		board,
		was: board.crits,
		view: { x: middle - m.screen.x / 2, y: middle - m.screen.y / 2 },
		hand: Resting,
		humans: [],
		disps: [],
		fraction: { x: 0, y: 0 },
		clock: 0,
		note: "",
	}
}

level_of : U64 -> World.Level
level_of = |n| match World.levels.get(n) {
	Ok(lv) => lv
	Err(_) => World.level_one
}

level_name : U64 -> Str
level_name = |n| match ["Level One", "Level Two", "Level Three"].get(n) {
	Ok(s) => s
	Err(_) => "Level ${(n + 1).to_str()}"
}

world_px : Model -> F32
world_px = |m| (level_of(m.level).world_tiles * World.tile_px).to_f32()

## A screenshot finished (S saves one, shots/shot.png: how the build's
## windowed run on the runner shows what it draws).
Msg : [Shot(Try({}, Capture.ScreenshotError))]

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model0, input, io| {
	if input.devices.key_pressed(KeyS) {
		Task.spawn!(input, || Shot(io.capture().screenshot!("shot.png")))
	}
	m0 = { ..model0, screen: { x: input.window.size.width.to_f32(), y: input.window.size.height.to_f32() } }
	mouse = input.devices.mouse
	p = mouse.position()
	m1 = if mouse.button_pressed(Left) {
		press(m0, p)
	} else if mouse.button_released(Left) {
		lift(m0)
	} else if mouse.button_down(Left) {
		move(m0, p)
	} else {
		m0
	}
	Ok(run_clock(m1, input.time.elapsed_seconds))
}

## ── the pointer (pointer.js, engine.js's intents) ──

## A press: the next level's button, once the level is won; a dog, which
## is grabbed (the leashed one) or leashed (another, the leashed one let
## go first); else the ground, which pans, with a quip if a critter that
## only a dog moves was under it.
press : Model, Vec -> Model
press = |m, p| {
	if Game.won(m.board) and has_next(m) and in_rect(p, next_button(m)) {
		play_level(m, m.level + 1)
	} else {
		at = park_point(m, p)
		dog = critter_at(m.board, at, 0, 0)
		if dog >= 0 {
			d = dog.to_u64_wrap()
			humans = match Game.leashed(m.board) {
				Dog(l, _) => if l == d m.humans.append(Grab) else m.humans.append(Release(l)).append(Leash(d))
				Nobody => m.humans.append(Leash(d))
			}
			{ ..m, hand: Dragging(p), humans, disps: [], fraction: { x: 0, y: 0 }, quips: forgive(m.quips) }
		} else {
			kind = pressed_kind(m.board, at)
			if kind == "" {
				{ ..m, hand: Panning(p) }
			} else {
				said = say_press(m.quips, kind)
				{ ..m, hand: Panning(p), note: said.line, quips: said.quips }
			}
		}
	}
}

## A move: the held dog's drag, in whole 256ths (a window pixel is a park
## pixel), or the view panned against the pointer.
move : Model, Vec -> Model
move = |m, p| match m.hand {
	Dragging(last) => {
		x = m.fraction.x + (p.x - last.x) * 256
		y = m.fraction.y + (p.y - last.y) * 256
		dx = x.to_i32_wrap()
		dy = y.to_i32_wrap()
		disps = if dx != 0 or dy != 0 m.disps.append({ dx, dy }) else m.disps
		{ ..m, hand: Dragging(p), disps, fraction: { x: x - dx.to_f32(), y: y - dy.to_f32() } }
	}
	Panning(last) => {
		{ ..m, hand: Panning(p), view: wrapped_view(m, { x: m.view.x - (p.x - last.x), y: m.view.y - (p.y - last.y) }) }
	}
	Resting => m
}

## The pointer up: the dog in hand let go, kept on the leash.
lift : Model -> Model
lift = |m| match m.hand {
	Dragging(_) => { ..m, hand: Resting, humans: m.humans.append(LetGo) }
	_ => { ..m, hand: Resting }
}

## The window's top-left back in the world.
wrapped_view : Model, Vec -> Vec
wrapped_view = |m, v| {
	w = world_px(m)
	{ x: v.x - v.x.div_floor_by(w) * w, y: v.y - v.y.div_floor_by(w) * w }
}

## The park point under a window point, in 256ths.
park_point : Model, Vec -> Walk.Pt
park_point = |m, p| {
	w = world_px(m)
	x = m.view.x + p.x
	y = m.view.y + p.y
	{ x: ((x - x.div_floor_by(w) * w) * 256).to_i32_wrap(), y: ((y - y.div_floor_by(w) * w) * 256).to_i32_wrap() }
}

## The critter of `kind` whose square, `slop` pixels larger, holds `at`
## (its index in `crits`), or -1.
critter_at : Game.Board, Walk.Pt, U8, I32 -> I64
critter_at = |b, at, kind, slop| {
	var $hit = -1
	var $i = 0
	for c in b.crits {
		d = Walk.delta(b.geo, Walk.pt(c), at)
		reach = c.half + slop * 256
		if $hit < 0 and c.kind == kind and d.x.abs() <= reach and d.y.abs() <= reach {
			$hit = $i
		} else {
			{}
		}
		$i = $i + 1
	}
	$hit
}

## The kind under a press that is no dog (quips.js's `pressedCritter`):
## a cow, a chicken (4 px of slop: it is small), a goat; "" for none.
pressed_kind : Game.Board, Walk.Pt -> Str
pressed_kind = |b, at| {
	if critter_at(b, at, 1, 0) >= 0 {
		"cow"
	} else if critter_at(b, at, 2, 4) >= 0 {
		"chicken"
	} else if critter_at(b, at, 3, 0) >= 0 {
		"goat"
	} else {
		""
	}
}

## ── the clock (engine.js's `frame`) ──

tick_s : F32
tick_s = 1 / Game.ticks_per_second.to_f32()

## The ticks due since the last: at most four a frame, the rest of a stall
## dropped, as the page drops them.
run_clock : Model, F32 -> Model
run_clock = |m0, elapsed| {
	var $m = { ..m0, clock: m0.clock + (if (elapsed > 0.25) 0.25 else elapsed) }
	var $k = 0
	while $m.clock >= tick_s and $k < 4 {
		$m = one_tick({ ..$m, clock: $m.clock - tick_s })
		$k = $k + 1
	}
	if $m.clock >= tick_s {
		{ ..$m, clock: 0 }
	} else {
		$m
	}
}

## One tick: the edge bands scroll the view under a held dog, then the
## board plays the inputs and the drag; a bump says what it hit.
one_tick : Model -> Model
one_tick = |m0| {
	m = band_scroll(m0)
	r = Game.tick(m.board, m.humans, m.disps)
	note = match r.bumped {
		NoBump => m.note
		Critter(k) => bump_line(k)
		PoopBump => "Even your dog won't walk through that."
	}
	{ ..m, board: r.board, was: m.board.crits, humans: [], disps: [], note }
}

## **THE EDGE BANDS** (pointer.js): a held dog within `band_px` of the
## window's edge scrolls the view, faster the deeper it is.
band_px : F32
band_px = 80

band_speed : F32 -> F32
band_speed = |depth_px| {
	depth = depth_px / band_px
	if depth <= 0 0 else 1.75 + (if (depth > 1) 1 else depth) * (14 - 1.75)
}

axis_scroll : F32, F32, F32 -> F32
axis_scroll = |at, length, reach| band_speed(at - (length - reach - band_px)) - band_speed(reach + band_px - at)

band_scroll : Model -> Model
band_scroll = |m| match m.hand {
	Dragging(_) => match Game.leashed(m.board) {
		Dog(d, on) => {
			if on {
				c = get_crit(m.board.crits, d)
				s = on_screen(m, Walk.pt(c))
				reach = c.half.to_f32() / 256
				{ ..m, view: wrapped_view(m, { x: m.view.x + axis_scroll(s.x, m.screen.x, reach), y: m.view.y + axis_scroll(s.y, m.screen.y, reach) }) }
			} else {
				m
			}
		}
		Nobody => m
	}
	_ => m
}

## Where a park point is on the window: the short way round from the
## window's middle, so a critter near the seam is drawn on the near side.
on_screen : Model, Walk.Pt -> Vec
on_screen = |m, p| {
	w = world_px(m)
	half = w / 2
	cx = m.view.x + m.screen.x / 2
	cy = m.view.y + m.screen.y / 2
	dx = p.x.to_f32() / 256 - cx
	dy = p.y.to_f32() / 256 - cy
	sx = dx - (dx + half).div_floor_by(w) * w
	sy = dy - (dy + half).div_floor_by(w) * w
	{ x: sx + m.screen.x / 2, y: sy + m.screen.y / 2 }
}

## A critter as a frame draws it: between where the last tick left it and
## where this one did, `alpha` of the way, the short way round.
between : Model, U64, Walk.Crit -> Walk.Pt
between = |m, i, now| match m.was.get(i) {
	Ok(was) => {
		alpha = m.clock / tick_s
		a = if alpha > 1 1 else alpha
		d = Walk.delta(m.board.geo, Walk.pt(was), Walk.pt(now))
		{ x: was.x + (d.x.to_f32() * a).to_i32_wrap(), y: was.y + (d.y.to_f32() * a).to_i32_wrap() }
	}
	Err(_) => Walk.pt(now)
}

## ── what a frame draws (scene.js) ──

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |m, frame| {
	frame.clear!(Color.from_hex_rgb(0xffffff))
	tile = World.tile_px.to_f32()
	tiles = level_of(m.level).world_tiles
	col0 = m.view.x.div_floor_by(tile).to_i64_wrap()
	row0 = m.view.y.div_floor_by(tile).to_i64_wrap()
	var $row = row0
	while $row.to_f32() * tile < m.view.y + m.screen.y {
		var $col = col0
		while $col.to_f32() * tile < m.view.x + m.screen.x {
			light = ($col.mod_by(tiles) + $row.mod_by(tiles)) % 2 != 0
			if light {
				frame.rectangle!({ x: $col.to_f32() * tile - m.view.x, y: $row.to_f32() * tile - m.view.y, width: tile, height: tile, style: Draw.filled(Color.from_hex_rgb(0xeaf3fc)) })
			} else {
				{}
			}
			$col = $col + 1
		}
		$row = $row + 1
	}
	poop_r = World.poop_px.to_f32() / 2
	for p in m.board.poops {
		frame.circle!({ center: on_screen(m, { x: p.x, y: p.y }), radius: poop_r, style: Draw.filled(Color.from_hex_rgb(0x7a4a1a)) })
	}

	## The dogs last, over the rest, as the page draws them.
	for kind in [2, 1, 3, 0] {
		var $i = 0
		for c in m.board.crits {
			if c.kind == kind {
				at = on_screen(m, between(m, $i, c))
				h = c.half.to_f32() / 256
				draw_ring!(frame, m, $i, at, h)
				t = art_of(m.art, c)
				frame.texture!({
					texture: t,
					source: { x: 0, y: 0, width: t.width, height: t.height },
					dest: { x: at.x - h, y: at.y - h, width: 2 * h, height: 2 * h },
					origin: Math.zero,
					rotation: 0,
					tint: Color.white,
				})
			} else {
				{}
			}
			$i = $i + 1
		}
	}
	draw_words!(frame, m)
	Ok({})
}

## The leashed dog's ring (scene.js): green while in hand, red while kept.
draw_ring! : Draw.Frame, Model, U64, Vec, F32 => {}
draw_ring! = |frame, m, i, at, h| match Game.leashed(m.board) {
	Dog(d, in_hand) => {
		if d == i {
			colour = if in_hand Color.from_hex_rgb(0x22aa22) else Color.from_hex_rgb(0xdd3333)
			r = h + 4
			frame.rectangle!({ x: at.x - r, y: at.y - r, width: 2 * r, height: 3, style: Draw.filled(colour) })
			frame.rectangle!({ x: at.x - r, y: at.y + r - 3, width: 2 * r, height: 3, style: Draw.filled(colour) })
			frame.rectangle!({ x: at.x - r, y: at.y - r, width: 3, height: 2 * r, style: Draw.filled(colour) })
			frame.rectangle!({ x: at.x + r - 3, y: at.y - r, width: 3, height: 2 * r, style: Draw.filled(colour) })
		} else {
			{}
		}
	}
	Nobody => {}
}

## The score (park.js): the level and the herd, or the win and the next
## level's button; the note under it; how to play along the bottom.
draw_words! : Draw.Frame, Model => {}
draw_words! = |frame, m| {
	cows = Game.cows(m.board)
	won = Game.won(m.board)
	score = if won {
		if cows == 2 "You have herded both cows!" else "All ${cows.to_str()} cows herded together!"
	} else {
		"Herd: ${Game.largest_herd(m.board).to_str()} of ${cows.to_str()} cows"
	}
	ink = Color.from_hex_rgb(0xffffff)
	shade = Color.with_alpha(Color.from_hex_rgb(0x223344), 200)
	frame.rectangle!({ x: 0, y: 0, width: m.screen.x, height: if (m.note == "") 40 else 70, style: Draw.filled(shade) })
	frame.text_at!({ pos: { x: 14, y: 10 }, text: "${level_name(m.level)}    ${score}", size: 22, color: ink })
	if m.note != "" {
		frame.text_at!({ pos: { x: 14, y: 42 }, text: m.note, size: 18, color: Color.from_hex_rgb(0xf8d8a8) })
	}
	if won and has_next(m) {
		b = next_button(m)
		frame.rectangle!({ x: b.x, y: b.y, width: b.width, height: b.height, style: Draw.filled(Color.from_hex_rgb(0x2a9a3a)) })
		frame.text_at!({ pos: { x: b.x + 14, y: b.y + 14 }, text: "Go to ${level_name(m.level + 1)}", size: 22, color: ink })
	}
	frame.rectangle!({ x: 0, y: m.screen.y - 30, width: m.screen.x, height: 30, style: Draw.filled(shade) })
	frame.text_at!({ pos: { x: 14, y: m.screen.y - 24 }, text: "Press a dog and drag it. Drag the ground to look around. Esc quits.", size: 16, color: ink })
}

has_next : Model -> Bool
has_next = |m| m.level + 1 < World.levels.len()

Rect : { x : F32, y : F32, width : F32, height : F32 }

next_button : Model -> Rect
next_button = |m| { x: m.screen.x / 2 - 120, y: m.screen.y / 2 - 26, width: 240, height: 52 }

in_rect : Vec, Rect -> Bool
in_rect = |p, r| p.x >= r.x and p.x <= r.x + r.width and p.y >= r.y and p.y <= r.y + r.height

## A critter's emoji: a dog's by its breed (its kin), the rest by kind.
art_of : Art, Walk.Crit -> Draw.Texture
art_of = |art, c| {
	if c.kind == 0 {
		match art.dogs.get(c.kin.to_u64()) {
			Ok(t) => t
			Err(_) => crash "native: no art for a breed"
		}
	} else if c.kind == 1 {
		art.cow
	} else if c.kind == 2 {
		art.chicken
	} else {
		art.goat
	}
}

get_crit : List(Walk.Crit), U64 -> Walk.Crit
get_crit = |l, j| match l.get(j) {
	Ok(c) => c
	Err(_) => crash "native: no critter there"
}

## ── the quips (solo/quips.js), their emoji left out: raylib's font has none ──

## Each kind's lines in turn, and how many presses in a row on critters
## that only dogs move (past four, the park's remarks).
Quips : { cow : U64, chicken : U64, goat : U64, tries : U64, remark : U64 }

quips_start : Quips
quips_start = { cow: 0, chicken: 0, goat: 0, tries: 0, remark: 0 }

forgive : Quips -> Quips
forgive = |q| { ..q, tries: 0 }

line_of : List(Str), U64 -> Str
line_of = |ls, n| match ls.get(n % ls.len()) {
	Ok(s) => s
	Err(_) => ""
}

say_press : Quips, Str -> { line : Str, quips : Quips }
say_press = |q0, kind| {
	q = { ..q0, tries: q0.tries + 1 }
	if q.tries > 4 {
		{ line: line_of(persistence, q.remark), quips: { ..q, remark: q.remark + 1 } }
	} else if kind == "cow" {
		{ line: line_of(cow_lines, q.cow), quips: { ..q, cow: q.cow + 1 } }
	} else if kind == "chicken" {
		{ line: line_of(chicken_lines, q.chicken), quips: { ..q, chicken: q.chicken + 1 } }
	} else {
		{ line: line_of(goat_lines, q.goat), quips: { ..q, goat: q.goat + 1 } }
	}
}

cow_lines = [
	"Moo means no. Cows only move for dogs.",
	"That cow weighs 1,400 pounds and does not do lifts. Send a dog.",
	"The cow has filed a formal complaint with the Dog Park Authority.",
	"You can't drag a cow. Nobody can. That's why dogs were invented.",
	"The cow regards your cursor with profound bovine indifference.",
	"Hands off the merchandise. Herd her with a dog.",
]

chicken_lines = [
	"BAWK. The chicken has escaped your grasp, and also your respect.",
	"Chickens are free-range, not free-drag.",
	"That chicken is on the clock. It has poop to eat.",
	"The chickens have unionized. Grabbing is a grievance.",
	"The chicken looks at you with 66 million years of dinosaur contempt.",
	"You can't herd chickens. Ask anyone. Ask the chickens.",
]

goat_lines = [
	"You can't drag a goat. You can barely suggest things to a goat.",
	"The goat chewed on your cursor a bit. Send a dog.",
	"Goats only move for dogs, and then only toward them.",
	"That goat has opinions. None of them involve being dragged.",
	"Bleat. (Translation: no.)",
]

persistence = [
	"Okay, now you're just doing it on purpose.",
	"The critters have started a group chat about you.",
	"Still no. Have you met the dogs? They're right there.",
]

## A bump's line, by the kind it hit (quips.js's `bumpLines`): the first of
## each, as a bump comes and goes too fast to cycle.
bump_line : U8 -> Str
bump_line = |kind| {
	if kind == 0 {
		"Bonk. Dogs don't stack. We checked."
	} else if kind == 1 {
		"You walked your dog into a cow. The cow won."
	} else if kind == 2 {
		"The chicken held its ground. Respect the chicken."
	} else {
		"The goat headbutted back. The goat always headbutts back."
	}
}

expect say_press(quips_start, "cow").line == "Moo means no. Cows only move for dogs."
expect {
	var $q = quips_start
	var $k = 0
	var $line = ""
	while $k < 5 {
		said = say_press($q, "cow")
		$q = said.quips
		$line = said.line
		$k = $k + 1
	}
	$line == "Okay, now you're just doing it on purpose."
}
expect axis_scroll(500, 960, 14) == 0
expect axis_scroll(950, 960, 14) > 0
expect axis_scroll(10, 960, 14) < 0
