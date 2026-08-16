## Tagged-union enums: cases that carry data, destructured in `match`.
## Runs byte-identically on the tree-walker and the --vm backend.

## A tiny JSON-ish value: some cases carry a payload, some don't.
enum Json {
    Null,
    Bool(b: bool),
    Num(n: float),
    Arr(items: list)
}

## Render a value back to a string, destructuring each case's payload.
func show(j: Json) -> str:
    return match j {
        Json.Null: "null"
        Json.Bool(b) if b: "true"
        Json.Bool(b): "false"
        Json.Num(n): str(n)
        Json.Arr(xs): "[" + str(len(xs)) + " items]"
    }

## A binary tree — a recursive tagged union (a payload holding more of itself).
enum Tree {
    Leaf(value: int),
    Branch(left: Tree, right: Tree)
}

func sum(t: Tree) -> int:
    return match t {
        Tree.Leaf(v): v
        Tree.Branch(l, r): sum(l) + sum(r)
    }

func main():
    print(Json.Num(3.5))                    ## Json.Num(3.5)
    print(show(Json.Null))                  ## null
    print(show(Json.Bool(true)))            ## true
    print(show(Json.Bool(false)))           ## false
    print(show(Json.Num(42.0)))             ## 42
    print(show(Json.Arr([1, 2, 3])))        ## [3 items]

    ## Equality is deep over the payload.
    print(Json.Num(5.0) == Json.Num(5.0))   ## true
    print(Json.Num(5.0) == Json.Num(6.0))   ## false

    ## A case is a first-class constructor: pass it to a higher-order builtin.
    var nums = map([1, 2, 3], Json.Num)
    print(show(nums[0]))                     ## 1

    ## Recursive destructuring: (1 + 2) + (3 + 4) = 10.
    var t = Tree.Branch(
        Tree.Branch(Tree.Leaf(1), Tree.Leaf(2)),
        Tree.Branch(Tree.Leaf(3), Tree.Leaf(4)))
    print(sum(t))                            ## 10
