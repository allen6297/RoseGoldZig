## Pattern-matching upgrades: match guards + destructuring (tuple/list, nested).
## Runs byte-identically on the tree-walker and the --vm backend.

enum Shape { POINT, LINE, TRIANGLE }

## --- guards: an arm matches only when its `if` condition also holds ---
func sign(n: int) -> str:
    return match n {
        0: "zero"
        x if x < 0: "negative"
        _: "positive"
    }

## --- tuple destructuring, with literals, bindings, and nesting ---
func describe(p: (int, int)) -> str:
    return match p {
        (0, 0): "origin"
        (0, y): "on the y-axis at ${y}"
        (x, 0): "on the x-axis at ${x}"
        (x, y): "point ${x},${y}"
    }

## --- list destructuring by exact length (a `_` covers the rest) ---
func head(xs: list<int>) -> str:
    return match xs {
        []: "empty"
        [only]: "just ${only}"
        [a, b]: "pair ${a} and ${b}"
        _: "many"
    }

## --- nesting + a guard cooperating on the same arm ---
func classify(v: any) -> str:
    return match v {
        (label, (x, y)) if x == y: "${label}: diagonal at ${x}"
        (label, (x, y)): "${label}: (${x}, ${y})"
        _: "unknown"
    }

func kind(count: int) -> Shape:
    return match count {
        1: Shape.POINT
        2: Shape.LINE
        _: Shape.TRIANGLE
    }

func main():
    print(sign(-4))                         ## negative
    print(sign(0))                          ## zero
    print(sign(9))                          ## positive

    print(describe((0, 0)))                 ## origin
    print(describe((0, 7)))                 ## on the y-axis at 7
    print(describe((3, 0)))                 ## on the x-axis at 3
    print(describe((3, 4)))                 ## point 3,4

    print(head([]))                         ## empty
    print(head([42]))                       ## just 42
    print(head([1, 2]))                     ## pair 1 and 2
    print(head([1, 2, 3, 4]))               ## many

    print(classify(("A", (5, 5))))          ## A: diagonal at 5
    print(classify(("B", (2, 9))))          ## B: (2, 9)
    print(classify("nope"))                 ## unknown

    print(kind(2))                          ## Shape.LINE
