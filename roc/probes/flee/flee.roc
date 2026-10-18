app [flee] { pf: platform "./platform/main.roc" }

world : I32
world = 2100 * 256

half_world : I32
half_world = world // 2

wary : I32
wary = 158 * 256

step_most : I32
step_most = 256

## The short way from 0 to d on the torus.
short_way : I32 -> I32
short_way = |d| {
	m = d % world
	w = if (m < 0) m + world else m
	if (w > half_world) w - world else w
}

sign : I32 -> I32
sign = |v| if (v > 0) 1 else if (v < 0) -1 else 0

## A cow at (cx, cy) steps away from a dog at (dx, dy) when it is within
## `wary`: one step on each axis, away; otherwise it stays.
flee : I32, I32, I32, I32 -> { x : I32, y : I32 }
flee = |dx, dy, cx, cy| {
	ox = short_way(cx - dx)
	oy = short_way(cy - dy)
	d2 = ox.to_i64() * ox.to_i64() + oy.to_i64() * oy.to_i64()
	w2 = wary.to_i64() * wary.to_i64()
	if d2 < w2 {
		{ x: cx + sign(ox) * step_most, y: cy + sign(oy) * step_most }
	} else {
		{ x: cx, y: cy }
	}
}
