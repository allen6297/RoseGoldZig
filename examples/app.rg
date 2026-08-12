## Entry program for the module-system demo.
##
## `mathutil` is imported by both this file and `geometry`, yet it is loaded
## and executed only once. Each `mod.name` reaches an exported member; the
## private `mathutil.twice` is not reachable from here.

import mathutil
import geometry

func main():
    print("PI =", mathutil.PI)
    print("square(6) =", mathutil.square(6))
    print("area(2) =", mathutil.area(2))
    print("ring(3, 2) =", geometry.ring_area(3, 2))

    ## An imported type, named through its module and used across the boundary.
    var c: geometry.Circle = geometry.circle(5)
    print("circle r =", c.radius, "area =", mathutil.area(c.radius))
