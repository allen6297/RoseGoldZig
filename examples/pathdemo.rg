## Imports `strutil`, which is NOT next to this file — it lives under
## examples/libs, supplied as a module search root:
##   RoseGold_Zig run --path examples/libs examples/pathdemo.rg
## Runs identically on the tree-walker and the --vm backend.
import strutil

func main():
    print(strutil.shout("hello"))
    print(strutil.repeat("ab", 3))
    print(strutil.indent("aligned", 4))
