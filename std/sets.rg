## std.sets — a Set collection, written in RoseGold itself (a class backed by a
## map). Demonstrates cross-module classes; runs on both backends.
##
##   import std.sets
##   var s = sets.of([1, 2, 2, 3])
##   print(s.size())          ## 3
##   print(s.member(2))       ## true

pub class Set:
    ## Membership is the map's key set; the bool value is just a marker.
    var items: map<any, bool> = {}

    ## Add `x` to the set (a no-op if already present).
    func add(x: any):
        items[x] = true

    ## Whether `x` is in the set.
    func member(x: any) -> bool:
        return has(items, x)

    ## Remove `x` if present (rebuilds the backing map; there's no delete builtin).
    func remove(x: any):
        var m: map<any, bool> = {}
        for k in keys(items):
            if k != x:
                m[k] = true
        items = m

    ## The number of distinct elements.
    func size() -> int:
        return len(items)

    ## The elements as a list (insertion order not guaranteed).
    func to_list() -> list:
        return keys(items)

    ## A new set with the elements of both this set and `other`.
    func union(other: Set) -> Set:
        var r = Set()
        for k in to_list():
            r.add(k)
        for k in other.to_list():
            r.add(k)
        return r

    ## A new set with only the elements in both this set and `other`.
    func intersect(other: Set) -> Set:
        var r = Set()
        for k in to_list():
            if other.member(k):
                r.add(k)
        return r

## Build a Set from the elements of a list.
pub func of(xs: list) -> Set:
    var s = Set()
    for x in xs:
        s.add(x)
    return s
