# Benchmarks

Compute-heavy programs for comparing the two backends. Build optimized first:

```bash
zig build -Doptimize=ReleaseFast
BIN=zig-out/bin/RoseGold_Zig
for f in bench/*.rg; do
  echo "== $f =="
  /usr/bin/time -p $BIN run       "$f"   # tree-walker
  /usr/bin/time -p $BIN run --vm  "$f"   # bytecode VM
done
```

Both backends print identical output. On an Apple-silicon laptop (ReleaseFast),
`run --vm` is roughly **2.8–3.9× faster** than the tree-walker:

| program   | tree-walker | `--vm` | speedup |
| --------- | ----------- | ------ | ------- |
| fib.rg    | ~1.54s      | ~0.35s | ~4.4×   |
| loop.rg   | ~0.74s      | ~0.22s | ~3.4×   |
| primes.rg | ~0.45s      | ~0.15s | ~3.0×   |

### VM micro-optimizations (best-of-7 `--vm`, same laptop)

A tuning pass shaved ~4–6% off the VM by removing per-instruction indirection and
call overhead:

- **`Frame.code` cache** — each call frame caches its bytecode slice, so the fetch
  loop and `readByte`/`readU16` index it directly instead of walking
  `frame.func.chunk.code.items` every instruction.
- **Inline arity fast path** — `call` skips the `fillDefaults` helper when the
  argument count already matches (no defaults to fill), the common case.

| program   | before | after  |
| --------- | ------ | ------ |
| fib.rg    | 0.37s  | 0.35s  |
| loop.rg   | 0.23s  | 0.22s  |
| primes.rg | 0.16s  | 0.15s  |
