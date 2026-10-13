"""Tests for tools/looks_to_four.py, on copies only: a five-look dogs.json
made as dogs.zig wrote it (and, given a DATA_DIR, a copy of that dir's
dogs.json) moves to four looks, positions untouched; a second run, a file
not as the server writes it, and one outside the world are refused with
nothing changed.

    python3 -I tools/test_looks_to_four.py [DATA_DIR_TO_COPY]
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import looks_to_four as tool  # noqa: E402

TOOL = os.path.join(HERE, "looks_to_four.py")


def five_look_dogs() -> list:
    """Today's layout's looks, at made-up places in the world's middle."""
    return [{"id": n, "emoji": tool.FIVE[n % 5], "park_x": 13_500 + 7 * n, "park_y": 13_600 + 11 * n} for n in range(tool.DOGS)]


def run(data: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", TOOL, data], capture_output=True, text=True)


def write(data: str, text: str) -> None:
    with open(os.path.join(data, "dogs.json"), "w", encoding="utf-8") as f:
        f.write(text)


def read(data: str) -> str:
    with open(os.path.join(data, "dogs.json"), encoding="utf-8") as f:
        return f.read()


def check(cond: bool, what: str) -> None:
    if not cond:
        raise SystemExit(f"FAIL: {what}")
    print(f"ok: {what}")


def moved_right(before: str, after: str) -> bool:
    import json
    b = json.loads(before)["dogs"]
    a = json.loads(after)["dogs"]
    return all(x["emoji"] == tool.FOUR[x["id"] % 4] and x["park_x"] == y["park_x"] and x["park_y"] == y["park_y"] for x, y in zip(a, b)) and after == tool.dogs_text(a)


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        data = os.path.join(tmp, "data")
        os.mkdir(data)
        before = tool.dogs_text(five_look_dogs())
        write(data, before)
        r = run(data)
        check(r.returncode == 0, "a five-look dogs.json moves")
        after = read(data)
        check(moved_right(before, after), "every look is n mod 4's, every position kept, the server's format")
        check(sorted(os.listdir(data)) == ["dogs.json"], "nothing left beside it")
        r = run(data)
        check(r.returncode == 1 and read(data) == after and "REFUSED" in r.stderr, "a second run is refused, nothing changed")

        write(data, before.replace('"park_x":', '"park_x": ', 1))
        r = run(data)
        check(r.returncode == 1 and "not as the server writes it" in r.stderr, "a file not as the server writes it is refused")

        dogs = five_look_dogs()
        dogs[9]["park_x"] = 32_000
        write(data, tool.dogs_text(dogs))
        r = run(data)
        check(r.returncode == 1 and "outside the 64 x 64 world" in r.stderr, "a dog outside the world is refused")

        if len(sys.argv) == 2:
            copy = os.path.join(tmp, "copy")
            os.mkdir(copy)
            shutil.copyfile(os.path.join(sys.argv[1], "dogs.json"), os.path.join(copy, "dogs.json"))
            before = read(copy)
            r = run(copy)
            check(r.returncode == 0, f"a copy of {sys.argv[1]}/dogs.json moves ({r.stdout.strip() or r.stderr.strip()})")
            check(moved_right(before, read(copy)), "the copy: looks n mod 4, positions kept")
    print("looks_to_four: all passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
