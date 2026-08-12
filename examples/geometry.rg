## A module that itself imports another module, re-using its exports, and
## exports a type other modules can name as `geometry.Circle`.

import mathutil

pub struct Circle:
    var radius: int = 0

pub func circle(r: int) -> Circle:
    var c: Circle = Circle()
    c.radius = r
    return c

pub func ring_area(outer: int, inner: int) -> float:
    return mathutil.area(outer) - mathutil.area(inner)
