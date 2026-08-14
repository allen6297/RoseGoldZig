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
| fib.rg    | ~1.54s      | ~0.38s | ~4.0×   |
| loop.rg   | ~0.74s      | ~0.23s | ~3.2×   |
| primes.rg | ~0.45s      | ~0.16s | ~2.8×   |
