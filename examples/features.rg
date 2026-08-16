## A tour of the newer language features: bitwise operators, slicing, named
## arguments, and list comprehensions. Runs identically on the tree-walker and
## the --vm backend.

## --- bitwise operators (int-only: & | ^ ~ << >>) ---
func flags() -> int:
    var f = 0
    f = f | (1 << 0)          ## set bit 0
    f = f | (1 << 2)          ## set bit 2
    return f                  ## 0b101 = 5

## --- default + named arguments ---
func rect(w: int, h: int = 1, fill: str = ".") -> str:
    return fill + " " + str(w) + "x" + str(h)

func main():
    print(flags())                         ## 5
    print(5 & 3, 5 ^ 1, ~0)                 ## 1 4 -1

    ## slicing (list and string, clamped)
    var xs = [10, 20, 30, 40, 50]
    print(xs[1:4])                          ## [20, 30, 40]
    print("rosegold"[0:4])                  ## rose

    ## named arguments (reordered, skipping the h default)
    print(rect(w: 3, fill: "#"))            ## # 3x1

    ## list comprehensions (map / filter / two bindings / nesting)
    print([x * x for x in range(6)])        ## [0, 1, 4, 9, 16, 25]
    print([x for x in xs if x >= 30])       ## [30, 40, 50]
    print([i for i, v in xs if v > 25])     ## [2, 3, 4]
    var grid = [[r * c for c in range(3)] for r in range(3)]
    print(grid)                             ## [[0, 0, 0], [0, 1, 2], [0, 2, 4]]

    ## method-call syntax: `x.f(args)` on a primitive/collection is `f(x, args)`
    print("  Rose Gold  ".trim().lower())   ## rose gold
    print([3, 1, 2].sort().len())           ## 3
