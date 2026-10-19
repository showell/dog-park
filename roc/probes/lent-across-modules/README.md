# Probe: a lent list changed through another module stays in place

**The question:** when a Zig host lends Roc a unique list (refcount 1, no
room to grow), and Roc changes it through a function in *another* module,
does Roc copy it? The physics' `roc_alloc` panics, so a copy there is a
crash. A reusable Roc data structure (a `Grid.roc`) is only worth having
if calling into it costs no copy.

**The answer (Roc nightly-2026-10-18-1df370f): no copy.** `app.roc` sets
one bit of a lent list in four ways:

- **0:** written inline;
- **1:** through a function of the same module;
- **2:** through `Grid.set_bit` in another module;
- **3 (the plant):** through `Grid.set_bit`, with the old list kept alive
  after the set.

Modes 0 to 2 change the list in place with no allocation, in Debug and
ReleaseSafe hosts alike. Mode 3 allocates and hands back a new list,
which shows the probe can see a copy.

**Run it** from this folder:

    roc build app.roc --target=x64musl --output=app.a
    zig build-exe host.zig app.a -target x86_64-linux-musl -O ReleaseSafe -femit-bin=host
    ./host

**What it printed:**

    mode 0 (inline): allocs 0, in place true, refcount 1, word 1 = 40
    mode 1 (same module): allocs 0, in place true, refcount 1, word 1 = 40
    mode 2 (Grid.roc): allocs 0, in place true, refcount 1, word 1 = 40
    mode 3 (plant: old list kept): allocs 1, in place false, refcount 0, word 1 = 0
