## A tiny shared string library, meant to live on a module search path.
## Run a program that imports it with:
##   RoseGold_Zig run --path examples/libs examples/pathdemo.rg

pub func shout(s: str) -> str:
    return upper(s) + "!"

pub func repeat(s: str, n: int) -> str:
    var out = ""
    for i in range(n):
        out = out + s
    return out

## Module-private helper — not visible to importers.
func spaces(n: int) -> str:
    return repeat(" ", n)

pub func indent(s: str, n: int) -> str:
    return spaces(n) + s
