## Default parameter values. A parameter may declare a default (`p = expr`);
## defaults must be trailing, and an omitted argument uses the default. Defaults
## are evaluated at call time in the function's home module (they see module-level
## names like GREETING, but not the other parameters). Runs identically on the
## tree-walker and the --vm backend.

const GREETING = "Hello"

func greet(name: str, greeting: str = GREETING, punct: str = "!"):
    print(greeting + ", " + name + punct)

func rect(w: int, h: int = 1) -> int:
    return w * h

class Counter:
    var n: int = 0
    func init(start: int = 0):
        n = start
    func bump(by: int = 1) -> int:
        n = n + by
        return n

func main():
    greet("Ada")                 ## Hello, Ada!
    greet("Ada", "Hi")           ## Hi, Ada!
    greet("Ada", "Hey", "?")     ## Hey, Ada?

    print(rect(4))               ## 4
    print(rect(4, 3))            ## 12

    var c = Counter()            ## starts at 0
    print(c.bump())              ## 1
    print(c.bump(10))            ## 11

    var scale = func(x, k = 2): x * k
    print(scale(5))              ## 10
    print(scale(5, 3))           ## 15
