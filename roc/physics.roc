## THE PHYSICS IN ROC, as the app its Zig links (roc/platform/main.roc).
app [walk] { pf: platform "./platform/main.roc" }

import Walk

## The physics' one call into Roc, by `mode`: 1, the forage turn after the
## drag (`forage_turn`, `inc` the leashed dog's
## net move over the tick); 2, the tick's whole drag (`drag_tick`: its
## pixel-ticks, Walk.roc's `pixel_tick` each, `disps`, the poops each lays filed on `from` and `poops`
## and listed in `placed`, then the forage turn unless `inc` is 0). Each
## first files the critters into the cells, if the physics lent them clear
## (`Walk.filed`).
## Its arguments unpacked into Walk.roc's records and its result laid flat
## for the host; what a mode does not use it hands back as lent.
walk = |
	mode,
	inc,
	side,
	before,
	laid,
	from,
	poops,
	homes,
	cells,
	crits,
	depth,
	eaten,
	moving,
	disps,
	placed,
| {
	{ cells: filed_cells, crits: filed_crits } = Walk.filed(Walk.geo_of(side), { cells, crits })
	if mode == 1 {
		t = Walk.forage_turn({ from, poops, side }, { cells: filed_cells, crits: filed_crits }, homes, eaten, inc, laid)
		{
			before,
			bump_at: 0,
			bump_kind: 0,
			cells: t.park.cells,
			crits: t.park.crits,
			depth,
			eaten: t.eaten,
			from,
			moving,
			placed,
			poops,
		}
	} else {
		d = Walk.drag_tick(
			{ from, poops, side },
			{ depth, moving, park: { cells: filed_cells, crits: filed_crits } },
			disps,
			homes,
			eaten,
			placed,
			before,
			laid,
			inc != 0,
		)
		{ bump, eaten: d_eaten, lent: { from: d_from, poops: d_poops, side: _ }, placed: d_placed, walked: d_before, work } = d
		{ depth: d_depth, moving: d_moving, park: { cells: d_cells, crits: d_crits } } = work
		{
			before: d_before,
			bump_at: bump.at,
			bump_kind: bump.kind,
			cells: d_cells,
			crits: d_crits,
			depth: d_depth,
			eaten: d_eaten,
			from: d_from,
			moving: d_moving,
			placed: d_placed,
			poops: d_poops,
		}
	}
}
