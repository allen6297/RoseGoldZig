## The math stdlib: sqrt / pow / floor / ceil / round, plus map over a list.
## sqrt and pow return a float; floor/ceil/round return an int (round is
## half-away-from-zero). Runs the same on both backends:
##
##   zig build run -- run       examples/mathdemo.rg
##   zig build run -- run --vm  examples/mathdemo.rg   ## the bytecode VM

##
## hello
##
struct Point:
    var x: float = 0.0
    var y: float = 0.0

func point(x: float, y: float) -> Point:
    var p = Point()
    p.x = x
    p.y = y
    return p

func dist(a: Point, b: Point) -> float:
    var dx = a.x - b.x
    var dy = a.y - b.y
    return sqrt(dx * dx + dy * dy)

func main():
    var a = point(0.0, 0.0)
    var b = point(3.0, 4.0)
    print("distance:", dist(a, b))
    print("2^10 =", pow(2.0, 10.0))

    var vals = [2.3, 2.5, 2.7, -1.5]
    print("floor:", map(vals, func(v): floor(v)))
    print("ceil: ", map(vals, func(v): ceil(v)))
    print("round:", map(vals, func(v): round(v)))
