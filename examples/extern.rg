## Host bindings declared in RoseGold source.
##
## An `extern func` is a signature with no body: the implementation is supplied
## by the embedding host (`vm.Session.registerHost`) and resolved by *linkage*
## when the module loads, the way Zig's `extern fn` resolves against a linker.
##
## This file is deliberately NOT runnable from the CLI — there is no host to
## register the natives, so `run --vm` reports an unregistered extern (a link
## error) and `run` reports that the tree-walker has no embedding API. It is
## here to be `check`ed, `fmt`ted and `doc`umented:
##
##     RoseGold_Zig check examples/extern.rg
##     RoseGold_Zig doc   examples/extern.rg
##
## See the README's "Declaring the host API in script" for the host-side Zig.

## Add two integers on the host side.
##
## Bare `extern` is shorthand for `extern "zig"`: the embedding host's
## registered natives, which is the only linkage implemented today.
pub extern func host_add(a: int, b: int) -> int

## Spawn an entity and return its id. Written with the tag spelled out — the
## formatter drops it again, since "zig" is the default.
pub extern "zig" func spawn(kind: str, x: float, y: float) -> int

## Look up the engine's current frame counter.
pub extern func frame_count() -> int


## Because the bindings are declared, ordinary calls are type-checked: passing a
## str for `a`, or the wrong number of arguments, is a compile-time error here
## rather than a surprise inside the host function.
pub func place_row(kind: str, count: int, y: float) -> int:
    var last = 0
    for i in 0..count:
        last = spawn(kind, float(i) * 2.0, y)
    return last

## Externs compose with everything else — they are just functions to the caller.
pub func scaled_sum(xs: list<int>) -> int:
    var total = 0
    for x in xs:
        total = host_add(total, x)
    return total

## The host drives a script by resolving a function once and calling it per
## frame; `frame_count` shows an extern used for a plain engine query.
pub func update() -> int:
    return host_add(frame_count(), 1)
