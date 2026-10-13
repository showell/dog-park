"""The one-time move of a play server's data into the 64 x 64 world: every
position in DATA_DIR's dogs.json, cows.json and humans/* (each human's
viewport) plus 13,500 px on each axis, so the 10 x 10 park sits in the
middle of the world (docs/PHYSICS.md, decision 14; tiles.zig's
park_offset_px).

    python3 -I tools/shift_park_to_64.py DATA_DIR

Stop the server first: it holds the dogs and cows in memory and rewrites
the files. **IT REFUSES, CHANGING NOTHING,** a data dir that is not exactly
the 10 x 10 world's: a file the server would not have written byte for byte
(the server's own format is read back and compared), the wrong dogs or
cows, any position outside the old world (0 to 4,999 px, so a dir already
shifted is refused), or anything in humans/ but a 32-hex-digit viewport
file. Every file is written beside its original and renamed over it only
once all of them are written.
"""
import json
import os
import re
import sys

OFFSET_PX = 13_500
OLD_WORLD_PX = 5_000
DOGS = 250
COWS = 50
HUMAN = re.compile(r"^[0-9a-f]{32}$")


class Refused(Exception):
    pass


def dumps(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def dogs_text(dogs: list) -> str:
    """dogs.zig's `written`."""
    return '{"dogs":[' + ",".join("\n" + dumps(d) for d in dogs) + "\n]}\n"


def cows_text(cows: list) -> str:
    """cows.zig's `written`."""
    return '{"cows":[' + ",".join("\n" + dumps(c) for c in cows) + "\n]}\n"


def viewport_text(v: dict) -> str:
    """app.zig's /viewport: std.json's ParkPoint, no newline."""
    return dumps(v)


def read(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


def in_old_world(name: str, x: int, y: int, lo: int, hi: int) -> None:
    if not (lo <= x <= hi and lo <= y <= hi):
        raise Refused(f"{name} at ({x}, {y}) is outside the 10 x 10 world ({lo} to {hi}): already shifted, or not this server's data")


def plan(data: str) -> list:
    """(path, new text) for every file, or Refused."""
    out = []

    path = os.path.join(data, "dogs.json")
    text = read(path)
    dogs = json.loads(text)["dogs"]
    if dogs_text(dogs) != text:
        raise Refused(f"{path} is not as the server writes it")
    if [d["id"] for d in dogs] != list(range(DOGS)) or any(list(d) != ["id", "emoji", "park_x", "park_y"] for d in dogs):
        raise Refused(f"{path} does not hold dogs 0 to {DOGS - 1}, in order")
    for d in dogs:
        in_old_world(f"dog {d['id']}", d["park_x"], d["park_y"], 0, OLD_WORLD_PX - 1)
        d["park_x"] += OFFSET_PX
        d["park_y"] += OFFSET_PX
    out.append((path, dogs_text(dogs)))

    path = os.path.join(data, "cows.json")
    text = read(path)
    cows = json.loads(text)["cows"]
    if cows_text(cows) != text:
        raise Refused(f"{path} is not as the server writes it")
    if [c["id"] for c in cows] != list(range(COWS)) or any(list(c) != ["id", "half_x", "half_y"] for c in cows):
        raise Refused(f"{path} does not hold cows 0 to {COWS - 1}, in order")
    for c in cows:
        # Half pixels, the whole square in the world: 30 to 4,970 px.
        in_old_world(f"cow {c['id']} (half pixels)", c["half_x"], c["half_y"], 2 * 30, 2 * (OLD_WORLD_PX - 30))
        c["half_x"] += 2 * OFFSET_PX
        c["half_y"] += 2 * OFFSET_PX
    out.append((path, cows_text(cows)))

    humans = os.path.join(data, "humans")
    names = sorted(os.listdir(humans)) if os.path.isdir(humans) else []
    for name in names:
        path = os.path.join(humans, name)
        if not HUMAN.match(name) or not os.path.isfile(path):
            raise Refused(f"{path} is not a human's viewport file")
        text = read(path)
        v = json.loads(text)
        if viewport_text(v) != text or list(v) != ["park_x", "park_y"]:
            raise Refused(f"{path} is not as the server writes it")
        # A viewport's top-left keeps its centre in the world, so it may
        # hang past an edge by half a screen, never past the far one.
        if not (v["park_x"] < OLD_WORLD_PX and v["park_y"] < OLD_WORLD_PX):
            raise Refused(f"viewport {name} at ({v['park_x']}, {v['park_y']}) is past the 10 x 10 world: already shifted?")
        v["park_x"] += OFFSET_PX
        v["park_y"] += OFFSET_PX
        out.append((path, viewport_text(v)))
    return out


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    data = sys.argv[1]
    try:
        writes = plan(data)
    except (Refused, OSError, ValueError, KeyError, TypeError) as e:
        print(f"REFUSED, nothing changed: {e}", file=sys.stderr)
        return 1
    staged = []
    for path, text in writes:
        with open(path + ".shift64", "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        staged.append(path)
    for path in staged:
        os.replace(path + ".shift64", path)
    viewports = len(writes) - 2
    print(f"shifted by {OFFSET_PX} px: {DOGS} dogs, {COWS} cows, {viewports} viewports in {data}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
