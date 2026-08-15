## std.test — a tiny unit-testing framework, written in RoseGold itself.
##
##   import std.test
##
##   func test_math():
##       test.assert_eq(2 + 2, 4)
##       test.assert(10 > 3, "ten beats three")
##
##   func main():
##       test.run([
##           ("math", test_math),
##       ])
##
## An assertion `raise`s on failure; `run` catches that per case, so one failing
## test never aborts the rest. Pure RoseGold, so it runs byte-identically on the
## tree-walker and the --vm backend.

## Raise a failure unless `cond` holds.
pub func assert(cond: bool, msg: str):
    if not cond:
        raise "assertion failed: ${msg}"

## Raise unless `actual == expected`, reporting both values.
pub func assert_eq(actual: any, expected: any):
    if actual != expected:
        raise "expected ${expected}, got ${actual}"

## Raise unless `actual != unexpected`.
pub func assert_ne(actual: any, unexpected: any):
    if actual == unexpected:
        raise "expected a value other than ${unexpected}"

## Raise unless `cond` is true.
pub func assert_true(cond: bool):
    if not cond:
        raise "expected true, got false"

## Raise unless `cond` is false.
pub func assert_false(cond: bool):
    if cond:
        raise "expected false, got true"

## Raise unless calling the zero-argument `fn` itself raises an error. Use it to
## check that a bad input is rejected: `assert_raises(func(): parse("nope"))`.
pub func assert_raises(fn: any):
    var raised = false
    try:
        fn()
    catch e:
        raised = true
    if not raised:
        raise "expected an error, but none was raised"

## Run a list of `(name, fn)` cases. Each `fn` is a zero-argument callable that
## uses the assertions above; a case passes if it returns without raising. Prints
## one line per case plus a summary, and returns true when every case passed.
pub func run(cases: list) -> bool:
    var passed = 0
    var failed = 0
    for entry in cases:
        var name, fn = entry
        try:
            fn()
            print("ok   - ${name}")
            passed = passed + 1
        catch e:
            print("FAIL - ${name}: ${e}")
            failed = failed + 1
    print("${passed} passed, ${failed} failed")
    return failed == 0
