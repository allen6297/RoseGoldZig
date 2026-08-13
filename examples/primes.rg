## Primes via trial division. Uses only core-language features, so it runs on
## both backends and prints the same thing either way:
##
##   zig build run -- run       examples/primes.rg
##   zig build run -- run --vm  examples/primes.rg   ## the bytecode VM

func is_prime(n: int) -> int:
    if n < 2:
        return 0
    var d = 2
    while d * d <= n:
        if n % d == 0:
            return 0
        d = d + 1
    return 1

func main():
    var primes = []
    var n = 2
    while len(primes) < 8:
        if is_prime(n) == 1:
            push(primes, n)
        n = n + 1
    print("first 8 primes:", primes)

    var total = 0
    for p in primes:
        if p == 7:
            continue
        total = total + p
    print("sum (skipping 7):", total)

    print("biggest=" + str(primes[len(primes) - 1]))
