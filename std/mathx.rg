## std.mathx — integer & numeric helpers, written in RoseGold itself.
## (Named `mathx` so it doesn't shade the built-in math functions like `sqrt`.)
##
##   import std.mathx
##   print(mathx.gcd(24, 36))   ## 12
##
## Runs on both backends.

## A rough value of π, for convenience.
pub const PI: float = 3.141592653589793

## Greatest common divisor of `a` and `b` (Euclid's algorithm; non-negative).
pub func gcd(a: int, b: int) -> int:
    var x = abs(a)
    var y = abs(b)
    while y != 0:
        var t = y
        y = x % y
        x = t
    return x

## Least common multiple of `a` and `b` (0 if either is 0).
pub func lcm(a: int, b: int) -> int:
    if a == 0 or b == 0:
        return 0
    return abs(a * b) / gcd(a, b)

## Clamp `x` into the inclusive range `[lo, hi]`.
pub func clamp(x: int, lo: int, hi: int) -> int:
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x

## The sign of `x`: -1, 0, or 1.
pub func sign(x: int) -> int:
    if x < 0:
        return -1
    if x > 0:
        return 1
    return 0

## `n!` (1 for n <= 1).
pub func factorial(n: int) -> int:
    var total = 1
    for i in 2..n + 1:
        total = total * i
    return total

## Whether `n` is a prime number.
pub func is_prime(n: int) -> bool:
    if n < 2:
        return false
    var i = 2
    while i * i <= n:
        if n % i == 0:
            return false
        i = i + 1
    return true

## The `n`th Fibonacci number (fib(0) = 0, fib(1) = 1).
pub func fib(n: int) -> int:
    var a = 0
    var b = 1
    for i in 0..n:
        var t = a + b
        a = b
        b = t
    return a

## The arithmetic mean of a non-empty list of ints, as a float.
pub func mean(xs: list<int>) -> float:
    var total = 0
    for x in xs:
        total = total + x
    return float(total) / float(len(xs))

## The largest element of a non-empty list of ints.
pub func maximum(xs: list<int>) -> int:
    var m = xs[0]
    for x in xs:
        if x > m:
            m = x
    return m

## The smallest element of a non-empty list of ints.
pub func minimum(xs: list<int>) -> int:
    var m = xs[0]
    for x in xs:
        if x < m:
            m = x
    return m
