#!/bin/sh
# A FOURTH KIND, MADE IN ROC ALONE (metal-vmm QUEUE 240): copy this
# checkout (its siblings linked, as build.zig.zon finds them), apply
# test/fourth_kind/goat.patch there, which may touch roc/*.roc and nothing
# else, print the goat world and build its Roc (`zig build roc`), and run
# src/play/fourth_kind_test.zig and the walk's judge against the same Zig.
# Usage: tools/fourth_kind.sh [roc]
set -eu
roc=${1:-roc}
here=$(pwd)
patch_file="$here/test/fourth_kind/goat.patch"
# Roc's files only: a patch that needs the Zig changed proves nothing.
if grep -E '^\+\+\+ ' "$patch_file" | grep -vqE '^\+\+\+ b/roc/[^/]*\.roc$'; then
    echo "fourth_kind: goat.patch touches more than roc/*.roc:" >&2
    grep -E '^\+\+\+ ' "$patch_file" >&2
    exit 1
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Every sibling of this checkout, linked: build.zig.zon's paths, and theirs.
for sibling in "$here"/../*; do
    name=$(basename "$sibling")
    [ "$name" = "$(basename "$here")" ] || ln -s "$(cd "$(dirname "$sibling")" && pwd)/$name" "$work/$name"
done
# The copy goes by this checkout's own name: a worktree's sibling may be
# the main checkout, `dog-park`, already linked above.
copy="$work/$(basename "$here")"
mkdir "$copy"
tar -C "$here" --exclude=./.zig-cache --exclude=./zig-out --exclude=./.git -cf - . | tar -C "$copy" -xf -
cd "$copy"
patch -p1 --quiet < "$patch_file"
# The Zig is this checkout's, byte for byte.
for f in $(cd "$here" && ls src/play/*.zig); do cmp -s "$here/$f" "$f" || { echo "fourth_kind: $f differs after the patch" >&2; exit 1; }; done
zig build -Droc="$roc" roc
zig build fourth-kind-test
zig build walk-judge
echo "fourth_kind: the goat world's test and the walk's judge pass on this checkout's Zig"
