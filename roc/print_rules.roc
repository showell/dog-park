## THE RULES, printed for the physics' Zig: `zig build roc` runs this
## (`roc roc/print_rules.roc -- zon`) and checks in what it prints,
## src/play/rules.zon, which src/play/rules.zig imports as `Rules`. The
## rules themselves are roc/Rules.roc's.

import Rules
import Wish
import World

zon_share : Rules.Share -> Str
zon_share = |sh| ".{ .num = ${sh.num.to_str()}, .den = ${sh.den.to_str()} }"

zon_rule : Rules.Rule -> Str
zon_rule = |rule| match rule {
	Ignore => ".ignore"
	Keep(reach) => ".{ .keep = ${reach.to_str()} }"
	Herd(
		{
			inner,
			outer,
		},
	) => ".{ .herd = .{ .inner = ${inner.to_str()}, .outer = ${outer.to_str()} } }"
	Close(reach) => ".{ .close = ${reach.to_str()} }"
}

## The kinds in World.roc's order, as Wish.roc numbers them.
all_kinds : List(Rules.Kind)
all_kinds = {
	var $out = []
	var $n = 0
	while $n < World.kinds.len() {
		$out = $out.append(Wish.kind_of($n.to_u8_wrap()))
		$n = $n + 1
	}
	$out
}

## How each kind moves in the walk, by its number (`null`, never in motion
## there), and each kind's answer to each, kin and not: the table the
## walk's Zig judge (src/play/walk_reference.zig) reads.
zon_movers : Str
zon_movers = {
	var $out = ""
	for k in all_kinds {
		$out = $out.concat(
			match Rules.mover(k) {
				Moves(m) => "        .{ .gathers = ${
					match m.gathers {
						Each => ".each"
						Nearest => ".nearest"
					}
				}, .pace = ${zon_share(m.pace)} },\n"
				Still => "        null,\n"
			},
		)
	}
	$out
}

zon_answers : Str
zon_answers = {
	var $out = ""
	for w in all_kinds {
		$out = $out.concat("        .{\n")
		for s in all_kinds {
			$out = $out.concat("            .{ .kin = ${zon_rule(Rules.rule(w, s, Bool.True))}, .other = ${zon_rule(Rules.rule(w, s, Bool.False))} },\n")
		}
		$out = $out.concat("        },\n")
	}
	$out
}

zon_chickens : Rules.Forage -> Str
zon_chickens = |c| ".{ .sight = ${c.sight.to_str()}, .step = ${c.step.to_str()}, .pace = ${zon_share(c.pace)}, .home_band = ${c.home_band.to_str()} }"

zon_poop : Rules.Poop -> Str
zon_poop = |p| ".{ .every = ${p.every.to_str()}, .back = ${p.back.to_str()}, .reach = ${p.reach.to_str()}, .grid = ${p.grid.to_str()}, .slots = ${p.slots.to_str()} }"

zon_limits : Rules.Limits -> Str
zon_limits = |l| ".{ .most = ${l.most.to_str()}, .nudge_most = ${l.nudge_most.to_str()}, .dead_zone = ${l.dead_zone.to_str()} }"

zon : Str
zon =
	\\// THE RULES, printed by roc/print_rules.roc (`zig build roc`): do not edit;
	\\// edit that and print it again. Read by src/play/rules.zig.
	\\.{
	\\    .wary = ${Rules.wary.to_str()},
	\\    .movers = .{
	\\${zon_movers}    },
	\\    .answers = .{
	\\${zon_answers}    },
	\\    .chickens = ${zon_chickens(Rules.chickens)},
	\\    .poop = ${zon_poop(Rules.poop)},
	\\    .limits = ${zon_limits(Rules.limits)},
	\\}
	\\

main! = |args| {
	match args {
		["zon"] => echo!(zon)
		_ => crash "roc/print_rules.roc: say `zon`"
	}
	Ok({})
}
