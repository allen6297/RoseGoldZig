## Using std.test: a small suite that exercises the standard library and shows
## a deliberately failing case + assert_raises. Run on either backend:
##   zig build run -- run       examples/selftest.rg
##   zig build run -- run --vm  examples/selftest.rg

import std.test
import std.lists
import std.strings

func test_lists():
    test.assert_eq(lists.sum([1, 2, 3, 4]), 10)
    test.assert_eq(lists.unique([1, 1, 2, 3, 3]), [1, 2, 3])
    test.assert_eq(lists.last([]), nil)

func test_strings():
    test.assert_eq(upper("rose"), "ROSE")
    test.assert(contains("rosegold", "gold"), "substring present")

func test_raises():
    ## dividing by zero is a catchable built-in error
    test.assert_raises(func(): 1 / 0)

func test_that_fails():
    test.assert_eq(2 + 2, 5)

func main():
    var ok = test.run([
        ("lists", test_lists),
        ("strings", test_strings),
        ("raises", test_raises),
        ("intentional failure", test_that_fails),
    ])
    print("all green: ${ok}")
