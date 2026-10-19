## THE PHYSICS IN ROC, as the app its Zig links (roc/platform/main.roc).
app [walk] { pf: platform "./platform/main.roc" }

import Walk

## The physics' one call into Roc, by `mode`: 0, one pixel-tick (Walk.roc's
## `pixel_tick`: the leashed dog's step, then the walk and the poop due);
## 1, the forage turn after the drag (`forage_turn`, `inc` the leashed dog's
## net move over the tick). Either first files the critters into the
## cells, if the physics lent them clear (`Walk.filed`). Its arguments
## unpacked into Walk.roc's records and its result laid flat for the host;
## what a mode does not use it hands back as lent.
walk = |
	mode,
	axis,
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
| {
	{ cells: filed_cells, crits: filed_crits } = Walk.filed({ cells, crits })
	if mode == 0 {
		r = Walk.pixel_tick(
			{ from, poops, side },
			{ depth, moving, park: { cells: filed_cells, crits: filed_crits } },
			axis,
			inc,
			before,
			laid,
		)
		{
			anchor: r.walk.anchor,
			bump_at: r.bump.at,
			bump_kind: r.bump.kind,
			cells: r.walk.work.park.cells,
			crits: r.walk.work.park.crits,
			depth: r.walk.work.depth,
			eaten,
			moving: r.walk.work.moving,
			poop_slot: r.poop.slot,
			poop_x: r.poop.x,
			poop_y: r.poop.y,
			pooper: r.walk.pooper,
			step_x: r.step.x,
			step_y: r.step.y,
			walked: r.walked,
		}
	} else {
		t = Walk.forage_turn({ from, poops, side }, { cells: filed_cells, crits: filed_crits }, homes, eaten, inc, laid)
		{
			anchor: -1,
			bump_at: 0,
			bump_kind: 0,
			cells: t.park.cells,
			crits: t.park.crits,
			depth,
			eaten: t.eaten,
			moving,
			poop_slot: -1,
			poop_x: 0,
			poop_y: 0,
			pooper: 0,
			step_x: 0,
			step_y: 0,
			walked: 0,
		}
	}
}
