"""The one-time move of a play server's dogs.json from five looks to four:
dog n's look becomes the n mod 4th of the four dogs with legs, its breed in
the physics (docs/PHYSICS.md, "Breeds"; dogs.zig's `looks`). The face 🐶
goes; every position stays.

    python3 -I tools/looks_to_four.py DATA_DIR

Stop the server first: it holds the dogs in memory and rewrites the file,
and once dogs.zig deals four looks it refuses to start on a five-look file.
**IT REFUSES, CHANGING NOTHING,** a dogs.json that is not exactly the
five-look one: a file the server would not have written byte for byte (its
own format is read back and compared), dogs other than 0 to 249 in order,
any look but the n mod 5th of the five (so a file already moved is
refused), or a dog outside the 64 x 64 world. Only dogs.json changes:
written beside itself, synced, then renamed over it.
"""
import json
import os
import sys

DOGS = 250
WORLD_PX = 64 * 500
FIVE = ["🐕", "🐩", "🦮", "🐶", "🐕‍🦺"]
FOUR = ["🐕", "🐩", "🦮", "🐕‍🦺"]


class Refused(Exception):
    pass


def dumps(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def dogs_text(dogs: list) -> str:
    """dogs.zig's `written`."""
    return '{"dogs":[' + ",".join("\n" + dumps(d) for d in dogs) + "\n]}\n"


def plan(data: str) -> tuple:
    """(path, new text), or Refused."""
    path = os.path.join(data, "dogs.json")
    with open(path, encoding="utf-8") as f:
        text = f.read()
    dogs = json.loads(text)["dogs"]
    if dogs_text(dogs) != text:
        raise Refused(f"{path} is not as the server writes it")
    if [d["id"] for d in dogs] != list(range(DOGS)) or any(list(d) != ["id", "emoji", "park_x", "park_y"] for d in dogs):
        raise Refused(f"{path} does not hold dogs 0 to {DOGS - 1}, in order")
    for d in dogs:
        n = d["id"]
        if d["emoji"] != FIVE[n % 5]:
            raise Refused(f"dog {n} looks {d['emoji']}, not the five-look layout's {FIVE[n % 5]}: already moved, or not this server's data")
        if not (0 <= d["park_x"] < WORLD_PX and 0 <= d["park_y"] < WORLD_PX):
            raise Refused(f"dog {n} at ({d['park_x']}, {d['park_y']}) is outside the 64 x 64 world: shift the park first (tools/shift_park_to_64.py)")
        d["emoji"] = FOUR[n % 4]
    return path, dogs_text(dogs)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    data = sys.argv[1]
    try:
        path, text = plan(data)
    except (Refused, OSError, ValueError, KeyError, TypeError) as e:
        print(f"REFUSED, nothing changed: {e}", file=sys.stderr)
        return 1
    with open(path + ".four", "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(path + ".four", path)
    print(f"{DOGS} dogs moved to four looks in {data}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
