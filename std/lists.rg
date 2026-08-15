## std.lists — list utilities, written in RoseGold itself.
##
##   import std.lists
##   print(lists.sum([1, 2, 3]))
##
## Runs on both backends (tree-walker and --vm). Element types are kept loose
## (`list` / `any`) so these work over lists of anything.

## Sum of a list of numbers (0 for an empty list).
pub func sum(xs: list<int>) -> int:
    var total = 0
    for x in xs:
        total = total + x
    return total

## Product of a list of numbers (1 for an empty list).
pub func product(xs: list<int>) -> int:
    var total = 1
    for x in xs:
        total = total * x
    return total

## The first `n` elements (fewer if the list is shorter).
pub func take(xs: list, n: int) -> list:
    return xs[0:n]

## Everything after the first `n` elements.
pub func drop(xs: list, n: int) -> list:
    return xs[n:len(xs)]

## The last element, or nil for an empty list.
pub func last(xs: list) -> any:
    if len(xs) == 0:
        return nil
    return xs[len(xs) - 1]

## How many times `x` appears in `xs`.
pub func count(xs: list, x: any) -> int:
    var n = 0
    for e in xs:
        if e == x:
            n = n + 1
    return n

## The elements of `xs` with duplicates removed, keeping first-seen order.
pub func unique(xs: list) -> list:
    var seen: map<any, bool> = {}
    var out = []
    for x in xs:
        if not has(seen, x):
            seen[x] = true
            push(out, x)
    return out

## Concatenate a list of lists into one flat list.
pub func flatten(xss: list) -> list:
    var out = []
    for xs in xss:
        for x in xs:
            push(out, x)
    return out

## Pair up two lists elementwise into a list of `(a, b)` tuples, stopping at the
## shorter length.
pub func zip(a: list, b: list) -> list:
    var out = []
    var n = min(len(a), len(b))
    for i in 0..n:
        push(out, (a[i], b[i]))
    return out

## `xs` paired with each element's index: a list of `(i, x)` tuples.
pub func enumerate(xs: list) -> list:
    var out = []
    for i, x in xs:
        push(out, (i, x))
    return out

## Whether every element is truthy-equal to `true`.
pub func all(xs: list<bool>) -> bool:
    for x in xs:
        if not x:
            return false
    return true

## Whether any element equals `true`.
pub func any(xs: list<bool>) -> bool:
    for x in xs:
        if x:
            return true
    return false

## Split `xs` into consecutive chunks of at most `size` elements.
pub func chunk(xs: list, size: int) -> list:
    var out = []
    var i = 0
    while i < len(xs):
        push(out, xs[i:i + size])
        i = i + size
    return out

## The integers `start, start+step, …` up to (but not including) `stop`.
pub func range_step(start: int, stop: int, step: int) -> list<int>:
    var out = []
    var i = start
    while i < stop:
        push(out, i)
        i = i + step
    return out
