# Probe: a physics-shaped Roc function, called from Zig

What it answers: can Roc code run inside Dog Park's physics, on each of
its three targets, and at what cost? `flee.roc` is one pure function, a
cow's step away from a dog round the torus, of the kind a later frontier
might hand to Roc. The hosts call it beside the same function in Zig, check
that the two agree on every input, and time them. Nothing here is built
by `zig build`; run it by hand, with the new compiler (`roc` on the PATH).

```sh
# Linux (the server): 2^20 pairs, all agree, then ns a call
roc build flee.roc --target=x64glibc --output=libflee.a
zig build-exe -OReleaseFast host.zig libflee.a -lc && ./host

# wasm32 (the page): under node
roc build flee.roc --target=wasm32 --output=libflee_wasm.a
zig build-exe -target wasm32-freestanding -OReleaseSafe -fno-entry -rdynamic page.zig libflee_wasm.a
node run.mjs page.wasm

# freestanding x86-64 (the kernel): links; read the code for SSE
roc build flee.roc --target=x64elf --output=libflee_elf.a
zig build-exe -target x86_64-freestanding-none -OReleaseSafe -fno-entry kern.zig libflee_elf.a -femit-bin=kern.elf
```

What it found (2026-10-18, Roc nightly-2026-10-18-1df370f, zig 0.16, a
shared cloud machine whose timings vary by a third run to run):

- **Linux:** Roc 9.0 to 9.8 ns a call; the Zig function not inlined 10.7
  to 12.7, inlined 9.6 to 10.2. All 1,048,576 pairs agree.
- **wasm32 under node:** Roc 11.8 to 16.0 ns a call, Zig (inlined) 9.7 to
  12.5; all 65,536 pairs agree. Linking the archive (260 KB) adds 113
  bytes to a stripped module: only what is called is kept.
- **x64elf:** links into a freestanding image. This function's code uses
  no SSE register and checks every add for overflow (a crash, as
  ReleaseSafe Zig panics). The kernel builds with SSE off and soft float;
  nothing yet holds a larger Roc function to that.
- **The host's side** is C symbols only: the app imports `roc_crashed`
  (and, once it allocates, `roc_alloc`, `roc_dealloc`, `roc_realloc`,
  `roc_dbg`, `roc_expect_failed`). Zig 0.16 supplies them; none of Roc's
  own Zig (0.17) is needed.
- **`roc build` exits 1 on a type error but writes the archive anyway**
  (the error becomes a crash where it is reached), so a build step must
  go by the exit code, never by the file being there.
