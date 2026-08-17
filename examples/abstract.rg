## Abstract classes + `super`: an abstract base defines a contract, concrete
## subclasses implement it, and `super` extends (not replaces) a base method.
## Runs byte-identically on the tree-walker and the --vm backend.

## An abstract class can't be constructed. Its `abstract` methods are bodiless
## contracts every concrete subclass must implement; the concrete `describe`
## calls the abstract `area`, dispatched virtually on the real subclass.
abstract class Shape:
    abstract func area() -> float
    abstract func name() -> str

    func describe() -> str:
        return name() + " with area " + str(area())

class Circle extends Shape:
    var r: float = 1.0

    func init(radius: float):
        r = radius

    func area() -> float:
        return 3.14 * r * r

    func name() -> str:
        return "circle"

## A subclass of a concrete class: `super` chains the base constructor and
## extends the base method rather than replacing it.
class LabeledCircle extends Circle:
    var label: str = "?"

    func init(radius: float, tag: str):
        super.init(radius)      ## run Circle.init to set r
        label = tag

    func name() -> str:
        return label + " " + super.name()   ## "big circle", not just "circle"

func main():
    var c = Circle(2.0)
    print(c.area())             ## 12.56
    print(c.describe())         ## circle with area 12.56

    var lc = LabeledCircle(1.0, "big")
    print(lc.name())            ## big circle
    print(lc.describe())        ## big circle with area 3.14
