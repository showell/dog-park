## THE PHYSICS IN ROC, as the app its Zig links (roc/platform/main.roc).
app [walk] { pf: platform "./platform/main.roc" }

import Walk

## The walk, its arguments unpacked into Walk.roc's records.
walk = |most, side, from, poops, cells, crits, depth, moving| {
	r = Walk.walk({ from, poops, side }, { depth, moving, park: { cells, crits } }, most)
	{ anchor: r.anchor, cells: r.work.park.cells, crits: r.work.park.crits, depth: r.work.depth, moving: r.work.moving, pooper: r.pooper }
}
