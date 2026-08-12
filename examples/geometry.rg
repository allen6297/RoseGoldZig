## A module that itself imports another module, re-using its exports.

import mathutil

pub func ring_area(outer: int, inner: int) -> float:
    return mathutil.area(outer) - mathutil.area(inner)
